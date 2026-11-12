// Horizontal category chips, per-category 更多, and series episode
// counts ("更新至 X 集").
//
// - Video page: a horizontal chip row (全部 + one chip per library)
//   filters the 最近添加 section; each category is a horizontal
//   poster row headed by the library name + a 更多 button.
// - 更多 opens CategoryItemsPage: the library's full list via
//   libraryItems (Emby Items by ParentId, paginated, deduped).
// - Series show "更新至 X 集" from Emby ChildCount (series only;
//   absent -> nothing) on cards, in the grid, and on the detail page.
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
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/home/home_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/video/category_items_page.dart';
import 'package:yinghui/features/video/video_detail_page.dart';
import 'package:yinghui/features/video/video_page.dart';

Server _server({String id = 'srv-emby'}) => Server(
  id: id,
  type: ServerType.emby,
  name: 'Test Emby',
  host: 'https://cf.imetyou.top',
  port: 443,
  username: 'yang',
  token: 'emby-token',
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
  int? childCount,
}) => {
  'Id': id,
  'Name': title,
  'ProductionYear': year,
  'Type': 'Series',
  'Overview': 'A hospital drama.',
  'RunTimeTicks': 27000000000,
  'ChildCount': ?childCount,
  'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
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

/// Mock Emby: two libraries, Latest per library, and getItems by
/// ParentId (honouring startIndex/limit) for the 更多 page.
Dio _libraryDio() {
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
        ],
      };
    }
    if (path.contains('Items/Latest')) {
      final parentId = options.queryParameters['ParentId'] as String?;
      if (parentId == 'lib-movies') {
        return {
          'Items': [
            _movieJson(),
            _movieJson(id: 'm2', title: 'Paper Moon', year: 2022),
          ],
        };
      }
      if (parentId == 'lib-tv') {
        return {
          'Items': [_seriesJson(childCount: 8)],
        };
      }
      return {'Items': []};
    }
    if (path.contains('/Items')) {
      // getItems by ParentId, paginated.
      final parentId = options.queryParameters['ParentId'] as String?;
      final start =
          (options.queryParameters['StartIndex'] as num?)?.toInt() ?? 0;
      final limit = (options.queryParameters['Limit'] as num?)?.toInt() ?? 20;
      final all = parentId == 'lib-movies'
          ? [
              _movieJson(),
              _movieJson(id: 'm2', title: 'Paper Moon', year: 2022),
            ]
          : parentId == 'lib-tv'
          ? [
              _seriesJson(childCount: 8),
              // Same title+year as the movie m1: deduped across
              // libraries when both are queried together.
              _movieJson(id: 'm1-copy'),
            ]
          : <Map<String, dynamic>>[];
      final page = all.skip(start).take(limit).toList();
      return {'Items': page};
    }
    return {};
  });
}

/// Video repo serving two named categories with library refs; the
/// 更多 page returns per-library items and records what it was asked
/// for.
class _MoreFakeVideoRepo implements VideoRepository {
  List<LibraryRef>? lastLibraries;

  @override
  bool get hasCredentials => true;

