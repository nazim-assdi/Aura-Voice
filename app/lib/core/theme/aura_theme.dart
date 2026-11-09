import 'package:flutter/material.dart';

abstract final class AuraTheme {
  static const background = Color(0xFF080D18);
  static const panel = Color(0xFF111A2B);
  static const panelLight = Color(0xFF18243A);
  static const mint = Color(0xFF73E2D1);
  static const violet = Color(0xFF9A8BFF);
  static const muted = Color(0xFF91A0B7);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: mint,
      secondary: violet,
      surface: panel,
      onSurface: Color(0xFFF3F6FC),
      onPrimary: Color(0xFF07151A),
      onSecondary: Color(0xFF15112A),
      error: Color(0xFFFF7D8A),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      dividerColor: Colors.white12,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: Color(0xFFF3F6FC),
        elevation: 0,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF0D1422),
        indicatorColor: Color(0xFF233D4A),
      ),
    );
  }
}
