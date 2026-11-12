import '../models/video_detail.dart';

/// Quality picked by the user in the video player.
enum VideoQuality { direct, p1080, p720, p480 }

extension VideoQualityLabel on VideoQuality {
  String get label => switch (this) {
    VideoQuality.direct => '直接播放',
    VideoQuality.p1080 => '1080p',
    VideoQuality.p720 => '720p',
    VideoQuality.p480 => '480p',
  };

  /// Server transcode ceiling for this quality; null = no ceiling.
  int? get maxStreamingBitrate => switch (this) {
    VideoQuality.direct => null,
    VideoQuality.p1080 => 8000000,
    VideoQuality.p720 => 4000000,
    VideoQuality.p480 => 1500000,
  };
}

enum PlaybackKind { direct, transcode }

/// The outcome of the direct-play vs transcode decision: which kind of
/// stream to open, with which codecs / bitrate ceiling / subtitle.
class PlaybackDecision {
  const PlaybackDecision({
    required this.kind,
    this.videoCodec = 'h264',
    this.audioCodec = 'aac',
    this.maxStreamingBitrate,
    this.subtitleStreamIndex,
    this.audioStreamIndex,
  });

  final PlaybackKind kind;
  final String videoCodec;
  final String audioCodec;
  final int? maxStreamingBitrate;
  final int? subtitleStreamIndex;
  final int? audioStreamIndex;

  bool get isDirect => kind == PlaybackKind.direct;
}

/// Pure direct-play vs transcode decision, from one Emby media source.
///
/// Rule: direct play whenever the server allows it
/// ([MediaSourceInfo.supportsDirectPlay]) and the user picked Direct
/// quality. This player is libmpv, which plays the containers and
/// codecs Emby serves (mkv, hevc/h265, vp9/av1, dts/truehd, flac…)
/// natively — there is no mp4/h264/aac-only restriction.
///
/// The old rule (direct only for mp4/m4v/mov + h264 + aac/mp3) forced
/// nearly every file through server-side HLS transcoding. On a shared
/// or slow server the transcode takes forever to produce its first
/// segment — or never does (transcoding disabled for the account, no
/// ffmpeg) — and the video never starts, while the direct file would
/// have played immediately. The server's flag stays the gate: when
/// the server says direct play is not supported, transcode.
///
/// * A user-picked quality other than Direct always forces transcoding
///   with that quality's bitrate ceiling, even for an otherwise
///   direct-playable file.
///
/// * A selected subtitle is burned into the transcode
///   (SubtitleStreamIndex); for direct play the player loads it as an
///   external track instead (see VideoPlayerService).
class PlaybackDecider {
  static PlaybackDecision decide(
    MediaSourceInfo source, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
  }) {
    if (quality != VideoQuality.direct || !source.supportsDirectPlay) {
      return PlaybackDecision(
        kind: PlaybackKind.transcode,
        maxStreamingBitrate: quality.maxStreamingBitrate,
        subtitleStreamIndex: subtitle?.index,
      );
    }
    return PlaybackDecision(
      kind: PlaybackKind.direct,
      videoCodec: (source.videoCodec ?? '').toLowerCase(),
      audioCodec: (source.audioCodec ?? '').toLowerCase(),
    );
  }
}
