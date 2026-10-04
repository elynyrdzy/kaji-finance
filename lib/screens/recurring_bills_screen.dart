import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../core/dialogs/app_confirm.dart';
import '../l10n/app_strings.dart';
import '../models/recurring_bill.dart';
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

/// Daftar + CRUD tagihan rutin & langganan Indonesia (offline-first).
/// Dark-only, nominal integer rupiah via [MoneyFormat].
/// Dibuka dari Pengaturan → Rencana → Tagihan Rutin.
/// Laporkan kegagalan storage (bukan penolakan validasi) ke user.
///
/// Top-level karena dipakai dua State berbeda: switch di daftar dan sheet
/// form. Pesannya sengaja BEDA dari "nama bentrok"/"data tak lengkap" —
/// di sini berarti data tak tersimpan sama sekali dan user harus mencoba
/// lagi, bukan memperbaiki isian.
void _reportSaveError(BuildContext context, String lang) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(AppStrings.get('recurringSaveFailed', lang)),
      backgroundColor: AppColors.errorContainer,
    ),
  );
}

class RecurringBillsScreen extends StatefulWidget {
  const RecurringBillsScreen({super.key});

  @override
  State<RecurringBillsScreen> createState() => _RecurringBillsScreenState();
}

class _RecurringBillsScreenState extends State<RecurringBillsScreen> {
  /// Toggle aktif dari daftar. Lemparan = gagal menulis ke storage; provider
  /// sudah rollback ke nilai lama, jadi cukup laporkan — switch akan
  /// kembali sendiri lewat rebuild.
  Future<void> _toggleActive(String id, bool v, String lang) async {
    final fp = context.read<FinanceProvider>();
    try {
      await fp.setRecurringBillActive(id, v);
    } catch (_) {
      if (!mounted) return;
      _reportSaveError(context, lang);
    }
  }

