import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/app_state.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/shell/app_shell.dart';

/// Counting music repo: every load records one call per method, so the
/// tests can tell an initial load from a tab-switch reload apart.
class _CountingMusicRepo implements MusicRepository {
  int albumsCalls = 0;
  int artistsCalls = 0;
  int playlistsCalls = 0;
  int starredCalls = 0;
  int searchCalls = 0;

  Album _album() => const Album(
    id: 'a1',
    title: 'Counted Album',
    artist: 'Counted Artist',
    serverId: 'srv-1',
  );

  @override
  bool get hasCredentials => true;

  @override
  Future<List<Album>> albums({
    String type = 'newest',
    int size = 20,
    int offset = 0,
    String? serverId,
  }) async {
    albumsCalls++;
    return [_album()];
  }

  @override
  Future<List<Artist>> artists({String? serverId}) async {
    artistsCalls++;
    return const [Artist(id: 'ar1', name: 'Counted Artist', serverId: 'srv-1')];
  }

  @override
  Future<List<Playlist>> playlists({String? serverId}) async {
    playlistsCalls++;
    return const [];
  }

  @override
  Future<({List<Track> songs, List<Album> albums})> starred({
    String? serverId,
  }) async {
    starredCalls++;
    return (songs: const <Track>[], albums: const <Album>[]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counting video repo: same idea as [_CountingMusicRepo].
class _CountingVideoRepo implements VideoRepository {
  int continueCalls = 0;
  int recentCalls = 0;
  int movieCalls = 0;
  int seriesCalls = 0;

  VideoItem _video() => const VideoItem(
    id: 'v1',
    title: 'Counted Video',
    type: 'Movie',
    year: 2024,
    serverId: 'srv-1',
  );

  @override
  bool get hasCredentials => true;

  @override
  Future<List<VideoItem>> continueWatching({String? serverId}) async {
    continueCalls++;
    return [_video()];
  }

  @override
  Future<List<VideoItem>> recentlyAdded({String? serverId}) async {
    recentCalls++;
    return [_video()];
  }

  @override
  Future<List<VideoItem>> movies({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    movieCalls++;
    return [_video()];
  }

  @override
  Future<List<VideoItem>> series({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    seriesCalls++;
    return [_video()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counting download repo: records refresh/polling calls. The polling
/// timer never actually runs here — startPolling just records the call
/// — so the tests stay deterministic.
class _CountingDownloadRepo extends ChangeNotifier
    implements DownloadRepository {
  int refreshCalls = 0;
  int startPollingCalls = 0;
  int stopPollingCalls = 0;

  @override
  String? serverFilter;

  @override
  bool get hasCredentials => true;

  @override
  List<Server> get usableDownloaders => const [];

  @override
  List<DownloadTask> get tasks => const [
    DownloadTask(
      id: 't1',
      name: 'Counted Task',
      source: DownloadSource.qbittorrent,
      status: DownloadStatus.downloading,
      serverId: 'srv-1',
    ),
  ];

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  List<DownloadTask> get activeTasks => tasks;

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Future<void> refresh() async {
    // Deliberately no notifyListeners: the real repo notifies after
    // its network round-trip, but this fake returns immediately and
    // notifying from a microtask lands inside the build phase.
    // The pages read `tasks` directly on build, so the tests do not
    // need the notification.
    refreshCalls++;
  }

  @override
  void startPolling({int intervalSeconds = 5}) {
    startPollingCalls++;
  }

  @override
  void stopPolling() {
    stopPollingCalls++;
  }

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

void main() {
  group('tab switching never refreshes', () {
    late AppDatabase db;
    late _CountingMusicRepo music;
    late _CountingVideoRepo video;
    late _CountingDownloadRepo downloads;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
      music = _CountingMusicRepo();
      video = _CountingVideoRepo();
      downloads = _CountingDownloadRepo();
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = ServerStore(database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      addTearDown(player.dispose);
      final state = AppStateStore();
      await state.load();
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            settings: SettingsService(),
            store: store,
            musicRepo: music,
            videoRepo: video,
            downloadRepo: downloads,
            history: PlaybackStore(db),
            player: player,
            appState: state,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    // The pages also contain horizontal lists (Home's active-downloads
    // row), so pull-to-refresh drags target the vertical list.
    Finder verticalList() => find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    );

    Future<void> tapTab(WidgetTester tester, String label) async {
      await tester.tap(navLabel(label));
      await tester.pumpAndSettle();
    }

    testWidgets('switching tabs back and forth loads each page once', (
      tester,
    ) async {
      await pumpShell(tester);

      // Home loaded once on startup.
      expect(music.albumsCalls, 1);
      expect(video.continueCalls, 1);
      expect(video.recentCalls, 1);
      expect(downloads.refreshCalls, 0);

      // First visit to Music loads it once.
      await tapTab(tester, '音乐');
      expect(music.albumsCalls, 2);
      expect(music.artistsCalls, 1);
      expect(music.playlistsCalls, 1);
      expect(music.starredCalls, 1);

      // Home and back: no reload anywhere.
      await tapTab(tester, '首页');
      await tapTab(tester, '音乐');
      expect(music.albumsCalls, 2);
      expect(music.artistsCalls, 1);
      expect(video.continueCalls, 1);
      expect(video.recentCalls, 1);

      // First visit to Video loads it once.
      await tapTab(tester, '视频');
      expect(video.continueCalls, 2);
      expect(video.recentCalls, 2);
      expect(video.movieCalls, 1);
      expect(video.seriesCalls, 1);

      // Home and back: no reload.
      await tapTab(tester, '首页');
      await tapTab(tester, '视频');
      expect(video.continueCalls, 2);
      expect(video.recentCalls, 2);
      expect(video.movieCalls, 1);
      expect(video.seriesCalls, 1);
      expect(music.albumsCalls, 2);

      // First visit to Downloads refreshes once and starts polling.
      await tapTab(tester, '下载');
      expect(downloads.refreshCalls, 1);
      expect(downloads.startPollingCalls, 1);

      // Leaving Downloads stops polling but does not refresh (no
      // filter was set, so there is nothing to restore to merged).
      await tapTab(tester, '首页');
      expect(downloads.stopPollingCalls, 1);
      expect(downloads.refreshCalls, 1);

      // Returning to Downloads restarts polling but does NOT refresh
      // immediately — the next poll tick is what reloads.
      await tapTab(tester, '下载');
      expect(downloads.startPollingCalls, 2);
      expect(downloads.refreshCalls, 1);
    });

    testWidgets('pull-to-refresh reloads exactly once per page', (
      tester,
    ) async {
      await pumpShell(tester);

      // Home: pull the list down.
      await tester.drag(verticalList(), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(music.albumsCalls, 2);
      expect(video.continueCalls, 2);
      expect(video.recentCalls, 2);

      // Music: pull the album grid down.
      await tapTab(tester, '音乐');
      expect(music.albumsCalls, 3);
      await tester.drag(find.byType(GridView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(music.albumsCalls, 4);
      expect(music.artistsCalls, 2);
      expect(music.playlistsCalls, 2);
      expect(music.starredCalls, 2);

      // Video: pull the list down.
      await tapTab(tester, '视频');
      expect(video.continueCalls, 3);
      await tester.drag(verticalList(), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(video.continueCalls, 4);
      expect(video.recentCalls, 4);
      expect(video.movieCalls, 2);
      expect(video.seriesCalls, 2);

      // Downloads: pull the task list down (drag the task card
      // itself — the page also has a horizontal list, so a bare
      // ListView finder is ambiguous).
      await tapTab(tester, '下载');
      expect(downloads.refreshCalls, 1);
      await tester.drag(find.text('Counted Task'), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(downloads.refreshCalls, 2);
    });
  });
}
