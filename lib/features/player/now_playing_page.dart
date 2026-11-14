import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../data/models/track.dart';
import '../../data/repositories/music_repository.dart';
import '../music/cover_image.dart';
import 'player_service.dart';

String _clock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Full-screen now-playing page: cover, title/artist, seek bar,
/// play/pause, next/prev, and the queue.
///
/// Presentation follows [SettingsService.musicPlayerStyle] (live —
/// changing the style in Settings restyles this page without a
/// restart). Only presentation changes: the queue, seek and playback
/// behaviour are identical in every style.
///
/// - default: Tempus-style layout (layout pattern only) — the cover
///   fills the content width, title/artist left-aligned under it,
///   elapsed and duration flank the slider on one row, a heart and a
///   播放队列 button under the transport, Up next list below.
/// - appleMusic: cover-tinted blurred background, white play button,
///   remaining time on the right end of the slider, and a volume
///   slider wired to the real player volume.
/// - spotify: pure black background, white play button, a heart
///   wired to the existing track favourite, and a Queue button that
///   scrolls to the Up next list. No Devices row — there is no
///   casting support, so none is shown.
///
/// Shuffle / repeat live in the transport row in every style:
/// shuffle (left of previous) and repeat (right of next), with the
/// active state in the style accent (green for default, white for
/// the other two); repeat-one shows the repeat_one icon. The Up
/// next list is reorderable (drag handle), each row has a remove
/// button, and the header has a 清空 button plus the queue length.
/// Tapping a queue row jumps within the queue (it does not rebuild
/// it). Tapping a song anywhere else in the app plays it in place
/// without destroying the queue (see [PlayerService.playTrack]).
///
/// Desktop (width >= 1024): a two-column layout — left column large
/// cover + title/artist + seek slider + play controls + volume
/// (the controls sit directly under the cover), right column Up next
/// queue only — centred with a max width of 1000. The style
/// variants keep working in both layouts; the desktop arrangement
/// applies on top of whichever style is selected. The volume slider
/// shows under the cover for every style on desktop (it is wired to
/// the real player volume); on phones it stays Apple Music only, as
/// before. Below 1024 the single-column layout is unchanged.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.player,
    this.settings,
    this.musicRepo,
  });

  final PlayerService player;

  /// Optional Settings: when null the default style applies, so
  /// existing callers keep working unchanged.
  final SettingsService? settings;

  /// Optional music repo: the Spotify heart needs it to star the
  /// current track. When null the heart is hidden.
  final MusicRepository? musicRepo;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _upNextKey = GlobalKey();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  MusicPlayerStyle get _style =>
      widget.settings?.musicPlayerStyle ?? MusicPlayerStyle.standard;

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final listenable = settings == null
        ? widget.player
        : Listenable.merge([widget.player, settings]);
    // The listener wraps the whole Scaffold: the background and app
    // bar colours are style-dependent too, so a style change in
    // Settings must restyle them live, not just the body below.
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: _style == MusicPlayerStyle.spotify
              ? Colors.black
              : null,
          appBar: AppBar(
            title: const Text('正在播放'),
            backgroundColor: _style == MusicPlayerStyle.spotify
                ? Colors.black
                : null,
            actions: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          body: _bodyOrEmpty(),
        );
      },
    );
  }

  Widget _bodyOrEmpty() {
    final track = widget.player.currentTrack;
    if (track == null) {
      return const Center(child: Text('还没有在播的歌曲。'));
    }
    final content = isWideLayout(context) ? _desktopBody(track) : _body(track);
    if (_style == MusicPlayerStyle.appleMusic &&
        track.coverUrl != null &&
        track.coverUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _blurredCover(track.coverUrl!),
          Container(color: Colors.black.withValues(alpha: 0.55)),
          content,
        ],
      );
    }
    return content;
  }

  /// Timing + colours shared by both layouts, so the mobile and
  /// desktop arrangements can never drift apart.
  ({Duration duration, Duration position, String rightTime, Color accent})
  _timing(Track track) {
    final player = widget.player;
    final style = _style;
    final duration = player.duration.inSeconds > 0
        ? player.duration
        : Duration(seconds: track.durationSeconds);
    final position = player.position.inSeconds > duration.inSeconds
        ? duration
        : player.position;
    // Apple Music shows remaining time on the right end; the other
    // styles show the total duration.
    final rightTime = style == MusicPlayerStyle.appleMusic
        ? '-${_clock(duration - position)}'
        : _clock(duration);
    final accent = style == MusicPlayerStyle.standard
        ? YingHuiTheme.primaryGreen
        : Colors.white;
    return (
      duration: duration,
      position: position,
      rightTime: rightTime,
      accent: accent,
    );
  }

  /// Cover + title/artist/source, used in both layouts.
  Widget _coverHeader(Track track, {double coverSize = 280}) {
    final style = _style;
    if (style == MusicPlayerStyle.standard) {
      // Tempus-style default: the cover fills the content width and
      // the title/artist sit left-aligned under it (not centred).
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : coverSize;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              CoverImage(
                coverUrl: track.coverUrl,
                size: size,
                borderRadius: 16,
                iconSize: 96,
              ),
              const SizedBox(height: 16),
              Text(
                track.title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 4),
              Text(
                '${track.artist} · ${track.album}',
                style: const TextStyle(
                  fontSize: 15,
                  color: YingHuiTheme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                track.sourceLabel,
                style: const TextStyle(
                  fontSize: 13,
                  color: YingHuiTheme.textMuted,
                ),
              ),
            ],
          );
        },
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: CoverImage(
            coverUrl: track.coverUrl,
            size: coverSize,
            borderRadius: 16,
            iconSize: 96,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          track.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
        ),
        const SizedBox(height: 4),
        Text(
          '${track.artist} · ${track.album}',
          style: const TextStyle(fontSize: 15, color: Colors.white70),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          track.sourceLabel,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// Seek slider + elapsed/right time + prev/play/next, used in both
  /// layouts.
  Widget _seekAndControls(Track track) {
    final player = widget.player;
    final style = _style;
    final timing = _timing(track);
    final duration = timing.duration;
    final position = timing.position;
    final accent = timing.accent;
    final slider = Slider(
      value: position.inMilliseconds.toDouble(),
      max: duration.inMilliseconds.toDouble() > 0
          ? duration.inMilliseconds.toDouble()
          : 1,
      onChanged: (value) => player.seek(Duration(milliseconds: value.round())),
      activeColor: accent,
    );
    final transport = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _shuffleButton(accent),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(
            Icons.skip_previous,
            size: 40,
            color: style == MusicPlayerStyle.standard ? null : accent,
          ),
          onPressed: player.previous,
        ),
        const SizedBox(width: 16),
        IconButton(
          icon: Icon(
            player.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled,
            size: 72,
            color: accent,
          ),
          onPressed: player.togglePlay,
        ),
        const SizedBox(width: 16),
        IconButton(
          icon: Icon(
            Icons.skip_next,
            size: 40,
            color: style == MusicPlayerStyle.standard ? null : accent,
          ),
          onPressed: player.next,
        ),
        const SizedBox(width: 4),
        _repeatButton(accent),
      ],
    );
    if (style == MusicPlayerStyle.standard) {
      // Tempus-style default: elapsed and duration flank the slider
      // on one row, transport below.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_clock(position)),
              Expanded(child: slider),
              Text(timing.rightTime),
            ],
          ),
          const SizedBox(height: 8),
          transport,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        slider,
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_clock(position), style: const TextStyle(color: Colors.white)),
            Text(timing.rightTime, style: const TextStyle(color: Colors.white)),
          ],
        ),
        const SizedBox(height: 8),
        transport,
      ],
    );
  }

  /// Inactive colour for the shuffle / repeat buttons: muted in
  /// the default style, dimmed white in the other two.
  Color get _inactiveControlColor => _style == MusicPlayerStyle.standard
      ? YingHuiTheme.textMuted
      : Colors.white54;

  /// Shuffle toggle. Active state in the style accent.
  Widget _shuffleButton(Color accent) {
    final player = widget.player;
    final active = player.isShuffle;
    return IconButton(
      icon: const Icon(Icons.shuffle, size: 28),
      color: active ? accent : _inactiveControlColor,
      tooltip: active ? '关闭随机播放' : '随机播放',
      onPressed: player.toggleShuffle,
    );
  }

  /// Repeat cycle (off → all → one). Repeat-one shows the
  /// repeat_one icon so the mode is visible at a glance.
  Widget _repeatButton(Color accent) {
    final player = widget.player;
    final mode = player.repeatMode;
    final active = mode != MusicRepeatMode.off;
    return IconButton(
      icon: Icon(
        mode == MusicRepeatMode.one ? Icons.repeat_one : Icons.repeat,
        size: 28,
      ),
      color: active ? accent : _inactiveControlColor,
      tooltip: switch (mode) {
        MusicRepeatMode.off => '循环播放：关闭',
        MusicRepeatMode.all => '循环播放：全部',
        MusicRepeatMode.one => '循环播放：单曲',
      },
      onPressed: player.cycleRepeat,
    );
  }

  /// Volume slider wired to the real player volume.
  Widget _volumeRow({bool showPercent = false}) {
    final player = widget.player;
    final style = _style;
    final accent = style == MusicPlayerStyle.standard
        ? YingHuiTheme.primaryGreen
        : Colors.white;
    final iconColor = style == MusicPlayerStyle.standard
        ? YingHuiTheme.textMuted
        : Colors.white70;
    return Row(
      children: [
        Icon(Icons.volume_down, color: iconColor),
        Expanded(
          child: Slider(
            value: player.volume,
            onChanged: player.setVolume,
            activeColor: accent,
          ),
        ),
        Icon(Icons.volume_up, color: iconColor),
        if (showPercent)
          Text(
            '${(player.volume * 100).round()}%',
            style: TextStyle(color: iconColor),
          ),
      ],
    );
  }

  /// Spotify heart + Queue row. The Queue button scrolls to the Up
  /// next list in whichever scrollable the page is using.
  Widget _spotifyRow(Track track) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (widget.musicRepo != null)
          _StarButton(repo: widget.musicRepo!, track: track)
        else
          const SizedBox(width: 48),
        _queueJumpButton(Colors.white70),
      ],
    );
  }

  /// Tempus-style default action row: heart on the left, 播放队列
  /// (scrolls to Up next) on the right. Same behaviours as the
  /// Spotify row, in the default style's colours.
  Widget _standardRow(Track track) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (widget.musicRepo != null)
          _StarButton(
            repo: widget.musicRepo!,
            track: track,
            activeColor: YingHuiTheme.primaryGreen,
            inactiveColor: YingHuiTheme.textMuted,
          )
        else
          const SizedBox(width: 48),
        _queueJumpButton(YingHuiTheme.textMuted),
      ],
    );
  }

  Widget _queueJumpButton(Color color) {
    return TextButton.icon(
      icon: Icon(Icons.queue_music, color: color),
      label: Text('播放队列', style: TextStyle(color: color)),
      onPressed: () {
        final context = _upNextKey.currentContext;
        if (context != null) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 300),
          );
        }
      },
    );
  }

  /// Up next header + queue rows, used in both layouts.
  ///
  /// The list is reorderable (drag the handle), each row has a
  /// remove button, and the header shows the queue length plus a
  /// 清空 button (which keeps the current track playing). Tapping a
  /// row jumps within the queue; it never rebuilds it.
  Widget _queueSection() {
    final player = widget.player;
    final style = _style;
    final queue = player.queue;
    final titleColor = style == MusicPlayerStyle.standard ? null : Colors.white;
    final mutedColor = style == MusicPlayerStyle.standard
        ? YingHuiTheme.textMuted
        : Colors.white70;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              '接下来播放',
              key: _upNextKey,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: titleColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '共 ${queue.length} 首',
              style: TextStyle(fontSize: 13, color: mutedColor),
            ),
            const Spacer(),
            if (queue.length > 1)
              TextButton(onPressed: player.clearQueue, child: const Text('清空')),
          ],
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: queue.length,
          onReorderItem: (oldIndex, newIndex) {
            // onReorderItem already adjusts newIndex for the removed
            // item, so it is the final position as-is.
            player.moveQueue(oldIndex, newIndex);
          },
          itemBuilder: (context, i) {
            final t = queue[i];
            final isCurrent = i == player.currentIndex;
            return ListTile(
              key: ValueKey(t),
              leading: CoverImage(coverUrl: t.coverUrl),
              title: Text(
                t.title,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent
                      ? (style == MusicPlayerStyle.standard
                            ? YingHuiTheme.primaryGreen
                            : Colors.white)
                      : (style == MusicPlayerStyle.standard
                            ? YingHuiTheme.textPrimary
                            : Colors.white70),
                ),
              ),
              subtitle: Text(
                '${t.artist} · ${t.album}',
                style: TextStyle(
                  color: style == MusicPlayerStyle.standard
                      ? null
                      : Colors.white70,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.durationText, style: TextStyle(color: mutedColor)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: mutedColor,
                    tooltip: '从队列中移除',
                    onPressed: () => player.removeAt(i),
                    visualDensity: VisualDensity.compact,
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_handle, size: 20, color: mutedColor),
                  ),
                ],
              ),
              onTap: () => player.jumpTo(i),
            );
          },
        ),
      ],
    );
  }

  /// Playback-failure banner: audio errors used to be silent, so a
  /// failed open looked like "tapping play does nothing". Shows the
  /// backend error (e.g. the missing-libmpv message) with a retry
  /// that re-opens the current track.
  Widget _errorBanner() {
    final player = widget.player;
    return Card(
      color: YingHuiTheme.errorRed.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: YingHuiTheme.errorRed),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '无法播放：\n${player.lastError}',
                style: const TextStyle(color: YingHuiTheme.errorRed),
              ),
            ),
            TextButton(onPressed: player.togglePlay, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  /// Phone layout: the current single column, unchanged.
  Widget _body(Track track) {
    final style = _style;
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(24),
      children: [
        if (widget.player.lastError != null) ...[
          _errorBanner(),
          const SizedBox(height: 12),
        ],
        _coverHeader(track),
        const SizedBox(height: 24),
        _seekAndControls(track),
        if (style == MusicPlayerStyle.appleMusic) ...[
          const SizedBox(height: 16),
          _volumeRow(),
        ],
        if (style == MusicPlayerStyle.spotify) ...[
          const SizedBox(height: 8),
          _spotifyRow(track),
        ],
        if (style == MusicPlayerStyle.standard) ...[
          const SizedBox(height: 8),
          _standardRow(track),
        ],
        const SizedBox(height: 24),
        _queueSection(),
      ],
    );
  }

  /// Desktop layout (width >= 1024): two columns inside the shared
  /// 1000px centred content — left column large cover + title/artist
  /// + seek slider + play controls + volume, right column Up next
  /// queue only. The controls moved under the cover (they used to
  /// sit in the right column above the queue); the extra
  /// skip-to-start/end buttons in the mockup are ignored: there is
  /// no such function. The style variants apply on top of this
  /// arrangement, exactly as on phones.
  Widget _desktopBody(Track track) {
    final style = _style;
    return CenteredContent(
      child: Row(
        key: const ValueKey('desktop-two-column'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.player.lastError != null) ...[
                    _errorBanner(),
                    const SizedBox(height: 12),
                  ],
                  _coverHeader(track, coverSize: 340),
                  const SizedBox(height: 24),
                  _seekAndControls(track),
                  const SizedBox(height: 16),
                  _volumeRow(showPercent: true),
                  if (style == MusicPlayerStyle.spotify) ...[
                    const SizedBox(height: 8),
                    _spotifyRow(track),
                  ],
                  if (style == MusicPlayerStyle.standard) ...[
                    const SizedBox(height: 8),
                    _standardRow(track),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [_queueSection()],
            ),
          ),
        ],
      ),
    );
  }

  /// Blurred cover art as a background. A plain dark background is
  /// used when the image fails — the page never depends on it.
  Widget _blurredCover(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      imageBuilder: (context, imageProvider) => ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          decoration: BoxDecoration(
            image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
          ),
        ),
      ),
      errorWidget: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

