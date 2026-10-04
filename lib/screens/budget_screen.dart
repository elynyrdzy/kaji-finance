import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/budget_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/app_keypad.dart';
import '../widgets/motion_kit.dart';
import 'recurring_bills_screen.dart';
import 'savings_goals_screen.dart';
import '../widgets/app_header.dart';

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  DateTime _month = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Scaffold(
      appBar: AppHeader(title: AppStrings.get('budget', lang)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _monthNavButton(
                  Icons.chevron_left,
                  () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1),
                  ),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.calendar_today,
                        size: 16,
                        color: AppColors.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        AppDates.monthYear(_month, lang),
                        style: AppTextStyles.headlineSm(),
                      ),
                    ],
                  ),
                ),
                _monthNavButton(
                  Icons.chevron_right,
                  () => setState(
                    () => _month = DateTime(_month.year, _month.month + 1),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => setState(() => _month = DateTime.now()),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      AppStrings.get('today', lang),
                      style: AppTextStyles.labelCaps(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _openCreateSheet(fp, lang),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.tertiary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.add,
                          size: 16,
                          color: AppColors.onTertiary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppStrings.get('add', lang),
                          style: AppTextStyles.labelSm(
                            color: AppColors.onTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _summaryCard(fp, lang),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                AppStrings.get('categoryBudgets', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  AppStrings.fill('budgetCount', lang, {
                    'n': fp.budgets.length,
                  }),
                  style: AppTextStyles.labelCaps(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (fp.budgets.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.pie_chart_outline,
                    size: 32,
                    color: AppColors.outline,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.get('noBudgets', lang),
                    style: AppTextStyles.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    AppStrings.get('noBudgetsDesc', lang),
                    style: AppTextStyles.bodySm(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                      ),
                      onPressed: () => _openCreateSheet(fp, lang),
                      icon: const Icon(
                        Icons.add,
                        color: AppColors.onTertiary,
                        size: 18,
                      ),
                      label: Text(
                        AppStrings.get('createBudget', lang),
                        style: AppTextStyles.labelSm(
                          color: AppColors.onTertiary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ...List.generate(fp.budgets.length, (i) {
            final b = fp.budgets[i];
            final spent = fp.spentForBudget(b.name, month: _month);
            final bForMonth = b.copyWith(spent: spent);
            return StaggerEntrance(
              index: i,
              key: ValueKey(b.id),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _budgetCard(bForMonth, fp, lang),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _monthNavButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: AppColors.onSurfaceVariant),
      ),
    );
  }

  Widget _summaryCard(FinanceProvider fp, String lang) {
    final now = DateTime.now();
    final isCurrentMonth = _month.year == now.year && _month.month == now.month;
    final isPastMonth = _month.year < now.year ||
        (_month.year == now.year && _month.month < now.month);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final daysLeft = isPastMonth
        ? 0
        : (isCurrentMonth ? daysInMonth - now.day : daysInMonth);
    final daysLabel = isPastMonth
        ? AppStrings.get('monthEnded', lang)
        : (isCurrentMonth
            ? AppStrings.fill('daysLeft', lang, {'n': daysLeft})
            : AppStrings.fill('monthDays', lang, {'n': daysInMonth}));
    // compute month totals
    var spentMonth = 0;
    for (final b in fp.budgets) {
      spentMonth += fp.spentForBudget(b.name, month: _month);
    }
    final remGap = fp.monthlyAllowance - spentMonth;
    final remaining = remGap < 0 ? 0 : remGap;
    final progress = fp.monthlyAllowance <= 0
        ? 0.0
        : (spentMonth / fp.monthlyAllowance).clamp(0, 1).toDouble();
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
                      AppStrings.get('monthlyAllowance', lang),
                      style: AppTextStyles.labelCaps(),
                    ),
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => _editAllowance(fp, lang),
                      child: Row(
                        children: [
                          Text(
                            MoneyFormat.format(fp.monthlyAllowance),
                            style: AppTextStyles.displayCurrencyMobile(),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: AppColors.outline,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.schedule,
                      size: 14,
                      color: AppColors.outline,
                    ),
                    const SizedBox(width: 4),
                    Text(daysLabel, style: AppTextStyles.labelSm()),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: AppColors.surfaceContainer,
              valueColor: AlwaysStoppedAnimation(
                progress >= 0.9 ? AppColors.error : AppColors.tertiary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(progress * 100).toStringAsFixed(1)}% ${AppStrings.get('budgetSpent', lang).toLowerCase()}',
                style: AppTextStyles.labelCaps(),
              ),
              Text(
                AppDates.monthYearShort(_month, lang),
                style: AppTextStyles.labelCaps(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _summaryStat(
                  AppStrings.get('budgetSpent', lang),
                  spentMonth,
                  Icons.arrow_upward,
                  AppColors.error,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _summaryStat(
                  AppStrings.get('budgetRemaining', lang),
                  remaining,
                  Icons.account_balance_wallet_outlined,
                  AppColors.tertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _planLinks(context, fp, lang),
        ],
      ),
    );
  }

  /// RENCANA dipindah dari Pengaturan ke layar Anggaran: anggaran, target
  /// tabungan, dan tagihan rutin adalah data keuangan, bukan preferensi.
  /// Uang bulanan ikut ke sini karena jadi masukan hitungan anggaran.
  Widget _planLinks(BuildContext context, FinanceProvider fp, String lang) {
    final nav = Navigator.of(context);

    Widget row(
      IconData icon,
      String title,
      String subtitle,
      VoidCallback tap,
    ) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              leading: Icon(icon, size: 20, color: AppColors.tertiary),
              title: Text(title, style: AppTextStyles.bodyMd()),
              subtitle: Text(subtitle, style: AppTextStyles.bodySm()),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.outline,
                size: 18,
              ),
              onTap: tap,
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            AppStrings.get('rencana', lang).toUpperCase(),
            style: AppTextStyles.labelCaps(),
          ),
        ),
        row(
          Icons.savings_outlined,
          AppStrings.get('savingsGoals', lang),
          fp.savingsGoals.isEmpty
              ? AppStrings.get('noSavings', lang)
              : '${fp.savingsGoals.length} • ${MoneyFormat.format(fp.totalSavingsSaved)}',
          () => nav.push(
            MaterialPageRoute(builder: (_) => const SavingsGoalsScreen()),
          ),
        ),
        row(
          Icons.event_repeat,
          AppStrings.get('recurringBills', lang),
          fp.recurringBills.isEmpty
              ? AppStrings.get('recurringBillsDesc', lang)
              : '${fp.recurringBills.where((b) => b.active).length} • ${AppStrings.fill('recurringMonthlyTotal', lang, {
                      'amount': MoneyFormat.format(fp.estimatedMonthlyRecurring)
                    })}',
          () => nav.push(
            MaterialPageRoute(builder: (_) => const RecurringBillsScreen()),
          ),
        ),
        row(
          Icons.payments_outlined,
          AppStrings.get('monthlyAllowance', lang),
          fp.monthlyAllowance == 0
              ? AppStrings.fill('allowanceHint', lang)
              : MoneyFormat.format(fp.monthlyAllowance),
          () => _editAllowance(fp, lang),
        ),
      ],
    );
  }

  void _editAllowance(FinanceProvider fp, String lang) {
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
        // 0 = tanpa uang bulanan. Sebelumnya nilai 0 diabaikan diam-diam
        // sehingga user tidak bisa membersihkan batas pengeluarannya.
        unawaited(fp.setMonthlyAllowance(MoneyFormat.toBaseMinorUnits(raw)));
      }),
    );
  }

  Widget _summaryStat(String label, int amount, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: AppColors.outline),
              const SizedBox(width: 4),
              Text(label, style: AppTextStyles.labelCaps()),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            MoneyFormat.format(amount),
            style: AppTextStyles.tabularAmountLg(color: color),
          ),
        ],
      ),
    );
  }

  Widget _budgetCard(BudgetCategory b, FinanceProvider fp, String lang) {
    Color barColor;
    String note;
    switch (b.status) {
      case BudgetStatus.limitReached:
        barColor = AppColors.error;
        note = AppStrings.get('limitReached', lang);
        break;
      case BudgetStatus.approaching:
        barColor = AppColors.error;
        note = AppStrings.get('approachingLimit', lang);
        break;
      case BudgetStatus.onTrack:
        barColor = AppColors.tertiary;
        note = AppStrings.get('onTrack', lang);
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
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(b.icon, size: 18, color: AppColors.onSurface),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            b.name,
                            style: AppTextStyles.headlineSm(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (b.status != BudgetStatus.onTrack) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: b.status == BudgetStatus.limitReached
                                  ? AppColors.errorContainer
                                  : AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              b.status == BudgetStatus.limitReached
                                  ? AppStrings.get('limitReached', lang)
                                  : AppStrings.get('approachingLimit', lang),
                              style: AppTextStyles.labelCaps(
                                color: b.status == BudgetStatus.limitReached
                                    ? AppColors.onErrorContainer
                                    : AppColors.error,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${MoneyFormat.format(b.spent)} ${AppStrings.get('budgetOf', lang)} ${MoneyFormat.format(b.limit)} • ${AppDates.monthYearShort(_month, lang)}',
                      style: AppTextStyles.bodySm(),
                    ),
                    Builder(
                      builder: (_) {
                        // Sisa boleh belanja per hari: sisa limit dibagi hari
                        // tersisa bulan tampil (termasuk hari ini bila bulan
                        // berjalan). Sembunyi bila limit sudah jebol.
                        if (b.remaining <= 0) return const SizedBox.shrink();
                        final now = DateTime.now();
                        final dim = DateTime(
                          _month.year,
                          _month.month + 1,
                          0,
                        ).day;
                        final left = (_month.year == now.year &&
                                _month.month == now.month)
                            ? (dim - now.day + 1).clamp(1, dim)
                            : dim;
                        final perDay = b.remaining / left;
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            AppStrings.fill('budgetPerDay', lang, {
                              'amount': MoneyFormat.format(perDay.round()),
                            }),
                            style: AppTextStyles.bodySm(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert,
                  size: 18,
                  color: AppColors.outline,
                ),
                color: AppColors.surfaceContainerHigh,
                onSelected: (v) {
                  if (v == 'edit') _openEditSheet(fp, b, lang);
                  if (v == 'delete') _confirmDeleteBudget(fp, b, lang);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(AppStrings.get('edit', lang)),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(AppStrings.get('delete', lang)),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    MoneyFormat.format(b.remaining),
                    style: AppTextStyles.tabularAmount(
                      color: b.status == BudgetStatus.limitReached
                          ? AppColors.error
                          : AppColors.onSurface,
                    ),
                  ),
                  Text(
                    AppStrings.get('remaining', lang),
                    style: AppTextStyles.labelCaps(),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: b.percent.clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: AppColors.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(b.percent * 100).toStringAsFixed(1)}%',
                style: AppTextStyles.labelCaps(),
              ),
              Text(
                note,
                style: AppTextStyles.labelCaps(
                  color: barColor == AppColors.error
                      ? AppColors.error
                      : AppColors.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Hapus anggaran selalu konfirmasi dulu (tak ada undo).
  void _confirmDeleteBudget(FinanceProvider fp, BudgetCategory b, String lang) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('confirmDeleteTitle', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Text(
          '${AppStrings.get('confirmDeleteBudget', lang)} (${b.name})',
          style: AppTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.errorContainer,
            ),
            onPressed: () async {
              await fp.deleteBudget(b.id);
              if (!dialogCtx.mounted) return;
              Navigator.pop(dialogCtx);
            },
            child: Text(
              AppStrings.get('delete', lang),
              style: AppTextStyles.labelSm(color: AppColors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  void _openCreateSheet(FinanceProvider fp, String lang) {
    final nameCtrl = TextEditingController();
    double limitRaw = 0;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.get('newBudget', lang),
                  style: AppTextStyles.headlineMd(),
                ),
                Text(
                  AppStrings.get('newBudgetDesc', lang),
                  style: AppTextStyles.bodySm(),
                ),
                const SizedBox(height: 16),
                Text(
                  AppStrings.get('budgetNameLabel', lang),
                  style: AppTextStyles.labelSm(color: AppColors.outline),
                ),
                const SizedBox(height: 6),
                _sheetField(
                  nameCtrl,
                  AppStrings.get('categoryNameHint', lang),
                  Icons.category_outlined,
                  TextInputType.text,
                ),
                const SizedBox(height: 12),
                Text(
                  AppStrings.get('budgetLimitLabel', lang),
                  style: AppTextStyles.labelSm(color: AppColors.outline),
                ),
                const SizedBox(height: 6),
                AppAmountInput(initialRaw: 0, onChanged: (v) => limitRaw = v),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AppColors.surfaceContainerHigh,
                          side: BorderSide.none,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          AppStrings.get('cancel', lang),
                          style: AppTextStyles.labelSm(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.tertiary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () async {
                          final name = nameCtrl.text.trim();
                          final limit = MoneyFormat.toBaseMinorUnits(limitRaw);
                          if (name.isEmpty || limit <= 0) return;
                          final messenger = ScaffoldMessenger.of(context);
                          final navigator = Navigator.of(ctx);
                          final ok = await fp.addBudgetCategory(
                            name: name,
                            limit: limit,
                          );
                          if (!ok) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  AppStrings.get('budgetExists', lang),
                                ),
                              ),
                            );
                            return;
                          }
                          navigator.pop();
                        },
                        child: Text(
                          AppStrings.get('save', lang),
                          style: AppTextStyles.labelSm(
                            color: AppColors.onTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openEditSheet(FinanceProvider fp, BudgetCategory b, String lang) {
    final nameCtrl = TextEditingController(text: b.name);
    double limitRaw = MoneyFormat.fromBase(b.limit);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.get('edit', lang),
                  style: AppTextStyles.headlineMd(),
                ),
                const SizedBox(height: 12),
                _sheetField(
                  nameCtrl,
                  AppStrings.get('categoryNameHint', lang),
                  Icons.category_outlined,
                  TextInputType.text,
                ),
                const SizedBox(height: 12),
                AppAmountInput(
                  initialRaw: limitRaw,
                  onChanged: (v) => limitRaw = v,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.tertiary,
                    ),
                    onPressed: () async {
                      final limit = MoneyFormat.toBaseMinorUnits(limitRaw);
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(ctx);
                      final ok = await fp.updateBudget(
                        b.id,
                        name: nameCtrl.text.trim(),
                        limit: limit > 0 ? limit : b.limit,
                      );
                      if (!ok) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(AppStrings.get('budgetExists', lang)),
                          ),
                        );
                        return;
                      }
                      navigator.pop();
                    },
                    child: Text(
                      AppStrings.get('save', lang),
                      style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetField(
    TextEditingController ctrl,
    String hint,
    IconData icon,
    TextInputType type,
  ) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.outline),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: ctrl,
              keyboardType: type,
              style: AppTextStyles.bodyMd(),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
