// aria2 / Transmission add flow: what each service's auth really is,
// and that Test Connection tells a wrong credential apart from a
// server that cannot be reached at all.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/servers/servers_page.dart';

Server _server({
  String id = 'srv-1',
  ServerType type = ServerType.aria2,
  String username = '',
  String token = '',
}) => Server(
  id: id,
  type: type,
  name: 'Test',
  host: 'http://192.168.1.2',
  port: type == ServerType.aria2 ? 6800 : 9091,
  username: username,
  token: token,
);

/// In-memory secure storage for tests (copied from the desktop
/// Servers CRUD tests): the real plugin hangs in widget tests.
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _data[key];

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
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }
}

void main() {
  group('aria2 auth', () {
    /// Mock aria2 JSON-RPC: records the params of the last call and
    /// answers getVersion from [respond].
    (Dio dio, List<dynamic> Function() lastParams) mockAria2(
      Map<String, dynamic> Function() respond,
    ) {
      var last = <dynamic>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final data = options.data as Map<String, dynamic>?;
              last = List<dynamic>.from(data?['params'] as List? ?? []);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: respond(),
                ),
              );
            },
          ),
        );
      return (dio, () => last);
    }

    test(
      'the secret is sent as the first param with the token: prefix',
      () async {
        final (dio, lastParams) = mockAria2(
          () => {
            'result': {'version': '1.37.0'},
          },
        );
        final client = Aria2Client(_server(token: 'my-secret'), dio: dio);
        final result = await client.testConnectionResult();
        expect(result.isOk, isTrue);
        expect(result.serverVersion, '1.37.0');
        expect(lastParams().first, 'token:my-secret');
      },
    );

    test('a secret pasted with token: already on it is not doubled', () async {
      final (dio, lastParams) = mockAria2(
        () => {
          'result': {'version': '1.37.0'},
        },
      );
      final client = Aria2Client(_server(token: 'token:my-secret'), dio: dio);
      await client.testConnectionResult();
      expect(lastParams().first, 'token:my-secret');
    });

    test('wrong secret -> needsAuth, not unreachable', () async {
      final (dio, _) = mockAria2(
        () => {
          'error': {'code': 1, 'message': 'Unauthorized'},
        },
      );
      final client = Aria2Client(_server(token: 'wrong'), dio: dio);
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, 'RPC 密钥错误');
    });

    test('server needs a secret but none is set -> needsAuth', () async {
      final (dio, lastParams) = mockAria2(
        () => {
          'error': {'code': 1, 'message': 'Unauthorized'},
        },
      );
      final client = Aria2Client(_server(), dio: dio);
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '需要 RPC 密钥');
      expect(lastParams(), isEmpty);
    });

    test('transport failure is still unreachable', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'Connection refused',
                ),
              );
            },
          ),
        );
      final client = Aria2Client(_server(token: 'x'), dio: dio);
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.unreachable);
    });
  });

  group('Transmission auth', () {
    /// Mock Transmission RPC: records the last request's headers and
    /// answers session_get from [respond].
    (Dio dio, Map<String, String> Function() lastHeaders) mockTransmission(
      Map<String, dynamic> Function() respond, {
      int statusCode = 200,
    }) {
      var last = <String, String>{};
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              last = Map<String, String>.from(
                (options.headers as Map?)?.cast<String, String>() ?? {},
              );
              if (statusCode != 200) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: statusCode,
                    ),
                  ),
                );
                return;
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'result': respond()},
                ),
              );
            },
          ),
        );
      return (dio, () => last);
    }

    test('username/password are sent as HTTP Basic auth', () async {
      final (dio, lastHeaders) = mockTransmission(() => {'version': '4.0.5'});
      final client = TransmissionClient(
        _server(type: ServerType.transmission, username: 'admin', token: 'pw'),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, '4.0.5');
      expect(
        lastHeaders()['Authorization'],
        'Basic ${base64Encode(utf8.encode('admin:pw'))}',
      );
    });

    test('wrong credentials (401) -> needsAuth, not unreachable', () async {
      final (dio, _) = mockTransmission(() => {}, statusCode: 401);
      final client = TransmissionClient(
        _server(type: ServerType.transmission, username: 'admin', token: 'bad'),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '用户名或密码错误');
    });

    test(
      'no credentials and server needs none -> ok, no auth header',
      () async {
        final (dio, lastHeaders) = mockTransmission(() => {'version': '4.0.5'});
        final client = TransmissionClient(
          _server(type: ServerType.transmission),
          dio: dio,
        );
        final result = await client.testConnectionResult();
        expect(result.isOk, isTrue);
        expect(lastHeaders().containsKey('Authorization'), isFalse);
      },
    );

    test('no credentials but server needs auth (401) -> needsAuth', () async {
      final (dio, _) = mockTransmission(() => {}, statusCode: 401);
      final client = TransmissionClient(
        _server(type: ServerType.transmission),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.message, '需要登录');
    });
  });

  group('add-server form fields per type', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> openForm(
      WidgetTester tester,
      ServerStore store,
      String typeLabel,
    ) async {
      await tester.pumpWidget(MaterialApp(home: ServersPage(store: store)));
      await tester.pump();
      await tester.tap(find.byTooltip('添加服务器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(typeLabel));
      await tester.pumpAndSettle();
    }

    Finder secretField(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label,
    );

    testWidgets('aria2 asks for its RPC secret, not a username', (
      tester,
    ) async {
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await openForm(tester, store, 'aria2');

      expect(find.text('添加aria2'), findsOneWidget);
      expect(find.text('用户名'), findsNothing);
      expect(secretField('RPC 密钥（可选）'), findsOneWidget);
      expect(find.text('没设 --rpc-secret 就留空'), findsOneWidget);
    });

    testWidgets('Transmission asks for username + password', (tester) async {
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await openForm(tester, store, 'Transmission');

      expect(find.text('添加Transmission'), findsOneWidget);
      expect(find.text('用户名'), findsOneWidget);
      expect(secretField('密码'), findsOneWidget);
    });

    testWidgets('other types keep the generic secret label', (tester) async {
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await openForm(tester, store, 'Emby');

      expect(find.text('添加Emby'), findsOneWidget);
      expect(find.text('用户名'), findsOneWidget);
      expect(secretField('密码 / Token / 密钥'), findsOneWidget);
    });

    testWidgets('Test Connection surfaces a wrong secret as needs login', (
      tester,
    ) async {
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
        connectionTester: (server) async {
          expect(server.token, 'wrong-secret');
          return ConnectionResult.needsAuth(message: 'RPC 密钥错误');
        },
      );
      await openForm(tester, store, 'aria2');
      await tester.enterText(secretField('RPC 密钥（可选）'), 'wrong-secret');
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('需要登录: RPC 密钥错误'), findsOneWidget);
    });
  });
}
