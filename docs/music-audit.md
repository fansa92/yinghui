# 音乐界面 UI + 功能性审计

Read-only audit, 2026-11-14. Scope: the music stack as it stands on local main
(`20c4478`, v0.2 candidate). Nothing was changed; this document is the only
file written. Baseline facts: music plays on device (v0.1.3, confirmed by yang
2026-11-12); video is the unproven side, not music. The Tempus batch
(`c29776e`) already restyled the browse sections and the default now-playing
layout — layout polish of those two screens is done; what is missing now is
mostly **functionality** and a few **data/quality** gaps underneath the new
layout.

## Ranked list — by what yang would feel most in daily use

| # | Gap | One-line build scope |
|---|---|---|
| 1 | No shuffle / repeat | Add `ShuffleMode`/`RepeatMode` to `PlayerService` + buttons in NowPlayingPage + persist the modes |
| 2 | Queue is tap-to-jump only | Add remove / reorder / clear + "play next" / "add to queue" to `PlayerService` and the Up next list |
| 3 | Emby audio not wired | Merge Emby `getAudioItems` into `MusicRepository` (dedup, covers, album/artist mapping) and route Emby tracks to `audioUniversalUrl` |
| 4 | No artist detail page | Add Subsonic `getArtist` to the client + an `ArtistDetailPage` (albums + top songs); make artist cards/rows tappable |
| 5 | "继续收听" resume is broken + Music tab has no 最近播放 | Fix Home `_playHistory` to seek to the saved position with the real track; add a 最近播放 section to the Music tab reusing `PlaybackStore.recentHistory` |
| 6 | Cover art cache defeated + low-res now-playing cover | Stop putting a fresh random salt in cover URLs (stable salt per session) so `CachedNetworkImage` actually caches; request a large cover for NowPlaying |
| 7 | No sleep timer, no playback speed | Add a sleep timer (Timer → pause) and a speed control (`media_kit` `setRate` via a new `PlayerBackend.setRate`) |
| 8 | Albums always "newest", no 全部歌曲 / 随机播放 | Add a sort control (newest / alphabetical / frequent / recent) to the Music page; add an all-songs shuffle entry via Subsonic `getRandomSongs` |
| 9 | Playlists are view-only | Add Subsonic `createPlaylist` / `updatePlaylist` / `deletePlaylist` + "add to playlist" from track rows and the player |
| 10 | Search is submit-only and forgetful | Live-as-you-type search, recent-search suggestions (history is already recorded, never shown), playlist results |

## What is already done — do not re-propose

- Tempus browse layout (`c29776e`): 浏览 sections (专辑/艺人/歌单/收藏 previews +
  查看全部), default now-playing layout (full-width cover, left-aligned
  title/artist, flanked times, heart + 播放队列 row). Apple Music / Spotify
  styles untouched.
- Audio quality setting exists and is wired: Settings → 音频质量（Navidrome）
  原始/128/192/320 kbps, read at call time in `main.dart:83-87` and passed as
  `maxBitRate` into `streamUrlFor`. No new quality UI is needed for Navidrome.
- Favourites work end to end: server star/unstar + local Drift fallback
  (`music_repository.dart:318-377`), heart in the player
  (`now_playing_page.dart`, `_StarButton`), star toggles on album detail and
  track lists.
- Queue restores across restarts (`AppStateStore` last music + `PlayerService.restoreQueue`,
  `player_service.dart:262`), mini player is a floating card, playback errors
  show a banner with retry, per-page server switching works.
- Test coverage for music/player is real: `music_p2_test.dart` (parsing,
  merge/dedup, star, playQueue/next/previous/completed),
  `tempus_music_test.dart` (browse sections, default player layout),
  `player_styles_test.dart`, `playback_error_test.dart`,
  `mini_player_floating_test.dart`, `desktop_players_test.dart`. No tests exist
  for shuffle/repeat, queue editing, Emby audio, lyrics, or sleep timer —
  because none of those features exist.

---

## 1. Sources — Music is Navidrome-only; Emby audio is dead code

