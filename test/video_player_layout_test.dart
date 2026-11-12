// Video player layout follows NextPlayer's three-zone structure
// (top bar / centred middle controls / bottom block), adapted to
// our styles — layout pattern only, no NextPlayer code or branding.
//
// Top bar: back + title + play-mode chip + subtitle + quality.
// Middle: seek-back-10 / play-pause / seek-forward-10, centred.
// Bottom: tappable time chip (elapsed / remaining), seek bar,
// scrollable action row (fullscreen, close, Netflix next episode).
// Plus: double-tap left/right half seeks ∓10s with a centre
// indicator, and a centred spinner while the backend is buffering.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';

const _item = VideoItem(
  id: 'm1',
  title: 'The Last Horizon',
  durationSeconds: 200,
  serverId: 'srv-emby',
);

/// Fake video backend with position/buffering control for the tests.
class _LayoutFakeBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();

  Duration lastSeek = Duration.zero;

  void emitPlaying(bool value) => _playing.add(value);
  void emitPosition(Duration value) => _position.add(value);
  void emitBuffering(bool value) => _buffering.add(value);

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
    _duration.add(const Duration(seconds: 200));
    _position.add(startPosition);
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
    await _buffering.close();
  }
}

class _LayoutVideoRepo implements VideoRepository {
  @override
  bool get hasCredentials => true;

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
    List<MediaSourceInfo>? sources,
  }) async {
    return (
      decision: const PlaybackDecision(kind: PlaybackKind.direct),
      url: 'https://example.com/v.mp4',
    );
  }

  @override
  Future<void> reportPlaybackStarted(
    VideoItem item, {
    String playMethod = 'DirectPlay',
  }) async {}

  @override
  Future<void> reportProgress(
    VideoItem item,
    Duration position, {
    bool isPaused = false,
  }) async {}

  @override
  Future<void> markPlayed(VideoItem item) async {}

  @override
  String subtitleUrlFor(VideoItem item, SubtitleTrackInfo track) => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<VideoPlayerService> _pumpPlayer(
  WidgetTester tester, {
  required _LayoutFakeBackend backend,
  List<SubtitleTrackInfo> subtitles = const [],
  SettingsService? settings,
  VideoItem? nextEpisode,
  void Function(VideoItem episode)? onPlayNextEpisode,
}) async {
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
        item: _item,
        repo: _LayoutVideoRepo(),
        history: PlaybackStore(db),
        service: service,
        subtitles: subtitles,
        settings: settings,
        nextEpisode: nextEpisode,
        onPlayNextEpisode: onPlayNextEpisode,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return service;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NextPlayer-style layout', () {
    testWidgets('top bar: back, title, chip, subtitle, quality', (
      tester,
    ) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(
        tester,
        backend: backend,
        subtitles: const [SubtitleTrackInfo(index: 0, language: 'eng')],
      );

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text('The Last Horizon'), findsWidgets);
      expect(find.text('直接播放'), findsOneWidget);
      expect(find.byIcon(Icons.subtitles), findsOneWidget);
      expect(find.byIcon(Icons.high_quality), findsOneWidget);
      // Subtitle button is enabled when tracks exist.
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.subtitles),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('subtitle button disabled with no subtitle tracks', (
      tester,
    ) async {
      await _pumpPlayer(tester, backend: _LayoutFakeBackend());
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.subtitles),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('middle: seek-back, play-pause, seek-forward centred', (
      tester,
    ) async {
      await _pumpPlayer(tester, backend: _LayoutFakeBackend());
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      // Open auto-plays, so the centre button shows pause.
      expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
    });

    testWidgets('bottom: time chip, slider, fullscreen, close', (tester) async {
      await _pumpPlayer(tester, backend: _LayoutFakeBackend());
      expect(find.text('0:00 / 3:20'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('tapping the time chip toggles remaining time', (tester) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(tester, backend: backend);
      backend.emitPosition(const Duration(seconds: 60));
      await tester.pump();
      await tester.pump();
      expect(find.text('1:00 / 3:20'), findsOneWidget);
      await tester.tap(find.text('1:00 / 3:20'));
      // A single tap waits out the double-tap timeout (300ms)
      // before the button fires.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text('-2:20 / 3:20'), findsOneWidget);
    });

    testWidgets('Netflix style shows the next-episode button', (tester) async {
      final settings = SettingsService();
      await settings.setVideoPlayerStyle(VideoPlayerStyle.netflix);
      await _pumpPlayer(
        tester,
        backend: _LayoutFakeBackend(),
        settings: settings,
        nextEpisode: const VideoItem(
          id: 'e2',
          title: 'Episode 2',
          serverId: 'srv-emby',
        ),
        onPlayNextEpisode: (_) {},
      );
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
    });

    testWidgets('standard style has no next-episode button', (tester) async {
      await _pumpPlayer(
        tester,
        backend: _LayoutFakeBackend(),
        nextEpisode: const VideoItem(
          id: 'e2',
          title: 'Episode 2',
          serverId: 'srv-emby',
        ),
        onPlayNextEpisode: (_) {},
      );
      expect(find.byIcon(Icons.skip_next), findsNothing);
    });
  });

  group('double-tap seek', () {
    testWidgets('double-tap right half seeks +10s with indicator', (
      tester,
    ) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(tester, backend: backend);
      backend.emitPosition(const Duration(seconds: 60));
      await tester.pump();
      await tester.pump();
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 70));
      expect(find.text('+10秒 · 1:10'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('double-tap left half seeks -10s with indicator', (
      tester,
    ) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(tester, backend: backend);
      backend.emitPosition(const Duration(seconds: 60));
      await tester.pump();
      await tester.pump();
      await tester.tapAt(const Offset(100, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(100, 300));
      await tester.pump();
      expect(backend.lastSeek, const Duration(seconds: 50));
      expect(find.text('−10秒 · 0:50'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('seek indicator disappears after a second', (tester) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(tester, backend: backend);
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
      expect(find.textContaining('+10秒'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('+10秒'), findsNothing);
    });
  });

  group('buffering indicator', () {
    testWidgets('centred spinner appears while buffering', (tester) async {
      final backend = _LayoutFakeBackend();
      await _pumpPlayer(tester, backend: backend);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      backend.emitBuffering(true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      backend.emitBuffering(false);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
