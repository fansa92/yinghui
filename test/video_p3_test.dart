import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/fake_repos.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';
import 'package:yinghui/features/video/video_page.dart';

Server _server({
  String id = 'srv-emby',
  String host = 'https://cf.imetyou.top',
  int port = 443,
  String username = 'yang',
  String token = 'emby-token',
}) => Server(
  id: id,
  type: ServerType.emby,
  name: 'Test Emby',
  host: host,
  port: port,
  username: username,
  token: token,
);

Map<String, dynamic> _movieJson({
  String id = 'm1',
  String title = 'The Last Horizon',
  int year = 2024,
  int playedPercentage = 0,
  int positionTicks = 0,
}) => {
  'Id': id,
  'Name': title,
  'ProductionYear': year,
  'Type': 'Movie',
  'Overview': 'A crew crosses the last horizon.',
  'RunTimeTicks': 76200000000,
  'UserData': {
    'PlayedPercentage': playedPercentage,
    'PlaybackPositionTicks': positionTicks,
  },
};

Map<String, dynamic> _episodeJson({
  String id = 'e1',
  String title = 'Pilot',
  int episode = 1,
}) => {
  'Id': id,
  'Name': title,
  'Type': 'Episode',
  'SeriesId': 's1',
  'SeasonId': 'se1',
  'ParentIndexNumber': 1,
  'IndexNumber': episode,
  'RunTimeTicks': 28800000000,
  'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
};

Map<String, dynamic> _detailJson() => {
  ..._movieJson(playedPercentage: 62, positionTicks: 47244000000),
  'People': [
    {'Type': 'Actor', 'Name': 'Ada Wong'},
    {'Type': 'Actor', 'Name': 'Ben Stone'},
    {'Type': 'Director', 'Name': 'Dan Ray'},
  ],
  'Genres': ['Sci-Fi', 'Drama'],
  'MediaStreams': [
    {
      'Type': 'Video',
      'Index': 0,
      'Codec': 'h264',
      'Width': 1920,
      'Height': 1080,
    },
    {'Type': 'Audio', 'Index': 1, 'Codec': 'aac', 'Language': 'eng'},
    {
      'Type': 'Subtitle',
      'Index': 2,
      'Codec': 'srt',
      'Language': 'eng',
      'DisplayTitle': 'English',
      'IsExternal': true,
      'DeliveryUrl': '/Videos/m1/ms1/Subtitles/2/Stream.srt',
    },
    {
      'Type': 'Subtitle',
      'Index': 3,
      'Codec': 'ass',
      'Language': 'chi',
      'DisplayTitle': 'Chinese',
      'IsExternal': false,
    },
  ],
};

Map<String, dynamic> _playbackInfoJson({
  String container = 'mkv',
  String videoCodec = 'hevc',
  String audioCodec = 'dts',
  bool supportsDirectPlay = true,
}) => {
  'MediaSources': [
    {
      'Id': 'ms1',
      'Container': container,
      'VideoCodec': videoCodec,
      'AudioCodec': audioCodec,
      'SupportsDirectPlay': supportsDirectPlay,
      'SupportsDirectStream': true,
      'MediaStreams': [
        {'Type': 'Video', 'Index': 0, 'Codec': videoCodec},
        {'Type': 'Audio', 'Index': 1, 'Codec': audioCodec},
        {'Type': 'Subtitle', 'Index': 2, 'Codec': 'srt', 'Language': 'eng'},
      ],
    },
  ],
};

/// A Dio that answers Emby calls from [respond], keyed by path.
Dio _mockEmbyDio(
  Map<String, dynamic> Function(RequestOptions options) respond, {
  List<String>? seenPaths,
}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Clients use relative paths now; normalise with a leading
          // slash so the matchers below read the same either way.
          final seenPath = options.path.startsWith('/')
              ? options.path
              : '/${options.path}';
          seenPaths?.add('${options.method} $seenPath');
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: respond(options),
            ),
          );
        },
      ),
    );
}

