import '../models/video_detail.dart';

/// Quality picked by the user in the video player.
enum VideoQuality { direct, p1080, p720, p480 }

extension VideoQualityLabel on VideoQuality {
  String get label => switch (this) {
    VideoQuality.direct => 'Direct',
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
/// Rule (documented, conservative by design):
///
/// * Direct play only when the server allows it (`supportsDirectPlay`)
///   AND the container is mp4/m4v/mov AND the video codec is h264 AND
///   the audio codec is aac or mp3. Everything else — mkv, hevc/h265,
///   vp9/av1, dts/truehd/flac audio, or a server that says no — goes
///   through **server-side Emby transcoding** (HLS master.m3u8). There
///   is no local FFmpeg transcoding in P3, per the settled design;
///   libmpv could direct-play more containers, but the Emby contract
///   above is what the server guarantees.
///
/// * A user-picked quality other than Direct always forces transcoding
///   with that quality's bitrate ceiling, even for an otherwise
///   direct-playable file.
///
/// * A selected subtitle is burned into the transcode
///   (SubtitleStreamIndex); for direct play the player loads it as an
///   external track instead (see VideoPlayerService).
class PlaybackDecider {
  static const directContainers = {'mp4', 'm4v', 'mov'};
  static const directVideoCodecs = {'h264'};
  static const directAudioCodecs = {'aac', 'mp3'};

  static PlaybackDecision decide(
    MediaSourceInfo source, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
  }) {
    final videoCodec = (source.videoCodec ?? '').toLowerCase();
    final audioCodec = (source.audioCodec ?? '').toLowerCase();
    final container = source.container.toLowerCase();
    // A file with no audio stream at all (video-only) has no audio
    // codec to check — a missing audio codec alone must not force a
    // transcode. Only when the source actually carries audio streams
    // (or reports an audio codec) does the codec have to be in the
    // direct list. With no stream info and no audio codec the call
    // stays conservative (transcode).
    final hasAudioStream = source.streams.any((s) => s.type == 'Audio');
    final audioOk =
        (source.streams.isNotEmpty && !hasAudioStream) ||
        directAudioCodecs.contains(audioCodec);
    final directPlayable =
        source.supportsDirectPlay &&
        directContainers.contains(container) &&
        directVideoCodecs.contains(videoCodec) &&
        audioOk;

    if (quality != VideoQuality.direct || !directPlayable) {
      return PlaybackDecision(
        kind: PlaybackKind.transcode,
        maxStreamingBitrate: quality.maxStreamingBitrate,
        subtitleStreamIndex: subtitle?.index,
      );
    }
    return PlaybackDecision(
      kind: PlaybackKind.direct,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
    );
  }
}
