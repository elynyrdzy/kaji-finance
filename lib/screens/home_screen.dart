import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/app_header.dart';
import '../widgets/app_keypad.dart';
import '../widgets/line_chart_painter.dart';
import '../widgets/motion_kit.dart';
import '../widgets/transaction_tile.dart';
import '../widgets/wallet_dialogs.dart';
import 'add_transaction_screen.dart';

class HomeScreen extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  const HomeScreen({super.key, this.onNavigate});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _range = '1M';
  int? _highlight;

  String _greeting(String lang) {
    final h = DateTime.now().hour;
    if (h < 11) return AppStrings.get('greetingMorning', lang);
    if (h < 15) return AppStrings.get('greetingAfternoon', lang);
    if (h < 19) return AppStrings.get('greetingEvening', lang);
    return AppStrings.get('greetingNight', lang);
  }

  /// Format tanggal aman via [AppDates] (fallback en → default bila
  /// simbol locale belum di-init — cegah LocaleDataException).
  /// Dipertahankan sebagai wrapper agar pemanggil lama tetap jalan.
  static String safeDate(String pattern, DateTime date, String lang) =>
      AppDates.pattern(pattern, date, lang);

  void _openSearch(BuildContext context) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final ctrl = TextEditingController();
    String query = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) {
          final fp = context.read<FinanceProvider>();
          final results = query.trim().isEmpty
              ? const []
              : fp.filter(query: query.trim()).take(5).toList();
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.get('search', lang),
                    style: AppTextStyles.headlineSm(),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.search,
                          color: AppColors.outline,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: ctrl,
                            autofocus: true,
                            style: AppTextStyles.bodyMd(),
                            decoration: InputDecoration(
                              hintText: AppStrings.get('searchHint', lang),
                              hintStyle: AppTextStyles.bodyMd(
                                color: AppColors.outline,
                              ),
                              border: InputBorder.none,
                            ),
                            onChanged: (v) => setSB(() => query = v),
                            onSubmitted: (v) {
                              // Enter selalu ke tab Transaksi (ada/tanpa teks).
                              Navigator.pop(ctx);
                              widget.onNavigate?.call(1);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...results.map(
                    (t) => ListTile(
                      dense: true,
                      leading: Icon(
                        t.icon,
                        size: 18,
                        color: AppColors.tertiary,
                      ),
                      title: Text(
                        t.title,
                        style: AppTextStyles.bodyMd(),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${t.category} • ${MoneyFormat.format(t.amount)}',
                        style: AppTextStyles.bodySm(),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AddTransactionScreen(editing: t),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onNavigate?.call(1);
                      },
                      child: Text(
                        query.trim().isEmpty
                            ? AppStrings.get('search', lang)
                            : '${AppStrings.get('viewAll', lang)} (${fp.filter(query: query.trim()).length})',
                        style: AppTextStyles.labelSm(
                          color: AppColors.onTertiary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showNotifications(BuildContext context) {
    final fp = context.read<FinanceProvider>();
    final over = fp.budgets.where((b) => b.status.name != 'onTrack').toList();
    final lang = context.read<AppSettingsProvider>().languageCode;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('notifications', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              if (over.isEmpty && fp.transactions.isEmpty)
                Text(
                  AppStrings.get('noNotifications', lang),
                  style: AppTextStyles.bodySm(),
                ),
              ...over.map(
                (b) => ListTile(
                  leading: Icon(b.icon, color: AppColors.error),
                  title: Text(
                    '${b.name} ${AppStrings.get('almostFull', lang)}',
                    style: AppTextStyles.bodyMd(),
                  ),
                  subtitle: Text(
                    AppStrings.fill('percentUsed', lang, {
                      'p': (b.percent * 100).toStringAsFixed(0),
                    }),
                    style: AppTextStyles.bodySm(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final settings = context.watch<AppSettingsProvider>();
    final lang = settings.languageCode;
    final recent = fp.transactions.take(4).toList();
    final wallets = fp.wallets;
    final overBudget =
        fp.budgets.where((b) => b.status.name != 'onTrack').toList();
    final isEmpty = fp.isEmpty;

    return Scaffold(
      appBar: const AppHeader(title: 'Home'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${_greeting(lang)}, ${fp.accountName.split(' ').first}',
                          style: AppTextStyles.headlineMd(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppColors.tertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _HomeScreenState.safeDate(
                      'EEEE, d MMM yyyy',
                      DateTime.now(),
                      lang,
                    ),
                    style: AppTextStyles.bodySm(),
                  ),
                ],
              ),
              const Spacer(),
              _iconSquareButton(Icons.search, () => _openSearch(context)),
              const SizedBox(width: 8),
              Consumer<FinanceProvider>(
                builder: (_, fp2, __) {
                  final hasAlert = fp2.budgets.any(
                    (b) => b.status.name != 'onTrack',
                  );
                  return Stack(
                    children: [
                      _iconSquareButton(
                        Icons.notifications_outlined,
                        () => _showNotifications(context),
                      ),
                      if (hasAlert)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.error,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _balanceCard(fp, lang),
          if (fp.monthlyAllowance == 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: () => _editAllowance(context, fp, lang),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.tertiary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.tertiary.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: AppColors.tertiary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppStrings.get('allowanceInfo', lang),
                          style: AppTextStyles.bodySm(
                            color: AppColors.tertiary,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: AppColors.tertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (overBudget.isNotEmpty) _budgetAlert(overBudget, lang),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                AppStrings.get('wallets', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => showAddWalletDialog(context, fp, lang),
                icon: const Icon(
                  Icons.add,
                  size: 16,
                  color: AppColors.tertiary,
                ),
                label: Text(
                  AppStrings.get('add', lang),
                  style: AppTextStyles.labelSm(color: AppColors.tertiary),
                ),
              ),
            ],
          ),
          if (wallets.isEmpty)
            InkWell(
              onTap: () => showAddWalletDialog(context, fp, lang),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.outlineVariant),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.wallet_outlined, color: AppColors.outline),
                    const SizedBox(height: 6),
                    Text(
                      AppStrings.get('noWallets', lang),
                      style: AppTextStyles.bodyMd(),
                    ),
                    Text(
                      AppStrings.get('addFirstWallet', lang),
                      style: AppTextStyles.bodySm(),
                    ),
                  ],
                ),
              ),
            )
          else
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: wallets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final w = wallets[i];
                  return InkWell(
                    onTap: () => showEditWalletDialog(context, fp, w, lang),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 160,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: w.color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          WalletAvatar(name: w.name, radius: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  w.name,
                                  style: AppTextStyles.labelSm(),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  MoneyFormat.format(w.balance),
                                  style: AppTextStyles.tabularAmount().copyWith(
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 16),
          _trendCard(fp, isEmpty, lang),
          const SizedBox(height: 20),
          Row(
            children: [
              Text(
                AppStrings.get('recentTransactions', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  AppStrings.fill('recentCount', lang, {'n': recent.length}),
                  style: AppTextStyles.labelCaps().copyWith(fontSize: 10),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => widget.onNavigate?.call(1),
                child: Row(
                  children: [
                    Text(
                      AppStrings.get('viewAll', lang),
                      style: AppTextStyles.labelSm(color: AppColors.tertiary),
                    ),
                    const Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: AppColors.tertiary,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const EmptyArt(icon: Icons.receipt_long_outlined, size: 36),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.get('noTransactions', lang),
                    style: AppTextStyles.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    AppStrings.get('emptyDesc', lang),
                    style: AppTextStyles.bodySm(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.tertiary,
                          ),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AddTransactionScreen(),
                            ),
                          ),
                          icon: const Icon(
                            Icons.add,
                            color: AppColors.onTertiary,
                            size: 18,
                          ),
                          label: Text(
                            AppStrings.get('firstTransaction', lang),
                            style: AppTextStyles.labelSm(
                              color: AppColors.onTertiary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: AppColors.outlineVariant,
                            ),
                          ),
                          onPressed: () => widget.onNavigate?.call(2),
                          icon: const Icon(Icons.pie_chart_outline, size: 18),
                          label: Text(
                            AppStrings.get('createBudget', lang),
                            style: AppTextStyles.labelSm(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ...List.generate(recent.length, (i) {
            final t = recent[i];
            return StaggerEntrance(
              index: i,
              key: ValueKey(t.id),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TransactionTile(
                  tx: t,
                  onTap: () {
                    // Mutasi tabungan bersifat atomik (lihat
                    // TransactionsScreen._openEdit): tolak di sini agar
                    // pengguna tidak mengedit lalu gagal saat Simpan.
                    final fp = context.read<FinanceProvider>();
                    final lang =
                        context.read<AppSettingsProvider>().languageCode;
                    if (fp.isSavingsLinkedTx(t.id)) {
                      AppMotion.tap();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppStrings.get('savingsReadonly', lang),
                          ),
                          backgroundColor: AppColors.surfaceBright,
                        ),
                      );
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AddTransactionScreen(editing: t),
                      ),
                    );
                  },
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFixed,
                foregroundColor: AppColors.onPrimaryFixed,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddTransactionScreen()),
              ),
              icon: const Icon(Icons.add),
              label: Text(
                AppStrings.get('addTransaction', lang),
                style: AppTextStyles.headlineSm(
                  color: AppColors.onPrimaryFixed,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _editAllowance(BuildContext context, FinanceProvider fp, String lang) {
    // Sheet angka bawaan aplikasi — keyboard perangkat tidak muncul.
    unawaited(
      showAppAmountSheet(
        context,
        title: AppStrings.get('monthlyAllowance', lang),
        message: AppStrings.get('allowanceHint', lang),
        cancelLabel: AppStrings.get('cancel', lang),
        okLabel: AppStrings.get('save', lang),
        initialRaw: fp.monthlyAllowance == 0
            ? 0
            : MoneyFormat.fromBase(fp.monthlyAllowance),
      ).then((raw) {
        if (raw == null) return;
        // 0 = tanpa batas; nilai 0 tidak boleh diabaikan diam-diam.
        unawaited(fp.setMonthlyAllowance(MoneyFormat.toBaseMinorUnits(raw)));
      }),
    );
  }

  Widget _budgetAlert(List over, String lang) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.errorContainer.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppStrings.fill('budgetAlertMsg', lang, {'n': over.length}),
              style: AppTextStyles.bodySm(color: AppColors.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: () => widget.onNavigate?.call(2),
            child: Text(
              AppStrings.get('viewAll', lang),
              style: AppTextStyles.labelSm(color: AppColors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconSquareButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 19, color: AppColors.onSurfaceVariant),
      ),
    );
  }

  Widget _balanceCard(FinanceProvider fp, String lang) {
    final netLabel = fp.transactions.isEmpty
        ? AppStrings.get('startNow', lang)
        : (fp.netAmount >= 0
            ? AppStrings.get('netPositive', lang)
            : AppStrings.get('netNegative', lang));
    var incomeN = 0;
    var expenseN = 0;
    for (final t in fp.transactions) {
      if (t.type == TransactionType.income) incomeN++;
      if (t.type == TransactionType.expense) expenseN++;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.get('totalBalance', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      fp.netAmount >= 0
                          ? Icons.trending_up
                          : Icons.trending_down,
                      size: 14,
                      color: fp.netAmount >= 0
                          ? AppColors.tertiary
                          : AppColors.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      netLabel,
                      style: AppTextStyles.tabularAmount(
                        color: fp.netAmount >= 0
                            ? AppColors.tertiary
                            : AppColors.error,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: AnimatedBalance(
                  value: fp.balance,
                  visible: fp.balanceVisible,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(
                Icons.account_balance_wallet_outlined,
                size: 16,
                color: AppColors.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(fp.accountName, style: AppTextStyles.bodySm()),
              ),
              InkWell(
                onTap: () => unawaited(fp.toggleBalanceVisibility()),
                child: Icon(
                  fp.balanceVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: AppColors.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _statTile(
                  AppStrings.get('income', lang),
                  fp.totalIncome,
                  AppColors.tertiary,
                  '+',
                  AppColors.tertiary,
                  AppStrings.fill('inflowCount', lang, {'n': incomeN}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statTile(
                  AppStrings.get('expenses', lang),
                  fp.totalExpense,
                  AppColors.error,
                  '-',
                  AppColors.error,
                  AppStrings.fill('outflowCount', lang, {'n': expenseN}),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statTile(
                  AppStrings.get('net', lang),
                  fp.netAmount.abs(),
                  AppColors.onSurface,
                  fp.netAmount >= 0 ? '+' : '-',
                  AppColors.onSurface,
                  fp.transactions.isEmpty
                      ? AppStrings.get('noTransactions', lang)
                      : AppStrings.get('currentPeriod', lang),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statTile(
    String label,
    int amount,
    Color dotColor,
    String sign,
    Color amountColor,
    String sub,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.surfaceContainerHigh),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.labelCaps(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$sign ${MoneyFormat.compact(amount)}',
            style: AppTextStyles.tabularAmount(color: amountColor),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            sub,
            style: AppTextStyles.bodySm().copyWith(fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _trendCard(FinanceProvider fp, bool isEmpty, String lang) {
    final vals = fp.cashFlowTrendFor(_range);
    // Nilai mentah (Rp) untuk tooltip — painter tetap pakai versi
    // normalisasi agar garis tidak terdistorsi.
    final raw = fp.cashFlowRawFor(_range);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.get('cashFlowTrend', lang),
                      style: AppTextStyles.labelCaps(),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      AppStrings.get('performanceOverview', lang),
                      style: AppTextStyles.headlineSm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 160,
                child: SlidingSegment(
                  labels: ['7D', '1M', '3M', '1Y'].map((r) {
                    return r == '7D'
                        ? AppStrings.get('period7d', lang)
                        : r == '1M'
                            ? AppStrings.get('period1m', lang)
                            : r == '3M'
                                ? AppStrings.get('period3m', lang)
                                : AppStrings.get('period1y', lang);
                  }).toList(),
                  selected: ['7D', '1M', '3M', '1Y'].indexOf(_range),
                  onSelect: (i) => setState(() {
                    const codes = ['7D', '1M', '3M', '1Y'];
                    _range = codes[i];
                    _highlight = null;
                  }),
                  height: 32,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isEmpty)
            SizedBox(
              height: 140,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.show_chart, color: AppColors.outline),
                    const SizedBox(height: 6),
                    Text(
                      AppStrings.get('noChartData', lang),
                      style: AppTextStyles.bodySm(),
                    ),
                    Text(
                      AppStrings.get('tapForTooltip', lang),
                      style: AppTextStyles.bodySm().copyWith(fontSize: 10),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            if (_highlight != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.tertiary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.circle, size: 8, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      AppStrings.fill('pointLabel', lang, {
                        'i': _highlight! + 1,
                        'v': MoneyFormat.format(raw[_highlight!]),
                        'range': _range,
                      }),
                      style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                    ),
                  ],
                ),
              ),
            LayoutBuilder(
              builder: (ctx, constraints) {
                final w = constraints.maxWidth > 0
                    ? constraints.maxWidth
                    : MediaQuery.of(ctx).size.width - 64;
                return GestureDetector(
                  onTapDown: (d) => _updateHighlight(d.localPosition, w, vals),
                  onPanUpdate: (d) =>
                      _updateHighlight(d.localPosition, w, vals),
                  child: SizedBox(
                    height: 140,
                    width: double.infinity,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: LineChartPainter(
                          values: vals,
                          highlightIndex: _highlight,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                );
              },
            ),
            Text(
              AppStrings.get('tapForTooltip', lang),
              style: AppTextStyles.bodySm().copyWith(fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _trendLabels(lang)
                .map(
                  (d) => Flexible(
                    child: Text(
                      d,
                      style: AppTextStyles.labelCaps(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  List<String> _trendLabels(String lang) {
    final now = DateTime.now();
    String fmt(DateTime d) {
      if (_range == '7D') {
        return _HomeScreenState.safeDate('EEE', d, lang);
      }
      return _HomeScreenState.safeDate('d MMM', d, lang);
    }

    if (_range == '7D') {
      return List.generate(
        5,
        (i) => fmt(now.subtract(Duration(days: (4 - i) * 2))),
      );
    }
    final days = _range == '3M'
        ? 90
        : _range == '1Y'
            ? 365
            : 30;
    return List.generate(
      5,
      (i) => i == 4
          ? AppStrings.get('today', lang)
          : fmt(now.subtract(Duration(days: (days * (4 - i) ~/ 4)))),
    ).toList();
  }

  void _updateHighlight(Offset pos, double width, List<double> vals) {
    final idx =
        ((pos.dx / width) * vals.length).clamp(0, vals.length - 1).round();
    setState(() => _highlight = idx);
  }
}
