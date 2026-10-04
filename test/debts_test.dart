import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/debt_entry.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mini-ledger Hutang–Piutang / Kasbon / Arisan: CRUD + cicilan ledger +
/// overdraft guard + rekonsiliasi pola walletExpected.
Future<FinanceProvider> freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  PrefsDebtStore.resetCacheForTest();
  // Isolasi antar-test: backend memori fresh + migrasi prefs mock.
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await fp.loadDebts();
  return fp;
}

Future<FinanceProvider> walletProvider(int balance) async {
  final fp = await freshProvider();
  expect(
    await fp.addWallet(
      'Utama',
      '• 1',
      Icons.wallet,
      const Color(0xFF1A4D8F),
      balance,
    ),
    isTrue,
  );
  return fp;
}

void main() {
  group('Debts mini-ledger', () {
    test('tambah hutang & piutang: ringkasan terpisah', () async {
      final fp = await walletProvider(1000000);
      final hutang = await fp.addDebt(
        counterparty: 'Budi',
        direction: DebtDirection.payable,
        kind: DebtKind.debt,
        amount: 500000,
      );
      final piutang = await fp.addDebt(
        counterparty: 'Ani',
        direction: DebtDirection.receivable,
        kind: DebtKind.kasbon,
        amount: 200000,
      );
      expect(hutang, isNotNull);
      expect(piutang, isNotNull);
      expect(fp.debts.length, 2);
      expect(fp.totalPayableRemaining, 500000);
      expect(fp.totalReceivableRemaining, 200000);
      // Tanpa dompet: tak ada transaksi ledger.
      expect(fp.transactions, isEmpty);
    });

    test('validasi: nama kosong / nominal 0 ditolak', () async {
      final fp = await walletProvider(1000000);
      expect(
        await fp.addDebt(
          counterparty: '  ',
          direction: DebtDirection.payable,
          kind: DebtKind.debt,
          amount: 100000,
        ),
        isNull,
      );
      expect(
        await fp.addDebt(
          counterparty: 'Budi',
          direction: DebtDirection.payable,
          kind: DebtKind.debt,
          amount: 0,
        ),
        isNull,
      );
      expect(fp.debts, isEmpty);
    });

    test('bayar hutang parsial: expense + sisa berkurang', () async {
      final fp = await walletProvider(1000000);
      final id = (await fp.addDebt(
        counterparty: 'Warung Bu Ani',
        direction: DebtDirection.payable,
        kind: DebtKind.kasbon,
        amount: 300000,
      ))!;
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 100000, wallet: 'Utama'),
        isTrue,
      );
      expect(fp.wallets.single.balance, 900000);
      expect(fp.totalExpense, 100000);
      final d = fp.debtById(id)!;
      expect(d.paidTotal, 100000);
      expect(d.remaining, 200000);
      expect(d.isSettled, isFalse);
      final tx = fp.transactionsForDebt(id);
      expect(tx.length, 1);
      expect(tx.single.type, TransactionType.expense);
      expect(tx.single.tag, DebtLedgerLink.paymentTag);
    });

    test('lunasi penuh + status settled + rekonsiliasi cocok', () async {
      final fp = await walletProvider(1000000);
      final id = (await fp.addDebt(
        counterparty: 'Budi',
        direction: DebtDirection.payable,
        kind: DebtKind.debt,
        amount: 300000,
      ))!;
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 100000, wallet: 'Utama'),
        isTrue,
      );
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 200000, wallet: 'Utama'),
        isTrue,
      );
      final d = fp.debtById(id)!;
      expect(d.isSettled, isTrue);
      expect(d.remaining, 0);
      expect(fp.totalPayableRemaining, 0);
      // Pola walletExpected: catatan == ledger.
      expect(fp.debtPaidFromLedger(id), 300000);
      expect(fp.reconcileDebts(), isEmpty);
      // Bayar lagi setelah lunas ditolak.
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 10000, wallet: 'Utama'),
        isFalse,
      );
    });

    test('overdraft guard: bayar melebihi saldo dompet ditolak', () async {
      final fp = await walletProvider(50000);
      final id = (await fp.addDebt(
        counterparty: 'Budi',
        direction: DebtDirection.payable,
        kind: DebtKind.debt,
        amount: 300000,
      ))!;
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 100000, wallet: 'Utama'),
        isFalse,
      );
      expect(fp.wallets.single.balance, 50000);
      expect(fp.debtById(id)!.paidTotal, 0);
      expect(fp.transactions, isEmpty);
    });

    test('terima piutang: income ke dompet', () async {
      final fp = await walletProvider(100000);
      final id = (await fp.addDebt(
        counterparty: 'Ani',
        direction: DebtDirection.receivable,
        kind: DebtKind.arisan,
        amount: 250000,
      ))!;
      expect(
        await fp.recordDebtPayment(debtId: id, amount: 250000, wallet: 'Utama'),
        isTrue,
      );
      expect(fp.wallets.single.balance, 350000);
      expect(fp.totalIncome, 250000);
      expect(fp.debtById(id)!.isSettled, isTrue);
      final tx = fp.transactionsForDebt(id);
      expect(tx.single.type, TransactionType.income);
    });

    test(
      'pencairan awal via dompet: payable→income, receivable→expense',
      () async {
        final fp = await walletProvider(1000000);
        final h = (await fp.addDebt(
          counterparty: 'Budi',
          direction: DebtDirection.payable,
          kind: DebtKind.debt,
          amount: 400000,
          wallet: 'Utama',
        ))!;
        expect(fp.totalIncome, 400000);
        expect(fp.wallets.single.balance, 1400000);
        final p = (await fp.addDebt(
          counterparty: 'Ani',
          direction: DebtDirection.receivable,
          kind: DebtKind.debt,
          amount: 200000,
          wallet: 'Utama',
        ))!;
        expect(fp.totalExpense, 200000);
        expect(fp.wallets.single.balance, 1200000);
        expect(
          fp.transactionsForDebt(h).single.tag,
          DebtLedgerLink.principalTag,
        );
        expect(
          fp.transactionsForDebt(p).single.tag,
          DebtLedgerLink.principalTag,
        );
      },
    );

    test(
      'beri pinjaman melebihi saldo ditolak (overdraft pencairan)',
      () async {
        final fp = await walletProvider(50000);
        expect(
          await fp.addDebt(
            counterparty: 'Ani',
            direction: DebtDirection.receivable,
            kind: DebtKind.debt,
            amount: 200000,
            wallet: 'Utama',
          ),
          isNull,
        );
        expect(fp.debts, isEmpty);
        expect(fp.wallets.single.balance, 50000);
      },
    );

    test('hapus entry: tx ledger di-unlink jadi biasa', () async {
      final fp = await walletProvider(1000000);
      final id = (await fp.addDebt(
        counterparty: 'Budi',
        direction: DebtDirection.payable,
        kind: DebtKind.debt,
        amount: 300000,
      ))!;
      await fp.recordDebtPayment(debtId: id, amount: 100000, wallet: 'Utama');
      final unlinked = await fp.deleteDebt(id);
      expect(unlinked, 1);
      expect(fp.debts, isEmpty);
      // Riwayat transaksi tetap ada sebagai expense biasa.
      expect(fp.transactions.length, 1);
      expect(fp.transactions.single.tag, isNull);
      expect(fp.totalExpense, 100000);
    });

    test('jatuh tempo: overdue & dueSoon', () async {
      final fp = await walletProvider(1000000);
      final now = DateTime.now();
      await fp.addDebt(
        counterparty: 'Lewat',
        direction: DebtDirection.payable,
        kind: DebtKind.debt,
        amount: 100000,
        borrowedAt: now.subtract(const Duration(days: 10)),
        dueAt: now.subtract(const Duration(days: 1)),
      );
      await fp.addDebt(
        counterparty: 'Segera',
        direction: DebtDirection.payable,
        kind: DebtKind.kasbon,
        amount: 100000,
        dueAt: now.add(const Duration(days: 3)),
      );
      expect(fp.overdueDebts().length, 1);
      expect(fp.overdueDebts().single.counterparty, 'Lewat');
      expect(fp.debtsDueSoon(days: 7).length, 1);
      expect(fp.overdueDebtsCount, 1);
    });

    test('persistensi prefs: load ulang memulihkan entry', () async {
      var fp = await walletProvider(1000000);
      await fp.addDebt(
        counterparty: 'Budi',
        direction: DebtDirection.payable,
        kind: DebtKind.arisan,
        amount: 150000,
      );
      // Provider baru, prefs mock yang sama → entry pulih via loadDebts.
      PrefsDebtStore.resetCacheForTest();
      await SecureDbService.useInMemory();
      fp = FinanceProvider();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await fp.loadDebts();
      expect(fp.debts.length, 1);
      expect(fp.debts.single.counterparty, 'Budi');
      expect(fp.totalPayableRemaining, 150000);
    });
  });
}
