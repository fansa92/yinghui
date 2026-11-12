import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/errors.dart';
import '../../core/models/server.dart';
import '../api/aria2_client.dart';
import '../api/qbittorrent_client.dart';
import '../api/transmission_client.dart';
import '../db/app_database.dart';
import '../models/download_task.dart';
import 'fake_repos.dart';
import 'server_store.dart';

/// What the Downloads tab needs, regardless of where the data comes from.
abstract class DownloadRepository {
  /// True when at least one downloader server is usable (see
  /// [RealDownloadRepository] for what "usable" means).
  bool get hasCredentials;

  /// Usable downloader servers, for the Add sheet's picker.
  List<Server> get usableDownloaders;

  /// Current unified queue, downloading first, then by progress.
  List<DownloadTask> get tasks;

  /// Per-server errors from the last refresh, keyed by server id.
  Map<String, String> get errors;

  bool get isLoading;

  /// Active (downloading/queued) tasks only, for the Home row.
  List<DownloadTask> get activeTasks;

  /// Aggregate download speed of the active tasks.
  int get totalSpeedBytesPerSec;

  Future<void> refresh();
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  });
  Future<bool> pauseTask(DownloadTask task);
  Future<bool> resumeTask(DownloadTask task);
  Future<bool> deleteTask(DownloadTask task, {bool deleteFiles = false});
  Future<bool> retryTask(DownloadTask task);

  /// Polling while the Downloads page is visible. Call
  /// [stopPolling] on dispose; only one timer ever runs. The
  /// interval comes from Settings (default 5s); calling
  /// [startPolling] again with a new interval restarts the timer.
  void startPolling({int intervalSeconds = 5});
  void stopPolling();
}

