import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Typography scale ported from the HTML design's Tailwind fontSize config.
///
/// Font dibundel lokal (assets/fonts, tanpa unduhan runtime) agar klaim
/// offline-first utuh — lihat `flutter: fonts` di pubspec.yaml.
class AppTextStyles {
  AppTextStyles._();

  static TextStyle _inter(
    double size,
    double height,
    FontWeight weight, {
    double letterSpacing = 0,
    Color? color,
  }) =>
      TextStyle(
        fontFamily: 'Inter',
        fontSize: size,
        height: height / size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? AppColors.onSurface,
      );

  static TextStyle _mono(
    double size,
    double height,
    FontWeight weight, {
    double letterSpacing = 0,
    Color? color,
  }) =>
      TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: size,
        height: height / size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color ?? AppColors.onSurface,
      );

  static TextStyle labelCaps({Color? color}) => _inter(
        11,
        14,
        FontWeight.w600,
        letterSpacing: 0.66,
        color: color ?? AppColors.outline,
      ).copyWith(fontFeatures: const []);

  static TextStyle labelSm({Color? color}) =>
      _inter(12, 16, FontWeight.w500, color: color);

  static TextStyle bodySm({Color? color}) => _inter(
        12,
        16,
        FontWeight.w400,
        letterSpacing: 0.12,
        color: color ?? AppColors.outline,
      );

  static TextStyle bodyMd({Color? color}) =>
      _inter(14, 20, FontWeight.w400, color: color);

  static TextStyle headlineSm({Color? color}) =>
      _inter(15, 20, FontWeight.w600, color: color);

  static TextStyle headlineMd({Color? color}) =>
      _inter(18, 24, FontWeight.w600, letterSpacing: -0.18, color: color);

  static TextStyle headlineLg({Color? color}) =>
      _inter(24, 30, FontWeight.w600, letterSpacing: -0.48, color: color);

  static TextStyle displayCurrencyMobile({Color? color}) =>
      _inter(28, 34, FontWeight.w700, letterSpacing: -0.56, color: color);

  static TextStyle displayCurrency({Color? color}) =>
      _inter(32, 38, FontWeight.w700, letterSpacing: -0.96, color: color);

  static TextStyle tabularAmount({Color? color}) =>
      _mono(14, 18, FontWeight.w500, letterSpacing: -0.28, color: color);

  static TextStyle tabularAmountLg({Color? color}) =>
      _mono(18, 24, FontWeight.w600, letterSpacing: -0.36, color: color);
}
