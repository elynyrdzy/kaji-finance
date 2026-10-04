part of '../../settings_screen.dart';

/// Perkakas DEBUG (batch 2, pindahan verbatim dari settings_screen.dart):
/// seed data contoh, reset lockout, info debug.
extension _SettingsDebugTools on _SettingsScreenState {
  /// Isi dompet, anggaran & transaksi contoh untuk pengujian alur.
  /// Melewati nama yang sudah ada agar aman diketuk berulang.
  /// Konfirmasi dulu: transaksi contoh selalu ditambah tiap eksekusi.
  Future<void> _seedSampleData(
    BuildContext context,
    FinanceProvider fp,
    String lang,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('seedDebugTitle', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: Text(
          AppStrings.get('seedDebugDesc', lang),
          style: AppTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(AppStrings.get('cancel', lang)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.tertiary,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(
              AppStrings.get('ok', lang),
              style: AppTextStyles.labelSm(color: AppColors.onTertiary),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!context.mounted) return;
    var added = 0;
    if (await fp.addWallet(
      'Dompet Utama',
      '• Utama',
      Icons.wallet,
      const Color(0xFF1A4D8F),
      5000000,
    )) {
      added++;
    }
    if (await fp.addWallet(
      'Bank',
      '• 8920',
      Icons.account_balance,
      const Color(0xFF2E7D32),
      12500000,
    )) {
      added++;
    }
    if (await fp.addBudgetCategory(
      name: 'Food & Drinks',
      limit: 3000000,
      icon: Icons.restaurant,
    )) {
      added++;
    }
    if (await fp.addBudgetCategory(
      name: 'Transport',
      limit: 1000000,
      icon: Icons.directions_car,
    )) {
      added++;
    }
    final now = DateTime.now();
    final samples = [
      (
        'Gaji Bulanan',
        'Income',
        'Bank',
        8500000,
        TransactionType.income,
        Icons.payments,
        0,
      ),
      (
        'Freelance',
        'Income',
        'Bank',
        1500000,
        TransactionType.income,
        Icons.work,
        2,
      ),
      (
        'Makan Siang',
        'Food & Drinks',
        'Dompet Utama',
        35000,
        TransactionType.expense,
        Icons.restaurant,
        0,
      ),
      (
        'Bensin',
        'Transport',
        'Dompet Utama',
        100000,
        TransactionType.expense,
        Icons.local_gas_station,
        1,
      ),
      (
        'Belanja Bulanan',
        'Shopping',
        'Dompet Utama',
        750000,
        TransactionType.expense,
        Icons.shopping_bag,
        3,
      ),
      (
        'Nonton',
        'Entertainment',
        'Dompet Utama',
        120000,
        TransactionType.expense,
        Icons.movie,
        5,
      ),
    ];
    for (final s in samples) {
      final ok = await fp.addTransaction(
        title: s.$1,
        category: s.$2,
        account: s.$3,
        amount: s.$4,
        type: s.$5,
        icon: s.$6,
        date: DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: s.$7)),
      );
      if (ok) added++;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${AppStrings.get('seedDebugDone', lang)} ($added)'),
        backgroundColor: AppColors.tertiary,
      ),
    );
  }

