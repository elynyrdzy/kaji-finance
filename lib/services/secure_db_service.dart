import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/profile_model.dart';
import 'app_log.dart';
import 'domain_errors.dart';

/// Nama tabel SQLite terenkripsi (SQLCipher) untuk data finansial inti.
/// Kolom 1:1 dengan `Model.toJson` agar migrasi prefs→DB dan ekspor backup
/// tanpa konversi bentuk. Pengaturan ringan tetap di SharedPreferences.
class SecureDbTables {
  SecureDbTables._();
  static const tx = 'transactions';
  static const wallets = 'wallets';
  static const budgets = 'budgets';
  static const goals = 'goals';
  static const categories = 'categories';

  /// Jejak audit lokal (P5). SENGAJA di luar [all]/backup: trail perangkat,
  /// capped 500 baris, prune amortisasi.
  static const audit = 'audit_log';
  static const all = [tx, wallets, budgets, goals, categories];
}

/// Peta kunci prefs lawas → tabel. Dipakai migrasi sekali jalan +
/// ekspor/impor backup (format backup TIDAK berubah).
const Map<String, String> legacyKeyToTable = {
  'kaji_tx': SecureDbTables.tx,
  'kaji_bd': SecureDbTables.budgets,
  'kaji_wl': SecureDbTables.wallets,
  'kaji_goals': SecureDbTables.goals,
  'kaji_cat': SecureDbTables.categories,
};

/// Kolom yang dikenal per tabel — baris korup (tanpa `id` / kolom asing)
/// di-skip agar satu baris rusak tak menggugurkan seluruh tabel.
const Map<String, Set<String>> _tableColumns = {
  SecureDbTables.tx: {
    'id',
    'title',
    'category',
    'account',
    'amount',
    'type',
    'date',
    'icon',
    'tag',
    'note',
    'linkedGoalId',
    'fromWalletId',
    'toWalletId',
  },
  SecureDbTables.wallets: {
    'id',
    'name',
    'number',
    'icon',
    'balance',
    // P3: opening balance ledger. Baris lama tanpa kolom ini tetap
    // terbaca (fallback di WalletModel.fromJson + backfill sekali jalan).
    'initial_balance',
    'color',
  },
  // Kolom `budget_limit` (BUKAN `limit`): LIMIT reserved di SQLite —
  // CREATE TABLE dengan kolom `limit` gagal syntax error dan database
  // tak pernah terbentuk (seluruh data hilang tiap restart).
  SecureDbTables.budgets: {'id', 'name', 'icon', 'spent', 'budget_limit'},
  SecureDbTables.goals: {
    'id',
    'name',
    'target',
    'saved',
    'icon',
    'color',
    'deadline',
    'createdAt',
  },
  SecureDbTables.categories: {'id', 'name', 'icon'},
  // P5: jejak audit (ditulis dalam transaksi yang sama dengan mutasi).
  SecureDbTables.audit: {
    'id',
    'timestamp',
    'action',
    'entity_type',
    'entity_id',
    'metadata',
  },
};

/// Executor transaksional minimal untuk mutasi multi-tabel atomik.
///
/// Dipakai di dalam [SecureDbService.transaction]. Implementasi SQL memakai
/// sqflite `Transaction`; implementasi memori memakai snapshot + commit /
/// rollback sehingga semantiknya sama di test.
abstract class DbTxn {
  Future<void> replace(String table, List<Map<String, Object?>> rows);
  Future<void> upsert(String table, Map<String, Object?> row);
  Future<void> delete(String table, String id);
  Future<List<Map<String, Object?>>> load(String table);
}

/// Kontrak backend entitas — produksi (SQLCipher) & test (memori).
abstract class _EntityBackend {
  Future<List<Map<String, Object?>>> load(String table);
  Future<void> replace(String table, List<Map<String, Object?>> rows);
  Future<void> upsert(String table, Map<String, Object?> row);
  Future<void> delete(String table, String id);
  Future<T> runInTransaction<T>(Future<T> Function(DbTxn txn) action);
  Future<void> close();
  Future<List<Map<String, Object?>>> queryTx({
    DateTime? from,
    DateTime? to,
    String? category,
    int? type,
    int? limit,
    int? offset,
  });
  Future<Map<String, int>> sumExpenseByCategory({
    required int type,
    required DateTime month,
  });
  Future<bool> get isEmpty;

  /// True bila [table] tak punya satu baris pun. Terpisah dari [isEmpty]
  /// karena migrasi prefs lawas butuh keputusan PER TABEL, dan [load] akan
  /// mendekripsi seluruh isi tabel (transaksi bisa ribuan baris) hanya
  /// untuk memeriksa ulang.
  Future<bool> tableIsEmpty(String table);
  Future<void> clear();
}

List<Map<String, Object?>> _sanitize(String table, List<dynamic> items) {
  final cols = _tableColumns[table]!;
  final out = <Map<String, Object?>>[];
  for (final item in items) {
    try {
      if (item is! Map) continue;
      final clean = <String, Object?>{};
      for (final k in cols) {
        if (item.containsKey(k)) clean[k] = item[k];
      }
      // Kompatibel backup lama: kunci `limit` dipetakan ke `budget_limit`.
      if (table == SecureDbTables.budgets &&
          !clean.containsKey('budget_limit') &&
          item.containsKey('limit')) {
        clean['budget_limit'] = item['limit'];
      }
      if (!clean.containsKey('id')) continue;
      out.add(clean);
    } catch (_) {
      continue;
    }
  }
  return out;
}

