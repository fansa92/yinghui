// Emby Recently Added is per-library now: for each library from
// UserViews the repo fetches that library's latest items via
// /Users/{uid}/Items/Latest and groups them under the library name.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/app_state.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/fake_repos.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/home/home_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/video/video_page.dart';

Server _server({
  String id = 'srv-emby',
  String username = 'yang',
  String token = 'emby-token',
}) => Server(
  id: id,
  type: ServerType.emby,
  name: 'Test Emby',
  host: 'https://cf.imetyou.top',
  port: 443,
  username: username,
  token: token,
);

Map<String, dynamic> _movieJson({
  String id = 'm1',
  String title = 'The Last Horizon',
  int year = 2024,
}) => {
  'Id': id,
  'Name': title,
  'ProductionYear': year,
  'Type': 'Movie',
  'Overview': 'A crew crosses the last horizon.',
  'RunTimeTicks': 76200000000,
  'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
};

Map<String, dynamic> _seriesJson({
  String id = 's1',
  String title = 'Night Shift',
  int year = 2023,
}) => {
  'Id': id,
  'Name': title,
  'ProductionYear': year,
  'Type': 'Series',
  'Overview': 'A hospital drama.',
  'RunTimeTicks': 27000000000,
  'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
};

Dio _mockEmbyDio(
  Map<String, dynamic> Function(RequestOptions options) respond, {
  List<String>? seenPaths,
}) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
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

/// The mock server: three libraries — movies, tv shows, music — with
/// latest items only for the first two. The movies library returns a
/// same-title+year duplicate to exercise the within-category dedup.
Dio _categoryDio({List<String>? seenPaths, String? failLatestFor}) {
  return _mockEmbyDio((options) {
    final path = options.path.startsWith('/')
        ? options.path
        : '/${options.path}';
    if (path.contains('Users/Me')) return {'Id': 'user-1'};
    if (path.contains('/Views')) {
      return {
        'Items': [
          {'Id': 'lib-movies', 'Name': '电影', 'CollectionType': 'movies'},
          {'Id': 'lib-tv', 'Name': '电视剧', 'CollectionType': 'tvshows'},
          {'Id': 'lib-music', 'Name': '音乐', 'CollectionType': 'music'},
        ],
      };
    }
    if (path.contains('Items/Latest')) {
      final parentId = options.queryParameters['ParentId'] as String?;
      if (parentId == failLatestFor) {
        throw DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 500),
        );
      }
      if (parentId == 'lib-movies') {
        return {
          'Items': [
            _movieJson(),
            _movieJson(id: 'm1-dup'),
            _movieJson(id: 'm2', title: 'Paper Moon', year: 2022),
          ],
        };
      }
      if (parentId == 'lib-tv') {
        return {
          'Items': [_seriesJson()],
        };
      }
      return {'Items': []};
    }
    return {};
  }, seenPaths: seenPaths);
}

