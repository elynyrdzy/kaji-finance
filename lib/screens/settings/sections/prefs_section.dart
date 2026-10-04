part of '../../settings_screen.dart';

/// Seksi PREFERENSI bahasa/kurs (batch 1, pindahan verbatim dari
/// settings_screen.dart): pilih bahasa, pilih kurs, editor kurs manual.
extension _SettingsPrefsSection on _SettingsScreenState {
  void _chooseLanguage(BuildContext context, String lang) {
    final settings = context.read<AppSettingsProvider>();
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
                AppStrings.get('chooseLanguage', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Text('🇮🇩', style: TextStyle(fontSize: 24)),
                title: Text(AppStrings.get('indonesia', 'id')),
                subtitle: const Text('Bahasa Indonesia'),
                trailing: lang == 'id'
                    ? const Icon(Icons.check, color: AppColors.tertiary)
                    : null,
                onTap: () {
                  settings.applySilently(() => settings.setLanguage('id'));
                  // Konten digest ikut bahasa — jadwalkan ulang.
                  unawaited(
                    refreshDigestSchedule(
                      context.read<FinanceProvider>(),
                      settings,
                    ),
                  );
                  Navigator.pop(sheetCtx);
                },
              ),
              ListTile(
                leading: const Text('🇺🇸', style: TextStyle(fontSize: 24)),
                title: Text(AppStrings.get('english', 'en')),
                subtitle: const Text('English'),
                trailing: lang == 'en'
                    ? const Icon(Icons.check, color: AppColors.tertiary)
                    : null,
                onTap: () {
                  settings.applySilently(() => settings.setLanguage('en'));
                  unawaited(
                    refreshDigestSchedule(
                      context.read<FinanceProvider>(),
                      settings,
                    ),
                  );
                  Navigator.pop(sheetCtx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _chooseCurrency(BuildContext context, String lang) {
    final settings = context.read<AppSettingsProvider>();
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
                AppStrings.get('chooseCurrency', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              ...MoneyFormat.symbols.entries.map((e) {
                final isActive = settings.currencyCode == e.key;
                final rateSub = e.key == 'IDR'
                    ? null
                    : AppStrings.fill('rateLine', lang, {
                        'code': e.key,
                        'amount': MoneyFormat.formatRp(
                          (settings.rates[e.key] ?? 0).round(),
                        ),
                      });
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    child: Text(
                      e.value,
                      style: AppTextStyles.bodyMd().copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  title: Text(e.key, style: AppTextStyles.bodyMd()),
                  subtitle: Text(
                    '${e.value} ${MoneyFormat.format(1234567, currency: e.key)}'
                    '${rateSub == null ? '' : '\n$rateSub'}',
                    style: AppTextStyles.bodySm(),
                  ),
                  isThreeLine: rateSub != null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (e.key != 'IDR')
                        IconButton(
                          icon: const Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: AppColors.outline,
                          ),
                          tooltip: AppStrings.fill('editRateTitle', lang, {
                            'code': e.key,
                          }),
                          onPressed: () => _editRate(context, e.key, lang),
                        ),
                      if (isActive)
                        const Icon(Icons.check, color: AppColors.tertiary),
                    ],
                  ),
                  onTap: () async {
                    // Gagal simpan → kurs lama dikembalikan oleh
                    // provider; beri tahu, jangan tutup sheet
                    // seolah-olah berhasil.
                    final changed = await settings
                        .setCurrency(e.key)
                        .then((_) => true)
                        .catchError((_) => false);
                    if (!sheetCtx.mounted) return;
                    Navigator.pop(sheetCtx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          changed
                              ? AppStrings.fill('currencyChanged', lang, {
                                  'code': e.key,
                                })
                              : AppStrings.get('genericError', lang),
                        ),
                        backgroundColor:
                            changed ? null : AppColors.errorContainer,
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// Editor kurs manual (P3-kurs): nominal rupiah per 1 unit kurs asing.
  /// Sheet angka bawaan aplikasi — keyboard perangkat tidak muncul.
  Future<void> _editRate(BuildContext context, String code, String lang) async {
    final settings = context.read<AppSettingsProvider>();
    final cur = settings.rates[code] ?? 0;
    final raw = await showAppAmountSheet(
      context,
      title: AppStrings.fill('editRateTitle', lang, {'code': code}),
      message: AppStrings.fill('rateHint', lang, {'code': code}),
      cancelLabel: AppStrings.get('cancel', lang),
      okLabel: AppStrings.get('save', lang),
      initialRaw: cur > 0 ? cur : 0,
      // Rate = angka mentah rupiah/unit, bukan nominal kurs tampil.
      displayFormat: (v) => v.toStringAsFixed(0),
    );
    if (raw == null) return;
    final ok = await settings.setRate(code, raw);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? AppStrings.fill('rateSaved', lang, {'code': code})
              : AppStrings.get('rateInvalid', lang),
        ),
      ),
    );
  }

  /// Komposisi seksi PREFERENSI untuk build().
  ///
  /// Uang bulanan TIDAK ada di sini: itu data keuangan (masukan hitungan
  /// anggaran), dipindah ke layar Anggaran bersama target tabungan dan
  /// tagihan rutin.
  /// bukan setiap perubahan setting.
  Widget _prefsSection(BuildContext context, String lang) {
    final currency = context.select<AppSettingsProvider, String>(
      (s) => s.currencyCode,
    );
    return _section(AppStrings.get('preferences', lang).toUpperCase(), [
      _tile(
        Icons.language_outlined,
        AppStrings.get('language', lang),
        lang == 'id'
            ? AppStrings.get('indonesia', lang)
            : AppStrings.get('english', lang),
        trailing: const Icon(
          Icons.translate,
          color: AppColors.tertiary,
          size: 18,
        ),
        onTap: () => _chooseLanguage(context, lang),
      ),
      _tile(
        Icons.payments_outlined,
        AppStrings.get('currency', lang),
        '$currency • ${MoneyFormat.symbolOf(currency)}',
        trailing: const Icon(
          Icons.chevron_right,
          color: AppColors.outline,
          size: 18,
        ),
        onTap: () => _chooseCurrency(context, lang),
      ),
    ]);
  }
}
