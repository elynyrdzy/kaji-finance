import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/backup_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/app_header.dart';
import '../widgets/donut_chart_painter.dart';
import '../widgets/line_chart_painter.dart';
import '../widgets/motion_kit.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  String _period = 'month';
  int? _selectedSlice;
  int? _selectedBar;
  // Mode grafik arus kas: 0 = batang (mingguan), 1 = area (tren ternormalisasi).
  // Lulusan fitur eksperimental "chart" — versi benar: painter menerima
  // nilai 0..1 dari cashFlowTrendFor, total Rp tampil sebagai teks.
  int _cashMode = 0;

  /// Penggerak draw-in chart + sweep donat tiap ganti periode.
  late final AnimationController _chartCtrl;

  @override
  void initState() {
    super.initState();
    _chartCtrl = AnimationController(duration: AppMotion.slow, vsync: this)
      ..forward();
  }

  @override
  void dispose() {
    _chartCtrl.dispose();
    super.dispose();
  }

  /// Progress chart 0..1 — selalu penuh bila reduce-motion aktif.
  double _chartProgress(BuildContext context) =>
      AppMotion.reduced(context) ? 1.0 : _chartCtrl.value;

  /// Nama bulan kapital via [AppDates] (fallback aman bila simbol
  /// locale belum di-init).
  static String safeMonth(DateTime date, String lang) =>
      AppDates.pattern('MMMM', date, lang).toUpperCase();

  /// Nama periode terpilih dalam bahasa aktif.
  String _periodName(String lang) => AppStrings.get(_period, lang);

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    // Satu pemindaian periode → kategori + income + expense sekaligus
    // (sebelumnya 2x transactionsForPeriod + 2x fold per build).
    final periodTxs = fp.transactionsForPeriod(_period);
    final byCategory = <String, int>{};
    var periodIncome = 0;
    var periodExpense = 0;
    for (final t in periodTxs) {
      if (t.type == TransactionType.income) {
        periodIncome += t.amount;
      } else if (t.type == TransactionType.expense) {
        periodExpense += t.amount;
        byCategory[t.category] = (byCategory[t.category] ?? 0) + t.amount;
      }
    }
    final total = byCategory.values.fold(0, (a, b) => a + b);
    final entries = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final slices = <DonutSlice>[];
    for (var i = 0; i < entries.length; i++) {
      final fraction = total == 0 ? 0.0 : entries[i].value / total;
      slices.add(
        DonutSlice(
          fraction,
          AppColors.chartPalette[i % AppColors.chartPalette.length],
        ),
      );
    }
    final topEntry = entries.isEmpty ? null : entries.first;

    return Scaffold(
      appBar: AppHeader(title: AppStrings.get('analytics', lang)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Text(
                AppStrings.get('financialPulse', lang),
                style: AppTextStyles.headlineMd(),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _AnalyticsScreenState.safeMonth(DateTime.now(), lang),
                  style: AppTextStyles.labelCaps(),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: _handleExport,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.download,
                        size: 16,
                        color: AppColors.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        AppStrings.get('exportCsv', lang),
                        style: AppTextStyles.labelSm(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _periodSelector(lang),
          const SizedBox(height: 16),
          // Crossfade halus tiap ganti periode (kartu di bawah ikut berganti).
          AnimatedSwitcher(
            duration: AppMotion.durationFor(context, AppMotion.fast),
            switchInCurve: AppMotion.sheet,
            child: KeyedSubtree(
              key: ValueKey(_period),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _heroMetricCard(fp, periodIncome, periodExpense, lang),
                  const SizedBox(height: 16),
                  // Perbandingan vs bulan lalu (khusus periode bulan).
                  if (_period == 'month')
                    _momCard(periodIncome, periodExpense, fp, lang),
                  if (_period == 'month') const SizedBox(height: 16),
                  _breakdownCard(entries, slices, total, lang),
                  const SizedBox(height: 16),
                  _cashFlowBarCard(fp, lang, periodIncome, periodExpense),
                  const SizedBox(height: 16),
                  _insightsCard(
                    fp,
                    lang,
                    topEntry: topEntry,
                    periodExpense: periodExpense,
                    periodIncome: periodIncome,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.get('tapDetailsHint', lang),
            style: AppTextStyles.bodySm().copyWith(fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _handleExport() async {
    // CSV dibangun sinkron dari memori (cepat) — tanpa jeda buatan.
    final fp = context.read<FinanceProvider>();
    final csv = fp.exportCsv();
    final lang = context.read<AppSettingsProvider>().languageCode;
    if (!mounted) return;
    final isEmpty =
        csv.trim() == 'id,title,category,account,amount,type,date,tag,note';
    final preview =
        isEmpty ? '' : (csv.length > 1200 ? '${csv.substring(0, 1200)}…' : csv);
    // Hasil dialog pratinjau sengaja diabaikan (unawaited): hanya info.
    unawaited(
      showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('exportCsv', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                isEmpty ? AppStrings.get('csvEmpty', lang) : preview,
                style: AppTextStyles.bodySm().copyWith(fontSize: 10),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(AppStrings.get('close', lang)),
            ),
            if (!isEmpty)
              TextButton(
                onPressed: () async {
                  // Tangkap messenger sebelum gap async agar tidak
                  // memakai BuildContext lintas await.
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final file = await BackupService.saveCsvFile(csv);
                    await BackupService.shareFile(file);
                  } catch (_) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          AppStrings.get('csvSaveShareFailed', lang),
                        ),
                      ),
                    );
                  }
                },
                child: Text(AppStrings.get('saveAndShare', lang)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _periodSelector(String lang) {
    const codes = ['week', 'month', 'quarter', 'year'];
    return SlidingSegment(
      labels: codes.map((c) => AppStrings.get(c, lang)).toList(),
      selected: codes.indexOf(_period),
      onSelect: (i) => setState(() {
        _period = codes[i];
        _selectedSlice = null;
        _selectedBar = null;
        _chartCtrl.forward(from: 0);
      }),
      height: 40,
    );
  }

  Widget _heroMetricCard(
    FinanceProvider fp,
    int periodIncome,
    int periodExpense,
    String lang,
  ) {
    // Hari aktual periode (bukan 30/90 tetap) agar rata-rata harian akurat.
    final now = DateTime.now();
    final start = FinanceProvider.periodStartFor(_period, now);
    final days = now.difference(start).inDays.clamp(1, 366);
    final avgDaily = periodExpense / days;
    final savingsRatio = periodIncome == 0
        ? 0.0
        : ((periodIncome - periodExpense) / periodIncome) * 100;
    final net = periodIncome - periodExpense;
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
                      '${AppStrings.get('totalDisbursed', lang)} (${_periodName(lang).toUpperCase()})',
                      style: AppTextStyles.labelCaps(),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      MoneyFormat.format(periodExpense),
                      style: AppTextStyles.displayCurrencyMobile(),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (net >= 0 ? AppColors.tertiary : AppColors.error)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      net >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 14,
                      color: net >= 0 ? AppColors.tertiary : AppColors.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${net >= 0 ? MoneyFormat.signed(net, 'income') : MoneyFormat.signed(net, 'expense')} ${AppStrings.get('net', lang).toLowerCase()}',
                      style: AppTextStyles.tabularAmount(
                        color: net >= 0 ? AppColors.tertiary : AppColors.error,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _microMetric(
                  AppStrings.get('dailyAverage', lang),
                  Icons.calendar_today_outlined,
                  MoneyFormat.format(avgDaily.round()),
                  AppStrings.get('perDay', lang),
                  '${MoneyFormat.compact(periodIncome)} ${AppStrings.get('incomeLabel', lang).toLowerCase()}',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _microMetric(
                  AppStrings.get('savingsRatio', lang),
                  Icons.savings_outlined,
                  '${savingsRatio.toStringAsFixed(1)}%',
                  AppStrings.get('savedWord', lang),
                  AppStrings.fill('fromAmount', lang, {
                    'amount': MoneyFormat.format(periodIncome),
                  }),
                  valueColor:
                      savingsRatio >= 20 ? AppColors.tertiary : AppColors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Perbandingan bulan berjalan vs bulan lalu (khusus periode bulan):
  /// delta pemasukan + pengeluaran dengan panah naik/turun.
  /// Belanja naik = buruk (merah), pemasukan naik = baik (hijau).
  Widget _momCard(
    int periodIncome,
    int periodExpense,
    FinanceProvider fp,
    String lang,
  ) {
    final now = DateTime.now();
    final prev = DateTime(now.year, now.month - 1, 1);
    var pIncome = 0;
    var pExpense = 0;
    for (final t in fp.transactions) {
      if (t.date.year == prev.year && t.date.month == prev.month) {
        if (t.type == TransactionType.income) {
          pIncome += t.amount;
        } else if (t.type == TransactionType.expense) {
          pExpense += t.amount;
        }
      }
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
          Text(
            AppStrings.get('vsLastMonth', lang),
            style: AppTextStyles.labelCaps(),
          ),
          const SizedBox(height: 8),
          _momRow(
            AppStrings.get('incomeLabel', lang),
            periodIncome,
            pIncome,
            true,
          ),
          const SizedBox(height: 4),
          _momRow(
            AppStrings.get('expenseLabel', lang),
            periodExpense,
            pExpense,
            false,
          ),
        ],
      ),
    );
  }

  Widget _momRow(String label, int cur, int prev, bool goodWhenUp) {
    final delta = cur - prev;
    final good = goodWhenUp ? delta >= 0 : delta <= 0;
    final pct = prev <= 0
        ? null
        : '${delta >= 0 ? '+' : ''}${(delta / prev * 100).toStringAsFixed(0)}%';
    return Row(
      children: [
        Icon(
          delta >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
          size: 16,
          color: good ? AppColors.tertiary : AppColors.error,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(label, style: AppTextStyles.bodyMd())),
        Text(
          '${MoneyFormat.format(cur)}${pct == null ? '' : ' ($pct)'}',
          style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _microMetric(
    String label,
    IconData icon,
    String value,
    String unit,
    String sub, {
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: AppColors.outline),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: AppTextStyles.tabularAmountLg(color: valueColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Text(unit, style: AppTextStyles.bodySm()),
            ],
          ),
          Text(
            sub,
            style: AppTextStyles.bodySm(),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _breakdownCard(
    List<MapEntry<String, int>> entries,
    List<DonutSlice> slices,
    int total,
    String lang,
  ) {
    if (entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            AppStrings.get('noPeriodExpenses', lang),
            style: AppTextStyles.bodySm(),
          ),
        ),
      );
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
          Text(
            AppStrings.get('expenseBreakdown', lang),
            style: AppTextStyles.headlineSm(),
          ),
          Text(
            '${AppStrings.get('currentPeriod', lang)} • ${_periodName(lang)} — ${AppStrings.get('breakdownHint', lang)}',
            style: AppTextStyles.bodySm(),
          ),
          const SizedBox(height: 12),
          Center(
            child: SizedBox(
              width: 176,
              height: 176,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _chartCtrl,
                      builder: (_, __) => CustomPaint(
                        painter: DonutChartPainter(
                          slices: slices,
                          highlightIndex: _selectedSlice,
                          progress: _chartProgress(context),
                        ),
                        size: const Size(176, 176),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('TOTAL', style: AppTextStyles.labelCaps()),
                      AnimatedBalance(
                        value: total,
                        compact: true,
                        style: AppTextStyles.headlineMd(),
                      ),
                      Text(
                        AppStrings.fill('categoryCount', lang, {
                          'n': entries.length,
                        }),
                        style: AppTextStyles.bodySm(color: AppColors.tertiary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ...List.generate(entries.length, (i) {
            final e = entries[i];
            final pct = total == 0 ? 0 : (e.value / total * 100);
            final color =
                AppColors.chartPalette[i % AppColors.chartPalette.length];
            final isSel = _selectedSlice == i;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () => setState(() => _selectedSlice = isSel ? null : i),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isSel
                        ? AppColors.tertiary.withValues(alpha: 0.15)
                        : AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        isSel ? Border.all(color: AppColors.tertiary) : null,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.key,
                              style: AppTextStyles.bodyMd().copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${pct.toStringAsFixed(0)}% ${AppStrings.get('ofSpend', lang)}',
                              style: AppTextStyles.bodySm(),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        MoneyFormat.format(e.value),
                        style: AppTextStyles.tabularAmount(
                          color:
                              isSel ? AppColors.tertiary : AppColors.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (_selectedSlice != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.tertiary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    entries[_selectedSlice!].key.contains('Food')
                        ? Icons.restaurant
                        : Icons.circle,
                    color: AppColors.onTertiary,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${entries[_selectedSlice!].key} • ${(entries[_selectedSlice!].value / total * 100).toStringAsFixed(1)}% • ${MoneyFormat.format(entries[_selectedSlice!].value)}',
                      style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cashFlowBarCard(
    FinanceProvider fp,
    String lang,
    int periodIncome,
    int periodExpense,
  ) {
    final weeks = fp.weeklyCashFlowFor(_period);
    var maxVal = 1;
    for (final w in weeks) {
      maxVal = [
        maxVal,
        w['income']!,
        w['expense']!,
      ].reduce((a, b) => a > b ? a : b);
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.get('cashFlowInOut', lang),
                      style: AppTextStyles.headlineSm(),
                    ),
                    Text(
                      '${AppStrings.get('weeklyVolume', lang)} • ${_periodName(lang)}',
                      style: AppTextStyles.bodySm(),
                    ),
                  ],
                ),
              ),
              _legendDot(AppColors.tertiary, AppStrings.get('inShort', lang)),
              const SizedBox(width: 10),
              _legendDot(AppColors.onSurface, AppStrings.get('outShort', lang)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                AppStrings.get('chartMode', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SlidingSegment(
                  labels: [
                    AppStrings.get('barMode', lang),
                    AppStrings.get('areaMode', lang),
                  ],
                  selected: _cashMode,
                  onSelect: (i) => setState(() => _cashMode = i),
                  height: 32,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_cashMode == 0)
            Container(
              height: 170,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLowest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: List.generate(weeks.length, (i) {
                  final income = weeks[i]['income']!;
                  final expense = weeks[i]['expense']!;
                  final isSel = _selectedBar == i;
                  return Expanded(
                    child: InkWell(
                      onTap: () =>
                          setState(() => _selectedBar = isSel ? null : i),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppColors.tertiary.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (isSel)
                              Container(
                                margin: const EdgeInsets.only(bottom: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.tertiary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${MoneyFormat.compact(income)} / ${MoneyFormat.compact(expense)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: AppTextStyles.labelCaps(
                                    color: AppColors.onTertiary,
                                  ).copyWith(fontSize: 9),
                                ),
                              ),
                            Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _bar(
                                    income / maxVal,
                                    AppColors.tertiary,
                                    isSel,
                                  ),
                                  const SizedBox(width: 4),
                                  _bar(
                                    expense / maxVal,
                                    AppColors.onSurface,
                                    isSel,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'W${i + 1}',
                              style: AppTextStyles.labelCaps(
                                color: isSel
                                    ? AppColors.tertiary
                                    : AppColors.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          if (_cashMode == 1) _areaTrend(fp, lang),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${AppStrings.get('net', lang)} • ${_periodName(lang)}',
                  style: AppTextStyles.bodySm(),
                ),
                Text(
                  (periodIncome - periodExpense) >= 0
                      ? MoneyFormat.signed(
                          periodIncome - periodExpense,
                          'income',
                        )
                      : MoneyFormat.signed(
                          periodIncome - periodExpense,
                          'expense',
                        ),
                  style: AppTextStyles.tabularAmount(
                    color: (periodIncome - periodExpense) >= 0
                        ? AppColors.tertiary
                        : AppColors.error,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Kode rentang LineChart untuk periode analitik terpilih.
  String _trendRange() {
    switch (_period) {
      case 'week':
        return '7D';
      case 'quarter':
        return '3M';
      case 'year':
        return '1Y';
      case 'month':
      default:
        return '1M';
    }
  }

  /// Tampilan area (lulusan Lab): painter menerima nilai ternormalisasi
  /// 0..1, sedangkan angka Rupiah tampil sebagai teks — bukan di-clamp.
  Widget _areaTrend(FinanceProvider fp, String lang) {
    final trend = fp.cashFlowTrendFor(_trendRange());
    final raw = fp.cashFlowRawFor(_trendRange());
    final net = raw.fold(0, (a, b) => a + b);
    return Container(
      height: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            net >= 0
                ? MoneyFormat.signed(net, 'income')
                : MoneyFormat.signed(net, 'expense'),
            style: AppTextStyles.tabularAmount(
              color: AppColors.tertiary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _chartCtrl,
                builder: (_, __) => CustomPaint(
                  painter: LineChartPainter(
                    values: trend,
                    progress: _chartProgress(context),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.labelCaps()),
        ],
      );
  Widget _bar(double heightFraction, Color color, bool highlight) => Container(
        width: 14,
        height: 100 * heightFraction.clamp(0.02, 1.0).toDouble(),
        decoration: BoxDecoration(
          color: highlight ? AppColors.tertiary : color,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          border: highlight ? Border.all(color: AppColors.tertiary) : null,
        ),
      );

  Widget _insightsCard(
    FinanceProvider fp,
    String lang, {
    required MapEntry<String, int>? topEntry,
    required int periodIncome,
    required int periodExpense,
  }) {
    final top = topEntry;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.lightbulb_outline,
                size: 20,
                color: AppColors.tertiary,
              ),
              const SizedBox(width: 8),
              Text(
                '${AppStrings.get('habits', lang)} & ${AppStrings.get('projections', lang)}',
                style: AppTextStyles.headlineSm(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _insightTile(
            Icons.event_repeat,
            top == null
                ? AppStrings.get('noDataYet', lang)
                : '${AppStrings.get('topSpendTitle', lang)}: ${top.key}',
            top == null
                ? AppStrings.get('insightsEmpty', lang)
                : '${MoneyFormat.format(top.value)} — ${(periodExpense == 0 ? 0 : top.value / periodExpense * 100).toStringAsFixed(0)}% ${AppStrings.get('ofSpend', lang)}',
            iconColor: AppColors.onSurface,
          ),
          const SizedBox(height: 8),
          _insightTile(
            Icons.verified_outlined,
            fp.budgetProgress < 0.8
                ? AppStrings.get('budgetSafe', lang)
                : AppStrings.get('budgetWarn', lang),
            fp.budgetProgress < 0.8
                ? AppStrings.get('budgetSafeDesc', lang)
                : '${(fp.budgetProgress * 100).toStringAsFixed(0)}% ${AppStrings.get('ofAllowance', lang)}',
            // Anggaran bersifat bulanan: selalu cerminkan bulan berjalan
            // walau tab periode menampilkan kuartal/tahun (audit P3-E).
            trailing: AppDates.monthYearShort(DateTime.now(), lang),
            iconColor:
                fp.budgetProgress < 0.8 ? AppColors.tertiary : AppColors.error,
          ),
        ],
      ),
    );
  }

  Widget _insightTile(
    IconData icon,
    String title,
    String body, {
    Color? iconColor,
    String? trailing,
  }) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.surfaceBright.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child:
                  Icon(icon, size: 16, color: iconColor ?? AppColors.onSurface),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: AppTextStyles.bodyMd().copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child:
                              Text(trailing, style: AppTextStyles.labelCaps()),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(body, style: AppTextStyles.bodySm()),
                ],
              ),
            ),
          ],
        ),
      );
}
