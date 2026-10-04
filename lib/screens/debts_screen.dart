import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/dialogs/app_confirm.dart';
import '../l10n/app_strings.dart';
import '../models/debt_entry.dart';
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
import '../widgets/motion_kit.dart';

/// Mini-ledger Hutang–Piutang / Kasbon / Arisan.
///
/// Layout follows reference/debts_receivables.html (list) +
/// reference/debt_detail_payment.html (detail sheet):
/// TopContext → PositionOverview (Net + I-owe/To-receive + attention
/// banner) → NeedsAttention urgent card → FilterTabs + Sort → LedgerList
/// → FAB Add pill. Detail is a bottom-sheet stack: utility chips →
/// HeroCard → MetadataGrid 2x2 → PaymentDeck → History+Export →
/// Edit/Delete.
///
/// Behavior preserved (see finance_debts.dart + debt_entry.dart):
/// debtsSorted settled-last, totals excl settled, overdue/dueSoon(7d),
/// addDebt wallet link + overdraft guard, updateDebt validation,
/// deleteDebt unlink-not-delete, recordDebtPayment clamp + wallet
/// required + overdraft + FX-safe fill-remaining, transactionsForDebt,
/// remindDebtsDue, RefreshIndicator loadDebts, AppConfirm delete.
class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key});

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

enum _DebtFilter { all, owe, receive, attention }

class _DebtsScreenState extends State<DebtsScreen> {
  bool _loaded = false;
  bool _loadFailed = false;
  _DebtFilter _filter = _DebtFilter.all;
  bool _sortByAmount = false;
  // Inline search (same pattern as recurring bills): filters by counterparty.
  bool _showSearch = false;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await context.read<FinanceProvider>().loadDebts();
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loadFailed = true;
      });
    }
  }

  Future<void> _remind(FinanceProvider fp, String lang) async {
    final messenger = ScaffoldMessenger.of(context);
    final has = fp.overdueDebts().isNotEmpty || fp.debtsDueSoon().isNotEmpty;
    if (!has) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('debtRemindEmpty', lang))),
      );
      return;
    }
    await fp.remindDebtsDue(lang: lang);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.get('debtRemindSent', lang))),
    );
  }

  void _openAdd() {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _DebtFormSheet(),
    );
  }

  void _openDetail(DebtEntry d, {bool autoOpenPay = false}) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DebtDetailSheet(debtId: d.id, autoOpenPay: autoOpenPay),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final now = DateTime.now();
    final all = fp.debtsSorted();

    final overdue = fp.overdueDebts(now: now);
    final soon = fp.debtsDueSoon(now: now);
    final attentionIds = <String>{
      for (final d in overdue) d.id,
      for (final d in soon) d.id,
    };

    List<DebtEntry> filtered = switch (_filter) {
      _DebtFilter.all => all,
      _DebtFilter.owe =>
        all.where((d) => d.direction == DebtDirection.payable).toList(),
      _DebtFilter.receive =>
        all.where((d) => d.direction == DebtDirection.receivable).toList(),
      _DebtFilter.attention =>
        all.where((d) => attentionIds.contains(d.id)).toList(),
    };
    if (_sortByAmount) {
      filtered = List.of(filtered)
        ..sort((a, b) {
          if (a.isSettled != b.isSettled) return a.isSettled ? 1 : -1;
          return b.remaining.compareTo(a.remaining);
        });
    }
    // Inline search keeps settled-last / sort order, only narrows rows.
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      filtered = filtered
          .where((d) => d.counterparty.toLowerCase().contains(q))
          .toList();
    }

    final oweActive = all
        .where((d) => d.direction == DebtDirection.payable && !d.isSettled)
        .toList();
    final receiveActive = all
        .where((d) => d.direction == DebtDirection.receivable && !d.isSettled)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppHeader(title: AppStrings.get('debts', lang)),
      body: RefreshIndicator(
        onRefresh: () => fp.loadDebts(),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                _TopContext(
                  onRemind: () => _remind(fp, lang),
                  showSearch: _showSearch,
                  onToggleSearch: () => setState(() {
                    _showSearch = !_showSearch;
                    if (!_showSearch) {
                      _query = '';
                      _searchCtrl.clear();
                    }
                  }),
                  onOpenSort: () => _pickSort(lang),
                ),
                if (_showSearch) ...[
                  const SizedBox(height: 8),
                  _DebtSearchField(
                    controller: _searchCtrl,
                    lang: lang,
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ],
                const SizedBox(height: 16),
                _PositionCard(
                  now: now,
                  onViewAttention: () =>
                      setState(() => _filter = _DebtFilter.attention),
                ),
                const SizedBox(height: 20),
                if (!_loaded && !_loadFailed)
                  const _DebtSkeleton()
                else if (_loadFailed && all.isEmpty)
                  _LoadErrorCard(onRetry: _reload)
                else if (all.isEmpty)
                  _EmptyDebts(onAdd: _openAdd)
                else ...[
                  if (overdue.isNotEmpty) ...[
                    _NeedsAttention(
                      overdue: overdue,
                      now: now,
                      onOpen: (d) => _openDetail(d),
                      onPay: (d) => _openDetail(d, autoOpenPay: true),
                    ),
                    const SizedBox(height: 20),
                  ],
                  _FilterTabs(
                    filter: _filter,
                    allCount: all.length,
                    oweCount: all
                        .where((d) => d.direction == DebtDirection.payable)
                        .length,
                    receiveCount: all
                        .where((d) => d.direction == DebtDirection.receivable)
                        .length,
                    attentionCount: attentionIds.length,
                    lang: lang,
                    onSelect: (f) => setState(() => _filter = f),
                  ),
                  const SizedBox(height: 12),
                  _ListHeader(
                    lang: lang,
                    filter: _filter,
                    sortByAmount: _sortByAmount,
                    onSort: () => _pickSort(lang),
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    _NoFilterResult(
                      lang: lang,
                      onClear: () => setState(() {
                        _filter = _DebtFilter.all;
                        _query = '';
                        _searchCtrl.clear();
                      }),
                    )
                  else
                    ...filtered.asMap().entries.map(
                          (e) => StaggerEntrance(
                            index: e.key,
                            key: ValueKey(e.value.id),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _LedgerTile(
                                entry: e.value,
                                now: now,
                                onTap: () => _openDetail(e.value),
                              ),
                            ),
                          ),
                        ),
                  // Keep remind reachable at list end too (progressive).
                  if (oweActive.isNotEmpty || receiveActive.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      lang == 'en'
                          ? 'Settled records stay at the bottom.'
                          : 'Catatan lunas tetap di bawah.',
                      style: AppTextStyles.bodySm(),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'debts_add',
        backgroundColor: AppColors.primaryFixed,
        foregroundColor: AppColors.onPrimaryFixed,
        // Flat pill: elevation 0 removes both shadow and M3
        // elevation-tint (whitish glow) on the dark theme.
        elevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        icon: const Icon(Icons.add, size: 20),
        label: Text(
          AppStrings.get('debtAdd', lang),
          style: AppTextStyles.labelSm(color: AppColors.onPrimaryFixed),
        ),
        onPressed: _openAdd,
      ),
    );
  }

  Future<void> _pickSort(String lang) async {
    AppMotion.tap();
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          lang == 'en' ? 'Sort debts' : 'Urutkan hutang',
          style: AppTextStyles.headlineSm(),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.event_outlined,
                color: !_sortByAmount
                    ? AppColors.tertiary
                    : AppColors.onSurfaceVariant,
              ),
              title: Text(
                lang == 'en' ? 'Due date' : 'Jatuh tempo',
                style: AppTextStyles.bodyMd(),
              ),
              trailing: !_sortByAmount
                  ? const Icon(Icons.check, color: AppColors.tertiary)
                  : null,
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.sort_outlined,
                color: _sortByAmount
                    ? AppColors.tertiary
                    : AppColors.onSurfaceVariant,
              ),
              title: Text(
                lang == 'en' ? 'Largest remaining' : 'Sisa terbesar',
                style: AppTextStyles.bodyMd(),
              ),
              trailing: _sortByAmount
                  ? const Icon(Icons.check, color: AppColors.tertiary)
                  : null,
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.get('cancel', lang)),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _sortByAmount = picked);
  }
}

