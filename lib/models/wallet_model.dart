import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

class WalletModel {
  final String id;
  final String name;
  final String number;
  final IconData icon;

  /// Rupiah utuh (Phase 4).
  final int balance;

  /// Saldo awal saat dompet dibuat (ledger opening balance, P3).
  ///
  /// Invarian: `balance == initialBalance + Σ ledgerDelta(dompet)`.
  /// `balance` adalah projection yang bisa di-rebuild; jangan tulis langsung
  /// untuk koreksi manual — pakai adjustment event agar ada audit trail.
  /// Default 0 agar konstruksi lama tetap compile; [addWallet] selalu
  /// mengisi eksplisit, data lama di-backfill sekali saat load.
  /// Rupiah utuh (Phase 4).
  final int initialBalance;
  final Color color;

  const WalletModel({
    required this.id,
    required this.name,
    required this.number,
    required this.icon,
    required this.balance,
    this.initialBalance = 0,
    required this.color,
  });

  WalletModel copyWith({
    String? name,
    String? number,
    IconData? icon,
    int? balance,
    int? initialBalance,
    Color? color,
  }) {
    return WalletModel(
      id: id,
      name: name ?? this.name,
      number: number ?? this.number,
      icon: icon ?? this.icon,
      balance: balance ?? this.balance,
      initialBalance: initialBalance ?? this.initialBalance,
      color: color ?? this.color,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'number': number,
        'icon': icon.codePoint,
        'balance': balance,
        'initial_balance': initialBalance,
        'color': color.toARGB32(),
      };

  factory WalletModel.fromJson(Map<String, dynamic> j) {
    // Fallback `balance`: backup/DB lama tanpa `initial_balance` tetap
    // terbaca; nilai awal yang benar dihitung oleh backfill sekali jalan
    // (lihat FinanceReconciliation.backfillWalletInitialBalances).
    final balance = (j['balance'] as num).round();
    final initial = j['initial_balance'] ?? j['initialBalance'];
    return WalletModel(
      id: j['id'] as String,
      name: j['name'] as String,
      number: j['number'] as String,
      icon: AppIcons.fromCodePoint(j['icon'] as int),
      balance: balance,
      initialBalance: initial == null ? balance : (initial as num).round(),
      color: Color(j['color'] as int),
    );
  }
}
