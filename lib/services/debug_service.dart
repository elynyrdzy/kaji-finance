import 'package:shared_preferences/shared_preferences.dart';

import 'secure_db_service.dart';

/// Gerbang mode debug ala "opsi developer" Android.
///
/// Kategori Debug di Pengaturan tersembunyi secara default dan hanya muncul
/// setelah tile "Tentang Kaji Finance" diketuk [unlockTaps] kali dalam
/// [tapWindow] (pola tap-cepat ala MIUI/Android). Flag [isEnabled]
/// persist di SharedPreferences dan SENGAJA tidak ikut file backup
/// (state perangkat ini, seperti PIN).
class DebugService {
  DebugService._();

  static const _kEnabled = 'kaji_debug_enabled';

  /// Jumlah ketukan tile Tentang untuk membuka mode debug.
  static const unlockTaps = 8;

  /// Jeda maksimum antar ketukan; penghitung reset bila melebihi ini.
  static const tapWindow = Duration(seconds: 3);

  static Future<bool> isEnabled() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_kEnabled) ?? false;
    } on Object catch (_) {
      return false;
    }
  }

  static Future<void> setEnabled(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, v);
    } on Object catch (_) {
      // best-effort: flag debug tak tersimpan → mode debug mati setelah restart.
    }
  }

  // --- Log peristiwa keamanan (audit trail lokal, maks 40) ---
  static const _kSecLog = 'kaji_sec_log';
  static const _secLogCap = 40;

  /// Catat peristiwa (`pin_wrong`, `pin_lockout`, ...). Best-effort,
  /// tak ikut backup (state perangkat). Ditampilkan di Info Debug.
  static Future<void> logEvent(String event) async {
    try {
      final p = await SharedPreferences.getInstance();
      final log = p.getStringList(_kSecLog) ?? [];
      log.add('${DateTime.now().toIso8601String()} $event');
      while (log.length > _secLogCap) {
        log.removeAt(0);
      }
      await p.setStringList(_kSecLog, log);
    } on Object catch (e) {
      SecureDbService.noteError('Debug: tulis log keamanan gagal: $e');
    }
  }

  /// Peristiwa terbaru dulu (maks [limit]).
  static Future<List<String>> recentEvents({int limit = 8}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final log = p.getStringList(_kSecLog) ?? [];
      final tail = log.length <= limit ? log : log.sublist(log.length - limit);
      return tail.reversed.toList();
    } on Object catch (_) {
      return [];
    }
  }
}
