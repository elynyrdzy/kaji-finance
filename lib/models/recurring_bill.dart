import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/profile_service.dart';
import '../services/secure_db_service.dart';
import '../utils/app_icons.dart';
import 'profile_model.dart';

/// Periode tagihan rutin.
enum RecurringPeriod { weekly, monthly, yearly }

/// Tagihan rutin / langganan Indonesia (kos, listrik, PDAM, BPJS, ...).
///
/// Offline-only, nominal SELALU integer rupiah ([amount] > 0) via MoneyFormat.
/// Penjadwalan murni tanggal lokal (tanpa timezone DB — Indonesia tanpa DST).
class RecurringBill {
  final String id;
  final String name;

  /// Rupiah utuh (Phase 4: integer, selalu positif).
  final int amount;
  final RecurringPeriod period;

  /// Makna tergantung [period]:
  /// - monthly/yearly: tanggal jatuh tempo 1-31 (dijepit ke panjang bulan).
  /// - weekly: hari Senin=1 .. Minggu=7 (ikut [DateTime.weekday]).
  final int dueDay;

  /// Bulan jatuh tempo 1-12 — hanya dipakai [RecurringPeriod.yearly].
  final int dueMonth;
  final String category;

  /// Nama dompet sumber (tampilan + fallback; ID di-resolve saat posting).
  final String wallet;
  final IconData icon;

  /// True = bukukan transaksi otomatis saat jatuh tempo;
  /// false = hanya pengingat (reminder saja).
  final bool autoCreate;
  final bool active;

  /// Kunci periode terakhir yang sudah dibukukan (lihat [periodKeyFor]),
  /// agar auto-create idempoten — dibuka sekali per periode.
  final String? lastPostedKey;
  final DateTime createdAt;

  const RecurringBill({
    required this.id,
    required this.name,
    required this.amount,
    required this.period,
    required this.dueDay,
    this.dueMonth = 1,
    required this.category,
    required this.wallet,
    required this.icon,
    this.autoCreate = false,
    this.active = true,
    this.lastPostedKey,
    required this.createdAt,
  });

  bool get isValid =>
      name.trim().isNotEmpty &&
      amount > 0 &&
      category.trim().isNotEmpty &&
      wallet.trim().isNotEmpty &&
      dueDay >= 1 &&
      (period == RecurringPeriod.weekly ? dueDay <= 7 : dueDay <= 31) &&
      dueMonth >= 1 &&
      dueMonth <= 12;

