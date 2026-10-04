import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' hide Hmac;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/debt_entry.dart';
import '../models/recurring_bill.dart';
import '../models/savings_goal_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../utils/app_lock_guard.dart';
import 'app_log.dart';
import 'audit_service.dart';
import 'auth_service.dart';
import 'domain_errors.dart';
import 'money.dart';
import 'pbkdf2.dart';
import 'profile_service.dart';
import 'reconciliation_service.dart';
import 'secure_db_service.dart';
import 'template_service.dart';

class BackupService {
  // Catatan: kaji_pin & kaji_pin_enabled SENGAJA tidak ikut di-backup.
  // Kunci layar adalah state perangkat ini; setelah restore, user
  // mengaktifkan ulang PIN di Settings → Keamanan.
  // Entitas (kaji_tx/bd/wl/goals/cat) dibaca/ditulis via SecureDbService
  // (SQLite terenkripsi) — format backup TIDAK berubah.
  static const _entityKeys = [
    'kaji_tx',
    'kaji_bd',
    'kaji_wl',
    'kaji_goals',
    'kaji_cat',
  ];

  /// Kunci prefs yang menyimpan JSON list per-domain (bukan tabel DB).
  /// Ini DATA pengguna (hutang, tagihan rutin, template) — bukan preferensi
  /// tampilan — sehingga ikut backup PENUH dan restore MENGGANTI isinya,
  /// sama seperti entitas DB. Kunci disimpan ter-scope profil, dibaca apa
  /// adanya sebagai string JSON.
  static const _prefsJsonKeys = [
    'kaji_debts',
    'kaji_recurring_bills',
    'kaji_tx_templates',
  ];
  static const _keys = [
    'kaji_allowance',
    'kaji_account',
    'kaji_balvis',
    'kaji_onb',
    'kaji_bio_enabled',
    'kaji_lang',
    'kaji_currency',
    'kaji_lock_timeout',
    'kaji_rates',
    'kaji_exp_enabled',
    'kaji_exp_flags',
    // Preferensi pengingat: perilaku non-sensitif, aman dipulihkan.
    'kaji_digest_enabled',
    'kaji_digest_h',
    'kaji_digest_m',
    'kaji_digest_opt_b',
    'kaji_digest_opt_g',
    'kaji_digest_opt_w',
    'kaji_digest_opt_n',
    'kaji_budget_alert',
    // Level alert ternotifikasi: pulihkan agar tak re-notif tiap restore.
    'kaji_budget_notified',
  ];

