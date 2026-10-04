part of '../finance_provider.dart';

/// Mini-ledger Hutang–Piutang / Kasbon / Arisan (extension FinanceProvider).
///
/// Arsitektur (tanpa ubah schema DB):
/// - Entry tersimpan di SharedPreferences ter-scope profil via [DebtStore]
///   ([PrefsDebtStore]); SATU instance prefs di-cache statis di store.
/// - Setiap pencairan & cicilan TERTAUT ke tabel transaksi yang ada
///   (kind:debt implisit lewat [DebtLedgerLink]: tag `debt_principal` /
///   `debt_payment` + note prefix `[debt:<id>]`), sehingga:
///   bayar hutang = expense dari dompet (overdraft guard yang ada),
///   terima piutang = income ke dompet, audit_log tertulis, dan saldo
///   dompet ikut ledger seperti transaksi biasa.
/// - Rekonsiliasi pola `walletExpected`: [debtPaidFromLedger] merekonstruksi
///   Σ cicilan dari ledger; [reconcileDebts] membandingkan dengan catatan.
extension FinanceDebts on FinanceProvider {
  DebtStore get _debtStore => PrefsDebtStore();

  /// Muat entry dari store ter-scope (dipanggil layar Hutang sekali per
  /// tampil; juga aman di-retry — replace penuh in-memory).
  Future<void> loadDebts() async {
    final entries = await _debtStore.load();
    _debts
      ..clear()
      ..addAll(entries);
    _notify();
  }

  /// Tulis in-memory → store. Throw bila prefs gagal (pemanggil rollback).
  Future<void> _saveDebtsOrThrow() => _debtStore.save(_debts);

  List<DebtEntry> debtsSorted({bool settledLast = true}) {
    final list = List<DebtEntry>.from(_debts);
    list.sort((a, b) {
      if (settledLast && a.isSettled != b.isSettled) {
        return a.isSettled ? 1 : -1;
      }
      final da = a.dueAt;
      final db = b.dueAt;
      if (da != null && db != null) {
        final c = da.compareTo(db);
        if (c != 0) return c;
      } else if (da != null) {
        return -1;
      } else if (db != null) {
        return 1;
      }
      return b.createdAt.compareTo(a.createdAt);
    });
    return List.unmodifiable(list);
  }

