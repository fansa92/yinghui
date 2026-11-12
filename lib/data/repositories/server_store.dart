import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../api/api_client_factory.dart';
import '../db/app_database.dart';

/// Holds the server list in memory and persists it in two tiers:
///
/// * non-secret fields (id, type, name, host, port, username, isDefault,
///   plus the last-known probe facts `serverVersion` / `serverName`)
///   -> Drift (SQLite) `servers` table;
/// * the secret per server ([Server.token]) -> flutter_secure_storage,
///   key `yinghui_token_<server id>`.
///
/// Migration (P0 -> P1): on first load, if Drift is empty but the old
/// shared_preferences key `yinghui_servers` exists, those servers are
/// imported once into Drift and the old key is cleared.
///
/// Seeding: on first run (Drift empty, no legacy data, not seeded before)
/// the three user-provided servers are seeded with NO credentials — the
/// user fills username/password/token in the app. Seeded once, guarded
/// by shared_preferences `yinghui_seeded_v1`, so a user-deleted server
/// is never re-seeded.
class ServerStore extends ChangeNotifier {
  ServerStore({
    FlutterSecureStorage? secureStorage,
    AppDatabase? database,
    Future<ConnectionResult> Function(Server)? connectionTester,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _db = database ?? AppDatabase(),
       _connectionTester = connectionTester ?? ApiClientFactory.testConnection;

  static const String _legacyPrefsKey = 'yinghui_servers';
  static const String _seededPrefsKey = 'yinghui_seeded_v1';

  final FlutterSecureStorage _secureStorage;
  final AppDatabase _db;

  /// Runs the native client's structured connectivity check. Injected
  /// for tests (a fake can return canned results without a network);
  /// production uses [ApiClientFactory.testConnection].
  final Future<ConnectionResult> Function(Server) _connectionTester;
  final List<Server> _servers = [];

  /// The Drift database, shared with PlaybackStore (P2) so servers,
  /// favourites and playback history live in one database.
  AppDatabase get database => _db;

  List<Server> get servers => List.unmodifiable(_servers);

  Server? get defaultServer {
    for (final s in _servers) {
      if (s.isDefault) return s;
    }
    return _servers.isEmpty ? null : _servers.first;
  }

  static final List<Server> seedServers = [
    Server(
      id: 'seed-navidrome',
      type: ServerType.navidrome,
      name: 'Navidrome',
      host: 'https://sg.kass.qzz.io/',
      port: 443,
    ),
    Server(
      id: 'seed-qbittorrent',
      type: ServerType.qbittorrent,
      name: 'qBittorrent',
      host: 'https://sg.kass.qzz.io/qb/',
      port: 443,
    ),
    Server(
      id: 'seed-emby',
      type: ServerType.emby,
      name: 'Emby',
      host: 'https://cf.imetyou.top',
      port: 443,
      isDefault: true,
    ),
  ];

  Future<void> load() async {
    try {
      final rows = await _db.select(_db.servers).get();
      _servers.clear();
      for (final row in rows) {
        // A token read must never drop the whole list: if secure
        // storage fails for one server, that server loads with an
        // empty token (the user re-enters it) and the rest still load.
        String token = '';
        try {
          token =
              await _secureStorage.read(key: 'yinghui_token_${row.id}') ?? '';
        } catch (e) {
          debugPrint('ServerStore token read failed for ${row.id}: $e');
        }
        _servers.add(_serverFromRow(row, token));
      }
      if (_servers.isEmpty) {
        await _migrateLegacyOrSeed();
      }
    } catch (e) {
      // Drift unavailable (e.g. widget test without plugins): the app
      // still starts in fake mode with no servers.
      debugPrint('ServerStore.load failed: $e');
      _servers.clear();
    }
    notifyListeners();
  }

  Future<void> _migrateLegacyOrSeed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyPrefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final json in list) {
          final server = Server.fromJson(json);
          final token = await _secureStorage.read(
            key: 'yinghui_token_${server.id}',
          );
          _servers.add(server.copyWith(token: token ?? ''));
        }
        await _save();
        await prefs.remove(_legacyPrefsKey);
        await prefs.setBool(_seededPrefsKey, true);
        return;
      } catch (e) {
        debugPrint('ServerStore legacy migration failed: $e');
      }
    }
    if (prefs.getBool(_seededPrefsKey) == true) return;
    _servers.addAll(seedServers);
    await _save();
    await prefs.setBool(_seededPrefsKey, true);
  }

  Server _serverFromRow(ServerRow row, String token) => Server(
    id: row.id,
    type: ServerType.values.byName(row.type),
    name: row.name,
    host: row.host,
    port: row.port,
    username: row.username,
    token: token,
    isDefault: row.isDefault,
    serverVersion: row.serverVersion,
    serverName: row.serverName,
  );

  Future<void> _save() async {
    await _db.transaction(() async {
      await _db.delete(_db.servers).go();
      for (final s in _servers) {
        await _db
            .into(_db.servers)
            .insert(
              ServersCompanion.insert(
                id: s.id,
                type: s.type.name,
                name: s.name,
                host: s.host,
                port: s.port,
                username: Value(s.username),
                isDefault: Value(s.isDefault),
                serverVersion: Value(s.serverVersion),
                serverName: Value(s.serverName),
              ),
            );
      }
    });
    for (final s in _servers) {
      try {
        await _secureStorage.write(
          key: 'yinghui_token_${s.id}',
          value: s.token,
        );
      } catch (e) {
        // Secure storage unavailable (e.g. tests without plugins):
        // the server list in Drift is still saved.
        debugPrint('ServerStore secure-storage write failed: $e');
      }
    }
  }

  Future<void> add(Server server) async {
    final toAdd = _servers.isEmpty ? server.copyWith(isDefault: true) : server;
    _servers.add(toAdd);
    await _save();
    notifyListeners();
  }

  Future<void> update(Server server) async {
    final index = _servers.indexWhere((s) => s.id == server.id);
    if (index < 0) return;
    // The edit form does not carry probe data, so a save must not wipe
    // the last-known version/name — keep the stored values unless the
    // caller explicitly provides new ones.
    final existing = _servers[index];
    _servers[index] = server.copyWith(
      serverVersion: server.serverVersion ?? existing.serverVersion,
      serverName: server.serverName ?? existing.serverName,
    );
    await _save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _servers.removeWhere((s) => s.id == id);
    try {
      await _secureStorage.delete(key: 'yinghui_token_$id');
    } catch (e) {
      debugPrint('ServerStore secure-storage delete failed: $e');
    }
    if (_servers.isNotEmpty && !_servers.any((s) => s.isDefault)) {
      _servers[0] = _servers[0].copyWith(isDefault: true);
    }
    await _save();
    notifyListeners();
  }

  Future<void> setDefault(String id) async {
    for (var i = 0; i < _servers.length; i++) {
      _servers[i] = _servers[i].copyWith(isDefault: _servers[i].id == id);
    }
    await _save();
    notifyListeners();
  }

  /// Runs the native client's structured connectivity check, then
  /// records any version/name the probe returned onto the server's
  /// row (see [_recordProbeResult]). The form's Test Connection button
  /// goes through here too, so a successful probe there persists as
  /// well — even if the dialog is then cancelled.
  Future<ConnectionResult> testConnection(Server server) async {
    final result = await _connectionTester(server);
    await _recordProbeResult(server.id, result);
    return result;
  }

  /// Persists a probe's version/name onto the stored server. Only a
  /// field the result actually carries is overwritten — a failed or
  /// version-less test never blanks a previously known version.
  /// Unknown server ids (e.g. a not-yet-saved form candidate) are
  /// ignored.
  Future<void> _recordProbeResult(
    String serverId,
    ConnectionResult result,
  ) async {
    if (result.serverVersion == null && result.serverName == null) return;
    final index = _servers.indexWhere((s) => s.id == serverId);
    if (index < 0) return;
    final current = _servers[index];
    final updated = current.copyWith(
      serverVersion: result.serverVersion ?? current.serverVersion,
      serverName: result.serverName ?? current.serverName,
    );
    if (updated.serverVersion == current.serverVersion &&
        updated.serverName == current.serverName) {
      return;
    }
    _servers[index] = updated;
    await _save();
    notifyListeners();
  }

  /// Bool helper: true only when the check is `ok`.
  Future<bool> testConnectionBool(Server server) =>
      ApiClientFactory.testConnectionBool(server);
}
