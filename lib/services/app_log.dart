import 'package:flutter/foundation.dart';

/// Structured debug logging untuk operasi penting.
///
/// Contoh nama event:
/// `transaction.add.started/completed/failed`,
/// `backup.restore.started/validation_failed/completed`,
/// `db.transaction.started/completed/failed`.
///
/// TIDAK boleh log nilai sensitif (PIN, key, password, salt, hash).
/// Kunci yang dicurigai otomatis di-redact; nilai panjang di-truncate.
class AppLog {
  AppLog._();

  static const _redacted = '[redacted]';

  static final RegExp _sensitiveKey = RegExp(
    r'pin|password|passwd|secret|token|salt|hash|db_key|kaji_db|backup|keystream|cipher|nonce|private',
    caseSensitive: false,
  );

  /// Redact + truncate satu pasang key/value untuk log aman.
  static Map<String, String> sanitize(Map<String, Object?>? data) {
    if (data == null || data.isEmpty) return const {};
    final out = <String, String>{};
    for (final e in data.entries) {
      final k = e.key;
      if (_sensitiveKey.hasMatch(k)) {
        out[k] = _redacted;
        continue;
      }
      var v = '${e.value}';
      if (v.length > 120) v = '${v.substring(0, 117)}...';
      out[k] = v;
    }
    return out;
  }

  /// Catat event lifecycle. Tidak pernah throw.
  static void event(String name, {Map<String, Object?>? data}) {
    try {
      final safe = sanitize(data);
      debugPrint('[KajiFinance][$name]${safe.isEmpty ? '' : ' $safe'}');
    } on Object catch (_) {
      // best-effort: logging tak boleh merusak alur data.
    }
  }

  /// Catat kegagalan dengan pesan error yang sudah dibersihkan dari
  /// potensi secret (potong panjang, jangan sertakan stack sensitif).
  static void error(String name, Object err, {Map<String, Object?>? data}) {
    try {
      var msg = '$err';
      if (msg.length > 300) msg = '${msg.substring(0, 297)}...';
      final safe = sanitize(data);
      debugPrint(
        '[KajiFinance][$name] error=$msg'
        '${safe.isEmpty ? '' : ' data=$safe'}',
      );
    } on Object catch (_) {
      // best-effort.
    }
  }
}
