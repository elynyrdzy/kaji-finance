part of '../../settings_screen.dart';

/// Seksi PROFIL — hapus & duplikat (batch 1, pindahan verbatim dari
/// settings_screen.dart, termasuk triase noteError todo 11).
extension _SettingsProfileDeleteSection on _SettingsScreenState {
  /// Hapus profil + seluruh datanya (konfirmasi dulu, tak ada undo).
  /// Bila yang dihapus sedang aktif, otomatis pindah ke default.
  Future<void> _confirmDeleteProfile(
    BuildContext context,
    String id,
    String name,
    String lang,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final fp = context.read<FinanceProvider>();
    final settings = context.read<AppSettingsProvider>();
    // Hapus profil = hapus DB + kunci + prefs profil tersebut. Sekelas
    // reset total, jadi konfirmasi + step-up wajib.
    // "Profil terakhir tak bisa dihapus" adalah kondisi bisnis yang
    // wajar, bukan kegagalan umum — beri pesan yang tepat.
    var quotaReached = false;
    final done = await AppConfirm.runAsync(
      context,
      lang: lang,
      title: AppStrings.get('confirmDeleteTitle', lang),
      message: AppStrings.fill('confirmDeleteProfile', lang, {'name': name}),
      confirmLabel: AppStrings.get('delete', lang),
      destructive: true,
      errorMessage: AppStrings.get('genericError', lang),
      beforeAction: () => stepUpAuth(context, lang),
      action: () async {
        final switchedTo = await ProfileService.remove(id);
        if (switchedTo == null) {
          quotaReached = true;
          return false;
        }
        await _loadProfiles();
        await SecureDbService.useProfile(switchedTo);
        await fp.reloadFromPrefs();
        await settings.reload();
        fp.budgetAlertsOn = settings.budgetAlertEnabled;
        NotificationService.setLanguage(settings.languageCode);
        unawaited(refreshDigestSchedule(fp, settings));
        return true;
      },
    );
    if (!context.mounted) return;
    if (done) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('profileDeleted', lang))),
      );
    } else if (quotaReached) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('profileCantDeleteLast', lang)),
          backgroundColor: AppColors.errorContainer,
        ),
      );
    }
  }

  /// Duplikat profil: salin SELURUH data (5 tabel + preferensi cloneable)
  /// ke profil baru, lalu beralih ke sana. ID baris dipertahankan
  /// (ruang DB terpisah → tak ada tabrakan) sehingga tautan
  /// dompet/goal tetap utuh. Tanpa PIN (diatur terpisah bila perlu).
  Future<void> _duplicateProfile(
    BuildContext context,
    String sourceId,
    String sourceName,
    String lang,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final existing = await ProfileService.profiles();
    if (!context.mounted) return;
    if (existing.length >= ProfileService.maxProfiles) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('profileMax', lang, {
              'n': ProfileService.maxProfiles,
            }),
          ),
        ),
      );
      return;
    }
    final source = await ProfileService.byId(sourceId);
    if (source == null || !context.mounted) return;
    // Bila sumber bukan profil aktif, beralih dulu (hormati PIN) agar
    // snapshot dibaca dari database yang benar.
    if (sourceId != ProfileService.activeId) {
      final ok = await switchActiveProfile(context, sourceId);
      if (!ok || !context.mounted) return;
    }
    final nameCtrl = TextEditingController(
      text: AppStrings.fill('profileCopyName', lang, {'name': source.name}),
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('duplicate', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: TextField(
          controller: nameCtrl,
          style: AppTextStyles.bodyMd(),
          decoration: InputDecoration(
            hintText: AppStrings.get('profileNameHint', lang),
            hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.tertiary,
            ),
            onPressed: () => Navigator.pop(dialogCtx, nameCtrl.text.trim()),
            child: Text(
              AppStrings.get('save', lang),
              style: AppTextStyles.labelSm(color: AppColors.onTertiary),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (newName == null || newName.isEmpty) return;
    final fp = context.read<FinanceProvider>();
    final settings = context.read<AppSettingsProvider>();
    // 1. Snapshot ruang sumber (masih terikat ke profil sumber).
    final rows = <String, List<Map<String, Object?>>>{};
    try {
      for (final t in SecureDbTables.all) {
        rows[t] = await SecureDbService.loadTable(t);
      }
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('genericError', lang))),
      );
      return;
    }
    final prefSnap = <String, Object?>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in ProfileService.cloneablePrefKeys) {
        final v = prefs.get(scopedProfileKey(sourceId, k));
        if (v != null) prefSnap[k] = v;
      }
    } catch (e) {
      SecureDbService.noteError('Profil: snapshot prefs klon gagal: $e');
    }
    // 2. Buat profil target + beralih (tanpa PIN: baru dibuat).
    final created = await ProfileService.create(
      name: newName,
      color: source.color,
    );
    if (created == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(AppStrings.get('profileCreateFailed', lang))),
      );
      return;
    }
    if (!await ProfileService.setActive(created.id)) return;
    await SecureDbService.useProfile(created.id);
    // 3. Tulis snapshot ke ruang target.
    try {
      for (final e in rows.entries) {
        await SecureDbService.saveTable(e.key, e.value);
      }
      final prefs = await SharedPreferences.getInstance();
      for (final e in prefSnap.entries) {
        final sk = ProfileService.scoped(e.key);
        final v = e.value;
        if (v is String) {
          await prefs.setString(sk, v);
        } else if (v is double) {
          await prefs.setDouble(sk, v);
        } else if (v is int) {
          await prefs.setInt(sk, v);
        } else if (v is bool) {
          await prefs.setBool(sk, v);
        } else if (v is List) {
          try {
            await prefs.setStringList(sk, v.map((x) => '$x').toList());
          } catch (err) {
            SecureDbService.noteError(
              'Profil: tulis StringList klon ${e.key} gagal: $err',
            );
          }
        }
      }
    } catch (err) {
      SecureDbService.noteError('Profil: tulis klon ke target gagal: $err');
    }
    await fp.reloadFromPrefs();
    await settings.reload();
    await _loadProfiles();
    fp.budgetAlertsOn = settings.budgetAlertEnabled;
    NotificationService.setLanguage(settings.languageCode);
    unawaited(refreshDigestSchedule(fp, settings));
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(AppStrings.get('profileDuplicated', lang)),
        backgroundColor: AppColors.tertiary,
      ),
    );
  }
}
