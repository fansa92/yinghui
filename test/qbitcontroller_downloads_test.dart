import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/core/theme.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/downloads/download_detail_page.dart';
import 'package:yinghui/features/downloads/download_progress.dart';
import 'package:yinghui/features/downloads/downloads_page.dart';

/// qBitController-style Downloads manager (layout pattern only):
/// the list row shows name, source chip, progress line + ETA,
/// a state-coloured bar, and state + speed; the detail page reuses
/// the same progress section on top of centred-title info cards.
/// Multi-server merge, filters, server selector, 5s polling and all
/// actions (pause/resume/delete/retry, copy magnet/hash/link) are
/// unchanged.
void main() {
  group('DownloadTask.progressLineText', () {
    test('combines downloaded / size with the percentage', () {
      const task = DownloadTask(
        id: 't1',
        name: 'Demo.iso',
        source: DownloadSource.qbittorrent,
        status: DownloadStatus.downloading,
        progress: 0.68,
        sizeBytes: 2000000000,
        downloadedBytes: 1360000000,
      );
      expect(task.progressLineText, '1.3 GB / 1.9 GB (68%)');
    });

    test('unknown size falls back to just the percentage', () {
      const task = DownloadTask(
        id: 't1',
        name: 'Demo.iso',
        source: DownloadSource.qbittorrent,
        status: DownloadStatus.downloading,
        progress: 0.45,
      );
      expect(task.progressLineText, '45%');
    });
  });

  group('downloadStatusColor', () {
    test('downloading stays amber, completed green, failed red', () {
      expect(
        downloadStatusColor(DownloadStatus.downloading),
        YingHuiTheme.downloadAmber,
      );
      expect(
        downloadStatusColor(DownloadStatus.completed),
        YingHuiTheme.primaryGreen,
      );
      expect(downloadStatusColor(DownloadStatus.failed), YingHuiTheme.errorRed);
      expect(
        downloadStatusColor(DownloadStatus.paused),
        YingHuiTheme.textMuted,
      );
      expect(
        downloadStatusColor(DownloadStatus.queued),
        YingHuiTheme.textMuted,
      );
    });
  });

  group('DownloadsPage task rows (qBitController-style)', () {
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

    final downloading = DownloadTask(
      id: 'dl1',
      name: 'Demo.iso',
      source: DownloadSource.qbittorrent,
      status: DownloadStatus.downloading,
      progress: 0.68,
      speedBytesPerSec: 3355443,
      sizeBytes: 2000000000,
      downloadedBytes: 1360000000,
      etaSeconds: 207,
      savePath: '/data/downloads',
      hash: 'a' * 40,
      sourceInput: 'magnet:?xt=urn:btih:${'a' * 40}',
    );

    Future<_FakeDownloadRepo> pumpPage(
      WidgetTester tester,
      List<DownloadTask> tasks,
    ) async {
      final repo = _FakeDownloadRepo(tasks);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              repo: repo,
              store: store,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('downloading row: progress line, ETA, state, speed', (
      tester,
    ) async {
      await pumpPage(tester, [downloading]);

      expect(find.text('Demo.iso'), findsOneWidget);
      // The source chip (the source filter chip shows it too).
      expect(find.text('qBittorrent'), findsNWidgets(2));
      // qBitController progress line + right-aligned ETA.
      expect(find.text('1.3 GB / 1.9 GB (68%)'), findsOneWidget);
      expect(find.text('剩余 3分钟'), findsOneWidget);
      // State on the left (the status filter chip shows it too),
      // speed on the right with a down arrow.
      expect(find.text('下载中'), findsNWidgets(2));
      expect(find.text('↓ 3.2 MB/s'), findsOneWidget);
      // The save path left the row (it is still on the detail page).
      expect(find.text('/data/downloads'), findsNothing);
      // One bar, coloured amber for downloading.
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.68);
      expect(bar.color, YingHuiTheme.downloadAmber);
    });

    testWidgets('bar colour follows state: green, muted, red', (tester) async {
      await pumpPage(tester, [
        const DownloadTask(
          id: 'c1',
          name: 'Done.mkv',
          source: DownloadSource.transmission,
          status: DownloadStatus.completed,
          progress: 1.0,
          sizeBytes: 1000000,
          downloadedBytes: 1000000,
        ),
        const DownloadTask(
          id: 'p1',
          name: 'Paused.mkv',
          source: DownloadSource.aria2,
          status: DownloadStatus.paused,
          progress: 0.45,
          sizeBytes: 1000000,
          downloadedBytes: 450000,
        ),
        const DownloadTask(
          id: 'f1',
          name: 'Failed.mkv',
          source: DownloadSource.qbittorrent,
          status: DownloadStatus.failed,
          progress: 0.1,
          sizeBytes: 1000000,
          downloadedBytes: 100000,
        ),
      ]);

      final bars = tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .toList();
      expect(bars.map((b) => b.color), [
        YingHuiTheme.primaryGreen,
        YingHuiTheme.textMuted,
        YingHuiTheme.errorRed,
      ]);
      // A paused task shows no speed; a failed task shows retry.
      expect(find.textContaining('↓'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      // Completed / paused / failed labels appear in the row and
      // in their status filter chip.
      expect(find.text('已完成'), findsNWidgets(2));
      expect(find.text('已暂停'), findsNWidgets(2));
      expect(find.text('失败'), findsNWidgets(2));
    });

    testWidgets('pause button calls the repo; delete asks first', (
      tester,
    ) async {
      final repo = await pumpPage(tester, [downloading]);

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(repo.paused, ['dl1']);

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      expect(find.text('删除这个下载任务？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.deleted, isEmpty);
    });

    testWidgets('tapping a row opens the detail page', (tester) async {
      await pumpPage(tester, [downloading]);

      await tester.tap(find.text('Demo.iso'));
      await tester.pumpAndSettle();
      expect(find.text('任务信息'), findsOneWidget);
      expect(find.text('磁力详情'), findsOneWidget);
    });

    testWidgets('status filter still narrows the list', (tester) async {
      await pumpPage(tester, [
        downloading,
        const DownloadTask(
          id: 'c1',
          name: 'Done.mkv',
          source: DownloadSource.transmission,
          status: DownloadStatus.completed,
          progress: 1.0,
        ),
      ]);

      // The first '已完成' is the status filter chip (the row's
      // label comes after it in the tree).
      await tester.tap(find.text('已完成').first);
      await tester.pumpAndSettle();
      expect(find.text('Done.mkv'), findsOneWidget);
      expect(find.text('Demo.iso'), findsNothing);
    });
  });

  group('DownloadDetailPage (qBitController-style overview)', () {
    testWidgets('progress section on top, no circular indicator', (
      tester,
    ) async {
      final hash40 = 'a' * 40;
      final task = DownloadTask(
        id: 'dl1',
        name: 'Demo.iso',
        source: DownloadSource.qbittorrent,
        status: DownloadStatus.downloading,
        progress: 0.68,
        speedBytesPerSec: 3355443,
        sizeBytes: 2000000000,
        downloadedBytes: 1360000000,
        etaSeconds: 207,
        savePath: '/data/downloads',
        hash: hash40,
        sourceInput: 'magnet:?xt=urn:btih:$hash40',
      );
      final repo = _FakeDownloadRepo([task]);
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadDetailPage(task: task, repo: repo),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1.3 GB / 1.9 GB (68%)'), findsOneWidget);
      expect(find.text('剩余 3分钟'), findsOneWidget);
      expect(find.text('↓ 3.2 MB/s'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Info cards keep their content; the save path is here.
      expect(find.text('任务信息'), findsOneWidget);
      expect(find.text('磁力详情'), findsOneWidget);
      expect(find.text('/data/downloads'), findsOneWidget);
      // Actions still wired: only Pause, not Resume.
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('继续'), findsNothing);

      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(repo.paused, ['dl1']);
    });

    testWidgets('paused task shows Resume only, no magnet section', (
      tester,
    ) async {
      const task = DownloadTask(
        id: 'g1',
        name: 'File.flac',
        source: DownloadSource.aria2,
        status: DownloadStatus.paused,
        progress: 0.45,
      );
      final repo = _FakeDownloadRepo([task]);
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DownloadDetailPage(task: task, repo: repo),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('继续'), findsOneWidget);
      expect(find.text('暂停'), findsNothing);
      expect(find.text('暂无磁力信息'), findsOneWidget);
    });
  });
}

/// Fake download repository with recording action calls.
class _FakeDownloadRepo extends ChangeNotifier implements DownloadRepository {
  _FakeDownloadRepo(this._tasks);

  final List<DownloadTask> _tasks;
  final List<String> paused = [];
  final List<String> resumed = [];
  final List<String> deleted = [];
  final List<String> retried = [];

  @override
  bool get hasCredentials => true;

  @override
  List<Server> get usableDownloaders => const [];

  @override
  String? serverFilter;

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  List<DownloadTask> get activeTasks => _tasks;

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async => false;

  @override
  Future<bool> pauseTask(DownloadTask task) async {
    paused.add(task.id);
    return true;
  }

  @override
  Future<bool> resumeTask(DownloadTask task) async {
    resumed.add(task.id);
    return true;
  }

  @override
  Future<bool> deleteTask(DownloadTask task, {bool deleteFiles = false}) async {
    deleted.add(task.id);
    return true;
  }

  @override
  Future<bool> retryTask(DownloadTask task) async {
    retried.add(task.id);
    return true;
  }

  @override
  bool isAuthBackedOff(String serverId) => false;

  @override
  Future<void> retryLogin(String serverId) async {}

  @override
  void startPolling({int intervalSeconds = 5}) {}

  @override
  void stopPolling() {}
}
