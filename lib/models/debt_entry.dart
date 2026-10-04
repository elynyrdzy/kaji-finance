import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/secure_db_service.dart';
import '../services/profile_service.dart';

/// Arah ledger hutang-piutang (IDR integer, offline-only).
///
/// - [payable]: saya berhutang ke [DebtEntry.counterparty]
///   (bayar hutang → transaksi expense dari dompet).
/// - [receivable]: [DebtEntry.counterparty] berhutang ke saya
///   (terima piutang → transaksi income ke dompet).
enum DebtDirection { payable, receivable }

/// Jenis catatan: hutang/piutang biasa, kasbon warung, arisan sederhana.
/// Kasbon & arisan memakai alur yang sama (cicilan parsial + jatuh tempo);
/// [kind] hanya memengaruhi label/kategori transaksi tertaut.
enum DebtKind { debt, kasbon, arisan }

/// Satu cicilan / pembayaran parsial per [DebtEntry].
class DebtPayment {
  const DebtPayment({
    required this.id,
    required this.debtId,
    required this.amount,
    required this.date,
    this.transactionId,
    this.note,
  });

  /// Rupiah utuh, selalu positif.
  final String id;
  final String debtId;
  final int amount;
  final DateTime date;

  /// ID transaksi ledger tertaut (expense/income). Null hanya untuk
  /// baris impor lama tanpa jejak ledger.
  final String? transactionId;
  final String? note;

  DebtPayment copyWith({int? amount, DateTime? date, String? note}) =>
      DebtPayment(
        id: id,
        debtId: debtId,
        amount: amount ?? this.amount,
        date: date ?? this.date,
        transactionId: transactionId,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'debtId': debtId,
        'amount': amount,
        'date': date.toIso8601String(),
        'transactionId': transactionId,
        'note': note,
      };

  factory DebtPayment.fromJson(Map<String, dynamic> j) => DebtPayment(
        id: '${j['id'] ?? ''}',
        debtId: '${j['debtId'] ?? ''}',
        amount: (j['amount'] as num).round(),
        date: DateTime.parse(j['date'] as String),
        transactionId: j['transactionId'] as String?,
        note: j['note'] as String?,
      );
}

/// Satu entry hutang/piutang/kasbon/arisan (mini-ledger).
///
/// - Nominal SELALU integer rupiah ([principal], [DebtPayment.amount]).
/// - Status lunas/belum diturunkan dari [remaining] (bukan flag tersimpan)
///   agar tak pernah divergen dari riwayat pembayaran.
/// - Kaitan ke ledger transaksi: pembayaran tercatat sebagai transaksi
///   expense/income bertag [debtTxTag]/[debtPrincipalTag] dengan
///   note berprefix `[debt:<id>]` (reuse tabel transaksi yang ada —
///   tanpa ubah schema DB; lihat TODO migrasi di bawah).
class DebtEntry {
  const DebtEntry({
    required this.id,
    required this.counterparty,
    required this.direction,
    required this.kind,
    required this.principal,
    required this.borrowedAt,
    this.dueAt,
    this.note,
    required this.createdAt,
    this.payments = const [],
  });

  final String id;

  /// Pihak lawan (nama orang / warung / kelompok arisan).
  final String counterparty;
  final DebtDirection direction;
  final DebtKind kind;

  /// Nominal pinjaman awal, rupiah utuh, selalu positif.
  final int principal;

  /// Tanggal pinjam & jatuh tempo (null = tanpa tenggat).
  final DateTime borrowedAt;
  final DateTime? dueAt;
  final String? note;
  final DateTime createdAt;
  final List<DebtPayment> payments;

  /// Total sudah dibayar (Σ cicilan).
  int get paidTotal => payments.fold(0, (s, p) => s + p.amount);

  /// Sisa = principal − terbayar (0 bila lunas/lebih-bayar, tak negatif).
  int get remaining {
    final r = principal - paidTotal;
    return r < 0 ? 0 : r;
  }

  bool get isSettled => paidTotal >= principal;

  bool isOverdue(DateTime now) {
    if (isSettled || dueAt == null) return false;
    final d = DateTime(dueAt!.year, dueAt!.month, dueAt!.day);
    final n = DateTime(now.year, now.month, now.day);
    return n.isAfter(d);
  }

  /// Hari sampai jatuh tempo (negatif = lewat). Null bila tanpa tenggat.
  int? daysUntilDue(DateTime now) {
    if (dueAt == null) return null;
    final d = DateTime(dueAt!.year, dueAt!.month, dueAt!.day);
    final n = DateTime(now.year, now.month, now.day);
    return d.difference(n).inDays;
  }

  DebtEntry copyWith({
    String? counterparty,
    DebtDirection? direction,
    DebtKind? kind,
    int? principal,
    DateTime? borrowedAt,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? note,
    bool clearNote = false,
    List<DebtPayment>? payments,
  }) =>
      DebtEntry(
        id: id,
        counterparty: counterparty ?? this.counterparty,
        direction: direction ?? this.direction,
        kind: kind ?? this.kind,
        principal: principal ?? this.principal,
        borrowedAt: borrowedAt ?? this.borrowedAt,
        dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
        note: clearNote ? null : (note ?? this.note),
        createdAt: createdAt,
        payments: payments ?? this.payments,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'counterparty': counterparty,
        'direction': direction.index,
        'kind': kind.index,
        'principal': principal,
        'borrowedAt': borrowedAt.toIso8601String(),
        'dueAt': dueAt?.toIso8601String(),
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'payments': payments.map((p) => p.toJson()).toList(),
      };

