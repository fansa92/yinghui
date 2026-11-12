import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Servers — the only table with a secret-adjacent column set, and even
/// here there is NO secret: [Servers.username] is non-secret, the
/// password/token lives only in flutter_secure_storage (see ServerStore).
/// Row class is [ServerRow] to avoid colliding with the domain [Server].
@DataClassName('ServerRow')
class Servers extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get name => text()();
  TextColumn get host => text()();
  IntColumn get port => integer()();
  TextColumn get username => text().withDefault(const Constant(''))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Playback history (P2+). Placeholder in P1 — table exists, unused.
class PlaybackHistory extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get serverId => text().withDefault(const Constant(''))();
  IntColumn get positionSeconds => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Favourites (P2+). Placeholder in P1 — table exists, unused.
class Favourites extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text()();
  TextColumn get kind => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get serverId => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Download tasks (P4+). Placeholder in P1 — table exists, unused.
/// Row class is [DownloadTaskRow] to avoid colliding with the domain
/// [DownloadTask] model (same pattern as Servers -> ServerRow).
@DataClassName('DownloadTaskRow')
class DownloadTasks extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get source => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant(''))();
  RealColumn get progress => real().withDefault(const Constant(0.0))();
  TextColumn get serverId => text().withDefault(const Constant(''))();

  /// The exact input the task was added from (magnet, http URL, or
  /// bare torrent hash), added in schema v2 so the detail page can
  /// show/copy it after a restart. Empty for older rows.
  TextColumn get sourceInput => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Servers, PlaybackHistory, Favourites, DownloadTasks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'yinghui'));

  /// Test / in-memory constructor. Pass `NativeDatabase.memory()` from
  /// `package:drift/native.dart`.
  AppDatabase.forExecutor(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(downloadTasks, downloadTasks.sourceInput);
      }
    },
  );
}