void main() {
  group('recentlyAddedByCategory (mocked Dio)', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    RealVideoRepository makeRepo({List<String>? seenPaths}) =>
        RealVideoRepository(
          store: store,
          database: db,
          clientFactory: (s) =>
              EmbyClient(s, dio: _categoryDio(seenPaths: seenPaths)),
        );

    test('one section per media library, music library skipped', () async {
      await store.add(_server());
      final repo = makeRepo();
      final categories = await repo.recentlyAddedByCategory();
      expect(categories.map((c) => c.name), ['电影', '电视剧']);
      expect(categories.first.items.map((v) => v.title), [
        'The Last Horizon',
        'Paper Moon',
      ]);
      expect(categories.last.items.map((v) => v.title), ['Night Shift']);
    });

    test('same title+year deduped within a category', () async {
      await store.add(_server());
      final repo = makeRepo();
      final categories = await repo.recentlyAddedByCategory();
      final movies = categories.first.items;
      expect(movies.length, 2);
      expect(movies.map((v) => v.id), ['m1', 'm2']);
    });

    test('a library whose Latest fails is skipped, not fatal', () async {
      await store.add(_server());
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) =>
            EmbyClient(s, dio: _categoryDio(failLatestFor: 'lib-tv')),
      );
      final categories = await repo.recentlyAddedByCategory();
      expect(categories.map((c) => c.name), ['电影']);
    });

    test('the old single getItems(DateCreated) query is gone', () async {
      await store.add(_server());
      final seenPaths = <String>[];
      final repo = makeRepo(seenPaths: seenPaths);
      await repo.recentlyAddedByCategory();
      expect(seenPaths.where((p) => p.contains('Items/Latest')).length, 2);
      // No bare GET /Items at all: Views + Latest are the only reads.
      expect(seenPaths.any((p) => p == 'GET /Items'), isFalse);
    });

    test('recentlyAdded is the flattened, deduped view', () async {
      await store.add(_server());
      final repo = makeRepo();
      final items = await repo.recentlyAdded();
      expect(items.map((v) => v.title), [
        'The Last Horizon',
        'Paper Moon',
        'Night Shift',
      ]);
    });

    test('server filter restricts to that server only', () async {
      await store.add(_server(id: 'srv-a'));
      await store.add(_server(id: 'srv-b'));
      final repo = makeRepo();
      final onlyB = await repo.recentlyAddedByCategory(serverId: 'srv-b');
      expect(onlyB.map((c) => c.name), ['电影', '电视剧']);
      final ghost = await repo.recentlyAddedByCategory(serverId: 'srv-nope');
      expect(ghost, isEmpty);
    });

    test('no credentials -> one fake 最近添加 category', () async {
      final repo = makeRepo();
      expect(repo.hasCredentials, isFalse);
      final categories = await repo.recentlyAddedByCategory();
      expect(categories.length, 1);
      expect(categories.first.name, '最近添加');
      expect(categories.first.items, FakeVideoRepo.recentlyAdded);
    });
  });

  group('per-category sections render', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('VideoPage shows library names as section headings', (
      tester,
    ) async {
      // Tall viewport: the page is a lazily-built ListView, and the
      // second category's heading must be in view to be built at all.
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = ServerStore(database: db);
      final repo = _CategoryVideoRepo();
      final state = AppStateStore();
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPage(
              repo: repo,
              store: store,
              history: PlaybackStore(db),
              settings: SettingsService(),
              appState: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('最近添加'), findsOneWidget);
      // '电影' is the category chip, the category heading, and the
      // 电影/剧集 filter chip; '电视剧' is the category chip + heading.
      expect(find.text('电影').evaluate().length, 3);
      expect(find.text('电视剧').evaluate().length, 2);
      expect(find.text('The Last Horizon'), findsWidgets);
      expect(find.text('Night Shift'), findsWidgets);
    });

    testWidgets('Home shows the video categories as rows', (tester) async {
      final store = ServerStore(database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      final state = AppStateStore();
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              store: store,
              downloadRepo: _EmptyDownloadRepo(),
              musicRepo: _NoMusicRepo(),
              videoRepo: _CategoryVideoRepo(),
              history: PlaybackStore(db),
              player: player,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('最近添加'), findsOneWidget);
      expect(find.text('电影'), findsOneWidget);
      expect(find.text('电视剧'), findsOneWidget);
      expect(find.text('The Last Horizon'), findsWidgets);
      expect(find.text('Night Shift'), findsWidgets);
    });
  });
}

/// Video repo that serves two named categories; everything else empty.
class _CategoryVideoRepo implements VideoRepository {
  @override
  bool get hasCredentials => true;

  @override
  Future<List<RecentCategory>> recentlyAddedByCategory({
    String? serverId,
  }) async => [
    const RecentCategory(
      name: '电影',
      items: [
        VideoItem(
          id: 'm1',
          title: 'The Last Horizon',
          type: 'Movie',
          year: 2024,
          serverId: 'srv-1',
        ),
        VideoItem(
          id: 'm2',
          title: 'Paper Moon',
          type: 'Movie',
          year: 2022,
          serverId: 'srv-1',
        ),
      ],
    ),
    const RecentCategory(
      name: '电视剧',
      items: [
        VideoItem(
          id: 's1',
          title: 'Night Shift',
          type: 'Series',
          year: 2023,
          serverId: 'srv-1',
        ),
      ],
    ),
  ];

  @override
  Future<List<VideoItem>> continueWatching({String? serverId}) async =>
      const [];

  @override
  Future<List<VideoItem>> recentlyAdded({String? serverId}) async => const [];

  @override
  Future<List<VideoItem>> movies({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async => const [];

  @override
  Future<List<VideoItem>> series({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoMusicRepo implements MusicRepository {
  @override
  bool get hasCredentials => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyDownloadRepo extends ChangeNotifier implements DownloadRepository {
  @override
  bool isAuthBackedOff(String serverId) => false;

  @override
  Future<void> retryLogin(String serverId) async {}
  @override
  String? serverFilter;

  @override
  bool get hasCredentials => false;

  @override
  List<Server> get usableDownloaders => const [];

  @override
  List<DownloadTask> get tasks => const [];

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  List<DownloadTask> get activeTasks => const [];

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  double get volume => 1.0;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}