  static Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } on Object catch (e) {
      AppLog.error('backup.app_version_failed', e);
      return '1.3.0+1';
    }
  }

  static Future<String> exportToJson() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final k in _keys) {
      // Baca ter-scope profil, tapi kunci di file backup tetap polos
      // (format backup tak berubah, restore masuk ke profil aktif).
      final sk = ProfileService.scoped(k);
      if (prefs.containsKey(sk)) {
        map[k] = prefs.get(sk);
      }
    }
    // Entitas dari SQLite terenkripsi — bentuk identik nilai prefs dulu.
    // FAIL-CLOSED: bila entitas finansial gagal dibaca, backup GAGAL total.
    // Backup "berhasil" tanpa transaksi/dompet/anggaran adalah file yang
    // terlihat valid padahal datanya hilang — jauh lebih berbahaya daripada
    // tidak ada backup sama sekali.
    try {
      map.addAll(await SecureDbService.exportEntityJson());
    } on Object catch (e) {
      SecureDbService.noteError('Backup: ekspor entitas gagal: $e');
      AppLog.error('backup.export_entities_failed', e);
      throw BackupExportException('export_entity_failed: $e');
    }
    // Domain JSON di prefs (hutang, tagihan rutin, template): baca apa
    // adanya sebagai string. Selalu ditulis — bahkan "[]" bila kosong —
    // agar restore mengganti (bukan menumpuk) data lama.
    for (final k in _prefsJsonKeys) {
      final sk = ProfileService.scoped(k);
      map[k] = prefs.getString(sk) ?? '[]';
    }
    var profileName = '';
    try {
      for (final pr in await ProfileService.profiles()) {
        if (pr.id == ProfileService.activeId) {
          profileName = pr.name;
          break;
        }
      }
    } catch (_) {
      // best-effort: meta profil kosong → backup tetap valid tanpa nama profil.
    }
    map['_meta'] = {
      'app': 'Kaji Finance',
      'package': 'com.el.finance',
      'exportedAt': DateTime.now().toIso8601String(),
      'version': await _appVersion(),
      'profile': profileName,
      // Penanda format backup (BUKAN app version, BUKAN versi kripto KAJI3).
      // Dibaca balik oleh [_checkBackupMeta] saat restore — file yang
      // menandai format lain ditolak, bukan diterjemahkan diam-diam.
      'format': _backupFormat,
      // Versi skema data. Backup lama (tanpa field ini) dianggap versi 1.
      // Restore menolak dataVersion yang lebih tinggi dari versi aplikasi,
      // dan menolak field yang ADA tapi tak terbaca sebagai bilangan.
      'dataVersion': _backupDataVersion,
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// Versi skema data backup saat ini. Naikkan bilamana bentuk struktur,
  /// keys, atau semantik entity berubah. Backup baru selalu dan hanya
  /// ditulis oleh versi aplikasi yang memakai konstanta ini.
  static const _backupDataVersion = 1;

  /// Penanda format file backup. Ditulis di `_meta` dan DIBACA saat restore
  /// ([_checkBackupMeta]) — field yang ditulis tapi tak pernah dibaca
  /// hanya ilusi kontrol versi.
  static const _backupFormat = 'kaji-backup';

  /// Ringkasan isi backup untuk pemeriksaan manual / verification UI.
  /// Menghitung baris per-domain struktural (entity map + domain JSON)
  /// TANPA menjalankan restore. `null` bila JSON tidak bisa di-decode
  /// sama sekali (file korup → UI tampilkan "tidak valid").
  static Future<Map<String, int>?> summarizeBackupContent(
    String jsonStr,
  ) async {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) return null;
      final out = <String, int>{};
      for (final k in _entityKeys) {
        final v = decoded[k];
        if (v is String) {
          final rows = (jsonDecode(v) as List?);
          out[k] = rows?.length ?? 0;
        }
      }
      for (final k in _prefsJsonKeys) {
        final v = decoded[k];
        if (v is String) {
          final rows = (jsonDecode(v) as List?);
          out[k] = rows?.length ?? 0;
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Nama berkas informatif: prefix + profil + cap tanggal-jam
  /// (bukan timestamp mentah). Aman karakter non-ascii → strip.
  static Future<String> _stampedName(String prefix, String suffix) async {
    var profile = 'profil';
    try {
      for (final pr in await ProfileService.profiles()) {
        if (pr.id == ProfileService.activeId) {
          final clean = pr.name
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
              .replaceAll(RegExp(r'^-+|-+$'), '');
          if (clean.isNotEmpty) profile = clean;
          break;
        }
      }
    } catch (_) {
      // best-effort: nama profil gagal dibaca → pakai 'profil'.
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
    return '$prefix-$profile-$stamp$suffix';
  }

  /// Cap waktu cadangan penuh terakhir (untuk pengingat di UI).
  static String get _kLastBackup => ProfileService.scoped('kaji_backup_last');

  static Future<void> noteBackupTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastBackup, DateTime.now().toIso8601String());
    } catch (e) {
      SecureDbService.noteError('Backup: catat waktu gagal: $e');
    }
  }

  static Future<DateTime?> lastBackupTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastBackup);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<File> saveToFile(String jsonStr) async {
    // Direktori cache sementara: file backup/share tidak menumpuk abadi
    // di dokumen + tidak meninggalkan plaintext riwayat keuangan.
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${await _stampedName('kaji-finance-backup', '.kaji.json')}',
    );
    final out = await file.writeAsString(jsonStr);
    await _cleanupOldBackups(dir, 'kaji-finance-backup-', '.kaji.json');
    // Best-effort: bersihkan tumpukan lama di direktori dokumen
    // (perilaku versi sebelum perbaikan #11).
    unawaited(_cleanupLegacyDocBackups());
    // P5: jejak ekspor (tanpa isi/nama sensitif), best-effort.
    unawaited(
      AuditService.log(
        action: AuditAction.backupExported,
        entityType: 'backup',
        entityId: 'full',
      ).catchError((_) {}),
    );
    return out;
  }

  static Future<File> saveCsvFile(String csv) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${await _stampedName('kaji-finance-transaksi', '.csv')}',
    );
    final out = await file.writeAsString(csv);
    await _cleanupOldBackups(dir, 'kaji-finance-transaksi-', '.csv');
    unawaited(_cleanupLegacyDocBackups());
    return out;
  }

  /// Backup KHUSUS transaksi: envelope JSON langsung dari database
  /// terenkripsi (bukan dari memori UI — anti-stale). Selain daftar
  /// transaksi, envelope membawa `goals` + `wallets` agar TARGET TABUNGAN
  /// ikut ter-backup dan ter-import (bukan cuma transaksinya).
  /// Kompatibel dua arah dengan [TransactionImportService.parseStaging]:
  /// bare-array lama tetap terbaca, envelope dibaca (transaksi via kunci
  /// `transactions`, goal/dompet via `goals`/`wallets`).
  ///
  /// Catatan: backup PENUH ([exportToJson]) juga selalu memuat transaksi
  /// (kunci `kaji_tx`) — fitur ini hanya versi ringkasnya.
  static Future<String> exportTransactionsJson() async {
    final tx = await SecureDbService.loadTable(SecureDbTables.tx);
    final goals = await SecureDbService.loadTable(SecureDbTables.goals);
    final wallets = await SecureDbService.loadTable(SecureDbTables.wallets);
    String profileName = '';
    try {
      for (final pr in await ProfileService.profiles()) {
        if (pr.id == ProfileService.activeId) {
          profileName = pr.name;
          break;
        }
      }
    } catch (_) {
      // best-effort: nama profil kosong → envelope transaksi tetap valid.
    }
    return const JsonEncoder.withIndent('  ').convert({
      'kind': 'kaji-tx-backup',
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'profile': profileName,
      'transactions': tx,
      'goals': goals,
      'wallets': wallets,
    });
  }

  static Future<File> saveTransactionsFile(String jsonStr) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${await _stampedName('kaji-finance-transaksi', '.json')}',
    );
    final out = await file.writeAsString(jsonStr);
    await _cleanupOldBackups(dir, 'kaji-finance-transaksi-', '.json');
    unawaited(_cleanupLegacyDocBackups());
    // P5: jejak ekspor (tanpa isi sensitif), best-effort.
    unawaited(
      AuditService.log(
        action: AuditAction.backupExported,
        entityType: 'backup',
        entityId: 'transactions',
      ).catchError((_) {}),
    );
    return out;
  }

  /// Simpan maksimal [keep] berkas terbaru berawalan [prefix]; sisanya +
  /// yang lebih tua dari [maxAge] dihapus. Semua best-effort.
  static Future<void> _cleanupOldBackups(
    Directory dir,
    String prefix,
    String suffix, {
    int keep = 10,
  }) async {
    try {
      final files = dir.listSync().whereType<File>().where((f) {
        final n = f.path.split(Platform.pathSeparator).last;
        return n.startsWith(prefix) && n.endsWith(suffix);
      }).toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        var tooOld = false;
        try {
          tooOld = f.statSync().modified.isBefore(cutoff);
        } catch (_) {
          // best-effort: stat gagal → hanya aturan keep yang dipakai.
        }
        if (i >= keep || tooOld) {
          try {
            f.deleteSync();
          } catch (_) {
            // best-effort: hapus file lama gagal → dibersihkan di run berikutnya.
          }
        }
      }
    } catch (_) {
      // best-effort: seluruh sapu berkas lama gagal → cache menumpuk, backup tetap jalan.
    }
  }

  static Future<void> _cleanupLegacyDocBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await _cleanupOldBackups(dir, 'kaji-finance-backup-', '.kaji.json');
      await _cleanupOldBackups(dir, 'kaji-finance-transaksi-', '.csv');
    } catch (_) {
      // best-effort: sapu dokumen lawas gagal → file lama menumpuk, fungsi inti aman.
    }
  }

  static Future<void> shareFile(File file) async {
    // Share-sheet memicu paused di sebagian ROM — tahan kunci layar.
    await AppLockGuard.run(() async {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'Backup Kaji Finance'),
      );
    });
  }

  /// Validasi satu entitas backup: tiap baris wajib lolos [_rowViolation]
  /// (parse via model: field wajib + rentang tipe + tanggal, lalu nominal
  /// uang yang masuk akal). Return false bila entitas non-kosong tapi TAK
  /// SATU pun baris valid (= korup) → file ditolak.
  /// Baris individual yang rusak di-skip saat impor (terdokumentasi) dan
  /// referensi yatim hanya diperingatkan (runtime no-op + rekonsiliasi
  /// menandainya pasca-restore, bukan diblokir).
  static bool _validateEntityRefs(String key, List<dynamic> items) {
    if (items.isEmpty) return true;
    var valid = 0;
    final rejected = <String>[];
    for (final item in items) {
      if (item is! Map) {
        rejected.add('bukan objek JSON');
        continue;
      }
      final reason = _rowViolation(key, Map<String, dynamic>.from(item));
      if (reason == null) {
        valid++;
      } else if (rejected.length < 3) {
        rejected.add(reason);
      }
    }
    if (valid == 0) {
      SecureDbService.noteError(
        'restore_validate: entitas $key tanpa baris valid '
        '(${items.length} input; alasan: ${rejected.join('; ')})',
      );
      return false;
    }
    return true;
  }

  /// Alasan baris backup TAK layak restore, atau null bila layak.
  ///
  /// Gate per-baris restore: [_validateEntityRefs] memakainya untuk menghitung
  /// baris yang mendarat, dan [_filterEntityRows] membuang baris ini dari
  /// data yang benar-benar ditulis ke DB — jadi "skip per-baris" bukan sekadar
  /// hitungan, tapi data korup tak pernah menyentuh storage.
  static String? _rowViolation(String key, Map<String, dynamic> m) {
    try {
      switch (key) {
        case 'kaji_tx':
          TransactionModel.fromJson(m);
        case 'kaji_wl':
          WalletModel.fromJson(m);
        case 'kaji_bd':
          BudgetCategory.fromJson(m);
        case 'kaji_goals':
          SavingsGoalModel.fromJson(m);
        case 'kaji_cat':
          CategoryModel.fromJson(m);
        case 'kaji_debts':
          // DebtEntry.fromJson throw bila invalid → dihitung invalid.
          DebtEntry.fromJson(m);
        case 'kaji_recurring_bills':
          // fromJson nullable → null berarti baris invalid. `isValid` WAJIB
          // ikut ditegakkan: mutator provider (add/updateRecurringBill)
          // menolak baris tak valid, jadi baris yang lolos restore tapi
          // gagal `isValid` (mis. amount <= 0) tidak akan pernah bisa
          // diperbaiki lewat UI — restore akan mengarang data yang editor
          // sendiri tolak. Semua baris prefs yang pernah tersimpan sudah
          // lolos `isValid` (satu-satunya jalan masuknya), jadi kegagalan
          // di sini berarti file bukan keluaran aplikasi ini.
          final bill = RecurringBill.fromJson(m);
          if (bill == null || !bill.isValid) {
            return 'kaji_recurring_bills: baris tak valid '
                '(amount>0/wallet/kategori/jatuh tempo)';
          }
        case 'kaji_tx_templates':
          if (TxTemplate.fromJson(m) == null) {
            return 'kaji_tx_templates: field wajib kosong';
          }
        default:
          // Kunci di luar daftar backup (tak terjangkau saat ini) — tetap
          // dihitung tak valid supaya kunci asing tak bisa lolos diam-diam.
          return 'kunci entitas tak dikenal';
      }
    } on Object catch (e) {
      return 'parse gagal: $e';
    }
    return _moneyViolation(key, m);
  }

  /// Gate nominal uang untuk satu baris backup.
  ///
  /// Menolak: non-finite (JSON `1e400` decode jadi `double.infinity`),
  /// di luar rentang [Money.maxMinorUnits], dan tanda yang tak pernah bisa
  /// dihasilkan aplikasi. Ambang SIGN sengaja diambil dari mutator provider
  /// (finance_transactions / finance_budgets / finance_savings /
  /// finance_wallets / finance_debts / finance_recurring) — bukan aturan
  /// baru — supaya "nilai uang yang sah" tetap punya satu sumber kebenaran.
  ///
  /// Alasannya keras, bukan kosmetik: nominal negatif/aneh yang mendarat
  /// tak bisa diperbaiki lewat UI (editor memintal amount > 0 di semua
  /// jalur), jadi menerimanya berarti user mendapat data permanen rusak dari
  /// file yang ia percaya. [Money.clampAmount] dipakai sebagai DETEKTOR
  /// overflow, bukan penebus: nilai yang masih perlu di-clamp adalah data
  /// rusak, bukan "~maksimal" yang layak disimpan diam-diam.
  static String? _moneyViolation(String key, Map<String, dynamic> m) {
    // Cek satu nilai nominal. `null` = field absen atau bertipe lain →
    // bukan urusan gate ini: field opsional/legacy memang boleh absen,
    // sedangkan tipe salah sudah tertangkap `fromJson` model.
    String? check(
      num? raw,
      String label, {
      required bool negOk,
      required bool zeroOk,
    }) {
      if (raw == null) return null;
      final d = raw.toDouble();
      if (!d.isFinite) return '$label non-finite';
      // Bulatkan dari double ASLI (bukan lewat [Money.roundBase] yang sudah
      // meng-clamp ke batas atas) supaya nilai di atas batas masih
      // terdeteksi, lalu uji hasilnya dengan pagar yang sama dengan
      // aritmetika ledger. Pembulatan = round-half-away, identik model.
      final v = d.round();
      if (Money.clampAmount(v) != v) return '$label di luar rentang Money';
      if (v < 0 && !negOk) return '$label negatif';
      if (v == 0 && !zeroOk) return '$label nol';
      return null;
    }

    String? field(String name, {required bool negOk, required bool zeroOk}) =>
        check(
          m[name] is num ? m[name] as num : null,
          '$key.$name',
          negOk: negOk,
          zeroOk: zeroOk,
        );

    switch (key) {
      case 'kaji_tx':
        // addTransaction/updateTransaction + impor transaksi: amount > 0.
        return field('amount', negOk: false, zeroOk: false);
      case 'kaji_bd':
        // addBudgetCategory/updateBudgetCategory: limit > 0. `spent` adalah
        // turunan rekonsiliasi (Σ expense) sehingga mustahil negatif.
        // `limit` = kunci legacy pra-`budget_limit`.
        return field('spent', negOk: false, zeroOk: true) ??
            field('budget_limit', negOk: false, zeroOk: false) ??
            field('limit', negOk: false, zeroOk: false);
      case 'kaji_wl':
        // addWallet/adjustWalletBalance: saldo tak boleh negatif — dan
        // karena kedua jalur itu juga menolak negatif, saldo negatif tak
        // bisa dikoreksi lewat UI. `initial_balance` mengikuti (dibuat
        // sama dengan saldo saat dompet dibuat); optional untuk backup lama.
        return field('balance', negOk: false, zeroOk: true) ??
            field('initial_balance', negOk: false, zeroOk: true) ??
            field('initialBalance', negOk: false, zeroOk: true);
      case 'kaji_goals':
        // addGoal: target > 0. `saved` boleh > target (tabungan lewat
        // target tetap sah) tapi tak boleh negatif.
        return field('target', negOk: false, zeroOk: false) ??
            field('saved', negOk: false, zeroOk: true);
      case 'kaji_debts':
        // Layar hutang + finance_debts: principal > 0 dan tiap cicilan > 0.
        final principal = field('principal', negOk: false, zeroOk: false);
        if (principal != null) return principal;
        final pays = m['payments'];
        if (pays is List) {
          for (final e in pays) {
            if (e is! Map) continue;
            final amount = e['amount'];
            final bad = check(
              amount is num ? amount : null,
              '$key.payments.amount',
              negOk: false,
              zeroOk: false,
            );
            if (bad != null) return bad;
          }
        }
        return null;
      case 'kaji_recurring_bills':
        // `amount > 0` sudah ditegakkan `RecurringBill.isValid` di
        // [_rowViolation] (sumber kebenaran, bukan rule duplikat); di sini
        // hanya pagar overflow.
        return field('amount', negOk: true, zeroOk: true);
      case 'kaji_tx_templates':
        // Template hanya mengisi keypad form; nominal 0 sah (formulir belum
        // diisi), negatif tidak pernah.
        return field('amount', negOk: false, zeroOk: true);
      default:
        return null;
    }
  }

  /// Buang baris yang gagal [_rowViolation] dari JSON entitas SEBELUM
  /// diteruskan ke DB — inilah "skip per-baris" yang sesungguhnya.
  ///
  /// Wajib karena `SecureDbService` hanya menyaring KOLOM dan mensyaratkan
  /// `id`: tanpa langkah ini, baris yang sudah dinyatakan invalid oleh gate
  /// tetap akan mendarat di tabel dan jadi data korup yang tak bisa
  /// diperbaiki UI. Key/value baris yang lolos dibiarkan apa adanya
  /// (tanpa re-mapping) supaya bentuk file tak berubah.
  static Map<String, String> _filterEntityRows(Map<String, String> entityData) {
    final out = <String, String>{};
    entityData.forEach((key, raw) {
      List<dynamic>? rows;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) rows = decoded;
      } catch (_) {
        // Sudah divalidasi tahap 1 — tak terjangkau.
      }
      if (rows == null) {
        // Bukan List: biarkan apa adanya agar DB yang menolak / nihil,
        // persis seperti sebelum gate ini (tanpa menebak-nebak).
        out[key] = raw;
        return;
      }
      final keep = <dynamic>[];
      var dropped = 0;
      for (final item in rows) {
        if (item is Map &&
            _rowViolation(key, Map<String, dynamic>.from(item)) == null) {
          keep.add(item);
        } else {
          dropped++;
        }
      }
      if (dropped == 0) {
        out[key] = raw;
        return;
      }
      SecureDbService.noteError(
        'restore_skip_baris: $key — $dropped/${rows.length} baris ditolak '
        'gate validasi (tak ditulis ke DB)',
      );
      out[key] = jsonEncode(keep);
    });
    return out;
  }

  /// Gate invarian backup sebelum restore MENGGANTI seluruh data (P8).
  /// Dijalankan setelah validasi struktural, sebelum satu pun byte ditulis.
  ///
  /// Dua kelas temuan, karena risikonya berbeda jauh dan TIDAK boleh
  /// diperlakukan sama:
  ///
  /// - **Ditegakkan** — [_enforceMoneyIntegrity]: bila satu entitas non-kosong
  ///   tak punya satu pun baris dengan nominal yang bisa dipercaya, fungsi ini
  ///   melempar [FormatException]. Restore lalu berhenti SEBELUM data existing
  ///   tersentuh. Nominal negatif/aneh adalah satu-satunya invarian yang tak
  ///   bisa "diperbaiki" setelah mendarat: semua jalur mutasi/UI memintal
  ///   amount > 0, jadi baris seperti itu permanen rusak — lebih baik file
  ///   ditolak daripada data user dibiarkan korup. Per-row skip tetap berlaku
  ///   (lihat [_rowViolation]/[_filterEntityRows]): ini menolak HANYA saat tak
  ///   satu pun baris layak, persis seperti aturan "tolak file bila tak ada
  ///   baris valid" yang sudah ada.
  /// - **Peringatan** (nilai kembalian) — drift nilai TURUNAN: saldo dompet
  ///   vs opening+ledger, spent anggaran vs Σ expense, tabungan vs Σ
  ///   deposit−penarikan. Drift tak diblokir: nilainya bisa dibetulkan
  ///   rekonsiliasi pasca-restore, dan menolak file hanya karena drift
  ///   bisa membekukan satu-satunya salinan user. Dicatat via noteError +
  ///   audit agar terlihat.
  ///
  /// - Wallet P3+ (baris MEMUAT `initial_balance`): expected vs balance.
  ///   Baris legacy tanpa kunci → opening tak diketahui → dilewati.
  /// - Budget: spent vs hitungan ulang pada bulan [exportedAt] (bulan
  ///   ekspor; null = lewati karena spent bersifat bulan-berjalan).
  /// - Goal: saved vs Σ deposit−withdraw tertaut.
  ///
  /// Melempar [FormatException] (bukan mengembalikan daftar) untuk pelanggaran
  /// uang supaya "validate" di nama ini tidak berbohong: pemanggil yang
  /// memperlakukannya sebagai sekadar laporan akan restoring file korup.
  static List<String> validateBackupInvariants(
    Map<String, String> entityData, {
    DateTime? exportedAt,
  }) {
    _enforceMoneyIntegrity(entityData);
    final warnings = <String>[];
    try {
      List<Map<String, dynamic>> rowsOf(String key) {
        final raw = entityData[key];
        if (raw == null) return [];
        final out = <Map<String, dynamic>>[];
        try {
          final list = jsonDecode(raw);
          if (list is! List) return out;
          for (final item in list) {
            if (item is Map) out.add(Map<String, dynamic>.from(item));
          }
        } catch (_) {
          // Struktural sudah divalidasi pemanggil — tak terjangkau.
        }
        return out;
      }

      final txs = <TransactionModel>[];
      for (final m in rowsOf('kaji_tx')) {
        try {
          txs.add(TransactionModel.fromJson(m));
        } catch (_) {
          continue;
        }
      }
      // Hanya baris yang benar-benar terpakai untuk walletExpected —
      // mengindeks `walletRows` dengan indeks hasil parse (yang bisa lebih
      // pendek) akan memakai baris dompet yang SALAH, atau melempar
      // RangeError yang melempar akan membuang SEMUA peringatan.
      final wallets = <WalletModel>[];
      final walletRows = <Map<String, dynamic>>[];
      for (final m in rowsOf('kaji_wl')) {
        try {
          wallets.add(WalletModel.fromJson(m));
          walletRows.add(m);
        } catch (_) {
          continue;
        }
      }
      for (var i = 0; i < wallets.length; i++) {
        // Legacy: tanpa kunci opening → tak bisa divalidasi, lewati.
        if (!walletRows[i].containsKey('initial_balance') &&
            !walletRows[i].containsKey('initialBalance')) {
          continue;
        }
        final w = wallets[i];
        final expected = ReconciliationService.walletExpected(
          w,
          txs,
          allWallets: wallets,
        );
        if (expected != w.balance) {
          warnings.add(
            'wallet ${w.name}: expected $expected '
            'actual ${w.balance} diff ${w.balance - expected}',
          );
        }
      }
      if (exportedAt != null) {
        for (final m in rowsOf('kaji_bd')) {
          BudgetCategory b;
          try {
            b = BudgetCategory.fromJson(m);
          } catch (_) {
            continue;
          }
          final expected = ReconciliationService.budgetExpected(
            b.name,
            txs,
            month: exportedAt,
          );
          if (expected != b.spent) {
            warnings.add(
              'budget ${b.name}: expected $expected '
              'actual ${b.spent}',
            );
          }
        }
      }
      for (final m in rowsOf('kaji_goals')) {
        SavingsGoalModel g;
        try {
          g = SavingsGoalModel.fromJson(m);
        } catch (_) {
          continue;
        }
        final r = ReconciliationService.goalExpected(g.id, txs);
        if (r.expected != g.saved) {
          warnings.add(
            'goal ${g.name}: expected ${r.expected} '
            'actual ${g.saved}',
          );
        }
      }
    } catch (e) {
      SecureDbService.noteError('restore_invariants_gagal: $e');
    }
    return warnings;
  }

  /// Terapkan gate [_moneyViolation] ke seluruh baris file dan TOLAK file
  /// (lempar [FormatException]) bila ada entitas non-kosong yang tak punya
  /// satu pun baris dengan nominal bisa dipercaya.
  ///
  /// Fail-closed dan hanya di batas "nol baris layak" supaya policy restore
  /// tak berubah: file dengan 1 baris korup di antara 500 baris baik tetap
  /// restore 499 barisnya (korupnya di-skip + dicatat), sedangkan file yang
  /// SELURUH nominalnya rusak ditolak utuh — persis aturan yang sudah
  /// berlaku di [_validateEntityRefs] untuk kerusakan struktural.
  static void _enforceMoneyIntegrity(Map<String, String> entityData) {
    entityData.forEach((key, raw) {
      List<dynamic> rows;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return; // struktur — ditangani pemanggil
        rows = decoded;
      } catch (_) {
        return; // struktur — ditangani pemanggil
      }
      if (rows.isEmpty) return;
      var trusted = 0;
      String? firstReason;
      for (final item in rows) {
        if (item is! Map) {
          firstReason ??= 'bukan objek JSON';
          continue;
        }
        final reason = _moneyViolation(key, Map<String, dynamic>.from(item));
        if (reason == null) {
          trusted++;
        } else {
          firstReason ??= reason;
        }
      }
      if (trusted == 0) {
        SecureDbService.noteError(
          'restore_money: entitas $key tanpa nominal yang bisa dipercaya '
          '(${rows.length} input; contoh: $firstReason)',
        );
        throw FormatException('backup berisi nominal tak valid pada $key');
      }
    });
  }

  /// Peringatkan referensi yatim antar-entitas backup (tak memblokir;
  /// lihat [_validateEntityRefs]). Dicek sekali untuk seluruh file:
  /// runtime menoleransi no-op + rekonsiliasi menandainya pasca-restore.
  static void _warnDanglingTxRefs(Map<String, String> entityData) {
    try {
      Set<String> idsOf(String key) {
        final raw = entityData[key];
        if (raw == null) return {};
        final out = <String>{};
        try {
          final list = jsonDecode(raw);
          if (list is! List) return out;
          for (final item in list) {
            if (item is Map && item['id'] is String) {
              out.add(item['id'] as String);
            }
          }
        } catch (_) {
          // Sudah divalidasi tahap 1 — tak terjangkau.
        }
        return out;
      }

      final walletIds = idsOf('kaji_wl');
      final goalIds = idsOf('kaji_goals');
      final rawTx = entityData['kaji_tx'];
      if (rawTx == null) return;
      final list = jsonDecode(rawTx);
      if (list is! List) return;
      var dangling = 0;
      for (final item in list) {
        if (item is! Map) continue;
        for (final k in ['fromWalletId', 'toWalletId']) {
          final v = item[k];
          if (v is String &&
              v.isNotEmpty &&
              walletIds.isNotEmpty &&
              !walletIds.contains(v)) {
            dangling++;
          }
        }
        final g = item['linkedGoalId'];
        if (g is String &&
            g.isNotEmpty &&
            goalIds.isNotEmpty &&
            !goalIds.contains(g)) {
          dangling++;
        }
      }
      if (dangling > 0) {
        SecureDbService.noteError(
          'restore_validate: $dangling referensi yatim di kaji_tx '
          '(no-op saat runtime, terlihat di rekonsiliasi)',
        );
      }
    } catch (_) {
      // best-effort: cek referensi gagal → impor tetap lanjut.
    }
  }

  /// Kunci jurnal restore ter-scope profil. Ditulis SEBELUM tulis destruktif
  /// pertama, DIHAPUS saat restore selesai atau saat file ditolk tanpa satu
  /// pun baris ditulis ([_rejectRestore]).
  ///
  /// Invariant yang-dihormati sejak perbaikan jurnal poisoning: jurnal yang
  /// tersisa SELALU berarti "ada data yang mungkin sudah separuh ter-tulis".
  /// Itu hanya sah kalau ada yang benar-benar ter-tulis; menempelkan jurnal di
  /// jalur penolakan membuat [checkRestoreJournal] memunculkan peringatan
  /// palsu di setiap cold start (restore file non-Kaji = `{}` akan memicu).
  static String get _journalKey => ProfileService.scoped('kaji_restore_jrnl');

  /// Hasil restore terakhir untuk UI & debug: `null` = belum ada restore di
  /// sesi ini, `'ok'`, `'rejected'` (tak ada data tersentuh), atau
  /// `'failed_after_db_commit'` (DB sudah ter-replace penuh lalu gagal di
  /// prefs/PIN — data existing TIDAK dikembalikan).
  ///
  /// Diperlukan karena `importFromJsonString` hanya mengembalikan `bool`:
  /// dua kegagalan yang sangat berbeda itu terlihat sama oleh pemanggil.
  static String? lastRestoreOutcome;

  /// Ambil snapshot darurat dari keadaan SEKARANG ke file temp, SEBELUM
  /// restore menimpa apa pun. Best-effort: bila snapshot gagal, restore
  /// tetap lanjut (niat eksplisit user) tapi kegagalannya dicatat.
  /// Return path file snapshot, atau null bila gagal.
  static Future<String?> snapshotCurrentState() async {
    try {
      final jsonStr = await exportToJson();
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final file = File('${dir.path}/kaji-emergency-$stamp.kaji.json');
      await file.writeAsString(jsonStr);
      await _cleanupOldBackups(dir, 'kaji-emergency-', '.kaji.json', keep: 3);
      return file.path;
    } catch (e) {
      SecureDbService.noteError('restore_snapshot_gagal: $e');
      AppLog.error('backup.emergency_snapshot_failed', e);
      return null;
    }
  }

  static Future<void> _journalWrite(String state, {String? snapshot}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _journalKey,
        jsonEncode({
          'state': state,
          'at': DateTime.now().toIso8601String(),
          if (snapshot != null) 'snapshot': snapshot,
        }),
      );
    } catch (e) {
      SecureDbService.noteError('restore_journal_write_gagal: $e');
    }
  }

  static Future<void> _journalClear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_journalKey);
    } catch (e) {
      SecureDbService.noteError('restore_journal_clear_gagal: $e');
    }
  }

  /// File DITOLAK dan nol baris data tersentuh → catat alasannya lalu
  /// HAPUS jurnal.
  ///
  /// Bedanya dengan jalur gagal pasca-commit sangat penting dan jangan
  /// pernah diratakan: di sini data existing utuh 100% (belum ada satu pun
  /// write), jadi tidak ada "data mungkin setengah tertulis" untuk dilaporkan.
  /// Jurnal yang dibiarkan di jalur ini ([_journalClear] hanya di success
  /// dulu) membuat [checkRestoreJournal] berteriak "restore_interrupted"
  /// pada SETIAP cold start berikutnya sampai ada restore yang berhasil —
  /// termasuk untuk kasus paling umum: file `{}` atau JSON non-Kaji.
  ///
  /// Sebaliknya, jalur yang SUDAH men-tulis sebagian (DB ter-commit, prefs
  /// gagal) TIDAK boleh memanggil ini: di situ peringatan jurnal justru
  /// satu-satunya bukti bahwa mungkin perlu dipulihkan dari snapshot darurat.
  static Future<void> _rejectRestore(String reason) async {
    SecureDbService.noteError(reason);
    lastRestoreOutcome = 'rejected';
    await _journalClear();
  }

  /// Kegagalan SETELAH commit: catat bahwa DB sudah ter-replace penuh dan
  /// di mana snapshot darurat berada, lalu JANGAN bersihkan jurnal (lihat
  /// [_rejectRestore]).
  static Future<void> _logPartialRestore(
    String stage,
    Object err, {
    required String? snapshotPath,
  }) async {
    SecureDbService.noteError(
      'restore_gagal_pascacommit($stage): $err — '
      'database SUDAH diganti total oleh file backup (data lama tidak '
      'dikembalikan); snapshot darurat: ${snapshotPath ?? 'tak ada'}',
    );
    AppLog.error(
      'backup.restore_partial_commit',
      err,
      data: {'stage': stage, 'hasSnapshot': snapshotPath != null},
    );
    lastRestoreOutcome = 'failed_after_db_commit';
  }

  /// Dipanggil sekali saat startup (setelah ProfileService.init).
  /// Bila restore sebelumnya tidak selesai (crash/kill di tengah),
  /// catat temuannya agar terlihat di Info Debug — file snapshot darurat
  /// (bila ada) adalah jalur pemulihan manual lewat layar Backup.
  ///
  /// Keberadaan jurnal = "ada data yang mungkin separuh ter-tulis", bukan
  /// sekadar "restore pernah jalan": jalur yang ditolak tanpa satu pun
  /// write sudah menghapus jurnalnya sendiri di [_rejectRestore]. Itu sebabnya
  /// restore file `{}` / JSON non-Kaji tak lagi menyalakan peringatan ini di
  /// setiap cold start.
  static Future<void> checkRestoreJournal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_journalKey);
      if (raw == null || raw.isEmpty) return;
      Map<String, dynamic>? j;
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) j = d;
      } catch (_) {
        // Jurnal korup = anggap interupsi juga.
      }
      final state = j?['state'] as String?;
      final snap = j?['snapshot'];
      SecureDbService.noteError(
        'restore_interrupted: restore sebelumnya tidak selesai '
        '(state=$state). Data mungkin setengah tertulis.'
        '${snap is String && snap.isNotEmpty ? ' Snapshot darurat: $snap.' : ''}',
      );
      AppLog.event(
        'backup.restore_interrupted',
        data: {
          'state': state ?? 'corrupt',
          'hasSnapshot': snap is String && snap.isNotEmpty,
        },
      );
      // Jurnal dibiarkan — bukti untuk diagnosis; dibersihkan saat
      // restore berikutnya selesai.
    } catch (e) {
      SecureDbService.noteError('restore_journal_check_gagal: $e');
    }
  }

  /// Restore bertahap P8: baca → dekripsi (di pemanggil) → parse → gate
  /// versi/format → validasi SEMUA entitas → snapshot darurat + jurnal →
  /// tulis entitas (satu transaksi DB) → prefs → reset PIN.
  ///
  /// ## Cakupan jaminan. Versi lama dokumen ini menjanjikan "bila restore
  /// gagal di tahap mana pun, data existing tetap utuh dan PIN tak
  /// di-reset" — itu SALAH untuk setiap kegagalan setelah commit DB, jadi
  /// jangan dibaca sebagai jaminan atomisitas.
  ///
  /// Yang benar-benar dijamin fail-closed, tanpa menyentuh DB, prefs, PIN,
  /// maupun biometrik:
  /// - TAHAP 0: gate versi/format ([_checkBackupMeta]).
  /// - TAHAP 1: validasi struktural + [_rowViolation] (field wajib, rentang
  ///   tipe, tanggal, dan nominal uang lewat [_moneyViolation]) untuk SELURUH
  ///   entitas, plus [_warnDanglingTxRefs].
  /// - TAHAP 1b: [_enforceMoneyIntegrity] menolak file yang tak punya satu
  ///   pun nominal yang bisa dipercaya per entitas.
  /// Kegagalan mana pun di sini terjadi SEBELUM [snapshotCurrentState] dan
  /// sebelum satu pun byte storage berubah; jalur ini juga menghapus jurnalnya
  /// sendiri ([_rejectRestore]) sehingga tak menyisakan peringatan palsu.
  ///
  /// Yang TIDAK dijamin, dan tak akan dijamin tanpa redesign: setelah
  /// `importEntityJson` COMMIT, prefs masih ditulis lewat API yang satu per
  /// satu, lalu PIN dihapus. Dua store (SQLite terenkripsi +
  /// SharedPreferences) berarti dua mekanisme commit, tanpa transaksi lintas
  /// keduanya. Konsekuensi konkretnya:
  /// - `prefs.setString` gagal (mis. storage hampir penuh) → SELURUH database
  ///   sudah ter-ganti, prefs lama masih utuh, PIN belum di-reset.
  /// - `clearPin()` gagal → DB + prefs sudah ter-ganti.
  /// [snapshotCurrentState] adalah jaring pengaman kedua kasus, BUKAN
  /// rollback: tak ada mekanisme yang mengembalikan baris yang sudah
  /// ter-commit, dan menambahkannya butuh jalur staging/swap di
  /// SecureDbService (di luar file ini). Karena itu setiap kegagalan
  /// pasca-commit dilog eksplisit lewat [_logPartialRestore] +
  /// [lastRestoreOutcome], supaya "restore gagal" tak pernah ditafsirkan
  /// "tidak ada yang berubah".
  ///
  /// Urutan prefs-sebelum-DB sengaja TIDAK dipakai meski terlihat lebih aman:
  /// memindahkan prefs (termasuk reset PIN) ke sebelum import DB hanya
  /// menukar satu lubang dengan lubang yang lebih buruk — PIN sudah
  /// ter-reset dan prefs sudah ter-ganti untuk file yang ternyata gagal
  /// menulis DB, persis kebalikan dari janji "PIN tak di-reset saat restore
  /// gagal".
  ///
  /// Policy invalid (terdokumentasi, TIDAK diubah): entitas korup struktural
  /// (bukan List JSON) atau tanpa satu pun baris valid → TOLAK seluruh file;
  /// baris rusak per-baris (termasuk nominal mustahil) → di-skip DAN tidak
  /// ditulis ke DB ([_filterEntityRows]) dengan verifikasi mendarat (tolak
  /// bila tak satu pun mendarat padahal input ada). Silent failure tidak ada:
  /// return false + noteError + [lastRestoreOutcome].
  static Future<bool> importFromJsonString(String jsonStr) async {
    final Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        lastRestoreOutcome = 'rejected';
        return false;
      }
      map = decoded;
    } catch (_) {
      lastRestoreOutcome = 'rejected';
      return false;
    }
    // TAHAP 0 — versi & format. Backup yang `dataVersion`-nya lebih baru
    // dari aplikasi ditolak, begitu pula field yang ADA tapi tak terbaca
    // (mis. `"dataVersion": "99999"` sebagai String, atau `_meta` yang bukan
    // objek JSON): gate versi yang dilewati diam-diam berarti file dari
    // versi berikutnya bisa menimpa data tanpa pernah dicek. Backup lama
    // yang field-nya memang ABSEN tetap diterima sebagai versi 1.
    if (!_checkBackupMeta(map)) {
      lastRestoreOutcome = 'rejected';
      return false;
    }
    // TAHAP 1 — validasi struktural entitas (tanpa tulis apa pun).
    final entityData = <String, String>{};
    for (final k in _entityKeys) {
      final v = map[k];
      if (v is String) entityData[k] = v;
    }
    // Domain JSON di prefs ikut divalidasi dengan kebijakan yang sama:
    // bukan-List atau tanpa satu pun baris valid → tolak seluruh file.
    final prefsJsonData = <String, String>{};
    for (final k in _prefsJsonKeys) {
      final v = map[k];
      if (v is String) prefsJsonData[k] = v;
    }
    for (final entry in {...entityData, ...prefsJsonData}.entries) {
      List<dynamic> items;
      try {
        final decoded = jsonDecode(entry.value);
        if (decoded is! List) {
          lastRestoreOutcome = 'rejected';
          return false;
        }
        items = decoded;
      } catch (_) {
        SecureDbService.noteError(
          'restore_validate: entitas ${entry.key} bukan List JSON',
        );
        lastRestoreOutcome = 'rejected';
        return false;
      }
      if (!_validateEntityRefs(entry.key, items)) {
        lastRestoreOutcome = 'rejected';
        return false;
      }
    }
    _warnDanglingTxRefs(entityData);
    // TAHAP 1b — invarian finansial isi backup. Drift nilai TURUNAN =
    // peringatan saja (bisa dibetulkan rekonsiliasi pasca-restore); nominal
    // mustahil = DITEGAKKAN (file ditolak) lewat [_enforceMoneyIntegrity].
    DateTime? exportedAt;
    try {
      final meta = map['_meta'];
      if (meta is Map && meta['exportedAt'] is String) {
        exportedAt = DateTime.tryParse(meta['exportedAt'] as String);
      }
    } catch (_) {
      // best-effort: tanpa bulan ekspor → cek budget dilewati.
    }
    final List<String> invariantWarnings;
    try {
      invariantWarnings = validateBackupInvariants(
        entityData,
        exportedAt: exportedAt,
      );
    } on FormatException catch (e) {
      // Ditegakkan: ditolak SEBELUM snapshot/jurnal, jadi data existing
      // belum tersentuh dan tak ada jurnal tertinggal.
      SecureDbService.noteError('restore_money: file ditolak: ${e.message}');
      lastRestoreOutcome = 'rejected';
      return false;
    }
    if (invariantWarnings.isNotEmpty) {
      SecureDbService.noteError(
        'restore_invariants: ${invariantWarnings.length} peringatan: '
        '${invariantWarnings.take(5).join(' | ')}',
      );
    }
    // Buang baris yang gagal gate SEBELUM serialisasi ke DB. Tanpa ini
    // "skip per-baris" cuma jadi hitungan: SecureDbService menyaring kolom,
    // bukan nilai, jadi baris yang sudah dinyatakan invalid tetap mendarat.
    final cleanEntityData = _filterEntityRows(entityData);
    final cleanPrefsJsonData = _filterEntityRows(prefsJsonData);
    // TAHAP 1c — snapshot darurat + jurnal. Snapshot diambil SETELAH
    // validasi lolos (file pasti baik) dan SEBELUM tulis destruktif
    // pertama. Jurnal menandai restore berjalan; crash/kill di titik
    // mana pun setelah ini terdeteksi saat startup berikutnya.
    final snapshotPath = await snapshotCurrentState();
    await _journalWrite('prepared', snapshot: snapshotPath);
    // TAHAP 2 — tulis entitas atomik (single DB transaction + rollback).
    // Throw / landed-0-dengan-input → return false SEBELUM prefs/PIN.
    //
    // Jurnal tetap dibersihkan di kedua jalur itu (lihat [_rejectRestore]):
    // DB memakai `replace` dalam SATU transaksi, jadi throw = rollback utuh
    // dan landed-0 = belum ada entitas yang tersimpan user. Nol baris
    // tersentuh → tak ada "data mungkin setengah tertulis" untuk dilaporkan,
    // dan membiarkan jurnal di sini memunculkan peringatan palsu di setiap
    // cold start (restore file `{}` = pemicu paling umum).
    if (cleanEntityData.isNotEmpty) {
      final Map<String, int> landed;
      try {
        landed = await SecureDbService.importEntityJson(cleanEntityData);
      } catch (e) {
        await _rejectRestore('restore_entities_gagal: $e');
        lastRestoreOutcome = 'rejected';
        return false;
      }
      var inputRows = 0;
      for (final v in cleanEntityData.values) {
        try {
          inputRows += (jsonDecode(v) as List).length;
        } catch (_) {
          // Sudah divalidasi tahap 1 — tak terjangkau.
        }
      }
      final landedRows = landed.values.fold(0, (a, b) => a + b);
      if (inputRows > 0 && landedRows == 0) {
        await _rejectRestore('db_import_all_failed: input=$inputRows landed=0');
        lastRestoreOutcome = 'rejected';
        return false;
      }
    }
    // TAHAP 3 — prefs ringan (state non-finansial) + domain JSON prefs
    // (hutang, tagihan rutin, template — MENGGANTI isi lama, bukan
    // menumpuk, agar restore benar-benar mengembalikan keadaan backup).
    // TAHAP INI BISA GAGAL SETELAH DB SUDAH TER-COMMIT — [_logPartialRestore]
    // yang mencatatnya, dan jurnal sengaja dibiarkan (satu-satunya kasus
    // peringatan restore_interrupted memang sah).
    try {
      final prefs = await SharedPreferences.getInstance();
      var applied = cleanEntityData.length;
      for (final entry in cleanPrefsJsonData.entries) {
        // Tulis ter-scope profil aktif (restore tak bocor antar-profil).
        // Nilai sudah lolos validasi tahap 1 — tulis apa adanya.
        await prefs.setString(ProfileService.scoped(entry.key), entry.value);
        applied++;
      }
      for (final k in _keys) {
        if (map.containsKey(k)) {
          final v = map[k];
          // Tulis ter-scope profil aktif (restore tak bocor antar-profil).
          final sk = ProfileService.scoped(k);
          // Nominal tak terhingga (JSON `1e400` → `double.infinity`) akan
          // MATI di `round()`/`setDouble` — dan itu jadi kegagalan prefs
          // SETELAH DB ter-ganti. Skip + catat jauh lebih murah.
          if (v is num && !v.toDouble().isFinite) {
            SecureDbService.noteError('restore_prefs_lewati: $k non-finite');
            continue;
          }
          // P4: allowance kini int; backup lama double dibulatkan.
          if (k == 'kaji_allowance' && v is num) {
            await prefs.setInt(sk, v.round());
          } else if (v is String) {
            await prefs.setString(sk, v);
          } else if (v is double) {
            await prefs.setDouble(sk, v);
          } else if (v is int) {
            await prefs.setInt(sk, v);
          } else if (v is bool) {
            await prefs.setBool(sk, v);
          } else if (v is List) {
            // StringList (mis. kaji_exp_flags) — hanya string murni.
            try {
              await prefs.setStringList(sk, v.map((e) => '$e').toList());
            } catch (e) {
              SecureDbService.noteError(
                'Backup: tulis StringList $k gagal: $e',
              );
            }
          } else {
            // Tipe tak dikenal (mis. Map rakitan) → abaikan tanpa dihitung.
            continue;
          }
          applied++;
        }
      }
      // Tolak file yang tidak mengandung satu pun kunci dikenal —
      // cegah "import sukses" palsu yang me-reset state kunci layar.
      // Diperiksa SEBELUM prefs pertama ditulis, jadi `applied == 0`
      // berarti benar-benar nol byte yang tersentuh → jurnal aman dihapus.
      if (applied == 0) {
        await _rejectRestore('restore_kosong: tak ada kunci dikenal di file');
        return false;
      }
      // PIN TIDAK PERNAH dipulihkan dari backup (sesuai README/keamanan):
      // kunci layar adalah state perangkat ini. Hapus via AuthService agar
      // bersih dari secure storage maupun sisa prefs lawas.
      // Biometrik ikut dimatikan: bio-aktif tanpa PIN = lockout permanen
      // (pengguna gagal bio lalu verifyPin selalu false, tanpa pemulihan).
      await AuthService.clearPin();
      // Scoped profil aktif via AuthService (bukan kunci polos):
      // bio-aktif tanpa PIN = lockout permanen. clearPin sudah
      // mematikan flag PIN, tapi bio dimatikan eksplisit di sini
      // karena _keys di atas baru saja me-restore nilainya.
      await AuthService.setBioEnabled(false);
      // Pengaman akhir: flag aktif tanpa PIN tersimpan = matikan.
      // Cek via secure storage (sumber kebenaran PIN), bukan
      // prefs.containsKey('kaji_pin') — PIN tinggal di Keystore.
      if (await AuthService.isPinEnabled() &&
          await AuthService.getPin() == null) {
        await AuthService.setPinEnabled(false);
      }
      // P5: jejak impor sukses (ditulis SETELAH data mendarat + PIN
      // di-reset; best-effort, tak menggagalkan restore). P8: sertakan
      // hitungan peringatan invarian.
      unawaited(
        AuditService.log(
          action: AuditAction.backupImported,
          entityType: 'backup',
          entityId: 'full',
          metadata: {
            'applied': applied,
            'invariantWarnings': invariantWarnings.length,
          },
        ).catchError((_) {}),
      );
      // Restore selesai penuh — hapus jurnal agar startup berikutnya
      // tahu tidak ada interupsi.
      await _journalClear();
      lastRestoreOutcome = 'ok';
      return applied > 0;
    } on Object catch (e) {
      // Titik ini DB sudah ter-ganti total (atau belum ada entitas sama
      // sekali bila file cuma prefs). Jangan clearing jurnal di sini: ini
      // justru kasus yang peringatan restore_interrupted tuju.
      SecureDbService.noteError('restore_prefs_gagal: $e');
      AppLog.error('backup.restore_prefs_failed', e);
      await _logPartialRestore('prefs', e, snapshotPath: snapshotPath);
      return false;
    }
  }

  /// Gerbang versi + format backup — fail-closed tanpa melonggarkan
  /// kompatibilitas backup lama.
  ///
  /// Field yang ADA tapi tak bisa dipakai DITOLAK: gate versi yang longgar
  /// (`if (v is num)` → abaikan kalau bukan num) membuat file ber-`dataVersion`
  /// String, atau `_meta` yang bukan objek, lolos tanpa cek sama sekali —
  /// persis kebalikan dari tujuan gerbang ini. Field yang benar-benar ABSEN
  /// tetap diartikan versi 1 (seluruh backup pra-`dataVersion`), jadi
  /// kompatibilitas dua arah tetap terjaga.
  ///
  /// `format` juga dibaca di sini: tanpa pemeriksaan field itu dekoratif
  /// (ditulis di ekspor lalu diabaikan selamanya). File yang `_meta`-nya
  /// menandai format lain ditolak, bukan diterjemahkan diam-diam.
  static bool _checkBackupMeta(Map<String, dynamic> map) {
    final rawMeta = map['_meta'];
    if (rawMeta == null) return true; // backup lama → dianggap versi 1
    if (rawMeta is! Map) {
      SecureDbService.noteError('restore_version: _meta bukan objek JSON');
      return false;
    }
    final meta = Map<String, dynamic>.from(rawMeta);
    final format = meta['format'];
    if (format != null && format != _backupFormat) {
      SecureDbService.noteError(
        'restore_format: format "$format" != "$_backupFormat"',
      );
      return false;
    }
    final rawV = meta['dataVersion'];
    if (rawV == null) return true; // backup lama → versi 1
    int v;
    if (rawV is int) {
      v = rawV;
    } else if (rawV is double &&
        rawV.isFinite &&
        rawV == rawV.roundToDouble()) {
      // 1.0 (double bulat) sah — versi skema selalu bilangan bulat, 1.5 tidak.
      v = rawV.toInt();
    } else {
      SecureDbService.noteError(
        'restore_version: dataVersion "$rawV" tak terbaca',
      );
      return false;
    }
    if (v < 1) {
      SecureDbService.noteError('restore_version: dataVersion $v invalid');
      return false;
    }
    if (v > _backupDataVersion) {
      SecureDbService.noteError(
        'restore_version: dataVersion $v lebih baru dari aplikasi '
        '($_backupDataVersion)',
      );
      return false;
    }
    return true;
  }

  // --- Enkripsi backup (Phase 6: KAJI3 AEAD standar) ---
  //
  // Format BARU yang ditulis: KAJI3 = AES-256-GCM (authenticated encryption)
  // dengan kunci PBKDF2-HMAC-SHA256(pin, salt acak 16B, 100.000 iterasi,
  // 32B), nonce acak 12B per file, tag autentikasi 16B dari cipher.
  // Ciphertext yang diubah / password salah → dekripsi GAGAL via tag
  // (fail-closed), bukan checksum di dalam ciphertext.
  // Iterasi 100k = amplop performa yang sama dengan KAJI2 (terbukti tidak
  // menjank low-end via isolate); PIN 4-6 digit tetap proteksi ringan —
  // file terproteksi wajib disimpan di tempat aman (lihat backupProtectBody).
  // Format teks:
  //   KAJI3:<kdfId>:<base64 salt16>:<base64 nonce12>:<base64 cipher>:<base64 tag16>
  // KAJI2 (stream cipher kustom + checksum, 100k PBKDF2) dan KAJI1
  // (single-SHA256, sangat lemah): DECRYPT-ONLY sebagai fallback
  // kompatibilitas — tidak pernah ditulis lagi.
  static const _encPrefix = 'KAJI2:';
  static const _encPrefixLegacy = 'KAJI1:';
  static const _encPrefixV3 = 'KAJI3:';

  /// Identitas KDF KAJI3 (agility masa depan: parser menolak ID asing).
  static const _kdfIdV3 = 'pbkdf2-sha256-100k';
  static const _pbkdf2IterationsV3 = 100000;

  static final _aesGcm = AesGcm.with256bits();
  static Pbkdf2 _kdfV3() =>
      Pbkdf2.hmacSha256(iterations: _pbkdf2IterationsV3, bits: 256);

  static bool isEncryptedBackup(String content) {
    final t = content.trimLeft();
    return t.startsWith(_encPrefixV3) ||
        t.startsWith(_encPrefix) ||
        t.startsWith(_encPrefixLegacy);
  }

  /// PBKDF2-HMAC-SHA256 standar (RFC 2898). [iterations] 100.000
  /// memperlambat brute-force offline, bukan membuatnya mustahil
  /// untuk PIN pendek — lihat catatan proteksi ringan di atas.
  /// Implementasi bersama di `pbkdf2.dart` (juga dipakai hash PIN v2).
  static List<int> _pbkdf2HmacSha256(
    List<int> password,
    List<int> salt,
    int iterations,
    int dkLen,
  ) =>
      pbkdf2HmacSha256(password, salt, iterations, dkLen);

  static const _pbkdf2Iterations = 100000;

  static List<int> _backupKey(String pin, List<int> salt) =>
      _pbkdf2HmacSha256(utf8.encode(pin), salt, _pbkdf2Iterations, 32);

  /// Kunci lama single-iteration (hanya untuk dekripsi fallback KAJI1).
  static List<int> _backupKeyLegacy(String pin) =>
      sha256.convert(utf8.encode('kaji-backup::$pin')).bytes;

  static List<int> _keystream(
    List<int> key,
    List<int> salt,
    List<int> nonce,
    int length,
  ) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      final h = sha256.convert([
        ...key,
        ...salt,
        ...nonce,
        (counter >> 24) & 0xFF,
        (counter >> 16) & 0xFF,
        (counter >> 8) & 0xFF,
        counter & 0xFF,
      ]).bytes;
      out.addAll(h);
      counter++;
    }
    return out.sublist(0, length);
  }

  /// Enkripsi KAJI3 (AES-256-GCM) dari JSON backup + PIN mentah user.
  /// Throw [ArgumentError] bila PIN kosong. Selalu via isolate di pemanggil
  /// ([encryptBackupAsync]) agar PBKDF2 tak menjank UI.
  static Future<String> encryptBackupV3(String plainJson, String pin) async {
    if (pin.isEmpty) throw ArgumentError('PIN kosong');
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256));
    final secretKey = await _kdfV3().deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    final box = await _aesGcm.encrypt(
      utf8.encode(plainJson),
      secretKey: secretKey,
      nonce: nonce,
    );
    return '$_encPrefixV3$_kdfIdV3:${base64.encode(salt)}:'
        '${base64.encode(box.nonce)}:'
        '${base64.encode(box.cipherText)}:'
        '${base64.encode(box.mac.bytes)}';
  }

  /// Dekripsi KAJI3; return null bila format/KDF salah, PIN salah,
  /// ciphertext/tag dimodifikasi, atau korup. Tag GCM memverifikasi
  /// SEBELUM plaintext dipakai (beda dari checksum-dalam-cipher KAJI2).
  static Future<String?> decryptBackupV3(String enc, String pin) async {
    try {
      final content = enc.trim();
      if (!content.startsWith(_encPrefixV3)) return null;
      final parts = content.substring(_encPrefixV3.length).split(':');
      if (parts.length != 5) return null;
      if (parts[0] != _kdfIdV3) return null; // KDF asing → fail closed.
      final salt = base64.decode(parts[1]);
      final nonce = base64.decode(parts[2]);
      final cipher = base64.decode(parts[3]);
      final tag = base64.decode(parts[4]);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          cipher.isEmpty ||
          tag.length != 16) {
        return null;
      }
      final secretKey = await _kdfV3().deriveKey(
        secretKey: SecretKey(utf8.encode(pin)),
        nonce: salt,
      );
      final clear = await _aesGcm.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
        secretKey: secretKey,
      );
      final plain = utf8.decode(clear, allowMalformed: false);
      // Pastikan isinya JSON object sebelum diteruskan ke import.
      if (jsonDecode(plain) is! Map<String, dynamic>) return null;
      return plain;
    } on Object catch (e) {
      // SecretBoxAuthenticationError (PIN salah / tamper), base64 rusak,
      // UTF-8 invalid → semuanya null (fail-closed). UI hanya terima null
      // tanpa sebab; detail hanya ke log ter-redaksi.
      AppLog.error('backup.decrypt_v3_failed', e);
      return null;
    }
  }

  /// Dekripsi LEGACY decrypt-only (R4): KAJI2/KAJI1 tidak pernah ditulis,
  /// sukses dekripsi mencatat peringatan migrasi ke KAJI3 via [AppLog].
  /// Dekripsi; return null bila format salah, PIN salah, atau korup.
  /// KAJI3 (AEAD) didukung di sini HANYA bila dipanggil dari isolate via
  /// [decryptBackupAsync] (dispatch prefix) — versi sinkron ini khusus
  /// fallback KAJI2 (PBKDF2) dan KAJI1 (single-SHA256 lawas), decrypt-only.
  static String? decryptBackup(String enc, String pin) {
    try {
      final content = enc.trim();
      if (content.startsWith(_encPrefixV3)) return null;
      final isNew = content.startsWith(_encPrefix);
      final isLegacy = content.startsWith(_encPrefixLegacy);
      if (!isNew && !isLegacy) return null;
      final prefix = isNew ? _encPrefix : _encPrefixLegacy;
      final parts = content.substring(prefix.length).split(':');
      if (parts.length != 3) return null;
      final salt = base64.decode(parts[0]);
      final nonce = base64.decode(parts[1]);
      final cipher = base64.decode(parts[2]);
      if (salt.length != 16 || nonce.length != 12 || cipher.isEmpty) {
        return null;
      }
      final key = isNew ? _backupKey(pin, salt) : _backupKeyLegacy(pin);
      final ks = _keystream(key, salt, nonce, cipher.length);
      final payload = List<int>.generate(
        cipher.length,
        (i) => cipher[i] ^ ks[i],
      );
      final text = utf8.decode(payload, allowMalformed: false);
      final sep = text.indexOf('::');
      if (sep <= 0) return null;
      final digest = text.substring(0, sep);
      final plain = text.substring(sep + 2);
      if (sha256.convert(utf8.encode(plain)).toString() != digest) {
        return null;
      }
      // Pastikan isinya JSON object sebelum diteruskan ke import.
      if (jsonDecode(plain) is! Map<String, dynamic>) return null;
      AppLog.event(
        'backup.legacy_decrypt',
        data: {'format': isNew ? 'KAJI2' : 'KAJI1'},
      );
      return plain;
    } on Object catch (e) {
      AppLog.error('backup.legacy_decrypt_failed', e);
      return null;
    }
  }

  /// Varian isolate: enkripsi KAJI3 (format tulis SATU-SATUNYA).
  /// PBKDF2 + AES-GCM tak menjank UI di HP low-end.
  static Future<String> encryptBackupAsync(String plainJson, String pin) =>
      compute(_encryptBackupV3Entry, [plainJson, pin]);

  /// Varian isolate dari dekripsi, dispatch otomatis by prefix:
  /// KAJI3 → AES-GCM, KAJI1/KAJI2 → fallback legacy (decrypt-only).
  static Future<String?> decryptBackupAsync(String enc, String pin) {
    if (enc.trimLeft().startsWith(_encPrefixV3)) {
      return compute(_decryptBackupV3Entry, [enc, pin]);
    }
    return compute(_decryptBackupEntry, [enc, pin]);
  }

  /// Ambil isi mentah file backup pilihan user (null bila batal/gagal).
  /// Dipakai alur import dengan dukungan enkripsi di Settings.
  /// Menerima file apa pun (`*.kaji.json`, `*.json`, tanpa ekstensi):
  /// filter ekstensi di sebagian file manager Android menyembunyikan
  /// `*.kaji.json`, jadi validasi dilakukan dari ISI (JSON valid atau
  /// prefix KAJI1:/KAJI2:/KAJI3:), bukan nama file.
  static Future<String?> pickRawContent() async {
    // File-picker adalah overlay sistem — tahan kunci layar selama jalan.
    return AppLockGuard.run(() async {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return null;
      try {
        // Baca sebagai bytes dulu: bisa cek ukuran sebelum decode
        // (tolak >25MB agar file raksasa tak bikin OOM).
        final bytes = file.path != null
            ? await File(file.path!).readAsBytes()
            : await file.readAsBytes();
        if (bytes.length > 25 * 1024 * 1024) return null;
        final text = utf8.decode(bytes, allowMalformed: false);
        if (text.trim().isEmpty) return null;
        return text;
      } on Object catch (e) {
        AppLog.error('backup.pick_read_failed', e);
        return null;
      }
    });
  }

  static Future<bool> pickAndImport() async {
    // Jalur kompatibel: hanya backup plaintext. Terenkripsi ditolak
    // (return false) — gunakan pickRawContent + decryptBackup untuk itu.
    final content = await pickRawContent();
    if (content == null) return false;
    if (isEncryptedBackup(content)) return false;
    return importFromJsonString(content);
  }
}

/// Entry isolate untuk [compute]: harus fungsi top-level.
Future<String> _encryptBackupV3Entry(List<String> args) =>
    BackupService.encryptBackupV3(args[0], args[1]);

/// Entry isolate untuk [compute]: harus fungsi top-level.
Future<String?> _decryptBackupV3Entry(List<String> args) =>
    BackupService.decryptBackupV3(args[0], args[1]);

/// Entry isolate untuk [compute]: harus fungsi top-level.
String? _decryptBackupEntry(List<String> args) =>
    BackupService.decryptBackup(args[0], args[1]);
