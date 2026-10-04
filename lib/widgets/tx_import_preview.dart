import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../services/transaction_import_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/money_format.dart';

/// Dialog pratinjau staging memori impor transaksi sebelum ditulis
/// terenkripsi ke SQL. Dipakai layar Transaksi & Pengaturan agar
/// alurnya satu pintu. Pop memakai [dialogCtx] (konvensi dialog app).
Future<bool?> showTxImportPreview(
  BuildContext context,
  TxImportStaging staging,
  String lang,
) {
  final sample = staging.valid.take(5).toList();
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      title: Text(
        AppStrings.get('importTxPreviewTitle', lang),
        style: AppTextStyles.headlineSm(),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('importTxHow', lang),
                style: AppTextStyles.bodySm(),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _TxImportChip(
                    label: AppStrings.fill('importTxValid', lang, {
                      'n': staging.valid.length,
                    }),
                    ok: true,
                  ),
                  const SizedBox(width: 8),
                  if (staging.invalid > 0)
                    _TxImportChip(
                      label: AppStrings.fill('importTxInvalid', lang, {
                        'n': staging.invalid,
                      }),
                      ok: false,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${AppStrings.get('inShort', lang)}: ${MoneyFormat.format(staging.incomeTotal)} • '
                '${AppStrings.get('outShort', lang)}: ${MoneyFormat.format(staging.expenseTotal)}',
                style: AppTextStyles.bodySm(),
              ),
              if (staging.goals.isNotEmpty || staging.wallets.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    AppStrings.fill('importTxLinked', lang, {
                      'n': staging.goals.length,
                      'm': staging.wallets.length,
                    }),
                    style: AppTextStyles.bodySm().copyWith(
                      color: AppColors.tertiary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              ...sample.map(
                (t) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.title,
                          style: AppTextStyles.bodySm(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        MoneyFormat.signed(
                          t.signedAmount,
                          t.type == TransactionType.expense
                              ? 'expense'
                              : 'income',
                        ),
                        style: AppTextStyles.tabularAmount(),
                      ),
                    ],
                  ),
                ),
              ),
              if (staging.valid.length > sample.length)
                Text(
                  '… +${staging.valid.length - sample.length}',
                  style: AppTextStyles.bodySm(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: Text(AppStrings.get('cancel', lang)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.tertiary),
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: Text(
            AppStrings.get('importTxConfirm', lang),
            style: AppTextStyles.labelSm(color: AppColors.onTertiary),
          ),
        ),
      ],
    ),
  );
}

/// Chip hitungan pratinjau impor (valid hijau / rusak merah).
class _TxImportChip extends StatelessWidget {
  final String label;
  final bool ok;

  const _TxImportChip({required this.label, required this.ok});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ok
            ? AppColors.tertiary.withValues(alpha: 0.15)
            : AppColors.errorContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.labelSm(
          color: ok ? AppColors.tertiary : AppColors.error,
        ),
      ),
    );
  }
}
