import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_model.dart';
import 'app_log.dart';
import 'audit_service.dart';
import 'domain_errors.dart';
import 'debug_service.dart';
import 'pbkdf2.dart';
import 'profile_service.dart';
import 'secure_db_service.dart';
import '../utils/app_lock_guard.dart';

/// PIN tidak pernah disimpan plaintext. Format tersimpan v2 (Phase 7):
/// `v2:<base64url salt16>:<hex PBKDF2-HMAC-SHA256(pin, salt, 10k, 32B)>`.
/// Format lama v1 (`salt:hex(sha256)`) dan plaintext prasejarah tetap
/// diverifikasi sekali lalu di-upgrade ke v2 saat cocok (best-effort;
/// kegagalan upgrade tak menggagalkan auth yang sudah sukses).
/// Hash PIN tinggal di Keystore/Keychain (secure storage), bukan prefs —
/// tahan intip di HP root. PIN lama di prefs dimigrasi otomatis.
/// FAIL-CLOSED (P7): tulis ke secure storage yang gagal melempar
/// [SecureStorageException] — TIDAK ADA fallback prefs untuk kredensial.
/// Verifikasi memakai perbandingan constant-time.
///
/// MULTI-PROFIL: semua kunci di-scope per profil via [scopedProfileKey]
/// (param [scope]; default = profil aktif). Profil default memakai kunci
/// polos — perilaku lama tak berubah.
///
/// RATE-LIMIT: [verifyPin] TIDAK sekadar membandingkan hash — ia menerapkan
/// lockout per scope untuk SETIAP pemanggil (lock screen, step-up auth,
/// ganti profil, enkripsi backup). PIN 4 digit hanya 10.000 kombinasi dan
/// semua jalur di atas bisa disentuh berulang tanpa satu pun jejak, jadi
/// penghitungnya wajib PERSIST di secure storage ter-scope profil, bukan
/// variabel in-memory di satu layar: counter in-memory dihapus oleh restart
/// aplikasi maupun pindah titik masuk, sehingga penyerang tinggal memberi
/// aplikasi itu sendiri "jatah baru" tiap beberapa saat. Scope per profil
/// menjaga agar tebak-menebak profil A tak mengunci pengguna sah profil B.
class AuthService {
  static const _kPin = 'kaji_pin';
  static const _kPinEnabled = 'kaji_pin_enabled';
  static const _kBioEnabled = 'kaji_bio_enabled';

  /// R3: rate-limit lockout — WAJIB di secure storage (bukan prefs polos).
  /// Kunci ter-scope profil via [scopedProfileKey] (default = polos).
  static const _kLockoutUntil = 'kaji_lockout_until';
  static const _kFailedAttempts = 'kaji_failed_attempts';
  static const _kLockoutStreak = 'kaji_lockout_streak';

  /// Batas percobaan + durasi backoff (satu sumber kebenaran; LockScreen
  /// memakai konstanta ini via [lockoutSecondsForStreak]).
  static const maxPinAttempts = 5;
  static const lockoutDurations = [30, 60, 300];

  static int lockoutSecondsForStreak(int streak) =>
      lockoutDurations[streak.clamp(0, lockoutDurations.length - 1)];

  static const _sec = FlutterSecureStorage();

  /// Scope penyimpanan aktif — selalu mengikuti profil aktif
  /// (satu sumber kebenaran di ProfileService, tanpa sinkron manual).
  static String get activeScope => ProfileService.activeId;

  static String _sk(String base, [String? scope]) =>
      scopedProfileKey(scope ?? activeScope, base);