**Today:** the Music tab only ever talks to Navidrome servers
(`music_repository.dart:63-70`, `_credentialedNavidrome`). An Emby server with
a music library contributes nothing to Music, even though the Emby client
already has the pieces: `getAudioItems` (`emby_client.dart:247`, newest 20
Audio items as unified `Track`s) and `audioUniversalUrl`
(`emby_client.dart:302`). Both have **zero callers** anywhere in `lib/`.

**What is missing / weak:**
- No Emby path in `MusicRepository` at all — no albums/artists/playlists/starred
  from Emby, no Emby stream URL routing (`streamUrlFor` builds a Subsonic URL
  only, `music_repository.dart:388-394`).
- Even the existing client methods are thin: `getAudioItems` returns only the
  newest 20 tracks, with **no cover URL and no albumId** (the `Track` is built
  without them), so Emby tracks would render with placeholder covers and could
  not open an album page. There is no Emby audio-album or audio-artist call
  (the generic `getItems` supports `IncludeItemTypes=Audio` / `MusicAlbum` /
  `MusicArtist`, but nothing maps those to `Album`/`Artist`).
- Dedup would need care: a track present in both Navidrome and Emby dedupes by
  title+artist today, but the two copies have different ids/servers, so the
  surviving copy's `serverId` decides which stream URL is used.

**Feasibility: medium.** Client groundwork is ~30% done (list + stream URL).
Still needed: Emby album/artist mapping, cover URLs via `EmbyClient.imageUrl`,
a merged repo path (Emby clients alongside Subsonic clients, same `_merged`
pattern), and `streamUrlFor` branching on `track.serverId`'s server type.
Testable with mocked Dio, like the existing `music_p2_test.dart`.

## 2. Playback modes — no shuffle, no repeat

**Today:** `PlayerService` (`player_service.dart:98-447`) has no shuffle or
repeat state at all. `next()` (`:337`) stops at the end of the queue (saves
position, stops the backend); `completed` auto-advances once and then stops.
The code says so explicitly: `now_playing_page.dart:40-41` — "No
shuffle/repeat buttons: [PlayerService] has no shuffle or repeat mode, and a
button that does nothing is not acceptable."

**What is missing:** shuffle (play the queue in random order, keeping the
current track first), repeat-off / repeat-all / repeat-one. This is the
single most-missed player control for daily listening — every other music app
has it, and its absence is visible every time a playlist/album ends.

**Feasibility: medium.** Needs: a shuffle flag + a shuffled index order kept
in the service (so next/previous/restore still work), a repeat mode enum,
`completed`/`next()` branching on the mode, UI buttons in `_seekAndControls`
(all three player styles + desktop), and persistence of the two modes
(`SettingsService` or `AppStateStore` — neither stores them today). No server
work: shuffle/repeat are purely client-side queue logic. Tests: extend the
existing `PlayerService` fake-backend tests.

## 3. Queue — Up next is tap-to-jump only

**Today:** the queue exists (`player.queue`, `currentIndex`) and the Up next
list in `now_playing_page.dart` (`_queueSection`) only supports tap-to-jump
(`playQueue(player.queue, startIndex: i)`). There is **no** remove, reorder,
clear, "play next", or "add to queue" anywhere: `grep removeFromQueue|moveQueue|clearQueue|reorder lib/` returns nothing, and every
call site uses `playQueue(...)`, which **replaces** the whole queue.

**What the user feels:** you cannot remove a track you don't want, cannot
drag a track up the list, cannot clear the queue, and tapping a song anywhere
( search results, a playlist, an album ) throws away whatever was queued
before. There is also no queue length shown and no "clear queue" affordance.

**Feasibility: medium.** Needs service methods (`removeAt`, `move`, `clear`,
`enqueue`/`playNext` that insert without replacing) with index bookkeeping
(current index shifts when items before it move), a `ReorderableListView` (or
swipe-to-remove + drag handle) for Up next on phone and desktop, and
"下一首播放 / 添加到队列" entries in the places that today call `playQueue`
(album detail, track lists, search results). All client-side; no server work.

## 4. Library browsing — artist detail does not exist

