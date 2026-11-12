import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:drift/native.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/settings/settings_page.dart';

void main() {
  group('SettingsService persistence round-trip', () {
    test('theme mode, seed preset, font scale, quality, polling', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();

      // Defaults.
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.seedIndex, 0);
      expect(settings.seedColor, seedPresets.first.color);
      expect(settings.fontScale, 1.0);
      expect(settings.videoQuality, VideoQualityPreference.auto);
      expect(settings.audioMaxBitrate, 0);
      expect(settings.subtitlesEnabled, isTrue);
      expect(settings.resumePlayback, isTrue);
      expect(settings.pollingIntervalSeconds, 5);

      // Change everything, then reload from the same prefs store.
      await settings.setThemeMode(ThemeMode.dark);
      await settings.setSeedIndex(2);
      await settings.setFontScale(1.2);
      await settings.setVideoQuality(VideoQualityPreference.p720);
      await settings.setAudioMaxBitrate(192);
      await settings.setSubtitlesEnabled(true);
      await settings.setResumePlayback(false);
      await settings.setPollingIntervalSeconds(30);
      await settings.setDynamicColor(true);

      final reloaded = SettingsService(prefs: prefs);
      await reloaded.load();
      expect(reloaded.themeMode, ThemeMode.dark);
      expect(reloaded.seedIndex, 2);
      expect(reloaded.seedColor, seedPresets[2].color);
      expect(reloaded.fontScale, 1.2);
      expect(reloaded.videoQuality, VideoQualityPreference.p720);
      expect(reloaded.audioMaxBitrate, 192);
      expect(reloaded.subtitlesEnabled, isTrue);
      expect(reloaded.resumePlayback, isFalse);
      expect(reloaded.pollingIntervalSeconds, 30);
      expect(reloaded.dynamicColor, isTrue);
    });

    test('font scale clamps to 0.8–1.3; polling stores the value', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.setFontScale(2.0);
      expect(settings.fontScale, 1.3);
      await settings.setFontScale(0.1);
      expect(settings.fontScale, 0.8);
      await settings.setPollingIntervalSeconds(10);
      expect(settings.pollingIntervalSeconds, 10);
      await settings.setPollingIntervalSeconds(30);
      expect(settings.pollingIntervalSeconds, 30);
    });

    test('search history dedupes and caps at 20', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
      await settings.recordSearch('a');
      await settings.recordSearch('b');
      await settings.recordSearch('a');
      expect(settings.searchHistory, ['a', 'b']);
      for (var i = 0; i < 25; i++) {
        await settings.recordSearch('q$i');
      }
      expect(settings.searchHistory.length, 20);
      expect(settings.searchHistory.first, 'q24');
      await settings.clearSearchHistory();
      expect(settings.searchHistory, isEmpty);
    });

    test('effectiveVideoQuality: auto -> direct', () async {
      final settings = SettingsService();
      await settings.setVideoQuality(VideoQualityPreference.auto);
      expect(settings.effectiveVideoQuality, VideoQuality.direct);
      await settings.setVideoQuality(VideoQualityPreference.p1080);
      expect(settings.effectiveVideoQuality, VideoQuality.p1080);
    });
  });

  group('formatBytes', () {
    test('bytes / KB / MB', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(5 * 1024 * 1024 + 512 * 1024), '5.5 MB');
    });
  });

  group('appVersionLabel', () {
    test('dev -> 开发版, tag -> the tag', () {
      expect(appVersionLabel('dev'), '开发版');
      expect(appVersionLabel('v0.1'), 'v0.1');
      expect(appVersionLabel(''), '');
    });
  });

  group('SettingsPage widget', () {
    testWidgets('renders all five sections', (tester) async {
      // Tall surface: the page is a lazy ListView, so off-screen
      // sections are only built when they fit in the viewport.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs: prefs);
      await settings.load();
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

      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Playback'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Data'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.text('影汇 YingHui'), findsOneWidget);
      expect(find.text('Version 开发版'), findsOneWidget);
      expect(find.text('Servers'), findsOneWidget);
    });
  });
}
