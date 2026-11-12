# API Audit — 影汇 YingHui (read-only)

Date: 2026-11-12. Scope: all 5 native clients in `lib/data/api/` + the calling
repositories (`music_repository.dart`, `video_repository.dart`,
`download_repository.dart`, `playback_decision.dart`) and the load paths
(Home / Music / Video / Downloads). Method: every call compared against the
official docs (listed under Sources), plus unauthenticated route-existence
probes against yang's own live servers (Navidrome `https://sg.kass.qzz.io/`,
Emby `https://cf.imetyou.top`) — a probe returning 401 proves the route
exists and needs auth; 404 proves the route does not exist. No source file
was edited; no authenticated call was made (no credentials were ever given).

Trigger: yang reported "有很多接口都不对" and "有很多都不加载" on the v0.1
device build. The load-path calls were prioritised, including response
parsing: a wrong field name or a single-object-vs-list mismatch that silently
yields an empty list is a likely cause of "does not load".

## Summary counts

| Service | Breaking | Minor | Verified-correct calls |
|---|---|---|---|
| Subsonic / Navidrome | 0 | 0 | 15 |
| Emby | 3 | 2 | 13 |
| qBittorrent | 1 | 2 | 8 |
| Transmission | 0 | 2 | 7 |
| aria2 | 0 | 1 | 8 |
| Cross-cutting (repositories / Home) | 1 | 0 | — |
| **Total** | **5** | **7** | **51** |

Headline: **the Subsonic (music) calls are all correct** — including the
`.view` question, settled by live probe (see S-0). The music load path has no
API bug; if Music shows nothing, the cause is missing credentials (the 3
seeded servers ship with empty username/token) or an auth failure being
swallowed (X-1). **The breaking bugs are concentrated in Emby (3) and
qBittorrent (1)**, plus the silent-empty-list mechanism (X-1) that hides all
of them from the user.

## Breaking findings

### B1 — qBittorrent login can never succeed: code expects `"Ok"`, server returns `"Ok."`
- **File:** `lib/data/api/qbittorrent_client.dart:67-84` (`login()`), exact line 79: `return response.data == 'Ok';`. If false, `login()` throws `ApiException('qBittorrent login failed: bad credentials')`.
- **What the docs say:** the official WebUI API wiki's login example shows the success response with `Content-Length: 3` — `"Ok."` is 3 bytes, `"Ok"` is 2. qBittorrent returns `"Ok."` on success (`"Fails."` on failure); the same convention is documented by the qbittorrent-api client ("Returns `Ok.` for success and `Fails.` for failure").
  Source: https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1) (Login section).
- **Impact:** every qB operation goes through `_ensureLogin()` (`:152`, called by `torrentsInfo()` `:174`, `addMagnet()` `:192`, pause/resume/delete `:229-235`), so **the whole qB download queue, add, pause/resume and delete are dead** — even with correct credentials. `testConnectionResult()` (`:101`) catches the login exception and reports `needsAuth` forever, so the Servers page will always show qB as "needs login". (The SID cookie *is* captured before the bad check, so the session is actually established and then thrown away.)
- **Correction:** `return response.data == 'Ok.';` — or, more robustly, accept the body after trimming and compare case-insensitively to `"Ok."`. The fix phase must also fix the unit test that encodes the old expectation.

### B2 — Emby has no working login path: `authenticate()` is implemented but never called
- **File:** `lib/data/api/emby_client.dart:64-96` (`authenticate()` — POST `Users/AuthenticateByName` with `{Username, Pw}`, returns `AccessToken`). A repo-wide grep finds **zero callers** in `lib/`. Its doc comment says "the caller stores it on the server (secure storage)" — no such caller exists.
- **What the code does instead:** the Servers form has one secret field labelled `Password / token / secret` (`lib/features/servers/servers_page.dart:301`) and the token is sent as `X-Emby-Token` on every call (`emby_client.dart:60-61`). So the only way Emby works today is if the user pastes a server API key (Emby Dashboard → API Keys) into that field. If yang entered his Emby account username + password — the natural reading of the form — every Emby call returns 401.
- **What the docs say:** `POST /Users/AuthenticateByName` with `Username`/`Pw` returns an `AccessToken` to be sent as `X-Emby-Token` (Emby developer docs / Swagger). The client implements this correctly; it is just never invoked.
- **Impact:** Video tab (UserViews, Resume, Movies/Series lists, detail, PlaybackInfo) and the Home video rows all 401 → `video_repository._merged` swallows the error (X-1) → blank lists, no error shown.
- **Correction:** in the Emby add/edit server flow, when username + password are given, call `authenticate()` and store the returned `AccessToken` as the server token (note: `authenticate()` reads the password from `server.token`, so the form must pass the password through at login time, then replace it with the token). Alternatively, relabel the field "Emby API key" with a hint where to create one — but do not leave a username+password form that silently does nothing.

