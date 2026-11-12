import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import '../../data/models/track.dart';
import '../../data/repositories/playback_store.dart';
import 'playback_coordinator.dart';

/// The small surface the player needs from a real audio backend.
///
/// [MediaKitPlayerBackend] is the production one (libmpv/FFmpeg via
/// media_kit); tests inject a fake. The backend is created lazily —
/// only when playback actually starts — so the app boots and widget
/// tests run without touching native libmpv.
abstract class PlayerBackend {
  Stream<bool> get playing;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get completed;

  Future<void> open(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();

  /// Playback volume, 0.0 (muted) to 1.0 (full).
  double get volume;
  Future<void> setVolume(double volume);

  Future<void> dispose();
}

/// media_kit backend. `MediaKit.ensureInitialized()` must run before
/// the first [Player] on desktop.
class MediaKitPlayerBackend implements PlayerBackend {
  MediaKitPlayerBackend() {
    MediaKit.ensureInitialized();
    _player = Player();
  }

  late final Player _player;

  /// media_kit's volume is 0–100; the service works in 0.0–1.0.
  /// Kept locally: the backend is created lazily, and the value must
  /// survive a setVolume call made before the first open.
  double _volume = 1.0;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player.setVolume(_volume * 100);
  }

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Future<void> open(String url) => _player.open(Media(url));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    await _player.dispose();
  }
}

/// Queue + now-playing state for audio (P2; video reuses it in P3).
///
/// Owns the queue, drives the backend, and notifies listeners so the
/// mini-player and the now-playing page stay in sync. Playback history
/// is written through [PlaybackStore] when one is provided: a row on
/// track start, resume position on pause/stop.
class PlayerService extends ChangeNotifier implements PausablePlayback {
  PlayerService({
    required this.streamUrlFor,
    PlayerBackend Function()? backendFactory,
    this.history,
    PlaybackCoordinator? coordinator,
  }) : _backendFactory = backendFactory ?? MediaKitPlayerBackend.new,
       _coordinator = coordinator ?? PlaybackCoordinator.instance {
    // Register with the coordinator so starting video pauses music
    // (and vice versa). No page has to pass the coordinator around:
    // both services default to the shared instance.
    _coordinator.registerMusic(this);
  }

  /// Resolves a track to a playable stream URL (Subsonic `streamUrl`
  /// from the music repository, with auth baked into the URL).
  final String Function(Track track) streamUrlFor;

  final PlayerBackend Function() _backendFactory;

  /// Optional history writer (Drift via [PlaybackStore] in the app).
  final PlaybackStore? history;

  /// Mutual-exclusion coordinator (shared instance by default).
  final PlaybackCoordinator _coordinator;

  PlayerBackend? _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  List<Track> _queue = [];
  int _index = -1;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// True once the backend has opened the current track's URL.
  /// A restored session (see [restoreQueue]) has a track but no open
  /// backend yet — [togglePlay] must open it instead of just calling
  /// play() on an empty backend.
  bool _hasOpened = false;

  /// Position to seek to right after the next open: the restored
  /// resume position. [_openCurrent] resets [_position] to zero, so
  /// the seek has to happen after the open, not before it.
  Duration? _pendingSeek;

  /// Guards the `completed` stream: a backend may emit `completed`
  /// twice for one track end, and advancing twice would skip a track.
  /// A per-track flag does not work — the auto-advance to the next
  /// track runs before a stale duplicate arrives, so the flag would
  /// already be reset. Instead, duplicate completions are debounced by
  /// time: a genuine completion of the next track cannot happen within
  /// 2s of the previous one, while a stale duplicate arrives within
  /// milliseconds.
  DateTime? _lastCompletedAt;

  List<Track> get queue => List.unmodifiable(_queue);
  int get currentIndex => _index;
  bool get hasTrack => _index >= 0 && _index < _queue.length;
  Track? get currentTrack => hasTrack ? _queue[_index] : null;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  /// Playback volume, 0.0 (muted) to 1.0 (full). Defaults to full.
  double get volume => _backend?.volume ?? _volume;
  double _volume = 1.0;

