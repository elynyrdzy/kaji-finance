import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/savings_goal_model.dart';
import '../models/transaction_model.dart';
import '../models/wallet_model.dart';
import '../utils/app_icons.dart';
import 'backup_service.dart';

/// Hasil tahap MEMORI: file `.json` sudah dibaca ke RAM sebagai daftar
/// transaksi tervalidasi + hitungan baris rusak. Belum menyentuh database.
///
/// Alur impor resmi (3 tahap):
/// 1. MEMORI — file `.json` diparse ke `TxImportStaging` (murni di RAM,
///    tidak disimpan plaintext ke mana pun).
/// 2. VALIDASI — tiap baris dinormalisasi toleran ([_parseOne]); yang
///    rusak dihitung di [invalid] dan di-skip, tidak menggugurkan semua.
/// 3. ENKRIPSI + SQL — [FinanceProvider.importTransactions] menulis daftar
///    [valid] ke SQLite terenkripsi (SQLCipher AES-256) via
///    [SecureDbService], lalu menerapkan delta dompet/anggaran.
///
/// Format `.json` yang diterima (terdeteksi otomatis):
/// - Backup penuh Kaji: `{"kaji_tx": "[{...}, ...]", ...}`
///   (nilai `kaji_tx` boleh string JSON-encoded maupun list langsung).
/// - `{"transactions": [...]}` / `{"data": [...]}`.
/// - List murni: `[{...}, {...}]`.
/// - Satu objek: `{...}` (satu transaksi).
class TxImportStaging {
  const TxImportStaging({
    required this.valid,
    required this.invalid,
    this.goals = const [],
    this.wallets = const [],
  });

  /// Transaksi siap tulis ke SQL (sudah tervalidasi, di RAM saja).
  final List<TransactionModel> valid;

  /// Jumlah baris yang rusak dan di-skip.
  final int invalid;

  /// Target tabungan + dompet bawaan file (format envelope Backup
  /// Transaksi). Best-effort: baris rusak di-skip diam-diam.
  final List<SavingsGoalModel> goals;
  final List<WalletModel> wallets;

  int get total => valid.length + invalid;
  bool get isEmpty => valid.isEmpty;

  int get incomeTotal => valid
      .where((t) => t.type == TransactionType.income)
      .fold(0, (s, t) => s + t.amount);

  int get expenseTotal => valid
      .where((t) => t.type == TransactionType.expense)
      .fold(0, (s, t) => s + t.amount);
}

/// Parser tahap MEMORI untuk impor transaksi dari file `.json`.
///
/// Murni fungsi sinkron tanpa I/O dan tanpa database — aman di-unit-test.
class TransactionImportService {
  TransactionImportService._();

  static const _uuid = Uuid();

  /// Ambil isi mentah file pilihan user (null bila batal/gagal).
  /// Mendelegasikan ke [BackupService.pickRawContent] agar batas 25MB
  /// + tahan auto-lock tetap satu pintu.
  static Future<String?> pickRawJson() => BackupService.pickRawContent();

