import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/track.dart';

/// Persistence for music (P2) on top of the P1 Drift tables — no new
/// tables, no new persistence layer.
///
/// * Favourites table: one row per starred track/album. `id` is
///   `kind:serverId:itemId` so the same track on two servers is two rows.
/// * PlaybackHistory table: one row per track (`id` is
///   `serverId:itemId`), updated with the resume position on pause/stop.
class PlaybackStore {
  PlaybackStore(this.db);

  final AppDatabase db;

  static String favouriteId(String kind, String serverId, String itemId) =>
      '$kind:$serverId:$itemId';

  static String historyId(String serverId, String itemId) =>
      '$serverId:$itemId';

  Future<bool> isStarred({
    required String kind,
    required String serverId,
    required String itemId,
  }) async {
    final rows = await (db.select(
      db.favourites,
    )..where((t) => t.id.equals(favouriteId(kind, serverId, itemId)))).get();
    return rows.isNotEmpty;
  }

  /// Toggle a favourite; returns true when it is starred afterwards.
  Future<bool> toggleStar({
    required String kind,
    required String serverId,
    required String itemId,
    required String title,
  }) async {
    final id = favouriteId(kind, serverId, itemId);
    final starred = await isStarred(
      kind: kind,
      serverId: serverId,
      itemId: itemId,
    );
    if (starred) {
      await (db.delete(db.favourites)..where((t) => t.id.equals(id))).go();
      return false;
    }
    await db
        .into(db.favourites)
        .insertOnConflictUpdate(
          FavouritesCompanion.insert(
            id: id,
            itemId: itemId,
            kind: Value(kind),
            title: Value(title),
            serverId: Value(serverId),
          ),
        );
    return true;
  }

  Future<List<Favourite>> starred({String? kind}) async {
    final query = db.select(db.favourites);
    if (kind != null) {
      query.where((t) => t.kind.equals(kind));
    }
    return query.get();
  }

  /// Write/update a playback-history row when a track starts.
  Future<void> recordStart(Track track) async {
    await db
        .into(db.playbackHistory)
        .insertOnConflictUpdate(
          PlaybackHistoryCompanion.insert(
            id: historyId(track.serverId, track.id),
            itemId: track.id,
            title: Value(track.title),
            serverId: Value(track.serverId),
            positionSeconds: const Value(0),
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Update the resume position for a track (pause / stop / seek).
  Future<void> updatePosition(Track track, int positionSeconds) async {
    await db
        .into(db.playbackHistory)
        .insertOnConflictUpdate(
          PlaybackHistoryCompanion.insert(
            id: historyId(track.serverId, track.id),
            itemId: track.id,
            title: Value(track.title),
            serverId: Value(track.serverId),
            positionSeconds: Value(positionSeconds),
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Most recent playback first, for "continue listening".
  Future<List<PlaybackHistoryData>> recentHistory({int limit = 20}) async {
    final query = db.select(db.playbackHistory)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
      ..limit(limit);
    return query.get();
  }

  /// Settings → Data: clear all playback history rows.
  Future<void> clearHistory() async {
    await db.delete(db.playbackHistory).go();
  }

  /// Settings → Data: clear all favourite rows.
  Future<void> clearFavourites() async {
    await db.delete(db.favourites).go();
  }
}
