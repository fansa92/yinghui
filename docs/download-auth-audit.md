# 下载认证审计 — Download Auth Audit

Read-only diagnosis, 2026-11-14. No source files edited. All line numbers refer to
`~/workspace/yinghui` at commit `59b9f42` (v0.2 + shuffle/repeat batch).

Background (verified, not assumed): qB 5.x login returns 204 No Content +
`Set-Cookie: SID=...` (fixed in `7ec106e`); the Downloads page once showed a raw
Dio 403 dump for `torrents/info` (fixed in `e4762e7`: login fails fast when no
SID is captured; `_withRelogin` retries on any 403 once; per-server errors are
short friendly text). A live curl test on 2026-11-12 proved the user's qB
credentials log in fine (204 + SID, `torrents/info` → `[]`).

## Ranked findings

| # | Finding | Impact | Fix scope | Effort |
|---|---------|--------|-----------|--------|
| 1 | Wrong-credential polling hammers login every 5 s — can get the IP banned, never backs off | Real harm | Stop polling a server after N consecutive auth failures; manual 重新登录 action | Medium |
| 2 | 401 (wrong password) and 403 (expired session) are indistinguishable everywhere | User confusion | Distinct messages per status | Easy |
| 3 | Login-first design + fail-fast SID check assumes every qB sets a SID cookie; no-auth servers untested | Potential permanent breakage for no-auth setups | Lazy auth: call first, login only on 403 | Medium |
| 4 | No login mutex: concurrent login() calls race and can null the SID mid-flight | Spurious 403s, duplicate logins | In-flight login future / mutex in the client | Medium |
| 5 | Port-only server edits don't rebuild the cached client (fingerprint omits port) | Talks to the old port until restart | Add port to the client-cache fingerprint | Easy |
| 6 | Probe path and live path are two different logins | Servers "在线" while Downloads says "登录已过期" | Share/warm the session, or re-test via the cached client | Easy–Medium |
| 7 | aria2 / Transmission auth errors misreported in live use ("服务器返回 HTTP 200") | Wrong-secret looks like a server bug | Map JSON-RPC auth errors to 401 in friendlyError/clients | Easy–Medium |
| 8 | Downloads error state has no action (no 重新登录 / 去服务器页 button) | User stuck with red text | Add per-error retry + Servers link | Easy |
| 9 | Transmission password silently dropped when username is empty | Silent misconfig | Send Basic when either field is set; warn on empty username | Easy |
| 10 | Credential load timing: store loads fire-and-forget; secure-storage failure → empty token, silent | Brief wrong empty state; misleading 401 | Await store load before first paint; surface token-read failure | Easy |
| 11 | Fake demo tasks leak into Home when no credentials exist | Demo data shown as real downloads | Guard Home row with hasCredentials / stop filling fake tasks | Easy |

**Single most valuable first fix: #1 — auth-failure backoff with a manual
重新登录 action.** It is the only finding that can make a working setup worse
over time (a wrong password today can become an IP ban tomorrow), and it
also delivers #2's distinct messages and #8's recovery action in the same
pass. After that, #3 (lazy auth) is the biggest structural win.

---

## 1. qB auth lifecycle (end-to-end trace)

### The happy path (works)

- `QbittorrentClient.login()` — `lib/data/api/qbittorrent_client.dart:75-110`:
  POST `api/v2/auth/login` (form-encoded `username`/`password`), parses
  `Set-Cookie` for `SID=([^;]+)`, accepts empty body / `Ok.` / `Ok` (qB 5.x
  204 / qB 4.x 200). Since `e4762e7`, a 2xx with **no SID captured throws
  401** ("server did not return a session (SID)") instead of letting every
  later call 403.
- `_ensureLogin()` (`:166-168`): logs in only when `_sid == null`.
- `_withRelogin()` (`:174-192`): on `ApiException` 403, clears `_sid`,
  logs in once, retries the call once (retry not wrapped — no loop).
