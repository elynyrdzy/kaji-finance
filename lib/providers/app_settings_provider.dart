import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_log.dart';
import '../services/profile_service.dart';
import '../services/secure_screen_service.dart';
import '../utils/money_format.dart';

/// Preferensi aplikasi: bahasa + timeout kunci otomatis + mata uang.
/// DARK ONLY — tidak ada lagi mode tema (§3).
class AppSettingsProvider extends ChangeNotifier {
  String languageCode = 'id';

  /// Kode kurs tampilan (IDR/USD/EUR/JPY/SGD/MYR). Mengatur
  /// [MoneyFormat.activeCurrency] agar semua widget ikut tanpa
  /// mengubah pemanggil satu per satu.
  String currencyCode = 'IDR';

  /// Nilai tukar rupiah-per-unit per kurs tampilan (P3-kurs).
  /// Semua nominal tersimpan basis IDR; rate hanya memengaruhi
  /// tampil (format/compact) & input (parse). IDR selalu 1.
  Map<String, double> rates = Map.of(MoneyFormat.rates);

  /// Timeout kunci otomatis setelah aplikasi ke background.
  /// 0 = segera, 60 = 1 menit, 300 = 5 menit.
  int lockTimeoutSeconds = 0;

  /// True setelah pemuatan awal selesai — dipakai penjadwal digest agar
  /// tak memakai nilai default sebelum preferensi dibaca.
  bool settingsLoaded = false;

  // --- Pengingat terjadwal (ringkasan harian). Jam 6–21 (jam tenang
  // 21–07 dijaga di UI + scheduler). Opsi isi default semua aktif.
  bool digestEnabled = false;
  int digestHour = 20;
  int digestMinute = 0;
  bool digestOptBudget = true;
  bool digestOptGoals = true;
  bool digestOptWallets = true;
  bool digestOptNudge = true;

  /// Alert anggaran seketika (50/80/100%) — master switch.
  bool budgetAlertEnabled = true;

  /// Blokir screenshot + thumbnail recent-apps via FLAG_SECURE.
  /// Default MATI: global-hardcoded sebelumnya memblokir semua user tanpa
  /// pemberitahuan; user mengaktifkannya eksplisit dari Pengaturan.
  bool screenshotProtection = false;

  // Kunci preferensi ter-scope profil (lihat FinancePersistence).
  static String get _kLang => ProfileService.scoped('kaji_lang');
  static String get _kLockTimeout => ProfileService.scoped('kaji_lock_timeout');
  static String get _kCurrency => ProfileService.scoped('kaji_currency');
  static String get _kRates => ProfileService.scoped('kaji_rates');
  static String get _kDigestEnabled =>
      ProfileService.scoped('kaji_digest_enabled');
  static String get _kDigestH => ProfileService.scoped('kaji_digest_h');
  static String get _kDigestM => ProfileService.scoped('kaji_digest_m');
  static String get _kDigestOptB => ProfileService.scoped('kaji_digest_opt_b');
  static String get _kDigestOptG => ProfileService.scoped('kaji_digest_opt_g');
  static String get _kDigestOptW => ProfileService.scoped('kaji_digest_opt_w');
  static String get _kDigestOptN => ProfileService.scoped('kaji_digest_opt_n');
  static String get _kBudgetAlert => ProfileService.scoped('kaji_budget_alert');
  static String get _kScreenshotProtection =>
      ProfileService.scoped('kaji_screenshot_protection');

  AppSettingsProvider() {
    _load();
  }

