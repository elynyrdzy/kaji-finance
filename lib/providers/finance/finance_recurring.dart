part of '../finance_provider.dart';

/// Hasil sekali jalan [FinanceRecurring.processDueBills].
class RecurringProcessResult {
  final int posted;
  final int skippedOverdraft;
  final int reminders;
  const RecurringProcessResult({
    this.posted = 0,
    this.skippedOverdraft = 0,
    this.reminders = 0,
  });
}

/// Dampak satu tagihan aktif ke anggaran kategorinya (data murni — komposisi
/// teks notifikasi oleh pemanggil agar bisa di-unit-test).
class RecurringBudgetImpact {
  final String billName;
  final String budgetName;
  final int billAmount;
  final int spent;
  final int limit;

  /// (spent + bill) / limit — proyeksi bulan berjalan bila tagihan dibayar.
  final double projectedPct;
  final int level;
  const RecurringBudgetImpact({
    required this.billName,
    required this.budgetName,
    required this.billAmount,
    required this.spent,
    required this.limit,
    required this.projectedPct,
    required this.level,
  });
}

/// Tagihan rutin & langganan (extension bagian FinanceProvider).
///
/// Persistensi: SharedPreferences ter-scope via [RecurringBillStore]
/// (BUKAN tabel SQL — lihat TODO(sql-migration) di model). Muat eksplisit
/// via [loadRecurringBills] (dipanggil layar tagihan) agar cold start tak
/// terbebani; mutasi selalu simpan ulang penuh (daftar kecil, <100 baris).
extension FinanceRecurring on FinanceProvider {
  /// Estimasi beban bulanan (normalisasi: mingguan ×52/12, tahunan ÷12).
  int get estimatedMonthlyRecurring {
    var total = 0;
    for (final b in _recurringBills) {
      if (!b.active) continue;
      switch (b.period) {
        case RecurringPeriod.weekly:
          total += (b.amount * 52 / 12).round();
          break;
        case RecurringPeriod.monthly:
          total += b.amount;
          break;
        case RecurringPeriod.yearly:
          total += (b.amount / 12).round();
          break;
      }
    }
    return total;
  }

  RecurringBillStore get _recurringStore => PrefsRecurringBillStore();

  Future<void> loadRecurringBills({RecurringBillStore? store}) async {
    try {
      final list = await (store ?? _recurringStore).load();
      _recurringBills
        ..clear()
        ..addAll(list.where((b) => b.amount > 0 || b.name.trim().isNotEmpty));
      _notify();
    } catch (e) {
      SecureDbService.noteError('Recurring: muat ke memori gagal: $e');
    }
  }

  /// Simpan penuh daftar tagihan. **Men Rethrow bila gagal.**
  ///
  /// Fail-closed: kalau error ditelan di sini, pemanggil menampilkan
  /// "Tagihan tersimpan" padahal setelah restart tagihannya hilang — data
  /// keuangan hilang tanpa jejak. Pola ini disamakan dengan
  /// `_saveDebtsOrThrow` di finance_debts.dart.
  Future<void> _saveRecurringBills() async {
    try {
      await _recurringStore.save(_recurringBills);
    } catch (e) {
      SecureDbService.noteError('Recurring: persist gagal: $e');
      rethrow;
    }
  }

  /// Salinan daftar untuk rollback. [_recurringBills] adalah state milik
  /// provider yang juga dibaca UI, jadi mutasi parsial tak boleh dibiarkan
  /// menggantung bila write prefs gagal.
  List<RecurringBill> _snapshotBills() =>
      List<RecurringBill>.of(_recurringBills);

  void _restoreBills(List<RecurringBill> snap) {
    _recurringBills
      ..clear()
      ..addAll(snap);
    _notify();
  }

  Future<bool> addRecurringBill(RecurringBill bill) async {
    if (!bill.isValid) return false;
    if (_recurringBills.any(
      (e) =>
          e.name.toLowerCase() == bill.name.trim().toLowerCase() &&
          e.period == bill.period,
    )) {
      return false;
    }
    final snap = _snapshotBills();
    _recurringBills.add(bill);
    _notify();
    try {
      await _saveRecurringBills();
    } catch (_) {
      _restoreBills(snap);
      // Rethrow, bukan `return false`: `false` berarti "validasi/duplikat
      // ditolak" (UI menampilkan pesan yang tepat), sedangkan kegagalan
      // storage adalah kondisi lain yang butuh pesannya sendiri.
      rethrow;
    }
    unawaited(refreshRecurringReminders());
    return true;
  }

