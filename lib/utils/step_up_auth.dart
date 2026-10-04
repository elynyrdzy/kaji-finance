import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/auth_service.dart';
import '../widgets/app_keypad.dart';

/// Step-up auth bersama: verifikasi ulang identitas sebelum aksi sensitif
/// (ekspor/share backup, reset total). Bio bila aktif, PIN bila aktif,
/// lolos bila keduanya mati. Return false = batal.
Future<bool> stepUpAuth(BuildContext context, String lang) async {
  if (await AuthService.isBioEnabled()) {
    try {
      if (await AuthService.canCheckBiometrics()) {
        return await AuthService.authenticateBio();
      }
    } catch (_) {
      // best-effort: bio gagal → jatuh ke verifikasi PIN di bawah.
    }
  }
  if (await AuthService.isPinEnabled()) {
    if (!context.mounted) return false;
    final pin = await showAppPinSheet(
      context,
      title: AppStrings.get('confirmIdentity', lang),
      cancelLabel: AppStrings.get('cancel', lang),
      okLabel: AppStrings.get('ok', lang),
    );
    if (pin == null || pin.isEmpty) return false;
    return AuthService.verifyPin(pin);
  }
  return true;
}
