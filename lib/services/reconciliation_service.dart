import '../models/budget_model.dart';
import '../models/savings_goal_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';

/// Tag audit untuk koreksi saldo manual (P3). Arah (kredit/debit) di-resolve
/// dari from/to wallet ID, bukan dari tag — tag hanya menandai audit trail.
class BalanceAdjustment {
  BalanceAdjustment._();
  static const tag = 'balance_adjustment';
  static const category = 'Adjustment';
  static const title = 'Penyesuaian saldo';
  static const defaultReason = 'Penyesuaian saldo manual';
}

/// Satu ketidaksesuaian ledger vs projection yang terdeteksi.
class ReconciliationMismatch {
  const ReconciliationMismatch({
    required this.entityType,
    required this.entityId,
    required this.entityName,
    required this.expected,
    required this.actual,
    required this.reason,
  });

  /// `wallet` | `budget` | `goal`.
  final String entityType;
  final String entityId;
  final String entityName;

  /// Nilai yang direkonstruksi dari ledger (source of truth, minor units).
  final int expected;

  /// Nilai projection yang tersimpan (minor units).
  final int actual;

  /// Selisih = actual − expected (negatif = tersimpan lebih kecil).
  int get difference => actual - expected;

  /// Penjelasan bila penyebab terdeteksi (mis. asumsi fallback).
  final String? reason;
}

/// Hasil rekonsiliasi deterministik (urut stabil by type + id).
class ReconciliationReport {
  const ReconciliationReport({
    required this.checkedAt,
    required this.mismatches,
    required this.checkedWallets,
    required this.checkedBudgets,
    required this.checkedGoals,
  });

  final DateTime checkedAt;
  final List<ReconciliationMismatch> mismatches;
  final int checkedWallets;
  final int checkedBudgets;
  final int checkedGoals;

  bool get ok => mismatches.isEmpty;
  int get checkedTotal => checkedWallets + checkedBudgets + checkedGoals;

  String summary() {
    if (ok) return 'OK ($checkedTotal entitas cocok)';
    final buf = StringBuffer('${mismatches.length} mismatch:\n');
    for (final m in mismatches) {
      buf.writeln(
        '- [${m.entityType}] ${m.entityName}: expected=${m.expected} '
        'actual=${m.actual} diff=${m.difference}'
        '${m.reason == null ? '' : ' (${m.reason})'}',
      );
    }
    return buf.toString();
  }
}

/// Ledger sebagai source of truth (P3): fungsi murni tanpa I/O agar
/// teruji deterministik. Phase 4: seluruh nilai minor units integer —
/// perbandingan eksak (tak ada epsilon debu float).
class ReconciliationService {
  ReconciliationService._();

  /// True bila dua nilai moneter sama. Dipertahankan sebagai API agar
  /// provider repair/backfill memakai predikat yang identik dengan report.
  /// Integer → persamaan eksak.
  static bool isClose(int a, int b) => a == b;

  // --- Delta ledger per wallet (SATU-SATUNYA definisi, dipakai mutasi + rekonsiliasi) ---

