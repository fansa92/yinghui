import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models/download_task.dart';

/// The state colour of a download's progress bar (qBitController
/// colours its bar by torrent state; the track is the same colour at
/// 38% alpha). Downloading keeps the app's amber — amber is the
/// download colour here, green stays reserved for playback —
/// completed is green, failed is red, queued/paused are muted.
Color downloadStatusColor(DownloadStatus status) => switch (status) {
  DownloadStatus.downloading => YingHuiTheme.downloadAmber,
  DownloadStatus.completed => YingHuiTheme.primaryGreen,
  DownloadStatus.failed => YingHuiTheme.errorRed,
  _ => YingHuiTheme.textMuted,
};

/// qBitController-style progress section, shared by the Downloads
/// list row and the detail page:
///
///   1.3 GB / 1.9 GB (68%)            剩余 3分钟
///   ━━━━━━━━━━ state-coloured bar ━━━━━━━━━━
///   下载中                            ↓ 3.2 MB/s
///
/// The progress line is [DownloadTask.progressLineText]; the ETA
/// (native when the server reports one, otherwise estimated from
/// speed and remaining size) sits right-aligned on the same row;
/// the bottom row shows the state on the left and the download
/// speed on the right (only while it is > 0). Our model carries no
/// upload speed and no ratio, so — unlike qBitController — neither
/// is shown.
class DownloadProgressSection extends StatelessWidget {
  const DownloadProgressSection({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final color = downloadStatusColor(task.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                task.progressLineText,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (task.remainingText.isNotEmpty)
              Text(
                task.remainingText,
                style: const TextStyle(
                  color: YingHuiTheme.textMuted,
                  fontSize: 13,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: task.progress,
          color: color,
          backgroundColor: color.withValues(alpha: 0.38),
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              task.status.label,
              style: const TextStyle(
                color: YingHuiTheme.textMuted,
                fontSize: 13,
              ),
            ),
            if (task.speedText.isNotEmpty)
              Text(
                '↓ ${task.speedText}',
                style: const TextStyle(
                  color: YingHuiTheme.primaryGreen,
                  fontSize: 13,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