/// Executor di atas sqflite `Transaction` — semua tulis di sini partisipan
/// satu transaksi SQLite (COMMIT bila [action] sukses, ROLLBACK bila throw).
class _SqlTxn implements DbTxn {
  _SqlTxn(this._txn);
  final DatabaseExecutor _txn;

  @override
  Future<void> replace(String table, List<Map<String, Object?>> rows) async {
    await _txn.delete(table);
    for (final r in rows) {
      await _txn.insert(table, r);
    }
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row) async {
    final clean = _sanitize(table, [row]);
    if (clean.isEmpty) return;
    await _txn.insert(
      table,
      clean.first,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String table, String id) async {
    await _txn.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<Map<String, Object?>>> load(String table) async {
    return _txn.query(table);
  }
}

/// Backend produksi: SQLite terenkripsi SQLCipher (AES-256).
/// Kunci 32-byte acak dibuat sekali & disimpan di Keystore/Keychain
/// via flutter_secure_storage — tidak tergantung PIN (reset PIN aman).
class _SqlCipherBackend implements _EntityBackend {
  _SqlCipherBackend(this._profileId);
  final String _profileId;

  String get _keyStorageKey => scopedProfileKey(_profileId, 'kaji_db_key');
  String get _fileName => profileDbFileName(_profileId);

  Database? _db;

  @override
  Future<void> close() async {
    try {
      await _db?.close();
    } catch (_) {
      // best-effort: tutup DB gagal → handle dibuang, koneksi baru dibuka saat perlu.
    }
    _db = null;
  }

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    const storage = FlutterSecureStorage();
    String? password;
    try {
      password = await storage.read(key: _keyStorageKey);
    } catch (e) {
      // Keystore/Keychain bermasalah = database tak bisa dibuka.
      // Catat + lempar (jangan buat kunci baru: kunci baru membuat
      // database lama yatim permanen). Lihat SecureDbService.lastError
      // dan SecureDbService.openFailed.
      SecureDbService.noteOpenError('db_key_read: $e', e);
      rethrow;
    }
    if (password == null || password.isEmpty) {
      try {
        final rnd = Random.secure();
        password = base64Url.encode(
          List<int>.generate(32, (_) => rnd.nextInt(256)),
        );
        await storage.write(key: _keyStorageKey, value: password);
      } catch (e) {
        SecureDbService.noteOpenError('db_key_write: $e', e);
        rethrow;
      }
    }
    final dir = await getDatabasesPath();
    const createIdx = [
      'CREATE INDEX IF NOT EXISTS idx_tx_date ON ${SecureDbTables.tx}(date)',
      'CREATE INDEX IF NOT EXISTS idx_tx_category ON ${SecureDbTables.tx}(category)',
      'CREATE INDEX IF NOT EXISTS idx_tx_type ON ${SecureDbTables.tx}(type)',
      'CREATE INDEX IF NOT EXISTS idx_tx_account ON ${SecureDbTables.tx}(account)',
      'CREATE INDEX IF NOT EXISTS idx_bd_name ON ${SecureDbTables.budgets}(name)',
      'CREATE INDEX IF NOT EXISTS idx_wl_name ON ${SecureDbTables.wallets}(name)',
    ];
    Database db;
    try {
      db = await openDatabase(
        '$dir/$_fileName',
        password: password,
        version: 5,
        onCreate: (db, version) async {
          // IF NOT EXISTS: aman dari file setengah-jadi bila pembuatan
          // sebelumnya pernah gagal di tengah jalan.
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.tx}('
            'id TEXT PRIMARY KEY, title TEXT NOT NULL, category TEXT NOT NULL, '
            'account TEXT NOT NULL, amount INTEGER NOT NULL, type INTEGER NOT NULL, '
            'date TEXT NOT NULL, icon INTEGER NOT NULL, tag TEXT, note TEXT, '
            'linkedGoalId TEXT, fromWalletId TEXT, toWalletId TEXT)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.wallets}('
            'id TEXT PRIMARY KEY, name TEXT NOT NULL, number TEXT NOT NULL, '
            'icon INTEGER NOT NULL, balance INTEGER NOT NULL, '
            // P3: opening balance; DEFAULT 0 agar baris lama tetap valid,
            // nilai historis yang benar diisi backfill sekali jalan.
            'initial_balance INTEGER NOT NULL DEFAULT 0, '
            'color INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.budgets}('
            'id TEXT PRIMARY KEY, name TEXT NOT NULL, icon INTEGER NOT NULL, '
            'spent INTEGER NOT NULL, budget_limit INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.goals}('
            'id TEXT PRIMARY KEY, name TEXT NOT NULL, target INTEGER NOT NULL, '
            'saved INTEGER NOT NULL, icon INTEGER NOT NULL, color INTEGER NOT NULL, '
            'deadline TEXT, createdAt TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.categories}('
            'id TEXT PRIMARY KEY, name TEXT NOT NULL, icon INTEGER NOT NULL)',
          );
          // P5: jejak audit lokal, capped di layer aplikasi.
          await db.execute(
            'CREATE TABLE IF NOT EXISTS ${SecureDbTables.audit}('
            'id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, '
            'action TEXT NOT NULL, entity_type TEXT NOT NULL, '
            'entity_id TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT \'{}\')',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_audit_time ON ${SecureDbTables.audit}(timestamp)',
          );
          for (final idx in createIdx) {
            await db.execute(idx);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // v1 → v2: indeks query periode (idempoten, aman dijalankan ulang).
          for (final idx in createIdx) {
            await db.execute(idx);
          }
          // v2 → v3 (P3): kolom opening balance. Idempoten via cek PRAGMA
          // dulu — ALTER hanya dijalankan bila kolom benar-benar belum ada.
          // Kegagalan ASLI (korup, I/O, skema tak terduga) melempar
          // MigrationException (fail-closed): skema setengah-jadi TIDAK
          // boleh dianggap sukses. Sebelumnya semua error ditelan dengan
          // asumsi "mungkin kolom sudah ada".
          if (oldVersion < 3) {
            final cols = await db.rawQuery(
              'PRAGMA table_info(${SecureDbTables.wallets})',
            );
            final hasCol = cols.any(
              (c) => (c['name'] as String?) == 'initial_balance',
            );
            if (!hasCol) {
              try {
                await db.execute(
                  'ALTER TABLE ${SecureDbTables.wallets} '
                  'ADD COLUMN initial_balance REAL NOT NULL DEFAULT 0',
                );
              } catch (e) {
                throw MigrationException(
                  'Migrasi database v3 gagal: kolom opening balance tidak '
                  'bisa ditambahkan. Data Anda tidak diubah.',
                  details: '$e',
                );
              }
            }
          }
          // v3 → v4 (P4): kanonik integer — bulatkan nilai pecahan legacy
          // (debu kurs asing) ke rupiah utuh, in-place. ROUND SQLite =
          // half-away-from-zero, sama dengan aturan Money.roundBase.
          // Idempoten (nilai bulat tak berubah bila dijalankan ulang).
          // Afinitas kolom lama (REAL) sengaja TIDAK diubah: SQLite typing
          // dinamis, nilai integer valid di kolom REAL; instalasi baru
          // memakai INTEGER via onCreate di atas.
          if (oldVersion < 4) {
            const moneyCols = <String, List<String>>{
              SecureDbTables.tx: ['amount'],
              SecureDbTables.wallets: ['balance', 'initial_balance'],
              SecureDbTables.budgets: ['spent', 'budget_limit'],
              SecureDbTables.goals: ['target', 'saved'],
            };
            for (final entry in moneyCols.entries) {
              for (final col in entry.value) {
                try {
                  await db.execute(
                    'UPDATE ${entry.key} SET $col = CAST(ROUND($col) AS INTEGER)',
                  );
                } catch (e) {
                  SecureDbService.noteError(
                    'db_migrate_v4(${entry.key}.$col): $e',
                  );
                }
              }
            }
          }
          // v4 → v5 (P5): tabel jejak audit + indeks waktu. IF NOT EXISTS
          // agar idempoten bila dijalankan ulang.
          if (oldVersion < 5) {
            try {
              await db.execute(
                'CREATE TABLE IF NOT EXISTS ${SecureDbTables.audit}('
                'id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, '
                'action TEXT NOT NULL, entity_type TEXT NOT NULL, '
                'entity_id TEXT NOT NULL, metadata TEXT NOT NULL DEFAULT \'{}\')',
              );
              await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_audit_time ON ${SecureDbTables.audit}(timestamp)',
              );
            } catch (e) {
              SecureDbService.noteError('db_migrate_v5: $e');
            }
          }
        },
      );
    } catch (e) {
      // Mis. native SQLCipher gagal dimuat, file korup/kunci salah, atau
      // migrasi skema gagal (fail-closed). Catat agar terlihat di log +
      // layar Info Debug (lastError) DAN tandai [openFailed] supaya
      // pemanggil bisa membedakannya dari "memang belum ada data" —
      // tanpa itu, load yang gagal sunyi membuat aplikasi tampil kosong
      // persis seperti akun baru.
      SecureDbService.noteOpenError('db_open: $e', e);
      rethrow;
    }
    _db = db;
    // Buka berhasil (bisa jadi setelah I/O transient pulih) → kegagalan
    // lama tak lagi menggambarkan keadaan DB.
    SecureDbService._clearOpenFailure();
    return db;
  }

