import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../providers/finance_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/money_format.dart';
import '../widgets/app_keypad.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageCtrl = PageController();
  int _step = 0;
  late final List<Widget> pages;
  final _nameCtrl = TextEditingController(text: 'Kaji Finance');
  double _allowRaw = 0;
  final _walletCtrl = TextEditingController(text: 'Dompet Utama');

  @override
  void initState() {
    super.initState();
    // Bahasa terkunci saat onboarding dibuka (tiada pemilih bahasa di sini),
    // jadi bangun sekali — dots/bounds/PageView selalu konsisten.
    pages = _buildPages(context.read<AppSettingsProvider>().languageCode);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _nameCtrl.dispose();
    _walletCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step < pages.length - 1) {
      setState(() => _step++);
      _pageCtrl.nextPage(
        duration: AppMotion.durationFor(context, AppMotion.medium),
        curve: AppMotion.sheet,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
      _pageCtrl.previousPage(
        duration: AppMotion.durationFor(context, AppMotion.medium),
        curve: AppMotion.sheet,
      );
    }
  }

  void _finish() async {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final fp = context.read<FinanceProvider>();
    var allowance = MoneyFormat.toBaseMinorUnits(_allowRaw);
    if (allowance < 0) allowance = 0;
    final name =
        _nameCtrl.text.trim().isEmpty ? 'Kaji Finance' : _nameCtrl.text.trim();
    await fp.completeOnboarding(
      name: name,
      allowance: allowance,
      walletName: _walletCtrl.text,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.fill('obWelcome', lang, {'name': name})),
        backgroundColor: AppColors.tertiary,
      ),
    );
  }

  void _skip() async {
    final fp = context.read<FinanceProvider>();
    await fp.completeOnboarding(
      name: 'Kaji Finance',
      allowance: 0,
      walletName: 'Dompet Utama',
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Text('KAJI FINANCE', style: AppTextStyles.labelCaps()),
                  const Spacer(),
                  TextButton(
                    onPressed: _skip,
                    child: Text(
                      AppStrings.get('skip', lang),
                      style: AppTextStyles.labelSm(color: AppColors.outline),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: List.generate(
                pages.length,
                (i) => Expanded(
                  child: AnimatedContainer(
                    duration: AppMotion.medium,
                    curve: AppMotion.sheet,
                    height: 4,
                    margin: EdgeInsets.only(
                      left: i == 0 ? 16 : 4,
                      right: i == pages.length - 1 ? 16 : 4,
                    ),
                    decoration: BoxDecoration(
                      color: i <= _step
                          ? AppColors.tertiary
                          : AppColors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _step = i),
                children: pages,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Row(
                children: [
                  if (_step > 0)
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(
                            color: AppColors.outlineVariant,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _back,
                        child: Text(
                          AppStrings.get('back', lang),
                          style: AppTextStyles.labelSm(),
                        ),
                      ),
                    ),
                  if (_step > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.tertiary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _next,
                      child: AnimatedSwitcher(
                        duration: AppMotion.fast,
                        child: Text(
                          _step == pages.length - 1
                              ? AppStrings.get('obStart', lang)
                              : AppStrings.get('next', lang),
                          key: ValueKey(_step),
                          style: AppTextStyles.labelSm(
                            color: AppColors.onTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Daftar halaman welcome (satu sumber kebenaran untuk dots/bounds/PageView).
  List<Widget> _buildPages(String lang) => [
        _stepCard(
          icon: Icons.waving_hand_rounded,
          title: AppStrings.get('wlcmAboutTitle', lang),
          subtitle: AppStrings.get('wlcmAboutDesc', lang),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              AppStrings.get('obLocal', lang),
              style: AppTextStyles.bodySm(),
            ),
          ),
        ),
        _stepCard(
          icon: Icons.savings_outlined,
          title: AppStrings.get('wlcmFeaturesTitle', lang),
          subtitle: AppStrings.get('wlcmFeaturesDesc', lang),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.verified_user_outlined,
                          color: AppColors.tertiary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppStrings.get('obLocal', lang),
                            style: AppTextStyles.bodySm(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.wallet_outlined,
                          color: AppColors.tertiary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppStrings.get('obMultiWallet', lang),
                            style: AppTextStyles.bodySm(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.category_outlined,
                          color: AppColors.tertiary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppStrings.get('obCustomCat', lang),
                            style: AppTextStyles.bodySm(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _stepCard(
          icon: Icons.security_outlined,
          title: AppStrings.get('wlcmSecurityTitle', lang),
          subtitle: AppStrings.get('wlcmSecurityDesc', lang),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              AppStrings.get('privacyDesc', lang),
              style: AppTextStyles.bodySm(),
            ),
          ),
        ),
        _stepCard(
          icon: Icons.person_outline,
          title: AppStrings.get('obNameTitle', lang),
          subtitle: AppStrings.get('obNameDesc', lang),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('obAccountLabel', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _nameCtrl,
                  style: AppTextStyles.bodyMd(),
                  decoration: InputDecoration(
                    hintText: AppStrings.get('obAccountHint', lang),
                    hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.get('obAllowanceLabel', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: InkWell(
                  onTap: () async {
                    final v = await showAppAmountSheet(
                      context,
                      title: AppStrings.get('obAllowanceLabel', lang),
                      cancelLabel: AppStrings.get('cancel', lang),
                      okLabel: AppStrings.get('save', lang),
                      initialRaw: _allowRaw,
                    );
                    if (v != null) {
                      setState(() => _allowRaw = v);
                    }
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.payments_outlined,
                          color: AppColors.outline,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _allowRaw == 0
                                ? AppStrings.get('obAllowanceHint2', lang)
                                : MoneyFormat.format(
                                    MoneyFormat.toBaseMinorUnits(_allowRaw),
                                  ),
                            style: AppTextStyles.bodyMd(
                              color: _allowRaw == 0
                                  ? AppColors.outline
                                  : AppColors.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.get('obAllowanceNote', lang),
                style: AppTextStyles.bodySm(),
              ),
              const SizedBox(height: 16),
              Text(
                AppStrings.get('obWalletLabel', lang),
                style: AppTextStyles.labelCaps(),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _walletCtrl,
                  style: AppTextStyles.bodyMd(),
                  decoration: InputDecoration(
                    hintText: AppStrings.get('onboardingWalletHint', lang),
                    hintStyle: AppTextStyles.bodyMd(color: AppColors.outline),
                    border: InputBorder.none,
                    prefixIcon: const Icon(
                      Icons.wallet_outlined,
                      color: AppColors.outline,
                      size: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A4D8F),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.account_balance_wallet,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${AppStrings.get('obPreview', lang)}: ${_walletCtrl.text.trim().isEmpty ? AppStrings.get('onboardingWalletHint', lang) : _walletCtrl.text.trim()}',
                            style: AppTextStyles.bodyMd().copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            AppStrings.get('obPreviewBalance', lang),
                            style: AppTextStyles.bodySm(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ];
  Widget _stepCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      children: [
        Center(
          // Ikon memantul pegas tiap ganti langkah (sinematik).
          child: TweenAnimationBuilder<double>(
            key: ValueKey(icon),
            tween: Tween(begin: 0.7, end: 1.0),
            duration: AppMotion.slow,
            curve: AppMotion.spring,
            builder: (_, s, __) => Transform.scale(
              scale: s,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.tertiary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: AppColors.tertiary),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          style: AppTextStyles.headlineLg(),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: AppTextStyles.bodySm(),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}
