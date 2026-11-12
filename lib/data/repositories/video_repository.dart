import 'dart:async';

import '../../core/errors.dart';
import '../../core/models/server.dart';
import '../api/emby_client.dart';
import '../db/app_database.dart';
import '../models/track.dart';
import '../models/video_detail.dart';
import '../models/video_item.dart';
import 'fake_repos.dart';
import 'playback_decision.dart';
import 'playback_store.dart';
import 'server_store.dart';

/// One library's recently added items, shown under the library's
/// name (e.g. "电影" / "电视剧").
class RecentCategory {
  const RecentCategory({required this.name, required this.items});

  final String name;
  final List<VideoItem> items;
}

/// What the Video tab needs, regardless of where the data comes from.
abstract class VideoRepository {
  /// True when at least one Emby server has a username + token.
  bool get hasCredentials;

  Future<List<LibraryView>> libraries();

  /// [serverId] scopes the load to one Emby server; null (the
  /// default) merges across all credentialed Emby servers. The Home
  /// page never passes it, so Home always stays merged.
  Future<List<VideoItem>> continueWatching({String? serverId});

  /// The generic recently-added list, flattened across categories.
  /// Prefer [recentlyAddedByCategory] for display: it groups by
  /// library, which is how Emby actually serves latest items.
  Future<List<VideoItem>> recentlyAdded({String? serverId});

  /// Recently added items grouped by library ("最近添加" per
  /// category). The default implementation flattens [recentlyAdded]
  /// into a single "最近添加" category, so repos that do not serve
  /// per-library latest items keep working.
  Future<List<RecentCategory>> recentlyAddedByCategory({
    String? serverId,
  }) async {
    final items = await recentlyAdded(serverId: serverId);
    if (items.isEmpty) return [];
    return [RecentCategory(name: '最近添加', items: items)];
  }

  Future<List<VideoItem>> movies({
    int limit = 20,
    int offset = 0,
    String? serverId,
  });
  Future<List<VideoItem>> series({
    int limit = 20,
    int offset = 0,
    String? serverId,
  });
  Future<List<VideoItem>> search(String query, {String? serverId});
  Future<SeriesDetail> seriesDetail(String seriesId, String serverId);
  Future<VideoDetail> itemDetail(String itemId, String serverId);

  /// Direct-play vs transcode decision for one item, as a playable URL.
  ///
  /// [sources] are media sources already fetched (e.g. the detail
  /// page's PlaybackInfo call). When non-empty the probe is skipped:
  /// the detail page already paid for it, and probing again before
  /// every open is the slowest step on the tap-to-first-frame path.
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
    List<MediaSourceInfo>? sources,
  });

  /// Stream URL for an external subtitle track (direct play only;
  /// transcodes burn the subtitle in via SubtitleStreamIndex).
  String subtitleUrlFor(VideoItem item, SubtitleTrackInfo track);

  Future<void> reportProgress(
    VideoItem item,
    Duration position, {
    bool isPaused = false,
  });
  Future<void> markPlayed(VideoItem item);

  /// Report that playback started (POST /Sessions/Playing). No-op by
  /// default; [RealVideoRepository] reports it to the server.
  Future<void> reportPlaybackStarted(
    VideoItem item, {
    String playMethod = 'DirectPlay',
  }) async {}

  /// Report that playback stopped (POST /Sessions/Playing/Stopped).
  /// No-op by default; [RealVideoRepository] reports it to the server.
  Future<void> reportPlaybackStopped(VideoItem item, Duration position) async {}
}

/// Real video repository: Emby servers, merged.
///
/// One [EmbyClient] per credentialed Emby server. Results are merged
/// across servers and deduped by title+year; a server that is offline
/// throws per-server [ApiException], which is caught here so one dead
/// server never blanks the whole list. With no credentialed Emby server
/// the P0 fake repo is the fallback (the Video page still shows an
/// explicit empty state instead of silently presenting demo data).
class RealVideoRepository implements VideoRepository {
  RealVideoRepository({
    required this.store,
    required AppDatabase database,
    EmbyClient Function(Server server)? clientFactory,
  }) : _playback = PlaybackStore(database),
       _clientFactory = clientFactory ?? ((s) => EmbyClient(s));

