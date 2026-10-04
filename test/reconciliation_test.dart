import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/models/wallet_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/reconciliation_service.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P3: ledger sebagai source of truth + adjustment beraudit.
///
/// Catatan: tidak ada `flutter test` lokal di sesi ini (instruksi user);
/// file ini diverifikasi via `flutter analyze` + CI.
Future<FinanceProvider> freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

WalletModel wallet(String id, String name, int balance, {int initial = 0}) =>
    WalletModel(
      id: id,
      name: name,
      number: '• 1',
      icon: Icons.wallet,
      balance: balance,
      initialBalance: initial,
      color: const Color(0xFF1A4D8F),
    );

TransactionModel tx(
  String id,
  String account,
  int amount,
  TransactionType type, {
  String? fromId,
  String? toId,
  String? tag,
}) =>
    TransactionModel(
      id: id,
      title: 'T',
      category: 'Other',
      account: account,
      amount: amount,
      type: type,
      date: DateTime(2026, 1, 5),
      icon: Icons.more_horiz,
      tag: tag,
      fromWalletId: fromId,
      toWalletId: toId,
    );

void main() {
  group('walletDeltasForTx (definisi tunggal)', () {
    final wallets = [wallet('w1', 'BCA', 0), wallet('w2', 'Dompet', 0)];

    test('income/expense berarah benar via ID', () {
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'BCA', 100, TransactionType.income, fromId: 'w1'),
        ),
        {'w1': 100},
      );
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'BCA', 40, TransactionType.expense, fromId: 'w1'),
        ),
        {'w1': -40},
      );
    });

    test('transfer mendebit sumber & mengkredit tujuan', () {
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx(
            't',
            'BCA → Dompet',
            25,
            TransactionType.transfer,
            fromId: 'w1',
            toId: 'w2',
          ),
        ),
        {'w1': -25, 'w2': 25},
      );
    });

    test('fallback nama untuk baris legacy tanpa ID', () {
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'Dompet', 10, TransactionType.income),
        ),
        {'w2': 10},
      );
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'BCA → Dompet', 10, TransactionType.transfer),
        ),
        {'w1': -10, 'w2': 10},
      );
    });

    test('dompet tak dikenal = no-op', () {
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'Hantu', 10, TransactionType.expense),
        ),
        isEmpty,
      );
    });

    test('adjustment: toId kredit, fromId debit, legacy tanpa ID kredit', () {
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'BCA', 25, TransactionType.adjustment, toId: 'w1'),
        ),
        {'w1': 25},
      );
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'BCA', 25, TransactionType.adjustment, fromId: 'w1'),
        ),
        {'w1': -25},
      );
      expect(
        ReconciliationService.walletDeltasForTx(
          wallets,
          tx('t', 'Dompet', 7, TransactionType.adjustment),
        ),
        {'w2': 7},
      );
    });
  });

  group('reconcileWallets murni', () {
    test('cocok → ok; drift → mismatch expected/actual/difference', () {
      final wallets = [wallet('w1', 'BCA', 750000, initial: 1000000)];
      final txs = [
        tx('t1', 'BCA', 250000, TransactionType.expense, fromId: 'w1'),
      ];
      // expected = 1000000 − 250000 = 750000 == actual → ok.
      expect(ReconciliationService.reconcileWallets(wallets, txs), isEmpty);

      final drifted = [wallet('w1', 'BCA', 725000, initial: 1000000)];
      final mism = ReconciliationService.reconcileWallets(drifted, txs);
      expect(mism.length, 1);
      expect(mism.single.expected, 750000);
      expect(mism.single.actual, 725000);
      expect(mism.single.difference, -25000);
    });
  });

  group('provider: adjustment beraudit + repair', () {
    test('adjust naik/turun: saldo + tx adjustment + reconcile ok', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 1',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          1000000,
        ),
        isTrue,
      );
      final id = fp.wallets.single.id;

      expect(
        await fp.adjustWalletBalance(id, 1025000, reason: 'Rekonsiliasi'),
        isTrue,
      );
      expect(fp.wallets.single.balance, 1025000);
      final adjs = fp.transactions
          .where((t) => t.type == TransactionType.adjustment)
          .toList();
      expect(adjs.length, 1);
      expect(adjs.single.tag, BalanceAdjustment.tag);
      expect(adjs.single.note, 'Rekonsiliasi');
      expect(adjs.single.toWalletId, id);

      expect(await fp.adjustWalletBalance(id, 1000000), isTrue);
      expect(fp.wallets.single.balance, 1000000);
      expect((await fp.reconcileAll()).ok, isTrue);
    });

    test(
      'updateWallet(balance:) menempuh adjustment, bukan tulis langsung',
      () async {
        final fp = await freshProvider();
        expect(
          await fp.addWallet(
            'BCA',
            '• 1',
            Icons.account_balance,
            const Color(0xFF1A4D8F),
            500000,
          ),
          isTrue,
        );
        final id = fp.wallets.single.id;
        final txCount = fp.transactions.length;
        expect(await fp.updateWallet(id, balance: 530000), isTrue);
        expect(fp.wallets.single.balance, 530000);
        expect(fp.transactions.length, txCount + 1);
        expect(fp.transactions.last.type, TransactionType.adjustment);
        expect((await fp.reconcileAll()).ok, isTrue);
      },
    );

    test(
      'divergensi level DB terdeteksi + repair tanpa sentuh ledger',
      () async {
        final fp = await freshProvider();
        expect(
          await fp.addWallet(
            'BCA',
            '• 1',
            Icons.account_balance,
            const Color(0xFF1A4D8F),
            1000000,
          ),
          isTrue,
        );
        expect(
          await fp.addTransaction(
            title: 'Gaji',
            category: 'Income',
            account: 'BCA',
            amount: 500000,
            type: TransactionType.income,
            icon: Icons.payments,
          ),
          isTrue,
        );
        expect(fp.wallets.single.balance, 1500000);
        final txCount = fp.transactions.length;

        // Simulasi partial write/korupsi: timpa balance langsung di DB.
        final row = Map<String, Object?>.from(fp.wallets.single.toJson());
        row['balance'] = 1400000.0;
        await SecureDbService.upsertRow(SecureDbTables.wallets, row);
        await fp.reloadFromPrefs();

        final report = await fp.reconcileAll();
        expect(report.ok, isFalse);
        final m = report.mismatches.singleWhere(
          (e) => e.entityType == 'wallet',
        );
        expect(m.expected, 1500000);
        expect(m.actual, 1400000);
        expect(m.difference, -100000);

        final repaired = await fp.repairProjections();
        expect(repaired, 1);
        expect(fp.wallets.single.balance, 1500000);
        // Ledger utuh: jumlah transaksi tidak berubah.
        expect(fp.transactions.length, txCount);
        expect((await fp.reconcileAll()).ok, isTrue);
      },
    );
  });
}
