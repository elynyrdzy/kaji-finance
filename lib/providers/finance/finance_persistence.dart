part of '../finance_provider.dart';

/// Persistensi SharedPreferences + onboarding + reset + setter ringan
/// (extension bagian FinanceProvider). Logic verbatim dari monolit (P2-a).
extension FinancePersistence on FinanceProvider {
  // Kunci preferensi ter-scope profil (default = polos, profil lain
  // ber-prefix) — isolasi data antar-profil tanpa ubah call-site.
  static String get _kAl => ProfileService.scoped('kaji_allowance');
  static String get _kAc => ProfileService.scoped('kaji_account');
  static String get _kBalVis => ProfileService.scoped('kaji_balvis');
  static String get _kOnb => ProfileService.scoped('kaji_onb');
  static String get _kNotif => ProfileService.scoped('kaji_budget_notified');

  /// Setter ringan: optimistic update → tulis → **rollback bila gagal**.
  ///
  /// Sebelumnya `notify()` lalu `_save*()` tanpa `await` dan tanpa jalur
  /// error, sehingga UI bisa menampilkan nilai yang tak pernah sampai
  /// ke disk (proses mati di tengah). Sekarang kegagalan penyimpanan
  /// mengembalikan nilai lama dan melempar error ke pemanggil.
  Future<void> _applyPref(
    void Function() mutate,
    Future<void> Function() persist, {
    required String label,
  }) async {
    final prevBalance = balanceVisible;
    final prevAllowance = monthlyAllowance;
    final prevAccount = accountName;
    mutate();
    _notify();
    try {
      await persist();
    } catch (e) {
      balanceVisible = prevBalance;
      monthlyAllowance = prevAllowance;
      accountName = prevAccount;
      _notify();
      AppLog.error('finance.$label', e);
      rethrow;
    }
  }

  Future<void> toggleBalanceVisibility() async {
    final next = !balanceVisible;
    await _applyPref(
      () => balanceVisible = next,
      () => _saveBool(_kBalVis, next),
      label: 'toggle_balance_visibility',
    );
  }

  Future<void> setMonthlyAllowance(int v) async {
    await _applyPref(
      () => monthlyAllowance = v,
      () => _saveInt(_kAl, v),
      label: 'set_monthly_allowance',
    );
  }

  Future<void> setAccountName(String v) async {
    await _applyPref(
      () => accountName = v,
      () => _saveString(_kAc, v),
      label: 'set_account_name',
    );
  }

  Future<void> completeOnboarding({
    required String name,
    required int allowance,
    required String walletName,
  }) async {
    accountName = name.trim().isEmpty ? 'Kaji Finance' : name.trim();
    monthlyAllowance = allowance;
    if (_wallets.isEmpty) {
      _wallets.add(
        WalletModel(
          id: _uuid.v4(),
          name: walletName.trim().isEmpty ? 'Dompet Utama' : walletName.trim(),
          number: '• Utama',
          icon: Icons.account_balance_wallet,
          balance: 0,
          initialBalance: 0,
          color: const Color(0xFF1A4D8F),
        ),
      );
    }
    onboardingDone = true;
    _notify();
    await _persistLists(wl: true);
    await _saveInt(_kAl, monthlyAllowance);
    await _saveString(_kAc, accountName);
    await _saveBool(_kOnb, onboardingDone);
  }

  /// Reset total ke kondisi onboarding. SINGLE SOURCE keamanan (P1-3):
  /// PIN + biometrik ikut dibersihkan di sini, bukan di UI — pemanggil
  /// masa depan tidak bisa lupa dan meninggalkan PIN aktif tanpa data.
  Future<void> resetAllData() async {
    _transactions.clear();
    _invalidateTxCache();
    _budgets.clear();
    _budgetAlertNotified.clear();
    _wallets.clear();
    _goals.clear();
    _customCategories.clear();
    monthlyAllowance = 0;
    accountName = 'Kaji Finance';
    balanceVisible = true;
    onboardingDone = false;
    _notify();
    await SecureDbService.clearAll();
    await _saveToPrefs();
    try {
      await AuthService.clearPin();
      await AuthService.setBioEnabled(false);
    } catch (e) {
      SecureDbService.noteError('Reset: bersihkan PIN gagal: $e');
    }
  }

