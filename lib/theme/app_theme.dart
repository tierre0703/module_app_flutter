// lib/theme/app_theme.dart
//
// Centralized ThemeData for the whole app (Material 3), driven by the
// SmartHome multi-theme palette system in theme_palettes.dart. The active
// palette (mintFrost/blaze/dust/magentaSurge/lime/noir) picks the
// primary/secondary/tertiary/background/text tokens, so every screen
// following Theme.of(context) re-skins when the theme switcher changes.
//
// A disciplined semantic rule is kept stable across every palette:
//   - green (#00A651) is reserved for "online" connectivity status only
//   - red   (#D32F2F) is reserved for "offline" / alert states only
// Control ON/OFF states still use fill-vs-outline contrast so they never
// collide with the online/offline meaning.
import 'package:flutter/material.dart';

import 'theme_palettes.dart';

/// App-wide semantic colors. Green/grey/red are reserved for connectivity
/// (online / unknown / offline-alert) and never change with the multi-theme,
/// so their meaning stays stable across every palette.
abstract class AppColors {
  static const Color online = Color(0xFF00A651);

  /// Reachability unknown: the module was online, but its 5008 API is
  /// currently broken / not answering.
  static const Color unknown = Color(0xFF757575);
  static const Color offlineAlert = Color(0xFFD32F2F);
}

/// Global theme-mode holder. Kept as a plain [ValueNotifier] (no
/// third-party state management) so the Settings screen can flip
/// Light / Dark / System instantly from anywhere in the widget tree.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);

/// Global application locale holder. Used by the Language settings screen to
/// switch the active language (English / Romanian) at runtime.
final ValueNotifier<Locale> appLocaleNotifier = ValueNotifier<Locale>(
  const Locale('en'),
);

abstract class AppTheme {
  /// Shared label style for extended [FloatingActionButton]s, kept here so all
  /// screens use one consistent bold label.
  static const TextStyle fabLabelStyle =
      TextStyle(fontWeight: FontWeight.w700, fontSize: 15);

  /// Global theme for the currently selected SmartHome palette + brightness.
  static ThemeData get light => _forPalette(Brightness.light);
  static ThemeData get dark => _forPalette(Brightness.dark);

  /// Global theme for an explicit palette + brightness (used so [MaterialApp]
  /// rebuilds when the multi-theme switcher changes the active palette).
  static ThemeData lightFor(HomeThemeId id) =>
      _forPalette(Brightness.light, id);
  static ThemeData darkFor(HomeThemeId id) => _forPalette(Brightness.dark, id);

  static ThemeData _forPalette(Brightness brightness, [HomeThemeId? id]) {
    final bool isLight = brightness == Brightness.light;
    final HomePalette p =
        HomeThemePalettes.byId(id ?? homeThemeIdNotifier.value);
    final Color onSurface = isLight ? p.lightText : p.text;
    final Color background = isLight
        ? p.lightBackgroundGradient.colors.first
        : p.backgroundGradient.colors.first;
    final Color primary = isLight ? p.lightPrimary : p.primary;
    final Color secondary = isLight ? p.lightBlue : p.accentBlue;
    final Color tertiary = isLight ? p.lightViolet : p.accentViolet;

    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      surface: background,
      onSurface: onSurface,
      error: p.danger,
      onError: isLight ? Colors.white : Colors.black,
      outline: onSurface.withValues(alpha: 0.24),
    );
    final Color surfaceAlt = isLight
        ? Colors.black.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.06);
    // Frosted "glass" fill for cards, translucent over the palette base so
    // panels read as subtle glass surfaces.
    final Color glass = isLight
        ? Colors.white.withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.07);
    final Color accent = colorScheme.primary;
    final Color onAccent = colorScheme.onPrimary;

    final ThemeData base = ThemeData(
        useMaterial3: true, brightness: brightness, colorScheme: colorScheme);
    final TextTheme textTheme = base.textTheme.apply(
      bodyColor: onSurface,
      displayColor: onSurface,
    );

    return base.copyWith(
      // Solid palette base as the app background (no external backdrop).
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700, fontSize: 22),
        iconTheme: IconThemeData(color: onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceAlt,
        surfaceTintColor: Colors.transparent,
        indicatorColor: onSurface.withValues(alpha: 0.1),
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: onSurface,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: onSurface.withValues(
                alpha: states.contains(WidgetState.selected) ? 1 : 0.5),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        // Glass panel (matches Home): translucent over the backdrop, soft
        // outer shadow, hairline border, generous radius.
        color: glass,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.20),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: onSurface.withValues(alpha: 0.10)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurface,
        textColor: onSurface,
        minVerticalPadding: 12,
      ),
      dividerTheme:
          DividerThemeData(color: onSurface.withValues(alpha: 0.1), space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: accent.withValues(alpha: 0.3),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: accent,
          side: BorderSide(color: accent, width: 1.4),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          minimumSize: const Size(48, 48),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: accent,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.online
              : onSurface.withValues(alpha: 0.6),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.online.withValues(alpha: 0.4)
              : onSurface.withValues(alpha: 0.15),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: onSurface.withValues(alpha: 0.15),
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
        valueIndicatorColor: accent,
        valueIndicatorTextStyle:
            TextStyle(color: onAccent, fontWeight: FontWeight.w700),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : Colors.transparent,
        ),
        checkColor: WidgetStateProperty.all(onAccent),
        side: BorderSide(color: accent, width: 1.4),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : onSurface.withValues(alpha: 0.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceAlt,
        selectedColor: accent,
        labelStyle: TextStyle(color: onSurface, fontWeight: FontWeight.w600),
        secondaryLabelStyle:
            TextStyle(color: onAccent, fontWeight: FontWeight.w600),
        side: BorderSide(color: accent.withValues(alpha: 0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: onSurface,
          selectedForegroundColor: onAccent,
          selectedBackgroundColor: accent,
          side: BorderSide(color: accent, width: 1.2),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: onSurface, width: 1.6),
        ),
        labelStyle: TextStyle(color: onSurface.withValues(alpha: 0.7)),
        hintStyle: TextStyle(color: onSurface.withValues(alpha: 0.4)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isLight ? glass.withValues(alpha: 0.96) : glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isLight
            ? Colors.white.withValues(alpha: 0.9)
            : Colors.black.withValues(alpha: 0.9), //glass,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: accent,
        contentTextStyle:
            TextStyle(color: onAccent, fontWeight: FontWeight.w600),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: onAccent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: onSurface),
    );
  }
}

/// Standard spacing constants used across every screen for a consistent
/// rhythm: 16dp outer padding, 12dp between cards.
abstract class AppSpacing {
  static const double outerPadding = 16;
  static const double betweenCards = 12;
}
