import 'package:dio/dio.dart';

import '../../core/proxy_config.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/download_task.dart';

/// aria2 client — its own native JSON-RPC protocol.
///
/// Every call is POST /jsonrpc with a JSON body
/// `{"jsonrpc": "2.0", "id": ..., "method": "aria2.xxx", "params": [...]}`.
/// When the server has a secret, it is sent as the **first** param with
/// the `token:` prefix: `"token:<secret>"`. No generic wrapper.
class Aria2Client {
  Aria2Client(this.server, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              // Trailing slash matters: Dio resolves a relative path
              // against baseUrl, so 'jsonrpc' keeps a subpath in the
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
  /// under a subpath.
  static String _baseUrlWithSlash(Server server) {
    final base = server.baseUrl;
    return base.endsWith('/') ? base : '$base/';
  }

  int _nextId = 1;

  /// The param list for an aria2 call: the `token:` secret first when one
  /// is configured, then the method's own params. Pure and unit-testable.
  /// A secret pasted with its `token:` prefix already on it is used
  /// as-is instead of being doubled into `token:token:…`.
  List<dynamic> buildParams([List<dynamic> params = const []]) {
    if (server.token.isEmpty) return params;
    final secret = server.token.startsWith('token:')
        ? server.token
        : 'token:${server.token}';
    return [secret, ...params];
  }

  /// One JSON-RPC call. Returns `result`, or throws [ApiException] on a
  /// JSON-RPC `error` object or a transport error.
  Future<dynamic> rpc(String method, [List<dynamic> params = const []]) async {
    final id = _nextId++;
    try {
      final response = await dio.post<Map<String, dynamic>>(
        'jsonrpc',
        data: {
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': buildParams(params),
        },
      );
      final data = response.data ?? {};
      if (data.containsKey('error')) {
        final error = data['error'] as Map<String, dynamic>?;
        throw ApiException(
          'aria2 $method failed: ${error?['message'] ?? 'unknown'}',
          statusCode: response.statusCode,
        );
      }
      return data['result'];
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException(
        'aria2 $method failed: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
        cause: e,
      );
    }
  }

  /// aria2.getVersion — also the connectivity check.
  Future<bool> testConnection() async {
    final result = await rpc('aria2.getVersion');
    return result is Map && result.containsKey('version');
  }

  /// Structured connectivity check: getVersion ok, otherwise
  /// unreachable — except a wrong/missing secret. aria2 answers that
  /// with the JSON-RPC error `{"code":1,"message":"Unauthorized"}`
  /// (aria2 docs, troubleshooting): the server is reachable, the
  /// secret is wrong, so this is needsAuth, not unreachable.
  Future<ConnectionResult> testConnectionResult() async {
    try {
      final result = await rpc('aria2.getVersion');
      if (result is Map && result['version'] is String) {
        return ConnectionResult.ok(serverVersion: '${result['version']}');
      }
      return ConnectionResult.unreachable(message: 'aria2 返回异常');
    } on ApiException catch (e) {
      if (e.message.contains('Unauthorized')) {
        return ConnectionResult.needsAuth(
          message: server.token.isEmpty ? '需要 RPC 密钥' : 'RPC 密钥错误',
        );
      }
      return ConnectionResult.unreachable(message: e.message);
    }
  }

  /// aria2.tellActive (+ tellWaiting merged in [tellAll]).
  Future<List<DownloadTask>> tellActive() async {
    final result = await rpc('aria2.tellActive');
    final list = (result as List?) ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((json) => _taskFromJson(json, DownloadStatus.downloading))
        .toList();
  }

  /// aria2.tellWaiting — queued/paused tasks.
  Future<List<DownloadTask>> tellWaiting() async {
    final result = await rpc('aria2.tellWaiting', [0, 100]);
    final list = (result as List?) ?? [];
    return list.whereType<Map<String, dynamic>>().map((json) {
      final status = '${json['status'] ?? ''}';
      return _taskFromJson(
        json,
        status == 'paused' ? DownloadStatus.paused : DownloadStatus.queued,
      );
    }).toList();
  }

  /// Active + waiting + stopped, the unified download queue.
  /// Stopped is capped at the 100 most recent (tellStopped has no
  /// totalLength filter in the JSON-RPC API).
  Future<List<DownloadTask>> tellAll() async {
    final active = await tellActive();
    final waiting = await tellWaiting();
    final stopped = await tellStopped();
    return [...active, ...waiting, ...stopped];
  }

  /// aria2.tellStopped — finished / failed / removed tasks. The
  /// entry's `status` decides: only `complete` is completed; `error`
  /// and `removed` are failed (a failed download must be offered a
  /// retry, not shown as done).
  Future<List<DownloadTask>> tellStopped() async {
    final result = await rpc('aria2.tellStopped', [0, 100]);
    final list = (result as List?) ?? [];
    return list.whereType<Map<String, dynamic>>().map((json) {
      final status = '${json['status'] ?? ''}';
      return _taskFromJson(
        json,
        status == 'complete' ? DownloadStatus.completed : DownloadStatus.failed,
      );
    }).toList();
  }

  /// aria2.tellStatus — one download by GID.
  Future<DownloadTask?> tellStatus(String gid) async {
    final result = await rpc('aria2.tellStatus', [gid]);
    if (result is! Map<String, dynamic>) return null;
    return _taskFromJson(result, DownloadStatus.queued);
  }

  /// aria2.addUri — magnet link or http(s) URL. Returns the GID.
  /// [dir] is passed as the aria2 `dir` option when given.
  Future<String?> addUri(String uri, {String? dir}) async {
    final options = <String, dynamic>{};
    if (dir != null && dir.isNotEmpty) options['dir'] = dir;
    final result = await rpc('aria2.addUri', [
      [uri],
      if (options.isNotEmpty) options,
    ]);
    return result == null ? null : '$result';
  }

  /// aria2.pause.
  Future<bool> pause(String gid) async {
    final result = await rpc('aria2.pause', [gid]);
    return result == gid;
  }

  /// aria2.unpause.
  Future<bool> unpause(String gid) async {
    final result = await rpc('aria2.unpause', [gid]);
    return result == gid;
  }

  /// aria2.remove.
  Future<bool> remove(String gid) async {
    final result = await rpc('aria2.remove', [gid]);
    return result == gid;
  }

  DownloadTask _taskFromJson(
    Map<String, dynamic> json,
    DownloadStatus fallback,
  ) {
    final total = int.tryParse('${json['totalLength'] ?? 0}') ?? 0;
    final done = int.tryParse('${json['completedLength'] ?? 0}') ?? 0;
    final speed = int.tryParse('${json['downloadSpeed'] ?? 0}') ?? 0;
    final status = '${json['status'] ?? ''}';
    final resolved = switch (status) {
      'active' => DownloadStatus.downloading,
      'waiting' => DownloadStatus.queued,
      'paused' => DownloadStatus.paused,
      'complete' => DownloadStatus.completed,
      'error' => DownloadStatus.failed,
      _ => fallback,
    };
    final files = (json['files'] as List?) ?? [];
    final firstFile = files.isEmpty
        ? null
        : files.first as Map<String, dynamic>?;
    final path = '${firstFile?['path'] ?? ''}';
    final name = path.isEmpty ? '${json['gid'] ?? ''}' : path.split('/').last;
    final dir = path.isEmpty
        ? '${json['dir'] ?? ''}'
        : (path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '');
    final fileNames = files
        .whereType<Map<String, dynamic>>()
        .map((f) => '${f['path'] ?? ''}')
        .where((p) => p.isNotEmpty)
        .map((p) => p.split('/').last)
        .toList();
    return DownloadTask(
      id: '${json['gid']}',
      name: name,
      source: DownloadSource.aria2,
      status: resolved,
      progress: total > 0 ? done / total : 0,
      speedBytesPerSec: speed,
      sizeBytes: total,
      downloadedBytes: done,
      serverId: server.id,
      savePath: dir,
      files: fileNames,
    );
  }
}