Dio _embyDioForTests({List<String>? seenPaths}) {
  return _mockEmbyDio((options) {
    final path = options.path.startsWith('/')
        ? options.path
        : '/${options.path}';
    if (path.contains('Users/Me')) {
      return {'Id': 'user-1', 'Name': 'yang'};
    }
    if (path.contains('/Views')) {
      return {
        'Items': [
          {'Id': 'lib1', 'Name': 'Movies', 'CollectionType': 'movies'},
          {'Id': 'lib2', 'Name': 'TV Shows', 'CollectionType': 'tvshows'},
        ],
      };
    }
    if (path.contains('Items/Resume')) {
      return {
        'Items': [_movieJson(playedPercentage: 62, positionTicks: 47244000000)],
      };
    }
    if (path.contains('PlaybackInfo')) {
      return _playbackInfoJson();
    }
    if (path.contains('/Seasons')) {
      return {
        'Items': [
          {'Id': 'se1', 'Name': 'Season 1', 'IndexNumber': 1, 'ChildCount': 8},
          {'Id': 'se2', 'Name': 'Season 2', 'IndexNumber': 2, 'ChildCount': 6},
        ],
      };
    }
    if (path.contains('/Episodes')) {
      return {
        'Items': [
          _episodeJson(),
          _episodeJson(id: 'e2', title: 'Second', episode: 2),
        ],
      };
    }
    if (path.contains('PlayedItems') || path.contains('/Progress')) {
      return {};
    }
    if (path.contains('/Items/') && !path.endsWith('/Items')) {
      // Item detail: /Users/user-1/Items/m1
      return _detailJson();
    }
    if (path.contains('/Items')) {
      final search = options.queryParameters['SearchTerm'] as String?;
      final items = [_movieJson(), _movieJson(id: 'm2', title: 'Paper Moon')];
      if (search != null && search.isNotEmpty) {
        return {
          'Items': items
              .where(
                (m) => (m['Name'] as String).toLowerCase().contains(
                  search.toLowerCase(),
                ),
              )
              .toList(),
        };
      }
      return {'Items': items};
    }
    return {};
  }, seenPaths: seenPaths);
}

