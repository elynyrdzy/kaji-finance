import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../services/notification_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/digest_scheduler.dart';
import '../utils/notification_guard.dart';

/// Nilai notifikasi yang benar-benar ditampilkan layar ini. Dipakai
/// `select` supaya hanya baris yang berubah yang dibangun ulang — bukan
/// setiap perubahan setting lain di aplikasi.
@immutable
class _NotifView {
  final bool enabled;
  final int hour;
  final int minute;
  final bool optBudget;
  final bool optGoals;
  final bool optWallets;
  final bool optNudge;
  final bool budgetAlert;

  const _NotifView({
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.optBudget,
    required this.optGoals,
    required this.optWallets,
    required this.optNudge,
    required this.budgetAlert,
  });

  @override
  bool operator ==(Object other) =>
      other is _NotifView &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute &&
      other.optBudget == optBudget &&
      other.optGoals == optGoals &&
      other.optWallets == optWallets &&
      other.optNudge == optNudge &&
      other.budgetAlert == budgetAlert;

  @override
  int get hashCode => Object.hash(
        enabled,
        hour,
        minute,
        optBudget,
        optGoals,
        optWallets,
        optNudge,
        budgetAlert,
      );
}

/// Sub-layar NOTIFIKASI — semua kendali yang dulu mendatar di Pengaturan,
/// dipindah ke sini lewat satu tile hub (pola tile Cadangan → BackupScreen).
///
/// Susunannya sengaja mengikuti ketergantungan, bukan urutan kronologis:
/// kartu master (tanpa judul grup) adalah satu-satunya kendali kuat, grup
/// "isi ringkasan" bergantung padanya, dan peringatan anggaran berdiri
/// sendiri. Saat master mati, grup bergantung diredupkan — bukan dikunci —
/// supaya pilihan isi tak hilang dan tetap bisa disiapkan sebelum dinyalakan.
class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  String _fmt(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Future<void> _toggleDigest(BuildContext context, String lang, bool v) async {
    final settings = context.read<AppSettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final fp = context.read<FinanceProvider>();
    if (!v) {
      await settings.setDigestEnabled(false).catchError((_) {});
      await refreshDigestSchedule(fp, settings);
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('digestOff', lang))),
      );
      return;
    }
    if (!await guardNotifBlocked(context, lang)) return;
    if (!await NotificationService.ensurePermission()) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('notifDenied', lang)),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return;
    }
    await settings.setDigestEnabled(true).catchError((_) {});
    // Alarm tepat-waktu (Android 12+): tanpa izin jadwal tetap jalan
    // mode inexact (bisa meleset) — beri tahu sekali.
    var exact = await NotificationService.canScheduleExact();
    if (!exact) exact = await NotificationService.requestExactAlarms();
    await refreshDigestSchedule(fp, settings);
    if (!context.mounted) return;
    // Satu snackbar hasil akhir: tanpa izin exact = peringatan, bila ada =
    // konfirmasi jadwal. (Dua snackbar bertumpuk membingungkan.)
    final exactOk = exact;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          exactOk
              ? AppStrings.fill('digestScheduled', lang, {
                  't': _fmt(settings.digestHour, settings.digestMinute),
                })
              : AppStrings.get('exactAlarmNeeded', lang),
        ),
        backgroundColor:
            exactOk ? AppColors.tertiary : AppColors.errorContainer,
      ),
    );
  }

  Future<void> _pickDigestTime(
    BuildContext context,
    String lang,
    _NotifView digest,
  ) async {
    final settings = context.read<AppSettingsProvider>();
    // Baca provider sebelum gap async (aturan use_build_context).
    final fp = context.read<FinanceProvider>();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: digest.hour, minute: digest.minute),
      helpText: AppStrings.get('digestTime', lang),
    );
    if (picked == null) return;
    // Setter menjepit ke 06–21 (jam tenang); snackbar menampilkan hasil —
    // jadi jam dibaca dari provider SESUDAH await, bukan dari `digest`
    // (snapshot build-time: memilih 05:00 akan menampilkan "terjadwal
    // 05:00" padahal yang tersimpan 06:00).
    await settings.setDigestTime(picked.hour, picked.minute).catchError((_) {});
    await refreshDigestSchedule(fp, settings);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.fill('digestScheduled', lang, {
            't': _fmt(settings.digestHour, settings.digestMinute),
          }),
        ),
        backgroundColor: AppColors.tertiary,
      ),
    );
  }

  /// Kartu utama: master ringkasan harian. Permukaannya lebih terang dan
  /// ikonnya menyala hijau saat hidup — di layar ini dialah yang paling
  /// penting untuk diputuskan.
  Widget _masterCard(BuildContext context, String lang, _NotifView view) {
    final on = view.enabled;
    return _card(
        context,
        [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            visualDensity: VisualDensity.comfortable,
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: on
                    ? AppColors.tertiaryContainer
                    : AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.schedule_outlined,
                color: on ? AppColors.tertiary : AppColors.onSurfaceVariant,
                size: 19,
              ),
            ),
            title: Text(
              AppStrings.get('digestDaily', lang),
              style: AppTextStyles.headlineSm(),
            ),
            subtitle: Text(
              AppStrings.get('digestDailyDesc', lang),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySm(),
            ),
            trailing: Switch(
              value: on,
              activeThumbColor: AppColors.tertiary,
              onChanged: (v) => _toggleDigest(context, lang, v),
            ),
            onTap: () => _toggleDigest(context, lang, !on),
          ),
          // Jam tersimpan walau master mati — meredupkan (bukan mengunci)
          // karena menyiapkannya lebih awal tetap berguna.
          AnimatedOpacity(
            opacity: on ? 1 : 0.5,
            duration: AppMotion.durationFor(context, AppMotion.medium),
            curve: AppMotion.pageCurve,
            child: _tileRow(
              Icons.access_time_outlined,
              AppStrings.get('digestTime', lang),
              _fmt(view.hour, view.minute),
              onTap: () => _pickDigestTime(context, lang, view),
            ),
          ),
        ],
        color: AppColors.surfaceContainer);
  }

  /// Satu opsi isi ringkasan. Nilai disimpan meski master mati agar tak
  /// hilang; [set] tetap menyegarkan jadwal karena penyesuaian isi bisa
  /// dilakukan lebih dulu.
  Widget _optTile(
    BuildContext context,
    AppSettingsProvider settings,
    String lang,
    IconData icon,
    String title,
    bool value,
    Future<void> Function(bool v) apply,
  ) {
    Future<void> set(bool v) async {
      final fp = context.read<FinanceProvider>();
      // Setter sudah rollback sendiri bila gagal; jangan sampai
      // error-nya jadi unhandled exception dari callback switch.
      await apply(v).catchError((_) {});
      if (!context.mounted) return;
      await refreshDigestSchedule(fp, settings);
    }

    return _tileRow(
      icon,
      title,
      value
          ? AppStrings.get('enabled', lang)
          : AppStrings.get('disabled', lang),
      trailing: Switch(
        value: value,
        activeThumbColor: AppColors.tertiary,
        onChanged: set,
      ),
      onTap: () => set(!value),
    );
  }

  /// Peringatan anggaran: berdiri sendiri dari jadwal, jadi tak ikut
  /// meredup saat digest mati. Ketuk baris atau switch-nya menyetel
  /// [FinanceProvider.budgetAlertsOn] agar threshold langsung berlaku.
  Widget _budgetAlertTile(
    BuildContext context,
    AppSettingsProvider settings,
    String lang,
    _NotifView view,
  ) {
    Future<void> set(bool v) async {
      final fp = context.read<FinanceProvider>();
      await settings.setBudgetAlertEnabled(v).catchError((_) {});
      // Sumber kebenaran = provider, bukan nilai yang diminta: setter
      // rollback + lempar ulang saat tulis prefs gagal, jadi `v` bisa
      // menyesatkan (UI snap-back ke ON tapi `budgetAlertsOn` mati →
      // semua peringatan anggaran diam tak berbunyi).
      fp.budgetAlertsOn = settings.budgetAlertEnabled;
    }

    return _tileRow(
      Icons.pie_chart_outline,
      AppStrings.get('notifBudgetAlert', lang),
      AppStrings.get('notifBudgetDesc', lang),
      trailing: Switch(
        value: view.budgetAlert,
        activeThumbColor: AppColors.tertiary,
        onChanged: set,
      ),
      onTap: () => set(!view.budgetAlert),
    );
  }

  /// Judul grup + satu kalimat petunjuk + kartu isinya. Setara mandiri
  /// `_section` dari Pengaturan, yang hanya tersedia di file `part`.
  Widget _group(
    String lang, {
    required String titleKey,
    required String hintKey,
    required Widget card,
    Widget? footnote,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Text(
            AppStrings.get(titleKey, lang).toUpperCase(),
            style: AppTextStyles.labelCaps(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            AppStrings.get(hintKey, lang),
            style: AppTextStyles.bodySm(),
          ),
        ),
        card,
        if (footnote != null) footnote,
      ],
    );
  }

  /// Kartu rounded 16 dengan garis tipis dan pemisah antar baris — nilai
  /// visual yang sama persis dengan `_section` di Pengaturan.
  /// [dimmed] menurunkan bobot sekelompok baris tanpa mengubah statusnya.
  Widget _card(
    BuildContext context,
    List<Widget> rows, {
    Color? color,
    bool dimmed = false,
  }) {
    final separated = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      separated.add(rows[i]);
      if (i < rows.length - 1) {
        separated.add(
          Divider(
            height: 1,
            thickness: 0.6,
            indent: 56,
            endIndent: 16,
            color: AppColors.outlineVariant.withValues(alpha: 0.45),
          ),
        );
      }
    }
    final card = Material(
      color: color ?? AppColors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.35),
            width: 0.6,
          ),
        ),
        child: Column(children: separated),
      ),
    );
    if (!dimmed) return card;
    return AnimatedOpacity(
      opacity: 0.5,
      duration: AppMotion.durationFor(context, AppMotion.medium),
      curve: AppMotion.pageCurve,
      child: card,
    );
  }

  /// Baris daftar — padanan `_tile` dari Pengaturan (tanpa `part`).
  Widget _tileRow(
    IconData icon,
    String title,
    String subtitle, {
    Widget? trailing,
    VoidCallback? onTap,
  }) =>
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        visualDensity: VisualDensity.comfortable,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.onSurfaceVariant, size: 19),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyMd().copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodySm(),
        ),
        trailing: trailing ??
            const Icon(Icons.chevron_right, color: AppColors.outline, size: 18),
        onTap: onTap,
      );

  /// Catatan jam tenang sebagai kaki grup — di luar kartu supaya tidak
  /// terbaca sebagai baris yang bisa diketuk.
  Widget _quietNote(String lang) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.bedtime_outlined,
            size: 13,
            color: AppColors.outline,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              AppStrings.get('quietNote', lang),
              style: AppTextStyles.bodySm(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.select<AppSettingsProvider, String>(
      (s) => s.languageCode,
    );
    // Hanya nilai yang tampil yang dipilih; setter dipanggil lewat `read`
    // di dalam baris, jadi layar ini tak dibangun ulang karena bagian
    // aplikasi lain yang berubah.
    final view = context.select<AppSettingsProvider, _NotifView>(
      (s) => _NotifView(
        enabled: s.digestEnabled,
        hour: s.digestHour,
        minute: s.digestMinute,
        optBudget: s.digestOptBudget,
        optGoals: s.digestOptGoals,
        optWallets: s.digestOptWallets,
        optNudge: s.digestOptNudge,
        budgetAlert: s.budgetAlertEnabled,
      ),
    );
    final settings = context.read<AppSettingsProvider>();
    final digestOn = view.enabled;

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(AppStrings.get('notifSection', lang)),
        backgroundColor: AppColors.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // ---------- MASTER ----------
          _GroupEntrance(index: 0, child: _masterCard(context, lang, view)),
          const SizedBox(height: 18),
          // ---------- ISI RINGKASAN (bergantung pada master) ----------
          _GroupEntrance(
            index: 1,
            child: _group(
              lang,
              titleKey: 'notifContent',
              hintKey: 'notifContentDesc',
              card: _card(
                context,
                [
                  _optTile(
                    context,
                    settings,
                    lang,
                    Icons.account_balance_wallet_outlined,
                    AppStrings.get('digestOptBudget', lang),
                    view.optBudget,
                    settings.setDigestOptBudget,
                  ),
                  _optTile(
                    context,
                    settings,
                    lang,
                    Icons.savings_outlined,
                    AppStrings.get('digestOptGoals', lang),
                    view.optGoals,
                    settings.setDigestOptGoals,
                  ),
                  _optTile(
                    context,
                    settings,
                    lang,
                    Icons.wallet_outlined,
                    AppStrings.get('digestOptWallets', lang),
                    view.optWallets,
                    settings.setDigestOptWallets,
                  ),
                  _optTile(
                    context,
                    settings,
                    lang,
                    Icons.edit_calendar_outlined,
                    AppStrings.get('digestOptNudge', lang),
                    view.optNudge,
                    settings.setDigestOptNudge,
                  ),
                ],
                // Tanpa master aktif, tak ada yang dikirim pagi hari —
                // redupkan sekalian agar urutannya terbaca.
                dimmed: !digestOn,
              ),
              footnote: _quietNote(lang),
            ),
          ),
          const SizedBox(height: 18),
          // ---------- PERINGATAN LANGSIR (independen) ----------
          _GroupEntrance(
            index: 2,
            child: _group(
              lang,
              titleKey: 'notifStandalone',
              hintKey: 'notifStandaloneDesc',
              card: _card(context, [
                _budgetAlertTile(context, settings, lang, view),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Munculnya tiap grup saat sub-layar dibuka: fade + naik tipis, jeda
/// berjenjang dari [AppMotion]. Reduced motion → tampil langsung, tanpa
/// controller yang tak terlihat hasilnya.
class _GroupEntrance extends StatefulWidget {
  final int index;
  final Widget child;

  const _GroupEntrance({required this.index, required this.child});

  @override
  State<_GroupEntrance> createState() => _GroupEntranceState();
}

class _GroupEntranceState extends State<_GroupEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: AppMotion.medium, vsync: this);
    _anim = CurvedAnimation(parent: _ctrl, curve: AppMotion.pageCurve);
    Future.delayed(AppMotion.staggerDelay(widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}
