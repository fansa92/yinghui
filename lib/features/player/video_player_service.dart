import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/track.dart';
import '../../data/repositories/playback_store.dart';
import 'playback_coordinator.dart';

/// The small surface the video player needs from a real backend.
///
/// [MediaKitVideoBackend] is the production one (libmpv/FFmpeg via
/// media_kit + media_kit_video); tests inject a fake. The backend is
/// created lazily — only when playback actually starts — so the app
/// boots and widget tests run without touching native libmpv.
abstract class VideoBackend {
  Stream<bool> get playing;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get completed;

  /// True while the backend is stalled waiting for data (buffering).
  /// Drives the centred spinner, NextPlayer-style.
  Stream<bool> get buffering;

  /// The media_kit_video VideoController for the [Video] widget, or
  /// null when the backend has no picture (fake backend in tests).
  Object? get videoController;

  Future<void> open(String url, {Duration startPosition});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// External subtitle track (SRT URL from Emby), or null for Off.
  Future<void> setSubtitleTrack(String? url);
  Future<void> dispose();
}

/// media_kit + media_kit_video backend.
class MediaKitVideoBackend implements VideoBackend {
  MediaKitVideoBackend() {
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
  }

  late final Player _player;
  late final VideoController _controller;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Object? get videoController => _controller;

  @override
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    await _player.open(Media(url));
    if (startPosition > Duration.zero) {
      await _player.seek(startPosition);
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> setSubtitleTrack(String? url) async {
    if (url == null || url.isEmpty) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.uri(url));
    }
  }

  @override
  Future<void> dispose() async {
    await _player.dispose();
  }
}

/// Video playback state: one video at a time (no queue — episodes are
/// opened one by one from the detail page).
///
/// Owns the backend and notifies listeners so the video page stays in
/// sync. Playback history is written through [PlaybackStore] when one
/// is provided: a row on open, resume position on pause/stop. Server
/// progress reporting (Emby) is the page's job — it has the repo.
class VideoPlayerService extends ChangeNotifier implements PausablePlayback {
  VideoPlayerService({
    VideoBackend Function()? backendFactory,
    this.history,
    PlaybackCoordinator? coordinator,
  }) : _backendFactory = backendFactory ?? MediaKitVideoBackend.new,
       _coordinator = coordinator ?? PlaybackCoordinator.instance {
    // Register with the coordinator so starting music pauses video
    // (and vice versa). No page has to pass the coordinator around:
    // both services default to the shared instance.
    _coordinator.registerVideo(this);
  }

  final VideoBackend Function() _backendFactory;
  final PlaybackStore? history;

  /// Mutual-exclusion coordinator (shared instance by default).
  final PlaybackCoordinator _coordinator;

  VideoBackend? _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Track? _track;
  VoidCallback? _onCompleted;
  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _completedFired = false;

  Track? get track => _track;
  bool get hasVideo => _track != null;
  bool get isPlaying => _playing;

  /// True while the backend is stalled waiting for data.
  bool get isBuffering => _buffering;
  Duration get position => _position;
  Duration get duration => _duration;
  Object? get videoController => _backend?.videoController;

  VideoBackend _ensureBackend() {
    final backend = _backend ??= _backendFactory();
    if (_subscriptions.isEmpty) {
      _subscriptions.addAll([
        backend.playing.listen((playing) {
          _playing = playing;
          notifyListeners();
        }),
        backend.position.listen((position) {
          _position = position;
          notifyListeners();
        }),
        backend.duration.listen((duration) {
          _duration = duration;
          notifyListeners();
        }),
        backend.buffering.listen((buffering) {
          _buffering = buffering;
          notifyListeners();
        }),
        backend.completed.listen((completed) {
          if (completed && !_completedFired) {
            _completedFired = true;
            _playing = false;
            notifyListeners();
            _onCompleted?.call();
          }
        }),
      ]);
    }
    return backend;
  }

  /// Open [url] for [track] (used for the Drift history row) and play.
  Future<void> open(
    String url,
    Track track, {
    Duration startPosition = Duration.zero,
    VoidCallback? onCompleted,
  }) async {
    if (url.isEmpty) return;
    _track = track;
    _onCompleted = onCompleted;
    _completedFired = false;
    _duration = track.durationSeconds > 0
        ? Duration(seconds: track.durationSeconds)
        : Duration.zero;
    _position = _clampPosition(startPosition);
    await _ensureBackend().open(url, startPosition: _position);
    await history?.recordStart(track);
    await _coordinator.videoStarted();
    await _ensureBackend().play();
    notifyListeners();
  }

  /// Re-open a different URL for the same track (quality / subtitle
  /// change) at the current position, without resetting history.
  Future<void> reopen(String url, {String? subtitleUrl}) async {
    final track = _track;
    if (track == null || url.isEmpty) return;
    final position = _position;
    await _ensureBackend().open(url, startPosition: position);
    if (subtitleUrl != null) {
      await _ensureBackend().setSubtitleTrack(subtitleUrl);
    }
    await _coordinator.videoStarted();
    await _ensureBackend().play();
    notifyListeners();
  }

  Future<void> setSubtitleTrack(String? url) =>
      _ensureBackend().setSubtitleTrack(url);

  Future<void> togglePlay() async {
    if (!hasVideo) return;
    final backend = _ensureBackend();
    if (_playing) {
      await backend.pause();
      await _savePosition();
    } else {
      await _coordinator.videoStarted();
      await backend.play();
    }
  }

  Future<void> seek(Duration position) async {
    final clamped = _clampPosition(position);
    await _ensureBackend().seek(clamped);
    _position = clamped;
    notifyListeners();
  }

  /// Clamps a seek target to [0, duration] when the duration is known,
  /// so a seek past the end cannot leave a bogus position in the
  /// service state (and in the saved resume position).
  Duration _clampPosition(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    if (_duration > Duration.zero && position > _duration) {
      return _duration;
    }
    return position;
  }

  /// Pause playback without clearing the track or the position, so a
  /// later resume continues where it left off. Used by the
  /// [PlaybackCoordinator] to enforce mutual exclusion with music; it
  /// never notifies the coordinator, so it cannot ping-pong back.
  /// A no-op when no backend was ever opened.
  @override
  Future<void> pause() async {
    final backend = _backend;
    if (backend == null) return;
    await backend.pause();
    _playing = false;
    await _savePosition();
    notifyListeners();
  }

  Future<void> stop() async {
    await _savePosition();
    await _backend?.stop();
    _playing = false;
    notifyListeners();
  }

  Future<void> _savePosition() async {
    final track = _track;
    if (track == null) return;
    await history?.updatePosition(track, _position.inSeconds);
  }

  @override
  void dispose() {
    // Unregister first so the coordinator never holds (or pauses) a
    // disposed service.
    _coordinator.unregisterVideo(this);
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await _backend?.dispose();
  }
}
