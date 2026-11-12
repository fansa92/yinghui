// Video opens fast and actually starts (v0.1.3 follow-up).
//
// v0.1.3: music plays, video never does. The old path was: detail page
// probes PlaybackInfo (sequential), then the player probes it AGAIN,
// then the conservative decider forced nearly every file through
// server-side HLS transcoding — on a slow/shared server the transcode
// never yields its first segment, so mpv buffers forever and nothing
// ever surfaces an error. These tests pin the fixes:
//
// * detail + probe run concurrently (itemDetail, seriesDetail);
// * the player re-uses the detail page's probed sources (no 2nd probe);
// * a slow/broken probe falls back to the direct stream URL instead
//   of blocking playback (auth errors still surface);
// * a hung player open times out into the error view with retry.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';

Server _server() => Server(
  id: 'srv-emby',
  type: ServerType.emby,
  name: 'Test Emby',
  host: 'https://cf.imetyou.top',
  port: 443,
  username: 'yang',
  token: 'emby-token',
);

Map<String, dynamic> _movieJson({String id = 'm1'}) => {
  'Id': id,
  'Name': 'The Last Horizon',
  'ProductionYear': 2024,
  'Type': 'Movie',
  'Overview': 'A crew crosses the last horizon.',
  'RunTimeTicks': 76200000000,
  'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
  'People': [
    {'Type': 'Actor', 'Name': 'Ada Wong'},
  ],
  'Genres': ['Sci-Fi'],
  'MediaStreams': [],
};

Map<String, dynamic> _playbackInfoJson({
  String container = 'mp4',
  String videoCodec = 'h264',
  String audioCodec = 'aac',
  bool supportsDirectPlay = true,
}) => {
  'PlaySessionId': 'ps-1',
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
      ],
    },
  ],
};

Dio _mockEmbyDio(
  Map<String, dynamic> Function(RequestOptions options) respond,
) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
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

/// Mock Dio where the detail and the PlaybackInfo probe only answer
/// after the test releases them — so the test can prove both requests
/// were in flight at the same time (concurrent), not one after the
/// other (sequential: the second request would never arrive).
Dio _gatedDio({
  required List<String> gatePaths,
  required Map<String, dynamic> Function(String path) respond,
  required void Function(String path) onRequest,
  required Completer<void> release,
}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final path = options.path;
          if (path.contains('Users/Me')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'Id': 'user-1'},
              ),
            );
            return;
          }
          onRequest(path);
          if (gatePaths.any(path.contains)) {
            await release.future;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: respond(path),
            ),
          );
        },
      ),
    );
}

