import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_state.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../data/models/track.dart';
import '../../data/models/video_detail.dart';
import '../../data/models/video_item.dart';
import '../../data/repositories/playback_decision.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/video_repository.dart';
import 'video_player_service.dart';

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = h > 0 ? '$h:${m.toString().padLeft(2, '0')}' : '$m';
  return '$mm:${s.toString().padLeft(2, '0')}';
}

/// Full-screen video player (P3).
///
/// Opens with the direct-play vs transcode decision from the repo,
/// resumes from the Emby resume position, and reports progress back to
/// Emby + Drift on pause/stop/dispose, marking the item played on
/// completion. Controls auto-hide 3s after the last tap while playing
/// and stay visible while paused. Subtitle and quality pickers re-open
/// the stream at the current position.
///
/// Desktop keyboard shortcuts (physical keyboard only, so harmless
/// on mobile): Space play/pause, ←/→ seek 10s (the same seek logic
/// as the Apple TV ±10s buttons), F fullscreen toggle, Esc exit
/// fullscreen or close the player. The first time the controls are
/// shown on a wide screen in a session, a dismissible shortcuts
/// hint appears in the controls overlay. No mouse double-click seek.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.item,
    required this.repo,
    required this.history,
    this.subtitles = const [],
    this.mediaSources = const [],
    this.service,
    this.settings,
    this.appState,
    this.nextEpisode,
    this.onPlayNextEpisode,
  });

  final VideoItem item;
  final VideoRepository repo;
  final PlaybackStore history;

  /// Subtitle tracks from the item detail (may be empty).
  final List<SubtitleTrackInfo> subtitles;

  /// Media sources already probed by the detail page (may be empty).
  /// When non-empty the player re-uses them instead of probing
  /// PlaybackInfo again before opening — the probe is the slowest
  /// step on the tap-to-first-frame path.
  final List<MediaSourceInfo> mediaSources;

  final VideoPlayerService? service;

  /// Optional Settings (P5): default quality, subtitle on/off and
  /// resume. When null the old defaults apply (Direct, subtitles off,
  /// resume on) so existing tests keep passing unchanged.
  final SettingsService? settings;

  /// Optional global state: the last played video + position are
  /// recorded here on dispose so they survive a restart.
  final AppStateStore? appState;

  /// The next episode in the same season, when known (series only,
  /// from the detail page). Drives the Netflix Next Episode button
  /// and the Apple TV Up Next card; null for movies and for episodes
  /// opened without series context.
  final VideoItem? nextEpisode;

  /// Called when the user picks the next episode (button or Up Next
  /// autoplay). The detail page pops this player and opens the next
  /// episode. When null, no next-episode UI is shown.
  final void Function(VideoItem episode)? onPlayNextEpisode;

  /// Test-only reset for the once-per-session shortcuts hint flag.
  static void resetShortcutsHintForTest() {
    _VideoPlayerPageState.resetShortcutsHintForTest();
  }

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final VideoPlayerService _service;
  bool _ownsService = false;

  /// Keyboard focus for the desktop shortcuts; autofocus when the
  /// page opens, released on dispose.
  final FocusNode _focusNode = FocusNode();

  /// Shortcuts hint: shown once per session, the first time the
  /// controls are shown on a wide screen. Static, so it survives
  /// opening a second video in the same run.
  static bool _shortcutsHintShown = false;
  bool _showShortcutsHint = false;

  /// Test-only reset for the once-per-session hint flag.
  static void resetShortcutsHintForTest() {
    _shortcutsHintShown = false;
  }

  bool _loading = true;
  String? _error;
  bool _controlsVisible = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  /// Time chip mode: elapsed vs remaining (NextPlayer toggles the
  /// time display on tap).
  bool _showRemainingTime = false;

  /// Double-tap seek feedback ("−10秒 · 12:34"), cleared ~1s after
  /// the last double-tap — NextPlayer's centre seek indicator.
  String? _seekIndicatorText;
  Timer? _seekIndicatorTimer;

  /// How long the player open may take before the page stops
  /// spinning and shows the error with retry. Opening only issues
  /// the load command to libmpv, so 30s is generous.
  static const _openTimeout = Duration(seconds: 30);

  PlaybackDecision? _decision;
  VideoQuality _quality = VideoQuality.direct;
  SubtitleTrackInfo? _subtitle;

  /// Apple TV Up Next card, shown when playback finishes and a next
  /// episode is known. Counts down from 10s, then auto-plays.
  bool _showUpNext = false;
  int _upNextSecondsLeft = 10;
  Timer? _upNextTimer;

  VideoPlayerStyle get _style =>
      widget.settings?.videoPlayerStyle ?? VideoPlayerStyle.standard;

  /// Control accent: green in the default style, Netflix red in the
  /// Netflix style, white in the Apple TV style.
  Color get _accent => switch (_style) {
    VideoPlayerStyle.standard => YingHuiTheme.primaryGreen,
    VideoPlayerStyle.netflix => const Color(0xFFE50914),
    VideoPlayerStyle.appleTv => Colors.white,
  };

  bool get _hasNext =>
      widget.nextEpisode != null && widget.onPlayNextEpisode != null;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? VideoPlayerService(history: widget.history);
    _ownsService = widget.service == null;
    // P5 defaults from Settings: quality, subtitles on/off, resume.
    _quality = widget.settings?.effectiveVideoQuality ?? VideoQuality.direct;
    if (widget.settings?.subtitlesEnabled == true &&
        widget.subtitles.isNotEmpty) {
      _subtitle = widget.subtitles.first;
    }
    _open();
  }

  Future<void> _open({bool keepPosition = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.repo.decidePlayback(
        widget.item,
        quality: _quality,
        subtitle: _subtitle,
        sources: widget.mediaSources.isEmpty ? null : widget.mediaSources,
      );
      if (!mounted) return;
      _decision = result.decision;
      final resume = widget.settings?.resumePlayback ?? true;
      // A re-open (quality / transcode subtitle change) resumes from
      // where playback actually is, not from the stored resume point
      // the item was opened with — otherwise changing quality mid-film
      // jumps back to the start of the session.
      final startPosition = keepPosition && _service.hasVideo
          ? _service.position
          : (resume
                ? Duration(seconds: widget.item.playbackPositionSeconds)
                : Duration.zero);
      // Player.open only issues the load command to libmpv — it does
      // not wait for the first frame — so it should return in seconds.
      // If it does not (backend stuck, stream never accepted), stop
      // spinning and show the error instead of loading forever.
      await _service
          .open(
            result.url,
            _trackFor(widget.item),
            startPosition: startPosition,
            onCompleted: _onCompleted,
          )
          .timeout(
            _openTimeout,
            onTimeout: () {
              throw TimeoutException('打开视频超时', _openTimeout);
            },
          );
      if (!mounted) return;
      // Direct play: the initial / default subtitle is an external
      // track and is only applied by setSubtitleTrack — deciding alone
      // does not load it, so it would silently never appear.
      if (result.decision.isDirect && _subtitle != null) {
        await _service.setSubtitleTrack(
          widget.repo.subtitleUrlFor(widget.item, _subtitle!),
        );
      }
      if (!mounted) return;
      setState(() => _loading = false);
      // Tell Emby playback started (creates the server session and
      // the resume entry). Best effort — the repo swallows failures.
      unawaited(
        widget.repo.reportPlaybackStarted(
          widget.item,
          playMethod: result.decision.isDirect ? 'DirectPlay' : 'Transcode',
        ),
      );
      _scheduleHide();
      _maybeShowShortcutsHint();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A timeout is a hang, not a detail: show a short message
        // instead of the raw TimeoutException dump.
        _error = e is TimeoutException ? '打开视频超时，请检查网络后重试。' : '$e';
      });
    }
  }

  Track _trackFor(VideoItem item) => Track(
    id: item.id,
    title: item.title,
    artist: item.sourceLabel,
    durationSeconds: item.durationSeconds,
    serverId: item.serverId,
  );

  void _onCompleted() {
    unawaited(widget.repo.markPlayed(widget.item));
    if (mounted) {
      setState(() => _controlsVisible = true);
      _hideTimer?.cancel();
      // Apple TV: offer the next episode with an autoplay countdown.
      if (_style == VideoPlayerStyle.appleTv && _hasNext) {
        _startUpNextCountdown();
      }
    }
  }

  void _startUpNextCountdown() {
    _upNextTimer?.cancel();
    setState(() {
      _showUpNext = true;
      _upNextSecondsLeft = 10;
    });
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_upNextSecondsLeft <= 1) {
        timer.cancel();
        _playNext();
        return;
      }
      setState(() => _upNextSecondsLeft--);
    });
  }

  void _playNext() {
    _upNextTimer?.cancel();
    final next = widget.nextEpisode;
    if (next == null) return;
    setState(() => _showUpNext = false);
    widget.onPlayNextEpisode?.call(next);
  }

  void _dismissUpNext() {
    _upNextTimer?.cancel();
    setState(() => _showUpNext = false);
  }

  /// First time the controls are shown on a wide screen in this
  /// session, show the dismissible shortcuts hint (once per session,
  /// not a blocking dialog).
  void _maybeShowShortcutsHint() {
    if (_shortcutsHintShown || !mounted) return;
    if (MediaQuery.of(context).size.width < 1024) return;
    _shortcutsHintShown = true;
    setState(() => _showShortcutsHint = true);
  }

  /// Desktop keyboard shortcuts, scoped to this page via [Focus].
  /// Space toggles play/pause, ←/→ seek 10s through the same
  /// [_seekBy] the Apple TV buttons use, F toggles fullscreen, Esc
  /// exits fullscreen or closes the player. Held-key repeats
  /// ([KeyRepeatEvent]) are ignored for the toggling keys — holding
  /// Space must not flip play/pause back and forth — while holding
  /// an arrow keeps seeking.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_loading || _error != null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isRepeat = event is KeyRepeatEvent;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (isRepeat) return KeyEventResult.ignored;
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (isRepeat) return KeyEventResult.ignored;
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (isRepeat) return KeyEventResult.ignored;
      if (_fullscreen) {
        unawaited(_toggleFullscreen());
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _seekBy(Duration offset) async {
    await _service.seek(_service.position + offset);
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_service.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _service.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onTapVideo() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  /// Double-tap the left/right half of the video to seek ∓10s,
  /// NextPlayer-style, with a centred indicator showing the jump and
  /// the target position. Single taps still just toggle the controls
  /// (the gesture arena separates the two).
  void _onDoubleTapSeek(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    final isLeft = details.localPosition.dx < width / 2;
    final offset = Duration(seconds: isLeft ? -10 : 10);
    final duration = _service.duration.inSeconds > 0
        ? _service.duration
        : Duration(seconds: widget.item.durationSeconds);
    var target = _service.position + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    unawaited(_seekBy(offset));
    setState(() {
      _seekIndicatorText = '${isLeft ? '−10秒' : '+10秒'} · ${_clock(target)}';
    });
    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _seekIndicatorText = null);
    });
  }

  Future<void> _togglePlay() async {
    await _service.togglePlay();
    if (!mounted) return;
    if (!_service.isPlaying) {
      // Paused: controls stay visible, and the position is reported.
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
      await widget.repo.reportProgress(
        widget.item,
        _service.position,
        isPaused: true,
      );
    } else {
      _scheduleHide();
    }
    setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    final enter = !_fullscreen;
    setState(() => _fullscreen = enter);
    try {
      if (enter) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } catch (_) {
      // Fullscreen is cosmetic; a failure must not break playback.
    }
  }

  Future<void> _pickSubtitle() async {
    // Returns -1 for Off, the subtitle list index for a track, and
    // null when the sheet is dismissed (no change).
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.subtitles_off),
              title: const Text('关闭'),
              selected: _subtitle == null,
              onTap: () => Navigator.of(context).pop(-1),
            ),
            ...widget.subtitles.asMap().entries.map((entry) {
              final i = entry.key;
              final s = entry.value;
              return ListTile(
                leading: const Icon(Icons.subtitles),
                title: Text(s.label),
                subtitle: Text(
                  [
                    s.language,
                    s.codec,
                  ].where((part) => part.isNotEmpty).join(' · '),
                ),
                selected: _subtitle?.index == s.index,
                onTap: () => Navigator.of(context).pop(i),
              );
            }),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final subtitle = picked < 0 ? null : widget.subtitles[picked];
    if (subtitle == _subtitle) return;
    await _applySubtitle(subtitle);
  }

  Future<void> _applySubtitle(SubtitleTrackInfo? subtitle) async {
    setState(() => _subtitle = subtitle);
    final decision = _decision;
    if (decision == null) return;
    if (decision.isDirect) {
      final url = subtitle == null
          ? null
          : widget.repo.subtitleUrlFor(widget.item, subtitle);
      await _service.setSubtitleTrack(url);
    } else {
      // Transcode burns the subtitle in: re-decide and re-open, keeping
      // the current position.
      await _open(keepPosition: true);
    }
  }

  Future<void> _pickQuality() async {
    final picked = await showModalBottomSheet<VideoQuality>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: VideoQuality.values.map((q) {
            return ListTile(
              leading: Icon(
                q == VideoQuality.direct
                    ? Icons.play_arrow
                    : Icons.high_quality,
              ),
              title: Text(q.label),
              subtitle: q == VideoQuality.direct
                  ? const Text('文件支持时不转码')
                  : Text('转码，最高 ${q.maxStreamingBitrate! ~/ 1000000} Mbps'),
              selected: _quality == q,
              onTap: () => Navigator.of(context).pop(q),
            );
          }).toList(),
        ),
      ),
    );
    if (picked == null || picked == _quality || !mounted) return;
    setState(() => _quality = picked);
    await _open(keepPosition: true);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekIndicatorTimer?.cancel();
    _upNextTimer?.cancel();
    _focusNode.dispose();
    unawaited(_reportFinalPosition());
    if (_ownsService) _service.dispose();
    if (_fullscreen) {
      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  Future<void> _reportFinalPosition() async {
    try {
      // Playback ended: report Stopped to Emby (closes the session)
      // and save the local resume position.
      await widget.repo.reportPlaybackStopped(widget.item, _service.position);
    } catch (_) {
      // Best effort on dispose.
    }
    try {
      await widget.appState?.recordLastVideo(widget.item, _service.position);
    } catch (_) {
      // Best effort on dispose.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Focus wraps the page so the desktop keyboard shortcuts are
    // scoped to it: autofocus on open, released on dispose.
    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _errorView()
              : _playerView(),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text('无法播放：\n$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _open, child: const Text('重试')),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerView() {
    // Listen to Settings too, so a style change in Settings restyles
    // the controls live without a restart.
    final listenables = <Listenable>[_service];
    if (widget.settings != null) listenables.add(widget.settings!);
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        final controller = _service.videoController as VideoController?;
        final duration = _service.duration.inSeconds > 0
            ? _service.duration
            : Duration(seconds: widget.item.durationSeconds);
        final position = _service.position.inSeconds > duration.inSeconds
            ? duration
            : _service.position;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Tap / double-tap live on the video layer only, NOT
            // around the whole stack: if the detector were an
            // ancestor of the control buttons, every button tap
            // would wait out the 300ms double-tap timeout before
            // firing. As a sibling below the overlay, taps on
            // buttons go straight to the button, and taps on the
            // overlay's empty areas fall through to the video.
            GestureDetector(
              onTap: _onTapVideo,
              onDoubleTapDown: _onDoubleTapSeek,
              child: controller == null
                  ? _posterFallback()
                  : Video(controller: controller),
            ),
            if (_service.isBuffering)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            if (_seekIndicatorText != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _seekIndicatorText!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (_controlsVisible) _controlsOverlay(position, duration),
            if (_showUpNext) _upNextCard(),
          ],
        );
      },
    );
  }

  /// Dismissible keyboard-shortcuts hint, shown once per session
  /// the first time the controls appear on a wide screen. A small
  /// panel in the controls overlay, never a blocking dialog.
  Widget _shortcutsHint() {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 12, bottom: 8),
        child: Card(
          color: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '键盘快捷键',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '空格 · 播放 / 暂停',
                      style: TextStyle(color: Colors.white70),
                    ),
                    Text(
                      '← → · 快进 / 快退 10 秒',
                      style: TextStyle(color: Colors.white70),
                    ),
                    Text('F · 全屏', style: TextStyle(color: Colors.white70)),
                    Text('Esc · 退出', style: TextStyle(color: Colors.white70)),
                  ],
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 18,
                  ),
                  tooltip: '知道了',
                  onPressed: () => setState(() => _showShortcutsHint = false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Apple TV Up Next card: the next episode with a 10s autoplay
  /// countdown. Play now plays it at once; Dismiss closes the card
  /// (and cancels the timer). The timer is also cancelled on dispose.
  Widget _upNextCard() {
    final next = widget.nextEpisode;
    if (next == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
        child: Card(
          color: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '接下来播放',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  next.title,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$_upNextSecondsLeft 秒后播放',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _playNext,
                      child: const Text('立即播放'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _dismissUpNext,
                      child: const Text(
                        '关闭',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _posterFallback() {
    return Container(
      color: YingHuiTheme.card,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie, size: 64, color: YingHuiTheme.primaryGreen),
            const SizedBox(height: 12),
            Text(
              widget.item.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const Text(
              '这个版本不支持视频预览',
              style: TextStyle(color: YingHuiTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  /// Controls overlay, NextPlayer-style layout (structure only, no
  /// code or branding copied): three zones over the video — a top bar
  /// (back + title + track buttons), a centred middle row (seek back /
  /// play-pause / seek forward), and a bottom block (time chip, seek
  /// bar, action row). The overlay fades with [_controlsVisible] as
  /// before; styles only change the accent colour and the style-only
  /// extras (Netflix next episode, Apple TV Up Next).
  Widget _controlsOverlay(Duration position, Duration duration) {
    return Column(
      children: [
        _topBar(),
        const Spacer(),
        _middleControls(),
        const Spacer(),
        if (_showShortcutsHint) _shortcutsHint(),
        _bottomBar(position, duration),
      ],
    );
  }

  /// Top bar: back button, title (weight 1, up to 2 lines), then the
  /// play-mode chip and the track buttons on the right — subtitles
  /// and quality moved up here from the bottom row, where NextPlayer
  /// puts its audio/subtitle/playlist buttons.
  Widget _topBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              widget.item.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_decision != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                label: Text(
                  _decision!.isDirect ? '直接播放' : '转码',
                  style: const TextStyle(fontSize: 12),
                ),
                backgroundColor: Colors.black54,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.subtitles, color: Colors.white),
            tooltip: '字幕',
            onPressed: widget.subtitles.isEmpty ? null : _pickSubtitle,
          ),
          IconButton(
            icon: const Icon(Icons.high_quality, color: Colors.white),
            tooltip: '清晰度',
            onPressed: _pickQuality,
          ),
        ],
      ),
    );
  }

  /// Centred middle row: seek back 10s, big play/pause, seek forward
  /// 10s. The ±10s buttons used to live in the bottom row and only in
  /// the Apple TV style; NextPlayer puts them in the centre for every
  /// video, so they are here for all styles now.
  Widget _middleControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 40,
      children: [
        IconButton(
          icon: const Icon(Icons.replay_10, color: Colors.white, size: 40),
          tooltip: '快退 10 秒',
          onPressed: () => _seekBy(const Duration(seconds: -10)),
        ),
        IconButton(
          icon: Icon(
            _service.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled,
            size: 64,
            color: _accent,
          ),
          tooltip: _service.isPlaying ? '暂停' : '播放',
          onPressed: _togglePlay,
        ),
        IconButton(
          icon: const Icon(Icons.forward_10, color: Colors.white, size: 40),
          tooltip: '快进 10 秒',
          onPressed: () => _seekBy(const Duration(seconds: 10)),
        ),
      ],
    );
  }

  /// Bottom block: a tappable time chip (toggles elapsed / remaining,
  /// NextPlayer-style), the seek bar, and a scrollable action row
  /// (fullscreen, close, Netflix next episode).
  Widget _bottomBar(Duration position, Duration duration) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () =>
                    setState(() => _showRemainingTime = !_showRemainingTime),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.black54,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _timeText(position, duration),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Slider(
            value: position.inMilliseconds.toDouble(),
            max: duration.inMilliseconds.toDouble() > 0
                ? duration.inMilliseconds.toDouble()
                : 1,
            onChanged: (value) =>
                _service.seek(Duration(milliseconds: value.round())),
            activeColor: _accent,
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.fullscreen, color: Colors.white),
                  tooltip: '全屏',
                  onPressed: _toggleFullscreen,
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                if (_style == VideoPlayerStyle.netflix && _hasNext)
                  IconButton(
                    icon: const Icon(Icons.skip_next, color: Colors.white),
                    tooltip: '下一集',
                    onPressed: _playNext,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "elapsed / total", or "-remaining / total" when the time chip
  /// was tapped. Without a known duration there is nothing to count
  /// down from, so it stays elapsed-only.
  String _timeText(Duration position, Duration duration) {
    if (!_showRemainingTime || duration.inSeconds <= 0) {
      return '${_clock(position)} / ${_clock(duration)}';
    }
    final remaining = duration - position;
    return '-${_clock(remaining.isNegative ? Duration.zero : remaining)}'
        ' / ${_clock(duration)}';
  }
}
