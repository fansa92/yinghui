import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/subsonic_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/home/home_page.dart';
import 'package:yinghui/features/player/player_service.dart';

Server _server({
  String id = 'srv-1',
  ServerType type = ServerType.emby,
  String host = 'https://cf.imetyou.top',
  int port = 443,
  String username = 'yang',
  String token = 'tok',
}) => Server(
  id: id,
  type: type,
  name: 'Test',
  host: host,
  port: port,
  username: username,
  token: token,
);

Response<dynamic> _ok(
  RequestOptions options,
  dynamic data, {
  Map<String, List<String>>? headers,
}) => Response(
  requestOptions: options,
  statusCode: 200,
  data: data,
  headers: headers == null ? Headers() : Headers.fromMap(headers),
);

/// In-memory secure storage for tests (same reason as in
/// server_version_test.dart: the real plugin hangs in widget tests).
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

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
      data.remove(key);
    } else {
      data[key] = value;
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
    data.remove(key);
  }
}

ServerStore _makeStore(
  AppDatabase db, {
  _FakeSecureStorage? storage,
  Future<ConnectionResult> Function(Server)? connectionTester,
  EmbyClient Function(Server server)? embyClientFactory,
}) => ServerStore(
  database: db,
  secureStorage: storage ?? _FakeSecureStorage(),
  connectionTester: connectionTester,
  embyClientFactory: embyClientFactory,
);

/// A Dio that rejects every request with the given HTTP status.
Dio _throwingDio({int statusCode = 401}) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            response: Response(requestOptions: options, statusCode: statusCode),
            type: DioExceptionType.badResponse,
          ),
        );
      },
    ),
  );

