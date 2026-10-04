import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/savings_goal_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/app_header.dart';
import '../widgets/app_keypad.dart';
import '../widgets/motion_kit.dart';

class SavingsGoalsScreen extends StatelessWidget {
  const SavingsGoalsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final goals = fp.savingsGoals;
    return Scaffold(
      appBar: AppHeader(title: AppStrings.get('savingsGoals', lang)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _summaryCard(fp, lang),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                AppStrings.get('savingsGoals', lang),
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
                  AppStrings.fill('activeGoals', lang, {'n': goals.length}),
                  style: AppTextStyles.labelCaps(),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => _openCreateSheet(context, fp, lang),
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
          const SizedBox(height: 12),
          if (goals.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.savings_outlined,
                    size: 32,
                    color: AppColors.outline,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.get('noSavings', lang),
                    style: AppTextStyles.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    AppStrings.get('noSavingsDesc', lang),
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
                      onPressed: () => _openCreateSheet(context, fp, lang),
                      icon: const Icon(
                        Icons.add,
                        color: AppColors.onTertiary,
                        size: 18,
                      ),
                      label: Text(
                        AppStrings.get('createFirstGoal', lang),
                        style: AppTextStyles.labelSm(
                          color: AppColors.onTertiary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ...List.generate(goals.length, (i) {
            final g = goals[i];
            return StaggerEntrance(
              index: i,
              key: ValueKey(g.id),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _goalCard(context, fp, g, lang),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _summaryCard(FinanceProvider fp, String lang) {
    final p = fp.savingsOverallProgress;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.get('totalSaved', lang),
            style: AppTextStyles.labelCaps(),
          ),
          const SizedBox(height: 4),
          Text(
            MoneyFormat.format(fp.totalSavingsSaved),
            style: AppTextStyles.displayCurrencyMobile(),
          ),
          Text(
            '${AppStrings.get('budgetOf', lang)} ${MoneyFormat.format(fp.totalSavingsTarget)} • ${(p * 100).toStringAsFixed(1)}%',
            style: AppTextStyles.bodySm(),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: p,
              minHeight: 8,
              backgroundColor: AppColors.surfaceContainer,
              valueColor: const AlwaysStoppedAnimation(AppColors.tertiary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _miniStat(
                  AppStrings.get('collected', lang),
                  fp.totalSavingsSaved,
                  Icons.savings_outlined,
                  AppColors.tertiary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniStat(
                  AppStrings.get('remainingTarget', lang),
                  (() {
                    final gap = fp.totalSavingsTarget - fp.totalSavingsSaved;
                    return gap < 0 ? 0 : gap;
                  })(),
                  Icons.flag_outlined,
                  AppColors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${AppStrings.get('depositsThisMonth', lang)}: ${MoneyFormat.format(fp.savingsDepositsThisMonth())}',
            style: AppTextStyles.bodySm(),
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, int amount, IconData icon, Color color) {
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
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.labelCaps(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            MoneyFormat.format(amount),
            style: AppTextStyles.tabularAmountLg(color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _goalCard(
    BuildContext context,
    FinanceProvider fp,
    SavingsGoalModel g,
    String lang,
  ) {
    final done = g.isCompleted;
    final days = g.daysLeft;
    return CelebrationPulse(
      done: done,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: g.color.withValues(alpha: 0.35)),
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
                    color: g.color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(g.icon, size: 18, color: g.color),
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
                              g.name,
                              style: AppTextStyles.headlineSm(),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (done) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.tertiary,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                AppStrings.get('goalCompleted', lang),
                                style: AppTextStyles.labelCaps(
                                  color: AppColors.onTertiary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '${MoneyFormat.format(g.saved)} / ${MoneyFormat.format(g.target)}',
                        style: AppTextStyles.bodySm(),
                      ),
                      if (days != null)
                        Text(
                          days < 0
                              ? AppStrings.fill('deadlineOverdue', lang, {
                                  'n': -days,
                                })
                              : days == 0
                                  ? AppStrings.get('deadlineToday', lang)
                                  : AppStrings.fill(
                                      'daysLeft', lang, {'n': days}),
                          style: AppTextStyles.labelCaps(
                            color:
                                days < 0 ? AppColors.error : AppColors.outline,
                          ),
                        ),
                      // Kebutuhan nabung harian agar target tercapai tepat
                      // waktu (disembunyikan bila selesai/tanpa deadline).
                      if (days != null && days > 0 && !done)
                        Builder(
                          builder: (_) {
                            final gap = g.target - g.saved;
                            final need = (gap < 0 ? 0 : gap) / days;
                            return Text(
                              AppStrings.fill('goalPerDay', lang, {
                                'amount': MoneyFormat.format(need.round()),
                              }),
                              style: AppTextStyles.labelCaps(
                                color: AppColors.outline,
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
                    if (v == 'edit') _openEditSheet(context, fp, g, lang);
                    if (v == 'delete') _confirmDelete(context, fp, g, lang);
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
              ],
            ),
            const SizedBox(height: 10),
            AnimatedProgressBar(
              value: g.progress,
              color: done ? AppColors.tertiary : g.color,
              background: AppColors.surfaceContainerHighest,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(g.progress * 100).toStringAsFixed(1)}%',
                  style: AppTextStyles.labelCaps(),
                ),
                Text(
                  done
                      ? AppStrings.get('targetReached', lang)
                      : AppStrings.fill('remainingToGoal', lang, {
                          'amount': MoneyFormat.format(g.remaining),
                        }),
                  style: AppTextStyles.labelCaps(
                    color: done ? AppColors.tertiary : AppColors.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.outlineVariant),
                    ),
                    onPressed: () => _openWithdrawSheet(context, fp, g, lang),
                    icon: const Icon(Icons.remove, size: 16),
                    label: Text(AppStrings.get('withdraw', lang)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.tertiary,
                    ),
                    onPressed: () => _openDepositSheet(context, fp, g, lang),
                    icon: const Icon(
                      Icons.add,
                      size: 16,
                      color: AppColors.onTertiary,
                    ),
                    label: Text(
                      AppStrings.get('deposit', lang),
                      style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    FinanceProvider fp,
    SavingsGoalModel g,
    String lang,
  ) {
    final n = fp.savingsLinkedCount(g.id);
    final body = n > 0
        ? AppStrings.fill('confirmDeleteGoalLinked', lang, {'n': n})
        : AppStrings.get('confirmDeleteGoal', lang);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('confirmDeleteTitle', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Text(
          '$body (${MoneyFormat.format(g.saved)})',
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
              await fp.deleteSavingsGoal(g.id);
              if (!dialogCtx.mounted) return;
              Navigator.pop(dialogCtx);
            },
            child: Text(AppStrings.get('delete', lang)),
          ),
        ],
      ),
    );
  }

  void _openCreateSheet(BuildContext context, FinanceProvider fp, String lang) {
    final nameCtrl = TextEditingController();
    double targetRaw = 0;
    IconData pickedIcon = Icons.savings_outlined;
    Color pickedColor = const Color(0xFF1A4D8F);
    DateTime? deadline;
    const icons = [
      Icons.savings_outlined,
      Icons.shield_outlined,
      Icons.home_outlined,
      Icons.directions_car_outlined,
      Icons.flight_outlined,
      Icons.school_outlined,
      Icons.phone_android_outlined,
      Icons.laptop_outlined,
      Icons.favorite_border,
      Icons.cake_outlined,
      Icons.health_and_safety_outlined,
      Icons.work_outline,
    ];
    const colors = [
      Color(0xFF1A4D8F),
      Color(0xFF0E7C5B),
      Color(0xFF8A5A00),
      Color(0xFF9C3D2E),
      Color(0xFF6C4FC4),
      Color(0xFF0077B6),
    ];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) => Padding(
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
                    AppStrings.get('newGoal', lang),
                    style: AppTextStyles.headlineMd(),
                  ),
                  Text(
                    AppStrings.get('goalNameHint', lang),
                    style: AppTextStyles.bodySm(),
                  ),
                  const SizedBox(height: 16),
                  _sheetField(
                    nameCtrl,
                    AppStrings.get('goalName', lang),
                    Icons.label_outline,
                    TextInputType.text,
                  ),
                  const SizedBox(height: 12),
                  AppAmountInput(
                    initialRaw: 0,
                    onChanged: (v) => targetRaw = v,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.get('categoryIcon', lang),
                    style: AppTextStyles.labelCaps(),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: icons
                        .map(
                          (ic) => InkWell(
                            onTap: () => setSB(() => pickedIcon = ic),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: pickedIcon == ic
                                    ? AppColors.tertiary
                                    : AppColors.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                ic,
                                color: pickedIcon == ic
                                    ? AppColors.onTertiary
                                    : AppColors.onSurface,
                                size: 20,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.get('colorLabel', lang),
                    style: AppTextStyles.labelCaps(),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: colors
                        .map(
                          (c) => InkWell(
                            onTap: () => setSB(() => pickedColor = c),
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: pickedColor == c
                                      ? AppColors.onSurface
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          deadline == null
                              ? AppStrings.get('noDeadline', lang)
                              : '${AppStrings.get('deadline', lang)}: ${AppDates.dateShort(deadline!, lang)}',
                          style: AppTextStyles.bodySm(),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: ctx2,
                            initialDate: deadline ?? now,
                            firstDate: now.subtract(const Duration(days: 1)),
                            lastDate: now.add(const Duration(days: 365 * 10)),
                          );
                          if (picked != null) {
                            setSB(() => deadline = picked);
                          }
                        },
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                          deadline == null
                              ? AppStrings.get('add', lang)
                              : AppStrings.get('edit', lang),
                          style: AppTextStyles.labelSm(),
                        ),
                      ),
                      if (deadline != null)
                        IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () => setSB(() => deadline = null),
                        ),
                    ],
                  ),
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
                            final target = MoneyFormat.toBaseMinorUnits(
                              targetRaw,
                            );
                            final ok = await fp.addSavingsGoal(
                              name: nameCtrl.text.trim(),
                              target: target,
                              icon: pickedIcon,
                              color: pickedColor,
                              deadline: deadline,
                            );
                            if (!ok) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppStrings.get('goalExists', lang),
                                  ),
                                ),
                              );
                              return;
                            }
                            if (!context.mounted) return;
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  AppStrings.get('goalCreated', lang),
                                ),
                              ),
                            );
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
      ),
    );
  }

  void _openEditSheet(
    BuildContext context,
    FinanceProvider fp,
    SavingsGoalModel g,
    String lang,
  ) {
    final nameCtrl = TextEditingController(text: g.name);
    double targetRaw = MoneyFormat.fromBase(g.target);
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
                  AppStrings.get('goalName', lang),
                  Icons.label_outline,
                  TextInputType.text,
                ),
                const SizedBox(height: 12),
                AppAmountInput(
                  initialRaw: targetRaw,
                  onChanged: (v) => targetRaw = v,
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
                      final target = MoneyFormat.toBaseMinorUnits(targetRaw);
                      final effective = target > 0 ? target : g.target;
                      final newName = nameCtrl.text.trim();
                      if (newName.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppStrings.get('validationTitle', lang),
                            ),
                          ),
                        );
                        return;
                      }
                      if (effective < g.saved) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppStrings.get('targetBelowSaved', lang),
                            ),
                          ),
                        );
                        return;
                      }
                      final ok = await fp.updateSavingsGoal(
                        g.id,
                        name: newName,
                        target: effective,
                      );
                      if (!ok) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(AppStrings.get('goalExists', lang)),
                          ),
                        );
                        return;
                      }
                      if (!context.mounted) return;
                      Navigator.pop(ctx);
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

  void _openDepositSheet(
    BuildContext context,
    FinanceProvider fp,
    SavingsGoalModel g,
    String lang,
  ) {
    double amtRaw = 0;
    // Dompet sumber WAJIB (default dompet pertama) agar kekayaan bersih
    // tidak mengembang — setoran adalah perpindahan internal (§32-§33).
    String? fromWallet = fp.wallets.isNotEmpty ? fp.wallets.first.name : null;
    bool busy = false;
    final opKey = 'dep-${g.id}-${DateTime.now().millisecondsSinceEpoch}';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) => Padding(
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
                    AppStrings.fill('depositTo', lang, {'name': g.name}),
                    style: AppTextStyles.headlineMd(),
                  ),
                  Text(
                    '${AppStrings.get('remaining', lang)} ${MoneyFormat.format(g.remaining)}',
                    style: AppTextStyles.bodySm(),
                  ),
                  const SizedBox(height: 12),
                  AppAmountInput(initialRaw: 0, onChanged: (v) => amtRaw = v),
                  const SizedBox(height: 12),
                  if (fp.wallets.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        AppStrings.get('walletRequired', lang),
                        style: AppTextStyles.bodySm(),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else ...[
                    Text(
                      AppStrings.get('selectSourceWallet', lang),
                      style: AppTextStyles.labelCaps(),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButton<String?>(
                        value: fromWallet,
                        isExpanded: true,
                        underline: const SizedBox(),
                        items: [
                          ...fp.wallets.map(
                            (w) => DropdownMenuItem<String?>(
                              value: w.name,
                              child: Text(
                                '${w.name} • ${MoneyFormat.format(w.balance)}',
                              ),
                            ),
                          ),
                        ],
                        onChanged: (v) => setSB(() => fromWallet = v),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              if (fromWallet == null || fromWallet!.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.get('validationWallet', lang),
                                    ),
                                  ),
                                );
                                return;
                              }
                              final amt = MoneyFormat.toBaseMinorUnits(amtRaw);
                              if (amt <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.get('validationAmount', lang),
                                    ),
                                  ),
                                );
                                return;
                              }
                              setSB(() => busy = true);
                              final ok = await fp.depositToGoalAtomic(
                                goalId: g.id,
                                amount: amt,
                                fromWallet: fromWallet!,
                                idempotencyKey: opKey,
                                txTitle: AppStrings.get(
                                  'savingsDepositTx',
                                  lang,
                                ),
                                txCategory: AppStrings.get(
                                  'transferLabel',
                                  lang,
                                ),
                              );
                              if (!ok) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        AppStrings.get('depositFailed', lang),
                                      ),
                                    ),
                                  );
                                }
                                setSB(() => busy = false);
                                return;
                              }
                              if (!context.mounted) return;
                              Navigator.pop(ctx);
                              AppMotion.success();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppStrings.get('depositSuccess', lang),
                                  ),
                                ),
                              );
                            },
                      child: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onTertiary,
                              ),
                            )
                          : Text(
                              AppStrings.get('deposit', lang),
                              style: AppTextStyles.labelSm(
                                color: AppColors.onTertiary,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openWithdrawSheet(
    BuildContext context,
    FinanceProvider fp,
    SavingsGoalModel g,
    String lang,
  ) {
    double amtRaw = 0;
    // Dompet tujuan WAJIB (default dompet pertama) agar penarikan tercatat
    // sebagai perpindahan internal (§35), bukan pemasukan.
    String? toWallet = fp.wallets.isNotEmpty ? fp.wallets.first.name : null;
    bool busy = false;
    final opKey = 'wd-${g.id}-${DateTime.now().millisecondsSinceEpoch}';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) => Padding(
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
                    AppStrings.fill('withdrawFrom', lang, {'name': g.name}),
                    style: AppTextStyles.headlineMd(),
                  ),
                  Text(
                    '${AppStrings.get('collected', lang)} ${MoneyFormat.format(g.saved)}',
                    style: AppTextStyles.bodySm(),
                  ),
                  const SizedBox(height: 12),
                  AppAmountInput(initialRaw: 0, onChanged: (v) => amtRaw = v),
                  const SizedBox(height: 12),
                  if (fp.wallets.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        AppStrings.get('walletRequired', lang),
                        style: AppTextStyles.bodySm(),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else ...[
                    Text(
                      AppStrings.get('returnToWallet', lang),
                      style: AppTextStyles.labelCaps(),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButton<String?>(
                        value: toWallet,
                        isExpanded: true,
                        underline: const SizedBox(),
                        items: [
                          ...fp.wallets.map(
                            (w) => DropdownMenuItem<String?>(
                              value: w.name,
                              child: Text(
                                '${w.name} • ${MoneyFormat.format(w.balance)}',
                              ),
                            ),
                          ),
                        ],
                        onChanged: (v) => setSB(() => toWallet = v),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              if (toWallet == null || toWallet!.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.get('validationWallet', lang),
                                    ),
                                  ),
                                );
                                return;
                              }
                              final amt = MoneyFormat.toBaseMinorUnits(amtRaw);
                              if (amt <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppStrings.get('validationAmount', lang),
                                    ),
                                  ),
                                );
                                return;
                              }
                              setSB(() => busy = true);
                              final ok = await fp.withdrawFromGoalAtomic(
                                goalId: g.id,
                                amount: amt,
                                toWallet: toWallet!,
                                idempotencyKey: opKey,
                                txTitle: AppStrings.get(
                                  'savingsWithdrawTx',
                                  lang,
                                ),
                                txCategory: AppStrings.get(
                                  'transferLabel',
                                  lang,
                                ),
                              );
                              if (!ok) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        AppStrings.get('withdrawFailed', lang),
                                      ),
                                    ),
                                  );
                                }
                                setSB(() => busy = false);
                                return;
                              }
                              if (!context.mounted) return;
                              Navigator.pop(ctx);
                              AppMotion.success();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppStrings.get('withdrawSuccess', lang),
                                  ),
                                ),
                              );
                            },
                      child: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onTertiary,
                              ),
                            )
                          : Text(
                              AppStrings.get('withdraw', lang),
                              style: AppTextStyles.labelSm(
                                color: AppColors.onTertiary,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
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