  /// Reset lockout brute-force PIN profil aktif — TERPROTEKSI.
  ///
  /// Wajib step-up auth (biometrik/PIN via [stepUpAuth]) dalam
  /// [AppLockGuard] + tercatat di audit. Dipicu dari seksi Keamanan
  /// (lihat `_lockoutActive`), BUKAN dari kategori Debug: recovery ini
  /// berguna justru saat user terkunci keluar, jadi harusnya terjangkau
  /// tanpa trik 8x-tap.
  Future<void> _resetPinLockout(BuildContext context, String lang) async {
    await AppLockGuard.run(() async {
      final ok = await stepUpAuth(context, lang);
      if (!context.mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.get('lockoutResetDenied', lang)),
            backgroundColor: AppColors.errorContainer,
          ),
        );
        return;
      }
      try {
        await AuthService.clearLockout();
      } on Object catch (e) {
        SecureDbService.noteError('Debug: reset lockout PIN gagal: $e');
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.get('genericError', lang)),
            backgroundColor: AppColors.errorContainer,
          ),
        );
        return;
      }
      unawaited(
        AuditService.log(
          action: AuditAction.securitySettingChanged,
          entityType: 'security',
          entityId: ProfileService.activeId,
          metadata: const {'setting': 'lockout_reset'},
        ).catchError((_) {}),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('lockoutCleared', lang)),
          backgroundColor: AppColors.tertiary,
        ),
      );
    });
  }

  /// Pratinjau isi backup JSON tanpa menulis file ke penyimpanan.
  /// exportToJson kini fail-closed (throw bila entitas gagal dibaca) —
  /// pratinjau menampilkannya sebagai error, bukan crash.
  Future<void> _showExportPreview(BuildContext context, String lang) async {
    final String jsonStr;
    try {
      jsonStr = await BackupService.exportToJson();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.get('exportPreviewFailed', lang)),
          backgroundColor: AppColors.errorContainer,
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final preview =
        jsonStr.length > 2000 ? '${jsonStr.substring(0, 2000)}…' : jsonStr;
    unawaited(
      showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('exportPreviewTitle', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                preview,
                style: AppTextStyles.bodySm().copyWith(fontSize: 10),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(AppStrings.get('ok', lang)),
            ),
          ],
        ),
      ),
    );
  }

  /// Jalankan rekonsiliasi ledger-vs-projection + tawarkan repair aman.
  /// Repair hanya menimpa projection (tak sentuh histori) + tercatat audit.
  Future<void> _showReconcile(
    BuildContext context,
    FinanceProvider fp,
    String lang,
  ) async {
    final report = await fp.reconcileAll();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final repaired = await showDialog<int>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          AppStrings.get('reconcileTitle', lang),
          style: AppTextStyles.headlineSm(),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              report.summary(),
              style: AppTextStyles.bodySm().copyWith(fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, 0),
            child: Text(AppStrings.get('close', lang)),
          ),
          if (!report.ok)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.tertiary,
              ),
              onPressed: () async {
                final n = await fp.repairProjections();
                if (!dialogCtx.mounted) return;
                Navigator.pop(dialogCtx, n);
              },
              child: Text(
                AppStrings.get('reconcileRepair', lang),
                style: AppTextStyles.labelSm(color: AppColors.onTertiary),
              ),
            ),
        ],
      ),
    );
    if (!context.mounted) return;
    if ((repaired ?? 0) > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.fill('repairDone', lang, {'n': '${repaired ?? 0}'}),
          ),
          backgroundColor: AppColors.tertiary,
        ),
      );
    }
  }

  /// Jejak audit terakhir (baca-saja).
  Future<void> _showAuditTrail(BuildContext context, String lang) async {
    final events = await AuditService.recent(limit: 30);
    if (!context.mounted) return;
    final body = events.isEmpty
        ? AppStrings.get('auditEmpty', lang)
        : events.map((e) => e.toString()).join('\n');
    unawaited(
      showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('auditTitle', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: AppTextStyles.bodySm().copyWith(fontSize: 10),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(AppStrings.get('ok', lang)),
            ),
          ],
        ),
      ),
    );
  }

  /// Redaksi error DB untuk Info Debug (R4): tanpa path file penuh / kunci,
  /// hanya 120 karakter + hash 8-char penanda korelasi log.
  /// Mencakup path Unix (/...db), Windows (C:\...db, \\...db) dan token
  /// panjang (kunci/salt/base64) yang diganti [hash:8char].
  String _redactDbError(String err) {
    var s = err.replaceAll(
      RegExp(r"/[^\s]*\.db\b", caseSensitive: false),
      '[db-path]',
    );
    s = s.replaceAll(
      RegExp(r"[A-Za-z]:\\[^\s]*\.db\b", caseSensitive: false),
      '[db-path]',
    );
    s = s.replaceAll(
      RegExp(r"\\\\[^\s]*\.db\b", caseSensitive: false),
      '[db-path]',
    );
    s = s.replaceAllMapped(RegExp(r'[A-Za-z0-9+/=_-]{24,}'), (m) {
      final v = m.group(0)!;
      final h = v.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
      return '[hash:${h.substring(0, 8)}]';
    });
    if (s.length > 120) s = '${s.substring(0, 117)}...';
    return s;
  }

  /// Ringkasan versi, platform & isi data untuk diagnosis.
  /// R4: redaksi — hash 8-char saja, tanpa path penuh/db-key.
  Future<void> _showDebugInfo(
    BuildContext context,
    FinanceProvider fp,
    AppSettingsProvider settings,
    String lang,
  ) async {
    var version = '…';
    try {
      final info = await PackageInfo.fromPlatform();
      version = 'v${info.version}+${info.buildNumber}';
    } on Object catch (_) {
      // best-effort: versi tak terbaca → tampil '…' di Info Debug.
    }
    if (!context.mounted) return;
    final secLog = await DebugService.recentEvents();
    // Status database terenkripsi: bila baris 0 padahal data pernah ada,
    // atau dbError terisi → itulah penyebab "data tereset" di perangkat.
    var dbLine = 'db=?';
    try {
      final counts = await SecureDbService.rowCounts();
      dbLine = counts.isEmpty
          ? 'db=UNREADABLE'
          : 'db: ${counts.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    } on Object catch (_) {
      dbLine = 'db=UNREADABLE';
    }
    final dbError = SecureDbService.lastError;
    if (!context.mounted) return;
    final lines = [
      'Kaji Finance $version • com.el.finance',
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'lang=$lang • currency=${settings.currencyCode}',
      'tx=${fp.transactions.length} • budgets=${fp.budgets.length} '
          '• wallets=${fp.wallets.length} • goals=${fp.savingsGoals.length} '
          '• customCat=${fp.customCategories.length}',
      dbLine,
      if (dbError != null) 'dbError=${_redactDbError(dbError)}',
      'allowance=${fp.monthlyAllowance} • onboarding=${fp.onboardingDone}',
      if (secLog.isNotEmpty) '— keamanan —',
      ...secLog,
    ];
    unawaited(
      showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: AppColors.surfaceContainer,
          title: Text(
            AppStrings.get('debugInfoTitle', lang),
            style: AppTextStyles.headlineSm(),
          ),
          content: SelectableText(
            lines.join('\n'),
            style: AppTextStyles.bodySm(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(AppStrings.get('ok', lang)),
            ),
          ],
        ),
      ),
    );
  }
}
