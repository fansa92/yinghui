import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/theme.dart';
import '../../core/settings.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../core/widgets/state_views.dart';
import '../../data/models/video_detail.dart';
import '../../data/models/video_item.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/video_repository.dart';
import '../player/video_player_page.dart';
import 'backdrop_header.dart';
import 'poster_image.dart';

/// Single-episode detail page (batch 2).
///
/// Tapping an episode in [VideoDetailPage] opens this instead of
/// playing directly. Header (poster, S/E number, overview, Play /
/// Resume), then three info sections built only from the Emby
/// MediaStreams / MediaSources the server actually returned — a
/// missing field shows "—", and a missing media source shows an
/// explicit "暂无媒体信息" instead of fake data.
///
/// When the episode has a backdrop URL, the header is a full-width
/// [BackdropHeader] (backdrop photo with a dark gradient, title +
/// meta + Play overlaid) and the poster thumbnail goes away; without
/// one the poster-row header is kept exactly. The episode's own
/// backdrop URL comes from the Emby item itself — there is no
/// series-backdrop fallback, because the model carries no series
/// backdrop and fetching one would be a new API call; when the
/// server has no backdrop for the episode the image fails and the
/// header falls back to its solid background.
///
/// - 视频信息: container, video codec, resolution, frame rate,
///   video bitrate, duration, overall bitrate.
/// - 音频信息: one row per audio stream — language, codec/格式,
///   channels, 码率, sample rate, default/forced flags.
/// - 字幕信息: one row per subtitle stream — language, codec/格式,
///   default/forced, embedded vs external, DeliveryUrl presence.
///   Subtitle rows are display-only.
class EpisodeDetailPage extends StatefulWidget {
  const EpisodeDetailPage({
    super.key,
    required this.episode,
    required this.repo,
    required this.history,
    required this.settings,
    this.appState,
  });

  final VideoItem episode;
  final VideoRepository repo;
  final PlaybackStore history;
  final SettingsService settings;
  final AppStateStore? appState;

  @override
  State<EpisodeDetailPage> createState() => _EpisodeDetailPageState();
}

class _EpisodeDetailPageState extends State<EpisodeDetailPage> {
  VideoDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.repo.itemDetail(
        widget.episode.id,
        widget.episode.serverId,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  VideoItem get _item => _detail?.item ?? widget.episode;

  void _play() {
    final item = _item;
    unawaited(
      widget.appState?.recordLastVideo(
        item,
        Duration(seconds: item.playbackPositionSeconds),
      ),
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoPlayerPage(
          item: item,
          repo: widget.repo,
          history: widget.history,
          subtitles: _detail?.allSubtitles ?? const [],
          mediaSources: _detail?.mediaSources ?? const [],
          settings: widget.settings,
          appState: widget.appState,
        ),
      ),
    );
  }

