import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/server_selector.dart';
import '../../core/widgets/state_views.dart';
import '../../data/models/download_task.dart';
import '../../data/repositories/download_repository.dart';
import '../../data/repositories/server_store.dart';
import '../servers/servers_page.dart';
import 'download_detail_page.dart';

/// Downloads: one unified queue for qBittorrent + Transmission + aria2.
///
/// Real tasks come from [DownloadRepository] (one native client per
/// downloader server, merged); with no usable downloader the page shows
/// an explicit empty state instead of silently presenting demo data.
/// Progress bars are amber — green is reserved for playback progress.
///
/// A server selector sits at the top: "全部" (all downloaders merged,
/// the default) or one downloader. The selection is per page and
/// persisted in [AppStateStore]; it only ever filters this page — the
/// polling timer and every action-triggered refresh honour it through
/// the repository's [DownloadRepository.serverFilter].
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.repo,
    required this.store,
    required this.settings,
    this.appState,
  });

  final DownloadRepository repo;
  final ServerStore store;
  final SettingsService settings;

  /// Optional global state: the source/status filters are restored
  /// from it on open and saved back on every change.
  final AppStateStore? appState;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadSource? _sourceFilter;
  DownloadStatus? _statusFilter;
  int _pollingInterval = 5;
  bool _hadCredentials = false;

  /// This page's server selection: a server id, or null for "全部".
  /// Restored from [AppStateStore] in initState; [effectiveServerId]
  /// sanitises it against the live usable downloaders.
  String? _serverId;

  /// Usable downloader ids seen at the last store change, so a server
  /// added or removed while this page is open updates the selector.
  Set<String> _knownDownloaderIds = {};

  /// The selection to actually query: null when nothing is selected
  /// or when the selected server no longer exists (deleted) — the
  /// page then falls back to "全部" instead of querying a ghost.
  String? get _effectiveServerId {
    final id = _serverId;
    if (id == null) return null;
    return widget.repo.usableDownloaders.any((s) => s.id == id) ? id : null;
  }

  @override
  void initState() {
    super.initState();
    _pollingInterval = widget.settings.pollingIntervalSeconds;
    _hadCredentials = widget.repo.hasCredentials;
    // Restore the persisted filters (batch 2 global persistence).
    final sourceName = widget.appState?.downloadSourceFilter;
    if (sourceName != null) {
      _sourceFilter = DownloadSource.values
          .where((s) => s.name == sourceName)
          .firstOrNull;
    }
    final statusName = widget.appState?.downloadStatusFilter;
    if (statusName != null) {
      _statusFilter = DownloadStatus.values
          .where((s) => s.name == statusName)
          .firstOrNull;
    }
    // Restore this page's server selection and apply it to the repo
    // before the first refresh, so the first poll already queries
    // only the selected server.
    _serverId = widget.appState?.downloadsServerId;
    _knownDownloaderIds = widget.repo.usableDownloaders
        .map((s) => s.id)
        .toSet();
    widget.repo.serverFilter = _effectiveServerId;
    widget.settings.addListener(_onSettingsChanged);
    widget.store.addListener(_onStoreChanged);
    widget.repo.refresh();
    widget.repo.startPolling(intervalSeconds: _pollingInterval);
  }

  /// The polling interval is a live setting: changing it in Settings
  /// while this page is alive restarts the timer instead of leaving
  /// the old interval running until the next tab switch.
  void _onSettingsChanged() {
    final interval = widget.settings.pollingIntervalSeconds;
    if (interval != _pollingInterval) {
      _pollingInterval = interval;
      widget.repo.startPolling(intervalSeconds: interval);
    }
  }

  /// The store loads asynchronously: when a downloader appears after
  /// this page first built (e.g. the user adds one in Servers), the
  /// queue refreshes instead of staying on the empty state.
  void _onStoreChanged() {
    final now = widget.repo.hasCredentials;
    if (now && !_hadCredentials) {
      widget.repo.refresh();
    }
    _hadCredentials = now;
    // A downloader added or removed while this page is open must
    // update the selector; a deleted selected server falls back to
    // "全部" and the stale persisted value is cleared. The store may
    // also finish loading after initState, so the persisted selection
    // is (re-)applied to the repo whenever the list changes.
    final ids = widget.repo.usableDownloaders.map((s) => s.id).toSet();
    if (ids.length != _knownDownloaderIds.length ||
        !ids.containsAll(_knownDownloaderIds)) {
      _knownDownloaderIds = ids;
      if (_serverId != null && !ids.contains(_serverId)) {
        _serverId = null;
        unawaited(widget.appState?.setDownloadsServerId(null));
      }
      if (mounted) setState(() {});
    }
    final effective = _effectiveServerId;
    if (widget.repo.serverFilter != effective) {
      widget.repo.serverFilter = effective;
      widget.repo.refresh();
    }
  }

  /// Switch this page to one downloader (or null for "全部"). The
  /// polling timer keeps running; it calls refresh(), which honours
  /// the new filter from the next tick.
  void _selectServer(String? id) {
    if (id == _effectiveServerId) return;
    setState(() => _serverId = id);
    unawaited(widget.appState?.setDownloadsServerId(id));
    widget.repo.serverFilter = id;
    widget.repo.refresh();
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    widget.store.removeListener(_onStoreChanged);
    widget.repo.stopPolling();
    // The filter belongs to this page, not the shared repo: if a
    // filter was active, restore the merged queue so Home's
    // active-downloads row is not filtered by a selection made here.
    // Skipped when nothing was filtered — no pointless refresh on
    // every tab switch (and no in-flight request at teardown).
    if (widget.repo.serverFilter != null) {
      widget.repo.serverFilter = null;
      unawaited(widget.repo.refresh());
    }
    super.dispose();
  }

  void _saveFilters() {
    unawaited(
      widget.appState?.setDownloadFilters(
        source: _sourceFilter?.name,
        status: _statusFilter?.name,
      ),
    );
  }

  List<DownloadTask> _filtered(List<DownloadTask> tasks) => tasks
      .where(
        (t) =>
            (_sourceFilter == null || t.source == _sourceFilter) &&
            (_statusFilter == null || t.status == _statusFilter),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo as Listenable,
      builder: (context, _) {
        final tasks = _filtered(widget.repo.tasks);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.repo.hasCredentials)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: ServerSelector(
                  servers: widget.repo.usableDownloaders,
                  selectedId: _effectiveServerId,
                  onSelected: _selectServer,
                  showType: true,
                  onManageServers: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ServersPage(store: widget.store),
                      ),
                    );
                  },
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _chip('All', null, _sourceFilter == null, () {
                    setState(() => _sourceFilter = null);
                    _saveFilters();
                  }),
                  ...DownloadSource.values.map(
                    (s) => _chip(s.label, s, _sourceFilter == s, () {
                      setState(() => _sourceFilter = s);
                      _saveFilters();
                    }),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _statusChip('All', null),
                  _statusChip('Downloading', DownloadStatus.downloading),
                  _statusChip('Completed', DownloadStatus.completed),
                  _statusChip('Paused', DownloadStatus.paused),
                  _statusChip('Failed', DownloadStatus.failed),
                ],
              ),
            ),
            if (widget.repo.errors.isNotEmpty)
              ...widget.repo.errors.values.map(
                (e) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    e,
                    style: const TextStyle(
                      color: YingHuiTheme.errorRed,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: !widget.repo.hasCredentials
                  ? EmptyView(
                      icon: Icons.download_outlined,
                      title: 'No downloader account yet',
                      subtitle: 'Add a qBittorrent, Transmission or aria2 account in Servers to see your real download queue.',
                      actionLabel: 'Open Servers',
                      onAction: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ServersPage(store: widget.store),
                          ),
                        );
                      },
                    )
                  : tasks.isEmpty
                  ? EmptyView(
                      icon: Icons.download_outlined,
                      title: 'No downloads',
                      subtitle: widget.repo.isLoading
                          ? 'Loading…'
                          : 'Tap + to add a magnet link or torrent URL.',
                    )
                  : RefreshIndicator(
                      onRefresh: widget.repo.refresh,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: tasks.length,
                        itemBuilder: (context, i) => _taskCard(tasks[i]),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _taskCard(DownloadTask t) => InkWell(
    borderRadius: BorderRadius.circular(12),
    // Tapping the card opens the detail page; the pause/resume/
    // delete buttons inside still handle their own taps.
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadDetailPage(task: t, repo: widget.repo),
      ),
    ),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Chip(
                  label: Text(
                    t.source.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                t.status.label,
                t.progressText,
                t.speedText,
                t.remainingText,
                t.sizeText,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(
                color: YingHuiTheme.textMuted,
                fontSize: 13,
              ),
            ),
            if (t.savePath.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                t.savePath,
                style: const TextStyle(
                  color: YingHuiTheme.textMuted,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: t.progress,
              color: YingHuiTheme.downloadAmber,
              backgroundColor: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.12),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (t.status == DownloadStatus.failed)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () => widget.repo.retryTask(t),
                    tooltip: 'Retry',
                  ),
                IconButton(
                  icon: Icon(
                    t.status == DownloadStatus.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                    size: 20,
                  ),
                  onPressed: () => t.status == DownloadStatus.paused
                      ? widget.repo.resumeTask(t)
                      : widget.repo.pauseTask(t),
                  tooltip: t.status == DownloadStatus.paused
                      ? 'Resume'
                      : 'Pause',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 20),
                  onPressed: () => _confirmDelete(t),
                  tooltip: 'Delete',
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _confirmDelete(DownloadTask t) async {
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Delete download?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFiles,
                onChanged: (v) => setState(() => deleteFiles = v ?? false),
                title: const Text('Delete downloaded files too'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await widget.repo.deleteTask(t, deleteFiles: deleteFiles);
    }
  }

  Widget _chip(
    String label,
    DownloadSource? source,
    bool selected,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    ),
  );

  Widget _statusChip(String label, DownloadStatus? status) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _statusFilter == status,
      onSelected: (_) {
        setState(() => _statusFilter = status);
        _saveFilters();
      },
    ),
  );
}
