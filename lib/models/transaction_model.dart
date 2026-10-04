import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

enum TransactionType { income, expense, transfer, adjustment }

extension TransactionTypeLabel on TransactionType {
  String get label {
    switch (this) {
      case TransactionType.income:
        return 'Income';
      case TransactionType.expense:
        return 'Expense';
      case TransactionType.transfer:
        return 'Transfer';
      case TransactionType.adjustment:
        return 'Adjustment';
    }
  }
}

class TransactionModel {
  final String id;
  final String title;
  final String category;
  final String account;
  final String? tag; // e.g. "QRIS", "Payroll", "BCA VA"
  /// Nominal basis IDR dalam rupiah utuh (Phase 4: integer, selalu positif).
  /// Baris lama pecahan dibulatkan deterministik saat baca (round-half-away).
  final int amount;
  final TransactionType type;
  final DateTime date;
  final IconData icon;
  final String? note;

  /// Tautan ke SavingsGoal bila transaksi ini adalah setoran/penarikan
  /// tabungan atomik (§33-§35). Null untuk transaksi biasa. Nullable agar
  /// JSON lama tetap bisa dibaca (migrasi forward-only, tanpa hapus data).
  final String? linkedGoalId;

  /// ID dompet sumber/tujuan (ID-ready, P0-6). Nullable agar JSON lama
  /// (hanya string `account`) tetap terbaca; `account` dipertahankan
  /// sebagai tampilan + fallback. Untuk income/expense: fromWalletId terisi,
  /// toWalletId null. Untuk transfer: keduanya terisi bila dompet dikenal.
  /// Untuk adjustment (P3): tepat satu terisi — toWalletId = koreksi kredit
  /// (saldo +), fromWalletId = koreksi debit (saldo −), counterparty-nya
  /// eksternal (rekonsiliasi bank) sehingga sisi lain null.
  final String? fromWalletId;
  final String? toWalletId;

  const TransactionModel({
    required this.id,
    required this.title,
    required this.category,
    required this.account,
    required this.amount,
    required this.type,
    required this.date,
    required this.icon,
    this.tag,
    this.note,
    this.linkedGoalId,
    this.fromWalletId,
    this.toWalletId,
  });

  /// Signed amount: negative for expense, positive otherwise.
  ///
  /// Catatan: arah [TransactionType.adjustment] bersifat per-wallet
  /// (kredit vs koreksi) dan di-resolve oleh
  /// `ReconciliationService.walletDeltasForTx`, bukan di sini.
  int get signedAmount => type == TransactionType.expense ? -amount : amount;

  TransactionModel copyWith({
    String? title,
    String? category,
    String? account,
    String? tag,
    int? amount,
    TransactionType? type,
    DateTime? date,
    IconData? icon,
    String? note,
    String? linkedGoalId,
    String? fromWalletId,
    String? toWalletId,
    bool clearLinkedGoal = false,
    bool clearWalletIds = false,
  }) {
    return TransactionModel(
      id: id,
      title: title ?? this.title,
      category: category ?? this.category,
      account: account ?? this.account,
      tag: tag ?? this.tag,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      date: date ?? this.date,
      icon: icon ?? this.icon,
      note: note ?? this.note,
      linkedGoalId:
          clearLinkedGoal ? null : (linkedGoalId ?? this.linkedGoalId),
      fromWalletId: clearWalletIds ? null : (fromWalletId ?? this.fromWalletId),
      toWalletId: clearWalletIds ? null : (toWalletId ?? this.toWalletId),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'account': account,
        'tag': tag,
        'amount': amount,
        'type': type.index,
        'date': date.toIso8601String(),
        'icon': icon.codePoint,
        'note': note,
        'linkedGoalId': linkedGoalId,
        'fromWalletId': fromWalletId,
        'toWalletId': toWalletId,
      };

  factory TransactionModel.fromJson(Map<String, dynamic> j) {
    final rawType = j['type'] as int;
    // P3: indeks di luar rentang = baris korup → FormatException supaya
    // di-skip per-baris oleh pemanggil (tidak menggugurkan seluruh tabel).
    if (rawType < 0 || rawType >= TransactionType.values.length) {
      throw FormatException('type tidak dikenal: $rawType');
    }
    return TransactionModel(
      id: j['id'] as String,
      title: j['title'] as String,
      category: j['category'] as String,
      account: j['account'] as String,
      tag: j['tag'] as String?,
      // P4: baris lama pecahan (kurs asing) dibulatkan ke rupiah utuh.
      amount: (j['amount'] as num).round(),
      type: TransactionType.values[rawType],
      date: DateTime.parse(j['date'] as String),
      icon: AppIcons.fromCodePoint(j['icon'] as int),
      note: j['note'] as String?,
      linkedGoalId: j['linkedGoalId'] as String?,
      fromWalletId: j['fromWalletId'] as String?,
      toWalletId: j['toWalletId'] as String?,
    );
  }
}