void main() {
  group('decidePlayback re-uses probed sources', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    RealVideoRepository makeRepo(EmbyClient Function(Server) factory) =>
        RealVideoRepository(store: store, database: db, clientFactory: factory);

    const item = VideoItem(
      id: 'm1',
      title: 'The Last Horizon',
      serverId: 'srv-emby',
    );

    test('cached sources: no second PlaybackInfo probe', () async {
      await store.add(_server());
      var probeCalls = 0;
      final dio = _mockEmbyDio((options) {
        if (options.path.contains('Users/Me')) return {'Id': 'user-1'};
        if (options.path.contains('PlaybackInfo')) {
          probeCalls++;
          return _playbackInfoJson();
        }
        return {};
      });
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      final sources = EmbyClient.parseMediaSources(_playbackInfoJson());
      final result = await repo.decidePlayback(item, sources: sources);
      expect(result.decision.isDirect, isTrue);
      expect(result.url, contains('/Videos/m1/stream'));
      expect(probeCalls, 0);
    });

    test('no cached sources: probes once', () async {
      await store.add(_server());
      var probeCalls = 0;
      final dio = _mockEmbyDio((options) {
        if (options.path.contains('Users/Me')) return {'Id': 'user-1'};
        if (options.path.contains('PlaybackInfo')) {
          probeCalls++;
          return _playbackInfoJson();
        }
        return {};
      });
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isTrue);
      expect(probeCalls, 1);
    });

    test('server refusing direct play still transcodes', () async {
      await store.add(_server());
      final dio = _mockEmbyDio((options) {
        if (options.path.contains('Users/Me')) return {'Id': 'user-1'};
        if (options.path.contains('PlaybackInfo')) {
          return _playbackInfoJson(supportsDirectPlay: false);
        }
        return {};
      });
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isFalse);
      expect(result.url, contains('/Videos/m1/master.m3u8'));
    });

    test('probe 500 falls back to the direct stream URL', () async {
      await store.add(_server());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'Id': 'user-1'},
                  ),
                );
                return;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 500),
                ),
              );
            },
          ),
        );
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isTrue);
      expect(result.url, contains('/Videos/m1/stream'));
    });

    test('probe timeout falls back to the direct stream URL', () async {
      await store.add(_server());
      final repo = makeRepo((s) => _TimeoutProbeClient(s));
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isTrue);
      expect(result.url, contains('/Videos/m1/stream'));
    });

    test('probe 401 still surfaces as an error, no silent fallback', () async {
      await store.add(_server());
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'Id': 'user-1'},
                  ),
                );
                return;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                ),
              );
            },
          ),
        );
      final repo = makeRepo((s) => EmbyClient(s, dio: dio));
      await expectLater(
        repo.decidePlayback(item),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('detail loads run concurrently', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('itemDetail: detail and probe in flight together', () async {
      await store.add(_server());
      final detailSeen = Completer<void>();
      final probeSeen = Completer<void>();
      final release = Completer<void>();
      final dio = _gatedDio(
        gatePaths: ['/Items/m1', 'PlaybackInfo'],
        respond: (path) =>
            path.contains('PlaybackInfo') ? _playbackInfoJson() : _movieJson(),
        onRequest: (path) {
          if (path.contains('PlaybackInfo') && !probeSeen.isCompleted) {
            probeSeen.complete();
          }
          if (path.contains('/Items/m1') && !detailSeen.isCompleted) {
            detailSeen.complete();
          }
        },
        release: release,
      );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: dio),
      );
      final future = repo.itemDetail('m1', 'srv-emby');
      // Both requests must be in flight before either is answered:
      // with the old sequential code the probe is only requested
      // after the detail answers, so this times out.
      await Future.wait([detailSeen.future, probeSeen.future])
          .timeout(const Duration(seconds: 5));
      release.complete();
      final detail = await future;
      expect(detail.item.title, 'The Last Horizon');
      expect(detail.mediaSources.length, 1);
    });

    test('seriesDetail: detail, seasons and episodes together', () async {
      await store.add(_server());
      final detailSeen = Completer<void>();
      final seasonsSeen = Completer<void>();
      final episodesSeen = Completer<void>();
      final release = Completer<void>();
      final dio = _gatedDio(
        gatePaths: ['/Items/s1', '/Seasons', '/Episodes'],
        respond: (path) {
          if (path.contains('/Seasons')) return {'Items': []};
          if (path.contains('/Episodes')) return {'Items': []};
          return _movieJson(id: 's1');
        },
        onRequest: (path) {
          if (path.contains('/Items/s1') && !detailSeen.isCompleted) {
            detailSeen.complete();
          }
          if (path.contains('/Seasons') && !seasonsSeen.isCompleted) {
            seasonsSeen.complete();
          }
          if (path.contains('/Episodes') && !episodesSeen.isCompleted) {
            episodesSeen.complete();
          }
        },
        release: release,
      );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: dio),
      );
      final future = repo.seriesDetail('s1', 'srv-emby');
      await Future.wait([
        detailSeen.future,
        seasonsSeen.future,
        episodesSeen.future,
      ]).timeout(const Duration(seconds: 5));
      release.complete();
      final detail = await future;
      expect(detail.series.id, 's1');
    });
  });

  group('VideoPlayerPage re-uses sources and times out a hung open', () {
    testWidgets('passes cached mediaSources to decidePlayback', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final repo = _RecordingVideoRepo();
      final service = VideoPlayerService(
        backendFactory: _FakeVideoBackend.new,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        durationSeconds: 7620,
        serverId: 'srv-emby',
      );
      final sources = EmbyClient.parseMediaSources(_playbackInfoJson());
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            repo: repo,
            history: PlaybackStore(db),
            service: service,
            mediaSources: sources,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(repo.lastSources, isNotNull);
      expect(repo.lastSources!.length, 1);
      expect(repo.lastSources!.first.container, 'mp4');
    });

    testWidgets('a hung open shows the timeout error, not a spinner', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final repo = _RecordingVideoRepo();
      final service = VideoPlayerService(
        backendFactory: _HungVideoBackend.new,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        durationSeconds: 7620,
        serverId: 'srv-emby',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            repo: repo,
            history: PlaybackStore(db),
            service: service,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The 30s open timeout fires in fake async: the spinner must
      // give way to the short timeout error with a retry button.
      await tester.pump(const Duration(seconds: 31));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('打开视频超时'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}

/// Emby client whose PlaybackInfo probe never answers in time.
class _TimeoutProbeClient extends EmbyClient {
  _TimeoutProbeClient(super.server) : super(dio: Dio());

  @override
  Future<List<MediaSourceInfo>> getPlaybackInfo(String itemId) async {
    throw TimeoutException('probe timed out', const Duration(seconds: 15));
  }
}

/// Video repo that records the sources it was given for decidePlayback.
class _RecordingVideoRepo implements VideoRepository {
  List<MediaSourceInfo>? lastSources;

  @override
  bool get hasCredentials => true;

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
    List<MediaSourceInfo>? sources,
  }) async {
    lastSources = sources;
    return (
      decision: const PlaybackDecision(kind: PlaybackKind.direct),
      url: 'https://example.com/v.mp4',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake video backend: no native code, streams driven by the test.
class _FakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Object? get videoController => null;

  @override
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    _duration.add(const Duration(seconds: 7620));
  }

  @override
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async => _position.add(position);
  @override
  Future<void> stop() async => _playing.add(false);
  @override
  Future<void> setSubtitleTrack(String? url) async {}

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
    await _buffering.close();
  }
}

/// Backend whose open() never completes — the hung-open case.
class _HungVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Object? get videoController => null;

  @override
  Future<void> open(String url, {Duration startPosition = Duration.zero}) {
    // Never completes: the page must time out, not spin forever.
    return Completer<void>().future;
  }

  @override
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async => _position.add(position);
  @override
  Future<void> stop() async => _playing.add(false);
  @override
  Future<void> setSubtitleTrack(String? url) async {}

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
    await _buffering.close();
  }
}
