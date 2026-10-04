part of '../finance_provider.dart';

/// Transaksi: CRUD + query + agregat chart + CSV (extension FinanceProvider).
/// Logic disalin verbatim dari FinanceProvider monolit (P2-a: code motion).
extension FinanceTransactions on FinanceProvider {
  int get totalIncome => _transactions
      .where((t) => t.type == TransactionType.income)
      .fold(0, (sum, t) => sum + t.amount);

  int get totalExpense => _transactions
      .where((t) => t.type == TransactionType.expense)
      .fold(0, (sum, t) => sum + t.amount);

  int get netAmount => totalIncome - totalExpense;

  List<TransactionModel> transactionsForPeriod(String period) {
    final now = DateTime.now();
    final start = FinanceProvider.periodStartFor(period, now);
    final from = start.subtract(const Duration(seconds: 1));
    final to = now.add(const Duration(days: 1));
    return _transactions
        .where((t) => t.date.isAfter(from) && t.date.isBefore(to))
        .toList();
  }

  Map<String, int> expenseByCategoryForPeriod(String period) {
    final list = transactionsForPeriod(
      period,
    ).where((t) => t.type == TransactionType.expense);
    final map = <String, int>{};
    for (final t in list) {
      map[t.category] = (map[t.category] ?? 0) + t.amount;
    }
    return map;
  }

  Map<String, int> get expenseByCategory {
    final map = <String, int>{};
    for (final t in _transactions.where(
      (t) => t.type == TransactionType.expense,
    )) {
      map[t.category] = (map[t.category] ?? 0) + t.amount;
    }
    return map;
  }

  /// Nilai bersih mentah (minor units IDR, bisa negatif) per bucket.
  /// Dipakai tooltip/label & Lab Fitur — sedangkan [cashFlowTrendFor]
  /// tetap menyediakan versi normalisasi 0..1 untuk painter.
  List<int> cashFlowRawFor(String range) {
    final now = DateTime.now();
    int days;
    switch (range) {
      case '7D':
        days = 7;
        break;
      case '1M':
        days = 30;
        break;
      case '3M':
        days = 90;
        break;
      case '1Y':
        days = 365;
        break;
      default:
        days = 30;
    }
    const buckets = 12;
    final windowStart = now.subtract(Duration(days: days));
    final totalMicros = now.difference(windowStart).inMicroseconds;
    final vals = <int>[];
    for (var i = 0; i < buckets; i++) {
      final start = windowStart.add(
        Duration(microseconds: (totalMicros * i ~/ buckets)),
      );
      final end = i == buckets - 1
          ? now.add(const Duration(seconds: 1))
          : windowStart.add(
              Duration(microseconds: (totalMicros * (i + 1) ~/ buckets)),
            );
      var net = 0;
      for (final t in _transactions) {
        if (t.date.isAfter(start) && t.date.isBefore(end)) {
          if (t.type == TransactionType.expense) {
            net -= t.amount;
          } else if (t.type == TransactionType.income) {
            net += t.amount;
          }
          // Transfer antar wallet/savings bersifat netral — tidak dihitung.
        }
      }
      vals.add(net);
    }
    return vals;
  }

