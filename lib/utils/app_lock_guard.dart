/// Penjaga kunci layar selama overlay sistem / operasi sensitif.
///
/// Sebagian ROM Android melaporkan file-picker, share-sheet, dan prompt
/// biometrik sebagai `paused` (bukan cuma `inactive`). Tanpa penjaga ini,
/// `_maybeLockOnPause/Resume` di `main.dart` bisa mengunci aplikasi tepat
/// di tengah alur restore/share/autentikasi.
///
/// Pola pakai: bungkus operasi pemicu overlay dengan `run`, atau
/// `enter()`/`exit()` manual dalam try/finally. Counter (bukan bool) agar
/// operasi bersarang tetap aman.
class AppLockGuard {
  AppLockGuard._();
  static int _depth = 0;
  static DateTime? _lastExit;

  static bool get isBusy => _depth > 0;

  /// Waktu keluar guard terakhir — dipakai _maybeLockOnResume sebagai
  /// masa tenggang agar paused yang dicatat saat overlay sistem tidak
  /// langsung mengunci tepat setelah flag dilepas (race file-picker/share).
  static DateTime? get lastExit => _lastExit;

  static void enter() => _depth++;

  static void exit() {
    if (_depth > 0) _depth--;
    if (_depth == 0) _lastExit = DateTime.now();
  }

  static Future<T> run<T>(Future<T> Function() fn) async {
    enter();
    try {
      return await fn();
    } finally {
      exit();
    }
  }
}
