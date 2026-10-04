import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../services/app_log.dart';
import '../services/auth_service.dart';
import '../services/debug_service.dart';
import '../services/secure_db_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../widgets/app_keypad.dart';
import '../widgets/motion_kit.dart';

class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  // PIN diketik via keyboard bawaan aplikasi (AppKeypad) — tidak ada
  // TextField agar keyboard perangkat tidak muncul.
  String _pin = '';
  final _shake = ShakeController();

  /// Timer penyegaran tampilan saat lockout aktif. Dibatalkan di dispose.
  Timer? _lockoutTimer;
  static const _maxPinLength = 6;
  bool _bioAvailable = false;
  bool _checking = false;

  // Rate-limit anti brute-force dengan backoff eksponensial (R3):
  // 5x salah → 30 dtk, lalu 60 dtk, lalu 5 mnt (bertahan hingga sukses).
  // SATU sumber kebenaran di AuthService (maxPinAttempts/lockoutDurations);
  // state persist di flutter_secure_storage via AuthService (fail-closed),
  // ter-scope profil aktif. Jangan duplikasi konstanta di sini.
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// Lockout beruntun (persist) — menentukan durasi jeda berikutnya.
  int _lockoutStreak = 0;

  int _lockoutSecondsForStreak() =>
      AuthService.lockoutSecondsForStreak(_lockoutStreak);

  bool get _isLockedOut {
    final until = _lockedUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _lockedUntil = null;
      _failedAttempts = 0;
      unawaited(_persistLockoutState());
      return false;
    }
    return true;
  }

  int get _lockoutRemaining => _lockedUntil == null
      ? 0
      : _lockedUntil!
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, AuthService.lockoutDurations.last);

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _shake.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadLockoutState();
    _checkBio();
    _tryBio();
  }

  /// R3: muat lockout dari secure storage via AuthService (fail-closed).
  /// Baca gagal → AuthService mengunci 300 dtk (tidak bisa di-bypass via
  /// keystore rusak). Migrasi prefs lawas → secure ditangani di sana.
  Future<void> _loadLockoutState() async {
    try {
      final s = await AuthService.loadLockout();
      DateTime? until;
      if (s.untilMs > 0) {
        final cand = DateTime.fromMillisecondsSinceEpoch(s.untilMs);
        if (DateTime.now().isBefore(cand)) {
          until = cand;
        } else {
          // Lockout kedaluwarsa: mulai bersih seperti perilaku lama.
          unawaited(AuthService.clearLockout());
          if (mounted) {
            setState(() {
              _lockedUntil = null;
              _failedAttempts = 0;
            });
          }
          return;
        }
      }
      // Pulihkan hitungan salah walau tanpa lockout aktif — menutup
      // bypass 4x-tebak + restart (counter sub-lockout ikut persist).
      if (mounted) {
        setState(() {
          _lockedUntil = until;
          _failedAttempts = s.failed;
          _lockoutStreak = s.streak;
        });
      }
    } on Object catch (e) {
      SecureDbService.noteError('Lock: pulihkan status lockout gagal: $e');
      AppLog.error('lock.load_failed', e);
    }
  }

  /// R3: simpan lockout ke secure storage via AuthService (fail-closed).
  /// Tulis gagal → throw SecureStorageException di AuthService; di sini
  /// dicatat + state in-memory dipertahankan (tetap terkunci di sesi ini).
  Future<void> _persistLockoutState() async {
    try {
      if (_lockedUntil != null || _failedAttempts > 0 || _lockoutStreak > 0) {
        await AuthService.saveLockout(
          untilMs: _lockedUntil?.millisecondsSinceEpoch ?? 0,
          failed: _failedAttempts,
          streak: _lockoutStreak,
        );
      } else {
        await AuthService.clearLockout();
      }
    } on Object catch (e) {
      SecureDbService.noteError('Lock: simpan status lockout gagal: $e');
      AppLog.error('lock.save_failed', e);
    }
  }

  Future<void> _checkBio() async {
    final can = await AuthService.canCheckBiometrics();
    final enabled = await AuthService.isBioEnabled();
    if (mounted) setState(() => _bioAvailable = can && enabled);
  }

  Future<void> _tryBio() async {
    final enabled = await AuthService.isBioEnabled();
    if (!enabled) return;
    final can = await AuthService.canCheckBiometrics();
    if (!can) return;
    await Future.delayed(AppMotion.bioGrace);
    final ok = await AuthService.authenticateBio();
    if (ok && mounted) widget.onUnlocked();
  }

  void _submit() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    // Tangkap messenger sebelum gap async agar lolos
    // use_build_context_synchronously.
    final messenger = ScaffoldMessenger.of(context);
    if (_isLockedOut) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('pinLockedOutRetry', lang, {
              'n': _lockoutRemaining,
            }),
          ),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return;
    }
    setState(() => _checking = true);
    final ok = await AuthService.verifyPin(_pin);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _pin = '';
    });
    if (ok) {
      _failedAttempts = 0;
      _lockedUntil = null;
      _lockoutStreak = 0;
      await _persistLockoutState();
      if (!mounted) return;
      AppMotion.success();
      widget.onUnlocked();
    } else {
      _failedAttempts++;
      if (!mounted) return;
      // Goyang indikator + haptik warn agar salah terasa seketika.
      _shake.shake();
      AppMotion.warn();
      if (_failedAttempts >= AuthService.maxPinAttempts) {
        final seconds = _lockoutSecondsForStreak();
        _lockedUntil = DateTime.now().add(Duration(seconds: seconds));
        _failedAttempts = 0;
        _lockoutStreak = (_lockoutStreak + 1).clamp(
          0,
          AuthService.lockoutDurations.length - 1,
        );
        await _persistLockoutState();
        if (!mounted) return;
        unawaited(DebugService.logEvent('pin_lockout'));
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.fill('pinLockedOut', lang, {'n': seconds}),
            ),
            backgroundColor: AppColors.errorContainer,
          ),
        );
        // Timer disimpan agar bisa dibatalkan saat widget dibuang.
        // Sebelumnya `Future.delayed` 5 menit menahan State tetap hidup
        // setelah layar kunci ditutup.
        _lockoutTimer?.cancel();
        _lockoutTimer = Timer(Duration(seconds: seconds), () {
          if (mounted) setState(() {});
        });
      } else {
        await _persistLockoutState();
        if (!mounted) return;
        unawaited(DebugService.logEvent('pin_wrong'));
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.fill('pinWrong', lang, {
                'n': AuthService.maxPinAttempts - _failedAttempts,
              }),
            ),
            backgroundColor: AppColors.errorContainer,
          ),
        );
      }
    }
  }

  void _onKey(String k) {
    if (_checking || _isLockedOut) return;
    // Keypad punya tombol '000': untuk PIN hanya 1 digit per ketuk
    // (tanpa ini 1 ketukan = 3 digit sekaligus).
    final digits = k.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return;
    final next = _pin + digits[digits.length - 1];
    if (next.length > _maxPinLength) return;
    setState(() => _pin = next);
  }

  void _onBackspace() {
    if (_checking || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.tertiary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  size: 36,
                  color: AppColors.tertiary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.get('appLocked', lang),
                style: AppTextStyles.headlineLg(),
                textAlign: TextAlign.center,
              ),
              Text(
                AppStrings.get('lockSubtitle', lang),
                style: AppTextStyles.bodySm(),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Shakeable(
                  controller: _shake,
                  child: AppPinDots(filled: _pin.length),
                ),
              ),
              const SizedBox(height: 12),
              AppKeypad(onKey: _onKey, onBackspace: _onBackspace),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.tertiary,
                  ),
                  // PIN valid 4–6 digit: cegah submit pendek yang hanya
                  // menghabiskan jatah percobaan (audit P3-J).
                  onPressed: _checking || _pin.length < 4 ? null : _submit,
                  child: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          AppStrings.get('unlock', lang),
                          style: AppTextStyles.labelSm(
                            color: AppColors.onTertiary,
                          ),
                        ),
                ),
              ),
              if (_bioAvailable) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.outlineVariant),
                    ),
                    onPressed: _tryBio,
                    icon: const Icon(
                      Icons.fingerprint,
                      color: AppColors.tertiary,
                    ),
                    label: Text(
                      AppStrings.get('unlockWithBio', lang),
                      style: AppTextStyles.labelSm(),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
