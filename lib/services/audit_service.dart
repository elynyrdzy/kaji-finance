import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'secure_db_service.dart';

/// Nama aksi audit. Superset dari daftar minimum master (created/updated/
/// deleted per domain + import/repair/migrasi agar trail utuh).
class AuditAction {
  AuditAction._();
  static const transactionCreated = 'transaction_created';
  static const transactionUpdated = 'transaction_updated';
  static const transactionDeleted = 'transaction_deleted';
  static const transactionRestored = 'transaction_restored';
  static const walletCreated = 'wallet_created';
  static const walletUpdated = 'wallet_updated';
  static const walletAdjusted = 'wallet_adjusted';
  static const walletDeleted = 'wallet_deleted';
  static const savingsDeposited = 'savings_deposited';
  static const savingsWithdrawn = 'savings_withdrawn';
  static const goalCreated = 'savings_goal_created';
  static const goalUpdated = 'savings_goal_updated';
  static const goalDeleted = 'savings_goal_deleted';
  static const budgetCreated = 'budget_created';
  static const budgetUpdated = 'budget_updated';
  static const budgetDeleted = 'budget_deleted';
  static const categoryCreated = 'category_created';
  static const categoryDeleted = 'category_deleted';
  static const transactionsCleared = 'transactions_cleared';
  static const importCompleted = 'import_completed';
  static const reconcileRepaired = 'reconcile_repaired';
  static const migrationBackfill = 'migration_backfill';
  static const backupExported = 'backup_exported';
  static const backupImported = 'backup_imported';
  static const pinChanged = 'pin_changed';
  static const securitySettingChanged = 'security_setting_changed';
  static const profileCreated = 'profile_created';
  static const profileDeleted = 'profile_deleted';
}

/// Satu baris jejak audit. Metadata disanitasi (kunci sensitif di-redact,
/// nilai dipotong) — TIDAK PERNAH berisi PIN/key/password.
class AuditEvent {
  const AuditEvent({
    required this.id,
    required this.timestamp,
    required this.action,
    required this.entityType,
    required this.entityId,
    this.metadata = const {},
  });

  final String id;
  final DateTime timestamp;
  final String action;
  final String entityType;
  final String entityId;
  final Map<String, String> metadata;

  Map<String, Object?> toRow() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'action': action,
        'entity_type': entityType,
        'entity_id': entityId,
        'metadata': jsonEncode(metadata),
      };

  static AuditEvent fromRow(Map<String, Object?> r) {
    Map<String, String> meta = const {};
    try {
      final raw = r['metadata'];
      if (raw is String && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          meta = {for (final e in decoded.entries) '${e.key}': '${e.value}'};
        }
      }
    } on Object catch (e) {
      // best-effort: metadata korup → event tetap terbaca tanpa metadata.
      AppLog.error('audit.from_row_meta_failed', e);
    }
    DateTime ts;
    try {
      ts = DateTime.parse(r['timestamp'] as String);
    } on Object catch (e) {
      AppLog.error('audit.from_row_time_failed', e);
      ts = DateTime.fromMillisecondsSinceEpoch(0);
    }
    return AuditEvent(
      id: '${r['id'] ?? ''}',
      timestamp: ts,
      action: '${r['action'] ?? ''}',
      entityType: '${r['entity_type'] ?? ''}',
      entityId: '${r['entity_id'] ?? ''}',
      metadata: meta,
    );
  }

  @override
  String toString() =>
      '${timestamp.toIso8601String()} $action $entityType/$entityId'
      '${metadata.isEmpty ? '' : ' $metadata'}';
}

/// Jejak audit lokal per profil (tabel `audit_log`, capped).
///
/// - Ditulis dalam transaksi DB yang SAMA dengan mutasi (via
///   `FinancePersistence._persistAtomically`) sehingga trail tak pernah
///   mendahului/missing dari data.
/// - Jalur non-provider (auth/backup/profil) memakai [log] standalone
///   best-effort: gagal tulis tak boleh menggagalkan operasi utama.
/// - SENGAJA tidak ikut backup (seperti sec-log): trail perangkat lokal,
///   dan agar backup tak membengkak.
class AuditService {
  AuditService._();

  static const _uuid = Uuid();

  /// Maksimum baris per profil; prune amortisasi tiap 20 tulis beraudit.
  static const maxRows = 500;
  static const _pruneEvery = 20;
  static int _writesSincePrune = 0;

  /// Bangun baris audit tersanitasi untuk ditulis dalam transaksi pemanggil.
  static Map<String, Object?> rowFor({
    required String action,
    String entityType = '',
    String entityId = '',
    Map<String, Object?> metadata = const {},
    DateTime? timestamp,
  }) {
    final safe = AppLog.sanitize(metadata);
    return AuditEvent(
      id: _uuid.v4(),
      timestamp: timestamp ?? DateTime.now(),
      action: action,
      entityType: entityType,
      entityId: entityId,
      metadata: safe,
    ).toRow();
  }

  /// Tulis satu event standalone (auth/backup/profil). Best-effort:
  /// tidak pernah throw.
  static Future<void> log({
    required String action,
    String entityType = '',
    String entityId = '',
    Map<String, Object?> metadata = const {},
  }) async {
    try {
      await SecureDbService.upsertRow(
        SecureDbTables.audit,
        rowFor(
          action: action,
          entityType: entityType,
          entityId: entityId,
          metadata: metadata,
        ),
      );
      if (claimPruneTurn()) await prune();
    } on Object catch (e) {
      SecureDbService.noteError('audit_log: $e');
      AppLog.error('audit.log_failed', e);
    }
  }

  /// Event terbaru dulu (maks [limit]). Best-effort: gagal → [].
  static Future<List<AuditEvent>> recent({int limit = 50}) async {
    try {
      final rows = await SecureDbService.loadTable(SecureDbTables.audit);
      final events = <AuditEvent>[];
      for (final r in rows) {
        try {
          events.add(AuditEvent.fromRow(r));
        } on Object catch (e) {
          AppLog.error('audit.recent_skip_row', e);
          continue;
        }
      }
      events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return events.length <= limit ? events : events.sublist(0, limit);
    } on Object catch (e) {
      SecureDbService.noteError('audit_recent: $e');
      AppLog.error('audit.recent_failed', e);
      return [];
    }
  }

  /// Klaim giliran prune (tiap [_pruneEvery] tulis beraudit).
  static bool claimPruneTurn() {
    _writesSincePrune++;
    if (_writesSincePrune >= _pruneEvery) {
      _writesSincePrune = 0;
      return true;
    }
    return false;
  }

  /// Pangkas ke [maxRows] terbaru. Best-effort, tidak pernah throw.
  static Future<void> prune({int keep = maxRows}) async {
    try {
      await SecureDbService.transaction((db) async {
        final rows = await db.load(SecureDbTables.audit);
        if (rows.length <= keep) return;
        final events = <AuditEvent>[];
        for (final r in rows) {
          try {
            events.add(AuditEvent.fromRow(r));
          } on Object catch (e) {
            AppLog.error('audit.prune_skip_row', e);
            continue;
          }
        }
        events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        for (var i = keep; i < events.length; i++) {
          await db.delete(SecureDbTables.audit, events[i].id);
        }
      }, debugLabel: 'auditPrune');
    } on Object catch (e) {
      SecureDbService.noteError('audit_prune: $e');
      AppLog.error('audit.prune_failed', e);
    }
  }
}
