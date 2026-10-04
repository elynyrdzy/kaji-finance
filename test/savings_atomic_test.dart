import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Skenario §56: pergerakan internal dompet ↔ tabungan.
Future<FinanceProvider> freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  // Isolasi antar-test: backend memori fresh + migrasi prefs mock.
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

void main() {
  group('Savings atomik (§33-§39, §56)', () {
    test('setor 500rb: dompet 8.5jt→8jt, tabungan 0→500rb', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'Utama',
          '• 1',
          Icons.wallet,
          const Color(0xFF1A4D8F),
          8500000,
        ),
        isTrue,
      );
      expect(
        await fp.addSavingsGoal(name: 'Dana Darurat', target: 1000000),
        isTrue,
      );
      final goalId = fp.savingsGoals.single.id;

      final ok = await fp.depositToGoalAtomic(
        goalId: goalId,
        amount: 500000,
        fromWallet: 'Utama',
        idempotencyKey: 'test-dep-1',
        txTitle: 'Setoran Tabungan',
      );
      expect(ok, isTrue);
      expect(fp.wallets.single.balance, 8000000);
      expect(fp.savingsGoals.single.saved, 500000);
    });

    test('setoran tercatat sebagai Transfer & analitik tak naik', () async {
      final fp = await freshProvider();
      await fp.addWallet(
        'Utama',
        '• 1',
        Icons.wallet,
        const Color(0xFF1A4D8F),
        8500000,
      );
      await fp.addSavingsGoal(name: 'Dana Darurat', target: 1000000);
      final goalId = fp.savingsGoals.single.id;
      await fp.depositToGoalAtomic(
        goalId: goalId,
        amount: 500000,
        fromWallet: 'Utama',
        txTitle: 'Setoran Tabungan',
      );

      final txs =
          fp.transactions.where((t) => t.linkedGoalId == goalId).toList();
      expect(txs.length, 1);
      expect(txs.single.type, TransactionType.transfer);
      expect(txs.single.tag, 'savings_deposit');
      // Kekayaan bersih TIDAK berubah: 8jt + 500rb = 8.5jt.
      expect(fp.walletTotal + fp.totalSavingsSaved, 8500000);
      // BUKAN belanja: totalExpense tetap 0.
      expect(fp.totalExpense, 0);
      expect(fp.totalIncome, 0);
      // Metrik tabungan naik 500rb.
      expect(fp.totalSavingsSaved, 500000);
      expect(fp.savingsDepositsThisMonth(), 500000);
    });

    test('tarik mengembalikan dompet + catat withdrawal', () async {
      final fp = await freshProvider();
      await fp.addWallet(
        'Utama',
        '• 1',
        Icons.wallet,
        const Color(0xFF1A4D8F),
        8000000,
      );
      await fp.addSavingsGoal(name: 'Dana Darurat', target: 1000000);
      final goalId = fp.savingsGoals.single.id;
      // Setor manual via atomik dari dompet lain? Setor dulu:
      await fp.depositToGoalAtomic(
        goalId: goalId,
        amount: 500000,
        fromWallet: 'Utama',
        txTitle: 'Setoran Tabungan',
      );
      final ok = await fp.withdrawFromGoalAtomic(
        goalId: goalId,
        amount: 200000,
        toWallet: 'Utama',
        txTitle: 'Penarikan Tabungan',
      );
      expect(ok, isTrue);
      expect(fp.savingsGoals.single.saved, 300000);
      expect(fp.wallets.single.balance, 7700000);
      expect(fp.totalExpense, 0);
      final wd =
          fp.transactions.where((t) => t.tag == 'savings_withdraw').toList();
      expect(wd.length, 1);
      expect(wd.single.linkedGoalId, goalId);
    });

    test('idempotency: kunci sama ditolak kedua kali', () async {
      final fp = await freshProvider();
      await fp.addWallet(
        'Utama',
        '• 1',
        Icons.wallet,
        const Color(0xFF1A4D8F),
        8500000,
      );
      await fp.addSavingsGoal(name: 'Dana Darurat', target: 10000000);
      final goalId = fp.savingsGoals.single.id;
      expect(
        await fp.depositToGoalAtomic(
          goalId: goalId,
          amount: 100000,
          fromWallet: 'Utama',
          idempotencyKey: 'same-key',
          txTitle: 'Setoran Tabungan',
        ),
        isTrue,
      );
      expect(
        await fp.depositToGoalAtomic(
          goalId: goalId,
          amount: 100000,
          fromWallet: 'Utama',
          idempotencyKey: 'same-key',
          txTitle: 'Setoran Tabungan',
        ),
        isFalse,
      );
      expect(fp.savingsGoals.single.saved, 100000);
    });

    test('saldo kurang & wallet hilang ditolak tanpa perubahan', () async {
      final fp = await freshProvider();
      await fp.addWallet(
        'Utama',
        '• 1',
        Icons.wallet,
        const Color(0xFF1A4D8F),
        100000,
      );
      await fp.addSavingsGoal(name: 'Dana Darurat', target: 1000000);
      final goalId = fp.savingsGoals.single.id;
      expect(
        await fp.depositToGoalAtomic(
          goalId: goalId,
          amount: 500000,
          fromWallet: 'Utama',
          txTitle: 'Setoran Tabungan',
        ),
        isFalse,
      );
      expect(
        await fp.depositToGoalAtomic(
          goalId: goalId,
          amount: 50000,
          fromWallet: 'Dompet Hantu',
          txTitle: 'Setoran Tabungan',
        ),
        isFalse,
      );
      expect(fp.savingsGoals.single.saved, 0);
      expect(fp.wallets.single.balance, 100000);
      expect(fp.transactions, isEmpty);
    });
  });
}