- `_cookieHeader` (`:63-64`): `Cookie: SID=<sid>` per request; empty when
  no SID. Dio has no cookie jar — this manual header is the whole session
  mechanism, and it is correct for a single cookie.
- Client cache — `lib/data/repositories/download_repository.dart:107-128`:
  one client per server id, cached across calls, rebuilt when the
  fingerprint (`type|host|username|token`) changes. The SID therefore
  **survives poll ticks and tab switches** (the repo is created once in
  `_YingHuiAppState.initState`, `lib/main.dart:78-83`, and lives for the
  app lifetime). Only an app restart loses the SID — the first poll then
  pays one extra login round-trip, which is correct behaviour (SIDs are
  server-side sessions; persisting them would be wrong).
- Login and data calls share one Dio `baseUrl` (relative `api/v2/...`
  paths), so the `/qb/` subpath is consistent between login and
  `torrents/info`. No subpath mismatch exists.

### SID capture edge cases (checked, mostly fine)

- Multiple `Set-Cookie` headers: `response.headers['set-cookie']` returns
  all values; the loop (`:83-86`) handles them. Dio lowercases header
  names, so the `'set-cookie'` lookup works.
- Cookie attributes (`Path=/; HttpOnly`): the regex `SID=([^;]+)` stops at
  the first `;` — correct.
- Empty SID (`SID=`): the regex requires 1+ chars, so it does not match
  and the fail-fast 401 fires — correct.
- Stale SID retained: `login()` never clears a previous `_sid` when the
  new login returns no cookie. In the retry path `_withRelogin` clears it
  first (`:185`), so the hole is only reachable from `testConnectionResult`
  (`:117-124`), which calls `login()` on a client that may already hold a
  stale SID. Minor; the fix is one line (`_sid = null` at the top of
  `login()`).

### Finding #1 — wrong-credential polling hammers login, no backoff (HIGH)

`RealDownloadRepository.startPolling` (`download_repository.dart:642-651`)
fires `refresh()` every 5 s (default). Every tick with bad credentials runs
`torrentsInfo → _ensureLogin → login()` → 401, forever. Consequences:

- qB's WebUI has a built-in "ban IP after N failed login attempts"
  option (default 5 failures). A wrong password therefore escalates from
  a 401 problem into a **403 IP ban**, after which even the correct
  password fails until the ban expires. The app is the thing doing the
  hammering, every 5 s, with no backoff and no stop.
- Each tick is a wasted round-trip and a fresh red error line; the user
  has no way to pause it short of leaving the tab (polling stops on tab
  switch, `downloads_page.dart` `didUpdateWidget`, but restarts on
  return).
- Fix: count consecutive auth failures per server in the repo; after N
  (e.g. 3) stop polling that server, keep the last error visible, and
  offer a manual 重新登录 action (which clears the counter and retries
  once). Resume automatically when the server's credentials change
  (the fingerprint already rebuilds the client — hook the counter reset
  there). Medium effort.

### Finding #2 — 401 vs 403 are conflated in every surface (MEDIUM)

- `RealDownloadRepository.friendlyError` (`download_repository.dart:363-372`)
  maps **both** 401 and 403 to one string: `登录已过期或账号不对，请在服务器页重新测试连接`.
- The Servers-page qB probe (`qbittorrent_client.dart:130-142`) also
  collapses a login failure into the same `needsAuth` message
  (`服务器可达，需要登录（HTTP 403）`) — a wrong password and "not logged
  in yet" look identical there too.
- The user therefore cannot tell "your password is wrong" from "your
  session expired" from "you never logged in". Fix: 401 →
  `用户名或密码错误，请检查账号`; 403 after a failed retry → `登录已过期，重新登录失败，请重新测试连接`;
  keep a distinct "needs login" only for the never-logged-in case. Easy.

### Finding #3 — login-first + fail-fast SID check assumes a SID always exists (MEDIUM)