  /// Whether the loaded item has a backdrop. While loading (or on
  /// error) this is false, so the page keeps its normal app bar.
  bool get _hasBackdrop {
    if (_loading || _error != null) return false;
    final url = _item.backdropUrl;
    return url != null && url.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    // In backdrop mode the header carries the title, so the app bar
    // goes transparent (back button only, floating over the photo);
    // otherwise the app bar keeps its title as before.
    return Scaffold(
      extendBodyBehindAppBar: _hasBackdrop,
      appBar: AppBar(
        title: _hasBackdrop ? null : Text(widget.episode.title),
        backgroundColor: _hasBackdrop ? Colors.transparent : null,
        scrolledUnderElevation: _hasBackdrop ? 0 : null,
        foregroundColor: _hasBackdrop ? Colors.white : null,
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(message: '详情加载失败：\n$_error', onRetry: _load)
          : CenteredContent(child: _detailView()),
    );
  }

  Widget _detailView() {
    final item = _item;
    final seasonEpisode = [
      if (item.seasonNumber != null) 'S${item.seasonNumber}',
      if (item.episodeNumber != null) 'E${item.episodeNumber}',
    ].join('');
    final meta = [
      if (seasonEpisode.isNotEmpty) seasonEpisode,
      if (item.year != null) '${item.year}',
      item.durationText,
      item.sourceLabel,
    ].join(' · ');
    final playLabel = item.playbackPositionSeconds > 0
        ? '从 ${item.positionText} 继续播放'
        : '播放';
    final source = _detail?.primarySource;
    final belowHeader = <Widget>[
      if (item.overview.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(item.overview),
      ],
      const SizedBox(height: 24),
      if (source == null)
        const _SectionCard(
          title: '媒体信息',
          child: Text(
            '暂无媒体信息',
            style: TextStyle(color: YingHuiTheme.textMuted),
          ),
        )
      else ...[
        ResponsiveTwoColumn(
          first: _SectionCard(
            title: '视频信息',
            child: Column(children: _videoRows(source, item)),
          ),
          second: _SectionCard(title: '音频信息', child: _audioSection(source)),
        ),
        const SizedBox(height: 16),
        _SectionCard(title: '字幕信息', child: _subtitleSection()),
      ],
      const SizedBox(height: 16),
    ];
    if (_hasBackdrop) {
      // Full-bleed backdrop header: the ListView loses its padding
      // and the content below gets its own horizontal padding.
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          BackdropHeader(
            backdropUrl: item.backdropUrl,
            title: item.title,
            meta: meta,
            playLabel: playLabel,
            onPlay: _play,
            topInset: MediaQuery.of(context).padding.top + kToolbarHeight,
          ),
          ...belowHeader.map(
            (w) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: w,
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [_posterHeader(item, meta, playLabel), ...belowHeader],
    );
  }

  /// The original poster-row header, kept exactly for items with no
  /// backdrop URL.
  Widget _posterHeader(VideoItem item, String meta, String playLabel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PosterImage(posterUrl: item.posterUrl),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(meta, style: const TextStyle(color: YingHuiTheme.textMuted)),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _play,
                icon: const Icon(Icons.play_arrow),
                label: Text(playLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _videoRows(MediaSourceInfo source, VideoItem item) {
    final video = source.videoStreams.isEmpty
        ? null
        : source.videoStreams.first;
    return [
      _infoRow('容器', source.container),
      _infoRow('编码', video?.codec ?? source.videoCodec),
      _infoRow(
        '分辨率',
        video?.width != null && video?.height != null
            ? '${video!.width}×${video.height}'
            : (source.width != null && source.height != null
                  ? '${source.width}×${source.height}'
                  : null),
      ),
      _infoRow(
        '帧率',
        video?.frameRate == null ? null : '${video!.frameRate} fps',
      ),
      _infoRow('视频码率', _kbps(video?.bitRate)),
      _infoRow('时长', item.durationText),
      _infoRow('总体码率', _kbps(source.videoBitRate)),
    ];
  }

  Widget _audioSection(MediaSourceInfo source) {
    final audios = source.audioStreams;
    if (audios.isEmpty) {
      return const Text(
        '暂无音频信息',
        style: TextStyle(color: YingHuiTheme.textMuted),
      );
    }
    return Column(
      children: audios.map((a) {
        final flags = [if (a.isDefault) '默认', if (a.isForced) '强制'].join(' · ');
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            [
              if (a.language.isNotEmpty) a.language,
              a.codec.isNotEmpty ? a.codec : '—',
            ].join(' · '),
          ),
          subtitle: Text(
            [
              _channelsText(a.channels),
              _kbps(a.bitRate),
              a.sampleRate == null
                  ? null
                  : '${(a.sampleRate! / 1000).toStringAsFixed(1)} kHz',
              if (flags.isNotEmpty) flags,
            ].whereType<String>().join(' · '),
          ),
        );
      }).toList(),
    );
  }

  Widget _subtitleSection() {
    final subs = _detail?.allSubtitles ?? const [];
    if (subs.isEmpty) {
      return const Text(
        '暂无字幕',
        style: TextStyle(color: YingHuiTheme.textMuted),
      );
    }
    return Column(
      children: subs.map((s) {
        final flags = [if (s.isDefault) '默认', if (s.isForced) '强制'].join(' · ');
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.label),
          subtitle: Text(
            [
              s.codec.isNotEmpty ? s.codec : '—',
              s.isExternal ? '外挂' : '内嵌',
              s.deliveryUrl != null && s.deliveryUrl!.isNotEmpty
                  ? '有直链'
                  : '无直链',
              if (flags.isNotEmpty) flags,
            ].join(' · '),
          ),
        );
      }).toList(),
    );
  }

  static String _kbps(int? bitRate) =>
      bitRate == null ? '—' : '${(bitRate / 1000).toStringAsFixed(0)} kbps';

  static String _channelsText(int? channels) => switch (channels) {
    1 => '单声道',
    2 => '立体声',
    6 => '5.1 声道',
    8 => '7.1 声道',
    null => '—',
    _ => '$channels 声道',
  };

  static Widget _infoRow(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(color: YingHuiTheme.textMuted),
          ),
        ),
        Expanded(
          child: Text(
            value == null || value.isEmpty ? '—' : value,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
