part of '../../settings_screen.dart';

/// Seksi AKUN (batch 1, pindahan verbatim dari settings_screen.dart):
/// edit nama akun, uang bulanan, kelola dompet.
extension _SettingsAccountSection on _SettingsScreenState {
  /// Ubah nama profil aktif. Ini satu-satunya jalan untuk memberi nama —
  /// sebelumnya ada dua tile yang membuka dialog identik.
  void _editAccount(BuildContext context, FinanceProvider fp) {
    final lang = context.read<AppSettingsProvider>().languageCode;
    final ctrl = TextEditingController(text: fp.accountName);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('editAccount', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: TextField(
          controller: ctrl,
          style: AppTextStyles.bodyMd(),
          decoration: InputDecoration(
            hintText: AppStrings.get('accountNameHint', lang),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name =
                  ctrl.text.trim().isEmpty ? 'Kaji Finance' : ctrl.text.trim();
              try {
                await fp.setAccountName(name);
                if (!dialogCtx.mounted) return;
                Navigator.pop(dialogCtx);
              } catch (_) {
                // Gagal simpan → dialog tetap terbuka.
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppStrings.get('genericError', lang)),
                    backgroundColor: AppColors.errorContainer,
                  ),
                );
              }
            },
            child: Text(AppStrings.get('save', lang)),
          ),
        ],
      ),
    );
  }

  void _showWallets(BuildContext context, FinanceProvider fp, String lang) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.get('wallets', lang),
                style: AppTextStyles.headlineSm(),
              ),
              const SizedBox(height: 12),
              ...fp.wallets.map(
                (w) => ListTile(
                  leading: WalletAvatar(name: w.name, radius: 20),
                  title: Text(w.name, style: AppTextStyles.bodyMd()),
                  subtitle: Text(
                    '${w.number} • ${MoneyFormat.format(w.balance)}',
                    style: AppTextStyles.bodySm(),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.history, size: 18),
                        tooltip: AppStrings.get('walletHistory', lang),
                        onPressed: () =>
                            _showWalletHistory(context, fp, w, lang),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          final go = await confirmDeleteWallet(context, lang);
                          if (!go || !context.mounted) return;
                          final ok = await fp.removeWallet(w.id);
                          if (!sheetCtx.mounted) return;
                          Navigator.pop(sheetCtx);
                          if (!ok && context.mounted) {
                            // removeWallet false = masih dirujuk
                            // transaksi, bukan nama duplikat.
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  AppStrings.get('walletInUse', lang),
                                ),
                              ),
                            );
                          }
                          if (!context.mounted) return;
                          _showWallets(context, fp, lang);
                        },
                      ),
                    ],
                  ),
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    await showEditWalletDialog(context, fp, w, lang);
                    if (!context.mounted) return;
                    _showWallets(context, fp, lang);
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(AppStrings.get('addWallet', lang)),
                  onPressed: () async {
                    Navigator.pop(sheetCtx);
                    await showAddWalletDialog(context, fp, lang);
                    if (!context.mounted) return;
                    _showWallets(context, fp, lang);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Riwayat per dompet: total masuk/keluar + 8 transaksi terakhir.
  /// Transfer dihitung dari sisi dompet (from = keluar, to = masuk).
  void _showWalletHistory(
    BuildContext context,
    FinanceProvider fp,
    WalletModel w,
    String lang,
  ) {
    final txs = fp.transactions
        .where(
          (t) =>
              t.account == w.name ||
              t.fromWalletId == w.id ||
              t.toWalletId == w.id,
        )
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    var income = 0;
    var expense = 0;
    for (final t in txs) {
      // Sisi ID mencakup transfer & adjustment (P3). Fallback nama untuk
      // income/expense legacy; adjustment legacy tanpa ID diasumsikan
      // kredit (mirror ReconciliationService).
      final out = t.fromWalletId == w.id ||
          (t.type == TransactionType.expense && t.account == w.name);
      final into = t.toWalletId == w.id ||
          (t.type == TransactionType.income && t.account == w.name) ||
          (t.type == TransactionType.adjustment &&
              t.account == w.name &&
              (t.fromWalletId == null || t.fromWalletId!.isEmpty));
      if (out && !into) {
        expense += t.amount;
      } else if (into && !out) {
        income += t.amount;
      }
    }
    final tiles = <Widget>[];
    for (final t in txs.take(8)) {
      final isIn = t.type == TransactionType.income ||
          (t.type == TransactionType.transfer && t.toWalletId == w.id) ||
          (t.type == TransactionType.adjustment &&
              (t.toWalletId == w.id ||
                  ((t.fromWalletId == null || t.fromWalletId!.isEmpty) &&
                      (t.toWalletId == null || t.toWalletId!.isEmpty))));
      tiles.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(t.title, style: AppTextStyles.bodyMd()),
          subtitle: Text(
            AppDates.dateShort(t.date, lang),
            style: AppTextStyles.bodySm(),
          ),
          trailing: Text(
            MoneyFormat.signed(
              isIn ? t.amount : -t.amount,
              isIn ? 'income' : 'expense',
            ),
            style: AppTextStyles.bodyMd(),
          ),
        ),
      );
    }
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('walletHistory', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${w.name} • ${MoneyFormat.format(w.balance)}',
                  style: AppTextStyles.bodyMd().copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${AppStrings.get('incomeLabel', lang)} ${MoneyFormat.format(income)} • ${AppStrings.get('expenseLabel', lang)} ${MoneyFormat.format(expense)}',
                  style: AppTextStyles.bodySm(),
                ),
                const SizedBox(height: 12),
                if (txs.isEmpty)
                  Text(
                    AppStrings.get('noTransactions', lang),
                    style: AppTextStyles.bodySm(),
                  ),
                ...tiles,
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(AppStrings.get('close', lang)),
          ),
        ],
      ),
    );
  }

  /// Komposisi seksi AKUN & PROFIL untuk build().
  Widget _accountSection(BuildContext context, String lang) {
    final fp = context.read<FinanceProvider>();
    // Dipilih satu per satu: seksi ini hanya dibangun ulang saat salah
    // satu dari nilai ini berubah, bukan pada setiap mutasi keuangan.
    final accountName = context.select<FinanceProvider, String>(
      (f) => f.accountName,
    );
    final balanceVisible = context.select<FinanceProvider, bool>(
      (f) => f.balanceVisible,
    );
    final walletCount = context.select<FinanceProvider, int>(
      (f) => f.wallets.length,
    );
    final customCount = context.select<FinanceProvider, int>(
      (f) => f.customCategories.length,
    );
    return _section(AppStrings.get('account', lang).toUpperCase(), [
      // Sebelumnya ada DUA tile ("Primary account" dan "Profile") yang
      // membuka dialog sama persis dan menampilkan nilai sama persis
      // (fp.accountName). Sekarang hanya satu tile: Profil.
      FutureBuilder<List<ProfileModel>>(
        future: _profilesFuture,
        builder: (_, snap) {
          final list = snap.data ?? const <ProfileModel>[];
          ProfileModel? active;
          for (final pr in list) {
            if (pr.id == ProfileService.activeId) active = pr;
          }
          active ??= list.isEmpty ? null : list.first;
          return Column(
            children: [
              _tile(
                Icons.person_outline,
                active?.name ?? '…',
                '${AppStrings.get('activeProfile', lang)}'
                ' • ${list.length}',
                trailing: const Icon(
                  Icons.swap_horiz_outlined,
                  color: AppColors.tertiary,
                  size: 20,
                ),
                onTap: () => _showProfileSwitcher(context, lang),
              ),
              _tile(
                Icons.edit_outlined,
                AppStrings.get('profile', lang),
                accountName,
                onTap: () => _editAccount(context, fp),
              ),
              _tile(
                Icons.add,
                AppStrings.get('addProfile', lang),
                AppStrings.get('switchProfileDesc', lang),
                onTap: () => _createProfileDialog(context, lang),
              ),
            ],
          );
        },
      ),
      _tile(
        Icons.wallet_outlined,
        AppStrings.get('wallets', lang),
        AppStrings.fill('walletsCount', lang, {'n': walletCount}),
        onTap: () => _showWallets(context, fp, lang),
      ),
      _tile(
        Icons.visibility_outlined,
        AppStrings.get('balanceVisibility', lang),
        balanceVisible
            ? AppStrings.get('visible', lang)
            : AppStrings.get('hidden', lang),
        trailing: Switch(
          value: balanceVisible,
          activeThumbColor: AppColors.tertiary,
          onChanged: (_) => unawaited(fp.toggleBalanceVisibility()),
        ),
      ),
      _tile(
        Icons.category_outlined,
        AppStrings.get('customCategories', lang),
        AppStrings.fill('customCount', lang, {'n': customCount}),
        onTap: () => _showCategories(context, fp, lang),
      ),
    ]);
  }
}