  Future<void> clearTransactions() async {
    final snap = _takeSnapshot();
    final count = _transactions.length;
    _transactions.clear();
    _invalidateTxCache();
    for (var i = 0; i < _budgets.length; i++) {
      _budgets[i] = _budgets[i].copyWith(spent: 0);
    }
    _notify();
    try {
      await _persistAtomically(
        fullTx: true,
        bd: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.transactionsCleared,
            entityType: 'transaction',
            entityId: 'all',
            metadata: {'cleared': count},
          ),
        ],
        debugLabel: 'clearTransactions',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('transactions.clear.failed', e);
    }
  }

  Future<void> _saveBool(String key, bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, v);
    } catch (e) {
      SecureDbService.noteError('Prefs: simpan $key gagal: $e');
    }
  }

  Future<void> _saveInt(String key, int v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, v);
    } catch (e) {
      SecureDbService.noteError('Prefs: simpan $key gagal: $e');
    }
  }

  Future<void> _saveString(String key, String v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, v);
    } catch (e) {
      SecureDbService.noteError('Prefs: simpan $key gagal: $e');
    }
  }

  /// Tulis atomik multi-tabel dalam SATU transaksi SQLite via
  /// [SecureDbService.transaction] (Phase 2).
  ///
  /// - [upsertTx]/[deleteTxId]: mutasi inkremental 1 baris tx (tabel tx
  ///   tumbuh tak terbatas, jangan replace penuh per mutasi).
  /// - [fullTx]: replace penuh tabel tx (dipakai import/restore/clear).
  /// - [bd]/[wl]/[goals]/[cat]: replace penuh tabel kecil.
  /// - [audit]: baris audit (lihat [AuditService.rowFor]) yang ditulis dalam
  ///   transaksi yang SAMA (P5) — trail tak pernah missing/mendahului data.
  /// Throw bila DB gagal — pemanggil wajib rollback snapshot in-memory.
  Future<void> _persistAtomically({
    TransactionModel? upsertTx,
    String? deleteTxId,
    bool fullTx = false,
    bool bd = false,
    bool wl = false,
    bool goals = false,
    bool cat = false,
    List<Map<String, Object?>> audit = const [],
    String? debugLabel,
  }) async {
    await SecureDbService.transaction((db) async {
      if (deleteTxId != null) {
        await db.delete(SecureDbTables.tx, deleteTxId);
      }
      if (upsertTx != null) {
        await db.upsert(
          SecureDbTables.tx,
          Map<String, Object?>.from(upsertTx.toJson()),
        );
      }
      if (fullTx) {
        await db.replace(
          SecureDbTables.tx,
          _transactions
              .map((e) => Map<String, Object?>.from(e.toJson()))
              .toList(),
        );
      }
      if (bd) {
        await db.replace(
          SecureDbTables.budgets,
          _budgets.map((e) => Map<String, Object?>.from(e.toJson())).toList(),
        );
      }
      if (wl) {
        await db.replace(
          SecureDbTables.wallets,
          _wallets.map((e) => Map<String, Object?>.from(e.toJson())).toList(),
        );
      }
      if (goals) {
        await db.replace(
          SecureDbTables.goals,
          _goals.map((e) => Map<String, Object?>.from(e.toJson())).toList(),
        );
      }
      if (cat) {
        await db.replace(
          SecureDbTables.categories,
          _customCategories
              .map((e) => Map<String, Object?>.from(e.toJson()))
              .toList(),
        );
      }
      // P5: audit dalam transaksi yang sama + prune amortisasi.
      for (final row in audit) {
        await db.upsert(SecureDbTables.audit, row);
      }
      if (audit.isNotEmpty && AuditService.claimPruneTurn()) {
        final rows = await db.load(SecureDbTables.audit);
        if (rows.length > AuditService.maxRows) {
          final events = <AuditEvent>[];
          for (final r in rows) {
            try {
              events.add(AuditEvent.fromRow(r));
            } catch (_) {
              continue;
            }
          }
          events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          for (var i = AuditService.maxRows; i < events.length; i++) {
            await db.delete(SecureDbTables.audit, events[i].id);
          }
        }
      }
    }, debugLabel: debugLabel ?? 'persist');
  }

  /// Snapshot in-memory untuk rollback bila tulis DB atomik gagal.
  /// Kembalikan via [_restoreSnapshot] sebelum [_notify] ulang.
  ({
    List<TransactionModel> tx,
    List<WalletModel> wl,
    List<BudgetCategory> bd,
    List<SavingsGoalModel> goals,
    List<CategoryModel> cat,
  }) _takeSnapshot() {
    return (
      tx: List<TransactionModel>.from(_transactions),
      wl: List<WalletModel>.from(_wallets),
      bd: List<BudgetCategory>.from(_budgets),
      goals: List<SavingsGoalModel>.from(_goals),
      cat: List<CategoryModel>.from(_customCategories),
    );
  }

  void _restoreSnapshot(
    ({
      List<TransactionModel> tx,
      List<WalletModel> wl,
      List<BudgetCategory> bd,
      List<SavingsGoalModel> goals,
      List<CategoryModel> cat,
    }) s,
  ) {
    _transactions
      ..clear()
      ..addAll(s.tx);
    _wallets
      ..clear()
      ..addAll(s.wl);
    _budgets
      ..clear()
      ..addAll(s.bd);
    _goals
      ..clear()
      ..addAll(s.goals);
    _customCategories
      ..clear()
      ..addAll(s.cat);
    _invalidateTxCache();
  }

  /// Tulis sebagian state ke SQLite terenkripsi — panggil hanya dengan
  /// flag yang berubah agar setter ringan tidak menulis ulang semua
  /// tabel setiap kali.
  ///
  /// Phase 2: didelegasikan ke [_persistAtomically] sehingga multi-tabel
  /// selalu dalam SATU transaksi SQLite (bukan `Future.wait` terpisah).
  Future<void> _persistLists({
    bool tx = false,
    bool bd = false,
    bool wl = false,
    bool goals = false,
    bool cat = false,
    String? debugLabel,
  }) async {
    if (!tx && !bd && !wl && !goals && !cat) return;
    try {
      await _persistAtomically(
        fullTx: tx,
        bd: bd,
        wl: wl,
        goals: goals,
        cat: cat,
        debugLabel: debugLabel ?? 'persistLists',
      );
    } catch (e) {
      // Legacy fire-and-forget path: catat, jangan lempar agar
      // `unawaited(_persistLists(...))` lama tidak jadi unhandled error.
      // Jalur baru pakai [_persistAtomically] langsung + rollback.
      SecureDbService.noteError('db_persist: $e');
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      await _persistLists(tx: true, bd: true, wl: true, goals: true, cat: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kAl, monthlyAllowance);
      await prefs.setString(_kAc, accountName);
      await prefs.setBool(_kBalVis, balanceVisible);
      await prefs.setBool(_kOnb, onboardingDone);
    } catch (e) {
      SecureDbService.noteError('Prefs: simpan state gagal: $e');
    }
  }

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Parse per-item: satu baris korup di-skip, tidak menggugurkan semua.
      T? tryParse<T>(dynamic e, T Function(Map<String, dynamic>) f) {
        try {
          if (e is! Map<String, dynamic>) return null;
          return f(e);
        } catch (_) {
          return null;
        }
      }

      // Entitas dari SQLite terenkripsi (migrasi prefs lawas otomatis
      // di dalam SecureDbService saat tabel masih kosong).
      try {
        final rows = await SecureDbService.loadTable(SecureDbTables.tx);
        final list = <TransactionModel>[];
        for (final e in rows) {
          final v = tryParse(
            Map<String, dynamic>.from(e),
            TransactionModel.fromJson,
          );
          if (v != null) list.add(v);
        }
        _transactions.clear();
        _transactions.addAll(list);
        _invalidateTxCache();
      } catch (e) {
        SecureDbService.noteError('Prefs: muat transaksi gagal: $e');
      }
      try {
        final rows = await SecureDbService.loadTable(SecureDbTables.budgets);
        final list = <BudgetCategory>[];
        for (final e in rows) {
          final v = tryParse(
            Map<String, dynamic>.from(e),
            BudgetCategory.fromJson,
          );
          if (v != null) list.add(v);
        }
        _budgets.clear();
        _budgets.addAll(list);
      } catch (e) {
        SecureDbService.noteError('Prefs: muat anggaran gagal: $e');
      }
      try {
        final rows = await SecureDbService.loadTable(SecureDbTables.wallets);
        final list = <WalletModel>[];
        for (final e in rows) {
          final v = tryParse(
            Map<String, dynamic>.from(e),
            WalletModel.fromJson,
          );
          if (v != null) list.add(v);
        }
        _wallets.clear();
        _wallets.addAll(list);
      } catch (e) {
        SecureDbService.noteError('Prefs: muat dompet gagal: $e');
      }
      try {
        final rows = await SecureDbService.loadTable(SecureDbTables.goals);
        final list = <SavingsGoalModel>[];
        for (final e in rows) {
          final v = tryParse(
            Map<String, dynamic>.from(e),
            SavingsGoalModel.fromJson,
          );
          if (v != null) list.add(v);
        }
        _goals.clear();
        _goals.addAll(list);
      } catch (e) {
        SecureDbService.noteError('Prefs: muat goal gagal: $e');
      }
      try {
        final rows = await SecureDbService.loadTable(SecureDbTables.categories);
        final list = <CategoryModel>[];
        for (final e in rows) {
          final v = tryParse(
            Map<String, dynamic>.from(e),
            CategoryModel.fromJson,
          );
          if (v != null) list.add(v);
        }
        _customCategories.clear();
        _customCategories.addAll(list);
      } catch (e) {
        SecureDbService.noteError('Prefs: muat kategori gagal: $e');
      }
      if (prefs.containsKey(_kAl)) {
        // P4: allowance kini int; nilai double legacy dibulatkan.
        final rawAl = prefs.get(_kAl);
        if (rawAl is int) {
          monthlyAllowance = rawAl;
        } else if (rawAl is double) {
          monthlyAllowance = rawAl.round();
        } else {
          monthlyAllowance = 0;
        }
      }
      // Pulihkan level alert agar ambang yang sudah bunyi tak bunyi lagi.
      try {
        _budgetAlertNotified.clear();
        final rawNotif = prefs.getString(_kNotif);
        if (rawNotif != null && rawNotif.isNotEmpty) {
          final m = jsonDecode(rawNotif) as Map<String, dynamic>;
          for (final e in m.entries) {
            final v = (e.value as num?)?.toDouble();
            if (v != null && v.isFinite) _budgetAlertNotified[e.key] = v;
          }
        }
      } catch (_) {
        // best-effort: level notif korup → alert berbunyi ulang sekali (pulih sendiri).
      }
      if (prefs.containsKey(_kAc)) {
        accountName = prefs.getString(_kAc) ?? 'Kaji Finance';
      }
      if (prefs.containsKey(_kBalVis)) {
        balanceVisible = prefs.getBool(_kBalVis) ?? true;
      }
      onboardingDone = prefs.getBool(_kOnb) ?? false;
      if (_wallets.isNotEmpty ||
          _transactions.isNotEmpty ||
          _budgets.isNotEmpty) {
        onboardingDone = true;
      }
      // Recalc spent via 1 agregat SQL (bukan O(B×T) scan). Aman di sini:
      // memori baru dimuat DARI db yang sama, jadi tak ada risiko stale.
      if (_budgets.isNotEmpty) {
        try {
          final now = DateTime.now();
          final sums = await SecureDbService.sumExpenseByCategory(
            type: TransactionType.expense.index,
            month: now,
          );
          for (var i = 0; i < _budgets.length; i++) {
            _budgets[i] = _budgets[i].copyWith(
              spent: sums[_budgets[i].name] ?? 0,
            );
          }
        } catch (_) {
          for (var i = 0; i < _budgets.length; i++) {
            final spent = spentForBudget(
              _budgets[i].name,
              month: DateTime.now(),
            );
            _budgets[i] = _budgets[i].copyWith(spent: spent);
          }
        }
      }
      // P3: backfill opening balance sekali-jalan (idempoten via flag
      // profil) sebelum prefsLoaded=true agar invariant ledger tegak
      // sejak load pertama pasca-migrasi v2→v3.
      try {
        await backfillWalletInitialBalances();
      } catch (e) {
        SecureDbService.noteError('backfill initial gagal: $e');
      }
      // DB gagal dibuka → memori kosong BUKAN "user belum punya data"
      // (SecureDbService.openFailed). prefsLoaded TIDAK di-set di sini:
      // kalau di-set, RootShell._maybeShowOnboarding menganggap ini akun
      // baru lalu menumpuk onboarding di atas data yang belum terbaca, dan
      // flushAll() (yang early-return saat !prefsLoaded) bisa menimpa DB
      // dengan state kosong — data keuangan hilang karena kegagalan BUKA.
      if (SecureDbService.openFailed) {
        dbLoadFailed = true;
        SecureDbService.noteError(
          'load: DB tak bisa dibuka — state TIDAK dimuat (bukan akun baru)',
        );
        _notify();
        return;
      }
      prefsLoaded = true;
      _notify();
    } catch (_) {
      prefsLoaded = true;
      _notify();
    }
  }

  /// Tulis SELURUH state ke SQLite terenkripsi + prefs — dipanggil saat
  /// aplikasi ke background (lihat RootShell) agar tulis fire-and-forget
  /// yang masih terbang sempat mendarat sebelum OS mematikan proses.
  /// Tanpa ini, mutasi terakhir bisa hilang dan terlihat "tereset".
  ///
  /// PENTING: jangan flush sebelum load awal selesai ([prefsLoaded]).
  /// Saat cold start, memori masih KOSONG sementara DB berisi data —
  /// flush di jendela ini justru MENIMPA data dengan tabel kosong
  /// (race: pause mendarat sebelum _loadFromPrefs selesai).
  Future<void> flushAll() async {
    if (!prefsLoaded) return;
    try {
      await _persistLists(tx: true, bd: true, wl: true, goals: true, cat: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kAl, monthlyAllowance);
      await prefs.setString(_kAc, accountName);
      await prefs.setBool(_kBalVis, balanceVisible);
      await prefs.setBool(_kOnb, onboardingDone);
      // Level alert yang sudah ternotifikasi ikut persist agar cold start
      // berikutnya tak mengulang notifikasi ambang yang sama (anti-spam).
      await prefs.setString(_kNotif, jsonEncode(_budgetAlertNotified));
    } catch (e) {
      SecureDbService.noteError('db_flush: $e');
    }
  }

  /// Muat ulang dari SharedPreferences — dipakai setelah import backup
  /// agar UI langsung mencerminkan data baru tanpa restart app.
  Future<void> reloadFromPrefs() => _loadFromPrefs();

  Future<bool> addCustomCategory(String name, IconData icon) async {
    if (name.trim().isEmpty) return false;
    if (_customCategories.any(
      (c) => c.name.toLowerCase() == name.trim().toLowerCase(),
    )) {
      return false;
    }
    final snap = _takeSnapshot();
    _customCategories.add(
      CategoryModel(id: _uuid.v4(), name: name.trim(), icon: icon),
    );
    final catId = _customCategories.last.id;
    _notify();
    try {
      await _persistAtomically(
        cat: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.categoryCreated,
            entityType: 'category',
            entityId: catId,
            metadata: {'name': name.trim()},
          ),
        ],
        debugLabel: 'addCategory',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('category.add.failed', e);
      return false;
    }
    return true;
  }

  Future<bool> removeCustomCategory(String id) async {
    final idx = _customCategories.indexWhere((c) => c.id == id);
    if (idx == -1) return false;
    final name = _customCategories[idx].name;
    final inUse = _transactions.any(
          (t) => t.category.toLowerCase() == name.toLowerCase(),
        ) ||
        _budgets.any((b) => b.name.toLowerCase() == name.toLowerCase());
    if (inUse) return false;
    final snap = _takeSnapshot();
    _customCategories.removeAt(idx);
    _notify();
    try {
      await _persistAtomically(
        cat: true,
        audit: [
          AuditService.rowFor(
            action: AuditAction.categoryDeleted,
            entityType: 'category',
            entityId: id,
            metadata: {'name': name},
          ),
        ],
        debugLabel: 'removeCategory',
      );
    } catch (e) {
      _restoreSnapshot(snap);
      _notify();
      AppLog.error('category.remove.failed', e);
      return false;
    }
    return true;
  }
}
