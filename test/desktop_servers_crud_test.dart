import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/models/connection_result.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/servers/servers_page.dart';

Server _server({
  String id = 'srv-1',
  ServerType type = ServerType.emby,
  String name = 'Emby',
  String host = 'https://cf.imetyou.top',
  bool isDefault = true,
}) => Server(
  id: id,
  type: type,
  name: name,
  host: host,
  port: 443,
  isDefault: isDefault,
);

/// In-memory secure storage for tests. The real plugin throws
/// MissingPluginException in unit tests and its write hangs forever in
/// widget tests on this machine, so a store can never be awaited
/// without this. The store under test accepts it via its constructor.
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }
}

ServerStore _store(
  AppDatabase db, {
  Future<ConnectionResult> Function(Server)? connectionTester,
}) => ServerStore(
  database: db,
  secureStorage: _FakeSecureStorage(),
  connectionTester: connectionTester,
);

void main() {
  group('desktop Servers CRUD', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    /// Runs [body] with the platform override set, resetting it before
    /// the test body returns — flutter_test checks foundation debug
    /// variables after the test body but before tearDown, so a tearDown
    /// reset would be too late.
    Future<void> withPlatform(
      TargetPlatform platform,
      Future<void> Function() body,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    Future<ServerStore> twoServers({
      Future<ConnectionResult> Function(Server)? connectionTester,
    }) async {
      final store = _store(db, connectionTester: connectionTester);
      await store.add(_server());
      await store.add(
        _server(
          id: 'srv-2',
          type: ServerType.navidrome,
          name: 'Navidrome',
          host: 'https://sg.kass.qzz.io/',
          isDefault: false,
        ),
      );
      return store;
    }

    Future<void> pumpPage(WidgetTester tester, ServerStore store) async {
      await tester.pumpWidget(MaterialApp(home: ServersPage(store: store)));
      await tester.pump();
    }

    Future<void> rightClickRow(WidgetTester tester, String name) async {
      await tester.tapAt(
        tester.getCenter(find.text(name)),
        buttons: kSecondaryButton,
      );
      // Let the menu's entrance animation finish: while it is still
      // scaling in, a tap at the item's final position lands outside
      // the menu and just dismisses it.
      await tester.pumpAndSettle();
    }

    /// Moves a real mouse pointer over [finder]'s centre, which is
    /// what fires MouseRegion.onEnter in widget tests.
    Future<void> hoverOver(WidgetTester tester, Finder finder) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: tester.getCenter(finder));
      await gesture.moveTo(tester.getCenter(finder));
      await tester.pump();
    }

    testWidgets('right-click opens a menu with the four entries', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await rightClickRow(tester, 'Emby');

        expect(find.text('设为默认'), findsOneWidget);
        expect(find.text('编辑'), findsOneWidget);
        expect(find.text('测试连接'), findsOneWidget);
        expect(find.text('删除'), findsOneWidget);
      });
    });

    testWidgets('menu 编辑 opens the server form', (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await rightClickRow(tester, 'Emby');
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();

        expect(find.text('编辑 Emby'), findsOneWidget);
      });
    });

    testWidgets('menu 删除 shows the confirm dialog, then deletes', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await rightClickRow(tester, 'Emby');
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();

        expect(find.text('删除 Emby？'), findsOneWidget);
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();

        expect(store.servers.map((s) => s.id), ['srv-2']);
        expect(find.text('Emby'), findsNothing);
      });
    });

    testWidgets('menu 设为默认 sets the default', (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        expect(store.servers[0].isDefault, isTrue);
        expect(store.servers[1].isDefault, isFalse);

        await rightClickRow(tester, 'Navidrome');
        await tester.tap(find.text('设为默认'));
        await tester.pumpAndSettle();

        expect(store.servers[0].isDefault, isFalse);
        expect(store.servers[1].isDefault, isTrue);
      });
    });

    testWidgets('menu 测试连接 runs the probe', (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        var probed = 0;
        final store = await twoServers(
          connectionTester: (_) async {
            probed++;
            return ConnectionResult.ok();
          },
        );
        await pumpPage(tester, store);
        await rightClickRow(tester, 'Emby');
        await tester.tap(find.text('测试连接'));
        await tester.pumpAndSettle();

        expect(probed, 1);
        expect(find.textContaining('在线'), findsOneWidget);
      });
    });

    testWidgets('hover shows edit and delete buttons on desktop', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        expect(find.byTooltip('编辑'), findsNothing);
        expect(find.byTooltip('删除'), findsNothing);

        await hoverOver(tester, find.text('Emby'));
        expect(find.byTooltip('编辑'), findsOneWidget);
        expect(find.byTooltip('删除'), findsOneWidget);
      });
    });

    testWidgets('hover edit button opens the form without setting default', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await hoverOver(tester, find.text('Navidrome'));
        await tester.tap(find.byTooltip('编辑'));
        await tester.pumpAndSettle();

        // The row was not tapped, so the default is untouched.
        expect(store.servers[0].isDefault, isTrue);
        expect(store.servers[1].isDefault, isFalse);
        expect(find.text('编辑 Navidrome'), findsOneWidget);
      });
    });

    testWidgets('hover delete button opens the confirm dialog', (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await hoverOver(tester, find.text('Emby'));
        await tester.tap(find.byTooltip('删除'));
        await tester.pumpAndSettle();

        expect(find.text('删除 Emby？'), findsOneWidget);
      });
    });

    testWidgets('edit and delete buttons are absent on mobile', (tester) async {
      await withPlatform(TargetPlatform.android, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await hoverOver(tester, find.text('Emby'));

        expect(find.byTooltip('编辑'), findsNothing);
        expect(find.byTooltip('删除'), findsNothing);
      });
    });

    testWidgets('Delete key after tapping a row opens the delete confirm', (
      tester,
    ) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await tester.tap(find.text('Navidrome'));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();

        expect(find.text('删除 Navidrome？'), findsOneWidget);
        // Cancel: the row survives.
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(store.servers.length, 2);
      });
    });

    testWidgets('Delete key with no selection does nothing', (tester) async {
      await withPlatform(TargetPlatform.windows, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();

        expect(find.text('删除 Emby？'), findsNothing);
        expect(find.text('删除 Navidrome？'), findsNothing);
      });
    });

    testWidgets('long-press edit still works on mobile', (tester) async {
      await withPlatform(TargetPlatform.android, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await tester.longPress(find.text('Emby'));
        await tester.pumpAndSettle();

        expect(find.text('编辑 Emby'), findsOneWidget);
      });
    });

    testWidgets('swipe delete still works on mobile', (tester) async {
      await withPlatform(TargetPlatform.android, () async {
        final store = await twoServers();
        await pumpPage(tester, store);
        await tester.drag(find.text('Emby'), const Offset(-400, 0));
        await tester.pumpAndSettle();

        expect(find.text('删除 Emby？'), findsOneWidget);
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();

        expect(store.servers.map((s) => s.id), ['srv-2']);
      });
    });
  });
}
