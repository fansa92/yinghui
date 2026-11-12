import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../core/widgets/state_views.dart';
import '../../data/models/video_item.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/video_repository.dart';
import 'poster_image.dart';
import 'video_detail_page.dart';

/// A library's full list, opened from a category's "更多" button.
///
/// All items of [libraries] via the existing Emby items query by
/// ParentId, paginated (20 per page, infinite scroll), merged and
/// title+year deduped by the repo. The libraries carry their server
/// ids, so the page stays scoped to the same server filter the
/// category came from — no separate filter of its own.
class CategoryItemsPage extends StatefulWidget {
  const CategoryItemsPage({
    super.key,
    required this.title,
    required this.libraries,
    required this.repo,
    required this.history,
    required this.settings,
    this.appState,
  });

  final String title;
  final List<LibraryRef> libraries;
  final VideoRepository repo;
  final PlaybackStore history;
  final SettingsService settings;
  final AppStateStore? appState;

  @override
  State<CategoryItemsPage> createState() => _CategoryItemsPageState();
}

class _CategoryItemsPageState extends State<CategoryItemsPage> {
  static const _pageSize = 20;

  final _scrollController = ScrollController();
  List<VideoItem> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore) return;
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
      final items = await widget.repo.libraryItems(
        libraries: widget.libraries,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _hasMore = items.length >= _pageSize;
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
      final more = await widget.repo.libraryItems(
        libraries: widget.libraries,
        limit: _pageSize,
        offset: _items.length,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...more];
        _hasMore = more.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading && _items.isEmpty
          ? const LoadingView()
          : _error != null
          ? ErrorView(message: '加载失败：\n$_error', onRetry: _loadInitial)
          : CenteredContent(
              child: RefreshIndicator(
                onRefresh: _loadInitial,
                child: _items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 64),
                            child: Center(child: Text('这个分类里还没有内容。')),
                          ),
                        ],
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        itemCount: _items.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _items.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return _tile(_items[i]);
                        },
                      ),
              ),
            ),
    );
  }

  Widget _tile(VideoItem v) {
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
}
