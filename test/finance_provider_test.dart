import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FinanceProvider memanggil _loadFromPrefs async di konstruktor.
/// Tunggu hingga load selesai sebelum assert.
Future<FinanceProvider> freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  // Isolasi antar-test: backend memori fresh + migrasi prefs mock.
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

void main() {
  group('Transaksi & saldo', () {
    test('income/expense memengaruhi total & balance', () async {
      final fp = await freshProvider();
      expect(
        await fp.addTransaction(
          title: 'Gaji',
          category: 'Income',
          account: 'BCA',
          amount: 5000000,
          type: TransactionType.income,
          icon: Icons.payments,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Kopi',
          category: 'Food & Drinks',
          account: 'BCA',
          amount: 20000,
          type: TransactionType.expense,
          icon: Icons.coffee,
        ),
        isTrue,
      );
      expect(fp.totalIncome, 5000000);
      expect(fp.totalExpense, 20000);
      expect(fp.balance, 4980000);
      expect(fp.transactions.first.title, 'Kopi'); // terbaru dulu
    });

    test('validasi: tolak amount<=0 & title kosong', () async {
      final fp = await freshProvider();
      expect(
        await fp.addTransaction(
          title: '',
          category: 'Other',
          account: 'Dompet',
          amount: 1000,
          type: TransactionType.expense,
          icon: Icons.more_horiz,
        ),
        isFalse,
      );
      expect(
        await fp.addTransaction(
          title: 'Nol',
          category: 'Other',
          account: 'Dompet',
          amount: 0,
          type: TransactionType.expense,
          icon: Icons.more_horiz,
        ),
        isFalse,
      );
      expect(
        await fp.addTransaction(
          title: 'Negatif',
          category: 'Other',
          account: 'Dompet',
          amount: -500,
          type: TransactionType.expense,
          icon: Icons.more_horiz,
        ),
        isFalse,
      );
      expect(fp.transactions, isEmpty);
    });

    test('transfer memindah saldo antar wallet', () async {
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
        await fp.addWallet(
          'Dompet',
          '• 2',
          Icons.wallet,
          const Color(0xFF2E7D32),
          0,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Tarik tunai',
          category: 'Transfer',
          account: 'BCA',
          amount: 200000,
          type: TransactionType.transfer,
          icon: Icons.swap_horiz,
          targetAccount: 'Dompet',
        ),
        isTrue,
      );
      final bca = fp.wallets.firstWhere((w) => w.name == 'BCA');
      final dompet = fp.wallets.firstWhere((w) => w.name == 'Dompet');
      expect(bca.balance, 800000);
      expect(dompet.balance, 200000);
    });

    test('transfer tanpa target / ke diri sendiri ditolak', () async {
      final fp = await freshProvider();
      expect(
        await fp.addTransaction(
          title: 'T',
          category: 'Transfer',
          account: 'BCA',
          amount: 1000,
          type: TransactionType.transfer,
          icon: Icons.swap_horiz,
        ),
        isFalse,
      );
      expect(
        await fp.addTransaction(
          title: 'T',
          category: 'Transfer',
          account: 'BCA',
          amount: 1000,
          type: TransactionType.transfer,
          icon: Icons.swap_horiz,
          targetAccount: 'BCA',
        ),
        isFalse,
      );
    });

    test('delete mengembalikan delta wallet & budget', () async {
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
      expect(await fp.addBudgetCategory(name: 'Makan', limit: 500000), isTrue);
      expect(
        await fp.addTransaction(
          title: 'Nasi',
          category: 'Makan',
          account: 'BCA',
          amount: 50000,
          type: TransactionType.expense,
          icon: Icons.restaurant,
        ),
        isTrue,
      );
      expect(fp.wallets.single.balance, 950000);
      expect(fp.budgets.single.spent, 50000);

      final id = fp.transactions.single.id;
      expect(await fp.deleteTransaction(id), isTrue);
      expect(fp.wallets.single.balance, 1000000);
      expect(fp.budgets.single.spent, 0);
      expect(await fp.deleteTransaction('tidak-ada'), isFalse);
    });

    test('update menolak id tak dikenal & amount invalid', () async {
      final fp = await freshProvider();
      expect(await fp.updateTransaction('nope', title: 'X'), isFalse);
      expect(
        await fp.addTransaction(
          title: 'A',
          category: 'Other',
          account: 'Dompet',
          amount: 10000,
          type: TransactionType.expense,
          icon: Icons.more_horiz,
        ),
        isTrue,
      );
      final id = fp.transactions.single.id;
      expect(await fp.updateTransaction(id, amount: -5), isFalse);
      expect(await fp.updateTransaction(id, title: '  '), isFalse);
      expect(await fp.updateTransaction(id, amount: 4000), isTrue);
      expect(fp.totalExpense, 4000);
    });
  });

  group('Budget & kategori', () {
    test('budget spent + recalc', () async {
      final fp = await freshProvider();
      expect(await fp.addBudgetCategory(name: 'Makan', limit: 200000), isTrue);
      expect(
        await fp.addTransaction(
          title: 'Bakso',
          category: 'Makan',
          account: 'Dompet',
          amount: 30000,
          type: TransactionType.expense,
          icon: Icons.restaurant,
          date: DateTime(2026, 9, 5),
        ),
        isTrue,
      );
      expect(fp.spentForBudget('Makan', month: DateTime(2026, 9)), 30000);
      expect(fp.spentForBudget('Makan', month: DateTime(2026, 8)), 0);
      await fp.recalcBudgetsForMonth(DateTime(2026, 9));
      expect(fp.budgets.single.spent, 30000);
    });

    test('budget duplikat/kosong/limit<=0 ditolak', () async {
      final fp = await freshProvider();
      expect(await fp.addBudgetCategory(name: 'Makan', limit: 100000), isTrue);
      expect(await fp.addBudgetCategory(name: 'makan', limit: 50000), isFalse);
      expect(await fp.addBudgetCategory(name: '  ', limit: 50000), isFalse);
      expect(await fp.addBudgetCategory(name: 'Jajan', limit: 0), isFalse);
      expect(fp.budgets.length, 1);
    });

    test('kategori custom duplikat ditolak', () async {
      final fp = await freshProvider();
      expect(await fp.addCustomCategory('Jajan', Icons.fastfood), isTrue);
      expect(await fp.addCustomCategory('jajan', Icons.fastfood), isFalse);
      expect(await fp.addCustomCategory('  ', Icons.fastfood), isFalse);
    });

    test('wallet duplikat/negatif ditolak', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 1',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          100,
        ),
        isTrue,
      );
      expect(
        await fp.addWallet(
          'bca',
          '• 2',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          100,
        ),
        isFalse,
      );
      expect(
        await fp.addWallet(
          'X',
          '• 3',
          Icons.wallet,
          const Color(0xFF1A4D8F),
          -1,
        ),
        isFalse,
      );
    });
  });

  group('Filter & export & ringkasan', () {
    Future<FinanceProvider> seeded() async {
      final fp = await freshProvider();
      await fp.addTransaction(
        title: 'Gaji Sept',
        category: 'Income',
        account: 'BCA',
        amount: 5000000,
        type: TransactionType.income,
        icon: Icons.payments,
        date: DateTime(2026, 9, 2),
      );
      await fp.addTransaction(
        title: 'Kopi, "spesial"',
        category: 'Food & Drinks',
        account: 'BCA',
        amount: 25000,
        type: TransactionType.expense,
        icon: Icons.coffee,
        date: DateTime(2026, 9, 3),
        note: 'catatan, koma',
      );
      await fp.addTransaction(
        title: 'Bensin',
        category: 'Transport',
        account: 'Dompet',
        amount: 100000,
        type: TransactionType.expense,
        icon: Icons.directions_car,
        date: DateTime(2026, 8, 20),
      );
      return fp;
    }

    test('filter query/type/category/month', () async {
      final fp = await seeded();
      expect(fp.filter(query: 'kopi').length, 1);
      expect(fp.filter(type: TransactionType.income).length, 1);
      expect(fp.filter(category: 'Transport').length, 1);
      expect(fp.filter(month: DateTime(2026, 9)).length, 2);
      expect(fp.filter(month: DateTime(2026, 8)).length, 1);
      expect(fp.filter(query: 'tidak ketemu'), isEmpty);
    });

    test('exportCsv escape koma & kutip', () async {
      final fp = await seeded();
      final csv = fp.exportCsv();
      expect(
        csv.startsWith('id,title,category,account,amount,type,date,tag,note'),
        isTrue,
      );
      expect(csv.contains('"Kopi, ""spesial"""'), isTrue);
      expect(csv.contains('"catatan, koma"'), isTrue);
    });

    test('monthlySummary benar & abaikan transfer', () async {
      final fp = await seeded();
      await fp.addWallet(
        'BCA',
        '• 1',
        Icons.account_balance,
        const Color(0xFF1A4D8F),
        9000000,
      );
      await fp.addWallet(
        'Dompet',
        '• 2',
        Icons.wallet,
        const Color(0xFF2E7D32),
        0,
      );
      await fp.addTransaction(
        title: 'Pindah',
        category: 'Transfer',
        account: 'BCA',
        amount: 500000,
        type: TransactionType.transfer,
        icon: Icons.swap_horiz,
        targetAccount: 'Dompet',
        date: DateTime(2026, 9, 4),
      );
      final s = fp.monthlySummary(month: DateTime(2026, 9));
      expect(s.income, 5000000);
      expect(s.expense, 25000);
      expect(s.net, 4975000);
      expect(s.transactionCount, 3);
      expect(s.topExpenseCategory, 'Food & Drinks');
    });
  });

  group('Overdraft guard & delta presisi (F7)', () {
    test('expense melebihi saldo ditolak, saldo utuh', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 1',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          100000,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Belanja besar',
          category: 'Other',
          account: 'BCA',
          amount: 150000,
          type: TransactionType.expense,
          icon: Icons.shopping_cart,
        ),
        isFalse,
      );
      expect(fp.transactions, isEmpty);
      expect(fp.wallets.single.balance, 100000);
    });

    test('expense tepat sebesar saldo lolos, saldo nol', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'Dompet',
          '• 2',
          Icons.wallet,
          const Color(0xFF2E7D32),
          50000,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Habiskan',
          category: 'Other',
          account: 'Dompet',
          amount: 50000,
          type: TransactionType.expense,
          icon: Icons.money_off,
        ),
        isTrue,
      );
      expect(fp.wallets.single.balance, 0);
    });

    test('transfer melebihi saldo sumber ditolak, kedua sisi utuh', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 1',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          100000,
        ),
        isTrue,
      );
      expect(
        await fp.addWallet(
          'Dompet',
          '• 2',
          Icons.wallet,
          const Color(0xFF2E7D32),
          0,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Tarik berlebih',
          category: 'Transfer',
          account: 'BCA',
          amount: 250000,
          type: TransactionType.transfer,
          icon: Icons.swap_horiz,
          targetAccount: 'Dompet',
        ),
        isFalse,
      );
      expect(fp.transactions, isEmpty);
      expect(fp.wallets.firstWhere((w) => w.name == 'BCA').balance, 100000);
      expect(fp.wallets.firstWhere((w) => w.name == 'Dompet').balance, 0);
    });

    test(
      'dompet tak dikenal: lolos no-op tanpa crash (perilaku lama)',
      () async {
        final fp = await freshProvider();
        expect(
          await fp.addTransaction(
            title: 'Kas manual',
            category: 'Other',
            account: 'DompetHantu',
            amount: 10000,
            type: TransactionType.expense,
            icon: Icons.more_horiz,
          ),
          isTrue,
        );
        expect(fp.transactions.single.account, 'DompetHantu');
        expect(fp.wallets, isEmpty);
      },
    );
  });
}
