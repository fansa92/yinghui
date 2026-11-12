# 播放失败诊断 — 视频和音频都不能播放

日期：2026-11-12。用户报告（18:34）：“视频播放器和音频播放器不能播放”。
诊断方式：只读代码核查 + 官方文档对照 + **已发布 v0.1.2 APK 实物检查**。未改任何源码。

## 结论先说

**根本原因只有一个，且已实证：App 里根本没有原生 libmpv。** 音频和视频都走同一个 media_kit Player，播放器在第一次播放时就初始化失败。修法也是一个：`pubspec.yaml` 加 `media_kit_libs_video: ^1.0.7`，重新完整打包发版。

---

## 原因排名

### 1. 缺少 `media_kit_libs_video`，APK 里没有 libmpv.so

- **证据 1 — pubspec：** `pubspec.yaml:21-23` 只有 `media_kit: ^1.2.0` 和 `media_kit_video: ^1.2.0`，没有任何 `media_kit_libs_*`。`pubspec.lock`（147 个包）和本地 pub 缓存里也没有任何 `media_kit_libs_*` 包。
- **证据 2 — media_kit 1.2.6 本身是纯 Dart：** 该包目录下没有 `android/`、`ios/` 等原生目录；其 README 的 Installation 一节明确要求 app 另加原生库：
- 视频：`media_kit_libs_video: ^1.0.7`（说明：视频和音频都需要时就选 video 库；video 和 audio 库不能混用）
- 纯音频才用 `media_kit_libs_audio: ^1.0.7`
- **证据 3 — 已发布 v0.1.2 的 arm64 APK 实物检查**（从 GitHub Release 下载后 `unzip -l`）：APK 里一共 5 个 `.so`——`libapp.so`、`libdartjni.so`、`libdatastore_shared_counter.so`、`libflutter.so`、`libsqlite3.so`，**没有 `libmpv.so`**。
- **失败链（文件+行号）：**
1. `lib/features/player/player_service.dart:39`（音频）与 `lib/features/player/video_player_service.dart:41`（视频）的 backend 构造函数都调 `MediaKit.ensureInitialized()`。
2. media_kit 1.2.6 的 `ensureInitialized()`（`lib/src/media_kit.dart:23`）→ `nativeEnsureInitialized()`（`lib/src/player/native/player/real.dart:43`）→ `NativeLibrary.ensureInitialized()`（`lib/src/player/native/core/native_library.dart`）→ `DynamicLibrary.open('libmpv.so')`（Android 默认名）。
3. APK 里没有这个文件，`DynamicLibrary.open` 抛错，`ensureInitialized` 打印一长串 `media_kit: ERROR: MediaKit.ensureInitialized` 后**把异常重新抛出**。
4. 所以第一次点播放时，`_ensureBackend()` 里直接抛错，`open(url)` 根本没执行到。
- **为什么 App 能正常打开、能浏览内容：** `lib/main.dart` 只调了 `WidgetsFlutterBinding.ensureInitialized()`，从不在启动时初始化 media_kit；backend 是懒创建的（`player_service.dart` 注释也写了“app boots without native libs”）。浏览列表走的是 Dio，与播放器无关。
- **为什么两个播放器一起坏：** 音频和视频共用同一个 media_kit Player / 同一套初始化，libmpv 缺失对两者是同一次失败。
- **与平台无关：** Android、iOS、macOS、Windows、Linux 都需要 `media_kit_libs_video` 这个包（它会拉起各平台对应的 `media_kit_libs_*_video`）；用户在哪个设备上都会复现。
- **修法：** `pubspec.yaml` 的 dependencies 加 `media_kit_libs_video: ^1.0.7`，`flutter pub get`，**完整重新打包**（原生插件加进来后 hot reload / hot restart 不够，必须全新构建），随新版本发布。发版后可用同样方法验证：解包 APK 确认 `lib/arm64-v8a/libmpv.so` 存在。
- **用户侧确认方法：** 打开任意一个视频，页面应显示 `无法播放：Exception: Cannot find libmpv.so. Please ensure it's presence in the APK.`（见原因 2 视频有错误显示）。如果看到这行字，诊断在真机上也确认了。

### 2. 音频播放失败是静默的，没有任何错误提示

