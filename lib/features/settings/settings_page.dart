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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
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
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('服务器'),
              subtitle: Text(
                widget.store.servers.isEmpty
                    ? '还没有服务器'
                    : '${widget.store.servers.length} 台服务器',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openServers,
            ),
            const Divider(),
            _sectionTitle('外观'),
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
                          ThemeMode.system => '跟随系统',
                          ThemeMode.light => '浅色',
                          ThemeMode.dark => '深色',
                        }),
                        value: m,
                      ),
                    )
                    .toList(),
              ),
            ),
            const ListTile(title: Text('主题色')),
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
              title: const Text('字号'),
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
              title: const Text('动态取色（Android 12+）'),
              subtitle: const Text('可用时使用系统壁纸颜色。'),
              value: settings.dynamicColor,
              onChanged: settings.setDynamicColor,
            ),
            const Divider(),
            _sectionTitle('播放'),
            ListTile(
              title: const Text('默认视频清晰度'),
              subtitle: const Text('自动：能直接播放就直接播放，否则由服务器转码。'),
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
              title: const Text('音频质量（Navidrome）'),
              subtitle: const Text('音乐流的最大码率。'),
              trailing: DropdownButton<int>(
                value: settings.audioMaxBitrate,
                items: const [0, 128, 192, 320]
                    .map(
                      (b) => DropdownMenuItem(
                        value: b,
                        child: Text(b == 0 ? '原始' : '$b kbps'),
                      ),
                    )
                    .toList(),
                onChanged: (b) {
                  if (b != null) settings.setAudioMaxBitrate(b);
                },
              ),
            ),
            SwitchListTile(
              title: const Text('字幕'),
              subtitle: const Text('有字幕时默认显示。'),
              value: settings.subtitlesEnabled,
              onChanged: settings.setSubtitlesEnabled,
            ),
            SwitchListTile(
              title: const Text('断点续播'),
              subtitle: const Text('从上次停下的位置继续播放。'),
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
                (MusicPlayerStyle.standard, '默认', '现在的 M3 绿色播放器'),
                (
                  MusicPlayerStyle.appleMusic,
                  'Apple Music',
                  '封面取色背景 + 白色播放键 + 音量条',
                ),
                (MusicPlayerStyle.spotify, 'Spotify', '纯黑底 + 白色播放键 + 收藏'),
              ],
            ),
            _styleGroup<VideoPlayerStyle>(
              title: '视频播放器',
              groupValue: settings.videoPlayerStyle,
              onChanged: settings.setVideoPlayerStyle,
              options: const [
                (VideoPlayerStyle.standard, '默认', '现在的 M3 绿色播放器'),
                (VideoPlayerStyle.netflix, 'Netflix', '红色进度条 + 下一集按钮'),
                (VideoPlayerStyle.appleTv, 'Apple TV', '±10 秒快进快退 + 播完自动播放下一集'),
              ],
            ),
            const Divider(),
            _sectionTitle('下载'),
            ListTile(
              title: const Text('默认下载器'),
              trailing: DropdownButton<String?>(
                value: settings.defaultDownloaderId,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('第一个可用'),
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
              title: const Text('默认保存路径'),
              subtitle: const Text('可选，每个下载器单独的保存路径。'),
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
              title: const Text('刷新间隔'),
              subtitle: const Text('下载队列多久刷新一次。'),
              trailing: DropdownButton<int>(
                value: settings.pollingIntervalSeconds,
                items: const [5, 10, 30]
                    .map((s) => DropdownMenuItem(value: s, child: Text('$s 秒')))
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
            _sectionTitle('数据'),
            ListTile(
              title: const Text('搜索记录'),
              subtitle: Text(
                settings.searchHistory.isEmpty
                    ? '没有保存的搜索'
                    : '${settings.searchHistory.length} 条搜索记录',
              ),
              trailing: TextButton(
                onPressed: settings.searchHistory.isEmpty
                    ? null
                    : () async {
                        if (await _confirm('清除搜索记录？', '保存的搜索记录将被删除。')) {
                          await settings.clearSearchHistory();
                        }
                      },
                child: const Text('清除'),
              ),
            ),
            ListTile(
              title: const Text('播放记录'),
              trailing: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await _confirm('清除播放记录？', '断点续播位置将被删除。')) {
                    await widget.history.clearHistory();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('播放记录已清除。')),
                    );
                  }
                },
                child: const Text('清除'),
              ),
            ),
            ListTile(
              title: const Text('收藏'),
              trailing: TextButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (await _confirm('清除收藏？', '所有收藏的歌曲和专辑将被删除。')) {
                    await widget.history.clearFavourites();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('收藏已清除。')),
                    );
                  }
                },
                child: const Text('清除'),
              ),
            ),
            ListTile(
              title: const Text('图片缓存'),
              subtitle: Text(
                _imageCacheBytes < 0 ? '计算中…' : formatBytes(_imageCacheBytes),
              ),
              trailing: TextButton(
                onPressed: () async {
                  if (await _confirm('清除图片缓存？', '缓存的专辑封面和海报需要重新下载。')) {
                    await DefaultCacheManager().emptyCache();
                    await _refreshCacheSize();
                  }
                },
                child: const Text('清除'),
              ),
            ),
            const Divider(),
            _sectionTitle('关于'),
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
              subtitle: Text('版本 ${appVersionLabel(appVersion)}'),
            ),
            const ListTile(
              title: Text('包名'),
              subtitle: Text('com.yinghui.app'),
            ),
            const ListTile(
              title: Text('这个应用是做什么的'),
              subtitle: Text(
                '播放 Navidrome 上的音乐和 Emby 上的视频，并管理 '
                'qBittorrent、Transmission 和 aria2 服务器上的下载。'
                '只连接你自己添加的服务器——不创建账号，'
                '也不保存任何媒体。',
              ),
            ),
            ListTile(
              title: const Text('开源许可证'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(context: context),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                '为你自己的服务器而做。',
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
