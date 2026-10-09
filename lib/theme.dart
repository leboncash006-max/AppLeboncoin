import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Couleurs et thèmes de l'appli (« outil pro de revendeur »).
class AppColors {
  static const accent = Color(0xFF7C5CFF);
  static const accentDeep = Color(0xFF4F33C9);
  static const good = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const bad = Color(0xFFEF4444);
  static const neutral = Color(0xFF8A8AA3);

  static const darkBg = Color(0xFF0A0A12);
  static const darkSurface = Color(0xFF14141F);
  static const darkSurfaceHigh = Color(0xFF1C1C2B);
  static const lightBg = Color(0xFFF4F3FA);
}

const double kRadius = 20;

/// Chiffres alignés (prix, marges).
const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xFF9B82FF) : AppColors.accentDeep,
    surface: dark ? AppColors.darkSurface : Colors.white,
    surfaceContainerLowest: dark ? AppColors.darkBg : AppColors.lightBg,
    surfaceContainerLow: dark ? const Color(0xFF111119) : const Color(0xFFF8F7FC),
    surfaceContainer: dark ? AppColors.darkSurface : Colors.white,
    surfaceContainerHigh: dark ? AppColors.darkSurfaceHigh : const Color(0xFFEDEBF7),
    surfaceContainerHighest: dark ? const Color(0xFF25253A) : const Color(0xFFE4E1F3),
    outlineVariant: dark ? const Color(0xFF2A2A3D) : const Color(0xFFDCD9EA),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final heading = GoogleFonts.manrope();

  return base.copyWith(
    scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.merge(heading).copyWith(fontWeight: FontWeight.w800),
      displayMedium: text.displayMedium?.merge(heading).copyWith(fontWeight: FontWeight.w800),
      displaySmall: text.displaySmall?.merge(heading).copyWith(fontWeight: FontWeight.w800),
      headlineMedium: text.headlineMedium?.merge(heading).copyWith(fontWeight: FontWeight.w800),
      headlineSmall: text.headlineSmall?.merge(heading).copyWith(fontWeight: FontWeight.w700),
      titleLarge: text.titleLarge?.merge(heading).copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: heading.copyWith(
          fontSize: 22, fontWeight: FontWeight.w800, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.6 : 1)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.darkSurfaceHigh : Colors.white,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: dark ? AppColors.darkSurfaceHigh : const Color(0xFFF1EFF9),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// Verdict et couleur selon la marge (mêmes seuils que la v1).
({String label, Color color, IconData icon}) verdictFor(double? margin, double minMargin) {
  if (margin == null) {
    return (label: 'Non estimé', color: AppColors.neutral, icon: Icons.help_outline);
  }
  if (margin >= minMargin) {
    return (label: 'Bonne affaire', color: AppColors.good, icon: Icons.trending_up);
  }
  if (margin >= 0) {
    return (label: 'Marge trop faible', color: AppColors.warn, icon: Icons.trending_flat);
  }
  return (label: 'Pas rentable', color: AppColors.bad, icon: Icons.trending_down);
}

String euros(double? v, {bool signed = false}) {
  if (v == null) return '—';
  final r = v.round();
  final s = r.abs().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]} ');
  final sign = r < 0 ? '−' : (signed && r > 0 ? '+' : '');
  return '$sign$s €';
}

String shortDate(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (day == today) return "Aujourd'hui $hm";
  if (day == today.subtract(const Duration(days: 1))) return 'Hier $hm';
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year % 100} $hm';
}