- `torrentsInfo()` (and every qB mutating call) runs `_ensureLogin()`
  **before** any data call (`qbittorrent_client.dart:196`). A server
  that needs no auth is still forced through login.
- `login()` throws 401 when the server answers 2xx without a SID cookie
  (`:99`). That assumption is verified for auth-enabled qB 5.2.1
  (live curl test) but **unverified for an auth-disabled qB**: the probe
  path (`testConnectionResult`, `:104-113`) proves a no-auth server with
  a bare 200 on `app/version` and never logs in — while the live path
  insists on login. If a no-auth qB answers login without `Set-Cookie`,
  Downloads is permanently broken ("登录已过期或账号不对") while Servers
  says "在线". The two paths disagree by design.
- Fix (medium, structural): lazy auth — try the data call first, call
  `login()` only when it answers 403. This removes the SID assumption
  entirely, handles no-auth servers naturally, and saves one round-trip
  on every cold start. Alternative: verify live against a no-auth qB
  and keep login-first; lazy auth is the better fix.

### Finding #4 — no login mutex; concurrent calls race on `_sid` (MEDIUM)

- `refresh()` coalesces overlapping refreshes (`download_repository.dart:333-352`),
  but `addTask`, `pauseTask`/`resumeTask`/`deleteTask` call the cached
  client **directly** (`:468-475`, `:554-604`), bypassing that lock. A
  poll tick and a user action can therefore run on the same
  `QbittorrentClient` concurrently.
- `_sid` is plain mutable state with no guard: if tick A gets a 403,
  `_withRelogin` sets `_sid = null` and awaits `login()`; meanwhile
  action B reads `_cookieHeader` with `_sid == null`, sends **no**
  cookie, gets its own 403, and starts a second concurrent `login()`.
  Both logins usually succeed (qB issues independent SIDs; last write
  wins), so the failure mode is spurious 403s and duplicate logins
  rather than corruption — but it is a real race, and it is the most
  likely explanation for any intermittent 403 that "fixes itself on the
  next tick".
- Fix: hold a single in-flight login `Future` in the client (or a mutex
  around `_ensureLogin` + the `_sid = null` + `login()` sequence in
  `_withRelogin`); concurrent callers await the same login. Medium.

### Finding #5 — port-only edits don't rebuild the cached client (MEDIUM)

- `_cachedClient` fingerprint (`download_repository.dart:115-116`) is
  `type|host|username|token` — **`port` is missing**. Editing only a
  server's port in the Servers page leaves the fingerprint unchanged, so
  the stale client (old `baseUrl`, old port — `Server.baseUrl`,
  `lib/core/models/server.dart:77-82`, builds `http://host:port` for bare
  hosts) is reused until the app restarts. The user sees "无法连接" after
  fixing a port, with no indication the app is still dialling the old
  one. Fix: add `port` (and, for completeness, nothing else is needed —
  `host` already covers host/subpath changes). One line. Easy.

### Finding #6 — probe login and live login are two different logins (LOW–MEDIUM)

- `ApiClientFactory.testConnection` (`lib/data/api/api_client_factory.dart:14-27`)
  constructs a **fresh client on every call**. The Servers page "测试连接"
  success therefore never warms the Downloads page's cached client SID:
  the next poll still has to log in itself. Worse, the two paths can
  disagree — probe says "在线" (fresh login works) while Downloads says
  "登录已过期" (cached client holds a revoked SID, or vice versa).
- Fix: run the Servers-page test through the repo's cached client (or
  share the client cache with the store), so a successful test also
  establishes the live session. Easy–medium.

### Finding #8 — Downloads error state has no action (LOW)

