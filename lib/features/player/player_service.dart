import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:shared_preferences/shared_preferences.dart';

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

/// Repeat behaviour for the music queue.
enum MusicRepeatMode {
  /// Stop at the end of the queue.
  off,

  /// Loop the queue from the start when it ends.
  all,

  /// Repeat the current track.
  one,
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
    SharedPreferences? prefs,
    Random? random,
  }) : _backendFactory = backendFactory ?? MediaKitPlayerBackend.new,
       _coordinator = coordinator ?? PlaybackCoordinator.instance,
       _random = random ?? Random() {
    // Assigned in the body (not an initializing formal) so the
    // parameter keeps its public name for tests.
    _prefs = prefs;
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

  /// Persisted playback modes (shared_preferences; injectable for
  /// tests so a test can share one prefs instance across two
  /// services and prove a mode survives a "restart").
  SharedPreferences? _prefs;

  /// Shuffle randomness (injectable so tests can use a fixed seed).
  final Random _random;

  /// Playback modes, persisted under `yinghui_shuffle_enabled` /
  /// `yinghui_repeat_mode`. Defaults: shuffle off, repeat off.
  static const _kShuffleEnabled = 'yinghui_shuffle_enabled';
  static const _kRepeatMode = 'yinghui_repeat_mode';

  PlayerBackend? _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// The user's queue, in the order they built it. This is what the
  /// Up next list shows and what [AppStateStore] persists — shuffle
  /// never reorders it, so turning shuffle off restores the exact
  /// same queue.
  List<Track> _queue = [];

  /// Playback order: queue indices in the order tracks actually
  /// play. Identity when shuffle is off; a shuffled permutation with
  /// the current track first when shuffle is on. [_index] is always
  /// `_playOrder[_playPos]` while a track is loaded.
  List<int> _playOrder = [];

  /// Position of the current track inside [_playOrder].
  int _playPos = 0;

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

  /// Shuffle / repeat state. Shuffle only changes the playback
  /// order ([_playOrder]); the user's queue ([_queue]) is never
  /// reordered, so turning shuffle off restores the original order.
  bool _shuffle = false;
  MusicRepeatMode _repeat = MusicRepeatMode.off;

  bool get isShuffle => _shuffle;
  MusicRepeatMode get repeatMode => _repeat;

  /// The current playback order, as queue indices. Exposed for
  /// tests so they can assert shuffle permutations without relying
  /// on which track happens to play next.
  @visibleForTesting
  List<int> get playOrder => List.unmodifiable(_playOrder);

  /// The last backend init/open failure, if any. Audio failures used
  /// to be fully silent (no try/catch in [_openCurrent], fire-and-
  /// forget call sites), so a missing native libmpv looked like
  /// "tapping play does nothing". The now-playing page shows this
  /// instead. Cleared by a successful open.
  String? _lastError;
  String? get lastError => _lastError;

  /// Record a backend failure for the UI (and notify, so the error
  /// banner appears immediately).
  void _recordError(Object e) {
    _lastError = '$e';
    notifyListeners();
  }

  /// Playback volume, 0.0 (muted) to 1.0 (full). Defaults to full.
  double get volume => _backend?.volume ?? _volume;
  double _volume = 1.0;

  /// Sets the volume on the backend (creating it if needed) and
  /// keeps it for a later open, so a volume set before the first
  /// play is not lost. A backend-init failure is recorded as
  /// [lastError] instead of throwing into the slider callback.
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    try {
      await _ensureBackend().setVolume(_volume);
    } catch (e) {
      _recordError(e);
    }
    notifyListeners();
  }

  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Load the persisted shuffle / repeat modes. Call once at
  /// startup, before restoring the queue, so a restored session
  /// plays in the saved order. Unknown stored values fall back to
  /// the defaults (shuffle off, repeat off).
  Future<void> loadModes() async {
    final p = await _ensurePrefs();
    _shuffle = p.getBool(_kShuffleEnabled) ?? false;
    _repeat = MusicRepeatMode.values.firstWhere(
      (m) => m.name == p.getString(_kRepeatMode),
      orElse: () => MusicRepeatMode.off,
    );
    notifyListeners();
  }

  Future<void> _saveModes() async {
    final p = await _ensurePrefs();
    await p.setBool(_kShuffleEnabled, _shuffle);
    await p.setString(_kRepeatMode, _repeat.name);
  }

  /// Enable or disable shuffle. Turning it on keeps the current
  /// track playing and shuffles the rest behind it; turning it off
  /// restores the user's original queue order. The queue itself is
  /// never reordered — only [_playOrder] changes.
  Future<void> setShuffle(bool value) async {
    if (value == _shuffle) return;
    _shuffle = value;
    _rebuildPlayOrder();
    await _saveModes();
    notifyListeners();
  }

  Future<void> toggleShuffle() => setShuffle(!_shuffle);

  /// Set the repeat mode (off → all → one → off via [cycleRepeat]).
  Future<void> setRepeat(MusicRepeatMode mode) async {
    if (mode == _repeat) return;
    _repeat = mode;
    await _saveModes();
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    final next = switch (_repeat) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    await setRepeat(next);
  }

  /// Rebuild [_playOrder] from the current queue and shuffle flag.
  /// With shuffle on, the current track (or [firstQueueIndex]) stays
  /// first and the rest are shuffled; with shuffle off the order is
  /// the queue order. [_playPos] is re-pointed at the current track.
  void _rebuildPlayOrder({int? firstQueueIndex}) {
    if (_queue.isEmpty) {
      _playOrder = [];
      _playPos = 0;
      return;
    }
    final first = firstQueueIndex ?? (_index >= 0 ? _index : 0);
    if (!_shuffle) {
      _playOrder = List.generate(_queue.length, (i) => i);
    } else {
      final rest = List<int>.generate(_queue.length, (i) => i)..remove(first);
      rest.shuffle(_random);
      _playOrder = [first, ...rest];
    }
    _playPos = _playOrder.indexOf(_index);
    if (_playPos < 0) _playPos = 0;
  }

  /// Open and play the track at [playPos] in the playback order
  /// (shared by next/previous/jumpTo/playTrack so they cannot drift
  /// apart). Saves the old track's position first.
  Future<void> _playAtPlayPos(int playPos) async {
    _playPos = playPos;
    _index = _playOrder[playPos];
    try {
      if (await _openCurrent()) {
        await _coordinator.musicStarted();
        await _ensureBackend().play();
      }
    } catch (e) {
      _recordError(e);
    }
  }

  /// Insert [track] at [queueIndex] in the user's queue, shifting
  /// the play-order entries that pointed at or past it. When
  /// [afterCurrent] is true the new track is also placed right after
  /// the current position in the play order (play-next); otherwise
  /// it goes at the end of the play order (add-to-queue).
  void _insertTrackAt(
    int queueIndex,
    Track track, {
    required bool afterCurrent,
  }) {
    _queue.insert(queueIndex, track);
    for (var i = 0; i < _playOrder.length; i++) {
      if (_playOrder[i] >= queueIndex) _playOrder[i]++;
    }
    _playOrder.insert(
      afterCurrent ? _playPos + 1 : _playOrder.length,
      queueIndex,
    );
  }

  static bool _sameTrack(Track a, Track b) =>
      a.id == b.id && a.serverId == b.serverId;

  int _indexOf(Track track) => _queue.indexWhere((t) => _sameTrack(t, track));

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
    try {
      await _ensureBackend().open(url);
      _hasOpened = true;
      if (_pendingSeek != null) {
        final target = _clampPosition(_pendingSeek!);
        _pendingSeek = null;
        await _ensureBackend().seek(target);
        _position = target;
      }
      await history?.recordStart(track);
    } catch (e) {
      // Backend init (missing native libmpv) or open failed: record
      // it for the UI instead of throwing into a fire-and-forget
      // caller. _hasOpened stays false so a later retry re-opens.
      _hasOpened = false;
      _recordError(e);
      return false;
    }
    _lastError = null;
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
    _rebuildPlayOrder(firstQueueIndex: _index);
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
  /// the old track in the mini-player. With shuffle on, the start
  /// track plays first and the rest follow in shuffled order.
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) {
      await _savePosition();
      await _backend?.stop();
      _queue = [];
      _playOrder = [];
      _playPos = 0;
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
    _rebuildPlayOrder(firstQueueIndex: _index);
    if (await _openCurrent()) {
      await _coordinator.musicStarted();
      try {
        await _ensureBackend().play();
      } catch (e) {
        _recordError(e);
      }
    }
  }

  /// Play [track] now without throwing away the queue — the
  /// behaviour for tapping a single song anywhere (album track,
  /// search result, starred song):
  ///
  /// - already the current track: just make sure it is playing;
  /// - already in the queue: jump to it (see [jumpTo]);
  /// - otherwise: insert it right after the current track and
  ///   play it. The rest of the queue is untouched.
  ///
  /// Starting a whole new list (an album's 全部播放, a playlist's
  /// 全部播放) still uses [playQueue], which replaces the queue.
  Future<void> playTrack(Track track) async {
    final current = currentTrack;
    if (current != null && _sameTrack(current, track)) {
      if (!_playing) await togglePlay();
      return;
    }
    final existing = _indexOf(track);
    if (existing >= 0) {
      await jumpTo(existing);
      return;
    }
    if (!hasTrack) {
      await playQueue([track]);
      return;
    }
    _insertTrackAt(_index + 1, track, afterCurrent: true);
    await _savePosition();
    await _playAtPlayPos(_playPos + 1);
  }

  /// Jump to the track at [queueIndex] without rebuilding the
  /// queue or the shuffle order (used by the Up next list).
  Future<void> jumpTo(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    final playPos = _playOrder.indexOf(queueIndex);
    if (playPos < 0) return;
    await _savePosition();
    await _playAtPlayPos(playPos);
  }

  /// Insert [track] right after the current track: it plays next,
  /// ahead of the rest of the queue. With no current track it just
  /// starts playing.
  Future<void> playNext(Track track) async {
    if (!hasTrack) {
      await playQueue([track]);
      return;
    }
    _insertTrackAt(_index + 1, track, afterCurrent: true);
    notifyListeners();
  }

  /// Append [track] to the end of the queue. With no current track
  /// it just starts playing.
  Future<void> addToQueue(Track track) async {
    if (!hasTrack) {
      await playQueue([track]);
      return;
    }
    _insertTrackAt(_queue.length, track, afterCurrent: false);
    notifyListeners();
  }

  /// Remove the track at [queueIndex]. Removing the current track
  /// starts the next track in the playback order; removing any
  /// other track leaves playback untouched. Removing the last
  /// track stops playback and clears the queue.
  Future<void> removeAt(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    final removedIsCurrent = queueIndex == _index;
    if (removedIsCurrent) await _savePosition();
    final removedPlayPos = _playOrder.indexOf(queueIndex);
    _queue.removeAt(queueIndex);
    _playOrder.removeAt(removedPlayPos);
    for (var i = 0; i < _playOrder.length; i++) {
      if (_playOrder[i] > queueIndex) _playOrder[i]--;
    }
    if (_queue.isEmpty) {
      await _backend?.stop();
      _index = -1;
      _playPos = 0;
      _playing = false;
      _hasOpened = false;
      _pendingSeek = null;
      _position = Duration.zero;
      notifyListeners();
      return;
    }
    if (removedIsCurrent) {
      if (_playPos >= _playOrder.length) {
        _playPos = _playOrder.length - 1;
      }
      _position = Duration.zero;
      await _playAtPlayPos(_playPos);
    } else {
      if (removedPlayPos < _playPos) _playPos--;
      _index = _playOrder[_playPos];
      notifyListeners();
    }
  }

  /// Move the track at [oldQueueIndex] to [newQueueIndex] in the
  /// user's queue (final positions, after removal). The playback
  /// order follows the move, so the current track keeps playing and
  /// shuffle order is preserved.
  void moveQueue(int oldQueueIndex, int newQueueIndex) {
    if (oldQueueIndex == newQueueIndex) return;
    if (oldQueueIndex < 0 || oldQueueIndex >= _queue.length) return;
    if (newQueueIndex < 0 || newQueueIndex >= _queue.length) return;
    final track = _queue.removeAt(oldQueueIndex);
    _queue.insert(newQueueIndex, track);
    _playOrder = _playOrder.map((i) {
      if (i == oldQueueIndex) return newQueueIndex;
      if (oldQueueIndex < newQueueIndex) {
        if (i > oldQueueIndex && i <= newQueueIndex) return i - 1;
      } else {
        if (i >= newQueueIndex && i < oldQueueIndex) return i + 1;
      }
      return i;
    }).toList();
    _index = _playOrder[_playPos];
    notifyListeners();
  }

  /// Clear the queue down to the current track, which keeps
  /// playing. A no-op with no current track.
  void clearQueue() {
    final current = currentTrack;
    if (current == null) return;
    _queue = [current];
    _playOrder = [0];
    _index = 0;
    _playPos = 0;
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (!hasTrack) return;
    try {
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
    } catch (e) {
      // Backend init failed (missing native libmpv) or play() threw:
      // record it for the UI instead of an unhandled async error.
      _recordError(e);
    }
  }

  Future<void> next() async {
    if (!hasTrack) return;
    if (_repeat == MusicRepeatMode.one) {
      // Repeat-one: restart the current track instead of moving on.
      await seek(Duration.zero);
      if (!_playing) {
        try {
          await _coordinator.musicStarted();
          await _ensureBackend().play();
        } catch (e) {
          _recordError(e);
        }
      }
      return;
    }
    if (_playPos + 1 >= _playOrder.length) {
      if (_repeat == MusicRepeatMode.all && _playOrder.isNotEmpty) {
        // Repeat-all: loop back to the start of the playback order
        // (the shuffled order when shuffle is on).
        await _savePosition();
        await _playAtPlayPos(0);
        return;
      }
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
    await _playAtPlayPos(_playPos + 1);
  }

  Future<void> previous() async {
    if (_position > const Duration(seconds: 3) ||
        _repeat == MusicRepeatMode.one) {
      await seek(Duration.zero);
      return;
    }
    if (_playPos <= 0) {
      if (_repeat == MusicRepeatMode.all && _playOrder.length > 1) {
        // Repeat-all: wrap to the last track in the playback order.
        await _savePosition();
        await _playAtPlayPos(_playOrder.length - 1);
      }
      return;
    }
    await _savePosition();
    await _playAtPlayPos(_playPos - 1);
  }

  Future<void> seek(Duration position) async {
    final clamped = _clampPosition(position);
    try {
      await _ensureBackend().seek(clamped);
    } catch (e) {
      _recordError(e);
      return;
    }
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
