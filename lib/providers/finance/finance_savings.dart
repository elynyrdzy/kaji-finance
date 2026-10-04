part of '../finance_provider.dart';

/// Target tabungan + operasi atomik + delta goal (extension FinanceProvider).
/// Logic disalin verbatim dari FinanceProvider monolit (P2-a: code motion).
extension FinanceSavings on FinanceProvider {
  int get totalSavingsTarget => _goals.fold(0, (sum, g) => sum + g.target);

  int get totalSavingsSaved => _goals.fold(0, (sum, g) => sum + g.saved);

  double get savingsOverallProgress => totalSavingsTarget <= 0
      ? 0
      : (totalSavingsSaved / totalSavingsTarget).clamp(0, 1).toDouble();

  Future<bool> addSavingsGoal({
    required String name,
    required int target,
    IconData icon = Icons.savings_outlined,
    Color color = const Color(0xFF1A4D8F),
    DateTime? deadline,
  }) async {
    if (name.trim().isEmpty || target <= 0) return false;
    if (_goals.any((g) => g.name.toLowerCase() == name.trim().toLowerCase())) {
      return false;
    }
    final snap = _takeSnapshot();
    _goals.add(
      SavingsGoalModel(
        id: _uuid.v4(),
        name: name.trim(),
        target: target,
        saved: 0,
        icon: icon,
        color: color,
        deadline: deadline,
        createdAt: DateTime.now(),
      ),
    );
    final goalId = _goals.last.id;
    _notify();
    try {
      await _persistAtomically(
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.goalCreated,
            entityType: 'goal',
            entityId: goalId,
            metadata: {'name': name.trim(), 'target': target},
          ),
        ],
        debugLabel: 'addGoal',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('goal.add.failed', e);
      return false;
    }
    return true;
  }

  Future<bool> updateSavingsGoal(
    String id, {
    String? name,
    int? target,
    IconData? icon,
    Color? color,
    DateTime? deadline,
    bool clearDeadline = false,
  }) async {
    final idx = _goals.indexWhere((g) => g.id == id);
    if (idx == -1) return false;
    final oldName = _goals[idx].name;
    final newName = name?.trim();
    if (newName != null) {
      if (newName.isEmpty) return false;
      if (_goals.any(
        (g) => g.id != id && g.name.toLowerCase() == newName.toLowerCase(),
      )) {
        return false;
      }
    }
    if (target != null && target <= 0) return false;
    final snap = _takeSnapshot();
    _goals[idx] = _goals[idx].copyWith(
      name: newName,
      target: target,
      icon: icon,
      color: color,
      deadline: deadline,
      clearDeadline: clearDeadline,
    );
    // Migrasi nama goal di transaksi tertaut (akun "Wallet → Goal").
    var touchedTx = false;
    if (newName != null && newName != oldName) {
      for (var i = 0; i < _transactions.length; i++) {
        final t = _transactions[i];
        if (t.linkedGoalId == id) {
          final parts = t.account.split(' → ');
          if (parts.length == 2) {
            final fixed = t.tag == 'savings_deposit'
                ? '${parts[0]} → $newName'
                : '$newName → ${parts[1]}';
            _transactions[i] = t.copyWith(account: fixed);
            touchedTx = true;
          }
        }
      }
      if (touchedTx) _invalidateTxCache();
    }
    _notify();
    try {
      await _persistAtomically(
        goals: true,
        fullTx: touchedTx,
        audit: [
          AuditService.rowFor(
            action: AuditAction.goalUpdated,
            entityType: 'goal',
            entityId: id,
            metadata: {'name': _goals[idx].name},
          ),
        ],
        debugLabel: 'updateGoal',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('goal.update.failed', e);
      return false;
    }
    return true;
  }

  /// Hapus goal. Transaksi tertaut TIDAK dihapus agar riwayat utuh —
  /// di-unlink jadi pemasukan/pengeluaran biasa (tanpa delta saldo,
  /// saldo sudah final saat setor/tarik). Return jumlah tx yang di-unlink.
  Future<int> deleteSavingsGoal(String id) async {
    final snap = _takeSnapshot();
    final gIdx = _goals.indexWhere((g) => g.id == id);
    final goalName = gIdx == -1 ? null : _goals[gIdx].name;
    var unlinked = 0;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (t.linkedGoalId != id) continue;
      TransactionModel fixed;
      if (t.tag == 'savings_deposit') {
        final from = t.account.contains(' → ')
            ? t.account.split(' → ').first
            : t.account;
        fixed = TransactionModel(
          id: t.id,
          title: t.title,
          category: t.category,
          account: from,
          amount: t.amount,
          type: TransactionType.expense,
          date: t.date,
          icon: t.icon,
          note: t.note,
          fromWalletId: t.fromWalletId ?? _walletIdOf(from),
        );
      } else if (t.tag == 'savings_withdraw') {
        final to =
            t.account.contains(' → ') ? t.account.split(' → ').last : t.account;
        fixed = TransactionModel(
          id: t.id,
          title: t.title,
          category: t.category,
          account: to,
          amount: t.amount,
          type: TransactionType.income,
          date: t.date,
          icon: t.icon,
          note: t.note,
          fromWalletId: t.toWalletId ?? _walletIdOf(to),
        );
      } else {
        // Fallback: pertahankan tipe, buang tautan. Bersihkan nama goal
        // dari string akun agar tidak menunjuk ke nama yang sudah dihapus.
        var acct = t.account;
        if (goalName != null && acct.contains(' → ')) {
          final parts = acct.split(' → ');
          if (parts.length == 2) {
            acct = parts[0] == goalName
                ? parts[1]
                : parts[1] == goalName
                    ? parts[0]
                    : acct;
          }
        }
        fixed = TransactionModel(
          id: t.id,
          title: t.title,
          category: t.category,
          account: acct,
          amount: t.amount,
          type: t.type,
          date: t.date,
          icon: t.icon,
          note: t.note,
        );
      }
      _transactions[i] = fixed;
      unlinked++;
    }
    if (unlinked > 0) _invalidateTxCache();
    _goals.removeWhere((g) => g.id == id);
    _notify();
    try {
      await _persistAtomically(
        goals: true,
        fullTx: unlinked > 0,
        audit: [
          AuditService.rowFor(
            action: AuditAction.goalDeleted,
            entityType: 'goal',
            entityId: id,
            metadata: {'unlinked': unlinked},
          ),
        ],
        debugLabel: 'deleteGoal',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('goal.delete.failed', e);
      return 0;
    }
    return unlinked;
  }

  /// Setor atomik: wallet −, goal +, transaksi Transfer tercatat (§33,§36).
  /// Semua mutasi memori terjadi sinkron; bila validasi gagal, TIDAK ADA
  /// yang berubah. Dompet sumber WAJIB agar kekayaan bersih tidak mengembang.
  /// [txTitle]/[txCategory] di-passing dari UI yang sudah lokal.
  /// Phase 2: persist SATU transaksi DB + rollback in-memory bila gagal.
  Future<bool> depositToGoalAtomic({
    required String goalId,
    required int amount,
    required String fromWallet,
    String? idempotencyKey,
    required String txTitle,
    String txCategory = 'Transfer',
  }) async {
    if (idempotencyKey != null && _savingsOpKeys.contains(idempotencyKey)) {
      return false;
    }
    final gIdx = _goals.indexWhere((g) => g.id == goalId);
    if (gIdx == -1) return false;
    if (amount <= 0) return false;
    if (fromWallet.isEmpty) return false;
    final wIdx = _wallets.indexWhere((w) => w.name == fromWallet);
    if (wIdx == -1) return false;
    if (_wallets[wIdx].balance < amount) return false;
    final goal = _goals[gIdx];
    final snap = _takeSnapshot();
    AppLog.event('savings.deposit.started', data: {'goal': goalId});
    try {
      _wallets[wIdx] = _wallets[wIdx].copyWith(
        balance: _wallets[wIdx].balance - amount,
      );
      _goals[gIdx] = goal.copyWith(saved: goal.saved + amount);
      final depTx = TransactionModel(
        id: _uuid.v4(),
        title: txTitle,
        category: txCategory,
        account: '$fromWallet → ${goal.name}',
        amount: amount,
        type: TransactionType.transfer,
        date: DateTime.now(),
        icon: Icons.savings_outlined,
        tag: 'savings_deposit',
        linkedGoalId: goalId,
        fromWalletId: _wallets[wIdx].id,
      );
      _transactions.add(depTx);
      _invalidateTxCache();
      if (idempotencyKey != null) _rememberSavingsOpKey(idempotencyKey);
      _notify();
      await _persistAtomically(
        upsertTx: depTx,
        wl: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.savingsDeposited,
            entityType: 'goal',
            entityId: goalId,
            metadata: {
              'amount': amount,
              'wallet': fromWallet,
              'transactionId': depTx.id,
            },
          ),
        ],
        debugLabel: 'depositToGoal',
      );
      AppLog.event('savings.deposit.completed', data: {'goal': goalId});
      return true;
    } catch (e) {
      _restoreSnapshot(snap);
      _invalidateTxCache();
      _notify();
      AppLog.error('savings.deposit.failed', e);
      return false;
    }
  }

  /// Tarik atomik: goal −, wallet +, transaksi Transfer tercatat (§35,§36).
  /// Phase 2: persist SATU transaksi DB + rollback in-memory bila gagal.
  Future<bool> withdrawFromGoalAtomic({
    required String goalId,
    required int amount,
    required String toWallet,
    String? idempotencyKey,
    required String txTitle,
    String txCategory = 'Transfer',
  }) async {
    if (idempotencyKey != null && _savingsOpKeys.contains(idempotencyKey)) {
      return false;
    }
    final gIdx = _goals.indexWhere((g) => g.id == goalId);
    if (gIdx == -1) return false;
    if (amount <= 0) return false;
    if (toWallet.isEmpty) return false;
    if (_goals[gIdx].saved < amount) return false;
    final wIdx = _wallets.indexWhere((w) => w.name == toWallet);
    if (wIdx == -1) return false;
    final snap = _takeSnapshot();
    AppLog.event('savings.withdraw.started', data: {'goal': goalId});
    try {
      final goal = _goals[gIdx];
      final prevWallet = _wallets[wIdx].balance;
      final ns = goal.saved - amount;
      _goals[gIdx] = goal.copyWith(saved: ns < 0 ? 0 : ns);
      _wallets[wIdx] = _wallets[wIdx].copyWith(balance: prevWallet + amount);
      final wdTx = TransactionModel(
        id: _uuid.v4(),
        title: txTitle,
        category: txCategory,
        account: '${goal.name} → $toWallet',
        amount: amount,
        type: TransactionType.transfer,
        date: DateTime.now(),
        icon: Icons.savings_outlined,
        tag: 'savings_withdraw',
        linkedGoalId: goalId,
        toWalletId: _wallets[wIdx].id,
      );
      _transactions.add(wdTx);
      _invalidateTxCache();
      if (idempotencyKey != null) _rememberSavingsOpKey(idempotencyKey);
      _notify();
      await _persistAtomically(
        upsertTx: wdTx,
        wl: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.savingsWithdrawn,
            entityType: 'goal',
            entityId: goalId,
            metadata: {
              'amount': amount,
              'wallet': toWallet,
              'transactionId': wdTx.id,
            },
          ),
        ],
        debugLabel: 'withdrawFromGoal',
      );
      AppLog.event('savings.withdraw.completed', data: {'goal': goalId});
      return true;
    } catch (e) {
      _restoreSnapshot(snap);
      _invalidateTxCache();
      _notify();
      AppLog.error('savings.withdraw.failed', e);
      return false;
    }
  }

  /// Total setoran tabungan bulan berjalan (dari transaksi tertaut) —
  /// metrik §40 yang didukung data aktual, bukan fabrikasi.
  int savingsDepositsThisMonth({DateTime? month}) {
    final m = month ?? DateTime.now();
    return _transactions
        .where(
          (t) =>
              t.tag == 'savings_deposit' &&
              t.date.year == m.year &&
              t.date.month == m.month,
        )
        .fold(0, (s, t) => s + t.amount);
  }

  bool _isSavingsLinked(TransactionModel tx) =>
      tx.linkedGoalId != null ||
      tx.tag == 'savings_deposit' ||
      tx.tag == 'savings_withdraw';

  /// Publik untuk UI (menu duplikat) — true bila tx adalah setoran/
  /// penarikan tabungan atomik yang tidak boleh diduplikat/diubah umum.
  bool isSavingsLinkedTx(String id) {
    final idx = _transactions.indexWhere((t) => t.id == id);
    if (idx == -1) return false;
    return _isSavingsLinked(_transactions[idx]);
  }

  /// Jumlah tx tertaut ke goal — dipakai dialog hapus goal.
  int savingsLinkedCount(String goalId) =>
      _transactions.where((t) => t.linkedGoalId == goalId).length;

  void _revertGoalDeltaForTx(TransactionModel tx) {
    if (!_isSavingsLinked(tx)) return;
    final gid = tx.linkedGoalId;
    final gIdx = gid == null ? -1 : _goals.indexWhere((g) => g.id == gid);
    if (gIdx == -1) return;
    if (tx.tag == 'savings_deposit') {
      final ns = _goals[gIdx].saved - tx.amount;
      _goals[gIdx] = _goals[gIdx].copyWith(saved: ns < 0 ? 0 : ns);
    } else if (tx.tag == 'savings_withdraw') {
      _goals[gIdx] = _goals[gIdx].copyWith(
        saved: _goals[gIdx].saved + tx.amount,
      );
    }
  }

  void _applyGoalDeltaForTx(TransactionModel tx) {
    if (!_isSavingsLinked(tx)) return;
    final gid = tx.linkedGoalId;
    final gIdx = gid == null ? -1 : _goals.indexWhere((g) => g.id == gid);
    if (gIdx == -1) return;
    if (tx.tag == 'savings_deposit') {
      _goals[gIdx] = _goals[gIdx].copyWith(
        saved: _goals[gIdx].saved + tx.amount,
      );
    } else if (tx.tag == 'savings_withdraw') {
      final ns = _goals[gIdx].saved - tx.amount;
      _goals[gIdx] = _goals[gIdx].copyWith(saved: ns < 0 ? 0 : ns);
    }
  }
}
