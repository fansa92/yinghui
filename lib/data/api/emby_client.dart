import 'package:dio/dio.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/track.dart';
import '../models/video_detail.dart';
import '../models/video_item.dart';

/// Emby client — its own native REST API.
///
/// Auth: POST /Users/AuthenticateByName with the
/// `X-Emby-Authorization` header; the returned `AccessToken` is stored on
/// the [Server] (via secure storage) and sent as `X-Emby-Token` afterwards.
/// No generic wrapper: every call below is a real Emby endpoint.
class EmbyClient {
  EmbyClient(this.server, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              // Trailing slash matters: Dio resolves a relative path
              // against baseUrl, so 'Users/...' keeps a subpath in the
              // server URL. A leading '/' would drop it.
              baseUrl: _baseUrlWithSlash(server),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final Server server;
  final Dio dio;

  /// Base URL with a trailing slash, so relative request paths resolve
  /// under a subpath.
  static String _baseUrlWithSlash(Server server) {
    final base = server.baseUrl;
    return base.endsWith('/') ? base : '$base/';
  }

  /// Base URL without a trailing slash, for string-built URLs — a
  /// trailing slash here would produce '//Videos/...'.
  String get _baseNoSlash {
    final base = server.baseUrl;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  static const String clientName = 'YingHui';
  static const String deviceId = 'yinghui-flutter-01';
  static const String version = '0.1.0';

  Map<String, String> get _authHeader => {
    'X-Emby-Authorization':
        'MediaBrowser Client="$clientName", Device="Flutter", '
        'DeviceId="$deviceId", Version="$version"',
  };

  Map<String, String> get _tokenHeader =>
      server.token.isEmpty ? {} : {'X-Emby-Token': server.token};

  /// POST /Users/AuthenticateByName. Returns the access token; the caller
  /// stores it on the server (secure storage). Throws [ApiException] on
  /// bad credentials (401) or transport errors.
  Future<String> authenticate() async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        'Users/AuthenticateByName',
        data: {'Username': server.username, 'Pw': server.token},
        options: Options(headers: _authHeader),
      );
      final token = response.data?['AccessToken'] as String?;
      if (token == null || token.isEmpty) {
        throw ApiException(
          'Emby login failed: no access token',
          statusCode: response.statusCode,
        );
      }
      return token;
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException(
        'Emby login failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// GET /Users/Me — true when the token is accepted. Used as the
  /// token check: /System/Info answers 200 without auth on some
  /// servers, so it cannot tell a good token from a bad one.
  Future<bool> testConnection() async {
    await userId();
    return true;
  }

  /// Pure, testable parse of GET /System/Info/Public. HTTP 200 with
  /// ProductName "Emby Server" proves the server is alive — it needs
  /// auth, it is not unreachable.
  static ConnectionResult parsePublicInfo(Map<String, dynamic> json) {
    if ('${json['ProductName'] ?? ''}' != 'Emby Server') {
      return ConnectionResult.unreachable(message: '不是 Emby 服务器');
    }
    return ConnectionResult.needsAuth(
      message: '服务器可达，需要登录',
      serverVersion: '${json['ServerVersion'] ?? ''}',
      serverName: '${json['ServerName'] ?? ''}',
    );
  }

  /// Structured connectivity check. GET /System/Info/Public first
  /// (no auth needed); if a token is present, validate it against
  /// GET /Users/Me — not /System/Info, which answers HTTP 200 without
  /// auth on some servers and so cannot detect a bad token — and
  /// return `ok` only when the token is accepted.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      final public = await dio.get<Map<String, dynamic>>(
        'System/Info/Public',
        options: Options(headers: _authHeader),
      );
      if (public.statusCode != 200) {
        return ConnectionResult.unreachable(
          message: 'HTTP ${public.statusCode}',
        );
      }
      final probe = parsePublicInfo(public.data ?? {});
      if (probe.isUnreachable) return probe;
      if (server.token.isEmpty) return probe;
      try {
        await userId();
        return ConnectionResult.ok(
          message: '已连接',
          serverVersion: probe.serverVersion,
          serverName: probe.serverName,
        );
      } on ApiException {
        // Token rejected: the public probe already proved reachability.
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

  /// GET /Items — movies / series / audio. [includeItemTypes] e.g.
  /// "Movie,Series" or "Audio". [parentId] scopes to a library.
  /// Pass [userId] (from [userId]) so UserData (resume progress) is
  /// included in the response.
  Future<List<VideoItem>> getItems({
    String includeItemTypes = 'Movie,Series',
    String? parentId,
    String? userId,
    String? searchTerm,
    int limit = 20,
    int startIndex = 0,
    bool recursive = true,
    String sortBy = 'DateCreated',
    String sortOrder = 'Descending',
  }) async {
    try {
      final queryParameters = <String, dynamic>{
        'IncludeItemTypes': includeItemTypes,
        'Recursive': recursive.toString(),
        'SortBy': sortBy,
        'SortOrder': sortOrder,
        'Limit': limit,
        'StartIndex': startIndex,
        'Fields': 'Overview,PrimaryImageAspectRatio',
      };
      if (parentId != null) queryParameters['ParentId'] = parentId;
      if (userId != null) queryParameters['UserId'] = userId;
      if (searchTerm != null && searchTerm.isNotEmpty) {
        queryParameters['SearchTerm'] = searchTerm;
      }
      final response = await dio.get<Map<String, dynamic>>(
        'Items',
        queryParameters: queryParameters,
        options: Options(headers: {..._authHeader, ..._tokenHeader}),
      );
      final items = (response.data?['Items'] as List?) ?? [];
      return items
          .whereType<Map<String, dynamic>>()
          .map(_videoFromJson)
          .toList();
    } on DioException catch (e) {
      throw ApiException(
        'Emby items failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// GET /Items?IncludeItemTypes=Audio — audio tracks as unified [Track]s.
  Future<List<Track>> getAudioItems({int limit = 20}) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'Items',
        queryParameters: {
          'IncludeItemTypes': 'Audio',
          'Recursive': 'true',
          'SortBy': 'DateCreated',
          'SortOrder': 'Descending',
          'Limit': limit,
          'Fields': 'Overview',
        },
        options: Options(headers: {..._authHeader, ..._tokenHeader}),
      );
      final items = (response.data?['Items'] as List?) ?? [];
      return items.whereType<Map<String, dynamic>>().map((json) {
        final albumArtists =
            (json['AlbumArtist'] as String?) ??
            (json['Album'] as String?) ??
            '';
        return Track(
          id: '${json['Id']}',
          title: '${json['Name'] ?? ''}',
          artist: albumArtists,
          album: '${json['Album'] ?? ''}',
          durationSeconds: ((json['RunTimeTicks'] as num?) ?? 0) ~/ 10000000,
          serverId: server.id,
          sourceLabel: server.name,
        );
      }).toList();
    } on DioException catch (e) {
      throw ApiException(
        'Emby audio failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// Direct video stream URL: GET `/Videos/{id}/stream`.
  String videoStreamUrl(String itemId, {int? maxStreamingBitrate}) {
    final query = <String, String>{'api_key': server.token};
    if (maxStreamingBitrate != null) {
      query['maxStreamingBitrate'] = '$maxStreamingBitrate';
    }
    final qs = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$_baseNoSlash/Videos/$itemId/stream${qs.isEmpty ? '' : '?$qs'}';
  }

  /// Universal audio URL: GET /Audio/{id}/universal.
  String audioUniversalUrl(String itemId) =>
      '$_baseNoSlash/Audio/$itemId/universal?api_key='
      '${Uri.encodeQueryComponent(server.token)}';

  /// Primary image URL for an item. The api_key query param carries
  /// auth, so CachedNetworkImage can fetch it without extra headers.
  String imageUrl(String itemId, {String type = 'Primary'}) {
    final base = '$_baseNoSlash/Items/$itemId/Images/$type';
    if (server.token.isEmpty) return base;
    return '$base?api_key=${Uri.encodeQueryComponent(server.token)}';
  }

  // ------------------------------------------------------------------
  // P3: video — views, resume, series, detail, PlaybackInfo, progress.
  // ------------------------------------------------------------------

  String? _cachedUserId;

  /// The current user's id, resolved once via GET /Users/Me and cached.
  /// Needed for Views / Resume / PlayedItems / progress endpoints.
  Future<String> userId() async {
    if (_cachedUserId != null) return _cachedUserId!;
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'Users/Me',
        options: Options(headers: {..._authHeader, ..._tokenHeader}),
      );
      final id = '${response.data?['Id'] ?? ''}';
      if (id.isEmpty) throw ApiException('Emby /Users/Me returned no Id');
      _cachedUserId = id;
      return id;
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException(
        'Emby user lookup failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  Future<Map<String, dynamic>> _getMap(
    String path, {
    Map<String, dynamic> query = const {},
  }) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        path,
        queryParameters: query,
        options: Options(headers: {..._authHeader, ..._tokenHeader}),
      );
      return response.data ?? {};
    } on DioException catch (e) {
      throw ApiException(
        'Emby GET $path failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  Future<Map<String, dynamic>> _postMap(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        path,
        data: data,
        options: Options(headers: {..._authHeader, ..._tokenHeader}),
      );
      return response.data ?? {};
    } on DioException catch (e) {
      throw ApiException(
        'Emby POST $path failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// GET /Users/{userId}/Views — the user's libraries.
  Future<List<LibraryView>> getUserViews() async {
    final uid = await userId();
    final body = await _getMap('Users/$uid/Views');
    final items = (body['Items'] as List?) ?? [];
    return items.whereType<Map<String, dynamic>>().map((json) {
      return LibraryView(
        id: '${json['Id']}',
        name: '${json['Name'] ?? ''}',
        collectionType: '${json['CollectionType'] ?? ''}',
      );
    }).toList();
  }

  /// GET /Users/{userId}/Items/Resume — continue watching, with
  /// UserData.PlaybackPositionTicks per item.
  Future<List<VideoItem>> getResumeItems({int limit = 20}) async {
    final uid = await userId();
    final body = await _getMap(
      'Users/$uid/Items/Resume',
      query: {
        'Limit': limit,
        'Recursive': 'true',
        'Fields': 'Overview,PrimaryImageAspectRatio',
        'IncludeItemTypes': 'Movie,Episode',
      },
    );
    final items = (body['Items'] as List?) ?? [];
    return items.whereType<Map<String, dynamic>>().map(_videoFromJson).toList();
  }

  /// GET /Users/{userId}/Items/{id} — full detail: overview, cast
  /// (People), genres, and MediaStreams (subtitle tracks included).
  Future<VideoDetail> getItemDetail(String itemId) async {
    final uid = await userId();
    final body = await _getMap(
      'Users/$uid/Items/$itemId',
      query: {'Fields': 'Overview,People,MediaStreams,Genres,Studios'},
    );
    final item = _videoFromJson(body);
    final people = (body['People'] as List?) ?? [];
    final cast = people
        .whereType<Map<String, dynamic>>()
        .where((p) => '${p['Type'] ?? ''}' == 'Actor')
        .map((p) => '${p['Name'] ?? ''}')
        .where((name) => name.isNotEmpty)
        .toList();
    final genres = (body['Genres'] as List?)?.map((g) => '$g').toList() ?? [];
    final subtitles = parseSubtitleStreams(body);
    return VideoDetail(
      item: item.copyWith(cast: cast, genres: genres),
      subtitleTracks: subtitles,
    );
  }

  /// Pure parse of an item's MediaStreams into subtitle tracks.
  static List<SubtitleTrackInfo> parseSubtitleStreams(
    Map<String, dynamic> json,
  ) {
    final streams = (json['MediaStreams'] as List?) ?? [];
    return streams
        .whereType<Map<String, dynamic>>()
        .where((s) => '${s['Type'] ?? ''}' == 'Subtitle')
        .map((s) {
          return SubtitleTrackInfo(
            index: (s['Index'] as num?)?.toInt() ?? 0,
            codec: '${s['Codec'] ?? ''}',
            language: '${s['Language'] ?? ''}',
            displayTitle: '${s['DisplayTitle'] ?? ''}',
            isExternal: s['IsExternal'] as bool? ?? false,
            isForced: s['IsForced'] as bool? ?? false,
            isDefault: s['IsDefault'] as bool? ?? false,
            deliveryUrl: s['DeliveryUrl'] as String?,
          );
        })
        .toList();
  }

  /// GET /Shows/{seriesId}/Seasons.
  Future<List<Season>> getSeasons(String seriesId) async {
    final uid = await userId();
    final body = await _getMap(
      'Shows/$seriesId/Seasons',
      query: {'UserId': uid, 'Fields': 'Overview'},
    );
    final items = (body['Items'] as List?) ?? [];
    return items.whereType<Map<String, dynamic>>().map((json) {
      return Season(
        id: '${json['Id']}',
        name: '${json['Name'] ?? ''}',
        indexNumber: (json['IndexNumber'] as num?)?.toInt(),
        episodeCount: (json['ChildCount'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// GET /Shows/{seriesId}/Episodes — all episodes, or one season's
  /// when [seasonId] is given. Episodes carry seasonId/seasonNumber.
  Future<List<VideoItem>> getEpisodes(
    String seriesId, {
    String? seasonId,
  }) async {
    final uid = await userId();
    final query = <String, dynamic>{
      'UserId': uid,
      'Recursive': 'true',
      'Fields': 'Overview,PrimaryImageAspectRatio',
    };
    if (seasonId != null) query['SeasonId'] = seasonId;
    final body = await _getMap('Shows/$seriesId/Episodes', query: query);
    final items = (body['Items'] as List?) ?? [];
    return items.whereType<Map<String, dynamic>>().map(_videoFromJson).toList();
  }

  /// POST /Items/{id}/PlaybackInfo — media sources for the
  /// direct-play vs transcode decision. Returns the parsed sources.
  /// Also remembers the response's PlaySessionId and the first
  /// source's id, which the /Sessions/Playing* check-ins need.
  Future<List<MediaSourceInfo>> getPlaybackInfo(String itemId) async {
    final uid = await userId();
    final body = await _postMap('Items/$itemId/PlaybackInfo', {
      'UserId': uid,
      'MaxStreamingBitrate': 120000000,
      'MaxStaticBitrate': 120000000,
    });
    _playSessionId = body['PlaySessionId'] as String?;
    final sources = parseMediaSources(body);
    _lastMediaSourceId = sources.isEmpty ? null : sources.first.id;
    return sources;
  }

  /// Pure parse of a PlaybackInfo response into media sources.
  static List<MediaSourceInfo> parseMediaSources(Map<String, dynamic> json) {
    final sources = (json['MediaSources'] as List?) ?? [];
    return sources.whereType<Map<String, dynamic>>().map((source) {
      final streams = (source['MediaStreams'] as List?) ?? [];
      return MediaSourceInfo(
        id: '${source['Id'] ?? ''}',
        container: '${source['Container'] ?? ''}',
        videoCodec: source['VideoCodec'] as String?,
        audioCodec: source['AudioCodec'] as String?,
        videoBitRate: (source['Bitrate'] as num?)?.toInt(),
        width:
            ((source['VideoStream'] as Map<String, dynamic>?)?['Width'] as num?)
                ?.toInt(),
        height:
            ((source['VideoStream'] as Map<String, dynamic>?)?['Height']
                    as num?)
                ?.toInt(),
        supportsDirectPlay: source['SupportsDirectPlay'] as bool? ?? true,
        supportsDirectStream: source['SupportsDirectStream'] as bool? ?? true,
        transcodingUrl: source['TranscodingUrl'] as String?,
        streams: streams.whereType<Map<String, dynamic>>().map((s) {
          return MediaStreamInfo(
            type: '${s['Type'] ?? ''}',
            index: (s['Index'] as num?)?.toInt() ?? 0,
            codec: '${s['Codec'] ?? ''}',
            language: '${s['Language'] ?? ''}',
            width: (s['Width'] as num?)?.toInt(),
            height: (s['Height'] as num?)?.toInt(),
            bitRate: (s['Bitrate'] as num?)?.toInt(),
            channels: (s['Channels'] as num?)?.toInt(),
            sampleRate: (s['SampleRate'] as num?)?.toInt(),
            frameRate: (s['FrameRate'] as num?)?.toDouble(),
            isDefault: s['IsDefault'] as bool? ?? false,
            isForced: s['IsForced'] as bool? ?? false,
            isExternal: s['IsExternal'] as bool? ?? false,
            displayTitle: '${s['DisplayTitle'] ?? ''}',
          );
        }).toList(),
      );
    }).toList();
  }

  /// HLS transcode URL: GET /Videos/{id}/master.m3u8. Server-side
  /// transcoding only — no local FFmpeg in P3. [mediaSourceId] pins
  /// the transcode to the source [getPlaybackInfo] chose; without it
  /// the server picks the default source, which may differ.
  String transcodeUrl(
    String itemId, {
    String videoCodec = 'h264',
    String audioCodec = 'aac',
    int? maxStreamingBitrate,
    int? subtitleStreamIndex,
    int? audioStreamIndex,
    String? mediaSourceId,
  }) {
    final query = <String, String>{
      'api_key': server.token,
      'VideoCodec': videoCodec,
      'AudioCodec': audioCodec,
    };
    if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
      query['MediaSourceId'] = mediaSourceId;
    }
    if (maxStreamingBitrate != null) {
      query['MaxStreamingBitrate'] = '$maxStreamingBitrate';
    }
    if (subtitleStreamIndex != null) {
      query['SubtitleStreamIndex'] = '$subtitleStreamIndex';
    }
    if (audioStreamIndex != null) {
      query['AudioStreamIndex'] = '$audioStreamIndex';
    }
    final qs = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return '$_baseNoSlash/Videos/$itemId/master.m3u8?$qs';
  }

  /// Subtitle stream URL for one subtitle track. Prefers the server's
  /// DeliveryUrl when present, else builds the Stream.srt URL from
  /// the track's media source id. When the track has no media source
  /// id there is no valid URL — the no-source route
  /// /Videos/{id}/Subtitles/{index}/Stream.srt does not exist (404) —
  /// so this returns '' and the caller clears the subtitle track.
  String subtitleUrl(
    String itemId,
    SubtitleTrackInfo track, {
    String format = 'srt',
  }) {
    final delivery = track.deliveryUrl;
    if (delivery != null && delivery.isNotEmpty) {
      return delivery.startsWith('http') ? delivery : '$_baseNoSlash$delivery';
    }
    final mediaSourceId = track.mediaSourceId;
    if (mediaSourceId == null || mediaSourceId.isEmpty) return '';
    final base =
        '$_baseNoSlash/Videos/$itemId/$mediaSourceId/Subtitles/${track.index}/Stream.$format';
    if (server.token.isEmpty) return base;
    return '$base?api_key=${Uri.encodeQueryComponent(server.token)}';
  }

  /// The PlaySessionId / media source id of the last PlaybackInfo
  /// response, for the /Sessions/Playing* check-ins (B4). Empty
  /// until a playback decision is made; the check-ins simply omit
  /// them when unknown.
  String? _playSessionId;
  String? _lastMediaSourceId;

  /// One PlaybackProgressInfo body (Emby "Playback Check-ins" doc):
  /// ItemId, PositionTicks (100ns), IsPaused, CanSeek, plus the
  /// MediaSourceId / PlaySessionId from the last PlaybackInfo when
  /// known, and EventName / PlayMethod when given.
  Map<String, dynamic> _playbackCheckIn(
    String itemId,
    Duration position, {
    bool isPaused = false,
    String? playMethod,
    String? eventName,
  }) {
    // Locals, with empty strings normalised to null so the null-aware
    // elements below omit them.
    final mediaSourceId = _lastMediaSourceId?.isEmpty == true
        ? null
        : _lastMediaSourceId;
    final playSessionId = _playSessionId?.isEmpty == true
        ? null
        : _playSessionId;
    return {
      'ItemId': itemId,
      'MediaSourceId': ?mediaSourceId,
      'PlaySessionId': ?playSessionId,
      'PositionTicks': position.inMicroseconds * 10,
      'IsPaused': isPaused,
      'CanSeek': true,
      'QueueableMediaTypes': ['Video'],
      'PlayMethod': ?playMethod,
      'EventName': ?eventName,
    };
  }

  /// POST /Sessions/Playing — tell the server playback started
  /// (creates the session and the resume entry).
  Future<void> reportPlaybackStarted(
    String itemId, {
    String playMethod = 'DirectPlay',
    Duration position = Duration.zero,
  }) async {
    await _postMap(
      'Sessions/Playing',
      _playbackCheckIn(itemId, position, playMethod: playMethod),
    );
  }

  /// POST /Sessions/Playing/Progress — resume position reporting
  /// (pause / periodic). Same body as the start check-in plus
  /// EventName: Pause when paused, TimeUpdate otherwise.
  Future<void> reportProgress(
    String itemId,
    Duration position, {
    bool isPaused = false,
  }) async {
    await _postMap(
      'Sessions/Playing/Progress',
      _playbackCheckIn(
        itemId,
        position,
        isPaused: isPaused,
        eventName: isPaused ? 'Pause' : 'TimeUpdate',
      ),
    );
  }

  /// POST /Sessions/Playing/Stopped — playback ended; same body as
  /// the start check-in.
  Future<void> reportPlaybackStopped(String itemId, Duration position) async {
    await _postMap(
      'Sessions/Playing/Stopped',
      _playbackCheckIn(itemId, position, isPaused: true),
    );
  }

  /// POST /Users/{userId}/PlayedItems/{id} — mark watched on completion.
  Future<void> markPlayed(String itemId) async {
    final uid = await userId();
    await _postMap('Users/$uid/PlayedItems/$itemId', {});
  }

  VideoItem _videoFromJson(Map<String, dynamic> json) {
    final id = '${json['Id']}';
    final ticks = (json['RunTimeTicks'] as num?) ?? 0;
    final userData = json['UserData'] as Map<String, dynamic>?;
    final played = (userData?['PlayedPercentage'] as num?) ?? 0;
    final positionTicks = (userData?['PlaybackPositionTicks'] as num?) ?? 0;
    final positionSeconds = positionTicks ~/ 10000000;
    final progress = played > 0
        ? played.toDouble() / 100
        : (ticks > 0 ? positionTicks / ticks : 0.0);
    return VideoItem(
      id: id,
      title: '${json['Name'] ?? ''}',
      overview: '${json['Overview'] ?? ''}',
      year: (json['ProductionYear'] as num?)?.toInt(),
      posterUrl: imageUrl(id),
      backdropUrl: imageUrl(id, type: 'Backdrop'),
      type: '${json['Type'] ?? 'Movie'}',
      durationSeconds: ticks ~/ 10000000,
      episodeCount: (json['ChildCount'] as num?)?.toInt() ?? 0,
      progress: progress.toDouble().clamp(0.0, 1.0),
      playbackPositionSeconds: positionSeconds.toInt(),
      serverId: server.id,
      sourceLabel: server.name,
      seriesId: json['SeriesId'] as String?,
      seasonId: json['SeasonId'] as String?,
      seasonNumber: (json['ParentIndexNumber'] as num?)?.toInt(),
      episodeNumber: (json['IndexNumber'] as num?)?.toInt(),
    );
  }
}
