part of '../finance_provider.dart';

/// Rekonsiliasi ledger-vs-projection + repair aman + backfill P3
/// (extension bagian FinanceProvider).
///
/// - Ledger ([_transactions]) adalah source of truth.
/// - `wallet.balance`, `budget.spent`, `goal.saved` adalah projection yang
///   bisa di-rebuild. [repairProjections] hanya menulis projection, TIDAK
///   PERNAH mengubah historical transaction.
extension FinanceReconciliation on FinanceProvider {
  /// Flag sekali-jalan per profil untuk backfill opening balance P3.
  static String get _kInitMigrated =>
      ProfileService.scoped('kaji_wallet_init_migrated');

  /// Saldo ledger-derived untuk wallet [w] (opening + delta).
  int walletExpectedOf(WalletModel w) => ReconciliationService.walletExpected(
        w,
        _transactions,
        allWallets: _wallets,
      );

  Future<ReconciliationReport> reconcileWallets() async => ReconciliationReport(
        checkedAt: DateTime.now(),
        mismatches:
            ReconciliationService.reconcileWallets(_wallets, _transactions),
        checkedWallets: _wallets.length,
        checkedBudgets: 0,
        checkedGoals: 0,
      );

  Future<ReconciliationReport> reconcileBudgets({DateTime? month}) async =>
      ReconciliationReport(
        checkedAt: DateTime.now(),
        mismatches: ReconciliationService.reconcileBudgets(
          _budgets,
          _transactions,
          month: month ?? DateTime.now(),
        ),
        checkedWallets: 0,
        checkedBudgets: _budgets.length,
        checkedGoals: 0,
      );

  Future<ReconciliationReport> reconcileGoals() async => ReconciliationReport(
        checkedAt: DateTime.now(),
        mismatches: ReconciliationService.reconcileGoals(_goals, _transactions),
        checkedWallets: 0,
        checkedBudgets: 0,
        checkedGoals: _goals.length,
      );

  Future<ReconciliationReport> reconcileAll({DateTime? month}) async =>
      ReconciliationService.reconcileAll(
        wallets: _wallets,
        budgets: _budgets,
        goals: _goals,
        transactions: _transactions,
        month: month,
      );

  /// Tulis ulang projection dari ledger dalam SATU transaksi DB.
  /// Aman: hanya `balance/spent/saved`, ledger tak disentuh.
  /// Return jumlah entitas yang diperbaiki.
  Future<int> repairProjections({DateTime? month}) async {
    final snap = _takeSnapshot();
    final m = month ?? DateTime.now();
    var repaired = 0;
    for (var i = 0; i < _wallets.length; i++) {
      final expected = ReconciliationService.walletExpected(
        _wallets[i],
        _transactions,
        allWallets: _wallets,
      );
      if (!ReconciliationService.isClose(expected, _wallets[i].balance)) {
        _wallets[i] = _wallets[i].copyWith(balance: expected);
        repaired++;
      }
    }
    for (var i = 0; i < _budgets.length; i++) {
      final expected = ReconciliationService.budgetExpected(
        _budgets[i].name,
        _transactions,
        month: m,
      );
      if (!ReconciliationService.isClose(expected, _budgets[i].spent)) {
        _budgets[i] = _budgets[i].copyWith(spent: expected);
        repaired++;
      }
    }
    for (var i = 0; i < _goals.length; i++) {
      final r = ReconciliationService.goalExpected(_goals[i].id, _transactions);
      if (!ReconciliationService.isClose(r.expected, _goals[i].saved)) {
        _goals[i] = _goals[i].copyWith(saved: r.expected);
        repaired++;
      }
    }
    if (repaired == 0) return 0;
    _invalidateTxCache();
    _notify();
    AppLog.event('reconcile.repair.started', data: {'count': repaired});
    try {
      await _persistAtomically(
        wl: true,
        bd: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.reconcileRepaired,
            entityType: 'reconcile',
            entityId: 'repair',
            metadata: {'repaired': repaired},
          ),
        ],
        debugLabel: 'repairProjections',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('reconcile.repair.failed', e);
      return 0;
    }
    AppLog.event('reconcile.repair.completed', data: {'count': repaired});
    return repaired;
  }

  /// Backfill sekali-jalan: `initialBalance = balance − ledgerDelta` per
  /// wallet, lalu persist atomik + set flag profil. Menjadikan ledger
  /// konsisten by construction untuk data pra-P3 (opening-balance plug);
  /// divergensi SETELAH ini adalah genuine dan terdeteksi reconcile.
  /// Idempoten via flag; aman di-retry (baca-banding-tulis ulang sama).
  Future<void> backfillWalletInitialBalances() async {
    if (_wallets.isEmpty) return;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kInitMigrated) == true) return;
    } catch (_) {
      // prefs tak terbaca → tetap hitung di memori, skip persist flag.
    }
    var touched = false;
    for (var i = 0; i < _wallets.length; i++) {
      final w = _wallets[i];
      // Baris pra-P3 punya initial 0 (default kolom) sementara balance
      // nonzero / ada delta ledger → hitung ulang. Wallet yang sudah
      // benar (initial + delta == balance) tidak disentuh.
      final delta = ReconciliationService.walletLedgerDelta(
        w,
        _transactions,
        allWallets: _wallets,
      );
      final implied = w.balance - delta;
      if (!ReconciliationService.isClose(w.initialBalance + delta, w.balance)) {
        _wallets[i] = w.copyWith(initialBalance: implied);
        touched = true;
      }
    }
    if (touched) {
      _notify();
      try {
        await _persistAtomically(
          wl: true,
          audit: [
            AuditService.rowFor(
              action: AuditAction.migrationBackfill,
              entityType: 'wallet',
              entityId: 'opening-balance',
            ),
          ],
          debugLabel: 'backfillInitial',
        );
      } catch (e) {
        SecureDbService.noteError('backfill initial gagal: $e');
      }
    }
    try {
      await prefs?.setBool(_kInitMigrated, true);
    } catch (_) {
      // best-effort: flag gagal → backfill dihitung ulang next load
      // (hasil sama, idempoten).
    }
  }
}
