import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_motion.dart';

/// Sistem dialog bersama untuk Kaji Finance.
///
/// Prinsip: **dialog adalah affordance UX untuk niat, bukan kontrol
/// keamanan.** Operasi yang mengubah state persisten punya tiga lapis,
/// dan [AppConfirm.runAsync] adalah satu-satunya jalan untuk operasi
/// destruktif:
///
/// ```text
/// Confirm → Step-up auth → Business operation → Persistence → UI
/// ```
///
/// Dialog **memiliki** operasinya sendiri ([runAsync]). Pemanggil tidak
/// bisa melakukan persistence lalu membuka konfirmasi, karena dialog
/// tidak mengekspos tombol konfirmasi sebelum `action` tersedia, dan
/// `action` hanya berjalan setelah dialog mengembalikan true.
///
/// Tipografi, spacing, warna, dan destructive styling terpusat di sini —
/// tidak ada lagi dialog kustom yang mendefinisikan ulang gayanya.
class AppConfirm {
  AppConfirm._();

  /// Konfirmasi sederhana tanpa efek samping. Dipakai untuk aksi yang
  /// destruktif tapi murah, atau ketika pemanggil sudah menjalankan
  /// operasinya sendiri setelah dialog ini selesai.
  static Future<bool> show(
    BuildContext context, {
    required String lang,
    required String title,
    required String message,
    String? cancelLabel,
    String? confirmLabel,
    bool destructive = false,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => _shell(
        title: title,
        destructive: destructive,
        children: [Text(message, style: AppTextStyles.bodyMd())],
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel ?? AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  destructive ? AppColors.errorContainer : AppColors.tertiary,
            ),
            onPressed: () {
              if (destructive) {
                AppMotion.error();
              } else {
                AppMotion.tap();
              }
              Navigator.pop(ctx, true);
            },
            child: Text(
              confirmLabel ?? AppStrings.get('ok', lang),
              style: AppTextStyles.labelSm(
                color: destructive
                    ? AppColors.onErrorContainer
                    : AppColors.onTertiary,
              ),
            ),
          ),
        ],
      ),
    );
    return go == true;
  }

  /// Jalankan operasi async yang mengubah state persisten, dengan
  /// konfirmasi (dan step-up auth opsional) **sebelum** operasi jalan.
  ///
  /// - [action] dijalankan hanya setelah user mengonfirmasi.
  /// - [beforeAction] dipakai untuk step-up auth (PIN/biometrik). Bila
  ///   mengembalikan false, operasi tidak dijalankan sama sekali.
  /// - Selama [action] berjalan, tombol dinonaktifkan dan dialog tak
  ///   bisa ditutup, sehingga double-tap tidak mungkin menjalankan
  ///   operasi dua kali.
  /// - Bila [action] mengembalikan false atau melempar, dialog **tetap
  ///   terbuka** dan [errorBuilder] menampilkan sebab. Data tidak
  ///   pernah hilang karena dialog tertutup diam-diam.
  static Future<bool> runAsync(
    BuildContext context, {
    required String lang,
    required String title,
    required String message,
    required Future<bool> Function() action,
    String? successMessage,
    String? errorMessage,
    Future<bool> Function()? beforeAction,
    String? cancelLabel,
    String? confirmLabel,
    bool destructive = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AsyncConfirmDialog(
        title: title,
        message: message,
        cancelLabel: cancelLabel ?? AppStrings.get('cancel', lang),
        confirmLabel: confirmLabel ?? AppStrings.get('ok', lang),
        destructive: destructive,
        beforeAction: beforeAction,
        action: action,
        lang: lang,
        errorMessage: errorMessage,
      ),
    );
    if (confirmed != true) return false;
    AppMotion.success();
    if (successMessage != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return true;
  }
}

/// Dialog konfirmasi yang menjalankan operasi async-nya sendiri.
class _AsyncConfirmDialog extends StatefulWidget {
  final String title;
  final String message;
  final String cancelLabel;
  final String confirmLabel;
  final bool destructive;
  final String lang;
  final String? errorMessage;
  final Future<bool> Function()? beforeAction;
  final Future<bool> Function() action;

  const _AsyncConfirmDialog({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.destructive,
    required this.lang,
    required this.action,
    this.beforeAction,
    this.errorMessage,
  });

  @override
  State<_AsyncConfirmDialog> createState() => _AsyncConfirmDialogState();
}

class _AsyncConfirmDialogState extends State<_AsyncConfirmDialog> {
  bool _busy = false;
  String? _error;

  /// Cegah operasi dijalankan dua kali bila tombol ditekan cepat atau
  /// callback terpicu ulang.
  bool _running = false;

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _busy = true;
      _error = null;
    });
    try {
      // 1. Step-up auth — sebelum ada perubahan state apa pun.
      if (widget.beforeAction != null) {
        final authorized = await widget.beforeAction!();
        if (!authorized) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      }
      // 2. Operasi bisnis + persistensi.
      final ok = await widget.action();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = widget.errorMessage;
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = widget.errorMessage;
      });
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _shell(
      title: widget.title,
      destructive: widget.destructive,
      children: [
        Text(widget.message, style: AppTextStyles.bodyMd()),
        if (_busy) ...[
          const SizedBox(height: 16),
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.errorMessage ?? AppStrings.get('genericError', widget.lang),
            style: AppTextStyles.bodySm(color: AppColors.error),
          ),
        ],
      ],
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(widget.cancelLabel),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.destructive
                ? AppColors.errorContainer
                : AppColors.tertiary,
            disabledBackgroundColor: AppColors.surfaceContainerHighest,
          ),
          onPressed: _busy ? null : _run,
          child: Text(
            widget.confirmLabel,
            style: AppTextStyles.labelSm(
              color: widget.destructive
                  ? AppColors.onErrorContainer
                  : AppColors.onTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Kerangka dialog standar: satu-satunya tempat yang mendefinisikan
/// bentuk, latar, radius, dan tipografi dialog.
Widget _shell({
  required String title,
  required List<Widget> children,
  required List<Widget> actions,
  bool destructive = false,
}) {
  return AlertDialog(
    backgroundColor: AppColors.surfaceContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: Text(
      title,
      style: destructive
          ? AppTextStyles.headlineSm(color: AppColors.error)
          : AppTextStyles.headlineSm(),
    ),
    content: SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
    actions: actions,
  );
}
