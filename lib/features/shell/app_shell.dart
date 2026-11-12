import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/settings.dart';
import '../../core/models/server.dart';
import '../../data/repositories/download_repository.dart';
import '../../data/repositories/music_repository.dart';
import '../../data/repositories/playback_store.dart';
import '../../data/repositories/server_store.dart';
import '../../data/repositories/video_repository.dart';
import '../downloads/downloads_page.dart';
import '../home/home_page.dart';
import '../music/music_page.dart';
import '../player/mini_player.dart';
import '../player/player_service.dart';
import '../settings/settings_page.dart';
import '../video/video_page.dart';

/// Adaptive shell, like douya: mobile bottom NavigationBar, desktop
/// NavigationRail. 4 tabs + a persistent mini-player above the nav.
/// The gear opens Settings (P5); Servers live under Settings.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.settings,
    required this.store,
    required this.musicRepo,
    required this.videoRepo,
    required this.downloadRepo,
    required this.history,
    required this.player,
    this.appState,
  });

  final SettingsService settings;
  final ServerStore store;
  final MusicRepository musicRepo;
  final VideoRepository videoRepo;
  final DownloadRepository downloadRepo;
  final PlaybackStore history;
  final PlayerService player;

  /// Optional global state (last tab). When null the shell starts
  /// on Home, as before.
  final AppStateStore? appState;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// Set once the user picks a tab: after that, a late app-state
  /// load must not yank the tab back to the saved one.
  bool _userNavigated = false;

  static const _titles = ['影汇', '音乐', '视频', '下载'];

  @override
  void initState() {
    super.initState();
    _index = widget.appState?.lastTab ?? 0;
    widget.appState?.addListener(_onAppStateChanged);
  }

  @override
  void dispose() {
    widget.appState?.removeListener(_onAppStateChanged);
    super.dispose();
  }

  /// The store may finish loading after the first frame (only when
  /// it was not pre-loaded in main); pick up the saved tab then.
  void _onAppStateChanged() {
    final saved = widget.appState?.lastTab ?? 0;
    if (!_userNavigated && saved != _index) {
      setState(() => _index = saved);
    }
  }

  void _selectTab(int i) {
    _userNavigated = true;
    setState(() => _index = i);
    unawaited(widget.appState?.setLastTab(i));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 800;
    final pages = [
      HomePage(
        store: widget.store,
        downloadRepo: widget.downloadRepo,
        musicRepo: widget.musicRepo,
        videoRepo: widget.videoRepo,
        history: widget.history,
        player: widget.player,
        settings: widget.settings,
        onSearchTap: () => _selectTab(1),
      ),
      MusicPage(
        repo: widget.musicRepo,
        player: widget.player,
        store: widget.store,
        settings: widget.settings,
        appState: widget.appState,
      ),
      VideoPage(
        repo: widget.videoRepo,
        store: widget.store,
        history: widget.history,
        settings: widget.settings,
        appState: widget.appState,
      ),
      DownloadsPage(
        repo: widget.downloadRepo,
        store: widget.store,
        settings: widget.settings,
        appState: widget.appState,
      ),
    ];
    // The mini-player is scoped to music pages only (the Music tab
    // here; AlbumDetailPage pins its own copy): on Home / Video /
    // Downloads it would sit above content it has nothing to do with.
    final body = Column(
      children: [
        Expanded(child: pages[_index]),
        if (_index == 1)
          MiniPlayer(
            player: widget.player,
            settings: widget.settings,
            musicRepo: widget.musicRepo,
          ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/logo.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            Text(_titles[_index]),
          ],
        ),
        actions: [
          if (_index == 3)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '添加下载',
              onPressed: () => _showAddDownload(context),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(
                    settings: widget.settings,
                    store: widget.store,
                    history: widget.history,
                    downloadRepo: widget.downloadRepo,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _selectTab,
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('首页'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.music_note_outlined),
                      selectedIcon: Icon(Icons.music_note),
                      label: Text('音乐'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.movie_outlined),
                      selectedIcon: Icon(Icons.movie),
                      label: Text('视频'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.download_outlined),
                      selectedIcon: Icon(Icons.download),
                      label: Text('下载'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _selectTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页',
                ),
                NavigationDestination(
                  icon: Icon(Icons.music_note_outlined),
                  selectedIcon: Icon(Icons.music_note),
                  label: '音乐',
                ),
                NavigationDestination(
                  icon: Icon(Icons.movie_outlined),
                  selectedIcon: Icon(Icons.movie),
                  label: '视频',
                ),
                NavigationDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download),
                  label: '下载',
                ),
              ],
            ),
    );
  }

  /// Add-download sheet: magnet link / torrent URL / .torrent URL,
  /// pick a downloader (Settings default first, else the default
  /// server, else the first usable one), save path prefilled from
  /// Settings. Server-side download, not a local device download.
  Future<void> _showAddDownload(BuildContext context) async {
    final usable = widget.downloadRepo.usableDownloaders;
    if (usable.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('还没有下载器账号——去“服务器”里添加。')));
      return;
    }
    final urlController = TextEditingController();
    final savePathController = TextEditingController(
      text: widget.settings.defaultSavePath,
    );
    Server? preferred;
    final preferredId = widget.settings.defaultDownloaderId;
    if (preferredId != null) {
      for (final s in usable) {
        if (s.id == preferredId) preferred = s;
      }
    }
    var server =
        preferred ??
        usable.firstWhere((s) => s.isDefault, orElse: () => usable.first);
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('添加下载'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '磁力链接、种子链接或种子哈希',
                  hintText: 'magnet:?xt=… / https://… / 40 或 64 位十六进制',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButton<Server>(
                value: server,
                isExpanded: true,
                items: usable
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text('${s.name} · ${s.type.label}'),
                      ),
                    )
                    .toList(),
                onChanged: (s) {
                  if (s != null) setState(() => server = s);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: savePathController,
                decoration: const InputDecoration(labelText: '保存路径（可选）'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final url = urlController.text.trim();
                if (url.isEmpty) {
                  // Nothing to add: keep the sheet open instead of
                  // closing it and flashing a failure snackbar.
                  return;
                }
                final ok = await widget.downloadRepo.addTask(
                  magnetOrUrl: url,
                  downloaderServerId: server.id,
                  savePath: savePathController.text.trim().isEmpty
                      ? null
                      : savePathController.text.trim(),
                );
                if (context.mounted) Navigator.of(context).pop(ok);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (added == false && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('添加下载失败——请检查服务器。')));
    }
  }
}
