import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/budget_model.dart';
import 'package:kaji_finance/models/category_model.dart';
import 'package:kaji_finance/models/monthly_summary.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/models/wallet_model.dart';

void main() {
  group('TransactionModel', () {
    test('signedAmount negatif untuk expense', () {
      final tx = TransactionModel(
        id: '1',
        title: 'Kopi',
        category: 'Food & Drinks',
        account: 'Dompet',
        amount: 20000,
        type: TransactionType.expense,
        date: DateTime(2026, 9, 6),
        icon: Icons.coffee,
      );
      expect(tx.signedAmount, -20000);
    });

    test('JSON round-trip', () {
      final tx = TransactionModel(
        id: 'abc',
        title: 'Gaji, "bulanan"',
        category: 'Income',
        account: 'BCA',
        amount: 5000000,
        type: TransactionType.income,
        date: DateTime(2026, 9, 1, 10, 30),
        icon: Icons.payments,
        tag: 'Payroll',
        note: 'catatan, penting',
      );
      final back = TransactionModel.fromJson(tx.toJson());
      expect(back.id, 'abc');
      expect(back.title, 'Gaji, "bulanan"');
      expect(back.amount, 5000000);
      expect(back.type, TransactionType.income);
      expect(back.tag, 'Payroll');
      expect(back.note, 'catatan, penting');
      expect(back.date, DateTime(2026, 9, 1, 10, 30));
    });

    test('copyWith mempertahankan id', () {
      final tx = TransactionModel(
        id: 'x',
        title: 'A',
        category: 'Other',
        account: 'Dompet',
        amount: 1000,
        type: TransactionType.expense,
        date: DateTime(2026, 9, 6),
        icon: Icons.more_horiz,
      );
      final c = tx.copyWith(amount: 2000);
      expect(c.id, 'x');
      expect(c.amount, 2000);
      expect(c.title, 'A');
    });
  });

  group('BudgetCategory', () {
    test('percent/remaining/status', () {
      const b = BudgetCategory(
        id: 'b1',
        name: 'Makan',
        icon: Icons.restaurant,
        spent: 80000,
        limit: 100000,
      );
      expect(b.percent, 0.8);
      expect(b.remaining, 20000);
      expect(b.status, BudgetStatus.approaching);

      const over = BudgetCategory(
        id: 'b2',
        name: 'X',
        icon: Icons.more_horiz,
        spent: 120000,
        limit: 100000,
      );
      expect(over.status, BudgetStatus.limitReached);
      expect(over.remaining, 0);

      const zero = BudgetCategory(
        id: 'b3',
        name: 'Y',
        icon: Icons.more_horiz,
        spent: 0,
        limit: 0,
      );
      expect(zero.percent, 0);
      expect(zero.status, BudgetStatus.onTrack);
    });

    test('JSON round-trip', () {
      const b = BudgetCategory(
        id: 'b1',
        name: 'Makan',
        icon: Icons.restaurant,
        spent: 1000,
        limit: 5000,
      );
      final back = BudgetCategory.fromJson(b.toJson());
      expect(back.name, 'Makan');
      expect(back.spent, 1000);
      expect(back.limit, 5000);
    });
  });

  group('WalletModel & CategoryModel', () {
    test('Wallet JSON round-trip', () {
      const w = WalletModel(
        id: 'w1',
        name: 'BCA',
        number: '• 8920',
        icon: Icons.account_balance,
        balance: 1500000,
        color: Color(0xFF1A4D8F),
      );
      final back = WalletModel.fromJson(w.toJson());
      expect(back.name, 'BCA');
      expect(back.balance, 1500000);
      expect(back.color, const Color(0xFF1A4D8F));
      expect(back.copyWith(balance: 0).balance, 0);
    });

    test('Wallet initialBalance round-trip + fallback lama', () {
      const w = WalletModel(
        id: 'w1',
        name: 'BCA',
        number: '• 8920',
        icon: Icons.account_balance,
        balance: 750000,
        initialBalance: 1000000,
        color: Color(0xFF1A4D8F),
      );
      final back = WalletModel.fromJson(w.toJson());
      expect(back.initialBalance, 1000000);
      expect(back.balance, 750000);
      // Baris lama tanpa kunci initial_* → fallback = balance.
      final legacy = WalletModel.fromJson({
        'id': 'w9',
        'name': 'Lama',
        'number': '• 0',
        'icon': Icons.wallet.codePoint,
        'balance': 300000,
        'color': 0xFF1A4D8F,
      });
      expect(legacy.initialBalance, 300000);
    });

    test('Category JSON round-trip', () {
      const c = CategoryModel(id: 'c1', name: 'Jajan', icon: Icons.fastfood);
      final back = CategoryModel.fromJson(c.toJson());
      expect(back.name, 'Jajan');
    });
  });

  group('MonthlySummary', () {
    test('net & savingsRate', () {
      const s = MonthlySummary(
        year: 2026,
        month: 9,
        income: 1000000,
        expense: 400000,
        transactionCount: 5,
      );
      expect(s.net, 600000);
      expect(s.savingsRate, 0.6);

      const empty = MonthlySummary(
        year: 2026,
        month: 9,
        income: 0,
        expense: 0,
        transactionCount: 0,
      );
      expect(empty.savingsRate, 0);
    });
  });
}
