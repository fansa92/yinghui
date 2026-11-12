import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models/server.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../core/widgets/server_selector.dart';
import '../../core/widgets/state_views.dart';
import '../../data/models/video_item.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/video_repository.dart';
import '../../data/repositories/server_store.dart';
import '../servers/servers_page.dart';
import 'category_items_page.dart';
import 'poster_image.dart';
import 'video_detail_page.dart';

/// Video (Emby): hero poster, Continue Watching 2:3 posters with
/// progress, Recently Added, Movies/Series grids.
///
/// Wired to the real Emby API through [VideoRepository]; with no Emby
/// credentials it shows an explicit empty state instead of silently
/// presenting demo data.
///
/// A server selector sits at the top: "全部" (all Emby servers merged,
/// the default) or one server. The selection is per page and persisted
/// in [AppStateStore]; it only ever filters this page.
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.repo,
    required this.store,
    required this.history,
    required this.settings,
    this.appState,
  });

  final VideoRepository repo;
  final ServerStore store;
  final PlaybackStore history;
  final SettingsService settings;
  final AppStateStore? appState;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  static const _filters = ['电影', '剧集'];
  static const _pageSize = 20;

  String _filter = '电影';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  List<VideoItem> _continueWatching = [];
  List<RecentCategory> _recentCategories = [];
  List<VideoItem> _movies = [];
  List<VideoItem> _series = [];
  List<VideoItem>? _searchResult;

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  /// The store loads asynchronously: when an Emby account appears
  /// after this page first built, the lists load instead of staying on
  /// the empty state until the next tab switch.
  bool _hadCredentials = false;

  /// This page's server selection: a server id, or null for "全部".
  /// Restored from [AppStateStore] in initState; [effectiveServerId]
  /// sanitises it against the live server list.
  String? _serverId;

  /// Selected category in the 最近添加 section: a library name, or
  /// null for "全部" (all categories stacked). Local UI state only —
  /// it resets on reload, like the 电影/剧集 filter.
  String? _selectedCategory;

  /// The categories actually shown: all of them, or only the selected
  /// one when a category chip is tapped.
  List<RecentCategory> get _visibleCategories {
    final selected = _selectedCategory;
    if (selected == null) return _recentCategories;
    return _recentCategories.where((c) => c.name == selected).toList();
  }

  /// Emby server ids seen at the last store change, so a server added
  /// or removed while this page is open updates the selector.
  Set<String> _knownTypeIds = {};

  List<Server> get _typeServers =>
      widget.store.servers.where((s) => s.type == ServerType.emby).toList();

  /// The selection to actually query: null when nothing is selected
  /// or when the selected server no longer exists (deleted) — the
  /// page then falls back to "全部" instead of querying a ghost.
  String? get _effectiveServerId {
    final id = _serverId;
    if (id == null) return null;
    return _typeServers.any((s) => s.id == id) ? id : null;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _serverId = widget.appState?.videoServerId;
    _knownTypeIds = _typeServers.map((s) => s.id).toSet();
    _hadCredentials = widget.repo.hasCredentials;
    widget.store.addListener(_onStoreChanged);
    if (_hadCredentials) {
      _loadInitial();
    }
  }

  void _onStoreChanged() {
    final now = widget.repo.hasCredentials;
    if (now &&
        !_hadCredentials &&
        !_loading &&
        _continueWatching.isEmpty &&
        _movies.isEmpty &&
        _error == null) {
      _loadInitial();
    }
    _hadCredentials = now;
    // A server added or removed while this page is open must update
    // the selector; a deleted selected server falls back to "全部"
    // and the stale persisted value is cleared.
    final ids = _typeServers.map((s) => s.id).toSet();
    if (ids.length != _knownTypeIds.length || !ids.containsAll(_knownTypeIds)) {
      _knownTypeIds = ids;
      if (_serverId != null && !ids.contains(_serverId)) {
        _serverId = null;
        unawaited(widget.appState?.setVideoServerId(null));
      }
      if (mounted) setState(() {});
    }
  }

  /// Switch this page to one server (or null for "全部") and reload.
  /// The search is cleared: its results belong to the old selection.
  void _selectServer(String? id) {
    if (id == _effectiveServerId) return;
    setState(() {
      _serverId = id;
      _searchResult = null;
      _searchController.clear();
    });
    unawaited(widget.appState?.setVideoServerId(id));
    _loadInitial();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_searchResult != null || _loadingMore || !_hasMore) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final continuing = await widget.repo.continueWatching(
        serverId: _effectiveServerId,
      );
      final recent = await widget.repo.recentlyAddedByCategory(
        serverId: _effectiveServerId,
      );
      final movies = await widget.repo.movies(
        limit: _pageSize,
        serverId: _effectiveServerId,
      );
      final series = await widget.repo.series(
        limit: _pageSize,
        serverId: _effectiveServerId,
      );
      if (!mounted) return;
      setState(() {
        _continueWatching = continuing;
        _recentCategories = recent;
        _movies = movies;
        _series = series;
        _hasMore = (_filter == '电影' ? movies : series).length >= _pageSize;
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

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final more = _filter == '电影'
          ? await widget.repo.movies(
              limit: _pageSize,
              offset: _movies.length,
              serverId: _effectiveServerId,
            )
          : await widget.repo.series(
              limit: _pageSize,
              offset: _series.length,
              serverId: _effectiveServerId,
            );
      if (!mounted) return;
      setState(() {
        if (_filter == '电影') {
          _movies = [..._movies, ...more];
        } else {
          _series = [..._series, ...more];
        }
        _hasMore = more.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _searchResult = null);
      return;
    }
    widget.settings.recordSearch(q);
    setState(() => _loading = true);
    try {
      final result = await widget.repo.search(q, serverId: _effectiveServerId);
      if (!mounted) return;
      setState(() {
        _searchResult = result;
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

  void _openDetail(VideoItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailPage(
          item: item,
          repo: widget.repo,
          history: widget.history,
          settings: widget.settings,
          appState: widget.appState,
        ),
      ),
    );
  }

  void _openServers() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ServersPage(store: widget.store)),
    );
  }

  void _openCategory(RecentCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CategoryItemsPage(
          title: category.name,
          libraries: category.libraries,
          repo: widget.repo,
          history: widget.history,
          settings: widget.settings,
          appState: widget.appState,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.repo.hasCredentials) return _emptyState();
    if (_loading && _continueWatching.isEmpty && _searchResult == null) {
      return const LoadingView();
    }
    if (_error != null) {
      return ErrorView(message: '视频加载失败：\n$_error', onRetry: _loadInitial);
    }
    final hero = _continueWatching.isNotEmpty
        ? _continueWatching.first
        : (_recentCategories.isNotEmpty &&
                  _recentCategories.first.items.isNotEmpty
              ? _recentCategories.first.items.first
              : null);
    return CenteredContent(
      child: RefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ServerSelector(
                servers: _typeServers,
                selectedId: _effectiveServerId,
                onSelected: _selectServer,
                onManageServers: _openServers,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索电影和剧集',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _search('');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  // Theme-aware: the old YingHuiTheme.card (#1A1C22) is a
                  // dark box that does not belong in light mode.
                  fillColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                onChanged: (value) {
                  if (value.isEmpty) _search('');
                  setState(() {});
                },
              ),
            ),
            if (_searchResult != null) ...[
              if (_searchResult!.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: Text('没有找到结果。')),
                ),
              ..._searchResult!.map(_searchTile),
            ] else ...[
              if (hero != null) _heroCard(hero),
              const SizedBox(height: 16),
              if (_continueWatching.isNotEmpty) ...[
                const Text(
                  '继续观看',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 250,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _continueWatching.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final v = _continueWatching[i];
                      return SizedBox(
                        width: 120,
                        child: InkWell(
                          onTap: () => _openDetail(v),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              PosterImage(posterUrl: v.posterUrl),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: v.progress,
                                // Green = playback progress (amber is
                                // reserved for downloads). Track colour
                                // follows the theme, not hard-coded white.
                                color: Theme.of(context).colorScheme.primary,
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.12),
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                v.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              Text(
                                '已看 ${(v.progress * 100).toStringAsFixed(0)}%',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: YingHuiTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_recentCategories.isNotEmpty) ...[
                const Text(
                  '最近添加',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                // Category navigation: a horizontal chip row (全部 +
                // one chip per library). Tapping a chip shows only
                // that category's items; 全部 shows them all stacked.
                // With a single category there is nothing to navigate.
                if (_recentCategories.length > 1) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _categoryChip(null, '全部'),
                        for (final category in _recentCategories)
                          _categoryChip(category.name, category.name),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                for (final category in _visibleCategories) ...[
                  _categoryHeader(category),
                  const SizedBox(height: 8),
                  _categoryRow(category),
                  const SizedBox(height: 16),
                ],
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _filters.map((f) {
                    final selected = f == _filter;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f),
                        selected: selected,
                        onSelected: (_) => setState(() {
                          _filter = f;
                          _hasMore =
                              (f == '电影' ? _movies : _series).length >=
                              _pageSize;
                        }),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              ...(_filter == '电影' ? _movies : _series).map(_gridTile),
              if (_loadingMore)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _categoryChip(String? name, String label) {
    final selected = _selectedCategory == name;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _selectedCategory = name),
      ),
    );
  }

  /// A category's header row: the library name on the left and a
  /// "更多" button on the right (only when the category has a library
  /// behind it — the fake "最近添加" category has none, so no button).
  /// The fake category's name is also hidden: the section title above
  /// already says 最近添加.
  Widget _categoryHeader(RecentCategory category) {
    final showName = category.name != '最近添加';
    final showMore = category.libraries.isNotEmpty;
    if (!showName && !showMore) return const SizedBox.shrink();
    return Row(
      children: [
        if (showName)
          Text(
            category.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        const Spacer(),
        if (showMore)
          TextButton(
            onPressed: () => _openCategory(category),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('更多 ›'),
          ),
      ],
    );
  }

  /// One category's items as a horizontal poster row (same card shape
  /// as 继续观看）, not a vertical list — the page reads as a media
  /// browser, and the row scrolls without pushing the rest down.
  Widget _categoryRow(RecentCategory category) {
    return SizedBox(
      height: 230,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: category.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => _categoryCard(category.items[i]),
      ),
    );
  }

  Widget _categoryCard(VideoItem v) {
    final subtitle = [
      if (v.year != null) '${v.year}',
      v.typeLabel,
      if (v.episodeCountText != null) v.episodeCountText!,
    ].join(' · ');
    return SizedBox(
      width: 120,
      child: InkWell(
        onTap: () => _openDetail(v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PosterImage(posterUrl: v.posterUrl),
            const SizedBox(height: 4),
            Text(
              v.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: YingHuiTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroCard(VideoItem hero) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(hero),
        child: Stack(
          children: [
            SizedBox(
              height: 220,
              width: double.infinity,
              child: hero.backdropUrl != null
                  ? Image.network(
                      hero.backdropUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _heroPlaceholder(),
                    )
                  : _heroPlaceholder(),
            ),
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              bottom: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hero.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    '${hero.year ?? ''} · ${hero.durationText} · ${hero.sourceLabel}',
                    style: const TextStyle(color: YingHuiTheme.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _openDetail(hero),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      hero.playbackPositionSeconds > 0
                          ? '从 ${hero.positionText} 继续播放'
                          : '播放',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroPlaceholder() {
    return Container(
      color: YingHuiTheme.primaryGreen.withValues(alpha: 0.2),
      child: const Center(
        child: Icon(Icons.movie, size: 64, color: YingHuiTheme.primaryGreen),
      ),
    );
  }

  Widget _gridTile(VideoItem v) {
    final subtitle = [
      if (v.year != null) '${v.year}',
      v.typeLabel,
      v.durationText,
      if (v.episodeCountText != null) v.episodeCountText!,
    ].join(' · ');
    return ListTile(
      leading: PosterImage(
        posterUrl: v.posterUrl,
        width: 48,
        height: 72,
        borderRadius: 8,
      ),
      title: Text(v.title),
      subtitle: Text(subtitle),
      trailing: Text(
        v.sourceLabel,
        style: const TextStyle(color: YingHuiTheme.textMuted),
      ),
      onTap: () => _openDetail(v),
    );
  }

  Widget _searchTile(VideoItem v) => _gridTile(v);

  Widget _emptyState() {
    return EmptyView(
      icon: Icons.movie_outlined,
      title: '还没有 Emby 账号',
      subtitle: '在“服务器”里添加 Emby 服务器，这里就会显示你的电影和剧集。',
      actionLabel: '去服务器页',
      onAction: _openServers,
    );
  }
}
