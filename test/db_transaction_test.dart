import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/app_log.dart';
import 'package:kaji_finance/services/domain_errors.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
  });

  group('SecureDbService.transaction (Phase 1 fondasi)', () {
    test('commit: multi-tabel mendarat semua', () async {
      await SecureDbService.transaction((db) async {
        await db.upsert(SecureDbTables.wallets, {
          'id': 'w1',
          'name': 'BCA',
          'number': '• 1',
          'icon': 1,
          'balance': 100000.0,
          'color': 1,
        });
        await db.upsert(SecureDbTables.tx, {
          'id': 't1',
          'title': 'Gaji',
          'category': 'Income',
          'account': 'BCA',
          'amount': 50000.0,
          'type': 0,
          'date': DateTime(2026, 1, 5).toIso8601String(),
          'icon': 1,
        });
      }, debugLabel: 'test-commit');

      final wallets = await SecureDbService.loadTable(SecureDbTables.wallets);
      final tx = await SecureDbService.loadTable(SecureDbTables.tx);
      expect(wallets.length, 1);
      expect(tx.length, 1);
    });

    test('rollback: throw di tengah → tidak ada yang mendarat', () async {
      // Seed awal.
      await SecureDbService.upsertRow(SecureDbTables.wallets, {
        'id': 'w0',
        'name': 'Seed',
        'number': '• 0',
        'icon': 1,
        'balance': 9000.0,
        'color': 1,
      });

      await expectLater(
        SecureDbService.transaction((db) async {
          await db.upsert(SecureDbTables.wallets, {
            'id': 'w1',
            'name': 'BCA',
            'number': '• 1',
            'icon': 1,
            'balance': 1.0,
            'color': 1,
          });
          await db.upsert(SecureDbTables.tx, {
            'id': 't-bad',
            'title': 'X',
            'category': 'Other',
            'account': 'BCA',
            'amount': 1.0,
            'type': 0,
            'date': DateTime(2026, 1, 5).toIso8601String(),
            'icon': 1,
          });
          throw const InvalidTransactionException('sengaja gagal');
        }, debugLabel: 'test-rollback'),
        throwsA(isA<InvalidTransactionException>()),
      );

      // KajiException diteruskan apa adanya (tidak dibungkus).
      final wallets = await SecureDbService.loadTable(SecureDbTables.wallets);
      final tx = await SecureDbService.loadTable(SecureDbTables.tx);
      expect(wallets.length, 1);
      expect(wallets.single['id'], 'w0');
      expect(tx, isEmpty);
    });

    test('error generik dibungkus KajiDatabaseException', () async {
      await expectLater(
        SecureDbService.transaction((_) async {
          throw StateError('boom');
        }, debugLabel: 'test-wrap'),
        throwsA(isA<KajiDatabaseException>()),
      );
    });

    test('return value diteruskan', () async {
      final v = await SecureDbService.transaction((_) async => 42);
      expect(v, 42);
    });
  });

  group('domain_errors userMessage aman', () {
    test('semua punya pesan user non-kosong', () {
      const errs = [
        InsufficientFundsException(),
        InvalidTransactionException('input buruk'),
        BackupCorruptedException(),
        BackupAuthenticationException(),
        MigrationException('migrasi gagal'),
        ReconciliationException('mismatch'),
        SecureStorageException(),
        KajiDatabaseException('db gagal', operation: 'op'),
      ];
      for (final e in errs) {
        expect(e.userMessage.isNotEmpty, isTrue, reason: '$e');
        expect('$e'.contains('PIN'), isFalse);
      }
    });
  });

  group('AppLog sanitize', () {
    test('kunci sensitif di-redact, data biasa lolos', () {
      final out = AppLog.sanitize({
        'label': 'depositToGoal',
        'pin': '123456',
        'kaji_db_key': 'rahasia',
        'amount': 50000,
      });
      expect(out['label'], 'depositToGoal');
      expect(out['pin'], '[redacted]');
      expect(out['kaji_db_key'], '[redacted]');
      expect(out['amount'], '50000');
    });

    test('nilai panjang di-truncate', () {
      final long = 'x' * 200;
      final out = AppLog.sanitize({'note': long});
      expect(out['note']!.length, lessThanOrEqualTo(123));
      expect(out['note']!.endsWith('...'), isTrue);
    });

    test('event/error tidak throw', () {
      AppLog.event('transaction.add.started', data: {'id': 't1'});
      AppLog.error('transaction.add.failed', StateError('x'));
    });
  });
}
