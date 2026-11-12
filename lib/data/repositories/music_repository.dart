import '../../core/errors.dart';
import '../../core/models/server.dart';
import '../api/subsonic_client.dart';
import '../db/app_database.dart';
import '../models/track.dart';
import 'fake_repos.dart';
import 'playback_store.dart';
import 'server_store.dart';

/// What the Music tab needs, regardless of where the data comes from.
abstract class MusicRepository {
  /// True when at least one Navidrome server has a username + password.
  bool get hasCredentials;

  Future<List<Album>> albums({
    String type = 'newest',
    int size = 20,
    int offset = 0,
  });
  Future<List<Artist>> artists();
  Future<({List<Track> songs, List<Album> albums, List<Artist> artists})>
  search(String query);
  Future<({Album album, List<Track> tracks})> album(
    String albumId,
    String serverId,
  );
  Future<({List<Track> songs, List<Album> albums})> starred();
  Future<List<Playlist>> playlists();
  Future<List<Track>> playlistTracks(String playlistId, String serverId);
  Future<bool> toggleStarTrack(Track track);
  Future<bool> toggleStarAlbum(Album album);
  Future<bool> isStarredTrack(Track track);
  Future<bool> isStarredAlbum(Album album);
  String streamUrlFor(Track track, {int maxBitRate = 0});
}

/// Real music repository: Navidrome (Subsonic) servers, merged.
///
/// One [SubsonicClient] per credentialed Navidrome server. Results are
/// merged across servers and deduped by title+artist(+album); a server
/// that is offline throws per-server [ApiException], which is caught
/// here so one dead server never blanks the whole list. With no
/// credentialed Navidrome server, the P0 fake repo is the fallback
/// (the Music page still shows an explicit empty state instead of
/// silently presenting demo data as real data).
class RealMusicRepository implements MusicRepository {
  RealMusicRepository({
    required this.store,
    required AppDatabase database,
    SubsonicClient Function(Server server)? clientFactory,
  }) : _playback = PlaybackStore(database),
       _clientFactory = clientFactory ?? ((s) => SubsonicClient(s));

  final ServerStore store;
  final PlaybackStore _playback;
  final SubsonicClient Function(Server server) _clientFactory;

  /// One client per credentialed server, cached across calls. A fresh
  /// client per access would re-create the Dio (and any per-client
  /// state) on every repository call; the cache is keyed by server id
  /// and rebuilt when the server's host or credentials change.
  final Map<String, (String fingerprint, SubsonicClient client)> _clientCache =
      {};

  List<Server> get _credentialedNavidrome => store.servers
      .where(
        (s) =>
            s.type == ServerType.navidrome &&
            s.username.isNotEmpty &&
            s.token.isNotEmpty,
      )
      .toList();

  @override
  bool get hasCredentials => _credentialedNavidrome.isNotEmpty;

  List<(Server, SubsonicClient)> get _clients {
    final servers = _credentialedNavidrome;
    final out = <(Server, SubsonicClient)>[];
    final seen = <String>{};
    for (final s in servers) {
      seen.add(s.id);
      final fingerprint = '${s.host}|${s.username}|${s.token}';
      final cached = _clientCache[s.id];
      if (cached != null && cached.$1 == fingerprint) {
        out.add((s, cached.$2));
      } else {
        final client = _clientFactory(s);
        _clientCache[s.id] = (fingerprint, client);
        out.add((s, client));
      }
    }
    _clientCache.removeWhere((id, _) => !seen.contains(id));
    return out;
  }

  SubsonicClient? _clientFor(String serverId) {
    for (final (server, client) in _clients) {
      if (server.id == serverId) return client;
    }
    return null;
  }

  Server? _serverFor(String serverId) {
    for (final s in store.servers) {
      if (s.id == serverId) return s;
    }
    return null;
  }

  /// Run [fetch] on every credentialed server, skipping servers that
  /// fail, and merge + dedupe the results by [key].
  Future<List<T>> _merged<T>(
    Future<List<T>> Function(SubsonicClient client) fetch,
    String Function(T item) key,
  ) async {
    final out = <T>[];
    final seen = <String>{};
    for (final (_, client) in _clients) {
      List<T> items;
      try {
        items = await fetch(client);
      } on ApiException {
        continue;
      }
      for (final item in items) {
        if (seen.add(key(item))) out.add(item);
      }
    }
    return out;
  }

  @override
  Future<List<Album>> albums({
    String type = 'newest',
    int size = 20,
    int offset = 0,
  }) async {
    if (!hasCredentials) return FakeMusicRepo.albums;
    return _merged<Album>(
      (c) => c.getAlbumList2(type: type, size: size, offset: offset),
      (a) => '${a.title.toLowerCase()}|${a.artist.toLowerCase()}',
    );
  }

  @override
  Future<List<Artist>> artists() async {
    if (!hasCredentials) return [];
    return _merged<Artist>((c) => c.getArtists(), (a) => a.name.toLowerCase());
  }