  factory DebtEntry.fromJson(Map<String, dynamic> j) {
    final rawDir = (j['direction'] as num?)?.toInt() ?? 0;
    final rawKind = (j['kind'] as num?)?.toInt() ?? 0;
    if (rawDir < 0 || rawDir >= DebtDirection.values.length) {
      throw FormatException('direction tidak dikenal: $rawDir');
    }
    if (rawKind < 0 || rawKind >= DebtKind.values.length) {
      throw FormatException('kind tidak dikenal: $rawKind');
    }
    final pays = <DebtPayment>[];
    final rawPays = j['payments'];
    if (rawPays is List) {
      for (final e in rawPays) {
        try {
          if (e is Map<String, dynamic>) {
            pays.add(DebtPayment.fromJson(e));
          } else if (e is Map) {
            pays.add(DebtPayment.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (_) {
          continue; // baris cicilan korup di-skip per-baris.
        }
      }
    }
    return DebtEntry(
      id: '${j['id'] ?? ''}',
      counterparty: '${j['counterparty'] ?? ''}',
      direction: DebtDirection.values[rawDir],
      kind: DebtKind.values[rawKind],
      principal: (j['principal'] as num).round(),
      borrowedAt: DateTime.parse(j['borrowedAt'] as String),
      dueAt: j['dueAt'] == null ? null : DateTime.parse(j['dueAt'] as String),
      note: j['note'] as String?,
      createdAt: DateTime.parse(j['createdAt'] as String),
      payments: pays,
    );
  }
}

/// Tag transaksi ledger tertaut hutang-piutang (reuse tabel transaksi).
///
/// - [debtPrincipalTag]: pencairan awal (payable→income, receivable→expense).
/// - [debtTxTag]: cicilan/pelunasan (payable→expense, receivable→income).
/// - ID entry disimpan sebagai prefix note `[debt:<id>]` (lihat
///   [debtNotePrefix]/[debtIdOfNote]) agar query per-entry bisa tanpa
///   kolom baru di tabel transaksi.
class DebtLedgerLink {
  DebtLedgerLink._();
  static const principalTag = 'debt_principal';
  static const paymentTag = 'debt_payment';

  static String notePrefix(String debtId) => '[debt:$debtId]';

  static String? debtIdOfNote(String? note) {
    if (note == null) return null;
    final m = RegExp(r'\[debt:([^\]]+)\]').firstMatch(note);
    return m?.group(1);
  }

  static bool isDebtTag(String? tag) =>
      tag == principalTag || tag == paymentTag;
}

/// Kontrak penyimpanan mini-ledger (ter-scope profil).
///
/// Implementasi saat ini: SharedPreferences JSON (tanpa migrasi schema DB).
/// Lihat [PrefsDebtStore] + [migrateToSecureDb].
abstract class DebtStore {
  Future<List<DebtEntry>> load();
  Future<void> save(List<DebtEntry> entries);
  Future<void> clear();
}

/// Store SharedPreferences ter-scope profil.
///
/// - Kunci: `ProfileService.scoped('kaji_debts')` (isolasi antar-profil).
/// - SATU instance prefs di-cache statis ([_cached]) — tidak ada
///   `SharedPreferences.getInstance()` berulang per operasi.
class PrefsDebtStore implements DebtStore {
  PrefsDebtStore();

  static String get key => ProfileService.scoped('kaji_debts');

  static SharedPreferences? _cached;

  /// Ambil instance tunggal (di-cache). Satu-satunya titik getInstance
  /// untuk seluruh fitur hutang — hindari duplikasi pemanggilan.
  static Future<SharedPreferences> prefs() async =>
      _cached ??= await SharedPreferences.getInstance();

  /// Dipakai test untuk isolasi antar-kasus (mock prefs di-reset).
  static void resetCacheForTest() => _cached = null;

  @override
  Future<List<DebtEntry>> load() async {
    try {
      final p = await prefs();
      final raw = p.getString(key);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final out = <DebtEntry>[];
      for (final e in list) {
        try {
          if (e is Map<String, dynamic>) {
            out.add(DebtEntry.fromJson(e));
          } else if (e is Map) {
            out.add(DebtEntry.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (_) {
          continue; // baris korup di-skip, entry lain tetap terbaca.
        }
      }
      return out;
    } catch (e) {
      SecureDbService.noteError('debts_load: $e');
      return [];
    }
  }

  @override
  Future<void> save(List<DebtEntry> entries) async {
    try {
      final p = await prefs();
      await p.setString(
        key,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      SecureDbService.noteError('debts_save: $e');
      rethrow;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final p = await prefs();
      await p.remove(key);
    } catch (e) {
      SecureDbService.noteError('debts_clear: $e');
    }
  }
}

// TODO(debt-migration): pindah mini-ledger ke tabel SQLite terenkripsi
// (SecureDbService, bump schema version + onUpgrade) saat diputuskan —
// hook migrasi sekali-jalan prefs→DB di sini agar call-site tak berubah:
//
//   Future<void> migrateToSecureDb() async {
//     final entries = await PrefsDebtStore().load();
//     if (entries.isEmpty) return;
//     await SecureDbService.transaction((db) async {
//       for (final e in entries) {
//         await db.upsert('debts', e.toJson());
//       }
//     }, debugLabel: 'debtsMigrate');
//     await PrefsDebtStore().clear();
//   }
//
// Sampai hook itu aktif, ledger pembayaran tetap memakai tabel transaksi
// yang ada via [DebtLedgerLink] (kind:debt implisit lewat tag+note),
// sehingga TIDAK ADA perubahan schema/migrasi DB pada fase ini.