  DebtEntry? debtById(String id) {
    for (final d in _debts) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Ringkasan: sisa hutang (saya berhutang) vs piutang (orang berhutang).
  int get totalPayableRemaining => _debts
      .where((d) => d.direction == DebtDirection.payable && !d.isSettled)
      .fold(0, (s, d) => s + d.remaining);

  int get totalReceivableRemaining => _debts
      .where((d) => d.direction == DebtDirection.receivable && !d.isSettled)
      .fold(0, (s, d) => s + d.remaining);

  int get totalPayablePrincipal => _debts
      .where((d) => d.direction == DebtDirection.payable)
      .fold(0, (s, d) => s + d.principal);

  int get totalReceivablePrincipal => _debts
      .where((d) => d.direction == DebtDirection.receivable)
      .fold(0, (s, d) => s + d.principal);

  int get overdueDebtsCount =>
      _debts.where((d) => d.isOverdue(DateTime.now())).length;

  List<DebtEntry> overdueDebts({DateTime? now}) {
    final n = now ?? DateTime.now();
    return _debts.where((d) => d.isOverdue(n)).toList();
  }

  /// Jatuh tempo dalam [days] hari ke depan (belum lunas, ada tenggat).
  List<DebtEntry> debtsDueSoon({int days = 7, DateTime? now}) {
    final n = now ?? DateTime.now();
    return _debts.where((d) {
      if (d.isSettled) return false;
      final left = d.daysUntilDue(n);
      return left != null && left >= 0 && left <= days;
    }).toList();
  }

  /// Tambah entry. Bila [wallet] diisi, pencairan awal ikut tercatat di
  /// ledger: payable (saya terima uang) → income; receivable (saya memberi
  /// pinjaman) → expense dengan overdraft guard. Return id entry / null.
  Future<String?> addDebt({
    required String counterparty,
    required DebtDirection direction,
    required DebtKind kind,
    required int amount,
    DateTime? borrowedAt,
    DateTime? dueAt,
    String? note,
    String? wallet,
    String? txTitle,
    String? txCategory,
  }) async {
    final name = counterparty.trim();
    if (name.isEmpty || amount <= 0) return null;
    if (dueAt != null &&
        borrowedAt != null &&
        dueAt.isBefore(
          DateTime(borrowedAt.year, borrowedAt.month, borrowedAt.day),
        )) {
      return null;
    }
    TransactionModel? principalTx;
    if (wallet != null && wallet.trim().isNotEmpty) {
      final w = wallet.trim();
      if (direction == DebtDirection.receivable &&
          _wouldOverdraw(
            type: TransactionType.expense,
            account: w,
            amount: amount,
          )) {
        return null;
      }
      final isPayable = direction == DebtDirection.payable;
      principalTx = TransactionModel(
        id: _uuid.v4(),
        title: txTitle ??
            (isPayable ? 'Terima hutang — $name' : 'Beri pinjaman — $name'),
        category: txCategory ?? (isPayable ? 'Hutang' : 'Piutang'),
        account: w,
        amount: amount,
        type: isPayable ? TransactionType.income : TransactionType.expense,
        date: borrowedAt ?? DateTime.now(),
        icon: Icons.handshake_outlined,
        tag: DebtLedgerLink.principalTag,
        fromWalletId: _walletIdOf(w),
      );
    }
    final snap = _takeSnapshot();
    final debtsSnap = _cloneDebts();
    final id = _uuid.v4();
    if (principalTx != null) {
      principalTx = TransactionModel(
        id: principalTx.id,
        title: principalTx.title,
        category: principalTx.category,
        account: principalTx.account,
        amount: principalTx.amount,
        type: principalTx.type,
        date: principalTx.date,
        icon: principalTx.icon,
        tag: principalTx.tag,
        note: '${DebtLedgerLink.notePrefix(id)} $name',
        fromWalletId: principalTx.fromWalletId,
        toWalletId: principalTx.toWalletId,
      );
      _transactions.add(principalTx);
      _invalidateTxCache();
      _applyWalletDeltaForTx(principalTx);
    }
    _debts.add(
      DebtEntry(
        id: id,
        counterparty: name,
        direction: direction,
        kind: kind,
        principal: amount,
        borrowedAt: borrowedAt ?? DateTime.now(),
        dueAt: dueAt,
        note: note?.trim().isEmpty == true ? null : note?.trim(),
        createdAt: DateTime.now(),
      ),
    );
    _notify();
    try {
      await _persistAtomically(
        upsertTx: principalTx,
        wl: principalTx != null,
        audit: [
          AuditService.rowFor(
            action: 'debt_created',
            entityType: 'debt',
            entityId: id,
            metadata: {
              'counterparty': name,
              'direction': direction.name,
              'kind': kind.name,
              'amount': amount,
              if (principalTx != null) 'transactionId': principalTx.id,
            },
          ),
        ],
        debugLabel: 'addDebt',
      );
      await _saveDebtsOrThrow();
    } catch (e) {
      _restoreSnapshot(snap);
      _restoreDebts(debtsSnap);
      _notify();
      AppLog.error('debt.add.failed', e);
      return null;
    }
    return id;
  }

  /// Ubah field entry (bukan riwayat bayar). Principal tak boleh di bawah
  /// total terbayar. Return false bila validasi gagal / tak ada.
  Future<bool> updateDebt(
    String id, {
    String? counterparty,
    int? principal,
    DateTime? borrowedAt,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? note,
    bool clearNote = false,
  }) async {
    final idx = _debts.indexWhere((d) => d.id == id);
    if (idx == -1) return false;
    final old = _debts[idx];
    final name = counterparty?.trim();
    if (name != null && name.isEmpty) return false;
    if (principal != null && (principal <= 0 || principal < old.paidTotal)) {
      return false;
    }
    final debtsSnap = _cloneDebts();
    _debts[idx] = old.copyWith(
      counterparty: name,
      principal: principal,
      borrowedAt: borrowedAt,
      dueAt: dueAt,
      clearDueAt: clearDueAt,
      note: note,
      clearNote: clearNote,
    );
    _notify();
    try {
      await _saveDebtsOrThrow();
      await _persistAtomically(
        audit: [
          AuditService.rowFor(
            action: 'debt_updated',
            entityType: 'debt',
            entityId: id,
            metadata: {'counterparty': _debts[idx].counterparty},
          ),
        ],
        debugLabel: 'updateDebt',
      );
    } catch (e) {
      _restoreDebts(debtsSnap);
      _notify();
      AppLog.error('debt.update.failed', e);
      return false;
    }
    return true;
  }

  /// Hapus entry. Transaksi ledger tertaut TIDAK dihapus (riwayat utuh) —
  /// di-unlink jadi income/expense biasa (tag dibuang, prefix note dibersihkan).
  /// Return jumlah tx yang di-unlink, -1 bila entry tak ada.
  Future<int> deleteDebt(String id) async {
    final idx = _debts.indexWhere((d) => d.id == id);
    if (idx == -1) return -1;
    final snap = _takeSnapshot();
    final debtsSnap = _cloneDebts();
    var unlinked = 0;
    for (var i = 0; i < _transactions.length; i++) {
      final t = _transactions[i];
      if (!DebtLedgerLink.isDebtTag(t.tag)) continue;
      if (DebtLedgerLink.debtIdOfNote(t.note) != id) continue;
      final cleanNote =
          (t.note ?? '').replaceAll(RegExp(r'\[debt:[^\]]+\]\s*'), '').trim();
      _transactions[i] = TransactionModel(
        id: t.id,
        title: t.title,
        category: t.category,
        account: t.account,
        amount: t.amount,
        type: t.type,
        date: t.date,
        icon: t.icon,
        note: cleanNote.isEmpty ? null : cleanNote,
        fromWalletId: t.fromWalletId ?? _walletIdOf(t.account),
        toWalletId: t.toWalletId,
      );
      unlinked++;
    }
    if (unlinked > 0) _invalidateTxCache();
    _debts.removeAt(idx);
    _notify();
    try {
      await _persistAtomically(
        fullTx: unlinked > 0,
        audit: [
          AuditService.rowFor(
            action: 'debt_deleted',
            entityType: 'debt',
            entityId: id,
            metadata: {'unlinked': unlinked},
          ),
        ],
        debugLabel: 'deleteDebt',
      );
      await _saveDebtsOrThrow();
    } catch (e) {
      _restoreSnapshot(snap);
      _restoreDebts(debtsSnap);
      _notify();
      AppLog.error('debt.delete.failed', e);
      return -1;
    }
    return unlinked;
  }

  /// Catat cicilan/pelunasan parsial:
  /// - payable (bayar hutang) → expense dari [wallet] (overdraft guard).
  /// - receivable (terima piutang) → income ke [wallet].
  /// Nominal dibatasi sisa ([remaining]); kelebihan dikembalikan sebagai
  /// nilai `false` + tak ada mutasi. Return true bila tercatat.
  Future<bool> recordDebtPayment({
    required String debtId,
    required int amount,
    required String wallet,
    DateTime? date,
    String? note,
    String? txTitle,
    String? txCategory,
    String? idempotencyKey,
  }) async {
    if (idempotencyKey != null && _savingsOpKeys.contains(idempotencyKey)) {
      return false;
    }
    final idx = _debts.indexWhere((d) => d.id == debtId);
    if (idx == -1) return false;
    final debt = _debts[idx];
    if (debt.isSettled || amount <= 0) return false;
    final w = wallet.trim();
    if (w.isEmpty) return false;
    final pay = amount > debt.remaining ? debt.remaining : amount;
    final isPayable = debt.direction == DebtDirection.payable;
    if (isPayable &&
        _wouldOverdraw(
          type: TransactionType.expense,
          account: w,
          amount: pay,
        )) {
      return false;
    }
    final snap = _takeSnapshot();
    final debtsSnap = _cloneDebts();
    final tx = TransactionModel(
      id: _uuid.v4(),
      title: txTitle ??
          (isPayable
              ? 'Bayar hutang — ${debt.counterparty}'
              : 'Terima piutang — ${debt.counterparty}'),
      category: txCategory ?? (isPayable ? 'Hutang' : 'Piutang'),
      account: w,
      amount: pay,
      type: isPayable ? TransactionType.expense : TransactionType.income,
      date: date ?? DateTime.now(),
      icon: Icons.handshake_outlined,
      tag: DebtLedgerLink.paymentTag,
      note: '${DebtLedgerLink.notePrefix(debtId)}'
          '${note == null || note.trim().isEmpty ? '' : ' ${note.trim()}'}',
      fromWalletId: _walletIdOf(w),
    );
    _transactions.add(tx);
    _invalidateTxCache();
    _applyWalletDeltaForTx(tx);
    _debts[idx] = debt.copyWith(
      payments: [
        ...debt.payments,
        DebtPayment(
          id: _uuid.v4(),
          debtId: debtId,
          amount: pay,
          date: date ?? DateTime.now(),
          transactionId: tx.id,
          note: note?.trim().isEmpty == true ? null : note?.trim(),
        ),
      ],
    );
    if (idempotencyKey != null) _rememberSavingsOpKey('debt:$idempotencyKey');
    _notify();
    try {
      await _persistAtomically(
        upsertTx: tx,
        wl: true,
        audit: [
          AuditService.rowFor(
            action: 'debt_payment',
            entityType: 'debt',
            entityId: debtId,
            metadata: {
              'amount': pay,
              'wallet': w,
              'transactionId': tx.id,
              'settled': _debts[idx].isSettled,
            },
          ),
        ],
        debugLabel: 'recordDebtPayment',
      );
      await _saveDebtsOrThrow();
    } catch (e) {
      _restoreSnapshot(snap);
      _restoreDebts(debtsSnap);
      _notify();
      AppLog.error('debt.payment.failed', e);
      return false;
    }
    return true;
  }

  /// Semua transaksi ledger tertaut satu entry (pencairan + cicilan),
  /// terbaru dulu.
  List<TransactionModel> transactionsForDebt(String debtId) {
    final out = _transactions.where((t) {
      if (!DebtLedgerLink.isDebtTag(t.tag)) return false;
      return DebtLedgerLink.debtIdOfNote(t.note) == debtId;
    }).toList();
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// Σ cicilan menurut LEDGER (source of truth) — pola `walletExpected`:
  /// jumlahkan transaksi bertag [DebtLedgerLink.paymentTag] untuk [debtId].
  int debtPaidFromLedger(String debtId) {
    var total = 0;
    for (final t in _transactions) {
      if (t.tag != DebtLedgerLink.paymentTag) continue;
      if (DebtLedgerLink.debtIdOfNote(t.note) != debtId) continue;
      total += t.amount;
    }
    return total;
  }

  /// Rekonsiliasi catatan vs ledger per entry (deterministik, urut by id).
  /// Mismatch = `paidTotal` catatan ≠ Σ cicilan ledger.
  List<ReconciliationMismatch> reconcileDebts() {
    final out = <ReconciliationMismatch>[];
    final sorted = List<DebtEntry>.from(_debts)
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final d in sorted) {
      final expected = debtPaidFromLedger(d.id);
      if (ReconciliationService.isClose(expected, d.paidTotal)) continue;
      out.add(
        ReconciliationMismatch(
          entityType: 'debt',
          entityId: d.id,
          entityName: d.counterparty,
          expected: expected,
          actual: d.paidTotal,
          reason: 'selisih catatan vs ledger pembayaran',
        ),
      );
    }
    return out;
  }

  /// Pengingat jatuh tempo lokal (best-effort): satu notifikasi ringkas
  /// untuk yang lewat tenggat + jatuh tempo ≤ [withinDays] hari.
  /// Dipanggil dari UI (tombol ingatkan), bukan otomatis tiap build.
  Future<void> remindDebtsDue({int withinDays = 7, String lang = 'id'}) async {
    final now = DateTime.now();
    final overdue = overdueDebts(now: now);
    final soon = debtsDueSoon(days: withinDays, now: now);
    if (overdue.isEmpty && soon.isEmpty) return;
    final lines = <String>[];
    for (final d in overdue) {
      lines.add('• ${d.counterparty} — lewat tenggat');
    }
    for (final d in soon) {
      final left = d.daysUntilDue(now) ?? 0;
      lines.add('• ${d.counterparty} — $left hari lagi');
    }
    try {
      await NotificationService.showSimple(
        lang == 'en' ? 'Debt due reminder' : 'Pengingat jatuh tempo',
        lines.join('\n'),
      );
    } catch (_) {
      // best-effort: notifikasi gagal → layar tetap menampilkan daftar.
    }
  }

  /// Bersihkan seluruh entry (hook reset data — dipanggil manual karena
  /// resetAllData milik persistence tak tersentuh fase ini).
  Future<void> clearDebts() async {
    _debts.clear();
    _notify();
    await _debtStore.clear();
  }

  List<DebtEntry> _cloneDebts() =>
      _debts.map((d) => DebtEntry.fromJson(d.toJson())).toList();

  void _restoreDebts(List<DebtEntry> snap) {
    _debts
      ..clear()
      ..addAll(snap);
  }
}
