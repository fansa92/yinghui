// qB 403 recovery + friendly per-server download errors.
//
// The bug (user screenshot 2026-11-12): the Downloads page showed a
// raw Dio exception dump in red — "qb: qBittorrent torrents/info
// failed: This exception was thrown because the response has a status
// code of 403 and RequestOptions.validateStatus was configured to
// throw…"
//
// Two fixes under test:
// 1. The 403 itself: a login that answers Ok but sets no SID cookie
//    used to leave the client session-less, so torrents/info went out
//    without a cookie, came back 403, and _withRelogin refused to
//    retry because _sid was null. Now login() fails fast when no SID
//    was captured, and _withRelogin retries on any 403.
// 2. The message: per-server errors are short friendly text only —
//    the raw Dio dump never reaches the UI.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/server_store.dart';

Server _qbServer() => Server(
  id: 'srv-qb',
  type: ServerType.qbittorrent,
  name: 'Test qBittorrent',
  host: 'https://sg.kass.qzz.io/qb/',
  port: 443,
  username: 'yang',
  token: 'pw',
);

/// A Dio whose requests are answered by [handler] instead of the network.
Dio _mockDio(
  FutureOr<Response<dynamic>> Function(RequestOptions options) handler,
) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, h) async {
        h.resolve(await handler(options));
      },
    ),
  );
  return dio;
}

Response<dynamic> _ok(
  RequestOptions options,
  dynamic data, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) => Response<dynamic>(
  requestOptions: options,
  data: data,
  statusCode: statusCode,
  headers: headers == null ? Headers() : Headers.fromMap(headers),
);

/// A real-looking 403: Dio's validateStatus would throw exactly this
/// for an HTTP 403, with the message the user saw in the screenshot.
DioException _forbidden(RequestOptions options) => DioException(
  requestOptions: options,
  response: Response<dynamic>(requestOptions: options, statusCode: 403),
  type: DioExceptionType.badResponse,
  message:
      'This exception was thrown because the response has a status code '
      'of 403 and RequestOptions.validateStatus was configured to throw.',
);

void main() {
  group('qB login without a SID cookie', () {
    test('login() fails fast with a clear auth error', () async {
      final client = QbittorrentClient(
        _qbServer(),
        dio: _mockDio((options) {
          // 200 "Ok." but no Set-Cookie header at all.
          return _ok(options, 'Ok.');
        }),
      );
      await expectLater(
        client.login(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('SID')),
        ),
      );
    });
  });

  group('qB 403 re-login + retry', () {
    test('torrents/info 403 re-logs in once and retries', () async {
      var loginCalls = 0;
      var infoCalls = 0;
      final client = QbittorrentClient(
        _qbServer(),
        dio: _mockDio((options) {
          if (options.path.contains('auth/login')) {
            loginCalls++;
            return _ok(
              options,
              '',
              statusCode: 204,
              headers: {
                'set-cookie': ['SID=sid$loginCalls; path=/'],
              },
            );
          }
          infoCalls++;
          if (infoCalls == 1) throw _forbidden(options);
          return _ok(options, <dynamic>[]);
        }),
      );

      final tasks = await client.torrentsInfo();
      expect(tasks, isEmpty);
      expect(
        loginCalls,
        1,
        reason:
            'lazy auth: no login before the first 403, one login to recover',
      );
      expect(infoCalls, 2, reason: 'original call + one retry');
    });

    test('retry 403 again surfaces the error, no loop', () async {
      var loginCalls = 0;
      var infoCalls = 0;
      final client = QbittorrentClient(
        _qbServer(),
        dio: _mockDio((options) {
          if (options.path.contains('auth/login')) {
            loginCalls++;
            return _ok(
              options,
              '',
              statusCode: 204,
              headers: {
                'set-cookie': ['SID=sid$loginCalls; path=/'],
              },
            );
          }
          infoCalls++;
          throw _forbidden(options);
        }),
      );

      await expectLater(
        client.torrentsInfo(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      expect(loginCalls, 1, reason: 'lazy auth: one login to recover, no loop');
      expect(infoCalls, 2, reason: 'original call + one retry');
    });
  });

  group('friendly per-server download errors', () {
    test('friendlyError maps status codes to short text only', () {
      final server = _qbServer();
      expect(
        RealDownloadRepository.friendlyError(
          server,
          ApiException('qBittorrent torrents/info failed: …', statusCode: 403),
        ),
        'Test qBittorrent：登录已过期，重新登录失败，请重新测试连接',
      );
      expect(
        RealDownloadRepository.friendlyError(
          server,
          ApiException('x', statusCode: 500),
        ),
        'Test qBittorrent：服务器返回 HTTP 500',
      );
      expect(
        RealDownloadRepository.friendlyError(
          server,
          ApiException('connection refused'),
        ),
        'Test qBittorrent：无法连接，请检查网络和服务器地址',
      );
    });

    test('a surviving 403 shows a short error, never a Dio dump', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      await store.add(_qbServer());

      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(
          s,
          dio: _mockDio((options) {
            if (options.path.contains('auth/login')) {
              return _ok(
                options,
                '',
                statusCode: 204,
                headers: {
                  'set-cookie': ['SID=s1; path=/'],
                },
              );
            }
            // torrents/info 403s even after the re-login.
            throw _forbidden(options);
          }),
        ),
      );
      addTearDown(repo.dispose);

      await repo.refresh();
      final error = repo.errors['srv-qb'];
      expect(error, isNotNull);
      expect(error, contains('登录'));
      for (final banned in [
        'RequestOptions',
        'validateStatus',
        'DioException',
        'torrents/info failed',
      ]) {
        expect(error, isNot(contains(banned)), reason: 'must not leak $banned');
      }
      expect(error!.length, lessThan(60));
      expect(repo.tasks, isEmpty);
    });
  });
}
