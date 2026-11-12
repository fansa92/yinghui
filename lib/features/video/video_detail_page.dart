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
import 'episode_detail_page.dart';
import 'poster_image.dart';

/// Video detail: backdrop/poster, overview, cast, and — for series —
/// a season picker plus the episode list with per-episode progress.
/// Play resumes from the Emby resume position when there is one.
///
/// When the item has a backdrop URL, the header is a full-width
/// [BackdropHeader] (backdrop photo with a dark gradient, title +
/// meta + genre chips + Play overlaid) and the poster thumbnail goes
/// away; without one the poster-row header is kept exactly. Overview,
/// cast and the series episode selector below are unchanged either
/// way.
class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    required this.item,
    required this.repo,
    required this.history,
    required this.settings,
    this.appState,
  });

  final VideoItem item;
  final VideoRepository repo;
  final PlaybackStore history;
  final SettingsService settings;
  final AppStateStore? appState;

  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage> {
  VideoDetail? _detail;
  SeriesDetail? _seriesDetail;
  String? _selectedSeasonId;
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
      // Detail and series (seasons + episodes) are independent reads:
      // fetch them at the same time instead of one after another, so
      // a series page waits ~1 round trip, not 2.
      final detailFuture = widget.repo.itemDetail(
        widget.item.id,
        widget.item.serverId,
      );
      final seriesFuture = widget.item.type == 'Series'
          ? widget.repo.seriesDetail(widget.item.id, widget.item.serverId)
          : Future<SeriesDetail?>.value();
      final detail = await detailFuture;
      SeriesDetail? seriesDetail;
      if (detail.item.type == 'Series') {
        seriesDetail = await seriesFuture;
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _seriesDetail = seriesDetail;
        _selectedSeasonId = seriesDetail?.seasons.isNotEmpty == true
            ? seriesDetail!.seasons.first.id
            : null;
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

  VideoItem get _item => _detail?.item ?? widget.item;

  void _play(VideoItem item) {
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
          nextEpisode: _nextEpisode(item),
          onPlayNextEpisode: (next) {
            // Pop this player, then open the next episode's player.
            Navigator.of(context).pop();
            _play(next);
          },
        ),
      ),
    );
  }

  /// The episode after [item] in the same season, or null for movies,
  /// the last episode, and items not in the episode list. Drives the
  /// Netflix Next Episode button and the Apple TV Up Next card.
  VideoItem? _nextEpisode(VideoItem item) {
    final episodes = _selectedSeasonId == null
        ? _seriesDetail?.episodes ?? []
        : _seriesDetail?.episodesForSeason(_selectedSeasonId!) ?? [];
    final index = episodes.indexWhere((e) => e.id == item.id);
    if (index < 0 || index + 1 >= episodes.length) return null;
    return episodes[index + 1];
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
        title: _hasBackdrop ? null : Text(widget.item.title),
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
    final isSeries = item.type == 'Series';
    final episodes = _selectedSeasonId == null
        ? _seriesDetail?.episodes ?? []
        : _seriesDetail?.episodesForSeason(_selectedSeasonId!) ?? [];
    final meta = [
      if (item.year != null) '${item.year}',
      item.durationText,
      item.typeLabel,
      item.sourceLabel,
    ].join(' · ');
    final playLabel = item.playbackPositionSeconds > 0
        ? '从 ${item.positionText} 继续播放'
        : '播放';
    final belowHeader = <Widget>[
      if (item.overview.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(item.overview),
      ],
      if (item.cast.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text(
          '演员',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: item.cast
              .map(
                (name) => Chip(
                  avatar: const Icon(Icons.person, size: 18),
                  label: Text(name),
                ),
              )
              .toList(),
        ),
      ],
      if (isSeries) ...[
        const SizedBox(height: 16),
        Row(
          children: [
            const Text(
              '分集',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if ((_seriesDetail?.seasons.length ?? 0) > 1)
              DropdownButton<String>(
                value: _selectedSeasonId,
                items: (_seriesDetail?.seasons ?? [])
                    .map(
                      (s) => DropdownMenuItem(value: s.id, child: Text(s.name)),
                    )
                    .toList(),
                onChanged: (id) => setState(() => _selectedSeasonId = id),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (episodes.isEmpty)
          const Text(
            '这一季还没有分集。',
            style: TextStyle(color: YingHuiTheme.textMuted),
          ),
        ...episodes.map((episode) {
          final seasonEpisode = [
            if (episode.seasonNumber != null) 'S${episode.seasonNumber}',
            if (episode.episodeNumber != null) 'E${episode.episodeNumber}',
          ].join('');
          return ListTile(
            leading: PosterImage(
              posterUrl: episode.posterUrl,
              width: 48,
              height: 72,
              borderRadius: 8,
            ),
            title: Text(
              seasonEpisode.isEmpty
                  ? episode.title
                  : '$seasonEpisode · ${episode.title}',
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (episode.overview.isNotEmpty)
                  Text(
                    episode.overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (episode.progress > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(
                      value: episode.progress,
                      color: YingHuiTheme.primaryGreen,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ),
            trailing: Text(episode.durationText),
            // Episodes open their own detail page (media info +
            // Play); the series Play button still plays directly.
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => EpisodeDetailPage(
                  episode: episode,
                  repo: widget.repo,
                  history: widget.history,
                  settings: widget.settings,
                  appState: widget.appState,
                ),
              ),
            ),
          );
        }),
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
            genres: item.genres,
            playLabel: playLabel,
            onPlay: () => _play(_playTarget(item, episodes)),
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
      children: [
        _posterHeader(item, meta, playLabel, episodes),
        ...belowHeader,
      ],
    );
  }

  /// The original poster-row header, kept exactly for items with no
  /// backdrop URL.
  Widget _posterHeader(
    VideoItem item,
    String meta,
    String playLabel,
    List<VideoItem> episodes,
  ) {
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
              const SizedBox(height: 8),
              if (item.genres.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: item.genres
                      .map((g) => Chip(label: Text(g)))
                      .toList(),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _play(_playTarget(item, episodes)),
                icon: const Icon(Icons.play_arrow),
                label: Text(playLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// What Play opens: for a series, the first unplayed episode (or the
  /// first episode); for a movie, the movie itself.
  VideoItem _playTarget(VideoItem item, List<VideoItem> episodes) {
    if (item.type != 'Series') return item;
    for (final episode in episodes) {
      if (episode.progress < 0.95) return episode;
    }
    return episodes.isNotEmpty ? episodes.first : item;
  }
}
