import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/fake_repos.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/downloads/downloads_page.dart';

Server _server({
  String id = 'srv-qb',
  ServerType type = ServerType.qbittorrent,
  String host = 'https://sg.kass.qzz.io/qb/',
  String username = 'yang',
  String token = 'pw',
}) => Server(
  id: id,
  type: type,
  name: 'Test ${type.label}',
  host: host,
  port: 443,
  username: username,
  token: token,
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

/// aria2 JSON-RPC envelope: the client reads data['result'].
Response<dynamic> _ariaOk(RequestOptions options, dynamic result) =>
    _ok(options, {'jsonrpc': '2.0', 'id': 1, 'result': result});

Map<String, dynamic> _qbJson({
  String hash = 'abc123',
  String name = 'Ubuntu 24.04 LTS.iso',
  String state = 'downloading',
  double progress = 0.62,
  int dlspeed = 5242880,
  int size = 6442450944,
  int completed = 3995076198,
  int eta = 480,
}) => {
  'hash': hash,
  'name': name,
  'state': state,
  'progress': progress,
  'dlspeed': dlspeed,
  'size': size,
  'completed': completed,
  'eta': eta,
  'save_path': '/data/downloads',
};

Map<String, dynamic> _trJson({
  int id = 7,
  String name = 'Documentary.S01E01.mkv',
  int status = 4,
  double percentDone = 0.31,
  int rateDownload = 2097152,
  int totalSize = 2147483648,
  int downloadedEver = 665719930,
  int eta = 900,
}) => {
  'id': id,
  'name': name,
  'status': status,
  'percent_done': percentDone,
  'rate_download': rateDownload,
  'total_size': totalSize,
  'downloaded_ever': downloadedEver,
  'eta': eta,
  'download_dir': '/data/torrents',
  'hash_string': 'deadbeef',
};

Map<String, dynamic> _ariaJson({
  String gid = 'gid-1',
  String status = 'active',
  String totalLength = '524288000',
  String completedLength = '235929600',
  String downloadSpeed = '1048576',
  String path = '/data/aria2/Album - Midnight City.flac',
}) => {
  'gid': gid,
  'status': status,
  'totalLength': totalLength,
  'completedLength': completedLength,
  'downloadSpeed': downloadSpeed,
  'files': [
    {'path': path},
  ],
};

void main() {
  group('QbittorrentClient task parsing', () {
    test('torrents/info maps state, progress, eta, save path', () async {
      final seen = <String>[];
      final dio = _mockDio((options) {
        seen.add(options.path);
        if (options.path.contains('auth/login')) {
          return _ok(
            options,
            'Ok',
            headers: {
              'set-cookie': ['SID=abc123; path=/'],
            },
          );
        }
        return _ok(options, [
          _qbJson(),
          _qbJson(
            hash: 'def456',
            name: 'Paused.iso',
            state: 'pausedDL',
            progress: 0.1,
            dlspeed: 0,
            eta: -1,
          ),
          _qbJson(
            hash: 'ghi789',
            name: 'Done.iso',
            state: 'uploading',
            progress: 1,
            dlspeed: 0,
            completed: 100,
            size: 100,
            eta: 0,
          ),
          _qbJson(
            hash: 'jkl012',
            name: 'Broken.iso',
            state: 'error',
            progress: 0.05,
          ),
        ]);
      });
      final client = QbittorrentClient(_server(), dio: dio);
      final tasks = await client.torrentsInfo();
      expect(tasks, hasLength(4));
      expect(tasks[0].status, DownloadStatus.downloading);
      expect(tasks[0].progress, 0.62);
      expect(tasks[0].speedBytesPerSec, 5242880);
      expect(tasks[0].etaSeconds, 480);
      expect(tasks[0].savePath, '/data/downloads');
      expect(tasks[0].hash, 'abc123');
      expect(tasks[0].remainingText, '剩余 8分钟');
      expect(tasks[1].status, DownloadStatus.paused);
      expect(tasks[2].status, DownloadStatus.completed);
      expect(tasks[3].status, DownloadStatus.failed);
      // Login happened first, then info — and the subpath is preserved.
      expect(seen.first, contains('auth/login'));
      expect(seen, contains('api/v2/torrents/info'));
    });

    test('addMagnet posts multipart FormData with urls + savepath', () async {
      String? seenPath;
      FormData? seenForm;
      final dio = _mockDio((options) {
        seenPath = options.path;
        if (options.path.contains('auth/login')) {
          return _ok(
            options,
            'Ok.',
            headers: {
              'set-cookie': ['SID=s1; path=/'],
            },
          );
        }
        seenForm = options.data as FormData?;
        return _ok(options, 'Ok.');
      });
      final client = QbittorrentClient(_server(), dio: dio);
      expect(
        await client.addMagnet('magnet:?xt=urn:btih:abc', savePath: '/data/dl'),
        isTrue,
      );
      expect(seenPath, 'api/v2/torrents/add');
      final fields = Map.fromEntries(seenForm!.fields);
      expect(fields['urls'], 'magnet:?xt=urn:btih:abc');
      expect(fields['savepath'], '/data/dl');
    });
  });

  group('TransmissionClient task parsing', () {
    test('torrent_get maps status, eta, download dir, hash', () async {
      final dio = _mockDio((options) {
        final data = options.data as Map<String, dynamic>;
        if (data['method'] == 'torrent_get') {
          expect(
            (data['params'] as Map)['fields'],
            containsAll(['eta', 'download_dir', 'hash_string']),
          );
          return _ok(options, {
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'torrents': [
                _trJson(),
                _trJson(
                  id: 8,
                  name: 'Stopped.iso',
                  status: 0,
                  percentDone: 0.5,
                ),
                _trJson(
                  id: 9,
                  name: 'Seeding.iso',
                  status: 6,
                  percentDone: 1.0,
                ),
              ],
            },
          });
        }
        return _ok(options, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, dynamic>{},
        });
      });
      final client = TransmissionClient(
        _server(id: 'srv-tr', type: ServerType.transmission),
        dio: dio,
      );
      final tasks = await client.torrentGet();
      expect(tasks, hasLength(3));
      expect(tasks[0].status, DownloadStatus.downloading);
      expect(tasks[0].etaSeconds, 900);
      expect(tasks[0].savePath, '/data/torrents');
      expect(tasks[0].hash, 'deadbeef');
      expect(tasks[0].remainingText, '剩余 15分钟');
      expect(tasks[1].status, DownloadStatus.paused);
      expect(tasks[2].status, DownloadStatus.completed);
    });

    test('409 session-id retry resends the request', () async {
      var calls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, h) async {
            calls++;
            if (calls == 1) {
              h.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 409,
                    headers: Headers.fromMap({
                      'X-Transmission-Session-Id': ['sess-1'],
                    }),
                  ),
                ),
              );
              return;
            }
            h.resolve(
              _ok(options, {
                'jsonrpc': '2.0',
                'id': 1,
                'result': <String, dynamic>{},
              }),
            );
          },
        ),
      );
      final client = TransmissionClient(
        _server(id: 'srv-tr', type: ServerType.transmission),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(client.sessionId, 'sess-1');
      expect(calls, 2);
    });

    test('torrent_add passes download_dir and setLocation works', () async {
      Map<String, dynamic>? seenAdd;
      Map<String, dynamic>? seenSet;
      final dio = _mockDio((options) {
        final data = options.data as Map<String, dynamic>;
        if (data['method'] == 'torrent_add') {
          seenAdd = data['params'] as Map<String, dynamic>;
          return _ok(options, {
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'torrent_added': {'id': 42},
            },
          });
        }
        if (data['method'] == 'torrent_set_location') {
          seenSet = data['params'] as Map<String, dynamic>;
          return _ok(options, {
            'jsonrpc': '2.0',
            'id': 1,
            'result': <String, dynamic>{},
          });
        }
        return _ok(options, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, dynamic>{},
        });
      });
      final client = TransmissionClient(
        _server(id: 'srv-tr', type: ServerType.transmission),
        dio: dio,
      );
      expect(
        await client.torrentAdd(
          'magnet:?xt=urn:btih:abc',
          downloadDir: '/data/new',
        ),
        '42',
      );
      expect(seenAdd?['download_dir'], '/data/new');
      await client.setLocation([42], '/data/moved', move: true);
      expect(seenSet?['location'], '/data/moved');
      expect(seenSet?['move'], isTrue);
    });
  });

  group('Aria2Client task parsing', () {
    test('tellAll merges active, waiting and stopped', () async {
      final dio = _mockDio((options) {
        final data = options.data as Map<String, dynamic>;
        return switch (data['method']) {
          'aria2.tellActive' => _ariaOk(options, [_ariaJson()]),
          'aria2.tellWaiting' => _ariaOk(options, [
            _ariaJson(
              gid: 'gid-2',
              status: 'paused',
              totalLength: '100',
              completedLength: '40',
              downloadSpeed: '0',
              path: '/data/aria2/Paused.flac',
            ),
          ]),
          'aria2.tellStopped' => _ariaOk(options, [
            _ariaJson(
              gid: 'gid-3',
              status: 'complete',
              totalLength: '100',
              completedLength: '100',
              downloadSpeed: '0',
              path: '/data/aria2/Done.flac',
            ),
            _ariaJson(
              gid: 'gid-4',
              status: 'error',
              totalLength: '100',
              completedLength: '10',
              downloadSpeed: '0',
              path: '/data/aria2/Broken.flac',
            ),
          ]),
          _ => _ok(options, null),
        };
      });
      final client = Aria2Client(
        _server(id: 'srv-aria', type: ServerType.aria2),
        dio: dio,
      );
      final tasks = await client.tellAll();
      expect(tasks, hasLength(4));
      expect(tasks[0].name, 'Album - Midnight City.flac');
      expect(tasks[0].status, DownloadStatus.downloading);
      expect(tasks[0].progress, closeTo(0.45, 0.001));
      expect(tasks[0].savePath, '/data/aria2');
      expect(tasks[1].status, DownloadStatus.paused);
      expect(tasks[2].status, DownloadStatus.completed);
      expect(tasks[3].status, DownloadStatus.failed);
    });

    test('token: prefix is the first RPC param', () async {
      List<dynamic>? seenParams;
      final dio = _mockDio((options) {
        seenParams = (options.data as Map)['params'] as List<dynamic>;
        return _ariaOk(options, {'version': '1.37.0'});
      });
      final client = Aria2Client(
        _server(id: 'srv-aria', type: ServerType.aria2, token: 'secret'),
        dio: dio,
      );
      expect(await client.testConnection(), isTrue);
      expect(seenParams?.first, 'token:secret');
    });

    test('tellStatus returns one task by gid', () async {
      final dio = _mockDio((options) {
        return _ariaOk(options, _ariaJson(gid: 'gid-9'));
      });
      final client = Aria2Client(
        _server(id: 'srv-aria', type: ServerType.aria2),
        dio: dio,
      );
      final task = await client.tellStatus('gid-9');
      expect(task?.id, 'gid-9');
      expect(task?.status, DownloadStatus.downloading);
    });
  });

  group('RealDownloadRepository merge / dispatch / persistence', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> addServers() async {
      await store.add(_server(id: 'srv-qb'));
      await store.add(
        _server(
          id: 'srv-tr',
          type: ServerType.transmission,
          host: 'http://192.168.1.10:9091',
        ),
      );
      await store.add(
        _server(
          id: 'srv-aria',
          type: ServerType.aria2,
          host: 'http://192.168.1.10:6800',
        ),
      );
    }

    Dio qbDio({bool fail = false}) => _mockDio((options) {
      if (fail) {
        throw DioException(
          requestOptions: options,
          error: 'connection refused',
        );
      }
      if (options.path.contains('auth/login')) {
        return _ok(
          options,
          'Ok',
          headers: {
            'set-cookie': ['SID=s1; path=/'],
          },
        );
      }
      return _ok(options, [_qbJson()]);
    });

    Dio trDio({bool fail = false}) => _mockDio((options) {
      if (fail) {
        throw DioException(
          requestOptions: options,
          error: 'connection refused',
        );
      }
      final data = options.data as Map<String, dynamic>;
      if (data['method'] == 'torrent_get') {
        return _ok(options, {
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'torrents': [_trJson()],
          },
        });
      }
      return _ok(options, {
        'jsonrpc': '2.0',
        'id': 1,
        'result': <String, dynamic>{},
      });
    });

    Dio ariaDio({bool fail = false}) => _mockDio((options) {
      if (fail) {
        throw DioException(
          requestOptions: options,
          error: 'connection refused',
        );
      }
      final data = options.data as Map<String, dynamic>;
      return switch (data['method']) {
        'aria2.tellActive' => _ariaOk(options, [_ariaJson()]),
        'aria2.tellWaiting' => _ariaOk(options, []),
        'aria2.tellStopped' => _ariaOk(options, []),
        _ => _ariaOk(options, 'gid-new'),
      };
    });

    RealDownloadRepository makeRepo({
      bool qbFail = false,
      bool trFail = false,
      bool ariaFail = false,
    }) => RealDownloadRepository(
      store: store,
      database: db,
      qbFactory: (s) => QbittorrentClient(s, dio: qbDio(fail: qbFail)),
      transmissionFactory: (s) =>
          TransmissionClient(s, dio: trDio(fail: trFail)),
      ariaFactory: (s) => Aria2Client(s, dio: ariaDio(fail: ariaFail)),
    );

    test(
      'no credentials -> hasCredentials false, refresh falls back to fake',
      () async {
        final repo = makeRepo();
        expect(repo.hasCredentials, isFalse);
        await repo.refresh();
        expect(repo.tasks, FakeDownloadRepo.tasks());
      },
    );

    test('seeded qb with empty credentials is not usable', () async {
      await store.add(_server(id: 'seed-qbittorrent', username: '', token: ''));
      final repo = makeRepo();
      expect(repo.hasCredentials, isFalse);
      expect(repo.usableDownloaders, isEmpty);
    });

    test(
      'tasks merge across all three downloaders, downloading first',
      () async {
        await addServers();
        final repo = makeRepo();
        await repo.refresh();
        expect(repo.tasks, hasLength(3));
        // Sorted downloading-first, then by progress: qb 0.62, aria2 0.45,
        // Transmission 0.31.
        expect(repo.tasks.map((t) => t.source), [
          DownloadSource.qbittorrent,
          DownloadSource.aria2,
          DownloadSource.transmission,
        ]);
        expect(repo.errors, isEmpty);
        expect(repo.activeTasks, hasLength(3));
        expect(repo.totalSpeedBytesPerSec, 5242880 + 2097152 + 1048576);
      },
    );

    test(
      'one server down does not blank the list, error is recorded',
      () async {
        await addServers();
        final repo = makeRepo(qbFail: true);
        await repo.refresh();
        expect(repo.tasks.map((t) => t.source), [
          DownloadSource.aria2,
          DownloadSource.transmission,
        ]);
        expect(repo.errors.keys, contains('srv-qb'));
        expect(repo.errors['srv-qb'], contains('qBittorrent'));
      },
    );

    test(
      'add/pause/resume/delete dispatch to the right native client',
      () async {
        await addServers();
        final seen = <String>[];
        final repo = RealDownloadRepository(
          store: store,
          database: db,
          qbFactory: (s) => QbittorrentClient(
            s,
            dio: _mockDio((options) {
              seen.add('qb:${options.path}');
              if (options.path.contains('auth/login')) {
                return _ok(
                  options,
                  'Ok',
                  headers: {
                    'set-cookie': ['SID=s1; path=/'],
                  },
                );
              }
              if (options.path.contains('torrents/info')) {
                return _ok(options, [_qbJson()]);
              }
              return _ok(options, 'Ok.');
            }),
          ),
          transmissionFactory: (s) => TransmissionClient(
            s,
            dio: _mockDio((options) {
              final data = options.data as Map<String, dynamic>;
              seen.add('tr:${data['method']}');
              if (data['method'] == 'torrent_get') {
                return _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'result': {
                    'torrents': [_trJson()],
                  },
                });
              }
              return _ok(options, {
                'jsonrpc': '2.0',
                'id': 1,
                'result': {
                  'torrent_added': {'id': 7},
                },
              });
            }),
          ),
          ariaFactory: (s) => Aria2Client(
            s,
            dio: _mockDio((options) {
              final data = options.data as Map<String, dynamic>;
              seen.add('aria:${data['method']}');
              return switch (data['method']) {
                'aria2.tellActive' => _ariaOk(options, [_ariaJson()]),
                'aria2.tellWaiting' => _ariaOk(options, []),
                'aria2.tellStopped' => _ariaOk(options, []),
                _ => _ariaOk(options, 'gid-new'),
              };
            }),
          ),
        );
        await repo.refresh();
        expect(
          await repo.addTask(magnetOrUrl: 'magnet:?xt=urn:btih:abc'),
          isTrue,
        );
        expect(seen, contains('qb:api/v2/torrents/add'));

        final qbTask = repo.tasks.firstWhere(
          (t) => t.source == DownloadSource.qbittorrent,
        );
        await repo.pauseTask(qbTask);
        expect(seen, contains('qb:api/v2/torrents/pause'));
        await repo.resumeTask(qbTask);
        expect(seen, contains('qb:api/v2/torrents/resume'));
        await repo.deleteTask(qbTask);
        expect(seen, contains('qb:api/v2/torrents/delete'));

        final trTask = repo.tasks.firstWhere(
          (t) => t.source == DownloadSource.transmission,
        );
        await repo.pauseTask(trTask);
        expect(seen, contains('tr:torrent_stop'));
        await repo.retryTask(trTask);
        expect(seen, contains('tr:torrent_start'));
      },
    );

    test(
      'persisted tasks survive a refresh where the server omits them',
      () async {
        await addServers();
        var omitQb = false;
        final repo = RealDownloadRepository(
          store: store,
          database: db,
          qbFactory: (s) => QbittorrentClient(
            s,
            dio: _mockDio((options) {
              if (options.path.contains('auth/login')) {
                return _ok(
                  options,
                  'Ok',
                  headers: {
                    'set-cookie': ['SID=s1; path=/'],
                  },
                );
              }
              if (options.path.contains('torrents/delete')) {
                return _ok(options, 'Ok.');
              }
              return _ok(options, omitQb ? [] : [_qbJson()]);
            }),
          ),
          transmissionFactory: (s) =>
              TransmissionClient(s, dio: trDio(fail: true)),
          ariaFactory: (s) => Aria2Client(s, dio: ariaDio(fail: true)),
        );
        await repo.refresh();
        expect(repo.tasks.map((t) => t.name), contains('Ubuntu 24.04 LTS.iso'));
        omitQb = true;
        await repo.refresh();
        // The qB task is gone from the server but stays visible from Drift.
        final kept = repo.tasks.firstWhere(
          (t) => t.name == 'Ubuntu 24.04 LTS.iso',
        );
        expect(kept.status, DownloadStatus.downloading);
        expect(kept.progress, 0.62);
        // Deleting it in the app removes the persisted row too.
        expect(await repo.deleteTask(kept), isTrue);
        expect(
          repo.tasks.map((t) => t.name),
          isNot(contains('Ubuntu 24.04 LTS.iso')),
        );
      },
    );

    test('sortTasks puts downloading first, then by progress', () {
      final sorted = RealDownloadRepository.sortTasks([
        const DownloadTask(
          id: 'c',
          name: 'Done',
          source: DownloadSource.aria2,
          status: DownloadStatus.completed,
          progress: 1,
        ),
        const DownloadTask(
          id: 'a',
          name: 'Slow',
          source: DownloadSource.qbittorrent,
          status: DownloadStatus.downloading,
          progress: 0.1,
        ),
        const DownloadTask(
          id: 'b',
          name: 'Fast',
          source: DownloadSource.qbittorrent,
          status: DownloadStatus.downloading,
          progress: 0.9,
        ),
        const DownloadTask(
          id: 'd',
          name: 'Paused',
          source: DownloadSource.transmission,
          status: DownloadStatus.paused,
          progress: 0.5,
        ),
      ]);
      expect(sorted.map((t) => t.id), ['b', 'a', 'd', 'c']);
    });
  });

  group('DownloadsPage empty state', () {
    testWidgets('no downloader account shows the empty state', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async {
        await db.close();
      });
      final store = ServerStore(database: db);
      final repo = RealDownloadRepository(store: store, database: db);
      addTearDown(repo.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              repo: repo,
              store: store,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      // No pumpAndSettle: the page starts a 5s polling timer, which
      // keeps the fake clock busy forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      repo.stopPolling();
      expect(find.text('还没有下载器账号'), findsOneWidget);
      expect(find.text('去服务器页'), findsOneWidget);
      expect(find.text('没有下载任务'), findsNothing);
    });
  });
}
