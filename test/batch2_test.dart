import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/app_state.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/widgets/desktop_layout.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/downloads/download_detail_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/video/episode_detail_page.dart';

Server _server({
  String id = 'srv-qb',
  ServerType type = ServerType.qbittorrent,
  String host = 'https://sg.kass.qzz.io/qb/',
  String username = 'yang',
  String token = 'pw',
}) => Server(
  id: id,
  type: type,
  name: 'Test ${type.label}',
  host: host,
  port: 443,
  username: username,
  token: token,
);

Dio _mockDio(
  FutureOr<Response<dynamic>> Function(RequestOptions options) handler,
) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, h) async {
        h.resolve(await handler(options));
      },
    ),
  );
  return dio;
}

Response<dynamic> _ok(
  RequestOptions options,
  dynamic data, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) => Response<dynamic>(
  requestOptions: options,
  data: data,
  statusCode: statusCode,
  headers: headers == null ? Headers() : Headers.fromMap(headers),
);

Map<String, dynamic> _qbJson({
  String hash = 'abc123',
  String name = 'Ubuntu 24.04 LTS.iso',
}) => {
  'hash': hash,
  'name': name,
  'state': 'downloading',
  'progress': 0.62,
  'dlspeed': 5242880,
  'size': 6442450944,
  'completed': 3995076198,
  'eta': 480,
  'save_path': '/data/downloads',
};

