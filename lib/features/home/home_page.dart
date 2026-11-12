import 'package:flutter/material.dart';

import '../../core/models/server.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../data/db/app_database.dart';
import '../../data/models/track.dart';
import '../../data/models/video_item.dart';
import '../../data/repositories/download_repository.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/server_store.dart';
import '../../data/repositories/video_repository.dart';
import '../music/album_detail_page.dart';
import '../player/player_service.dart';
import '../video/video_detail_page.dart';

/// Home: search, server status, continue watching/listening,
/// recently added, and a download progress row (amber).
///
/// Everything here is real data from the wired repositories and local
/// playback history. With no servers configured the sections stay
/// empty behind an explicit hint — the old demo library is gone: the
/// home tab must never present fake titles as if they were the user's
/// library.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.downloadRepo,
    required this.musicRepo,
    required this.videoRepo,
    required this.history,
    required this.player,
    required this.settings,
    this.onSearchTap,
  });

  final ServerStore store;
  final DownloadRepository downloadRepo;
  final MusicRepository musicRepo;
  final VideoRepository videoRepo;
  final PlaybackStore history;
  final PlayerService player;
  final SettingsService settings;

  /// Jump to the Music tab's search (the shell owns the tab index).
  final VoidCallback? onSearchTap;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<VideoItem> _continueWatching = [];
  List<Album> _recentAlbums = [];
  List<RecentCategory> _recentVideoCategories = [];
  List<PlaybackHistoryData> _recentHistory = [];
  bool _hadCredentials = false;

  /// Per-section load failures, shown inline instead of a blank
  /// section (a failed fetch must never look like an empty library).
  String? _videoError;
  String? _musicError;

  bool get _hasAnyCredentials =>
      widget.musicRepo.hasCredentials ||
      widget.videoRepo.hasCredentials ||
      widget.downloadRepo.hasCredentials;

  @override
  void initState() {
    super.initState();
    _hadCredentials = _hasAnyCredentials;
    widget.store.addListener(_onStoreChanged);
    _load();
  }

  void _onStoreChanged() {
    final now = _hasAnyCredentials;
    if (now && !_hadCredentials) {
      _load();
    }
    _hadCredentials = now;
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  Future<void> _load() async {
    List<VideoItem> watching = [];
    List<RecentCategory> recentVideoCategories = [];
    List<Album> albums = [];
    List<PlaybackHistoryData> history = [];
    String? videoError;
    String? musicError;
    try {
      if (widget.videoRepo.hasCredentials) {
        watching = await widget.videoRepo.continueWatching();
        recentVideoCategories = await widget.videoRepo
            .recentlyAddedByCategory();
      }
    } catch (e) {
      // The video section failed on every server: keep the error so
      // the section shows it instead of staying blank.
      videoError = '$e';
    }
    try {
      if (widget.musicRepo.hasCredentials) {
        albums = await widget.musicRepo.albums(size: 6);
      }
    } catch (e) {
      musicError = '$e';
    }
    try {
      history = await widget.history.recentHistory(limit: 3);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _continueWatching = watching;
      _recentVideoCategories = recentVideoCategories;
      _recentAlbums = albums;
      _recentHistory = history;
      _videoError = videoError;
      _musicError = musicError;
    });
  }

  void _openVideo(VideoItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailPage(
          item: item,
          repo: widget.videoRepo,
          history: widget.history,
          settings: widget.settings,
        ),
      ),
    );
  }

  void _playHistory(PlaybackHistoryData row) {
    widget.player.playQueue([
      Track(
        id: row.itemId,
        title: row.title,
        artist: '',
        serverId: row.serverId,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: widget.downloadRepo as Listenable,
          builder: (context, _) {
            final downloading = widget.downloadRepo.activeTasks;
            final totalSpeed = widget.downloadRepo.totalSpeedBytesPerSec;
            // The hint is about servers, not about loading: with no
            // credentials nothing is being fetched, so it shows at
            // once. (No loading spinner here: the sections pop in as
            // their loads finish, and a spinner would keep animating
            // if a load ever stalled.)
            final showHint = !_hasAnyCredentials;
            return RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  SearchBar(
                    hintText: '搜索音乐、视频、下载',
                    leading: const Icon(Icons.search),
                    backgroundColor: WidgetStateProperty.all(
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    elevation: WidgetStateProperty.all(0),
                    onTap: widget.onSearchTap,
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('服务器'),
                  SizedBox(
                    height: 44,
                    child: widget.store.servers.isEmpty
                        ? const _ServerChip(
                            label: '还没有服务器——去设置里添加',
                            online: false,
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: widget.store.servers.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) {
                              final s = widget.store.servers[i];
                              return _ServerChip(
                                label: '${s.name} · ${s.type.label}',
                                online: true,
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 16),
                  if (showHint)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '还没有服务器——在设置里添加 Navidrome、Emby 或'
                        '下载器账号，这里就会显示你的媒体库。',
                        style: TextStyle(color: YingHuiTheme.textMuted),
                      ),
                    ),
                  if (downloading.isNotEmpty) ...[
                    _sectionTitle('下载'),
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.download,
                          color: YingHuiTheme.downloadAmber,
                        ),
                        title: Text(downloading.first.name),
                        subtitle: Text(
                          '${downloading.first.progressText} · ${_speedText(totalSpeed)}',
                        ),
                        trailing: Text(
                          '${downloading.length} 个进行中',
                          style: const TextStyle(color: YingHuiTheme.textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Download progress is amber; playback progress is green.
                    LinearProgressIndicator(
                      value: downloading.first.progress,
                      color: YingHuiTheme.downloadAmber,
                      backgroundColor: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.12),
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_videoError != null &&
                      _continueWatching.isEmpty &&
                      _recentVideoCategories.isEmpty) ...[
                    _sectionError('视频加载失败', _videoError!, _load),
                    const SizedBox(height: 16),
                  ],
                  if (_musicError != null && _recentAlbums.isEmpty) ...[
                    _sectionError('音乐加载失败', _musicError!, _load),
                    const SizedBox(height: 16),
                  ],
                  if (_continueWatching.isNotEmpty) ...[
                    _sectionTitle('继续观看'),
                    SizedBox(
                      height: 200,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _continueWatching.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final v = _continueWatching[i];
                          return InkWell(
                            onTap: () => _openVideo(v),
                            child: _PosterCard(
                              title: v.title,
                              progress: v.progress,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_recentHistory.isNotEmpty) ...[
                    _sectionTitle('继续收听'),
                    ..._recentHistory.map(
                      (h) => ListTile(
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: YingHuiTheme.primaryGreen.withValues(
                              alpha: 0.25,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.music_note,
                            color: YingHuiTheme.primaryGreen,
                          ),
                        ),
                        title: Text(h.title),
                        subtitle: Text(
                          h.positionSeconds > 0
                              ? '从 ${_positionText(h.positionSeconds)} 继续'
                              : '最近播放',
                        ),
                        trailing: const Icon(Icons.play_arrow),
                        onTap: () => _playHistory(h),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_recentAlbums.isNotEmpty ||
                      _recentVideoCategories.isNotEmpty) ...[
                    _sectionTitle('最近添加'),
                    if (_recentAlbums.isNotEmpty)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: gridColumnsForWidth(
                            MediaQuery.of(context).size.width,
                          ),
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.85,
                        ),
                        itemCount: _recentAlbums.length,
                        itemBuilder: (context, i) {
                          final a = _recentAlbums[i];
                          return _AlbumCard(
                            title: a.title,
                            subtitle: a.artist,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => AlbumDetailPage(
                                  album: a,
                                  repo: widget.musicRepo,
                                  player: widget.player,
                                  settings: widget.settings,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    for (final category in _recentVideoCategories) ...[
                      // A library name ("电影" / "电视剧") heads its own
                      // row; the single fake category is just "最近添加".
                      if (category.name != '最近添加') ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            category.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                      SizedBox(
                        height: 200,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: category.items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, i) {
                            final v = category.items[i];
                            return SizedBox(
                              width: 140,
                              child: _AlbumCard(
                                title: v.title,
                                subtitle: '${v.year ?? ''} · ${v.typeLabel}'
                                    .trim(),
                                onTap: () => _openVideo(v),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  static String _positionText(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _speedText(int bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
    ),
  );

  /// A failed section, inline with a retry — never a blank section.
  Widget _sectionError(String title, String detail, VoidCallback onRetry) =>
      Card(
        child: ListTile(
          leading: const Icon(
            Icons.error_outline,
            color: YingHuiTheme.errorRed,
          ),
          title: Text(title),
          subtitle: Text(detail),
          trailing: TextButton(onPressed: onRetry, child: const Text('重试')),
        ),
      );
}

class _ServerChip extends StatelessWidget {
  const _ServerChip({required this.label, required this.online});

  final String label;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        Icons.circle,
        size: 10,
        color: online ? YingHuiTheme.primaryGreen : YingHuiTheme.textMuted,
      ),
      label: Text(label),
    );
  }
}

/// 2:3 poster with a green resume-progress bar.
class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.title, required this.progress});

  final String title;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: YingHuiTheme.card,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(
                  Icons.movie,
                  size: 40,
                  color: YingHuiTheme.primaryGreen,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            color: YingHuiTheme.primaryGreen,
            backgroundColor: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.12),
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: YingHuiTheme.primaryGreen.withValues(alpha: 0.2),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.album,
                    size: 48,
                    color: YingHuiTheme.primaryGreen,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: YingHuiTheme.textMuted,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
