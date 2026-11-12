import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import '../../core/theme.dart';
import '../../data/repositories/server_store.dart';

/// Servers (under Settings): list with a connection status dot, tap to
/// make default, long-press to edit, swipe to delete. Add picks the type
/// first, then the form, with Test Connection before save.
///
/// Desktop adds three affordances on top of the mobile gestures (which
/// stay as-is): edit/delete buttons appear on a hovered row, a
/// right-click opens a context menu (设为默认 / 编辑 / 测试连接 / 删除),
/// and the Delete key deletes the last tapped row. All three reuse the
/// same form and delete confirm dialog as the mobile gestures.
///
/// Connection state per server is shown distinctly:
/// online (green) / needs login (amber) / unreachable (red) / not yet
/// tested (grey). The Test button runs the structured probe
/// ([ConnectionResult]) — e.g. a Subsonic code-10 or qBittorrent 403
/// shows as "needs login", not as unreachable.
///
/// Each row also shows the last-known server version/name (schema v3),
/// persisted when a probe returns them and surviving restarts — a
/// server never tested shows no version at all. A fresh probe result
/// in this session takes precedence over the stored values and updates
/// them immediately.
class ServersPage extends StatefulWidget {
  const ServersPage({super.key, required this.store});

  final ServerStore store;

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  final Map<String, ConnectionResult> _results = {};
  final Set<String> _testing = {};

  /// Row the mouse is over (desktop only) — drives the inline
  /// edit/delete buttons. Null on touch platforms.
  String? _hoveredId;

  /// Last tapped row — the Delete key deletes this one. Set by onTap
  /// alongside the existing set-default behaviour.
  String? _selectedId;

  final FocusNode _focusNode = FocusNode();

  ServerStore get store => widget.store;

