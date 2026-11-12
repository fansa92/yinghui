// Mutual exclusion between music and video playback, plus the
// mini-player being scoped to music pages only (Music tab +
// AlbumDetailPage).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/music/album_detail_page.dart';
import 'package:yinghui/features/player/mini_player.dart';
import 'package:yinghui/features/player/playback_coordinator.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/player/video_player_service.dart';
import 'package:yinghui/features/shell/app_shell.dart';

void main() {
  group('PlaybackCoordinator mutual exclusion', () {
    late _FakeBackend musicBackend;
    late _FakeVideoBackend videoBackend;
    late PlayerService music;
    late VideoPlayerService video;
    late AppDatabase db;
    var musicDisposed = false;

    const tracks = [
      Track(
        id: 't1',
        title: 'Exclusion One',
        artist: 'A',
        durationSeconds: 200,
        serverId: 'srv-a',
      ),
      Track(
        id: 't2',
        title: 'Exclusion Two',
        artist: 'A',
        durationSeconds: 180,
        serverId: 'srv-a',
      ),
    ];

    const item = VideoItem(
      id: 'm1',
      title: 'The Last Horizon',
      durationSeconds: 7620,
      serverId: 'srv-emby',
    );

    Track videoTrackFor(VideoItem v) => Track(
      id: v.id,
      title: v.title,
      artist: v.sourceLabel,
      durationSeconds: v.durationSeconds,
      serverId: v.serverId,
    );

    setUp(() {
      // Fresh shared coordinator per test: services default to it.
      PlaybackCoordinator.resetForTest();
      musicDisposed = false;
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      musicBackend = _FakeBackend();
      videoBackend = _FakeVideoBackend();
      music = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/rest/stream?id=${t.id}',
        backendFactory: () => musicBackend,
        history: PlaybackStore(db),
      );
      video = VideoPlayerService(
        backendFactory: () => videoBackend,
        history: PlaybackStore(db),
      );
    });

    tearDown(() async {
      if (!musicDisposed) music.dispose();
      video.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });

    test('music start pauses video and keeps its track and position', () async {
      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
        startPosition: const Duration(minutes: 10),
      );
      await Future<void>.delayed(Duration.zero);
      expect(video.isPlaying, isTrue);
      videoBackend.emitPosition(const Duration(minutes: 12));
      await Future<void>.delayed(Duration.zero);
      expect(video.position, const Duration(minutes: 12));

      await music.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);

      expect(music.isPlaying, isTrue);
      expect(music.currentTrack?.id, 't1');
      expect(videoBackend.pauseCalls, 1);
      expect(video.isPlaying, isFalse);
      // Pause only: the video keeps its track and position.
      expect(video.track?.id, 'm1');
      expect(video.position, const Duration(minutes: 12));
    });

    test('video start pauses music; resuming music pauses video and keeps position', () async {
      await music.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      expect(music.isPlaying, isTrue);
      musicBackend.emitPosition(const Duration(seconds: 30));
      await Future<void>.delayed(Duration.zero);
      expect(music.position, const Duration(seconds: 30));

      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await Future<void>.delayed(Duration.zero);

      expect(video.isPlaying, isTrue);
      expect(musicBackend.pauseCalls, 1);
      expect(music.isPlaying, isFalse);
      // Pause only: queue, track and position are kept.
      expect(music.currentTrack?.id, 't1');
      expect(music.queue.length, 2);
      expect(music.position, const Duration(seconds: 30));

      // Resume via the mini-player path (togglePlay): music continues
      // where it left off and video is paused in return.
      await music.togglePlay();
      await Future<void>.delayed(Duration.zero);
      expect(music.isPlaying, isTrue);
      expect(music.position, const Duration(seconds: 30));
      expect(videoBackend.pauseCalls, 1);
      expect(video.isPlaying, isFalse);
    });

    test('music next pauses video', () async {
      await music.playQueue(tracks);
      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await Future<void>.delayed(Duration.zero);
      expect(music.isPlaying, isFalse);
      expect(video.isPlaying, isTrue);

      await music.next();
      await Future<void>.delayed(Duration.zero);
      expect(music.currentTrack?.id, 't2');
      expect(music.isPlaying, isTrue);
      expect(video.isPlaying, isFalse);
      expect(videoBackend.pauseCalls, 1);
    });

    test('video reopen pauses music', () async {
      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await music.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      expect(video.isPlaying, isFalse);
      expect(music.isPlaying, isTrue);

      await video.reopen(
        'https://example.invalid/Videos/m1/stream?quality=720p',
      );
      await Future<void>.delayed(Duration.zero);
      expect(video.isPlaying, isTrue);
      expect(music.isPlaying, isFalse);
      expect(musicBackend.pauseCalls, 1);
    });

    test('restoreQueue does not pause video', () async {
      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await Future<void>.delayed(Duration.zero);
      expect(video.isPlaying, isTrue);

      music.restoreQueue(
        tracks,
        index: 0,
        position: const Duration(seconds: 30),
      );
      await Future<void>.delayed(Duration.zero);

      expect(video.isPlaying, isTrue);
      expect(videoBackend.pauseCalls, 0);
      expect(music.isPlaying, isFalse);
      expect(music.currentTrack?.id, 't1');
      expect(music.position, const Duration(seconds: 30));
    });

    test('a disposed music service is unregistered and never paused', () async {
      await music.playQueue(tracks);
      await video.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await Future<void>.delayed(Duration.zero);
      expect(musicBackend.pauseCalls, 1);

      music.dispose();
      musicDisposed = true;
      await video.togglePlay(); // pause video
      await Future<void>.delayed(Duration.zero);
      await video.togglePlay(); // resume video -> coordinator finds no music
      await Future<void>.delayed(Duration.zero);

      expect(video.isPlaying, isTrue);
      expect(musicBackend.pauseCalls, 1);
    });

    test('video starts with no music service registered', () async {
      PlaybackCoordinator.resetForTest();
      final loneVideo = VideoPlayerService(
        backendFactory: _FakeVideoBackend.new,
        history: PlaybackStore(db),
      );
      addTearDown(loneVideo.dispose);
      await loneVideo.open(
        'https://example.invalid/Videos/m1/stream',
        videoTrackFor(item),
      );
      await Future<void>.delayed(Duration.zero);
      expect(loneVideo.isPlaying, isTrue);
      expect(musicBackend.pauseCalls, 0);
    });
  });

  group('MiniPlayer scoping', () {
    testWidgets('shows only on the Music tab', (tester) async {
      // Mobile width: bottom NavigationBar (the shell switches to a
      // rail at >= 800).
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      player.restoreQueue(const [
        Track(
          id: 't1',
          title: 'Exclusion Song',
          artist: 'A',
          durationSeconds: 200,
          serverId: 'srv-a',
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            settings: SettingsService(),
            store: store,
            musicRepo: RealMusicRepository(store: store, database: db),
            videoRepo: RealVideoRepository(store: store, database: db),
            downloadRepo: RealDownloadRepository(store: store, database: db),
            history: PlaybackStore(db),
            player: player,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      Finder navLabel(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

      // Home: no mini-player.
      expect(find.byType(MiniPlayer), findsNothing);
      expect(find.text('Exclusion Song'), findsNothing);

      // Music tab: mini-player appears.
      await tester.tap(navLabel('Music'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('Exclusion Song'), findsOneWidget);

      // Video tab: gone again.
      await tester.tap(navLabel('Video'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MiniPlayer), findsNothing);

      // Downloads tab: still gone.
      await tester.tap(navLabel('Downloads'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MiniPlayer), findsNothing);
    });

    testWidgets('mini-player is pinned at the bottom of AlbumDetailPage', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final repo = RealMusicRepository(store: store, database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      player.restoreQueue(const [
        Track(
          id: 't1',
          title: 'Exclusion Song',
          artist: 'Neon Lights',
          album: 'Midnight City',
          durationSeconds: 214,
          serverId: 'srv-a',
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumDetailPage(
            album: const Album(
              id: 'a1',
              title: 'Midnight City',
              artist: 'Neon Lights',
              year: 2024,
              trackCount: 12,
              serverId: 'srv-a',
            ),
            repo: repo,
            player: player,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('Exclusion Song'), findsOneWidget);
      // Pinned at the bottom of the screen (default 800x600 surface).
      expect(tester.getRect(find.byType(MiniPlayer)).bottom, 600.0);
      // Scroll the track list: the mini-player stays put.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(tester.getRect(find.byType(MiniPlayer)).bottom, 600.0);
    });

    testWidgets('mini-player hides on AlbumDetailPage with no current track', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final repo = RealMusicRepository(store: store, database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumDetailPage(
            album: const Album(
              id: 'a1',
              title: 'Midnight City',
              artist: 'Neon Lights',
              year: 2024,
              trackCount: 12,
              serverId: 'srv-a',
            ),
            repo: repo,
            player: player,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // The widget is present but renders zero height when there is
      // no current track.
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(tester.getRect(find.byType(MiniPlayer)).height, 0.0);
      expect(find.text('Exclusion Song'), findsNothing);
    });
  });
}

class _FakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;

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
    _duration.add(const Duration(seconds: 200));
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

class _FakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  Duration? openedStart;
  String? subtitleUrl;
  int pauseCalls = 0;

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
  Object? get videoController => null;

  @override
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    openedUrl = url;
    openedStart = startPosition;
    _duration.add(const Duration(seconds: 7620));
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async => _position.add(position);

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setSubtitleTrack(String? url) async {
    subtitleUrl = url;
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}
