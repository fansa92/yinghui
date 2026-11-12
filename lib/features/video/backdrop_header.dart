import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Full-width backdrop header shared by [VideoDetailPage] and
/// [EpisodeDetailPage].
///
/// The backdrop photo fills the header with a dark gradient over it:
/// a top scrim keeps the back button readable, and the bottom fades to
/// solid [YingHuiTheme.background] so the title, meta line, genre
/// chips and Play / Resume button sit on dark ground in white text.
///
/// The solid background is painted underneath the image, so while the
/// image is loading — or when it fails to load (the server has no
/// Backdrop image for this item, so the constructed URL 404s) — the
/// header degrades to the same layout on a solid background, never a
/// broken-image box.
class BackdropHeader extends StatelessWidget {
  const BackdropHeader({
    super.key,
    required this.backdropUrl,
    required this.title,
    required this.meta,
    required this.playLabel,
    required this.onPlay,
    this.genres = const [],
    this.topInset = 0,
  });

  /// Backdrop image URL. Null or empty means "no image": only the
  /// solid background is painted. Callers with no backdrop at all
  /// should use the poster-row header instead of this widget.
  final String? backdropUrl;

  final String title;
  final String meta;
  final String playLabel;
  final VoidCallback onPlay;

  /// Genre chips, shown between the meta line and the Play button
  /// (video detail only; episodes pass none).
  final List<String> genres;

  /// Space reserved at the top for the status bar + app bar when the
  /// page draws this header behind a transparent app bar.
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final url = backdropUrl;
    return Stack(
      children: [
        // Solid ground first: visible while the image loads and when
        // it fails, so the text never sits on a broken image.
        const Positioned.fill(
          child: ColoredBox(color: YingHuiTheme.background),
        ),
        if (url != null && url.isNotEmpty)
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, _) => const SizedBox.shrink(),
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        // Top scrim for the back button floating over the photo.
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black45, Colors.transparent],
                stops: [0.0, 0.35],
              ),
            ),
          ),
        ),
        // Bottom fade into the page background.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  YingHuiTheme.background.withValues(alpha: 0.72),
                  YingHuiTheme.background,
                ],
                stops: const [0.4, 0.72, 1.0],
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, topInset + 16, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                meta,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
              ),
              if (genres.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: genres.map((g) => Chip(label: Text(g))).toList(),
                ),
              ],
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow),
                label: Text(playLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