**Today:** artist cards in the browse grid (`music_page.dart`, `_artistCard`)
and artist rows in the 艺人 filter and search results are **display-only** —
no `onTap`. The comment in the code admits it: "Artists have no cover art in
our model (and no detail page), so the card is display-only."
`SubsonicClient` has `getArtists` (`subsonic_client.dart:242`, index only)
but no `getArtist` (single-artist detail: albums + top songs), and the
`Artist` model (`track.dart:27-41`) carries no cover art field.

**What is missing:** tapping an artist should open an artist page (albums by
that artist + top songs, like the album detail page). Artist cards also show a
generic person icon instead of any image — Subsonic's `getArtist` returns a
`coverArt` id, which the current model cannot even hold.

**Feasibility: medium.** Needs: `getArtist(id)` in the client (one endpoint),
`Artist.coverUrl` on the model, `MusicRepository.artist(id, serverId)`, and a
new `ArtistDetailPage` reusing the album-detail/track-row patterns. No schema
work. Note the dedup caveat: the same artist name on two servers is two
`Artist` rows today (dedup by name in `_merged`, so the merged list keeps one
— its `serverId` then decides which server the detail page queries).

## 5. Recently played — shown only on Home, and its resume is broken

**Today:** `PlaybackStore.recentHistory` (`playback_store.dart:106-112`)
exists and `PlayerService` records every track start (`recordStart`) and
position (`updatePosition`). Home shows it as "继续收听" (limit 3,
`home_page.dart:121,298-326`). The Music tab has **no** 最近播放 section at
all — the tab is browse/search only.

**Broken part (bug, not a missing feature):** Home's `_playHistory`
(`home_page.dart:161-170`) builds a bare `Track` with only `id`/`title`/
`serverId` and calls `playQueue([track])`. Two things are wrong:
- It **ignores the saved position**: the row's subtitle says "从 X 继续" but
  playback starts from 0. The resume position is only honoured by the
  startup restore path (`restoreQueue`, `player_service.dart:262`), never by
  this tap.
- The bare track has no artist, album, cover, or duration, so the mini
  player / now-playing page shows a title-only track with a placeholder cover
  and a 0:00 duration until the backend reports one.

**Feasibility: easy (fix) / easy (Music-tab section).** Fix: resolve the
history row to a real track (via `SubsonicClient.getSong`, which already
exists at `subsonic_client.dart:331` but has no callers) and seek to
`row.positionSeconds` after open — or reuse `restoreQueue` with a
single-track queue + position. Section: a 最近播放 block on the Music tab
reusing `recentHistory`, same data Home already loads. "最多播放" (most played)
is a separate, harder item: history rows store one row per track with no play
count, so ranking by plays needs a count column (schema change) — do not
bundle it into this one.

## 6. Cover art — the image cache is defeated, and the now-playing cover is low-res

**Today:** covers render through `CoverImage` (`cover_image.dart`), which uses
`CachedNetworkImage` (URL-keyed cache) with a music-note placeholder on
missing/failed images. That part is sound.

**Two real defects underneath:**
- **The cache never hits across loads.** `coverArtUrl`
  (`subsonic_client.dart:347`) builds its auth params via `_authParams()`
  (`:76-84`), which generates a **fresh random salt on every call**. Every
  repo fetch re-parses every album/track and mints new cover URLs, so the
  cache key changes on every page load and every cover is re-downloaded.
  Within one load the URL is stable (parsed once), so scrolling is fine — but
  returning to the tab, pulling to refresh, or reopening the app re-fetches
  all covers. On a slow connection the grids visibly re-populate.
- **The now-playing cover is a 300px image stretched full-width.**
  `coverArtUrl` defaults to `size: 300` and the model stores a single URL, so
  the same 300px image that is fine in a grid cell is stretched to the full
  content width on phones and up to ~1000px on desktop in the Tempus default
  layout (`now_playing_page.dart`, `_coverHeader` standard branch). It looks
  soft/blurry on any modern phone.

**Feasibility: easy–medium.** Cache: use one stable salt per app session (or
per server) for cover URLs instead of a fresh random salt per call — auth
still holds (salt only needs to be unpredictable per request for the token;
a session-stable salt is the standard Subsonic practice), or pass an explicit
`cacheKey` to `CachedNetworkImage`. Resolution: request a larger size for the
now-playing cover (e.g. size 800–1200) — needs either a second URL field on
`Track`/`Album` or a helper that re-derives the URL at a different size.

