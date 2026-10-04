import 'package:flutter/material.dart';

/// Central registry for icons that can be persisted (categories, wallets,
/// transactions, budgets, savings goals).
///
/// Release builds tree-shake the MaterialIcons font, which requires every
/// [IconData] instantiation in source to be `const`. Deserializing with
/// `IconData(codePoint)` (non-const) breaks `flutter build apk --release`
/// with "cannot tree shake icons fonts". Resolving through this registry
/// keeps all [IconData] usages const — the lookup only compares ints.
///
/// When adding a new persistable icon, add it to [values] (and to the
/// icon pickers in the UI) so old data can still resolve after upgrades.
class AppIcons {
  const AppIcons._();

  /// Every icon that may appear in persisted JSON (codePoint storage).
  /// Union of: built-in categories, wallet/savings/tx defaults, and both
  /// icon pickers (add_transaction + settings category dialog).
  ///
  /// WAJIB lengkap: ikon yang dipakai model tapi tak ada di sini akan
  /// terdegradasi jadi Icons.category setiap aplikasi dibuka ulang
  /// (fromCodePoint fallback) — datanya "rusak" perlahan tanpa error.
  static const List<IconData> values = [
    Icons.restaurant,
    Icons.fastfood,
    Icons.local_cafe,
    Icons.shopping_bag,
    Icons.shopping_cart,
    Icons.directions_car,
    Icons.directions_bus,
    Icons.local_gas_station,
    Icons.receipt_long,
    Icons.bolt,
    Icons.sports_esports,
    Icons.movie,
    Icons.music_note,
    Icons.favorite_border,
    Icons.medical_services,
    Icons.school,
    Icons.work,
    Icons.home,
    Icons.flight,
    Icons.pets,
    Icons.payments,
    Icons.more_horiz,
    Icons.category,
    Icons.category_outlined,
    Icons.account_balance_wallet,
    Icons.savings_outlined,
    // Dompet: add-dialog + seed memakai ikon non-outlined ini.
    Icons.wallet,
    Icons.account_balance,
    // Sheet target tabungan (savings_goals): varian outlined.
    Icons.shield_outlined,
    Icons.home_outlined,
    Icons.directions_car_outlined,
    Icons.flight_outlined,
    Icons.school_outlined,
    Icons.phone_android_outlined,
    Icons.laptop_outlined,
    Icons.cake_outlined,
    Icons.health_and_safety_outlined,
    Icons.work_outline,
    // P3: ikon default transaksi penyesuaian saldo (audit trail).
    Icons.tune,
  ];

  /// Resolve a persisted codePoint to its const [IconData].
  /// Unknown codes (e.g. data from older versions) fall back to
  /// [Icons.category] instead of crashing or breaking tree-shaking.
  static IconData fromCodePoint(int code) {
    for (final icon in values) {
      if (icon.codePoint == code) return icon;
    }
    return Icons.category;
  }
}