  @override
  Future<({List<Track> songs, List<Album> albums, List<Artist> artists})>
  search(String query) async {
    if (!hasCredentials) {
      final q = query.toLowerCase();
      final songs = FakeMusicRepo.tracks
          .where(
            (t) =>
                t.title.toLowerCase().contains(q) ||
                t.artist.toLowerCase().contains(q) ||
                t.album.toLowerCase().contains(q),
          )
          .toList();
      final albums = FakeMusicRepo.albums
          .where(
            (a) =>
                a.title.toLowerCase().contains(q) ||
                a.artist.toLowerCase().contains(q),
          )
          .toList();
      return (songs: songs, albums: albums, artists: <Artist>[]);
    }
    final results =
        <({List<Track> songs, List<Album> albums, List<Artist> artists})>[];
    for (final (_, client) in _clients) {
      try {
        results.add(await client.searchAll(query));
      } on ApiException {
        continue;
      }
    }
    List<T> dedupe<T>(List<T> items, String Function(T) key) {
      final out = <T>[];
      final seen = <String>{};
      for (final item in items) {
        if (seen.add(key(item))) out.add(item);
      }
      return out;
    }

    final songs = dedupe<Track>(
      [for (final r in results) ...r.songs],
      (t) =>
          '${t.title.toLowerCase()}|${t.artist.toLowerCase()}|'
          '${t.album.toLowerCase()}',
    );
    final albums = dedupe<Album>([
      for (final r in results) ...r.albums,
    ], (a) => '${a.title.toLowerCase()}|${a.artist.toLowerCase()}');
    final artists = dedupe<Artist>([
      for (final r in results) ...r.artists,
    ], (a) => a.name.toLowerCase());
    return (songs: songs, albums: albums, artists: artists);
  }

  @override
  Future<({Album album, List<Track> tracks})> album(
    String albumId,
    String serverId,
  ) async {
    final client = _clientFor(serverId);
    if (client == null) {
      final fake = FakeMusicRepo.albums.firstWhere(
        (a) => a.id == albumId,
        orElse: () => FakeMusicRepo.albums.first,
      );
      final tracks = FakeMusicRepo.tracks
          .where((t) => t.albumId == albumId)
          .toList();
      return (
        album: fake,
        tracks: tracks.isNotEmpty ? tracks : FakeMusicRepo.tracks,
      );
    }
    return client.getAlbum(albumId);
  }

  @override
  Future<({List<Track> songs, List<Album> albums})> starred() async {
    if (!hasCredentials) return (songs: <Track>[], albums: <Album>[]);
    final results = <({List<Track> songs, List<Album> albums})>[];
    for (final (_, client) in _clients) {
      try {
        results.add(await client.getStarred2());
      } on ApiException {
        continue;
      }
    }
    List<T> dedupe<T>(List<T> items, String Function(T) key) {
      final out = <T>[];
      final seen = <String>{};
      for (final item in items) {
        if (seen.add(key(item))) out.add(item);
      }
      return out;
    }

    final songs = dedupe<Track>(
      [for (final r in results) ...r.songs],
      (t) =>
          '${t.title.toLowerCase()}|${t.artist.toLowerCase()}|'
          '${t.album.toLowerCase()}',
    );
    final albums = dedupe<Album>([
      for (final r in results) ...r.albums,
    ], (a) => '${a.title.toLowerCase()}|${a.artist.toLowerCase()}');
    return (songs: songs, albums: albums);
  }

  @override
  Future<List<Playlist>> playlists() async {
    if (!hasCredentials) return [];
    return _merged<Playlist>(
      (c) => c.getPlaylists(),
      (p) => p.name.toLowerCase(),
    );
  }

  @override
  Future<List<Track>> playlistTracks(String playlistId, String serverId) async {
    final client = _clientFor(serverId);
    if (client == null) return [];
    return client.getPlaylist(playlistId);
  }

  @override
  Future<bool> toggleStarTrack(Track track) async {
    final client = _clientFor(track.serverId);
    var starred = await _playback.isStarred(
      kind: 'track',
      serverId: track.serverId,
      itemId: track.id,
    );
    if (client != null) {
      try {
        await (starred
            ? client.unstar(id: track.id)
            : client.star(id: track.id));
      } on ApiException {
        // Server unreachable: the local favourite still flips.
      }
    }
    starred = await _playback.toggleStar(
      kind: 'track',
      serverId: track.serverId,
      itemId: track.id,
      title: track.title,
    );
    return starred;
  }

  @override
  Future<bool> toggleStarAlbum(Album album) async {
    final client = _clientFor(album.serverId);
    var starred = await _playback.isStarred(
      kind: 'album',
      serverId: album.serverId,
      itemId: album.id,
    );
    if (client != null) {
      try {
        await (starred
            ? client.unstar(albumId: album.id)
            : client.star(albumId: album.id));
      } on ApiException {
        // Server unreachable: the local favourite still flips.
      }
    }
    starred = await _playback.toggleStar(
      kind: 'album',
      serverId: album.serverId,
      itemId: album.id,
      title: album.title,
    );
    return starred;
  }

  @override
  Future<bool> isStarredTrack(Track track) => _playback.isStarred(
    kind: 'track',
    serverId: track.serverId,
    itemId: track.id,
  );

  @override
  Future<bool> isStarredAlbum(Album album) => _playback.isStarred(
    kind: 'album',
    serverId: album.serverId,
    itemId: album.id,
  );

  @override
  String streamUrlFor(Track track, {int maxBitRate = 0}) {
    final server = _serverFor(track.serverId);
    if (server == null) return '';
    return SubsonicClient(server).streamUrl(track.id, maxBitRate: maxBitRate);
  }
}
