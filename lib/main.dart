import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/app_settings_provider.dart';
import 'providers/finance_provider.dart';
import 'screens/add_transaction_screen.dart';
import 'screens/savings_goals_screen.dart';
import 'screens/root_shell.dart';
import 'screens/lock_screen.dart';
import 'services/auth_service.dart';
import 'services/backup_service.dart';
import 'services/notification_service.dart';
import 'services/profile_service.dart';
import 'services/secure_db_service.dart';
import 'theme/app_theme.dart';
import 'utils/app_lock_guard.dart';
import 'utils/app_nav.dart';
import 'widgets/motion_kit.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Muat simbol tanggal id/en agar DateFormat(..., 'id') tidak throw
  // LocaleDataException baik di device maupun di flutter test.
  try {
    await initializeDateFormatting('id');
  } catch (_) {
    // best-effort: simbol tanggal id gagal → format tanggal fallback default.
  }
  try {
    await initializeDateFormatting('en');
  } catch (_) {
    // best-effort: simbol tanggal en gagal → format tanggal fallback default.
  }
  // Izin notifikasi TIDAK diminta di cold start (P1-2): prompt berulang
  // mengganggu. Diminta lazy saat momen relevan — lihat
  // NotificationService.showBudgetAlert/showSimple (ensurePermission)
  // dan tile notifikasi di Settings. Init sendiri idempoten: pemanggil
  // alert memanggil init() lagi bila perlu, jadi cold start tak tertahan.
  unawaited(NotificationService.init());
  // Profil aktif + database-nya disiapkan SEBELUM provider pertama
  // membaca data (provider membaca kunci ter-scope profil).
  await ProfileService.init();
  await SecureDbService.useProfile(ProfileService.activeId);
  // Deteksi restore yang terinterupsi (crash/kill di tengah tulis).
  // Best-effort, tak boleh menahan cold start.
  unawaited(BackupService.checkRestoreJournal().catchError((_) {}));
  runApp(const KajiFinanceApp());
}

class KajiFinanceApp extends StatefulWidget {
  const KajiFinanceApp({super.key});
  @override
  State<KajiFinanceApp> createState() => _KajiFinanceAppState();
}

class _KajiFinanceAppState extends State<KajiFinanceApp>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _checked = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppNav.navigatorKey = GlobalKey<NavigatorState>();
    NotificationService.onResponse = _onNotifResponse;
    _checkLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Hanya paused yang dicatat. State inactive juga muncul saat overlay
    // sistem (file-picker, share-sheet, prompt biometrik) sehingga ikut
    // mengunci akan mengganggu alur backup/restore & autentikasi.
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      _maybeLockOnPause();
    } else if (state == AppLifecycleState.resumed) {
      _maybeLockOnResume();
    }
  }

  /// Kunci bila PIN *atau* biometrik aktif (§21-§24).
  static Future<bool> _securityEnabled() async {
    final pin = await AuthService.isPinEnabled();
    final bio = await AuthService.isBioEnabled();
    return pin || bio;
  }

  Future<void> _checkLock() async {
    final enabled = await _securityEnabled();
    if (mounted) {
      setState(() {
        _locked = enabled;
        _checked = true;
      });
    }
  }

  Future<void> _maybeLockOnPause() async {
    // Jangan kunci saat overlay sistem / operasi sensitif berjalan
    // (file-picker, share-sheet, prompt biometrik di sebagian ROM
    // dilaporkan sebagai paused). Lihat AppLockGuard.
    // Penting: _pausedAt sudah dicatat pemanggil sebelum cek ini —
    // nol-kan agar resume berikutnya tidak mengunci alur import/share.
    if (AppLockGuard.isBusy) {
      _pausedAt = null;
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      final timeout = p.getInt(ProfileService.scoped('kaji_lock_timeout')) ?? 0;
      if (timeout <= 0) {
        final enabled = await _securityEnabled();
        if (enabled && mounted) setState(() => _locked = true);
      }
    } catch (e) {
      SecureDbService.noteError('App: baca timeout kunci gagal saat pause: $e');
    }
  }

  Future<void> _maybeLockOnResume() async {
    if (_locked) return;
    // Operasi sensitif baru selesai (flag dilepas tepat sebelum resume
    // tiba) — beri kesempatan satu frame agar tidak langsung terkunci.
    // Masa tenggang 2 detik setelah guard keluar menutup race: run()
    // selesai (flag dilepas) tepat sebelum event resumed tiba, sehingga
    // isBusy sudah false padahal paused dicatat saat overlay terbuka.
    if (AppLockGuard.isBusy) {
      _pausedAt = null;
      return;
    }
    final lastExit = AppLockGuard.lastExit;
    if (lastExit != null && DateTime.now().difference(lastExit).inSeconds < 2) {
      _pausedAt = null;
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      final timeout = p.getInt(ProfileService.scoped('kaji_lock_timeout')) ?? 0;
      final pausedAt = _pausedAt;
      // Tanpa catatan pause (fresh start) jangan paksa kunci ulang —
      // _checkLock awal sudah menentukan status.
      if (pausedAt == null) return;
      final elapsed = DateTime.now().difference(pausedAt).inSeconds;
      if (elapsed >= timeout) await _checkLock();
    } catch (e) {
      SecureDbService.noteError(
        'App: baca timeout kunci gagal saat resume: $e',
      );
    }
  }

  void _unlock() => setState(() {
        _locked = false;
        _pausedAt = null;
      });

  /// Rute ketukan notifikasi (payload/action dari NotificationService).
  /// Kunci diutamakan: tak ada navigasi data selagi terkunci.
  void _onNotifResponse(String? payload, String? actionId) {
    if (_locked) return;
    final nav = AppNav.navigatorKey?.currentState;
    if (actionId == 'add' || payload == 'add') {
      nav?.push(
        MaterialPageRoute(builder: (_) => const AddTransactionScreen()),
      );
      return;
    }
    if (payload == 'budget') {
      AppNav.goToTab?.call(2);
      return;
    }
    if (payload == 'savings') {
      nav?.push(MaterialPageRoute(builder: (_) => const SavingsGoalsScreen()));
    }
    // 'digest' / lain: cukup buka aplikasi (Beranda).
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => FinanceProvider()),
        ChangeNotifierProvider(create: (_) => AppSettingsProvider()),
      ],
      child: MaterialApp(
        title: 'Kaji Finance',
        debugShowCheckedModeBanner: false,
        navigatorKey: AppNav.navigatorKey,
        theme: AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        // Responsif font sistem: hormati aksesibilitas secukupnya tapi
        // cegah overflow layout bila pengguna memakai font raksasa (>130%).
        builder: (ctx, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.3,
          child: child ?? const SizedBox.shrink(),
        ),
        home: EntranceFade(
          key: ValueKey('$_checked-$_locked'),
          child: !_checked
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _locked
                  ? LockScreen(onUnlocked: _unlock)
                  : const RootShell(),
        ),
      ),
    );
  }
}