## 7. Sleep timer + playback speed — both absent, both cheap

**Today:** no sleep timer and no speed control anywhere. `grep` for
`sleep|timer` (excluding download polling) and `setRate|playbackRate|speed`
in `lib/` finds nothing in the player. The `PlayerBackend` interface
(`player_service.dart:20-44`) exposes play/pause/seek/stop/volume only.

**Feasibility: easy.** Sleep timer is pure client logic: a `Timer` (15/30/60
min / end-of-track) that calls `pause()` — no backend change, no server work,
one small menu in NowPlayingPage. Speed: `media_kit`'s `Player.setRate`
exists upstream, so it is one new method on `PlayerBackend` (`setRate`),
a `rate` field on the service, and a speed picker (0.75×/1×/1.25×/1.5×/2×) in
the player; rate does not need persistence, though remembering it in Settings
is one line. Both are self-contained and testable with the existing fake
backend.

## 8. Album sort + all-songs shuffle — the library has one order

**Today:** the Music page always loads albums with `type: 'newest'`
(`music_repository.dart:19,155`; the UI never passes another type) and there
is no sort control. There is also no "全部歌曲" view at all: songs are only
reachable inside an album, a playlist, search results, or starred. And there
is no random-play entry: `SubsonicClient` has no `getRandomSongs` (grep
confirms absent).

**Feasibility: easy (sort) / medium (shuffle-all).** Sort: `getAlbumList2`
already accepts `newest | alphabeticalByName | frequent | recent | random`
server-side — it is a chip/dropdown in the Music page wired to the existing
`albums(type:)` parameter, plus pagination already exists for the 专辑 filter.
Shuffle-all: add `getRandomSongs` to the client (one endpoint) and a
"随机播放" entry (e.g. on the 浏览 view) that builds a queue from it. No schema
or player changes.

## 9. Playlists are view-only

**Today:** `getPlaylists` / `getPlaylist` exist (`subsonic_client.dart:290-310`)
and the UI lists playlists and plays them (`track_list_page.dart`). There is
no create / rename / delete / add-track / remove-track: `createPlaylist`,
`updatePlaylist`, `deletePlaylist` do not exist in the client, `MusicRepository`
has no playlist-mutation method, and no UI offers "添加到歌单" (track rows and
the player have star buttons only).

**Feasibility: medium.** Client: three Subsonic endpoints (`createPlaylist`,
`updatePlaylist`, `deletePlaylist` — all simple GETs with auth params, same
pattern as `star`). Repo: thin wrappers following `toggleStarTrack`. UI: a
create dialog on the 歌单 filter + an "添加到歌单" sheet from track rows and
NowPlayingPage. No schema work; server-owned playlists stay server-owned.

## 10. Search — submit-only, and its history is dead data

**Today:** search runs only on submit (`music_page.dart`, `onSubmitted: _search`);
typing does nothing until Enter, and there is no live-as-you-type search.
`SettingsService.recordSearch` (`settings.dart:330`) dutifully records every
query and `searchHistory` (`settings.dart:175`) persists it — but **nothing in
the UI ever reads it**: no recent-search chips, no suggestions. Search results
cover songs/albums/artists (`searchAll`, `search3`) but **not playlists**, and
result rows are plain `ListTile`s with no per-result actions (no "play next",
no "go to album" from a song row).

**Feasibility: easy–medium.** Live search: debounce the existing `_search`
call on `onChanged` (the repo call already exists; add a 300ms debounce and
guard against out-of-order responses). Recent searches: render
`settings.searchHistory` as chips under the search box (data already exists).
Playlist results: `search3` does not return playlists, so this needs a
client-side filter over `getPlaylists` — cheap but a second fetch; or leave
playlists out and say so.

---

## More gaps worth knowing (lower priority than the top 10)