/// Real download repository: qBittorrent + Transmission + aria2, merged.
///
/// One native client per usable downloader server. Results are merged
/// into one unified queue (source label + serverId kept per task);
/// a server that is offline throws per-server [ApiException], which is
/// caught here so one dead server never blanks the whole list — its
/// error is exposed in [errors] instead. With no usable downloader the
/// P0 fake repo is the fallback (the Downloads page still shows an
/// explicit empty state instead of silently presenting demo data).
///
/// "Usable" means a downloader server with a username or a token, or a
/// user-added server (id not starting with `seed-`) — the latter covers
/// no-auth Transmission/aria2 servers. The seeded qBittorrent server
/// has empty credentials and a `seed-` id, so it is excluded until the
/// user fills in its login in the app.
///
/// Persistence uses the P1 Drift `download_tasks` table (no new layer):
/// every live task is upserted on refresh, and rows that the servers no
/// longer return are still shown with their last-seen state until the
/// user deletes them in the app.
class RealDownloadRepository extends ChangeNotifier
    implements DownloadRepository {
  RealDownloadRepository({
    required this.store,
    required AppDatabase database,
    QbittorrentClient Function(Server server)? qbFactory,
    TransmissionClient Function(Server server)? transmissionFactory,
    Aria2Client Function(Server server)? ariaFactory,
  }) : _db = database,
       _qbFactory = qbFactory ?? ((s) => QbittorrentClient(s)),
       _transmissionFactory =
           transmissionFactory ?? ((s) => TransmissionClient(s)),
       _ariaFactory = ariaFactory ?? ((s) => Aria2Client(s));

  final ServerStore store;
  final AppDatabase _db;
  final QbittorrentClient Function(Server) _qbFactory;
  final TransmissionClient Function(Server) _transmissionFactory;
  final Aria2Client Function(Server) _ariaFactory;

  /// One native client per downloader server, cached across calls. A
  /// fresh client per call would throw away the qB SID (re-login on
  /// every refresh) and the Transmission session id (a 409 round-trip
  /// on every call). Keyed by server id; rebuilt when the server's
  /// type, host or credentials change.
  final Map<String, (String fingerprint, Object client)> _clientCache = {};

  T _cachedClient<T>(Server server, T Function(Server) factory) {
    final fingerprint =
        '${server.type.name}|${server.host}|${server.username}|${server.token}';
    final cached = _clientCache[server.id];
    if (cached != null && cached.$1 == fingerprint && cached.$2 is T) {
      return cached.$2 as T;
    }
    final client = factory(server);
    _clientCache[server.id] = (fingerprint, client as Object);
    return client;
  }

  void _pruneClientCache() {
    final ids = store.servers.map((s) => s.id).toSet();
    _clientCache.removeWhere((id, _) => !ids.contains(id));
  }

  final List<DownloadTask> _tasks = [];
  final Map<String, String> _errors = {};
  bool _isLoading = false;
  Timer? _timer;

  static bool _isDownloader(ServerType type) =>
      type == ServerType.qbittorrent ||
      type == ServerType.transmission ||
      type == ServerType.aria2;

  List<Server> get _usableDownloaders => store.servers
      .where(
        (s) =>
            _isDownloader(s.type) &&
            (s.username.isNotEmpty ||
                s.token.isNotEmpty ||
                !s.id.startsWith('seed-')),
      )
      .toList();

  @override
  bool get hasCredentials => _usableDownloaders.isNotEmpty;

  @override
  List<Server> get usableDownloaders => List.unmodifiable(_usableDownloaders);

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  Map<String, String> get errors => Map.unmodifiable(_errors);

  @override
  bool get isLoading => _isLoading;

  @override
  List<DownloadTask> get activeTasks => _tasks
      .where(
        (t) =>
            t.status == DownloadStatus.downloading ||
            t.status == DownloadStatus.queued,
      )
      .toList();

  @override
  int get totalSpeedBytesPerSec =>
      activeTasks.fold(0, (sum, t) => sum + t.speedBytesPerSec);

  Server? _serverFor(String serverId) {
    for (final s in store.servers) {
      if (s.id == serverId) return s;
    }
    return null;
  }

  Server? _downloaderForAdd(String? downloaderServerId) {
    if (downloaderServerId != null) {
      final picked = _serverFor(downloaderServerId);
      if (picked != null && _isDownloader(picked.type)) return picked;
    }
    final def = store.defaultServer;
    if (def != null && _usableDownloaders.any((s) => s.id == def.id)) {
      return def;
    }
    return _usableDownloaders.isEmpty ? null : _usableDownloaders.first;
  }

  static int _rank(DownloadStatus status) => switch (status) {
    DownloadStatus.downloading => 0,
    DownloadStatus.queued => 1,
    DownloadStatus.paused => 2,
    DownloadStatus.completed => 3,
    DownloadStatus.failed => 4,
  };

  static List<DownloadTask> sortTasks(List<DownloadTask> tasks) {
    final sorted = [...tasks];
    sorted.sort((a, b) {
      final rank = _rank(a.status).compareTo(_rank(b.status));
      if (rank != 0) return rank;
      return b.progress.compareTo(a.progress);
    });
    return sorted;
  }

  Future<List<DownloadTask>> _fetchFor(Server server) {
    _pruneClientCache();
    return switch (server.type) {
      ServerType.qbittorrent => _cachedClient(
        server,
        _qbFactory,
      ).torrentsInfo(),
      ServerType.transmission => _cachedClient(
        server,
        _transmissionFactory,
      ).torrentGet(),
      ServerType.aria2 => _cachedClient(server, _ariaFactory).tellAll(),
      _ => Future.value(<DownloadTask>[]),
    };
  }

  Future<void> _upsertLive(List<DownloadTask> live) async {
    for (final t in live) {
      await _db
          .into(_db.downloadTasks)
          .insertOnConflictUpdate(
            DownloadTasksCompanion.insert(
              id: t.storageId,
              name: Value(t.name),
              source: Value(t.source.name),
              status: Value(t.status.name),
              progress: Value(t.progress),
              serverId: Value(t.serverId),
            ),
          );
    }
  }

  Future<List<DownloadTask>> _persistedNotLive(Set<String> liveIds) async {
    final rows = await _db.select(_db.downloadTasks).get();
    final out = <DownloadTask>[];
    for (final row in rows) {
      if (liveIds.contains(row.id)) continue;
      final source = DownloadSource.values.firstWhere(
        (s) => s.name == row.source,
        orElse: () => DownloadSource.qbittorrent,
      );
      final status = DownloadStatus.values.firstWhere(
        (s) => s.name == row.status,
        orElse: () => DownloadStatus.queued,
      );
      out.add(
        DownloadTask(
          id: row.id.split(':').skip(1).join(':'),
          name: row.name,
          source: source,
          status: status,
          progress: row.progress,
          serverId: row.serverId,
          sourceInput: row.sourceInput,
        ),
      );
    }
    return out;
  }

  /// Re-attach the persisted original input to live tasks: the
  /// servers never return it, so a plain refresh would otherwise
  /// wipe it from the in-memory list (and from the detail page).
  Future<List<DownloadTask>> _withPersistedInput(
    List<DownloadTask> live,
  ) async {
    try {
      final rows = await _db.select(_db.downloadTasks).get();
      final byId = {for (final r in rows) r.id: r.sourceInput};
      return live
          .map(
            (t) => t.sourceInput.isEmpty && (byId[t.storageId] ?? '').isNotEmpty
                ? t.copyWith(sourceInput: byId[t.storageId])
                : t,
          )
          .toList();
    } catch (e) {
      debugPrint('DownloadRepository persisted-input lookup failed: $e');
      return live;
    }
  }

  /// Persist the original add input for one task (matched by
  /// storage id), so the detail page can show/copy it after restart.
  Future<void> _persistSourceInput(DownloadTask task, String input) async {
    try {
      await _db
          .into(_db.downloadTasks)
          .insertOnConflictUpdate(
            DownloadTasksCompanion.insert(
              id: task.storageId,
              name: Value(task.name),
              source: Value(task.source.name),
              status: Value(task.status.name),
              progress: Value(task.progress),
              serverId: Value(task.serverId),
              sourceInput: Value(input),
            ),
          );
    } catch (e) {
      debugPrint('DownloadRepository source-input persist failed: $e');
    }
  }

  @override
  Future<void> refresh() async {
    // Coalesce overlapping refreshes (timer tick vs an action-triggered
    // refresh): a second call while one is running only schedules one
    // follow-up round instead of interleaving two fetches that clear
    // and rebuild the task list and error map under each other.
    if (_refreshing) {
      _refreshPending = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshPending = false;
        await _refreshOnce();
      } while (_refreshPending);
    } finally {
      _refreshing = false;
    }
  }

  bool _refreshing = false;
  bool _refreshPending = false;

  Future<void> _refreshOnce() async {
    if (!hasCredentials) {
      _tasks
        ..clear()
        ..addAll(FakeDownloadRepo.tasks());
      _errors.clear();
      _isLoading = false;
      notifyListeners();
      return;
    }
    _isLoading = true;
    notifyListeners();
    final live = <DownloadTask>[];
    _errors.clear();
    for (final server in _usableDownloaders) {
      try {
        live.addAll(await _fetchFor(server));
      } on ApiException catch (e) {
        _errors[server.id] = '${server.name}: ${e.message}';
      }
    }
    try {
      await _upsertLive(live);
      final liveIds = live.map((t) => t.storageId).toSet();
      live.addAll(await _persistedNotLive(liveIds));
      // Live tasks never carry sourceInput from the server; restore
      // the persisted value so the detail page keeps working.
      final withInput = await _withPersistedInput(live);
      live
        ..clear()
        ..addAll(withInput);
    } catch (e) {
      debugPrint('DownloadRepository Drift upsert failed: $e');
    }
    _tasks
      ..clear()
      ..addAll(sortTasks(live));
    _isLoading = false;
    notifyListeners();
  }

  /// What [addTask] accepts: a magnet link, an http(s) URL (a
  /// .torrent URL or a direct file URL for aria2), or a bare torrent
  /// hash (40 hex = SHA-1 / info-hash v1, 64 hex = SHA-256 / v2).
  /// Anything else is rejected before any network call — the native
  /// clients would otherwise send the garbage to the server.
  static bool isValidAddInput(String input) {
    final value = input.trim();
    if (value.isEmpty) return false;
    return value.startsWith('magnet:') ||
        value.startsWith('http://') ||
        value.startsWith('https://') ||
        isTorrentHash(value);
  }

  /// Bare torrent hash: exactly 40 or 64 hex chars, nothing else.
  static bool isTorrentHash(String input) {
    final value = input.trim();
    return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(value) ||
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
  }

  /// A bare hash as a magnet URI — what qB's torrents/add (and
  /// Transmission / aria2) actually accept. There is no hash-only
  /// endpoint; the hash is sent as `magnet:?xt=urn:btih:<hash>`.
  static String hashToMagnet(String hash) =>
      'magnet:?xt=urn:btih:${hash.trim().toLowerCase()}';

  /// The value to send to the downloader for [input]: a bare hash
  /// becomes its magnet URI, everything else passes through.
  static String normalizeAddInput(String input) {
    final value = input.trim();
    return isTorrentHash(value) ? hashToMagnet(value) : value;
  }

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async {
    final input = magnetOrUrl.trim();
    if (!isValidAddInput(input)) return false;
    final server = _downloaderForAdd(downloaderServerId);
    if (server == null) return false;
    // A bare hash is sent as a magnet URI (see [hashToMagnet]); the
    // original input is persisted so the detail page can show it.
    final toSend = normalizeAddInput(input);
    try {
      final ok = switch (server.type) {
        ServerType.qbittorrent => await _cachedClient(
          server,
          _qbFactory,
        ).addMagnet(toSend, savePath: savePath),
        ServerType.transmission =>
          await _cachedClient(
                server,
                _transmissionFactory,
              ).torrentAdd(toSend, downloadDir: savePath) !=
              null,
        ServerType.aria2 =>
          await _cachedClient(
                server,
                _ariaFactory,
              ).addUri(toSend, dir: savePath) !=
              null,
        _ => false,
      };
      if (ok) {
        await refresh();
        // Match the newly added task so its original input survives
        // a restart: by hash for magnets/hashes, by save path + name
        // is unreliable, so fall back to nothing when unmatchable.
        final hash = _hashFromInput(input);
        DownloadTask? added;
        if (hash != null) {
          for (final t in _tasks) {
            if (t.serverId == server.id && t.hash.toLowerCase() == hash) {
              added = t;
              break;
            }
          }
        }
        if (added != null) {
          await _persistSourceInput(added, input);
          final i = _tasks.indexWhere((t) => t.storageId == added!.storageId);
          if (i >= 0) {
            _tasks[i] = _tasks[i].copyWith(sourceInput: input);
            notifyListeners();
          }
        }
      }
      return ok;
    } on ApiException catch (e) {
      _errors[server.id] = '${server.name}: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  /// Info-hash from a magnet link or a bare hash; null for http URLs.
  static String? _hashFromInput(String input) {
    final value = input.trim();
    if (isTorrentHash(value)) return value.toLowerCase();
    final m = RegExp(r'xt=urn:btih:([0-9a-fA-F]{40,64})').firstMatch(value);
    return m?[1]?.toLowerCase();
  }

  @override
  Future<bool> pauseTask(DownloadTask task) => _act(task, _pause);

  @override
  Future<bool> resumeTask(DownloadTask task) => _act(task, _resume);

  @override
  Future<bool> retryTask(DownloadTask task) async {
    // Retry is resume for qB/Transmission; for aria2 a failed task can
    // only be re-added, so unpause is the best the API offers.
    return _act(task, _resume);
  }

  Future<bool> _pause(Server server, DownloadTask task) async {
    switch (server.type) {
      case ServerType.qbittorrent:
        return _cachedClient(server, _qbFactory).pause([task.id]);
      case ServerType.transmission:
        final id = int.tryParse(task.id);
        if (id == null) return false;
        await _cachedClient(server, _transmissionFactory).stop([id]);
        return true;
      case ServerType.aria2:
        return _cachedClient(server, _ariaFactory).pause(task.id);
      default:
        return false;
    }
  }

  Future<bool> _resume(Server server, DownloadTask task) async {
    switch (server.type) {
      case ServerType.qbittorrent:
        return _cachedClient(server, _qbFactory).resume([task.id]);
      case ServerType.transmission:
        final id = int.tryParse(task.id);
        if (id == null) return false;
        await _cachedClient(server, _transmissionFactory).start([id]);
        return true;
      case ServerType.aria2:
        return _cachedClient(server, _ariaFactory).unpause(task.id);
      default:
        return false;
    }
  }

  Future<bool> _act(
    DownloadTask task,
    Future<bool> Function(Server server, DownloadTask task) fn,
  ) async {
    final server = _serverFor(task.serverId);
    if (server == null) return false;
    try {
      final ok = await fn(server, task);
      if (ok) await refresh();
      return ok;
    } on ApiException catch (e) {
      _errors[server.id] = '${server.name}: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> deleteTask(DownloadTask task, {bool deleteFiles = false}) async {
    final server = _serverFor(task.serverId);
    if (server == null) return false;
    try {
      // A native delete that reports failure must not be treated as a
      // success: the Drift row stays and no refresh runs, so the task
      // remains visible instead of silently vanishing while the file
      // is still on the server.
      final deleted = switch (server.type) {
        ServerType.qbittorrent => await _cachedClient(
          server,
          _qbFactory,
        ).delete([task.id], deleteFiles: deleteFiles),
        ServerType.transmission => await (() async {
          final id = int.tryParse(task.id);
          if (id == null) return false;
          await _cachedClient(
            server,
            _transmissionFactory,
          ).remove([id], deleteLocalData: deleteFiles);
          return true;
        })(),
        ServerType.aria2 => await (() async {
          final aria = _cachedClient(server, _ariaFactory);
          if (task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed) {
            await aria.rpc('aria2.removeDownloadResult', [task.id]);
            return true;
          }
          return aria.remove(task.id);
        })(),
        _ => false,
      };
      if (!deleted) return false;
      try {
        await (_db.delete(
          _db.downloadTasks,
        )..where((t) => t.id.equals(task.storageId))).go();
      } catch (e) {
        debugPrint('DownloadRepository Drift delete failed: $e');
      }
      await refresh();
      return true;
    } on ApiException catch (e) {
      _errors[server.id] = '${server.name}: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  @override
  void startPolling({int intervalSeconds = 5}) {
    stopPolling();
    _timer = Timer.periodic(Duration(seconds: intervalSeconds.clamp(1, 300)), (
      _,
    ) {
      // Fire-and-forget: errors are recorded in [errors], never thrown.
      unawaited(refresh());
    });
  }

  @override
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
