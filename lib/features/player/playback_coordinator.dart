import 'package:flutter/foundation.dart';

/// Something the coordinator can pause: music or video playback.
///
/// Implemented by [PlayerService] and [VideoPlayerService] (named here
/// only in docs — this file imports neither, so there is no import
/// cycle). Pause only ever pauses: it never clears a queue/track or a
/// position, and it never notifies the coordinator, so coordination
/// cannot ping-pong back.
abstract class PausablePlayback {
  Future<void> pause();
}

/// Keeps music and video playback mutually exclusive.
///
/// Both player services register with the shared instance (by default —
/// each service takes an optional coordinator and falls back to
/// [PlaybackCoordinator.instance], so no page has to pass anything
/// around) and report when they actually start audible playback. The
/// coordinator then pauses the other side. Pausing keeps the other
/// side's track/queue and position, so resuming continues where it
/// left off.
class PlaybackCoordinator {
  PlaybackCoordinator._();

  static PlaybackCoordinator _shared = PlaybackCoordinator._();

  /// The app-wide coordinator. Services default to this instance.
  static PlaybackCoordinator get instance => _shared;

  /// Test hook: drop the shared instance (and its registrations) so
  /// each test starts with a clean coordinator.
  @visibleForTesting
  static void resetForTest() {
    _shared = PlaybackCoordinator._();
  }

  PausablePlayback? _music;
  PausablePlayback? _video;

  void registerMusic(PausablePlayback music) => _music = music;

  void unregisterMusic(PausablePlayback music) {
    if (identical(_music, music)) _music = null;
  }

  void registerVideo(PausablePlayback video) => _video = video;

  void unregisterVideo(PausablePlayback video) {
    if (identical(_video, video)) _video = null;
  }

  /// Music started audible playback: pause video, if any.
  ///
  /// Deliberately unconditional — pausing an already-paused side is a
  /// harmless no-op, and checking `isPlaying` first would race the
  /// backend's `playing` stream (it may not have delivered yet).
  Future<void> musicStarted() async {
    await _video?.pause();
  }

  /// Video started audible playback: pause music, if any.
  Future<void> videoStarted() async {
    await _music?.pause();
  }
}