  /// Parse [raw] menjadi staging memori. Tidak pernah throw:
  /// konten bukan-JSON / bentuk tak dikenal → staging kosong dengan
  /// [TxImportStaging.invalid] = 1 bila ada konten tapi tak terbaca.
  static TxImportStaging parseStaging(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const TxImportStaging(valid: [], invalid: 1);
    }
    final items = _extractItems(decoded);
    if (items == null) {
      return const TxImportStaging(valid: [], invalid: 1);
    }
    final valid = <TransactionModel>[];
    var invalid = 0;
    for (final item in items) {
      try {
        if (item is! Map) {
          invalid++;
          continue;
        }
        valid.add(_parseOne(Map<String, dynamic>.from(item)));
      } catch (_) {
        invalid++;
      }
    }
    // Envelope Backup Transaksi juga membawa target tabungan + dompet
    // (kunci top-level `goals`/`wallets`) agar tabungan ikut terbackup
    // dan ter-import — bukan cuma transaksinya.
    final goals = _extractModels(
      decoded,
      'goals',
      (m) => SavingsGoalModel.fromJson(m),
    );
    final wallets = _extractModels(
      decoded,
      'wallets',
      (m) => WalletModel.fromJson(m),
    );
    return TxImportStaging(
      valid: valid,
      invalid: invalid,
      goals: goals,
      wallets: wallets,
    );
  }

  /// Ambil daftar model opsional dari kunci top-level ([key]) bila
  /// berupa list. Baris rusak di-skip diam-diam (best-effort).
  static List<T> _extractModels<T>(
    dynamic decoded,
    String key,
    T Function(Map<String, dynamic>) parse,
  ) {
    try {
      if (decoded is! Map<String, dynamic>) return const [];
      final v = decoded[key];
      if (v is! List) return const [];
      final out = <T>[];
      for (final item in v) {
        try {
          if (item is Map) {
            out.add(parse(Map<String, dynamic>.from(item)));
          }
        } catch (_) {
          // best-effort: baris rusak dilewati (terdokumentasi di doc-method ini).
        }
      }
      return out;
    } catch (_) {
      // best-effort: envelope tak dikenal → daftar kosong (pemanggil menilai).
      return const [];
    }
  }

  /// Keluarkan daftar item transaksi dari berbagai bentuk JSON.
  /// Return null bila bentuk tidak dikenal sama sekali.
  static List<dynamic>? _extractItems(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map<String, dynamic>) {
      // Backup penuh Kaji — `kaji_tx` string JSON-encoded (format backup)
      // atau list langsung (toleran untuk file rakitan tangan).
      if (decoded.containsKey('kaji_tx')) {
        final v = decoded['kaji_tx'];
        if (v is String) {
          try {
            final inner = jsonDecode(v);
            if (inner is List) return inner;
          } catch (_) {
            // best-effort: string kaji_tx korup → daftar kosong (pemanggil menilai).
          }
          return const [];
        }
        if (v is List) return v;
        return const [];
      }
      for (final key in ['transactions', 'data']) {
        final v = decoded[key];
        if (v is List) return v;
      }
      // Satu objek transaksi langsung.
      if (_looksLikeTransaction(decoded)) return [decoded];
      return const [];
    }
    return null;
  }

  static bool _looksLikeTransaction(Map<String, dynamic> m) =>
      m.containsKey('amount') ||
      m.containsKey('title') ||
      m.containsKey('nominal');

  /// Normalisasi toleran satu baris JSON → [TransactionModel].
  /// Throw bila field inti (nominal/tipe/tanggal) tak bisa dipulihkan.
  static TransactionModel _parseOne(Map<String, dynamic> j) {
    final id = j['id'] is String && (j['id'] as String).isNotEmpty
        ? j['id'] as String
        : _uuid.v4();
    final title = _stringOf(
        j,
        [
          'title',
          'name',
          'merchant',
          'keterangan',
        ],
        fallback: 'Transaksi impor');
    final category = _stringOf(j, ['category', 'kategori'], fallback: 'Other');
    final account = _stringOf(
        j,
        [
          'account',
          'wallet',
          'dompet',
          'akun',
        ],
        fallback: 'Dompet Utama');
    final amount = _parseAmount(j['amount'] ?? j['nominal']);
    final type = _parseType(j['type'] ?? j['tipe']);
    final date = _parseDate(j['date'] ?? j['tanggal'] ?? j['createdAt']);
    final icon = _parseIcon(j['icon']);
    final tag = j['tag'] is String ? j['tag'] as String : null;
    final note = _stringOrNull(j['note'] ?? j['catatan']);

    String? linkedGoalId;
    final lg = j['linkedGoalId'];
    if (lg is String && lg.isNotEmpty) linkedGoalId = lg;

    // ID dompet ditulis ulang oleh provider dari nama akun
    // ([FinanceProvider.importTransactions]) agar selalu konsisten
    // dengan dompet yang ada di perangkat ini.
    return TransactionModel(
      id: id,
      title: title,
      category: category,
      account: account,
      amount: amount,
      type: type,
      date: date,
      icon: icon,
      tag: tag,
      note: note,
      linkedGoalId: linkedGoalId,
    );
  }

  static String _stringOf(
    Map<String, dynamic> j,
    List<String> keys, {
    required String fallback,
  }) {
    for (final k in keys) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return fallback;
  }

  static String? _stringOrNull(dynamic v) =>
      v is String && v.trim().isNotEmpty ? v : null;

  /// Terima angka maupun string ("50000", "Rp 50.000", "50.000,00").
  /// Return rupiah utuh (Phase 4): pecahan dibulatkan tunggal di sini,
  /// tidak ada debu yang lolos ke ledger.
  static int _parseAmount(dynamic v) {
    double? out;
    if (v is num) {
      out = v.toDouble();
    } else if (v is String) {
      var s = v.trim().replaceAll(RegExp(r'[^0-9,.\-]'), '');
      if (s.isEmpty) throw const FormatException('amount kosong');
      // Format Indonesia: "50.000,00" → "50000.00".
      if (s.contains('.') && s.contains(',')) {
        s = s.replaceAll('.', '').replaceAll(',', '.');
      } else if (s.contains(',')) {
        s = s.replaceAll(',', '.');
      }
      out = double.tryParse(s);
    }
    if (out == null || !out.isFinite) {
      throw const FormatException('amount tidak valid');
    }
    final rounded = out.round();
    if (rounded <= 0) throw const FormatException('amount tidak valid');
    return rounded;
  }

  /// Terima index (0/1/2/3), nama Inggris maupun Indonesia.
  static TransactionType _parseType(dynamic v) {
    if (v is int && v >= 0 && v < TransactionType.values.length) {
      return TransactionType.values[v];
    }
    if (v is String) {
      final s = v.trim().toLowerCase();
      switch (s) {
        case 'income':
        case 'pemasukan':
        case 'masuk':
        case 'in':
        case '0':
          return TransactionType.income;
        case 'expense':
        case 'pengeluaran':
        case 'belanja':
        case 'keluar':
        case 'out':
        case '1':
          return TransactionType.expense;
        case 'transfer':
        case '2':
          return TransactionType.transfer;
        case 'adjustment':
        case 'penyesuaian':
        case 'koreksi':
        case '3':
          return TransactionType.adjustment;
      }
    }
    throw const FormatException('type tidak valid');
  }

  static DateTime _parseDate(dynamic v) {
    if (v == null) return DateTime.now();
    if (v is int) {
      // Deteksi detik vs milidetik dari besarnya angka.
      final ms = v < 10000000000 ? v * 1000 : v;
      try {
        return DateTime.fromMillisecondsSinceEpoch(ms);
      } catch (_) {
        throw const FormatException('date tidak valid');
      }
    }
    if (v is String && v.trim().isNotEmpty) {
      try {
        return DateTime.parse(v.trim());
      } catch (_) {
        throw const FormatException('date tidak valid');
      }
    }
    throw const FormatException('date tidak valid');
  }

  static IconData _parseIcon(dynamic v) {
    if (v is int) return AppIcons.fromCodePoint(v);
    if (v is String) {
      final code = int.tryParse(v);
      if (code != null) return AppIcons.fromCodePoint(code);
    }
    return Icons.receipt_long;
  }

  /// Parse CSV ekspor aplikasi (`id,title,category,account,amount,type,
  /// date,tag,note` — lihat FinanceTransactions.exportCsv) menjadi staging
  /// memori. Tipe boleh nama (`income`) maupun index (`0`). Kolom ikon
  /// tak ada di CSV → ikon default. ID asli dipertahankan sehingga
  /// impor-ulang file yang sama terdeteksi duplikat, bukan ganda.
  static TxImportStaging parseTransactionsCsv(String raw) {
    final rows = _splitCsvRows(raw);
    if (rows.isEmpty) {
      return const TxImportStaging(valid: [], invalid: 1);
    }
    const want = [
      'id',
      'title',
      'category',
      'account',
      'amount',
      'type',
      'date',
      'tag',
      'note',
    ];
    final head = rows.first.map((c) => c.trim().toLowerCase()).toList();
    if (head.length != want.length) {
      return const TxImportStaging(valid: [], invalid: 1);
    }
    for (var i = 0; i < want.length; i++) {
      if (head[i] != want[i]) {
        return const TxImportStaging(valid: [], invalid: 1);
      }
    }
    final valid = <TransactionModel>[];
    var invalid = 0;
    for (var r = 1; r < rows.length; r++) {
      try {
        final cells = rows[r];
        if (cells.length != want.length) {
          invalid++;
          continue;
        }
        final m = <String, dynamic>{
          for (var i = 0; i < want.length; i++) want[i]: cells[i],
        };
        // Sel kosong = null (tag/note opsional).
        for (final k in ['tag', 'note']) {
          if ((m[k] as String).trim().isEmpty) m[k] = null;
        }
        valid.add(_parseOne(m));
      } catch (_) {
        invalid++;
      }
    }
    return TxImportStaging(valid: valid, invalid: invalid);
  }

  /// Pecah teks CSV per RFC 4180 (kutip ganda + koma/baris-baru di sel).
  /// Baris kosong diabaikan.
  static List<List<String>> _splitCsvRows(String raw) {
    final rows = <List<String>>[];
    var cur = <String>[];
    var buf = StringBuffer();
    var inQuotes = false;
    var touched = false;
    void pushCell() {
      cur.add(buf.toString());
      buf = StringBuffer();
      touched = true;
    }

    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < raw.length && raw[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
        touched = true;
      } else if (c == ',') {
        pushCell();
      } else if (c == '\n') {
        pushCell();
        rows.add(cur);
        cur = <String>[];
        touched = false;
      } else if (c == '\r') {
        // Diabaikan (pasangan \r\n ditangani \n).
      } else {
        buf.write(c);
        touched = true;
      }
    }
    if (touched) {
      pushCell();
      rows.add(cur);
    }
    return rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  }
}
