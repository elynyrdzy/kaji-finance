import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../providers/app_settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppSettingsProvider>().languageCode;
    final items = [
      (
        icon: Icons.account_balance,
        activeIcon: Icons.account_balance,
        label: AppStrings.get('home', lang),
      ),
      (
        icon: Icons.receipt_long_outlined,
        activeIcon: Icons.receipt_long,
        label: AppStrings.get('transactions', lang),
      ),
      (
        icon: Icons.pie_chart_outline,
        activeIcon: Icons.pie_chart,
        label: AppStrings.get('budget', lang),
      ),
      (
        icon: Icons.monitor_heart_outlined,
        activeIcon: Icons.monitor_heart,
        label: AppStrings.get('analytics', lang),
      ),
      (
        icon: Icons.tune_outlined,
        activeIcon: Icons.tune,
        label: AppStrings.get('settings', lang),
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.96),
        border: Border(
          top: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.4),
            width: 0.6,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 66,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(items.length, (i) {
              final selected = i == currentIndex;
              final color =
                  selected ? AppColors.tertiary : AppColors.onSurfaceVariant;
              return Expanded(
                child: Semantics(
                  selected: selected,
                  button: true,
                  label: items[i].label,
                  child: Tooltip(
                    message: items[i].label,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        if (i != currentIndex) AppMotion.tap();
                        onTap(i);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: AppMotion.durationFor(
                              context,
                              AppMotion.nav,
                            ),
                            curve: Curves.easeOut,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.tertiary.withValues(alpha: 0.16)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              selected ? items[i].activeIcon : items[i].icon,
                              size: 23,
                              color: color,
                            ),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              items[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  AppTextStyles.labelSm(color: color).copyWith(
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
