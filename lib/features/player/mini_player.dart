import 'package:flutter/material.dart';

import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../data/repositories/music_repository.dart';
import '../music/cover_image.dart';
import 'now_playing_page.dart';
import 'player_service.dart';

/// Persistent mini-player above the navigation bar/rail.
///
/// P2: drives the real [PlayerService] — play/pause, progress from the
/// backend, tap to open the full-screen now-playing page. Hidden when
/// nothing is playing yet. The mini-player itself is never restyled;
/// the style settings only change the full-screen page, which is
/// passed [settings] and [musicRepo] for that.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.player,
    this.settings,
    this.musicRepo,
  });

  final PlayerService player;

  /// Optional Settings + music repo, forwarded to the full-screen
  /// now-playing page (player style + Spotify heart). When null the
  /// page falls back to the default style with no heart.
  final SettingsService? settings;
  final MusicRepository? musicRepo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = player.currentTrack;
        if (track == null) return const SizedBox.shrink();
        final duration = player.duration.inSeconds > 0
            ? player.duration
            : Duration(seconds: track.durationSeconds);
        final progress = duration.inSeconds > 0
            ? (player.position.inSeconds / duration.inSeconds).clamp(0.0, 1.0)
            : 0.0;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NowPlayingPage(
                    player: player,
                    settings: settings,
                    musicRepo: musicRepo,
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      CoverImage(coverUrl: track.coverUrl, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              track.artist,
                              style: const TextStyle(
                                fontSize: 13,
                                color: YingHuiTheme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          player.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: YingHuiTheme.primaryGreen,
                        ),
                        onPressed: player.togglePlay,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        onPressed: player.next,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Playback progress is green; download progress is amber.
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.12),
                    color: YingHuiTheme.primaryGreen,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 2),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
