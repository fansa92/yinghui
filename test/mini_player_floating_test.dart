// MiniPlayer floating presentation: a card with side + bottom margins,
// rounded corners and elevation, sitting above the page content and
// the bottom navigation instead of a pinned edge-to-edge bar.
// Controls are unchanged: tap opens NowPlayingPage, play/pause works.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/theme.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/features/player/mini_player.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/playback_coordinator.dart';
import 'package:yinghui/features/player/player_service.dart';

void main() {
  group('MiniPlayer floating presentation', () {
    const track = Track(
      id: 't1',
      title: 'Floating Song',
      artist: 'Neon Lights',
      durationSeconds: 200,
      serverId: 'srv-a',
    );

    PlayerService playerWithTrack() {
      final player = PlayerService(
        streamUrlFor: (_) => 'https://example.com/stream',
        backendFactory: _FloatingFakeBackend.new,
      );
      player.restoreQueue([track]);
      return player;
    }

    Future<void> pumpMiniPlayer(
      WidgetTester tester, {
      required PlayerService player,
      required ThemeData theme,
      required Size surface,
    }) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(PlaybackCoordinator.resetForTest);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                MiniPlayer(player: player),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    final cardFinder = find.byKey(const ValueKey('mini-player-card'));

    testWidgets('mobile: card floats with side and bottom margins', (
      tester,
    ) async {
      final player = playerWithTrack();
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.dark,
        surface: const Size(390, 844),
      );

      expect(cardFinder, findsOneWidget);
      final rect = tester.getRect(cardFinder);
      // 16 from each side, 12 above the bottom edge.
      expect(rect.left, 16.0);
      expect(rect.right, 374.0);
      expect(rect.bottom, 832.0);

      final card = tester.widget<Card>(cardFinder);
      expect(card.elevation, 8);
      expect(card.shape, isA<RoundedRectangleBorder>());
      expect(
        (card.shape as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(16),
      );
      // Dark card colour comes from the theme (#1A1C22).
      final material = tester.widget<Material>(
        find.descendant(of: cardFinder, matching: find.byType(Material)).first,
      );
      expect(material.color, YingHuiTheme.card);
    });

    testWidgets('desktop: card is capped and centred', (tester) async {
      final player = playerWithTrack();
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.dark,
        surface: const Size(1440, 900),
      );

      expect(cardFinder, findsOneWidget);
      final rect = tester.getRect(cardFinder);
      // 720-wide cap, centred in the 1440-wide surface.
      expect(rect.left, 360.0);
      expect(rect.right, 1080.0);
      expect(rect.bottom, 888.0);
    });

    testWidgets('light theme: card uses the light surface colour', (
      tester,
    ) async {
      final player = playerWithTrack();
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.light,
        surface: const Size(390, 844),
      );

      final material = tester.widget<Material>(
        find.descendant(of: cardFinder, matching: find.byType(Material)).first,
      );
      expect(material.color, YingHuiTheme.lightCard);
    });

    testWidgets('tap the card opens NowPlayingPage', (tester) async {
      final player = playerWithTrack();
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.dark,
        surface: const Size(390, 844),
      );

      await tester.tap(find.text('Floating Song'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NowPlayingPage), findsOneWidget);
    });

    testWidgets('play/pause button still toggles playback', (tester) async {
      final player = playerWithTrack();
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.dark,
        surface: const Size(390, 844),
      );

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('hides when there is no current track', (tester) async {
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FloatingFakeBackend.new,
      );
      addTearDown(player.dispose);
      await pumpMiniPlayer(
        tester,
        player: player,
        theme: YingHuiTheme.dark,
        surface: const Size(390, 844),
      );

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(tester.getRect(find.byType(MiniPlayer)).height, 0.0);
      expect(cardFinder, findsNothing);
    });
  });
}

class _FloatingFakeBackend implements PlayerBackend {
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
  Future<void> stop() async => _playing.add(false);

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}
