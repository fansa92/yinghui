/// A download task, unified across qBittorrent, Transmission and aria2.
enum DownloadSource { qbittorrent, transmission, aria2 }

extension DownloadSourceLabel on DownloadSource {
  String get label => switch (this) {
    DownloadSource.qbittorrent => 'qBittorrent',
    DownloadSource.transmission => 'Transmission',
    DownloadSource.aria2 => 'aria2',
  };
}

enum DownloadStatus { queued, downloading, paused, completed, failed }

extension DownloadStatusLabel on DownloadStatus {
  String get label => switch (this) {
    DownloadStatus.queued => '排队中',
    DownloadStatus.downloading => '下载中',
    DownloadStatus.paused => '已暂停',
    DownloadStatus.completed => '已完成',
    DownloadStatus.failed => '失败',
  };
}

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.name,
    required this.source,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.speedBytesPerSec = 0,
    this.sizeBytes = 0,
    this.downloadedBytes = 0,
    this.serverId = '',
    this.etaSeconds = -1,
    this.savePath = '',
    this.hash = '',
    this.sourceInput = '',
    this.files = const [],
  });

  final String id;
  final String name;
  final DownloadSource source;
  final DownloadStatus status;

  /// 0.0–1.0.
  final double progress;
  final int speedBytesPerSec;
  final int sizeBytes;
  final int downloadedBytes;
  final String serverId;

  /// Native ETA in seconds, -1 when the server reports none.
  final int etaSeconds;

  /// Where the downloader is saving this task (may be empty).
  final String savePath;

  /// Native hash (qBittorrent/Transmission) or empty for aria2 (gid is id).
  final String hash;

  /// The exact input the task was added from (magnet link, http(s)
  /// URL, or bare torrent hash), persisted in Drift so the detail page
  /// can show/copy it after a restart. Empty for tasks that predate
  /// the field or came from the server without being added in-app.
  final String sourceInput;

  /// File names inside the download, when a client returns them
  /// (aria2 only so far — qB/Transmission file lists are not fetched).
  final List<String> files;

  /// Magnet URI for this task: the original magnet when the task was
  /// added from one, otherwise reconstructed from the hash.
  /// Empty when neither is known.
  String get magnetUri {
    if (sourceInput.startsWith('magnet:')) return sourceInput;
    if (hash.isNotEmpty) return 'magnet:?xt=urn:btih:$hash';
    final fromInput = RegExp(r'xt=urn:btih:([0-9a-fA-F]{40,64})')
        .firstMatch(sourceInput);
    if (fromInput != null) return 'magnet:?xt=urn:btih:${fromInput[1]}';
    return '';
  }

  /// The original download link (magnet or http URL) when known.
  String get originalLink =>
      sourceInput.startsWith('magnet:') || sourceInput.startsWith('http')
      ? sourceInput
      : '';

  DownloadTask copyWith({
    String? id,
    String? name,
    DownloadSource? source,
    DownloadStatus? status,
    double? progress,
    int? speedBytesPerSec,
    int? sizeBytes,
    int? downloadedBytes,
    String? serverId,
    int? etaSeconds,
    String? savePath,
    String? hash,
    String? sourceInput,
    List<String>? files,
  }) => DownloadTask(
    id: id ?? this.id,
    name: name ?? this.name,
    source: source ?? this.source,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    serverId: serverId ?? this.serverId,
    etaSeconds: etaSeconds ?? this.etaSeconds,
    savePath: savePath ?? this.savePath,
    hash: hash ?? this.hash,
    sourceInput: sourceInput ?? this.sourceInput,
    files: files ?? this.files,
  );

  /// Storage key: serverId + native id, so the same torrent on two
  /// servers is two rows.
  String get storageId => '$serverId:$id';

  String get progressText => '${(progress * 100).toStringAsFixed(0)}%';

  /// qBitController-style progress line: 'downloaded / size (progress%)'.
  /// Falls back to just the percentage when the size is unknown.
  String get progressLineText {
    if (sizeBytes <= 0) return progressText;
    return '$sizeText ($progressText)';
  }

  String get speedText {
    if (speedBytesPerSec <= 0) return '';
    if (speedBytesPerSec >= 1024 * 1024) {
      return '${(speedBytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${(speedBytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }

  String get sizeText {
    String fmt(int bytes) {
      if (bytes >= 1024 * 1024 * 1024) {
        return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
      }
      if (bytes >= 1024 * 1024) {
        return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
      }
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }

    if (sizeBytes <= 0) return '';
    return '${fmt(downloadedBytes)} / ${fmt(sizeBytes)}';
  }

  String get remainingText {
    if (etaSeconds >= 0) {
      final seconds = etaSeconds;
      if (seconds < 60) return '剩余 $seconds秒';
      if (seconds < 3600) return '剩余 ${seconds ~/ 60}分钟';
      return '剩余 ${seconds ~/ 3600}小时${seconds % 3600 ~/ 60}分钟';
    }
    if (speedBytesPerSec <= 0 || sizeBytes <= downloadedBytes) return '';
    final seconds = (sizeBytes - downloadedBytes) ~/ speedBytesPerSec;
    if (seconds < 60) return '剩余 $seconds秒';
    if (seconds < 3600) return '剩余 ${seconds ~/ 60}分钟';
    return '剩余 ${seconds ~/ 3600}小时${seconds % 3600 ~/ 60}分钟';
  }
}