### B3 — Emby connection test cannot detect a bad token on this server: `GET /System/Info` is unauthenticated
- **File:** `lib/data/api/emby_client.dart:121-160` (`testConnectionResult()`), `:90-105` (`testConnection()`). With a token present it does `GET System/Info` and returns `ok` on HTTP 200.
- **Live probe (2026-11-12, unauthenticated):** `GET https://cf.imetyou.top/System/Info` → **HTTP 200 with full SystemInfo JSON** (`Id: mediastation-go-001`, `OperatingSystem: Windows`, …). So on yang's server the test reports "Connected" for *any* non-empty token, including a wrong one or an account password. The user sees a green check while every library call 401s.
- **Correction:** validate the token against an endpoint that actually requires auth on this server — `GET /Users/Me` (probed **401** without auth, i.e. the route exists and enforces auth) — and return `ok` only when that succeeds. (`GET /Users/Me` also yields the user id, which `userId()` fetches separately today.)
- Note: whether the unauthenticated `/System/Info` is a deliberate server setting or proxy behaviour is unknown; the fix works either way. (`/Audio/{id}/stream`, `/Audio/{id}/universal` and `/Items/{id}/Images/Primary` also returned 200 without auth on this server — images/audio are effectively public here; not a client bug, noted only.)

### B4 — Emby progress reporting posts to a route that does not exist: resume is never saved
- **File:** `lib/data/api/emby_client.dart:581-592` (`reportProgress()`). Posts `Users/{uid}/Items/{itemId}/PlayingItems/{itemId}/Progress` with `{PositionTicks, IsPaused, CanSeek}`.
- **What the docs say:** Emby's documented progress endpoint is **POST `/Sessions/Playing/Progress`** with a `PlaybackProgressInfo` body (`ItemId`, `PositionTicks`, `IsPaused`, `PlaySessionId`, …) — "Playback Check-ins", https://betadev.emby.media/doc/restapi/Playback-Check-ins.html. The generated Emby OpenAPI client also lists a legacy route `POST /Users/{UserId}/PlayingItems/{Id}/Progress` — **without** the `/Items/{id}/` segment the code inserts.
- **Live probe on Emby 4.8.10.0 (unauthenticated):** code path → **404**; legacy path → **404**; `/Sessions/Playing/Progress` → **401** (route exists, auth required). So on this server *neither* user-scoped progress route exists; only the session route does.
- **Impact:** every progress report (pause / dispose) 404s, so the server never records resume positions — **Continue Watching / Resume never updates** and "Resume from xx:xx" never appears, even though the UI for it exists. The code also never POSTs `/Sessions/Playing` (start) or `/Sessions/Playing/Stopped`, so no playback session is ever created on the server at all. (`markPlayed()` is fine — `POST Users/{uid}/PlayedItems/{id}` probed 401 = exists.)
- **Correction:** POST `/Sessions/Playing` on playback start, POST `/Sessions/Playing/Progress` with `PlaybackProgressInfo` (`ItemId`, `PositionTicks`, `IsPaused`, `PlaySessionId` from the PlaybackInfo response) periodically and on pause, POST `/Sessions/Playing/Stopped` on dispose.

