// Desktop-only HTTP proxy (Settings -> Dio clients).
//
// - ProxyConfig: enabled/host/port, persisted in shared_preferences
//   under yinghui_proxy_*, validated (blank host / bad port = no proxy).
// - DioProxy: every service client registers its Dio in the
//   constructor; update() re-applies the config to all of them.
// - Scope: Dio only. media_kit 1.2.6 exposes no http-proxy option,
//   so playback streams do NOT go through the proxy.
// - The Settings section shows only on desktop (Windows/macOS/Linux).
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/proxy_config.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/settings/settings_page.dart';

void main() {
  group('ProxyConfig', () {
    test('valid only when enabled with a host and a port', () {
      expect(const ProxyConfig().isValid, isFalse);
      expect(
        const ProxyConfig(enabled: true, host: '', port: 7890).isValid,
        isFalse,
      );
      expect(
        const ProxyConfig(enabled: true, host: '127.0.0.1', port: 0).isValid,
        isFalse,
      );
      expect(
        const ProxyConfig(
          enabled: true,
          host: '127.0.0.1',
          port: 70000,
        ).isValid,
        isFalse,
      );
      const config = ProxyConfig(enabled: true, host: '127.0.0.1', port: 7890);
      expect(config.isValid, isTrue);
      expect(config.address, '127.0.0.1:7890');
    });

    test('copyWith + equality', () {
      const base = ProxyConfig(enabled: true, host: '127.0.0.1', port: 7890);
      expect(
        base.copyWith(port: 8080),
        const ProxyConfig(enabled: true, host: '127.0.0.1', port: 8080),
      );
      expect(base.copyWith(enabled: false).isValid, isFalse);
    });
  });

  group('SettingsService proxy persistence', () {
    test('round-trip through shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      expect(settings.proxyConfig, const ProxyConfig());

      await settings.setProxyEnabled(true);
      await settings.setProxyHost('127.0.0.1');
      await settings.setProxyPort(7890);

      final reloaded = SettingsService();
      await reloaded.load();
      expect(
        reloaded.proxyConfig,
        const ProxyConfig(enabled: true, host: '127.0.0.1', port: 7890),
      );

      // Host is trimmed, port is clamped to 0..65535.
      await reloaded.setProxyHost('  10.0.0.1  ');
      await reloaded.setProxyPort(70000);
      expect(reloaded.proxyConfig.host, '10.0.0.1');
      expect(reloaded.proxyConfig.port, 65535);
    });
  });

  group('DioProxy', () {
    setUp(DioProxy.resetForTest);
    tearDown(DioProxy.resetForTest);

    // A local HTTP proxy: records every request it receives and
    // answers 200. HttpClient.findProxy is setter-only in this Dart,
    // so the wiring is verified end to end — a request must arrive
    // at the proxy when enabled, and must not when disabled.
    late HttpServer proxy;
    late List<Uri> seenUris;

    setUp(() async {
      seenUris = [];
      proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((request) async {
        seenUris.add(request.uri);
        request.response
          ..statusCode = HttpStatus.ok
          ..write('proxied')
          ..close();
      });
    });

    tearDown(() async {
      await proxy.close(force: true);
    });

    // Restores real HttpClient behaviour: flutter_test's binding
    // answers every HttpClient request with 400, so a real proxy
    // round-trip needs real overrides scoped to the Dio call.
    Future<Response<String>> getReal(Dio dio, String url) =>
        HttpOverrides.runWithHttpOverrides(
          () => dio.get<String>(url),
          _RealHttpOverrides(),
        );

    test('enabled config routes the request through the proxy', () async {
      DioProxy.update(
        ProxyConfig(enabled: true, host: '127.0.0.1', port: proxy.port),
      );
      final dio = Dio();
      DioProxy.apply(dio);
      final response = await getReal(dio, 'http://example.com/hello');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.data, 'proxied');
      expect(seenUris, hasLength(1));
      expect(seenUris.single.host, 'example.com');
    });

    test('disabled config means DIRECT (no request at the proxy)', () async {
      final dio = Dio();
      DioProxy.apply(dio);
      // Closed port: DIRECT fails fast with connection refused.
      await expectLater(
        getReal(dio, 'http://127.0.0.1:1/'),
        throwsA(isA<DioException>()),
      );
      expect(seenUris, isEmpty);
    });

    test('update() re-applies to already-registered Dios', () async {
      final dio = Dio();
      DioProxy.apply(dio);
      // Starts DIRECT: closed port, connection refused.
      await expectLater(
        getReal(dio, 'http://127.0.0.1:1/'),
        throwsA(isA<DioException>()),
      );
      expect(seenUris, isEmpty);
      // Enable the proxy: the same Dio now routes through it.
      DioProxy.update(
        ProxyConfig(enabled: true, host: '127.0.0.1', port: proxy.port),
      );
      final response = await getReal(dio, 'http://example.com/hello');
      expect(response.statusCode, HttpStatus.ok);
      expect(seenUris, hasLength(1));
      // Disable again: back to DIRECT.
      DioProxy.update(const ProxyConfig());
      await expectLater(
        getReal(dio, 'http://127.0.0.1:1/'),
        throwsA(isA<DioException>()),
      );
      expect(seenUris, hasLength(1));
    });

    test('enabled but invalid config stays DIRECT', () async {
      DioProxy.update(const ProxyConfig(enabled: true, host: '', port: 7890));
      final dio = Dio();
      DioProxy.apply(dio);
      await expectLater(
        getReal(dio, 'http://127.0.0.1:1/'),
        throwsA(isA<DioException>()),
      );
      expect(seenUris, isEmpty);
    });
  });

  group('SettingsPage proxy section', () {
    Future<void> pumpSettings(
      WidgetTester tester, {
      required SettingsService settings,
    }) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            settings: settings,
            store: ServerStore(database: db),
            history: PlaybackStore(db),
            downloadRepo: RealDownloadRepository(
              store: ServerStore(database: db),
              database: db,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('desktop shows the proxy section', (tester) async {
      // flutter_test checks foundation debug variables after the
      // test body but before tearDown, so the override must be
      // reset here, not in a tearDown.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.load();
        await pumpSettings(tester, settings: settings);

        expect(find.text('代理'), findsOneWidget);
        expect(find.text('使用 HTTP 代理'), findsOneWidget);
        // Fields only appear once the switch is on.
        expect(find.text('代理地址'), findsNothing);
        expect(find.text('代理端口'), findsNothing);

        await tester.tap(find.text('使用 HTTP 代理'));
        await tester.pump();
        expect(find.text('代理地址'), findsOneWidget);
        expect(find.text('代理端口'), findsOneWidget);
        expect(
          find.text('服务器连接（Navidrome、Emby、下载器）走代理；音乐和视频播放不走代理。'),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('mobile hides the proxy section', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      await pumpSettings(tester, settings: settings);

      expect(find.text('代理'), findsNothing);
      expect(find.text('使用 HTTP 代理'), findsNothing);
    });
  });
}

/// Real HttpClient behaviour for the DioProxy tests (see above).
class _RealHttpOverrides extends HttpOverrides {}
