import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/app_state.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/widgets/server_selector.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/subsonic_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/downloads/downloads_page.dart';
import 'package:yinghui/features/music/music_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/video/video_page.dart';

Server _server({
  String id = 'srv-a',
  ServerType type = ServerType.navidrome,
  String name = 'Server A',
  String host = '192.168.1.10',
  String username = 'yang',
  String token = 'pw',
}) => Server(
  id: id,
  type: type,
  name: name,
  host: host,
  port: 443,
  username: username,
  token: token,
);

/// A ServerStore whose list is driven directly in tests, bypassing
/// secure storage (see the same helper in fix_pass_test.dart): the
/// real plugin's write hangs forever in widget tests on this machine.
class _MutableStore extends ServerStore {
  _MutableStore({required super.database});

  final List<Server> _list = [];

  @override
  List<Server> get servers => List.unmodifiable(_list);

  void addServer(Server server) {
    _list.add(server);
    notifyListeners();
  }

  void removeServer(String id) {
    _list.removeWhere((s) => s.id == id);
    notifyListeners();
  }
}

Response<dynamic> _ok(RequestOptions options, dynamic data) =>
    Response<dynamic>(requestOptions: options, statusCode: 200, data: data);

/// Mock Subsonic Dio: records the server id per request and answers
/// getAlbumList2 with one album named after the server. [throwOn]
/// makes every call fail, to simulate an offline server.
Dio _mockSubsonicDio(
  String serverId,
  List<String> hit, {
  bool throwOn = false,
}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hit.add(serverId);
          if (throwOn) {
            handler.reject(
              DioException(
                requestOptions: options,
                message: 'offline',
                type: DioExceptionType.connectionError,
              ),
            );
            return;
          }
          final path = options.path;
          if (path.contains('getAlbumList2')) {
            handler.resolve(
              _ok(options, {
                'subsonic-response': {
                  'status': 'ok',
                  'albumList2': {
                    'album': [
                      {
                        'id': 'a-$serverId',
                        'name': 'Album $serverId',
                        'artist': 'Artist $serverId',
                        'year': 2024,
                        'songCount': 10,
                      },
                    ],
                  },
                },
              }),
            );
          } else if (path.contains('getArtists')) {
            handler.resolve(
              _ok(options, {
                'subsonic-response': {'status': 'ok', 'artists': {}},
              }),
            );
          } else if (path.contains('getPlaylists')) {
            handler.resolve(
              _ok(options, {
                'subsonic-response': {'status': 'ok', 'playlists': {}},
              }),
            );
          } else if (path.contains('getStarred2')) {
            handler.resolve(
              _ok(options, {
                'subsonic-response': {'status': 'ok', 'starred2': {}},
              }),
            );
          } else {
            handler.resolve(
              _ok(options, {
                'subsonic-response': {'status': 'ok'},
              }),
            );
          }
        },
      ),
    );
}

/// Mock Emby Dio: records the server id per request. Users/Me returns
/// a user id; Resume and Items return one video named after the server.
Dio _mockEmbyDio(String serverId, List<String> hit, {bool throwOn = false}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hit.add(serverId);
          if (throwOn) {
            handler.reject(
              DioException(
                requestOptions: options,
                message: 'offline',
                type: DioExceptionType.connectionError,
              ),
            );
            return;
          }
          final path = options.path;
          if (path.contains('Users/Me')) {
            handler.resolve(_ok(options, {'Id': 'u1', 'Name': 'yang'}));
          } else {
            handler.resolve(
              _ok(options, {
                'Items': [
                  {
                    'Id': 'v-$serverId',
                    'Name': 'Video $serverId',
                    'Type': 'Movie',
                    'ProductionYear': 2024,
                    'RunTimeTicks': 72000000000,
                  },
                ],
              }),
            );
          }
        },
      ),
    );
}

/// Mock qBittorrent Dio: login answers exactly "Ok" (what the client
/// checks) with an SID cookie; torrents/info returns one task.
Dio _mockQbDio(String serverId, List<String> hit) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hit.add(serverId);
          if (options.path.contains('auth/login')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: 'Ok',
                headers: Headers.fromMap({
                  'set-cookie': ['SID=test-sid'],
                }),
              ),
            );
          } else if (options.path.contains('torrents/info')) {
            handler.resolve(
              _ok(options, [
                {
                  'hash': 'hash-$serverId',
                  'name': 'QB File $serverId',
                  'state': 'downloading',
                  'progress': 0.5,
                  'dlspeed': 1000,
                  'size': 10000,
                  'completed': 5000,
                  'eta': 60,
                  'save_path': '/dl',
                },
              ]),
            );
          } else {
            handler.resolve(_ok(options, 'Ok'));
          }
        },
      ),
    );
}