void main() {
  group('B1 — qBittorrent login accepts "Ok."', () {
    Dio loginDio(String body) => Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              _ok(
                options,
                body,
                headers: {
                  'set-cookie': ['SID=abc123; path=/'],
                },
              ),
            );
          },
        ),
      );

    test('"Ok." (3 bytes, the documented body) logs in', () async {
      final client = QbittorrentClient(
        _server(type: ServerType.qbittorrent, host: 'https://qb.example.com/'),
        dio: loginDio('Ok.'),
      );
      expect(await client.login(), isTrue);
    });

    test('bare "Ok" is still accepted defensively', () async {
      final client = QbittorrentClient(
        _server(type: ServerType.qbittorrent, host: 'https://qb.example.com/'),
        dio: loginDio('Ok'),
      );
      expect(await client.login(), isTrue);
    });

    test('"Fails." still throws bad credentials', () async {
      final client = QbittorrentClient(
        _server(type: ServerType.qbittorrent, host: 'https://qb.example.com/'),
        dio: loginDio('Fails.'),
      );
      expect(client.login(), throwsA(isA<ApiException>()));
    });
  });

  group('B3 — Emby token validation uses /Users/Me', () {
    Dio embyProbeDio({required bool meOk}) => Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('System/Info/Public')) {
              handler.resolve(
                _ok(options, {
                  'ProductName': 'Emby Server',
                  'ServerVersion': '4.8.10.0',
                  'ServerName': 'TestSrv',
                }),
              );
              return;
            }
            if (options.path.contains('Users/Me')) {
              if (meOk) {
                handler.resolve(_ok(options, {'Id': 'u1', 'Name': 'yang'}));
              } else {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 401,
                    ),
                    type: DioExceptionType.badResponse,
                  ),
                );
              }
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

    test(
      'bad token -> needsAuth, not ok (even though /System/Info is 200)',
      () async {
        final client = EmbyClient(_server(), dio: embyProbeDio(meOk: false));
        final result = await client.testConnectionResult();
        expect(result.needsAuth, isTrue);
        expect(result.isOk, isFalse);
      },
    );

    test('good token -> ok with version/name from the public probe', () async {
      final client = EmbyClient(_server(), dio: embyProbeDio(meOk: true));
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, '4.8.10.0');
      expect(result.serverName, 'TestSrv');
    });

    test('no token -> needsAuth without calling /Users/Me', () async {
      var meCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('System/Info/Public')) {
                handler.resolve(
                  _ok(options, {
                    'ProductName': 'Emby Server',
                    'ServerVersion': '4.8.10.0',
                    'ServerName': 'TestSrv',
                  }),
                );
                return;
              }
              if (options.path.contains('Users/Me')) meCalls++;
              handler.resolve(_ok(options, {'Id': 'u1'}));
            },
          ),
        );
      final client = EmbyClient(
        _server(username: '', token: ''),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.needsAuth, isTrue);
      expect(meCalls, 0);
    });
  });

  group('B4 — Emby session playback check-ins', () {
    late List<String> seenPaths;
    late List<Map<String, dynamic>> seenBodies;

    Dio embySessionDio() => Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('Users/Me')) {
              handler.resolve(_ok(options, {'Id': 'user-1'}));
              return;
            }
            if (options.path.contains('PlaybackInfo')) {
              handler.resolve(
                _ok(options, {
                  'PlaySessionId': 'sess-9',
                  'MediaSources': [
                    {
                      'Id': 'ms-1',
                      'Container': 'mkv',
                      'VideoCodec': 'hevc',
                      'AudioCodec': 'dts',
                      'SupportsDirectPlay': true,
                      'SupportsDirectStream': true,
                      'MediaStreams': [
                        {'Type': 'Video', 'Index': 0, 'Codec': 'hevc'},
                        {'Type': 'Audio', 'Index': 1, 'Codec': 'dts'},
                      ],
                    },
                  ],
                }),
              );
              return;
            }
            seenPaths.add('${options.method} ${options.path}');
            seenBodies.add((options.data as Map<String, dynamic>?) ?? {});
            handler.resolve(_ok(options, <String, dynamic>{}));
          },
        ),
      );

    setUp(() {
      seenPaths = [];
      seenBodies = [];
    });

    test(
      'progress posts to /Sessions/Playing/Progress with session fields',
      () async {
        final client = EmbyClient(_server(), dio: embySessionDio());
        await client.getPlaybackInfo('m1');
        await client.reportProgress('m1', const Duration(seconds: 90));
        expect(seenPaths, ['POST Sessions/Playing/Progress']);
        final body = seenBodies.single;
        expect(body['ItemId'], 'm1');
        expect(body['PositionTicks'], 900000000);
        expect(body['IsPaused'], isFalse);
        expect(body['EventName'], 'TimeUpdate');
        expect(body['MediaSourceId'], 'ms-1');
        expect(body['PlaySessionId'], 'sess-9');
        expect(body['CanSeek'], isTrue);
      },
    );

    test('paused progress reports EventName Pause', () async {
      final client = EmbyClient(_server(), dio: embySessionDio());
      await client.getPlaybackInfo('m1');
      await client.reportProgress(
        'm1',
        const Duration(seconds: 10),
        isPaused: true,
      );
      expect(seenBodies.single['EventName'], 'Pause');
      expect(seenBodies.single['IsPaused'], isTrue);
    });

    test('started / stopped post to their session routes', () async {
      final client = EmbyClient(_server(), dio: embySessionDio());
      await client.getPlaybackInfo('m1');
      await client.reportPlaybackStarted('m1', playMethod: 'Transcode');
      await client.reportPlaybackStopped('m1', const Duration(seconds: 30));
      expect(seenPaths, [
        'POST Sessions/Playing',
        'POST Sessions/Playing/Stopped',
      ]);
      expect(seenBodies[0]['PlayMethod'], 'Transcode');
      expect(seenBodies[0]['ItemId'], 'm1');
      expect(seenBodies[1]['PositionTicks'], 300000000);
    });

    test(
      'no PlaybackInfo yet -> session fields are omitted, not empty',
      () async {
        final client = EmbyClient(_server(), dio: embySessionDio());
        await client.reportProgress('m1', const Duration(seconds: 5));
        final body = seenBodies.single;
        expect(body.containsKey('MediaSourceId'), isFalse);
        expect(body.containsKey('PlaySessionId'), isFalse);
        expect(body['ItemId'], 'm1');
      },
    );
  });

  group('B2 — Emby username+password login is wired', () {
    Dio authDio({required bool ok}) => Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, contains('Users/AuthenticateByName'));
            if (ok) {
              handler.resolve(
                _ok(options, {
                  'AccessToken': 'access-1',
                  'User': {'Id': 'u1'},
                }),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response(requestOptions: options, statusCode: 401),
                  type: DioExceptionType.badResponse,
                ),
              );
            }
          },
        ),
      );

    test(
      'loginEmby exchanges the password for a token and persists it',
      () async {
        final db = AppDatabase.forExecutor(NativeDatabase.memory());
        addTearDown(() async => db.close());
        final storage = _FakeSecureStorage();
        final store = _makeStore(
          db,
          storage: storage,
          embyClientFactory: (s) => EmbyClient(s, dio: authDio(ok: true)),
        );
        final server = _server(username: 'yang', token: 'pw-123');
        await store.add(server);
        final authed = await store.loginEmby(server);
        expect(authed, isNotNull);
        expect(authed!.token, 'access-1');
        expect(store.servers.single.token, 'access-1');
        expect(storage.data['yinghui_token_${server.id}'], 'access-1');
        // A fresh store over the same storage reads the token back.
        final reloaded = _makeStore(db, storage: storage);
        await reloaded.load();
        expect(reloaded.servers.single.token, 'access-1');
      },
    );

    test('loginEmby failure returns null and keeps the old secret', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _makeStore(
        db,
        embyClientFactory: (s) => EmbyClient(s, dio: authDio(ok: false)),
      );
      final server = _server(username: 'yang', token: 'wrong-pw');
      await store.add(server);
      expect(await store.loginEmby(server), isNull);
      expect(store.servers.single.token, 'wrong-pw');
    });

    test('testConnection self-heals a password-based server', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _makeStore(
        db,
        embyClientFactory: (s) => EmbyClient(s, dio: authDio(ok: true)),
        connectionTester: (s) async {
          // The password fails as a token; the access token passes.
          if (s.token == 'access-1') {
            return ConnectionResult.ok(
              serverVersion: '4.8.10.0',
              serverName: 'EmbySrv',
            );
          }
          return ConnectionResult.needsAuth();
        },
      );
      await store.add(_server(username: 'yang', token: 'pw-123'));
      final result = await store.testConnection(store.servers.single);
      expect(result.isOk, isTrue);
      expect(result.serverVersion, '4.8.10.0');
      expect(store.servers.single.token, 'access-1');
    });

    test('pasted API key (no username) never triggers a login', () async {
      var authCalls = 0;
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _makeStore(
        db,
        embyClientFactory: (s) {
          authCalls++;
          return EmbyClient(s, dio: authDio(ok: true));
        },
        connectionTester: (_) async => ConnectionResult.ok(),
      );
      await store.add(_server(username: '', token: 'api-key-xyz'));
      final result = await store.testConnection(store.servers.single);
      expect(result.isOk, isTrue);
      expect(authCalls, 0);
      expect(store.servers.single.token, 'api-key-xyz');
    });
  });

  group('M1 — Emby subtitle URL needs a media source id', () {
    test('no media source id -> empty string, never the 404 route', () {
      final client = EmbyClient(_server());
      const track = SubtitleTrackInfo(index: 2, codec: 'srt', language: 'eng');
      expect(client.subtitleUrl('m1', track), '');
    });

    test('with media source id -> the documented route', () {
      final client = EmbyClient(_server());
      const track = SubtitleTrackInfo(
        index: 2,
        codec: 'srt',
        language: 'eng',
        mediaSourceId: 'ms-1',
      );
      final url = client.subtitleUrl('m1', track);
      expect(url, contains('/Videos/m1/ms-1/Subtitles/2/Stream.srt'));
    });

    test('a server DeliveryUrl still wins', () {
      final client = EmbyClient(_server());
      const track = SubtitleTrackInfo(
        index: 2,
        codec: 'srt',
        deliveryUrl: '/Videos/m1/ms-1/Subtitles/2/Stream.srt',
      );
      expect(
        client.subtitleUrl('m1', track),
        contains('/Videos/m1/ms-1/Subtitles/2/Stream.srt'),
      );
    });
  });

  group('M2 — aria2 tellStopped maps failed/removed, not completed', () {
    test('complete -> completed, error/removed -> failed', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'result': [
                    {
                      'gid': 'g1',
                      'status': 'complete',
                      'totalLength': '100',
                      'completedLength': '100',
                      'downloadSpeed': '0',
                      'dir': '/dl',
                      'files': [
                        {'path': '/dl/done.mkv'},
                      ],
                    },
                    {
                      'gid': 'g2',
                      'status': 'error',
                      'totalLength': '100',
                      'completedLength': '10',
                      'downloadSpeed': '0',
                      'dir': '/dl',
                      'files': [
                        {'path': '/dl/broken.mkv'},
                      ],
                    },
                    {
                      'gid': 'g3',
                      'status': 'removed',
                      'totalLength': '100',
                      'completedLength': '0',
                      'downloadSpeed': '0',
                      'dir': '/dl',
                      'files': [
                        {'path': '/dl/gone.mkv'},
                      ],
                    },
                  ],
                }),
              );
            },
          ),
        );
      final client = Aria2Client(
        _server(type: ServerType.aria2, host: 'http://nas:6800', token: ''),
        dio: dio,
      );
      final tasks = await client.tellStopped();
      expect(tasks.map((t) => t.status), [
        DownloadStatus.completed,
        DownloadStatus.failed,
        DownloadStatus.failed,
      ]);
    });
  });

  group('M3 — qBittorrent state mapping + unknown ETA', () {
    test('forcedDL/forcedUP/stoppedUP map, eta 8640000 is unknown', () async {
      Map<String, dynamic> qbJson({
        required String hash,
        required String state,
        int eta = -1,
      }) => {
        'hash': hash,
        'name': '$hash.iso',
        'state': state,
        'progress': 0.5,
        'dlspeed': 0,
        'size': 100,
        'completed': 50,
        'eta': eta,
        'save_path': '/dl',
      };
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok.',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              handler.resolve(
                _ok(options, [
                  qbJson(hash: 'a', state: 'forcedDL', eta: 8640000),
                  qbJson(hash: 'b', state: 'forcedUP'),
                  qbJson(hash: 'c', state: 'stoppedUP'),
                ]),
              );
            },
          ),
        );
      final client = QbittorrentClient(
        _server(type: ServerType.qbittorrent, host: 'https://qb.example.com/'),
        dio: dio,
      );
      final tasks = await client.torrentsInfo();
      expect(tasks[0].status, DownloadStatus.downloading);
      expect(tasks[0].etaSeconds, -1);
      expect(tasks[1].status, DownloadStatus.completed);
      expect(tasks[2].status, DownloadStatus.paused);
    });
  });

  group('M6 — qBittorrent torrents/add is multipart/form-data', () {
    test('addMagnet sends FormData with urls + savepath', () async {
      FormData? seenForm;
      String? seenContentType;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok.',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              seenForm = options.data as FormData?;
              seenContentType = options.contentType;
              handler.resolve(_ok(options, 'Ok.'));
            },
          ),
        );
      final client = QbittorrentClient(
        _server(type: ServerType.qbittorrent, host: 'https://qb.example.com/'),
        dio: dio,
      );
      expect(
        await client.addMagnet('magnet:?xt=urn:btih:abc', savePath: '/data/dl'),
        isTrue,
      );
      expect(seenForm, isNotNull);
      final fields = Map.fromEntries(seenForm!.fields);
      expect(fields['urls'], 'magnet:?xt=urn:btih:abc');
      expect(fields['savepath'], '/data/dl');
      expect(seenContentType, contains('multipart/form-data'));
    });
  });

  group('M7 — Emby transcode URL carries MediaSourceId', () {
    test('transcodeUrl includes the source id when given', () {
      final client = EmbyClient(_server());
      final url = client.transcodeUrl('m1', mediaSourceId: 'ms-9');
      expect(url, contains('MediaSourceId=ms-9'));
      expect(url, contains('/Videos/m1/master.m3u8'));
    });

    test('transcodeUrl omits it when unknown', () {
      final client = EmbyClient(_server());
      expect(client.transcodeUrl('m1'), isNot(contains('MediaSourceId')));
    });

    test('decidePlayback pins the transcode to the chosen source', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await store.add(_server(id: 'srv-emby'));
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(_ok(options, {'Id': 'user-1'}));
                return;
              }
              handler.resolve(
                _ok(options, {
                  'MediaSources': [
                    {
                      'Id': 'ms-9',
                      'Container': 'mkv',
                      'VideoCodec': 'hevc',
                      'AudioCodec': 'dts',
                      'SupportsDirectPlay': true,
                      'SupportsDirectStream': true,
                      'MediaStreams': [
                        {'Type': 'Video', 'Index': 0, 'Codec': 'hevc'},
                        {'Type': 'Audio', 'Index': 1, 'Codec': 'dts'},
                      ],
                    },
                  ],
                }),
              );
            },
          ),
        );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: dio),
      );
      const item = VideoItem(
        id: 'm1',
        title: 'The Last Horizon',
        serverId: 'srv-emby',
      );
      final result = await repo.decidePlayback(item);
      expect(result.decision.isDirect, isFalse);
      expect(result.url, contains('MediaSourceId=ms-9'));
    });
  });

  group('M4/M5 — Transmission speaks JSON-RPC 2.0 (snake_case)', () {
    test('rpc sends the JSON-RPC 2.0 envelope, parses result', () async {
      Map<String, dynamic>? seenBody;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seenBody = options.data as Map<String, dynamic>?;
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'result': {'version': '4.0.5'},
                }),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(seenBody?['jsonrpc'], '2.0');
      expect(seenBody?['method'], 'session_get');
      expect(seenBody?['params'], isA<Map>());
      expect(seenBody?.containsKey('arguments'), isFalse);
    });

    test('torrent_get uses snake_case fields; status 3 is queued', () async {
      Map<String, dynamic>? seenParams;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final body = options.data as Map<String, dynamic>;
              seenParams = body['params'] as Map<String, dynamic>?;
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 2,
                  'result': {
                    'torrents': [
                      {
                        'id': 7,
                        'name': 'Doc.mkv',
                        'status': 4,
                        'percent_done': 0.5,
                        'rate_download': 1000,
                        'total_size': 2000,
                        'downloaded_ever': 1000,
                        'eta': 60,
                        'download_dir': '/dl',
                        'hash_string': 'deadbeef',
                      },
                      {
                        'id': 8,
                        'name': 'Waiting.iso',
                        'status': 3,
                        'percent_done': 0.0,
                        'rate_download': 0,
                        'total_size': 100,
                        'downloaded_ever': 0,
                        'eta': -1,
                        'download_dir': '/dl',
                        'hash_string': 'cafef00d',
                      },
                      {
                        'id': 9,
                        'name': 'Checking.iso',
                        'status': 2,
                        'percent_done': 0.0,
                        'rate_download': 0,
                        'total_size': 100,
                        'downloaded_ever': 0,
                        'eta': -1,
                        'download_dir': '/dl',
                        'hash_string': 'babe',
                      },
                    ],
                  },
                }),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      final tasks = await client.torrentGet();
      expect(
        (seenParams?['fields'] as List?)?.cast<String>(),
        containsAll([
          'percent_done',
          'total_size',
          'download_dir',
          'hash_string',
        ]),
      );
      expect(tasks, hasLength(3));
      expect(tasks[0].status, DownloadStatus.downloading);
      expect(tasks[0].progress, 0.5);
      expect(tasks[0].savePath, '/dl');
      expect(tasks[0].hash, 'deadbeef');
      // 3 = download-wait is queued, not downloading; 2 = verifying
      // reads as queued too (no checking state in the unified model).
      expect(tasks[1].status, DownloadStatus.queued);
      expect(tasks[2].status, DownloadStatus.queued);
    });

    test('a JSON-RPC error object throws ApiException', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'error': {'code': -32602, 'message': 'invalid params'},
                }),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      expect(client.testConnection(), throwsA(isA<ApiException>()));
    });

    test('409 session-id retry still works under JSON-RPC 2.0', () async {
      var calls = 0;
      String? secondSession;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls++;
              if (calls == 1) {
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
              secondSession =
                  options.headers['X-Transmission-Session-Id'] as String?;
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 2,
                  'result': {'version': '4.0.5'},
                }),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(calls, 2);
      expect(client.sessionId, 'sess-xyz');
      expect(secondSession, 'sess-xyz');
    });

    test('add/remove/set-location use snake_case methods and params', () async {
      final seen = <Map<String, dynamic>>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final body = options.data as Map<String, dynamic>;
              seen.add(body);
              final result = body['method'] == 'torrent_add'
                  ? {
                      'torrent_added': {'id': 42},
                    }
                  : <String, dynamic>{};
              handler.resolve(
                _ok(options, {'jsonrpc': '2.0', 'id': 1, 'result': result}),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      expect(
        await client.torrentAdd(
          'magnet:?xt=urn:btih:abc',
          downloadDir: '/data/new',
        ),
        '42',
      );
      await client.remove([42], deleteLocalData: true);
      await client.setLocation([42], '/data/moved', move: true);
      expect(seen[0]['method'], 'torrent_add');
      expect(seen[0]['params']['download_dir'], '/data/new');
      expect(seen[1]['method'], 'torrent_remove');
      expect(seen[1]['params']['delete_local_data'], isTrue);
      expect(seen[2]['method'], 'torrent_set_location');
      expect(seen[2]['params']['location'], '/data/moved');
      expect(seen[2]['params']['move'], isTrue);
    });
  });

  group('X-1 — all-servers-fail surfaces an error, one failure does not', () {
    Map<String, dynamic> albumJson({
      String id = 'a1',
      String name = 'Midnight City',
      String artist = 'Neon Lights',
    }) => {
      'id': id,
      'name': name,
      'artist': artist,
      'year': 2024,
      'songCount': 12,
    };

    Dio subsonicDio(Map<String, dynamic> Function(RequestOptions) respond) =>
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'subsonic-response': respond(options)},
                  ),
                );
              },
            ),
          );

    Map<String, dynamic> movieJson({String id = 'm1'}) => {
      'Id': id,
      'Name': 'The Last Horizon',
      'ProductionYear': 2024,
      'Type': 'Movie',
      'RunTimeTicks': 76200000000,
      'UserData': {
        'PlayedPercentage': 62,
        'PlaybackPositionTicks': 47244000000,
      },
    };

    Dio embyDio(Map<String, dynamic> Function(RequestOptions) respond) =>
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                handler.resolve(_ok(options, respond(options)));
              },
            ),
          );

    test('music: every Navidrome server 401s -> albums() throws', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await store.add(
        _server(
          id: 'srv-a',
          type: ServerType.navidrome,
          host: 'https://a.example.com',
        ),
      );
      await store.add(
        _server(
          id: 'srv-b',
          type: ServerType.navidrome,
          host: 'https://b.example.com',
        ),
      );
      final repo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) => SubsonicClient(s, dio: _throwingDio()),
      );
      expect(repo.albums(), throwsA(isA<ApiException>()));
    });

    test('music: one server down, one up -> merged list still loads', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await store.add(
        _server(
          id: 'srv-a',
          type: ServerType.navidrome,
          host: 'https://a.example.com',
        ),
      );
      await store.add(
        _server(
          id: 'srv-b',
          type: ServerType.navidrome,
          host: 'https://b.example.com',
        ),
      );
      final repo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) => SubsonicClient(
          s,
          dio: s.id == 'srv-b'
              ? _throwingDio()
              : subsonicDio(
                  (_) => {
                    'status': 'ok',
                    'albumList2': {
                      'album': [albumJson()],
                    },
                  },
                ),
        ),
      );
      final albums = await repo.albums();
      expect(albums.map((a) => a.title), ['Midnight City']);
    });

    test(
      'video: every Emby server 401s -> continueWatching() throws',
      () async {
        final db = AppDatabase.forExecutor(NativeDatabase.memory());
        addTearDown(() async => db.close());
        final store = ServerStore(
          database: db,
          secureStorage: _FakeSecureStorage(),
        );
        await store.add(_server(id: 'srv-a'));
        await store.add(
          _server(id: 'srv-b', host: 'https://emby2.example.com'),
        );
        final repo = RealVideoRepository(
          store: store,
          database: db,
          clientFactory: (s) => EmbyClient(s, dio: _throwingDio()),
        );
        expect(repo.continueWatching(), throwsA(isA<ApiException>()));
      },
    );

    test('video: one server down, one up -> merged list still loads', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await store.add(_server(id: 'srv-a'));
      await store.add(_server(id: 'srv-b', host: 'https://emby2.example.com'));
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(
          s,
          dio: s.id == 'srv-b'
              ? _throwingDio()
              : embyDio((options) {
                  if (options.path.contains('Users/Me')) {
                    return {'Id': 'user-1'};
                  }
                  return {
                    'Items': [movieJson()],
                  };
                }),
        ),
      );
      final watching = await repo.continueWatching();
      expect(watching.map((v) => v.title), ['The Last Horizon']);
    });
  });

  group('X-1 — Home shows per-section errors inline', () {
    testWidgets('both sections fail -> two error cards with retry', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(
        database: db,
        secureStorage: _FakeSecureStorage(),
      );
      await store.add(
        _server(
          id: 'srv-n',
          type: ServerType.navidrome,
          host: 'https://nav.example.com',
        ),
      );
      await store.add(_server(id: 'srv-e'));
      final musicRepo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) => SubsonicClient(s, dio: _throwingDio()),
      );
      final videoRepo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: _throwingDio()),
      );
      final downloadRepo = RealDownloadRepository(store: store, database: db);
      addTearDown(downloadRepo.dispose);
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('视频加载失败'), findsOneWidget);
      expect(find.text('音乐加载失败'), findsOneWidget);
      expect(find.text('重试'), findsNWidgets(2));
    });
  });

  group('ConnectionResult messages are Chinese', () {
    test('defaults', () {
      expect(ConnectionResult.ok().message, '已连接');
      expect(ConnectionResult.needsAuth().message, '服务器可达，需要登录');
      expect(ConnectionResult.unreachable().message, '无法连接');
    });

    test('Emby public-info parse', () {
      expect(
        EmbyClient.parsePublicInfo({'ProductName': 'Other'}).message,
        '不是 Emby 服务器',
      );
    });

    test('qB 403 without credentials', () async {
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
          host: 'https://qb.example.com/',
          username: '',
          token: '',
        ),
        dio: dio,
      );
      final result = await client.testConnectionResult();
      expect(result.needsAuth, isTrue);
      expect(result.message, '服务器可达，需要登录（HTTP 403）');
    });
  });
}

/// A PlayerBackend that does nothing (HomePage never plays in tests).
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