  /// Delta per walletId untuk satu [tx], mirror persis semantik
  /// `_applyDeltaIdOrName` P2: cocok ID dulu, fallback nama eksak bila ID
  /// tak dikenal/tak ada. Kunci map = wallet id, nilai = delta bertanda.
  static Map<String, int> walletDeltasForTx(
    List<WalletModel> wallets,
    TransactionModel tx,
  ) {
    final out = <String, int>{};
    if (wallets.isEmpty) return out;
    final ids = {for (final w in wallets) w.id};
    final byName = <String, WalletModel>{};
    for (final w in wallets) {
      byName.putIfAbsent(w.name, () => w);
    }

    void side(String? id, String name, int delta) {
      if (delta == 0) return;
      if (id != null && id.isNotEmpty && ids.contains(id)) {
        out[id] = (out[id] ?? 0) + delta;
        return;
      }
      final w = byName[name];
      if (w != null) out[w.id] = (out[w.id] ?? 0) + delta;
    }

    switch (tx.type) {
      case TransactionType.income:
        side(tx.fromWalletId, tx.account, tx.amount);
      case TransactionType.expense:
        side(tx.fromWalletId, tx.account, -tx.amount);
      case TransactionType.transfer:
        final parts = tx.account.split(' → ');
        final fromName = parts.isNotEmpty ? parts[0] : tx.account;
        final toName = parts.length == 2 ? parts[1] : tx.account;
        side(tx.fromWalletId, fromName, -tx.amount);
        side(tx.toWalletId, toName, tx.amount);
      case TransactionType.adjustment:
        // Tepat satu sisi terisi saat dibuat via adjustWalletBalance.
        // Fallback baris legacy/tangan tanpa ID: asumsikan kredit (+)
        // dengan reason agar terlihat di report, bukan diam.
        if ((tx.fromWalletId == null || tx.fromWalletId!.isEmpty) &&
            (tx.toWalletId == null || tx.toWalletId!.isEmpty)) {
          final w = byName[tx.account];
          if (w != null) out[w.id] = (out[w.id] ?? 0) + tx.amount;
        } else {
          if (tx.fromWalletId != null && tx.fromWalletId!.isNotEmpty) {
            side(tx.fromWalletId, tx.account, -tx.amount);
          }
          if (tx.toWalletId != null && tx.toWalletId!.isEmpty == false) {
            side(tx.toWalletId, tx.account, tx.amount);
          }
        }
    }
    out.removeWhere((_, v) => v == 0);
    return out;
  }

  /// Total delta ledger untuk [wallet] dari seluruh [transactions].
  static int walletLedgerDelta(
    WalletModel wallet,
    List<TransactionModel> transactions, {
    List<WalletModel>? allWallets,
  }) {
    final scope = allWallets ?? [wallet];
    var total = 0;
    for (final tx in transactions) {
      total += walletDeltasForTx(scope, tx)[wallet.id] ?? 0;
    }
    return total;
  }

  /// Saldo yang direkonstruksi dari ledger = opening + delta.
  static int walletExpected(
    WalletModel wallet,
    List<TransactionModel> transactions, {
    List<WalletModel>? allWallets,
  }) =>
      wallet.initialBalance +
      walletLedgerDelta(wallet, transactions, allWallets: allWallets);

  // --- Budget & goal expectations ---

  /// Pengeluaran kategori [category] pada [month], semantik identik
  /// `spentForBudget` (start−1s eksklusif, end eksklusif).
  static int budgetExpected(
    String category,
    List<TransactionModel> transactions, {
    DateTime? month,
  }) {
    final m = month ?? DateTime.now();
    final start = DateTime(m.year, m.month, 1);
    final end = DateTime(m.year, m.month + 1, 1);
    final from = start.subtract(const Duration(seconds: 1));
    var total = 0;
    for (final t in transactions) {
      if (t.type != TransactionType.expense || t.category != category) {
        continue;
      }
      if (t.date.isAfter(from) && t.date.isBefore(end)) total += t.amount;
    }
    return total;
  }

  /// Tabungan yang direkonstruksi = Σ deposit − Σ withdraw tertaut.
  /// Hanya tag resmi yang dihitung (mirror `_applyGoalDeltaForTx`); tautan
  /// bertag asing diabaikan dengan reason agar tidak diam.
  static ({int expected, String? reason}) goalExpected(
    String goalId,
    List<TransactionModel> transactions,
  ) {
    var total = 0;
    String? reason;
    for (final t in transactions) {
      if (t.linkedGoalId != goalId) continue;
      if (t.tag == 'savings_deposit') {
        total += t.amount;
      } else if (t.tag == 'savings_withdraw') {
        total -= t.amount;
      } else {
        reason ??= 'tautan bertag tak dikenal diabaikan';
      }
    }
    return (expected: total, reason: reason);
  }

