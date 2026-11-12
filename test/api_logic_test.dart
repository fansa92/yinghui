import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/subsonic_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';

Server _server({
  ServerType type = ServerType.navidrome,
  String host = '192.168.1.10',
  int port = 4533,
  String username = 'yang',
  String token = 's3cret',
}) => Server(
  id: 'srv-1',
  type: type,
  name: 'Test',
  host: host,
  port: port,
  username: username,
  token: token,
);

void main() {
  group('Subsonic auth params', () {
    test('t is md5(password + salt), params carry u/s/c/v/f=json', () {
      const salt = 'abcdef123456';
      final params = SubsonicClient.buildAuthParams(
        'yang',
        's3cret',
        salt: salt,
      );
      expect(params['u'], 'yang');
      expect(params['s'], salt);
      expect(params['c'], 'YingHui');
      expect(params['v'], '1.16.1');
      expect(params['f'], 'json');
      // Independent recomputation, not the same code path in spirit:
      // md5 of the concatenated string.
      final expected = md5.convert('s3cretabcdef123456'.codeUnits).toString();
      expect(params['t'], expected);
    });

    test('different salts give different tokens', () {
      final a = SubsonicClient.buildAuthParams('u', 'p', salt: 'aaaa');
      final b = SubsonicClient.buildAuthParams('u', 'p', salt: 'bbbb');
      expect(a['t'], isNot(b['t']));
    });

    test('streamUrl embeds id and auth params', () {
      final client = SubsonicClient(_server());
      final url = client.streamUrl('song-42');
      expect(url, startsWith('http://192.168.1.10:4533/rest/stream?'));
      expect(url, contains('id=song-42'));
      expect(url, contains('u=yang'));
      expect(url, contains('f=json'));
    });
  });

  group('Transmission 409 session-id retry', () {
    test('a 409 with X-Transmission-Session-Id is retried once', () async {
      var calls = 0;
      String? secondCallSession;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls++;
              if (calls == 1) {
                // First call: fresh server, no session id yet.
                expect(options.headers['X-Transmission-Session-Id'], isNull);
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 409,
                      headers: Headers.fromMap({
                        'X-Transmission-Session-Id': ['sess-xyz'],
                      }),
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
              // Second call: the learned session id must be sent.
              secondCallSession =
                  options.headers['X-Transmission-Session-Id'] as String?;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'result': 'success',
                    'arguments': {'session-id': 'sess-xyz'},
                  },
                ),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, port: 9091),
        dio: dio,
      );
      final ok = await client.testConnection();
      expect(ok, isTrue);
      expect(calls, 2);
      expect(client.sessionId, 'sess-xyz');
      expect(secondCallSession, 'sess-xyz');
    });
  });

  group('aria2 token prefix', () {
    test('secret is sent first as token:<secret>', () {
      final client = Aria2Client(
        _server(type: ServerType.aria2, port: 6800, token: 'mysecret'),
      );
      final params = client.buildParams([
        [Uri.parse('magnet:?xt=urn:btih:abc').toString()],
      ]);
      expect(params.first, 'token:mysecret');
      expect(params.length, 2);
    });

    test('no secret means no token param', () {
      final client = Aria2Client(
        _server(type: ServerType.aria2, port: 6800, token: ''),
      );
      expect(client.buildParams(), isEmpty);
      expect(client.buildParams(['x']), ['x']);
    });

    test('rpc sends the token param in the JSON-RPC body', () async {
      Map<String, dynamic>? captured;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options.data as Map<String, dynamic>?;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'jsonrpc': '2.0',
                    'id': 1,
                    'result': {'version': '1.37.0'},
                  },
                ),
              );
            },
          ),
        );
      final client = Aria2Client(
        _server(type: ServerType.aria2, port: 6800, token: 'mysecret'),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(captured?['method'], 'aria2.getVersion');
      expect((captured?['params'] as List?)?.first, 'token:mysecret');
    });
  });

  group('Server JSON round-trip', () {
    test('toJson/fromJson preserves fields, token stays out of JSON', () {
      final server = _server();
      final json = server.toJson();
      expect(json.containsKey('token'), isFalse);
      final restored = Server.fromJson(json);
      expect(restored.id, server.id);
      expect(restored.type, ServerType.navidrome);
      expect(restored.name, server.name);
      expect(restored.host, server.host);
      expect(restored.port, server.port);
      expect(restored.username, server.username);
      expect(restored.isDefault, server.isDefault);
    });

    test('baseUrl: bare host gets http + port, full URL is kept', () {
      expect(_server().baseUrl, 'http://192.168.1.10:4533');
      expect(
        _server(host: 'https://music.example.com', port: 443).baseUrl,
        'https://music.example.com',
      );
      expect(
        _server(host: 'http://nas.local:4533', port: 9999).baseUrl,
        'http://nas.local:4533',
      );
    });
  });
  _mainP1();
}

