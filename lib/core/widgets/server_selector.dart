import 'package:flutter/material.dart';

import '../../core/models/server.dart';

/// Per-page server selector, shared by the Music, Video and Downloads
/// pages (one instance per page, each with its own persisted selection).
///
/// A compact dropdown: "全部" first (all servers of the page's type,
/// merged — the behaviour before this selector existed), then one entry
/// per server of that type, then a "管理服务器" entry that opens the
/// Servers page. [selectedId] is null for "全部".
///
/// The selector never invents a selection: if [selectedId] names a
/// server that is no longer in [servers] (deleted), it displays "全部".
/// The page owns that fallback and clears the persisted value.
class ServerSelector extends StatelessWidget {
  const ServerSelector({
    super.key,
    required this.servers,
    required this.selectedId,
    required this.onSelected,
    required this.onManageServers,
    this.showType = false,
  });

  /// Servers of the page's type, in store order.
  final List<Server> servers;

  /// The selected server id, or null for "全部".
  final String? selectedId;

  /// Called with the picked server id, or null for "全部".
  final ValueChanged<String?> onSelected;

  /// Called when the "管理服务器" entry is picked (not a selection).
  final VoidCallback onManageServers;

  /// Show each server's type next to its name (Downloads: qB /
  /// Transmission / aria2 share one list).
  final bool showType;

  /// Sentinel value of the "管理服务器" menu item. Never a real id.
  static const String manageValue = '__manage__';

  @override
  Widget build(BuildContext context) {
    final effective =
        selectedId != null && servers.any((s) => s.id == selectedId)
        ? selectedId
        : null;
    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 18),
        const SizedBox(width: 4),
        Expanded(
          child: DropdownButton<String?>(
            key: const ValueKey('server-selector'),
            value: effective,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('全部')),
              ...servers.map(
                (s) => DropdownMenuItem<String?>(
                  value: s.id,
                  child: Text(
                    showType ? '${s.name} · ${s.type.label}' : s.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const DropdownMenuItem<String?>(
                value: manageValue,
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('管理服务器'),
                  ],
                ),
              ),
            ],
            onChanged: (value) {
              if (value == manageValue) {
                onManageServers();
              } else {
                onSelected(value);
              }
            },
          ),
        ),
      ],
    );
  }
}
