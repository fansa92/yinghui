import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/servers/servers_page.dart';

Server _server({
  String id = 'srv-1',
  ServerType type = ServerType.emby,
  String name = 'Emby',
  String host = 'https://cf.imetyou.top',
  String? serverVersion,
  String? serverName,
}) => Server(
  id: id,
  type: type,
  name: name,
  host: host,
  port: 443,
  serverVersion: serverVersion,
  serverName: serverName,
);

/// In-memory secure storage for tests. The real plugin throws
/// MissingPluginException in unit tests and its write hangs forever in
/// widget tests on this machine, so a store can never be awaited
/// without this. The store under test accepts it via its constructor.
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

ServerStore _store(
  AppDatabase db, {
  Future<ConnectionResult> Function(Server)? connectionTester,
}) => ServerStore(
  database: db,
  secureStorage: _FakeSecureStorage(),
  connectionTester: connectionTester,
);

Dio _mockTransmissionDio(Map<String, dynamic> arguments) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'result': 'success', 'arguments': arguments},
            ),
          );
        },
      ),
    );
  return dio;
}

void main() {
  group('Drift migration v2 -> v3', () {
    test('keeps existing servers and other tables, adds version columns', () async {
      // Hand-built schema v2 (what schemaVersion 2 created), made with
      // the raw sqlite3 binding in a temp file: the servers table
      // without the v3 columns, plus the other tables. Opening it with
      // AppDatabase (schemaVersion 3) must run the v2 -> v3 migration.
      final dir = await Directory.systemTemp.createTemp('yinghui-v2-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/yinghui.db');
      final raw = sqlite3.open(file.path);
      raw.execute(
        'CREATE TABLE servers ('
        'id TEXT NOT NULL PRIMARY KEY, '
        'type TEXT NOT NULL, '
        'name TEXT NOT NULL, '
        'host TEXT NOT NULL, '
        'port INTEGER NOT NULL, '
        "username TEXT NOT NULL DEFAULT '', "
        'is_default INTEGER NOT NULL DEFAULT 0)',
      );
      raw.execute(
        'CREATE TABLE playback_history ('
        'id TEXT NOT NULL PRIMARY KEY, '
        'item_id TEXT NOT NULL, '
        "title TEXT NOT NULL DEFAULT '', "
        "server_id TEXT NOT NULL DEFAULT '', "
        'position_seconds INTEGER NOT NULL DEFAULT 0, '
        'updated_at INTEGER NOT NULL)',
      );
      raw.execute(
        'CREATE TABLE favourites ('
        'id TEXT NOT NULL PRIMARY KEY, '
        'item_id TEXT NOT NULL, '
        "kind TEXT NOT NULL DEFAULT '', "
        "title TEXT NOT NULL DEFAULT '', "
        "server_id TEXT NOT NULL DEFAULT '')",
      );
      raw.execute(
        'CREATE TABLE download_tasks ('
        'id TEXT NOT NULL PRIMARY KEY, '
        "name TEXT NOT NULL DEFAULT '', "
        "source TEXT NOT NULL DEFAULT '', "
        "status TEXT NOT NULL DEFAULT '', "
        'progress REAL NOT NULL DEFAULT 0.0, '
        "server_id TEXT NOT NULL DEFAULT '', "
        "source_input TEXT NOT NULL DEFAULT '')",
      );
      raw.execute(
        "INSERT INTO servers (id, type, name, host, port, username, "
        "is_default) VALUES ('srv-1', 'emby', 'Emby', "
        "'https://cf.imetyou.top', 443, '', 1)",
      );
      raw.execute(
        "INSERT INTO download_tasks (id, name, source, status, progress, "
        "server_id, source_input) VALUES ('task-1', 'File.iso', "
        "'qbittorrent', 'downloading', 0.5, 'srv-1', 'magnet:?xt=urn:btih:x')",
      );
      raw.execute('PRAGMA user_version = 2');
      raw.close();

      final db = AppDatabase.forExecutor(NativeDatabase(file));
      addTearDown(db.close);

      // First access runs the v2 -> v3 migration.
      final servers = await db.select(db.servers).get();
      expect(servers, hasLength(1));
      expect(servers.first.id, 'srv-1');
      expect(servers.first.name, 'Emby');
      expect(servers.first.serverVersion, isNull);
      expect(servers.first.serverName, isNull);

      // The other table survives the migration untouched.
      final tasks = await db.select(db.downloadTasks).get();
      expect(tasks, hasLength(1));
      expect(tasks.first.sourceInput, 'magnet:?xt=urn:btih:x');

      // The new columns exist (drift snake_cases them).
      final columns = await db.customSelect('PRAGMA table_info(servers)').get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      expect(names, containsAll(['server_version', 'server_name']));

      // The migrated database is usable: a probe version round-trips.
      final store = _store(db);
      await store.load();
      expect(store.servers, hasLength(1));
      expect(store.servers.first.serverVersion, isNull);
    });
  });

  group('ServerStore persists probe versions', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('testConnection saves version+name, reload sees them', () async {
      final store = _store(
        db,
        connectionTester: (_) async => ConnectionResult.ok(
          serverVersion: '4.8.10.0',
          serverName: 'paul_电报服',
        ),
      );
      await store.add(_server());
      final result = await store.testConnection(store.servers.first);
      expect(result.isOk, isTrue);
      expect(store.servers.first.serverVersion, '4.8.10.0');
      expect(store.servers.first.serverName, 'paul_电报服');

      // Survives a restart: a fresh store on the same database.
      final reloaded = _store(db);
      await reloaded.load();
      expect(reloaded.servers, hasLength(1));
      expect(reloaded.servers.first.serverVersion, '4.8.10.0');
      expect(reloaded.servers.first.serverName, 'paul_电报服');
    });

    test('failed test keeps the previously known version', () async {
      var next = ConnectionResult.ok(
        serverVersion: '4.8.10.0',
        serverName: 'paul_电报服',
      );
      final store = _store(db, connectionTester: (_) async => next);
      await store.add(_server());
      await store.testConnection(store.servers.first);
      expect(store.servers.first.serverVersion, '4.8.10.0');

      next = ConnectionResult.unreachable(message: 'timeout');
      final failed = await store.testConnection(store.servers.first);
      expect(failed.isUnreachable, isTrue);
      expect(store.servers.first.serverVersion, '4.8.10.0');
      expect(store.servers.first.serverName, 'paul_电报服');
    });

    test('ok test without a version keeps the old version', () async {
      var next = ConnectionResult.ok(
        serverVersion: '1.37.0',
        serverName: 'aria2',
      );
      final store = _store(db, connectionTester: (_) async => next);
      await store.add(
        _server(type: ServerType.aria2, name: 'aria2', host: '127.0.0.1'),
      );
      await store.testConnection(store.servers.first);
      expect(store.servers.first.serverVersion, '1.37.0');

      // A probe that carries no version (e.g. Transmission before the
      // fix, or a needsAuth result) must not blank it.
      next = ConnectionResult.ok();
      await store.testConnection(store.servers.first);
      expect(store.servers.first.serverVersion, '1.37.0');
      expect(store.servers.first.serverName, 'aria2');
    });

    test('probe for an unknown server id is ignored', () async {
      final store = _store(
        db,
        connectionTester: (_) async =>
            ConnectionResult.ok(serverVersion: '9.9.9'),
      );
      await store.add(_server());
      // A form candidate that was never saved has no row in the store.
      await store.testConnection(_server(id: 'not-saved-yet'));
      expect(store.servers.first.serverVersion, isNull);
    });

    test('update() keeps the stored version (form save path)', () async {
      final store = _store(db);
      await store.add(
        _server(serverVersion: '4.8.10.0', serverName: 'paul_电报服'),
      );
      // The edit form rebuilds the server from its text fields, which
      // do not carry the probe data — saving must not wipe it.
      await store.update(_server(name: 'Emby Renamed'));
      expect(store.servers.first.name, 'Emby Renamed');
      expect(store.servers.first.serverVersion, '4.8.10.0');
      expect(store.servers.first.serverName, 'paul_电报服');

      final reloaded = _store(db);
      await reloaded.load();
      expect(reloaded.servers.first.serverVersion, '4.8.10.0');
    });

    test('Server JSON round-trips the version fields', () {
      final server = _server(serverVersion: '0.62.0', serverName: 'navidrome');
      final restored = Server.fromJson(server.toJson());
      expect(restored.serverVersion, '0.62.0');
      expect(restored.serverName, 'navidrome');
      // Legacy JSON without the fields still parses.
      final legacy = Server.fromJson({
        'id': 'srv-1',
        'type': 'emby',
        'name': 'Emby',
        'host': 'https://cf.imetyou.top',
        'port': 443,
      });
      expect(legacy.serverVersion, isNull);
      expect(legacy.serverName, isNull);
    });
  });

  group('ServersPage shows stored versions', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    testWidgets('row shows the stored version without any test tap', (
      tester,
    ) async {
      final store = _store(db);
      await store.add(
        _server(serverVersion: '4.8.10.0', serverName: 'paul_电报服'),
      );
      await tester.pumpWidget(MaterialApp(home: ServersPage(store: store)));
      await tester.pump();
      expect(find.textContaining('v4.8.10.0'), findsOneWidget);
      expect(find.textContaining('paul_电报服'), findsOneWidget);
    });

    testWidgets('never-tested server shows nothing version-like', (
      tester,
    ) async {
      final store = _store(db);
      await store.add(_server());
      await tester.pumpWidget(MaterialApp(home: ServersPage(store: store)));
      await tester.pump();
      expect(find.text('Emby · https://cf.imetyou.top'), findsOneWidget);
      expect(find.textContaining(RegExp(r'v\d')), findsNothing);
    });
  });

  group('Transmission version parsing', () {
    Server transmissionServer() => Server(
      id: 'srv-tr',
      type: ServerType.transmission,
      name: 'Transmission',
      host: '192.168.1.10',
      port: 9091,
    );

    test('session-get with version -> ok with version', () async {
      final client = TransmissionClient(
        transmissionServer(),
        dio: _mockTransmissionDio({'version': '4.0.5'}),
      );
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, '4.0.5');
    });

    test('session-get without version -> ok without version', () async {
      final client = TransmissionClient(
        transmissionServer(),
        dio: _mockTransmissionDio({}),
      );
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, isNull);
    });

    test('session-get with non-string version -> ok without version', () async {
      final client = TransmissionClient(
        transmissionServer(),
        dio: _mockTransmissionDio({'version': 405}),
      );
      final result = await client.testConnectionResult();
      expect(result.isOk, isTrue);
      expect(result.serverVersion, isNull);
    });
  });
}