/// Mock Transmission Dio: every RPC call answers torrent_get with one
/// task (or an error when [throwOn]).
Dio _mockTransmissionDio(
  String serverId,
  List<String> hit, {
  bool throwOn = false,
}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hit.add(serverId);
          if (throwOn) {
            handler.reject(
              DioException(
                requestOptions: options,
                message: 'offline',
                type: DioExceptionType.connectionError,
              ),
            );
            return;
          }
          handler.resolve(
            _ok(options, {
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'torrents': [
                  {
                    'id': 1,
                    'name': 'TR File $serverId',
                    'status': 4,
                    'percent_done': 0.3,
                    'rate_download': 2000,
                    'total_size': 8000,
                    'downloaded_ever': 2400,
                    'eta': 30,
                    'download_dir': '/dl',
                    'hash_string': 'abc',
                  },
                ],
              },
            }),
          );
        },
      ),
    );
}

/// Mock aria2 Dio: tellActive returns one task, the other tells none.
Dio _mockAriaDio(String serverId, List<String> hit) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          hit.add(serverId);
          final method = (options.data as Map?)?['method'] as String?;
          final result = method == 'aria2.tellActive'
              ? [
                  {
                    'gid': 'g-$serverId',
                    'status': 'active',
                    'totalLength': '10000',
                    'completedLength': '4000',
                    'downloadSpeed': '3000',
                    'dir': '/dl',
                    'files': [
                      {'path': '/dl/Aria File $serverId.mkv'},
                    ],
                  },
                ]
              : <dynamic>[];
          handler.resolve(
            _ok(options, {'jsonrpc': '2.0', 'id': 1, 'result': result}),
          );
        },
      ),
    );
}

/// Recording music repo: records the serverId each list call received
/// and returns one album/artist/playlist named after it, so a widget
/// test can tell which server the page loaded.
class _RecordingMusicRepo implements MusicRepository {
  final List<String?> albumCalls = [];
  final List<String?> artistCalls = [];
  final List<String?> playlistCalls = [];
  final List<String?> starredCalls = [];
  final List<String?> searchCalls = [];

  Album _album(String? serverId) => Album(
    id: 'a-${serverId ?? 'all'}',
    title: 'Album ${serverId ?? 'all'}',
    artist: 'Artist',
    year: 2024,
    serverId: serverId ?? '',
  );

  @override
  bool get hasCredentials => true;

  @override
  Future<List<Album>> albums({
    String type = 'newest',
    int size = 20,
    int offset = 0,
    String? serverId,
  }) async {
    albumCalls.add(serverId);
    return [_album(serverId)];
  }

  @override
  Future<List<Artist>> artists({String? serverId}) async {
    artistCalls.add(serverId);
    return const [];
  }

  @override
  Future<({List<Track> songs, List<Album> albums, List<Artist> artists})>
  search(String query, {String? serverId}) async {
    searchCalls.add(serverId);
    return (songs: <Track>[], albums: <Album>[], artists: <Artist>[]);
  }

  @override
  Future<({Album album, List<Track> tracks})> album(
    String albumId,
    String serverId,
  ) async => (album: _album(serverId), tracks: <Track>[]);

  @override
  Future<({List<Track> songs, List<Album> albums})> starred({
    String? serverId,
  }) async {
    starredCalls.add(serverId);
    return (songs: <Track>[], albums: <Album>[]);
  }

