// Tests for the download-auth batch (2026-11-14): auth-failure
// backoff, distinct 401/403 messages, lazy qB auth, the login
// mutex, the port in the client fingerprint, JSON-RPC auth errors
// on HTTP 200, Transmission password-only auth, credential load
// timing, and the fake-demo-tasks leak into Home.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/downloads/downloads_page.dart';
import 'package:yinghui/features/home/home_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/servers/servers_page.dart';
import 'package:yinghui/core/settings.dart';

Dio _mockDio(Future<Response<dynamic>> Function(RequestOptions) handler) {
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
}) {
  final map = <String, List<String>>{};
  if (headers != null) map.addAll(headers);
  return Response(
    requestOptions: options,
    statusCode: statusCode,
    data: data,
    headers: Headers.fromMap(map),
  );
}

DioException _httpError(RequestOptions options, int statusCode) => DioException(
  requestOptions: options,
  response: Response(requestOptions: options, statusCode: statusCode, data: ''),
  type: DioExceptionType.badResponse,
);

Server _qbServer({
  String id = 'srv-qb',
  String host = 'qb.local',
  int port = 8080,
  String username = 'yang',
  String token = 'pw',
}) => Server(
  id: id,
  type: ServerType.qbittorrent,
  name: 'Test qBittorrent',
  host: host,
  port: port,
  username: username,
  token: token,
);

Server _ariaServer({String id = 'srv-aria'}) => Server(
  id: id,
  type: ServerType.aria2,
  name: 'Test aria2',
  host: 'aria.local',
  port: 6800,
  username: '',
  token: 'secret',
);

Server _trServer({
  String username = '',
  String token = '',
  String id = 'srv-tr',
}) => Server(
  id: id,
  type: ServerType.transmission,
  name: 'Test Transmission',
  host: 'tr.local',
  port: 9091,
  username: username,
  token: token,
);

/// qB mock whose behaviour can be flipped mid-test (fail-auth vs ok),
/// with login/info call counters.
class _QbMock {
  var mode = 'fail401'; // 'fail401' | 'ok'
  var loginCalls = 0;
  var infoCalls = 0;

  Dio get dio => _mockDio((options) async {
    if (options.path.contains('auth/login')) {
      loginCalls++;
      if (mode == 'fail401') throw _httpError(options, 401);
      return _ok(
        options,
        '',
        statusCode: 204,
        headers: {
          'set-cookie': ['SID=s1; path=/'],
        },
      );
    }
    infoCalls++;
    if (mode == 'fail401') throw _httpError(options, 403);
    return _ok(options, <dynamic>[]);
  });
}

/// Builds a repo backed by [_QbMock] for one qB server. Uses the
/// in-memory fake secure storage: the real plugin's method channel
/// never completes in a widget test (and throws MissingPluginException
/// in a plain test), so the token round-trips through the fake instead.
Future<({RealDownloadRepository repo, _QbMock mock, ServerStore store})>
makeQbRepo({String token = 'pw'}) async {
  final db = AppDatabase.forExecutor(NativeDatabase.memory());
  addTearDown(db.close);
  final store = ServerStore(database: db, secureStorage: _FakeSecureStorage());
  await store.add(_qbServer(token: token));
  final mock = _QbMock();
  final repo = RealDownloadRepository(
    store: store,
    database: db,
    qbFactory: (s) => QbittorrentClient(s, dio: mock.dio),
  );
  return (repo: repo, mock: mock, store: store);
}

