import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/wallet_model.dart';
import '../providers/finance_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_motion.dart';
import '../utils/money_format.dart';
import 'app_keypad.dart';

/// Dialog tambah/ubah dompet SATU-SATUNYA (dulu duplikat di Beranda dan
/// Pengaturan dengan risiko divergen). Ikon/warna default tetap
/// (Icons.wallet, biru) — selaras AppIcons.values agar persist-aman.

Future<void> showAddWalletDialog(
  BuildContext context,
  FinanceProvider fp,
  String lang,
) {
  final nameCtrl = TextEditingController();
  final numCtrl = TextEditingController();
  double balRaw = 0;
  return showDialog(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (sbCtx, setSB) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('newWallet', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                hintText: AppStrings.get('walletNameHint', lang),
              ),
              style: AppTextStyles.bodyMd(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: numCtrl,
              decoration: InputDecoration(
                hintText: AppStrings.get('walletNumberHint', lang),
              ),
              style: AppTextStyles.bodyMd(),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final v = await showAppAmountSheet(
                  sbCtx,
                  title: AppStrings.get('walletBalanceHint', lang),
                  cancelLabel: AppStrings.get('cancel', lang),
                  okLabel: AppStrings.get('save', lang),
                  initialRaw: balRaw,
                );
                if (v != null) setSB(() => balRaw = v);
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.outlineVariant),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  balRaw == 0
                      ? AppStrings.get('walletBalanceHint', lang)
                      : MoneyFormat.format(
                          MoneyFormat.toBaseMinorUnits(balRaw),
                        ),
                  style: AppTextStyles.bodyMd(
                    color:
                        balRaw == 0 ? AppColors.outline : AppColors.onSurface,
                  ),
                ),
              ),
            ),
          ],
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
              final ok = await fp.addWallet(
                nameCtrl.text.trim().isEmpty ? 'Wallet' : nameCtrl.text.trim(),
                numCtrl.text.trim().isEmpty ? '• 0000' : numCtrl.text.trim(),
                Icons.wallet,
                const Color(0xFF1A4D8F),
                MoneyFormat.toBaseMinorUnits(balRaw),
              );
              if (!context.mounted) return;
              Navigator.pop(dialogCtx);
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(AppStrings.get('walletExists', lang))),
                );
              } else {
                AppMotion.success();
              }
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

Future<void> showEditWalletDialog(
  BuildContext context,
  FinanceProvider fp,
  WalletModel wallet,
  String lang,
) {
  final nameCtrl = TextEditingController(text: wallet.name);
  final numCtrl = TextEditingController(text: wallet.number);
  return showDialog(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      title: Text(
        AppStrings.get('editWallet', lang),
        style: AppTextStyles.headlineSm(),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              hintText: AppStrings.get('walletNameHint', lang),
            ),
            style: AppTextStyles.bodyMd(),
          ),
          TextField(
            controller: numCtrl,
            decoration: InputDecoration(
              hintText: AppStrings.get('walletNumberHint', lang),
            ),
            style: AppTextStyles.bodyMd(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final ok = await confirmDeleteWallet(context, lang);
            if (!ok || !context.mounted) return;
            final removed = await fp.removeWallet(wallet.id);
            if (!context.mounted) return;
            Navigator.pop(dialogCtx);
            // removeWallet false = masih dirujuk transaksi.
            if (!removed) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.get('walletInUse', lang))),
              );
            }
          },
          child: Text(
            AppStrings.get('delete', lang),
            style: const TextStyle(color: AppColors.error),
          ),
        ),
        ElevatedButton(
          onPressed: () async {
            final ok = await fp.updateWallet(
              wallet.id,
              name: nameCtrl.text.trim(),
              number: numCtrl.text.trim(),
            );
            if (!context.mounted) return;
            Navigator.pop(dialogCtx);
            if (!ok) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.get('walletExists', lang))),
              );
            }
          },
          child: Text(AppStrings.get('save', lang)),
        ),
      ],
    ),
  );
}

/// Konfirmasi hapus dompet (dulu langsung hapus tanpa konfirmasi).
Future<bool> confirmDeleteWallet(BuildContext context, String lang) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (confirmCtx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      title: Text(
        AppStrings.get('confirmDeleteTitle', lang),
        style: AppTextStyles.headlineSm(),
      ),
      content: Text(
        AppStrings.get('confirmDeleteWallet', lang),
        style: AppTextStyles.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(confirmCtx, false),
          child: Text(AppStrings.get('cancel', lang)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.errorContainer,
          ),
          onPressed: () => Navigator.pop(confirmCtx, true),
          child: Text(
            AppStrings.get('delete', lang),
            style: AppTextStyles.labelSm(color: AppColors.onErrorContainer),
          ),
        ),
      ],
    ),
  );
  return go == true;
}
