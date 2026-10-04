import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_strings.dart';
import '../models/transaction_model.dart';
import '../providers/app_settings_provider.dart';
import '../services/reconciliation_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/date_format.dart';
import '../utils/money_format.dart';

class TransactionTile extends StatelessWidget {
  final TransactionModel tx;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onLongPress;

  const TransactionTile({
    super.key,
    required this.tx,
    this.onTap,
    this.onDelete,
    this.onEdit,
    this.onLongPress,
  });

  Color get _iconBg {
    switch (tx.type) {
      case TransactionType.income:
        return AppColors.tertiaryContainer;
      case TransactionType.expense:
      case TransactionType.transfer:
      case TransactionType.adjustment:
        return AppColors.surfaceContainerHigh;
    }
  }

  Color get _iconColor => tx.type == TransactionType.income
      ? AppColors.tertiary
      : AppColors.onSurface;

  Color get _amountColor => tx.type == TransactionType.income
      ? AppColors.tertiary
      : AppColors.onSurface;

  /// Tag internal tabungan/penyesuaian tak pernah ditampilkan mentah —
  /// pengguna melihat lencana "Tabungan". Tag bebas lain (QRIS, Payroll, ...)
  /// tetap tampil apa adanya karena bermakna bagi pengguna.
  bool get _isSavingsTag =>
      tx.tag == 'savings_deposit' ||
      tx.tag == 'savings_withdraw' ||
      tx.linkedGoalId != null;

  /// Tag internal koreksi saldo — disembunyikan seperti tag tabungan
  /// (alasan koreksi tetap tersimpan di note/detail).
  bool get _isInternalTag => _isSavingsTag || tx.tag == BalanceAdjustment.tag;

  String _amountText() {
    switch (tx.type) {
      case TransactionType.income:
        return MoneyFormat.signed(tx.amount, 'income');
      case TransactionType.expense:
        return MoneyFormat.signed(tx.amount, 'expense');
      case TransactionType.transfer:
      case TransactionType.adjustment:
        return MoneyFormat.format(tx.amount);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Selector, bukan watch: baris transaksi hanya butuh `languageCode`.
    // Dengan watch, SETIAP baris yang terlihat subscribing ke seluruh
    // AppSettingsProvider, sehingga satu perubahan setting apa pun
    // membangun ulang seluruh baris di layar.
    final lang = context.select<AppSettingsProvider, String>(
      (s) => s.languageCode,
    );
    final semanticLabel =
        '${tx.title}, ${tx.category}, ${_amountText()}, ${AppDates.tileDate(tx.date, lang)}';
    final content = Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: Container(
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
                color: _iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(tx.icon, size: 20, color: _iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.title,
                    style: AppTextStyles.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tx.category} • ${AppDates.tileDate(tx.date, lang)}',
                    style: AppTextStyles.bodySm(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _amountText(),
                  style: AppTextStyles.tabularAmount(
                    color: _amountColor,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                if (_isSavingsTag) ...[
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.tertiary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.savings_outlined,
                          size: 11,
                          color: AppColors.tertiary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          AppStrings.get('savings', lang),
                          style: AppTextStyles.bodySm().copyWith(
                            fontSize: 11,
                            color: AppColors.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (tx.tag != null && !_isInternalTag) ...[
                  const SizedBox(height: 2),
                  Text(
                    tx.tag!,
                    style: AppTextStyles.bodySm().copyWith(fontSize: 11),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    if (onDelete == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      );
    }

    // Geser dua arah ala Telegram: kanan = ubah, kiri = hapus.
    return Dismissible(
      key: ValueKey(tx.id),
      direction: DismissDirection.horizontal,
      background: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: AppColors.tertiary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.edit_outlined, color: AppColors.onTertiary),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.symmetric(vertical: 0),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: AppColors.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.delete_outline,
          color: AppColors.onErrorContainer,
        ),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          onEdit?.call();
          return false;
        }
        return true;
      },
      onDismissed: (_) => onDelete?.call(),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: content,
      ),
    );
  }
}
