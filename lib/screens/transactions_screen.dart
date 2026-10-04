import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/backup_service.dart';
import '../services/transaction_import_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/app_header.dart';
import '../widgets/app_keypad.dart';
import '../widgets/tx_import_preview.dart';
import '../widgets/motion_kit.dart';
import '../widgets/transaction_tile.dart';
import 'add_transaction_screen.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _searchDebounce;
  TransactionType? _typeFilter;
  String _categoryFilter = 'All';
  DateTime? _monthFilter;
  DateTime? _fromFilter;
  DateTime? _toFilter;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Tunda filter 250ms agar ketikan cepat hanya memicu 1x pemindaian.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(AppMotion.searchDebounce, () {
      if (!mounted) return;
      setState(() => _query = v);
    });
  }

  bool _isSavings(TransactionModel t) =>
      t.linkedGoalId != null ||
      t.tag == 'savings_deposit' ||
      t.tag == 'savings_withdraw';

  /// P3: adjustment readonly di log (immutable audit trail).
  bool _isAdjustment(TransactionModel t) =>
      t.type == TransactionType.adjustment;

  void _openEdit(TransactionModel t) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    if (_isSavings(t)) {
      // Bukan error: transaksi tabungan by-design readonly di log —
      // ubah/hapus atomik hanya via layar Tabungan. Hapus tetap bisa
      // (delta goal dikembalikan provider).
      AppMotion.tap();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('savingsReadonly', lang)),
          backgroundColor: AppColors.surfaceBright,
        ),
      );
      return;
    }
    if (_isAdjustment(t)) {
      // Koreksi saldo tidak bisa diubah/dihapus — buat koreksi baru
      // bila nilainya salah, agar trail utuh.
      AppMotion.tap();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('savingsReadonly', lang)),
          backgroundColor: AppColors.surfaceBright,
        ),
      );
      return;
    }
    AppMotion.tap();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => AddTransactionScreen(editing: t)));
  }

  Future<void> _deleteWithUndo(
    TransactionModel t,
    FinanceProvider fp,
    String lang,
  ) async {
    final removed = t;
    final ok = await fp.deleteTransaction(t.id);
    if (!mounted) return;
    if (!ok) {
      // P3: adjustment ditolak provider (immutable) — jangan klaim terhapus.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.get('undoFailed', lang))),
      );
      return;
    }
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.get('txDeleted', lang)),
        action: SnackBarAction(
          label: AppStrings.get('undo', lang),
          onPressed: () async {
            AppMotion.tap();
            final messenger = ScaffoldMessenger.of(context);
            final ok = await fp.restoreTransaction(removed);
            if (!ok) {
              messenger.showSnackBar(
                SnackBar(content: Text(AppStrings.get('undoFailed', lang))),
              );
            }
          },
        ),
      ),
    );
  }

  /// Impor transaksi dari file `.json` — alur 3 tahap:
  /// MEMORI (file → staging RAM) → pratinjau → ENKRIPSI + SQL.
  /// Menerima JSON polos maupun backup terenkripsi (KAJI1:/KAJI2:, PIN).
  Future<void> _importFromJson() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final messenger = ScaffoldMessenger.of(context);
    final raw = await TransactionImportService.pickRawJson();
    if (!mounted) return;
    if (raw == null) return; // batal pilih file — bukan error.
    var plain = raw;
    if (BackupService.isEncryptedBackup(raw)) {
      final pin = await showAppPinSheet(
        context,
        title: AppStrings.get('decryptTitle', lang),
        message: AppStrings.get('decryptBody', lang),
        cancelLabel: AppStrings.get('cancel', lang),
        okLabel: AppStrings.get('ok', lang),
      );
      if (!mounted) return;
      if (pin == null || pin.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(AppStrings.get('importTxFailed', lang))),
        );
        return;
      }
      final dec = await BackupService.decryptBackupAsync(raw, pin);
      if (!mounted) return;
      if (dec == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(AppStrings.get('decryptWrong', lang))),
        );
        return;
      }
      plain = dec;
    }
    final staging = TransactionImportService.parseStaging(plain);
    if (!mounted) return;
    if (staging.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('importTxEmpty', lang))),
      );
      return;
    }
    final go = await showTxImportPreview(context, staging, lang);
    if (go != true || !mounted) return;
    final fp = context.read<FinanceProvider>();
    final res = await fp.importTransactions(
      staging.valid,
      goals: staging.goals,
      wallets: staging.wallets,
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: AppColors.tertiary,
        content: Text(
          AppStrings.fill('importTxSuccess', lang, {
            'n': res.imported,
            'd': res.skippedDuplicates,
            'x': res.skippedInvalid + staging.invalid,
          }),
        ),
      ),
    );
  }

  /// Menu tahan-lama ala Telegram: sheet blur dengan Ubah/Duplikat/Hapus.
  void _showTxMenu(TransactionModel t, FinanceProvider fp, String lang) {
    AppMotion.tap();
    showModalBottomSheet(
      context: context,
      // Blur full-screen dihapus: sheet ini muncul di atas
      // CustomScrollView + pinned sliver + baris Dismissible, sehingga
      // BackdropFilter memaksa baca-pixels + saveLayer tiap frame saat
      // sheet bergerak. Konten buram di balik barrier 0.45 hampir tak
      // terlihat, jadi ia hanyapure cost.
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (sheetCtx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          decoration: const BoxDecoration(color: AppColors.surfaceContainer),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHandle(),
                // Ubah & Duplikat disembunyikan untuk transaksi tabungan:
                // readonly di log (badge Tabungan), kelola via layar Tabungan.
                // Hapus tetap ada — delta goal dikembalikan provider.
                if (!_isSavings(t)) ...[
                  ListTile(
                    leading: const Icon(
                      Icons.edit_outlined,
                      color: AppColors.tertiary,
                    ),
                    title: Text(
                      AppStrings.get('edit', lang),
                      style: AppTextStyles.bodyMd(),
                    ),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _openEdit(t);
                    },
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.copy_outlined,
                      color: AppColors.onSurfaceVariant,
                    ),
                    title: Text(
                      AppStrings.get('duplicate', lang),
                      style: AppTextStyles.bodyMd(),
                    ),
                    onTap: () async {
                      final navigator = Navigator.of(sheetCtx);
                      final messenger = ScaffoldMessenger.of(context);
                      navigator.pop();
                      AppMotion.success();
                      if (fp.isSavingsLinkedTx(t.id)) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              AppStrings.get('txDuplicateBlocked', lang),
                            ),
                          ),
                        );
                        return;
                      }
                      final ok = await fp.duplicateTransaction(t.id);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? AppStrings.get('txDuplicated', lang)
                                : AppStrings.get('genericError', lang),
                          ),
                        ),
                      );
                    },
                  ),
                ],
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
                    Navigator.pop(sheetCtx);
                    AppMotion.warn();
                    _deleteWithUndo(t, fp, lang);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final results = fp.filter(
      query: _query,
      type: _typeFilter,
      category: _categoryFilter,
      month: _monthFilter,
      from: _fromFilter,
      to: _toFilter,
    );
    final grouped = _groupByDay(results, lang);

    return Scaffold(
      appBar: AppHeader(title: AppStrings.get('transactions', lang)),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  // Responsif: layar sempit (≤360px) memakai mode ringkas —
                  // tombol 40px + jeda 6 agar kolom cari tetap lega.
                  LayoutBuilder(
                    builder: (filterCtx, filterCons) {
                      final compact = filterCons.maxWidth < 360;
                      final barH = compact ? 40.0 : 48.0;
                      final btn = compact ? 40.0 : 48.0;
                      final gap = compact ? 6.0 : 8.0;
                      return Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: barH,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.search,
                                    size: 18,
                                    color: AppColors.outline,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: _searchCtrl,
                                      style: AppTextStyles.bodyMd(),
                                      decoration: InputDecoration(
                                        hintText: AppStrings.get(
                                          'searchHint',
                                          lang,
                                        ),
                                        hintStyle: AppTextStyles.bodyMd(
                                          color: AppColors.outline,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                      onChanged: _onSearchChanged,
                                    ),
                                  ),
                                  if (_query.isNotEmpty ||
                                      _searchCtrl.text.isNotEmpty)
                                    InkWell(
                                      onTap: () => setState(() {
                                        _searchDebounce?.cancel();
                                        _searchCtrl.clear();
                                        _query = '';
                                      }),
                                      child: const Icon(
                                        Icons.close,
                                        size: 16,
                                        color: AppColors.outline,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(width: gap),
                          InkWell(
                            onTap: _pickMonth,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              height: barH,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: _monthFilter == null
                                    ? AppColors.surfaceContainer
                                    : AppColors.tertiary.withValues(
                                        alpha: 0.15,
                                      ),
                                borderRadius: BorderRadius.circular(10),
                                border: _monthFilter != null
                                    ? Border.all(color: AppColors.tertiary)
                                    : null,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    _monthFilter == null
                                        ? AppDates.monthYearShort(
                                            DateTime.now(),
                                            lang,
                                          )
                                        : AppDates.monthYearShort(
                                            _monthFilter!,
                                            lang,
                                          ),
                                    style: AppTextStyles.labelSm(
                                      color: _monthFilter != null
                                          ? AppColors.tertiary
                                          : AppColors.onSurface,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 16,
                                    color: AppColors.outline,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: _importFromJson,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: btn,
                              height: btn,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.file_download_outlined,
                                size: 20,
                                color: AppColors.onSurface,
                              ),
                            ),
                          ),
                          SizedBox(width: gap),
                          InkWell(
                            onTap: () => _openCategoryFilter(fp),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: btn,
                              height: btn,
                              decoration: BoxDecoration(
                                color: _categoryFilter != 'All'
                                    ? AppColors.tertiary
                                    : AppColors.surfaceContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.tune,
                                size: 20,
                                color: _categoryFilter != 'All'
                                    ? AppColors.onTertiary
                                    : AppColors.onSurface,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  SlidingSegment(
                    labels: [
                      AppStrings.get('all', lang),
                      AppStrings.get('incomeLabel', lang),
                      AppStrings.get('expenseLabel', lang),
                      AppStrings.get('transferLabel', lang),
                    ],
                    selected: _typeFilter == null
                        ? 0
                        : _typeFilter == TransactionType.income
                            ? 1
                            : _typeFilter == TransactionType.expense
                                ? 2
                                : 3,
                    onSelect: (i) => setState(
                      () => _typeFilter = i == 0
                          ? null
                          : i == 1
                              ? TransactionType.income
                              : i == 2
                                  ? TransactionType.expense
                                  : TransactionType.transfer,
                    ),
                    height: 36,
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Text(
                          '${AppStrings.get('filterCategory', lang)}:',
                          style: AppTextStyles.labelCaps(),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _categoryFilter == 'All'
                              ? AppStrings.get('all', lang)
                              : _categoryFilter,
                          style: AppTextStyles.labelCaps(
                            color: AppColors.onSurface,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (_monthFilter != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            AppDates.monthYearShort(_monthFilter!, lang),
                            style: AppTextStyles.labelCaps(
                              color: AppColors.tertiary,
                            ).copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => setState(() => _monthFilter = null),
                            child: const Icon(
                              Icons.close,
                              size: 14,
                              color: AppColors.tertiary,
                            ),
                          ),
                        ],
                        const Spacer(),
                        Text(
                          AppStrings.fill('txCount', lang, {
                            'n': results.length,
                          }),
                          style: AppTextStyles.bodySm(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Text(
                          '${AppStrings.get('filterRange', lang)}:',
                          style: AppTextStyles.labelCaps(),
                        ),
                        const SizedBox(width: 4),
                        _rangeButton(
                          _fromFilter == null
                              ? AppStrings.get('filterFrom', lang)
                              : AppDates.dateShort(_fromFilter!, lang),
                          () => _pickRangeDate(isFrom: true),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('–', style: AppTextStyles.labelCaps()),
                        ),
                        _rangeButton(
                          _toFilter == null
                              ? AppStrings.get('filterTo', lang)
                              : AppDates.dateShort(
                                  _toFilter!.subtract(const Duration(days: 1)),
                                  lang,
                                ),
                          () => _pickRangeDate(isFrom: false),
                        ),
                        if (_fromFilter != null || _toFilter != null)
                          InkWell(
                            onTap: () => setState(() {
                              _fromFilter = null;
                              _toFilter = null;
                            }),
                            child: const Icon(
                              Icons.close,
                              size: 14,
                              color: AppColors.tertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          if (grouped.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      const EmptyArt(icon: Icons.inbox_outlined, size: 36),
                      const SizedBox(height: 8),
                      Text(
                        fp.transactions.isEmpty
                            ? AppStrings.get('noTransactions', lang)
                            : AppStrings.get('noResults', lang),
                        style: AppTextStyles.bodyMd().copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        fp.transactions.isEmpty
                            ? AppStrings.get('emptyDesc', lang)
                            : AppStrings.get('noResults', lang),
                        style: AppTextStyles.bodySm(),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      if (fp.transactions.isEmpty)
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.tertiary,
                            ),
                            onPressed: () {
                              AppMotion.tap();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const AddTransactionScreen(),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.add,
                              color: AppColors.onTertiary,
                              size: 18,
                            ),
                            label: Text(
                              AppStrings.get('addTransaction', lang),
                              style: AppTextStyles.labelSm(
                                color: AppColors.onTertiary,
                              ),
                            ),
                          ),
                        ),
                      if (fp.transactions.isEmpty) const SizedBox(height: 8),
                      if (fp.transactions.isEmpty)
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              AppMotion.tap();
                              _importFromJson();
                            },
                            icon: const Icon(
                              Icons.file_download_outlined,
                              color: AppColors.tertiary,
                              size: 18,
                            ),
                            label: Text(
                              AppStrings.get('importTx', lang),
                              style: AppTextStyles.labelSm(
                                color: AppColors.tertiary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ...grouped.entries.expand((entry) {
            final items = entry.value;
            final income = items
                .where((t) => t.type == TransactionType.income)
                .fold<int>(0, (sum, t) => sum + t.amount);
            final expense = items
                .where((t) => t.type == TransactionType.expense)
                .fold<int>(0, (sum, t) => sum + t.amount);
            final net = income - expense;
            final netText = net >= 0
                ? MoneyFormat.signed(net, 'income')
                : MoneyFormat.signed(net, 'expense');
            return [
              SliverPersistentHeader(
                pinned: true,
                delegate: _DayHeaderDelegate(
                  title: entry.key,
                  trailing: netText,
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((ctx, i) {
                    final t = items[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TransactionTile(
                        tx: t,
                        onTap: () => _openEdit(t),
                        onEdit: () => _openEdit(t),
                        onLongPress: () => _showTxMenu(t, fp, lang),
                        onDelete: () {
                          AppMotion.warn();
                          _deleteWithUndo(t, fp, lang);
                        },
                      ),
                    );
                  }, childCount: items.length),
                ),
              ),
            ];
          }),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.tertiary,
        foregroundColor: AppColors.onTertiary,
        icon: const Icon(Icons.add),
        label: Text(
          AppStrings.get('add', lang),
          style: AppTextStyles.labelSm(color: AppColors.onTertiary),
        ),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AddTransactionScreen())),
      ),
    );
  }

  void _pickMonth() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _monthFilter ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: AppStrings.get('filterMonth', lang),
      fieldLabelText: AppStrings.get('filterMonth', lang),
    );
    if (picked != null) {
      setState(() => _monthFilter = DateTime(picked.year, picked.month, 1));
    }
  }

  Widget _rangeButton(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: AppTextStyles.labelCaps(
            color: AppColors.tertiary,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  /// Rentang tanggal bebas: from inklusif, to eksklusif (disimpan
  /// sebagai awal-hari s/d akhir-hari + 1). Batas yang berkonflik
  /// me-reset pasangannya agar rentang tak pernah terbalik.
  Future<void> _pickRangeDate({required bool isFrom}) async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _fromFilter : _toFilter) ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: AppStrings.get(isFrom ? 'filterFrom' : 'filterTo', lang),
    );
    if (picked == null) return;
    setState(() {
      final day = DateTime(picked.year, picked.month, picked.day);
      if (isFrom) {
        _fromFilter = day;
        if (_toFilter != null && !_toFilter!.isAfter(day)) _toFilter = null;
      } else {
        _toFilter = day.add(const Duration(days: 1));
        if (_fromFilter != null && !_fromFilter!.isBefore(_toFilter!)) {
          _fromFilter = null;
        }
      }
    });
  }

  void _openCategoryFilter(FinanceProvider fp) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('filterCategory', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: fp.allCategories.map((c) {
                  final active = c == _categoryFilter;
                  return InkWell(
                    onTap: () {
                      setState(() => _categoryFilter = c);
                      Navigator.pop(sheetCtx);
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.onSurface
                            : AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        c == 'All' ? AppStrings.get('all', lang) : c,
                        style: AppTextStyles.labelSm(
                          color: active
                              ? AppColors.primaryContainer
                              : AppColors.onSurface,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              if (_monthFilter != null)
                TextButton.icon(
                  onPressed: () {
                    setState(() => _monthFilter = null);
                    Navigator.pop(sheetCtx);
                  },
                  icon: const Icon(Icons.clear),
                  label: Text(AppStrings.get('clearFilter', lang)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, List<TransactionModel>> _groupByDay(
    List<TransactionModel> list,
    String lang,
  ) {
    final map = <String, List<TransactionModel>>{};
    for (final t in list) {
      final key = AppDates.dayGroup(t.date, lang);
      map.putIfAbsent(key, () => []).add(t);
    }
    return map;
  }
}

/// Header tanggal lengket ala bubble tanggal Telegram: menempel di atas
/// saat daftar digulir, dengan latar permukaan agar ubin lewat di bawahnya.
class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final String trailing;

  const _DayHeaderDelegate({required this.title, required this.trailing});

  @override
  double get minExtent => 40;
  @override
  double get maxExtent => 40;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              title,
              style: AppTextStyles.labelCaps().copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Spacer(),
          Text(trailing, style: AppTextStyles.tabularAmount()),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DayHeaderDelegate old) =>
      old.title != title || old.trailing != trailing;
}
