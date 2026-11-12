import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/theme.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';
import 'package:yinghui/features/settings/settings_page.dart';

void main() {
  group('Player style settings persistence', () {
    test('round-trip + invalid values fall back to default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();

      expect(settings.musicPlayerStyle, MusicPlayerStyle.standard);
      expect(settings.videoPlayerStyle, VideoPlayerStyle.standard);

      await settings.setMusicPlayerStyle(MusicPlayerStyle.appleMusic);
      await settings.setVideoPlayerStyle(VideoPlayerStyle.netflix);

      final reloaded = SettingsService(prefs: prefs);
      await reloaded.load();
      expect(reloaded.musicPlayerStyle, MusicPlayerStyle.appleMusic);
      expect(reloaded.videoPlayerStyle, VideoPlayerStyle.netflix);

      await settings.setMusicPlayerStyle(MusicPlayerStyle.spotify);
      await settings.setVideoPlayerStyle(VideoPlayerStyle.appleTv);
      final reloaded2 = SettingsService(prefs: prefs);
      await reloaded2.load();
      expect(reloaded2.musicPlayerStyle, MusicPlayerStyle.spotify);
      expect(reloaded2.videoPlayerStyle, VideoPlayerStyle.appleTv);
    });

    test('unknown stored strings fall back to default', () async {
      SharedPreferences.setMockInitialValues({
        'yinghui_music_player_style': 'winamp',
        'yinghui_video_player_style': 'quicktime',
      });
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      expect(settings.musicPlayerStyle, MusicPlayerStyle.standard);
      expect(settings.videoPlayerStyle, VideoPlayerStyle.standard);
    });
  });

  group('PlayerService volume', () {
    test('setVolume clamps and reaches the backend', () async {
      final backend = _StyleFakeBackend();
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: () => backend,
      );
      addTearDown(player.dispose);
      expect(player.volume, 1.0);
      await player.setVolume(0.5);
      expect(player.volume, 0.5);
      expect(backend.lastVolume, 0.5);
      await player.setVolume(2.0);
      expect(player.volume, 1.0);
      await player.setVolume(-1.0);
      expect(player.volume, 0.0);
    });
  });

  group('SettingsPage player style section', () {
    testWidgets('shows both style groups with hints', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            settings: settings,
            store: ServerStore(database: db),
            history: PlaybackStore(db),
            downloadRepo: RealDownloadRepository(
              store: ServerStore(database: db),
              database: db,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('播放器风格'), findsOneWidget);
      expect(find.text('音乐播放器'), findsOneWidget);
      expect(find.text('视频播放器'), findsOneWidget);
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Apple TV'), findsOneWidget);
      expect(find.text('封面取色背景 + 白色播放键 + 音量条'), findsOneWidget);
      expect(find.text('±10 秒快进快退 + 播完 Up Next'), findsOneWidget);
    });
  });

  group('NowPlayingPage styles', () {
    const track = Track(
      id: 't1',
      title: 'Test Song',
      artist: 'Singer',
      album: 'Album',
      durationSeconds: 200,
      serverId: 'srv',
      sourceLabel: 'Navidrome',
    );

    Future<(PlayerService, _StyleFakeBackend)> playingPlayer() async {
      final backend = _StyleFakeBackend();
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: () => backend,
      );
      await player.playQueue([track]);
      return (player, backend);
    }

    /// Tall surface: the page is a lazy ListView, so rows below the
    /// controls (volume slider, heart, Queue) are only built when
    /// they fit in the viewport.
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

    testWidgets('default: green play button and one seek slider', (
      tester,
    ) async {
      setTallSurface(tester);
      final (player, _) = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: player, settings: settings),
        ),
      );
      await tester.pump();

      // The track shows twice on a tall surface: the header and its
      // own row in the Up next list.
      expect(find.text('Test Song'), findsNWidgets(2));
      expect(find.text('3:20'), findsNWidgets(2));
      final playIcon = tester.widget<Icon>(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == YingHuiTheme.primaryGreen,
        ),
      );
      expect(playIcon.color, YingHuiTheme.primaryGreen);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('appleMusic: white button, remaining time, volume slider', (
      tester,
    ) async {
      setTallSurface(tester);
      final (player, backend) = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.appleMusic);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: player, settings: settings),
        ),
      );
      await tester.pump();

      // Remaining time on the right end, not the total. The one
      // '3:20' left is the queue row's duration.
      expect(find.text('-3:20'), findsOneWidget);
      expect(find.text('3:20'), findsNWidgets(1));
      // White play button + a second (volume) slider.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == Colors.white,
        ),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsNWidgets(2));

      // Dragging the volume slider reaches the backend.
      await tester.drag(find.byType(Slider).at(1), const Offset(50, 0));
      await tester.pump();
      expect(backend.lastVolume, isNotNull);
    });

    testWidgets('appleMusic: cover adds a blurred background image', (
      tester,
    ) async {
      setTallSurface(tester);
      final backend = _StyleFakeBackend();
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: () => backend,
      );
      addTearDown(player.dispose);
      const withCover = Track(
        id: 't1',
        title: 'Test Song',
        artist: 'Singer',
        album: 'Album',
        durationSeconds: 200,
        coverUrl: 'https://example.com/cover.jpg',
        serverId: 'srv',
      );
      await player.playQueue([withCover]);
      final settings = await settingsWith(MusicPlayerStyle.appleMusic);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: player, settings: settings),
        ),
      );
      await tester.pump();

      // One CachedNetworkImage for the blurred background, one for
      // the cover itself, one for the queue row's cover.
      expect(find.byType(CachedNetworkImage), findsNWidgets(3));
    });

    testWidgets('spotify: black background, white button, heart + queue', (
      tester,
    ) async {
      setTallSurface(tester);
      final (player, _) = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.spotify);
      final repo = _StyleFakeMusicRepo();
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
      await tester.pump();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.black);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == Colors.white,
        ),
        findsOneWidget,
      );
      // Heart starts unstarred; tapping it stars the track.
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('Queue'), findsOneWidget);
      await tester.tap(find.byTooltip('Like'));
      await tester.pump();
      expect(repo.starredState, isTrue);
      expect(find.byIcon(Icons.favorite), findsOneWidget);

      // Queue button scrolls to the Up next list without crashing.
      await tester.tap(find.text('Queue'));
      await tester.pump();
      expect(find.text('Up next'), findsOneWidget);
    });

    testWidgets('changing the style in Settings restyles the page live', (
      tester,
    ) async {
      setTallSurface(tester);
      final (player, _) = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: player, settings: settings),
        ),
      );
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == YingHuiTheme.primaryGreen,
        ),
        findsOneWidget,
      );

      await settings.setMusicPlayerStyle(MusicPlayerStyle.spotify);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == Colors.white,
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.black,
      );
    });
  });

  group('VideoPlayerPage styles', () {
    const item = VideoItem(
      id: 'e1',
      title: 'Episode 1',
      durationSeconds: 7620,
      serverId: 'srv-emby',
    );
    const next = VideoItem(
      id: 'e2',
      title: 'Episode 2',
      durationSeconds: 7620,
      serverId: 'srv-emby',
    );

    Future<SettingsService> settingsWith(VideoPlayerStyle style) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.setVideoPlayerStyle(style);
      return settings;
    }

    Future<void> pumpPlayer(
      WidgetTester tester, {
      required VideoPlayerStyle style,
      VideoItem? nextEpisode,
      void Function(VideoItem episode)? onPlayNext,
      required _StyleFakeVideoBackend backend,
    }) async {
      final settings = await settingsWith(style);
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final service = VideoPlayerService(
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            repo: _StyleFakeVideoRepo(),
            history: PlaybackStore(db),
            service: service,
            settings: settings,
            nextEpisode: nextEpisode,
            onPlayNextEpisode: onPlayNext,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('default: green progress, no next or ±10s buttons', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.standard,
        nextEpisode: next,
        backend: backend,
      );

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.activeColor, YingHuiTheme.primaryGreen);
      expect(find.byTooltip('Next Episode'), findsNothing);
      expect(find.byTooltip('Back 10 seconds'), findsNothing);
      expect(find.byTooltip('Forward 10 seconds'), findsNothing);
    });

    testWidgets('netflix: red progress and a working Next Episode button', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      VideoItem? played;
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.netflix,
        nextEpisode: next,
        onPlayNext: (e) => played = e,
        backend: backend,
      );

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.activeColor, const Color(0xFFE50914));
      expect(find.byTooltip('Next Episode'), findsOneWidget);
      await tester.tap(find.byTooltip('Next Episode'));
      await tester.pump();
      expect(played?.id, 'e2');
    });

    testWidgets('netflix: no Next Episode button without a next episode', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.netflix,
        backend: backend,
      );
      expect(find.byTooltip('Next Episode'), findsNothing);
    });

    testWidgets('appleTv: ±10s buttons seek the service', (tester) async {
      final backend = _StyleFakeVideoBackend();
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.appleTv,
        nextEpisode: next,
        backend: backend,
      );

      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 10));
      await tester.tap(find.byTooltip('Forward 10 seconds'));
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 20));
      await tester.tap(find.byTooltip('Back 10 seconds'));
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 10));
    });

    testWidgets('appleTv: Up Next card counts down and can play/dismiss', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      VideoItem? played;
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.appleTv,
        nextEpisode: next,
        onPlayNext: (e) => played = e,
        backend: backend,
      );

      backend.emitCompleted();
      await tester.pump();
      // The broadcast completion event is delivered on the next pump.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Up Next'), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);
      expect(find.text('Playing in 10 s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Playing in 9 s'), findsOneWidget);

      // Dismiss cancels the autoplay.
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(find.text('Up Next'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(played, isNull);
    });

    testWidgets('appleTv: Up Next Play now plays the next episode', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      VideoItem? played;
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.appleTv,
        nextEpisode: next,
        onPlayNext: (e) => played = e,
        backend: backend,
      );

      backend.emitCompleted();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Play now'));
      await tester.pump();
      expect(played?.id, 'e2');
    });

    testWidgets('appleTv: Up Next autoplays when the countdown reaches zero', (
      tester,
    ) async {
      final backend = _StyleFakeVideoBackend();
      VideoItem? played;
      await pumpPlayer(
        tester,
        style: VideoPlayerStyle.appleTv,
        nextEpisode: next,
        onPlayNext: (e) => played = e,
        backend: backend,
      );

      backend.emitCompleted();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Playing in 10 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(played?.id, 'e2');
    });
  });
}