  final ServerStore store;
  final PlaybackStore _playback;
  final EmbyClient Function(Server server) _clientFactory;

  /// One client per credentialed server, cached across calls. A fresh
  /// client per access would throw away the per-client /Users/Me cache
  /// and re-fetch it on every repository call; the cache is keyed by
  /// server id and rebuilt when the server's host or credentials
  /// change.
  final Map<String, (String fingerprint, EmbyClient client)> _clientCache = {};

  List<Server> get _credentialedEmby => store.servers
      .where(
        (s) =>
            s.type == ServerType.emby &&
            s.username.isNotEmpty &&
            s.token.isNotEmpty,
      )
      .toList();

  @override
  bool get hasCredentials => _credentialedEmby.isNotEmpty;

  List<(Server, EmbyClient)> get _clients {
    final servers = _credentialedEmby;
    final out = <(Server, EmbyClient)>[];
    final seen = <String>{};
    for (final s in servers) {
      seen.add(s.id);
      final fingerprint = '${s.host}|${s.username}|${s.token}';
      final cached = _clientCache[s.id];
      if (cached != null && cached.$1 == fingerprint) {
        out.add((s, cached.$2));
      } else {
        final client = _clientFactory(s);
        _clientCache[s.id] = (fingerprint, client);
        out.add((s, client));
      }
    }
    _clientCache.removeWhere((id, _) => !seen.contains(id));
    return out;
  }

  EmbyClient? _clientFor(String serverId) {
    for (final (server, client) in _clients) {
      if (server.id == serverId) return client;
    }
    return null;
  }

  /// Run [fetch] on every credentialed server, skipping servers that
  /// fail, and merge + dedupe the results by [key]. With [serverId]
  /// set, only that server is queried at all — and its failure is
  /// rethrown instead of swallowed, so a page filtered to one offline
  /// server shows an error instead of a misleading empty list. With
  /// no filter, one dead server is still skipped — but when EVERY
  /// credentialed server fails, the last failure is rethrown, so the
  /// page shows its error view instead of a silent empty list.
  Future<List<T>> _merged<T>(
    Future<List<T>> Function(EmbyClient client) fetch,
    String Function(T item) key, {
    String? serverId,
  }) async {
    final clients = serverId == null
        ? _clients
        : _clients.where((e) => e.$1.id == serverId).toList();
    final out = <T>[];
    final seen = <String>{};
    ApiException? lastError;
    var failures = 0;
    for (final (_, client) in clients) {
      List<T> items;
      try {
        items = await fetch(client);
      } on ApiException catch (e) {
        if (serverId != null) rethrow;
        failures++;
        lastError = e;
        continue;
      }
      for (final item in items) {
        if (seen.add(key(item))) out.add(item);
      }
    }
    if (clients.isNotEmpty && failures == clients.length) throw lastError!;
    return out;
  }

  static String _videoKey(VideoItem v) =>
      '${v.title.toLowerCase()}|${v.year ?? ''}';

  @override
  Future<List<LibraryView>> libraries() async {
    if (!hasCredentials) return [];
    final out = <LibraryView>[];
    for (final (_, client) in _clients) {
      try {
        out.addAll(await client.getUserViews());
      } on ApiException {
        continue;
      }
    }
    return out;
  }

  @override
  Future<List<VideoItem>> continueWatching({String? serverId}) async {
    if (!hasCredentials) return FakeVideoRepo.continueWatching;
    return _merged<VideoItem>(
      (c) => c.getResumeItems(),
      _videoKey,
      serverId: serverId,
    );
  }