### X-1 — Cross-cutting: auth failures are swallowed into empty lists, so "does not load" shows no error
- **Files:** `lib/data/repositories/music_repository.dart:113-133` (`_merged`: `on ApiException { continue; }`), `lib/data/repositories/video_repository.dart:114-134` (same), `lib/features/home/home_page.dart:88-113` (`_load()`: each section wrapped in `catch (_) {}` with the comment "A failed section stays empty; it never blanks the page").
- **Mechanism:** any 401/403 — wrong credentials, expired qB SID, a password pasted where an API key belongs (B2), a token the test wrongly validated (B3) — produces `[]`. The Music/Video pages *do* have an `_error` path (`music_page.dart:125-129`, `video_page.dart:126-130`) but the repositories never throw, so it is never reached. Home shows blank sections with no error at all. The user sees "a lot does not load" with no indication of why. (Downloads is the exception: `download_repository.dart:353-354, 469-470, 539-540, 590-591` records per-server errors in `_errors`, so a qB failure there at least surfaces as an inline error.)
- **Correction:** distinguish "no credentials configured" from "request failed": keep the last `ApiException` per server/section and surface it (at minimum its status: 401/403 → "login needed — check the server credentials in Settings → Servers"). Do not turn a failed fetch into an empty list without a visible reason.

## Minor findings

