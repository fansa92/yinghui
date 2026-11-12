import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models/server.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/widgets/desktop_layout.dart';
import '../../core/widgets/server_selector.dart';
import '../../core/widgets/state_views.dart';
import '../../data/models/track.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/server_store.dart';
import '../player/player_service.dart';
import '../servers/servers_page.dart';
import 'album_detail_page.dart';
import 'cover_image.dart';
import 'track_list_page.dart';

/// Music (Navidrome): filter chips, album grid with cover art,
/// search, album detail, favourites. Wired to the real Subsonic API
/// through [MusicRepository]; with no Navidrome credentials it shows an
/// explicit empty state instead of silently presenting demo data.
/// The grid is 2 columns on phones, 4 on desktop (>= 1024 wide).
///
/// A server selector sits at the top: "全部" (all Navidrome servers
/// merged, the default) or one server. The selection is per page and
/// persisted in [AppStateStore]; it only ever filters this page.
class MusicPage extends StatefulWidget {
  const MusicPage({
    super.key,
    required this.repo,
    required this.player,
    required this.store,
    required this.settings,
    this.appState,
  });

  final MusicRepository repo;
  final PlayerService player;
  final ServerStore store;
  final SettingsService settings;

  /// Optional global state: this page's server selection is restored
  /// from it on open and saved back on every change.
  final AppStateStore? appState;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  static const _filters = ['Albums', 'Artists', 'Playlists', 'Favorites'];
  static const _pageSize = 20;

  String _filter = 'Albums';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  List<Album> _albums = [];
  List<Artist> _artists = [];
  List<Playlist> _playlists = [];
  List<Track> _starredSongs = [];
  List<Album> _starredAlbums = [];

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  ({List<Track> songs, List<Album> albums, List<Artist> artists})?
  _searchResult;

  /// The store loads asynchronously: when a Navidrome account appears
  /// after this page first built, the list loads instead of staying on
  /// the empty state until the next tab switch.
  bool _hadCredentials = false;

  /// This page's server selection: a server id, or null for "全部".
  /// Restored from [AppStateStore] in initState; [effectiveServerId]
  /// sanitises it against the live server list.
  String? _serverId;

  /// Navidrome server ids seen at the last store change, so a server
  /// added or removed while this page is open updates the selector.
  Set<String> _knownTypeIds = {};

