import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/secure_db_service.dart';
import '../utils/app_nav.dart';
import '../utils/digest_scheduler.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/motion_kit.dart';
import 'analytics_screen.dart';
import 'budget_screen.dart';
import 'debts_screen.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _onboardingShown = false;
  bool _digestScheduled = false;

  void _goTo(int i) => setState(() => _index = i);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Daftarkan pemindah tab agar sheet profil bisa membuka Pengaturan.
    AppNav.goToTab = _goTo;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (AppNav.goToTab == _goTo) AppNav.goToTab = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Tulis tertunda wajib mendarat SEBELUM potensi kunci/mati proses:
    // tanpa flush, mutasi terakhir bisa hilang dan terlihat "tereset"
    // saat aplikasi dibuka lagi. Jadwal digest ikut disegarkan agar
    // isinya mencerminkan data terbaru.
    if (state == AppLifecycleState.paused) {
      try {
        final fp = context.read<FinanceProvider>();
        final settings = context.read<AppSettingsProvider>();
        unawaited(fp.flushAll());
        unawaited(refreshDigestSchedule(fp, settings));
      } catch (e) {
        SecureDbService.noteError('Root: flush saat pause gagal: $e');
      }
    }
  }

  void _maybeScheduleDigest(FinanceProvider fp, AppSettingsProvider settings) {
    // Sekali per proses setelah kedua provider selesai load.
    if (_digestScheduled || !fp.prefsLoaded || !settings.settingsLoaded) {
      return;
    }
    _digestScheduled = true;
    unawaited(refreshDigestSchedule(fp, settings));
  }

  void _maybeShowOnboarding(FinanceProvider fp) {
    // Tunggu prefs selesai dimuat agar tidak flash onboarding saat cold start.
    if (!fp.prefsLoaded || fp.onboardingDone || !fp.isEmpty) return;
    // Reset total mengembalikan fp.onboardingDone=false + isEmpty=true
    // sementara _onboardingShown masih true di memori — nol-kan agar
    // panduan setup awal tampil lagi setelah "Reset Semua Data".
    if (fp.isEmpty && !fp.onboardingDone) _onboardingShown = false;
    if (_onboardingShown) return;
    _onboardingShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const OnboardingScreen(),
          fullscreenDialog: true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsProvider>();
    final screens = [
      HomeScreen(onNavigate: _goTo),
      const TransactionsScreen(),
      const BudgetScreen(),
      const AnalyticsScreen(),
      const SettingsScreen(),
    ];

    return Consumer<FinanceProvider>(
      builder: (_, fp, __) {
        // DB gagal dibuka → jangan pernah tampilkan shell dengan data kosong.
        // Itu kontradiksi langsung dengan keadaan sebenarnya dan mendorong
        // user mengira artefak datanya hilang (bisa saja ia masih ada di disk).
        if (fp.dbLoadFailed) return const _DbLoadFailedScreen();
        _maybeShowOnboarding(fp);
        _maybeScheduleDigest(fp, settings);
        return Scaffold(
          body: IndexedStack(
            index: _index,
            // TickerMode: layar di luar tab aktif tidak boleh menjalankan
            // ticker-nya. Tanpa ini semua 5 layar tetap beranimasi
            // sepanjang sesi meski tak terlihat.
            children: List.generate(
              screens.length,
              (i) => TickerMode(
                enabled: _index == i,
                child: TabEntrance(active: _index == i, child: screens[i]),
              ),
            ),
          ),
          // Entry mini-ledger Hutang (BottomNav 5 tab tak tersentuh):
          // tombol kecil kiri-bawah di tab Beranda/Transaksi membuka
          // DebtsScreen sebagai route push agar state tab tetap utuh.
          // (startFloat: FAB kanan milik layar Transaksi tak tertutup.)
          floatingActionButton: (_index == 0 || _index == 1)
              ? FloatingActionButton.small(
                  heroTag: 'debts_entry',
                  backgroundColor: AppColors.surfaceContainerHighest,
                  foregroundColor: AppColors.onSurfaceVariant,
                  tooltip: 'Hutang',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DebtsScreen()),
                  ),
                  child: const Icon(Icons.handshake_outlined),
                )
              : null,
          floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
          bottomNavigationBar: BottomNavBar(currentIndex: _index, onTap: _goTo),
        );
      },
    );
  }
}

/// Layar bantalan saat DB terenkripsi gagal dibuka di cold start.
///
/// Sengaja menggantikan shell, bukan dialog di atasnya: shell dengan data
/// kosong menampilkan saldo nol, daftar kosong, dan angka nol yang
/// meyakinkan user datanya hilang — padahal isinya masih utuh di disk dan
/// hanya tidak terbaca. Menutupi shell juga mencegah onboarding dan
/// full-state flush ikut berjalan di atas state kosong.
class _DbLoadFailedScreen extends StatelessWidget {
  const _DbLoadFailedScreen();

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const EmptyArt(icon: Icons.lock_outline, size: 36),
                const SizedBox(height: 16),
                Text(
                  AppStrings.get('loadError', lang),
                  style: AppTextStyles.headlineSm(),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.get('dbLoadFailedHint', lang),
                  style: AppTextStyles.bodySm(),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