  /// Sets the volume on the backend (creating it if needed) and
  /// keeps it for a later open, so a volume set before the first
  /// play is not lost.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _ensureBackend().setVolume(_volume);
    notifyListeners();
  }

  PlayerBackend _ensureBackend() {
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
        backend.completed.listen((completed) {
          if (!completed) return;
          final now = DateTime.now();
          if (_lastCompletedAt != null &&
              now.difference(_lastCompletedAt!) < const Duration(seconds: 2)) {
            return;
          }
          _lastCompletedAt = now;
          unawaited(next());
        }),
      ]);
    }
    return backend;
  }

  Future<bool> _openCurrent() async {
    final track = currentTrack;
    if (track == null) return false;
    final url = streamUrlFor(track);
    if (url.isEmpty) return false;
    _position = Duration.zero;
    _duration = track.durationSeconds > 0
        ? Duration(seconds: track.durationSeconds)
        : Duration.zero;
    await _ensureBackend().open(url);
    _hasOpened = true;
    if (_pendingSeek != null) {
      final target = _clampPosition(_pendingSeek!);
      _pendingSeek = null;
      await _ensureBackend().seek(target);
      _position = target;
    }
    await history?.recordStart(track);
    notifyListeners();
    return true;
  }

  /// Restore a saved session (from [AppStateStore]) without playing:
  /// the mini-player shows the last track and position, and pressing
  /// play opens the stream and seeks to the saved position. Nothing
  /// is opened here, so a restart never starts audio by itself.
  void restoreQueue(
    List<Track> tracks, {
    int index = 0,
    Duration position = Duration.zero,
  }) {
    if (tracks.isEmpty) return;
    _queue = List.of(tracks);
    _index = index.clamp(0, tracks.length - 1);
    _playing = false;
    _hasOpened = false;
    _duration = currentTrack!.durationSeconds > 0
        ? Duration(seconds: currentTrack!.durationSeconds)
        : Duration.zero;
    _position = _clampPosition(position);
    _pendingSeek = _position > Duration.zero ? _position : null;
    notifyListeners();
  }

  /// Replace the queue and start at [startIndex]. An empty queue
  /// clears the current track and stops playback instead of leaving
  /// the old track in the mini-player.
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) {
      await _savePosition();
      await _backend?.stop();
      _queue = [];
      _index = -1;
      _playing = false;
      _hasOpened = false;
      _pendingSeek = null;
      _position = Duration.zero;
      notifyListeners();
      return;
    }
    _queue = List.of(tracks);
    _index = startIndex.clamp(0, tracks.length - 1);
    if (await _openCurrent()) {
      await _coordinator.musicStarted();
      await _ensureBackend().play();
    }
  }

  Future<void> playTrack(Track track) => playQueue([track]);

  Future<void> togglePlay() async {
    if (!hasTrack) return;
    final backend = _ensureBackend();
    if (!_hasOpened) {
      // Restored session (or first play): open the stream first,
      // seeking to the restored position, then play.
      if (await _openCurrent()) {
        await _coordinator.musicStarted();
        await backend.play();
      }
      return;
    }
    if (_playing) {
      await backend.pause();
      await _savePosition();
    } else {
      await _coordinator.musicStarted();
      await backend.play();
    }
  }

  Future<void> next() async {
    if (_index + 1 >= _queue.length) {
      // End of the queue: save the position and stop the backend
      // instead of just flipping the flag — otherwise the backend
      // keeps its completed state and the resume position is lost.
      await _savePosition();
      await _backend?.stop();
      _playing = false;
      notifyListeners();
      return;
    }
    await _savePosition();
    _index++;
    if (await _openCurrent()) {
      await _coordinator.musicStarted();
      await _ensureBackend().play();
    }
  }

  Future<void> previous() async {
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    if (_index <= 0) return;
    await _savePosition();
    _index--;
    if (await _openCurrent()) {
      await _coordinator.musicStarted();
      await _ensureBackend().play();
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

  /// Pause playback without clearing the queue or the position, so a
  /// later resume continues where it left off. Used by the
  /// [PlaybackCoordinator] to enforce mutual exclusion with video; it
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
    _hasOpened = false;
    _pendingSeek = null;
    notifyListeners();
  }

  Future<void> _savePosition() async {
    final track = currentTrack;
    if (track == null) return;
    await history?.updatePosition(track, _position.inSeconds);
  }

  @override
  void dispose() {
    // Unregister first so the coordinator never holds (or pauses) a
    // disposed service.
    _coordinator.unregisterMusic(this);
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
