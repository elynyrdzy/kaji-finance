part of '../../settings_screen.dart';

/// Status ringkas notifikasi untuk tile hub di Pengaturan — layar ini tak
/// lagi membangun ulang karena nilai yang tak diringkas di sini (opsi isi,
/// menit, dst).
@immutable
class _NotifStatusView {
  final bool digestOn;
  final int hour;
  final int minute;

  const _NotifStatusView({
    required this.digestOn,
    required this.hour,
    required this.minute,
  });

  @override
  bool operator ==(Object other) =>
      other is _NotifStatusView &&
      other.digestOn == digestOn &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(digestOn, hour, minute);
}

/// Seksi NOTIFIKASI + timeout kunci: keduanya kini tile hub menuju layar
/// sendiri, seperti tile Cadangan → BackupScreen.
extension _SettingsNotificationSection on _SettingsScreenState {
  String _timeoutLabel(int s, String lang) {
    if (s <= 0) return AppStrings.get('lockImmediately', lang);
    if (s < 120) return AppStrings.get('lock1min', lang);
    return AppStrings.get('lock5min', lang);
  }

  void _chooseTimeout(BuildContext context, String lang) {
    final settings = context.read<AppSettingsProvider>();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('lockTimeout', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: RadioGroup<int>(
          groupValue: settings.lockTimeoutSeconds,
          onChanged: (nv) {
            if (nv != null) {
              settings.applySilently(() => settings.setLockTimeout(nv));
            }
            Navigator.pop(dialogCtx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in [0, 60, 300])
                RadioListTile<int>(
                  title: Text(_timeoutLabel(v, lang)),
                  value: v,
                  activeColor: AppColors.tertiary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Jam ringkas dengan nol di depan — format yang sama dengan sub-layar
  /// Notifikasi, supaya keduanya tak pernah menampilkan jam berbeda.
  String _fmtDigestTime(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Tile hub NOTIFIKASI. Tujuh baris kontrol yang nyaris tak pernah diubah
  /// kini hidup di [NotificationSettingsScreen]; subtitle meringkas status
  /// live supaya pengguna tahu ringkasan harian sedang mati/hidup pada jam
  /// berapa tanpa perlu membuka dulu.
  Widget _notifSection(BuildContext context, String lang) {
    final v = context.select<AppSettingsProvider, _NotifStatusView>(
      (s) => _NotifStatusView(
        digestOn: s.digestEnabled,
        hour: s.digestHour,
        minute: s.digestMinute,
      ),
    );
    final status = v.digestOn
        ? '${AppStrings.get('enabled', lang)} • ${_fmtDigestTime(v.hour, v.minute)}'
        : AppStrings.get('disabled', lang);
    return _section(AppStrings.get('notifSection', lang).toUpperCase(), [
      _tile(
        Icons.notifications_outlined,
        AppStrings.get('notifSection', lang),
        '${AppStrings.get('notifHubDesc', lang)} • $status',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
        ),
      ),
    ]);
  }
}
