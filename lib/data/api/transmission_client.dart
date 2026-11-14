import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/proxy_config.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/download_task.dart';

/// Transmission client — its own native JSON-RPC 2.0 protocol
/// (Transmission 4.1+, rpc_version_semver 6.0.0).
///
/// Every call is POST /transmission/rpc with a JSON-RPC 2.0 body
/// `{"jsonrpc": "2.0", "id": ..., "method": "snake_case", "params": {...}}`
/// and the result object comes back in `result` (errors in `error`).
/// The old bespoke protocol (kebab-case methods, `{"result": "success",
/// "arguments": {...}}`) is deprecated and removed in Transmission 5,
/// so this client speaks only the new one — it needs a daemon
/// >= 4.1.0. A fresh server answers **409** with an
/// `X-Transmission-Session-Id` header; the client must resend the same
/// request with that header. No generic wrapper.
class TransmissionClient {
  TransmissionClient(this.server, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              // Trailing slash matters: Dio resolves a relative path
              // against baseUrl, so 'transmission/rpc' keeps a subpath
              // in the server URL. A leading '/' would drop it.
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
  /// under a subpath.
  static String _baseUrlWithSlash(Server server) {
    final base = server.baseUrl;
    return base.endsWith('/') ? base : '$base/';
  }

  /// Current session id, learned from a 409 response. Exposed for tests.
  String? sessionId;

  static const String sessionHeader = 'X-Transmission-Session-Id';

  int _nextId = 1;

  /// One JSON-RPC 2.0 call, with the 409 session-id retry (at most one
  /// retry). The retry is wrapped the same way as the first call: a
  /// second failure surfaces as [ApiException], never as a raw
  /// [DioException] — repositories only catch [ApiException], so a
  /// leak here would break a whole refresh.
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final body = {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      'params': params,
    };
    try {
      return await _postOnce(body);
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final id = e.response?.headers.value(sessionHeader);
        if (id != null && id.isNotEmpty) {
          sessionId = id;
          try {
            return await _postOnce(body);
          } on DioException catch (retryError) {
            throw ApiException(
              'Transmission $method failed: '
              '${retryError.message ?? retryError.type.name}',
              statusCode: retryError.response?.statusCode,
              cause: retryError,
            );
          }
        }
      }
      throw ApiException(
        'Transmission $method failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  Future<Map<String, dynamic>> _postOnce(Map<String, dynamic> body) async {
    final headers = <String, String>{};
    if (sessionId != null) headers[sessionHeader] = sessionId!;
    // Basic auth is sent when EITHER credential is set: sending
    // nothing when only a password is configured used to drop the
    // password silently, so a password-only setup 401'd with no
    // indication that its credential never left the app. An
    // empty username with a password is valid Basic syntax
    // (`:password`); a daemon with a username set still rejects
    // it as wrong credentials, which is the correct outcome.
    if (server.username.isNotEmpty || server.token.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${_basicAuth(server.username, server.token)}';
    }
    final response = await dio.post<Map<String, dynamic>>(
      'transmission/rpc',
      data: body,
      options: Options(headers: headers),
    );
    final data = response.data ?? {};
    final error = data['error'] as Map<String, dynamic>?;
    if (error != null) {
      final message = '${error['message'] ?? 'unknown'}';
      final errorString = '${(error['data'] as Map?)?['errorString'] ?? ''}';
      // JSON-RPC auth failures ride on HTTP 200, so the HTTP status
      // is useless here: map an "unauthorized" error to a synthetic
      // 401, so live use reports "用户名或密码错误" instead of the
      // nonsense "服务器返回 HTTP 200" the Downloads page used to
      // show for exactly the same condition the Servers probe names
      // correctly.
      final isAuth =
          message.toLowerCase().contains('unauthorized') ||
          errorString.toLowerCase().contains('unauthorized');
      throw ApiException(
        isAuth ? '用户名或密码错误' : 'Transmission error: $message',
        statusCode: isAuth ? 401 : response.statusCode,
      );
    }
    return (data['result'] as Map<String, dynamic>?) ?? {};
  }

  String _basicAuth(String user, String pass) =>
      base64Encode(utf8.encode('$user:$pass'));

  /// session_get — also the connectivity check.
  Future<bool> testConnection() async {
    await rpc('session_get', {
      'fields': ['version'],
    });
    return true;
  }

  /// Structured connectivity check: session_get ok, otherwise
  /// unreachable — except HTTP 401. Transmission answers a missing
  /// or wrong Basic-auth credential with 401: the server is
  /// reachable, the credentials are wrong, so this is needsAuth,
  /// not unreachable. The `session_get` result carries the daemon
  /// `version`, which is returned when present; a missing or
  /// non-string version is not a failure — the check is still ok,
  /// just without a version.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      final args = await rpc('session_get', {
        'fields': ['version'],
      });
      final version = args['version'];
      return ConnectionResult.ok(
        serverVersion: version is String && version.isNotEmpty ? version : null,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        return ConnectionResult.needsAuth(
          message: server.username.isEmpty && server.token.isEmpty
              ? '需要登录'
              : '用户名或密码错误',
        );
      }
      return ConnectionResult.unreachable(message: e.message);
    }
  }

  /// torrent_get with the fields the unified model needs.
  Future<List<DownloadTask>> torrentGet() async {
    final args = await rpc('torrent_get', {
      'fields': [
        'id',
        'name',
        'status',
        'percent_done',
        'rate_download',
        'total_size',
        'downloaded_ever',
        'eta',
        'download_dir',
        'hash_string',
      ],
    });
    final torrents = (args['torrents'] as List?) ?? [];
    return torrents
        .whereType<Map<String, dynamic>>()
        .map(_taskFromJson)
        .toList();
  }

  /// torrent_add — magnet link or torrent URL.
  Future<String?> torrentAdd(String filename, {String? downloadDir}) async {
    final args = <String, dynamic>{'filename': filename};
    if (downloadDir != null && downloadDir.isNotEmpty) {
      args['download_dir'] = downloadDir;
    }
    final result = await rpc('torrent_add', args);
    final added = result['torrent_added'] as Map<String, dynamic>?;
    final dup = result['torrent_duplicate'] as Map<String, dynamic>?;
    final id = added?['id'] ?? dup?['id'];
    return id == null ? null : '$id';
  }

  Future<void> _torrentAction(String method, List<int> ids) async {
    await rpc(method, {'ids': ids});
  }

  /// torrent_start.
  Future<void> start(List<int> ids) => _torrentAction('torrent_start', ids);

  /// torrent_stop.
  Future<void> stop(List<int> ids) => _torrentAction('torrent_stop', ids);

  /// torrent_remove (deleteLocalData=false keeps the files).
  Future<void> remove(List<int> ids, {bool deleteLocalData = false}) async {
    await rpc('torrent_remove', {
      'ids': ids,
      'delete_local_data': deleteLocalData,
    });
  }

  /// torrent_set_location — move a torrent's data to a new directory.
  Future<void> setLocation(
    List<int> ids,
    String location, {
    bool move = false,
  }) async {
    await rpc('torrent_set_location', {
      'ids': ids,
      'location': location,
      'move': move,
    });
  }

  DownloadTask _taskFromJson(Map<String, dynamic> json) {
    // Transmission status: 0 stopped, 1 check-wait, 2 check,
    // 3 download-wait (queued for a slot, not downloading),
    // 4 downloading, 5 seed-wait, 6 seeding. 1/2 are verifying, so
    // they read as queued too — there is no "checking" state in the
    // unified model.
    final statusCode = (json['status'] as num?)?.toInt() ?? 0;
    final status = switch (statusCode) {
      4 => DownloadStatus.downloading,
      0 => DownloadStatus.paused,
      6 || 5 => DownloadStatus.completed,
      _ => DownloadStatus.queued,
    };
    return DownloadTask(
      id: '${json['id']}',
      name: '${json['name'] ?? ''}',
      source: DownloadSource.transmission,
      status: status,
      progress: ((json['percent_done'] as num?) ?? 0).toDouble(),
      speedBytesPerSec: (json['rate_download'] as num?)?.toInt() ?? 0,
      sizeBytes: (json['total_size'] as num?)?.toInt() ?? 0,
      downloadedBytes: (json['downloaded_ever'] as num?)?.toInt() ?? 0,
      serverId: server.id,
      etaSeconds: (json['eta'] as num?)?.toInt() ?? -1,
      savePath: '${json['download_dir'] ?? ''}',
      hash: '${json['hash_string'] ?? ''}',
    );
  }
}
