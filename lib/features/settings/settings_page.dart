import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/settings.dart';
import '../../core/models/server.dart';
import '../../data/repositories/download_repository.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/server_store.dart';
import '../servers/servers_page.dart';

/// Settings (P5): Appearance / Playback / Downloads / Data / About.
///
/// Reached from the app shell's gear button. Servers live on their
/// own page (the "Servers" row below) — this page is preferences only.
/// The version row reads `--dart-define=APP_VERSION` ('dev' on
/// non-tag builds) and is never hard-coded.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.store,
    required this.history,
    required this.downloadRepo,
  });

  final SettingsService settings;
  final ServerStore store;
  final PlaybackStore history;
  final DownloadRepository downloadRepo;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _imageCacheBytes = -1;

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
  }

  Future<void> _refreshCacheSize() async {
    final bytes = await imageCacheBytes();
    if (mounted) setState(() => _imageCacheBytes = bytes);
  }

  /// Bytes under the cached_network_image cache dir
  /// (`libCachedImageData` under the temp dir); 0 when it is absent.
  /// Kept static + pure-ish so tests can check the formatting
  /// separately via [formatBytes].
  static Future<int> imageCacheBytes() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/libCachedImageData');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _openServers() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ServersPage(store: widget.store)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Servers'),
              subtitle: Text(
                widget.store.servers.isEmpty
                    ? 'No servers yet'
                    : '${widget.store.servers.length} server(s)',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openServers,
            ),
            const Divider(),
            _sectionTitle('Appearance'),
            RadioGroup<ThemeMode>(
              groupValue: settings.themeMode,
              onChanged: (v) {
                if (v != null) settings.setThemeMode(v);
              },
              child: Column(
                children: ThemeMode.values
                    .map(
                      (m) => RadioListTile<ThemeMode>(
                        title: Text(switch (m) {
                          ThemeMode.system => 'System',
                          ThemeMode.light => 'Light',
                          ThemeMode.dark => 'Dark',
                        }),
                        value: m,
                      ),
                    )
                    .toList(),
              ),
            ),
            const ListTile(title: Text('Accent colour')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: seedPresets.indexed.map((entry) {
                  final (i, preset) = entry;
                  final selected = i == settings.seedIndex;
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      onTap: () => settings.setSeedIndex(i),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: preset.color,
                          shape: BoxShape.circle,
                          border: selected
                              ? Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                                  width: 2,
                                )
                              : null,
                        ),
                        child: selected
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            ListTile(
              title: const Text('Font size'),
              subtitle: Slider(
                value: settings.fontScale,
                min: 0.8,
                max: 1.3,
                divisions: 5,
                label: '${(settings.fontScale * 100).round()}%',
                onChanged: settings.setFontScale,
              ),
              trailing: Text('${(settings.fontScale * 100).round()}%'),
            ),
            SwitchListTile(
              title: const Text('Dynamic colour (Android 12+)'),
              subtitle: const Text(
                'Use the system wallpaper colours when available.',
              ),
              value: settings.dynamicColor,
              onChanged: settings.setDynamicColor,
            ),
            const Divider(),
            _sectionTitle('Playback'),
            ListTile(
              title: const Text('Default video quality'),
              subtitle: const Text(
                'Auto: direct play when possible, otherwise server transcoding.',
              ),
              trailing: DropdownButton<VideoQualityPreference>(
                value: settings.videoQuality,
                items: VideoQualityPreference.values
                    .map(
                      (q) => DropdownMenuItem(value: q, child: Text(q.label)),
                    )
                    .toList(),
                onChanged: (q) {
                  if (q != null) settings.setVideoQuality(q);
                },
              ),
            ),
            ListTile(
              title: const Text('Audio quality (Navidrome)'),
              subtitle: const Text('Max bitrate for music streams.'),
              trailing: DropdownButton<int>(
                value: settings.audioMaxBitrate,
                items: const [0, 128, 192, 320]
                    .map(
                      (b) => DropdownMenuItem(
                        value: b,
                        child: Text(b == 0 ? 'Original' : '$b kbps'),
                      ),
                    )
                    .toList(),
                onChanged: (b) {
                  if (b != null) settings.setAudioMaxBitrate(b);
                },
              ),
            ),
            SwitchListTile(
              title: const Text('Subtitles'),
              subtitle: const Text('Show subtitles by default when available.'),
              value: settings.subtitlesEnabled,
              onChanged: settings.setSubtitlesEnabled,
            ),
            SwitchListTile(
              title: const Text('Resume playback'),
              subtitle: const Text('Continue from where you left off.'),
              value: settings.resumePlayback,
              onChanged: settings.setResumePlayback,
            ),
            const Divider(),
            _sectionTitle('播放器风格'),
            _styleGroup<MusicPlayerStyle>(
              title: '音乐播放器',
              groupValue: settings.musicPlayerStyle,
              onChanged: settings.setMusicPlayerStyle,
              options: const [
                (
                  MusicPlayerStyle.standard,
                  '默认',
                  '现在的 M3 绿色播放器',
                ),
                (
                  MusicPlayerStyle.appleMusic,
                  'Apple Music',
                  '封面取色背景 + 白色播放键 + 音量条',
                ),
                (
                  MusicPlayerStyle.spotify,
                  'Spotify',
                  '纯黑底 + 白色播放键 + 收藏',
                ),
              ],
            ),
            _styleGroup<VideoPlayerStyle>(
              title: '视频播放器',
              groupValue: settings.videoPlayerStyle,
              onChanged: settings.setVideoPlayerStyle,
              options: const [
                (
                  VideoPlayerStyle.standard,
                  '默认',
                  '现在的 M3 绿色播放器',
                ),
                (
                  VideoPlayerStyle.netflix,
                  'Netflix',
                  '红色进度条 + 下一集按钮',
                ),
                (
                  VideoPlayerStyle.appleTv,
                  'Apple TV',
                  '±10 秒快进快退 + 播完 Up Next',
                ),
              ],
            ),
            const Divider(),
            _sectionTitle('Downloads'),
            ListTile(
              title: const Text('Default downloader'),
              trailing: DropdownButton<String?>(
                value: settings.defaultDownloaderId,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('First available'),
                  ),
                  ...widget.downloadRepo.usableDownloaders.map(
                    (s) => DropdownMenuItem<String?>(
                      value: s.id,
                      child: Text('${s.name} · ${s.type.label}'),
                    ),
                  ),
                ],
                onChanged: settings.setDefaultDownloaderId,
              ),
            ),
            ListTile(
              title: const Text('Default save path'),
              subtitle: const Text('Optional, per-downloader save path.'),
              trailing: SizedBox(
                width: 160,
                child: TextField(
                  controller: TextEditingController(
                    text: settings.defaultSavePath,
                  ),
                  decoration: const InputDecoration(
                    hintText: '/downloads',
                    border: InputBorder.none,
                  ),
                  textAlign: TextAlign.right,
                  onSubmitted: settings.setDefaultSavePath,
                ),
              ),
            ),
            ListTile(
              title: const Text('Refresh interval'),
              subtitle: const Text('How often the download queue refreshes.'),
              trailing: DropdownButton<int>(
                value: settings.pollingIntervalSeconds,
                items: const [5, 10, 30]
                    .map((s) => DropdownMenuItem(value: s, child: Text('$s s')))
                    .toList(),
                onChanged: (s) {
                  if (s != null) {
                    settings.setPollingIntervalSeconds(s);
                    widget.downloadRepo.startPolling(intervalSeconds: s);
                  }
                },
              ),
            ),
            const Divider(),
            _sectionTitle('Data'),
            ListTile(
              title: const Text('Search history'),
              subtitle: Text(
                settings.searchHistory.isEmpty
                    ? 'No saved searches'
                    : '${settings.searchHistory.length} saved search(es)',
              ),
              trailing: TextButton(
                onPressed: settings.searchHistory.isEmpty
                    ? null
                    : () async {
                        if (await _confirm(
                          'Clear search history?',
                          'Your saved searches will be removed.',
                        )) {
                          await settings.clearSearchHistory();
                        }
                      },
                child: const Text('Clear'),
              ),
            ),
            ListTile(
              title: const Text('Playback history'),
              trailing: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await _confirm(
                    'Clear playback history?',
                    'Resume positions will be removed.',
                  )) {
                    await widget.history.clearHistory();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Playback history cleared.'),
                      ),
                    );
                  }
                },
                child: const Text('Clear'),
              ),
            ),
            ListTile(
              title: const Text('Favourites'),
              trailing: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await _confirm(
                    'Clear favourites?',
                    'All starred tracks and albums will be removed.',
                  )) {
                    await widget.history.clearFavourites();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Favourites cleared.')),
                    );
                  }
                },
                child: const Text('Clear'),
              ),
            ),
            ListTile(
              title: const Text('Image cache'),
              subtitle: Text(
                _imageCacheBytes < 0
                    ? 'Calculating…'
                    : formatBytes(_imageCacheBytes),
              ),
              trailing: TextButton(
                onPressed: () async {
                  if (await _confirm(
                    'Clear image cache?',
                    'Cached album covers and posters will be re-downloaded.',
                  )) {
                    await DefaultCacheManager().emptyCache();
                    await _refreshCacheSize();
                  }
                },
                child: const Text('Clear'),
              ),
            ),
            const Divider(),
            _sectionTitle('About'),
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/logo.png',
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                ),
              ),
              title: const Text('影汇 YingHui'),
              subtitle: Text('Version ${appVersionLabel(appVersion)}'),
            ),
            const ListTile(
              title: Text('Package'),
              subtitle: Text('com.yinghui.app'),
            ),
            const ListTile(
              title: Text('What this app does'),
              subtitle: Text(
                'Plays your music from Navidrome and your videos from '
                'Emby, and manages downloads on your qBittorrent, '
                'Transmission and aria2 servers. It only connects to '
                'servers you add yourself — it creates no account and '
                'stores no media of its own.',
              ),
            ),
            ListTile(
              title: const Text('Open-source licences'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(context: context),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'Made for your own servers.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// One style picker group: a title plus a radio per option with a
  /// one-line hint. Text labels only — no brand logos or trademarked
  /// assets.
  Widget _styleGroup<T>({
    required String title,
    required T groupValue,
    required void Function(T value) onChanged,
    required List<(T, String, String)> options,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(title: Text(title)),
        RadioGroup<T>(
          groupValue: groupValue,
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
          child: Column(
            children: options
                .map(
                  (option) => RadioListTile<T>(
                    title: Text(option.$2),
                    subtitle: Text(option.$3),
                    value: option.$1,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}
