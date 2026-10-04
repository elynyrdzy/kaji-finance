import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

enum BudgetStatus { onTrack, approaching, limitReached }

class BudgetCategory {
  final String id;
  final String name;
  final IconData icon;

  /// Rupiah utuh (Phase 4).
  final int spent;
  final int limit;

  const BudgetCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.spent,
    required this.limit,
  });

  double get percent =>
      limit <= 0 ? 0 : (spent / limit).clamp(0, 1.5).toDouble();
  int get remaining {
    final v = limit - spent;
    return v < 0 ? 0 : v;
  }

  BudgetStatus get status {
    if (percent >= 1.0) return BudgetStatus.limitReached;
    if (percent >= 0.8) return BudgetStatus.approaching;
    return BudgetStatus.onTrack;
  }

  BudgetCategory copyWith({
    String? name,
    IconData? icon,
    int? spent,
    int? limit,
  }) {
    return BudgetCategory(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      spent: spent ?? this.spent,
      limit: limit ?? this.limit,
    );
  }

  /// Kunci JSON `budget_limit` (BUKAN `limit`): LIMIT adalah kata kunci
  /// reserved SQLite — kolom bernama `limit` membuat CREATE TABLE gagal
  /// dengan "syntax error", database tak pernah terbentuk, dan seluruh
  /// data hilang tiap restart. Field Dart tetap bernama `limit` agar
  /// pemanggil (`b.limit`, `copyWith(limit:)`) tidak berubah.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon.codePoint,
        'spent': spent,
        'budget_limit': limit,
      };

  factory BudgetCategory.fromJson(Map<String, dynamic> j) => BudgetCategory(
        id: j['id'] as String,
        name: j['name'] as String,
        icon: AppIcons.fromCodePoint(j['icon'] as int),
        // P4: pecahan legacy dibulatkan ke rupiah utuh.
        spent: (j['spent'] as num).round(),
        // Fallback `limit`: file backup lama (pra-perbaikan) tetap terbaca.
        limit: ((j['budget_limit'] ?? j['limit']) as num).round(),
      );
}