void main() {
  group('qB lazy auth', () {
    test('no-auth server: torrents/info works with zero logins', () async {
      var loginCalls = 0;
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          loginCalls++;
          throw StateError('login must not be called on a no-auth server');
        }
        return _ok(options, <dynamic>[]);
      });
      final client = QbittorrentClient(
        _qbServer(username: '', token: ''),
        dio: dio,
      );
      expect(await client.torrentsInfo(), isEmpty);
      expect(loginCalls, 0);
    });

    test('first 403 logs in once, then the retry succeeds', () async {
      var loginCalls = 0;
      var infoCalls = 0;
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          loginCalls++;
          return _ok(
            options,
            '',
            statusCode: 204,
            headers: {
              'set-cookie': ['SID=s1; path=/'],
            },
          );
        }
        infoCalls++;
        if (infoCalls == 1) throw _httpError(options, 403);
        return _ok(options, <dynamic>[]);
      });
      final client = QbittorrentClient(_qbServer(), dio: dio);
      expect(await client.torrentsInfo(), isEmpty);
      expect(loginCalls, 1);
      expect(infoCalls, 2);
    });

    test('wrong password: login 401 surfaces as 401', () async {
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          throw _httpError(options, 401);
        }
        throw _httpError(options, 403);
      });
      final client = QbittorrentClient(_qbServer(), dio: dio);
      final err = await _expectApiException(client.torrentsInfo);
      expect(err.statusCode, 401);
    });

    test('concurrent calls share one login (mutex)', () async {
      var loginCalls = 0;
      var infoCalls = 0;
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          loginCalls++;
          // Slow login: both callers must be waiting on this one
          // Future instead of each firing their own login.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _ok(
            options,
            '',
            statusCode: 204,
            headers: {
              'set-cookie': ['SID=s1; path=/'],
            },
          );
        }
        infoCalls++;
        if (infoCalls <= 2) throw _httpError(options, 403);
        return _ok(options, <dynamic>[]);
      });
      final client = QbittorrentClient(_qbServer(), dio: dio);
      final results = await Future.wait([
        client.torrentsInfo(),
        client.torrentsInfo(),
      ]);
      expect(results, [<dynamic>[], <dynamic>[]]);
      expect(loginCalls, 1);
      expect(infoCalls, 4);
    });

    test('testConnection is lazy: no-auth server needs no login', () async {
      var loginCalls = 0;
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          loginCalls++;
          throw StateError('login must not be called');
        }
        return _ok(options, 'v5.2.1');
      });
      final client = QbittorrentClient(
        _qbServer(username: '', token: ''),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(loginCalls, 0);
    });

    test('testConnectionResult: wrong password says so', () async {
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          throw _httpError(options, 401);
        }
        throw _httpError(options, 403);
      });
      final client = QbittorrentClient(_qbServer(), dio: dio);
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '用户名或密码错误，请检查账号');
    });

    test('testConnectionResult: no credentials says 登录', () async {
      final dio = _mockDio((options) async {
        if (options.path.contains('auth/login')) {
          throw _httpError(options, 401);
        }
        throw _httpError(options, 403);
      });
      final client = QbittorrentClient(
        _qbServer(username: '', token: ''),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '服务器可达，需要登录');
    });
  });

  group('auth-failure backoff', () {
    test('three consecutive auth failures stop polling the server', () async {
      final (:repo, :mock, store: _) = await makeQbRepo();
      addTearDown(repo.dispose);
      for (var i = 0; i < 4; i++) {
        await repo.refresh();
      }
      // 3 refreshes each attempted one login; the 4th made no calls.
      expect(mock.loginCalls, 3);
      expect(mock.infoCalls, 3);
      expect(repo.isAuthBackedOff('srv-qb'), isTrue);
      expect(repo.errors['srv-qb'], contains('用户名或密码错误'));
    });

    test('retryLogin clears the backoff and retries immediately', () async {
      final (:repo, :mock, :store) = await makeQbRepo();
      addTearDown(repo.dispose);
      for (var i = 0; i < 3; i++) {
        await repo.refresh();
      }
      expect(repo.isAuthBackedOff('srv-qb'), isTrue);
      mock.mode = 'ok';
      await repo.retryLogin('srv-qb');
      expect(repo.isAuthBackedOff('srv-qb'), isFalse);
      expect(repo.errors, isEmpty);
      expect(mock.infoCalls, 4);
    });

    test('changing credentials clears the backoff and retries', () async {
      final (:repo, :mock, :store) = await makeQbRepo();
      addTearDown(repo.dispose);
      for (var i = 0; i < 3; i++) {
        await repo.refresh();
      }
      expect(repo.isAuthBackedOff('srv-qb'), isTrue);
      await store.update(_qbServer(token: 'newpw'));
      await repo.refresh();
      expect(repo.isAuthBackedOff('srv-qb'), isFalse);
      expect(mock.loginCalls, 4);
    });
  });

  group('distinct 401/403 messages', () {
    test('friendlyError: 401 wrong password, 403 expired session', () {
      final qb = _qbServer();
      expect(
        RealDownloadRepository.friendlyError(
          qb,
          ApiException('Unauthorized', statusCode: 401),
        ),
        'Test qBittorrent：用户名或密码错误，请检查账号',
      );
      expect(
        RealDownloadRepository.friendlyError(
          qb,
          ApiException('Forbidden', statusCode: 403),
        ),
        'Test qBittorrent：登录已过期，重新登录失败，请重新测试连接',
      );
    });

    test('friendlyError: aria2 auth errors map to RPC-key messages', () {
      final aria = _ariaServer();
      expect(
        RealDownloadRepository.friendlyError(
          aria,
          ApiException('RPC 密钥错误', statusCode: 401),
        ),
        'Test aria2：RPC 密钥错误，请检查密钥',
      );
      // JSON-RPC auth errors ride on HTTP 200: no status code, but
      // the message names the auth failure.
      expect(
        RealDownloadRepository.friendlyError(
          aria,
          ApiException('Unauthorized'),
        ),
        'Test aria2：RPC 密钥错误，请检查密钥',
      );
    });

    test('friendlyError: other errors keep short generic messages', () {
      final qb = _qbServer();
      expect(
        RealDownloadRepository.friendlyError(
          qb,
          ApiException('x', statusCode: 500),
        ),
        'Test qBittorrent：服务器返回 HTTP 500',
      );
      expect(
        RealDownloadRepository.friendlyError(qb, ApiException('x')),
        'Test qBittorrent：无法连接，请检查网络和服务器地址',
      );
    });
  });

  group('client fingerprint', () {
    test('editing the port rebuilds the client', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      await store.add(_qbServer(port: 8080));
      var factoryCalls = 0;
      final seenPorts = <int>[];
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) {
          factoryCalls++;
          final dio = Dio(BaseOptions(baseUrl: '${s.baseUrl}/'));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, h) async {
                seenPorts.add(options.uri.port);
                h.resolve(_ok(options, <dynamic>[]));
              },
            ),
          );
          return QbittorrentClient(s, dio: dio);
        },
      );
      addTearDown(repo.dispose);
      await repo.refresh();
      expect(factoryCalls, 1);
      expect(seenPorts, [8080]);
      await store.update(_qbServer(port: 9090));
      await repo.refresh();
      expect(factoryCalls, 2);
      expect(seenPorts, [8080, 9090]);
    });
  });

  group('JSON-RPC auth errors on HTTP 200', () {
    test('aria2 wrong secret -> ApiException 401', () async {
      final dio = _mockDio((options) async {
        return _ok(options, {
          'jsonrpc': '2.0',
          'id': 'yinghui',
          'error': {'code': 1, 'message': 'Unauthorized'},
        });
      });
      final client = Aria2Client(_ariaServer(), dio: dio);
      final err = await _expectApiException(client.testConnection);
      expect(err.statusCode, 401);
      // The raw message keeps the server's wording; the friendly
      // "RPC 密钥错误" mapping happens in friendlyError (verified at
      // the repository level below).
      expect(err.message, contains('Unauthorized'));
    });

    test('aria2 wrong secret shows a friendly message in Downloads', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      await store.add(_ariaServer());
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        ariaFactory: (s) => Aria2Client(
          s,
          dio: _mockDio((options) async {
            return _ok(options, {
              'jsonrpc': '2.0',
              'id': 'yinghui',
              'error': {'code': 1, 'message': 'Unauthorized'},
            });
          }),
        ),
      );
      addTearDown(repo.dispose);
      await repo.refresh();
      expect(repo.errors['srv-aria'], contains('RPC 密钥错误'));
    });

    test(
      'Transmission JSON-RPC unauthorized error -> ApiException 401',
      () async {
        final dio = _mockDio((options) async {
          return _ok(options, {
            'jsonrpc': '2.0',
            'id': 1,
            'error': {
              'code': -32602,
              'message': 'unauthorized',
              'data': {'errorString': 'unauthorized'},
            },
          });
        });
        final client = TransmissionClient(
          _trServer(username: 'u', token: 'p'),
          dio: dio,
        );
        final err = await _expectApiException(client.testConnection);
        expect(err.statusCode, 401);
        expect(err.message, contains('用户名或密码错误'));
      },
    );

    test('Transmission wrong password shows a friendly message', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      await store.add(_trServer(username: 'u', token: 'wrong'));
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        transmissionFactory: (s) => TransmissionClient(
          s,
          dio: _mockDio((options) async {
            return _ok(options, {
              'jsonrpc': '2.0',
              'id': 1,
              'error': {
                'code': -32602,
                'message': 'unauthorized',
                'data': {'errorString': 'unauthorized'},
              },
            });
          }),
        ),
      );
      addTearDown(repo.dispose);
      await repo.refresh();
      expect(repo.errors['srv-tr'], contains('用户名或密码错误'));
    });
  });

  group('Transmission password-only auth', () {
    test('password without a username is still sent as Basic auth', () async {
      String? authHeader;
      final dio = _mockDio((options) async {
        authHeader = options.headers['Authorization'] as String?;
        return _ok(options, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {'version': '4.0.5'},
        });
      });
      final client = TransmissionClient(
        _trServer(username: '', token: 'pw'),
        dio: dio,
      );
      await client.testConnection();
      expect(authHeader, 'Basic ${base64Encode(utf8.encode(':pw'))}');
    });

    test('probe with a password but 401 says wrong password', () async {
      final dio = _mockDio((options) async {
        throw _httpError(options, 401);
      });
      final client = TransmissionClient(
        _trServer(username: '', token: 'wrong'),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '用户名或密码错误');
    });

    test('probe with no credentials at all says 需要登录', () async {
      final dio = _mockDio((options) async {
        throw _httpError(options, 401);
      });
      final client = TransmissionClient(_trServer(), dio: dio);
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '需要登录');
    });
  });

  group('probe warms the cached client', () {
    test('testConnection reuses one client and warms its SID', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      await store.add(_qbServer());
      var loginCalls = 0;
      var factoryCalls = 0;
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) {
          factoryCalls++;
          return QbittorrentClient(
            s,
            dio: _mockDio((options) async {
              if (options.path.contains('auth/login')) {
                loginCalls++;
                return _ok(
                  options,
                  '',
                  statusCode: 204,
                  headers: {
                    'set-cookie': ['SID=s1; path=/'],
                  },
                );
              }
              final cookie = options.headers['Cookie'] as String?;
              if (cookie == null || !cookie.contains('SID=s1')) {
                throw _httpError(options, 403);
              }
              if (options.path.contains('app/version')) {
                return _ok(options, 'v5.2.1');
              }
              return _ok(options, <dynamic>[]);
            }),
          );
        },
      );
      addTearDown(repo.dispose);
      // Two probes: one client, one login (the second probe reuses
      // the warmed SID).
      expect(
        (await repo.testConnection(_qbServer())).status,
        ConnectionStatus.ok,
      );
      expect(
        (await repo.testConnection(_qbServer())).status,
        ConnectionStatus.ok,
      );
      expect(factoryCalls, 1);
      expect(loginCalls, 1);
      // The Downloads refresh then needs no further login.
      await repo.refresh();
      expect(loginCalls, 1);
      expect(repo.errors, isEmpty);
    });
  });

  group('credential load timing', () {
    test('isLoaded is false before load and true after', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      expect(store.isLoaded, isFalse);
      await store.load();
      expect(store.isLoaded, isTrue);
    });

    test('a secure-storage read failure keeps the server, flagged', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final good = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await good.add(_qbServer());
      final failing = ServerStore(
        database: db,
        secureStorage: _ThrowingSecureStorage(),
      );
      await failing.load();
      expect(failing.servers.length, 1);
      expect(failing.servers.first.token, isEmpty);
      expect(failing.tokenReadFailedIds, contains('srv-qb'));
    });

    testWidgets('Servers page warns when the secret failed to read', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final good = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await good.add(_qbServer());
      final failing = ServerStore(
        database: db,
        secureStorage: _ThrowingSecureStorage(),
      );
      await failing.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ServersPage(store: failing)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('密钥读取失败'), findsOneWidget);
    });
  });

  group('no demo tasks on Home without credentials', () {
    test('refresh with no credentials yields no tasks', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      final store = ServerStore(database: db);
      await store.load();
      final repo = RealDownloadRepository(store: store, database: db);
      addTearDown(repo.dispose);
      await repo.refresh();
      expect(repo.tasks, isEmpty);
      expect(repo.hasCredentials, isFalse);
    });

    testWidgets('Home hides the downloads row without credentials', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      // Fake secure storage, like the other HomePage widget tests:
      // the real plugin has no implementation in tests.
      // NOTE: do NOT call store.load() here: an empty database would
      // run the legacy-migration path, whose
      // SharedPreferences.getInstance() never completes in a widget
      // test (no channel handler). An unloaded empty store is
      // already the "no credentials" state this test needs.
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      final downloadRepo = _LeakyFakeDownloadRepo();
      final musicRepo = RealMusicRepository(store: store, database: db);
      final videoRepo = RealVideoRepository(store: store, database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _NoopBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              store: store,
              downloadRepo: downloadRepo,
              musicRepo: musicRepo,
              videoRepo: videoRepo,
              history: PlaybackStore(db),
              player: player,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      // Fixed pumps, not pumpAndSettle: Home keeps a loading
      // indicator animating while its sections load, so settle
      // would wait forever (the same pattern api_fixes_test uses
      // for HomePage).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // Even though the fake repo carries a downloading task, the
      // row must not appear: no credentials means no real downloads.
      expect(find.text('进行中的下载'), findsNothing);
      expect(find.text('Ubuntu 24.04 LTS.iso'), findsNothing);
    });
  });

  group('Downloads error recovery actions', () {
    testWidgets('backed-off error shows 重新登录 and 去服务器页', (tester) async {
      final (:repo, :mock, :store) = await makeQbRepo();
      addTearDown(repo.dispose);
      // The refreshes run in runAsync: Dio's interceptor chain is
      // built on `Future(...)`, which the widget test's FakeAsync
      // freezes until a pump — awaiting refresh() directly here
      // would hang forever. (The page itself is only pumped after
      // the backoff is established.)
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          await repo.refresh();
        }
      });
      expect(repo.isAuthBackedOff('srv-qb'), isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              repo: repo,
              store: store,
              settings: SettingsService(),
              // No polling while asserting: the real repo's 5s timer
              // would keep scheduling frames and pumpAndSettle would
              // never settle. The error state is already in the repo
              // from the three refreshes above.
              isActive: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('重新登录'), findsOneWidget);
      expect(find.text('去服务器页'), findsOneWidget);
      // Fix the credentials server-side, tap 重新登录: the error
      // clears and the button disappears.
      mock.mode = 'ok';
      await tester.tap(find.text('重新登录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('重新登录'), findsNothing);
      expect(repo.errors, isEmpty);
    });
  });
}