  RecurringBill copyWith({
    String? name,
    int? amount,
    RecurringPeriod? period,
    int? dueDay,
    int? dueMonth,
    String? category,
    String? wallet,
    IconData? icon,
    bool? autoCreate,
    bool? active,
    String? lastPostedKey,
    bool clearLastPostedKey = false,
  }) {
    return RecurringBill(
      id: id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      period: period ?? this.period,
      dueDay: dueDay ?? this.dueDay,
      dueMonth: dueMonth ?? this.dueMonth,
      category: category ?? this.category,
      wallet: wallet ?? this.wallet,
      icon: icon ?? this.icon,
      autoCreate: autoCreate ?? this.autoCreate,
      active: active ?? this.active,
      lastPostedKey:
          clearLastPostedKey ? null : (lastPostedKey ?? this.lastPostedKey),
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'amount': amount,
        'period': period.index,
        'dueDay': dueDay,
        'dueMonth': dueMonth,
        'category': category,
        'wallet': wallet,
        'icon': icon.codePoint,
        'autoCreate': autoCreate,
        'active': active,
        'lastPostedKey': lastPostedKey,
        'createdAt': createdAt.toIso8601String(),
      };

  static RecurringBill? fromJson(Map<String, dynamic> j) {
    try {
      final id = '${j['id'] ?? ''}';
      final name = '${j['name'] ?? ''}';
      final category = '${j['category'] ?? ''}';
      final wallet = '${j['wallet'] ?? ''}';
      final rawPeriod = (j['period'] as num?)?.toInt() ?? 1;
      if (id.isEmpty || name.isEmpty || category.isEmpty || wallet.isEmpty) {
        return null;
      }
      if (rawPeriod < 0 || rawPeriod >= RecurringPeriod.values.length) {
        return null;
      }
      return RecurringBill(
        id: id,
        name: name,
        // P4: baris lama pecahan dibulatkan ke rupiah utuh.
        amount: ((j['amount'] as num?) ?? 0).round(),
        period: RecurringPeriod.values[rawPeriod],
        dueDay: ((j['dueDay'] as num?) ?? 1).toInt().clamp(1, 31),
        dueMonth: ((j['dueMonth'] as num?) ?? 1).toInt().clamp(1, 12),
        category: category,
        wallet: wallet,
        icon: AppIcons.fromCodePoint((j['icon'] as num?)?.toInt() ?? 0),
        autoCreate: (j['autoCreate'] as bool?) ?? false,
        active: (j['autoCreate'] == null && j['active'] == null)
            ? true
            : (j['active'] as bool?) ?? true,
        lastPostedKey: j['lastPostedKey'] as String?,
        createdAt: j['createdAt'] == null
            ? DateTime.now()
            : DateTime.parse(j['createdAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  // --- Penjadwalan murni (semua memakai tanggal kalender lokal) ---

  static int _dim(int year, int month) => DateTime(year, month + 1, 0).day;

  /// Kemunculan berikutnya pada/SETELAH tanggal [from] (termasuk hari ini).
  DateTime nextDue(DateTime from) {
    final today = DateTime(from.year, from.month, from.day);
    switch (period) {
      case RecurringPeriod.weekly:
        final wd = dueDay.clamp(1, 7);
        return today.add(Duration(days: (wd - today.weekday) % 7));
      case RecurringPeriod.monthly:
        final d = dueDay.clamp(1, _dim(today.year, today.month));
        var cand = DateTime(today.year, today.month, d);
        if (cand.isBefore(today)) {
          final ny = today.month == 12 ? today.year + 1 : today.year;
          final nm = today.month == 12 ? 1 : today.month + 1;
          cand = DateTime(ny, nm, dueDay.clamp(1, _dim(ny, nm)));
        }
        return cand;
      case RecurringPeriod.yearly:
        final m = dueMonth.clamp(1, 12);
        var cand = DateTime(
          today.year,
          m,
          dueDay.clamp(1, _dim(today.year, m)),
        );
        if (cand.isBefore(today)) {
          cand = DateTime(
            today.year + 1,
            m,
            dueDay.clamp(1, _dim(today.year + 1, m)),
          );
        }
        return cand;
    }
  }

  /// Kemunculan terakhir pada/SEBELUM tanggal [from] (null bila belum
  /// pernah terjadi — mis. tagihan dibuat setelah jatuh tempo bulan ini
  /// untuk periode bulanan; pemanggil boleh fallback ke [createdAt]).
  DateTime? lastOccurrence(DateTime from) {
    final today = DateTime(from.year, from.month, from.day);
    switch (period) {
      case RecurringPeriod.weekly:
        final wd = dueDay.clamp(1, 7);
        return today.subtract(Duration(days: (today.weekday - wd) % 7));
      case RecurringPeriod.monthly:
        final d = dueDay.clamp(1, _dim(today.year, today.month));
        final cand = DateTime(today.year, today.month, d);
        return cand.isAfter(today) ? null : cand;
      case RecurringPeriod.yearly:
        final m = dueMonth.clamp(1, 12);
        final cand = DateTime(
          today.year,
          m,
          dueDay.clamp(1, _dim(today.year, m)),
        );
        return cand.isAfter(today) ? null : cand;
    }
  }

  /// Kunci idempoten per kemunculan (stabil lintas restart).
  static String periodKeyFor(RecurringPeriod period, DateTime occ) {
    final d = DateTime(occ.year, occ.month, occ.day);
    switch (period) {
      case RecurringPeriod.weekly:
        final monday = d.subtract(Duration(days: (d.weekday - 1) % 7));
        return 'W${monday.year.toString().padLeft(4, '0')}-'
            '${monday.month.toString().padLeft(2, '0')}-'
            '${monday.day.toString().padLeft(2, '0')}';
      case RecurringPeriod.monthly:
        return 'M${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}';
      case RecurringPeriod.yearly:
        return 'Y${d.year.toString().padLeft(4, '0')}';
    }
  }

  /// Sisa hari kalender hingga jatuh tempo berikutnya (0 = hari ini).
  int daysUntilDue(DateTime now) =>
      nextDue(now).difference(DateTime(now.year, now.month, now.day)).inDays;

  /// True bila kemunculan terakhir sudah lewat hari ini dan periode itu
  /// belum dibukukan (khusus [autoCreate] — reminder-only tak overdue).
  bool isOverdue(DateTime now) {
    if (!active || !autoCreate) return false;
    final occ = lastOccurrence(now);
    if (occ == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    if (!occ.isBefore(today)) return false;
    return lastPostedKey != periodKeyFor(period, occ);
  }
}

/// Template awal khas Indonesia (nominal 0 = isi sendiri, dompet kosong =
/// pilih sendiri). ID segar tiap dipanggil.
class RecurringBillPresets {
  const RecurringBillPresets._();

  static List<RecurringBill> templates() {
    final now = DateTime.now();
    RecurringBill t({
      required String name,
      required String category,
      required IconData icon,
      RecurringPeriod period = RecurringPeriod.monthly,
      required int dueDay,
    }) =>
        RecurringBill(
          id: 'preset-${DateTime.now().microsecondsSinceEpoch}-${name.hashCode & 0xffff}',
          name: name,
          amount: 0,
          period: period,
          dueDay: dueDay,
          category: category,
          wallet: '',
          icon: icon,
          autoCreate: false,
          active: true,
          createdAt: now,
        );
    return [
      t(
        name: 'Kos / Kontrakan',
        category: 'Bills & Utilities',
        icon: Icons.home,
        dueDay: 1,
      ),
      t(
        name: 'Listrik PLN',
        category: 'Bills & Utilities',
        icon: Icons.bolt,
        dueDay: 20,
      ),
      t(
        name: 'PDAM / Air',
        category: 'Bills & Utilities',
        icon: Icons.receipt_long,
        dueDay: 15,
      ),
      t(
        name: 'BPJS Kesehatan',
        category: 'Health & Care',
        icon: Icons.medical_services,
        dueDay: 10,
      ),
      t(
        name: 'Pulsa / Paket Data',
        category: 'Bills & Utilities',
        icon: Icons.phone_android_outlined,
        dueDay: 1,
      ),
      t(
        name: 'Internet / WiFi',
        category: 'Bills & Utilities',
        icon: Icons.laptop_outlined,
        dueDay: 5,
      ),
      t(
        name: 'Langganan Aplikasi',
        category: 'Entertainment',
        icon: Icons.movie,
        dueDay: 1,
      ),
    ];
  }
}

// --- Persistensi ---

/// Kontrak simpan/muat tagihan rutin.
///
/// TODO(sql-migration): pindahkan ke tabel `recurring_bills` terenkripsi di
/// SecureDbService saat orchestrator menaikkan schema version — bentuk baris
/// 1:1 dengan [RecurringBill.toJson] (+ kolom `profile_id` implisit via file
/// DB per-profil). Sampai saat itu implementasi SharedPreferences ter-scope
/// di bawah adalah sumber kebenaran. Bentuk JSON HARUS tetap kompatibel agar
/// migrasi tinggal `load()` → insert rows.
abstract class RecurringBillStore {
  Future<List<RecurringBill>> load();
  Future<void> save(List<RecurringBill> bills);
}

/// Implementasi SharedPreferences ter-scope profil (lihat [scopedProfileKey]:
/// profil `default` polos, sisanya ber-prefix). Entri korup di-skip per-baris.
class PrefsRecurringBillStore implements RecurringBillStore {
  /// Pabrik prefs yang bisa diinjeksi test (default = singleton global).
  /// Satu titik akuisisi — jangan panggil SharedPreferences.getInstance()
  /// untuk tagihan rutin di luar sini.
  final Future<SharedPreferences> Function() prefsFactory;

  PrefsRecurringBillStore({Future<SharedPreferences> Function()? prefsFactory})
      : prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  static String keyFor(String profileId) =>
      scopedProfileKey(profileId, 'kaji_recurring_bills');

  @override
  Future<List<RecurringBill>> load() async {
    try {
      final p = await prefsFactory();
      final raw = p.getString(keyFor(ProfileService.activeId));
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final out = <RecurringBill>[];
      for (final e in list) {
        try {
          if (e is Map<String, dynamic>) {
            final b = RecurringBill.fromJson(e);
            if (b != null) out.add(b);
          }
        } catch (_) {
          continue;
        }
      }
      return out;
    } catch (e) {
      SecureDbService.noteError('Recurring: baca gagal: $e');
      return [];
    }
  }

  @override
  Future<void> save(List<RecurringBill> bills) async {
    try {
      final p = await prefsFactory();
      await p.setString(
        keyFor(ProfileService.activeId),
        jsonEncode(bills.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      SecureDbService.noteError('Recurring: simpan gagal: $e');
    }
  }
}