  List<Server> get _typeServers => widget.store.servers
      .where((s) => s.type == ServerType.navidrome)
      .toList();

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
    _serverId = widget.appState?.musicServerId;
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
        _albums.isEmpty &&
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
        unawaited(widget.appState?.setMusicServerId(null));
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
    unawaited(widget.appState?.setMusicServerId(id));
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
    if (_filter != 'Albums' || _searchResult != null) return;
    if (!_scrollController.hasClients || _loadingMore || !_hasMore) return;
    final max = _scrollController.position.maxScrollExtent;
    if (_scrollController.position.pixels >= max - 400) {
      _loadMoreAlbums();
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final albums = await widget.repo.albums(
        size: _pageSize,
        serverId: _effectiveServerId,
      );
      final artists = await widget.repo.artists(serverId: _effectiveServerId);
      final playlists = await widget.repo.playlists(
        serverId: _effectiveServerId,
      );
      final starred = await widget.repo.starred(serverId: _effectiveServerId);
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _artists = artists;
        _playlists = playlists;
        _starredSongs = starred.songs;
        _starredAlbums = starred.albums;
        _hasMore = albums.length >= _pageSize;
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

  Future<void> _loadMoreAlbums() async {
    setState(() => _loadingMore = true);
    try {
      final more = await widget.repo.albums(
        size: _pageSize,
        offset: _albums.length,
        serverId: _effectiveServerId,
      );
      if (!mounted) return;
      setState(() {
        _albums = [..._albums, ...more];
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

  void _openServers() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ServersPage(store: widget.store)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.repo.hasCredentials) return _emptyState();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ServerSelector(
            servers: _typeServers,
            selectedId: _effectiveServerId,
            onSelected: _selectServer,
            onManageServers: _openServers,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search songs, albums, artists',
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
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: _filters.map((f) {
              final selected = f == _filter;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f),
                  selected: selected,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: _loading && _albums.isEmpty && _searchResult == null
              ? const LoadingView()
              : _error != null
              ? ErrorView(
                  message: 'Could not load music:\n$_error',
                  onRetry: _loadInitial,
                )
              : _searchResult != null
              ? _searchResults()
              : _filterBody(),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return EmptyView(
      icon: Icons.music_off_outlined,
      title: 'No Navidrome account yet',
      subtitle: 'Add your Navidrome server in Servers to see your music here.',
      actionLabel: 'Open Servers',
      onAction: _openServers,
    );
  }

  Widget _searchResults() {
    final result = _searchResult!;
    if (result.songs.isEmpty &&
        result.albums.isEmpty &&
        result.artists.isEmpty) {
      return const Center(child: Text('No results.'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (result.songs.isNotEmpty) ...[
          const _SectionTitle('Songs'),
          ...result.songs.map(
            (t) => ListTile(
              leading: CoverImage(coverUrl: t.coverUrl),
              title: Text(t.title),
              subtitle: Text('${t.artist} · ${t.album}'),
              trailing: Text(t.durationText),
              onTap: () => widget.player.playQueue(
                result.songs,
                startIndex: result.songs.indexOf(t),
              ),
            ),
          ),
        ],
        if (result.albums.isNotEmpty) ...[
          const _SectionTitle('Albums'),
          ...result.albums.map(
            (a) => ListTile(
              leading: CoverImage(coverUrl: a.coverUrl),
              title: Text(a.title),
              subtitle: Text('${a.artist} · ${a.year ?? ''}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AlbumDetailPage(
                    album: a,
                    repo: widget.repo,
                    player: widget.player,
                    settings: widget.settings,
                  ),
                ),
              ),
            ),
          ),
        ],
        if (result.artists.isNotEmpty) ...[
          const _SectionTitle('Artists'),
          ...result.artists.map(
            (a) => ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(a.name),
              subtitle: Text('${a.albumCount} albums'),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _filterBody() {
    switch (_filter) {
      case 'Artists':
        if (_artists.isEmpty) {
          return const Center(child: Text('No artists yet.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _artists.length,
          itemBuilder: (context, i) {
            final a = _artists[i];
            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(a.name),
              subtitle: Text('${a.albumCount} albums · ${a.sourceLabel}'),
            );
          },
        );
      case 'Playlists':
        if (_playlists.isEmpty) {
          return const Center(child: Text('No playlists yet.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _playlists.length,
          itemBuilder: (context, i) {
            final p = _playlists[i];
            return ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: YingHuiTheme.primaryGreen.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.queue_music,
                  color: YingHuiTheme.primaryGreen,
                ),
              ),
              title: Text(p.name),
              subtitle: Text('${p.songCount} songs · ${p.sourceLabel}'),
              onTap: () async {
                final tracks = await widget.repo.playlistTracks(
                  p.id,
                  p.serverId,
                );
                if (!context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TrackListPage(
                      title: p.name,
                      tracks: tracks,
                      repo: widget.repo,
                      player: widget.player,
                    ),
                  ),
                );
              },
            );
          },
        );
      case 'Favorites':
        if (_starredSongs.isEmpty && _starredAlbums.isEmpty) {
          return const Center(child: Text('No favourites yet.'));
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            if (_starredAlbums.isNotEmpty) ...[
              const _SectionTitle('Starred albums'),
              ..._starredAlbums.map(
                (a) => ListTile(
                  leading: CoverImage(coverUrl: a.coverUrl),
                  title: Text(a.title),
                  subtitle: Text(a.artist),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AlbumDetailPage(
                        album: a,
                        repo: widget.repo,
                        player: widget.player,
                        settings: widget.settings,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_starredSongs.isNotEmpty) ...[
              const _SectionTitle('Starred songs'),
              ..._starredSongs.map(
                (t) => ListTile(
                  leading: CoverImage(coverUrl: t.coverUrl),
                  title: Text(t.title),
                  subtitle: Text('${t.artist} · ${t.album}'),
                  trailing: Text(t.durationText),
                  onTap: () => widget.player.playQueue(
                    _starredSongs,
                    startIndex: _starredSongs.indexOf(t),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
          ],
        );
      case 'Albums':
      default:
        if (_albums.isEmpty) {
          return RefreshIndicator(
            onRefresh: _loadInitial,
            child: ListView(
              children: const [
                SizedBox(height: 120),
                Center(child: Text('No albums yet.')),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _loadInitial,
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: gridColumnsForWidth(
                MediaQuery.of(context).size.width,
              ),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.85,
            ),
            itemCount: _albums.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= _albums.length) {
                return const Center(child: CircularProgressIndicator());
              }
              final a = _albums[i];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AlbumDetailPage(
                        album: a,
                        repo: widget.repo,
                        player: widget.player,
                        settings: widget.settings,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SizedBox(
                          width: double.infinity,
                          child: a.coverUrl == null
                              ? Container(
                                  color: YingHuiTheme.primaryGreen.withValues(
                                    alpha: 0.2,
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.album,
                                      size: 48,
                                      color: YingHuiTheme.primaryGreen,
                                    ),
                                  ),
                                )
                              : CoverImage(
                                  coverUrl: a.coverUrl,
                                  fill: true,
                                  borderRadius: 0,
                                ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${a.artist} · ${a.year ?? ''}',
                              style: const TextStyle(
                                color: YingHuiTheme.textMuted,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              a.sourceLabel,
                              style: const TextStyle(
                                color: YingHuiTheme.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
    );
  }
}
