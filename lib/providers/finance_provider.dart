library finance_provider;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/debt_entry.dart';
import '../models/monthly_summary.dart';
import '../models/recurring_bill.dart';
import '../models/savings_goal_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../services/auth_service.dart';
import '../services/app_log.dart';
import '../services/audit_service.dart';
import '../services/reconciliation_service.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/secure_db_service.dart';
import '../l10n/app_strings.dart';
import '../utils/money_format.dart';

part 'finance/finance_wallets.dart';
part 'finance/finance_transactions.dart';
part 'finance/finance_import.dart';
part 'finance/finance_digest.dart';
part 'finance/finance_budgets.dart';
part 'finance/finance_savings.dart';
part 'finance/finance_reconciliation.dart';
part 'finance/finance_persistence.dart';
part 'finance/finance_recurring.dart';
part 'finance/finance_debts.dart';

/// State terpusat Kaji Finance (ChangeNotifier + SharedPreferences).
///
/// P2-a: logika domain dipecah ke extension per berkas di `finance/` —
/// BERKAS INI hanya menyimpan state + getter baca. Semua method adalah
/// code motion verbatim dari monolit 1580-baris; tidak ada perubahan perilaku.
///
/// - [FinanceWallets]: CRUD dompet + delta saldo ID-ready.
/// - [FinanceTransactions]: CRUD transaksi + query + agregat + CSV.
/// - [FinanceImport]: impor transaksi dari staging JSON memori ke SQL.
/// - [FinanceBudgets]: CRUD anggaran + hitung spent + alert notifikasi.
/// - [FinanceSavings]: goal + operasi atomik + delta goal.
/// - [FinancePersistence]: prefs keys + save/load + onboarding + reset.
///
/// Dipakai extension (bukan mixin): extension `on FinanceProvider` dalam
/// satu library boleh mengakses member privat, sedangkan body mixin hanya
/// melihat interface-nya sendiri + `on`-clause.
class FinanceProvider extends ChangeNotifier {
  FinanceProvider() {
    _loadFromPrefs();
  }

  final _uuid = const Uuid();

  String accountName = 'Kaji Finance';
  int monthlyAllowance = 0;
  bool balanceVisible = true;
  bool onboardingDone = false;

  /// True setelah pemuatan awal SharedPreferences selesai — dipakai UI
  /// agar tidak menampilkan onboarding sekilas sebelum data dibaca.
  bool prefsLoaded = false;

  /// Database terenkripsi gagal DIBUKA saat cold start.
  ///
  /// Ini BUKAN "akun baru": membedakannya penting karena dua konsekuensi
  /// yang merusak. (1) Salah dianggap akun baru → onboarding menumpuk di
  /// atas data yang belum terbaca dan user mengira datanya hilang. (2) Yang
  /// lebih buruk, `flushAll()` adalah full-state write — kalau state kosong
  /// ikut tersimpan, seluruh DB tertimpa. Karena itu [prefsLoaded] sengaja
  /// dibiarkan false saat flag ini menyala.
  ///
  /// Ditampilkan ke user sebagai pesan kesalahan, bukan disembunyikan di log
  /// debug: tanpa ini kegagalan paling menyakitkan di aplikasi ini diam.
  bool dbLoadFailed = false;

  final List<WalletModel> _wallets = [];
  List<WalletModel> get wallets => List.unmodifiable(_wallets);

  final List<SavingsGoalModel> _goals = [];
  List<SavingsGoalModel> get savingsGoals => List.unmodifiable(_goals);

  final List<TransactionModel> _transactions = [];
  final List<BudgetCategory> _budgets = [];
  final List<CategoryModel> _customCategories = [];
  List<CategoryModel> get customCategories =>
      List.unmodifiable(_customCategories);

  /// Tagihan rutin (state milik FinanceRecurring; extension tak boleh
  /// deklarasi field — lihat pola _budgetAlertNotified).
  final List<RecurringBill> _recurringBills = [];
  List<RecurringBill> get recurringBills => List.unmodifiable(_recurringBills);

  List<TransactionModel>? _sortedTxCache;
  void _invalidateTxCache() => _sortedTxCache = null;

  /// Penerus notifyListeners untuk extension satu library — panggil
  /// [_notify] dari part file agar tidak melanggar @protected.
  void _notify() => notifyListeners();

  List<TransactionModel> get transactions {
    _sortedTxCache ??= (() {
      final copy = List<TransactionModel>.from(_transactions);
      copy.sort((a, b) => b.date.compareTo(a.date));
      return copy;
    })();
    return List.unmodifiable(_sortedTxCache!);
  }

  List<BudgetCategory> get budgets => List.unmodifiable(_budgets);

  bool get isEmpty =>
      _transactions.isEmpty &&
      _budgets.isEmpty &&
      _wallets.isEmpty &&
      !onboardingDone;

  /// Awal periode untuk [period]: dukung kode chart ('7D','1M','3M','1Y')
  /// dan kode analitik ('week','month','quarter','year').
  /// Statik murni di kelas induk (bukan extension): dipakai via
  /// `FinanceProvider.periodStartFor` dari luar (mis. Analytics).
  static DateTime periodStartFor(String period, DateTime now) {
    switch (period) {
      case 'week':
      case '7D':
        return now.subtract(const Duration(days: 7));
      case 'quarter':
      case '3M':
        return now.subtract(const Duration(days: 90));
      case 'year':
      case '1Y':
        return DateTime(now.year, 1, 1);
      case '1M':
        return now.subtract(const Duration(days: 30));
      case 'month':
      default:
        return DateTime(now.year, now.month, 1);
    }
  }

  /// State in-memory milik extension (tetap di kelas induk karena
  /// extension tidak boleh mendeklarasikan instance field).
  /// Persen terakhir yang sudah dinotifikasikan per budget id —
  /// cegah spam alert (lihat FinanceBudgets._checkBudgetAlerts).
  final Map<String, double> _budgetAlertNotified = {};

  /// Kunci idempotency operasi tabungan — cegah double-tap (§37).
  /// Dibatasi 200 terakhir agar sesi panjang tak membengkak (audit).
  final Set<String> _savingsOpKeys = {};

  /// State in-memory milik FinanceDebts (lihat pola _budgetAlertNotified):
  /// mini-ledger hutang/piutang/kasbon/arisan. Persist di store ter-scope
  /// (PrefsDebtStore), ledger pembayaran reuse tabel transaksi via tag
  /// debt_* + note prefix — tanpa kolom/schema DB baru.
  final List<DebtEntry> _debts = [];
  List<DebtEntry> get debts => List.unmodifiable(_debts);

  /// Master switch alert anggaran seketika (50/80/100%) — disinkron
  /// dari AppSettingsProvider oleh penjadwal digest (default aktif).
  bool budgetAlertsOn = true;

  /// Daftarkan kunci idempotency dengan batas ukuran.
  void _rememberSavingsOpKey(String key) {
    if (_savingsOpKeys.length >= 200) {
      _savingsOpKeys.remove(_savingsOpKeys.first);
    }
    _savingsOpKeys.add(key);
  }
}