  @override
  Future<List<RecentCategory>> recentlyAddedByCategory({
    String? serverId,
  }) async => const [
    RecentCategory(
      name: '电影',
      libraries: [LibraryRef(serverId: 'srv-1', libraryId: 'lib-movies')],
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
    RecentCategory(
      name: '电视剧',
      libraries: [LibraryRef(serverId: 'srv-1', libraryId: 'lib-tv')],
      items: [
        VideoItem(
          id: 's1',
          title: 'Night Shift',
          type: 'Series',
          year: 2023,
          episodeCount: 8,
          serverId: 'srv-1',
        ),
      ],
    ),
  ];

  @override
  Future<List<VideoItem>> libraryItems({
    required List<LibraryRef> libraries,
    int limit = 20,
    int offset = 0,
  }) async {
    lastLibraries = libraries;
    final id = libraries.first.libraryId;
    final all = id == 'lib-tv'
        ? const [
            VideoItem(
              id: 's1',
              title: 'Night Shift',
              type: 'Series',
              year: 2023,
              episodeCount: 8,
              serverId: 'srv-1',
            ),
            VideoItem(
              id: 's2',
              title: 'Harbour Lights',
              type: 'Series',
              year: 2024,
              episodeCount: 12,
              serverId: 'srv-1',
            ),
          ]
        : const [
            VideoItem(
              id: 'm1',
              title: 'The Last Horizon',
              type: 'Movie',
              year: 2024,
              serverId: 'srv-1',
            ),
          ];
    return all.skip(offset).take(limit).toList();
  }

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

/// Fake detail repo: the detail page shows the item it was given.
class _DetailFakeVideoRepo implements VideoRepository {
  _DetailFakeVideoRepo(this.detail);

  final VideoDetail detail;

  @override
  bool get hasCredentials => true;

  @override
  Future<VideoDetail> itemDetail(String itemId, String serverId) async =>
      detail;

  @override
  Future<SeriesDetail> seriesDetail(String seriesId, String serverId) async =>
      SeriesDetail(series: detail.item);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('episodeCount mapping', () {
    test('episodeCountText: series only, absent -> nothing', () {
      const series = VideoItem(
        id: 's1',
        title: 'Night Shift',
        type: 'Series',
        episodeCount: 8,
      );
      expect(series.episodeCountText, '更新至 8 集');
      const seriesNoCount = VideoItem(
        id: 's2',
        title: 'No Count',
        type: 'Series',
      );
      expect(seriesNoCount.episodeCount, isNull);
      expect(seriesNoCount.episodeCountText, isNull);
      const seriesZero = VideoItem(
        id: 's3',
        title: 'Zero',
        type: 'Series',
        episodeCount: 0,
      );
      expect(seriesZero.episodeCountText, isNull);
      const movie = VideoItem(
        id: 'm1',
        title: 'Film',
        type: 'Movie',
        episodeCount: 8,
      );
      expect(movie.episodeCountText, isNull);
      const episode = VideoItem(
        id: 'e1',
        title: 'Pilot',
        type: 'Episode',
        episodeCount: 8,
      );
      expect(episode.episodeCountText, isNull);
    });

    test('Emby ChildCount maps to series only', () async {
      final client = EmbyClient(
        _server(),
        dio: _mockEmbyDio((options) {
          final path = options.path.startsWith('/')
              ? options.path
              : '/${options.path}';
          if (path.contains('Users/Me')) return {'Id': 'user-1'};
          return {
            'Items': [
              _seriesJson(childCount: 12),
              _seriesJson(id: 's2', title: 'No Count'),
              // A movie carrying ChildCount must not show a count.
              {..._movieJson(), 'ChildCount': 5},
            ],
          };
        }),
      );
      final items = await client.getItems(userId: 'user-1');
      expect(items[0].episodeCount, 12);
      expect(items[0].episodeCountText, '更新至 12 集');
      expect(items[1].episodeCount, isNull);
      expect(items[1].episodeCountText, isNull);
      expect(items[2].episodeCount, isNull);
    });
  });

  group('libraryItems (mocked Dio)', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    RealVideoRepository makeRepo() => RealVideoRepository(
      store: store,
      database: db,
      clientFactory: (s) => EmbyClient(s, dio: _libraryDio()),
    );

    test('recentlyAddedByCategory carries the library refs', () async {
      await store.add(_server());
      final categories = await makeRepo().recentlyAddedByCategory();
      expect(categories.map((c) => c.name), ['电影', '电视剧']);
      expect(categories.first.libraries.map((r) => r.libraryId), [
        'lib-movies',
      ]);
      expect(categories.first.libraries.map((r) => r.serverId), ['srv-emby']);
      expect(categories.last.libraries.map((r) => r.libraryId), ['lib-tv']);
    });

    test('libraryItems merges, dedups by title+year, paginates', () async {
      await store.add(_server());
      final repo = makeRepo();
      final page1 = await repo.libraryItems(
        libraries: const [
          LibraryRef(serverId: 'srv-emby', libraryId: 'lib-movies'),
          LibraryRef(serverId: 'srv-emby', libraryId: 'lib-tv'),
        ],
        limit: 2,
      );
      // m1, m2, s1 — the lib-tv copy of m1's title+year is deduped.
      expect(page1.map((v) => v.title), ['The Last Horizon', 'Paper Moon']);
      final page2 = await repo.libraryItems(
        libraries: const [
          LibraryRef(serverId: 'srv-emby', libraryId: 'lib-movies'),
          LibraryRef(serverId: 'srv-emby', libraryId: 'lib-tv'),
        ],
        limit: 2,
        offset: 2,
      );
      expect(page2.map((v) => v.title), ['Night Shift']);
      // Unknown library id: skipped, not fatal.
      final ghost = await repo.libraryItems(
        libraries: const [
          LibraryRef(serverId: 'srv-emby', libraryId: 'lib-nope'),
        ],
      );
      expect(ghost, isEmpty);
    });
  });

  group('category chips + 更多 (widget)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> pumpVideoPage(
      WidgetTester tester,
      _MoreFakeVideoRepo repo,
    ) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = ServerStore(database: db);
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
    }