  /// Desktop = a platform with a mouse (hover + right-click + Delete
  /// key). Width is not the test: a narrow desktop window still has a
  /// mouse, and a wide tablet does not.
  bool get _isDesktop {
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// The shared delete confirm: the server and its stored secret are
  /// deleted together. Used by swipe, the hover button, the context
  /// menu and the Delete key alike.
  Future<bool> _confirmDelete(Server server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${server.name}？'),
        content: const Text('服务器和它保存的密码也会一起删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _delete(Server server) async {
    if (await _confirmDelete(server)) {
      if (_selectedId == server.id) _selectedId = null;
      await store.remove(server.id);
    }
  }

  /// Desktop right-click menu at the cursor. Each entry runs the exact
  /// same action as its mobile counterpart.
  Future<void> _showContextMenu(
    BuildContext rowContext,
    Server server,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(rowContext).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: rowContext,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'default', child: Text('设为默认')),
        PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(value: 'test', child: Text('测试连接')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'default':
        await store.setDefault(server.id);
      case 'edit':
        // The State's own context is guarded by the mounted check
        // above; the row context from before the await is not.
        await _showServerForm(context, server: server);
      case 'test':
        await _test(server);
      case 'delete':
        await _delete(server);
      case null:
        break;
    }
  }

  Future<void> _test(Server server) async {
    setState(() => _testing.add(server.id));
    try {
      final result = await store.testConnection(server);
      if (mounted) setState(() => _results[server.id] = result);
    } catch (e) {
      // A connectivity check must never crash the button: anything
      // unexpected surfaces as unreachable with the error attached.
      if (mounted) {
        setState(
          () =>
              _results[server.id] = ConnectionResult.unreachable(message: '$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _testing.remove(server.id));
    }
  }

  Color _statusColor(ConnectionResult? result) {
    if (result == null) return Colors.grey;
    return switch (result.status) {
      ConnectionStatus.ok => YingHuiTheme.primaryGreen,
      ConnectionStatus.needsAuth => YingHuiTheme.downloadAmber,
      ConnectionStatus.unreachable => YingHuiTheme.errorRed,
    };
  }

  String _statusLabel(ConnectionResult? result) {
    if (result == null) return '未测试';
    return switch (result.status) {
      ConnectionStatus.ok => '在线',
      ConnectionStatus.needsAuth => '需要登录',
      ConnectionStatus.unreachable => '无法连接',
    };
  }

  @override
  Widget build(BuildContext context) {
    // Delete key (desktop): deletes the last tapped row. The Focus
    // node takes focus when the page opens and again on every row tap,
    // so the key reaches here even after the user has clicked around.
    // With no selection the key does nothing.
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.delete &&
            _selectedId != null) {
          final selected = store.servers
              .where((s) => s.id == _selectedId)
              .firstOrNull;
          if (selected != null) {
            _delete(selected);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('服务器'),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '添加服务器',
              onPressed: () => _pickTypeAndAdd(context),
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            if (store.servers.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '还没有服务器。\n点 + 添加你的 Navidrome、Emby、'
                    'qBittorrent、Transmission 或 aria2 服务器。',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: store.servers.length,
              itemBuilder: (context, i) {
                final server = store.servers[i];
                final result = _results[server.id];
                final testing = _testing.contains(server.id);
                // Last-known version/name from a previous probe, shown
                // until a fresh test in this session replaces it.
                final storedDetail = [
                  if (server.serverVersion != null &&
                      server.serverVersion!.isNotEmpty)
                    'v${server.serverVersion}',
                  if (server.serverName != null &&
                      server.serverName!.isNotEmpty)
                    server.serverName!,
                ].join(' · ');
                final detail = result == null
                    ? (storedDetail.isEmpty ? '' : '\n$storedDetail')
                    : '\n${_statusLabel(result)}: ${result.message}'
                          '${result.serverVersion?.isNotEmpty == true ? ' · v${result.serverVersion}' : ''}'
                          '${result.serverName?.isNotEmpty == true ? ' · ${result.serverName}' : ''}';
                return Dismissible(
                  key: ValueKey(server.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: YingHuiTheme.errorRed,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) => _confirmDelete(server),
                  onDismissed: (_) => store.remove(server.id),
                  child: MouseRegion(
                    onEnter: (_) {
                      if (_isDesktop) {
                        setState(() => _hoveredId = server.id);
                      }
                    },
                    onExit: (_) {
                      if (_isDesktop && _hoveredId == server.id) {
                        setState(() => _hoveredId = null);
                      }
                    },
                    child: GestureDetector(
                      // Right-click (desktop only — touch has no
                      // secondary button) opens the context menu at
                      // the cursor.
                      onSecondaryTapDown: (details) {
                        if (_isDesktop) {
                          _showContextMenu(
                            context,
                            server,
                            details.globalPosition,
                          );
                        }
                      },
                      child: Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.circle,
                            size: 12,
                            color: _statusColor(result),
                          ),
                          title: Text(server.name),
                          subtitle: Text(
                            '${server.type.label} · ${server.baseUrl}$detail',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (testing)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                IconButton(
                                  icon: const Icon(Icons.refresh),
                                  tooltip: '测试连接',
                                  onPressed: () => _test(server),
                                ),
                              // Desktop hover buttons: edit + delete.
                              // IconButtons in the trailing do not
                              // trigger the row's onTap.
                              if (_isDesktop && _hoveredId == server.id) ...[
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  tooltip: '编辑',
                                  onPressed: () =>
                                      _showServerForm(context, server: server),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete),
                                  tooltip: '删除',
                                  onPressed: () => _delete(server),
                                ),
                              ],
                              if (server.isDefault)
                                const Chip(label: Text('默认')),
                            ],
                          ),
                          onTap: () {
                            // Tap still sets the default, as before —
                            // it also remembers the row for Delete.
                            _selectedId = server.id;
                            _focusNode.requestFocus();
                            store.setDefault(server.id);
                          },
                          onLongPress: () =>
                              _showServerForm(context, server: server),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickTypeAndAdd(BuildContext context) async {
    final type = await showDialog<ServerType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('服务器类型'),
        children: ServerType.values
            .map(
              (t) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(t),
                child: Text(t.label),
              ),
            )
            .toList(),
      ),
    );
    if (type == null || !context.mounted) return;
    await _showServerForm(context, type: type);
  }

  Future<void> _showServerForm(
    BuildContext context, {
    ServerType? type,
    Server? server,
  }) async {
    final effectiveType = server?.type ?? type!;
    final nameController = TextEditingController(text: server?.name ?? '');
    final hostController = TextEditingController(text: server?.host ?? '');
    final portController = TextEditingController(
      text: '${server?.port ?? effectiveType.defaultPort}',
    );
    final userController = TextEditingController(text: server?.username ?? '');
    final secretController = TextEditingController(text: server?.token ?? '');
    var testing = false;
    var testResult = '';
    var testOk = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          Future<void> test() async {
            final candidate = Server(
              id:
                  server?.id ??
                  DateTime.now().millisecondsSinceEpoch.toString(),
              type: effectiveType,
              name: nameController.text.trim(),
              host: hostController.text.trim(),
              port:
                  int.tryParse(portController.text.trim()) ??
                  effectiveType.defaultPort,
              username: userController.text.trim(),
              token: secretController.text,
              isDefault: server?.isDefault ?? false,
            );
            setState(() {
              testing = true;
              testResult = '';
            });
            final result = await store.testConnection(candidate);
            setState(() {
              testOk = result.isOk;
              testResult =
                  '${_statusLabel(result)}: ${result.message}'
                  '${result.serverVersion?.isNotEmpty == true ? ' · v${result.serverVersion}' : ''}'
                  '${result.serverName?.isNotEmpty == true ? ' · ${result.serverName}' : ''}';
              testing = false;
            });
          }

          return AlertDialog(
            title: Text(
              server == null ? '添加${effectiveType.label}' : '编辑 ${server.name}',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  TextField(
                    controller: hostController,
                    decoration: const InputDecoration(
                      labelText: '地址（IP、域名或完整链接）',
                    ),
                  ),
                  TextField(
                    controller: portController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                  ),
                  TextField(
                    controller: userController,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  TextField(
                    controller: secretController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码 / Token / 密钥',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (testResult.isNotEmpty)
                    Text(
                      testResult,
                      style: TextStyle(
                        color: testOk
                            ? YingHuiTheme.primaryGreen
                            : YingHuiTheme.downloadAmber,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: testing ? null : test,
                child: testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('测试连接'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final result = Server(
                    id:
                        server?.id ??
                        DateTime.now().millisecondsSinceEpoch.toString(),
                    type: effectiveType,
                    name: nameController.text.trim(),
                    host: hostController.text.trim(),
                    port:
                        int.tryParse(portController.text.trim()) ??
                        effectiveType.defaultPort,
                    username: userController.text.trim(),
                    token: secretController.text,
                    isDefault: server?.isDefault ?? false,
                  );
                  // Emby: a username + secret is an account login, not
                  // an API key — exchange the password for an access
                  // token now, so the saved server actually works. If
                  // login fails the server is saved as entered (the
                  // test result already showed it needs login).
                  var toSave = result;
                  if (effectiveType == ServerType.emby &&
                      result.username.isNotEmpty &&
                      result.token.isNotEmpty) {
                    toSave = await store.loginEmby(result) ?? result;
                  }
                  if (server == null) {
                    await store.add(toSave);
                  } else {
                    await store.update(toSave);
                  }
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }
}
