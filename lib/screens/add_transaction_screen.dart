import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/template_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_icons.dart';
import '../utils/app_motion.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';
import '../widgets/motion_kit.dart';

class AddTransactionScreen extends StatefulWidget {
  final TransactionModel? editing;
  const AddTransactionScreen({super.key, this.editing});

  @override
  State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}

class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _noteCtrl = TextEditingController();

  late int _rawAmount;

  /// Nominal tersimpan SEBAGAI BASIS, apa adanya seperti dari storage.
  ///
  /// Basis→tampil→basis hanya identity kalau nominal tersimpan habis dibagi
  /// kurs. Untuk non-IDR tidak selalu: kurs 16.000, tersimpan 24.000 →
  /// tampil 2 → kembali 32.000. Di transaksi ini konsekuensinya lebih berat daripada
  /// di tagihan, karena `updateTransaction` membalik lalu menerapkan ulang
  /// delta dompet — jadi nominal yang bergeser itu **bergerak di saldo**.
  /// Selama user tak menyentuh nominal, simpan nilai ini apa adanya; mengedit
  /// kategori/label saja tak boleh mengubah nominal maupun saldo.
  late int _baseAmountOriginal;

  /// true begitu user menyentuh nominal (keypad / chip / template / Hapus).
  bool _amountEdited = false;

  late TransactionType _type;
  late String _category;
  late IconData _categoryIcon;
  late DateTime _date;
  late String _selectedWallet;
  late String _fromWallet;
  late String _toWallet;
  List<TxTemplate> _templates = [];

  static const _iconOptions = [
    Icons.restaurant,
    Icons.fastfood,
    Icons.local_cafe,
    Icons.shopping_bag,
    Icons.shopping_cart,
    Icons.directions_car,
    Icons.directions_bus,
    Icons.local_gas_station,
    Icons.receipt_long,
    Icons.bolt,
    Icons.sports_esports,
    Icons.movie,
    Icons.music_note,
    Icons.favorite_border,
    Icons.medical_services,
    Icons.school,
    Icons.work,
    Icons.home,
    Icons.flight,
    Icons.pets,
    Icons.more_horiz,
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _rawAmount = MoneyFormat.fromBase(e.amount).round();
      _baseAmountOriginal = e.amount;
      _type = e.type;
      _category = e.category;
      _categoryIcon = e.icon;
      _date = e.date;
      if (e.type == TransactionType.transfer && e.account.contains(' → ')) {
        final parts = e.account.split(' → ');
        _fromWallet = parts[0];
        _toWallet = parts[1];
        _selectedWallet = parts[0];
      } else {
        _selectedWallet = e.account;
        _fromWallet = e.account;
        _toWallet = '';
      }
      _noteCtrl.text = e.title == e.category ? '' : e.title;
    } else {
      _rawAmount = 0;
      _baseAmountOriginal = 0;
      _type = TransactionType.expense;
      _category = 'Food & Drinks';
      _categoryIcon = Icons.restaurant;
      _date = DateTime.now();
      _selectedWallet = 'Dompet Utama';
      _fromWallet = 'Dompet Utama';
      _toWallet = '';
    }
    unawaited(_loadTemplates());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wallets = context.read<FinanceProvider>().wallets;
    if (wallets.isEmpty) return;
    final names = wallets.map((w) => w.name).toSet();
    // Hanya petakan default generik bila nilai saat ini bukan dompet nyata
    // (hindari menimpa dompet user yang kebetulan bernama sama).
    bool isKnown(String v) => names.contains(v);
    if (_selectedWallet == 'Dompet Utama' && !isKnown(_selectedWallet)) {
      _selectedWallet = wallets.first.name;
      _fromWallet = wallets.first.name;
      if (wallets.length > 1 && _toWallet.isEmpty) {
        _toWallet = wallets[1].name;
      }
    }
    if (_type == TransactionType.transfer &&
        _toWallet.isEmpty &&
        wallets.length > 1) {
      _toWallet = wallets.last.name;
    }
    // Samakan _fromWallet bila masih menunjuk default yang tak dikenal.
    if (!isKnown(_fromWallet)) _fromWallet = _selectedWallet;
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  void _keypadPress(String digit) {
    final str = (_rawAmount == 0 ? '' : '$_rawAmount') + digit;
    if (!MoneyFormat.displayDigitsAllowed(str.length)) {
      AppMotion.warn();
      return;
    }
    setState(() {
      _rawAmount = int.parse(str);
      _amountEdited = true;
    });
  }

  void _backspace() {
    setState(() {
      final str = _rawAmount.toString();
      _rawAmount =
          str.length > 1 ? int.parse(str.substring(0, str.length - 1)) : 0;
      _amountEdited = true;
    });
  }

  void _adjust(int delta) => setState(() {
        _rawAmount =
            (_rawAmount + delta).clamp(0, MoneyFormat.maxDisplayAmount).toInt();
        _amountEdited = true;
      });

  Future<void> _loadTemplates() async {
    final list = await TemplateService.load();
    if (!mounted) return;
    setState(() => _templates = list);
  }

  /// Isi form dari template (dompet dipertahankan bila nama dompet
  /// template sudah tak ada).
  void _applyTemplate(TxTemplate t) {
    final names =
        context.read<FinanceProvider>().wallets.map((w) => w.name).toSet();
    setState(() {
      _type = TransactionType.values[t.type.clamp(0, 2)];
      _category = t.category;
      _categoryIcon = AppIcons.fromCodePoint(t.icon);
      _rawAmount = MoneyFormat.fromBase(t.amount).round();
      _amountEdited = true;
      _noteCtrl.text = t.title == t.category ? '' : t.title;
      if (names.contains(t.account)) {
        _selectedWallet = t.account;
        _fromWallet = t.account;
      }
    });
  }

  Future<void> _saveTemplate(String lang) async {
    final title =
        _noteCtrl.text.trim().isEmpty ? _category : _noteCtrl.text.trim();
    final ok = await TemplateService.save(
      TxTemplate.create(
        title: title,
        category: _category,
        account: _selectedWallet,
        amount: MoneyFormat.toBaseMinorUnits(_rawAmount),
        type: _type.index,
        icon: _categoryIcon.codePoint,
      ),
    );
    if (!mounted) return;
    if (ok) await _loadTemplates();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.get(ok ? 'templateSaved' : 'templateFull', lang),
        ),
        backgroundColor: ok ? AppColors.tertiary : AppColors.errorContainer,
      ),
    );
  }

  Future<void> _removeTemplate(String id) async {
    await TemplateService.remove(id);
    if (!mounted) return;
    setState(() => _templates.removeWhere((e) => e.id == id));
  }

  bool get _isEdit => widget.editing != null;

  /// Nominal basis yang AKAN tersimpan, apa adanya. Dipakai bersama oleh
  /// kartu nominal dan [_save] supaya angka yang tampil dijamin sama dengan
  /// angka yang ditulis — kalau dua-duanya menghitung sendiri, kartu bisa
  /// menampilkan "0" sementara yang tersimpan 7.500.
  int get _effectiveBase => _amountEdited
      ? MoneyFormat.toBaseMinorUnits(_rawAmount)
      : _baseAmountOriginal;

  Future<void> _save() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    // Transaksi tabungan atomik readonly di sini — cegah divergensi goal.
    final e = widget.editing;
    if (e != null &&
        (e.linkedGoalId != null ||
            e.tag == 'savings_deposit' ||
            e.tag == 'savings_withdraw')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('savingsReadonly', lang)),
          backgroundColor: AppColors.surfaceBright,
        ),
      );
      return;
    }
    // Nominal efektif. Konversi ulang HANYA bila user menyentuh nominal;
    // kalau tidak, pakai basis asli apa adanya (lihat _baseAmountOriginal).
    //
    // Validasi ikut memakai nilai efektif ini, bukan _rawAmount: nominal
    // kecil non-IDR (mis. 7.500 IDR ≈ $0,47) membulatkan ke 0 di unit
    // tampilan, dan bila validasi memakai _rawAmount maka transaksi
    // tersebut jadi mustahil diedit sama sekali — user tak bisa membetulkan
    // kategori, catatan, atau tanggalnya karena `_save` selalu ditolak.
    final baseAmount = _effectiveBase;
    if (baseAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('validationAmount', lang)),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return;
    }
    if (_type == TransactionType.transfer) {
      if (_fromWallet == _toWallet) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.get('validationTarget', lang))),
        );
        return;
      }
      if (_fromWallet.isEmpty || _toWallet.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.get('validationWallet', lang))),
        );
        return;
      }
    }
    if (context.read<FinanceProvider>().wallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.get('createWalletFirst', lang))),
      );
      return;
    }
    final fp = context.read<FinanceProvider>();
    final title =
        _noteCtrl.text.trim().isEmpty ? _category : _noteCtrl.text.trim();
    if (_isEdit) {
      final ok = await fp.updateTransaction(
        widget.editing!.id,
        title: title,
        category: _category,
        account:
            _type == TransactionType.transfer ? _fromWallet : _selectedWallet,
        targetAccount: _type == TransactionType.transfer ? _toWallet : null,
        amount: baseAmount,
        type: _type,
        icon: _categoryIcon,
        date: _date,
      );
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.get('dataUpdateFailed', lang)),
            backgroundColor: AppColors.errorContainer,
          ),
        );
        return;
      }
      Navigator.of(context).pop();
      AppMotion.success();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppStrings.get('txUpdated', lang)} • ${MoneyFormat.format(baseAmount)}',
          ),
          backgroundColor: AppColors.surfaceBright,
        ),
      );
    } else {
      final ok = await fp.addTransaction(
        title: title,
        category: _category,
        account:
            _type == TransactionType.transfer ? _fromWallet : _selectedWallet,
        targetAccount: _type == TransactionType.transfer ? _toWallet : null,
        amount: baseAmount,
        type: _type,
        icon: _categoryIcon,
        date: _date,
      );
      if (!mounted) return;
      if (!ok) {
        // Satu-satunya penyebab lolos validasi UI adalah overdraft —
        // dompet sumber tidak mencukupi (audit P2-B).
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.get('insufficientBalance', lang)),
            backgroundColor: AppColors.errorContainer,
          ),
        );
        return;
      }
      Navigator.of(context).pop();
      AppMotion.success();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppStrings.get('txSaved', lang)} • ${MoneyFormat.format(baseAmount)}',
          ),
          backgroundColor: AppColors.surfaceBright,
        ),
      );
    }
  }

  void _openAddCategory() {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final nameCtrl = TextEditingController();
    IconData picked = Icons.category_outlined;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('newCategory', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: AppTextStyles.bodyMd(),
                  decoration: InputDecoration(
                    hintText: AppStrings.get('categoryNameHint', lang),
                    hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
                    border: const OutlineInputBorder(),
                  ),
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
                  children: _iconOptions
                      .map(
                        (ic) => InkWell(
                          onTap: () => setSB(() => picked = ic),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: picked == ic
                                  ? AppColors.tertiary
                                  : AppColors.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              ic,
                              color: picked == ic
                                  ? AppColors.onTertiary
                                  : AppColors.onSurface,
                              size: 20,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.get('cancel', lang)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.tertiary,
              ),
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                context.read<FinanceProvider>().addCustomCategory(
                      nameCtrl.text.trim(),
                      picked,
                    );
                setState(() {
                  _category = nameCtrl.text.trim();
                  _categoryIcon = picked;
                });
                Navigator.pop(ctx);
              },
              child: Text(
                AppStrings.get('save', lang),
                style: AppTextStyles.labelSm(color: AppColors.onTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fp = context.watch<FinanceProvider>();
    final settings = context.watch<AppSettingsProvider>();
    final lang = settings.languageCode;
    final curCode = settings.currencyCode;
    final curSymbol = MoneyFormat.symbolOf(curCode);
    final wallets = fp.wallets;
    final cats = fp.allTransactionCategories;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(
          _isEdit
              ? AppStrings.get('editTransaction', lang)
              : AppStrings.get('addTransaction', lang),
          style: AppTextStyles.headlineSm(),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.error),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(context);
                final ok = await context
                    .read<FinanceProvider>()
                    .deleteTransaction(widget.editing!.id);
                if (!ok) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.get('dataUpdateFailed', lang)),
                    ),
                  );
                  return;
                }
                navigator.pop();
                messenger.showSnackBar(
                  SnackBar(content: Text(AppStrings.get('txDeleted', lang))),
                );
              },
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                // P3: adjustment hanya via koreksi saldo (audit trail),
                // tidak ditawarkan di pembuatan manual.
                children: TransactionType.values
                    .where((t) => t != TransactionType.adjustment)
                    .map((t) {
                  final active = t == _type;
                  return Expanded(
                    child: InkWell(
                      onTap: () {
                        AppMotion.tap();
                        setState(() => _type = t);
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? AppColors.surfaceContainerHighest
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              t == TransactionType.income
                                  ? Icons.arrow_upward
                                  : t == TransactionType.transfer
                                      ? Icons.sync_alt
                                      : Icons.arrow_downward,
                              size: 16,
                              color: active && t == TransactionType.expense
                                  ? AppColors.tertiary
                                  : (active
                                      ? AppColors.onSurface
                                      : AppColors.outline),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              t == TransactionType.income
                                  ? AppStrings.get('incomeLabel', lang)
                                  : t == TransactionType.transfer
                                      ? AppStrings.get('transferLabel', lang)
                                      : AppStrings.get('expenseLabel', lang),
                              style: AppTextStyles.labelSm(
                                color: active
                                    ? AppColors.onSurface
                                    : AppColors.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    AppStrings.get('template', lang),
                    style: AppTextStyles.labelCaps(),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(
                      Icons.bookmark_add_outlined,
                      size: 18,
                      color: AppColors.tertiary,
                    ),
                    tooltip: AppStrings.get('templateSave', lang),
                    onPressed: () => _saveTemplate(lang),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_templates.isEmpty)
                Text(
                  AppStrings.get('templateEmpty', lang),
                  style: AppTextStyles.bodySm(),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final t in _templates) ...[
                        _templateChip(t),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
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
                      Text(
                        (_type == TransactionType.income
                                ? AppStrings.get('enterIncome', lang)
                                : _type == TransactionType.transfer
                                    ? AppStrings.get('enterTransfer', lang)
                                    : AppStrings.get('enterExpense', lang))
                            .toUpperCase(),
                        style: AppTextStyles.labelCaps(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          curSymbol,
                          style: AppTextStyles.tabularAmountLg(
                            color: AppColors.outline,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          MoneyFormat.format(
                            _effectiveBase,
                          ).replaceFirst('$curSymbol ', ''),
                          style: AppTextStyles.displayCurrencyMobile(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Wrap (bukan Row): 4 chip tak overflow di layar 320px.
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 2,
                    runSpacing: 6,
                    children: [
                      _quickChip(
                        '+${MoneyFormat.compact(MoneyFormat.toBaseMinorUnits(curCode == 'IDR' ? 10000 : (curCode == 'JPY' ? 100 : 5)))}',
                        () => _adjust(
                          curCode == 'IDR'
                              ? 10000
                              : (curCode == 'JPY' ? 100 : 5),
                        ),
                      ),
                      _quickChip(
                        '+${MoneyFormat.compact(MoneyFormat.toBaseMinorUnits(curCode == 'IDR' ? 50000 : (curCode == 'JPY' ? 500 : 20)))}',
                        () => _adjust(
                          curCode == 'IDR'
                              ? 50000
                              : (curCode == 'JPY' ? 500 : 20),
                        ),
                      ),
                      _quickChip(
                        '+${MoneyFormat.compact(MoneyFormat.toBaseMinorUnits(curCode == 'IDR' ? 100000 : (curCode == 'JPY' ? 1000 : 50)))}',
                        () => _adjust(
                          curCode == 'IDR'
                              ? 100000
                              : (curCode == 'JPY' ? 1000 : 50),
                        ),
                      ),
                      _quickChip(
                        AppStrings.get('clear', lang),
                        () => setState(() {
                          _rawAmount = 0;
                          _amountEdited = true;
                        }),
                        isDanger: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  AppStrings.get('category', lang),
                  style: AppTextStyles.labelCaps(),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _openAddCategory,
                  icon: const Icon(
                    Icons.add,
                    size: 16,
                    color: AppColors.tertiary,
                  ),
                  label: Text(
                    AppStrings.get('custom', lang),
                    style: AppTextStyles.labelSm(color: AppColors.tertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.95,
              children: [
                ...cats.map((c) {
                  final active = c.name == _category;
                  return InkWell(
                    onTap: () => setState(() {
                      _category = c.name;
                      _categoryIcon = c.icon;
                    }),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.surfaceContainerHighest
                            : AppColors.surfaceContainer,
                        borderRadius: BorderRadius.circular(10),
                        border: active
                            ? Border.all(
                                color: AppColors.tertiary.withValues(
                                  alpha: 0.5,
                                ),
                              )
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            c.icon,
                            size: 20,
                            color:
                                active ? AppColors.tertiary : AppColors.outline,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            c.name.split(' ').first,
                            style: AppTextStyles.bodySm(
                              color: active
                                  ? AppColors.onSurface
                                  : AppColors.outline,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                InkWell(
                  onTap: _openAddCategory,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.outlineVariant,
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.add_circle_outline,
                          size: 20,
                          color: AppColors.tertiary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.get('add', lang),
                          style: AppTextStyles.bodySm(
                            color: AppColors.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_type == TransactionType.transfer) ...[
              Text(
                AppStrings.get('transfer', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _pickWallet(wallets, isFrom: true),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppStrings.get('from', lang),
                              style: AppTextStyles.labelCaps(),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.wallet_outlined,
                                  size: 18,
                                  color: AppColors.tertiary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _fromWallet.isEmpty
                                        ? AppStrings.get('selectWallet', lang)
                                        : _fromWallet,
                                    style: AppTextStyles.bodyMd().copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: AppColors.outline,
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => _pickWallet(wallets, isFrom: false),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppStrings.get('to', lang),
                              style: AppTextStyles.labelCaps(),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.wallet,
                                  size: 18,
                                  color: AppColors.tertiary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    _toWallet.isEmpty
                                        ? AppStrings.get('selectWallet', lang)
                                        : _toWallet,
                                    style: AppTextStyles.bodyMd().copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (wallets.length < 2)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: AppColors.onErrorContainer,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          AppStrings.get('needTwoWallets', lang),
                          style: AppTextStyles.bodySm(
                            color: AppColors.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ] else ...[
              Text(
                AppStrings.get('paymentSource', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _pickWallet(wallets, isFrom: null),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 22,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedWallet.isEmpty
                                  ? AppStrings.get('selectWallet', lang)
                                  : _selectedWallet,
                              style: AppTextStyles.headlineSm(),
                            ),
                            Text(
                              wallets.isEmpty
                                  ? AppStrings.get('createWalletFirst', lang)
                                  : AppStrings.get('tapToChangeWallet', lang),
                              style: AppTextStyles.bodySm(),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.unfold_more, color: AppColors.outline),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              AppStrings.get('timestamp', lang),
              style: AppTextStyles.labelCaps(),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                // Batal pilih tanggal = selesai (jangan buka pemilih jam).
                if (picked == null) return;
                if (!context.mounted) return;
                final base = DateTime(
                  picked.year,
                  picked.month,
                  picked.day,
                  _date.hour,
                  _date.minute,
                );
                setState(() => _date = base);
                final t = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(base),
                );
                if (t != null) {
                  setState(
                    () => _date = DateTime(
                      base.year,
                      base.month,
                      base.day,
                      t.hour,
                      t.minute,
                    ),
                  );
                }
              },
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today,
                      size: 18,
                      color: AppColors.outline,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      AppDates.dateTimeShort(_date, lang),
                      style: AppTextStyles.bodyMd(),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.schedule,
                      size: 16,
                      color: AppColors.outline,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.get('merchantNote', lang),
              style: AppTextStyles.labelCaps(),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.storefront,
                    size: 20,
                    color: AppColors.outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _noteCtrl,
                      style: AppTextStyles.bodyMd(),
                      decoration: InputDecoration(
                        hintText: AppStrings.get('merchantHint', lang),
                        hintStyle: AppTextStyles.bodyMd(
                          color: AppColors.outline.withValues(alpha: 0.6),
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _keypad(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.onSurface,
                  foregroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _save,
                icon: Icon(_isEdit ? Icons.save_outlined : Icons.check),
                label: Text(
                  _isEdit
                      ? AppStrings.get('update', lang)
                      : AppStrings.get('save', lang),
                  style: AppTextStyles.headlineSm(color: AppColors.surface),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pickWallet(List wallets, {bool? isFrom}) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    if (wallets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.get('createWalletFirst', lang))),
      );
      return;
    }
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
                AppStrings.get('selectWallet', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              ...wallets.map(
                (w) => ListTile(
                  leading: WalletAvatar(name: w.name, radius: 20),
                  title: Text(w.name, style: AppTextStyles.bodyMd()),
                  subtitle: Text(
                    '${w.number} • ${MoneyFormat.format(w.balance)}',
                    style: AppTextStyles.bodySm(),
                  ),
                  trailing: (isFrom == true
                              ? _fromWallet
                              : isFrom == false
                                  ? _toWallet
                                  : _selectedWallet) ==
                          w.name
                      ? const Icon(Icons.check, color: AppColors.tertiary)
                      : null,
                  onTap: () {
                    setState(() {
                      if (isFrom == true) {
                        _fromWallet = w.name;
                      } else if (isFrom == false) {
                        _toWallet = w.name;
                      } else {
                        _selectedWallet = w.name;
                      }
                    });
                    Navigator.pop(sheetCtx);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _templateChip(TxTemplate t) {
    return InkWell(
      onTap: () => _applyTemplate(t),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6, right: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.fromCodePoint(t.icon),
              size: 16,
              color: AppColors.tertiary,
            ),
            const SizedBox(width: 6),
            Text(t.title, style: AppTextStyles.labelSm()),
            const SizedBox(width: 2),
            InkWell(
              onTap: () => _removeTemplate(t.id),
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: AppColors.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickChip(String label, VoidCallback onTap, {bool isDanger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isDanger
                ? AppColors.surfaceContainerHigh
                : AppColors.surfaceContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: isDanger
                ? AppTextStyles.bodySm(color: AppColors.error)
                : AppTextStyles.tabularAmount(),
          ),
        ),
      ),
    );
  }

  Widget _keypad() {
    const keys = [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '000',
      '0',
      'del',
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.9,
        children: keys.map((k) {
          return InkWell(
            onTap: () => k == 'del' ? _backspace() : _keypadPress(k),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: k == 'del'
                  ? const Icon(
                      Icons.backspace_outlined,
                      size: 18,
                      color: AppColors.outline,
                    )
                  : Text(k, style: AppTextStyles.headlineMd()),
            ),
          );
        }).toList(),
      ),
    );
  }
}