void main() {
  group('Emby video endpoints (mocked Dio)', () {
    test('getUserViews parses libraries', () async {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final views = await client.getUserViews();
      expect(views.map((v) => v.name), ['Movies', 'TV Shows']);
      expect(views.first.collectionType, 'movies');
    });

    test('getResumeItems parses progress and resume position', () async {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final items = await client.getResumeItems();
      expect(items.length, 1);
      expect(items.first.title, 'The Last Horizon');
      expect(items.first.progress, closeTo(0.62, 0.001));
      // 47,244,000,000 ticks = 4724 seconds.
      expect(items.first.playbackPositionSeconds, 4724);
      expect(items.first.positionText, '78:44');
    });

    test('getItemDetail parses cast, genres and subtitle streams', () async {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final detail = await client.getItemDetail('m1');
      expect(detail.item.title, 'The Last Horizon');
      expect(detail.item.cast, ['Ada Wong', 'Ben Stone']);
      expect(detail.item.genres, ['Sci-Fi', 'Drama']);
      expect(detail.subtitleTracks.length, 2);
      final eng = detail.subtitleTracks.first;
      expect(eng.language, 'eng');
      expect(eng.displayTitle, 'English');
      expect(eng.isExternal, isTrue);
      expect(eng.deliveryUrl, contains('Stream.srt'));
      expect(detail.subtitleTracks[1].codec, 'ass');
    });

    test('getSeasons and getEpisodes parse series structure', () async {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final seasons = await client.getSeasons('s1');
      expect(seasons.map((s) => s.name), ['Season 1', 'Season 2']);
      expect(seasons.first.episodeCount, 8);
      final episodes = await client.getEpisodes('s1');
      expect(episodes.length, 2);
      expect(episodes.first.type, 'Episode');
      expect(episodes.first.seriesId, 's1');
      expect(episodes.first.seasonNumber, 1);
      expect(episodes[1].episodeNumber, 2);
    });

    test('getPlaybackInfo parses media sources and subtitles', () async {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final sources = await client.getPlaybackInfo('m1');
      expect(sources.length, 1);
      expect(sources.first.container, 'mkv');
      expect(sources.first.videoCodec, 'hevc');
      expect(sources.first.subtitles.length, 1);
      expect(sources.first.subtitles.first.language, 'eng');
    });

    test(
      'subtitleUrl prefers DeliveryUrl, else builds Stream.srt URL',
      () async {
        final client = EmbyClient(_server(), dio: _embyDioForTests());
        const withDelivery = SubtitleTrackInfo(
          index: 2,
          codec: 'srt',
          deliveryUrl: '/Videos/m1/ms1/Subtitles/2/Stream.srt',
          mediaSourceId: 'ms1',
        );
        expect(
          client.subtitleUrl('m1', withDelivery),
          'https://cf.imetyou.top/Videos/m1/ms1/Subtitles/2/Stream.srt',
        );
        const built = SubtitleTrackInfo(index: 3, codec: 'ass');
        // No media source id: the empty segment is omitted, not left as '//'.
        expect(
          client.subtitleUrl('m1', built),
          'https://cf.imetyou.top/Videos/m1/Subtitles/3/Stream.srt'
          '?api_key=emby-token',
        );
      },
    );

    test('transcodeUrl carries codecs and bitrate ceiling', () {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      final url = client.transcodeUrl(
        'm1',
        maxStreamingBitrate: 4000000,
        subtitleStreamIndex: 2,
      );
      expect(url, contains('/Videos/m1/master.m3u8?'));
      expect(url, contains('VideoCodec=h264'));
      expect(url, contains('AudioCodec=aac'));
      expect(url, contains('MaxStreamingBitrate=4000000'));
      expect(url, contains('SubtitleStreamIndex=2'));
    });

    test('imageUrl carries the api_key so posters load without headers', () {
      final client = EmbyClient(_server(), dio: _embyDioForTests());
      expect(
        client.imageUrl('m1'),
        contains('/Items/m1/Images/Primary?api_key=emby-token'),
      );
    });

    test('reportProgress and markPlayed hit the right endpoints', () async {
      final seen = <String>[];
      final client = EmbyClient(
        _server(),
        dio: _embyDioForTests(seenPaths: seen),
      );
      await client.reportProgress(
        'm1',
        const Duration(minutes: 10),
        isPaused: true,
      );
      await client.markPlayed('m1');
      expect(
        seen,
        containsAll([
          'POST /Users/user-1/Items/m1/PlayingItems/m1/Progress',
          'POST /Users/user-1/PlayedItems/m1',
        ]),
      );
    });
  });

  group('PlaybackDecider (pure)', () {
    MediaSourceInfo source({
      String container = 'mp4',
      String videoCodec = 'h264',
      String audioCodec = 'aac',
      bool supportsDirectPlay = true,
    }) => MediaSourceInfo(
      id: 'ms1',
      container: container,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      supportsDirectPlay: supportsDirectPlay,
    );

    test('mp4/h264/aac direct-plays', () {
      final d = PlaybackDecider.decide(source());
      expect(d.isDirect, isTrue);
      expect(d.kind, PlaybackKind.direct);
    });

    test('mkv/hevc/dts transcodes', () {
      final d = PlaybackDecider.decide(
        source(container: 'mkv', videoCodec: 'hevc', audioCodec: 'dts'),
      );
      expect(d.isDirect, isFalse);
      expect(d.kind, PlaybackKind.transcode);
    });

    test('mp4/h264/ac3 transcodes (audio not in the direct list)', () {
      final d = PlaybackDecider.decide(source(audioCodec: 'ac3'));
      expect(d.isDirect, isFalse);
    });

    test('server refusing direct play transcodes even for mp4/h264/aac', () {
      final d = PlaybackDecider.decide(source(supportsDirectPlay: false));
      expect(d.isDirect, isFalse);
    });

    test('picking 720p forces transcode with a 4 Mbps ceiling', () {
      final d = PlaybackDecider.decide(source(), quality: VideoQuality.p720);
      expect(d.isDirect, isFalse);
      expect(d.maxStreamingBitrate, 4000000);
    });

    test('subtitle index is carried into the transcode decision', () {
      const sub = SubtitleTrackInfo(index: 2, language: 'eng');
      final d = PlaybackDecider.decide(
        source(container: 'mkv', videoCodec: 'hevc', audioCodec: 'dts'),
        subtitle: sub,
      );
      expect(d.subtitleStreamIndex, 2);
    });
  });

  group('RealVideoRepository merge / dedupe / fallback', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> addServers() async {
      await store.add(_server(id: 'srv-a', username: 'yang', token: 'tok-a'));
      await store.add(_server(id: 'srv-b', username: 'yang', token: 'tok-b'));
    }

    RealVideoRepository makeRepo(EmbyClient Function(Server server) factory) =>
        RealVideoRepository(store: store, database: db, clientFactory: factory);

    test(
      'no credentials -> hasCredentials false, lists fall back to fake',
      () async {
        final repo = makeRepo((s) => EmbyClient(s));
        expect(repo.hasCredentials, isFalse);
        expect(await repo.continueWatching(), FakeVideoRepo.continueWatching);
        expect(await repo.recentlyAdded(), FakeVideoRepo.recentlyAdded);
      },
    );

    test('movies merge across servers and dedupe by title+year', () async {
      await addServers();
      Dio dioFor(String id) {
        return _mockEmbyDio((options) {
          if (options.path.contains('Users/Me')) {
            return {'Id': 'user-1'};
          }
          final items = id == 'srv-a'
              ? [_movieJson(), _movieJson(id: 'm2', title: 'Paper Moon')]
              : [
                  _movieJson(id: 'm1-dup'),
                  _movieJson(id: 'm3', title: 'Desert Road', year: 2022),
                ];
          return {'Items': items};
        });
      }

      final repo = makeRepo((s) => EmbyClient(s, dio: dioFor(s.id)));
      final movies = await repo.movies();
      expect(movies.map((m) => m.title), [
        'The Last Horizon',
        'Paper Moon',
        'Desert Road',
      ]);
      expect(movies.first.serverId, 'srv-a');
    });

    test('one server down does not blank the list', () async {
      await addServers();
      Dio dioFor(String id) {
        if (id == 'srv-b') {
          return Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionTimeout,
                    ),
                  );
                },
              ),
            );
        }
        return _mockEmbyDio((options) {
          if (options.path.contains('Users/Me')) return {'Id': 'user-1'};
          return {
            'Items': [_movieJson()],
          };
        });
      }

      final repo = makeRepo((s) => EmbyClient(s, dio: dioFor(s.id)));
      final movies = await repo.movies();
      expect(movies.map((m) => m.title), ['The Last Horizon']);
    });

    test('decidePlayback: mkv/hevc transcodes to master.m3u8', () async {
      await store.add(_server());
      final repo = makeRepo((s) => EmbyClient(s, dio: _embyDioForTests()));
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        serverId: 'srv-emby',
      );
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isFalse);
      expect(result.url, contains('/Videos/m1/master.m3u8'));
    });

    test('decidePlayback: mp4/h264/aac direct-plays via stream URL', () async {
      await store.add(_server());
      final dio = _mockEmbyDio((options) {
        if (options.path.contains('Users/Me')) return {'Id': 'user-1'};
        if (options.path.contains('PlaybackInfo')) {
          return _playbackInfoJson(
            container: 'mp4',
            videoCodec: 'h264',
            audioCodec: 'aac',
          );
        }
        return {};
      });
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        serverId: 'srv-emby',
      );
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isTrue);
      expect(result.url, contains('/Videos/m1/stream'));
    });

    test('seriesDetail groups seasons and episodes', () async {
      await store.add(_server());
      final repo = makeRepo((s) => EmbyClient(s, dio: _embyDioForTests()));
      const series = VideoItem(
        id: 's1',
        title: 'Harbour Lights',
        type: 'Series',
        serverId: 'srv-emby',
      );
      final detail = await repo.seriesDetail('s1', 'srv-emby');
      expect(detail.seasons.length, 2);
      expect(detail.episodes.length, 2);
      expect(detail.episodesForSeason('se1').length, 2);
      expect(series.type, 'Series');
    });
  });

  group('VideoPlayerService with a fake backend', () {
    late _FakeVideoBackend backend;
    late VideoPlayerService service;
    late AppDatabase db;

    const item = VideoItem(
      id: 'm1',
      title: 'The Last Horizon',
      durationSeconds: 7620,
      serverId: 'srv-emby',
    );

    Track trackFor(VideoItem v) => Track(
      id: v.id,
      title: v.title,
      artist: v.sourceLabel,
      durationSeconds: v.durationSeconds,
      serverId: v.serverId,
    );

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      backend = _FakeVideoBackend();
      service = VideoPlayerService(
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('open starts playback at the resume position', () async {
      await service.open(
        'https://example.invalid/Videos/m1/stream',
        trackFor(item),
        startPosition: const Duration(minutes: 78, seconds: 44),
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.hasVideo, isTrue);
      expect(service.isPlaying, isTrue);
      expect(backend.openedUrl, contains('/Videos/m1/stream'));
      expect(backend.openedStart, const Duration(minutes: 78, seconds: 44));
      final rows = await db.select(db.playbackHistory).get();
      expect(rows.length, 1);
      expect(rows.single.itemId, 'm1');
    });

    test('togglePlay pauses and saves the position', () async {
      await service.open('https://example.invalid/x', trackFor(item));
      await Future<void>.delayed(Duration.zero);
      expect(service.isPlaying, isTrue);
      await service.togglePlay();
      await Future<void>.delayed(Duration.zero);
      expect(service.isPlaying, isFalse);
      expect(backend.pauseCalls, 1);
    });

    test('completed fires onCompleted once', () async {
      var completed = 0;
      await service.open(
        'https://example.invalid/x',
        trackFor(item),
        onCompleted: () => completed++,
      );
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, 1);
    });

    test('empty URL opens nothing', () async {
      await service.open('', trackFor(item));
      expect(backend.openedUrl, isNull);
      expect(service.hasVideo, isFalse);
    });

    test('setSubtitleTrack forwards the SRT URL', () async {
      await service.open('https://example.invalid/x', trackFor(item));
      await service.setSubtitleTrack('https://example.invalid/sub.srt');
      expect(backend.subtitleUrl, 'https://example.invalid/sub.srt');
      await service.setSubtitleTrack(null);
      expect(backend.subtitleUrl, isNull);
    });
  });

  group('VideoPage empty state (no credentials)', () {
    testWidgets('shows "No Emby account yet"', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final repo = RealVideoRepository(store: store, database: db);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPage(
            repo: repo,
            store: store,
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('还没有 Emby 账号'), findsOneWidget);
      expect(find.text('去服务器页'), findsOneWidget);
      expect(find.text('The Last Horizon'), findsNothing);
    });
  });

  group('VideoPlayerPage error state', () {
    testWidgets('shows "Could not play" when playback fails', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        durationSeconds: 7620,
        serverId: 'srv-emby',
      );
      final service = VideoPlayerService(
        backendFactory: _FakeVideoBackend.new,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            repo: _ThrowingVideoRepo(),
            history: PlaybackStore(db),
            service: service,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('无法播放'), findsOneWidget);
    });
  });
}

/// Fake video backend: no native code, streams driven by the test.
class _FakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  Duration? openedStart;
  String? subtitleUrl;
  int pauseCalls = 0;

  void emitCompleted() => _completed.add(true);

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Object? get videoController => null;

  @override
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    openedUrl = url;
    openedStart = startPosition;
    _duration.add(const Duration(seconds: 7620));
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async => _position.add(position);

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setSubtitleTrack(String? url) async {
    subtitleUrl = url;
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

/// A repo whose playback decision always fails, for the error-state test.
class _ThrowingVideoRepo implements VideoRepository {
  @override
  bool get hasCredentials => true;

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
  }) async {
    throw ApiException('Emby returned no media sources');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
