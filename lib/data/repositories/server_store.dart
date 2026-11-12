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
/// * non-secret fields (id, type, name, host, port, username, isDefault)
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
  ServerStore({FlutterSecureStorage? secureStorage, AppDatabase? database})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _db = database ?? AppDatabase();

  static const String _legacyPrefsKey = 'yinghui_servers';
  static const String _seededPrefsKey = 'yinghui_seeded_v1';

  final FlutterSecureStorage _secureStorage;
  final AppDatabase _db;
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
        final token = await _secureStorage.read(key: 'yinghui_token_${row.id}');
        _servers.add(_serverFromRow(row, token ?? ''));
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
    _servers[index] = server;
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

  /// Runs the native client's structured connectivity check.
  Future<ConnectionResult> testConnection(Server server) =>
      ApiClientFactory.testConnection(server);

  /// Bool helper: true only when the check is `ok`.
  Future<bool> testConnectionBool(Server server) =>
      ApiClientFactory.testConnectionBool(server);
}
