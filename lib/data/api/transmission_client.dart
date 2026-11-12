import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/errors.dart';
import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../models/download_task.dart';

/// Transmission client — its own native JSON-RPC protocol.
///
/// Every call is POST /transmission/rpc with a JSON body
/// `{"method": ..., "arguments": ...}`. A fresh server answers **409** with
/// an `X-Transmission-Session-Id` header; the client must resend the same
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
          );

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

  /// One RPC call, with the 409 session-id retry (at most one retry).
  /// The retry is wrapped the same way as the first call: a second
  /// failure surfaces as [ApiException], never as a raw [DioException]
  /// — repositories only catch [ApiException], so a leak here would
  /// break a whole refresh.
  Future<Map<String, dynamic>> rpc(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final body = {'method': method, 'arguments': arguments};
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
    if (server.username.isNotEmpty) {
      headers['Authorization'] =
          'Basic ${_basicAuth(server.username, server.token)}';
    }
    final response = await dio.post<Map<String, dynamic>>(
      'transmission/rpc',
      data: body,
      options: Options(headers: headers),
    );
    final data = response.data ?? {};
    if (data['result'] != 'success') {
      throw ApiException(
        'Transmission error: ${data['result'] ?? 'unknown'}',
        statusCode: response.statusCode,
      );
    }
    return (data['arguments'] as Map<String, dynamic>?) ?? {};
  }

  String _basicAuth(String user, String pass) =>
      base64Encode(utf8.encode('$user:$pass'));

  /// session-get — also the connectivity check.
  Future<bool> testConnection() async {
    await rpc('session-get');
    return true;
  }

  /// Structured connectivity check: session-get ok, otherwise
  /// unreachable (auth failures surface as unreachable here — a
  /// Transmission server does not expose a public probe).
  Future<ConnectionResult> testConnectionResult() async {
    try {
      await rpc('session-get');
      return ConnectionResult.ok();
    } on ApiException catch (e) {
      return ConnectionResult.unreachable(message: e.message);
    }
  }

  /// torrent-get with the fields the unified model needs.
  Future<List<DownloadTask>> torrentGet() async {
    final args = await rpc('torrent-get', {
      'fields': [
        'id',
        'name',
        'status',
        'percentDone',
        'rateDownload',
        'totalSize',
        'downloadedEver',
        'eta',
        'downloadDir',
        'hashString',
      ],
    });
    final torrents = (args['torrents'] as List?) ?? [];
    return torrents
        .whereType<Map<String, dynamic>>()
        .map(_taskFromJson)
        .toList();
  }

  /// torrent-add — magnet link or torrent URL.
  Future<String?> torrentAdd(String filename, {String? downloadDir}) async {
    final args = <String, dynamic>{'filename': filename};
    if (downloadDir != null && downloadDir.isNotEmpty) {
      args['download-dir'] = downloadDir;
    }
    final result = await rpc('torrent-add', args);
    final added = result['torrent-added'] as Map<String, dynamic>?;
    final dup = result['torrent-duplicate'] as Map<String, dynamic>?;
    final id = added?['id'] ?? dup?['id'];
    return id == null ? null : '$id';
  }

  Future<void> _torrentAction(String method, List<int> ids) async {
    await rpc(method, {'ids': ids});
  }

  /// torrent-start.
  Future<void> start(List<int> ids) => _torrentAction('torrent-start', ids);

  /// torrent-stop.
  Future<void> stop(List<int> ids) => _torrentAction('torrent-stop', ids);

  /// torrent-remove (deleteLocalData=false keeps the files).
  Future<void> remove(List<int> ids, {bool deleteLocalData = false}) async {
    await rpc('torrent-remove', {
      'ids': ids,
      'delete-local-data': deleteLocalData,
    });
  }

  /// torrent-set-location — move a torrent's data to a new directory.
  Future<void> setLocation(
    List<int> ids,
    String location, {
    bool move = false,
  }) async {
    await rpc('torrent-set-location', {
      'ids': ids,
      'location': location,
      'move': move,
    });
  }

  DownloadTask _taskFromJson(Map<String, dynamic> json) {
    // Transmission status: 0 stopped, 1 check-wait, 2 check, 3 download-wait,
    // 4 downloading, 5 seed-wait, 6 seeding.
    final statusCode = (json['status'] as num?)?.toInt() ?? 0;
    final status = switch (statusCode) {
      4 || 3 => DownloadStatus.downloading,
      0 => DownloadStatus.paused,
      6 || 5 => DownloadStatus.completed,
      _ => DownloadStatus.queued,
    };
    return DownloadTask(
      id: '${json['id']}',
      name: '${json['name'] ?? ''}',
      source: DownloadSource.transmission,
      status: status,
      progress: ((json['percentDone'] as num?) ?? 0).toDouble(),
      speedBytesPerSec: (json['rateDownload'] as num?)?.toInt() ?? 0,
      sizeBytes: (json['totalSize'] as num?)?.toInt() ?? 0,
      downloadedBytes: (json['downloadedEver'] as num?)?.toInt() ?? 0,
      serverId: server.id,
      etaSeconds: (json['eta'] as num?)?.toInt() ?? -1,
      savePath: '${json['downloadDir'] ?? ''}',
      hash: '${json['hashString'] ?? ''}',
    );
  }
}
