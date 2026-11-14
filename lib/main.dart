import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/proxy_config.dart';
import 'core/settings.dart';
import 'core/theme.dart';
import 'data/repositories/download_repository.dart';
import 'data/repositories/music_repository.dart';
import 'data/repositories/playback_store.dart';
import 'data/repositories/server_store.dart';
import 'data/repositories/video_repository.dart';
import 'features/player/player_service.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Global state (last tab, last music/video, download filters) is
  // loaded before the first frame so the shell can start on the
  // saved tab instead of flashing Home first.
  final appState = AppStateStore();
  await appState.load();
  runApp(YingHuiApp(appState: appState));
}

/// 影汇 YingHui — media manager + player for Navidrome, Emby,
/// qBittorrent, Transmission and aria2.
///
/// P2: the Music tab is wired to real Navidrome (Subsonic) servers
/// through [RealMusicRepository]; with no Navidrome credentials the
/// Music page shows an explicit empty state. Playback is media_kit
/// (libmpv/FFmpeg) through [PlayerService]; the backend is created
/// lazily on first play, so the app still boots without native libs.
/// P3: the Video tab is wired to real Emby servers through
/// [RealVideoRepository] (direct play vs server transcoding); the
/// video player is media_kit + media_kit_video.
/// P4: the Downloads tab is wired to real qBittorrent / Transmission /
/// aria2 servers through [RealDownloadRepository] (one native client
/// per downloader, merged queue, 5s polling while visible).
/// P5: Settings (theme mode, seed colour, font size, dynamic colour,
/// playback/download defaults, data, About with APP_VERSION).
class YingHuiApp extends StatefulWidget {
  const YingHuiApp({super.key, this.appState});

  /// Pre-loaded global state (main loads it before runApp). When
  /// null — e.g. in the smoke test — a fresh store is created and
  /// loaded in initState instead.
  final AppStateStore? appState;

  @override
  State<YingHuiApp> createState() => _YingHuiAppState();
}

class _YingHuiAppState extends State<YingHuiApp> {
  late final ServerStore _store;
  late final MusicRepository _musicRepo;
  late final VideoRepository _videoRepo;
  late final RealDownloadRepository _downloadRepo;
  late final PlaybackStore _history;
  late final PlayerService _player;
  late final SettingsService _settings;
  late final AppStateStore _appState;

  /// Throttle for the music-state save: the player notifies on every
  /// position tick, so only a track change or a >=10s move is saved.
  String? _lastSavedTrackId;
  int _lastSavedPositionSeconds = -1;

  @override
  void initState() {
    super.initState();
    _settings = SettingsService();
    _store = ServerStore();
    _musicRepo = RealMusicRepository(store: _store, database: _store.database);
    _videoRepo = RealVideoRepository(store: _store, database: _store.database);
    _downloadRepo = RealDownloadRepository(
      store: _store,
      database: _store.database,
    );
    _history = PlaybackStore(_store.database);
    // The audio bitrate is read from Settings at call time, so a
    // change in Settings applies to the next track without a restart.
    _player = PlayerService(
      streamUrlFor: (track) =>
          _musicRepo.streamUrlFor(track, maxBitRate: _settings.audioMaxBitrate),
      history: _history,
    );
    _appState = widget.appState ?? AppStateStore();
    _player.addListener(_onPlayerChanged);
    if (_appState.isLoaded) {
      unawaited(_restorePlayer());
    } else {
      unawaited(_appState.load().then((_) => _restorePlayer()));
    }
    // Load saved servers (Drift + secure storage) and settings.
    // Failures are non-fatal: the app still starts, with the Music
    // empty state.
    _settings.addListener(_onSettingsChanged);
    _settings.load();
    _store.load();
  }

  /// A settings change re-applies the desktop proxy to every Dio
  /// client (Settings notifies on load too, so the stored proxy is
  /// applied once loading finishes — even for clients created
  /// before the load completed).
  void _onSettingsChanged() {
    DioProxy.update(_settings.proxyConfig);
  }

  /// Restore the last music session into the mini-player: queue +
  /// position are shown, nothing auto-plays. The saved shuffle /
  /// repeat modes load first, so a restored session plays in the
  /// saved order.
  Future<void> _restorePlayer() async {
    await _player.loadModes();
    final saved = _appState.lastMusic;
    if (saved == null) return;
    _player.restoreQueue(
      saved.queue,
      index: saved.index,
      position: Duration(seconds: saved.positionSeconds),
    );
  }

  void _onPlayerChanged() {
    final track = _player.currentTrack;
    if (track == null) return;
    final positionSeconds = _player.position.inSeconds;
    if (track.id == _lastSavedTrackId &&
        (positionSeconds - _lastSavedPositionSeconds).abs() < 10) {
      return;
    }
    _lastSavedTrackId = track.id;
    _lastSavedPositionSeconds = positionSeconds;
    unawaited(
      _appState.saveMusicState(
        _player.queue,
        _player.currentIndex,
        _player.position,
      ),
    );
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _player.removeListener(_onPlayerChanged);
    _player.dispose();
    _downloadRepo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final seed = _settings.seedColor;
        final themeMode = _settings.themeMode;
        final textScaler = TextScaler.linear(_settings.fontScale);
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final useDynamic = _settings.dynamicColor;
            return MaterialApp(
              title: '影汇 YingHui',
              theme: YingHuiTheme.build(
                seed: seed,
                brightness: Brightness.light,
                dynamicScheme: useDynamic ? lightDynamic : null,
              ),
              darkTheme: YingHuiTheme.build(
                seed: seed,
                brightness: Brightness.dark,
                dynamicScheme: useDynamic ? darkDynamic : null,
              ),
              themeMode: themeMode,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
              home: AppShell(
                settings: _settings,
                store: _store,
                musicRepo: _musicRepo,
                videoRepo: _videoRepo,
                downloadRepo: _downloadRepo,
                history: _history,
                player: _player,
                appState: _appState,
              ),
            );
          },
        );
      },
    );
  }
}