  /// Terapkan nilai baru lalu **tunggu** penulisan ke disk. Bila
  /// penyimpanan gagal, nilai in-memory dikembalikan ke sebelumnya dan
  /// error dilempar ulang ke pemanggil.
  ///
  /// Sebelumnya semua setter melakukan `notifyListeners()` lalu menulis
  /// ke prefs tanpa `await` dan tanpa jalur error. Kalau proses mati
  /// di antara keduanya, UI sudah menampilkan nilai baru sementara disk
  /// masih menyimpan nilai lama — divergensi senyap pada aplikasi
  /// keuangan. Pola [_apply] dipakai untuk setiap setter.
  Future<void> _apply(
    void Function() mutate,
    Future<void> Function(SharedPreferences p) persist, {
    required String label,
  }) async {
    mutate();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await persist(p);
    } catch (e) {
      // Kembalikan state in-memory ke snapshot sebelum mutasi.
      _rollback();
      notifyListeners();
      AppLog.error('settings.$label', e);
      rethrow;
    }
  }

  /// Snapshot seluruh field untuk `_rollback`. Diisi ulang setiap
  /// mutasi berhasil.
  late Map<String, Object?> _snapshot = _capture();

  Map<String, Object?> _capture() => {
        'lang': languageCode,
        'currency': currencyCode,
        'lockTimeout': lockTimeoutSeconds,
        'digestEnabled': digestEnabled,
        'digestHour': digestHour,
        'digestMinute': digestMinute,
        'digestOptBudget': digestOptBudget,
        'digestOptGoals': digestOptGoals,
        'digestOptWallets': digestOptWallets,
        'digestOptNudge': digestOptNudge,
        'budgetAlert': budgetAlertEnabled,
        'screenshotProtection': screenshotProtection,
        'rates': Map<String, double>.of(rates),
      };

  void _rollback() {
    languageCode = _snapshot['lang']! as String;
    currencyCode = _snapshot['currency']! as String;
    MoneyFormat.activeCurrency = currencyCode;
    lockTimeoutSeconds = _snapshot['lockTimeout']! as int;
    digestEnabled = _snapshot['digestEnabled']! as bool;
    digestHour = _snapshot['digestHour']! as int;
    digestMinute = _snapshot['digestMinute']! as int;
    digestOptBudget = _snapshot['digestOptBudget']! as bool;
    digestOptGoals = _snapshot['digestOptGoals']! as bool;
    digestOptWallets = _snapshot['digestOptWallets']! as bool;
    digestOptNudge = _snapshot['digestOptNudge']! as bool;
    budgetAlertEnabled = _snapshot['budgetAlert']! as bool;
    screenshotProtection = _snapshot['screenshotProtection']! as bool;
    rates = Map<String, double>.of(_snapshot['rates']! as Map<String, double>);
    MoneyFormat.setRates(rates);
  }

  Future<void> setLanguage(String code) async {
    await _apply(
      () => languageCode = code,
      (p) => p.setString(_kLang, code),
      label: 'set_language',
    );
    _snapshot = _capture();
  }

  Future<void> setCurrency(String code) async {
    if (!MoneyFormat.symbols.containsKey(code)) return;
    await _apply(
      () {
        currencyCode = code;
        MoneyFormat.activeCurrency = code;
      },
      (p) => p.setString(_kCurrency, code),
      label: 'set_currency',
    );
    _snapshot = _capture();
  }

  Future<void> setLockTimeout(int seconds) async {
    await _apply(
      () => lockTimeoutSeconds = seconds,
      (p) => p.setInt(_kLockTimeout, seconds),
      label: 'set_lock_timeout',
    );
    _snapshot = _capture();
  }

  Future<void> setDigestEnabled(bool v) async {
    await _apply(
      () => digestEnabled = v,
      (p) => p.setBool(_kDigestEnabled, v),
      label: 'set_digest_enabled',
    );
    _snapshot = _capture();
  }

  /// Jam 6–21 (jam tenang). Di luar itu dijepit defensif di sini.
  Future<void> setDigestTime(int hour, int minute) async {
    final h = hour.clamp(6, 21);
    final m = minute.clamp(0, 59);
    await _apply(
      () {
        digestHour = h;
        digestMinute = m;
      },
      (p) async {
        await p.setInt(_kDigestH, h);
        await p.setInt(_kDigestM, m);
      },
      label: 'set_digest_time',
    );
    _snapshot = _capture();
  }

  Future<void> _setDigestOpt(String key, bool v) async {
    await _apply(
      () {
        // Getter kunci non-const → rantai if (bukan switch-case const).
        if (key == _kDigestOptB) {
          digestOptBudget = v;
        } else if (key == _kDigestOptG) {
          digestOptGoals = v;
        } else if (key == _kDigestOptW) {
          digestOptWallets = v;
        } else if (key == _kDigestOptN) {
          digestOptNudge = v;
        }
      },
      (p) => p.setBool(key, v),
      label: 'set_digest_opt',
    );
    _snapshot = _capture();
  }

  Future<void> setDigestOptBudget(bool v) => _setDigestOpt(_kDigestOptB, v);
  Future<void> setDigestOptGoals(bool v) => _setDigestOpt(_kDigestOptG, v);
  Future<void> setDigestOptWallets(bool v) => _setDigestOpt(_kDigestOptW, v);
  Future<void> setDigestOptNudge(bool v) => _setDigestOpt(_kDigestOptN, v);

  Future<void> setBudgetAlertEnabled(bool v) async {
    await _apply(
      () => budgetAlertEnabled = v,
      (p) => p.setBool(_kBudgetAlert, v),
      label: 'set_budget_alert',
    );
    _snapshot = _capture();
  }

  /// Toggle anti-screenshot (FLAG_SECURE). Persist dulu via [_apply]
  /// (gagal → rollback + lempar ulang, native tak disentuh sehingga tetap
  /// konsisten), lalu sinkron native best-effort (tak melempar).
  Future<void> setScreenshotProtection(bool v) async {
    await _apply(
      () => screenshotProtection = v,
      (p) => p.setBool(_kScreenshotProtection, v),
      label: 'set_screenshot_protection',
    );
    _snapshot = _capture();
    await SecureScreenService.setEnabled(v);
  }

  /// Ubah rate satu kurs (IDR ditolak — selalu 1). Persist + sinkron
  /// MoneyFormat agar seluruh tampilan ikut seketika. Return false
  /// bila kode tak dikenal / nominal tak valid, atau bila penyimpanan
  /// gagal (nilai in-memory dikembalikan ke kondisi sebelumnya).
  Future<bool> setRate(String code, double idrPerUnit) async {
    if (!MoneyFormat.symbols.containsKey(code) || code == 'IDR') {
      return false;
    }
    if (!idrPerUnit.isFinite || idrPerUnit <= 0) return false;
    try {
      await _apply(
        () {
          rates[code] = idrPerUnit;
          MoneyFormat.setRates(rates);
        },
        (p) => p.setString(_kRates, jsonEncode(rates)),
        label: 'set_rate',
      );
    } catch (_) {
      // Kegagalan persistensi dilaporkan sebagai 'tidak berubah',
      // bukan exception ke UI — setter ini sudah punya kontrak bool.
      return false;
    }
    _snapshot = _capture();
    return true;
  }

  /// Jalankan setter ringan di latar. Kegagalan sudah di-rollback dan
  /// dicatat oleh [_apply]; di sini kita hanya menahan error agar tak
  /// menjadi unhandled exception untuk toggle yang memang interaktif
  /// dan reversible (tidak butuh dialog konfirmasi).
  void applySilently(Future<void> Function() setter) {
    unawaited(
      setter().catchError((Object e) {
        AppLog.event('settings.apply_failed', data: {'error': '$e'});
      }),
    );
  }

  /// Muat ulang dari disk — dipakai setelah import backup.
  Future<void> reload() => _load();

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    languageCode = p.getString(_kLang) ?? 'id';
    lockTimeoutSeconds = p.getInt(_kLockTimeout) ?? 0;
    digestEnabled = p.getBool(_kDigestEnabled) ?? false;
    digestHour = (p.getInt(_kDigestH) ?? 20).clamp(6, 21);
    digestMinute = (p.getInt(_kDigestM) ?? 0).clamp(0, 59);
    digestOptBudget = p.getBool(_kDigestOptB) ?? true;
    digestOptGoals = p.getBool(_kDigestOptG) ?? true;
    digestOptWallets = p.getBool(_kDigestOptW) ?? true;
    digestOptNudge = p.getBool(_kDigestOptN) ?? true;
    budgetAlertEnabled = p.getBool(_kBudgetAlert) ?? true;
    screenshotProtection = p.getBool(_kScreenshotProtection) ?? false;
    final cur = p.getString(_kCurrency) ?? 'IDR';
    currencyCode = MoneyFormat.symbols.containsKey(cur) ? cur : 'IDR';
    MoneyFormat.activeCurrency = currencyCode;
    final ratesStr = p.getString(_kRates);
    if (ratesStr != null) {
      try {
        final raw = jsonDecode(ratesStr) as Map<String, dynamic>;
        final next = <String, double>{};
        for (final e in raw.entries) {
          final v = (e.value as num?)?.toDouble();
          if (v != null && v.isFinite && v > 0) next[e.key] = v;
        }
        if (next.isNotEmpty) {
          rates = {...MoneyFormat.rates, ...next};
          MoneyFormat.setRates(rates);
        }
      } catch (_) {
        // best-effort: tabel kurs korup → kurs default dipakai (aman).
      }
    } else {
      MoneyFormat.setRates(rates);
    }
    settingsLoaded = true;
    _snapshot = _capture();
    notifyListeners();
    // Sinkron startup (dan reload pasca-restore): terapkan nilai prefs ke
    // native agar FLAG_SECURE mengikuti profil aktif. Best-effort.
    unawaited(SecureScreenService.setEnabled(screenshotProtection));
  }
}