- Errors render as plain red text lines (`downloads_page.dart`, the
  `repo.errors.values` block) with no button. There is no per-server
  重新登录, no retry button, and no link to the Servers page — the
  "去服务器页" action exists only in the **no-credentials** empty state.
  The error text itself says "请在服务器页重新测试连接" but offers no way
  to get there. Recovery today is pull-to-refresh or waiting for the
  next tick. Fix: put a 重新登录 / 去服务器页 action next to each error
  line. Easy. (Pairs with finding #1.)

### Finding #10 — credential load timing (LOW)

- `_store.load()` is fire-and-forget in `main.dart:102` (not awaited).
  The Downloads page can paint "还没有下载器账号" before the store
  finishes loading; it self-heals via the `_onStoreChanged` listener
  (`downloads_page.dart`, which refreshes when credentials appear), so
  this is a brief wrong empty state, not a stuck one.
- A per-row secure-storage read failure is swallowed into an empty
  token (`server_store.dart:104-113`, `debugPrint` only). The server
  then loads with no password and every login 401s as "账号不对" — the
  real cause (keychain unreadable) is invisible. Fix: await store load
  before first paint (or show a loading state), and surface a token-read
  failure distinctly. Easy.

---

## 2. Transmission auth

- Stateless HTTP Basic Auth on **every** call (`transmission_client.dart:100-110`):
  `Authorization: Basic base64(user:pass)` when `username` is non-empty.
  No session, no login step, no expiry — nothing to re-authenticate.
- 409 `X-Transmission-Session-Id` retry (`:73-104`): the session id is
  learned from a 409 and stored on the client instance; the client is
  cached per server, so it survives poll ticks. A daemon restart
  invalidates it and the next call re-learns it via a fresh 409 — handled.
- 401 mapping is good at the probe level: `testConnectionResult`
  (`:141-158`) returns `needsAuth` with `需要登录` (no username) or
  `用户名或密码错误` (username set). But in live use the same 401 goes
  through `friendlyError` and becomes the generic "登录已过期或账号不对"
  (finding #2 applies here too).
- Finding #9 — password silently dropped when username is empty: `_postOnce`
  only adds the `Authorization` header if `server.username.isNotEmpty`
  (`:107-110`). A user who sets only a password gets no auth header at
  all and a confusing 401. Fix: send Basic when **either** field is set,
  and/or warn in the form. Easy. (Transmission with auth disabled works
  fine — no header is sent, as intended.)
- Finding #7 (part 2) — JSON-RPC errors ride on HTTP 200 (see §4).

## 3. aria2 auth

- Secret sent as the first JSON-RPC param with the `token:` prefix
  (`aria2_client.dart:44-53`); a pasted `token:` prefix is not doubled
  (already fixed). Wrong/missing secret → JSON-RPC
  `{"code":1,"message":"Unauthorized"}`.
- Probe mapping is good: `testConnectionResult` (`:102-119`) returns
  `needsAuth` with `需要 RPC 密钥` (no secret) or `RPC 密钥错误` (wrong
  secret).
- Finding #7 (part 1) — **live-use auth errors are misreported**:
  `rpc()` (`:59-91`) throws `ApiException` with
  `statusCode: response.statusCode` — but a JSON-RPC error still comes
  back **HTTP 200**, so `friendlyError` (`download_repository.dart:361-363`)
  falls into `服务器返回 HTTP 200` for a wrong secret. The Servers page
  says "RPC 密钥错误"; the Downloads page says "服务器返回 HTTP 200" for
  the same condition. Fix: map the JSON-RPC `Unauthorized` error to
  status 401 in the client (or teach `friendlyError` to recognise it by
  message — the client mapping is cleaner). Easy–medium.
- Secret rotation on the server: the client keeps sending the stored
  secret; editing the server rebuilds the client via the fingerprint, so
  a corrected secret takes effect on the next poll. No re-auth path is
  needed (the secret is sent per call, like Transmission Basic).
- `tellAll()` (`:145-152`) runs `tellActive` → `tellWaiting` →
  `tellStopped` sequentially; an auth error in the first call aborts the
  rest — fine, the error is what matters.

## 4. Cross-cutting: how auth errors are classified

`ApiException` (`lib/core/errors.dart`) carries `statusCode` = the **HTTP**
status, or null for transport errors. That works for qB and Transmission
(HTTP 401/403/409 are real), but **not for aria2/Transmission JSON-RPC
errors, which arrive as HTTP 200 with an `error` object**:

- aria2 wrong secret → HTTP 200 + `{"code":1,"message":"Unauthorized"}` →
  shown as "服务器返回 HTTP 200" in live use.
- Transmission JSON-RPC error (e.g. bad params) → HTTP 200 + `error` →
  `ApiException('Transmission error: ...', statusCode: 200)` →
  also "服务器返回 HTTP 200".

Fix (finding #7): give JSON-RPC auth failures a synthetic 401 at the
client layer (`aria2_client.dart` `rpc()` when `error.message ==
'Unauthorized'`; `transmission_client.dart` `_postOnce` has no
auth-specific JSON-RPC error today — a 401 there is already HTTP-level,
so only aria2 needs the mapping, plus a `friendlyError` fallback for
message-based auth errors). Then findings #2's distinct messages apply
uniformly to all three downloaders.

## 5. UX of auth states (what the user sees today)

| State | Downloads page | Servers page |
|---|---|---|
| Never logged in / no credentials | Empty state "还没有下载器账号" + 去服务器页 button | Grey dot, "未测试" |
| Session expired (qB 403) | Red line "登录已过期或账号不对…" (auto re-login usually recovers silently) | Amber "需要登录" only after a manual test |
| Wrong password (qB/Transmission 401) | Same red line as expired session — indistinguishable (#2); retried every 5 s (#1) | Same "需要登录" as not-logged-in — indistinguishable (#2) |
| Wrong aria2 secret | Red line "服务器返回 HTTP 200" — wrong message (#7) | Correct "RPC 密钥错误" |
| Server unreachable | Red line "无法连接，请检查网络和服务器地址" | Red dot, "无法连接" |
| Auth disabled (no-auth qB/Transmission/aria2) | Works for Transmission/aria2; **qB untested** — live path insists on login (#3) | Probe says "在线" without login |
| Port changed | Keeps dialling the old port until restart (#5) | Row still shows the new port — the display and the client disagree |

Confusing or silent states: wrong-password vs expired-session (#2), the
aria2 HTTP-200 message (#7), and the no-auth qB case (#3). Nothing is
fully silent — every failure surfaces as a red line — but the lines do not
say what is actually wrong and offer no action (#8).

## 6. Secondary finding — fake demo tasks leak into Home

`_refreshOnce` (`download_repository.dart:373-381`) fills `_tasks` with
`FakeDownloadRepo.tasks()` when there is no usable downloader. The
Downloads page guards on `hasCredentials` and shows its empty state, so
the fakes never render there — but Home reads the **same shared repo**
without that guard (`home_page.dart:180,236`: `if (downloading.isNotEmpty)`
shows `downloading.first` as "进行中的下载"). After the Downloads tab has
refreshed once with no credentials, Home shows the fake "Ubuntu 24.04
LTS.iso" as a real in-progress download. Fix: guard the Home row with
`hasCredentials`, or stop filling fake tasks into the shared list. Easy.
(Not auth, but found while tracing the shared repo's auth-adjacent state.)

## Explicitly NOT worth doing

- **Persisting the qB SID across restarts.** SIDs are server-side
  sessions that expire; the first poll after a restart re-logs in with
  one extra round-trip. Persisting buys nothing and risks sending a dead
  SID that 403s on first paint.
- **A Dio cookie jar / CookieManager.** The manual `Cookie: SID=...`
  header is the entire session mechanism and it works; a jar adds a
  dependency and a second source of truth for one cookie.
- **A SID refresh timer / proactive re-login.** 403-triggered re-login
  is the correct trigger; a timer would just add login traffic for
  sessions that are still valid.
