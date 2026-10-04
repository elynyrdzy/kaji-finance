import 'package:flutter/material.dart';
import '../utils/app_motion.dart';
import 'app_colors.dart';
import 'app_text_styles.dart';

/// Tema tunggal Kaji Finance — DARK ONLY (§3).
class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.surface,
      canvasColor: AppColors.surface,
      splashFactory: InkRipple.splashFactory,
      colorScheme: const ColorScheme.dark(
        surface: Color(0xFF131316),
        primary: AppColors.tertiary,
        onPrimary: AppColors.onTertiary,
        secondary: AppColors.secondary,
        error: AppColors.error,
        onSurface: Color(0xFFE4E1E5),
        outline: Color(0xFF919095),
      ),
      textTheme: TextTheme(
        bodyMedium: AppTextStyles.bodyMd(),
        bodySmall: AppTextStyles.bodySm(),
        titleMedium: AppTextStyles.headlineMd(),
        titleLarge: AppTextStyles.headlineLg(),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF131316),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      dividerColor: AppColors.outlineVariant,
      splashColor: Colors.white.withValues(alpha: 0.04),
      highlightColor: Colors.transparent,
      // Transisi pegas app-wide ala Telegram (lihat AppMotion).
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SpringPageTransitionsBuilder(),
          TargetPlatform.iOS: SpringPageTransitionsBuilder(),
          TargetPlatform.macOS: SpringPageTransitionsBuilder(),
          TargetPlatform.windows: SpringPageTransitionsBuilder(),
          TargetPlatform.linux: SpringPageTransitionsBuilder(),
          TargetPlatform.fuchsia: SpringPageTransitionsBuilder(),
        },
      ),
    );
  }
}
