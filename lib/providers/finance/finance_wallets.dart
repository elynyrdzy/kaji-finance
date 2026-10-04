part of '../finance_provider.dart';

/// Dompet + delta saldo (extension bagian FinanceProvider).
///
/// P3: delta ledger didefinisikan tunggal di
/// [ReconciliationService.walletDeltasForTx]; mutasi dan rekonsiliasi
/// memakai definisi yang sama. Koreksi manual TIDAK boleh tulis balance
/// langsung — lewat adjustment event ([adjustWalletBalance]/updateWallet
/// dengan `balance`) agar ada audit trail.
extension FinanceWallets on FinanceProvider {
  int get walletTotal => _wallets.fold(0, (sum, w) => sum + w.balance);

  /// Saldo tampil: jumlahkan saldo wallet bila wallet ada (sehingga saldo
  /// awal wallet ikut terlihat), fallback ke net transaksi bila belum ada wallet.
  int get balance => _wallets.isEmpty ? netAmount : walletTotal;

  Future<bool> addWallet(
    String name,
    String number,
    IconData icon,
    Color color,
    int balance,
  ) async {
    if (name.trim().isEmpty || balance < 0) return false;
    if (_wallets.any(
      (w) => w.name.toLowerCase() == name.trim().toLowerCase(),
    )) {
      return false;
    }
    final snap = _takeSnapshot();
    final walletId = _uuid.v4();
    _wallets.add(
      WalletModel(
        id: walletId,
        name: name.trim(),
        number: number,
        icon: icon,
        balance: balance,
        // P3: opening balance = saldo awal; mutasi berikutnya hanya via ledger.
        initialBalance: balance,
        color: color,
      ),
    );
    _notify();
    try {
      await _persistAtomically(
        wl: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.walletCreated,
            entityType: 'wallet',
            entityId: walletId,
            metadata: {'name': name.trim(), 'balance': balance},
          ),
        ],
        debugLabel: 'addWallet',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('wallet.add.failed', e);
      return false;
    }
    return true;
  }

  /// Koreksi saldo manual sebagai adjustment event beraudit (P3).
  /// Membuat satu [TransactionType.adjustment] (`tag` balance_adjustment,
  /// `note` = alasan) + delta dompet, atomik + rollback bila DB gagal.
  /// Return false bila wallet tak ada / nominal invalid / DB gagal.
  Future<bool> adjustWalletBalance(
    String id,
    int newBalance, {
    String? reason,
  }) async {
    final idx = _wallets.indexWhere((w) => w.id == id);
    if (idx == -1) return false;
    if (newBalance < 0) return false;
    final old = _wallets[idx].balance;
    final diff = newBalance - old;
    if (diff == 0) return true;
    final snap = _takeSnapshot();
    AppLog.event('wallet.adjust.started', data: {'id': id});
    final w = _wallets[idx];
    final adj = TransactionModel(
      id: _uuid.v4(),
      title: BalanceAdjustment.title,
      category: BalanceAdjustment.category,
      account: w.name,
      amount: diff.abs(),
      type: TransactionType.adjustment,
      date: DateTime.now(),
      icon: Icons.tune,
      tag: BalanceAdjustment.tag,
      note: (reason == null || reason.trim().isEmpty)
          ? BalanceAdjustment.defaultReason
          : reason.trim(),
      fromWalletId: diff < 0 ? w.id : null,
      toWalletId: diff > 0 ? w.id : null,
    );
    _transactions.add(adj);
    _invalidateTxCache();
    _applyWalletDeltaForTx(adj);
    _notify();
    try {
      await _persistAtomically(
        upsertTx: adj,
        wl: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.walletAdjusted,
            entityType: 'wallet',
            entityId: id,
            metadata: {
              'oldBalance': old,
              'newBalance': newBalance,
              'adjustmentId': adj.id,
            },
          ),
        ],
        debugLabel: 'adjustWalletBalance',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('wallet.adjust.failed', e);
      return false;
    }
    AppLog.event('wallet.adjust.completed', data: {'id': id});
    return true;
  }

  Future<bool> updateWallet(
    String id, {
    String? name,
    String? number,
    IconData? icon,
    Color? color,
    int? balance,
    String? balanceReason,
  }) async {
    final idx = _wallets.indexWhere((w) => w.id == id);
    if (idx == -1) return false;
    final oldName = _wallets[idx].name;
    final newName = name?.trim();
    if (newName != null) {
      if (newName.isEmpty) return false;
      if (_wallets.any(
        (w) => w.id != id && w.name.toLowerCase() == newName.toLowerCase(),
      )) {
        return false;
      }
    }
    if (balance != null && balance < 0) return false;
    final snap = _takeSnapshot();
    _wallets[idx] = _wallets[idx].copyWith(
      name: newName,
      number: number,
      icon: icon,
      color: color,
    );
    // P3: JANGAN tulis balance langsung — koreksi manual selalu lewat
    // adjustment event agar ada audit trail di ledger.
    TransactionModel? adj;
    if (balance != null) {
      final diff = balance - _wallets[idx].balance;
      if (diff != 0) {
        final w = _wallets[idx];
        adj = TransactionModel(
          id: _uuid.v4(),
          title: BalanceAdjustment.title,
          category: BalanceAdjustment.category,
          account: w.name,
          amount: diff.abs(),
          type: TransactionType.adjustment,
          date: DateTime.now(),
          icon: Icons.tune,
          tag: BalanceAdjustment.tag,
          note: (balanceReason == null || balanceReason.trim().isEmpty)
              ? BalanceAdjustment.defaultReason
              : balanceReason.trim(),
          fromWalletId: diff < 0 ? w.id : null,
          toWalletId: diff > 0 ? w.id : null,
        );
        _transactions.add(adj);
        _invalidateTxCache();
        _applyWalletDeltaForTx(adj);
      }
    }
    // Migrasi referensi nama di transaksi agar delta dompet tidak yatim.
    // Transaksi menyimpan nama (bukan id): "Dompet" atau "A → B".
    var touched = false;
    if (newName != null && newName != oldName) {
      for (var i = 0; i < _transactions.length; i++) {
        final t = _transactions[i];
        if (t.account == oldName) {
          _transactions[i] = t.copyWith(account: newName);
          touched = true;
        } else if (t.account.contains(' → ')) {
          final parts = t.account.split(' → ');
          if (parts.length == 2 &&
              (parts[0] == oldName || parts[1] == oldName)) {
            final fixed =
                '${parts[0] == oldName ? newName : parts[0]} → ${parts[1] == oldName ? newName : parts[1]}';
            _transactions[i] = t.copyWith(account: fixed);
            touched = true;
          }
        }
      }
      if (touched) _invalidateTxCache();
    }
    _notify();
    try {
      await _persistAtomically(
        upsertTx: adj,
        wl: true,
        fullTx: touched,
        audit: [
          AuditService.rowFor(
            action: AuditAction.walletUpdated,
            entityType: 'wallet',
            entityId: id,
            metadata: {'name': _wallets[idx].name},
          ),
          if (adj != null)
            AuditService.rowFor(
              action: AuditAction.walletAdjusted,
              entityType: 'wallet',
              entityId: id,
              metadata: {
                'newBalance': _wallets[idx].balance,
                'adjustmentId': adj.id,
              },
            ),
        ],
        debugLabel: 'updateWallet',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('wallet.update.failed', e);
      return false;
    }
    return true;
  }

  /// Hapus dompet. Diblokir (return false) bila masih dirujuk transaksi
  /// agar delta saldo tidak hilang diam-diam.
  Future<bool> removeWallet(String id) async {
    final idx = _wallets.indexWhere((w) => w.id == id);
    if (idx == -1) return false;
    final name = _wallets[idx].name;
    final referenced = _transactions.any(
      (t) =>
          t.account == name ||
          (t.account.contains(' → ') && t.account.split(' → ').contains(name)),
    );
    if (referenced) return false;
    final snap = _takeSnapshot();
    _wallets.removeWhere((w) => w.id == id);
    _notify();
    try {
      await _persistAtomically(
        wl: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.walletDeleted,
            entityType: 'wallet',
            entityId: id,
            metadata: {'name': name},
          ),
        ],
        debugLabel: 'removeWallet',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('wallet.remove.failed', e);
      return false;
    }
    return true;
  }

  void _applyWalletDelta(String walletName, int delta) {
    final idx = _wallets.indexWhere((w) => w.name == walletName);
    if (idx == -1) return;
    _wallets[idx] = _wallets[idx].copyWith(
      balance: _wallets[idx].balance + delta,
    );
  }

  /// Resolve ID dompet dari nama (toleran huruf besar/kecil + trim).
  /// Null bila tidak dikenal — pemanggil fallback ke string `account`.
  String? _walletIdOf(String name) {
    final key = name.trim().toLowerCase();
    for (final w in _wallets) {
      if (w.name.trim().toLowerCase() == key) return w.id;
    }
    return null;
  }

  /// Terapkan delta via ID bila tersedia, fallback ke nama untuk data lama.
  /// Return true bila salah satu jalur berhasil (atau tidak ada wallet yang
  /// cocok — no-op seperti perilaku lama agar tidak throw).
  void _applyDeltaIdOrName(String? walletId, String walletName, int delta) {
    if (walletId != null && walletId.isNotEmpty) {
      final idx = _wallets.indexWhere((w) => w.id == walletId);
      if (idx != -1) {
        _wallets[idx] = _wallets[idx].copyWith(
          balance: _wallets[idx].balance + delta,
        );
        return;
      }
    }
    _applyWalletDelta(walletName, delta);
  }

  /// Saldo dompet sumber untuk [walletName] (ID dulu, fallback nama).
  /// Null bila dompet tidak dikenal — pemanggil mengizinkan (delta no-op,
  /// perilaku lama untuk data tanpa dompet).
  int? _sourceBalance(String walletName) {
    final id = _walletIdOf(walletName);
    if (id != null) {
      final i = _wallets.indexWhere((w) => w.id == id);
      if (i != -1) return _wallets[i].balance;
    }
    final j = _wallets.indexWhere((w) => w.name == walletName);
    if (j != -1) return _wallets[j].balance;
    return null;
  }

  /// True bila transaksi akan membuat dompet sumber negatif (overdraft).
  /// Expense memakai [account] sebagai sumber; transfer memakai sisi kiri
  /// "A → B". Income tidak pernah overdraft. Dompet tak dikenal → false.
  bool _wouldOverdraw({
    required TransactionType type,
    required String account,
    required int amount,
  }) {
    if (amount <= 0) return false;
    if (type != TransactionType.expense && type != TransactionType.transfer) {
      return false;
    }
    final fromName =
        account.contains(' → ') ? account.split(' → ').first : account;
    final bal = _sourceBalance(fromName);
    return bal != null && bal < amount;
  }

  /// Kembalikan delta ledger satu [tx] (negasi persis dari apply).
  /// P3: didelegasikan ke definisi tunggal
  /// [ReconciliationService.walletDeltasForTx] agar mutasi dan
  /// rekonsiliasi tidak pernah divergen.
  void _revertWalletDeltaForTx(TransactionModel tx) {
    final deltas = ReconciliationService.walletDeltasForTx(_wallets, tx);
    if (deltas.isEmpty) return;
    for (var i = 0; i < _wallets.length; i++) {
      final d = deltas[_wallets[i].id];
      if (d != null && d != 0) {
        _wallets[i] = _wallets[i].copyWith(balance: _wallets[i].balance - d);
      }
    }
  }

  /// Terapkan delta ledger satu [tx] ke wallet yang cocok.
  /// P3: termasuk [TransactionType.adjustment] (kredit/debit via sisi ID
  /// yang terisi). Definisi tunggal di ReconciliationService.
  void _applyWalletDeltaForTx(TransactionModel tx) {
    final deltas = ReconciliationService.walletDeltasForTx(_wallets, tx);
    if (deltas.isEmpty) return;
    for (var i = 0; i < _wallets.length; i++) {
      final d = deltas[_wallets[i].id];
      if (d != null && d != 0) {
        _wallets[i] = _wallets[i].copyWith(balance: _wallets[i].balance + d);
      }
    }
  }
}
