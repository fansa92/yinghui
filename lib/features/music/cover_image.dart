import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Album/track cover. The URL already carries Subsonic auth in its
/// query string (see SubsonicClient.coverArtUrl), so no extra headers
/// are needed. Falls back to a music-note tile when there is no URL or
/// the image fails to load.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.coverUrl,
    this.size = 48,
    this.borderRadius = 12,
    this.iconSize = 24,
    this.fill = false,
  });

  final String? coverUrl;
  final double size;
  final double borderRadius;
  final double iconSize;

  /// When true, fills the parent (e.g. a grid cell) instead of using a
  /// fixed [size].
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final url = coverUrl;
    if (url == null || url.isEmpty) {
      final placeholder = _placeholder();
      return fill ? SizedBox.expand(child: placeholder) : placeholder;
    }
    final image = CachedNetworkImage(
      imageUrl: url,
      width: fill ? null : size,
      height: fill ? null : size,
      fit: BoxFit.cover,
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) => _placeholder(),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: fill ? SizedBox.expand(child: image) : image,
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: YingHuiTheme.primaryGreen.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(
        Icons.music_note,
        size: iconSize,
        color: YingHuiTheme.primaryGreen,
      ),
    );
  }
}