void main() {
  group('Batch 2 — qB torrent hash download', () {
    test('isTorrentHash: 40 and 64 hex accepted, others rejected', () {
      expect(RealDownloadRepository.isTorrentHash('a' * 40), isTrue);
      expect(RealDownloadRepository.isTorrentHash('B' * 64), isTrue);
      expect(RealDownloadRepository.isTorrentHash('a' * 39), isFalse);
      expect(RealDownloadRepository.isTorrentHash('a' * 41), isFalse);
      expect(RealDownloadRepository.isTorrentHash('g' * 40), isFalse);
      expect(RealDownloadRepository.isTorrentHash(''), isFalse);
      expect(
        RealDownloadRepository.isTorrentHash('magnet:?xt=urn:btih:${'a' * 40}'),
        isFalse,
      );
    });

    test('hashToMagnet builds the magnet URI, lowercased', () {
      expect(
        RealDownloadRepository.hashToMagnet('A' * 40),
        'magnet:?xt=urn:btih:${'a' * 40}',
      );
      expect(
        RealDownloadRepository.normalizeAddInput('b' * 64),
        'magnet:?xt=urn:btih:${'b' * 64}',
      );
      expect(
        RealDownloadRepository.normalizeAddInput('magnet:?xt=urn:btih:abc'),
        'magnet:?xt=urn:btih:abc',
      );
    });

    test('isValidAddInput accepts hash, magnet, http; rejects garbage', () {
      expect(RealDownloadRepository.isValidAddInput('a' * 40), isTrue);
      expect(RealDownloadRepository.isValidAddInput('a' * 64), isTrue);
      expect(
        RealDownloadRepository.isValidAddInput('magnet:?xt=urn:btih:abc'),
        isTrue,
      );
      expect(
        RealDownloadRepository.isValidAddInput(
          'https://example.invalid/x.torrent',
        ),
        isTrue,
      );
      expect(RealDownloadRepository.isValidAddInput('not a link'), isFalse);
      expect(RealDownloadRepository.isValidAddInput('a' * 39), isFalse);
      expect(RealDownloadRepository.isValidAddInput(''), isFalse);
    });

    group('addTask with a bare hash', () {
      late AppDatabase db;
      late ServerStore store;

      setUp(() {
        db = AppDatabase.forExecutor(NativeDatabase.memory());
        store = ServerStore(database: db);
      });

      tearDown(() async {
        await db.close();
      });

      Future<RealDownloadRepository> makeRepo({
        required String hash,
        required List<String> sentUrls,
        required List<String> calls,
      }) async {
        await store.add(_server(id: 'srv-qb'));
        final dio = _mockDio((options) {
          calls.add(options.path);
          if (options.path.contains('auth/login')) {
            return _ok(
              options,
              'Ok',
              headers: {
                'set-cookie': ['SID=s1; path=/'],
              },
            );
          }
          if (options.path.contains('torrents/add')) {
            sentUrls.add('${(options.data as Map)['urls']}');
            return _ok(options, 'Ok.');
          }
          // refresh() after the add: the new torrent is live.
          return _ok(options, [_qbJson(hash: hash, name: 'Added.iso')]);
        });
        return RealDownloadRepository(
          store: store,
          database: db,
          qbFactory: (s) => QbittorrentClient(s, dio: dio),
        );
      }

      test(
        '40-hex hash is sent as a magnet URI and the input persists',
        () async {
          final hash = 'a' * 40;
          final sentUrls = <String>[];
          final calls = <String>[];
          final repo = await makeRepo(
            hash: hash,
            sentUrls: sentUrls,
            calls: calls,
          );
          final ok = await repo.addTask(magnetOrUrl: hash);
          expect(ok, isTrue);
          expect(sentUrls, ['magnet:?xt=urn:btih:$hash']);
          expect(repo.tasks, hasLength(1));
          expect(repo.tasks.first.hash, hash);
          expect(repo.tasks.first.sourceInput, hash);
          // And it survives a reload from Drift (restart).
          final rows = await db.select(db.downloadTasks).get();
          expect(rows, hasLength(1));
          expect(rows.first.sourceInput, hash);
        },
      );

      test('64-hex hash is sent as a magnet URI', () async {
        final hash = 'b' * 64;
        final sentUrls = <String>[];
        final calls = <String>[];
        final repo = await makeRepo(
          hash: hash,
          sentUrls: sentUrls,
          calls: calls,
        );
        expect(await repo.addTask(magnetOrUrl: hash), isTrue);
        expect(sentUrls, ['magnet:?xt=urn:btih:$hash']);
      });

      test('invalid hash is rejected with zero client calls', () async {
        final sentUrls = <String>[];
        final calls = <String>[];
        final repo = await makeRepo(
          hash: 'a' * 40,
          sentUrls: sentUrls,
          calls: calls,
        );
        expect(await repo.addTask(magnetOrUrl: 'z' * 40), isFalse);
        expect(await repo.addTask(magnetOrUrl: 'a' * 39), isFalse);
        expect(await repo.addTask(magnetOrUrl: ''), isFalse);
        expect(calls, isEmpty);
        expect(sentUrls, isEmpty);
      });

      test('existing magnet behaviour is unchanged', () async {
        final magnet = 'magnet:?xt=urn:btih:${'c' * 40}&dn=Demo';
        final sentUrls = <String>[];
        final calls = <String>[];
        final repo = await makeRepo(
          hash: 'c' * 40,
          sentUrls: sentUrls,
          calls: calls,
        );
        expect(await repo.addTask(magnetOrUrl: magnet), isTrue);
        expect(sentUrls, [magnet]);
        expect(repo.tasks.first.sourceInput, magnet);
        expect(repo.tasks.first.magnetUri, magnet);
      });
    });
  });

  group('Batch 2 — Emby media-stream parsing', () {
    test(
      'parseMediaSources keeps channels, sample rate, frame rate, flags',
      () {
        final sources = EmbyClient.parseMediaSources({
          'MediaSources': [
            {
              'Id': 'ms1',
              'Container': 'mkv',
              'Bitrate': 8500000,
              'VideoCodec': 'h264',
              'VideoStream': {'Width': 1920, 'Height': 1080},
              'MediaStreams': [
                {
                  'Type': 'Video',
                  'Index': 0,
                  'Codec': 'h264',
                  'Width': 1920,
                  'Height': 1080,
                  'FrameRate': 23.976,
                  'Bitrate': 8000000,
                },
                {
                  'Type': 'Audio',
                  'Index': 1,
                  'Codec': 'aac',
                  'Language': 'eng',
                  'Channels': 6,
                  'SampleRate': 48000,
                  'Bitrate': 384000,
                  'IsDefault': true,
                },
                {
                  'Type': 'Subtitle',
                  'Index': 2,
                  'Codec': 'srt',
                  'Language': 'chi',
                  'IsForced': true,
                  'DisplayTitle': 'Chinese (forced)',
                },
              ],
            },
          ],
        });
        expect(sources, hasLength(1));
        final source = sources.first;
        expect(source.container, 'mkv');
        expect(source.videoBitRate, 8500000);
        final video = source.videoStreams.first;
        expect(video.codec, 'h264');
        expect(video.width, 1920);
        expect(video.height, 1080);
        expect(video.frameRate, 23.976);
        expect(video.bitRate, 8000000);
        final audio = source.audioStreams.first;
        expect(audio.codec, 'aac');
        expect(audio.language, 'eng');
        expect(audio.channels, 6);
        expect(audio.sampleRate, 48000);
        expect(audio.bitRate, 384000);
        expect(audio.isDefault, isTrue);
        final sub = source.subtitles.first;
        expect(sub.codec, 'srt');
        expect(sub.language, 'chi');
        expect(sub.isForced, isTrue);
        expect(sub.displayTitle, 'Chinese (forced)');
      },
    );

    test('parseSubtitleStreams keeps isDefault', () {
      final subs = EmbyClient.parseSubtitleStreams({
        'MediaStreams': [
          {
            'Type': 'Subtitle',
            'Index': 0,
            'Codec': 'ass',
            'Language': 'jpn',
            'IsDefault': true,
            'IsExternal': true,
            'DeliveryUrl': '/Videos/x/Subtitles/0/Stream.ass',
          },
        ],
      });
      expect(subs.first.isDefault, isTrue);
      expect(subs.first.isExternal, isTrue);
      expect(subs.first.deliveryUrl, contains('Stream.ass'));
    });

    test('DownloadTask.magnetUri reconstructs from a hash', () {
      const t = DownloadTask(
        id: 'abc',
        name: 'Demo',
        source: DownloadSource.qbittorrent,
        hash: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
      expect(
        t.magnetUri,
        'magnet:?xt=urn:btih:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
      const noHash = DownloadTask(
        id: 'g1',
        name: 'Demo',
        source: DownloadSource.aria2,
      );
      expect(noHash.magnetUri, isEmpty);
    });
  });

  group('Batch 2 — AppStateStore round-trip', () {
    test('tab, music, video and download filters survive a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStateStore(prefs: prefs);
      await store.load();
      expect(store.lastTab, 0);
      expect(store.lastMusic, isNull);

      await store.setLastTab(3);
      await store.saveMusicState(
        const [
          Track(
            id: 't1',
            title: 'One',
            artist: 'A',
            durationSeconds: 200,
            serverId: 'srv-a',
          ),
          Track(
            id: 't2',
            title: 'Two',
            artist: 'A',
            durationSeconds: 180,
            serverId: 'srv-a',
          ),
        ],
        1,
        const Duration(seconds: 65),
      );
      await store.recordLastVideo(
        const VideoItem(
          id: 'v1',
          title: 'Movie',
          type: 'Movie',
          durationSeconds: 3600,
          serverId: 'srv-e',
        ),
        const Duration(seconds: 120),
      );
      await store.setDownloadFilters(source: 'qbittorrent', status: 'paused');

      final reloaded = AppStateStore(prefs: prefs);
      await reloaded.load();
      expect(reloaded.lastTab, 3);
      final music = reloaded.lastMusic!;
      expect(music.queue.map((t) => t.id), ['t1', 't2']);
      expect(music.index, 1);
      expect(music.positionSeconds, 65);
      expect(music.queue[1].title, 'Two');
      final video = reloaded.lastVideo!;
      expect(video.id, 'v1');
      expect(video.positionSeconds, 120);
      expect(reloaded.downloadSourceFilter, 'qbittorrent');
      expect(reloaded.downloadStatusFilter, 'paused');
    });

    test('corrupt saved music is ignored, not a crash', () async {
      SharedPreferences.setMockInitialValues({
        'yinghui_last_music': 'not-json{{{',
        'yinghui_last_tab': 9,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = AppStateStore(prefs: prefs);
      await store.load();
      expect(store.lastMusic, isNull);
      expect(store.lastTab, 3); // clamped to the 4 tabs
    });
  });

  group('Batch 2 — PlayerService restore', () {
    late _BatchFakeBackend backend;
    late PlayerService service;

    const tracks = [
      Track(
        id: 't1',
        title: 'One',
        artist: 'A',
        durationSeconds: 200,
        serverId: 'srv-a',
      ),
      Track(
        id: 't2',
        title: 'Two',
        artist: 'A',
        durationSeconds: 180,
        serverId: 'srv-a',
      ),
    ];

    setUp(() {
      backend = _BatchFakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/rest/stream?id=${t.id}',
        backendFactory: () => backend,
      );
    });

    test('restoreQueue shows the track and position without playing', () {
      service.restoreQueue(
        tracks,
        index: 1,
        position: const Duration(seconds: 65),
      );
      expect(service.currentTrack?.id, 't2');
      expect(service.currentIndex, 1);
      expect(service.position, const Duration(seconds: 65));
      expect(service.isPlaying, isFalse);
      expect(backend.openedUrl, isNull);
      expect(backend.playCalls, 0);
    });

    test('togglePlay after restore opens the stream and seeks to the saved position', () async {
      service.restoreQueue(
        tracks,
        index: 1,
        position: const Duration(seconds: 65),
      );
      await service.togglePlay();
      await Future<void>.delayed(Duration.zero);
      expect(backend.openedUrl, contains('id=t2'));
      expect(backend.seekCalls, 1);
      expect(backend.playCalls, 1);
      expect(service.isPlaying, isTrue);
    });
  });

  group('Batch 2 — EpisodeDetailPage', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    VideoDetail detailWithSources() => VideoDetail(
      item: const VideoItem(
        id: 'e1',
        title: 'Pilot',
        type: 'Episode',
        seasonNumber: 1,
        episodeNumber: 1,
        durationSeconds: 2880,
        playbackPositionSeconds: 600,
        overview: 'The crew sets out.',
      ),
      mediaSources: [
        MediaSourceInfo(
          id: 'ms1',
          container: 'mkv',
          videoBitRate: 8500000,
          streams: [
            const MediaStreamInfo(
              type: 'Video',
              index: 0,
              codec: 'h264',
              width: 1920,
              height: 1080,
              frameRate: 23.976,
              bitRate: 8000000,
            ),
            const MediaStreamInfo(
              type: 'Audio',
              index: 1,
              codec: 'aac',
              language: 'eng',
              channels: 6,
              sampleRate: 48000,
              bitRate: 384000,
              isDefault: true,
            ),
            const MediaStreamInfo(
              type: 'Subtitle',
              index: 2,
              codec: 'srt',
              language: 'chi',
              displayTitle: 'Chinese',
              isForced: true,
            ),
          ],
        ),
      ],
      subtitleTracks: const [
        SubtitleTrackInfo(
          index: 2,
          codec: 'srt',
          language: 'chi',
          displayTitle: 'Chinese',
          isForced: true,
          deliveryUrl: '/Videos/e1/Subtitles/2/Stream.srt',
        ),
      ],
    );

    Future<void> pumpEpisode(
      WidgetTester tester,
      VideoDetail detail, {
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: EpisodeDetailPage(
            episode: detail.item,
            repo: _BatchFakeVideoRepo(detail),
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows video, audio (bitrate + format) and subtitle info', (
      tester,
    ) async {
      await pumpEpisode(tester, detailWithSources());
      expect(find.text('视频信息'), findsOneWidget);
      expect(find.text('音频信息'), findsOneWidget);
      expect(find.text('字幕信息'), findsOneWidget);
      expect(find.text('h264'), findsWidgets);
      expect(find.text('1920×1080'), findsOneWidget);
      expect(find.text('23.976 fps'), findsOneWidget);
      expect(find.text('8000 kbps'), findsOneWidget);
      expect(find.textContaining('aac'), findsOneWidget);
      expect(find.textContaining('384 kbps'), findsOneWidget);
      expect(find.textContaining('5.1 声道'), findsOneWidget);
      expect(find.textContaining('48.0 kHz'), findsOneWidget);
      expect(find.text('Chinese'), findsOneWidget);
      expect(find.textContaining('内嵌'), findsOneWidget);
      expect(find.text('Resume from 10:00'), findsOneWidget);
    });

    testWidgets('no media sources shows an explicit empty state', (
      tester,
    ) async {
      const detail = VideoDetail(
        item: VideoItem(id: 'e9', title: 'Lost', type: 'Episode'),
      );
      await pumpEpisode(tester, detail);
      expect(find.text('暂无媒体信息'), findsOneWidget);
      expect(find.text('视频信息'), findsNothing);
    });

    testWidgets('wide layout builds without overflow', (tester) async {
      await pumpEpisode(
        tester,
        detailWithSources(),
        size: const Size(1440, 900),
      );
      expect(find.text('视频信息'), findsOneWidget);
      expect(find.text('音频信息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Batch 2 — DownloadDetailPage', () {
    testWidgets('magnet details, copy buttons, single pause/resume', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter/platform', JSONMethodCodec()),
            (call) async {
              // The handler returns plain values; the test messenger
              // encodes them. (Returning an already-encoded envelope
              // here corrupts the reply.)
              return switch (call.method) {
                'Clipboard.hasStrings' => {'value': false},
                'LiveText.isLiveTextInputAvailable' => false,
                _ => null,
              };
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('flutter/platform', JSONMethodCodec()),
              null,
            ),
      );
      final hash40 = 'a' * 40;
      final task = DownloadTask(
        id: hash40,
        name: 'Demo.iso',
        source: DownloadSource.qbittorrent,
        status: DownloadStatus.downloading,
        progress: 0.68,
        speedBytesPerSec: 3355443,
        sizeBytes: 2000000000,
        downloadedBytes: 1360000000,
        etaSeconds: 207,
        savePath: '/data/downloads',
        hash: hash40,
        sourceInput: 'magnet:?xt=urn:btih:$hash40',
        files: ['Demo.iso', 'Demo.nfo'],
      );
      final repo = _BatchFakeDownloadRepo([task]);
      // Tall surface: the page is a ListView, which only builds the
      // rows in the viewport — a phone-height surface leaves the
      // file list and bottom buttons unbuilt.
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadDetailPage(task: task, repo: repo),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('68%'), findsOneWidget);
      expect(find.text('磁力详情'), findsOneWidget);
      expect(find.textContaining('magnet:?xt=urn:btih:'), findsOneWidget);
      expect(find.text(hash40), findsOneWidget);
      expect(find.text('Demo.iso'), findsWidgets);
      expect(find.text('Demo.nfo'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('继续'), findsNothing);
      expect(find.text('复制'), findsNWidgets(2)); // magnet + hash

      // Copy the hash: the second copy button, snackbar confirms.
      // Two pumps: the Clipboard.setData round-trip is async, so the
      // snackbar only appears on the frame after the tap's frame.
      await tester.tap(find.text('复制').at(1));
      await tester.pump();
      await tester.pump();
      expect(find.text('Hash 已复制'), findsOneWidget);
      expect(repo.paused, isEmpty);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(repo.paused, [hash40]);
    });

    testWidgets(
      'paused task shows Resume only, no magnet section when unknown',
      (tester) async {
        const task = DownloadTask(
          id: 'g1',
          name: 'File.flac',
          source: DownloadSource.aria2,
          status: DownloadStatus.paused,
          progress: 0.45,
        );
        final repo = _BatchFakeDownloadRepo([task]);
        // Tall surface (see the test above): the bottom buttons are
        // below the fold on a phone-height surface and unbuilt.
        tester.view.physicalSize = const Size(390, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: DownloadDetailPage(task: task, repo: repo),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('继续'), findsOneWidget);
        expect(find.text('暂停'), findsNothing);
        expect(find.text('暂无磁力信息'), findsOneWidget);
      },
    );
  });

  group('Batch 2 — desktop layout', () {
    test('grid columns: 2 on phones, 4 on desktop', () {
      expect(gridColumnsForWidth(390), 2);
      expect(gridColumnsForWidth(800), 2);
      expect(gridColumnsForWidth(1023), 2);
      expect(gridColumnsForWidth(1024), 4);
      expect(gridColumnsForWidth(1440), 4);
    });

    testWidgets('CenteredContent constrains width on desktop, not on phones', (
      tester,
    ) async {
      Future<double> widthAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: CenteredContent(
                child: SizedBox(
                  key: Key('box'),
                  width: double.infinity,
                  height: 100,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.getSize(find.byKey(const Key('box'))).width;
      }

      expect(await widthAt(const Size(1440, 900)), 1000);
      expect(await widthAt(const Size(390, 844)), 390);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    });
  });
}

/// Fake video repo: only itemDetail is real; the rest is unreachable
/// from the episode detail page.
class _BatchFakeVideoRepo implements VideoRepository {
  _BatchFakeVideoRepo(this.detail);

  final VideoDetail detail;

  @override
  bool get hasCredentials => true;

  @override
  Future<VideoDetail> itemDetail(String itemId, String serverId) async =>
      detail;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake download repo: a fixed task list, recording pause calls.
class _BatchFakeDownloadRepo extends ChangeNotifier
    implements DownloadRepository {
  _BatchFakeDownloadRepo(List<DownloadTask> tasks) : _tasks = tasks;

  final List<DownloadTask> _tasks;
  final List<String> paused = [];

  @override
  bool get hasCredentials => true;

  @override
  List<Server> get usableDownloaders => const [];

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  List<DownloadTask> get activeTasks => _tasks;

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async => false;

  @override
  Future<bool> pauseTask(DownloadTask task) async {
    paused.add(task.id);
    return true;
  }

  @override
  Future<bool> resumeTask(DownloadTask task) async => true;

  @override
  Future<bool> deleteTask(
    DownloadTask task, {
    bool deleteFiles = false,
  }) async => true;

  @override
  Future<bool> retryTask(DownloadTask task) async => true;

  @override
  void startPolling({int intervalSeconds = 5}) {}

  @override
  void stopPolling() {}
}

/// Fake audio backend (same shape as the P2 one): no native code.
class _BatchFakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  int playCalls = 0;
  int seekCalls = 0;

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Future<void> open(String url) async {
    openedUrl = url;
    _duration.add(const Duration(seconds: 180));
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    _position.add(position);
  }

  double _volume = 1.0;
  double? lastVolume;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    lastVolume = _volume;
  }

  @override
  Future<void> stop() async {
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}
