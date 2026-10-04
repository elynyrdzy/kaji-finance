import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/dialogs/app_confirm.dart';
import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/auth_service.dart';
import '../services/backup_service.dart';
import '../services/secure_db_service.dart';
import '../services/transaction_import_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/date_format.dart';
import '../utils/digest_scheduler.dart';
import '../utils/step_up_auth.dart';
import '../widgets/app_keypad.dart';
import '../widgets/tx_import_preview.dart';

/// SATU-SATUNYA UI cadangan & pulihkan: satu file `.kaji.json` mencakup
/// seluruh data (transaksi, dompet, anggaran, tabungan, kategori kustom +
/// pengaturan). CSV = format baca-manusia sekunder (bukan pengganti).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  /// Lama snackbar "restore parsial" ditampilkan. Lebih panjang dari
  /// default karena pesannya menyuruh user bertindak (cadangan darurat sudah
  /// ditulis, jangan uninstall aplikasi) — pesan yang terlewat sama
  /// bahayanya dengan tak ditampilkan.
  static const _partialRestoreReadTime = Duration(seconds: 8);
  Future<void> _exportBackup() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    try {
      if (!await stepUpAuth(context, lang)) return;
      var jsonStr = await BackupService.exportToJson();
      if (!mounted) return;
      final finalStr = await _maybeEncryptBackup(jsonStr);
      if (finalStr == null) return; // user batal di dialog proteksi/PIN
      final file = await BackupService.saveToFile(finalStr);
      await BackupService.noteBackupTime();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('backupSaved', lang, {'path': file.path}),
          ),
        ),
      );
      // Hasil dialog sukses sengaja diabaikan (unawaited): hanya info path.
      await showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('backupSuccess', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SelectableText(file.path, style: AppTextStyles.bodySm()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(AppStrings.get('close', lang)),
            ),
            TextButton(
              onPressed: () async {
                try {
                  // Berbagi plaintext = data keluar perangkat tanpa
                  // proteksi: minta konfirmasi eksplisit.
                  if (!BackupService.isEncryptedBackup(finalStr)) {
                    final go = await showDialog<bool>(
                      context: context,
                      builder: (confirmCtx) => AlertDialog(
                        backgroundColor: AppColors.surfaceContainer,
                        title: Text(
                          AppStrings.get('sharePlainTitle', lang),
                          style: AppTextStyles.headlineSm(),
                        ),
                        content: Text(
                          AppStrings.get('sharePlainBody', lang),
                          style: AppTextStyles.bodyMd(),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(confirmCtx, false),
                            child: Text(AppStrings.get('cancel', lang)),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.errorContainer,
                            ),
                            onPressed: () => Navigator.pop(confirmCtx, true),
                            child: Text(AppStrings.get('ok', lang)),
                          ),
                        ],
                      ),
                    );
                    if (go != true) return;
                  }
                  await BackupService.shareFile(file);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppStrings.fill('shareFailed', lang, {'error': e}),
                      ),
                    ),
                  );
                }
              },
              child: Text(AppStrings.get('saveAndShare', lang)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.fill('backupFailed', lang, {'error': e})),
        ),
      );
    }
  }

  Future<void> _importBackup() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final raw = await BackupService.pickRawContent();
    if (!mounted) return;
    if (raw == null) {
      // Pengguna membatalkan pemilihan file — jangan tampilkan error.
      return;
    }
    var plain = raw;
    if (BackupService.isEncryptedBackup(raw)) {
      final pin = await _askBackupPin(
        title: AppStrings.get('decryptTitle', lang),
        body: AppStrings.get('decryptBody', lang),
      );
      if (!mounted) return;
      if (pin == null || pin.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.get('importFailed', lang))),
        );
        return;
      }
      final dec = await BackupService.decryptBackupAsync(raw, pin);
      if (dec == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.get('decryptWrong', lang))),
        );
        return;
      }
      plain = dec;
    }
    if (!mounted) return;
    // P0: pulihkan menimpa SELURUH data dan mematikan PIN/biometrik.
    // Wajib konfirmasi + step-up sebelum ada perubahan state apa pun.
    final fp = context.read<FinanceProvider>();
    final appSettings = context.read<AppSettingsProvider>();
    if (!mounted) return;
    // Tampilkan ringkasan isi backup di dialog konfirmasi: user harus
    // melihat APA yang akan menimpa data mereka sebelum menyetujui.
    final summary = await BackupService.summarizeBackupContent(plain);
    if (!mounted) return;
    final summaryLine = summary == null || summary.isEmpty
        ? ''
        : '\n\n${AppStrings.get('importSummaryHeader', lang)}:\n'
            '${_summaryLines(summary, lang)}';
    final ok = await AppConfirm.runAsync(
      context,
      lang: lang,
      title: AppStrings.get('importConfirmTitle', lang),
      message: '${AppStrings.get('importConfirmBody', lang)}$summaryLine',
      confirmLabel: AppStrings.get('importConfirmAction', lang),
      destructive: true,
      errorMessage: AppStrings.get('importFailed', lang),
      beforeAction: () => stepUpAuth(context, lang),
      action: () async {
        final restored = await BackupService.importFromJsonString(plain);
        if (!restored) return false;
        await fp.reloadFromPrefs();
        await appSettings.reload();
        await refreshDigestSchedule(fp, appSettings);
        return true;
      },
    );
    if (!mounted) return;
    if (ok) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('importSuccess', lang)),
          backgroundColor: AppColors.tertiary,
        ),
      );
      return;
    }
    // Kegagalan SETELAH DB ter-commit tak sama dengan "tak ada yang
    // berubah". Database sudah diganti total, jadi diam-diam menunjukkan
    // "restore gagal" yang sama adalah misleading — user bisa menyimpulkan
    // datanya utuh lalu melakukan tindakan lain di atas data yang sudah
    // berubah. Lihat BackupService.lastRestoreOutcome.
    if (BackupService.lastRestoreOutcome == 'failed_after_db_commit') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('restorePartial', lang)),
          backgroundColor: AppColors.errorContainer,
          duration: _partialRestoreReadTime,
        ),
      );
    }
  }

  void _showExportCsv() {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final fp = context.read<FinanceProvider>();
    final csv = fp.exportCsv();
    // Pratinjau dibatasi 2000 char: riwayat besar tak boleh menjank dialog.
    final preview = csv.length > 2000 ? '${csv.substring(0, 2000)}…' : csv;
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
              csv.trim() ==
                      'id,title,category,account,amount,type,date,tag,note'
                  ? AppStrings.get('csvEmpty', lang)
                  : preview,
              style: AppTextStyles.bodySm().copyWith(fontSize: 10),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('close', lang)),
          ),
          if (csv.trim() !=
              'id,title,category,account,amount,type,date,tag,note')
            TextButton(
              onPressed: () async {
                try {
                  final file = await BackupService.saveCsvFile(csv);
                  await BackupService.shareFile(file);
                } catch (_) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.get('csvSaveShareFailed', lang)),
                    ),
                  );
                }
              },
              child: Text(AppStrings.get('saveAndShare', lang)),
            ),
        ],
      ),
    );
  }

  /// Impor transaksi dari CSV hasil ekspor (kebalikan Ekspor CSV).
  /// Alur: staging memori → pratinjau → enkripsi + SQL, duplikat
  /// by-ID di-skip (menggabungkan, bukan menimpa).
  Future<void> _importCsv() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final messenger = ScaffoldMessenger.of(context);
    final raw = await TransactionImportService.pickRawJson();
    if (!mounted) return;
    if (raw == null) return; // batal pilih file — bukan error.
    final staging = TransactionImportService.parseTransactionsCsv(raw);
    if (!mounted) return;
    if (staging.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('importTxEmpty', lang))),
      );
      return;
    }
    final go = await showTxImportPreview(context, staging, lang);
    if (go != true || !mounted) return;
    // Baca provider sebelum gap async berikutnya — jangan pakai
    // BuildContext lintas await.
    final fp = context.read<FinanceProvider>();
    final appSettings = context.read<AppSettingsProvider>();
    final res = await fp.importTransactions(
      staging.valid,
      goals: staging.goals,
      wallets: staging.wallets,
    );
    await refreshDigestSchedule(fp, appSettings);
    if (!mounted) return;
    setState(() {});
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

  void _confirmReset() {
    final lang = context.read<AppSettingsProvider>().languageCode;
    unawaited(
      AppConfirm.runAsync(
        context,
        lang: lang,
        title: AppStrings.get('resetTitle', lang),
        message: AppStrings.get('resetBody', lang),
        confirmLabel: AppStrings.get('resetData', lang),
        destructive: true,
        errorMessage: AppStrings.get('genericError', lang),
        successMessage: AppStrings.get('resetDone', lang),
        // Step-up dulu: reset total tak bisa dibatalkan.
        beforeAction: () => stepUpAuth(context, lang),
        action: () async {
          if (!mounted) return false;
          // Keamanan dibersihkan di dalam resetAllData (P1-3).
          await context.read<FinanceProvider>().resetAllData();
          return true;
        },
      ).then((ok) {
        if (ok && mounted) setState(() {});
      }),
    );
  }

  /// Enkripsi PIN untuk isi backup. Bila PIN aktif, proteksi WAJIB
  /// (opsi plaintext dihapus — backup polos + PIN aktif = bocor sia-sia).
  /// Return isi final yang siap disimpan, atau null bila user membatalkan.
  Future<String?> _maybeEncryptBackup(String plain) async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    if (!await AuthService.isPinEnabled()) return plain;
    if (!mounted) return null;
    final protect = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('backupProtectTitle', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Text(
          AppStrings.get('backupProtectBody', lang),
          style: AppTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.tertiary,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(
              AppStrings.get('protect', lang),
              style: AppTextStyles.labelSm(color: AppColors.onTertiary),
            ),
          ),
        ],
      ),
    );
    if (protect != true) return null;
    if (!mounted) return null;
    final pin = await _askBackupPin(
      title: AppStrings.get('backupProtectTitle', lang),
      body: AppStrings.get('decryptBody', lang),
    );
    if (pin == null || pin.isEmpty) return null;
    final valid = await AuthService.verifyPin(pin);
    if (!mounted) return null;
    if (!valid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.get('decryptWrong', lang))),
      );
      return null;
    }
    try {
      // PBKDF2 di isolate agar tak menjank UI (audit P3-D).
      return await BackupService.encryptBackupAsync(plain, pin);
    } catch (_) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('backupFailed', lang, {'error': 'encrypt'}),
          ),
        ),
      );
      return null;
    }
  }

  /// Dialog input PIN sekali pakai (impor terenkripsi / proteksi ekspor).
  Future<String?> _askBackupPin({required String title, required String body}) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    // Sheet PIN bawaan aplikasi — keyboard perangkat tidak muncul.
    return showAppPinSheet(
      context,
      title: title,
      message: body,
      cancelLabel: AppStrings.get('cancel', lang),
      okLabel: AppStrings.get('ok', lang),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(AppStrings.get('backupSection', lang)),
        backgroundColor: AppColors.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _StatusCard(lang: lang),
          const SizedBox(height: 12),
          _action(
            icon: Icons.backup_outlined,
            title: AppStrings.get('exportBackup', lang),
            subtitle: AppStrings.get('exportBackupDesc', lang),
            onTap: _exportBackup,
          ),
          _action(
            icon: Icons.restore_outlined,
            title: AppStrings.get('importBackup', lang),
            subtitle: AppStrings.get('importBackupDesc', lang),
            onTap: _importBackup,
          ),
          const SizedBox(height: 12),
          _action(
            icon: Icons.cloud_download_outlined,
            title: AppStrings.get('exportCsv', lang),
            subtitle: AppStrings.get('exportCsvDesc', lang),
            onTap: _showExportCsv,
          ),
          _action(
            icon: Icons.upload_file_outlined,
            title: AppStrings.get('importCsv', lang),
            subtitle: AppStrings.get('importCsvDesc', lang),
            onTap: _importCsv,
          ),
          const SizedBox(height: 12),
          _action(
            icon: Icons.delete_sweep_outlined,
            title: AppStrings.get('resetData', lang),
            subtitle: AppStrings.get('resetDataDesc', lang),
            danger: true,
            onTap: _confirmReset,
          ),
        ],
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return Card(
      color: AppColors.surfaceContainer,
      child: ListTile(
        leading: Icon(
          icon,
          color: danger ? AppColors.error : AppColors.tertiary,
        ),
        title: Text(
          title,
          style: danger
              ? AppTextStyles.bodyMd().copyWith(color: AppColors.error)
              : AppTextStyles.bodyMd(),
        ),
        subtitle: Text(subtitle, style: AppTextStyles.bodySm()),
        trailing: const Icon(
          Icons.chevron_right_outlined,
          color: AppColors.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }

  /// Baris ringkas isi backup untuk dialog konfirmasi restore.
  /// Memakai key l10n yang sudah ada agar tidak menambah string baru.
  String _summaryLines(Map<String, int> summary, String lang) {
    const labelOf = {
      'kaji_tx': 'transactions',
      'kaji_bd': 'categoryBudgets',
      'kaji_wl': 'wallets',
      'kaji_goals': 'savingsGoals',
      'kaji_cat': 'customCategories',
      'kaji_debts': 'debts',
      'kaji_recurring_bills': 'recurringBills',
      'kaji_tx_templates': 'template',
    };
    final lines = <String>[];
    for (final e in summary.entries) {
      final key = labelOf[e.key];
      if (key == null) continue;
      lines.add('• ${AppStrings.get(key, lang)}: ${e.value}');
    }
    return lines.isEmpty ? '-' : lines.join('\n');
  }
}

/// Kartu isi cadangan: jumlah baris per tabel agar pengguna tahu persis
/// apa yang ikut dalam satu file (transaksi, dompet, anggaran,
/// tabungan, kategori).
class _StatusCard extends StatelessWidget {
  final String lang;
  const _StatusCard({required this.lang});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.get('backupAllDesc', lang),
              style: AppTextStyles.bodySm(),
            ),
            const SizedBox(height: 8),
            FutureBuilder<DateTime?>(
              future: BackupService.lastBackupTime(),
              builder: (_, snap) {
                final at = snap.data?.toLocal();
                if (at == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    AppStrings.fill('backupLast', lang, {
                      't': AppDates.dateTimeShort(at, lang),
                    }),
                    style: AppTextStyles.bodySm(),
                  ),
                );
              },
            ),
            FutureBuilder<Map<String, int>>(
              future: SecureDbService.rowCounts(),
              builder: (_, snap) {
                final counts = snap.data ?? const <String, int>{};
                int of(String table) => counts[table] ?? 0;
                return Column(
                  children: [
                    _row('transactions', of(SecureDbTables.tx)),
                    _row('wallets', of(SecureDbTables.wallets)),
                    _row('categoryBudgets', of(SecureDbTables.budgets)),
                    _row('savingsGoals', of(SecureDbTables.goals)),
                    _row('customCategories', of(SecureDbTables.categories)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String key, int n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.get(key, lang),
              style: AppTextStyles.bodyMd(),
            ),
          ),
          Text(
            '$n',
            style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
