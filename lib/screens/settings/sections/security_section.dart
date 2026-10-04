part of '../../settings_screen.dart';

/// Seksi KEAMANAN — step-up auth (batch 2, pindahan verbatim dari
/// settings_screen.dart). State PIN/bio (_loadSecurity, _setPinDialog,
/// _setDebugEnabled, _onAboutTap) tetap di parent karena memakai
/// setState/member State.
extension _SettingsSecuritySection on _SettingsScreenState {
  /// Muat ulang status keamanan ke state (boleh dipanggil kapan saja;
  /// guard mounted di dalam).
  Future<void> _loadSecurity() async {
    final pin = await AuthService.isPinEnabled();
    final bio = await AuthService.isBioEnabled();
    final canBio = await AuthService.canCheckBiometrics();
    final dbg = await DebugService.isEnabled();
    // Lockout dibaca terpisah, dalam try sendiri: kalau secure storage tak
    // bisa dibaca, pemanggilan di sini melempar dan seluruh status keamanan
    // tak akan pernah ter-render. Kegagalan ditelan, default-nya "tak
    // terkunci" (tile tidak muncul — bukan action yang salah).
    var locked = false;
    try {
      final st = await AuthService.loadLockout();
      locked = st.untilMs > DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      locked = false;
    }
    if (!mounted) return;
    _applyLockoutActive(locked);
    _applySecurityState(pin: pin, bio: bio, canBio: canBio, dbg: dbg);
  }

