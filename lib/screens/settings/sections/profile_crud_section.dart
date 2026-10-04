part of '../../settings_screen.dart';

/// Seksi PROFIL — CRUD (batch 1, pindahan verbatim dari settings_screen.dart):
/// switcher, beralih, buat baru, chip tipe.
/// Daftar profil + ganti/hapus. Data tiap profil terisolasi penuh
/// (database + preferensi + PIN masing-masing).
/// Hapus profil + seluruh datanya (konfirmasi dulu, tak ada undo).
/// Bila yang dihapus sedang aktif, otomatis pindah ke default.
extension _SettingsProfileCrudSection on _SettingsScreenState {
  Future<void> _showProfileSwitcher(BuildContext context, String lang) async {
    final list = await ProfileService.profiles();
    if (!context.mounted) return;
    final activeId = ProfileService.activeId;
    unawaited(
      showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.surfaceContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetCtx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.get('switchProfile', lang),
                  style: AppTextStyles.headlineSm(),
                ),
                Text(
                  AppStrings.get('switchProfileDesc', lang),
                  style: AppTextStyles.bodySm(),
                ),
                const SizedBox(height: 12),
                ...list.map(
                  (pr) => ListTile(
                    leading: WalletAvatar(name: pr.name, radius: 20),
                    title: Text(pr.name, style: AppTextStyles.bodyMd()),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (pr.id == activeId)
                          const Icon(Icons.check, color: AppColors.tertiary),
                        IconButton(
                          icon: const Icon(
                            Icons.copy_outlined,
                            size: 18,
                            color: AppColors.onSurfaceVariant,
                          ),
                          tooltip: AppStrings.get('duplicate', lang),
                          onPressed: () {
                            Navigator.pop(sheetCtx);
                            _duplicateProfile(context, pr.id, pr.name, lang);
                          },
                        ),
                        if (list.length > 1 &&
                            pr.id != ProfileService.defaultId)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: AppColors.error,
                            ),
                            onPressed: () {
                              Navigator.pop(sheetCtx);
                              _confirmDeleteProfile(
                                context,
                                pr.id,
                                pr.name,
                                lang,
                              );
                            },
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      _switchProfile(context, pr.id, lang);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Beralih profil: PIN profil target bila diproteksi, lalu arahkan
  /// database + muat ulang seluruh state dari ruang profil tersebut.
  Future<void> _switchProfile(
    BuildContext context,
    String id,
    String lang,
  ) async {
    // Orkestrasi bersama (PIN + reload + digest) — satu sumber.
    await switchActiveProfile(context, id);
  }

  /// Buat profil baru (nama + tipe + warna), lalu beralih dan tawarkan
  /// PIN opsional (Batal = tanpa PIN).
  Future<void> _createProfileDialog(BuildContext context, String lang) async {
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
    final nameCtrl = TextEditingController();
    var color = ProfileService.avatarColors.first;
    unawaited(
      showDialog(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (sbCtx, setSB) => AlertDialog(
            backgroundColor: AppColors.surfaceContainer,
            title: Text(
              AppStrings.get('newProfile', lang),
              style: AppTextStyles.headlineSm(),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      style: AppTextStyles.bodyMd(),
                      decoration: InputDecoration(
                        hintText: AppStrings.get('profileNameHint', lang),
                        hintStyle: AppTextStyles.bodyMd(
                          color: AppColors.outline,
                        ),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ProfileService.avatarColors
                          .map(
                            (c) => InkWell(
                              onTap: () => setSB(() => color = c),
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: color == c
                                        ? AppColors.onSurface
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
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
                onPressed: () async {
                  final pr = await ProfileService.create(
                    name: nameCtrl.text,
                    color: color.toARGB32(),
                  );
                  if (pr == null) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AppStrings.get('profileCreateFailed', lang),
                        ),
                      ),
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.pop(dialogCtx);
                  await _loadProfiles();
                  if (!context.mounted) return;
                  await _switchProfile(context, pr.id, lang);
                  if (!context.mounted) return;
                  final pin = await showAppPinSheet(
                    context,
                    title: AppStrings.get('setProfilePin', lang),
                    message: AppStrings.get('profilePinOptional', lang),
                    cancelLabel: AppStrings.get('cancel', lang),
                    okLabel: AppStrings.get('save', lang),
                  );
                  if (pin == null || pin.isEmpty) return;
                  try {
                    await AuthService.setPin(pin, enabled: true);
                  } on SecureStorageException {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AppStrings.get('secureStorageUnavailable', lang),
                        ),
                        backgroundColor: AppColors.errorContainer,
                      ),
                    );
                    await _loadSecurity();
                    return;
                  }
                  await _loadSecurity();
                },
                child: Text(
                  AppStrings.get('save', lang),
                  style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
