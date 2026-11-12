import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/track.dart';
import '../data/models/video_item.dart';

/// Global app state persisted across restarts (batch 2), on top of
/// what already exists: servers + favourites + history + download
/// tasks live in Drift, settings in [SettingsService]. This store
/// only holds UI/session state in `shared_preferences` (`yinghui_*`
/// keys, documented in README) — never secrets.
///
/// - last selected tab, restored on launch;
/// - last played music track + queue + position (restored into the
///   mini-player on boot, never auto-played);
/// - last played video + position (continue-watching resume);
/// - download list filters (source + status).
class AppStateStore extends ChangeNotifier {
  AppStateStore({this._prefs});

  SharedPreferences? _prefs;

  static const _kLastTab = 'yinghui_last_tab';
  static const _kLastMusic = 'yinghui_last_music';
  static const _kLastVideo = 'yinghui_last_video';
  static const _kDownloadSource = 'yinghui_download_source';
  static const _kDownloadStatus = 'yinghui_download_status';

  int _lastTab = 0;
  SavedMusicState? _lastMusic;
  SavedVideoState? _lastVideo;
  String? _downloadSource;
  String? _downloadStatus;

  /// True once [load] has read the persisted values.
  bool _loaded = false;
  bool get isLoaded => _loaded;

  int get lastTab => _lastTab;
  SavedMusicState? get lastMusic => _lastMusic;
  SavedVideoState? get lastVideo => _lastVideo;
  String? get downloadSourceFilter => _downloadSource;
  String? get downloadStatusFilter => _downloadStatus;

  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _ensurePrefs();
    _lastTab = (p.getInt(_kLastTab) ?? 0).clamp(0, 3);
    final musicJson = p.getString(_kLastMusic);
    _lastMusic = musicJson == null ? null : SavedMusicState.fromJson(musicJson);
    final videoJson = p.getString(_kLastVideo);
    _lastVideo = videoJson == null ? null : SavedVideoState.fromJson(videoJson);
    _downloadSource = p.getString(_kDownloadSource);
    _downloadStatus = p.getString(_kDownloadStatus);
    _loaded = true;
    notifyListeners();
  }

  Future<void> setLastTab(int index) async {
    _lastTab = index.clamp(0, 3);
    final p = await _ensurePrefs();
    await p.setInt(_kLastTab, _lastTab);
    notifyListeners();
  }

  Future<void> saveMusicState(
    List<Track> queue,
    int index,
    Duration position,
  ) async {
    if (queue.isEmpty || index < 0 || index >= queue.length) return;
    _lastMusic = SavedMusicState(
      queue: List.of(queue),
      index: index,
      positionSeconds: position.inSeconds,
    );
    final p = await _ensurePrefs();
    await p.setString(_kLastMusic, _lastMusic!.toJson());
    notifyListeners();
  }

  Future<void> recordLastVideo(VideoItem item, Duration position) async {
    _lastVideo = SavedVideoState(
      id: item.id,
      title: item.title,
      serverId: item.serverId,
      type: item.type,
      positionSeconds: position.inSeconds,
    );
    final p = await _ensurePrefs();
    await p.setString(_kLastVideo, _lastVideo!.toJson());
    notifyListeners();
  }

  Future<void> setDownloadFilters({String? source, String? status}) async {
    _downloadSource = source;
    _downloadStatus = status;
    final p = await _ensurePrefs();
    if (source == null) {
      await p.remove(_kDownloadSource);
    } else {
      await p.setString(_kDownloadSource, source);
    }
    if (status == null) {
      await p.remove(_kDownloadStatus);
    } else {
      await p.setString(_kDownloadStatus, status);
    }
    notifyListeners();
  }
}

/// Saved music session: the queue, the current index, and the
/// position inside the current track.
class SavedMusicState {
  const SavedMusicState({
    required this.queue,
    required this.index,
    required this.positionSeconds,
  });

  final List<Track> queue;
  final int index;
  final int positionSeconds;

  static Map<String, dynamic> _trackJson(Track t) => {
    'id': t.id,
    'title': t.title,
    'artist': t.artist,
    'album': t.album,
    'albumId': t.albumId,
    'durationSeconds': t.durationSeconds,
    'coverUrl': t.coverUrl,
    'serverId': t.serverId,
    'sourceLabel': t.sourceLabel,
  };

  static Track _trackFromJson(Map<String, dynamic> j) => Track(
    id: '${j['id'] ?? ''}',
    title: '${j['title'] ?? ''}',
    artist: '${j['artist'] ?? ''}',
    album: '${j['album'] ?? ''}',
    albumId: '${j['albumId'] ?? ''}',
    durationSeconds: (j['durationSeconds'] as num?)?.toInt() ?? 0,
    coverUrl: j['coverUrl'] as String?,
    serverId: '${j['serverId'] ?? ''}',
    sourceLabel: '${j['sourceLabel'] ?? ''}',
  );

  String toJson() => jsonEncode({
    'queue': queue.map(_trackJson).toList(),
    'index': index,
    'positionSeconds': positionSeconds,
  });

  static SavedMusicState? fromJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final queue = (j['queue'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(_trackFromJson)
          .toList();
      if (queue.isEmpty) return null;
      return SavedMusicState(
        queue: queue,
        index: ((j['index'] as num?)?.toInt() ?? 0).clamp(0, queue.length - 1),
        positionSeconds: (j['positionSeconds'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Saved video session: the last played item + its position.
class SavedVideoState {
  const SavedVideoState({
    required this.id,
    required this.title,
    required this.serverId,
    required this.type,
    required this.positionSeconds,
  });

  final String id;
  final String title;
  final String serverId;
  final String type;
  final int positionSeconds;

  String toJson() => jsonEncode({
    'id': id,
    'title': title,
    'serverId': serverId,
    'type': type,
    'positionSeconds': positionSeconds,
  });

  static SavedVideoState? fromJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final id = '${j['id'] ?? ''}';
      if (id.isEmpty) return null;
      return SavedVideoState(
        id: id,
        title: '${j['title'] ?? ''}',
        serverId: '${j['serverId'] ?? ''}',
        type: '${j['type'] ?? 'Movie'}',
        positionSeconds: (j['positionSeconds'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
