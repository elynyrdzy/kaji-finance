import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// Sistem gerak Kaji Finance — diinspirasi fisika Telegram:
/// kurva pegas, durasi pendek, dan haptic yang menyertai aksi.
///
/// Semua durasi/kurva TERPUSAT di sini agar gerak konsisten di semua layar.
class AppMotion {
  AppMotion._();

  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 380);

  /// Tekanan taktil (kartu, tombol).
  static const press = Duration(milliseconds: 120);
  static const pressRelease = Duration(milliseconds: 180);

  /// Pil navigasi bawah.
  static const nav = Duration(milliseconds: 180);

  /// Tombol keypad.
  static const key = Duration(milliseconds: 100);

  /// Transisi masuk layar.
  static const entrance = Duration(milliseconds: 350);

  /// Lompat tab bawah (fade tipis per tab).
  static const tab = Duration(milliseconds: 140);

  /// Goyangan saat PIN salah.
  static const shake = Duration(milliseconds: 420);

  /// Dentang celebration saat goal mencapai 100%.
  static const celebrate = Duration(milliseconds: 550);

  /// Denyut empty-state.
  static const emptyPulse = Duration(milliseconds: 2400);

  /// Stagger: jeda per item + batas atas jeda total.
  static const staggerStep = Duration(milliseconds: 45);
  static const staggerMax = Duration(milliseconds: 360);

  /// Berapa item pertama yang boleh staggering. Item setelah ini tampil
  /// langsung — mencegah puluhan layer fade menyala bersamaan.
  static const staggerCap = 8;

  /// Jeda wajar sebelum prompt biometrik otomatis (bukan animasi).
  static const bioGrace = Duration(milliseconds: 400);

  /// Debounce pencarian (bukan animasi).
  static const searchDebounce = Duration(milliseconds: 250);

  /// Jendela 7-ketuk untuk membuka Debug (bukan animasi).
  static const debugTapWindow = Duration(milliseconds: 800);

  /// Jeda stagger untuk item [index]. Item di luar [staggerCap] tidak
  /// lagi dianimasikan sama sekali.
  static Duration staggerDelay(int index) {
    if (index >= staggerCap) return Duration.zero;
    final ms = (index * staggerStep.inMilliseconds).clamp(
      0,
      staggerMax.inMilliseconds,
    );
    return Duration(milliseconds: ms);
  }

  /// Kurva halaman: geser cepat lalu settle lembut (khas Telegram).
  static const pageCurve = Cubic(0.22, 0.9, 0.28, 1.0);

  /// Kurva pegas untuk segmen, chip, dan penanda (sedikit overshoot).
  static const spring = Curves.easeOutBack;

  /// Kurva sheet/dialog.
  static const sheet = Curves.easeOutCubic;

  /// True bila sistem meminta gerak diminimalkan (aksesibilitas).
  /// Semua animasi dekoratif baru WAJIB mengecek ini dan tampil instan.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Durasi aman untuk semua animasi: [base] seperti biasa, atau nol
  /// bila pengguna meminta reduced motion.
  ///
  /// Ini satu-satunya pintu yang perlu dipanggil animasi baru, sehingga
  /// kebijakan reduced motion tidak tercecer di banyak tempat.
  static Duration durationFor(BuildContext context, Duration base) =>
      reduced(context) ? Duration.zero : base;

  // --- Haptic (pasangan wajib setiap aksi taktil ala Telegram) ---

  static void tap() => HapticFeedback.lightImpact();
  static void success() => HapticFeedback.lightImpact();
  static void warn() => HapticFeedback.mediumImpact();
  static void error() => HapticFeedback.heavyImpact();
}

/// Transisi halaman app-wide: dipasang di [ThemeData.pageTransitionsTheme]
/// agar SELURUH push terasa pegas tanpa menyentuh pemanggil.
class SpringPageTransitionsBuilder extends PageTransitionsBuilder {
  const SpringPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Reduced motion: tampilkan langsung tanpa fade/geser. Satu baris ini
    // menutup celah yang tersisa di seluruh push/pop aplikasi.
    if (AppMotion.reduced(context)) return child;
    // Dialog fullscreen tetap fade sederhana.
    if (route.fullscreenDialog) {
      return FadeTransition(opacity: animation, child: child);
    }
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.pageCurve,
      reverseCurve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0.06, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Gagang sheet standar ala Telegram — pakai di atas setiap bottom sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}
