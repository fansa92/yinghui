import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models/track.dart';
import '../../data/repositories/music_repository.dart';
import '../player/player_service.dart';
import 'cover_image.dart';

/// A plain list of tracks — used for playlists and search results.
class TrackListPage extends StatefulWidget {
  const TrackListPage({
    super.key,
    required this.title,
    required this.tracks,
    required this.repo,
    required this.player,
  });

  final String title;
  final List<Track> tracks;
  final MusicRepository repo;
  final PlayerService player;

  @override
  State<TrackListPage> createState() => _TrackListPageState();
}

class _TrackListPageState extends State<TrackListPage> {
  final Map<String, bool> _starred = {};

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.icon(
              onPressed: tracks.isEmpty
                  ? null
                  : () => widget.player.playQueue(tracks),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play All'),
            ),
          ),
          ...tracks.asMap().entries.map((entry) {
            final i = entry.key;
            final t = entry.value;
            final starred = _starred[t.id] ?? false;
            return ListTile(
              leading: CoverImage(coverUrl: t.coverUrl),
              title: Text(t.title),
              subtitle: Text('${t.artist} · ${t.album}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.durationText,
                    style: const TextStyle(color: YingHuiTheme.textMuted),
                  ),
                  IconButton(
                    icon: Icon(
                      starred ? Icons.favorite : Icons.favorite_border,
                      size: 20,
                      color: starred
                          ? YingHuiTheme.primaryGreen
                          : YingHuiTheme.textMuted,
                    ),
                    onPressed: () async {
                      final next = await widget.repo.toggleStarTrack(t);
                      if (mounted) setState(() => _starred[t.id] = next);
                    },
                  ),
                ],
              ),
              onTap: () => widget.player.playQueue(tracks, startIndex: i),
            );
          }),
        ],
      ),
    );
  }
}