/// Spotify-style heart: the existing track favourite, reused from
/// the music repository (server star + local Drift favourite).
class _StarButton extends StatefulWidget {
  const _StarButton({
    required this.repo,
    required this.track,
    this.activeColor = Colors.white,
    this.inactiveColor = Colors.white70,
  });

  final MusicRepository repo;
  final Track track;
  final Color activeColor;
  final Color inactiveColor;

  @override
  State<_StarButton> createState() => _StarButtonState();
}

class _StarButtonState extends State<_StarButton> {
  bool? _starred;

  @override
  void didUpdateWidget(covariant _StarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track starts from the server state, not the old toggle.
    if (oldWidget.track.id != widget.track.id) _starred = null;
  }

  Future<void> _toggle() async {
    final starred = await widget.repo.toggleStarTrack(widget.track);
    if (mounted) setState(() => _starred = starred);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: widget.repo.isStarredTrack(widget.track),
      builder: (context, snapshot) {
        final starred = _starred ?? snapshot.data ?? false;
        return IconButton(
          icon: Icon(
            starred ? Icons.favorite : Icons.favorite_border,
            color: starred ? widget.activeColor : widget.inactiveColor,
          ),
          tooltip: starred ? '取消收藏' : '收藏',
          onPressed: _toggle,
        );
      },
    );
  }
}