/// Top context + actions (reference: Ledger/Balances + search/tune).
///
/// Search toggles an inline field (filters by counterparty, same pattern
/// as recurring bills); tune opens sort; the bell keeps the due reminder.
class _TopContext extends StatelessWidget {
  final VoidCallback onRemind;
  final bool showSearch;
  final VoidCallback onToggleSearch;
  final VoidCallback onOpenSort;
  const _TopContext({
    required this.onRemind,
    required this.showSearch,
    required this.onToggleSearch,
    required this.onOpenSort,
  });

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lang == 'en' ? 'LEDGER / BALANCES' : 'BUKU BESAR / SALDO',
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 4),
              Text(
                lang == 'en' ? 'Debts & Receivables' : 'Hutang & Piutang',
                style: AppTextStyles.headlineMd(),
              ),
              const SizedBox(height: 4),
              Text(
                lang == 'en'
                    ? 'Track money owed and money you should receive'
                    : 'Lacak uang yang dipinjam dan yang harus diterima',
                style: AppTextStyles.bodySm(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TopIconButton(
              icon: showSearch ? Icons.close : Icons.search_outlined,
              label: AppStrings.get('search', lang),
              active: showSearch,
              onTap: onToggleSearch,
            ),
            const SizedBox(width: 8),
            _TopIconButton(
              icon: Icons.tune_outlined,
              label: lang == 'en' ? 'Sort debts' : 'Urutkan hutang',
              onTap: onOpenSort,
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: AppStrings.get('debtRemind', lang),
              child: InkWell(
                onTap: () {
                  AppMotion.tap();
                  onRemind();
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.notifications_outlined,
                    size: 19,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 40px top-context action (reference search/tune/bell).
class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _TopIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: () {
          AppMotion.tap();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active
                ? AppColors.surfaceContainerHigh
                : AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 19,
            color: active ? AppColors.onSurface : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Inline search field (same pattern as recurring bills).
class _DebtSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String lang;
  final ValueChanged<String> onChanged;
  const _DebtSearchField({
    required this.controller,
    required this.lang,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
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
        onChanged: onChanged,
      ),
    );
  }
}

/// Position overview: Net chip + I-owe / To-receive + attention banner.
class _PositionCard extends StatelessWidget {
  final DateTime now;
  final VoidCallback onViewAttention;

  const _PositionCard({required this.now, required this.onViewAttention});

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final payable = fp.totalPayableRemaining;
    final receivable = fp.totalReceivableRemaining;
    final net = receivable - payable;
    final netNegative = net < 0;
    final netLabel = net == 0
        ? MoneyFormat.format(0)
        : '${netNegative ? '-' : '+'}${MoneyFormat.format(net.abs())}';

    final oweCount = fp.debts
        .where((d) => d.direction == DebtDirection.payable && !d.isSettled)
        .length;
    final recCount = fp.debts
        .where((d) => d.direction == DebtDirection.receivable && !d.isSettled)
        .length;

    final overdue = fp.overdueDebts(now: now);
    final soon = fp.debtsDueSoon(now: now);
    final overdueSum = overdue.fold<int>(0, (s, d) => s + d.remaining);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  lang == 'en' ? 'POSITION OVERVIEW' : 'RINGKASAN POSISI',
                  style: AppTextStyles.labelCaps(),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color:
                            netNegative ? AppColors.error : AppColors.tertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${lang == 'en' ? 'Net' : 'Bersih'}: $netLabel',
                      style: AppTextStyles.tabularAmount(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (ctx, cons) {
              final narrow = cons.maxWidth < 360;
              final cards = [
                _SplitStat(
                  icon: Icons.arrow_outward,
                  iconColor: AppColors.error,
                  label: AppStrings.get('debtPayable', lang),
                  amount: payable,
                  sub: lang == 'en'
                      ? '$oweCount active payables'
                      : '$oweCount hutang aktif',
                ),
                _SplitStat(
                  icon: Icons.arrow_downward,
                  iconColor: AppColors.tertiary,
                  label: AppStrings.get('debtReceivable', lang),
                  amount: receivable,
                  sub: lang == 'en'
                      ? '$recCount active claims'
                      : '$recCount piutang aktif',
                ),
              ];
              if (narrow) {
                return Column(
                  children: [cards[0], const SizedBox(height: 8), cards[1]],
                );
              }
              return Row(
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 8),
                  Expanded(child: cards[1]),
                ],
              );
            },
          ),
          if (overdue.isNotEmpty || soon.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.crisis_alert_outlined,
                      size: 16,
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (overdue.isNotEmpty)
                            TextSpan(
                              text: lang == 'en'
                                  ? '${MoneyFormat.compact(overdueSum)} overdue'
                                  : '${MoneyFormat.compact(overdueSum)} lewat tenggat',
                              style: AppTextStyles.bodySm(
                                color: AppColors.error,
                              ).copyWith(fontWeight: FontWeight.w600),
                            ),
                          if (overdue.isNotEmpty && soon.isNotEmpty)
                            TextSpan(
                              text: ' · ',
                              style: AppTextStyles.bodySm(),
                            ),
                          if (soon.isNotEmpty)
                            TextSpan(
                              text: lang == 'en'
                                  ? '${soon.length} due this week'
                                  : '${soon.length} jatuh tempo minggu ini',
                              style: AppTextStyles.bodySm(),
                            ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      AppMotion.tap();
                      onViewAttention();
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      lang == 'en' ? 'VIEW' : 'LIHAT',
                      style: AppTextStyles.labelCaps(color: AppColors.tertiary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SplitStat extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final int amount;
  final String sub;

  const _SplitStat({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.amount,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.labelSm(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            MoneyFormat.format(amount),
            style: AppTextStyles.tabularAmountLg(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(sub, style: AppTextStyles.bodySm()),
        ],
      ),
    );
  }
}

/// Urgent card for the most overdue entry (left error accent).
class _NeedsAttention extends StatelessWidget {
  final List<DebtEntry> overdue;
  final DateTime now;
  final ValueChanged<DebtEntry> onOpen;
  final ValueChanged<DebtEntry> onPay;

  const _NeedsAttention({
    required this.overdue,
    required this.now,
    required this.onOpen,
    required this.onPay,
  });

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final sorted = List<DebtEntry>.of(overdue)
      ..sort((a, b) {
        final da = a.dueAt ?? DateTime(2100);
        final db = b.dueAt ?? DateTime(2100);
        return da.compareTo(db);
      });
    final top = sorted.first;
    // First linked tx category feeds the varied icon (existing data only).
    final topTxs = context.read<FinanceProvider>().transactionsForDebt(top.id);
    final String? topTxCategory =
        topTxs.isNotEmpty ? topTxs.first.category : null;
    final left = top.daysUntilDue(now) ?? 0;
    final overdueDays = left < 0 ? -left : 0;
    final pct = top.principal <= 0
        ? 0.0
        : (top.paidTotal / top.principal).clamp(0.0, 1.0);
    final pctLabel =
        '${(pct * 100).toStringAsFixed(pct * 100 % 1 == 0 ? 0 : 1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              lang == 'en' ? 'Needs attention' : 'Perlu perhatian',
              style: AppTextStyles.headlineSm(),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                lang == 'en'
                    ? '${overdue.length} overdue'
                    : '${overdue.length} lewat tenggat',
                style: AppTextStyles.labelCaps(color: AppColors.error),
              ),
            ),
            const Spacer(),
            Text(
              lang == 'en' ? 'Priority 1' : 'Prioritas 1',
              style: AppTextStyles.bodySm(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 4, color: AppColors.error),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              _iconForDebt(top, topTxCategory),
                              size: 20,
                              color: AppColors.onSurface,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  top.counterparty,
                                  style: AppTextStyles.headlineSm(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${_kindLabel(top.kind, lang)} · ${top.direction == DebtDirection.payable ? AppStrings.get('debtPayable', lang) : AppStrings.get('debtReceivable', lang)}',
                                  style: AppTextStyles.bodySm(),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              lang == 'en'
                                  ? '$overdueDays${'d'} overdue'
                                  : '$overdueDays h lewat',
                              style: AppTextStyles.labelCaps(
                                color: AppColors.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: Text(
                              MoneyFormat.format(top.remaining),
                              style: AppTextStyles.tabularAmountLg(
                                color: AppColors.error,
                              ),
                            ),
                          ),
                          Text(
                            '${lang == 'en' ? 'of' : 'dari'} ${MoneyFormat.format(top.principal)}',
                            style: AppTextStyles.tabularAmount(
                              color: AppColors.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Semantics(
                        label: '$pctLabel settled',
                        child: AnimatedProgressBar(
                          value: pct,
                          color: AppColors.error,
                          background: AppColors.surfaceContainerLowest,
                          height: 6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            lang == 'en'
                                ? '$pctLabel settled'
                                : '$pctLabel lunas',
                            style: AppTextStyles.bodySm(),
                          ),
                          const Spacer(),
                          Text(
                            '${MoneyFormat.format(top.paidTotal)} ${lang == 'en' ? 'paid' : 'dibayar'}',
                            style: AppTextStyles.bodySm(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryFixed,
                            foregroundColor: AppColors.onPrimaryFixed,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () => onPay(top),
                          icon: const Icon(Icons.payments_outlined, size: 18),
                          label: Text(
                            AppStrings.get('debtPayTitle', lang),
                            style: AppTextStyles.headlineSm(
                              color: AppColors.onPrimaryFixed,
                            ),
                          ),
                        ),
                      ),
                      // Tap card body opens detail too.
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: () => onOpen(top),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 4,
                          ),
                          child: Text(
                            lang == 'en' ? 'Open detail →' : 'Buka detail →',
                            style: AppTextStyles.labelSm(
                              color: AppColors.outline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterTabs extends StatelessWidget {
  final _DebtFilter filter;
  final int allCount;
  final int oweCount;
  final int receiveCount;
  final int attentionCount;
  final String lang;
  final ValueChanged<_DebtFilter> onSelect;

  const _FilterTabs({
    required this.filter,
    required this.allCount,
    required this.oweCount,
    required this.receiveCount,
    required this.attentionCount,
    required this.lang,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        _DebtFilter.all,
        lang == 'en' ? 'All ($allCount)' : 'Semua ($allCount)',
        false,
      ),
      (
        _DebtFilter.owe,
        '${AppStrings.get('debtPayable', lang)} ($oweCount)',
        false,
      ),
      (
        _DebtFilter.receive,
        '${AppStrings.get('debtReceivable', lang)} ($receiveCount)',
        false,
      ),
      (
        _DebtFilter.attention,
        lang == 'en'
            ? 'Needs attention ($attentionCount)'
            : 'Perlu perhatian ($attentionCount)',
        true,
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _FilterChip(
              label: items[i].$2,
              selected: filter == items[i].$1,
              dot: items[i].$3 && attentionCount > 0,
              onTap: () => onSelect(items[i].$1),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dot;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: () {
          AppMotion.tap();
          onTap();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surfaceContainerHigh
                : AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dot) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: AppTextStyles.labelSm(
                  color: selected
                      ? AppColors.onSurface
                      : AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListHeader extends StatelessWidget {
  final String lang;
  final _DebtFilter filter;
  final bool sortByAmount;
  final VoidCallback onSort;

  const _ListHeader({
    required this.lang,
    required this.filter,
    required this.sortByAmount,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final title = switch (filter) {
      _DebtFilter.all => lang == 'en' ? 'All debts' : 'Semua hutang',
      _DebtFilter.owe => AppStrings.get('debtPayable', lang),
      _DebtFilter.receive => AppStrings.get('debtReceivable', lang),
      _DebtFilter.attention =>
        lang == 'en' ? 'Needs attention' : 'Perlu perhatian',
    };
    return Row(
      children: [
        Text(title, style: AppTextStyles.headlineSm()),
        const Spacer(),
        InkWell(
          onTap: onSort,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${lang == 'en' ? 'Sort' : 'Urut'}: ${sortByAmount ? (lang == 'en' ? 'Largest' : 'Terbesar') : (lang == 'en' ? 'Due date' : 'Jatuh tempo')}',
                  style: AppTextStyles.bodySm(),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.expand_more,
                  size: 16,
                  color: AppColors.outline,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ledger article: 36px icon + name/sub + -Rp/+Rp + chip + progress.
class _LedgerTile extends StatelessWidget {
  final DebtEntry entry;
  final DateTime now;
  final VoidCallback onTap;

  const _LedgerTile({
    required this.entry,
    required this.now,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final d = entry;
    // First linked tx category feeds the varied icon (existing data only).
    final txsForIcon = context.read<FinanceProvider>().transactionsForDebt(
          d.id,
        );
    final String? txCategory =
        txsForIcon.isNotEmpty ? txsForIcon.first.category : null;
    final settled = d.isSettled;
    final overdue = d.isOverdue(now);
    final isPayable = d.direction == DebtDirection.payable;
    final pct =
        d.principal <= 0 ? 0.0 : (d.paidTotal / d.principal).clamp(0.0, 1.0);

    final status = _statusOf(d, now, lang);
    final sub = _subLabel(d, now, lang);
    final amountText = isPayable
        ? '-${MoneyFormat.format(d.remaining)}'
        : '+${MoneyFormat.format(d.remaining)}';
    final amountColor = settled
        ? AppColors.outline
        : overdue
            ? AppColors.error
            : isPayable
                ? AppColors.onSurface
                : AppColors.tertiary;
    final barColor = settled
        ? AppColors.tertiary
        : overdue
            ? AppColors.error
            : isPayable
                ? AppColors.primary
                : AppColors.tertiary;

    return Semantics(
      button: true,
      label: '${d.counterparty}, $sub, $amountText',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _iconForDebt(d, txCategory),
                      size: 18,
                      color:
                          isPayable ? AppColors.onSurface : AppColors.tertiary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.counterparty,
                          style: AppTextStyles.headlineSm(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          style: AppTextStyles.bodySm(
                            color: overdue && !settled
                                ? AppColors.error
                                : AppColors.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        amountText,
                        style: AppTextStyles.tabularAmount(color: amountColor),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          status.$1,
                          style: AppTextStyles.labelCaps(color: status.$2),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (d.paidTotal > 0 || !settled) ...[
                const SizedBox(height: 8),
                Semantics(
                  label: '${(pct * 100).toStringAsFixed(0)}% paid',
                  child: AnimatedProgressBar(
                    value: pct,
                    color: barColor,
                    background: AppColors.surfaceContainerLowest,
                    height: 4,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      isPayable
                          ? '${MoneyFormat.compact(d.paidTotal)} ${lang == 'en' ? 'paid' : 'dibayar'}'
                          : '${MoneyFormat.compact(d.paidTotal)} ${lang == 'en' ? 'received' : 'diterima'}',
                      style: AppTextStyles.bodySm(),
                    ),
                    const Spacer(),
                    Text(
                      '${lang == 'en' ? 'Total' : 'Total'} ${MoneyFormat.compact(d.principal)}',
                      style: AppTextStyles.bodySm(),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

(String, Color) _statusOf(DebtEntry d, DateTime now, String lang) {
  if (d.isSettled) {
    return (AppStrings.get('debtSettled', lang), AppColors.tertiary);
  }
  if (d.isOverdue(now)) {
    return (AppStrings.get('debtOverdue', lang), AppColors.error);
  }
  if (d.paidTotal > 0) {
    return (
      lang == 'en' ? 'Partially paid' : 'Dibayar sebagian',
      AppColors.tertiary,
    );
  }
  if (d.dueAt == null) {
    return (AppStrings.get('debtUnpaid', lang), AppColors.onSurfaceVariant);
  }
  final left = d.daysUntilDue(now) ?? 99;
  if (left <= 7) {
    return (lang == 'en' ? 'Upcoming' : 'Segera', AppColors.onSurfaceVariant);
  }
  return (lang == 'en' ? 'Active' : 'Aktif', AppColors.onSurfaceVariant);
}

String _subLabel(DebtEntry d, DateTime now, String lang) {
  final kind = _kindLabel(d.kind, lang);
  if (d.isSettled) return '$kind · ${AppStrings.get('debtSettled', lang)}';
  if (d.dueAt == null) {
    return d.direction == DebtDirection.payable
        ? '$kind · ${AppStrings.get('debtNoDue', lang)}'
        : '$kind · ${AppStrings.get('debtNoDue', lang)}';
  }
  final left = d.daysUntilDue(now) ?? 0;
  if (left < 0) {
    final n = -left;
    return lang == 'en'
        ? '$kind · Overdue $n day${n == 1 ? '' : 's'}'
        : '$kind · Lewat $n hari';
  }
  if (left == 0) {
    return lang == 'en' ? '$kind · Due today' : '$kind · Jatuh tempo hari ini';
  }
  final date = AppDates.dateShort(d.dueAt!, lang);
  return lang == 'en'
      ? '$kind · Due in $left days ($date)'
      : '$kind · $left hari lagi ($date)';
}

IconData _iconForKind(DebtKind k) => switch (k) {
      DebtKind.kasbon => Icons.storefront_outlined,
      DebtKind.arisan => Icons.groups_outlined,
      DebtKind.debt => Icons.handshake_outlined,
    };

/// Varied ledger icon from data that already exists: counterparty keywords
/// + first linked transaction category (no new model columns).
/// Falls back to [_iconForKind] when nothing matches.
IconData _iconForDebt(DebtEntry d, String? txCategory) {
  final hay = '${d.counterparty} ${txCategory ?? ''}'.toLowerCase();
  bool hasAny(List<String> keys) => keys.any(hay.contains);
  if (hasAny(const [
    'warung',
    'toko',
    'pasar',
    'minimarket',
    'alfamart',
    'indomaret',
    'kelontong',
    'kantin',
    'belanja',
    'kuliner',
    'makan',
    'food',
    'grocery',
    'shop',
    'store',
  ])) {
    return Icons.shopping_bag_outlined;
  }
  if (hasAny(const [
    'motor',
    'bengkel',
    'honda',
    'yamaha',
    'vespa',
    'mobil',
    'service',
    'sparepart',
    'otomotif',
  ])) {
    return Icons.two_wheeler_outlined;
  }
  if (hasAny(const [
    'laptop',
    'macbook',
    'komputer',
    'computer',
    'gadget',
    'handphone',
    'kantor',
    'kerja',
    'freelance',
  ])) {
    return Icons.laptop_mac_outlined;
  }
  if (hasAny(const ['arisan', ' rt ', 'komunitas', 'koperasi', 'kelompok'])) {
    return Icons.groups_outlined;
  }
  return _iconForKind(d.kind);
}

/// Short honest ref from the real ledger id (never invented).
/// Returns '-' when there is no id to show.
String _shortRef(String id) {
  final s = id.trim();
  if (s.isEmpty) return '-';
  final tail = s.length <= 4 ? s : s.substring(s.length - 4);
  return 'Ref #$tail';
}

String _kindLabel(DebtKind k, String lang) {
  switch (k) {
    case DebtKind.kasbon:
      return AppStrings.get('debtKindKasbon', lang);
    case DebtKind.arisan:
      return AppStrings.get('debtKindArisan', lang);
    case DebtKind.debt:
      return AppStrings.get('debtKindDebt', lang);
  }
}

class _DebtSkeleton extends StatelessWidget {
  const _DebtSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 120,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 10,
                        width: 180,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh.withValues(
                            alpha: 0.6,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          height: 4,
                          color: AppColors.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LoadErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
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
            style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton(
              onPressed: () {
                AppMotion.tap();
                onRetry();
              },
              child: Text(lang == 'en' ? 'Retry' : 'Coba lagi'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDebts extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyDebts({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const EmptyArt(icon: Icons.handshake_outlined, size: 36),
          const SizedBox(height: 8),
          Text(
            AppStrings.get('debtEmpty', lang),
            style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            AppStrings.get('debtEmptyDesc', lang),
            style: AppTextStyles.bodySm(),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryFixed,
                foregroundColor: AppColors.onPrimaryFixed,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              onPressed: onAdd,
              icon: const Icon(
                Icons.add,
                color: AppColors.onPrimaryFixed,
                size: 18,
              ),
              label: Text(
                AppStrings.get('debtAdd', lang),
                style: AppTextStyles.labelSm(color: AppColors.onPrimaryFixed),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFilterResult extends StatelessWidget {
  final String lang;
  final VoidCallback onClear;
  const _NoFilterResult({required this.lang, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.search_off_outlined,
            color: AppColors.outline,
            size: 28,
          ),
          const SizedBox(height: 8),
          Text(
            AppStrings.get('noResults', lang),
            style: AppTextStyles.bodyMd(),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              AppMotion.tap();
              onClear();
            },
            child: Text(AppStrings.get('clearFilter', lang)),
          ),
        ],
      ),
    );
  }
}

/// Form tambah / ubah entry (bottom-sheet r20 + SheetHandle).
///
/// Create uses addDebt (wallet link + overdraft guard in provider).
/// Edit uses updateDebt (principal >= paidTotal, name non-empty).
/// Direction/kind are create-only: provider updateDebt has no
/// direction/kind params, so edit shows them read-only.
class _DebtFormSheet extends StatefulWidget {
  final DebtEntry? existing;
  const _DebtFormSheet({this.existing});

  @override
  State<_DebtFormSheet> createState() => _DebtFormSheetState();
}

class _DebtFormSheetState extends State<_DebtFormSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _noteCtrl;
  final _nameFocus = FocusNode();
  final _noteFocus = FocusNode();

  int _rawAmount = 0;
  DebtDirection _direction = DebtDirection.payable;
  DebtKind _kind = DebtKind.debt;
  // Ledger category for the principal tx (create-only). Null = auto
  // (provider defaults to Hutang/Piutang by direction).
  String? _txCategory;
  late DateTime _borrowedAt;
  DateTime? _dueAt;
  String? _wallet;

  bool _amountOpen = false;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.counterparty ?? '');
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    if (e != null) {
      _direction = e.direction;
      _kind = e.kind;
      _borrowedAt = e.borrowedAt;
      _dueAt = e.dueAt;
      _rawAmount = MoneyFormat.fromBase(e.principal).round();
    } else {
      _borrowedAt = DateTime.now();
    }
    _nameFocus.addListener(_onTextFocus);
    _noteFocus.addListener(_onTextFocus);
  }

  @override
  void dispose() {
    _nameFocus
      ..removeListener(_onTextFocus)
      ..dispose();
    _noteFocus
      ..removeListener(_onTextFocus)
      ..dispose();
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onTextFocus() {
    if (_nameFocus.hasFocus || _noteFocus.hasFocus) _closeAmount();
  }

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
    final str = (_rawAmount == 0 ? '' : '$_rawAmount') + digit;
    if (!MoneyFormat.displayDigitsAllowed(str.length)) {
      AppMotion.warn();
      return;
    }
    setState(() => _rawAmount = int.parse(str));
  }

  void _backspace() {
    setState(() {
      final str = _rawAmount.toString();
      _rawAmount =
          str.length > 1 ? int.parse(str.substring(0, str.length - 1)) : 0;
    });
  }

  void _adjust(int delta) => setState(
        () => _rawAmount =
            (_rawAmount + delta).clamp(0, MoneyFormat.maxDisplayAmount).toInt(),
      );

  void _clearAmount() => setState(() => _rawAmount = 0);

  Future<void> _pickDate({required bool isDue}) async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final picked = await showDatePicker(
      context: context,
      initialDate: isDue ? (_dueAt ?? DateTime.now()) : _borrowedAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: AppStrings.get(isDue ? 'debtDueAt' : 'debtBorrowedAt', lang),
    );
    if (picked == null) return;
    setState(() {
      if (isDue) {
        _dueAt = picked;
      } else {
        _borrowedAt = picked;
        if (_dueAt != null &&
            _dueAt!.isBefore(DateTime(picked.year, picked.month, picked.day))) {
          _dueAt = null;
        }
      }
    });
  }

  Future<void> _save() async {
    final fp = context.read<FinanceProvider>();
    final lang = context.read<AppSettingsProvider>().languageCode;
    final messenger = ScaffoldMessenger.of(context);
    if (_saving) return;
    final amount = MoneyFormat.toBaseMinorUnits(_rawAmount);
    if (amount <= 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('validationAmount', lang))),
      );
      return;
    }
    setState(() => _saving = true);
    if (_editing) {
      final ok = await fp.updateDebt(
        widget.existing!.id,
        counterparty: _nameCtrl.text,
        principal: amount,
        borrowedAt: _borrowedAt,
        dueAt: _dueAt,
        clearDueAt: _dueAt == null,
        note: _noteCtrl.text,
        clearNote: _noteCtrl.text.trim().isEmpty,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (!ok) {
        messenger.showSnackBar(
          SnackBar(content: Text(AppStrings.get('genericError', lang))),
        );
        return;
      }
      AppMotion.success();
      Navigator.pop(context);
      return;
    }
    final id = await fp.addDebt(
      counterparty: _nameCtrl.text,
      direction: _direction,
      kind: _kind,
      amount: amount,
      borrowedAt: _borrowedAt,
      dueAt: _dueAt,
      note: _noteCtrl.text,
      wallet: _wallet,
      txCategory: _txCategory,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (id == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('debtCreateFailed', lang))),
      );
      return;
    }
    AppMotion.success();
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.get('debtCreated', lang))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final settings = context.watch<AppSettingsProvider>();
    final lang = settings.languageCode;
    final currencyCode = settings.currencyCode;
    final insetsBottom = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.94;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: EdgeInsets.only(bottom: insetsBottom),
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
                      _FormEyebrow(
                        label: lang == 'en' ? 'Direction' : 'Arah',
                        trailing: _editing
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.lock_outline,
                                    size: 12,
                                    color: AppColors.outline,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    lang == 'en' ? 'Locked' : 'Terkunci',
                                    style: AppTextStyles.labelCaps(),
                                  ),
                                ],
                              )
                            : null,
                      ),
                      const SizedBox(height: 8),
                      _directionSection(lang),
                      const SizedBox(height: 6),
                      Text(
                        _editing
                            ? (lang == 'en'
                                ? 'Direction and type are locked after creation.'
                                : 'Arah dan jenis terkunci setelah dibuat.')
                            : (lang == 'en'
                                ? 'Choose direction first — who owes whom.'
                                : 'Pilih arah dulu — siapa berhutang ke siapa.'),
                        style: AppTextStyles.bodySm(),
                      ),
                      const SizedBox(height: 16),
                      _FormEyebrow(label: lang == 'en' ? 'Type' : 'Jenis'),
                      const SizedBox(height: 8),
                      _typeSection(lang),
                      const SizedBox(height: 16),
                      _FormEyebrow(
                        label: AppStrings.get(
                          'debtCounterparty',
                          lang,
                        ).toUpperCase(),
                      ),
                      const SizedBox(height: 8),
                      _partyField(lang),
                      const SizedBox(height: 16),
                      _FormEyebrow(
                        label: AppStrings.get(
                          'debtPrincipal',
                          lang,
                        ).toUpperCase(),
                        trailing: Text(
                          _direction == DebtDirection.payable
                              ? (lang == 'en' ? 'I owe' : 'Saya berhutang')
                              : (lang == 'en' ? 'Owed to me' : 'Piutang saya'),
                          style: AppTextStyles.labelCaps(
                            color: _direction == DebtDirection.payable
                                ? AppColors.onSurfaceVariant
                                : AppColors.tertiary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _amountHero(lang, currencyCode),
                      if (!_editing) ...[
                        const SizedBox(height: 16),
                        _FormEyebrow(
                          label: lang == 'en' ? 'Ledger link' : 'Tautan ledger',
                        ),
                        const SizedBox(height: 8),
                        _ledgerLinkGroup(fp, lang),
                      ],
                      const SizedBox(height: 16),
                      _FormEyebrow(
                        label: lang == 'en'
                            ? 'Schedule & note'
                            : 'Jadwal & catatan',
                      ),
                      const SizedBox(height: 8),
                      _scheduleGroup(lang),
                      if (_editing) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.info_outline,
                              size: 14,
                              color: AppColors.outline,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                lang == 'en'
                                    ? 'Paid so far: ${MoneyFormat.format(widget.existing!.paidTotal)} — principal cannot go below this.'
                                    : 'Sudah dibayar: ${MoneyFormat.format(widget.existing!.paidTotal)} — nominal tak boleh di bawah ini.',
                                style: AppTextStyles.bodySm(),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _iconForKind(_kind),
              size: 18,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _editing
                      ? (lang == 'en' ? 'Edit terms' : 'Ubah ketentuan')
                      : AppStrings.get('debtAdd', lang),
                  style: AppTextStyles.headlineSm(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _editing
                      ? (lang == 'en'
                          ? 'Adjust amount, dates & note'
                          : 'Sesuaikan nominal, tanggal & catatan')
                      : (lang == 'en'
                          ? 'New obligation in the ledger'
                          : 'Kewajiban baru di buku besar'),
                  style: AppTextStyles.bodySm(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => Navigator.pop(context),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.close,
                size: 18,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _directionSection(String lang) {
    if (_editing) {
      final label = _direction == DebtDirection.payable
          ? AppStrings.get('debtPayable', lang)
          : AppStrings.get('debtReceivable', lang);
      final icon = _direction == DebtDirection.payable
          ? Icons.arrow_outward
          : Icons.arrow_downward;
      final iconColor = _direction == DebtDirection.payable
          ? AppColors.onSurfaceVariant
          : AppColors.tertiary;
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    lang == 'en'
                        ? 'Locked after creation'
                        : 'Terkunci setelah dibuat',
                    style: AppTextStyles.bodySm(),
                  ),
                ],
              ),
            ),
            const Icon(Icons.lock_outline, size: 16, color: AppColors.outline),
          ],
        ),
      );
    }
    return SlidingSegment(
      labels: [
        AppStrings.get('debtPayable', lang),
        AppStrings.get('debtReceivable', lang),
      ],
      selected: _direction == DebtDirection.payable ? 0 : 1,
      height: 40,
      onSelect: (i) {
        _closeAmount();
        setState(
          () => _direction =
              i == 0 ? DebtDirection.payable : DebtDirection.receivable,
        );
      },
    );
  }

  Widget _typeSection(String lang) {
    return Row(
      children: [
        for (var i = 0; i < DebtKind.values.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _ObligationTypeChip(
              icon: _iconForKind(DebtKind.values[i]),
              label: _kindLabel(DebtKind.values[i], lang),
              selected: _kind == DebtKind.values[i],
              enabled: !_editing,
              onTap: () {
                _closeAmount();
                setState(() => _kind = DebtKind.values[i]);
              },
              onLocked: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      lang == 'en'
                          ? 'Locked after creation.'
                          : 'Terkunci setelah dibuat.',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _partyField(String lang) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _iconForKind(_kind),
              size: 18,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _nameCtrl,
              focusNode: _nameFocus,
              style: AppTextStyles.bodyMd(),
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: AppStrings.get('debtCounterpartyHint', lang),
                hintStyle: AppTextStyles.bodySm(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nameCtrl,
            builder: (_, v, __) {
              if (v.text.isEmpty) return const SizedBox.shrink();
              return InkWell(
                onTap: () => setState(() => _nameCtrl.clear()),
                borderRadius: BorderRadius.circular(999),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close, size: 16, color: AppColors.outline),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _amountHero(String lang, String currencyCode) {
    final symbol = MoneyFormat.symbolOf(currencyCode);
    final base = MoneyFormat.toBaseMinorUnits(
      _rawAmount,
      currency: currencyCode,
    );
    final full = MoneyFormat.format(base, currency: currencyCode);
    final number = full.replaceFirst('$symbol ', '');
    final open = _amountOpen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggleAmount,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: open
                    ? AppColors.tertiary.withValues(alpha: 0.45)
                    : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.tertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        (lang == 'en'
                                ? 'Obligation amount'
                                : 'Nominal kewajiban')
                            .toUpperCase(),
                        style: AppTextStyles.labelCaps(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      Icons.edit_outlined,
                      size: 14,
                      color: AppColors.outline,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      symbol,
                      style: AppTextStyles.headlineSm(color: AppColors.outline),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _rawAmount <= 0 ? '0' : number,
                        style: AppTextStyles.displayCurrencyMobile().copyWith(
                          color: _rawAmount <= 0
                              ? AppColors.outline
                              : AppColors.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  open
                      ? (lang == 'en'
                          ? 'Tap Done or the card to close the keypad'
                          : 'Ketuk Selesai atau kartu untuk menutup')
                      : AppStrings.get('amountTapToEdit', lang),
                  style: AppTextStyles.bodySm(),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in AppAmountPad.stepsFor(currencyCode))
                      _AmountQuickChip(
                        label:
                            '+${MoneyFormat.compact(MoneyFormat.toBaseMinorUnits(s, currency: currencyCode))}',
                        onTap: () => _adjust(s),
                      ),
                    _AmountQuickChip(
                      label: AppStrings.get('clear', lang),
                      danger: true,
                      onTap: _clearAmount,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    children: [
                      AppKeypad(onKey: _keypadPress, onBackspace: _backspace),
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: _toggleAmount,
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.check_rounded,
                                size: 14,
                                color: AppColors.tertiary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                AppStrings.get('keypadDone', lang),
                                style: AppTextStyles.labelSm(
                                  color: AppColors.tertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  String? _walletBalance(FinanceProvider fp) {
    if (_wallet == null || _wallet!.isEmpty) return null;
    for (final w in fp.wallets) {
      if (w.name == _wallet) return MoneyFormat.format(w.balance);
    }
    return null;
  }

  Widget _ledgerLinkGroup(FinanceProvider fp, String lang) {
    final walletSub = _walletBalance(fp);
    final catLabel = _txCategory ??
        (_direction == DebtDirection.payable
            ? (lang == 'en' ? 'Auto (Debt)' : 'Otomatis (Hutang)')
            : (lang == 'en' ? 'Auto (Receivable)' : 'Otomatis (Piutang)'));
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _LinkRow(
            icon: Icons.account_balance_outlined,
            label: AppStrings.get('debtWalletOptional', lang).toUpperCase(),
            value: (_wallet == null || _wallet!.isEmpty)
                ? AppStrings.get('debtNoWallet', lang)
                : _wallet!,
            sub: walletSub,
            isPlaceholder: _wallet == null || _wallet!.isEmpty,
            onTap: () => _pickWallet(fp, lang),
            onClear: (_wallet == null || _wallet!.isEmpty)
                ? null
                : () => setState(() => _wallet = null),
          ),
          const _SheetDivider(indent: 56),
          _LinkRow(
            icon: Icons.category_outlined,
            label: (lang == 'en' ? 'Ledger category' : 'Kategori ledger')
                .toUpperCase(),
            value: catLabel,
            isPlaceholder: _txCategory == null,
            onTap: () => _pickCategory(fp, lang),
            onClear: _txCategory == null
                ? null
                : () => setState(() => _txCategory = null),
          ),
        ],
      ),
    );
  }

  Widget _scheduleGroup(String lang) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _LinkRow(
            icon: Icons.calendar_today_outlined,
            label: AppStrings.get('debtBorrowedAt', lang).toUpperCase(),
            value: AppDates.dateShort(_borrowedAt, lang),
            onTap: () => _pickDate(isDue: false),
          ),
          const _SheetDivider(indent: 56),
          _LinkRow(
            icon: Icons.event_outlined,
            label: AppStrings.get('debtDueAt', lang).toUpperCase(),
            value: _dueAt == null
                ? AppStrings.get('debtNoDue', lang)
                : AppDates.dateShort(_dueAt!, lang),
            isPlaceholder: _dueAt == null,
            onTap: () => _pickDate(isDue: true),
            onClear:
                _dueAt == null ? null : () => setState(() => _dueAt = null),
          ),
          const _SheetDivider(indent: 56),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.edit_note_outlined,
                    size: 18,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _noteCtrl,
                    focusNode: _noteFocus,
                    style: AppTextStyles.bodyMd(),
                    maxLines: 2,
                    minLines: 1,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: lang == 'en'
                          ? 'Note (optional)'
                          : 'Catatan (opsional)',
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

  Widget _stickySave(String lang) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
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
                  backgroundColor: AppColors.primaryFixed,
                  foregroundColor: AppColors.onPrimaryFixed,
                  disabledBackgroundColor: AppColors.surfaceContainerHighest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline, size: 20),
                label: Text(
                  _editing
                      ? AppStrings.get('save', lang)
                      : AppStrings.get('debtAdd', lang),
                  style: AppTextStyles.headlineSm(
                    color: AppColors.onPrimaryFixed,
                  ).copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              lang == 'en'
                  ? 'Stored locally · Ledger precision'
                  : 'Tersimpan lokal · Presisi ledger',
              style: AppTextStyles.bodySm().copyWith(fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickWallet(FinanceProvider fp, String lang) async {
    _closeAmount();
    FocusScope.of(context).unfocus();
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
              const SizedBox(height: 8),
              Text(
                AppStrings.get('debtWalletOptional', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: (_wallet == null || _wallet!.isEmpty)
                          ? AppColors.surfaceContainerHigh
                          : AppColors.surfaceContainerLow,
                      title: Text(
                        AppStrings.get('debtNoWallet', lang),
                        style: AppTextStyles.bodyMd(),
                      ),
                      subtitle: Text(
                        lang == 'en'
                            ? 'Record without posting to a wallet'
                            : 'Catat tanpa posting ke dompet',
                        style: AppTextStyles.bodySm(),
                      ),
                      trailing: (_wallet == null || _wallet!.isEmpty)
                          ? const Icon(Icons.check, color: AppColors.tertiary)
                          : null,
                      onTap: () => Navigator.pop(ctx, ''),
                    ),
                    const SizedBox(height: 4),
                    for (final w in fp.wallets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          tileColor: w.name == _wallet
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
                          trailing: w.name == _wallet
                              ? const Icon(
                                  Icons.check,
                                  color: AppColors.tertiary,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, w.name),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() => _wallet = picked.isEmpty ? null : picked);
    }
  }

  Future<void> _pickCategory(FinanceProvider fp, String lang) async {
    _closeAmount();
    FocusScope.of(context).unfocus();
    final categories = fp.allTransactionCategories
        .map((c) => c.name)
        .where((n) => n != 'All')
        .toSet()
        .toList()
      ..sort();
    final autoLabel = _direction == DebtDirection.payable
        ? (lang == 'en' ? 'Auto (Debt)' : 'Otomatis (Hutang)')
        : (lang == 'en' ? 'Auto (Receivable)' : 'Otomatis (Piutang)');
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
              const SizedBox(height: 8),
              Text(
                lang == 'en' ? 'Ledger category' : 'Kategori ledger',
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: _txCategory == null
                          ? AppColors.surfaceContainerHigh
                          : AppColors.surfaceContainerLow,
                      title: Text(autoLabel, style: AppTextStyles.bodyMd()),
                      trailing: _txCategory == null
                          ? const Icon(Icons.check, color: AppColors.tertiary)
                          : null,
                      onTap: () => Navigator.pop(ctx, ''),
                    ),
                    const SizedBox(height: 4),
                    for (final c in categories)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          tileColor: c == _txCategory
                              ? AppColors.surfaceContainerHigh
                              : AppColors.surfaceContainerLow,
                          title: Text(
                            c,
                            style: AppTextStyles.bodyMd(),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: c == _txCategory
                              ? const Icon(
                                  Icons.check,
                                  color: AppColors.tertiary,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, c),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() => _txCategory = picked.isEmpty ? null : picked);
    }
  }
}

/// Detail stack (reference debt_detail_payment.html).
class _DebtDetailSheet extends StatefulWidget {
  final String debtId;
  final bool autoOpenPay;
  const _DebtDetailSheet({required this.debtId, this.autoOpenPay = false});

  @override
  State<_DebtDetailSheet> createState() => _DebtDetailSheetState();
}

class _DebtDetailSheetState extends State<_DebtDetailSheet> {
  int _payRaw = 0;
  int? _payExactBase;
  String? _wallet;
  bool _payOpen = false;
  bool _paying = false;
  bool _autoApplied = false;
  int _preset = 0; // 0 full, 1 half, 2 custom
  late DateTime _payDate;
  late final TextEditingController _noteCtrl;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _payDate = DateTime.now();
    _noteCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  void _togglePay() => setState(() => _payOpen = !_payOpen);

  void _payKeypadPress(String digit) {
    final str = (_payRaw == 0 ? '' : '$_payRaw') + digit;
    if (!MoneyFormat.displayDigitsAllowed(str.length)) {
      AppMotion.warn();
      return;
    }
    setState(() {
      _payRaw = int.parse(str);
      _payExactBase = null;
      _preset = 2;
    });
  }

  void _payBackspace() {
    setState(() {
      final str = _payRaw.toString();
      _payRaw =
          str.length > 1 ? int.parse(str.substring(0, str.length - 1)) : 0;
      _payExactBase = null;
      _preset = 2;
    });
  }

  void _payAdjust(int delta) => setState(() {
        _payRaw =
            (_payRaw + delta).clamp(0, MoneyFormat.maxDisplayAmount).toInt();
        _payExactBase = null;
        _preset = 2;
      });

  void _payClear() => setState(() {
        _payRaw = 0;
        _payExactBase = null;
        _preset = 2;
      });

  /// FX-safe: store base as-is, display is only rounded for the pad.
  void _payFull(DebtEntry d) {
    AppMotion.tap();
    setState(() {
      _payExactBase = d.remaining;
      _payRaw = MoneyFormat.fromBase(d.remaining).round();
      _preset = 0;
    });
  }

  void _payHalf(DebtEntry d) {
    AppMotion.tap();
    final half = (d.remaining / 2).round().clamp(1, d.remaining);
    setState(() {
      _payExactBase = half;
      _payRaw = MoneyFormat.fromBase(half).round();
      _preset = 1;
    });
  }

  void _payCustom() {
    AppMotion.tap();
    setState(() {
      _preset = 2;
      _payExactBase = null;
      _payOpen = true;
    });
  }

  int _effectiveAmount(DebtEntry d) {
    final raw = (_payExactBase ?? MoneyFormat.toBaseMinorUnits(_payRaw))
        .clamp(0, d.remaining)
        .toInt();
    return raw;
  }

  Future<void> _pay(DebtEntry d) async {
    final fp = context.read<FinanceProvider>();
    final lang = context.read<AppSettingsProvider>().languageCode;
    final messenger = ScaffoldMessenger.of(context);
    if (_paying) return;
    if (_wallet == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('validationWallet', lang))),
      );
      return;
    }
    final amount = _effectiveAmount(d);
    if (amount <= 0) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('validationAmount', lang))),
      );
      return;
    }
    setState(() => _paying = true);
    final ok = await fp.recordDebtPayment(
      debtId: d.id,
      amount: amount,
      wallet: _wallet!,
      date: _payDate,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _paying = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? AppStrings.get('debtPaid', lang)
              : AppStrings.get('debtPayFailed', lang),
        ),
      ),
    );
    if (ok) {
      AppMotion.success();
      _payClear();
      setState(() => _preset = 0);
    }
  }

  Future<void> _delete(DebtEntry d) async {
    final fp = context.read<FinanceProvider>();
    final lang = context.read<AppSettingsProvider>().languageCode;
    final navigator = Navigator.of(context);
    final deleted = await AppConfirm.runAsync(
      context,
      lang: lang,
      title: AppStrings.get('confirmDeleteTitle', lang),
      message: AppStrings.get('debtConfirmDelete', lang),
      confirmLabel: AppStrings.get('delete', lang),
      destructive: true,
      action: () async => (await fp.deleteDebt(d.id)) >= 0,
      successMessage: AppStrings.get('debtDeleted', lang),
      errorMessage: AppStrings.get('genericError', lang),
    );
    if (!deleted || !mounted) return;
    navigator.pop();
  }

  void _openEdit(DebtEntry d) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DebtFormSheet(existing: d),
    );
  }

  Future<void> _export(
    DebtEntry d,
    List<TransactionModel> txs,
    String lang,
  ) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final buf = StringBuffer('title,amount,date,note\n');
      for (final t in txs) {
        final title = t.title.replaceAll(',', ';');
        final note = (t.note ?? '').replaceAll(',', ';').replaceAll('\n', ' ');
        buf.writeln('$title,${t.amount},${t.date.toIso8601String()},$note');
      }
      final text =
          '${d.counterparty} — ${MoneyFormat.format(d.remaining)} / ${MoneyFormat.format(d.principal)}\n${buf.toString()}';
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.get('csvSaveShareFailed', lang))),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _pickPayDate(String lang) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _payDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _payDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final settings = context.watch<AppSettingsProvider>();
    final lang = settings.languageCode;
    final d = fp.debtById(widget.debtId);
    if (d == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppStrings.get('genericError', lang),
            style: AppTextStyles.bodyMd(),
          ),
        ),
      );
    }
    // Auto-open payment deck when launched from NeedsAttention CTA.
    if (widget.autoOpenPay && !_autoApplied) {
      _autoApplied = true;
      _payOpen = true;
      _preset = 0;
      _payExactBase = d.remaining;
      _payRaw = MoneyFormat.fromBase(d.remaining).round();
    }
    final txs = fp.transactionsForDebt(d.id);
    final now = DateTime.now();
    final overdue = d.isOverdue(now);
    final left = d.daysUntilDue(now);
    final pct =
        d.principal <= 0 ? 0.0 : (d.paidTotal / d.principal).clamp(0.0, 1.0);
    final pctLabel =
        '${(pct * 100).toStringAsFixed(pct * 100 % 1 == 0 ? 0 : 1)}%';
    final insets = MediaQuery.of(context).viewInsets;
    final effective = _effectiveAmount(d);

    // Linked wallet/category derived from ledger (model has no
    // dedicated wallet/category columns). Empty strings are treated as
    // missing so the cells never look broken.
    String? linkedWallet;
    String? linkedCategory;
    if (txs.isNotEmpty) {
      linkedWallet = txs.first.account.isEmpty ? null : txs.first.account;
      linkedCategory = txs.first.category.isEmpty ? null : txs.first.category;
    }
    String? walletBalance;
    if (linkedWallet != null) {
      for (final w in fp.wallets) {
        if (w.name == linkedWallet) {
          walletBalance = MoneyFormat.format(w.balance);
          break;
        }
      }
    }
    final tenureDays = DateTime(now.year, now.month, now.day)
        .difference(
          DateTime(d.borrowedAt.year, d.borrowedAt.month, d.borrowedAt.day),
        )
        .inDays;

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + insets.bottom),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SheetHandle(),
                  const SizedBox(height: 4),
                  // Utility chips + overflow.
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              Container(
                                height: 28,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${d.direction == DebtDirection.payable ? AppStrings.get('debtPayable', lang) : AppStrings.get('debtReceivable', lang)} • ${_kindLabel(d.kind, lang)}',
                                  style: AppTextStyles.labelCaps(
                                    color: AppColors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              if (!d.isSettled && d.dueAt != null) ...[
                                const SizedBox(width: 8),
                                Container(
                                  height: 28,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    // ≈30% like ref bg-error-container/30.
                                    color: overdue
                                        ? AppColors.errorContainer.withAlpha(77)
                                        : AppColors.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (overdue)
                                        const Icon(
                                          Icons.warning_amber_rounded,
                                          size: 12,
                                          color: AppColors.error,
                                        ),
                                      if (overdue) const SizedBox(width: 4),
                                      Text(
                                        overdue
                                            ? (lang == 'en'
                                                ? '${-(left ?? 0)} days overdue'
                                                : 'Lewat ${-(left ?? 0)} hari')
                                            : (lang == 'en'
                                                ? 'Due in ${left ?? 0}d'
                                                : '${left ?? 0} hari lagi'),
                                        style: AppTextStyles.labelCaps(
                                          color: overdue
                                              ? AppColors.error
                                              : AppColors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              if (d.isSettled) ...[
                                const SizedBox(width: 8),
                                Container(
                                  height: 28,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.tertiary.withValues(
                                      alpha: 0.14,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    AppStrings.get('debtSettled', lang),
                                    style: AppTextStyles.labelCaps(
                                      color: AppColors.tertiary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _moreMenu(d, lang),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.more_vert,
                            size: 18,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Hero card.
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.counterparty.toUpperCase(),
                                    style: AppTextStyles.labelCaps(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    lang == 'en'
                                        ? 'Remaining Obligation'
                                        : 'Sisa Kewajiban',
                                    style: AppTextStyles.headlineMd(),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                _iconForDebt(d, linkedCategory),
                                size: 20,
                                color: AppColors.onSurface,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              MoneyFormat.symbolOf(settings.currencyCode),
                              style: AppTextStyles.headlineSm(
                                color: AppColors.outline,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                MoneyFormat.format(d.remaining).replaceFirst(
                                  '${MoneyFormat.symbolOf(settings.currencyCode)} ',
                                  '',
                                ),
                                style: AppTextStyles.displayCurrencyMobile(),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Semantics(
                          label: '$pctLabel paid',
                          child: AnimatedProgressBar(
                            value: pct,
                            color: AppColors.tertiary,
                            background: AppColors.surfaceContainerHighest,
                            height: 8,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
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
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: MoneyFormat.format(d.paidTotal),
                                      style: AppTextStyles.bodyMd().copyWith(
                                        color: AppColors.tertiary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(
                                      text: lang == 'en'
                                          ? ' paid ($pctLabel)'
                                          : ' dibayar ($pctLabel)',
                                      style: AppTextStyles.bodySm(),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${lang == 'en' ? 'Total' : 'Total'}: ${MoneyFormat.format(d.principal)}',
                              style: AppTextStyles.tabularAmount(
                                color: AppColors.outline,
                              ),
                            ),
                          ],
                        ),
                        if (d.note != null && d.note!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(d.note!, style: AppTextStyles.bodySm()),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Metadata 2x2.
                  LayoutBuilder(
                    builder: (ctx, cons) {
                      final narrow = cons.maxWidth < 360;
                      final cells = [
                        _MetaCell(
                          icon: Icons.event_busy_outlined,
                          iconColor:
                              overdue && !d.isSettled ? AppColors.error : null,
                          label: lang == 'en' ? 'DUE DATE' : 'JATUH TEMPO',
                          value: d.dueAt == null
                              ? AppStrings.get('debtNoDue', lang)
                              : AppDates.dateShort(d.dueAt!, lang),
                          sub: d.isSettled
                              ? AppStrings.get('debtSettled', lang)
                              : d.dueAt == null
                                  ? '—'
                                  : overdue
                                      ? (lang == 'en'
                                          ? 'Overdue by ${-(left ?? 0)} days'
                                          : 'Lewat ${-(left ?? 0)} hari')
                                      : (lang == 'en'
                                          ? 'In ${left ?? 0} days'
                                          : '${left ?? 0} hari lagi'),
                          subColor:
                              overdue && !d.isSettled ? AppColors.error : null,
                        ),
                        _MetaCell(
                          icon: Icons.calendar_today_outlined,
                          label: lang == 'en' ? 'ORIGINATED' : 'DIBUAT',
                          value: AppDates.dateShort(d.borrowedAt, lang),
                          sub: lang == 'en'
                              ? '$tenureDays days tenure'
                              : '$tenureDays hari berjalan',
                        ),
                        _MetaCell(
                          icon: Icons.account_balance_wallet_outlined,
                          label:
                              lang == 'en' ? 'LINKED WALLET' : 'DOMPET TERKAIT',
                          value: linkedWallet ?? '—',
                          sub: walletBalance ??
                              (linkedWallet != null
                                  ? '—'
                                  : (lang == 'en'
                                      ? 'Cash / manual record'
                                      : 'Tunai / catatan manual')),
                        ),
                        _MetaCell(
                          icon: Icons.category_outlined,
                          label: lang == 'en' ? 'CATEGORY' : 'KATEGORI',
                          value: linkedCategory ?? _kindLabel(d.kind, lang),
                          sub:
                              '${_kindLabel(d.kind, lang)} • ${d.direction == DebtDirection.payable ? AppStrings.get('debtPayable', lang) : AppStrings.get('debtReceivable', lang)}',
                        ),
                      ];
                      if (narrow) {
                        return Column(
                          children: [
                            cells[0],
                            const SizedBox(height: 8),
                            cells[1],
                            const SizedBox(height: 8),
                            cells[2],
                            const SizedBox(height: 8),
                            cells[3],
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: cells[0]),
                              const SizedBox(width: 8),
                              Expanded(child: cells[1]),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: cells[2]),
                              const SizedBox(width: 8),
                              Expanded(child: cells[3]),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  // Payment deck.
                  if (d.isSettled)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.tertiary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_outline,
                            color: AppColors.tertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppStrings.get('debtSettled', lang),
                              style: AppTextStyles.bodyMd().copyWith(
                                color: AppColors.tertiary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(12),
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
                                        Expanded(
                                          child: Text(
                                            AppStrings.get(
                                              'debtPayTitle',
                                              lang,
                                            ),
                                            style: AppTextStyles.headlineSm(),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: lang == 'en'
                                                ? 'Remaining unpaid: '
                                                : 'Sisa belum dibayar: ',
                                            style: AppTextStyles.bodySm(),
                                          ),
                                          TextSpan(
                                            text: MoneyFormat.format(
                                              d.remaining,
                                            ),
                                            style:
                                                AppTextStyles.tabularAmount(),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  lang == 'en'
                                      ? 'FAST SETTLEMENT'
                                      : 'PELUNASAN CEPAT',
                                  style: AppTextStyles.labelCaps(
                                    color: AppColors.tertiary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _PresetChip(
                                  title: lang == 'en' ? 'FULL' : 'LUNAS',
                                  sub: MoneyFormat.compact(d.remaining),
                                  selected: _preset == 0,
                                  onTap: () => _payFull(d),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _PresetChip(
                                  title: lang == 'en'
                                      ? 'HALF (50%)'
                                      : 'SETENGAH (50%)',
                                  sub: MoneyFormat.compact(
                                    (d.remaining / 2).round(),
                                  ),
                                  selected: _preset == 1,
                                  onTap: () => _payHalf(d),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _PresetChip(
                                  title: lang == 'en' ? 'CUSTOM' : 'KUSTOM',
                                  sub: lang == 'en' ? 'Flexible' : 'Bebas',
                                  selected: _preset == 2,
                                  onTap: _payCustom,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          AppAmountPad(
                            label: AppStrings.get('debtPay', lang),
                            amount: _payRaw,
                            currencyCode: settings.currencyCode,
                            lang: lang,
                            expanded: _payOpen,
                            onToggleExpanded: _togglePay,
                            onKey: _payKeypadPress,
                            onBackspace: _payBackspace,
                            onAdjust: _payAdjust,
                            onClear: _payClear,
                            extraChipLabel:
                                '${AppStrings.get('debtRemainingLabel', lang)} ${MoneyFormat.format(d.remaining)}',
                            onExtraChip: () => _payFull(d),
                          ),
                          const SizedBox(height: 12),
                          // Source wallet.
                          DropdownButtonFormField<String>(
                            // ignore: deprecated_member_use
                            value: _wallet,
                            dropdownColor: AppColors.surfaceContainerHigh,
                            style: AppTextStyles.bodyMd(),
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: lang == 'en'
                                  ? 'Source Wallet'
                                  : 'Dompet Sumber',
                              hintText: AppStrings.get('selectWallet', lang),
                              prefixIcon: const Icon(
                                Icons.account_balance_outlined,
                                size: 18,
                              ),
                            ),
                            items: fp.wallets
                                .map(
                                  (w) => DropdownMenuItem<String>(
                                    value: w.name,
                                    child: Text(
                                      '${w.name} • ${MoneyFormat.format(w.balance)}',
                                      style: AppTextStyles.bodyMd(),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _wallet = v),
                          ),
                          const SizedBox(height: 8),
                          // Effective date + note (in reference).
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => _pickPayDate(lang),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    height: 48,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.today_outlined,
                                          size: 18,
                                          color: AppColors.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                lang == 'en'
                                                    ? 'EFFECTIVE DATE'
                                                    : 'TANGGAL BERLAKU',
                                                style:
                                                    AppTextStyles.labelCaps(),
                                              ),
                                              Text(
                                                AppDates.dateShort(
                                                  _payDate,
                                                  lang,
                                                ),
                                                style: AppTextStyles.bodyMd(),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _noteCtrl,
                            style: AppTextStyles.bodyMd(),
                            decoration: InputDecoration(
                              labelText: AppStrings.get('note', lang),
                              hintText: lang == 'en'
                                  ? 'Note (e.g. October payoff)'
                                  : 'Catatan (mis. pelunasan Oktober)',
                              prefixIcon: const Icon(
                                Icons.edit_note_outlined,
                                size: 18,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.tertiary,
                                foregroundColor: AppColors.onTertiary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onPressed: _paying ? null : () => _pay(d),
                              icon: _paying
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.onTertiary,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.check_circle_outline,
                                      size: 20,
                                    ),
                              label: Text(
                                _paying
                                    ? (lang == 'en'
                                        ? 'Processing…'
                                        : 'Memproses…')
                                    : '${lang == 'en' ? 'Confirm Payment' : 'Konfirmasi Bayar'} (${MoneyFormat.format(effective)})',
                                style: AppTextStyles.labelSm(
                                  color: AppColors.onTertiary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  // History + export.
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              AppStrings.get('debtHistory', lang),
                              style: AppTextStyles.headlineSm(),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                lang == 'en'
                                    ? '${txs.length} records'
                                    : '${txs.length} catatan',
                                style: AppTextStyles.labelCaps(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed:
                            _exporting ? null : () => _export(d, txs, lang),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(44, 32),
                        ),
                        // No pdf dependency in pubspec, so this stays a
                        // plain-text share; the label stays honest (Export).
                        icon: const Icon(
                          Icons.share_outlined,
                          size: 16,
                          color: AppColors.tertiary,
                        ),
                        label: Text(
                          lang == 'en' ? 'Export' : 'Ekspor',
                          style: AppTextStyles.labelSm(
                            color: AppColors.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (txs.isEmpty)
                    Text(
                      AppStrings.get('debtNoHistory', lang),
                      style: AppTextStyles.bodySm(),
                    )
                  else
                    ...txs.asMap().entries.map((e) {
                      final TransactionModel t = e.value;
                      final isIncome = t.type.name == 'income';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                t.tag == 'debt_principal'
                                    ? Icons.handshake_outlined
                                    : Icons.payments_outlined,
                                size: 18,
                                color: AppColors.tertiary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.title,
                                    style: AppTextStyles.bodyMd(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${AppDates.dateTimeShort(t.date, lang)} • ${_shortRef(t.id)}',
                                    style: AppTextStyles.bodySm(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  MoneyFormat.signed(t.amount, t.type.name),
                                  style: AppTextStyles.tabularAmount(
                                    color: isIncome
                                        ? AppColors.tertiary
                                        : AppColors.onSurface,
                                  ),
                                ),
                                InkWell(
                                  onTap: () => _showTxLedger(t, lang),
                                  borderRadius: BorderRadius.circular(4),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: 4,
                                      horizontal: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Ledger',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.outline,
                                          ),
                                        ),
                                        SizedBox(width: 2),
                                        Icon(
                                          Icons.north_east,
                                          size: 12,
                                          color: AppColors.outline,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                  const SizedBox(height: 16),
                  // Edit / Delete deck.
                  LayoutBuilder(
                    builder: (ctx, cons) {
                      final narrow = cons.maxWidth < 360;
                      final editBtn = SizedBox(
                        height: 44,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: AppColors.surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () => _openEdit(d),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(
                            lang == 'en' ? 'Edit Terms' : 'Ubah',
                            style: AppTextStyles.labelSm(),
                          ),
                        ),
                      );
                      final delBtn = SizedBox(
                        height: 44,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                AppColors.errorContainer.withValues(alpha: 0.2),
                            foregroundColor: AppColors.error,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () => _delete(d),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text(
                            AppStrings.get('delete', lang),
                            style: AppTextStyles.labelSm(
                              color: AppColors.error,
                            ),
                          ),
                        ),
                      );
                      if (narrow) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            editBtn,
                            const SizedBox(height: 8),
                            delBtn,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: editBtn),
                          const SizedBox(width: 8),
                          Expanded(child: delBtn),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _moreMenu(DebtEntry d, String lang) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(
                  lang == 'en' ? 'Edit Terms' : 'Ubah Ketentuan',
                  style: AppTextStyles.bodyMd(),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _openEdit(d);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.error,
                ),
                title: Text(
                  AppStrings.get('delete', lang),
                  style: AppTextStyles.bodyMd().copyWith(
                    color: AppColors.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _delete(d);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTxLedger(TransactionModel t, String lang) {
    final title = t.title;
    final amount = t.amount;
    final kind = t.type.name;
    final date = t.date;
    final ref = _shortRef(t.id);
    final note = t.note ?? '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: AppTextStyles.headlineSm()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              MoneyFormat.signed(amount, kind),
              style: AppTextStyles.tabularAmountLg(),
            ),
            const SizedBox(height: 4),
            Text(
              AppDates.dateTimeShort(date, lang),
              style: AppTextStyles.bodySm(),
            ),
            const SizedBox(height: 2),
            Text(
              '${lang == 'en' ? 'Ref' : 'No. resi'}: $ref',
              style: AppTextStyles.bodySm(color: AppColors.outline),
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(note, style: AppTextStyles.bodyMd()),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.get('close', lang)),
          ),
        ],
      ),
    );
  }
}

class _MetaCell extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String label;
  final String value;
  final String sub;
  final Color? subColor;

  const _MetaCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.iconColor,
    this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 15,
                color: iconColor ?? AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: AppTextStyles.labelCaps(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: AppTextStyles.headlineSm(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            sub,
            style: AppTextStyles.bodySm(color: subColor ?? AppColors.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String title;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.title,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceContainerHighest
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: AppColors.tertiary.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: AppTextStyles.labelCaps(
                color:
                    selected ? AppColors.onSurface : AppColors.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              sub,
              style: AppTextStyles.tabularAmount(
                color:
                    selected ? AppColors.onSurface : AppColors.onSurfaceVariant,
              ).copyWith(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _FormEyebrow extends StatelessWidget {
  final String label;
  final Widget? trailing;
  const _FormEyebrow({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: AppTextStyles.labelCaps(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

class _ObligationTypeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLocked;

  const _ObligationTypeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onLocked,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: InkWell(
        onTap: enabled
            ? () {
                AppMotion.tap();
                onTap();
              }
            : onLocked,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surfaceContainerHighest
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppColors.tertiary.withValues(alpha: 0.5)
                  : AppColors.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color:
                    selected ? AppColors.tertiary : AppColors.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: AppTextStyles.labelSm(
                  color: selected
                      ? AppColors.onSurface
                      : AppColors.onSurfaceVariant,
                ).copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final bool isPlaceholder;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _LinkRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.sub,
    this.isPlaceholder = false,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        AppMotion.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.labelCaps(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          style: AppTextStyles.bodyMd().copyWith(
                            fontWeight: FontWeight.w600,
                            color: isPlaceholder
                                ? AppColors.outline
                                : AppColors.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (sub != null) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            sub!,
                            style: AppTextStyles.tabularAmount(
                              color: AppColors.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (onClear != null)
              InkWell(
                onTap: () {
                  AppMotion.tap();
                  onClear!();
                },
                borderRadius: BorderRadius.circular(999),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.close, size: 14, color: AppColors.outline),
                ),
              )
            else
              const Icon(Icons.unfold_more, size: 18, color: AppColors.outline),
          ],
        ),
      ),
    );
  }
}

class _SheetDivider extends StatelessWidget {
  final double indent;
  const _SheetDivider({this.indent = 0});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: EdgeInsets.only(left: indent, right: 12),
      color: AppColors.outlineVariant.withValues(alpha: 0.35),
    );
  }
}

class _AmountQuickChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _AmountQuickChip({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        AppMotion.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: danger
              ? AppTextStyles.bodySm(color: AppColors.error)
              : AppTextStyles.tabularAmount(
                  color: AppColors.onSurfaceVariant,
                ).copyWith(fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