  bool _booted = false;
  bool _loadError = false;
  bool _showSearch = false;
  String _query = '';
  int _filter = 0; // 0 All · 1 Subs · 2 Utilities · 3 Auto-create
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  /// Urutan cold-start: load → processDue → refreshReminders.
  /// Gagal load = error card + retry (bukan skeleton selamanya).
  Future<void> _boot() async {
    if (!mounted) return;
    setState(() {
      _loadError = false;
    });
    try {
      final fp = context.read<FinanceProvider>();
      await fp.loadRecurringBills();
      if (!mounted) return;
      final res = await fp.processDueBills();
      await fp.refreshRecurringReminders();
      if (!mounted) return;
      setState(() => _booted = true);
      if (res.posted > 0) {
        final lang = context.read<AppSettingsProvider>().languageCode;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.fill('recurringPosted', lang, {'n': res.posted}),
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _booted = true;
        _loadError = true;
      });
    }
  }

  String _periodLabel(RecurringPeriod p, String lang) => switch (p) {
        RecurringPeriod.weekly => AppStrings.get('recurringWeekly', lang),
        RecurringPeriod.monthly => AppStrings.get('recurringMonthly', lang),
        RecurringPeriod.yearly => AppStrings.get('recurringYearly', lang),
      };

  /// Nama hari dari formatter tanggal app (satu sumber kebenaran untuk
  /// nama hari/bulan) — bukan daftar hardcoded per bahasa di widget.
  /// 3 Januari 2000 = Senin, jadi hari ke-`w` jatuh di tanggal `2 + w`.
  String _weekdayName(int weekday, String lang) =>
      AppDates.pattern('EEEE', DateTime(2000, 1, 2 + weekday), lang);

  String _dueLabel(RecurringBill b, String lang) {
    final now = DateTime.now();
    final n = b.daysUntilDue(now);
    final when = n == 0
        ? AppStrings.fill('recurringDueToday', lang)
        : AppStrings.fill('recurringDueIn', lang, {'n': n});
    final sched = switch (b.period) {
      RecurringPeriod.weekly => _weekdayName(b.dueDay.clamp(1, 7), lang),
      RecurringPeriod.monthly =>
        '${AppStrings.get('recurringDueDay', lang)} ${b.dueDay}',
      RecurringPeriod.yearly =>
        '${b.dueDay} ${AppDates.monthYearShort(DateTime(2000, b.dueMonth.clamp(1, 12), 1), lang)}',
    };
    final overdue = b.isOverdue(now) ? ' • ⚠' : '';
    return '${_periodLabel(b.period, lang)} • $sched • $when$overdue';
  }

  void _openForm({RecurringBill? existing}) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BillFormSheet(existing: existing),
    );
  }

  /// Hapus tagihan selalu lewat dialog konfirmasi bersama (destruktif,
  /// tanpa undo); dialog itu sendiri yang menjalankan penghapusan.
  Future<void> _confirmDelete(RecurringBill b, String lang) async {
    final fp = context.read<FinanceProvider>();
    await AppConfirm.runAsync(
      context,
      lang: lang,
      title: AppStrings.get('confirmDeleteTitle', lang),
      message: AppStrings.fill('recurringConfirmDelete', lang, {
        'name': b.name,
      }),
      confirmLabel: AppStrings.get('delete', lang),
      destructive: true,
      action: () => fp.removeRecurringBill(b.id),
      successMessage: AppStrings.get('recurringDeleted', lang),
      errorMessage: AppStrings.get('genericError', lang),
    );
  }

  // ---------- helpers: copy ringkas untuk header baru (tanpa kunci l10n baru) ----------

  String _t(String id, String en, String lang) => lang == 'id' ? id : en;

  int _monthlyEquiv(RecurringBill b) => switch (b.period) {
        RecurringPeriod.weekly => (b.amount * 52 / 12).round(),
        RecurringPeriod.monthly => b.amount,
        RecurringPeriod.yearly => (b.amount / 12).round(),
      };

  ({int count, int paidMonthly}) _paidStats(
    List<RecurringBill> active,
    DateTime now,
  ) {
    var c = 0;
    var m = 0;
    for (final b in active) {
      final occ = b.lastOccurrence(now);
      if (occ == null) continue;
      if (b.lastPostedKey == RecurringBill.periodKeyFor(b.period, occ)) {
        c++;
        m += _monthlyEquiv(b);
      }
    }
    return (count: c, paidMonthly: m);
  }

  bool _isSubs(RecurringBill b) {
    final c = b.category.toLowerCase();
    final n = b.name.toLowerCase();
    if (c.contains('entertain') || c.contains('hiburan')) return true;
    for (final k in [
      'netflix',
      'spotify',
      'disney',
      'youtube',
      'prime',
      'langganan',
      'subs',
      'gym',
      'aplikasi',
    ]) {
      if (n.contains(k)) return true;
    }
    return false;
  }

  bool _isUtil(RecurringBill b) {
    final c = b.category.toLowerCase();
    if (c.contains('bill') || c.contains('util') || c.contains('tagihan')) {
      return true;
    }
    final n = b.name.toLowerCase();
    for (final k in [
      'pln',
      'pdam',
      'indihome',
      'internet',
      'listrik',
      'air',
      'wifi',
      'bpjs',
      'kos',
      'kontrak',
    ]) {
      if (n.contains(k)) return true;
    }
    return false;
  }

  List<RecurringBill> _applyFilter(List<RecurringBill> all) {
    var list = all;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (b) =>
                b.name.toLowerCase().contains(q) ||
                b.wallet.toLowerCase().contains(q) ||
                b.category.toLowerCase().contains(q),
          )
          .toList();
    }
    switch (_filter) {
      case 1:
        return list.where(_isSubs).toList();
      case 2:
        return list.where(_isUtil).toList();
      case 3:
        return list.where((b) => b.autoCreate).toList();
      default:
        return list;
    }
  }

  String _relativeLabel(DateTime due, DateTime now, String lang) {
    final dd = DateTime(
      due.year,
      due.month,
      due.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (dd <= 0) return _t('Hari ini', 'Today', lang);
    if (dd == 1) return _t('Besok', 'Tomorrow', lang);
    return AppStrings.fill('recurringDueIn', lang, {'n': dd});
  }

  String _periodSuffix(RecurringBill b) => switch (b.period) {
        RecurringPeriod.weekly => '/ wk',
        RecurringPeriod.monthly => '/ mo',
        RecurringPeriod.yearly => '/ yr',
      };

  void _openActions(RecurringBill b, String lang) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      b.icon,
                      color: b.active
                          ? AppColors.tertiary
                          : AppColors.onSurfaceVariant,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyMd().copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${MoneyFormat.format(b.amount)} • ${_periodLabel(b.period, lang)}',
                          style: AppTextStyles.tabularAmount(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(_dueLabel(b, lang), style: AppTextStyles.bodySm()),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  title: Text(
                    AppStrings.get('recurringActive', lang),
                    style: AppTextStyles.bodyMd(),
                  ),
                  subtitle: Text(
                    b.active
                        ? _t(
                            'Menagih sesuai jadwal',
                            'Billing on schedule',
                            lang,
                          )
                        : _t('Nonaktif — dijeda', 'Inactive — paused', lang),
                    style: AppTextStyles.bodySm(),
                  ),
                  value: b.active,
                  activeThumbColor: AppColors.tertiary,
                  onChanged: (v) {
                    Navigator.pop(ctx);
                    unawaited(_toggleActive(b.id, v, lang));
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.onSurface,
                        side: const BorderSide(
                          color: AppColors.outlineVariant,
                          width: 0.8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openForm(existing: b);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: Text(AppStrings.get('edit', lang)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.errorContainer,
                        foregroundColor: AppColors.onErrorContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmDelete(b, lang);
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(AppStrings.get('delete', lang)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openScheduleSheet(
    List<RecurringBill> active,
    String lang,
    DateTime now,
  ) {
    AppMotion.tap();
    final sorted = List<RecurringBill>.of(active)
      ..sort((a, b) => a.daysUntilDue(now).compareTo(b.daysUntilDue(now)));
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Text(
                _t('Jadwal kalender', 'Calendar schedule', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 4),
              Text(
                _t('Tanggal jatuh tempo berikutnya', 'Next due dates', lang),
                style: AppTextStyles.bodySm(),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: sorted.length.clamp(0, 12),
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final b = sorted[i];
                    final d = b.nextDue(now);
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '${d.day}',
                                  style: AppTextStyles.headlineSm(),
                                ),
                                Text(
                                  AppDates.pattern('MMM', d, lang),
                                  style: AppTextStyles.labelCaps(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  b.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyMd().copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _relativeLabel(d, now, lang),
                                  style: AppTextStyles.bodySm(),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            MoneyFormat.format(b.amount),
                            style: AppTextStyles.tabularAmount(),
                          ),
                        ],
                      ),
                    );
                  },
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
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final now = DateTime.now();
    final bills = fp.recurringBills;
    final impacts =
        _booted ? fp.recurringBudgetImpacts() : const <RecurringBudgetImpact>[];

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppHeader(title: AppStrings.get('recurringBills', lang)),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primaryFixed,
        foregroundColor: AppColors.onPrimaryFixed,
        // Flat pill: elevation 0 removes both shadow and M3
        // elevation-tint (whitish glow) on the dark theme.
        elevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: Text(
          _t('Tambah Tagihan', 'Add Bill', lang),
          style: AppTextStyles.labelSm(
            color: AppColors.onPrimaryFixed,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Builder(
              builder: (_) {
                if (!_booted) return _loadingSkeleton();
                if (_loadError) return _errorState(lang);
                return RefreshIndicator(
                  color: AppColors.tertiary,
                  backgroundColor: AppColors.surfaceContainer,
                  onRefresh: _boot,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    children: [
                      _subHeader(bills, lang, now),
                      if (_showSearch) _searchField(lang),
                      const SizedBox(height: 12),
                      _committedCard(fp, bills, lang, now),
                      const SizedBox(height: 12),
                      if (bills.where((b) => b.active).isNotEmpty)
                        _nextUpcoming(bills, lang, now),
                      if (bills.where((b) => b.active).isNotEmpty)
                        const SizedBox(height: 20),
                      _obligationsSection(fp, bills, lang, now),
                      if (impacts.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _impactCard(fp, impacts, lang),
                      ],
                      const SizedBox(height: 16),
                      _microInsights(bills, lang),
                      if (bills.isEmpty) ...[
                        const SizedBox(height: 16),
                        _emptyState(lang),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Sub-header: title + LIVE + sub + search/calendar ----------

  Widget _subHeader(List<RecurringBill> bills, String lang, DateTime now) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        AppStrings.get('recurringBills', lang),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.headlineMd().copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'LIVE',
                        style: AppTextStyles.labelCaps(
                          color: AppColors.tertiary,
                        ).copyWith(fontSize: 10),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _t(
                    'Tagihan, langganan & jadwal bayar',
                    'Bills, subscriptions, and scheduled payments',
                    lang,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySm(),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Row(
            children: [
              _iconBtn(
                icon: _showSearch ? Icons.close : Icons.search,
                tooltip: AppStrings.get('search', lang),
                onTap: () {
                  setState(() {
                    _showSearch = !_showSearch;
                    if (!_showSearch) {
                      _query = '';
                      _searchCtrl.clear();
                    }
                  });
                },
              ),
              const SizedBox(width: 8),
              _iconBtn(
                icon: Icons.calendar_month_outlined,
                tooltip: _t('Jadwal', 'Schedule', lang),
                onTap: () => _openScheduleSheet(
                  bills.where((b) => b.active).toList(),
                  lang,
                  now,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: tooltip,
      child: InkWell(
        onTap: () {
          AppMotion.tap();
          onTap();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: AppColors.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _searchField(String lang) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: _searchCtrl,
        style: AppTextStyles.bodyMd(),
        decoration: InputDecoration(
          hintText: AppStrings.get('searchHint', lang),
          hintStyle: AppTextStyles.bodySm(),
          prefixIcon: const Icon(
            Icons.search,
            size: 18,
            color: AppColors.outline,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  // ---------- Committed Outflow ----------

  Widget _committedCard(
    FinanceProvider fp,
    List<RecurringBill> bills,
    String lang,
    DateTime now,
  ) {
    final active = bills.where((b) => b.active).toList();
    final total = fp.estimatedMonthlyRecurring;
    final stats = _paidStats(active, now);
    final scheduled = (total - stats.paidMonthly).clamp(0, 1 << 62);
    final progress =
        total <= 0 ? 0.0 : (stats.paidMonthly / total).clamp(0.0, 1.0);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _t('ARUS KELUAR TERIKAT', 'COMMITTED OUTFLOW', lang),
                      style: AppTextStyles.labelCaps(),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.schedule,
                            size: 12,
                            color: AppColors.tertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _t(
                              '${active.length} Aktif',
                              '${active.length} Active',
                              lang,
                            ),
                            style: AppTextStyles.labelSm(
                              color: AppColors.tertiary,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: AnimatedBalance(
                        value: total,
                        style: AppTextStyles.displayCurrencyMobile(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _t('/ bulan', '/ month', lang),
                      style: AppTextStyles.bodySm(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _t(
                    '${MoneyFormat.compact(total)} total kewajiban bulanan di semua akun',
                    '${MoneyFormat.compact(total)} total monthly obligations across all accounts',
                    lang,
                  ),
                  style: AppTextStyles.bodySm(),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _t('Progres Siklus', 'Cycle Progress', lang),
                      style: AppTextStyles.bodySm(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: MoneyFormat.format(stats.paidMonthly),
                              style: AppTextStyles.tabularAmount(),
                            ),
                            TextSpan(
                              text: ' / ${MoneyFormat.format(total)}',
                              style: AppTextStyles.tabularAmount(
                                color: AppColors.outline,
                              ),
                            ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AnimatedProgressBar(
                  value: progress,
                  color: AppColors.tertiary,
                  background: AppColors.surfaceContainerHighest,
                  height: 6,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: AppColors.tertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _t(
                              '${stats.count} lunas (${MoneyFormat.format(stats.paidMonthly)})',
                              '${stats.count} paid (${MoneyFormat.format(stats.paidMonthly)})',
                              lang,
                            ),
                            style: AppTextStyles.labelSm(
                              color: AppColors.tertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _t(
                          '${MoneyFormat.format(scheduled)} terjadwal',
                          '${MoneyFormat.format(scheduled)} scheduled',
                          lang,
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.labelSm(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Next Upcoming ----------

  Widget _nextUpcoming(List<RecurringBill> bills, String lang, DateTime now) {
    final active = bills.where((b) => b.active).toList()
      ..sort((a, b) => a.daysUntilDue(now).compareTo(b.daysUntilDue(now)));
    if (active.isEmpty) return const SizedBox.shrink();
    final b = active.first;
    final due = b.nextDue(now);
    final rel = _relativeLabel(due, now, lang);
    final dateStr = AppDates.pattern('d MMM', due, lang);
    return StaggerEntrance(
      index: 0,
      child: InkWell(
        onTap: () => _openActions(b, lang),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const _PulseDot(),
                      const SizedBox(width: 8),
                      Text(
                        _t('BERIKUTNYA', 'NEXT UPCOMING', lang),
                        style: AppTextStyles.labelCaps(
                          color: AppColors.tertiary,
                        ).copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.tertiary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$rel, $dateStr',
                      style: AppTextStyles.labelSm(color: AppColors.tertiary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(b.icon, color: AppColors.tertiary, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.headlineSm(),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${b.wallet} • ${b.autoCreate ? _t('Auto-bill', 'Auto-bill', lang) : _t('Pengingat', 'Reminder', lang)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodySm(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        MoneyFormat.format(b.amount),
                        style: AppTextStyles.tabularAmountLg(),
                      ),
                      if (b.autoCreate) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.bolt,
                              size: 13,
                              color: AppColors.tertiary,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              _t('Otomatis', 'Auto-create', lang),
                              style: AppTextStyles.labelSm(
                                color: AppColors.tertiary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Upcoming Obligations + filters + groups ----------

  Widget _obligationsSection(
    FinanceProvider fp,
    List<RecurringBill> bills,
    String lang,
    DateTime now,
  ) {
    final filtered = _applyFilter(bills);
    final activeFiltered = filtered.where((b) => b.active).toList()
      ..sort((a, b) => a.daysUntilDue(now).compareTo(b.daysUntilDue(now)));
    final inactiveFiltered = filtered.where((b) => !b.active).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final subsCount = bills.where(_isSubs).length;
    final utilCount = bills.where(_isUtil).length;
    final autoCount = bills.where((b) => b.autoCreate).length;

    // Kelompok tanggal dari yang aktif saja (mendatang).
    final groups = <DateTime, List<RecurringBill>>{};
    for (final b in activeFiltered) {
      final d = b.nextDue(now);
      final key = DateTime(d.year, d.month, d.day);
      groups.putIfAbsent(key, () => []).add(b);
    }
    final keys = groups.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _t('Kewajiban Mendatang', 'Upcoming Obligations', lang),
              style: AppTextStyles.headlineSm().copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              _t('${filtered.length} item', '${filtered.length} items', lang),
              style: AppTextStyles.labelCaps(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              _filterPill(
                label: AppStrings.get('all', lang),
                count: bills.length,
                selected: _filter == 0,
                onTap: () => setState(() => _filter = 0),
              ),
              const SizedBox(width: 8),
              _filterPill(
                label: _t('Langganan', 'Subscriptions', lang),
                count: subsCount,
                selected: _filter == 1,
                onTap: () => setState(() => _filter = 1),
              ),
              const SizedBox(width: 8),
              _filterPill(
                label: _t('Utilitas', 'Utilities', lang),
                count: utilCount,
                selected: _filter == 2,
                onTap: () => setState(() => _filter = 2),
              ),
              const SizedBox(width: 8),
              _filterPill(
                label: _t('Otomatis', 'Auto-create', lang),
                icon: Icons.bolt,
                count: autoCount,
                selected: _filter == 3,
                onTap: () => setState(() => _filter = 3),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (activeFiltered.isEmpty && inactiveFiltered.isEmpty)
          _noResults(lang)
        else ...[
          for (var gi = 0; gi < keys.length; gi++) ...[
            _groupHeader(keys[gi], groups[keys[gi]]!, lang, now),
            const SizedBox(height: 8),
            for (var bi = 0; bi < groups[keys[gi]]!.length; bi++)
              StaggerEntrance(
                index: (gi + bi).clamp(0, 7),
                key: ValueKey(groups[keys[gi]]![bi].id),
                child: _billRow(groups[keys[gi]]![bi], lang, now),
              ),
            if (gi != keys.length - 1) const SizedBox(height: 12),
          ],
          if (inactiveFiltered.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _t('NONAKTIF', 'INACTIVE', lang),
              style: AppTextStyles.labelCaps(),
            ),
            const SizedBox(height: 8),
            for (final b in inactiveFiltered)
              _billRow(b, lang, now, inactive: true),
          ],
        ],
      ],
    );
  }

  Widget _filterPill({
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    return InkWell(
      onTap: () {
        AppMotion.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceContainerHigh
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(999),
          border: selected
              ? Border.all(
                  color: AppColors.tertiary.withValues(alpha: 0.4),
                  width: 0.8,
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 13,
                color:
                    selected ? AppColors.tertiary : AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: AppTextStyles.labelSm(
                color:
                    selected ? AppColors.onSurface : AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: AppTextStyles.tabularAmount(
                  color: selected ? AppColors.tertiary : AppColors.outline,
                ).copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(
    DateTime date,
    List<RecurringBill> items,
    String lang,
    DateTime now,
  ) {
    final total = items.fold(0, (s, b) => s + _monthlyEquiv(b));
    final rel = _relativeLabel(date, now, lang);
    final dStr = AppDates.pattern('d MMM', date, lang);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              '$dStr • $rel'.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelCaps().copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            MoneyFormat.format(total),
            style: AppTextStyles.labelCaps().copyWith(
              fontFamily: 'JetBrainsMono',
              color: AppColors.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _billRow(
    RecurringBill b,
    String lang,
    DateTime now, {
    bool inactive = false,
  }) {
    final dimmed = inactive || !b.active;
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: dimmed
              ? Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.4),
                  width: 0.6,
                )
              : null,
        ),
        child: InkWell(
          onTap: () => _openActions(b, lang),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    b.icon,
                    size: 20,
                    color: dimmed ? AppColors.outline : AppColors.onSurface,
                  ),
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.headlineSm().copyWith(
                                color: dimmed
                                    ? AppColors.onSurfaceVariant
                                    : AppColors.onSurface,
                              ),
                            ),
                          ),
                          // Titik otomasi HANYA bila autoCreate && aktif.
                          if (b.autoCreate && b.active) ...[
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
                          if (b.isOverdue(now)) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.warning_amber,
                              size: 14,
                              color: AppColors.error,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              b.wallet,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodySm(),
                            ),
                          ),
                          Text(' • ', style: AppTextStyles.bodySm()),
                          if (b.autoCreate)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.bolt,
                                  size: 11,
                                  color: AppColors.tertiary,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  _t('Otomatis', 'Auto-create', lang),
                                  style: AppTextStyles.labelSm(
                                    color: AppColors.tertiary,
                                  ).copyWith(fontSize: 11),
                                ),
                              ],
                            )
                          else
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.notifications_outlined,
                                  size: 11,
                                  color: AppColors.outline,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  AppStrings.get('recurringReminderOnly', lang),
                                  style: AppTextStyles.labelSm(
                                    color: AppColors.outline,
                                  ).copyWith(fontSize: 11),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      MoneyFormat.format(b.amount),
                      style: AppTextStyles.tabularAmount(
                        color: dimmed
                            ? AppColors.onSurfaceVariant
                            : AppColors.onSurface,
                      ),
                    ),
                    Text(_periodSuffix(b), style: AppTextStyles.bodySm()),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Planned Budget Impact ----------

  Widget _impactCard(
    FinanceProvider fp,
    List<RecurringBudgetImpact> impacts,
    String lang,
  ) {
    // Gabung per kategori anggaran agar bar "Utilities Rp X / Rp Y" utuh.
    final grouped = <String, List<RecurringBudgetImpact>>{};
    for (final im in impacts) {
      grouped.putIfAbsent(im.budgetName, () => []).add(im);
    }
    final entries = grouped.entries.toList()
      ..sort(
        (a, b) =>
            b.value.first.projectedPct.compareTo(a.value.first.projectedPct),
      );
    final totalPct = fp.monthlyAllowance > 0
        ? (fp.estimatedMonthlyRecurring / fp.monthlyAllowance * 100)
            .toStringAsFixed(0)
        : null;
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.analytics_outlined,
                    size: 18,
                    color: AppColors.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _t('Dampak Anggaran', 'Planned Budget Impact', lang),
                      style: AppTextStyles.headlineSm().copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (totalPct != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$totalPct% Total',
                    style: AppTextStyles.tabularAmount(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: AppTextStyles.bodySm(color: AppColors.onSurfaceVariant),
              children: [
                TextSpan(
                  text: _t(
                    'Tagihan rutin akan memakai ',
                    'Your recurring bills will consume ',
                    lang,
                  ),
                ),
                TextSpan(
                  text: MoneyFormat.format(fp.estimatedMonthlyRecurring),
                  style: AppTextStyles.tabularAmount(),
                ),
                if (totalPct != null)
                  TextSpan(
                    text: ' ($totalPct%)',
                    style: AppTextStyles.tabularAmount(),
                  ),
                if (fp.monthlyAllowance > 0)
                  TextSpan(text: _t(' dari ', ' of ', lang)),
                if (fp.monthlyAllowance > 0)
                  TextSpan(
                    text: MoneyFormat.format(fp.monthlyAllowance),
                    style: AppTextStyles.tabularAmount(),
                  ),
                if (fp.monthlyAllowance > 0)
                  TextSpan(
                    text: _t(' uang bulanan.', ' monthly allowance.', lang),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < entries.take(5).length; i++)
            _impactRow(entries[i].key, entries[i].value, i, lang),
        ],
      ),
    );
  }

  Widget _impactRow(
    String budgetName,
    List<RecurringBudgetImpact> items,
    int idx,
    String lang,
  ) {
    final first = items.first;
    final sumBills = items.fold(0, (s, e) => s + e.billAmount);
    final projected = first.spent + sumBills;
    final pct = first.limit > 0 ? projected / first.limit : 0.0;
    final pctExisting = first.limit > 0 ? first.spent / first.limit : 0.0;
    final names = items.map((e) => e.billName).take(2).join(', ');
    final high = pct >= 0.8;
    final barColor = high ? AppColors.error : AppColors.tertiary;
    final dotColor = idx == 1
        ? AppColors.secondary
        : high
            ? AppColors.error
            : AppColors.tertiary;
    return Padding(
      padding: EdgeInsets.only(top: idx == 0 ? 4 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      budgetName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMd().copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: MoneyFormat.format(projected),
                      style: AppTextStyles.tabularAmount(),
                    ),
                    TextSpan(
                      text: ' / ${MoneyFormat.format(first.limit)}',
                      style: AppTextStyles.tabularAmount(
                        color: AppColors.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Gauge dua segmen: existing (abu) + tambahan (aksen).
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 6,
              color: AppColors.surfaceContainerHighest,
              child: Row(
                children: [
                  Flexible(
                    flex: (pctExisting.clamp(0.0, 1.0) * 1000).round(),
                    child: Container(color: AppColors.outlineVariant),
                  ),
                  Flexible(
                    flex: ((pct - pctExisting).clamp(0.0, 1.0) * 1000).round(),
                    child: Container(color: barColor),
                  ),
                  Flexible(
                    flex: ((1.0 - pct).clamp(0.0, 1.0) * 1000).round(),
                    child: const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  names,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.labelSm(color: AppColors.outline),
                ),
              ),
              const SizedBox(width: 8),
              high
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          size: 12,
                          color: AppColors.error,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${(pct * 100).toStringAsFixed(0)}% • ${_t('Mendekati batas', 'Approaching limit', lang)}',
                          style: AppTextStyles.labelSm(color: AppColors.error),
                        ),
                      ],
                    )
                  : Text(
                      '${(pct * 100).toStringAsFixed(0)}% ${_t('terpakai', 'used', lang)}',
                      style: AppTextStyles.labelSm(color: AppColors.outline),
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _microInsights(List<RecurringBill> bills, String lang) {
    final active = bills.where((b) => b.active).length;
    final auto = bills.where((b) => b.active && b.autoCreate).length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.auto_awesome_outlined,
            size: 20,
            color: AppColors.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: AppTextStyles.bodySm(),
                children: [
                  TextSpan(
                    text: _t('Otomasi cerdas: ', 'Smart Automation: ', lang),
                  ),
                  TextSpan(
                    text: '$auto ${_t('dari', 'of', lang)} $active',
                    style: AppTextStyles.bodySm(
                      color: AppColors.onSurface,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: _t(
                      ' pembayaran rutin otomatis mencatat di ledger saat jatuh tempo.',
                      ' recurring payments are configured to automatically log ledger entries on due dates.',
                      lang,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noResults(String lang) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const EmptyArt(icon: Icons.search_off_outlined, size: 32),
          const SizedBox(height: 8),
          Text(
            AppStrings.get('noResults', lang),
            style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String lang) {
    // Empty penuh (belum ada tagihan sama sekali) — CTA besar.
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const EmptyArt(icon: Icons.event_repeat, size: 36),
          const SizedBox(height: 8),
          Text(
            AppStrings.get('recurringEmpty', lang),
            style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            AppStrings.get('recurringEmptyDesc', lang),
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
              onPressed: () => _openForm(),
              icon: const Icon(
                Icons.add,
                color: AppColors.onTertiary,
                size: 18,
              ),
              label: Text(
                AppStrings.get('recurringNew', lang),
                style: AppTextStyles.labelSm(color: AppColors.onTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorState(String lang) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 32,
                color: AppColors.error,
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.get('loadError', lang),
                style: AppTextStyles.bodyMd().copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.tertiary,
                    foregroundColor: AppColors.onTertiary,
                  ),
                  onPressed: () {
                    setState(() => _booted = false);
                    _boot();
                  },
                  child: Text(_t('Coba lagi', 'Retry', lang)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _loadingSkeleton() {
    Widget box({required double h, double? w, double r = 12}) => Container(
          height: h,
          width: w,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(r),
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        box(h: 28, w: 200, r: 8),
        const SizedBox(height: 8),
        box(h: 14, w: 260, r: 6),
        const SizedBox(height: 16),
        box(h: 168),
        const SizedBox(height: 12),
        box(h: 120),
        const SizedBox(height: 16),
        box(h: 32, w: 220, r: 999),
        const SizedBox(height: 12),
        box(h: 72),
        const SizedBox(height: 8),
        box(h: 72),
        const SizedBox(height: 8),
        box(h: 72),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      duration: const Duration(milliseconds: 1600),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppColors.tertiary,
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: AppColors.tertiary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.tertiary.withValues(
                alpha: 0.35 + 0.35 * _c.value,
              ),
              blurRadius: 6 + 6 * _c.value,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet tambah/ubah tagihan (nama, nominal, periode, jatuh tempo,
/// kategori, dompet, auto-create vs reminder, aktif) + pilihan template.
///
/// Bentuk stepped 4 langkah sesuai referensi:
/// Step1 Basic (nama + nominal hero + shortcut + kategori + dompet),
/// Step2 Schedule (segmented + due-day + preview + annual),
/// Step3 Automation (radio Auto-create vs Reminder-only),
/// Step4 BudgetIntel (gauge).
class _BillFormSheet extends StatefulWidget {
  final RecurringBill? existing;
  const _BillFormSheet({this.existing});

  @override
  State<_BillFormSheet> createState() => _BillFormSheetState();
}

class _BillFormSheetState extends State<_BillFormSheet> {
  final _uuid = const Uuid();
  late final TextEditingController _name;
  final _nameFocus = FocusNode();

  /// Nominal dalam unit mata uang tampil (lihat [AppAmountPad]).
  late int _amount;

  /// Nominal tersimpan SEBAGAI BASIS, apa adanya seperti dari storage.
  ///
  /// Basis→tampil→basis HANYA identity kalau nominal tersimpan habis dibagi
  /// kurs. Untuk non-IDR itu tidak selalu: kurs 16.500, tersimpan 320.000
  /// → tampil 19 → kembali 313.500 (naik/turun 2 %). Karena [_amount] bertipe
  /// int, rndanya lossy. Jadi selama user tak menyentuh nominal, [_save]
  /// memakai nilai ini apa adanya — mengedit "jatuh tempo" saja tak boleh
  /// ikut mengubah nominal. Lihat [_amountEdited].
  late int _baseAmountOriginal;

  /// true begitu user menyentuh nominal lewat keypad/chip/Hapus.
  /// Menyimpan basis asli hanya berguna selama flag ini false.
  bool _amountEdited = false;

  late RecurringPeriod _period;
  late int _dueDay;
  late int _dueMonth;
  late String? _category;
  late String? _wallet;
  late bool _autoCreate;
  late bool _active;
  bool _notifyMe = true;

  /// Keypad tersembunyi sampai kartu nominal diketuk — lihat [_toggleAmount].
  bool _amountOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _amount = e == null ? 0 : MoneyFormat.fromBase(e.amount).round();
    _baseAmountOriginal = e?.amount ?? 0;
    _period = e?.period ?? RecurringPeriod.monthly;
    _dueDay = (e?.dueDay ?? 1).clamp(1, 31);
    _dueMonth = (e?.dueMonth ?? 1).clamp(1, 12);
    _category = e?.category;
    _wallet = e?.wallet;
    _autoCreate = e?.autoCreate ?? false;
    _active = e?.active ?? true;
    _nameFocus.addListener(_onNameFocus);
  }

  @override
  void dispose() {
    _nameFocus
      ..removeListener(_onNameFocus)
      ..dispose();
    _name.dispose();
    super.dispose();
  }

  /// Ketuk nama = pengguna sedang mengetik teks, jadi keypad angka menyingkir
  /// supaya keyboard perangkat dan keyboard app tak berebut ruang di sheet.
  void _onNameFocus() {
    if (_nameFocus.hasFocus) _closeAmount();
  }

  /// Buka/tutup keypad lewat kartu nominal. Membuka juga menutup keyboard
  /// perangkat: dua keyboard di sheet yang sama tidak punya ruang.
  void _toggleAmount() {
    final open = !_amountOpen;
    setState(() => _amountOpen = open);
    if (open) FocusScope.of(context).unfocus();
  }

  void _closeAmount() {
    if (!_amountOpen) return;
    setState(() => _amountOpen = false);
  }

  void _keypadPress(String digit) {
    final str = (_amount == 0 ? '' : '$_amount') + digit;
    // Digit yang tak muat di-drop, bukan listener, dan user diberi getaran
    // singkat — diam saja bikin keypad terasa macet (lihat
    // MoneyFormat.maxDisplayDigits).
    if (!MoneyFormat.displayDigitsAllowed(str.length)) {
      AppMotion.warn();
      return;
    }
    setState(() {
      _amount = int.parse(str);
      _amountEdited = true;
    });
  }

  void _backspace() {
    setState(() {
      final str = _amount.toString();
      _amount =
          str.length > 1 ? int.parse(str.substring(0, str.length - 1)) : 0;
      _amountEdited = true;
    });
  }

  void _adjust(int delta) => setState(() {
        _amount =
            (_amount + delta).clamp(0, MoneyFormat.maxDisplayAmount).toInt();
        _amountEdited = true;
      });

  void _clearAmount() => setState(() {
        _amount = 0;
        _amountEdited = true;
      });

  int _currentBase() => _amountEdited
      ? MoneyFormat.toBaseMinorUnits(_amount)
      : _baseAmountOriginal;

  Future<void> _save(String lang) async {
    final fp = context.read<FinanceProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (_saving) return;
    // Hanya konversi ulang bila user benar-benar menyentuh nominal.
    // Bila tidak, pakai basis asli apa adanya supaya mengedit field lain
    // (mis. hanya jatuh tempo) tak ikut menggeser nominal non-IDR.
    final amount = _currentBase();
    if (amount <= 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('validationAmount', lang))),
      );
      return;
    }
    setState(() => _saving = true);
    final bill = RecurringBill(
      id: widget.existing?.id ?? _uuid.v4(),
      name: _name.text.trim(),
      amount: amount,
      period: _period,
      dueDay: _period == RecurringPeriod.weekly
          ? _dueDay.clamp(1, 7)
          : _dueDay.clamp(1, 31),
      dueMonth: _dueMonth.clamp(1, 12),
      category: (_category ?? '').trim(),
      wallet: (_wallet ?? '').trim(),
      icon: widget.existing?.icon ?? Icons.receipt_long,
      autoCreate: _autoCreate,
      active: _active,
      lastPostedKey: widget.existing?.lastPostedKey,
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
    // `false` = ditolak validasi/duplikat. Lemparan = kegagalan storage,
    // sudah di-rollback provider — beide harus menghasilkan pesan berbeda.
    bool ok;
    try {
      ok = widget.existing == null
          ? await fp.addRecurringBill(bill)
          : await fp.updateRecurringBill(bill.id, bill);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _reportSaveError(context, lang);
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      AppMotion.success();
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.get(
              widget.existing == null ? 'recurringSaved' : 'recurringUpdated',
              lang,
            ),
          ),
        ),
      );
      return;
    }
    // Provider menolak bila data tak valid (nama/kategori/dompet kosong,
    // nominal 0) atau bila nama + periode bentrok.
    final invalid = !bill.isValid;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.get(
            invalid ? 'recurringInvalid' : 'recurringExists',
            lang,
          ),
        ),
      ),
    );
  }

  String _t(String id, String en, String lang) => lang == 'id' ? id : en;

  String _weekdayName(int w, String lang) =>
      AppDates.pattern('EEEE', DateTime(2000, 1, 2 + w), lang);

  String _ordinal(int d, String lang) {
    if (lang == 'id') return '$d';
    if (d >= 11 && d <= 13) return '${d}th';
    switch (d % 10) {
      case 1:
        return '${d}st';
      case 2:
        return '${d}nd';
      case 3:
        return '${d}rd';
      default:
        return '${d}th';
    }
  }

  String _scheduleSummary(String lang) {
    final day = _dueDay.clamp(1, _period == RecurringPeriod.weekly ? 7 : 31);
    switch (_period) {
      case RecurringPeriod.weekly:
        return _t(
          'Berulang tiap minggu • ${_weekdayName(day, lang)}',
          'Repeats every week on ${_weekdayName(day, lang)}',
          lang,
        );
      case RecurringPeriod.monthly:
        return _t(
          'Berulang tiap tanggal ${_ordinal(day, lang)}',
          'Repeats on the ${_ordinal(day, lang)} of every month',
          lang,
        );
      case RecurringPeriod.yearly:
        final m = AppDates.pattern('MMMM', DateTime(2000, _dueMonth, 1), lang);
        return _t(
          'Berulang tiap tahun • $day $m',
          'Repeats annually on $m ${_ordinal(day, lang)}',
          lang,
        );
    }
  }

  String _annualText() {
    final base = _currentBase();
    final annual = switch (_period) {
      RecurringPeriod.weekly => base * 52,
      RecurringPeriod.monthly => base * 12,
      RecurringPeriod.yearly => base,
    };
    return '${MoneyFormat.format(annual)} / yr';
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final settings = context.watch<AppSettingsProvider>();
    final lang = settings.languageCode;
    final categories = fp.allTransactionCategories
        .map((c) => c.name)
        .where((n) => n != 'All')
        .toSet()
        .toList()
      ..sort();
    final wallets = fp.wallets.map((w) => w.name).toList();
    if (_category != null &&
        !categories.contains(_category) &&
        widget.existing != null) {
      categories.add(_category!);
    }
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.94;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: EdgeInsets.only(bottom: insets),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              const SheetHandle(),
              _formHeader(lang),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _stepLabel(
                        _t('Detail Dasar', 'Basic Details', lang),
                        '1 / 4',
                        lang,
                      ),
                      const SizedBox(height: 8),
                      _nameCard(lang),
                      const SizedBox(height: 8),
                      AppAmountPad(
                        label: AppStrings.get('recurringAmount', lang),
                        amount: _amount,
                        currencyCode: settings.currencyCode,
                        lang: lang,
                        expanded: _amountOpen,
                        onToggleExpanded: _toggleAmount,
                        onKey: (k) {
                          // AppKeypad mengirim '000' sekaligus — urai per digit
                          // agar pagar maxDisplayDigits tetap per-digit.
                          final digits = k.replaceAll(RegExp(r'[^0-9]'), '');
                          if (digits.isEmpty) return;
                          for (var i = 0; i < digits.length; i++) {
                            _keypadPress(digits[i]);
                          }
                        },
                        onBackspace: _backspace,
                        onAdjust: _adjust,
                        onClear: _clearAmount,
                      ),
                      const SizedBox(height: 8),
                      _pickerCard(
                        icon: Icons.bolt,
                        iconBg: AppColors.tertiary.withValues(alpha: 0.14),
                        iconColor: AppColors.tertiary,
                        label: _t('KATEGORI', 'CATEGORY', lang),
                        value: (_category == null || _category!.isEmpty)
                            ? _t('Pilih kategori', 'Choose category', lang)
                            : _category!,
                        isPlaceholder: _category == null || _category!.isEmpty,
                        onTap: () => _pickCategory(categories, lang),
                      ),
                      const SizedBox(height: 8),
                      _pickerCard(
                        icon: Icons.account_balance_outlined,
                        iconBg: AppColors.surfaceContainerHigh,
                        iconColor: AppColors.onSurfaceVariant,
                        label: _t('AKUN PEMBAYARAN', 'PAYMENT ACCOUNT', lang),
                        value: (_wallet == null || _wallet!.isEmpty)
                            ? _t('Pilih dompet', 'Choose wallet', lang)
                            : _wallet!,
                        sub: _walletBalance(fp),
                        isPlaceholder: _wallet == null || _wallet!.isEmpty,
                        onTap: () => _pickWallet(fp, lang),
                      ),
                      if (wallets.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            AppStrings.get('createWalletFirst', lang),
                            style: AppTextStyles.bodySm(),
                          ),
                        ),
                      const SizedBox(height: 20),
                      _stepLabel(
                        _t('Jadwal & Siklus', 'Schedule & Cadence', lang),
                        '2 / 4',
                        lang,
                      ),
                      const SizedBox(height: 8),
                      _scheduleCard(fp, lang, settings.currencyCode),
                      const SizedBox(height: 20),
                      _stepLabel(
                        _t('Otomasi', 'Automation Semantics', lang),
                        '3 / 4',
                        lang,
                      ),
                      const SizedBox(height: 8),
                      _automationCard(lang),
                      const SizedBox(height: 20),
                      _stepLabel(
                        _t('Intel Anggaran', 'Budget Intelligence', lang),
                        '4 / 4',
                        lang,
                      ),
                      const SizedBox(height: 8),
                      _budgetIntelCard(fp, lang),
                      const SizedBox(height: 8),
                      _activeRow(lang),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              _stickySave(lang),
            ],
          ),
        ),
      ),
    );
  }

  Widget _formHeader(String lang) {
    final isNew = widget.existing == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.receipt_long,
              size: 16,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppStrings.get(isNew ? 'recurringNew' : 'recurringEdit', lang),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.headlineSm(),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : () => _save(lang),
            style: TextButton.styleFrom(
              backgroundColor: AppColors.surfaceContainerHigh,
              foregroundColor: AppColors.onSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(
              AppStrings.get('save', lang),
              style: AppTextStyles.labelSm(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepLabel(String title, String step, String lang) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.labelCaps().copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(step, style: AppTextStyles.bodySm()),
      ],
    );
  }

  Widget _nameCard(String lang) {
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
            _t('Nama Tagihan / Layanan', 'Bill Name / Service', lang),
            style: AppTextStyles.labelSm(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.router_outlined,
                  size: 20,
                  color: AppColors.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    style: AppTextStyles.bodyMd(),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: AppStrings.get('recurringNameHint', lang),
                      hintStyle: AppTextStyles.bodySm(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _walletBalance(FinanceProvider fp) {
    if (_wallet == null || _wallet!.isEmpty) return null;
    for (final w in fp.wallets) {
      if (w.name == _wallet) return '(${MoneyFormat.format(w.balance)})';
    }
    return null;
  }

  Widget _pickerCard({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String label,
    required String value,
    String? sub,
    required bool isPlaceholder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        AppMotion.tap();
        _closeAmount();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTextStyles.labelCaps()),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodyMd().copyWith(
                            fontWeight: FontWeight.w600,
                            color: isPlaceholder
                                ? AppColors.outline
                                : AppColors.onSurface,
                          ),
                        ),
                      ),
                      if (sub != null) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.tabularAmount(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.unfold_more, size: 20, color: AppColors.outline),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCategory(List<String> categories, String lang) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Text(
                AppStrings.get('recurringCategory', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final c = categories[i];
                    final sel = c == _category;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: sel
                          ? AppColors.surfaceContainerHigh
                          : AppColors.surfaceContainerLow,
                      title: Text(c, style: AppTextStyles.bodyMd()),
                      trailing: sel
                          ? const Icon(Icons.check, color: AppColors.tertiary)
                          : null,
                      onTap: () => Navigator.pop(ctx, c),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) setState(() => _category = picked);
  }

  Future<void> _pickWallet(FinanceProvider fp, String lang) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Text(
                AppStrings.get('recurringWallet', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              if (fp.wallets.isEmpty)
                Text(
                  AppStrings.get('createWalletFirst', lang),
                  style: AppTextStyles.bodySm(),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: fp.wallets.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, i) {
                      final w = fp.wallets[i];
                      final sel = w.name == _wallet;
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        tileColor: sel
                            ? AppColors.surfaceContainerHigh
                            : AppColors.surfaceContainerLow,
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            w.icon,
                            size: 18,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        title: Text(w.name, style: AppTextStyles.bodyMd()),
                        subtitle: Text(
                          MoneyFormat.format(w.balance),
                          style: AppTextStyles.tabularAmount(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        trailing: sel
                            ? const Icon(Icons.check, color: AppColors.tertiary)
                            : null,
                        onTap: () => Navigator.pop(ctx, w.name),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) setState(() => _wallet = picked);
  }

  // ---------- Step 2 ----------

  Widget _scheduleCard(FinanceProvider fp, String lang, String currencyCode) {
    final now = DateTime.now();
    final tmp = RecurringBill(
      id: 'preview',
      name: _name.text.trim().isEmpty ? '—' : _name.text.trim(),
      amount: _currentBase() <= 0
          ? MoneyFormat.toBaseMinorUnits(_amount)
          : _currentBase(),
      period: _period,
      dueDay: _period == RecurringPeriod.weekly
          ? _dueDay.clamp(1, 7)
          : _dueDay.clamp(1, 31),
      dueMonth: _dueMonth.clamp(1, 12),
      category: _category ?? '',
      wallet: _wallet ?? '',
      icon: Icons.receipt_long,
      createdAt: now,
    );
    final next = tmp.nextDue(now);
    final days = tmp.daysUntilDue(now);
    final when = days == 0
        ? AppStrings.fill('recurringDueToday', lang)
        : AppStrings.fill('recurringDueIn', lang, {'n': days});
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
            _t('Siklus Berulang', 'Recurrence Cycle', lang),
            style: AppTextStyles.labelSm(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SlidingSegment(
            labels: RecurringPeriod.values
                .map(
                  (p) => switch (p) {
                    RecurringPeriod.weekly => AppStrings.get(
                        'recurringWeekly',
                        lang,
                      ),
                    RecurringPeriod.monthly => AppStrings.get(
                        'recurringMonthly',
                        lang,
                      ),
                    RecurringPeriod.yearly => AppStrings.get(
                        'recurringYearly',
                        lang,
                      ),
                  },
                )
                .toList(),
            selected: _period.index,
            onSelect: (i) => setState(() {
              _period = RecurringPeriod.values[i];
              if (_period == RecurringPeriod.weekly) {
                _dueDay = _dueDay.clamp(1, 7);
              } else {
                if (_dueDay < 1) _dueDay = 1;
                if (_dueDay > 31) _dueDay = 31;
              }
            }),
          ),
          const SizedBox(height: 16),
          // Schedule fields hanya untuk frekuensi terpilih.
          if (_period == RecurringPeriod.weekly) _weekdayPills(lang),
          if (_period == RecurringPeriod.monthly) _daySlider(lang, max: 31),
          if (_period == RecurringPeriod.yearly) ...[
            _monthGrid(lang),
            const SizedBox(height: 12),
            _daySlider(lang, max: 31),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.event_repeat,
                        size: 18,
                        color: AppColors.tertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _scheduleSummary(lang),
                            style: AppTextStyles.bodyMd().copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(
                                Icons.schedule,
                                size: 14,
                                color: AppColors.tertiary,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '${_t('Jatuh tempo berikutnya:', 'Next payment due:', lang)} ${AppDates.dateShort(next, lang)} ($when)',
                                  style: AppTextStyles.bodySm(
                                    color: AppColors.tertiary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _t(
                          'Proyeksi tahunan',
                          'Projected annual outflow',
                          lang,
                        ),
                        style: AppTextStyles.labelSm(color: AppColors.outline),
                      ),
                      Text(_annualText(), style: AppTextStyles.tabularAmount()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekdayPills(String lang) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _t('Hari jatuh tempo', 'Due weekday', lang),
              style: AppTextStyles.labelSm(color: AppColors.onSurfaceVariant),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _weekdayName(_dueDay.clamp(1, 7), lang),
                style: AppTextStyles.tabularAmount(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(7, (i) {
            final d = i + 1;
            final sel = _dueDay == d;
            final short = AppDates.pattern(
              'EEE',
              DateTime(2000, 1, 2 + d),
              lang,
            );
            return InkWell(
              onTap: () => setState(() => _dueDay = d),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: sel
                      ? AppColors.tertiary.withValues(alpha: 0.16)
                      : AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(999),
                  border: sel
                      ? Border.all(
                          color: AppColors.tertiary.withValues(alpha: 0.5),
                        )
                      : null,
                ),
                child: Text(
                  short,
                  style: AppTextStyles.labelSm(
                    color:
                        sel ? AppColors.tertiary : AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _daySlider(String lang, {required int max}) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _t('Tanggal jatuh tempo', 'Due Day of Month', lang),
              style: AppTextStyles.labelSm(color: AppColors.onSurfaceVariant),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _t('Tgl $_dueDay', 'Day $_dueDay', lang),
                style: AppTextStyles.tabularAmountLg().copyWith(fontSize: 15),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: AppColors.tertiary,
            inactiveTrackColor: AppColors.surfaceContainerHighest,
            thumbColor: AppColors.primary,
            overlayColor: AppColors.tertiary.withValues(alpha: 0.15),
            trackHeight: 4,
          ),
          child: Slider(
            min: 1,
            max: max.toDouble(),
            divisions: max - 1,
            value: _dueDay.clamp(1, max).toDouble(),
            label: '$_dueDay',
            onChanged: (v) => setState(() => _dueDay = v.round()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '1st',
                style: AppTextStyles.tabularAmount(
                  color: AppColors.outline,
                ).copyWith(fontSize: 11),
              ),
              Text(
                '15th',
                style: AppTextStyles.tabularAmount(
                  color: AppColors.outline,
                ).copyWith(fontSize: 11),
              ),
              Text(
                '31st',
                style: AppTextStyles.tabularAmount(
                  color: AppColors.outline,
                ).copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _monthGrid(String lang) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.get('recurringDueMonth', lang),
          style: AppTextStyles.labelSm(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.4,
          children: List.generate(12, (i) {
            final m = i + 1;
            final sel = _dueMonth == m;
            final label = AppDates.pattern('MMM', DateTime(2000, m, 1), lang);
            return InkWell(
              onTap: () => setState(() => _dueMonth = m),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel
                      ? AppColors.tertiary.withValues(alpha: 0.16)
                      : AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                  border: sel
                      ? Border.all(
                          color: AppColors.tertiary.withValues(alpha: 0.5),
                        )
                      : null,
                ),
                child: Text(
                  label,
                  style: AppTextStyles.labelSm(
                    color:
                        sel ? AppColors.tertiary : AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  // ---------- Step 3 ----------

  Widget _automationCard(String lang) {
    return Column(
      children: [
        _autoOption(
          selected: _autoCreate,
          icon: '⚡',
          title: _t(
            'Buat transaksi otomatis',
            'Automatically create transaction',
            lang,
          ),
          desc: _period == RecurringPeriod.monthly
              ? _t(
                  'Tiap tanggal $_dueDay, potong dari ${_wallet?.isEmpty ?? true ? 'dompet' : _wallet} dan catat di ledger tanpa input manual.',
                  'On the $_dueDay, automatically deduct from ${_wallet?.isEmpty ?? true ? 'wallet' : _wallet} and record in ledger with zero manual input.',
                  lang,
                )
              : _t(
                  'Dibukukan otomatis saat jatuh tempo, tanpa input manual.',
                  'Posted automatically when due, with zero manual input.',
                  lang,
                ),
          onTap: () => setState(() => _autoCreate = true),
          extra: _autoCreate
              ? Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.notifications_active_outlined,
                            size: 18,
                            color: AppColors.tertiary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _t(
                              'Beri tahu saat tercatat',
                              'Notify me when auto-recorded',
                              lang,
                            ),
                            style: AppTextStyles.bodySm(
                              color: AppColors.onSurface,
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: _notifyMe,
                        activeThumbColor: AppColors.tertiary,
                        onChanged: (v) => setState(() => _notifyMe = v),
                      ),
                    ],
                  ),
                )
              : null,
          lang: lang,
        ),
        const SizedBox(height: 8),
        _autoOption(
          selected: !_autoCreate,
          icon: '🔔',
          title: AppStrings.get('recurringReminderOnly', lang),
          desc: _t(
            'Kirim notifikasi saat jatuh tempo. Kamu konfirmasi dan catat manual setelah bayar.',
            'Send a push notification on the due date. You confirm and record the payment manually when settled.',
            lang,
          ),
          onTap: () => setState(() => _autoCreate = false),
          lang: lang,
        ),
      ],
    );
  }

  Widget _autoOption({
    required bool selected,
    required String icon,
    required String title,
    required String desc,
    required VoidCallback onTap,
    required String lang,
    Widget? extra,
  }) {
    return InkWell(
      onTap: () {
        AppMotion.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceContainer
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(
                  color: AppColors.tertiary.withValues(alpha: 0.45),
                  width: 1,
                )
              : null,
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? AppColors.primary
                        : AppColors.surfaceContainerHigh,
                  ),
                  child: selected
                      ? Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.surface,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(icon, style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              title,
                              style: AppTextStyles.headlineSm(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(desc, style: AppTextStyles.bodySm()),
                    ],
                  ),
                ),
              ],
            ),
            if (extra != null) extra,
          ],
        ),
      ),
    );
  }

  // ---------- Step 4 ----------

  Widget _budgetIntelCard(FinanceProvider fp, String lang) {
    final cat = (_category ?? '').trim();
    if (cat.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          _t(
            'Pilih kategori untuk melihat dampak anggaran.',
            'Choose a category to see budget impact.',
            lang,
          ),
          style: AppTextStyles.bodySm(),
        ),
      );
    }
    BudgetCategoryMatch? match;
    for (final b in fp.budgets) {
      if (b.name.toLowerCase() == cat.toLowerCase()) {
        match = BudgetCategoryMatch(
          name: b.name,
          limit: b.limit,
          spent: fp.spentForBudget(b.name),
        );
        break;
      }
    }
    if (match == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.query_stats,
                size: 18,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _t('Analisis Dampak', 'Live Impact Analysis', lang),
                    style: AppTextStyles.headlineSm(),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _t(
                      'Belum ada anggaran "$cat". Tagihan tetap bisa disimpan.',
                      'No budget for "$cat" yet. The bill can still be saved.',
                      lang,
                    ),
                    style: AppTextStyles.bodySm(),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final add = _currentBase() <= 0
        ? MoneyFormat.toBaseMinorUnits(_amount)
        : _currentBase();
    final post = match.spent + add;
    final pctExist = match.limit > 0 ? match.spent / match.limit : 0.0;
    final pctAdd = match.limit > 0 ? add / match.limit : 0.0;
    final pctTotal = match.limit > 0 ? post / match.limit : 0.0;
    final onTrack = pctTotal < 0.8;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.query_stats,
                  size: 18,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t('Analisis Dampak', 'Live Impact Analysis', lang),
                      style: AppTextStyles.headlineSm(),
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        style: AppTextStyles.bodySm(
                          color: AppColors.onSurfaceVariant,
                        ),
                        children: [
                          TextSpan(
                            text: _t(
                              'Tagihan ini memakai ',
                              'Adding this bill will allocate ',
                              lang,
                            ),
                          ),
                          TextSpan(
                            text: MoneyFormat.format(add),
                            style: AppTextStyles.tabularAmount(),
                          ),
                          TextSpan(
                            text: _t(
                              ' untuk alokasi $cat.',
                              ' to your monthly $cat allocation.',
                              lang,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        _t('Pool Bulanan $cat', '$cat Monthly Pool', lang),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.labelSm(),
                      ),
                    ),
                    Text(
                      onTrack
                          ? _t(
                              '${(pctTotal * 100).toStringAsFixed(0)}% Aman',
                              '${(pctTotal * 100).toStringAsFixed(0)}% Used · On Track',
                              lang,
                            )
                          : _t(
                              '${(pctTotal * 100).toStringAsFixed(0)}% Hati-hati',
                              '${(pctTotal * 100).toStringAsFixed(0)}% Used · Watch out',
                              lang,
                            ),
                      style: AppTextStyles.labelSm(
                        color: onTrack ? AppColors.tertiary : AppColors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    height: 12,
                    color: AppColors.surfaceContainerHigh,
                    child: Row(
                      children: [
                        Flexible(
                          flex: (pctExist.clamp(0.0, 1.0) * 1000).round(),
                          child: Container(color: AppColors.outlineVariant),
                        ),
                        Flexible(
                          flex: (pctAdd.clamp(0.0, 1.0) * 1000).round(),
                          child: Container(color: AppColors.tertiary),
                        ),
                        Flexible(
                          flex:
                              ((1.0 - pctExist - pctAdd).clamp(0.0, 1.0) * 1000)
                                  .round(),
                          child: const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.tertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _t('Setelah tambah:', 'Post-addition:', lang),
                          style: AppTextStyles.bodySm(),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          MoneyFormat.format(post),
                          style: AppTextStyles.tabularAmount(),
                        ),
                      ],
                    ),
                    Text(
                      '${_t('Batas', 'Limit', lang)}: ${MoneyFormat.format(match.limit)}',
                      style: AppTextStyles.bodySm(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _activeRow(String lang) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          AppStrings.get('recurringActive', lang),
          style: AppTextStyles.bodyMd(),
        ),
        subtitle: Text(
          _active
              ? _t(
                  'Aktif menagih sesuai jadwal',
                  'Active — billing on schedule',
                  lang,
                )
              : _t(
                  'Nonaktif — dijeda, tetap tersimpan',
                  'Inactive — paused but kept',
                  lang,
                ),
          style: AppTextStyles.bodySm(),
        ),
        value: _active,
        activeThumbColor: AppColors.tertiary,
        onChanged: (v) => setState(() => _active = v),
      ),
    );
  }

  Widget _stickySave(String lang) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        border: Border(
          top: BorderSide(color: AppColors.surfaceContainerHigh, width: 0.8),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.onSurface,
                  foregroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saving ? null : () => _save(lang),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline, size: 20),
                label: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _t('Simpan Tagihan Rutin', 'Save Recurring Bill', lang),
                        style: AppTextStyles.headlineSm(
                          color: AppColors.surface,
                        ).copyWith(fontWeight: FontWeight.w700),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _t(
                'Tersimpan lokal · Didukung presisi ledger',
                'Encrypted locally · Backed by Ledger Precision',
                lang,
              ),
              style: AppTextStyles.bodySm().copyWith(fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class BudgetCategoryMatch {
  final String name;
  final int limit;
  final int spent;
  const BudgetCategoryMatch({
    required this.name,
    required this.limit,
    required this.spent,
  });
}
