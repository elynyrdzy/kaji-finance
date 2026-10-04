library settings_screen;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/dialogs/app_confirm.dart';
import '../l10n/app_strings.dart';
import '../models/profile_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/auth_service.dart';
import '../services/audit_service.dart';
import '../services/backup_service.dart';
import '../services/domain_errors.dart';
import '../services/profile_service.dart';
import '../services/secure_db_service.dart';
import '../services/debug_service.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/app_lock_guard.dart';
import '../utils/date_format.dart';
import '../utils/digest_scheduler.dart';
import '../utils/money_format.dart';
import '../utils/notification_guard.dart';
import '../utils/profile_switch.dart';
import '../utils/step_up_auth.dart';
import '../widgets/app_header.dart';
import '../widgets/app_keypad.dart';
import '../widgets/motion_kit.dart';
import '../widgets/wallet_dialogs.dart';
import 'backup_screen.dart';
import 'lock_screen.dart';
import 'notification_settings_screen.dart';
import 'onboarding_screen.dart';

part 'settings/sections/section_widgets.dart';
part 'settings/sections/notification_section.dart';
part 'settings/sections/account_section.dart';
part 'settings/sections/profile_crud_section.dart';
part 'settings/sections/profile_delete_section.dart';
part 'settings/sections/categories_section.dart';
part 'settings/sections/prefs_section.dart';
part 'settings/sections/security_section.dart';
part 'settings/sections/data_section.dart';
part 'settings/sections/debug_section.dart';
part 'settings/sections/debug_tools.dart';
part 'settings/sections/about_section.dart';

/// Pusat konfigurasi Kaji Finance: AKUN & PROFIL / PREFERENSI / NOTIFIKASI /
/// KEAMANAN (termasuk Vault E2EE) / RENCANA / BERBAGI (perusahaan) /
/// DATA / TENTANG. Dark-only.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pinEnabled = false;
  bool _bioEnabled = false;
  bool _bioAvailable = false;
  bool _debugEnabled = false;

  /// Profil aktif sedang terkunci lockout brute-force PIN. Mengatur
  /// visibilitas tile "Reset Lockout" di seksi Keamanan (lihat
  /// `_resetPinLockout`). Hanya relevan multi-profil: kalau semua profil
  /// terkunci, user tak bisa sampai ke Settings sama sekali.
  bool _lockoutActive = false;

  int _aboutTaps = 0;
  DateTime? _lastAboutTap;

  /// Future profil di-cache — sebelumnya `ProfileService.profiles()`
  /// (baca SharedPreferences + jsonDecode) dipanggil di dalam build(),
  /// sehingga tiap rebuild Settings men-decode ulang registry profil.
  /// Sekarang decoding hanya terjadi saat profil benar-benar berubah
  /// (load, create, delete, switch) lewat [_loadProfiles].
  Future<List<ProfileModel>> _profilesFuture = ProfileService.profiles();

  Future<void> _loadProfiles() async {
    final next = ProfileService.profiles();
    if (!mounted) return;
    setState(() => _profilesFuture = next);
    await next;
  }

  /// Helper setState untuk dipakai ekstensi part (menghindari
  /// invalid_use_of_protected_member: extension bukan subclass State,
  /// jadi tak boleh memanggil setState langsung).
  void _applyDebugEnabled(bool v) {
    if (mounted) setState(() => _debugEnabled = v);
  }

  /// Sama seperti [_applyDebugEnabled] — ekstensi part tak boleh memanggil
  /// [State.setState] langsung.
  void _applyLockoutActive(bool v) {
    if (mounted) setState(() => _lockoutActive = v);
  }

  /// Segarkan UI setelah aksi yang mengubah state provider di luar
  /// build (mis. reset total dari seksi DATA).
  void _refreshSettings() {
    if (mounted) setState(() {});
  }

  void _applySecurityState({
    required bool pin,
    required bool bio,
    required bool canBio,
    required bool dbg,
  }) {
    if (mounted) {
      setState(() {
        _pinEnabled = pin;
        _bioEnabled = bio;
        _bioAvailable = canBio;
        _debugEnabled = dbg;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // initState sinkron: refresh keamanan jalan fire-and-forget sengaja
    // (guard mounted di dalam _loadSecurity).
    unawaited(_loadSecurity());
  }

  @override
  Widget build(BuildContext context) {
    // Hanya BAHASA yang dipilih di level teratas. Kedua provider
    // 'watch' sebelumnya membuat satu perubahan setting apa pun membangun
    // ulang seluruh 29 tile sekaligus; sekarang tiap seksi memanggil
    // `context.select` sendiri untuk persis field yang ia pakai.
    final lang = context.select<AppSettingsProvider, String>(
      (s) => s.languageCode,
    );

    return Scaffold(
      appBar: AppHeader(title: AppStrings.get('settings', lang)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ---------- AKUN & PROFIL ----------
          _accountSection(context, lang),
          const SizedBox(height: 16),
          // ---------- PREFERENCES ----------
          _prefsSection(context, lang),
          const SizedBox(height: 16),
          // ---------- NOTIFIKASI ----------
          _notifSection(context, lang),
          const SizedBox(height: 16),
          // ---------- SECURITY ----------
          _securitySection(context, lang),
          const SizedBox(height: 16),
          // ---------- DATA ----------
          _dataSection(context, lang),
          const SizedBox(height: 16),
          // ---------- TENTANG ----------
          _aboutSection(context, lang),
          // ---------- DEBUG (tersembunyi: buka via 8x ketuk tile Tentang) --
          if (_debugEnabled) ...[
            const SizedBox(height: 16),
            _debugSection(context, lang),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  color: AppColors.tertiary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.get('aboutBody', lang),
                        style: AppTextStyles.bodySm(),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        AppStrings.get('developedBy', lang),
                        style: AppTextStyles.labelCaps(
                          color: AppColors.tertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
