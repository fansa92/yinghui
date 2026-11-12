import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A 2:3 movie/series poster. The Emby image URL already carries the
/// api_key query param (see EmbyClient.imageUrl), so no extra headers
/// are needed. Falls back to a movie tile when there is no URL or the
/// image fails to load.
class PosterImage extends StatelessWidget {
  const PosterImage({
    super.key,
    required this.posterUrl,
    this.width = 120,
    this.height = 180,
    this.borderRadius = 12,
  });

  final String? posterUrl;
  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = posterUrl;
    if (url == null || url.isEmpty) return _placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: YingHuiTheme.card,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: const Icon(
        Icons.movie,
        size: 40,
        color: YingHuiTheme.primaryGreen,
      ),
    );
  }
}
