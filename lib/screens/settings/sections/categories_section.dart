part of '../../settings_screen.dart';

/// Seksi KATEGORI (batch 1, pindahan verbatim dari settings_screen.dart):
/// daftar kategori + dialog tambah.
extension _SettingsCategoriesSection on _SettingsScreenState {
  void _showCategories(BuildContext context, FinanceProvider fp, String lang) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
              Row(
                children: [
                  Text(
                    AppStrings.get('categories', lang),
                    style: AppTextStyles.headlineSm(),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, color: AppColors.tertiary),
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _addCategoryDialog(context, lang);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.get('builtIn', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: fp.displayBuiltInCategories
                    .map(
                      (c) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(c.icon, size: 14, color: AppColors.outline),
                            const SizedBox(width: 4),
                            Text(c.name, style: AppTextStyles.labelSm()),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.fill('customCount', lang, {
                  'n': fp.customCategories.length,
                }),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              if (fp.customCategories.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    AppStrings.get('noCustomCategory', lang),
                    style: AppTextStyles.bodySm(),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: (() {
                    // Kustom terlaris di depan (tanpa mengubah
                    // urutan simpan): hitung pemakaian dari log.
                    final usage = <String, int>{};
                    for (final t in fp.transactions) {
                      usage[t.category] = (usage[t.category] ?? 0) + 1;
                    }
                    final customs = fp.customCategories.toList()
                      ..sort(
                        (a, b) => (usage[b.name] ?? 0).compareTo(
                          usage[a.name] ?? 0,
                        ),
                      );
                    return customs;
                  }())
                      .map(
                        (c) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.tertiary.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AppColors.tertiary.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                c.icon,
                                size: 14,
                                color: AppColors.tertiary,
                              ),
                              const SizedBox(width: 4),
                              Text(c.name, style: AppTextStyles.labelSm()),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () async {
                                  final go = await AppConfirm.show(
                                    context,
                                    lang: lang,
                                    title: AppStrings.get(
                                      'deleteCategoryTitle',
                                      lang,
                                    ),
                                    message: AppStrings.get(
                                      'deleteCategoryBody',
                                      lang,
                                    ),
                                    confirmLabel: AppStrings.get(
                                      'delete',
                                      lang,
                                    ),
                                    destructive: true,
                                  );
                                  if (!go || !sheetCtx.mounted) {
                                    return;
                                  }
                                  final ok = await fp.removeCustomCategory(
                                    c.id,
                                  );
                                  if (!sheetCtx.mounted) return;
                                  Navigator.pop(sheetCtx);
                                  if (!ok && context.mounted) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          AppStrings.get(
                                            'categoryExists',
                                            lang,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  _showCategories(context, fp, lang);
                                },
                                child: const Icon(
                                  Icons.close,
                                  size: 14,
                                  color: AppColors.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.tertiary,
                  ),
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    _addCategoryDialog(context, lang);
                  },
                  icon: const Icon(
                    Icons.add,
                    color: AppColors.onTertiary,
                    size: 18,
                  ),
                  label: Text(
                    AppStrings.get('addCategory', lang),
                    style: AppTextStyles.labelSm(color: AppColors.onTertiary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addCategoryDialog(BuildContext context, String lang) {
    final nameCtrl = TextEditingController();
    IconData picked = Icons.category_outlined;
    const icons = [
      Icons.restaurant,
      Icons.fastfood,
      Icons.shopping_bag,
      Icons.directions_car,
      Icons.receipt_long,
      Icons.bolt,
      Icons.sports_esports,
      Icons.movie,
      Icons.favorite_border,
      Icons.school,
      Icons.work,
      Icons.home,
      Icons.flight,
      Icons.pets,
      Icons.more_horiz,
    ];
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSB) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('newCategory', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: AppTextStyles.bodyMd(),
                decoration: InputDecoration(
                  hintText: AppStrings.get('categoryNameHint', lang),
                  hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.get('categoryIcon', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: icons
                    .map(
                      (ic) => InkWell(
                        onTap: () => setSB(() => picked = ic),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: picked == ic
                                ? AppColors.tertiary
                                : AppColors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            ic,
                            color: picked == ic
                                ? AppColors.onTertiary
                                : AppColors.onSurface,
                            size: 20,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.get('cancel', lang)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.tertiary,
              ),
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(ctx);
                final fp = context.read<FinanceProvider>();
                final ok = await fp.addCustomCategory(
                  nameCtrl.text.trim(),
                  picked,
                );
                if (!ok) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(AppStrings.get('categoryExists', lang)),
                    ),
                  );
                  return;
                }
                navigator.pop();
              },
              child: Text(
                AppStrings.get('save', lang),
                style: AppTextStyles.labelSm(color: AppColors.onTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
