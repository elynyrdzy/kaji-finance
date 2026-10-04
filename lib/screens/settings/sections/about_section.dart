part of '../../settings_screen.dart';

/// Seksi TENTANG (batch 2, pindahan verbatim dari settings_screen.dart).
extension _SettingsAboutSection on _SettingsScreenState {
  void _showAbout(BuildContext context, String lang) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('about', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.get('aboutDetail', lang),
              style: AppTextStyles.bodyMd(),
            ),
            const SizedBox(height: 12),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (ctx, snap) {
                final v = snap.hasData
                    ? 'v${snap.data!.version}+${snap.data!.buildNumber}'
                    : 'v…';
                return Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$v • ${AppStrings.get('aboutBody', lang)}',
                        style: AppTextStyles.labelSm(color: AppColors.tertiary),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.code_rounded,
                  size: 16,
                  color: AppColors.tertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    AppStrings.get('developedBy', lang),
                    style: AppTextStyles.labelSm(color: AppColors.tertiary),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('ok', lang)),
          ),
        ],
      ),
    );
  }

  void _showPrivacy(BuildContext context, String lang) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('privacy', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.get('privacyDetail', lang),
              style: AppTextStyles.bodyMd(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  size: 16,
                  color: AppColors.tertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    AppStrings.get('developedBy', lang),
                    style: AppTextStyles.labelSm(color: AppColors.tertiary),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('ok', lang)),
          ),
        ],
      ),
    );
  }

  /// Komposisi seksi TENTANG untuk build().
  Widget _aboutSection(BuildContext context, String lang) {
    return _section(AppStrings.get('about', lang).toUpperCase(), [
      _tile(
        Icons.info_outline,
        AppStrings.get('about', lang),
        AppStrings.get('aboutBody', lang),
        onTap: () => _onAboutTap(context, lang),
      ),
      _tile(
        Icons.school_outlined,
        AppStrings.get('replayOnboarding', lang),
        AppStrings.get('replayOnboardingDesc', lang),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const OnboardingScreen(),
            fullscreenDialog: true,
          ),
        ),
      ),
      _tile(
        Icons.shield_outlined,
        AppStrings.get('privacy', lang),
        AppStrings.get('privacyDesc', lang),
        onTap: () => _showPrivacy(context, lang),
      ),
    ]);
  }
}