- **Mini player is minimal and vanishes off the Music tab.** It has
  play/pause + next only — no previous button, and the progress bar is
  display-only (no drag-to-seek). There is no swipe-to-dismiss/close. And by
  an earlier deliberate decision it only appears on the Music tab and
  AlbumDetailPage, so it disappears on Home / Video / Downloads / Settings.
  Easy–medium to extend; the scoping decision is worth re-confirming with
  yang before changing.
- **Track rows have no context menu.** Long-press does nothing anywhere in
  music (album tracks, playlist tracks, search results, starred songs). Every
  "play next / add to queue / add to playlist / go to album / go to artist"
  action needs a long-press menu first — this is the UI surface items 2 and 9
  depend on. Easy once the service methods exist.
- **No per-track metadata.** `Track` (`track.dart:3-24`) carries no bitrate,
  format, genre, year, or play count, although Subsonic's song JSON provides
  `bitRate`, `suffix`, `contentType`, `genre`, `year`, `playCount` — none are
  parsed in `_trackFromJson` (`subsonic_client.dart:381`). So the UI cannot
  show "FLAC · 320kbps" or a genre anywhere. Easy to parse; display is a
  one-line addition per row.
- **Volume slider is style-gated on phones.** Only the Apple Music style shows
  a volume slider on phones (`now_playing_page.dart`, `_body`); default and
  Spotify get it only on desktop (`_desktopBody`). Easy: show it in all
  styles (it is already wired to the real volume).
- **Album detail polish.** It has 全部播放 + 收藏 but no shuffle-play button;
  its error view prints the raw exception (`album_detail_page.dart`,
  `'专辑加载失败：\n${snapshot.error}'`); and `_loadStarred` does a second full
  `starred()` fetch just to seed star icons. Easy.
- **`TrackListPage` star state is keyed by track id only**
  (`track_list_page.dart`, `_starred[t.id]`) — it collides across servers and
  is never seeded from the server's starred list, so playlist tracks always
  start unstarred (contrast `AlbumDetailPage`, which seeds correctly). Easy
  fix, same `serverId:itemId` key.
- **Album pagination only exists for the 专辑 filter.** `_onScroll` /
  `_loadMoreAlbums` (`music_page.dart:164-171,209`) only run when
  `_filter == '专辑'`; the browse view caps at 8 albums with no way to page
  further except switching filters. Easy.
- **No keyboard shortcuts for music on desktop.** Video has them
  (Space/←→/F/Esc); music has none. Easy, low value.
- **`getGenres` is dead code.** It exists (`subsonic_client.dart:313`) with no
  callers — genre browsing would be a small section/filter on top of it (see
  item 8's neighbourhood), but it is not wired to anything today.

## Explicitly NOT worth doing now

1. **Lyrics.** Neither Subsonic/Navidrome nor Emby exposes a lyrics endpoint,
   and neither client has one. Real lyrics would need a third-party provider
   (e.g. lrclib) matched by title+artist+duration, or reading embedded tags
   the servers do not serve. No data source in the current stack — defer
   until/unless yang wants an external lyrics provider.
2. **Offline music (download tracks to the phone).** Downloads today are
   server-side torrents by design; offline music needs the Subsonic `download`
   endpoint + local file storage + an offline library + cache management + a
   download-state UI — a whole subsystem, not a music-page tweak. Only build
   if yang explicitly wants offline listening.
3. **Gapless / crossfade playback.** `PlayerService` opens one URL per track
   (`player_service.dart`, `_openCurrent`), so track changes have a small gap.
   True gapless needs `media_kit` playlist mode and a queue rework in the
   service — noticeable only on gapless albums (live/concept albums), and
   invisible for most listening. Defer behind items 1–3.
4. **"Most played" as its own build.** History rows store one row per track
   with no play count (`playback_store.dart`), so ranking by plays needs a
   schema change. Fold it into item 5 later if wanted; it is not worth a
   migration on its own.

## Suggested first step

**Build #1 + #2 together (shuffle/repeat + queue management).** They share one
service change (queue state in `PlayerService`), one UI surface (the
now-playing transport + Up next list), and no server work — and they are the
two things a daily listener hits first every session. After that, #3 (Emby
audio) is the biggest library win, and #5's Home-resume fix is a one-hour bug
fix that should not wait for a batch.
