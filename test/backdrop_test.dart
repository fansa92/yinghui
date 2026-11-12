import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/video/backdrop_header.dart';
import 'package:yinghui/features/video/episode_detail_page.dart';
import 'package:yinghui/features/video/poster_image.dart';
import 'package:yinghui/features/video/video_detail_page.dart';

/// Fake video repo: a fixed detail (and optional series detail).
class _BackdropFakeVideoRepo implements VideoRepository {
  _BackdropFakeVideoRepo(this.detail, {this.seriesDetailData});

  final VideoDetail detail;
  final SeriesDetail? seriesDetailData;

  @override
  bool get hasCredentials => true;

  @override
  Future<VideoDetail> itemDetail(String itemId, String serverId) async =>
      detail;

  @override
  Future<SeriesDetail> seriesDetail(String seriesId, String serverId) async =>
      seriesDetailData ?? SeriesDetail(series: detail.item);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BackdropHeader widget', () {
    testWidgets('shows title, meta and Play over a backdrop URL', (
      tester,
    ) async {
      var played = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackdropHeader(
              backdropUrl: 'https://example.invalid/backdrop.jpg',
              title: 'Pilot',
              meta: 'S1E1 · 2024 · 48m · Demo Emby',
              playLabel: 'Play',
              onPlay: () => played = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('S1E1 · 2024 · 48m · Demo Emby'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      // The URL cannot load in tests (mock HTTP client returns 400),
      // which is exactly the error path: no broken-image UI appears.
      expect(find.byIcon(Icons.broken_image), findsNothing);
      expect(find.byIcon(Icons.error), findsNothing);
      await tester.tap(find.text('Play'));
      expect(played, isTrue);
    });

    testWidgets('null backdrop URL renders the same content on solid '
        'background', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BackdropHeader(
              backdropUrl: null,
              title: 'Pilot',
              meta: 'S1E1 · 2024 · 48m · Demo Emby',
              playLabel: '从 10:00 继续播放',
              onPlay: _noop,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('S1E1 · 2024 · 48m · Demo Emby'), findsOneWidget);
      expect(find.text('从 10:00 继续播放'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });

    testWidgets('empty backdrop URL behaves like null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BackdropHeader(
              backdropUrl: '',
              title: 'Pilot',
              meta: 'S1E1 · 2024 · 48m · Demo Emby',
              playLabel: 'Play',
              onPlay: _noop,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });

    testWidgets('genre chips shown when provided, hidden when empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BackdropHeader(
              backdropUrl: null,
              title: 'Dune',
              meta: '2024 · 2h 46m · 电影 · Demo Emby',
              genres: ['Sci-Fi', 'Drama'],
              playLabel: 'Play',
              onPlay: _noop,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sci-Fi'), findsOneWidget);
      expect(find.text('Drama'), findsOneWidget);
    });
  });

  group('EpisodeDetailPage backdrop', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    VideoDetail episodeDetail({String? backdropUrl, String? posterUrl}) =>
        VideoDetail(
          item: VideoItem(
            id: 'e1',
            title: 'Pilot',
            type: 'Episode',
            seasonNumber: 1,
            episodeNumber: 1,
            year: 2024,
            durationSeconds: 2880,
            playbackPositionSeconds: 600,
            overview: 'The crew sets out.',
            sourceLabel: 'Demo Emby',
            posterUrl: posterUrl,
            backdropUrl: backdropUrl,
          ),
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
            repo: _BackdropFakeVideoRepo(detail),
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('backdrop URL uses the backdrop header, poster goes away', (
      tester,
    ) async {
      await pumpEpisode(
        tester,
        episodeDetail(
          backdropUrl: 'https://example.invalid/backdrop.jpg',
          posterUrl: 'https://example.invalid/poster.jpg',
        ),
      );
      expect(find.byType(BackdropHeader), findsOneWidget);
      // The poster thumbnail is gone in backdrop mode, even though
      // the item has a poster URL.
      expect(find.byType(PosterImage), findsNothing);
      // Title + meta + Resume sit over the gradient (the app bar
      // title is hidden in backdrop mode, so the title appears once).
      expect(find.text('Pilot'), findsOneWidget);
      expect(find.text('S1E1 · 2024 · 48m · Demo Emby'), findsOneWidget);
      expect(find.text('从 10:00 继续播放'), findsOneWidget);
      expect(find.text('The crew sets out.'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });

    testWidgets('no backdrop URL keeps the poster-row header exactly', (
      tester,
    ) async {
      await pumpEpisode(
        tester,
        episodeDetail(posterUrl: 'https://example.invalid/poster.jpg'),
      );
      expect(find.byType(BackdropHeader), findsNothing);
      expect(find.byType(PosterImage), findsOneWidget);
      // App bar title + header title both show the episode name.
      expect(find.text('Pilot'), findsNWidgets(2));
      expect(find.text('S1E1 · 2024 · 48m · Demo Emby'), findsOneWidget);
      expect(find.text('从 10:00 继续播放'), findsOneWidget);
    });

    testWidgets('backdrop header spans the centred width on desktop', (
      tester,
    ) async {
      await pumpEpisode(
        tester,
        episodeDetail(backdropUrl: 'https://example.invalid/backdrop.jpg'),
        size: const Size(1280, 800),
      );
      expect(find.byType(BackdropHeader), findsOneWidget);
      // CenteredContent caps page content at 1000 on wide screens.
      expect(tester.getSize(find.byType(BackdropHeader)).width, 1000);
    });
  });

  group('VideoDetailPage backdrop', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    VideoDetail movieDetail({String? backdropUrl, String? posterUrl}) =>
        VideoDetail(
          item: VideoItem(
            id: 'm1',
            title: 'Dune',
            type: 'Movie',
            year: 2024,
            durationSeconds: 9960,
            overview: 'Spice must flow.',
            cast: const ['Actor One'],
            genres: const ['Sci-Fi', 'Drama'],
            sourceLabel: 'Demo Emby',
            posterUrl: posterUrl,
            backdropUrl: backdropUrl,
          ),
        );

    Future<void> pumpDetail(
      WidgetTester tester,
      VideoDetail detail, {
      SeriesDetail? series,
      Size size = const Size(390, 844),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoDetailPage(
            item: detail.item,
            repo: _BackdropFakeVideoRepo(detail, seriesDetailData: series),
            history: PlaybackStore(db),
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('movie with backdrop uses the backdrop header with genres', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        movieDetail(
          backdropUrl: 'https://example.invalid/backdrop.jpg',
          posterUrl: 'https://example.invalid/poster.jpg',
        ),
      );
      expect(find.byType(BackdropHeader), findsOneWidget);
      expect(find.byType(PosterImage), findsNothing);
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('2024 · 2h 46m · 电影 · Demo Emby'), findsOneWidget);
      expect(find.text('Sci-Fi'), findsOneWidget);
      expect(find.text('Drama'), findsOneWidget);
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('Spice must flow.'), findsOneWidget);
      expect(find.text('Actor One'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });

    testWidgets('movie without backdrop keeps the poster-row header', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        movieDetail(posterUrl: 'https://example.invalid/poster.jpg'),
      );
      expect(find.byType(BackdropHeader), findsNothing);
      expect(find.byType(PosterImage), findsOneWidget);
      expect(find.text('Dune'), findsNWidgets(2));
      expect(find.text('Sci-Fi'), findsOneWidget);
    });

    testWidgets('series with backdrop still lists its episodes below', (
      tester,
    ) async {
      const seriesItem = VideoItem(
        id: 's1',
        title: 'Harbour Lights',
        type: 'Series',
        year: 2023,
        durationSeconds: 2880,
        episodeCount: 2,
        overview: 'A harbour drama.',
        genres: ['Drama'],
        sourceLabel: 'Demo Emby',
        backdropUrl: 'https://example.invalid/backdrop.jpg',
      );
      const seriesDetail = SeriesDetail(
        series: seriesItem,
        seasons: [Season(id: 'season1', name: 'Season 1', indexNumber: 1)],
        episodes: [
          VideoItem(
            id: 'e1',
            title: 'Pilot',
            type: 'Episode',
            seasonId: 'season1',
            seasonNumber: 1,
            episodeNumber: 1,
            durationSeconds: 2880,
            overview: 'The crew sets out.',
          ),
          VideoItem(
            id: 'e2',
            title: 'Storm',
            type: 'Episode',
            seasonId: 'season1',
            seasonNumber: 1,
            episodeNumber: 2,
            durationSeconds: 2880,
            overview: 'A storm hits.',
          ),
        ],
      );
      await pumpDetail(
        tester,
        const VideoDetail(item: seriesItem),
        series: seriesDetail,
      );
      expect(find.byType(BackdropHeader), findsOneWidget);
      expect(find.text('Harbour Lights'), findsOneWidget);
      expect(find.text('分集'), findsOneWidget);
      expect(find.text('S1E1 · Pilot'), findsOneWidget);
      expect(find.text('S1E2 · Storm'), findsOneWidget);
    });
  });
}

void _noop() {}
