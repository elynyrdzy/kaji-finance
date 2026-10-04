part of '../../settings_screen.dart';

/// Seksi DATA: cadangan/pulihkan + atur ulang data.
///
/// "Atur Ulang Data" sebelumnya hanya hidup di dalam BackupScreen — dua
/// level dari Pengaturan, padahal itu aksi paling destruktif di aplikasi.
/// Sekarang ada tile sendiri di kedalaman satu; langkah kedua hanya
/// konfirmasi + step-up di dalam dialog.
extension _SettingsDataSection on _SettingsScreenState {
  /// Komposisi seksi DATA untuk build().
  Widget _dataSection(BuildContext context, String lang) {
    return _section(AppStrings.get('data', lang).toUpperCase(), [
      _tile(
        Icons.backup_outlined,
        AppStrings.get('backupSection', lang),
        AppStrings.get('backupAllDesc', lang),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const BackupScreen())),
      ),
      _tile(
        Icons.restart_alt,
        AppStrings.get('resetData', lang),
        AppStrings.get('resetBody', lang),
        trailing: const Icon(
          Icons.chevron_right,
          color: AppColors.outline,
          size: 18,
        ),
        onTap: () => _confirmResetData(context, lang),
      ),
    ]);
  }

  /// Reset total dari Pengaturan. Konfirmasi + step-up terjadi di dalam
  /// [AppConfirm.runAsync] — jadi tidak ada aksi sebelum user menyetujuinya.
  Future<void> _confirmResetData(BuildContext context, String lang) async {
    final fp = context.read<FinanceProvider>();
    final ok = await AppConfirm.runAsync(
      context,
      lang: lang,
      title: AppStrings.get('resetTitle', lang),
      message: AppStrings.get('resetBody', lang),
      confirmLabel: AppStrings.get('resetData', lang),
      destructive: true,
      errorMessage: AppStrings.get('genericError', lang),
      successMessage: AppStrings.get('resetDone', lang),
      beforeAction: () => stepUpAuth(context, lang),
      action: () async {
        // Keamanan ikut dibersihkan di dalam resetAllData.
        await fp.resetAllData();
        return true;
      },
    );
    if (ok) {
      _refreshSettings();
    }
  }
}
