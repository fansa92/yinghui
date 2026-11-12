import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../data/models/download_task.dart';
import '../../data/repositories/download_repository.dart';

/// Download detail page (batch 2), opened by tapping a task card.
///
/// Layout follows the download-detail mockup (amber circular progress,
/// speed, remaining time, downloaded/total, source, save path, file
/// list, pause/resume/delete) — except the mockup wrongly shows both
/// Pause and Resume at once; here only one appears, depending on
/// status. Plus magnet details: magnet URI (reconstructed from the
/// hash when only the hash is known), the full hash, and the original
/// download link, each with a copy button when the value exists.
class DownloadDetailPage extends StatelessWidget {
  const DownloadDetailPage({super.key, required this.task, required this.repo});

  final DownloadTask task;
  final DownloadRepository repo;

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label 已复制')));
    }
  }

  Future<void> _confirmDelete(BuildContext context, DownloadTask t) async {
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('删除这个下载任务？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFiles,
                onChanged: (v) => setState(() => deleteFiles = v ?? false),
                title: const Text('同时删除下载的文件'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      final ok = await repo.deleteTask(t, deleteFiles: deleteFiles);
      if (ok && context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(task.name)),
      // The repo is a ChangeNotifier: the live task (progress, speed,
      // status) updates in place; fall back to the tapped snapshot
      // when the task has vanished from the queue.
      body: ListenableBuilder(
        listenable: repo as Listenable,
        builder: (context, _) {
          final live = repo.tasks.where((t) => t.storageId == task.storageId);
          final t = live.isEmpty ? task : live.first;
          return CenteredContent(child: _detailView(context, t));
        },
      ),
    );
  }

  Widget _detailView(BuildContext context, DownloadTask t) {
    final magnet = t.magnetUri;
    final link = t.originalLink;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                SizedBox(
                  width: 140,
                  height: 140,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: t.progress,
                          strokeWidth: 10,
                          color: YingHuiTheme.downloadAmber,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.12),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            t.progressText,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            t.status.label,
                            style: const TextStyle(
                              color: YingHuiTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _stat('速度', t.speedText.isEmpty ? '—' : t.speedText),
                    _stat(
                      '剩余时间',
                      t.remainingText.isEmpty ? '—' : t.remainingText,
                    ),
                    _stat('已下载 / 总大小', t.sizeText.isEmpty ? '—' : t.sizeText),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ResponsiveTwoColumn(
          first: _SectionCard(
            title: '任务信息',
            child: Column(
              children: [
                _infoRow('来源', t.source.label),
                _infoRow('状态', t.status.label),
                _infoRow('保存路径', t.savePath),
                _infoRow('服务器', t.serverId),
              ],
            ),
          ),
          second: _SectionCard(
            title: '磁力详情',
            child: magnet.isEmpty && t.hash.isEmpty && link.isEmpty
                ? const Text(
                    '暂无磁力信息',
                    style: TextStyle(color: YingHuiTheme.textMuted),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (magnet.isNotEmpty)
                        _copyableRow(
                          context,
                          label: '磁力链接',
                          value: magnet,
                          onCopy: () => _copy(context, '磁力链接', magnet),
                        ),
                      if (t.hash.isNotEmpty)
                        _copyableRow(
                          context,
                          label: '哈希',
                          value: t.hash,
                          monospace: true,
                          onCopy: () => _copy(context, '哈希', t.hash),
                        ),
                      if (link.isNotEmpty && link != magnet)
                        _copyableRow(
                          context,
                          label: '下载链接',
                          value: link,
                          onCopy: () => _copy(context, '下载链接', link),
                        ),
                    ],
                  ),
          ),
        ),
        if (t.files.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: '文件 · ${t.files.length}',
            child: Column(
              children: t.files
                  .map(
                    (f) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(
                        f,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            if (t.status == DownloadStatus.failed)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => repo.retryTask(t),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ),
            if (t.status == DownloadStatus.failed) const SizedBox(width: 12),
            // Only one of Pause / Resume, depending on status.
            Expanded(
              child: FilledButton.icon(
                onPressed: () => t.status == DownloadStatus.paused
                    ? repo.resumeTask(t)
                    : repo.pauseTask(t),
                icon: Icon(
                  t.status == DownloadStatus.paused
                      ? Icons.play_arrow
                      : Icons.pause,
                ),
                label: Text(t.status == DownloadStatus.paused ? '继续' : '暂停'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(context, t),
                icon: const Icon(Icons.delete),
                label: const Text('删除'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _stat(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: YingHuiTheme.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  static Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(color: YingHuiTheme.textMuted),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );

  Widget _copyableRow(
    BuildContext context, {
    required String label,
    required String value,
    bool monospace = false,
    required VoidCallback onCopy,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(color: YingHuiTheme.textMuted)),
            const Spacer(),
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: monospace
              ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
              : const TextStyle(fontSize: 13),
        ),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
