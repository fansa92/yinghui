import 'package:dio/dio.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/download_task.dart';

/// qBittorrent client — the Web API v2, its own native protocol.
///
/// Auth: POST /api/v2/auth/login with `username`/`password` (the password
/// is [Server.token]); the server answers `Set-Cookie: SID=...` and the
/// SID cookie is sent on every later call. No generic wrapper.
class QbittorrentClient {
  QbittorrentClient(this.server, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              // Trailing slash matters: Dio resolves a relative path
              // against baseUrl, so 'api/v2/...' keeps a subpath like
              // /qb/ in https://host/qb/. A leading '/' would drop it.
              baseUrl: _baseUrlWithSlash(server),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  final Server server;
  final Dio dio;

  /// Base URL with a trailing slash, so relative request paths resolve
  /// under a subpath (e.g. https://host/qb/ + api/v2/...).
  /// Pure and unit-testable.
  static String _baseUrlWithSlash(Server server) {
    final base = server.baseUrl;
    return base.endsWith('/') ? base : '$base/';
  }

  /// Full URL for a relative API path, preserving any subpath in the
  /// server URL. Pure and unit-testable: for https://sg.kass.qzz.io/qb/
  /// + 'api/v2/app/version' this must be
  /// https://sg.kass.qzz.io/qb/api/v2/app/version.
  static Uri buildApiUri(Server server, String relativePath) {
    final base = _baseUrlWithSlash(server);
    return Uri.parse(base).resolve(relativePath);
  }

  String? _sid;

  Future<T> _guard<T>(Future<T> Function() run, String what) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw ApiException(
        'qBittorrent $what failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  Map<String, String> get _cookieHeader =>
      _sid == null ? {} : {'Cookie': 'SID=$_sid'};

  /// POST /api/v2/auth/login. qB 4.x answers 200 "Ok." (the wiki's login
  /// example shows Content-Length: 3); qB 5.x answers 204 No Content
  /// with an empty body. Any 2xx here is a successful login — bad
  /// credentials come back 401, which Dio already turned into an
  /// exception before we get here. Throws [ApiException] on bad
  /// credentials.
  Future<bool> login() async {
    final ok = await _guard(() async {
      final response = await dio.post<String>(
        'api/v2/auth/login',
        data: {'username': server.username, 'password': server.token},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final setCookie = response.headers['set-cookie'] ?? [];
      for (final cookie in setCookie) {
        final match = RegExp(r'SID=([^;]+)').firstMatch(cookie);
        if (match != null) _sid = match.group(1);
      }
      // "Ok." (qB 4.x) or an empty body (qB 5.x, 204 No Content).
      final body = (response.data ?? '').trim();
      return body.isEmpty || body == 'Ok.' || body == 'Ok';
    }, 'login');
    if (!ok) throw ApiException('qBittorrent login failed: bad credentials');
    // A login that answers "Ok." but sets no SID cookie leaves the
    // client with no session: every later call goes out without a
    // cookie and comes back 403. Fail here, as an auth failure, with
    // a clear message — instead of surfacing that confusing 403
    // downstream in the Downloads page.
    if (_sid == null) {
      throw ApiException(
        'qBittorrent login failed: server did not return a session (SID)',
        statusCode: 401,
      );
    }
    return true;
  }

  /// Login, then GET /api/v2/app/version as a connectivity check.
  Future<bool> testConnection() async {
    await login();
    return _guard(() async {
      final response = await dio.get<String>(
        'api/v2/app/version',
        options: Options(headers: _cookieHeader),
      );
      return response.statusCode == 200;
    }, 'version check');
  }

  /// Structured connectivity check. GET app/version WITHOUT login
  /// first: HTTP 403 means the Web API is present behind the subpath
  /// and needs login (needsAuth, not unreachable). With credentials,
  /// login then re-check; HTTP 200 after login is ok.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      final probe = await dio.get<String>('api/v2/app/version');
      if (probe.statusCode == 200) {
        return ConnectionResult.ok(message: '已连接', serverVersion: probe.data);
      }
      return ConnectionResult.unreachable(message: 'HTTP ${probe.statusCode}');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403) {
        if (server.username.isEmpty || server.token.isEmpty) {
          return ConnectionResult.needsAuth(message: '服务器可达，需要登录（HTTP 403）');
        }
        try {
          await login();
          final version = await dio.get<String>(
            'api/v2/app/version',
            options: Options(headers: _cookieHeader),
          );
          if (version.statusCode == 200) {
            return ConnectionResult.ok(
              message: '已连接',
              serverVersion: version.data,
            );
          }
        } on ApiException {
          // Login failed: the 403 probe already proved reachability.
        } on DioException {
          // The version check itself failed after login (transport
          // error): the 403 probe already proved reachability, so this
          // is still "needs login", not "unreachable" — and it must not
          // escape as a raw DioException to the caller.
        }
        return ConnectionResult.needsAuth(message: '服务器可达，需要登录（HTTP 403）');
      }
      if (status != null) {
        return ConnectionResult.unreachable(message: 'HTTP $status');
      }
      return ConnectionResult.unreachable(
        message: '无法连接：${e.message ?? e.type.name}',
      );
    }
  }

