import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/playback_decision.dart';
import 'proxy_config.dart';

/// App version: from the release tag via `--dart-define=APP_VERSION`
/// (release.yml sets it from the tag on tag builds, 'dev' on any other
/// build). Never hard-coded in the app.
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

/// Pure helper, unit-tested: 'dev' builds show as 开发版.
String appVersionLabel(String version) => version == 'dev' ? '开发版' : version;

/// Pure helper, unit-tested: human-readable byte size.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

/// Default video quality picked in Settings. `auto` means: direct play
/// when the file is direct-playable, otherwise the server transcodes
/// (the P3 [PlaybackDecider] rule) — i.e. the decider decides.
enum VideoQualityPreference { auto, direct, p1080, p720, p480 }

extension VideoQualityPreferenceLabel on VideoQualityPreference {
  String get label => switch (this) {
    VideoQualityPreference.auto => '自动',
    VideoQualityPreference.direct => '直接播放',
    VideoQualityPreference.p1080 => '1080p',
    VideoQualityPreference.p720 => '720p',
    VideoQualityPreference.p480 => '480p',
  };

  /// The [VideoQuality] handed to the P3 decider.
  VideoQuality get effectiveQuality => switch (this) {
    VideoQualityPreference.auto ||
    VideoQualityPreference.direct => VideoQuality.direct,
    VideoQualityPreference.p1080 => VideoQuality.p1080,
    VideoQualityPreference.p720 => VideoQuality.p720,
    VideoQualityPreference.p480 => VideoQuality.p480,
  };
}

/// Music player presentation style. Only presentation changes —
/// the queue, seek and playback behaviour are the same in every
/// style. Stored as 'default' / 'appleMusic' / 'spotify'.
enum MusicPlayerStyle {
  standard,
  appleMusic,
  spotify;

  /// Stored string: 'default' for the current M3 green layout.
  String get storageName => switch (this) {
    MusicPlayerStyle.standard => 'default',
    MusicPlayerStyle.appleMusic => 'appleMusic',
    MusicPlayerStyle.spotify => 'spotify',
  };

  static MusicPlayerStyle fromString(String? name) =>
      MusicPlayerStyle.values.firstWhere(
        (s) => s.storageName == name,
        orElse: () => MusicPlayerStyle.standard,
      );
}

/// Video player presentation style. Only presentation changes (plus
/// the real ±10s seek and Up Next of the Apple TV style, and the
/// real Next Episode button of the Netflix style). Stored as
/// 'default' / 'netflix' / 'appleTv'.
enum VideoPlayerStyle {
  standard,
  netflix,
  appleTv;

  /// Stored string: 'default' for the current M3 green layout.
  String get storageName => switch (this) {
    VideoPlayerStyle.standard => 'default',
    VideoPlayerStyle.netflix => 'netflix',
    VideoPlayerStyle.appleTv => 'appleTv',
  };

  static VideoPlayerStyle fromString(String? name) =>
      VideoPlayerStyle.values.firstWhere(
        (s) => s.storageName == name,
        orElse: () => VideoPlayerStyle.standard,
      );
}

/// M3 seed-colour presets. Emby green is the default; the others are
/// harmonious with the dark-first palette (forest, teal, slate blue).
class SeedPreset {
  const SeedPreset(this.label, this.color);

  final String label;
  final Color color;
}

const seedPresets = [
  SeedPreset('Emby 绿', Color(0xFF52B54B)),
  SeedPreset('深林绿', Color(0xFF1B7A2E)),
  SeedPreset('青色', Color(0xFF00897B)),
  SeedPreset('石板蓝', Color(0xFF5C6BC0)),
];

/// Settings, persisted in shared_preferences and applied app-wide via
/// this [ChangeNotifier]. Secrets are never stored here — only
/// preferences. All setters persist first, then notify.
class SettingsService extends ChangeNotifier {
  SettingsService({this._prefs});

  SharedPreferences? _prefs;