  @override
  Future<List<Playlist>> playlists({String? serverId}) async {
    playlistCalls.add(serverId);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Recording video repo: same idea as [_RecordingMusicRepo].
class _RecordingVideoRepo implements VideoRepository {
  final List<String?> continueCalls = [];
  final List<String?> recentCalls = [];
  final List<String?> movieCalls = [];
  final List<String?> seriesCalls = [];
  final List<String?> searchCalls = [];

  VideoItem _video(String? serverId) => VideoItem(
    id: 'v-${serverId ?? 'all'}',
    title: 'Video ${serverId ?? 'all'}',
    type: 'Movie',
    year: 2024,
    serverId: serverId ?? '',
  );

  @override
  bool get hasCredentials => true;

  @override
  Future<List<LibraryView>> libraries() async => const [];

  @override
  Future<List<VideoItem>> continueWatching({String? serverId}) async {
    continueCalls.add(serverId);
    return [_video(serverId)];
  }

  @override
  Future<List<VideoItem>> recentlyAdded({String? serverId}) async {
    recentCalls.add(serverId);
    return [_video(serverId)];
  }

  @override
  Future<List<RecentCategory>> recentlyAddedByCategory({
    String? serverId,
  }) async {
    recentCalls.add(serverId);
    return [
      RecentCategory(name: '最近添加', items: [_video(serverId)]),
    ];
  }

  @override
  Future<List<VideoItem>> movies({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    movieCalls.add(serverId);
    return [_video(serverId)];
  }

  @override
  Future<List<VideoItem>> series({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    seriesCalls.add(serverId);
    return [_video(serverId)];
  }

  @override
  Future<List<VideoItem>> search(String query, {String? serverId}) async {
    searchCalls.add(serverId);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Recording download repo: a fixed task list, filtered in-memory by
/// [serverFilter] on refresh — the same contract the real repo keeps
/// (refresh only shows the selected server's tasks).
class _RecordingDownloadRepo extends ChangeNotifier
    implements DownloadRepository {
  _RecordingDownloadRepo({
    required this.downloaders,
    required List<DownloadTask> tasks,
  }) : _allTasks = tasks;

  final List<Server> downloaders;
  final List<DownloadTask> _allTasks;
  final List<String?> refreshCalls = [];
  final List<int> pollingCalls = [];

  @override
  String? serverFilter;

  @override
  bool get hasCredentials => downloaders.isNotEmpty;

  @override
  List<Server> get usableDownloaders => List.unmodifiable(downloaders);

  @override
  List<DownloadTask> get tasks => serverFilter == null
      ? List.unmodifiable(_allTasks)
      : _allTasks.where((t) => t.serverId == serverFilter).toList();

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  List<DownloadTask> get activeTasks =>
      tasks.where((t) => t.status == DownloadStatus.downloading).toList();

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Future<void> refresh() async {
    refreshCalls.add(serverFilter);
    notifyListeners();
  }

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async => false;

  @override
  Future<bool> pauseTask(DownloadTask task) async => false;

  @override
  Future<bool> resumeTask(DownloadTask task) async => false;

  @override
  Future<bool> deleteTask(
    DownloadTask task, {
    bool deleteFiles = false,
  }) async => false;

  @override
  Future<bool> retryTask(DownloadTask task) async => false;

  @override
  void startPolling({int intervalSeconds = 5}) {
    pollingCalls.add(intervalSeconds);
  }

  @override
  void stopPolling() {}
}

/// Minimal fake audio backend: no native code.
class _FakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Future<void> open(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  double get volume => 1.0;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  group('AppStateStore per-page server selection', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('selections persist and restore across a simulated restart', () async {
      final first = AppStateStore();
      await first.load();
      await first.setMusicServerId('srv-nav-b');
      await first.setVideoServerId('srv-emby-b');
      await first.setDownloadsServerId('srv-qb');

      // A fresh store on the same preferences = an app restart.
      final restarted = AppStateStore();
      await restarted.load();
      expect(restarted.musicServerId, 'srv-nav-b');
      expect(restarted.videoServerId, 'srv-emby-b');
      expect(restarted.downloadsServerId, 'srv-qb');
    });

    test('setting null clears the selection', () async {
      final first = AppStateStore();
      await first.load();
      await first.setMusicServerId('srv-nav-b');
      await first.setMusicServerId(null);

      final restarted = AppStateStore();
      await restarted.load();
      expect(restarted.musicServerId, isNull);
    });

    test('each page keeps its own selection', () async {
      final store = AppStateStore();
      await store.load();
      await store.setMusicServerId('srv-nav-b');
      expect(store.videoServerId, isNull);
      expect(store.downloadsServerId, isNull);
      await store.setVideoServerId('srv-emby-a');
      expect(store.musicServerId, 'srv-nav-b');
    });
  });

  group('RealMusicRepository serverId scoping', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'albums() queries every server; albums(serverId) queries one',
      () async {
        final hit = <String>[];
        final store = _MutableStore(database: db)
          ..addServer(_server(id: 'srv-a', name: 'Navidrome A'))
          ..addServer(_server(id: 'srv-b', name: 'Navidrome B'));
        final repo = RealMusicRepository(
          store: store,
          database: db,
          clientFactory: (s) =>
              SubsonicClient(s, dio: _mockSubsonicDio(s.id, hit)),
        );

        hit.clear();
        final merged = await repo.albums();
        expect(
          merged.map((a) => a.title),
          containsAll(['Album srv-a', 'Album srv-b']),
        );
        expect(hit.toSet(), {'srv-a', 'srv-b'});

        hit.clear();
        final single = await repo.albums(serverId: 'srv-b');
        expect(single.map((a) => a.title), ['Album srv-b']);
        expect(hit, ['srv-b']);
      },
    );

    test(
      'single-server failure rethrows; merged mode skips the dead server',
      () async {
        final hit = <String>[];
        final store = _MutableStore(database: db)
          ..addServer(_server(id: 'srv-a', name: 'Navidrome A'))
          ..addServer(_server(id: 'srv-b', name: 'Navidrome B'));
        final repo = RealMusicRepository(
          store: store,
          database: db,
          clientFactory: (s) => SubsonicClient(
            s,
            dio: _mockSubsonicDio(s.id, hit, throwOn: s.id == 'srv-b'),
          ),
        );

        // Filtered to the dead server: the error surfaces (the page
        // shows its error view instead of an empty list).
        await expectLater(
          repo.albums(serverId: 'srv-b'),
          throwsA(isA<Object>()),
        );
        // Merged: the dead server is skipped, the live one still loads.
        final merged = await repo.albums();
        expect(merged.map((a) => a.title), ['Album srv-a']);
        expect(hit.toSet(), contains('srv-a'));
      },
    );
  });

  group('RealVideoRepository serverId scoping', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'continueWatching() queries every server; with serverId only one',
      () async {
        final hit = <String>[];
        final store = _MutableStore(database: db)
          ..addServer(
            _server(id: 'srv-ea', type: ServerType.emby, name: 'Emby A'),
          )
          ..addServer(
            _server(id: 'srv-eb', type: ServerType.emby, name: 'Emby B'),
          );
        final repo = RealVideoRepository(
          store: store,
          database: db,
          clientFactory: (s) => EmbyClient(s, dio: _mockEmbyDio(s.id, hit)),
        );

        hit.clear();
        final merged = await repo.continueWatching();
        expect(
          merged.map((v) => v.title),
          containsAll(['Video srv-ea', 'Video srv-eb']),
        );
        expect(hit.toSet(), {'srv-ea', 'srv-eb'});

        hit.clear();
        final single = await repo.continueWatching(serverId: 'srv-eb');
        expect(single.map((v) => v.title), ['Video srv-eb']);
        // Only srv-eb was queried (Users/Me is cached per client after
        // the merged call above, so this round is a single Resume hit).
        expect(hit.toSet(), {'srv-eb'});
      },
    );

    test(
      'single-server failure rethrows; merged mode skips the dead server',
      () async {
        final store = _MutableStore(database: db)
          ..addServer(
            _server(id: 'srv-ea', type: ServerType.emby, name: 'Emby A'),
          )
          ..addServer(
            _server(id: 'srv-eb', type: ServerType.emby, name: 'Emby B'),
          );
        final repo = RealVideoRepository(
          store: store,
          database: db,
          clientFactory: (s) => EmbyClient(
            s,
            dio: _mockEmbyDio(s.id, <String>[], throwOn: s.id == 'srv-eb'),
          ),
        );

        await expectLater(
          repo.continueWatching(serverId: 'srv-eb'),
          throwsA(isA<Object>()),
        );
        final merged = await repo.continueWatching();
        expect(merged.map((v) => v.title), ['Video srv-ea']);
      },
    );
  });

  group('RealDownloadRepository serverFilter', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    RealDownloadRepository repoWithMocks(
      _MutableStore store,
      List<String> hit,
    ) {
      return RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: _mockQbDio(s.id, hit)),
        transmissionFactory: (s) =>
            TransmissionClient(s, dio: _mockTransmissionDio(s.id, hit)),
        ariaFactory: (s) => Aria2Client(s, dio: _mockAriaDio(s.id, hit)),
      );
    }

