import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/features/music/music_page.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/data/repositories/server_store.dart';

/// Tempus-style music browsing + now-playing layout (layout pattern
/// only): the Music page's "浏览" view stacks 专辑/艺人/歌单/收藏
/// sections with "查看全部", and the default now-playing style puts
/// a full-width cover on top, title/artist left-aligned under it,
/// and elapsed/duration flanking the slider.
void main() {
  group('MusicPage browse view (Tempus-style sections)', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> pumpPage(WidgetTester tester, _FakeMusicRepo repo) async {
      // Tall surface: the browse view is a lazy ListView/GridView,
      // so preview items below the fold are only built when they
      // fit in the viewport.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('浏览 is the default view: all four sections render', (
      tester,
    ) async {
      final repo = _FakeMusicRepo()
        ..albumsData = [
          const Album(id: 'a1', title: 'Album One', artist: 'Singer'),
          const Album(id: 'a2', title: 'Album Two', artist: 'Singer'),
        ]
        ..artistsData = [const Artist(id: 'ar1', name: 'Singer')]
        ..playlistsData = [
          const Playlist(id: 'p1', name: 'My Mix', songCount: 12),
        ]
        ..starredSongsData = [
          const Track(id: 't1', title: 'Fav Song', artist: 'Singer'),
        ]
        ..starredAlbumsData = [
          const Album(id: 'a3', title: 'Fav Album', artist: 'Singer'),
        ];
      await pumpPage(tester, repo);

      // The 浏览 chip is selected; each section has a header and a
      // 查看全部 button.
      expect(find.text('浏览'), findsOneWidget);
      expect(find.text('专辑'), findsNWidgets(2)); // chip + header
      expect(find.text('艺人'), findsNWidgets(2)); // chip + header
      expect(find.text('歌单'), findsNWidgets(2)); // chip + header
      expect(find.text('收藏'), findsNWidgets(2)); // chip + header
      expect(find.text('查看全部 ›'), findsNWidgets(4));
      expect(find.text('Album One'), findsOneWidget);
      // 'Singer' exactly once: the artist card name (album cards
      // show 'Singer · ' as a subtitle, not the bare name).
      expect(find.text('Singer'), findsOneWidget);
      expect(find.text('My Mix'), findsOneWidget);
      expect(find.text('Fav Song'), findsOneWidget);
      expect(find.text('Fav Album'), findsOneWidget);
    });

    testWidgets('empty sections are hidden; only non-empty ones show', (
      tester,
    ) async {
      final repo = _FakeMusicRepo()
        ..albumsData = [
          const Album(id: 'a1', title: 'Album One', artist: 'Singer'),
        ];
      await pumpPage(tester, repo);

      expect(find.text('查看全部 ›'), findsOneWidget);
      expect(find.text('Album One'), findsOneWidget);
      // The other sections have no header (their chip is still there).
      expect(find.text('艺人'), findsOneWidget);
      expect(find.text('歌单'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
    });

    testWidgets('查看全部 switches to that kind\'s full list', (tester) async {
      final repo = _FakeMusicRepo()
        ..albumsData = [
          const Album(id: 'a1', title: 'Album One', artist: 'Singer'),
        ]
        ..artistsData = [const Artist(id: 'ar1', name: 'Singer')];
      await pumpPage(tester, repo);

      await tester.tap(find.text('查看全部 ›').first);
      await tester.pumpAndSettle();

      // Now on the 专辑 full list: no section headers remain.
      expect(find.text('查看全部 ›'), findsNothing);
      expect(find.text('Album One'), findsOneWidget);
      expect(find.text('艺人'), findsOneWidget); // chip only
    });

    testWidgets('browse preview caps albums at 8; full list shows all', (
      tester,
    ) async {
      final repo = _FakeMusicRepo()
        ..albumsData = List.generate(
          10,
          (i) => Album(id: 'a$i', title: 'Album $i', artist: 'Singer'),
        );
      await pumpPage(tester, repo);

      expect(find.text('Album 7'), findsOneWidget);
      expect(find.text('Album 8'), findsNothing);

      await tester.tap(find.text('查看全部 ›').first);
      await tester.pumpAndSettle();
      expect(find.text('Album 8'), findsOneWidget);
      expect(find.text('Album 9'), findsOneWidget);
    });

    testWidgets('tapping the 专辑 chip leaves the browse view', (tester) async {
      final repo = _FakeMusicRepo()
        ..albumsData = [
          const Album(id: 'a1', title: 'Album One', artist: 'Singer'),
        ]
        ..artistsData = [const Artist(id: 'ar1', name: 'Singer')];
      await pumpPage(tester, repo);

      await tester.tap(find.text('专辑').first);
      await tester.pumpAndSettle();
      expect(find.text('查看全部 ›'), findsNothing);
      expect(find.text('Album One'), findsOneWidget);
    });
  });

  group('NowPlayingPage default style (Tempus-style layout)', () {
    const track = Track(
      id: 't1',
      title: 'Test Song',
      artist: 'Singer',
      album: 'Album',
      durationSeconds: 200,
      serverId: 'srv',
      sourceLabel: 'Navidrome',
    );

    void setTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<SettingsService> settingsWith(MusicPlayerStyle style) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.setMusicPlayerStyle(style);
      return settings;
    }

    Future<PlayerService> playingPlayer() async {
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: _FakeBackend.new,
      );
      await player.playQueue([track]);
      return player;
    }

    testWidgets('default: title/artist shown, one slider, heart + queue', (
      tester,
    ) async {
      setTallSurface(tester);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      final repo = _FakeMusicRepo();
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(
            player: player,
            settings: settings,
            musicRepo: repo,
          ),
        ),
      );
      await tester.pump();

      // Title once in the header (the second 'Test Song' is the Up
      // next row); artist/album line under it, also twice.
      expect(find.text('Test Song'), findsNWidgets(2));
      expect(find.text('Singer · Album'), findsNWidgets(2));
      // One seek slider (no volume slider in the default style).
      expect(find.byType(Slider), findsOneWidget);
      // Tempus-style action row: heart + 播放队列.
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('播放队列'), findsOneWidget);
      // Times flank the slider: elapsed left, total right.
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('3:20'), findsNWidgets(2)); // total + queue row
    });

    testWidgets('default: tapping the heart favourites the track', (
      tester,
    ) async {
      setTallSurface(tester);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      final repo = _FakeMusicRepo();
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(
            player: player,
            settings: settings,
            musicRepo: repo,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pumpAndSettle();
      expect(repo.starredTrackIds, contains('t1'));
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });

    testWidgets('spotify style still has its own heart + queue row', (
      tester,
    ) async {
      setTallSurface(tester);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.spotify);
      final repo = _FakeMusicRepo();
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(
            player: player,
            settings: settings,
            musicRepo: repo,
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('播放队列'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
    });
  });
}

