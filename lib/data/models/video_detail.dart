import 'video_item.dart';

// Detail models for Emby video (P3). These are parsed from the Emby
// native API and kept separate from the list-level VideoItem so list
// parsing stays cheap.

/// A library view, from GET /Users/{userId}/Views.
class LibraryView {
  const LibraryView({
    required this.id,
    required this.name,
    this.collectionType = '',
  });

  final String id;
  final String name;

  /// "movies", "tvshows", "music", ...
  final String collectionType;
}

/// A season of a series, from GET /Shows/{seriesId}/Seasons.
class Season {
  const Season({
    required this.id,
    required this.name,
    this.indexNumber,
    this.episodeCount = 0,
  });

  final String id;
  final String name;
  final int? indexNumber;
  final int episodeCount;
}

/// One subtitle stream, from a MediaStreams entry with Type == Subtitle.
class SubtitleTrackInfo {
  const SubtitleTrackInfo({
    required this.index,
    this.codec = '',
    this.language = '',
    this.displayTitle = '',
    this.isExternal = false,
    this.isForced = false,
    this.isDefault = false,
    this.deliveryUrl,
    this.mediaSourceId,
  });

  /// Stream index within its media source (used as SubtitleStreamIndex).
  final int index;
  final String codec;
  final String language;
  final String displayTitle;
  final bool isExternal;
  final bool isForced;
  final bool isDefault;

  /// Relative DeliveryUrl from the server, if the server gave one.
  final String? deliveryUrl;

  /// The MediaSource this stream belongs to.
  final String? mediaSourceId;

  String get label {
    if (displayTitle.isNotEmpty) return displayTitle;
    if (language.isNotEmpty) return language;
    return 'Subtitle $index';
  }

  SubtitleTrackInfo copyWith({
    int? index,
    String? codec,
    String? language,
    String? displayTitle,
    bool? isExternal,
    bool? isForced,
    bool? isDefault,
    String? deliveryUrl,
    String? mediaSourceId,
  }) => SubtitleTrackInfo(
    index: index ?? this.index,
    codec: codec ?? this.codec,
    language: language ?? this.language,
    displayTitle: displayTitle ?? this.displayTitle,
    isExternal: isExternal ?? this.isExternal,
    isForced: isForced ?? this.isForced,
    isDefault: isDefault ?? this.isDefault,
    deliveryUrl: deliveryUrl ?? this.deliveryUrl,
    mediaSourceId: mediaSourceId ?? this.mediaSourceId,
  );
}

/// One media stream (video / audio / subtitle) inside a media source.
/// Fields the server does not return stay null — callers must show
/// "—" for them, never invent a value.
class MediaStreamInfo {
  const MediaStreamInfo({
    required this.type,
    required this.index,
    this.codec = '',
    this.language = '',
    this.width,
    this.height,
    this.bitRate,
    this.channels,
    this.sampleRate,
    this.frameRate,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.displayTitle = '',
  });

  /// "Video", "Audio" or "Subtitle".
  final String type;
  final int index;
  final String codec;
  final String language;
  final int? width;
  final int? height;
  final int? bitRate;

  /// Audio only: channel count (2 = stereo, 6 = 5.1).
  final int? channels;

  /// Audio only: sample rate in Hz.
  final int? sampleRate;

  /// Video only: frames per second (may be a double, e.g. 23.976).
  final double? frameRate;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;
  final String displayTitle;
}

/// One media source, from POST /Items/{id}/PlaybackInfo.
class MediaSourceInfo {
  const MediaSourceInfo({
    required this.id,
    this.container = '',
    this.videoCodec,
    this.audioCodec,
    this.videoBitRate,
    this.width,
    this.height,
    this.supportsDirectPlay = true,
    this.supportsDirectStream = true,
    this.transcodingUrl,
    this.streams = const [],
  });

  final String id;
  final String container;
  final String? videoCodec;
  final String? audioCodec;
  final int? videoBitRate;
  final int? width;
  final int? height;

  /// False when the server says this source cannot be direct-played.
  final bool supportsDirectPlay;
  final bool supportsDirectStream;

  /// Server-provided transcode URL, if any.
  final String? transcodingUrl;
  final List<MediaStreamInfo> streams;

  List<SubtitleTrackInfo> get subtitles => streams
      .where((s) => s.type == 'Subtitle')
      .map(
        (s) => SubtitleTrackInfo(
          index: s.index,
          codec: s.codec,
          language: s.language,
          displayTitle: s.displayTitle,
          isExternal: s.isExternal,
          isForced: s.isForced,
          isDefault: s.isDefault,
          mediaSourceId: id,
        ),
      )
      .toList();

  List<MediaStreamInfo> get videoStreams =>
      streams.where((s) => s.type == 'Video').toList();
  List<MediaStreamInfo> get audioStreams =>
      streams.where((s) => s.type == 'Audio').toList();
}

/// Full detail for one item: the item itself, its cast, its seasons
/// (series only), and the media sources from PlaybackInfo.
class VideoDetail {
  const VideoDetail({
    required this.item,
    this.seasons = const [],
    this.mediaSources = const [],
    this.subtitleTracks = const [],
  });

  final VideoItem item;
  final List<Season> seasons;
  final List<MediaSourceInfo> mediaSources;

  /// Subtitle tracks from the item's MediaStreams (detail endpoint).
  /// DeliveryUrl entries are kept when the server provides them.
  final List<SubtitleTrackInfo> subtitleTracks;

  /// All subtitle tracks: detail ones first, then any from PlaybackInfo.
  /// Detail tracks carry displayTitle / isExternal / DeliveryUrl but no
  /// media source id — without it the subtitle URL falls back to the
  /// no-source route, so the id is filled in from the media source
  /// whose streams contain this subtitle index.
  List<SubtitleTrackInfo> get allSubtitles {
    if (subtitleTracks.isNotEmpty) {
      return subtitleTracks.map((track) {
        if (track.mediaSourceId != null && track.mediaSourceId!.isNotEmpty) {
          return track;
        }
        return track.copyWith(mediaSourceId: _mediaSourceIdFor(track.index));
      }).toList();
    }
    return [for (final source in mediaSources) ...source.subtitles];
  }

  String? _mediaSourceIdFor(int index) {
    for (final source in mediaSources) {
      if (source.streams.any((s) => s.type == 'Subtitle' && s.index == index)) {
        return source.id;
      }
    }
    return null;
  }

  /// First media source (PlaybackInfo), or null when the server gave
  /// none — the detail page shows "暂无媒体信息" in that case.
  MediaSourceInfo? get primarySource =>
      mediaSources.isEmpty ? null : mediaSources.first;
}

/// A series with its seasons and episodes.
class SeriesDetail {
  const SeriesDetail({
    required this.series,
    this.seasons = const [],
    this.episodes = const [],
  });

  final VideoItem series;
  final List<Season> seasons;

  /// All episodes (type Episode), each carrying seasonId/seasonNumber.
  final List<VideoItem> episodes;

  List<VideoItem> episodesForSeason(String seasonId) =>
      episodes.where((e) => e.seasonId == seasonId).toList();
}