- `PlayerService._openCurrent()`（`player_service.dart:204-227`）没有任何 try/catch；`playQueue` / `togglePlay` / `next` / `previous` 抛出的异常直接向上传。
- 所有调用点都是 fire-and-forget，不 await 也不 catch：`lib/features/music/music_page.dart:363,541`、`album_detail_page.dart:185,241`、`track_list_page.dart:44,79`、`home_page.dart:147`，迷你播放器 `mini_player.dart:124` 直接把 `player.togglePlay` 当 `onPressed`。
- 结果：点播放后什么都不发生——按钮还是播放态、进度停在 0:00、没有任何提示。这正是“不能播放”在音频侧的表现。
- 视频侧相反：`video_player_page.dart:165-211` 的 `_open()` 有 try/catch，出错会进 `_error`，build 里 `_errorView()`（`:510-527`）显示 `无法播放：\n$_error`。
- 修法方向（在修原因 1 的同时顺手做）：`PlayerService` 捕获 backend 异常并暴露错误状态（或弹提示），别让音频失败继续静默。

### 3. PlaybackCoordinator 不可能自己暂停自己

- `lib/features/player/playback_coordinator.dart:50-58`：`musicStarted()` 只 pause `_video`，`videoStarted()` 只 pause `_music`。`PlayerService.playQueue` / `togglePlay` 里 `musicStarted()` 在 `open` 之后、`play()` 之前调，`VideoPlayerService.open` 里 `videoStarted()` 同理。没有一条路径会 pause 刚打开的自己。

### 4. 播放 URL 本身有问题（待原因 1 修好后复核）

以下几项都已逐项核对无误，单独列在“已验证正确”里。但它们有个共同点：**在 libmpv 缺失的情况下根本走不到这一步**，所以即使 URL 有问题，现在也看不出来。修好原因 1 后若仍有单个视频/音频放不出，再按这条线查（尤其注意：Cloudflare/Caddy 前置代理对 libmpv 的 HTTP Range 请求是否友好；以及个别 mkv/hevc 走 HLS 转码是否正常）。

---

## 逐路追踪

### 音频（Navidrome → 迷你播放器 / 正在播放页）

1. `SubsonicClient.streamUrl()`（`lib/data/api/subsonic_client.dart:338-355`）：URL 自带鉴权参数 `u/t/s/c/v/f` + `id`，全部 `Uri.encodeQueryComponent` 编码，形如 `https://host/rest/stream?u=…&t=…&s=…&c=YingHui&v=1.16.1&f=json&id=…`。**正确。**
2. `RealMusicRepository.streamUrlFor()`（`lib/data/repositories/music_repository.dart:390-395`）：按 track 的 serverId 找到对应服务器，找不到才返回空串。**正确。**
3. `PlayerService.playQueue()`（`player_service.dart:269-284`）→ `_openCurrent()`（`:204-227`）→ `_ensureBackend().open(url)` → `MediaKitPlayerBackend.open()`（`:104`）→ `_player.open(Media(url))`。**死在 `_ensureBackend()` 创建 backend 那一步**（见原因 1），`open` 未执行。
4. 失败无任何提示（见原因 2）。

### 视频（Emby → 视频播放页）

1. `VideoPlayerPage._open()`（`lib/features/player/video_player_page.dart:158-211`）→ `repo.decidePlayback()` → `VideoPlayerService.open()`（`video_player_service.dart:182-200`）→ `_ensureBackend()` → 同样死在 `MediaKit.ensureInitialized()`（原因 1）。`_open()` 的 catch 会把异常变成页面上的 `无法播放：…`（`:209, 510-527`）。
2. URL 构造本身**正确**：
- 直接播放 `EmbyClient.videoStreamUrl()`（`lib/data/api/emby_client.dart:283-297`）：`/Videos/{id}/stream?api_key=…`，api_key 在 URL 里，libmpv 纯 HTTP GET 不需要额外 header。**正确。**
- 转码 `transcodeUrl()`（`:558-592`）：`/Videos/{id}/master.m3u8?api_key=…&VideoCodec=h264&AudioCodec=aac&MediaSourceId=…&MaxStreamingBitrate=…`，参数齐全。**正确。**
- `RealVideoRepository.decidePlayback()`（`lib/data/repositories/video_repository.dart:467-499`）：`getPlaybackInfo` 拿源，`sources.first`，`PlaybackDecider.decide`，转码时用 `mediaSourceId: source.id` 钉住所选源。**正确。**
- `PlaybackDecider`（`lib/data/repositories/playback_decision.dart`）：仅 mp4/m4v/mov + h264 + aac/mp3 且服务器允许时直接播，其余走服务端 HLS 转码；规则保守但自洽。**正确。**
- 字幕 `subtitleUrl()`（`emby_client.dart:599-618`）：优先 DeliveryUrl，否则带 MediaSourceId 的 Stream.srt 形式并附 api_key；无源时返回空串。**正确。**