/// Fake music repository with configurable browse content.
class _FakeMusicRepo implements MusicRepository {
  List<Album> albumsData = [];
  List<Artist> artistsData = [];
  List<Playlist> playlistsData = [];
  List<Track> starredSongsData = [];
  List<Album> starredAlbumsData = [];
  final starredTrackIds = <String>{};

  @override
  bool get hasCredentials => true;

  @override
  Future<List<Album>> albums({
    String type = 'newest',
    int size = 20,
    int offset = 0,
    String? serverId,
  }) async => albumsData.skip(offset).take(size).toList();

  @override
  Future<List<Artist>> artists({String? serverId}) async => artistsData;

  @override
  Future<List<Playlist>> playlists({String? serverId}) async => playlistsData;

  @override
  Future<({List<Track> songs, List<Album> albums})> starred({
    String? serverId,
  }) async => (songs: starredSongsData, albums: starredAlbumsData);

  @override
  Future<({List<Track> songs, List<Album> albums, List<Artist> artists})>
  search(String query, {String? serverId}) async =>
      (songs: <Track>[], albums: <Album>[], artists: <Artist>[]);

  @override
  Future<({Album album, List<Track> tracks})> album(
    String albumId,
    String serverId,
  ) async => (album: albumsData.first, tracks: <Track>[]);

  @override
  Future<List<Track>> playlistTracks(
    String playlistId,
    String serverId,
  ) async => <Track>[];

  @override
  String streamUrlFor(Track track, {int maxBitRate = 0}) =>
      'https://example.com/stream';

  @override
  Future<bool> toggleStarTrack(Track track) async {
    if (starredTrackIds.contains(track.id)) {
      starredTrackIds.remove(track.id);
      return false;
    }
    starredTrackIds.add(track.id);
    return true;
  }

  @override
  Future<bool> toggleStarAlbum(Album album) async => false;

  @override
  Future<bool> isStarredTrack(Track track) async =>
      starredTrackIds.contains(track.id);

  @override
  Future<bool> isStarredAlbum(Album album) async => false;
}

/// Fake audio backend: no native code, streams driven by the test.
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
  Future<void> open(String url) async {
    _duration.add(const Duration(seconds: 200));
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> seek(Duration position) async => _position.add(position);

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}
