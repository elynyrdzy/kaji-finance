import 'package:flutter/material.dart';

/// Token warna terpusat Kaji Finance — DARK ONLY (§3).
///
/// Tidak ada cabang light/system di sini. Semua widget wajib memakai
/// token ini, bukan hardcode warna, agar palet tetap satu sumber.
class AppColors {
  AppColors._();

  static const surface = Color(0xFF131316);
  static const surfaceDim = Color(0xFF131316);
  static const surfaceBright = Color(0xFF39393C);
  static const surfaceContainerLowest = Color(0xFF0E0E11);
  static const surfaceContainerLow = Color(0xFF1B1B1E);
  static const surfaceContainer = Color(0xFF1F1F22);
  static const surfaceContainerHigh = Color(0xFF2A2A2D);
  static const surfaceContainerHighest = Color(0xFF353437);
  static const surfaceVariant = Color(0xFF353437);

  static const onSurface = Color(0xFFE4E1E5);
  static const onSurfaceVariant = Color(0xFFC8C5CA);
  static const outline = Color(0xFF919095);
  static const outlineVariant = Color(0xFF47464A);

  static const primary = Color(0xFFC8C6C8);
  static const primaryFixed = Color(0xFFE5E1E4);
  static const onPrimaryFixed = Color(0xFF1C1B1D);
  static const primaryContainer = Color(0xFF09090B);
  static const inversePrimary = Color(0xFF5F5E60);

  static const secondary = Color(0xFFC6C6C7);
  static const secondaryContainer = Color(0xFF454747);

  static const tertiary = Color(0xFF4EDEA3);
  static const onTertiary = Color(0xFF003824);
  static const tertiaryContainer = Color(0xFF000C05);

  static const error = Color(0xFFE54D4D);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF93000A);

  static const List<Color> chartPalette = [
    Color(0xFFE4E1E5),
    Color(0xFF919095),
    Color(0xFF5F5E60),
    Color(0xFF353437),
    Color(0xFF2A2A2D),
  ];
}