    Finder categoryChip(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip));

    testWidgets('chips filter the categories; series shows 更新至 8 集', (
      tester,
    ) async {
      final repo = _MoreFakeVideoRepo();
      await pumpVideoPage(tester, repo);

      // '全部' is both the server selector's value and the category
      // chip; the chip is the ChoiceChip ancestor.
      expect(categoryChip('全部'), findsOneWidget);
      // '电影' is the category chip, the category heading, and the
      // 电影/剧集 filter chip; '电视剧' is the chip + the heading.
      expect(find.text('电影').evaluate().length, 3);
      expect(find.text('电视剧').evaluate().length, 2);
      expect(find.textContaining('更新至 8 集'), findsOneWidget);
      expect(find.text('更多 ›'), findsNWidgets(2));

      // Tap the 电视剧 chip: only that category stays.
      await tester.tap(categoryChip('电视剧'));
      await tester.pumpAndSettle();
      expect(find.text('Night Shift'), findsWidgets);
      expect(find.text('Paper Moon'), findsNothing);
      expect(find.textContaining('更新至 8 集'), findsOneWidget);

      // Back to 全部: both categories return.
      await tester.tap(categoryChip('全部'));
      await tester.pumpAndSettle();
      expect(find.text('Paper Moon'), findsWidgets);
      expect(find.text('Night Shift'), findsWidgets);
    });

    testWidgets('更多 opens the library list page with the right library', (
      tester,
    ) async {
      final repo = _MoreFakeVideoRepo();
      await pumpVideoPage(tester, repo);

      // The last 更多 button belongs to the 电视剧 category.
      await tester.tap(find.text('更多 ›').last);
      await tester.pumpAndSettle();

      expect(find.byType(CategoryItemsPage), findsOneWidget);
      expect(repo.lastLibraries, [
        const LibraryRef(serverId: 'srv-1', libraryId: 'lib-tv'),
      ]);
      expect(find.text('Harbour Lights'), findsOneWidget);
      expect(find.textContaining('更新至 12 集'), findsOneWidget);
    });

    testWidgets('Home shows 更多 per category and the episode count', (
      tester,
    ) async {
      final store = ServerStore(database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              store: store,
              downloadRepo: _EmptyDownloadRepo(),
              musicRepo: _NoMusicRepo(),
              videoRepo: _MoreFakeVideoRepo(),
              history: PlaybackStore(db),
              player: player,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('更多 ›'), findsNWidgets(2));
      expect(find.textContaining('更新至 8 集'), findsOneWidget);
      // The movie card shows no count.
      expect(find.textContaining('更新至'), findsOneWidget);
    });

    testWidgets('detail page meta shows 更新至 8 集 for a series', (tester) async {
      const seriesItem = VideoItem(
        id: 's1',
        title: 'Night Shift',
        type: 'Series',
        year: 2023,
        durationSeconds: 2700,
        episodeCount: 8,
        overview: 'A hospital drama.',
        sourceLabel: 'Demo Emby',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            item: seriesItem,
            repo: _DetailFakeVideoRepo(const VideoDetail(item: seriesItem)),
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('更新至 8 集'), findsOneWidget);
    });

    testWidgets('detail page meta shows no count for a movie', (tester) async {
      const movieItem = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        type: 'Movie',
        year: 2024,
        durationSeconds: 7620,
        overview: 'A crew crosses the last horizon.',
        sourceLabel: 'Demo Emby',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            item: movieItem,
            repo: _DetailFakeVideoRepo(const VideoDetail(item: movieItem)),
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('更新至'), findsNothing);
    });
  });
}