  static const _kThemeMode = 'yinghui_theme_mode';
  static const _kSeedIndex = 'yinghui_seed_index';
  static const _kFontScale = 'yinghui_font_scale';
  static const _kDynamicColor = 'yinghui_dynamic_color';
  static const _kVideoQuality = 'yinghui_video_quality';
  static const _kAudioBitrate = 'yinghui_audio_bitrate';
  static const _kSubtitles = 'yinghui_subtitles_on';
  static const _kResume = 'yinghui_resume_playback';
  static const _kDefaultDownloader = 'yinghui_default_downloader';
  static const _kDefaultSavePath = 'yinghui_default_save_path';
  static const _kPollingInterval = 'yinghui_polling_interval';
  static const _kSearchHistory = 'yinghui_search_history';
  static const _kMusicPlayerStyle = 'yinghui_music_player_style';
  static const _kVideoPlayerStyle = 'yinghui_video_player_style';

  /// Desktop HTTP proxy (see [ProxyConfig]): enabled, host, port.
  /// Persisted even when disabled, so the fields keep their values.
  static const _kProxyEnabled = 'yinghui_proxy_enabled';
  static const _kProxyHost = 'yinghui_proxy_host';
  static const _kProxyPort = 'yinghui_proxy_port';

  ThemeMode _themeMode = ThemeMode.system;
  int _seedIndex = 0;
  double _fontScale = 1.0;
  bool _dynamicColor = false;
  VideoQualityPreference _videoQuality = VideoQualityPreference.auto;
  int _audioMaxBitrate = 0;
  bool _subtitlesEnabled = true;
  bool _resumePlayback = true;
  String? _defaultDownloaderId;
  String _defaultSavePath = '';
  int _pollingIntervalSeconds = 5;
  List<String> _searchHistory = [];
  MusicPlayerStyle _musicPlayerStyle = MusicPlayerStyle.standard;
  VideoPlayerStyle _videoPlayerStyle = VideoPlayerStyle.standard;
  ProxyConfig _proxyConfig = const ProxyConfig();