  static Future<bool> isPinEnabled({String? scope}) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_sk(_kPinEnabled, scope)) ?? false;
  }

  static Future<bool> isBioEnabled({String? scope}) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_sk(_kBioEnabled, scope)) ?? false;
  }

  static Future<String?> getPin({String? scope}) async =>
      _readPin(scope: scope);

  /// Baca hash PIN: secure storage dulu, fallback migrasi prefs lawas.
  static Future<String?> _readPin({String? scope}) async {
    try {
      final s = await _sec.read(key: _sk(_kPin, scope));
      if (s != null && s.isNotEmpty) return s;
    } catch (_) {
      // best-effort: keystore tak terbaca → lanjut fallback prefs lawas di bawah.
    }
    try {
      final p = await SharedPreferences.getInstance();
      final legacy = p.getString(_sk(_kPin, scope));
      if (legacy != null && legacy.isNotEmpty) {
        try {
          await _sec.write(key: _sk(_kPin, scope), value: legacy);
        } catch (_) {
          // best-effort: tulis-balik migrasi gagal → baca dari prefs tetap jalan.
        }
        await p.remove(_sk(_kPin, scope));
        return legacy;
      }
    } catch (_) {
      // best-effort: seluruh baca PIN gagal → null (fail-closed: verifyPin false).
    }
    return null;
  }

  /// Tulis hash PIN ke secure storage. Gagal → lempar
  /// [SecureStorageException] (FAIL-CLOSED P7): kredensial tidak pernah
  /// jatuh ke SharedPreferences. Pemanggil (UI) menampilkan pesan aman.
  static Future<void> _writePin(String value, {String? scope}) async {
    try {
      await _sec.write(key: _sk(_kPin, scope), value: value);
    } catch (e) {
      SecureDbService.noteError('auth_secure_write_gagal: $e');
      throw SecureStorageException(details: '$e');
    }
  }

  static Future<void> _deletePin({String? scope}) async {
    try {
      await _sec.delete(key: _sk(_kPin, scope));
    } catch (_) {
      // best-effort: hapus keystore gagal → prefs di bawah tetap dibersihkan (fail-closed).
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_sk(_kPin, scope));
    } catch (_) {
      // best-effort: hapus prefs gagal → flag PIN nonaktif tetap ditegakkan pemanggil.
    }
  }

  /// Iterasi KDF hash PIN v2 — ~190ms di mesin dev (isolate), menarget
  /// <1 dtk di HP low-end dengan spinner lock screen. 10.000x lebih lambat
  /// dari single-SHA256 v1 bagi brute-force offline; pertahanan utama
  /// tetap Keystore + lockout + rate-limit (PIN pendek kalah vs GPU).
  static const pinKdfIterations = 10000;

  static String _hashPinV1(String pin, String salt) {
    final bytes = utf8.encode('$salt::$pin');
    return sha256.convert(bytes).toString();
  }

  /// Hitung hash v2 di isolate (berat) — kembalikan string simpan utuh.
  static Future<String> _hashPinV2(String pin) async {
    final salt = _newSaltBytes();
    final dk = await compute(_pinKdfEntry, [pin, base64Url.encode(salt)]);
    return 'v2:${base64Url.encode(salt)}:$dk';
  }

  static List<int> _newSaltBytes([int length = 16]) {
    final rnd = Random.secure();
    return List<int>.generate(length, (_) => rnd.nextInt(256));
  }

  /// Perbandingan constant-time atas byte UTF-8 (anti timing-oracle).
  static bool _constantTimeEqual(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    if (x.length != y.length) return false;
    var diff = 0;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static bool _looksV2(String? stored) {
    if (stored == null || !stored.startsWith('v2:')) return false;
    final parts = stored.split(':');
    return parts.length == 3 &&
        parts[1].isNotEmpty &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(parts[2]);
  }

  static bool _looksHashed(String? stored) {
    if (_looksV2(stored)) return true;
    if (stored == null) return false;
    final sep = stored.indexOf(':');
    if (sep <= 0) return false;
    final hash = stored.substring(sep + 1);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hash);
  }

  static Future<void> setPin(
    String pin, {
    bool enabled = true,
    String? scope,
  }) async {
    // P7: hash di isolate dulu; tulis secure gagal → throw (fail-closed),
    // flag PIN tak tersentuh sehingga tak ada PIN setengah-jadi.
    final stored = await _hashPinV2(pin);
    await _writePin(stored, scope: scope);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_sk(_kPinEnabled, scope), enabled);
    // P5: jejak perubahan kredensial (tanpa nilai sensitif), best-effort.
    unawaited(
      AuditService.log(
        action: AuditAction.pinChanged,
        entityType: 'security',
        entityId: scope ?? activeScope,
      ).catchError((_) {}),
    );
  }

  static Future<void> setPinEnabled(bool v, {String? scope}) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_sk(_kPinEnabled, scope), v);
    unawaited(
      AuditService.log(
        action: AuditAction.securitySettingChanged,
        entityType: 'security',
        entityId: scope ?? activeScope,
        metadata: {'setting': 'pin_enabled', 'value': v},
      ).catchError((_) {}),
    );
  }

  static Future<bool> setBioEnabled(bool v, {String? scope}) async {
    if (v) {
      final pin = await _readPin(scope: scope);
      if (pin == null || pin.isEmpty) return false;
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool(_sk(_kBioEnabled, scope), v);
    unawaited(
      AuditService.log(
        action: AuditAction.securitySettingChanged,
        entityType: 'security',
        entityId: scope ?? activeScope,
        metadata: {'setting': 'bio_enabled', 'value': v},
      ).catchError((_) {}),
    );
    return true;
  }

  static Future<void> clearPin({String? scope}) async {
    await _deletePin(scope: scope);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_sk(_kPinEnabled, scope), false);
    unawaited(
      AuditService.log(
        action: AuditAction.securitySettingChanged,
        entityType: 'security',
        entityId: scope ?? activeScope,
        metadata: {'setting': 'pin_cleared'},
      ).catchError((_) {}),
    );
  }

  // --- R3: lockout brute-force di flutter_secure_storage (fail-closed) ---

  static String _lockScope(String? scope) => scope ?? activeScope;

  /// Muat status lockout dari secure storage.
  /// Return (untilMs, failed, streak). Fail-closed: baca gagal → kunci
  /// (until = now+300s, failed = max) agar tak bisa bypass via keystore rusak.
  /// Migrasi sekali jalan: bila secure kosong, baca prefs lawas lalu tulis
  /// ke secure + hapus prefs.
  static Future<({int untilMs, int failed, int streak})> loadLockout({
    String? scope,
  }) async {
    final sc = _lockScope(scope);
    if (!isValidProfileId(sc)) {
      AppLog.error('auth.lockout.invalid_scope', FormatException(sc));
      final now = DateTime.now().millisecondsSinceEpoch;
      return (untilMs: now + 300000, failed: maxPinAttempts, streak: 2);
    }
    try {
      final untilRaw = await _sec.read(
        key: scopedProfileKey(sc, _kLockoutUntil),
      );
      final failedRaw = await _sec.read(
        key: scopedProfileKey(sc, _kFailedAttempts),
      );
      final streakRaw = await _sec.read(
        key: scopedProfileKey(sc, _kLockoutStreak),
      );
      var untilMs = int.tryParse(untilRaw ?? '') ?? 0;
      var failed = int.tryParse(failedRaw ?? '') ?? 0;
      var streak = int.tryParse(streakRaw ?? '') ?? 0;
      // Migrasi prefs lawas → secure (sekali jalan per profil).
      if (untilRaw == null && failedRaw == null && streakRaw == null) {
        try {
          final p = await SharedPreferences.getInstance();
          final legacyUntil = p.getInt(scopedProfileKey(sc, _kLockoutUntil));
          final legacyFailed = p.getInt(scopedProfileKey(sc, _kFailedAttempts));
          final legacyStreak = p.getInt(scopedProfileKey(sc, _kLockoutStreak));
          if (legacyUntil != null ||
              legacyFailed != null ||
              legacyStreak != null) {
            untilMs = legacyUntil ?? 0;
            failed = legacyFailed ?? 0;
            streak = legacyStreak ?? 0;
            try {
              if (untilMs > 0) {
                await _sec.write(
                  key: scopedProfileKey(sc, _kLockoutUntil),
                  value: '$untilMs',
                );
              }
              if (failed > 0) {
                await _sec.write(
                  key: scopedProfileKey(sc, _kFailedAttempts),
                  value: '$failed',
                );
              }
              if (streak > 0) {
                await _sec.write(
                  key: scopedProfileKey(sc, _kLockoutStreak),
                  value: '$streak',
                );
              }
            } on Object catch (e) {
              SecureDbService.noteError('auth_lockout_migrate_write: $e');
              AppLog.error('auth.lockout.migrate_write_failed', e);
            }
            try {
              await p.remove(scopedProfileKey(sc, _kLockoutUntil));
              await p.remove(scopedProfileKey(sc, _kFailedAttempts));
              await p.remove(scopedProfileKey(sc, _kLockoutStreak));
            } on Object catch (e) {
              SecureDbService.noteError('auth_lockout_migrate_cleanup: $e');
              AppLog.error('auth.lockout.migrate_cleanup_failed', e);
            }
          }
        } on Object catch (e) {
          SecureDbService.noteError('auth_lockout_migrate_read: $e');
          AppLog.error('auth.lockout.migrate_read_failed', e);
        }
      }
      return (untilMs: untilMs, failed: failed, streak: streak);
    } on Object catch (e) {
      SecureDbService.noteError('auth_lockout_read: $e');
      AppLog.error('auth.lockout.read_failed', e);
      final now = DateTime.now().millisecondsSinceEpoch;
      return (untilMs: now + 300000, failed: maxPinAttempts, streak: 2);
    }
  }

  /// Simpan status lockout ke secure storage. Gagal → throw
  /// [SecureStorageException] (fail-closed, jangan fallback prefs).
  static Future<void> saveLockout({
    required int untilMs,
    required int failed,
    required int streak,
    String? scope,
  }) async {
    final sc = _lockScope(scope);
    if (!isValidProfileId(sc)) {
      throw const SecureStorageException(details: 'invalid scope');
    }
    try {
      if (untilMs > 0) {
        await _sec.write(
          key: scopedProfileKey(sc, _kLockoutUntil),
          value: '$untilMs',
        );
      } else {
        await _sec.delete(key: scopedProfileKey(sc, _kLockoutUntil));
      }
      if (failed > 0) {
        await _sec.write(
          key: scopedProfileKey(sc, _kFailedAttempts),
          value: '$failed',
        );
      } else {
        await _sec.delete(key: scopedProfileKey(sc, _kFailedAttempts));
      }
      if (streak > 0) {
        await _sec.write(
          key: scopedProfileKey(sc, _kLockoutStreak),
          value: '$streak',
        );
      } else {
        await _sec.delete(key: scopedProfileKey(sc, _kLockoutStreak));
      }
    } on Object catch (e) {
      SecureDbService.noteError('auth_lockout_write: $e');
      AppLog.error('auth.lockout.write_failed', e);
      throw SecureStorageException(details: '$e');
    }
  }

  /// Hapus lockout (secure + sisa prefs lawas). Dipakai reset terproteksi
  /// (R1) + sukses login. Best-effort per langkah, tak pernah throw.
  static Future<void> clearLockout({String? scope}) async {
    final sc = _lockScope(scope);
    if (!isValidProfileId(sc)) return;
    for (final base in [_kLockoutUntil, _kFailedAttempts, _kLockoutStreak]) {
      try {
        await _sec.delete(key: scopedProfileKey(sc, base));
      } on Object catch (e) {
        SecureDbService.noteError('auth_lockout_clear_secure($base): $e');
        AppLog.error(
          'auth.lockout.clear_secure_failed',
          e,
          data: {'key': base},
        );
      }
    }
    try {
      final p = await SharedPreferences.getInstance();
      for (final base in [_kLockoutUntil, _kFailedAttempts, _kLockoutStreak]) {
        try {
          await p.remove(scopedProfileKey(sc, base));
        } on Object catch (e) {
          SecureDbService.noteError('auth_lockout_clear_prefs($base): $e');
          AppLog.error(
            'auth.lockout.clear_prefs_failed',
            e,
            data: {'key': base},
          );
        }
      }
    } on Object catch (e) {
      SecureDbService.noteError('auth_lockout_clear_prefs_open: $e');
      AppLog.error('auth.lockout.clear_prefs_open_failed', e);
    }
  }

  static Future<bool> verifyPin(String input, {String? scope}) async {
    final sc = _lockScope(scope);
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = await _liveLockout(sc, now);
    if (s.untilMs > now) {
      // PIN yang BENAR pun ditolak selama jeda — gerbang ini bukan sekadar
      // penghitung dan tidak boleh dilewati lewat "coba lagi". Sekalian
      // menghemat KDF ~190ms yang tak akan dipakai.
      unawaited(DebugService.logEvent('pin_lockout'));
      return false;
    }
    final r = await _comparePin(input, scope: scope);
    if (r.ok) {
      await clearLockout(scope: scope);
      return true;
    }
    // Tanpa hash PIN tak ada yang bisa ditebak dan verifikasi sudah
    // fail-closed; membakar jatah lockout di sini hanya bisa mengunci
    // scope yang belum punya PIN.
    if (!r.guessable) return false;
    await _recordPinFailure(sc, s);
    return false;
  }

  /// Sisa detik lockout aktif untuk [scope]; 0 bila tak terkunci. Dipakai
  /// UI supaya menampilkan "coba lagi dalam N detik", bukan "PIN salah" —
  /// yang menyesatkan saat PIN-nya sebenarnya benar tapi ditolak jeda.
  static Future<int> pinLockoutSeconds({String? scope}) async {
    try {
      final s = await _liveLockout(
        _lockScope(scope),
        DateTime.now().millisecondsSinceEpoch,
      );
      final remain = s.untilMs - DateTime.now().millisecondsSinceEpoch;
      if (remain <= 0) return 0;
      return (remain / 1000).ceil().clamp(1, lockoutDurations.last);
    } on Object catch (_) {
      // best-effort: tak bisa baca → UI jatuh ke pesan generik.
      return 0;
    }
  }

  /// State lockout yang sudah dinormalisasi terhadap [nowMs]: lockout
  /// kedaluwarsa dibersihkan (percobaan dinolkan, `streak` dipertahankan
  /// supaya backoff berikutnya lebih panjang — sama dengan LockScreen).
  /// Fail-closed diwarisi dari [loadLockout]: baca gagal → terkunci.
  static Future<({int untilMs, int failed, int streak})> _liveLockout(
    String sc,
    int nowMs,
  ) async {
    final s = await loadLockout(scope: sc);
    if (s.untilMs > 0 && s.untilMs <= nowMs) {
      await _writeLockoutQuiet(
        untilMs: 0,
        failed: 0,
        streak: s.streak,
        scope: sc,
      );
      return (untilMs: 0, failed: 0, streak: s.streak);
    }
    return s;
  }

  /// Tambah satu kegagalan pada state [s] lalu simpan; [maxPinAttempts]
  /// kegagalan berturut-turut memicu lockout dengan backoff beruntun.
  /// Tulis gagal sengaja ditelan (tidak melemahkan verifikasi yang sudah
  /// mengembalikan false) tapi dicatat di log keamanan.
  static Future<void> _recordPinFailure(
    String sc,
    ({int untilMs, int failed, int streak}) s,
  ) async {
    final failed = s.failed + 1;
    if (failed < maxPinAttempts) {
      await _writeLockoutQuiet(
        untilMs: 0,
        failed: failed,
        streak: s.streak,
        scope: sc,
      );
      unawaited(DebugService.logEvent('pin_wrong'));
      return;
    }
    final seconds = lockoutSecondsForStreak(s.streak);
    await _writeLockoutQuiet(
      untilMs: DateTime.now().millisecondsSinceEpoch + seconds * 1000,
      failed: 0,
      streak: (s.streak + 1).clamp(0, lockoutDurations.length - 1),
      scope: sc,
    );
    unawaited(DebugService.logEvent('pin_lockout'));
  }

  /// [saveLockout] yang tak pernah melempar — pemanggil sudah menolak PIN,
  /// jadi kegagalan tulis hanya boleh dicatat, bukan jadi exception
  /// liar dari callback UI.
  static Future<void> _writeLockoutQuiet({
    required int untilMs,
    required int failed,
    required int streak,
    required String scope,
  }) async {
    try {
      await saveLockout(
        untilMs: untilMs,
        failed: failed,
        streak: streak,
        scope: scope,
      );
    } on Object catch (e) {
      SecureDbService.noteError('auth_lockout_write_quiet: $e');
      AppLog.error('auth.lockout.write_quiet_failed', e);
    }
  }

  /// Perbandingan hash murni (tanpa rate-limit) — [verifyPin] yang mengatur
  /// gerbang lockout + penghitung. [guessable] = scope ini punya hash PIN
  /// (tak ada hash → tak ada yang bisa ditebak).
  static Future<({bool ok, bool guessable})> _comparePin(
    String input, {
    String? scope,
  }) async {
    final stored = await _readPin(scope: scope);
    if (stored == null || stored.isEmpty) return (ok: false, guessable: false);
    if (_looksV2(stored)) {
      final parts = stored.split(':');
      final salt = base64Url.decode(parts[1]);
      final expectedHex = parts[2];
      final dk = await compute(_pinKdfEntry, [input, base64Url.encode(salt)]);
      return (ok: _constantTimeEqual(dk, expectedHex), guessable: true);
    }
    if (_looksHashed(stored)) {
      // Format v1 legacy: verifikasi constant-time, lalu upgrade ke v2.
      final sep = stored.indexOf(':');
      final salt = stored.substring(0, sep);
      final ok = _constantTimeEqual(
        _hashPinV1(input, salt),
        stored.substring(sep + 1),
      );
      if (ok) {
        try {
          await _writePin(await _hashPinV2(input), scope: scope);
        } on Object catch (e) {
          SecureDbService.noteError('auth_upgrade_v1: $e');
          AppLog.error('auth.upgrade_v1_failed', e);
        }
      }
      return (ok: ok, guessable: true);
    }
    // Migrasi sekali jalan: PIN lama plaintext cocok (constant-time) →
    // simpan sebagai hash v2.
    if (_constantTimeEqual(stored, input)) {
      try {
        await _writePin(await _hashPinV2(input), scope: scope);
      } on Object catch (e) {
        SecureDbService.noteError('auth_upgrade_plain: $e');
        AppLog.error('auth.upgrade_plain_failed', e);
      }
      return (ok: true, guessable: true);
    }
    return (ok: false, guessable: true);
  }

  static Future<bool> isDeviceSupported() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> canCheckBiometrics() async {
    try {
      final auth = LocalAuthentication();
      // Perangkat harus didukung dulu; lalu harus ada biometrik terdaftar.
      // Cek berlapis karena sebagian ROM melaporkan canCheckBiometrics
      // true padahal tidak ada sidik/wajah terdaftar.
      final supported = await auth.isDeviceSupported();
      if (!supported) return false;
      final can = await auth.canCheckBiometrics;
      if (!can) return false;
      final available = await auth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticateBio({
    String reason = 'Buka Kaji Finance',
  }) async {
    // Prompt biometrik adalah overlay sistem — tahan kunci layar selama jalan.
    return AppLockGuard.run(() async {
      try {
        final auth = LocalAuthentication();
        // Pra-validasi agar gagal cepat dengan pesan yang benar di UI,
        // bukan dialog sistem yang langsung ditolak.
        try {
          if (!await auth.isDeviceSupported()) return false;
          if (!await auth.canCheckBiometrics) return false;
          if ((await auth.getAvailableBiometrics()).isEmpty) return false;
        } catch (_) {
          return false;
        }
        return await auth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            // Kunci biometrik murni: jangan fallback ke PIN perangkat di sini
            // (PIN aplikasi sudah ada jalurnya sendiri). biometricOnly:false
            // di sebagian perangkat langsung gagal tanpa dialog.
            biometricOnly: true,
            stickyAuth: true,
            sensitiveTransaction: false,
          ),
        );
      } catch (_) {
        return false;
      }
    });
  }
}

/// Entry isolate untuk [compute]: KDF hash PIN v2.
/// args = [pin, base64urlSalt] → hex derived key. Harus top-level.
String _pinKdfEntry(List<String> args) {
  final salt = base64Url.decode(args[1]);
  final dk = pbkdf2HmacSha256(
    utf8.encode(args[0]),
    salt,
    AuthService.pinKdfIterations,
    32,
  );
  return hexEncode(dk);
}
