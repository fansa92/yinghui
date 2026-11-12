import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/player_service.dart';

/// A backend whose open() fails (e.g. the stream URL is rejected).
class _OpenFailingBackend implements PlayerBackend {
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
    throw Exception('failed to open $url');
  }

  @override
  Future<void> play() async => _playing.add(true);
  @override
  Future<void> pause() async => _playing.add(false);
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}

  double _volume = 1.0;
  @override
  double get volume => _volume;
  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

/// A working backend (same shape as the music_p2 fake).
class _WorkingBackend implements PlayerBackend {
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
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}

  double _volume = 1.0;
  @override
  double get volume => _volume;
  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

const _tracks = [
  Track(
    id: 't1',
    title: 'Test Song',
    artist: 'Singer',
    album: 'Album',
    durationSeconds: 200,
    serverId: 'srv',
    sourceLabel: 'Navidrome',
  ),
];

PlayerService _service(PlayerBackend Function() factory) => PlayerService(
  streamUrlFor: (_) => 'https://example.com/stream',
  backendFactory: factory,
);

void main() {
  group('PlayerService surfaces backend failures instead of silence', () {
    test(
      'backend factory throwing (missing libmpv) is recorded, not thrown',
      () async {
        final service = _service(
          () => throw Exception(
            "Cannot find libmpv.so. Please ensure it's presence in the APK.",
          ),
        );
        addTearDown(service.dispose);
        // Must complete normally: the old code let this throw into a
        // fire-and-forget caller, so nothing ever showed.
        await service.playQueue(_tracks);
        expect(service.lastError, contains('libmpv'));
        expect(service.hasTrack, isTrue);
        expect(service.isPlaying, isFalse);
      },
    );

    test('open() throwing is recorded, not thrown', () async {
      final service = _service(_OpenFailingBackend.new);
      addTearDown(service.dispose);
      await service.playQueue(_tracks);
      expect(service.lastError, contains('failed to open'));
      expect(service.isPlaying, isFalse);
    });

    test('a successful open clears a previous error', () async {
      var calls = 0;
      final working = _WorkingBackend();
      final service = _service(() {
        calls++;
        if (calls == 1) {
          throw Exception('Cannot find libmpv.so');
        }
        return working;
      });
      addTearDown(service.dispose);
      await service.playQueue(_tracks);
      expect(service.lastError, isNotNull);
      await service.playQueue(_tracks);
      await Future<void>.delayed(Duration.zero);
      expect(service.lastError, isNull);
      expect(service.isPlaying, isTrue);
    });

    test('togglePlay on a restored session surfaces init failure', () async {
      final service = _service(() => throw Exception('Cannot find libmpv.so'));
      addTearDown(service.dispose);
      service.restoreQueue(_tracks, position: const Duration(seconds: 30));
      await service.togglePlay();
      expect(service.lastError, contains('libmpv'));
    });

    test('seek and setVolume failures are recorded, not thrown', () async {
      final service = _service(() => throw Exception('Cannot find libmpv.so'));
      addTearDown(service.dispose);
      await service.playQueue(_tracks);
      expect(service.lastError, isNotNull);
      // These create the backend (which throws) from UI callbacks.
      await service.seek(const Duration(seconds: 10));
      expect(service.lastError, contains('libmpv'));
      await service.setVolume(0.5);
      expect(service.lastError, contains('libmpv'));
    });
  });

  group('NowPlayingPage shows the audio error', () {
    testWidgets('failed open shows 无法播放 with retry', (tester) async {
      final service = _service(
        () => throw Exception(
          "Cannot find libmpv.so. Please ensure it's presence in the APK.",
        ),
      );
      addTearDown(service.dispose);
      await service.playQueue(_tracks);
      expect(service.lastError, isNotNull);

      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(player: service)),
      );
      await tester.pump();

      expect(find.textContaining('无法播放'), findsOneWidget);
      expect(find.textContaining('libmpv'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // Retry re-attempts the open and stays on the error (no crash).
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.textContaining('无法播放'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('no banner once playback opens fine', (tester) async {
      final backend = _WorkingBackend();
      final service = _service(() => backend);
      addTearDown(service.dispose);
      await service.playQueue(_tracks);
      // NOTE: no Future.delayed here — testWidgets runs in fake async
      // and a delayed future only fires when the tester pumps, so
      // awaiting one before the first pump hangs the test forever.
      // The banner depends only on lastError, which the open path
      // already settled synchronously above.
      await tester.pumpWidget(
        MaterialApp(home: NowPlayingPage(player: service)),
      );
      await tester.pump();

      expect(find.textContaining('无法播放'), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
