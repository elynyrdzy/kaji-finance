import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/app_settings_provider.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:provider/provider.dart';
import 'package:kaji_finance/screens/add_transaction_screen.dart';
import 'package:kaji_finance/screens/budget_screen.dart';
import 'package:kaji_finance/screens/home_screen.dart';
import 'package:kaji_finance/screens/onboarding_screen.dart';
import 'package:kaji_finance/screens/settings_screen.dart';
import 'package:kaji_finance/widgets/bottom_nav_bar.dart';
import 'package:kaji_finance/widgets/transaction_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget test terisolasi: tiap layar dipump dengan provider-nya sendiri
/// (bukan full KajiFinanceApp) agar tidak tergantung pada
/// NotificationService, LockScreen, maupun IndexedStack 5 tab sekaligus.
Future<FinanceProvider> _freshFinance() async {
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  // Pastikan load async dari prefs selesai sebelum dipakai.
  return fp;
}

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen, {
  FinanceProvider? finance,
  AppSettingsProvider? settings,
}) async {
  final fp = finance ?? await _freshFinance();
  final st = settings ?? AppSettingsProvider();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<FinanceProvider>.value(value: fp),
        ChangeNotifierProvider<AppSettingsProvider>.value(value: st),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('id');
    await initializeDateFormatting('en');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Isolasi antar-test: backend memori fresh (tanpa platform channel).
    await SecureDbService.useInMemory();
  });

  group('OnboardingScreen', () {
    testWidgets('langkah awal tampil + tombol Lanjut/Lewati ada', (
      tester,
    ) async {
      await _pumpScreen(tester, const OnboardingScreen());

      expect(find.text('KAJI FINANCE'), findsOneWidget);
      expect(find.textContaining('Selamat datang'), findsOneWidget);
      expect(find.text('Lanjut'), findsOneWidget);
      expect(find.text('Lewati'), findsOneWidget);
    });

    testWidgets('Lanjut pindah ke langkah nama + Kembali berfungsi', (
      tester,
    ) async {
      await _pumpScreen(tester, const OnboardingScreen());

      await tester.tap(find.text('Lanjut'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Siapa namamu?'), findsOneWidget);
      expect(find.text('NAMA AKUN'), findsOneWidget);

      await tester.tap(find.text('Lanjut'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Wallet pertama'), findsOneWidget);

      await tester.tap(find.text('Kembali'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Siapa namamu?'), findsOneWidget);
    });

    testWidgets('Lewati menyelesaikan onboarding di provider', (tester) async {
      final fp = await _freshFinance();
      await _pumpScreen(tester, const OnboardingScreen(), finance: fp);
      expect(fp.onboardingDone, isFalse);

      await tester.tap(find.text('Lewati'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(fp.onboardingDone, isTrue);
      expect(fp.wallets, isNotEmpty);
    });
  });

  group('TransactionTile', () {
    testWidgets('expense tampil "-" + judul + kategori', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TransactionTile(tx: _kExpenseTx)),
        ),
      );
      await tester.pump();

      expect(find.text('Kopi Susu'), findsOneWidget);
      expect(find.textContaining('Food & Drinks'), findsOneWidget);
      expect(find.textContaining('- Rp'), findsOneWidget);
    });

    testWidgets('income tampil "+" dan bukan Dismissible tanpa onDelete', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TransactionTile(tx: _kIncomeTx)),
        ),
      );
      await tester.pump();

      expect(find.text('Gaji Sept'), findsOneWidget);
      expect(find.textContaining('+ Rp'), findsOneWidget);
      expect(find.byType(Dismissible), findsNothing);
    });

    testWidgets('dengan onDelete menjadi Dismissible + callback jalan', (
      tester,
    ) async {
      var deleted = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionTile(
              tx: _kExpenseTx,
              onDelete: () => deleted = true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Dismissible), findsOneWidget);

      // Geser kiri untuk dismiss.
      await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(deleted, isTrue);
    });
  });

  group('HomeScreen', () {
    testWidgets('empty state: wallet kosong + CTA transaksi', (tester) async {
      final fp = await _freshFinance();
      await _pumpScreen(tester, const HomeScreen(), finance: fp);

      expect(find.text('Belum ada wallet'), findsOneWidget);
      expect(find.text('Belum ada transaksi'), findsOneWidget);
      expect(find.text('Transaksi Pertama'), findsOneWidget);
      expect(find.text('Tambah Transaksi'), findsOneWidget);
    });

    testWidgets('tap Transaksi Pertama buka AddTransactionScreen', (
      tester,
    ) async {
      final fp = await _freshFinance();
      await _pumpScreen(tester, const HomeScreen(), finance: fp);

      await tester.tap(find.text('Transaksi Pertama'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AddTransactionScreen), findsOneWidget);
    });

    testWidgets('transaksi terbaru tampil di daftar recent', (tester) async {
      final fp = await _freshFinance();
      await fp.addTransaction(
        title: 'Nasi Padang',
        category: 'Food & Drinks',
        account: 'Dompet',
        amount: 35000,
        type: TransactionType.expense,
        icon: Icons.restaurant,
      );
      await _pumpScreen(tester, const HomeScreen(), finance: fp);

      expect(find.text('Nasi Padang'), findsOneWidget);
      expect(find.byType(TransactionTile), findsOneWidget);
    });
  });

  group('BudgetScreen', () {
    testWidgets('empty state ajak buat budget pertama', (tester) async {
      final fp = await _freshFinance();
      await _pumpScreen(tester, const BudgetScreen(), finance: fp);

      expect(find.text('Belum ada budget'), findsOneWidget);
      expect(find.text('Buat Budget Pertama'), findsOneWidget);
    });

    testWidgets('budget dari provider tampil dengan limit', (tester) async {
      final fp = await _freshFinance();
      expect(await fp.addBudgetCategory(name: 'Makan', limit: 500000), isTrue);
      await _pumpScreen(tester, const BudgetScreen(), finance: fp);

      expect(find.text('Makan'), findsOneWidget);
      expect(find.textContaining('500.000'), findsOneWidget);
    });
  });

  group('SettingsScreen', () {
    testWidgets('render semua seksi tanpa framework exception', (tester) async {
      final fp = await _freshFinance();
      await _pumpScreen(tester, const SettingsScreen(), finance: fp);

      expect(find.text('TAMPILAN'), findsOneWidget);
      expect(find.text('KEAMANAN'), findsOneWidget);
      expect(find.text('BACKUP & RESTORE'), findsOneWidget);
      expect(find.byType(ListTile), findsWidgets);
    });
  });

  group('BottomNavBar', () {
    testWidgets('tap item memanggil onTap dengan index benar', (tester) async {
      int? tapped;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSettingsProvider()),
          ],
          child: MaterialApp(
            home: Scaffold(
              bottomNavigationBar: BottomNavBar(
                currentIndex: 0,
                onTap: (i) => tapped = i,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Budget'), findsOneWidget);

      await tester.tap(find.text('Budget'));
      await tester.pump();
      expect(tapped, 2);
    });
  });
}

final _kExpenseTx = TransactionModel(
  id: 't1',
  title: 'Kopi Susu',
  category: 'Food & Drinks',
  account: 'Dompet',
  amount: 25000,
  type: TransactionType.expense,
  date: DateTime(2026, 9, 6, 10, 30),
  icon: Icons.coffee,
);

final _kIncomeTx = TransactionModel(
  id: 't2',
  title: 'Gaji Sept',
  category: 'Income',
  account: 'BCA',
  amount: 5000000,
  type: TransactionType.income,
  date: DateTime(2026, 9, 6, 9, 0),
  icon: Icons.payments,
);
