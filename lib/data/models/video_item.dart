/// A movie / series / episode, unified across Emby (and Navidrome has no
/// video, so video items come from Emby servers only).
class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    this.overview = '',
    this.year,
    this.posterUrl,
    this.backdropUrl,
    this.type = 'Movie',
    this.durationSeconds = 0,
    this.episodeCount = 0,

    /// 0.0–1.0 resume position; 0 means not started.
    this.progress = 0,

    /// Resume position in seconds, from UserData.PlaybackPositionTicks.
    this.playbackPositionSeconds = 0,
    this.serverId = '',
    this.sourceLabel = '',

    /// Series / episode linkage (episodes only).
    this.seriesId,
    this.seasonId,
    this.seasonNumber,
    this.episodeNumber,

    /// Detail fields (filled by getItemDetail; empty on list items).
    this.cast = const [],
    this.genres = const [],
  });

  final String id;
  final String title;
  final String overview;
  final int? year;
  final String? posterUrl;
  final String? backdropUrl;

  /// "Movie", "Series" or "Episode".
  final String type;
  final int durationSeconds;
  final int episodeCount;
  final double progress;
  final int playbackPositionSeconds;
  final String serverId;
  final String sourceLabel;
  final String? seriesId;
  final String? seasonId;
  final int? seasonNumber;
  final int? episodeNumber;
  final List<String> cast;
  final List<String> genres;

  String get durationText {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  String get positionText {
    final m = playbackPositionSeconds ~/ 60;
    final s = playbackPositionSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Display label for the server item type ('Movie' / 'Series' /
  /// 'Episode'), shown in list subtitles and the detail header. The raw
  /// [type] stays English — it is also a code value (`type == 'Series'`).
  String get typeLabel => switch (type) {
    'Movie' => '电影',
    'Series' => '剧集',
    'Episode' => '单集',
    _ => type,
  };

  bool get isEpisode => type == 'Episode';

  VideoItem copyWith({
    double? progress,
    int? playbackPositionSeconds,
    List<String>? cast,
    List<String>? genres,
  }) => VideoItem(
    id: id,
    title: title,
    overview: overview,
    year: year,
    posterUrl: posterUrl,
    backdropUrl: backdropUrl,
    type: type,
    durationSeconds: durationSeconds,
    episodeCount: episodeCount,
    progress: progress ?? this.progress,
    playbackPositionSeconds:
        playbackPositionSeconds ?? this.playbackPositionSeconds,
    serverId: serverId,
    sourceLabel: sourceLabel,
    seriesId: seriesId,
    seasonId: seasonId,
    seasonNumber: seasonNumber,
    episodeNumber: episodeNumber,
    cast: cast ?? this.cast,
    genres: genres ?? this.genres,
  );
}