  Future<bool> updateRecurringBill(String id, RecurringBill next) async {
    final idx = _recurringBills.indexWhere((e) => e.id == id);
    if (idx == -1 || !next.isValid) return false;
    if (_recurringBills.any(
      (e) =>
          e.id != id &&
          e.name.toLowerCase() == next.name.trim().toLowerCase() &&
          e.period == next.period,
    )) {
      return false;
    }
    // Jadwal berubah → kunci posting lama tak berlaku lagi.
    final old = _recurringBills[idx];
    final scheduleChanged = old.period != next.period ||
        old.dueDay != next.dueDay ||
        old.dueMonth != next.dueMonth;
    final snap = _snapshotBills();
    _recurringBills[idx] =
        scheduleChanged ? next.copyWith(clearLastPostedKey: true) : next;
    _notify();
    try {
      await _saveRecurringBills();
    } catch (_) {
      _restoreBills(snap);
      // Rethrow, bukan `return false`: `false` berarti "validasi/duplikat
      // ditolak" (UI menampilkan pesan yang tepat), sedangkan kegagalan
      // storage adalah kondisi lain yang butuh pesannya sendiri.
      rethrow;
    }
    unawaited(refreshRecurringReminders());
    return true;
  }

  Future<bool> removeRecurringBill(String id) async {
    final idx = _recurringBills.indexWhere((e) => e.id == id);
    if (idx == -1) return false;
    final snap = _snapshotBills();
    _recurringBills.removeAt(idx);
    _notify();
    try {
      await _saveRecurringBills();
    } catch (_) {
      _restoreBills(snap);
      // Rethrow, bukan `return false`: `false` berarti "validasi/duplikat
      // ditolak" (UI menampilkan pesan yang tepat), sedangkan kegagalan
      // storage adalah kondisi lain yang butuh pesannya sendiri.
      rethrow;
    }
    unawaited(NotificationService.cancelRecurringBillReminders(id));
    unawaited(refreshRecurringReminders());
    return true;
  }

  Future<bool> setRecurringBillActive(String id, bool active) async {
    final idx = _recurringBills.indexWhere((e) => e.id == id);
    if (idx == -1) return false;
    final snap = _snapshotBills();
    _recurringBills[idx] = _recurringBills[idx].copyWith(active: active);
    _notify();
    try {
      await _saveRecurringBills();
    } catch (_) {
      _restoreBills(snap);
      // Rethrow, bukan `return false`: `false` berarti "validasi/duplikat
      // ditolak" (UI menampilkan pesan yang tepat), sedangkan kegagalan
      // storage adalah kondisi lain yang butuh pesannya sendiri.
      rethrow;
    }
    if (!active) {
      unawaited(NotificationService.cancelRecurringBillReminders(id));
    } else {
      unawaited(refreshRecurringReminders());
    }
    return true;
  }

  /// Tagihan aktif yang jatuh tempo dalam [days] hari (termasuk hari ini),
  /// terurut terdekat dulu. Murni (tanpa I/O) agar bisa di-unit-test.
  List<RecurringBill> recurringDueWithin({required int days, DateTime? now}) {
    final ref = now ?? DateTime.now();
    final out = <RecurringBill>[];
    for (final b in _recurringBills) {
      if (!b.active) continue;
      if (b.daysUntilDue(ref) <= days) out.add(b);
    }
    out.sort((a, b) => a.daysUntilDue(ref).compareTo(b.daysUntilDue(ref)));
    return out;
  }

  /// Tagihan auto-create yang sudah lewat jatuh tempo dan belum dibukukan.
  List<RecurringBill> get overdueRecurring {
    final now = DateTime.now();
    return _recurringBills.where((b) => b.isOverdue(now)).toList();
  }

