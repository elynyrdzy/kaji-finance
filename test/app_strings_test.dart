import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/l10n/app_strings.dart';

/// §58: setiap kunci wajib ada di id DAN en (tanpa sisa bahasa Inggris
/// nyasar di UI Indonesia dan sebaliknya).
const _requiredKeys = [
  // Navigasi
  'home', 'transactions', 'budget', 'analytics', 'settings',
  // Home
  'greetingMorning', 'totalBalance', 'income', 'expenses', 'net',
  'cashFlowTrend', 'performanceOverview', 'recentTransactions', 'viewAll',
  'noTransactions', 'addTransaction',
  // Transaksi
  'searchHint', 'incomeLabel', 'expenseLabel', 'transferLabel', 'today',
  'yesterday', 'txSaved', 'txUpdated', 'txDeleted', 'txUndone', 'undo',
  'insufficientBalance', 'validationAmount', 'validationWallet',
  // Anggaran
  'monthlyAllowance', 'budgetSpent', 'budgetRemaining', 'onTrack',
  'approachingLimit', 'limitReached', 'daysLeft', 'recalculate',
  'noBudgets', 'categoryBudgets',
  // Analitik
  'financialPulse', 'totalDisbursed', 'dailyAverage', 'savingsRatio',
  'expenseBreakdown', 'cashFlow', 'habits', 'projections',
  'noAnalyticsData', 'ofSpend', 'topExpense',
  // Tabungan
  'savings', 'savingsGoals', 'totalSaved', 'deposit', 'withdraw',
  'depositSuccess', 'withdrawSuccess', 'depositFailed', 'walletRequired',
  'noSavings', 'goalCreated', 'savingsDepositTx', 'savingsWithdrawTx',
  // Pengaturan
  'language', 'currency', 'security', 'biometricLock', 'enabled',
  'disabled', 'bioNotAvailable', 'experimental', 'experimentalDesc',
  'featureLab', 'exportBackup', 'importBackup', 'exportCsv', 'resetData',
  'about', 'privacy',
  // Umum
  'save', 'cancel', 'delete', 'edit', 'close', 'saveFailed',
  'dataUpdateFailed', 'genericError',
  // Lock
  'appLocked', 'lockSubtitle', 'unlock', 'unlockWithBio', 'pinWrong',
  'pinLockedOut',
];

void main() {
  group('AppStrings cakupan id+en', () {
    test('semua kunci wajib ada di kedua bahasa', () {
      for (final k in _requiredKeys) {
        expect(
          AppStrings.get(k, 'id'),
          isNot(k),
          reason: 'kunci "$k" hilang di id',
        );
        expect(
          AppStrings.get(k, 'en'),
          isNot(k),
          reason: 'kunci "$k" hilang di en',
        );
      }
    });

    test('contoh mutu terjemahan id (§11)', () {
      expect(AppStrings.get('totalBalance', 'id'), 'TOTAL SALDO');
      expect(AppStrings.get('income', 'id'), 'PEMASUKAN');
      expect(AppStrings.get('budget', 'id'), 'Anggaran');
      expect(AppStrings.get('savings', 'id'), 'Tabungan');
      expect(AppStrings.get('dailyAverage', 'id'), 'Rata-rata Harian');
      expect(AppStrings.get('expenseBreakdown', 'id'), 'Rincian Pengeluaran');
      expect(AppStrings.get('approachingLimit', 'id'), 'Mendekati Batas');
      expect(AppStrings.get('limitReached', 'id'), 'Batas Tercapai');
      expect(AppStrings.get('onTrack', 'id'), 'Sesuai Target');
    });

    test('fill() interpolasi {arg}', () {
      expect(AppStrings.fill('txCount', 'id', {'n': 5}), '5 transaksi');
      expect(AppStrings.fill('pinWrong', 'en', {'n': 3}), contains('3'));
      expect(AppStrings.fill('budgetAlertMsg', 'id', {'n': 2}), contains('2'));
    });

    test('kunci tak dikenal mengembalikan key (tidak crash)', () {
      expect(
        AppStrings.get('tidak_ada_kunci_ini', 'id'),
        'tidak_ada_kunci_ini',
      );
    });

    test('parity PENUH: semua kunci ada + non-empty di id dan en', () {
      final keys = AppStrings.allKeys;
      expect(keys, isNotEmpty);
      for (final k in keys) {
        expect(
          AppStrings.get(k, 'id'),
          isNot(k),
          reason: 'kunci "$k" hilang di id',
        );
        expect(
          AppStrings.get(k, 'en'),
          isNot(k),
          reason: 'kunci "$k" hilang di en',
        );
        expect(
          AppStrings.get(k, 'id'),
          isNotEmpty,
          reason: 'kunci "$k" kosong di id',
        );
        expect(
          AppStrings.get(k, 'en'),
          isNotEmpty,
          reason: 'kunci "$k" kosong di en',
        );
      }
    });
  });
}
