import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

/// Target tabungan user — murni data lokal, offline-first.
/// Mengikuti pola [BudgetCategory]/[WalletModel]: copyWith + toJson/fromJson
/// dengan IconData & Color disimpan sebagai int.
class SavingsGoalModel {
  final String id;
  final String name;

  /// Rupiah utuh (Phase 4).
  final int target;
  final int saved;
  final IconData icon;
  final Color color;
  final DateTime? deadline;
  final DateTime createdAt;

  const SavingsGoalModel({
    required this.id,
    required this.name,
    required this.target,
    this.saved = 0,
    required this.icon,
    required this.color,
    this.deadline,
    required this.createdAt,
  });

  double get progress =>
      target <= 0 ? 0 : (saved / target).clamp(0, 1).toDouble();

  int get remaining {
    final v = target - saved;
    return v < 0 ? 0 : v;
  }

  bool get isCompleted => target > 0 && saved >= target;

  int? get daysLeft {
    if (deadline == null) return null;
    final now = DateTime.now();
    final d0 = DateTime(now.year, now.month, now.day);
    final d1 = DateTime(deadline!.year, deadline!.month, deadline!.day);
    return d1.difference(d0).inDays;
  }

  SavingsGoalModel copyWith({
    String? name,
    int? target,
    int? saved,
    IconData? icon,
    Color? color,
    DateTime? deadline,
    bool clearDeadline = false,
  }) {
    return SavingsGoalModel(
      id: id,
      name: name ?? this.name,
      target: target ?? this.target,
      saved: saved ?? this.saved,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      deadline: clearDeadline ? null : (deadline ?? this.deadline),
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'target': target,
        'saved': saved,
        'icon': icon.codePoint,
        'color': color.toARGB32(),
        'deadline': deadline?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory SavingsGoalModel.fromJson(Map<String, dynamic> j) => SavingsGoalModel(
        id: j['id'] as String,
        name: j['name'] as String,
        // P4: pecahan legacy dibulatkan ke rupiah utuh.
        target: (j['target'] as num).round(),
        saved: (j['saved'] as num?)?.round() ?? 0,
        icon: AppIcons.fromCodePoint(j['icon'] as int),
        color: Color(j['color'] as int),
        deadline: j['deadline'] == null
            ? null
            : DateTime.tryParse(j['deadline'] as String),
        createdAt: j['createdAt'] == null
            ? DateTime.now()
            : DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now(),
      );
}