  /// Bukukan kemunculan yang sudah jatuh tempo (maks 1 catch-up per tagihan
  /// per jalan — kemunculan TERAKHIR saja, bukan seluruh tunggakan, agar
  /// ledger tak dibanjiri bila aplikasi lama tak dibuka).
  ///
  /// Transaksi memakai tanggal kemunculan (bukan hari ini) agar agregat
  /// bulanan & spent anggaran akurat. Gagal overdraft = skip (saldo dompet
  /// tak boleh negatif), dicatat di [RecurringProcessResult].
  /// Dipanggil saat cold start selesai load + app ke background (lihat
  /// digest_scheduler / RootShell oleh orchestrator).
  Future<RecurringProcessResult> processDueBills({DateTime? now}) async {
    final ref = now ?? DateTime.now();
    final today = DateTime(ref.year, ref.month, ref.day);
    var posted = 0;
    var skipped = 0;
    for (var i = 0; i < _recurringBills.length; i++) {
      final b = _recurringBills[i];
      if (!b.active || !b.autoCreate) continue;
      final occ = b.lastOccurrence(ref);
      if (occ == null || occ.isAfter(today)) continue;
      if (b.lastPostedKey == RecurringBill.periodKeyFor(b.period, occ)) {
        continue;
      }
      final ok = await addTransaction(
        title: b.name,
        category: b.category,
        account: b.wallet,
        amount: b.amount,
        type: TransactionType.expense,
        icon: b.icon,
        tag: 'Tagihan Rutin',
        date: occ,
      );
      if (ok) {
        posted++;
        _recurringBills[i] = b.copyWith(
          lastPostedKey: RecurringBill.periodKeyFor(b.period, occ),
        );
      } else {
        skipped++;
      }
    }
    if (posted > 0) {
      _notify();
      try {
        await _saveRecurringBills();
      } catch (e) {
        // BEDA dari mutator di atas: transaksinya sudah terlanjur tercatat
        // di ledger, jadi tak ada yang bisa di-rollback. Kegagalan di sini
        // berarti `lastPostedKey` tak tersimpan → kemunculan yang sama akan
        // dibukukan LAGI di proses berikutnya (duplikat), bukan tagihan yang
        // hilang. Dicatat serius lalu ditelan: pemanggilnya cold start dan
        // tak punya jalan pemulihan yang berguna — Rethrow hanya akan
        // menggagalkan start aplikasi.
        SecureDbService.noteError(
          'Recurring: SIMPAN lastPostedKey GAGAL, risiko tagihan dobel '
          'di proses berikutnya: $e',
        );
      }
    }
    return RecurringProcessResult(
      posted: posted,
      skippedOverdraft: skipped,
      reminders: 0,
    );
  }

  /// Proyeksi 50/80/100%: untuk tiap tagihan aktif yang kategorinya punya
  /// anggaran, hitung (spent bulan ini + nominal tagihan) / limit.
  /// Kembalikan hanya yang levelnya > 0. Murni (tanpa notifikasi).
  List<RecurringBudgetImpact> recurringBudgetImpacts({DateTime? now}) {
    final ref = now ?? DateTime.now();
    final out = <RecurringBudgetImpact>[];
    for (final b in _recurringBills) {
      if (!b.active) continue;
      BudgetCategory? budget;
      for (final bd in _budgets) {
        if (bd.name.toLowerCase() == b.category.toLowerCase()) {
          budget = bd;
          break;
        }
      }
      if (budget == null || budget.limit <= 0) continue;
      final spent = spentForBudget(budget.name, month: ref);
      final pct = (spent + b.amount) / budget.limit;
      final level = NotificationService.budgetAlertLevel(pct);
      if (level > 0) {
        out.add(
          RecurringBudgetImpact(
            billName: b.name,
            budgetName: budget.name,
            billAmount: b.amount,
            spent: spent,
            limit: budget.limit,
            projectedPct: pct,
            level: level,
          ),
        );
      }
    }
    out.sort((a, b) => b.projectedPct.compareTo(a.projectedPct));
    return out;
  }

  /// Jadwalkan pengingat H-3/H-1/H0 untuk tagihan jatuh tempo ≤3 hari via
  /// channel `kaji_reminder` yang ada. Best-effort: kegagalan jadwal tak
  /// boleh merusak alur data.
  Future<void> refreshRecurringReminders({DateTime? now}) async {
    try {
      final due = recurringDueWithin(days: 3, now: now);
      for (final b in due) {
        final ref = now ?? DateTime.now();
        final dueDate = b.nextDue(ref);
        for (final h in const [3, 1, 0]) {
          await NotificationService.scheduleRecurringBillReminder(
            billId: b.id,
            name: b.name,
            amount: b.amount,
            dueDate: dueDate,
            daysBefore: h,
          );
        }
      }
    } catch (e) {
      SecureDbService.noteError('Recurring: jadwalkan pengingat gagal: $e');
    }
  }

  /// Baris teks tagihan untuk disisipkan ke digest harian oleh penjadwal
  /// (lihat digest_scheduler — orchestrator tinggal append ke body).
  /// Murni (tanpa I/O) agar bisa di-unit-test.
  List<String> recurringDigestLines(String lang, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    final lines = <String>[];
    for (final b in recurringDueWithin(days: 3, now: ref)) {
      final n = b.daysUntilDue(ref);
      final when = n == 0
          ? AppStrings.fill('recurringDueToday', lang)
          : AppStrings.fill('recurringDueIn', lang, {'n': n});
      lines.add(
        AppStrings.fill('recurringDigestLine', lang, {
          'name': b.name,
          'amount': MoneyFormat.format(b.amount),
          'when': when,
        }),
      );
    }
    return lines;
  }
}
