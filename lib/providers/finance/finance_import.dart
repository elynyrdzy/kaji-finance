part of '../finance_provider.dart';

/// Hasil tahap ENKRIPSI + SQL dari impor transaksi.
class TxImportResult {
  const TxImportResult({
    required this.imported,
    required this.skippedDuplicates,
    required this.skippedInvalid,
    this.importedGoals = 0,
    this.importedWallets = 0,
  });

  /// Baris baru yang masuk ke database terenkripsi.
  final int imported;

  /// Baris dengan ID yang sudah ada (tidak diduplikat).
  final int skippedDuplicates;

  /// Baris lolos parser tapi gagal validasi akhir (nominal/judul).
  final int skippedInvalid;

  /// Target tabungan + dompet baru dari file (bukan duplikat).
  final int importedGoals;
  final int importedWallets;

  bool get isEmpty => imported == 0;
}

/// Impor transaksi: tahap ENKRIPSI + SQL dari alur
/// JSON (memori) → validasi → enkripsi + SQL.
///
/// Menerima daftar staging dari [TransactionImportService.parseStaging]
/// (murni di RAM), menggabungkan ke state (duplikat by-ID di-skip),
/// menerapkan delta dompet/goal/anggaran lewat jalur resmi yang sama
/// seperti transaksi manual, lalu menulis ke SQLite terenkripsi.
///
/// [goals]/[wallets] opsional dari envelope Backup Transaksi: yang belum
/// ada (by-ID) ditambahkan UTUH dengan saldo/tersimpan backup, dan delta
/// transaksi yang menyentuhnya dilewat agar tak dihitung ganda.
/// Yang sudah ada dilewat (saldo berjalan dipertahankan) dan delta
/// transaksi baru tetap diterapkan di atasnya.
///
/// Berbeda dari tambah manual: guard overdraft dilewat — data historis
/// dari file boleh membuat saldo negatif (fakta masa lalu, bukan aksi
/// baru yang harus ditolak).
extension FinanceImport on FinanceProvider {
  Future<TxImportResult> importTransactions(
    List<TransactionModel> staged, {
    List<SavingsGoalModel> goals = const [],
    List<WalletModel> wallets = const [],
  }) async {
    final snap = _takeSnapshot();
    final existingIds = _transactions.map((t) => t.id).toSet();
    final now = DateTime.now();
    var imported = 0;
    var dups = 0;
    var invalid = 0;
    var importedGoals = 0;
    var importedWallets = 0;

    // Dompet/goal baru-dari-backup: delta dilewat (nilai backup final).
    final skipWalletIds = <String>{};
    final skipGoalIds = <String>{};

    for (final g in goals) {
      if (_goals.any((e) => e.id == g.id)) continue;
      if (g.name.trim().isEmpty || g.target <= 0) {
        invalid++;
        continue;
      }
      final saved = g.saved >= 0 ? g.saved : 0;
      _goals.add(
        SavingsGoalModel(
          id: g.id,
          name: g.name,
          target: g.target,
          saved: saved,
          icon: g.icon,
          color: g.color,
          deadline: g.deadline,
          createdAt: g.createdAt,
        ),
      );
      skipGoalIds.add(g.id);
      importedGoals++;
    }

    final knownWalletNames = {
      for (final w in _wallets) w.name.trim().toLowerCase(),
    };
    // P3: ingat saldo file per wallet baru agar opening balance bisa
    // dihitung ledger-konsisten setelah loop (initial = file − delta staged).
    final newWalletFileBalance = <String, int>{};
    for (final w in wallets) {
      if (_wallets.any((e) => e.id == w.id)) continue;
      if (w.name.trim().isEmpty ||
          knownWalletNames.contains(w.name.trim().toLowerCase()) ||
          w.balance < 0) {
        invalid++;
        continue;
      }
      _wallets.add(w);
      knownWalletNames.add(w.name.trim().toLowerCase());
      skipWalletIds.add(w.id);
      newWalletFileBalance[w.id] = w.balance;
      importedWallets++;
    }

    final addedTxs = <TransactionModel>[];

    for (final src in staged) {
      if (existingIds.contains(src.id)) {
        dups++;
        continue;
      }
      if (src.title.trim().isEmpty ||
          src.account.trim().isEmpty ||
          src.amount <= 0) {
        invalid++;
        continue;
      }
      // Taut ulang ID dompet dari nama akun agar konsisten dengan
      // dompet di perangkat ini (ID file asing tidak berlaku di sini).
      // P3: adjustment mengandalkan arah via sisi ID — pertahankan arah
      // dari file (keberadaan ID), bukan nilai ID-nya.
      String? fromId;
      String? toId;
      if (src.type == TransactionType.adjustment) {
        final wantsCredit =
            (src.toWalletId != null && src.toWalletId!.isNotEmpty) ||
                ((src.fromWalletId == null || src.fromWalletId!.isEmpty) &&
                    (src.toWalletId == null || src.toWalletId!.isEmpty));
        if (wantsCredit) {
          toId = _walletIdOf(src.account);
        } else {
          fromId = _walletIdOf(src.account);
        }
      } else if (src.account.contains(' → ')) {
        final parts = src.account.split(' → ');
        if (parts.length == 2) {
          fromId = _walletIdOf(parts[0]);
          toId = _walletIdOf(parts[1]);
        }
      } else {
        fromId = _walletIdOf(src.account);
      }
      final tx = TransactionModel(
        id: src.id,
        title: src.title,
        category: src.category,
        account: src.account,
        amount: src.amount,
        type: src.type,
        date: src.date,
        icon: src.icon,
        tag: src.tag,
        note: src.note,
        linkedGoalId: src.linkedGoalId,
        fromWalletId: fromId,
        toWalletId: toId,
      );
      _transactions.add(tx);
      existingIds.add(tx.id);
      addedTxs.add(tx);
      _applyWalletDeltaSkipping(tx, skipWalletIds);
      if (tx.linkedGoalId == null || !skipGoalIds.contains(tx.linkedGoalId)) {
        _applyGoalDeltaForTx(tx);
      }
      if (tx.type == TransactionType.expense &&
          tx.date.year == now.year &&
          tx.date.month == now.month) {
        final bIdx = _budgets.indexWhere((b) => b.name == tx.category);
        if (bIdx != -1) {
          _budgets[bIdx] = _budgets[bIdx].copyWith(
            spent: _budgets[bIdx].spent + tx.amount,
          );
        }
      }
      imported++;
    }

    // P3: wallet baru-dari-file menyimpan saldo final backup sementara
    // delta staged-nya di-skip di memori. Agar ledger konsisten
    // (expected = initial + deltaLedger == saldo file), tetapkan
    // initial = file − Σ delta staged untuk wallet itu. Wallet lama
    // tidak disentuh (delta staged menempel pada balance berjalannya).
    if (newWalletFileBalance.isNotEmpty && addedTxs.isNotEmpty) {
      for (var i = 0; i < _wallets.length; i++) {
        final fileBalance = newWalletFileBalance[_wallets[i].id];
        if (fileBalance == null) continue;
        var stagedDelta = 0;
        for (final t in addedTxs) {
          stagedDelta += ReconciliationService.walletDeltasForTx(
                _wallets,
                t,
              )[_wallets[i].id] ??
              0;
        }
        _wallets[i] = _wallets[i].copyWith(
          initialBalance: fileBalance - stagedDelta,
        );
      }
    }

    if (imported == 0 && importedGoals == 0 && importedWallets == 0) {
      return TxImportResult(
        imported: 0,
        skippedDuplicates: dups,
        skippedInvalid: invalid,
        importedGoals: 0,
        importedWallets: 0,
      );
    }
    _invalidateTxCache();
    _notify();
    _checkBudgetAlerts();
    // Tulis bulk SEKALI dalam SATU transaksi SQLite: tx + wallets + budgets
    // + goals COMMIT bersama, ROLLBACK bersama bila gagal (Phase 2).
    AppLog.event(
      'import.started',
      data: {'imported': imported, 'goals': importedGoals},
    );
    try {
      await _persistAtomically(
        fullTx: true,
        wl: true,
        bd: true,
        goals: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.importCompleted,
            entityType: 'import',
            entityId: 'tx-import',
            metadata: {
              'imported': imported,
              'duplicates': dups,
              'invalid': invalid,
              'goals': importedGoals,
              'wallets': importedWallets,
            },
          ),
        ],
        debugLabel: 'importTransactions',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _invalidateTxCache();
      _notify();
      AppLog.error('import.failed', e);
      return TxImportResult(
        imported: 0,
        skippedDuplicates: dups,
        skippedInvalid: invalid,
        importedGoals: 0,
        importedWallets: 0,
      );
    }
    AppLog.event('import.completed', data: {'imported': imported});
    return TxImportResult(
      imported: imported,
      skippedDuplicates: dups,
      skippedInvalid: invalid,
      importedGoals: importedGoals,
      importedWallets: importedWallets,
    );
  }

  /// Varian [_applyWalletDeltaForTx] yang melewatkan dompet dalam
  /// [skipIds] (dompet baru-dari-backup yang saldonya sudah final).
  /// Sisi transfer yang tidak di-skip tetap diterapkan normal.
  void _applyWalletDeltaSkipping(TransactionModel tx, Set<String> skipIds) {
    if (skipIds.isEmpty) {
      _applyWalletDeltaForTx(tx);
      return;
    }
    String? resolveId(String name) => _walletIdOf(name);
    if (tx.type == TransactionType.expense) {
      final id = tx.fromWalletId ?? resolveId(tx.account);
      if (id == null || !skipIds.contains(id)) {
        _applyWalletDeltaForTx(tx);
      }
      return;
    }
    if (tx.type == TransactionType.income) {
      final id = tx.fromWalletId ?? resolveId(tx.account);
      if (id == null || !skipIds.contains(id)) {
        _applyWalletDeltaForTx(tx);
      }
      return;
    }
    if (tx.type == TransactionType.transfer) {
      final parts = tx.account.split(' → ');
      final fromName = parts.isNotEmpty ? parts[0] : tx.account;
      final toName = parts.length == 2 ? parts[1] : tx.account;
      final fromId = tx.fromWalletId ?? resolveId(fromName);
      final toId = tx.toWalletId ?? resolveId(toName);
      if (fromId == null || !skipIds.contains(fromId)) {
        _applyDeltaIdOrName(tx.fromWalletId, fromName, -tx.amount);
      }
      if (toId == null || !skipIds.contains(toId)) {
        _applyDeltaIdOrName(tx.toWalletId, toName, tx.amount);
      }
    }
  }
}
