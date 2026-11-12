import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../core/proxy_config.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/track.dart';

/// Navidrome client — the Subsonic API, its own native protocol.
///
/// Auth is the salted-MD5 scheme: `t = md5(password + salt)`, sent as
/// query params `u` (user), `t`, `s` (salt), plus `c` (client), `v`
/// (API version) and `f=json`. No generic wrapper: every call below is a
/// real Subsonic endpoint. Secrets are never logged.
class SubsonicClient {
  SubsonicClient(this.server, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              // Trailing slash matters: Dio resolves a relative path
              // against baseUrl, so 'rest/...' keeps a subpath in the
              // server URL. A leading '/' would drop it.
              baseUrl: _baseUrlWithSlash(server),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            ),
          ) {
    DioProxy.apply(this.dio);
  }

  final Server server;
  final Dio dio;

  /// Base URL with a trailing slash, so relative request paths resolve
  /// under a subpath (e.g. https://host/music/ + rest/...).
  static String _baseUrlWithSlash(Server server) {
    final base = server.baseUrl;
    return base.endsWith('/') ? base : '$base/';
  }

  /// Base URL without a trailing slash, for string-built URLs — a
  /// trailing slash here would produce '//rest/...'.
  String get _baseNoSlash {
    final base = server.baseUrl;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  static const String clientName = 'YingHui';
  static const String apiVersion = '1.16.1';

  /// Pure, unit-testable auth params. [salt] is random per request in
  /// production; tests pass a fixed salt.
  static Map<String, String> buildAuthParams(
    String username,
    String password, {
    required String salt,
  }) {
    final token = md5.convert(utf8.encode(password + salt)).toString();
    return {
      'u': username,
      't': token,
      's': salt,
      'c': clientName,
      'v': apiVersion,
      'f': 'json',
    };
  }

  Map<String, String> _authParams() {
    final random = Random.secure();
    final salt = List.generate(
      12,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return buildAuthParams(server.username, server.token, salt: salt);
  }

  /// GET `/rest/<endpoint>` with auth params. Returns the
  /// `subsonic-response` body, or throws [ApiException] on a Subsonic
  /// `status: failed` or a transport error.
  Future<Map<String, dynamic>> _get(
    String endpoint, [
    Map<String, dynamic> extra = const {},
  ]) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'rest/$endpoint',
        queryParameters: {..._authParams(), ...extra},
      );
      final body =
          (response.data?['subsonic-response'] as Map<String, dynamic>?) ?? {};
      if (body['status'] != 'ok') {
        final error = body['error'] as Map<String, dynamic>?;
        throw ApiException(
          'Subsonic error: ${error?['message'] ?? 'unknown'}',
          statusCode: response.statusCode,
        );
      }
      return body;
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException(
        'Subsonic request failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// GET /rest/ping — true when the server answers `status: ok`.
  Future<bool> testConnection() async {
    final body = await _get('ping');
    return body['status'] == 'ok';
  }

  /// Unauthenticated probe: GET /rest/ping.view with only c/v/f.
  /// A live Subsonic/Navidrome server answers HTTP 200 with a
  /// `subsonic-response` even when auth is missing (status failed,
  /// error code 10 "missing parameter: 'u'" or 40 "wrong username or
  /// password"). That proves the server is reachable — it needs auth,
  /// it is not unreachable. Pure parsing lives in [parseProbeResponse]
  /// so tests can cover it without a network.
  static ConnectionResult parseProbeResponse(Map<String, dynamic> body) {
    final response =
        (body['subsonic-response'] as Map<String, dynamic>?) ?? body;
    final version =
        response['serverVersion'] as String? ?? response['version'] as String?;
    if (response['status'] == 'ok') {
      return ConnectionResult.ok(message: '已连接', serverVersion: version);
    }
    final error = response['error'] as Map<String, dynamic>?;
    final code = (error?['code'] as num?)?.toInt();
    final message = '${error?['message'] ?? 'authentication required'}';
    // 10 = required parameter missing, 40 = wrong username/password:
    // the server is alive and speaking Subsonic, it just needs auth.
    if (code == 10 || code == 40) {
      return ConnectionResult.needsAuth(
        message: '服务器可达，需要登录（$message）',
        serverVersion: version,
      );
    }
    if (error != null) {
      return ConnectionResult.needsAuth(
        message: '服务器可达：$message',
        serverVersion: version,
      );
    }
    return ConnectionResult.unreachable(message: 'Subsonic 返回异常');
  }

  /// Structured connectivity check. Probes without auth first; if the
  /// probe says "needs auth" and credentials are present, tries an
  /// authenticated ping and returns `ok` when it succeeds.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'rest/ping.view',
        queryParameters: {'c': clientName, 'v': apiVersion, 'f': 'json'},
      );
      final probe = parseProbeResponse(response.data ?? {});
      if (probe.status != ConnectionStatus.needsAuth) return probe;
      if (server.username.isEmpty || server.token.isEmpty) return probe;
      try {
        final body = await _get('ping');
        if (body['status'] == 'ok') {
          return ConnectionResult.ok(
            message: '已连接',
            serverVersion: probe.serverVersion,
          );
        }
      } on ApiException {
        // Authenticated ping failed: the probe already proved the
        // server is reachable, so it still needs auth.
      }
      return probe;
    } on DioException catch (e) {
      if (e.response != null) {
        return ConnectionResult.unreachable(
          message: 'HTTP ${e.response?.statusCode}',
        );
      }
      return ConnectionResult.unreachable(
        message: '无法连接：${e.message ?? e.type.name}',
      );
    }
  }

  /// A Subsonic list field as a list of objects. Some servers return a
  /// single bare object instead of a one-element list — and a bare
  /// `as List?` cast would throw on it. Null stays empty.
  static List<Map<String, dynamic>> _asList(dynamic value) {
    if (value is List) {
      return value.whereType<Map<String, dynamic>>().toList();
    }
    if (value is Map<String, dynamic>) return [value];
    return [];
  }

  /// GET /rest/getAlbumList2?type=newest|alphabeticalByName|...
  Future<List<Album>> getAlbumList2({
    String type = 'newest',
    int size = 20,
    int offset = 0,
  }) async {
    final body = await _get('getAlbumList2', {
      'type': type,
      'size': size,
      'offset': offset,
    });
    final list = body['albumList2'] as Map<String, dynamic>?;
    final albums = _asList(list?['album']);
    return albums.map((a) => _albumFromJson(a)).toList();
  }

  /// GET /rest/search3?query=... (songs only, kept for compatibility).
  Future<List<Track>> search3(String query) async {
    final body = await _get('search3', {'query': query});
    final result = body['searchResult3'] as Map<String, dynamic>?;
    final songs = _asList(result?['song']);
    return songs.map((s) => _trackFromJson(s)).toList();
  }

  /// GET /rest/search3?query=... — songs, albums and artists together.
  Future<({List<Track> songs, List<Album> albums, List<Artist> artists})>
  searchAll(String query) async {
    final body = await _get('search3', {'query': query});
    final result = body['searchResult3'] as Map<String, dynamic>?;
    final songs = _asList(result?['song']).map(_trackFromJson).toList();
    final albums = _asList(result?['album']).map(_albumFromJson).toList();
    final artists = _asList(result?['artist']).map(_artistFromJson).toList();
    return (songs: songs, albums: albums, artists: artists);
  }

  /// GET /rest/getArtists — the full artist index, flattened.
  Future<List<Artist>> getArtists() async {
    final body = await _get('getArtists');
    final artists = body['artists'] as Map<String, dynamic>?;
    final indexes = _asList(artists?['index']);
    final out = <Artist>[];
    for (final index in indexes) {
      for (final a in _asList(index['artist'])) {
        out.add(_artistFromJson(a));
      }
    }
    return out;
  }

  /// GET /rest/getAlbum?id=... — album metadata + its track list.
  Future<({Album album, List<Track> tracks})> getAlbum(String id) async {
    final body = await _get('getAlbum', {'id': id});
    final albumJson = body['album'] as Map<String, dynamic>? ?? {};
    final album = _albumFromJson(albumJson);
    final songs = _asList(albumJson['song']);
    return (album: album, tracks: songs.map(_trackFromJson).toList());
  }

  /// GET /rest/getStarred2 — starred songs and albums.
  Future<({List<Track> songs, List<Album> albums})> getStarred2() async {
    final body = await _get('getStarred2');
    final starred = body['starred2'] as Map<String, dynamic>?;
    final songs = _asList(starred?['song']).map(_trackFromJson).toList();
    final albums = _asList(starred?['album']).map(_albumFromJson).toList();
    return (songs: songs, albums: albums);
  }

  /// GET /rest/star?id=... (or albumId=...) / unstar — returns true on ok.
  Future<bool> _setStar(bool star, {String? id, String? albumId}) async {
    final params = <String, dynamic>{};
    if (id != null) params['id'] = id;
    if (albumId != null) params['albumId'] = albumId;
    final body = await _get(star ? 'star' : 'unstar', params);
    return body['status'] == 'ok';
  }

  Future<bool> star({String? id, String? albumId}) =>
      _setStar(true, id: id, albumId: albumId);

  Future<bool> unstar({String? id, String? albumId}) =>
      _setStar(false, id: id, albumId: albumId);

  /// GET /rest/getPlaylists.
  Future<List<Playlist>> getPlaylists() async {
    final body = await _get('getPlaylists');
    final list = body['playlists'] as Map<String, dynamic>?;
    final playlists = _asList(list?['playlist']);
    return playlists.map((p) {
      return Playlist(
        id: '${p['id']}',
        name: '${p['name'] ?? ''}',
        songCount: (p['songCount'] as num?)?.toInt() ?? 0,
        serverId: server.id,
        sourceLabel: server.name,
      );
    }).toList();
  }

  /// GET /rest/getPlaylist?id=... — the playlist's tracks.
  Future<List<Track>> getPlaylist(String id) async {
    final body = await _get('getPlaylist', {'id': id});
    final playlist = body['playlist'] as Map<String, dynamic>?;
    final entries = _asList(playlist?['entry']);
    return entries.map(_trackFromJson).toList();
  }

  /// GET /rest/getGenres — cheap list of genre names.
  Future<List<String>> getGenres() async {
    final body = await _get('getGenres');
    final genres = body['genres'] as Map<String, dynamic>?;
    final list = _asList(genres?['genre']);
    return list
        .map((g) => '${g['value'] ?? g['name'] ?? ''}')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// GET /rest/getSong?id=...
  Future<Track?> getSong(String id) async {
    final body = await _get('getSong', {'id': id});
    final song = body['song'] as Map<String, dynamic>?;
    return song == null ? null : _trackFromJson(song);
  }

  /// Direct stream URL for a song (with auth params, for the player).
  String streamUrl(String songId, {int maxBitRate = 0}) {
    final params = {
      ..._authParams(),
      'id': songId,
      if (maxBitRate > 0) 'maxBitRate': maxBitRate.toString(),
    };
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$_baseNoSlash/rest/stream?$query';
  }

  /// Cover-art URL for an album/song cover id.
  String coverArtUrl(String coverArtId, {int size = 300}) {
    final params = {..._authParams(), 'id': coverArtId, 'size': '$size'};
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$_baseNoSlash/rest/getCoverArt?$query';
  }

  Artist _artistFromJson(Map<String, dynamic> json) {
    return Artist(
      id: '${json['id']}',
      name: '${json['name'] ?? ''}',
      albumCount: (json['albumCount'] as num?)?.toInt() ?? 0,
      serverId: server.id,
      sourceLabel: server.name,
    );
  }

  Album _albumFromJson(Map<String, dynamic> json) {
    // coverArt is usually a string id, but some Subsonic servers send
    // a number — stringify instead of `as String?`, which would throw.
    final coverArt = json['coverArt'];
    return Album(
      id: '${json['id']}',
      title: '${json['name'] ?? json['title'] ?? ''}',
      artist: '${json['artist'] ?? ''}',
      coverUrl: coverArt == null ? null : coverArtUrl('$coverArt'),
      year: (json['year'] as num?)?.toInt(),
      trackCount: (json['songCount'] as num?)?.toInt() ?? 0,
      serverId: server.id,
      sourceLabel: server.name,
    );
  }

  Track _trackFromJson(Map<String, dynamic> json) {
    final coverArt = json['coverArt'];
    return Track(
      id: '${json['id']}',
      title: '${json['title'] ?? ''}',
      artist: '${json['artist'] ?? ''}',
      album: '${json['album'] ?? ''}',
      albumId: '${json['albumId'] ?? ''}',
      durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
      coverUrl: coverArt == null ? null : coverArtUrl('$coverArt'),
      serverId: server.id,
      sourceLabel: server.name,
    );
  }
}