  Future<void> _ensureLogin() async {
    if (_sid == null) await login();
  }

  /// Runs [run] once; if the server answers 403 the SID has expired
  /// (or was revoked), so log in once more and retry the call a single
  /// time. Without this, every call after a SID expiry fails until the
  /// client is recreated.
  Future<T> _withRelogin<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        // The SID expired (or was never captured): log in once more
        // and retry a single time. The retry is not wrapped, so its
        // failure propagates — no loop. The old code also required
        // _sid != null here, which meant a login that succeeded
        // without capturing a SID could never recover from the 403
        // that followed.
        _sid = null;
        await login();
        return run();
      }
      rethrow;
    }
  }

  /// GET /api/v2/torrents/info — all torrents as unified [DownloadTask]s.
  Future<List<DownloadTask>> torrentsInfo() async {
    return _withRelogin(() async {
      await _ensureLogin();
      return _guard(() async {
        final response = await dio.get<List<dynamic>>(
          'api/v2/torrents/info',
          options: Options(headers: _cookieHeader),
        );
        final list = response.data ?? [];
        return list
            .whereType<Map<String, dynamic>>()
            .map(_taskFromJson)
            .toList();
      }, 'torrents/info');
    });
  }

  /// POST /api/v2/torrents/add — magnet link or torrent URL. The
  /// wiki's example posts multipart/form-data (`urls`, `savepath`),
  /// so this sends a [FormData], not urlencoded fields.
  Future<bool> addMagnet(String magnetUrl, {String? savePath}) async {
    return _withRelogin(() async {
      await _ensureLogin();
      final formMap = <String, dynamic>{'urls': magnetUrl};
      final path = savePath;
      if (path != null) formMap['savepath'] = path;
      final form = FormData.fromMap(formMap);
      return _guard(() async {
        final response = await dio.post<String>(
          'api/v2/torrents/add',
          data: form,
          options: Options(headers: _cookieHeader),
        );
        return response.statusCode == 200;
      }, 'add torrent');
    });
  }

  Future<bool> _torrentAction(String action, List<String> hashes) async {
    return _withRelogin(() async {
      await _ensureLogin();
      return _guard(() async {
        final response = await dio.post<String>(
          'api/v2/torrents/$action',
          data: {'hashes': hashes.join('|')},
          options: Options(
            headers: _cookieHeader,
            contentType: Headers.formUrlEncodedContentType,
          ),
        );
        return response.statusCode == 200;
      }, action);
    });
  }

  /// POST /api/v2/torrents/pause.
  Future<bool> pause(List<String> hashes) => _torrentAction('pause', hashes);

  /// POST /api/v2/torrents/resume.
  Future<bool> resume(List<String> hashes) => _torrentAction('resume', hashes);

  /// POST /api/v2/torrents/delete?deleteFiles=false.
  Future<bool> delete(List<String> hashes, {bool deleteFiles = false}) async {
    return _withRelogin(() async {
      await _ensureLogin();
      return _guard(() async {
        final response = await dio.post<String>(
          'api/v2/torrents/delete',
          data: {
            'hashes': hashes.join('|'),
            'deleteFiles': deleteFiles.toString(),
          },
          options: Options(
            headers: _cookieHeader,
            contentType: Headers.formUrlEncodedContentType,
          ),
        );
        return response.statusCode == 200;
      }, 'delete');
    });
  }

  DownloadTask _taskFromJson(Map<String, dynamic> json) {
    final state = '${json['state'] ?? ''}';
    // Wiki state table: forcedDL is downloading (forced start),
    // forcedUP is seeding (done), stoppedUP is paused. `checking*`,
    // `allocating` and `moving` have no dedicated state here and fall
    // through to queued.
    final status = switch (state) {
      'downloading' ||
      'stalledDL' ||
      'queuedDL' ||
      'metaDL' ||
      'forcedDL' => DownloadStatus.downloading,
      'pausedDL' ||
      'pausedUP' ||
      'stoppedDL' ||
      'stoppedUP' => DownloadStatus.paused,
      'uploading' ||
      'stalledUP' ||
      'queuedUP' ||
      'forcedUP' => DownloadStatus.completed,
      'error' || 'missingFiles' => DownloadStatus.failed,
      _ => DownloadStatus.queued,
    };
    return DownloadTask(
      id: '${json['hash']}',
      name: '${json['name'] ?? ''}',
      source: DownloadSource.qbittorrent,
      status: status,
      progress: ((json['progress'] as num?) ?? 0).toDouble(),
      speedBytesPerSec: (json['dlspeed'] as num?)?.toInt() ?? 0,
      sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
      downloadedBytes: (json['completed'] as num?)?.toInt() ?? 0,
      serverId: server.id,
      etaSeconds: _etaFromJson(json['eta']),
      savePath: '${json['save_path'] ?? ''}',
      hash: '${json['hash'] ?? ''}',
    );
  }

  /// The wiki's torrents/info table: eta 8640000 means "unknown" —
  /// show no ETA (same as -1) instead of a bogus 100-day countdown.
  static int _etaFromJson(dynamic raw) {
    final eta = (raw as num?)?.toInt() ?? -1;
    return eta == 8640000 ? -1 : eta;
  }
}