### M1 — Emby subtitle fallback URL uses a route that does not exist when `mediaSourceId` is missing
- **File:** `lib/data/api/emby_client.dart:560-578` (`subtitleUrl()`). Fallback (no media source id): `/Videos/{id}/Subtitles/{index}/Stream.srt`.
- **What the docs say:** dev.emby.media "Subtitles" documents only `/Videos/{Id}/{MediaSourceId}/Subtitles/{Index}/Stream.{Format}` (https://dev.emby.media/doc/restapi/Subtitles.html).
- **Live probe:** `GET /Videos/abc/Subtitles/0/Stream.srt` → **404**; the MediaSourceId form → **401** (exists).
- **Mitigation in code:** `VideoDetail.allSubtitles` (`lib/data/models/video_detail.dart:214-236`) fills `mediaSourceId` from the PlaybackInfo media sources, and `MediaSourceInfo.subtitles` (`:175-189`) sets it — so the fallback is only hit when PlaybackInfo has not been fetched (e.g. detail-page subtitle list). **Correction:** always resolve the media source id (from PlaybackInfo) before building the URL; never emit the no-source form. Minor — subtitles only.

### M2 — aria2 `tellStopped` maps failed/removed downloads to "completed"
- **File:** `lib/data/api/aria2_client.dart:136-143` (`tellStopped()` maps every entry to `DownloadStatus.completed`).
- **What the docs say:** `aria2.tellStopped` "returns the list of stopped download" — stopped includes `complete`, `error` and `removed` (status values documented under `aria2.tellStatus`). Source: https://aria2.github.io/manual/en/html/aria2c.html (RPC Interface).
- **Impact:** a failed aria2 download shows as completed and is never offered a retry. **Correction:** map by the entry's `status` field (`complete` → completed, `error` → failed, `removed` → failed/removed).

### M3 — qBittorrent state mapping misses `forcedDL`, `forcedUP`, `stoppedUP`
- **File:** `lib/data/api/qbittorrent_client.dart:257-267` (`_taskFromJson` switch).
- **What the docs say:** the wiki's `torrents/info` state table lists `error, missingFiles, uploading, pausedUP, queuedUP, stalledUP, checkingUP, forcedUP, allocating, downloading, metaDL, pausedDL, queuedDL, stalledDL, checkingDL, forcedDL, checkingResumeData, moving, unknown`.
- **Impact (display only):** `forcedDL` → queued (should be downloading), `forcedUP` → queued (should be completed/seeding), `stoppedUP` → queued (should be paused; the code handles `stoppedDL` only). `checking*` / `allocating` / `moving` → queued is acceptable. **Correction:** add `forcedDL` to downloading, `forcedUP` to completed, `stoppedUP` to paused. Also `eta`: the wiki shows `eta: 8640000` means "unknown" — the code displays that raw; treat 8640000 as unknown.

### M4 — Transmission speaks the deprecated pre-4.1 RPC protocol
- **File:** `lib/data/api/transmission_client.dart` (method names `torrent-get`, `session-get`, `torrent-add`, …, old camelCase field names `totalSize`, `percentDone`, …, success check `data['result'] == 'success'`).
- **What the docs say:** rpc-spec.md (main branch): "Transmission 4.1.0 (`rpc_version_semver` 6.0.0) added support for the JSON-RPC 2.0 protocol and converted all RPC strings to snake_case. The old bespoke RPC protocol, and the old mix of kebab-case and camelCase strings, are still supported in Transmission 4 but are deprecated and will be removed in the future." Source: https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md.
- **Impact:** works today on Transmission 4.x; will break on a future Transmission 5. **Correction (later, not urgent):** migrate to JSON-RPC 2.0 (`{"jsonrpc":"2.0","method":"torrent_get","params":{...}}`, result object instead of `{"result":"success","arguments":{...}}`) and rename all field names to snake_case (`total_size`, `percent_done`, …).

### M5 — Transmission status 3 (download-wait) shown as downloading; 1/2 (checking) shown as queued
- **File:** `lib/data/api/transmission_client.dart:200-209`. Status enum per spec (`tr_torrent_activity`): 0 stopped, 1 check-wait, 2 check, 3 download-wait, 4 download, 5 seed-wait, 6 seed.
- **Impact (cosmetic):** status 3 is queued for a download slot, not downloading; 1/2 are verifying, not queued. **Correction:** map 3 → queued, 1/2 → a checking state (or queued with a "verifying" label if the UI gains one).

### M6 — qBittorrent `torrents/add` sent as form-urlencoded; the wiki example is multipart/form-data
- **File:** `lib/data/api/qbittorrent_client.dart:192-210` (`addMagnet()` posts `{'urls': …, 'savepath': …}` with `formUrlEncodedContentType`).
- **What the docs say:** the wiki's "Add new torrent" example posts `multipart/form-data` with `urls` (newline-separated) and `savepath`. The params themselves (`urls`, `savepath`) are correct; only the encoding differs, and qB's form handling accepts urlencoded fields for other endpoints (its `addTrackers` example is urlencoded).
- **Impact:** unproven either way from the docs alone. **Correction:** after fixing B1, live-test an add; if it fails, switch `addMagnet` to multipart/form-data. Marked unverifiable from docs (see below).

### M7 — Emby HLS transcode URL omits `MediaSourceId`
- **File:** `lib/data/api/emby_client.dart:496-534` (`transcodeUrl()` builds `/Videos/{id}/master.m3u8?api_key=…&VideoCodec=…&AudioCodec=…`).
- **What the docs say:** `GET /Videos/{Id}/master.m3u8` exists (probed 401) and accepts `MediaSourceId` among its parameters.
- **Impact:** for items with multiple media sources the server picks the default source, which may differ from the source chosen by `getPlaybackInfo`. **Correction:** pass `MediaSourceId` from the selected `MediaSourceInfo` when present. Minor.

## Verified correct (do not touch in the fix phase)

### Subsonic / Navidrome — 15 calls
- Auth: `t = md5(password + salt)`, 12-hex-char salt (≥6 required), `u/t/s/c/v/f=json`, `v=1.16.1` — matches Navidrome 0.62's API version 1.16.1 (subsonic.org/api.jsp; Navidrome DeepWiki "API Version: 1.16.1").
- `ping`, `getAlbumList2` (`type`/`size`/`offset`; `newest` is a valid type), `search3` (`query` only; counts default 20/20/20), `getArtists`, `getArtist`, `getAlbum`, `getSong`, `getStarred2`, `star`/`unstar` (`id` for songs, `albumId` for albums, `artistId` for artists — exactly per doc), `getPlaylists`, `getPlaylist`, `getGenres`, `getCoverArt` (`id`/`size`), `stream` (`id`/`maxBitRate`) — paths, params and response keys (`subsonic-response`, `albumList2.album`, `searchResult3.{song,album,artist}`, `artists.index[].artist`, `album.song`, `starred2.{song,album}`, `playlists.playlist`, `playlist.entry`) all match the Subsonic API reference (https://www.subsonic.org/pages/api.jsp).
- **`.view` suffix NOT required (live probe, 2026-11-12):** `GET https://sg.kass.qzz.io/rest/ping?v=1.16.1&c=yinghui&f=json` (no `.view`) → HTTP 200 with the standard Subsonic error JSON (`code 10 missing parameter: 'u'`), identical to `rest/ping.view`; same for `rest/getAlbumList2`. The code's `rest/<endpoint>` paths are fine against Navidrome 0.62.
- Base-URL/subpath joining (trailing-slash `rest/…` resolution) and the `_asList` single-object-vs-list handling are correct.
- Notes (not bugs): `getGenres` reads `g['value'] ?? g['name']` — Navidrome returns genre objects with `value`; and no repository currently calls `getGenres`, so it has no load-path impact. `search3` sends no counts — server defaults (20/20/20) apply.

### Emby — 13 calls
- `Users/AuthenticateByName` shape (`Username`/`Pw` → `AccessToken`) — correct, but see B2 (never called).
- `Users/Me` → `Id`; `Users/{uid}/Views`; `Users/{uid}/Items/Resume` (`Limit`/`Recursive`/`Fields`/`IncludeItemTypes=Movie,Episode`); `Users/{uid}/Items/{id}` (`Fields: Overview,People,MediaStreams,Genres,Studios`); `Shows/{id}/Seasons` (`UserId`/`Fields`); `Shows/{id}/Episodes` (`UserId`/`Recursive`/`Fields`/`SeasonId`); `Items/{id}/PlaybackInfo` POST (`UserId`, `MaxStreamingBitrate`, `MaxStaticBitrate`); `MediaSources`/`MediaStreams` parsing (`VideoStream.Width/Height`, `Bitrate`, `SupportsDirectPlay/Stream`, `TranscodingUrl`, per-stream `Channels`/`SampleRate`/`FrameRate`/`IsDefault`/`IsForced`/`IsExternal`/`DisplayTitle`); `GET /Items` with `UserId` (top-level form; the doc's canonical form is `/Users/{id}/Items` — the top-level route exists, probed 401); `Videos/{id}/stream?api_key=`; `Videos/{id}/master.m3u8`; subtitle URL **with** MediaSourceId (`/Videos/{id}/{ms}/Subtitles/{i}/Stream.srt` per dev.emby.media Subtitles doc); `Users/{uid}/PlayedItems/{id}`; image URLs `/Items/{id}/Images/{Primary,Backdrop}?api_key=`; `UserData.PlaybackPositionTicks`/`PlayedPercentage` resume parsing; ticks math (`position.inMicroseconds * 10` = 100ns ticks) — all verified against dev.emby.media and by unauthenticated route probes on Emby 4.8.10.0 (every route above returned 401 = exists, auth required; only the two B4 paths returned 404).
- `getAudioItems` (`Items?IncludeItemTypes=Audio`, `AlbumArtist` string field) and `audioUniversalUrl` (`/Audio/{id}/universal`) are correct but **unused** — Emby audio is not wired into the Music tab (known, pre-existing).

### qBittorrent — 8 calls
- `auth/login` (form `username`/`password`, SID cookie from `Set-Cookie`) — correct except B1's body check. `app/version`, `app/webapiVersion`; `torrents/info` — every field read (`state`, `hash`, `name`, `progress`, `dlspeed`, `size`, `completed`, `eta`, `save_path`) matches the wiki's response table; `torrents/add` params (`urls`, `savepath`) correct (see M6 for encoding); `torrents/pause|resume|delete` (`hashes` `|`-joined, `deleteFiles`) correct; subpath-preserving base URL (`https://host/qb/` + relative `api/v2/…`); 403 probe → `needsAuth` (not unreachable) is the right distinction.

### Transmission — 7 calls
- `session-get` (incl. `version` field for the version display), `torrent-get` fields (`id`, `name`, `status`, `percentDone`, `rateDownload`, `totalSize`, `downloadedEver`, `eta`, `downloadDir`, `hashString`) — all valid old-protocol field names; `torrent-add` (`filename` = magnet/URL, `download-dir`; response `torrent-added`/`torrent-duplicate` with `id`); `torrent-start`/`torrent-stop`; `torrent-remove` (`delete-local-data`); `torrent-set-location` (`ids`/`location`/`move`); 409 `X-Transmission-Session-Id` retry; HTTP Basic auth. (Protocol deprecation: see M4.)

### aria2 — 8 calls
- JSON-RPC 2.0 envelope (`{"jsonrpc":"2.0","id":…,"method":…,"params":[…]}`, POST `jsonrpc`); `token:` secret as first param; `tellActive` (no params), `tellWaiting(0,100)`, `tellStopped(0,100)`, `tellStatus(gid)`, `addUri([uri], {dir})`, `pause`/`unpause`/`remove` (return gid), `removeDownloadResult` for completed/failed, `getVersion` → `result.version`. String-number parsing (`totalLength`, `completedLength`, `downloadSpeed`, `files[].path`) is correct per the manual (https://aria2.github.io/manual/en/html/aria2c.html). (Status mapping gap: see M2.)

## What could NOT be verified
- **qB `torrents/add` encoding (M6):** the wiki example is multipart; urlencoded acceptance could not be confirmed from the docs. Needs a live test after B1 is fixed.
- **Transmission / aria2 against real servers:** no Transmission or aria2 server address was ever given, so no live route probe was possible for those two services; their findings rest on the official docs only.
- **Why `/System/Info` (and audio/image routes) answer unauthenticated on yang's Emby** (B3): observed 200s, cause unknown (server setting vs proxy). The recommended fix (validate via `/Users/Me`) works regardless.
- **No authenticated end-to-end test was possible for any service** — no credentials were ever provided in chat. All "verified correct" judgements above are doc + unauthenticated-route checks, not logged-in behaviour. The fix phase should re-run the load paths with real credentials on device.

## Sources
- Subsonic API reference: https://www.subsonic.org/pages/api.jsp
- Navidrome Subsonic API (API version 1.16.1, OpenSubsonic): https://deepwiki.com/navidrome/navidrome/4.1-subsonic-api-endpoints
- Emby developer docs — Browsing the Library: https://dev.emby.media/doc/restapi/Browsing-the-Library.html
- Emby developer docs — Playback Check-ins: https://betadev.emby.media/doc/restapi/Playback-Check-ins.html
- Emby developer docs — Subtitles: https://dev.emby.media/doc/restapi/Subtitles.html
- Emby OpenAPI-derived client (PlaystateService, SubtitleService): https://github.com/AkimioJR/emby-go/blob/HEAD/api/docs/PlaystateServiceAPI.md and https://pypi.org/project/EmbyServerAPI/
- qBittorrent WebUI API (qBittorrent 4.1): https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)
- Transmission RPC spec (main): https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md
- aria2 manual, RPC Interface: https://aria2.github.io/manual/en/html/aria2c.html
- Live probes 2026-11-12 (unauthenticated, read-only): Navidrome `https://sg.kass.qzz.io/rest/ping` and `rest/getAlbumList2` with/without `.view`; Emby `https://cf.imetyou.top` route table (`/System/Info` 200, `/System/Info/Public` 200, `/Users/Me` 401, `/Items` 401, `/Users/x/Views` 401, `/Users/x/Items/Resume` 401, `/Users/x/Items/abc` 401, `/Shows/abc/Seasons` 401, `/Shows/abc/Episodes` 401, `/Videos/abc/stream` 401, `/Videos/abc/master.m3u8` 401, `POST /Items/abc/PlaybackInfo` 401, `POST /Users/x/PlayedItems/abc` 401, `POST /Sessions/Playing/Progress` 401, `POST /Users/x/PlayingItems/abc/Progress` 404, `POST /Users/x/Items/abc/PlayingItems/abc/Progress` 404, `/Videos/abc/Subtitles/0/Stream.srt` 404, `/Videos/abc/ms/Subtitles/0/Stream.srt` 401, `/Items/abc/Images/Primary` 200, `/Audio/abc/stream` 200, `/Audio/abc/universal` 200).

## Suggested fix order (for the fix phase, not done here)
1. B1 (qB `"Ok."`) — one-line fix, unblocks the entire qB download queue.
2. B2 + B3 (Emby login path + token validation via `/Users/Me`) — unblocks the whole Video tab; do together since both are the Emby auth flow.
3. X-1 (surface auth failures instead of empty lists) — makes every future auth bug visible instead of silent.
4. B4 (progress → `/Sessions/Playing*`) — restores resume / Continue Watching.
5. M1, M2, M3, M5, M7 (small mappings), then M4 (Transmission JSON-RPC 2.0 migration, later).
