import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/features/player/now_playing_page.dart';
import 'package:yinghui/features/player/player_service.dart';

Track _track(String id, [String title = '']) => Track(
  id: id,
  title: title.isEmpty ? 'Track $id' : title,
  artist: 'A',
  durationSeconds: 180,
  serverId: 'srv',
);

List<Track> _tracks(int n) =>
    List.generate(n, (i) => _track('t${i + 1}', 'Track ${i + 1}'));

/// Fake audio backend: no native code, streams driven by the test.
/// Same shape as the one in music_p2_test.dart.
class _FakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int stopCalls = 0;

  void emitPosition(Duration position) => _position.add(position);
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
  Future<void> open(String url) async {
    openedUrl = url;
    _duration.add(const Duration(seconds: 180));
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
    seekCalls++;
    _position.add(position);
  }

  double _volume = 1.0;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

void main() {
  group('Repeat modes', () {
    late _FakeBackend backend;
    late PlayerService service;
    late List<Track> tracks;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = _FakeBackend();
      tracks = _tracks(3);
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    test('repeat off (default): next() at the end stops playback', () async {
      await service.playQueue(tracks);
      await service.next();
      await service.next();
      expect(service.currentTrack?.id, 't3');
      await service.next();
      expect(service.currentTrack?.id, 't3');
      expect(service.isPlaying, isFalse);
      expect(backend.stopCalls, 1);
    });

    test('repeat all: next() at the end loops to the first track', () async {
      await service.setRepeat(MusicRepeatMode.all);
      await service.playQueue(tracks);
      await service.next();
      await service.next();
      expect(service.currentTrack?.id, 't3');
      await service.next();
      expect(service.currentTrack?.id, 't1');
      expect(service.isPlaying, isTrue);
      await service.next();
      expect(service.currentTrack?.id, 't2');
    });

    test('repeat all: a completion at the last track wraps', () async {
      await service.setRepeat(MusicRepeatMode.all);
      await service.playQueue(tracks);
      await service.next();
      await service.next();
      expect(service.currentTrack?.id, 't3');
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.currentTrack?.id, 't1');
    });

    test('repeat one: completion restarts the same track', () async {
      await service.setRepeat(MusicRepeatMode.one);
      await service.playQueue(tracks);
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.currentTrack?.id, 't1');
      expect(backend.seekCalls, 1);
      expect(backend.openedUrl, contains('id=t1'));
    });

    test(
      'repeat one: next() restarts the track instead of moving on',
      () async {
        await service.setRepeat(MusicRepeatMode.one);
        await service.playQueue(tracks);
        await service.next();
        expect(service.currentTrack?.id, 't1');
        expect(backend.seekCalls, 1);
      },
    );

    test('cycleRepeat goes off -> all -> one -> off', () async {
      expect(service.repeatMode, MusicRepeatMode.off);
      await service.cycleRepeat();
      expect(service.repeatMode, MusicRepeatMode.all);
      await service.cycleRepeat();
      expect(service.repeatMode, MusicRepeatMode.one);
      await service.cycleRepeat();
      expect(service.repeatMode, MusicRepeatMode.off);
    });

    test(
      'repeat all: previous() at the start wraps to the last track',
      () async {
        await service.setRepeat(MusicRepeatMode.all);
        await service.playQueue(tracks);
        // Position <= 3s so previous() moves instead of restarting.
        await service.previous();
        expect(service.currentTrack?.id, 't3');
      },
    );
  });

  group('Shuffle', () {
    late _FakeBackend backend;
    late PlayerService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = _FakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    test(
      'shuffle keeps the current track first and permutes the rest',
      () async {
        final tracks = _tracks(10);
        await service.playQueue(tracks);
        await service.setShuffle(true);
        expect(service.isShuffle, isTrue);
        expect(service.currentTrack?.id, 't1');
        final order = service.playOrder;
        expect(order.length, 10);
        expect(order.toSet(), {0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
        expect(order.first, 0);
        expect(order, isNot(List.generate(10, (i) => i)));
        // The user's queue itself is untouched.
        expect(service.queue.map((t) => t.id).toList(), [
          for (var i = 1; i <= 10; i++) 't$i',
        ]);
      },
    );

    test('shuffle follows the shuffled order on next()', () async {
      final tracks = _tracks(10);
      await service.playQueue(tracks);
      await service.setShuffle(true);
      final order = service.playOrder;
      await service.next();
      expect(service.currentIndex, order[1]);
      await service.next();
      expect(service.currentIndex, order[2]);
    });

    test('turning shuffle off restores the original order', () async {
      final tracks = _tracks(10);
      await service.playQueue(tracks);
      await service.setShuffle(true);
      final shuffled = service.playOrder;
      expect(shuffled, isNot(List.generate(10, (i) => i)));
      await service.setShuffle(false);
      expect(service.playOrder, List.generate(10, (i) => i));
      expect(service.currentTrack?.id, 't1');
      await service.next();
      expect(service.currentTrack?.id, 't2');
    });

    test('enabling shuffle mid-queue keeps the current track first', () async {
      final tracks = _tracks(5);
      await service.playQueue(tracks, startIndex: 2);
      expect(service.currentTrack?.id, 't3');
      await service.setShuffle(true);
      expect(service.currentTrack?.id, 't3');
      expect(service.playOrder.first, 2);
      expect(service.playOrder.toSet(), {0, 1, 2, 3, 4});
    });

    test('shuffle + repeat-all loops the shuffled order', () async {
      final tracks = _tracks(4);
      await service.setShuffle(true);
      await service.setRepeat(MusicRepeatMode.all);
      await service.playQueue(tracks);
      final order = service.playOrder;
      for (var i = 0; i < 3; i++) {
        await service.next();
      }
      expect(service.currentIndex, order[3]);
      await service.next();
      expect(service.currentIndex, order[0]);
    });
  });

  group('Mode persistence', () {
    test('shuffle + repeat survive a service restart via prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final backend = _FakeBackend();
      final first = PlayerService(
        streamUrlFor: (_) => 'https://example.invalid/stream',
        backendFactory: () => backend,
        prefs: prefs,
      );
      addTearDown(first.dispose);
      await first.setShuffle(true);
      await first.setRepeat(MusicRepeatMode.all);
      expect(prefs.getBool('yinghui_shuffle_enabled'), isTrue);
      expect(prefs.getString('yinghui_repeat_mode'), 'all');

      final second = PlayerService(
        streamUrlFor: (_) => 'https://example.invalid/stream',
        backendFactory: () => backend,
        prefs: prefs,
      );
      addTearDown(second.dispose);
      expect(second.isShuffle, isFalse);
      expect(second.repeatMode, MusicRepeatMode.off);
      await second.loadModes();
      expect(second.isShuffle, isTrue);
      expect(second.repeatMode, MusicRepeatMode.all);
    });

    test('unknown stored repeat value falls back to off', () async {
      SharedPreferences.setMockInitialValues({
        'yinghui_repeat_mode': 'banana',
        'yinghui_shuffle_enabled': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final service = PlayerService(
        streamUrlFor: (_) => 'https://example.invalid/stream',
        backendFactory: _FakeBackend.new,
        prefs: prefs,
      );
      addTearDown(service.dispose);
      await service.loadModes();
      expect(service.repeatMode, MusicRepeatMode.off);
      expect(service.isShuffle, isTrue);
    });

    test('restored queue honours the saved shuffle mode', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final backend = _FakeBackend();
      final service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        prefs: prefs,
        random: Random(7),
      );
      addTearDown(service.dispose);
      await service.setShuffle(true);
      service.restoreQueue(_tracks(5), index: 1);
      expect(service.currentTrack?.id, 't2');
      expect(service.playOrder.first, 1);
      expect(service.playOrder.toSet(), {0, 1, 2, 3, 4});
    });
  });

  group('Queue management', () {
    late _FakeBackend backend;
    late PlayerService service;
    late List<Track> tracks;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = _FakeBackend();
      tracks = _tracks(4);
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    List<String> ids() => service.queue.map((t) => t.id).toList();

    test('removeAt drops a later track and keeps playing', () async {
      await service.playQueue(tracks);
      await service.removeAt(2);
      expect(ids(), ['t1', 't2', 't4']);
      expect(service.currentTrack?.id, 't1');
      expect(service.isPlaying, isTrue);
    });

    test('removeAt on the current track plays the next one', () async {
      await service.playQueue(tracks);
      await service.removeAt(0);
      expect(ids(), ['t2', 't3', 't4']);
      expect(service.currentTrack?.id, 't2');
      expect(backend.openedUrl, contains('id=t2'));
    });

    test('removeAt on the last track stops and clears the queue', () async {
      await service.playQueue([tracks.first]);
      await service.removeAt(0);
      expect(service.queue, isEmpty);
      expect(service.currentTrack, isNull);
      expect(service.isPlaying, isFalse);
    });

    test('removeAt with shuffle on keeps the play order consistent', () async {
      await service.setShuffle(true);
      await service.playQueue(tracks);
      final orderBefore = service.playOrder;
      // Remove a track that is not current and not next in play order.
      final victim = orderBefore.last;
      await service.removeAt(victim);
      expect(service.queue.length, 3);
      expect(service.currentTrack?.id, 't1');
      final order = service.playOrder;
      expect(order.length, 3);
      expect(order.toSet(), {0, 1, 2});
      // next() still follows the shuffled order.
      await service.next();
      expect(service.currentIndex, order[1]);
    });

    test('moveQueue reorders and the current track follows', () async {
      await service.playQueue(tracks);
      service.moveQueue(0, 2);
      expect(ids(), ['t2', 't3', 't1', 't4']);
      expect(service.currentTrack?.id, 't1');
      expect(service.currentIndex, 2);
      service.moveQueue(3, 0);
      expect(ids(), ['t4', 't2', 't3', 't1']);
      expect(service.currentTrack?.id, 't1');
      expect(service.currentIndex, 3);
    });

    test('moveQueue with shuffle on preserves the play order', () async {
      await service.setShuffle(true);
      await service.playQueue(tracks);
      final orderBefore = service.playOrder;
      // Move the track that plays last to the front of the queue.
      final lastPlayed = orderBefore.last;
      service.moveQueue(lastPlayed, 0);
      expect(service.currentTrack?.id, 't1');
      // The play order still lists the same tracks in the same
      // playback sequence, just with remapped queue indices.
      final orderAfter = service.playOrder;
      expect(
        orderAfter.map((i) => service.queue[i].id).toList(),
        orderBefore.map((i) => tracks[i].id).toList(),
      );
    });

    test('clearQueue keeps only the current track playing', () async {
      await service.playQueue(tracks);
      await service.next();
      expect(service.currentTrack?.id, 't2');
      service.clearQueue();
      expect(ids(), ['t2']);
      expect(service.currentTrack?.id, 't2');
      expect(service.isPlaying, isTrue);
    });

    test('playNext inserts after the current track', () async {
      await service.playQueue(tracks);
      final extra = _track('tx', 'Extra');
      await service.playNext(extra);
      expect(ids(), ['t1', 'tx', 't2', 't3', 't4']);
      await service.next();
      expect(service.currentTrack?.id, 'tx');
    });

    test('addToQueue appends at the end', () async {
      await service.playQueue(tracks);
      final extra = _track('tx', 'Extra');
      await service.addToQueue(extra);
      expect(ids(), ['t1', 't2', 't3', 't4', 'tx']);
      expect(service.currentTrack?.id, 't1');
      await service.next();
      await service.next();
      await service.next();
      await service.next();
      expect(service.currentTrack?.id, 'tx');
    });

    test('jumpTo jumps without rebuilding the shuffle order', () async {
      await service.setShuffle(true);
      await service.playQueue(tracks);
      final orderBefore = service.playOrder;
      await service.jumpTo(2);
      expect(service.currentTrack?.id, 't3');
      expect(service.playOrder, orderBefore);
      expect(service.queue.map((t) => t.id).toList(), ['t1', 't2', 't3', 't4']);
    });
  });

  group('playTrack does not destroy the queue', () {
    late _FakeBackend backend;
    late PlayerService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = _FakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    test('tapping an unknown track inserts it after the current one', () async {
      final tracks = _tracks(3);
      await service.playQueue(tracks);
      final extra = _track('tx', 'Extra');
      await service.playTrack(extra);
      expect(service.currentTrack?.id, 'tx');
      expect(service.queue.map((t) => t.id).toList(), ['t1', 'tx', 't2', 't3']);
      // The rest of the queue is still there afterwards.
      await service.next();
      expect(service.currentTrack?.id, 't2');
    });

    test('tapping a track already in the queue jumps to it', () async {
      final tracks = _tracks(3);
      await service.playQueue(tracks);
      await service.playTrack(tracks[2]);
      expect(service.currentTrack?.id, 't3');
      expect(service.queue.map((t) => t.id).toList(), ['t1', 't2', 't3']);
      expect(backend.openedUrl, contains('id=t3'));
    });

    test('tapping the current track does not restart it', () async {
      final tracks = _tracks(3);
      await service.playQueue(tracks);
      final openedBefore = backend.openedUrl;
      await service.playTrack(tracks.first);
      expect(service.currentTrack?.id, 't1');
      expect(backend.openedUrl, openedBefore);
    });

    test('playTrack with an empty queue just plays the track', () async {
      final extra = _track('tx', 'Extra');
      await service.playTrack(extra);
      expect(service.currentTrack?.id, 'tx');
      expect(service.queue.map((t) => t.id).toList(), ['tx']);
    });

    test('playQueue still replaces the whole queue (play-all)', () async {
      final tracks = _tracks(3);
      await service.playQueue(tracks);
      await service.playTrack(_track('tx', 'Extra'));
      expect(service.queue.length, 4);
      await service.playQueue(_tracks(2));
      expect(service.queue.map((t) => t.id).toList(), ['t1', 't2']);
      expect(service.currentTrack?.id, 't1');
    });
  });

  group('NowPlayingPage shuffle / repeat buttons', () {
    late _FakeBackend backend;
    late PlayerService service;

    Future<void> pumpPage(
      WidgetTester tester, {
      MusicPlayerStyle style = MusicPlayerStyle.standard,
    }) async {
      // Tall viewport so the whole single-column page (cover +
      // transport + queue) is built: ListView builds lazily.
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.setMusicPlayerStyle(style);
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: service, settings: settings),
        ),
      );
      await tester.pump();
    }

    setUp(() {
      backend = _FakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    testWidgets('standard style: shuffle + repeat toggle and show state', (
      tester,
    ) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester);
      await tester.pump();

      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);

      await tester.tap(find.byIcon(Icons.shuffle));
      await tester.pump();
      expect(service.isShuffle, isTrue);
      expect(find.byTooltip('关闭随机播放'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pump();
      expect(service.repeatMode, MusicRepeatMode.all);
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pump();
      expect(service.repeatMode, MusicRepeatMode.one);
      expect(find.byIcon(Icons.repeat_one), findsOneWidget);
      await tester.tap(find.byIcon(Icons.repeat_one));
      await tester.pump();
      expect(service.repeatMode, MusicRepeatMode.off);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
    });

    testWidgets('appleMusic style: buttons toggle', (tester) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester, style: MusicPlayerStyle.appleMusic);
      await tester.pump();
      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      await tester.tap(find.byIcon(Icons.shuffle));
      await tester.pump();
      expect(service.isShuffle, isTrue);
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pump();
      expect(service.repeatMode, MusicRepeatMode.all);
    });

    testWidgets('spotify style: buttons toggle', (tester) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester, style: MusicPlayerStyle.spotify);
      await tester.pump();
      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      await tester.tap(find.byIcon(Icons.shuffle));
      await tester.pump();
      expect(service.isShuffle, isTrue);
      await tester.tap(find.byIcon(Icons.repeat));
      await tester.pump();
      expect(service.repeatMode, MusicRepeatMode.all);
    });
  });

  group('NowPlayingPage Up next management', () {
    late _FakeBackend backend;
    late PlayerService service;

    Future<void> pumpPage(WidgetTester tester) async {
      // Tall viewport so the whole single-column page (cover +
      // transport + queue) is built: ListView builds lazily.
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await tester.pumpWidget(
        MaterialApp(
          home: NowPlayingPage(player: service, settings: settings),
        ),
      );
      await tester.pump();
    }

    setUp(() {
      backend = _FakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        random: Random(42),
      );
      addTearDown(service.dispose);
    });

    testWidgets('header shows the count and 清空 keeps the current track', (
      tester,
    ) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester);
      expect(find.text('共 3 首'), findsOneWidget);
      expect(find.text('清空'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(service.queue.map((t) => t.id).toList(), ['t1']);
      expect(service.currentTrack?.id, 't1');
      expect(find.text('共 1 首'), findsOneWidget);
      expect(find.text('清空'), findsNothing);
    });

    testWidgets('remove button drops a row', (tester) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester);
      // The second row's remove button.
      final removeButtons = find.byIcon(Icons.close);
      expect(removeButtons, findsNWidgets(3));
      await tester.tap(removeButtons.at(1));
      await tester.pump();
      expect(service.queue.map((t) => t.id).toList(), ['t1', 't3']);
      expect(find.text('Track 2'), findsNothing);
    });

    testWidgets('tapping a row jumps without rebuilding the queue', (
      tester,
    ) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester);
      await tester.tap(find.text('Track 3'));
      await tester.pump();
      expect(service.currentTrack?.id, 't3');
      expect(service.queue.map((t) => t.id).toList(), ['t1', 't2', 't3']);
    });

    testWidgets('dragging the handle reorders the queue', (tester) async {
      await service.playQueue(_tracks(3));
      await pumpPage(tester);
      // Drag the first row's handle onto the second row's handle:
      // the first track moves down exactly one position. A timed
      // drag sends incremental moves, like a real finger drag.
      final handles = find.byIcon(Icons.drag_handle);
      expect(handles, findsNWidgets(3));
      final from = tester.getCenter(handles.first);
      final to = tester.getCenter(handles.at(1));
      await tester.timedDrag(
        handles.first,
        to - from + const Offset(0, 8),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(service.queue.map((t) => t.id).toList(), ['t2', 't1', 't3']);
      expect(service.currentTrack?.id, 't1');
      expect(service.currentIndex, 1);
    });
  });
}