  // --- Report builders (deterministik) ---

  static List<ReconciliationMismatch> reconcileWallets(
    List<WalletModel> wallets,
    List<TransactionModel> transactions,
  ) {
    final out = <ReconciliationMismatch>[];
    final sorted = List<WalletModel>.from(wallets)
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final w in sorted) {
      final expected = walletExpected(w, transactions, allWallets: wallets);
      if (expected == w.balance) continue;
      String? reason;
      final hasLegacyAdjustment = transactions.any(
        (t) =>
            t.type == TransactionType.adjustment &&
            (t.fromWalletId == null || t.fromWalletId!.isEmpty) &&
            (t.toWalletId == null || t.toWalletId!.isEmpty) &&
            t.account == w.name,
      );
      if (hasLegacyAdjustment) {
        reason = 'adjustment legacy tanpa ID diasumsikan kredit';
      } else if (w.initialBalance == w.balance &&
          transactions.any(
            (t) =>
                t.account == w.name || t.account.split(' → ').contains(w.name),
          )) {
        reason = 'kemungkinan saldo awal belum di-backfill';
      }
      out.add(
        ReconciliationMismatch(
          entityType: 'wallet',
          entityId: w.id,
          entityName: w.name,
          expected: expected,
          actual: w.balance,
          reason: reason,
        ),
      );
    }
    return out;
  }

  static List<ReconciliationMismatch> reconcileBudgets(
    List<BudgetCategory> budgets,
    List<TransactionModel> transactions, {
    DateTime? month,
  }) {
    final out = <ReconciliationMismatch>[];
    final sorted = List<BudgetCategory>.from(budgets)
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final b in sorted) {
      final expected = budgetExpected(
        b.name,
        transactions,
        month: month ?? DateTime.now(),
      );
      if (expected == b.spent) continue;
      out.add(
        ReconciliationMismatch(
          entityType: 'budget',
          entityId: b.id,
          entityName: b.name,
          expected: expected,
          actual: b.spent,
          reason: null,
        ),
      );
    }
    return out;
  }

  static List<ReconciliationMismatch> reconcileGoals(
    List<SavingsGoalModel> goals,
    List<TransactionModel> transactions,
  ) {
    final out = <ReconciliationMismatch>[];
    final sorted = List<SavingsGoalModel>.from(goals)
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final g in sorted) {
      final r = goalExpected(g.id, transactions);
      if (r.expected == g.saved) continue;
      out.add(
        ReconciliationMismatch(
          entityType: 'goal',
          entityId: g.id,
          entityName: g.name,
          expected: r.expected,
          actual: g.saved,
          reason: r.reason ??
              (transactions.any((t) => t.linkedGoalId == g.id)
                  ? null
                  : 'tanpa riwayat ledger tertaut (saldo impor/manual?)'),
        ),
      );
    }
    return out;
  }

  static ReconciliationReport reconcileAll({
    required List<WalletModel> wallets,
    required List<BudgetCategory> budgets,
    required List<SavingsGoalModel> goals,
    required List<TransactionModel> transactions,
    DateTime? month,
    DateTime? checkedAt,
  }) {
    final mismatches = [
      ...reconcileWallets(wallets, transactions),
      ...reconcileBudgets(budgets, transactions, month: month),
      ...reconcileGoals(goals, transactions),
    ]..sort((a, b) {
        final c = a.entityType.compareTo(b.entityType);
        return c != 0 ? c : a.entityId.compareTo(b.entityId);
      });
    return ReconciliationReport(
      checkedAt: checkedAt ?? DateTime.now(),
      mismatches: mismatches,
      checkedWallets: wallets.length,
      checkedBudgets: budgets.length,
      checkedGoals: goals.length,
    );
  }
}
