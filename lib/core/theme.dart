import 'package:flutter/material.dart';

/// 影汇 YingHui theme — M3, dark-first, seed-colour driven.
///
/// Dark (default): background #0F1013, cards #1A1C22, primary Emby
/// green #52B54B (the default seed), download amber #F5A623.
/// Light: same seed, pale mint container tones (#C8E6C9 family, the
/// logo background). Content is the lead; the UI recedes.
///
/// [build] takes the seed + brightness so Settings (seed presets,
/// theme mode) actually drives the app. [dynamicScheme] is the
/// Android 12+ system colour scheme when dynamic colour is on.
class YingHuiTheme {
  static const Color background = Color(0xFF0F1013);
  static const Color card = Color(0xFF1A1C22);
  static const Color primaryGreen = Color(0xFF52B54B);
  static const Color downloadAmber = Color(0xFFF5A623);
  static const Color errorRed = Color(0xFFFF5A5A);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFD6D8DE);
  static const Color textMuted = Color(0xFF8A8E99);

  /// Light-theme scaffold / card colours (pale mint, logo family).
  static const Color lightBackground = Color(0xFFF6F8F6);
  static const Color lightCard = Colors.white;

  static ThemeData build({
    required Color seed,
    required Brightness brightness,
    ColorScheme? dynamicScheme,
  }) {
    final dark = brightness == Brightness.dark;
    final scheme =
        dynamicScheme ??
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? background : lightBackground,
      cardColor: dark ? card : lightCard,
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? background : lightBackground,
        foregroundColor: dark ? textPrimary : Colors.black87,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: dark ? card : lightCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 0,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: dark ? card : const Color(0xFFE8EDE8),
        selectedColor: scheme.primary,
        labelStyle: TextStyle(
          color: dark ? textPrimary : Colors.black87,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide.none,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? background : lightBackground,
        indicatorColor: scheme.primary.withValues(alpha: 0.25),
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark ? background : lightBackground,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: TextStyle(color: scheme.primary),
        unselectedIconTheme: IconThemeData(
          color: dark ? textMuted : Colors.black54,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: dark ? textMuted : Colors.black54,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.primary : null,
        ),
      ),
      textTheme: TextTheme(
        titleLarge: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        bodyMedium: const TextStyle(fontSize: 15),
        bodySmall: TextStyle(
          fontSize: 13,
          color: dark ? textMuted : Colors.black54,
        ),
      ),
    );
  }

  /// Backwards-compatible dark theme with the default seed.
  static ThemeData get dark =>
      build(seed: primaryGreen, brightness: Brightness.dark);

  static ThemeData get light =>
      build(seed: primaryGreen, brightness: Brightness.light);
}