    test('refresh() queries all downloaders; filter queries one', () async {
      final hit = <String>[];
      final store = _MutableStore(database: db)
        ..addServer(
          _server(id: 'srv-qb', type: ServerType.qbittorrent, name: 'qB'),
        )
        ..addServer(
          _server(id: 'srv-tr', type: ServerType.transmission, name: 'TR'),
        )
        ..addServer(
          _server(id: 'srv-ar', type: ServerType.aria2, name: 'aria2'),
        );
      final repo = repoWithMocks(store, hit);

      await repo.refresh();
      expect(
        repo.tasks.map((t) => t.name),
        containsAll([
          'QB File srv-qb',
          'TR File srv-tr',
          'Aria File srv-ar.mkv',
        ]),
      );
      expect(hit.toSet(), {'srv-qb', 'srv-tr', 'srv-ar'});

      hit.clear();
      repo.serverFilter = 'srv-tr';
      await repo.refresh();
      expect(repo.tasks.map((t) => t.name), ['TR File srv-tr']);
      expect(hit, ['srv-tr']);

      hit.clear();
      repo.serverFilter = null;
      await repo.refresh();
      expect(hit.toSet(), {'srv-qb', 'srv-tr', 'srv-ar'});
    });

    test('only the selected server error is recorded', () async {
      final hit = <String>[];
      final store = _MutableStore(database: db)
        ..addServer(
          _server(id: 'srv-qb', type: ServerType.qbittorrent, name: 'qB'),
        )
        ..addServer(
          _server(id: 'srv-tr', type: ServerType.transmission, name: 'TR'),
        );
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: _mockQbDio(s.id, hit)),
        transmissionFactory: (s) => TransmissionClient(
          s,
          dio: _mockTransmissionDio(s.id, hit, throwOn: true),
        ),
        ariaFactory: (s) => Aria2Client(s, dio: _mockAriaDio(s.id, hit)),
      );

