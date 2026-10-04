import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_strings.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'app_motion.dart';

/// Cegah kirim notifikasi sia-sia: bila izin ditolak permanen, tawarkan
/// jalan satu-satunya (Pengaturan sistem). Return false bila alur harus
/// berhenti di sini.
///
/// Berdiri sendiri (bukan `part` Settings) karena dipakai dua layar yang
/// tak saling punya file: sub-layar Notifikasi untuk menyalakan ringkasan
/// harian, dan seksi DEBUG untuk mengirim notifikasi uji.
Future<bool> guardNotifBlocked(BuildContext context, String lang) async {
  final st = await NotificationService.notificationStatus();
  if (!context.mounted) return false;
  if (!st.isPermanentlyDenied) return true;
  AppMotion.warn();
  final open = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      title: Text(
        AppStrings.get('notifBudgetAlert', lang),
        style: AppTextStyles.headlineSm(),
      ),
      content: Text(
        AppStrings.get('notifPermanentlyDenied', lang),
        style: AppTextStyles.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: Text(AppStrings.get('cancel', lang)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.tertiary),
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: Text(
            AppStrings.get('openSystemSettings', lang),
            style: AppTextStyles.labelSm(color: AppColors.onTertiary),
          ),
        ),
      ],
    ),
  );
  if (open == true) {
    await NotificationService.openSystemSettings();
  }
  return false;
}
