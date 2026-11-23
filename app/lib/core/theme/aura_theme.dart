import 'package:material_ui/material_ui.dart';

abstract final class AuraTheme {
  static const background = Color(0xFF080D18);
  static const panel = Color(0xFF111A2B);
  static const panelLight = Color(0xFF19263A);
  static const mint = Color(0xFF79E8D4);
  static const violet = Color(0xFFA294FF);
  static const muted = Color(0xFF9BAAC1);
  static const surfaceRaised = Color(0xFF1A2638);

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: mint,
      secondary: violet,
      surface: panel,
      surfaceContainer: Color(0xFF101A2B),
      surfaceContainerHigh: surfaceRaised,
      onSurface: Color(0xFFF3F6FC),
      onPrimary: Color(0xFF07151A),
      onSecondary: Color(0xFF15112A),
      error: Color(0xFFFF8794),
      outline: Color(0xFF344158),
    );
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      dividerColor: Colors.white12,
      visualDensity: VisualDensity.standard,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: Color(0xFFF3F6FC),
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF0D1422),
        indicatorColor: Color(0xFF233D4A),
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xFF0C1422),
        indicatorColor: Color(0xFF23434B),
        selectedIconTheme: IconThemeData(color: mint),
        unselectedIconTheme: IconThemeData(color: muted),
        selectedLabelTextStyle: TextStyle(
          color: mint,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: muted),
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: rounded,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0C1422),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF344158)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF344158)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: mint, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          side: const BorderSide(color: Color(0xFF344158)),
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: mint,
        thumbColor: mint,
        inactiveTrackColor: Color(0xFF344158),
        overlayColor: Color(0x3379E8D4),
      ),
    );
  }
}