### 共享配置

- `pubspec.yaml:21-23`：`media_kit: ^1.2.0`（实际锁定 1.2.6）、`media_kit_video: ^1.2.0`（实际锁定 1.3.1，依赖 `media_kit ^1.2.1`，与 1.2.6 兼容）。**缺 `media_kit_libs_video`。**
- `android/app/src/main/AndroidManifest.xml:2`：`INTERNET` 权限在。无 `usesCleartextTraffic`，但三台服务器都是 HTTPS，不需要。
- `main.dart`：启动时不初始化 media_kit（故 App 能正常打开）。
- dispose/注销时序：`PlayerService.dispose()` 与 `VideoPlayerService.dispose()` 都是先从 coordinator 注销再 dispose backend；shell 是懒加载 IndexedStack，页面常驻；没有“页面一切换就停播”的竞态能解释“完全不能播”。

---

## 与之前 API 审计的对照（`docs/api-audit.md`）

审计**覆盖**的（与播放有关的部分）：

- Subsonic `stream`（`id`/`maxBitRate`）路径与参数符合 Subsonic API 参考；Emby `/Videos/{id}/stream`、`/Videos/{id}/master.m3u8`、`POST /Items/{id}/PlaybackInfo`、`GET /Users/Me` 等路由在 Emby 4.8.10.0 上经未登录探测返回 401（= 路由存在）。
- Emby B4（进度上报改走 `/Sessions/Playing/Progress` 等）与字幕回退 URL（M1）已在 v0.1.2 修复，均与“能不能播出声音/画面”无关。

审计**没有覆盖**的（本次才查到）：

- **原生 libmpv 是否打包进 App**：审计只核对了 API 请求/响应形状，没看 `pubspec.yaml` 的 native 依赖，也没检查构建产物。
- **播放 URL 实际能不能播**：审计的探测是未登录的路由存在性检查（401 = 存在），从未用带鉴权的真实 URL 在 libmpv 里打开过；也没有任何带账号的端到端播放验证。
- 因此审计结论“51 个调用验证正确”只代表“API 形状正确”，**不能推出“能播放”**。本次诊断补上了这一层。

---

## 已验证正确（逐条一句话）

- Subsonic `streamUrl` 自带 u/t/s/c/v/f 鉴权参数且已 URL 编码（`subsonic_client.dart:338-355`）。
- `streamUrlFor` 按 track 的 serverId 取对应服务器，找不到才返回空串（`music_repository.dart:390-395`）。
- Emby 直接播 / 转码 / 字幕 URL 都在 query 里带 `api_key`，libmpv 纯 GET 不需要额外 header（`emby_client.dart:283-297, 558-592, 599-618`）。
- 转码 URL 形如 `/Videos/{id}/master.m3u8?api_key=…&VideoCodec=h264&AudioCodec=aac&MediaSourceId=…`，参数齐全（`emby_client.dart:558-592`）。
- `decidePlayback` 用 PlaybackInfo 所选源的 `MediaSourceId` 钉住转码源（`video_repository.dart:467-499`）。
- 直接播 vs 转码的判定规则保守且自洽（`playback_decision.dart`）。
- Coordinator 只 pause 对方，不可能自 pause（`playback_coordinator.dart:50-58`）。
- `INTERNET` 权限在 `AndroidManifest.xml:2`。
- 视频页捕获打开失败并显示 `无法播放：…`（`video_player_page.dart:165-211, 510-527`）。
- `media_kit_video` 1.3.1 与 `media_kit` 1.2.6 兼容（依赖 `media_kit ^1.2.1`）。

## 修法（给修复方）

1. `pubspec.yaml` 加 `media_kit_libs_video: ^1.0.7`（README 推荐版；video 库同时覆盖音频，不用再加 `_audio`）。
2. `flutter pub get` 后**完整重新构建**（原生插件，hot restart 不够）。
3. 发版前验证构建产物：解包 APK 确认 `lib/arm64-v8a/libmpv.so` 存在（v0.1.2 的包里没有）。
4. 顺手：`PlayerService` 捕获 backend 异常并在 UI 上提示，别再让音频静默失败。
5. 真机复核：装新版后放一首歌、放一个视频；视频页若仍报错，把 `无法播放：` 后面的文字发回来。