  ThemeMode get themeMode => _themeMode;
  int get seedIndex => _seedIndex;
  Color get seedColor =>
      seedPresets[_seedIndex.clamp(0, seedPresets.length - 1)].color;
  double get fontScale => _fontScale;
  bool get dynamicColor => _dynamicColor;
  VideoQualityPreference get videoQuality => _videoQuality;
  VideoQuality get effectiveVideoQuality => _videoQuality.effectiveQuality;
  int get audioMaxBitrate => _audioMaxBitrate;
  bool get subtitlesEnabled => _subtitlesEnabled;
  bool get resumePlayback => _resumePlayback;
  String? get defaultDownloaderId => _defaultDownloaderId;
  String get defaultSavePath => _defaultSavePath;
  int get pollingIntervalSeconds => _pollingIntervalSeconds;
  List<String> get searchHistory => List.unmodifiable(_searchHistory);
  MusicPlayerStyle get musicPlayerStyle => _musicPlayerStyle;
  VideoPlayerStyle get videoPlayerStyle => _videoPlayerStyle;
  ProxyConfig get proxyConfig => _proxyConfig;

  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _ensurePrefs();
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == p.getString(_kThemeMode),
      orElse: () => ThemeMode.system,
    );
    _seedIndex = p.getInt(_kSeedIndex) ?? 0;
    _fontScale = p.getDouble(_kFontScale) ?? 1.0;
    _dynamicColor = p.getBool(_kDynamicColor) ?? false;
    _videoQuality = VideoQualityPreference.values.firstWhere(
      (q) => q.name == p.getString(_kVideoQuality),
      orElse: () => VideoQualityPreference.auto,
    );
    _audioMaxBitrate = p.getInt(_kAudioBitrate) ?? 0;
    _subtitlesEnabled = p.getBool(_kSubtitles) ?? true;
    _resumePlayback = p.getBool(_kResume) ?? true;
    _defaultDownloaderId = p.getString(_kDefaultDownloader);
    _defaultSavePath = p.getString(_kDefaultSavePath) ?? '';
    _pollingIntervalSeconds = p.getInt(_kPollingInterval) ?? 5;
    _searchHistory = p.getStringList(_kSearchHistory) ?? [];
    // Unknown stored values fall back to the default style so an
    // old or hand-edited value never breaks the player pages.
    _musicPlayerStyle = MusicPlayerStyle.fromString(
      p.getString(_kMusicPlayerStyle),
    );
    _videoPlayerStyle = VideoPlayerStyle.fromString(
      p.getString(_kVideoPlayerStyle),
    );
    _proxyConfig = ProxyConfig(
      enabled: p.getBool(_kProxyEnabled) ?? false,
      host: p.getString(_kProxyHost) ?? '',
      port: p.getInt(_kProxyPort) ?? 0,
    );
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await _ensurePrefs();
    await p.setString(_kThemeMode, _themeMode.name);
    await p.setInt(_kSeedIndex, _seedIndex);
    await p.setDouble(_kFontScale, _fontScale);
    await p.setBool(_kDynamicColor, _dynamicColor);
    await p.setString(_kVideoQuality, _videoQuality.name);
    await p.setInt(_kAudioBitrate, _audioMaxBitrate);
    await p.setBool(_kSubtitles, _subtitlesEnabled);
    await p.setBool(_kResume, _resumePlayback);
    if (_defaultDownloaderId == null) {
      await p.remove(_kDefaultDownloader);
    } else {
      await p.setString(_kDefaultDownloader, _defaultDownloaderId!);
    }
    await p.setString(_kDefaultSavePath, _defaultSavePath);
    await p.setInt(_kPollingInterval, _pollingIntervalSeconds);
    await p.setStringList(_kSearchHistory, _searchHistory);
    await p.setString(_kMusicPlayerStyle, _musicPlayerStyle.storageName);
    await p.setString(_kVideoPlayerStyle, _videoPlayerStyle.storageName);
    await p.setBool(_kProxyEnabled, _proxyConfig.enabled);
    await p.setString(_kProxyHost, _proxyConfig.host);
    await p.setInt(_kProxyPort, _proxyConfig.port);
  }

  Future<void> _update(Future<void> Function() save) async {
    await save();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _update(_save);
  }

  Future<void> setSeedIndex(int index) async {
    _seedIndex = index.clamp(0, seedPresets.length - 1);
    await _update(_save);
  }

  Future<void> setFontScale(double scale) async {
    _fontScale = scale.clamp(0.8, 1.3);
    await _update(_save);
  }

  Future<void> setDynamicColor(bool value) async {
    _dynamicColor = value;
    await _update(_save);
  }

  Future<void> setVideoQuality(VideoQualityPreference quality) async {
    _videoQuality = quality;
    await _update(_save);
  }

  Future<void> setAudioMaxBitrate(int kbps) async {
    _audioMaxBitrate = kbps;
    await _update(_save);
  }

  Future<void> setSubtitlesEnabled(bool value) async {
    _subtitlesEnabled = value;
    await _update(_save);
  }

  Future<void> setResumePlayback(bool value) async {
    _resumePlayback = value;
    await _update(_save);
  }

  Future<void> setDefaultDownloaderId(String? id) async {
    _defaultDownloaderId = id;
    await _update(_save);
  }

  Future<void> setDefaultSavePath(String path) async {
    _defaultSavePath = path.trim();
    await _update(_save);
  }

  Future<void> setPollingIntervalSeconds(int seconds) async {
    _pollingIntervalSeconds = seconds;
    await _update(_save);
  }

  Future<void> setMusicPlayerStyle(MusicPlayerStyle style) async {
    _musicPlayerStyle = style;
    await _update(_save);
  }

  Future<void> setVideoPlayerStyle(VideoPlayerStyle style) async {
    _videoPlayerStyle = style;
    await _update(_save);
  }

  Future<void> setProxyEnabled(bool value) async {
    _proxyConfig = _proxyConfig.copyWith(enabled: value);
    await _update(_save);
  }

  Future<void> setProxyHost(String host) async {
    _proxyConfig = _proxyConfig.copyWith(host: host.trim());
    await _update(_save);
  }

  Future<void> setProxyPort(int port) async {
    _proxyConfig = _proxyConfig.copyWith(port: port.clamp(0, 65535));
    await _update(_save);
  }

  /// Records a search term (most recent first, max 20, deduped).
  Future<void> recordSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchHistory = [
      q,
      ..._searchHistory.where((s) => s != q),
    ].take(20).toList();
    await _update(_save);
  }

  Future<void> clearSearchHistory() async {
    _searchHistory = [];
    await _update(_save);
  }
}
