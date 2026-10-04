import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/notification_service.dart';
import '../services/secure_db_service.dart';

/// Satu pintu penjadwalan ringkasan harian. Dipanggil saat:
/// cold start selesai load, app ke background, preferensi/ganti bahasa
/// berubah, dan setelah impor backup. Aman dipanggil berulang
/// (jadwal lama ditimpa; mati bila preferensi/belum-load).
///
/// Catatan: alarm terjadwal hangus saat reboot — BootReceiver native
/// menampilkan pengingat generik sekali agar pengguna membuka aplikasi,
/// yang lalu menjadwalkan ulang digest sebenarnya lewat fungsi ini.
Future<void> refreshDigestSchedule(
  FinanceProvider fp,
  AppSettingsProvider settings,
) async {
  // Sinkronkan konteks seketika + bahasa notifikasi.
  fp.budgetAlertsOn = settings.budgetAlertEnabled;
  NotificationService.setLanguage(settings.languageCode);
  if (!fp.prefsLoaded || !settings.settingsLoaded) return;
  if (!settings.digestEnabled) {
    await NotificationService.cancelDailyDigest();
    return;
  }
  try {
    final data = fp.buildDigestData();
    final content = NotificationService.composeDigest(
      data,
      DigestOptions(
        budget: settings.digestOptBudget,
        goals: settings.digestOptGoals,
        wallets: settings.digestOptWallets,
        nudge: settings.digestOptNudge,
      ),
      settings.languageCode,
    );
    var exact = false;
    try {
      exact = await NotificationService.canScheduleExact();
    } catch (_) {
      // best-effort: izin exact tak terbaca → jadwal inexact (tetap bunyi).
    }
    await NotificationService.scheduleDailyDigest(
      content: content,
      hour: settings.digestHour,
      minute: settings.digestMinute,
      exact: exact,
      addLabel: AppStrings.get('digestCtaAdd', settings.languageCode),
      viewLabel: AppStrings.get('viewAll', settings.languageCode),
    );
  } catch (e) {
    SecureDbService.noteError('Digest: susun/jadwalkan ringkasan gagal: $e');
  }
}