Future<ApiException> _expectApiException(Future<void> Function() fn) async {
  try {
    await fn();
  } on ApiException catch (e) {
    return e;
  }
  throw TestFailure('expected an ApiException');
}

/// In-memory secure storage for tests.
class _FakeSecureStorage extends FlutterSecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _map[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

/// Secure storage whose reads always fail (e.g. a locked keychain).
class _ThrowingSecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('keychain locked');
  }
}

/// A download repo that still carries tasks while reporting no
/// credentials — the old leak shape. Home must not show its row.
class _LeakyFakeDownloadRepo extends ChangeNotifier
    implements DownloadRepository {
  @override
  bool isAuthBackedOff(String serverId) => false;

  @override
  Future<void> retryLogin(String serverId) async {}

  @override
  String? serverFilter;

  @override
  bool get hasCredentials => false;

  @override
  List<Server> get usableDownloaders => const [];

  @override
  List<DownloadTask> get tasks => [
    DownloadTask(
      id: 'demo',
      name: 'Ubuntu 24.04 LTS.iso',
      source: DownloadSource.qbittorrent,
      status: DownloadStatus.downloading,
      progress: 0.4,
      sizeBytes: 100,
      downloadedBytes: 40,
    ),
  ];

  @override
  List<DownloadTask> get activeTasks => tasks;

  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Map<String, String> get errors => const {};

  @override
  bool get isLoading => false;

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async => false;

  @override
  Future<bool> pauseTask(DownloadTask task) async => false;

  @override
  Future<bool> resumeTask(DownloadTask task) async => false;

  @override
  Future<bool> deleteTask(
    DownloadTask task, {
    bool deleteFiles = false,
  }) async => false;

  @override
  Future<bool> retryTask(DownloadTask task) async => false;

  @override
  void startPolling({int intervalSeconds = 5}) {}

  @override
  void stopPolling() {}
}

class _NoopBackend implements PlayerBackend {
  @override
  Stream<bool> get playing => Stream.value(false);

  @override
  Stream<Duration> get position => Stream.value(Duration.zero);

  @override
  Stream<Duration> get duration => Stream.value(Duration.zero);

  @override
  Stream<bool> get completed => Stream.value(false);

  @override
  Future<void> open(String url) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> stop() async {}

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}
}
