import 'package:flutter/material.dart';

import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../data/models/track.dart';
import '../../data/repositories/music_repository.dart';
import '../player/mini_player.dart';
import '../player/player_service.dart';
import 'cover_image.dart';

/// Album detail: cover, metadata, Play All, track rows with star toggles.
class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({
    super.key,
    required this.album,
    required this.repo,
    required this.player,
    this.settings,
  });

  final Album album;
  final MusicRepository repo;
  final PlayerService player;

  /// Optional settings, forwarded to the mini-player's full-screen
  /// page so the chosen player style applies there too. When null
  /// the page falls back to the default style.
  final SettingsService? settings;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late Future<({Album album, List<Track> tracks})> _future;

  /// Star state keyed by `serverId:itemId`, seeded from the server's
  /// starred list — a track starred in Navidrome (or on another
  /// device) must not show as unstarred here until it is tapped.
  final Map<String, bool> _starred = {};
  bool _albumStarred = false;

  @override
  void initState() {
    super.initState();
    _future = widget.repo.album(widget.album.id, widget.album.serverId);
    _loadStarred();
  }

  String _starKey(String serverId, String id) => '$serverId:$id';

  Future<void> _loadStarred() async {
    try {
      final starred = await widget.repo.starred();
      if (!mounted) return;
      setState(() {
        for (final t in starred.songs) {
          _starred[_starKey(t.serverId, t.id)] = true;
        }
        _albumStarred = starred.albums.any(
          (a) => a.serverId == widget.album.serverId && a.id == widget.album.id,
        );
      });
    } catch (_) {
      // Star state is best-effort: on failure the tracks stay
      // unstarred rather than breaking the album view.
    }
  }

  Future<void> _toggleStarTrack(Track track) async {
    try {
      final starred = await widget.repo.toggleStarTrack(track);
      if (!mounted) return;
      setState(() => _starred[_starKey(track.serverId, track.id)] = starred);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('收藏失败，请重试。')));
    }
  }

  Future<void> _toggleStarAlbum() async {
    try {
      final starred = await widget.repo.toggleStarAlbum(widget.album);
      if (!mounted) return;
      setState(() => _albumStarred = starred);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('收藏失败，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.album.title)),
      // The mini-player floats above the bottom of this page (same
      // Column pattern as the shell): it stays visible while the
      // track list scrolls, and — unlike the shell's copy — it is not
      // covered when this page is pushed on top. It hides itself when
      // there is no current track. No settings are passed, so the
      // full-screen page opened from here falls back to the default
      // style; the music repo is passed so the Spotify heart works.
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<({Album album, List<Track> tracks})>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '专辑加载失败：\n${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final album = snapshot.data?.album ?? widget.album;
                final tracks = snapshot.data?.tracks ?? const <Track>[];
                return CenteredContent(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CoverImage(
                            coverUrl: album.coverUrl,
                            size: 140,
                            borderRadius: 12,
                            iconSize: 48,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  album.title,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  album.artist,
                                  style: const TextStyle(
                                    color: YingHuiTheme.textSecondary,
                                  ),
                                ),
                                Text(
                                  '${album.year ?? ''} · ${album.trackCount} 首歌',
                                  style: const TextStyle(
                                    color: YingHuiTheme.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  album.sourceLabel,
                                  style: const TextStyle(
                                    color: YingHuiTheme.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: tracks.isEmpty
                                ? null
                                : () => widget.player.playQueue(tracks),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('全部播放'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: _toggleStarAlbum,
                            icon: Icon(
                              _albumStarred
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: YingHuiTheme.primaryGreen,
                            ),
                            label: Text(_albumStarred ? '已收藏' : '收藏'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ...tracks.asMap().entries.map((entry) {
                        final i = entry.key;
                        final t = entry.value;
                        final starred =
                            _starred[_starKey(t.serverId, t.id)] ?? false;
                        return ListTile(
                          leading: Text(
                            '${i + 1}',
                            style: const TextStyle(
                              color: YingHuiTheme.textMuted,
                            ),
                          ),
                          title: Text(t.title),
                          subtitle: Text('${t.artist} · ${t.album}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t.durationText,
                                style: const TextStyle(
                                  color: YingHuiTheme.textMuted,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  starred
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 20,
                                  color: starred
                                      ? YingHuiTheme.primaryGreen
                                      : YingHuiTheme.textMuted,
                                ),
                                onPressed: () => _toggleStarTrack(t),
                              ),
                            ],
                          ),
                          onTap: () =>
                              widget.player.playQueue(tracks, startIndex: i),
                        );
                      }),
                    ],
                  ),
                );
              },
            ),
          ),
          MiniPlayer(
            player: widget.player,
            settings: widget.settings,
            musicRepo: widget.repo,
          ),
        ],
      ),
    );
  }
}