  void _setPinDialog(String lang) {
    // Sheet PIN bawaan aplikasi — keyboard perangkat tidak muncul.
    // Panjang 4–6 digit sudah dijamin sheet, regex tak perlu lagi.
    unawaited(
      showAppPinSheet(
        context,
        title: AppStrings.get('setPin', lang),
        cancelLabel: AppStrings.get('cancel', lang),
        okLabel: AppStrings.get('save', lang),
      ).then((pin) async {
        if (pin == null) return;
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        try {
          await AuthService.setPin(pin, enabled: true);
        } on SecureStorageException {
          // P7 fail-closed: penyimpanan aman mati → PIN tak tersimpan.
          // Jangan klaim aktif; arahkan user perbaiki perangkat.
          if (!mounted) return;
          messenger.showSnackBar(
            SnackBar(
              content: Text(AppStrings.get('secureStorageUnavailable', lang)),
              backgroundColor: AppColors.errorContainer,
            ),
          );
          await _loadSecurity();
          return;
        }
        await _loadSecurity();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.get('pinActivated', lang))),
          );
        }
      }),
    );
  }

  /// Mengganti PIN yang SUDAH aktif wajib step-up lebih dulu.
  ///
  /// Mematikan PIN sudah dilindungi konfirmasi + step-up, tapi mengganti
  /// PIN lama dengan PIN milik penyerang jauh lebih berbahaya: akibatnya
  /// permanen (pemilik asli terkunci selamanya dari profilnya) dan tak ada
  /// konfirmasi pun yang memperingatkan. Akses sesaat ke HP yang tak
  /// terkunci sudah cukup untuk melakukannya.
  ///
  /// Belum ada PIN → step-up dilewati, karena belum ada yang bisa diverifikasi
  /// sehingga memintanya hanya membingungkan.
  Future<void> _changePin(String lang) async {
    if (_pinEnabled) {
      final ok = await AppLockGuard.run(() => stepUpAuth(context, lang));
      if (!ok || !context.mounted) return;
    }
    _setPinDialog(lang);
  }

  /// Komposisi seksi KEAMANAN untuk build(). Menyentuh state (_pinEnabled
  /// dkk) — legal karena satu library via part.
  Widget _securitySection(BuildContext context, String lang) {
    final lockTimeout = context.select<AppSettingsProvider, int>(
      (s) => s.lockTimeoutSeconds,
    );
    // Rebuild sempit: hanya tile screenshot yang mendengar field ini.
    final screenshotOn = context.select<AppSettingsProvider, bool>(
      (s) => s.screenshotProtection,
    );
    return _section(AppStrings.get('security', lang).toUpperCase(), [
      _tile(
        Icons.lock_outline,
        AppStrings.get('pinLock', lang),
        _pinEnabled
            ? AppStrings.get('pinActive', lang)
            : AppStrings.get('pinInactive', lang),
        trailing: Switch(
          value: _pinEnabled,
          activeThumbColor: AppColors.tertiary,
          onChanged: (v) async {
            if (v) {
              unawaited(_changePin(lang));
            } else {
              // Mematikan PIN melemahkan keamanan aplikasi secara
              // langsung dan sedikit demi sedikit (tidak ada undo
              // selain menyetel PIN lagi) → konfirmasi + step-up.
              final go = await AppConfirm.runAsync(
                context,
                lang: lang,
                title: AppStrings.get('pinOffConfirmTitle', lang),
                message: AppStrings.get('pinOffConfirmBody', lang),
                confirmLabel: AppStrings.get('pinOffConfirmAction', lang),
                destructive: true,
                errorMessage: AppStrings.get('genericError', lang),
                beforeAction: () => stepUpAuth(context, lang),
                action: () async {
                  // Matikan total: hapus hash PIN juga, bukan cuma
                  // flag. Hash basi + bio-aktif = lockout permanen.
                  await AuthService.clearPin();
                  await AuthService.setBioEnabled(false);
                  return true;
                },
              );
              await _loadSecurity();
              if (go && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppStrings.get('pinInactive', lang))),
                );
              }
            }
          },
        ),
        onTap: () => unawaited(_changePin(lang)),
      ),
      _tile(
        Icons.fingerprint,
        AppStrings.get('biometricLock', lang),
        !_bioAvailable
            ? AppStrings.get('bioNotAvailable', lang)
            : _bioEnabled
                ? AppStrings.get('enabled', lang)
                : AppStrings.get('disabled', lang),
        trailing: Switch(
          value: _bioEnabled && _bioAvailable,
          activeThumbColor: AppColors.tertiary,
          onChanged: !_bioAvailable
              ? null
              : (v) async {
                  if (v) {
                    if (!_pinEnabled || await AuthService.getPin() == null) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppStrings.get('activatePinFirst', lang),
                          ),
                          backgroundColor: AppColors.errorContainer,
                        ),
                      );
                      _setPinDialog(lang);
                      return;
                    }
                    // Cek ulang saat ditekan (state cache bisa basi
                    // bila user baru mendaftarkan sidik jari).
                    final can = await AuthService.canCheckBiometrics();
                    if (!context.mounted) return;
                    if (!can) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppStrings.get('bioNotAvailable', lang),
                          ),
                        ),
                      );
                      await _loadSecurity();
                      return;
                    }
                    final ok = await AuthService.authenticateBio();
                    if (!context.mounted) return;
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(AppStrings.get('bioFailed', lang)),
                        ),
                      );
                      await _loadSecurity();
                      return;
                    }
                    await AuthService.setBioEnabled(true);
                  } else {
                    await AuthService.setBioEnabled(false);
                  }
                  await _loadSecurity();
                },
        ),
      ),
      _tile(
        Icons.timer_outlined,
        AppStrings.get('lockTimeout', lang),
        _timeoutLabel(lockTimeout, lang),
        onTap: () => _chooseTimeout(context, lang),
      ),
      // Anti-intip opsional (default MATI): FLAG_SECURE via channel native.
      // Ketuk baris = toggle, sama seperti switch-nya.
      _tile(
        Icons.screenshot_monitor_outlined,
        AppStrings.get('screenshotProtection', lang),
        AppStrings.get('screenshotProtectionDesc', lang),
        trailing: Switch(
          value: screenshotOn,
          activeThumbColor: AppColors.tertiary,
          onChanged: (v) {
            final settings = context.read<AppSettingsProvider>();
            settings.applySilently(() => settings.setScreenshotProtection(v));
          },
        ),
        onTap: () {
          final settings = context.read<AppSettingsProvider>();
          settings.applySilently(
            () => settings.setScreenshotProtection(!screenshotOn),
          );
        },
      ),
      _tile(
        Icons.security_outlined,
        AppStrings.get('lockNow', lang),
        AppStrings.get('lockNowDesc', lang),
        onTap: () async {
          final pin = await AuthService.isPinEnabled();
          final bio = await AuthService.isBioEnabled();
          if (!context.mounted) return;
          if (!pin && !bio) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(AppStrings.get('activatePinFirst', lang))),
            );
            return;
          }
          // Kunci nyata: tampilkan LockScreen; buka kembali via PIN/bio.
          // Hasil push sengaja diabaikan (unawaited): dialog kunci
          // selesai lewat maybePop dari dalam LockScreen.
          unawaited(
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LockScreen(
                  onUnlocked: () => Navigator.of(context).maybePop(),
                ),
                fullscreenDialog: true,
              ),
            ),
          );
        },
      ),
      // Pemulihan khusus multi-profil: profil B bisa terkunci lockout
      // sementara user masih bisa masuk lewat profil A — tanpa ini, profil B
      // hanya bisa menunggu timer atau dihapus. Step-up wajib (lihat
      // [_resetPinLockout]) karena ini menyentuh gerbang keamanan.
      if (_lockoutActive)
        _tile(
          Icons.lock_reset_outlined,
          AppStrings.get('lockoutReset', lang),
          AppStrings.get('lockoutResetDesc', lang),
          onTap: () => unawaited(_resetPinLockout(context, lang)),
        ),
    ]);
  }
}
