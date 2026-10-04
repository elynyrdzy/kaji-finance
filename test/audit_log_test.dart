import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/audit_service.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P5: jejak audit operasi penting.
///
/// Catatan: tidak ada `flutter test` lokal di sesi ini (instruksi user);
/// file ini diverifikasi via `flutter analyze` + CI.
Future<FinanceProvider> freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

void main() {
  group('Audit trail (Phase 5)', () {
    test(
      'addTransaction mencatat transaction_created dalam txn yang sama',
      () async {
        final fp = await freshProvider();
        expect(
          await fp.addTransaction(
            title: 'Gaji',
            category: 'Income',
            account: 'BCA',
            amount: 1000000,
            type: TransactionType.income,
            icon: Icons.payments,
          ),
          isTrue,
        );
        final events = await AuditService.recent(limit: 10);
        expect(
          events.any(
            (e) =>
                e.action == AuditAction.transactionCreated &&
                e.entityType == 'transaction',
          ),
          isTrue,
        );
        final created = events.firstWhere(
          (e) => e.action == AuditAction.transactionCreated,
        );
        expect(created.metadata['amount'], '1000000');
        expect(created.metadata['type'], 'income');
      },
    );

    test(
      'adjustWalletBalance mencatat wallet_adjusted + reconcile ok',
      () async {
        final fp = await freshProvider();
        expect(
          await fp.addWallet(
            'BCA',
            '• 1',
            Icons.account_balance,
            const Color(0xFF1A4D8F),
            1000000,
          ),
          isTrue,
        );
        final id = fp.wallets.single.id;
        expect(await fp.adjustWalletBalance(id, 1025000), isTrue);
        final events = await AuditService.recent(limit: 10);
        expect(
          events.any(
            (e) => e.action == AuditAction.walletAdjusted && e.entityId == id,
          ),
          isTrue,
        );
        expect((await fp.reconcileAll()).ok, isTrue);
      },
    );

    test('repair mencatat reconcile_repaired', () async {
      final fp = await freshProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 1',
          Icons.account_balance,
          const Color(0xFF1A4D8F),
          1000000,
        ),
        isTrue,
      );
      expect(
        await fp.addTransaction(
          title: 'Gaji',
          category: 'Income',
          account: 'BCA',
          amount: 500000,
          type: TransactionType.income,
          icon: Icons.payments,
        ),
        isTrue,
      );
      // Simulasi divergensi level DB.
      final row = Map<String, Object?>.from(fp.wallets.single.toJson());
      row['balance'] = 1400000;
      await SecureDbService.upsertRow(SecureDbTables.wallets, row);
      await fp.reloadFromPrefs();
      expect((await fp.reconcileAll()).ok, isFalse);
      expect(await fp.repairProjections(), 1);
      final events = await AuditService.recent(limit: 10);
      expect(
        events.any((e) => e.action == AuditAction.reconcileRepaired),
        isTrue,
      );
    });

    test('metadata sensitif di-redact, tak ada secret', () async {
      await SecureDbService.useInMemory();
      await AuditService.log(
        action: AuditAction.pinChanged,
        entityType: 'security',
        entityId: 'default',
        metadata: {'pin': '123456', 'note': 'ok'},
      );
      final events = await AuditService.recent(limit: 5);
      final logged = events.firstWhere(
        (e) => e.action == AuditAction.pinChanged,
      );
      expect(logged.metadata['pin'], '[redacted]');
      expect(logged.toString().contains('123456'), isFalse);
    });

    test('AuditEvent.fromRow toleran baris korup', () {
      final e = AuditEvent.fromRow({
        'id': 'a1',
        'timestamp': 'bukan-tanggal',
        'action': 'x',
        'entity_type': 'y',
        'entity_id': 'z',
        'metadata': 'bukan-json{{{',
      });
      expect(e.id, 'a1');
      expect(e.metadata, isEmpty);
    });
  });
}