  List<double> cashFlowTrendFor(String range) {
    final now = DateTime.now();
    int days;
    switch (range) {
      case '7D':
        days = 7;
        break;
      case '1M':
        days = 30;
        break;
      case '3M':
        days = 90;
        break;
      case '1Y':
        days = 365;
        break;
      default:
        days = 30;
    }
    // Jendela pas [now-days, now] dibagi 12 bucket sama besar — bucket
    // terakhir tidak pernah lari ke masa depan seperti sebelumnya.
    const buckets = 12;
    final windowStart = now.subtract(Duration(days: days));
    final totalMicros = now.difference(windowStart).inMicroseconds;
    final vals = <double>[];
    double maxAbs = 1;
    for (var i = 0; i < buckets; i++) {
      final start = windowStart.add(
        Duration(microseconds: (totalMicros * i ~/ buckets)),
      );
      final end = i == buckets - 1
          ? now.add(const Duration(seconds: 1))
          : windowStart.add(
              Duration(microseconds: (totalMicros * (i + 1) ~/ buckets)),
            );
      var net = 0;
      for (final t in _transactions) {
        if (t.date.isAfter(start) && t.date.isBefore(end)) {
          if (t.type == TransactionType.expense) {
            net -= t.amount;
          } else if (t.type == TransactionType.income) {
            net += t.amount;
          }
          // Transfer antar wallet bersifat netral — tidak dihitung.
        }
      }
      vals.add(net.toDouble());
      if (net.abs() > maxAbs) maxAbs = net.abs().toDouble();
    }
    if (vals.every((v) => v == 0)) return List.filled(buckets, 0.5);
    return vals
        .map((v) => ((v / maxAbs) * 0.4 + 0.5).clamp(0.05, 0.95).toDouble())
        .toList();
  }

  List<Map<String, int>> weeklyCashFlowFor(String period) {
    final now = DateTime.now();
    // 4 irisan sama besar dari periode terpilih — konsisten untuk
    // week/month/quarter/year (sebelumnya selalu 4 minggu terakhir).
    final start = FinanceProvider.periodStartFor(period, now);
    final end = now.add(const Duration(seconds: 1));
    final totalMicros = end.difference(start).inMicroseconds;
    final buckets = List.generate(4, (_) => {'income': 0, 'expense': 0});
    for (final t in _transactions) {
      if (!t.date.isAfter(start) || !t.date.isBefore(end)) continue;
      if (t.type != TransactionType.income &&
          t.type != TransactionType.expense) {
        continue;
      }
      final elapsed = t.date.difference(start).inMicroseconds;
      var idx = (elapsed * 4 ~/ totalMicros).clamp(0, 3);
      if (t.type == TransactionType.income) {
        buckets[idx]['income'] = buckets[idx]['income']! + t.amount;
      } else {
        buckets[idx]['expense'] = buckets[idx]['expense']! + t.amount;
      }
    }
    return buckets;
  }

