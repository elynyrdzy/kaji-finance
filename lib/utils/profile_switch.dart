import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/secure_db_service.dart';
import '../theme/app_colors.dart';
import '../utils/digest_scheduler.dart';
import '../widgets/app_keypad.dart';

/// Orkestrasi ganti profil bersama (dipakai Pengaturan + header).
/// Return true bila beralih. Tak ada aksi sebelum PIN profil target
/// lolos (bila diproteksi). Aman dipanggil berulang.
///
/// PIN target diverifikasi lewat [AuthService.verifyPin], jadi ikut
/// rate-limit yang sama dengan lock screen: jalur "Ubah Akun → B → asal
/// tebak" bukan celah tanpa batas untuk menebak PIN profil lain.
Future<bool> switchActiveProfile(BuildContext context, String id) async {
  if (id == ProfileService.activeId) return false;
  final messenger = ScaffoldMessenger.of(context);
  final fp = context.read<FinanceProvider>();
  final settings = context.read<AppSettingsProvider>();
  final lang = settings.languageCode;
  if (await AuthService.isPinEnabled(scope: id)) {
    // Profil target sedang terkunci (jatah percobaan habis) — jangan buka
    // keypad hanya untuk menolak PIN-nya: beri sisa waktu. Sekalian menutup
    // jalur "Ubah Akun → B → asal tebak" sepenuhnya selama jeda aktif.
    var wait = await AuthService.pinLockoutSeconds(scope: id);
    if (wait > 0) {
      if (!context.mounted) return false;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('pinLockedOutRetry', lang, {'n': wait}),
          ),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return false;
    }
    if (!context.mounted) return false;
    final target = await ProfileService.byId(id);
    if (!context.mounted) return false;
    final pin = await showAppPinSheet(
      context,
      title: AppStrings.get('switchProfile', lang),
      message: target?.name,
      cancelLabel: AppStrings.get('cancel', lang),
      okLabel: AppStrings.get('ok', lang),
    );
    if (!context.mounted) return false;
    if (pin == null || pin.isEmpty) return false;
    if (!await AuthService.verifyPin(pin, scope: id)) {
      if (!context.mounted) return false;
      // Verifikasi ikut rate-limit, jadi "salah" tak selalu berarti PIN-nya
      // keliru — saat jeda aktif tunjukkan sisa waktunya.
      wait = await AuthService.pinLockoutSeconds(scope: id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            wait > 0
                ? AppStrings.fill('pinLockedOutRetry', lang, {'n': wait})
                : AppStrings.get('profilePinWrong', lang),
          ),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return false;
    }
  }
  if (!await ProfileService.setActive(id)) return false;
  await SecureDbService.useProfile(id);
  await fp.reloadFromPrefs();
  await settings.reload();
  fp.budgetAlertsOn = settings.budgetAlertEnabled;
  NotificationService.setLanguage(settings.languageCode);
  unawaited(refreshDigestSchedule(fp, settings));
  if (!context.mounted) return false;
  final name = (await ProfileService.byId(id))?.name ?? id;
  if (!context.mounted) return false;
  messenger.showSnackBar(
    SnackBar(
      content: Text(AppStrings.fill('profileSwitched', lang, {'name': name})),
      backgroundColor: AppColors.tertiary,
    ),
  );
  return true;
}
