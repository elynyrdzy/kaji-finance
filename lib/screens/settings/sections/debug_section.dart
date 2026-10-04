part of '../../settings_screen.dart';

/// Seksi DEBUG/DIAGNOSTIK (batch 2, pindahan verbatim dari
/// settings_screen.dart): seed data contoh, reset lockout, info debug,
/// dialog Tentang & Privasi.
extension _SettingsDebugSection on _SettingsScreenState {
  Future<void> _setDebugEnabled(
    BuildContext context,
    String lang,
    bool v,
  ) async {
    await DebugService.setEnabled(v);
    if (!context.mounted) return;
    _applyDebugEnabled(v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.get(v ? 'debugUnlocked' : 'debugLocked', lang),
        ),
        backgroundColor: v ? AppColors.tertiary : null,
      ),
    );
  }

  /// Ketuk cepat 8x pada tile Tentang untuk membuka kategori Debug
  /// (pola opsi developer Android). Ketukan lambat tetap membuka dialog
  /// Tentang seperti biasa; dialog dilewati saat burst agar 8 ketukan
  /// cepat tidak tertutup dialog berulang.
  void _onAboutTap(BuildContext context, String lang) {
    final now = DateTime.now();
    final burst = _lastAboutTap != null &&
        now.difference(_lastAboutTap!) < AppMotion.debugTapWindow;
    if (_lastAboutTap != null &&
        now.difference(_lastAboutTap!) > DebugService.tapWindow) {
      _aboutTaps = 0;
    }
    _lastAboutTap = now;
    if (_debugEnabled) {
      _showAbout(context, lang);
      return;
    }
    _aboutTaps++;
    final remaining = DebugService.unlockTaps - _aboutTaps;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    if (remaining <= 0) {
      _aboutTaps = 0;
      unawaited(_setDebugEnabled(context, lang, true));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('debugTapToUnlock', lang, {'n': remaining}),
          ),
        ),
      );
      if (!burst) _showAbout(context, lang);
    }
  }

  /// Komposisi seksi DEBUG untuk build(). Gate `_debugEnabled` tetap di build().
  Widget _debugSection(BuildContext context, String lang) {
    final fp = context.read<FinanceProvider>();
    final settings = context.read<AppSettingsProvider>();
    return _section(AppStrings.get('debugSection', lang).toUpperCase(), [
      _tile(
        Icons.bug_report_outlined,
        AppStrings.get('notifTest', lang),
        AppStrings.get('notifTestDesc', lang),
        onTap: () async {
          if (!await guardNotifBlocked(context, lang)) return;
          await NotificationService.ensurePermission();
          await NotificationService.showSimple(
            'Kaji Finance',
            AppStrings.get('notifTestBody', lang),
          );
        },
      ),
      _tile(
        Icons.fingerprint_outlined,
        AppStrings.get('expBioTitle', lang),
        AppStrings.get('expBioDesc', lang),
        onTap: () async {
          final can = await AuthService.canCheckBiometrics();
          if (!context.mounted) return;
          if (!can) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(AppStrings.get('bioNotAvailable', lang))),
            );
            return;
          }
          final ok = await AuthService.authenticateBio();
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                ok
                    ? AppStrings.get('bioSuccess', lang)
                    : AppStrings.get('bioFailed', lang),
              ),
            ),
          );
        },
      ),
      _tile(
        Icons.preview_outlined,
        AppStrings.get('exportPreviewTitle', lang),
        AppStrings.get('exportPreviewDesc', lang),
        onTap: () => _showExportPreview(context, lang),
      ),
      _tile(
        Icons.science_outlined,
        AppStrings.get('seedDebugTitle', lang),
        AppStrings.get('seedDebugDesc', lang),
        onTap: () => _seedSampleData(context, fp, lang),
      ),
      _tile(
        Icons.fact_check_outlined,
        AppStrings.get('reconcileTitle', lang),
        AppStrings.get('reconcileDesc', lang),
        onTap: () => _showReconcile(context, fp, lang),
      ),
      _tile(
        Icons.history_outlined,
        AppStrings.get('auditTitle', lang),
        AppStrings.get('auditDesc', lang),
        onTap: () => _showAuditTrail(context, lang),
      ),
      _tile(
        Icons.memory_outlined,
        AppStrings.get('debugInfoTitle', lang),
        AppStrings.get('debugInfoDesc', lang),
        onTap: () => _showDebugInfo(context, fp, settings, lang),
      ),
      _tile(
        Icons.visibility_off_outlined,
        AppStrings.get('hideDebugTitle', lang),
        AppStrings.get('hideDebugDesc', lang),
        onTap: () => _setDebugEnabled(context, lang, false),
      ),
    ]);
  }
}
