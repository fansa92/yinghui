import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/theme.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';

void main() {
  group('NowPlayingPage desktop layout', () {
    const track = Track(
      id: 't1',
      title: 'Test Song',
      artist: 'Singer',
      album: 'Album',
      durationSeconds: 200,
      serverId: 'srv',
      sourceLabel: 'Navidrome',
    );

    void setSurface(WidgetTester tester, double width, double height) {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<PlayerService> playingPlayer() async {
      final backend = _DesktopFakeBackend();
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: () => backend,
      );
      await player.playQueue([track]);
      return player;
    }

    Future<SettingsService> settingsWith(MusicPlayerStyle style) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.setMusicPlayerStyle(style);
      return settings;
    }

    Future<void> pumpPage(
      WidgetTester tester, {
      required PlayerService player,
      required SettingsService settings,
      MusicRepository? musicRepo,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(
            player: player,
            settings: settings,
            musicRepo: musicRepo,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('desktop: two-column layout with a volume slider', (
      tester,
    ) async {
      setSurface(tester, 1440, 900);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      await pumpPage(tester, player: player, settings: settings);

      expect(find.byKey(const ValueKey('desktop-two-column')), findsOneWidget);
      // Seek slider + volume slider; the mockup's volume row is in
      // the right column for every style on desktop.
      expect(find.byType(Slider), findsNWidgets(2));
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('接下来播放'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == YingHuiTheme.primaryGreen,
        ),
        findsOneWidget,
      );
    });

    testWidgets('desktop: appleMusic keeps white button + remaining time', (
      tester,
    ) async {
      setSurface(tester, 1440, 900);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.appleMusic);
      await pumpPage(tester, player: player, settings: settings);

      expect(find.byKey(const ValueKey('desktop-two-column')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == Colors.white,
        ),
        findsOneWidget,
      );
      expect(find.text('-3:20'), findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets('desktop: spotify keeps black background + heart', (
      tester,
    ) async {
      setSurface(tester, 1440, 900);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.spotify);
      await pumpPage(
        tester,
        player: player,
        settings: settings,
        musicRepo: _DesktopFakeMusicRepo(),
      );

      expect(find.byKey(const ValueKey('desktop-two-column')), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.black,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.icon == Icons.pause_circle_filled &&
              w.color == Colors.white,
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('播放队列'), findsOneWidget);
    });

    testWidgets('desktop: style change restyles the two-column page live', (
      tester,
    ) async {
      setSurface(tester, 1440, 900);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      await pumpPage(tester, player: player, settings: settings);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        isNull,
      );

      await settings.setMusicPlayerStyle(MusicPlayerStyle.spotify);
      await tester.pump();
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.black,
      );
      expect(find.byKey(const ValueKey('desktop-two-column')), findsOneWidget);
    });

    testWidgets('phone: single column, no desktop volume slider', (
      tester,
    ) async {
      setSurface(tester, 390, 844);
      final player = await playingPlayer();
      addTearDown(player.dispose);
      final settings = await settingsWith(MusicPlayerStyle.standard);
      await pumpPage(tester, player: player, settings: settings);

      expect(find.byKey(const ValueKey('desktop-two-column')), findsNothing);
      // Seek slider only — the volume slider stays Apple Music only
      // on phones.
      expect(find.byType(Slider), findsOneWidget);
    });
  });

  group('VideoPlayerPage keyboard shortcuts', () {
    const item = VideoItem(
      id: 'e1',
      title: 'Episode 1',
      durationSeconds: 7620,
      serverId: 'srv-emby',
    );

    void setSurface(WidgetTester tester, double width, double height) {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<SettingsService> videoSettings() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      return settings;
    }

    /// Pumps the player directly as the home page (no route to pop).
    Future<_DesktopFakeVideoBackend> pumpPlayer(
      WidgetTester tester, {
      double width = 800,
      double height = 600,
    }) async {
      setSurface(tester, width, height);
      final backend = _DesktopFakeVideoBackend();
      final settings = await videoSettings();
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
            repo: _DesktopFakeVideoRepo(),
            history: PlaybackStore(db),
            service: service,
            settings: settings,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      return backend;
    }

    /// Pumps a Home page with an Open button, then opens the player
    /// on a real route so Esc can be tested as a pop.
    Future<_DesktopFakeVideoBackend> pumpPlayerOnRoute(
      WidgetTester tester, {
      double width = 800,
      double height = 600,
    }) async {
      setSurface(tester, width, height);
      final backend = _DesktopFakeVideoBackend();
      final settings = await videoSettings();
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final service = VideoPlayerService(
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VideoPlayerPage(
                          item: item,
                          repo: _DesktopFakeVideoRepo(),
                          history: PlaybackStore(db),
                          service: service,
                          settings: settings,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open player'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open player'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      return backend;
    }

    testWidgets('narrow screen: no shortcuts hint on first open', (
      tester,
    ) async {
      VideoPlayerPage.resetShortcutsHintForTest();
      await pumpPlayer(tester, width: 390, height: 844);
      expect(find.text('键盘快捷键'), findsNothing);
    });

    testWidgets('Space toggles play/pause', (tester) async {
      final backend = await pumpPlayer(tester);
      expect(backend.playCalls, 1);
      expect(backend.pauseCalls, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.pauseCalls, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.playCalls, 2);
    });

    testWidgets('Arrow keys seek ∓10s through the shared seek logic', (
      tester,
    ) async {
      final backend = await pumpPlayer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 10));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 20));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 10));
    });

    testWidgets('Esc closes the player when not fullscreen', (tester) async {
      await pumpPlayerOnRoute(tester);
      expect(find.text('Open player'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Open player'), findsOneWidget);
    });

    testWidgets('F toggles fullscreen; Esc exits it, second Esc closes', (
      tester,
    ) async {
      await pumpPlayerOnRoute(tester);
      expect(find.text('Open player'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(find.text('Open player'), findsNothing);

      // First Esc exits fullscreen, it must not pop the player.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Open player'), findsNothing);

      // Second Esc closes the player.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Open player'), findsOneWidget);
    });

    testWidgets('wide screen: shortcuts hint shows once per session', (
      tester,
    ) async {
      VideoPlayerPage.resetShortcutsHintForTest();
      await pumpPlayer(tester, width: 1440, height: 900);
      expect(find.text('键盘快捷键'), findsOneWidget);
      expect(find.text('空格 · 播放 / 暂停'), findsOneWidget);
      expect(find.text('← → · 快进 / 快退 10 秒'), findsOneWidget);

      await tester.tap(find.byTooltip('知道了'));
      await tester.pump();
      expect(find.text('键盘快捷键'), findsNothing);

      // A second player in the same session does not show it again.
      await pumpPlayer(tester, width: 1440, height: 900);
      expect(find.text('键盘快捷键'), findsNothing);
    });
  });
}

/// Fake audio backend with volume, for the desktop music tests.
class _DesktopFakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  double _volume = 1.0;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
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
class _DesktopFakeMusicRepo implements MusicRepository {
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
class _DesktopFakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  Duration _positionValue = Duration.zero;
  Duration? lastSeek;
  int playCalls = 0;
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
    _positionValue = startPosition;
    _duration.add(const Duration(seconds: 7620));
    _position.add(_positionValue);
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    _positionValue = position;
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

/// Fake video repo: direct play always succeeds, progress is a no-op.
class _DesktopFakeVideoRepo implements VideoRepository {
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
  Future<void> reportPlaybackStarted(
    VideoItem item, {
    String playMethod = 'DirectPlay',
  }) async {}

  @override
  Future<void> reportPlaybackStopped(VideoItem item, Duration position) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