      repo.serverFilter = 'srv-tr';
      await repo.refresh();
      expect(repo.tasks, isEmpty);
      expect(repo.errors.keys, ['srv-tr']);
      expect(hit, ['srv-tr']);
    });
  });

  group('MusicPage server selector', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    Future<AppStateStore> appState() async {
      final state = AppStateStore();
      await state.load();
      return state;
    }

    testWidgets(
      'shows 全部 + Navidrome servers only; switching reloads one server',
      (tester) async {
        final store = _MutableStore(database: db)
          ..addServer(_server(id: 'srv-a', name: 'Navidrome A'))
          ..addServer(_server(id: 'srv-b', name: 'Navidrome B'))
          ..addServer(
            _server(id: 'srv-e', type: ServerType.emby, name: 'Emby Server'),
          );
        final repo = _RecordingMusicRepo();
        final player = PlayerService(
          streamUrlFor: (_) => '',
          backendFactory: _FakeBackend.new,
        );
        addTearDown(player.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MusicPage(
                repo: repo,
                player: player,
                store: store,
                settings: SettingsService(),
                appState: await appState(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Default is 全部: the first load queried with no server id.
        expect(find.text('全部'), findsOneWidget);
        expect(repo.albumCalls, [null]);

        // The dropdown lists the Navidrome servers, not the Emby one.
        await tester.tap(find.text('全部'));
        await tester.pumpAndSettle();
        expect(find.text('Navidrome A'), findsOneWidget);
        expect(find.text('Navidrome B'), findsOneWidget);
        expect(find.text('Emby Server'), findsNothing);
        expect(find.text('管理服务器'), findsOneWidget);

        await tester.tap(find.text('Navidrome B'));
        await tester.pumpAndSettle();
        expect(repo.albumCalls.last, 'srv-b');
        expect(find.text('Album srv-b'), findsOneWidget);
        expect(find.text('Album srv-a'), findsNothing);
        // The button now shows the selected server.
        expect(find.text('Navidrome B'), findsOneWidget);
      },
    );

    testWidgets('管理服务器 opens the Servers page', (tester) async {
      final store = _MutableStore(database: db)
        ..addServer(_server(id: 'srv-a', name: 'Navidrome A'));
      final repo = _RecordingMusicRepo();
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPage(
              repo: repo,
              player: player,
              store: store,
              settings: SettingsService(),
              appState: await appState(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理服务器'));
      await tester.pumpAndSettle();
      expect(find.text('服务器'), findsOneWidget);
    });

    testWidgets('selection for a deleted server falls back to 全部', (
      tester,
    ) async {
      final state = await appState();
      await state.setMusicServerId('srv-gone');
      final store = _MutableStore(database: db)
        ..addServer(_server(id: 'srv-a', name: 'Navidrome A'));
      final repo = _RecordingMusicRepo();
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPage(
              repo: repo,
              player: player,
              store: store,
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The ghost selection is never queried; the button shows 全部.
      expect(repo.albumCalls, [null]);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('Album all'), findsOneWidget);
    });

    testWidgets('selection persists: reopening restores the server', (
      tester,
    ) async {
      final state = await appState();
      final store = _MutableStore(database: db)
        ..addServer(_server(id: 'srv-a', name: 'Navidrome A'))
        ..addServer(_server(id: 'srv-b', name: 'Navidrome B'));
      final repo = _RecordingMusicRepo();
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPage(
              repo: repo,
              player: player,
              store: store,
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Navidrome B'));
      await tester.pumpAndSettle();
      expect(state.musicServerId, 'srv-b');

      // A fresh page on the same app state restores the selection.
      // (A new key so this is a new State, like reopening the tab —
      // otherwise Flutter would reuse the old page's State.)
      final repo2 = _RecordingMusicRepo();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPage(
              key: const ValueKey('reopened'),
              repo: repo2,
              player: player,
              store: store,
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo2.albumCalls, ['srv-b']);
      expect(find.text('Album srv-b'), findsOneWidget);
    });
  });

  group('VideoPage server selector', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('switching to one Emby server reloads with that id', (
      tester,
    ) async {
      final store = _MutableStore(database: db)
        ..addServer(
          _server(id: 'srv-ea', type: ServerType.emby, name: 'Emby A'),
        )
        ..addServer(
          _server(id: 'srv-eb', type: ServerType.emby, name: 'Emby B'),
        );
      final repo = _RecordingVideoRepo();
      final history = PlaybackStore(db);
      final state = AppStateStore();
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPage(
              repo: repo,
              store: store,
              history: history,
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('全部'), findsOneWidget);
      expect(repo.continueCalls, [null]);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.text('Emby A'), findsOneWidget);
      expect(find.text('Emby B'), findsOneWidget);

      await tester.tap(find.text('Emby B'));
      await tester.pumpAndSettle();
      expect(repo.continueCalls.last, 'srv-eb');
      expect(find.text('Video srv-eb'), findsWidgets);
    });
  });

  group('DownloadsPage server selector', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('switching filters the queue and sets the repo filter', (
      tester,
    ) async {
      final store = _MutableStore(database: db);
      final qb = _server(
        id: 'srv-qb',
        type: ServerType.qbittorrent,
        name: 'qB',
      );
      final tr = _server(
        id: 'srv-tr',
        type: ServerType.transmission,
        name: 'Transmission',
      );
      final repo = _RecordingDownloadRepo(
        downloaders: [qb, tr],
        tasks: const [
          DownloadTask(
            id: 't1',
            name: 'QB Task',
            source: DownloadSource.qbittorrent,
            status: DownloadStatus.downloading,
            serverId: 'srv-qb',
          ),
          DownloadTask(
            id: 't2',
            name: 'TR Task',
            source: DownloadSource.transmission,
            status: DownloadStatus.downloading,
            serverId: 'srv-tr',
          ),
        ],
      );
      final state = AppStateStore();
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              repo: repo,
              store: store,
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Default is 全部: both tasks visible, no filter on the repo.
      // The page shows 全部 three times (server selector + source and
      // status filters), so scope the selector's value explicitly.
      final selectorAll = find.descendant(
        of: find.byType(ServerSelector),
        matching: find.text('全部'),
      );
      expect(selectorAll, findsOneWidget);
      expect(repo.serverFilter, isNull);
      expect(find.text('QB Task'), findsOneWidget);
      expect(find.text('TR Task'), findsOneWidget);

      await tester.tap(selectorAll);
      await tester.pumpAndSettle();
      // Downloaders show their type next to the name.
      expect(find.text('qB · qBittorrent'), findsOneWidget);
      expect(find.text('Transmission · Transmission'), findsOneWidget);

      await tester.tap(find.text('Transmission · Transmission'));
      await tester.pumpAndSettle();
      expect(repo.serverFilter, 'srv-tr');
      expect(repo.refreshCalls.last, 'srv-tr');
      expect(find.text('TR Task'), findsOneWidget);
      expect(find.text('QB Task'), findsNothing);

      // Disposing the page clears the shared repo filter again, so
      // Home's merged queue is not filtered by this page's choice —
      // and it refreshes once with the cleared filter to restore it.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(repo.serverFilter, isNull);
      expect(repo.refreshCalls.last, isNull);
    });
  });
}