  @override
  Future<List<RecentCategory>> recentlyAddedByCategory({
    String? serverId,
  }) async {
    // No credentials: the demo data has no library to traverse, so
    // it stays one "最近添加" category (the old fake list).
    if (!hasCredentials) {
      return [RecentCategory(name: '最近添加', items: FakeVideoRepo.recentlyAdded)];
    }
    final out = <RecentCategory>[];
    for (final (server, client) in _clients) {
      if (serverId != null && server.id != serverId) continue;
      late final List<LibraryView> views;
      try {
        views = await client.getUserViews();
      } on ApiException {
        continue;
      }
      for (final view in views) {
        // Only media libraries have latest items; a music library
        // or a plain folder returns nothing useful from Latest.
        if (view.collectionType != 'movies' &&
            view.collectionType != 'tvshows') {
          continue;
        }
        late final List<VideoItem> items;
        try {
          items = await client.getLatestItems(parentId: view.id);
        } on ApiException {
          continue;
        }
        if (items.isEmpty) continue;
        // Same title + year twice in one library (e.g. a movie and
        // its extras) shows once.
        final seen = <String>{};
        final deduped = items.where((v) => seen.add(_videoKey(v))).toList();
        // Two servers with a same-named library merge into one
        // section instead of showing "电影" twice.
        final existing = out.where((c) => c.name == view.name).firstOrNull;
        if (existing == null) {
          out.add(RecentCategory(name: view.name, items: deduped));
        } else {
          final existingKeys = existing.items.map(_videoKey).toSet();
          final merged = [
            ...existing.items,
            ...deduped.where((v) => existingKeys.add(_videoKey(v))),
          ];
          out[out.indexOf(existing)] = RecentCategory(
            name: existing.name,
            items: merged,
          );
        }
      }
    }
    return out;
  }

  @override
  Future<List<VideoItem>> recentlyAdded({String? serverId}) async {
    // Kept as a flattened view of the per-category traversal: the
    // old single getItems(DateCreated) query is gone.
    if (!hasCredentials) return FakeVideoRepo.recentlyAdded;
    final categories = await recentlyAddedByCategory(serverId: serverId);
    final seen = <String>{};
    return categories
        .expand((c) => c.items)
        .where((v) => seen.add(_videoKey(v)))
        .toList();
  }

