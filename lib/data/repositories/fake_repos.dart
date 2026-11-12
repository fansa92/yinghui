import '../models/download_task.dart';
import '../models/track.dart';
import '../models/video_item.dart';

/// Placeholder data so the UI runs offline with no credentials, like
/// douya's fake repository. Real clients (lib/data/api/) are used only
/// when a server is added and tested.
class FakeMusicRepo {
  static const List<Album> albums = [
    Album(
      id: 'a1',
      title: 'Midnight City',
      artist: 'Neon Lights',
      year: 2024,
      trackCount: 12,
      sourceLabel: 'Demo Navidrome',
    ),
    Album(
      id: 'a2',
      title: 'Blue Hour',
      artist: 'Aurora Field',
      year: 2023,
      trackCount: 9,
      sourceLabel: 'Demo Navidrome',
    ),
    Album(
      id: 'a3',
      title: 'Golden Hour',
      artist: 'Coastline',
      year: 2025,
      trackCount: 10,
      sourceLabel: 'Demo Navidrome',
    ),
    Album(
      id: 'a4',
      title: 'Silent Echo',
      artist: 'Mono No Aware',
      year: 2022,
      trackCount: 8,
      sourceLabel: 'Demo Navidrome',
    ),
    Album(
      id: 'a5',
      title: 'Paper Planes',
      artist: 'Low Orbit',
      year: 2024,
      trackCount: 11,
      sourceLabel: 'Demo Navidrome',
    ),
    Album(
      id: 'a6',
      title: 'Northern Lights',
      artist: 'Fjord',
      year: 2021,
      trackCount: 7,
      sourceLabel: 'Demo Navidrome',
    ),
  ];

  static const List<Track> tracks = [
    Track(
      id: 't1',
      title: 'Midnight Drive',
      artist: 'Neon Lights',
      album: 'Midnight City',
      durationSeconds: 214,
      sourceLabel: 'Demo Navidrome',
    ),
    Track(
      id: 't2',
      title: 'City Lights',
      artist: 'Neon Lights',
      album: 'Midnight City',
      durationSeconds: 187,
      sourceLabel: 'Demo Navidrome',
    ),
    Track(
      id: 't3',
      title: 'Blue Hour',
      artist: 'Aurora Field',
      album: 'Blue Hour',
      durationSeconds: 243,
      sourceLabel: 'Demo Navidrome',
    ),
    Track(
      id: 't4',
      title: 'Golden Hour',
      artist: 'Coastline',
      album: 'Golden Hour',
      durationSeconds: 198,
      sourceLabel: 'Demo Navidrome',
    ),
    Track(
      id: 't5',
      title: 'Silent Echo',
      artist: 'Mono No Aware',
      album: 'Silent Echo',
      durationSeconds: 261,
      sourceLabel: 'Demo Navidrome',
    ),
  ];
}

class FakeVideoRepo {
  static const List<VideoItem> continueWatching = [
    VideoItem(
      id: 'v1',
      title: 'The Last Horizon',
      year: 2024,
      type: 'Movie',
      durationSeconds: 7620,
      progress: 0.62,
      sourceLabel: 'Demo Emby',
    ),
    VideoItem(
      id: 'v2',
      title: 'Harbour Lights',
      year: 2023,
      type: 'Series',
      durationSeconds: 2880,
      progress: 0.35,
      episodeCount: 8,
      sourceLabel: 'Demo Emby',
    ),
    VideoItem(
      id: 'v3',
      title: 'Mountain Pass',
      year: 2025,
      type: 'Movie',
      durationSeconds: 6540,
      progress: 0.18,
      sourceLabel: 'Demo Emby',
    ),
  ];

  static const List<VideoItem> recentlyAdded = [
    VideoItem(
      id: 'v4',
      title: 'The Last Horizon',
      year: 2024,
      type: 'Movie',
      durationSeconds: 7620,
      sourceLabel: 'Demo Emby',
    ),
    VideoItem(
      id: 'v5',
      title: 'Paper Moon',
      year: 2024,
      type: 'Movie',
      durationSeconds: 5940,
      sourceLabel: 'Demo Emby',
    ),
    VideoItem(
      id: 'v6',
      title: 'Harbour Lights',
      year: 2023,
      type: 'Series',
      durationSeconds: 2880,
      episodeCount: 8,
      sourceLabel: 'Demo Emby',
    ),
    VideoItem(
      id: 'v7',
      title: 'Desert Road',
      year: 2022,
      type: 'Movie',
      durationSeconds: 7020,
      sourceLabel: 'Demo Emby',
    ),
  ];
}

class FakeDownloadRepo {
  static final List<DownloadTask> _tasks = [
    const DownloadTask(
      id: 'd1',
      name: 'Ubuntu 24.04 LTS.iso',
      source: DownloadSource.qbittorrent,
      status: DownloadStatus.downloading,
      progress: 0.62,
      speedBytesPerSec: 5242880,
      sizeBytes: 6442450944,
      downloadedBytes: 3995076198,
    ),
    const DownloadTask(
      id: 'd2',
      name: 'Documentary.S01E01.mkv',
      source: DownloadSource.transmission,
      status: DownloadStatus.downloading,
      progress: 0.31,
      speedBytesPerSec: 2097152,
      sizeBytes: 2147483648,
      downloadedBytes: 665719930,
    ),
    const DownloadTask(
      id: 'd3',
      name: 'Album - Midnight City.flac',
      source: DownloadSource.aria2,
      status: DownloadStatus.paused,
      progress: 0.45,
      sizeBytes: 524288000,
      downloadedBytes: 235929600,
    ),
    const DownloadTask(
      id: 'd4',
      name: 'Concert.2024.1080p.mkv',
      source: DownloadSource.qbittorrent,
      status: DownloadStatus.completed,
      progress: 1,
      sizeBytes: 8589934592,
      downloadedBytes: 8589934592,
    ),
  ];

  static List<DownloadTask> tasks({DownloadSource? filter}) => filter == null
      ? List.unmodifiable(_tasks)
      : _tasks.where((t) => t.source == filter).toList();

  static void add(String name, DownloadSource source) {
    _tasks.insert(
      0,
      DownloadTask(
        id: 'd${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        source: source,
        status: DownloadStatus.queued,
      ),
    );
  }
}
