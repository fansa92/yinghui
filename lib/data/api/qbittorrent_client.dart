import 'package:dio/dio.dart';

import '../../core/proxy_config.dart';

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
          ) {
    DioProxy.apply(this.dio);
  }

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

  /// The in-flight login, shared by concurrent callers. Without
  /// this, a poll tick and a user action (pause/add/delete) could
  /// both see a 403, both call [login] and race on [_sid] — the
  /// second login's `_sid = null` (see [login]) could wipe the
  /// first login's fresh SID mid-flight, producing spurious 403s
  /// and duplicate logins. Callers await the same future instead.
  Future<bool>? _loginFuture;

  /// One shared login: concurrent callers await the same in-flight
  /// [login] instead of each starting their own. The entry is
  /// cleared when the future completes, success or failure, so a
  /// later call starts a fresh login.
  Future<bool> _loginOnce() {
    final inFlight = _loginFuture;
    if (inFlight != null) return inFlight;
    final future = login();
    _loginFuture = future;
    return future.whenComplete(() {
      if (identical(_loginFuture, future)) _loginFuture = null;
    });
  }

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
    // A stale SID must not survive a new login: if this login
    // returns no cookie (e.g. a no-auth server answering "Ok."),
    // the fail-fast check below throws — and the old SID must not
    // stay behind to be sent as if it were still valid.
    _sid = null;
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

  /// Version check, lazy like every other call: try without a
  /// session first (a no-auth server answers 200 with no login at
  /// all); only on 401/403 log in once (shared via [_loginOnce])
  /// and retry. A wrong password surfaces as a 401 from the login.
  Future<bool> testConnection() async {
    try {
      return await _guard(() async {
        final response = await dio.get<String>(
          'api/v2/app/version',
          options: Options(headers: _cookieHeader),
        );
        return response.statusCode == 200;
      }, 'version check');
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        await _loginOnce();
        return _guard(() async {
          final response = await dio.get<String>(
            'api/v2/app/version',
            options: Options(headers: _cookieHeader),
          );
          return response.statusCode == 200;
        }, 'version check');
      }
      rethrow;
    }
  }

  /// Structured connectivity check. GET app/version WITHOUT login
  /// first: HTTP 403 means the Web API is present behind the subpath
  /// and needs login (needsAuth, not unreachable). With credentials,
  /// log in once (shared via [_loginOnce]) then re-check; HTTP 200
  /// after login is ok. A 401 from the login and a bare 403 are
  /// told apart: a wrong password says so, "never logged in" says
  /// so — they used to collapse into one message.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      // Send the known SID when one exists: a warmed session must
      // not be re-proven with a bare probe that 403s and forces a
      // second login on every repeat check.
      final probe = await dio.get<String>(
        'api/v2/app/version',
        options: Options(headers: _cookieHeader),
      );
      if (probe.statusCode == 200) {
        return ConnectionResult.ok(message: '已连接', serverVersion: probe.data);
      }
      return ConnectionResult.unreachable(message: 'HTTP ${probe.statusCode}');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403) {
        if (server.username.isEmpty && server.token.isEmpty) {
          return ConnectionResult.needsAuth(message: '服务器可达，需要登录');
        }
        try {
          await _loginOnce();
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
        } on ApiException catch (loginError) {
          // A 401 here is a wrong username/password, not an
          // expired session — say so instead of the generic
          // "needs login" the probe used to return for both.
          if (loginError.statusCode == 401) {
            return ConnectionResult.needsAuth(message: '用户名或密码错误，请检查账号');
          }
          // Any other login failure: the 403 probe already proved
          // reachability, so this is still "needs login".
        } on DioException {
          // The version check itself failed after login (transport
          // error): the 403 probe already proved reachability, so this
          // is still "needs login", not "unreachable" — and it must not
          // escape as a raw DioException to the caller.
        }
        return ConnectionResult.needsAuth(message: '服务器可达，需要登录');
      }
      if (status != null) {
        return ConnectionResult.unreachable(message: 'HTTP $status');
      }
      return ConnectionResult.unreachable(
        message: '无法连接：${e.message ?? e.type.name}',
      );
    }
  }

  /// Lazy auth: runs [run] first with whatever session exists
  /// (possibly none), and only logs in when the server answers
  /// 401/403 — then retries the call a single time. This is what
  /// makes a no-auth server work end to end (its calls answer 200
  /// with no login at all) and saves one login round-trip on every
  /// cold start. The old login-first design forced even a no-auth
  /// server through [login], whose fail-fast "no SID" check then
  /// broke Downloads while the Servers probe said "在线".
  ///
  /// The login is shared ([_loginOnce]) so concurrent callers that
  /// all hit 403 await one login instead of racing on [_sid]. The
  /// retry is not wrapped, so its failure propagates — no loop.
  Future<T> _withRelogin<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        // No (valid) session: log in once more and retry a single
        // time. A wrong password surfaces as the login's own 401.
        _sid = null;
        await _loginOnce();
        return run();
      }
      rethrow;
    }
  }

  /// GET /api/v2/torrents/info — all torrents as unified [DownloadTask]s.
  Future<List<DownloadTask>> torrentsInfo() async {
    return _withRelogin(() async {
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