  @override
  Future<List<Map<String, Object?>>> load(String table) async {
    try {
      final db = await _open();
      return db.query(table);
    } catch (e) {
      SecureDbService.noteError('db_load($table): $e');
      rethrow;
    }
  }

  @override
  Future<void> replace(String table, List<Map<String, Object?>> rows) async {
    try {
      final db = await _open();
      final batch = db.batch();
      batch.delete(table);
      for (final r in rows) {
        batch.insert(table, r);
      }
      await batch.commit(noResult: true);
    } catch (e) {
      SecureDbService.noteError('db_replace($table,${rows.length}): $e');
      rethrow;
    }
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row) async {
    final clean = _sanitize(table, [row]);
    if (clean.isEmpty) return;
    try {
      final db = await _open();
      await db.insert(
        table,
        clean.first,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      SecureDbService.noteError('db_upsert($table): $e');
      rethrow;
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    try {
      final db = await _open();
      await db.delete(table, where: 'id = ?', whereArgs: [id]);
    } catch (e) {
      SecureDbService.noteError('db_delete($table): $e');
      rethrow;
    }
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function(DbTxn txn) action) async {
    final db = await _open();
    return db.transaction<T>((txn) async => action(_SqlTxn(txn)));
  }

  @override
  Future<List<Map<String, Object?>>> queryTx({
    DateTime? from,
    DateTime? to,
    String? category,
    int? type,
    int? limit,
    int? offset,
  }) async {
    final db = await _open();
    final where = <String>[];
    final args = <Object?>[];
    if (from != null) {
      where.add('date >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('date < ?');
      args.add(to.toIso8601String());
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category);
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type);
    }
    return db.query(
      SecureDbTables.tx,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<Map<String, int>> sumExpenseByCategory({
    required int type,
    required DateTime month,
  }) async {
    try {
      final db = await _open();
      final from = DateTime(month.year, month.month, 1);
      final to = DateTime(month.year, month.month + 1, 1);
      // Samakan semantik spentForBudget: date > start-1s AND date < end.
      final start = from.subtract(const Duration(seconds: 1)).toIso8601String();
      final rows = await db.rawQuery(
        'SELECT category, SUM(amount) AS total FROM ${SecureDbTables.tx} '
        'WHERE type = ? AND date > ? AND date < ? GROUP BY category',
        [type, start, to.toIso8601String()],
      );
      // P4: kolom amount integer → SUM integer. Baris legacy pecahan
      // (pra-migrasi v4) dibulatkan di sini sebagai jaring pengaman.
      final out = <String, int>{};
      for (final r in rows) {
        final cat = r['category'] as String?;
        final total = (r['total'] as num?)?.round();
        if (cat != null && total != null) out[cat] = total;
      }
      return out;
    } catch (e) {
      SecureDbService.noteError('db_sumExpense: $e');
      rethrow;
    }
  }

  @override
  Future<bool> get isEmpty async {
    final db = await _open();
    for (final t in [...SecureDbTables.all, SecureDbTables.audit]) {
      final n = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $t'),
      );
      if ((n ?? 0) > 0) return false;
    }
    return true;
  }

  @override
  Future<bool> tableIsEmpty(String table) async {
    final db = await _open();
    // LIMIT 1, bukan COUNT(*): yang ditanyakan hanya "ada atau tidak",
    // jadi tak perlu memindai seluruh tabel.
    final rows = await db.rawQuery('SELECT 1 FROM $table LIMIT 1');
    return rows.isEmpty;
  }

  @override
  Future<void> clear() async {
    final db = await _open();
    final batch = db.batch();
    for (final t in [...SecureDbTables.all, SecureDbTables.audit]) {
      batch.delete(t);
    }
    await batch.commit(noResult: true);
  }
}

/// Backend test/in-memory: tanpa platform channel & tanpa enkripsi.
/// Dipakai via [SecureDbService.useInMemory] di test.
class _MemoryTxn implements DbTxn {
  _MemoryTxn(this._snapshot);
  final Map<String, List<Map<String, Object?>>> _snapshot;

  @override
  Future<void> replace(String table, List<Map<String, Object?>> rows) async {
    _snapshot[table] =
        rows.map((r) => Map<String, Object?>.of(r)).toList(growable: false);
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row) async {
    final clean = _sanitize(table, [row]);
    if (clean.isEmpty) return;
    final list = _snapshot[table]!;
    final id = clean.first['id'];
    final i = list.indexWhere((r) => r['id'] == id);
    if (i == -1) {
      list.add(Map<String, Object?>.of(clean.first));
    } else {
      list[i] = Map<String, Object?>.of(clean.first);
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    _snapshot[table]!.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<List<Map<String, Object?>>> load(String table) async =>
      _snapshot[table]!.map((r) => Map<String, Object?>.of(r)).toList();
}

/// Backend test/in-memory: tanpa platform channel & tanpa enkripsi.
/// Dipakai via [SecureDbService.useInMemory] di test.
class _MemoryBackend implements _EntityBackend {
  final Map<String, List<Map<String, Object?>>> _data = {
    for (final t in SecureDbTables.all) t: [],
    SecureDbTables.audit: [],
  };

  @override
  Future<void> close() async {}

  @override
  Future<List<Map<String, Object?>>> load(String table) async =>
      _data[table]!.map((r) => Map<String, Object?>.of(r)).toList();

  @override
  Future<void> replace(String table, List<Map<String, Object?>> rows) async {
    _data[table] =
        rows.map((r) => Map<String, Object?>.of(r)).toList(growable: false);
  }

  @override
  Future<void> upsert(String table, Map<String, Object?> row) async {
    final clean = _sanitize(table, [row]);
    if (clean.isEmpty) return;
    final list = _data[table]!;
    final id = clean.first['id'];
    final i = list.indexWhere((r) => r['id'] == id);
    if (i == -1) {
      list.add(Map<String, Object?>.of(clean.first));
    } else {
      list[i] = Map<String, Object?>.of(clean.first);
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    _data[table]!.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function(DbTxn txn) action) async {
    // Snapshot deep-copy: bila [action] throw, _data dikembalikan utuh
    // (semantik ROLLBACK). Bila sukses, snapshot yang dimutasi di-commit.
    final snapshot = <String, List<Map<String, Object?>>>{
      for (final e in _data.entries)
        e.key: e.value.map((r) => Map<String, Object?>.of(r)).toList(),
    };
    final txn = _MemoryTxn(snapshot);
    try {
      final result = await action(txn);
      for (final t in SecureDbTables.all) {
        _data[t] = snapshot[t]!;
      }
      return result;
    } catch (_) {
      rethrow;
    }
  }

  bool _txInRange(
    Map<String, Object?> r, {
    DateTime? from,
    DateTime? to,
    String? category,
    int? type,
  }) {
    if (category != null && r['category'] != category) return false;
    if (type != null && (r['type'] as num?)?.toInt() != type) return false;
    DateTime? date;
    try {
      final d = r['date'];
      date = d is String ? DateTime.parse(d) : null;
    } catch (_) {
      return false;
    }
    if (date == null) return false;
    // Samakan query SQL: from inklusif, to eksklusif.
    if (from != null && date.isBefore(from)) return false;
    if (to != null && !date.isBefore(to)) return false;
    return true;
  }

  @override
  Future<List<Map<String, Object?>>> queryTx({
    DateTime? from,
    DateTime? to,
    String? category,
    int? type,
    int? limit,
    int? offset,
  }) async {
    var rows = _data[SecureDbTables.tx]!
        .where(
          (r) =>
              _txInRange(r, from: from, to: to, category: category, type: type),
        )
        .map((r) => Map<String, Object?>.of(r))
        .toList();
    rows.sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    if (offset != null && offset > 0) {
      rows = offset < rows.length ? rows.sublist(offset) : [];
    }
    if (limit != null && limit < rows.length) {
      rows = rows.sublist(0, limit);
    }
    return rows;
  }

  @override
  Future<Map<String, int>> sumExpenseByCategory({
    required int type,
    required DateTime month,
  }) async {
    // Samakan spentForBudget: date > start-1s AND date < end.
    final from = DateTime(month.year, month.month, 1);
    final to = DateTime(month.year, month.month + 1, 1);
    final start = from.subtract(const Duration(seconds: 1));
    final out = <String, int>{};
    for (final r in _data[SecureDbTables.tx]!) {
      if ((r['type'] as num?)?.toInt() != type) continue;
      DateTime? date;
      try {
        final d = r['date'];
        date = d is String ? DateTime.parse(d) : null;
      } catch (_) {
        continue;
      }
      if (date == null) continue;
      if (!date.isAfter(start) || !date.isBefore(to)) continue;
      final cat = r['category'];
      if (cat is! String) continue;
      // P4: baris legacy pecahan dibulatkan (jaring pengaman).
      out[cat] = (out[cat] ?? 0) + ((r['amount'] as num?)?.round() ?? 0);
    }
    return out;
  }

  @override
  Future<bool> get isEmpty async => _data.values.every((list) => list.isEmpty);

  @override
  Future<bool> tableIsEmpty(String table) async => _data[table]!.isEmpty;

  @override
  Future<void> clear() async {
    for (final t in [...SecureDbTables.all, SecureDbTables.audit]) {
      _data[t] = [];
    }
  }
}

/// Facade penyimpanan entitas. Produksi = SQLCipher; test = memori.
/// Migrasi prefs lawas→DB berjalan per tabel: hanya kunci lawas yang belum
/// pernah berhasil dimigrasikan, dan hanya ke tabel yang masih kosong.
class SecureDbService {
  SecureDbService._();

  static Future<_EntityBackend>? _readyFuture;
  static bool _inMemory = false;

  /// Profil pemilik database aktif. Diubah hanya via [useProfile].
  static String _profileId = 'default';

  /// Error database terakhir (null = belum ada kegagalan sesi ini).
  /// Ditampilkan di layar Info Debug agar penyebab "data hilang"
  /// terlihat di perangkat, bukan gagal sunyi.
  static String? lastError;

  /// Catat error DB + tampilkan di konsol debug (`flutter run`).
  /// Dipanggil jalur backend; tidak melempar.
  static void noteError(String message) {
    lastError = message;
    try {
      debugPrint('[KajiFinance][DB] $message');
    } catch (_) {
      // best-effort: konsol debug tak tersedia → lastError tetap tercatat.
    }
  }

  /// Objek error [_open] terakhir pada backend aktif (gagal baca/tulis
  /// kunci Keystore, SQLCipher tak termuat, file korup, migrasi skema
  /// gagal). Disimpan sebagai objek, bukan teks, supaya tipe aslinya masih
  /// bisa diperiksa pemanggil: `MigrationException` = skema gagal
  /// fail-closed (user harus diberi tahu), beda dari kegagalan I/O biasa.
  /// Null = DB terbuka normal pada sesi ini.
  static Object? _lastOpenFailure;

  /// True bila DB gagal dibuka pada sesi ini.
  ///
  /// Wajib diperiksa pemanggil yang memuat data ke memori: kegagalan buka
  /// DB dan "user memang belum punya data" sama-sama membuat memori
  /// kosong. Kalau yang pertama dianggap yang kedua, user melihat aplikasi
  /// seperti akun BARU (onboarding) padahal datanya masih ada di disk —
  /// dan yang lebih buruk, bisa menimpanya dengan data baru.
  static bool get openFailed => _lastOpenFailure != null;

  /// Objek error [_open] terakhir, atau null bila tak ada kegagalan
  /// (lihat [openFailed]).
  static Object? get lastOpenFailure => _lastOpenFailure;

  /// Catat kegagalan [_open]. Selain [lastError] (log + layar Debug),
  /// menandai [_lastOpenFailure] supaya [openFailed] true. Dipakai HANYA di
  /// jalur buka DB: kegagalan load/upsert/hapus satu tabel tak menyentuh
  /// penanda ini, karena yang harus ditampilkan ke user adalah "DB-nya
  /// tak kebuka", bukan satu tabel yang gagal.
  static void noteOpenError(String message, Object error) {
    _lastOpenFailure = error;
    noteError(message);
  }

  /// Nolkan [_lastOpenFailure] — dipanggil setelah [_open] berhasil atau
  /// saat backend dilepas (ganti profil / backend memori).
  static void _clearOpenFailure() => _lastOpenFailure = null;

  /// Pakai backend memori fresh (test). Memutus backend lama agar tiap
  /// pemanggilan terisolasi. WAJIB dipanggil sebelum provider dipakai.
  static Future<void> useInMemory() {
    _inMemory = true;
    // Backend memori tak pernah gagal buka → penanda dari backend SQLCipher
    // sebelumnya tak boleh diwarisi.
    _clearOpenFailure();
    _readyFuture = _initBackend(_MemoryBackend());
    return _readyFuture!.then((_) {});
  }

  static Future<_EntityBackend> _ready() => _readyFuture ??= _initBackend(
        _inMemory ? _MemoryBackend() : _SqlCipherBackend(_profileId),
      );

  /// Beralih database ke profil [id]: tutup koneksi lama, buang cache
  /// backend. WAJIB dipanggil sebelum reload provider setelah ganti
  /// profil (lihat switch profil di Settings). Aman di test (backend
  /// memori dihormati).
  /// R2 fail-closed: ID tak valid → throw (jangan bentuk path traversal).
  static Future<void> useProfile(String id) async {
    if (!isValidProfileId(id)) {
      noteError('db_useProfile: invalid id');
      throw FormatException('invalid profile id: $id');
    }
    _profileId = id;
    // Kegagalan buka milik backend LAMA — jangan diwarisi profil baru.
    _clearOpenFailure();
    final old = _readyFuture;
    _readyFuture = null;
    if (old == null) return;
    try {
      await (await old).close();
    } catch (_) {
      // best-effort: tutup backend lama gagal → backend baru tetap dipakai.
    }
  }

  static Future<_EntityBackend> _initBackend(_EntityBackend backend) async {
    await _migrateLegacyPrefs(backend);
    return backend;
  }

  /// Kunci prefs yang menandai kunci prefs lawas mana yang SUDAH DIAMBIL
  /// ALIH oleh DB — ter-scope profil, konvensi sama dengan flag backfill
  /// `kaji_wallet_init_migrated`. Tanpa penanda ini, kunci lawas yang gagal
  /// sekali migrasi tak akan pernah dicoba lagi: begitu satu tabel sukses,
  /// DB tak lagi kosong sehingga gate lama menutup migrasi di launch
  /// berikutnya, dan tak ada jalur kode lain yang membaca kunci itu
  /// (backup hanya mengekspor dari DB) → data tersebut hilang selamanya.
  static String get _legacyDoneKey =>
      scopedProfileKey(_profileId, 'kaji_legacy_migrated');

  /// Baca [_legacyDoneKey] sebagai himpunan kunci lawas yang sudah selesai.
  static Set<String> _readLegacyDone(SharedPreferences prefs) {
    final raw = prefs.get(_legacyDoneKey);
    if (raw is! String || raw.isEmpty) return <String>{};
    try {
      final list = jsonDecode(raw);
      if (list is! List) return <String>{};
      return list.whereType<String>().toSet();
    } catch (_) {
      // Penanda korup → anggap belum ada. Tidak berbahaya: tabel yang
      // sudah terisi tetap dilewati (lihat [_migrateLegacyPrefs]), jadi
      // yang terulang hanya percobaan ke tabel yang benar-benar kosong.
      return <String>{};
    }
  }

  /// Simpan [_legacyDoneKey]. Best-effort: kalau gagal, lain kali kunci
  /// lawas yang SUDAH ter-migrasi akan diperiksa lagi — dan hanya dilewati
  /// (tabelnya sudah terisi), tanpa penulisan ulang, jadi tetap aman.
  static Future<void> _writeLegacyDone(
    SharedPreferences prefs,
    Set<String> done,
  ) async {
    try {
      await prefs.setString(_legacyDoneKey, jsonEncode(done.toList()..sort()));
    } catch (e) {
      noteError('db_migrate_penanda: $e');
    }
  }

  /// Parse nilai prefs lawas [raw] untuk tabel [table] menjadi JSON list.
  /// Null = tak bisa dipakai (JSON rusak / bukan list) — kegagalan yang
  /// deterministik, bukan sementara: dicoba lagi tak akan berhasil.
  static List? _parseLegacyList(String table, String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
      noteError(
        'db_migrate $table: JSON lawas bukan list '
        '(${decoded.runtimeType}) — dilewati',
      );
    } catch (e) {
      // Isi prefs sengaja tak ikut dicatat: bisa memuat data keuangan user.
      noteError('db_migrate $table: JSON lawas rusak: $e');
    }
    return null;
  }

  /// Pindahkan kunci prefs lawas ke tabel, lalu hapus kunci lawas yang
  /// datanya benar-benar sudah mendarat di DB agar DB jadi satu sumber
  /// kebenaran (tidak ada divergensi ganda). Kunci dibaca ter-scope profil
  /// (profil baru tak punya warisan).
  ///
  /// Syarat migrasi dihitung PER TABEL, bukan satu flag global "DB kosong":
  /// 1. kunci prefs lawas masih ada, dan
  /// 2. kunci itu belum pernah diambil alih ([_legacyDoneKey]), dan
  /// 3. tabel tujuan masih kosong.
  ///
  /// Syarat 3 adalah penjaga anti-hilang-data: nilai prefs lawas adalah
  /// snapshot JADUL. Menyalinnya ke tabel yang sudah berisi data — mis. user
  /// sudah lanjut memakai app (dan menambah dompet) sejak migrasi
  /// pertamanya, atau datanya baru datang lewat restore — akan menimpa data
  /// yang lebih baru. Sebaliknya, tabel yang masih kosong WAJIB dicoba ulang:
  /// itulah yang membuat kunci lawas yang gagal sekali (I/O transient)
  /// akhirnya berhasil. Gate lama `if (!await backend.isEmpty) return`
  /// menutup migrasi begitu satu tabel saja sukses, sehingga launch
  /// berikutnya tak pernah menyentuhnya lagi — itu sumber kebocoran data
  /// di sini.
  ///
  /// Kunci prefs hanya dihapus SETELAH `replace` sukses (rollback penuh
  /// `Batch.commit` sqflite menjamin tak ada tabel setengah jadi) — inilah
  /// yang membuat percobaan berikutnya selalu punya sumber data. Kunci lawas
  /// yang sengaja dilewati TIDAK dihapus: itu masih satu-satunya salinan.
  static Future<void> _migrateLegacyPrefs(_EntityBackend backend) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = _readLegacyDone(prefs);
      var dirty = false;
      for (final e in legacyKeyToTable.entries) {
        if (done.contains(e.key)) continue;
        final scoped = scopedProfileKey(_profileId, e.key);
        final raw = prefs.get(scoped);
        if (raw == null) continue; // tak ada warisan untuk kunci ini
        if (raw is! String) {
          // Bentuk lawas tak terduga (bukan JSON string). Kunci tak dihapus
          // (jangan buang data yang belum kita pahami), tapi ditandai
          // selesai supaya tak ditanyakan ulang tiap launch.
          noteError(
            'db_migrate ${e.value}: nilai prefs bukan string '
            '(${raw.runtimeType}) — dilewati, kunci dipertahankan',
          );
          done.add(e.key);
          dirty = true;
          continue;
        }
        // Satu tabel gagal tidak boleh memblokir tabel lain, dan kuncinya
        // tidak boleh dihapus: sisa untuk percobaan berikutnya.
        try {
          if (!await backend.tableIsEmpty(e.value)) {
            // Tabel sudah berisi data yang lebih baru daripada snapshot
            // prefs. Kunci lawas SENGAJA dibiarkan utuh — kalau ternyata
            // tabel itu bukan data yang benar, salinan ini masih ada.
            noteError(
              'db_migrate ${e.value}: dilewati, tabel sudah terisi '
              '(kunci lawas dipertahankan)',
            );
            done.add(e.key);
            dirty = true;
            continue;
          }
          final list = _parseLegacyList(e.value, raw);
          if (list == null) {
            done.add(e.key);
            dirty = true;
            continue;
          }
          final rows = _sanitize(e.value, list);
          if (rows.isEmpty) {
            // Tak ada satu pun baris yang bisa disimpan (daftar kosong, atau
            // semua baris tanpa `id` valid). Kunci lawas dibiarkan utuh
            // karena tak ada yang "mendarat" ke DB — aturan hapus hanya
            // berlaku bagi data yang benar-benar sudah tersimpan.
            if (list.isNotEmpty) {
              noteError(
                'db_migrate ${e.value}: ${list.length} baris lawas '
                'tanpa id valid — tak ada yang bisa dimigrasi',
              );
            }
            done.add(e.key);
            dirty = true;
            continue;
          }
          await backend.replace(e.value, rows);
          try {
            await prefs.remove(scoped);
          } catch (err) {
            // best-effort: kunci lawas tak terhapus, tapi tabel sudah terisi
            // sehingga launch berikutnya hanya melewatinya (syarat 3).
            noteError('db_migrate ${e.value}: hapus kunci lawas gagal: $err');
          }
          done.add(e.key);
          dirty = true;
        } catch (err) {
          // Kegagalan SEMENTARA (I/O, backend) → jangan tandai selesai,
          // biar launch berikutnya mencoba lagi ke tabel yang masih kosong.
          SecureDbService.noteError('db_migrate ${e.value} gagal: $err');
        }
      }
      if (dirty) await _writeLegacyDone(prefs, done);
    } catch (e) {
      // Tidak melempar: [_initBackend] tak boleh gagal total hanya karena
      // prefs tak terbaca. Kalau [_readyFuture] jadi Future ber-error,
      // SETIAP akses DB berikutnya ikut gagal dan data yang masih ada di
      // disk tak akan pernah tampil.
      SecureDbService.noteError('db_migrate gagal: $e');
    }
  }

  static Future<List<Map<String, Object?>>> loadTable(String table) async =>
      (await _ready()).load(table);

  static Future<void> saveTable(
    String table,
    List<Map<String, Object?>> rows,
  ) async =>
      (await _ready()).replace(table, rows);

  /// Tulis inkremental 1 baris (insert-or-replace by id). Baris tanpa
  /// `id` valid di-skip. Dipakai jalur mutasi agar tak menulis ulang
  /// seluruh tabel tiap transaksi.
  static Future<void> upsertRow(String table, Map<String, Object?> row) async =>
      (await _ready()).upsert(table, row);

  /// Hapus 1 baris by id (no-op bila tak ada).
  static Future<void> deleteRow(String table, String id) async =>
      (await _ready()).delete(table, id);

  /// Query transaksi terfilter langsung di SQLite (mendukung paging).
  /// `from` inklusif, `to` eksklusif, urut tanggal terbaru dulu.
  static Future<List<Map<String, Object?>>> queryTransactions({
    DateTime? from,
    DateTime? to,
    String? category,
    int? type,
    int? limit,
    int? offset,
  }) async =>
      (await _ready()).queryTx(
        from: from,
        to: to,
        category: category,
        type: type,
        limit: limit,
        offset: offset,
      );

  /// Total expense per kategori pada bulan [month] — 1 round trip
  /// untuk recalc anggaran (gantikan O(B×T) scan in-memory).
  /// Semantik batas == spentForBudget (start-1s eksklusif, end eksklusif).
  static Future<Map<String, int>> sumExpenseByCategory({
    required int type,
    required DateTime month,
  }) async =>
      (await _ready()).sumExpenseByCategory(type: type, month: month);

  static Future<void> clearAll() async => (await _ready()).clear();

  /// Abstraksi transaksi database yang reusable untuk operasi finansial
  /// multi-tabel (add/update/delete transaction, deposit/withdraw, transfer,
  /// bulk import, restore).
  ///
  /// Semantik: BEGIN → [action] → COMMIT; bila [action] throw → ROLLBACK
  /// semuanya. Tidak boleh terjadi "transaction berhasil, wallet gagal".
  ///
  /// Contoh:
  /// ```dart
  /// await SecureDbService.transaction((db) async {
  ///   await db.upsert(SecureDbTables.tx, txRow);
  ///   await db.replace(SecureDbTables.wallets, walletRows);
  /// });
  /// ```
  ///
  /// [debugLabel] hanya untuk log (mis. `depositToGoal`), jangan isi data
  /// sensitif. Error bertipe [KajiException] diteruskan apa adanya; error
  /// lain dibungkus [KajiDatabaseException] agar pemanggil bisa tangani seragam.
  static Future<T> transaction<T>(
    Future<T> Function(DbTxn db) action, {
    String? debugLabel,
  }) async {
    final label = debugLabel ?? 'transaction';
    AppLog.event('db.transaction.started', data: {'label': label});
    try {
      final backend = await _ready();
      final result = await backend.runInTransaction(action);
      AppLog.event('db.transaction.completed', data: {'label': label});
      return result;
    } catch (e) {
      AppLog.error('db.transaction.failed', e, data: {'label': label});
      noteError('db_transaction($label): $e');
      if (e is KajiException) rethrow;
      throw KajiDatabaseException(
        'Operasi database gagal. Tidak ada data yang berubah.',
        operation: label,
        details: '$e',
      );
    }
  }

  /// Jumlah baris per tabel untuk diagnostik (layar Info Debug).
  /// Best-effort: gagal buka DB → peta kosong + [lastError] terisi.
  static Future<Map<String, int>> rowCounts() async {
    final out = <String, int>{};
    try {
      final backend = await _ready();
      for (final t in SecureDbTables.all) {
        try {
          out[t] = (await backend.load(t)).length;
        } catch (e) {
          noteError('db_count($t): $e');
        }
      }
    } catch (e) {
      noteError('db_counts: $e');
    }
    return out;
  }

  /// Ekspor entitas sebagai string JSON per kunci backup lawas
  /// (bentuk identik nilai prefs dulu — format backup tak berubah).
  static Future<Map<String, String>> exportEntityJson() async {
    final backend = await _ready();
    final out = <String, String>{};
    for (final e in legacyKeyToTable.entries) {
      out[e.key] = jsonEncode(await backend.load(e.value));
    }
    return out;
  }

  /// Parse + sanitize SATU entitas backup TANPA menulis DB (tahap
  /// validasi restore P8). Throw [FormatException] bila bukan List JSON —
  /// pemanggil menolak file sebelum data existing tersentuh.
  static List<Map<String, Object?>> stageEntityRows(
    String table,
    String rawJson,
  ) {
    final list = jsonDecode(rawJson) as List;
    return _sanitize(table, list);
  }

  /// Impor entitas dari string JSON backup. Baris rusak di-skip.
  /// Return jumlah baris per TABEL yang benar-benar mendarat di DB
  /// (read-back). Pemanggil membandingkan dengan input untuk mendeteksi
  /// impor parsial yang gagal sunyi — jangan klaim sukses palsu.
  /// Throw bila satu pun entitas korup (bukan List) atau transaksi DB
  /// gagal — panggil dari jalur staged-restore yang menolak file utuh
  /// sebelum menulis prefs/PIN (P8).
  static Future<Map<String, int>> importEntityJson(
    Map<String, String> data,
  ) async {
    // Phase 2: parse + sanitize SEMUA tabel dulu, lalu replace dalam SATU
    // transaksi — restore parsial tidak mungkin (ROLLBACK bila gagal).
    final cleaned = <String, List<Map<String, Object?>>>{};
    for (final e in legacyKeyToTable.entries) {
      final raw = data[e.key];
      if (raw == null) continue;
      cleaned[e.value] = stageEntityRows(e.value, raw);
    }
    if (cleaned.isEmpty) return const {};
    await transaction((db) async {
      for (final entry in cleaned.entries) {
        await db.replace(entry.key, entry.value);
      }
    }, debugLabel: 'importEntityJson');
    // Restore menimpa data dengan isi file (yang umumnya berformat lama
    // tanpa initial_balance) → reset flag backfill P3 agar reload berikutnya
    // menghitung ulang opening balance dari data hasil restore.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(
        scopedProfileKey(_profileId, 'kaji_wallet_init_migrated'),
      );
    } catch (e) {
      noteError('db_import_flag: $e');
    }
    // Verifikasi read-back pasca-commit.
    final landed = <String, int>{};
    for (final entry in cleaned.entries) {
      try {
        final back = await loadTable(entry.key);
        landed[entry.key] = back.length;
        if (back.length != entry.value.length) {
          noteError(
            'db_import_verify(${entry.key}): input=${entry.value.length} db=${back.length}',
          );
        }
      } catch (err) {
        noteError('db_import_verify(${entry.key}): $err');
      }
    }
    return landed;
  }
}