  /// Phase 2: tulis DB atomik (tx + wallets + budgets dalam SATU transaksi)
  /// + rollback snapshot in-memory bila gagal. Default `await`.
  Future<bool> addTransaction({
    required String title,
    required String category,
    required String account,
    required int amount,
    required TransactionType type,
    required IconData icon,
    String? tag,
    DateTime? date,
    String? note,
    String? targetAccount,
  }) async {
    if (title.trim().isEmpty || account.trim().isEmpty) return false;
    // P4: int selalu finite; 0/negatif ditolak.
    if (amount <= 0) return false;
    // P3: adjustment hanya via adjustWalletBalance/updateWallet(balance:)
    // agar arah + alasan tercatat benar; tolak dari jalur umum.
    if (type == TransactionType.adjustment) return false;
    if (type == TransactionType.transfer &&
        (targetAccount == null ||
            targetAccount.isEmpty ||
            targetAccount == account)) {
      return false;
    }
    // Tolak overdraft: dompet sumber tidak boleh negatif (audit P2-B).
    // Dompet tak dikenal tetap lolos (delta no-op, perilaku lama).
    if (_wouldOverdraw(type: type, account: account, amount: amount)) {
      return false;
    }
    final effectiveAccount = type == TransactionType.transfer &&
            targetAccount != null &&
            targetAccount.isNotEmpty
        ? '$account → $targetAccount'
        : account;
    final tx = TransactionModel(
      id: _uuid.v4(),
      title: title,
      category: category,
      account: effectiveAccount,
      amount: amount,
      type: type,
      icon: icon,
      tag: tag,
      date: date ?? DateTime.now(),
      note: note,
      fromWalletId: _walletIdOf(account),
      toWalletId: type == TransactionType.transfer && targetAccount != null
          ? _walletIdOf(targetAccount)
          : null,
    );
    final snap = _takeSnapshot();
    AppLog.event('transaction.add.started', data: {'type': type.name});
    _transactions.add(tx);
    _invalidateTxCache();
    _applyWalletDeltaForTx(tx);

    if (type == TransactionType.expense) {
      final effectiveDate = date ?? DateTime.now();
      final now = DateTime.now();
      if (effectiveDate.year == now.year && effectiveDate.month == now.month) {
        final idx = _budgets.indexWhere((b) => b.name == category);
        if (idx != -1) {
          _budgets[idx] = _budgets[idx].copyWith(
            spent: _budgets[idx].spent + amount,
          );
        }
      }
    }
    _notify();
    _checkBudgetAlerts();
    try {
      await _persistAtomically(
        upsertTx: tx,
        wl: true,
        bd: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionCreated,
            entityType: 'transaction',
            entityId: tx.id,
            metadata: {
              'type': type.name,
              'amount': amount,
              'category': category,
            },
          ),
        ],
        debugLabel: 'addTransaction',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transaction.add.failed', e);
      return false;
    }
    AppLog.event('transaction.add.completed', data: {'id': tx.id});
    return true;
  }

  Future<bool> updateTransaction(
    String id, {
    String? title,
    String? category,
    String? account,
    int? amount,
    TransactionType? type,
    IconData? icon,
    String? tag,
    DateTime? date,
    String? note,
    String? targetAccount,
  }) async {
    final idx = _transactions.indexWhere((t) => t.id == id);
    if (idx == -1) return false;
    if (amount != null && amount <= 0) return false;
    if (title != null && title.trim().isEmpty) return false;
    // P3: adjustment & savings-linked readonly di jalur umum.
    if (type == TransactionType.adjustment) return false;
    final old = _transactions[idx];
    // Transaksi tabungan atomik tidak boleh diubah via jalur umum —
    // ubah/hapus via layar Tabungan agar goal.saved tetap konsisten.
    // Adjustment juga readonly (koreksi baru via adjustWalletBalance).
    if (_isSavingsLinked(old)) return false;
    if (old.type == TransactionType.adjustment) return false;
    // Akun efektif dihitung murni dulu untuk cek overdraft sebelum mutasi.
    String? effectiveAccount = account;
    if (type == TransactionType.transfer && targetAccount != null) {
      final from = account ?? old.account.split(' → ').first;
      effectiveAccount = '$from → $targetAccount';
    } else if (type == TransactionType.transfer &&
        account != null &&
        account.contains(' → ')) {
      effectiveAccount = account;
    }
    final effType = type ?? old.type;
    final effAmount = amount ?? old.amount;
    final snap = _takeSnapshot();
    _revertWalletDeltaForTx(old);
    final now = DateTime.now();
    final oldCounted = old.type == TransactionType.expense &&
        old.date.year == now.year &&
        old.date.month == now.month;
    var oldBudgetIdx = -1;
    if (oldCounted) {
      oldBudgetIdx = _budgets.indexWhere((b) => b.name == old.category);
      if (oldBudgetIdx != -1) {
        final ns = _budgets[oldBudgetIdx].spent - old.amount;
        _budgets[oldBudgetIdx] = _budgets[oldBudgetIdx].copyWith(
          spent: ns < 0 ? 0 : ns,
        );
      }
    }
    // Tolak overdraft nilai baru; rollback delta & anggaran lama (P2-B).
    if (_wouldOverdraw(
      type: effType,
      account: effectiveAccount ?? old.account,
      amount: effAmount,
    )) {
      _applyWalletDeltaForTx(old);
      if (oldBudgetIdx != -1) {
        _budgets[oldBudgetIdx] = _budgets[oldBudgetIdx].copyWith(
          spent: _budgets[oldBudgetIdx].spent + old.amount,
        );
      }
      return false;
    }
    final updatedBase = old.copyWith(
      title: title,
      category: category,
      account: effectiveAccount,
      amount: amount,
      type: type,
      date: date,
      icon: icon,
      tag: tag,
      note: note,
    );
    // Refresh ID dompet bila akun berubah — agar rename berikutnya tidak
    // yatim. Data lama tanpa ID tetap jalan via fallback nama.
    final resolvedAccount = updatedBase.account;
    String? fromId = old.fromWalletId;
    String? toId = old.toWalletId;
    if (effectiveAccount != null || type != null) {
      if (updatedBase.type == TransactionType.transfer &&
          resolvedAccount.contains(' → ')) {
        final parts = resolvedAccount.split(' → ');
        fromId = _walletIdOf(parts[0]);
        toId = _walletIdOf(parts[1]);
      } else {
        fromId = _walletIdOf(resolvedAccount);
        toId = null;
      }
    }
    final updated = TransactionModel(
      id: updatedBase.id,
      title: updatedBase.title,
      category: updatedBase.category,
      account: updatedBase.account,
      amount: updatedBase.amount,
      type: updatedBase.type,
      date: updatedBase.date,
      icon: updatedBase.icon,
      tag: updatedBase.tag,
      note: updatedBase.note,
      linkedGoalId: updatedBase.linkedGoalId,
      fromWalletId: fromId,
      toWalletId: toId,
    );
    _transactions[idx] = updated;
    _invalidateTxCache();
    _applyWalletDeltaForTx(updated);
    if (updated.type == TransactionType.expense &&
        updated.date.year == now.year &&
        updated.date.month == now.month) {
      final bIdx = _budgets.indexWhere((b) => b.name == updated.category);
      if (bIdx != -1) {
        _budgets[bIdx] = _budgets[bIdx].copyWith(
          spent: _budgets[bIdx].spent + updated.amount,
        );
      }
    }
    _notify();
    _checkBudgetAlerts();
    try {
      await _persistAtomically(
        upsertTx: updated,
        wl: true,
        bd: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionUpdated,
            entityType: 'transaction',
            entityId: id,
            metadata: {
              'type': updated.type.name,
              'amount': updated.amount,
              'category': updated.category,
            },
          ),
        ],
        debugLabel: 'updateTransaction',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transaction.update.failed', e);
      return false;
    }
    return true;
  }

  Future<bool> deleteTransaction(String id) async {
    final snap = _takeSnapshot();
    final tx = _transactions.where((t) => t.id == id).toList();
    if (tx.isEmpty) return false;
    // P3: adjustment immutable — jejak audit koreksi saldo tidak boleh
    // dihapus (buat koreksi tandingan via adjustWalletBalance bila salah).
    if (tx.first.type == TransactionType.adjustment) return false;
    _revertWalletDeltaForTx(tx.first);
    _revertGoalDeltaForTx(tx.first);
    if (tx.first.type == TransactionType.expense) {
      final now = DateTime.now();
      if (tx.first.date.year == now.year && tx.first.date.month == now.month) {
        final bIdx = _budgets.indexWhere((b) => b.name == tx.first.category);
        if (bIdx != -1) {
          final ns = _budgets[bIdx].spent - tx.first.amount;
          _budgets[bIdx] = _budgets[bIdx].copyWith(spent: ns < 0 ? 0 : ns);
        }
      }
    }
    _transactions.removeWhere((t) => t.id == id);
    _invalidateTxCache();
    _notify();
    _checkBudgetAlerts();
    try {
      await _persistAtomically(
        deleteTxId: id,
        wl: true,
        bd: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionDeleted,
            entityType: 'transaction',
            entityId: id,
            metadata: {'type': tx.first.type.name, 'amount': tx.first.amount},
          ),
        ],
        debugLabel: 'deleteTransaction',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transaction.delete.failed', e);
      return false;
    }
    return true;
  }

  /// Kembalikan transaksi yang sama persis (ID asli dipertahankan) —
  /// dipakai Undo hapus agar tidak lahir sebagai transaksi baru.
  Future<bool> restoreTransaction(TransactionModel tx) async {
    if (_transactions.any((t) => t.id == tx.id)) return false;
    final snap = _takeSnapshot();
    _transactions.add(tx);
    _invalidateTxCache();
    _applyWalletDeltaForTx(tx);
    _applyGoalDeltaForTx(tx);
    if (tx.type == TransactionType.expense) {
      final now = DateTime.now();
      if (tx.date.year == now.year && tx.date.month == now.month) {
        final bIdx = _budgets.indexWhere((b) => b.name == tx.category);
        if (bIdx != -1) {
          _budgets[bIdx] = _budgets[bIdx].copyWith(
            spent: _budgets[bIdx].spent + tx.amount,
          );
        }
      }
    }
    _notify();
    _checkBudgetAlerts();
    try {
      await _persistAtomically(
        upsertTx: tx,
        wl: true,
        bd: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionRestored,
            entityType: 'transaction',
            entityId: tx.id,
          ),
        ],
        debugLabel: 'restoreTransaction',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transaction.restore.failed', e);
      return false;
    }
    return true;
  }

  /// Duplikat transaksi (aksi menu tahan-lama): salinan baru dengan ID
  /// dan tanggal sekarang, delta dompet/goal/budget ikut diterapkan.
  /// Ditolak untuk transaksi tertaut tabungan — duplikatnya akan
  /// menggandakan goal.saved via _applyGoalDeltaForTx dengan linkedGoalId
  /// yang sama. Ubah/tambah via layar Tabungan agar atomik.
  Future<bool> duplicateTransaction(String id) async {
    final snap = _takeSnapshot();
    final idx = _transactions.indexWhere((t) => t.id == id);
    if (idx == -1) return false;
    final src = _transactions[idx];
    if (_isSavingsLinked(src)) return false;
    // P3: adjustment tidak boleh diduplikat (akan menggandakan koreksi).
    if (src.type == TransactionType.adjustment) return false;
    final copy = TransactionModel(
      id: _uuid.v4(),
      title: src.title,
      category: src.category,
      account: src.account,
      amount: src.amount,
      type: src.type,
      icon: src.icon,
      tag: src.tag,
      date: DateTime.now(),
      note: src.note,
      linkedGoalId: src.linkedGoalId,
      fromWalletId: src.fromWalletId ?? _walletIdOf(src.account),
      toWalletId: src.toWalletId,
    );
    _transactions.add(copy);
    _invalidateTxCache();
    _applyWalletDeltaForTx(copy);
    _applyGoalDeltaForTx(copy);
    if (copy.type == TransactionType.expense) {
      final bIdx = _budgets.indexWhere((b) => b.name == copy.category);
      if (bIdx != -1) {
        _budgets[bIdx] = _budgets[bIdx].copyWith(
          spent: _budgets[bIdx].spent + copy.amount,
        );
      }
    }
    _notify();
    _checkBudgetAlerts();
    try {
      await _persistAtomically(
        upsertTx: copy,
        wl: true,
        bd: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionCreated,
            entityType: 'transaction',
            entityId: copy.id,
            metadata: {
              'type': copy.type.name,
              'amount': copy.amount,
              'duplicatedFrom': id,
            },
          ),
        ],
        debugLabel: 'duplicateTransaction',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transaction.duplicate.failed', e);
      return false;
    }
    return true;
  }

  List<CategoryModel> get builtInCategories => const [
        CategoryModel(id: 'c1', name: 'Food & Drinks', icon: Icons.restaurant),
        CategoryModel(id: 'c2', name: 'Transport', icon: Icons.directions_car),
        CategoryModel(id: 'c3', name: 'Shopping', icon: Icons.shopping_bag),
        CategoryModel(
          id: 'c4',
          name: 'Bills & Utilities',
          icon: Icons.receipt_long,
        ),
        CategoryModel(
            id: 'c5', name: 'Entertainment', icon: Icons.sports_esports),
        CategoryModel(
            id: 'c6', name: 'Health & Care', icon: Icons.favorite_border),
        CategoryModel(id: 'c7', name: 'Education', icon: Icons.school),
        CategoryModel(id: 'c8', name: 'Income', icon: Icons.payments),
        CategoryModel(id: 'c9', name: 'Other', icon: Icons.more_horiz),
      ];

  List<CategoryModel> get allTransactionCategories => [
        ...builtInCategories,
        ..._customCategories,
      ];

  /// Kategori bawaan untuk TAMPILAN (pengelola kategori).
  List<CategoryModel> get displayBuiltInCategories => builtInCategories;

  static String _csvCell(Object? value) {
    final s = '${value ?? ''}';
    if (s.contains('"') ||
        s.contains(',') ||
        s.contains('\n') ||
        s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  String exportCsv() {
    final buf = StringBuffer();
    buf.writeln('id,title,category,account,amount,type,date,tag,note');
    for (final t in transactions) {
      final row = [
        t.id,
        t.title,
        t.category,
        t.account,
        t.amount,
        t.type.name,
        t.date.toIso8601String(),
        t.tag ?? '',
        t.note ?? '',
      ].map(_csvCell).join(',');
      buf.writeln(row);
    }
    return buf.toString();
  }

  /// Monthly income/expense summary for [month] (defaults to current month).
  /// Transfers are excluded from income/expense totals.
  MonthlySummary monthlySummary({DateTime? month}) {
    final m = month ?? DateTime.now();
    var income = 0;
    var expense = 0;
    int count = 0;
    final byCategory = <String, int>{};
    for (final t in _transactions) {
      if (t.date.year != m.year || t.date.month != m.month) continue;
      count++;
      if (t.type == TransactionType.income) {
        income += t.amount;
      } else if (t.type == TransactionType.expense) {
        expense += t.amount;
        byCategory[t.category] = (byCategory[t.category] ?? 0) + t.amount;
      }
    }
    String? topCategory;
    var topAmount = 0;
    byCategory.forEach((k, v) {
      if (v > topAmount) {
        topAmount = v;
        topCategory = k;
      }
    });
    return MonthlySummary(
      year: m.year,
      month: m.month,
      income: income,
      expense: expense,
      transactionCount: count,
      topExpenseCategory: topCategory,
      topExpenseAmount: topAmount,
    );
  }

  List<TransactionModel> filter({
    String query = '',
    TransactionType? type,
    String? category,
    DateTime? month,
    DateTime? from,
    DateTime? to,
  }) {
    return transactions.where((t) {
      final matchesQuery = query.isEmpty ||
          t.title.toLowerCase().contains(query.toLowerCase()) ||
          t.category.toLowerCase().contains(query.toLowerCase()) ||
          (t.note != null &&
              t.note!.toLowerCase().contains(query.toLowerCase()));
      final matchesType = type == null || t.type == type;
      final matchesCategory =
          category == null || category == 'All' || t.category == category;
      final matchesMonth = month == null ||
          (t.date.year == month.year && t.date.month == month.month);
      // Rentang bebas: from inklusif, to eksklusif (konsisten query SQL).
      final matchesFrom = from == null || !t.date.isBefore(from);
      final matchesTo = to == null || t.date.isBefore(to);
      return matchesQuery &&
          matchesType &&
          matchesCategory &&
          matchesMonth &&
          matchesFrom &&
          matchesTo;
    }).toList();
  }

  List<String> get allCategories => {
        'All',
        ..._transactions.map((t) => t.category),
        ..._budgets.map((b) => b.name),
        ..._customCategories.map((c) => c.name),
      }.toList();
}