  @override
  Future<List<VideoItem>> movies({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    if (!hasCredentials) {
      return FakeVideoRepo.recentlyAdded
          .where((v) => v.type == 'Movie')
          .toList();
    }
    return _merged<VideoItem>(
      (c) async {
        final uid = await c.userId();
        return c.getItems(
          includeItemTypes: 'Movie',
          userId: uid,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          limit: limit,
          startIndex: offset,
        );
      },
      _videoKey,
      serverId: serverId,
    );
  }

  @override
  Future<List<VideoItem>> series({
    int limit = 20,
    int offset = 0,
    String? serverId,
  }) async {
    if (!hasCredentials) {
      return FakeVideoRepo.recentlyAdded
          .where((v) => v.type == 'Series')
          .toList();
    }
    return _merged<VideoItem>(
      (c) async {
        final uid = await c.userId();
        return c.getItems(
          includeItemTypes: 'Series',
          userId: uid,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          limit: limit,
          startIndex: offset,
        );
      },
      _videoKey,
      serverId: serverId,
    );
  }

  @override
  Future<List<VideoItem>> search(String query, {String? serverId}) async {
    if (!hasCredentials) {
      final q = query.toLowerCase();
      return [
        ...FakeVideoRepo.continueWatching,
        ...FakeVideoRepo.recentlyAdded,
      ].where((v) => v.title.toLowerCase().contains(q)).toList();
    }
    final out = <VideoItem>[];
    final seen = <String>{};
    final clients = serverId == null
        ? _clients
        : _clients.where((e) => e.$1.id == serverId).toList();
    ApiException? lastError;
    var failures = 0;
    for (final (_, client) in clients) {
      try {
        final uid = await client.userId();
        final items = await client.getItems(
          includeItemTypes: 'Movie,Series,Episode',
          userId: uid,
          searchTerm: query,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          limit: 20,
        );
        for (final item in items) {
          if (seen.add(_videoKey(item))) out.add(item);
        }
      } on ApiException catch (e) {
        if (serverId != null) rethrow;
        failures++;
        lastError = e;
        continue;
      }
    }
    if (clients.isNotEmpty && failures == clients.length) throw lastError!;
    return out;
  }

  @override
  Future<SeriesDetail> seriesDetail(String seriesId, String serverId) async {
    final client = _clientFor(serverId);
    if (client == null) {
      final fake = FakeVideoRepo.recentlyAdded.firstWhere(
        (v) => v.id == seriesId,
        orElse: () => FakeVideoRepo.recentlyAdded.first,
      );
      return SeriesDetail(series: fake);
    }
    // Detail, seasons and episodes are independent reads: fetch them
    // concurrently instead of one after another, so the series page
    // waits ~1 round trip, not 3.
    final results = await Future.wait([
      client.getItemDetail(seriesId),
      client.getSeasons(seriesId),
      client.getEpisodes(seriesId),
    ]);
    final detail = results[0] as VideoDetail;
    final seasons = results[1] as List<Season>;
    final episodes = results[2] as List<VideoItem>;
    // The server does not guarantee order: seasons by IndexNumber
    // (Specials first), episodes by season then episode number, so the
    // detail page never shows E2 before E1.
    seasons.sort(
      (a, b) => (a.indexNumber ?? 1 << 30).compareTo(b.indexNumber ?? 1 << 30),
    );
    episodes.sort((a, b) {
      final season = (a.seasonNumber ?? 1 << 30).compareTo(
        b.seasonNumber ?? 1 << 30,
      );
      if (season != 0) return season;
      return (a.episodeNumber ?? 1 << 30).compareTo(b.episodeNumber ?? 1 << 30);
    });
    return SeriesDetail(
      series: detail.item,
      seasons: seasons,
      episodes: episodes,
    );
  }

  @override
  Future<VideoDetail> itemDetail(String itemId, String serverId) async {
    final client = _clientFor(serverId);
    if (client == null) {
      final fake =
          [
            ...FakeVideoRepo.continueWatching,
            ...FakeVideoRepo.recentlyAdded,
          ].firstWhere(
            (v) => v.id == itemId,
            orElse: () => FakeVideoRepo.recentlyAdded.first,
          );
      return VideoDetail(item: fake);
    }
    final detailFuture = client.getItemDetail(itemId);
    final sourcesFuture = _playbackInfoOrEmpty(client, itemId);
    final detail = await detailFuture;
    // Media info (video/audio/subtitle streams) comes from
    // PlaybackInfo, not from the detail endpoint. A failure here must
    // not break the detail page — it just shows "暂无媒体信息".
    //
    // The detail and the PlaybackInfo probe are independent reads:
    // start the probe at the same time as the detail instead of after
    // it, so the page waits ~1 round trip, not 2. The probe is also
    // what the player re-uses at open time (see decidePlayback), so
    // paying for it once here saves a second probe later.
    final sources = await sourcesFuture;
    if (detail.item.type == 'Series') {
      final seasons = await client.getSeasons(itemId);
      return VideoDetail(
        item: detail.item,
        seasons: seasons,
        mediaSources: sources,
        subtitleTracks: detail.subtitleTracks,
      );
    }
    return VideoDetail(
      item: detail.item,
      mediaSources: sources,
      subtitleTracks: detail.subtitleTracks,
    );
  }

  /// PlaybackInfo for one item, or empty when the probe fails. The
  /// detail page must not break on a probe failure — it just shows
  /// "暂无媒体信息" — and the player falls back to probing at open
  /// time when no sources were cached.
  Future<List<MediaSourceInfo>> _playbackInfoOrEmpty(
    EmbyClient client,
    String itemId,
  ) async {
    try {
      return await client.getPlaybackInfo(itemId);
    } on ApiException {
      return const [];
    }
  }

  /// How long the PlaybackInfo probe may take before the player
  /// gives up on it and just plays the direct stream URL instead.
  /// The probe makes the server inspect the file, which on a slow or
  /// shared server can take tens of seconds — longer than the whole
  /// open should take.
  static const probeTimeout = Duration(seconds: 15);

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
    List<MediaSourceInfo>? sources,
  }) async {
    final client = _clientFor(item.serverId);
    if (client == null) {
      throw ApiException('No Emby client for server ${item.serverId}');
    }
    // Re-use sources the detail page already probed when they are
    // given: the probe is a POST that makes the server inspect the
    // file, and re-probing before every open is the slowest step on
    // the tap-to-first-frame path. Without cached sources, probe now.
    final mediaSources = (sources != null && sources.isNotEmpty)
        ? sources
        : await _probeSources(client, item);
    if (mediaSources == null) {
      // The probe failed or timed out (see _probeSources): fall back
      // to the direct stream URL, which needs no probe at all. A slow
      // or broken probe must not stop the video from starting.
      return (
        decision: const PlaybackDecision(kind: PlaybackKind.direct),
        url: client.videoStreamUrl(item.id),
      );
    }
    if (mediaSources.isEmpty) {
      throw ApiException('Emby returned no media sources for ${item.title}');
    }
    final source = mediaSources.first;
    final decision = PlaybackDecider.decide(
      source,
      quality: quality,
      subtitle: subtitle,
    );
    final url = decision.isDirect
        ? client.videoStreamUrl(item.id)
        : client.transcodeUrl(
            item.id,
            // Pin the transcode to the source PlaybackInfo chose;
            // without it the server transcodes its default source.
            mediaSourceId: source.id,
            maxStreamingBitrate: decision.maxStreamingBitrate,
            subtitleStreamIndex: decision.subtitleStreamIndex,
          );
    return (decision: decision, url: url);
  }

  /// Probe PlaybackInfo for one item. Returns null (instead of
  /// throwing) when the probe cannot answer: timed out, unreachable,
  /// or a server error. Those are not decisive — the direct stream
  /// URL works without any probe. Auth errors (401/403) and
  /// not-found (404) are rethrown: the stream would fail the same
  /// way, so the player shows the error instead of a black screen.
  Future<List<MediaSourceInfo>?> _probeSources(
    EmbyClient client,
    VideoItem item,
  ) async {
    try {
      return await client.getPlaybackInfo(item.id).timeout(probeTimeout);
    } on TimeoutException {
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404) {
        rethrow;
      }
      return null;
    }
  }

  @override
  String subtitleUrlFor(VideoItem item, SubtitleTrackInfo track) {
    final client = _clientFor(item.serverId);
    if (client == null) return '';
    return client.subtitleUrl(item.id, track);
  }

  Track _trackFor(VideoItem item) => Track(
    id: item.id,
    title: item.title,
    artist: item.sourceLabel,
    durationSeconds: item.durationSeconds,
    serverId: item.serverId,
  );

  @override
  Future<void> reportProgress(
    VideoItem item,
    Duration position, {
    bool isPaused = false,
  }) async {
    final client = _clientFor(item.serverId);
    if (client != null) {
      try {
        await client.reportProgress(item.id, position, isPaused: isPaused);
      } on ApiException {
        // Server unreachable: the local resume position still saves.
      }
    }
    await _playback.updatePosition(_trackFor(item), position.inSeconds);
  }

  @override
  Future<void> markPlayed(VideoItem item) async {
    final client = _clientFor(item.serverId);
    if (client != null) {
      try {
        await client.markPlayed(item.id);
      } on ApiException {
        // Server unreachable: local history still updates.
      }
    }
    await _playback.updatePosition(_trackFor(item), item.durationSeconds);
  }

  @override
  Future<void> reportPlaybackStarted(
    VideoItem item, {
    String playMethod = 'DirectPlay',
  }) async {
    final client = _clientFor(item.serverId);
    if (client != null) {
      try {
        await client.reportPlaybackStarted(item.id, playMethod: playMethod);
      } on ApiException {
        // Server unreachable: playback continues locally.
      }
    }
  }

  @override
  Future<void> reportPlaybackStopped(VideoItem item, Duration position) async {
    final client = _clientFor(item.serverId);
    if (client != null) {
      try {
        await client.reportPlaybackStopped(item.id, position);
      } on ApiException {
        // Server unreachable: the local resume position still saves.
      }
    }
    await _playback.updatePosition(_trackFor(item), position.inSeconds);
  }
}