/// Fake audio backend with volume, for the style tests.
class _StyleFakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

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
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

/// Fake music repo: only starring is real; the rest is never called.
class _StyleFakeMusicRepo implements MusicRepository {
  bool starredState = false;

  @override
  Future<bool> isStarredTrack(Track track) async => starredState;

  @override
  Future<bool> toggleStarTrack(Track track) async {
    starredState = !starredState;
    return starredState;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake video backend: no native code, streams driven by the test.
class _StyleFakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  Duration? lastSeek;

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
    _duration.add(const Duration(seconds: 7620));
    if (startPosition > Duration.zero) _position.add(startPosition);
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _position.add(position);
  }

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
  }
}

/// Fake video repo: direct play always succeeds; progress calls are
/// no-ops. Everything else is never called.
class _StyleFakeVideoRepo implements VideoRepository {
  @override
  bool get hasCredentials => true;

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
  }) async {
    return (
      decision: const PlaybackDecision(kind: PlaybackKind.direct),
      url: 'https://example.com/v.mp4',
    );
  }

  @override
  String subtitleUrlFor(VideoItem item, SubtitleTrackInfo track) => '';

  @override
  Future<void> reportProgress(
    VideoItem item,
    Duration position, {
    bool isPaused = false,
  }) async {}

  @override
  Future<void> markPlayed(VideoItem item) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
