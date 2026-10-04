part of '../finance_provider.dart';

/// Anggaran + alert notifikasi (extension bagian FinanceProvider).
/// Logic disalin verbatim dari FinanceProvider monolit (P2-a: code motion).
extension FinanceBudgets on FinanceProvider {
  int get totalBudgetSpent => _budgets.fold(0, (sum, b) => sum + b.spent);

  int get totalBudgetRemaining {
    final v = monthlyAllowance - totalBudgetSpent;
    return v < 0 ? 0 : v;
  }

  double get budgetProgress => monthlyAllowance <= 0
      ? 0
      : (totalBudgetSpent / monthlyAllowance).clamp(0, 1).toDouble();

  int spentForBudget(String category, {DateTime? month}) {
    final m = month ?? DateTime.now();
    final start = DateTime(m.year, m.month, 1);
    final end = DateTime(m.year, m.month + 1, 1);
    return _transactions
        .where(
          (t) =>
              t.type == TransactionType.expense &&
              t.category == category &&
              t.date.isAfter(start.subtract(const Duration(seconds: 1))) &&
              t.date.isBefore(end),
        )
        .fold(0, (s, t) => s + t.amount);
  }

  Future<void> recalcBudgetsForMonth(DateTime month) async {
    final snap = _takeSnapshot();
    for (var i = 0; i < _budgets.length; i++) {
      final spent = spentForBudget(_budgets[i].name, month: month);
      _budgets[i] = _budgets[i].copyWith(spent: spent);
    }
    _notify();
    try {
      await _persistAtomically(bd: true, debugLabel: 'recalcBudgets');
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('budget.recalc.failed', e);
    }
  }

  Future<bool> addBudgetCategory({
    required String name,
    required int limit,
    IconData icon = Icons.category,
  }) async {
    if (name.trim().isEmpty || limit <= 0) return false;
    if (_budgets.any(
      (b) => b.name.toLowerCase() == name.trim().toLowerCase(),
    )) {
      return false;
    }
    final snap = _takeSnapshot();
    _budgets.add(
      BudgetCategory(
        id: _uuid.v4(),
        name: name.trim(),
        icon: icon,
        spent: 0,
        limit: limit,
      ),
    );
    final budgetId = _budgets.last.id;
    _notify();
    try {
      await _persistAtomically(
        bd: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.budgetCreated,
            entityType: 'budget',
            entityId: budgetId,
            metadata: {'name': name.trim(), 'limit': limit},
          ),
        ],
        debugLabel: 'addBudget',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('budget.add.failed', e);
      return false;
    }
    return true;
  }

  Future<bool> updateBudget(
    String id, {
    String? name,
    int? limit,
    IconData? icon,
  }) async {
    final idx = _budgets.indexWhere((b) => b.id == id);
    if (idx == -1) return false;
    final newName = name?.trim();
    if (newName != null) {
      if (newName.isEmpty) return false;
      if (_budgets.any(
        (b) => b.id != id && b.name.toLowerCase() == newName.toLowerCase(),
      )) {
        return false;
      }
    }
    if (limit != null && limit <= 0) return false;
    final snap = _takeSnapshot();
    final oldName = _budgets[idx].name;
    _budgets[idx] = _budgets[idx].copyWith(
      name: newName,
      limit: limit,
      icon: icon,
    );
    // Migrasi kategori transaksi agar spent tidak yatim.
    var touchedTx = false;
    if (newName != null && newName != oldName) {
      for (var i = 0; i < _transactions.length; i++) {
        if (_transactions[i].category == oldName) {
          _transactions[i] = _transactions[i].copyWith(category: newName);
          touchedTx = true;
        }
      }
      if (touchedTx) _invalidateTxCache();
    }
    _notify();
    try {
      await _persistAtomically(
        bd: true,
        fullTx: touchedTx,
        audit: [
          AuditService.rowFor(
            action: AuditAction.budgetUpdated,
            entityType: 'budget',
            entityId: id,
            metadata: {
              'name': _budgets[idx].name,
              'limit': _budgets[idx].limit,
            },
          ),
        ],
        debugLabel: 'updateBudget',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('budget.update.failed', e);
      return false;
    }
    _checkBudgetAlerts();
    return true;
  }

  Future<void> deleteBudget(String id) async {
    final snap = _takeSnapshot();
    var name = '';
    for (final b in _budgets) {
      if (b.id == id) {
        name = b.name;
        break;
      }
    }
    _budgets.removeWhere((b) => b.id == id);
    _budgetAlertNotified.remove(id);
    _notify();
    try {
      await _persistAtomically(
        bd: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.budgetDeleted,
            entityType: 'budget',
            entityId: id,
            metadata: {'name': name},
          ),
        ],
        debugLabel: 'deleteBudget',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('budget.delete.failed', e);
    }
  }

  void _checkBudgetAlerts() {
    if (!budgetAlertsOn) return;
    // Samakan dengan UI: pakai hitungan bulan berjalan agar persen
    // notifikasi tidak divergen dari yang tampil di BudgetScreen.
    // Tier 50/80/100%: tiap ambang yang baru ditembus ke atas ternotifikasi
    // sekali; turun di bawahnya me-reset agar penembusan berikutnya bunyi.
    final now = DateTime.now();
    for (var i = 0; i < _budgets.length; i++) {
      final spent = spentForBudget(_budgets[i].name, month: now);
      if (_budgets[i].spent != spent) {
        _budgets[i] = _budgets[i].copyWith(spent: spent);
      }
      final b = _budgets[i];
      final lastLevel = NotificationService.budgetAlertLevel(
        _budgetAlertNotified[b.id] ?? 0.0,
      );
      final level = NotificationService.budgetAlertLevel(b.percent);
      if (level <= lastLevel) {
        if (level < lastLevel) _budgetAlertNotified[b.id] = b.percent;
        continue;
      }
      _budgetAlertNotified[b.id] = b.percent;
      // Proyeksi akhir bulan dari laju belanja: bila diproyeksi jebol,
      // sertakan di alert tier 80/100 agar ada waktu koreksi.
      double? projected;
      if (level >= 2 && b.limit > 0) {
        final dim = DateTime(now.year, now.month + 1, 0).day;
        final elapsed = now.day.clamp(1, dim);
        final proj = spent / elapsed * dim;
        if (proj > b.limit) projected = proj / b.limit;
      }
      // Fire-and-forget sengaja: alert tidak boleh menahan persist UI.
      unawaited(
        NotificationService.showBudgetAlert(
          id: b.id,
          category: b.name,
          percent: b.percent,
          spent: b.spent,
          limit: b.limit,
          tier: level,
          projectedPct: projected,
        ),
      );
    }
  }
}