void _mainP1() {
  group('qBittorrent subpath URL building (P1)', () {
    test('https://sg.kass.qzz.io/qb/ + api/v2/app/version keeps /qb/', () {
      final server = _server(
        type: ServerType.qbittorrent,
        host: 'https://sg.kass.qzz.io/qb/',
        port: 443,
        username: '',
        token: '',
      );
      final uri = QbittorrentClient.buildApiUri(server, 'api/v2/app/version');
      expect(uri.toString(), 'https://sg.kass.qzz.io/qb/api/v2/app/version');
    });

    test('no subpath: https://host/ + api/v2/... stays at root', () {
      final server = _server(
        type: ServerType.qbittorrent,
        host: 'https://qb.example.com/',
        port: 443,
        username: '',
        token: '',
      );
      expect(
        QbittorrentClient.buildApiUri(server, 'api/v2/app/version').toString(),
        'https://qb.example.com/api/v2/app/version',
      );
    });

    test('Dio request for app/version actually hits /qb/api/v2/...', () async {
      Uri? seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://sg.kass.qzz.io/qb/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options.uri;
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 403),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
      final client = QbittorrentClient(
        _server(
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          port: 443,
          username: '',
          token: '',
        ),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.needsAuth, isTrue);
      // The request must have gone to the subpath, not the site root.
      expect(seen.toString(), 'https://sg.kass.qzz.io/qb/api/v2/app/version');
    });

    test('qB 403 without credentials -> needsAuth, not unreachable', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 403),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
      final client = QbittorrentClient(
        _server(
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          port: 443,
          username: '',
          token: '',
        ),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.isUnreachable, isFalse);
    });
  });

  group('Subsonic probe parsing (P1)', () {
    test('live Navidrome probe: code 10 -> needsAuth, keeps serverVersion', () {
      final result = SubsonicClient.parseProbeResponse({
        'subsonic-response': {
          'status': 'failed',
          'version': '1.16.1',
          'type': 'navidrome',
          'serverVersion': '0.62.0 (1b46b977)',
          'openSubsonic': true,
          'error': {'code': 10, 'message': "missing parameter: 'u'"},
        },
      });
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.serverVersion, '0.62.0 (1b46b977)');
    });

    test('code 40 (wrong username/password) -> needsAuth', () {
      final result = SubsonicClient.parseProbeResponse({
        'subsonic-response': {
          'status': 'failed',
          'version': '1.16.1',
          'error': {'code': 40, 'message': 'wrong username or password'},
        },
      });
      expect(result.needsAuth, isTrue);
    });

    test('status ok -> ok', () {
      final result = SubsonicClient.parseProbeResponse({
        'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
      });
      expect(result.isOk, isTrue);
    });

    test('probe without credentials returns needsAuth via client', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, contains('ping.view'));
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'subsonic-response': {
                      'status': 'failed',
                      'version': '1.16.1',
                      'serverVersion': '0.62.0 (1b46b977)',
                      'error': {
                        'code': 10,
                        'message': "missing parameter: 'u'",
                      },
                    },
                  },
                ),
              );
            },
          ),
        );
      final client = SubsonicClient(
        _server(
          host: 'https://sg.kass.qzz.io/',
          port: 443,
          username: '',
          token: '',
        ),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.needsAuth, isTrue);
      expect(result.serverVersion, '0.62.0 (1b46b977)');
    });
  });

  group('Emby public-info parsing (P1)', () {
    test('live Emby public info -> needsAuth with name/version', () {
      final result = EmbyClient.parsePublicInfo({
        'ProductName': 'Emby Server',
        'ServerVersion': '4.8.10.0',
        'ServerName': 'paul_电报服',
        'ServerId': 'mediastation-go-001',
      });
      expect(result.status, ConnectionStatus.needsAuth);
      expect(result.serverVersion, '4.8.10.0');
      expect(result.serverName, 'paul_电报服');
    });

    test('not an Emby server -> unreachable', () {
      final result = EmbyClient.parsePublicInfo({'ProductName': 'Other'});
      expect(result.isUnreachable, isTrue);
    });

    test('client probe without token returns needsAuth', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'ProductName': 'Emby Server',
                    'ServerVersion': '4.8.10.0',
                    'ServerName': 'paul_电报服',
                  },
                ),
              );
            },
          ),
        );
      final client = EmbyClient(
        _server(
          type: ServerType.emby,
          host: 'https://cf.imetyou.top',
          port: 443,
          username: '',
          token: '',
        ),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.needsAuth, isTrue);
      expect(result.serverName, 'paul_电报服');
    });
  });

  group('Transmission / aria2 structured check (P1)', () {
    test('Transmission session-get ok -> ok', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'result': 'success', 'arguments': <String, dynamic>{}},
                ),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, port: 9091),
        dio: dio,
      );
      expect((await client.testConnectionResult()).isOk, isTrue);
    });

    test('aria2 getVersion ok -> ok with version', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'jsonrpc': '2.0',
                    'id': 1,
                    'result': {'version': '1.37.0'},
                  },
                ),
              );
            },
          ),
        );
      final client = Aria2Client(
        _server(type: ServerType.aria2, port: 6800, token: ''),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, '1.37.0');
    });
  });

  group('Drift server CRUD (P1, in-memory)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('insert, select, update default, delete', () async {
      await db
          .into(db.servers)
          .insert(
            ServersCompanion.insert(
              id: 'srv-1',
              type: 'emby',
              name: 'Emby',
              host: 'https://cf.imetyou.top',
              port: 443,
              username: const Value(''),
              isDefault: const Value(true),
            ),
          );
      await db
          .into(db.servers)
          .insert(
            ServersCompanion.insert(
              id: 'srv-2',
              type: 'navidrome',
              name: 'Navidrome',
              host: 'https://sg.kass.qzz.io/',
              port: 443,
            ),
          );
      var rows = await db.select(db.servers).get();
      expect(rows.length, 2);
      expect(rows.map((r) => r.name), containsAll(['Emby', 'Navidrome']));
      expect(rows.firstWhere((r) => r.id == 'srv-1').isDefault, isTrue);

      await (db.update(db.servers)..where((t) => t.id.equals('srv-2'))).write(
        const ServersCompanion(isDefault: Value(true)),
      );
      await (db.update(db.servers)..where((t) => t.id.equals('srv-1'))).write(
        const ServersCompanion(isDefault: Value(false)),
      );
      rows = await db.select(db.servers).get();
      expect(rows.firstWhere((r) => r.id == 'srv-2').isDefault, isTrue);

      await (db.delete(db.servers)..where((t) => t.id.equals('srv-1'))).go();
      rows = await db.select(db.servers).get();
      expect(rows.length, 1);
      expect(rows.single.id, 'srv-2');
    });

    test('placeholder tables exist and accept a row', () async {
      await db
          .into(db.playbackHistory)
          .insert(
            PlaybackHistoryCompanion.insert(
              id: 'h1',
              itemId: 'item-1',
              updatedAt: DateTime.utc(2026, 11, 12),
            ),
          );
      await db
          .into(db.favourites)
          .insert(FavouritesCompanion.insert(id: 'f1', itemId: 'item-1'));
      await db
          .into(db.downloadTasks)
          .insert(
            DownloadTasksCompanion.insert(id: 'd1', name: const Value('x.mkv')),
          );
      expect((await db.select(db.playbackHistory).get()).length, 1);
      expect((await db.select(db.favourites).get()).length, 1);
      expect((await db.select(db.downloadTasks).get()).length, 1);
    });
  });
}
