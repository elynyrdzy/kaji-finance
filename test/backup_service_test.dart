import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/backup_service.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Entitas kini di SQLite — test memakai backend memori.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
  });

  test('exportToJson memuat semua key + meta', () async {
    SharedPreferences.setMockInitialValues({
      'kaji_account': 'Budi',
      'kaji_allowance': 3000000.0,
      'kaji_balvis': true,
      'kaji_onb': true,
    });
    final jsonStr = await BackupService.exportToJson();
    expect(jsonStr.contains('Kaji Finance'), isTrue);
    expect(jsonStr.contains('kaji_account'), isTrue);
    expect(jsonStr.contains('com.el.finance'), isTrue);
  });

  test('importFromJsonString round-trip bool/int', () async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
    const payload = '''
{"kaji_account": "Ani", "kaji_allowance": 2500000,
 "kaji_allowance_int": 0, "kaji_balvis": false,
 "kaji_tx": "[]", "_meta": {"app": "Kaji Finance"}}''';
    expect(await BackupService.importFromJsonString(payload), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kaji_account'), 'Ani');
    // P4: allowance tersimpan int.
    expect(prefs.getInt('kaji_allowance'), 2500000);
    expect(prefs.getBool('kaji_balvis'), isFalse);
    // Entitas kini di SQLite, bukan prefs — tabel tx kosong (payload "[]").
    expect(await SecureDbService.loadTable(SecureDbTables.tx), isEmpty);
    expect(prefs.containsKey('kaji_tx'), isFalse);
  });

  test('import allowance double legacy dibulatkan ke int', () async {
    SharedPreferences.setMockInitialValues({});
    expect(
      await BackupService.importFromJsonString('{"kaji_allowance": 1000000.0}'),
      isTrue,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('kaji_allowance'), 1000000);
  });

  test('import json rusak mengembalikan false', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await BackupService.importFromJsonString('bukan-json{{{'), isFalse);
    expect(await BackupService.importFromJsonString('[]'), isFalse);
  });

  test('import kunci tak dikenal saja ditolak', () async {
    SharedPreferences.setMockInitialValues({});
    expect(
      await BackupService.importFromJsonString(
        '{"aneh": 1, "_meta": {"version": "0.0.0"}}',
      ),
      isFalse,
    );
  });

  test('import versi lama (_meta beda) tetap diterima', () async {
    SharedPreferences.setMockInitialValues({});
    const payload =
        '{"kaji_account": "Lama", "_meta": {"version": "0.9.0", "app": "Kaji Finance"}}';
    expect(await BackupService.importFromJsonString(payload), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kaji_account'), 'Lama');
  });

  test('entitas backup round-trip via SQLite', () async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
    // P8: baris harus valid penuh (field wajib + tipe + tanggal).
    const payload = '{"kaji_tx": "[{\\"id\\":\\"t1\\",\\"title\\":\\"Gaji\\",'
        '\\"category\\":\\"Income\\",\\"account\\":\\"BCA\\",'
        '\\"amount\\":5000000,\\"type\\":0,'
        '\\"date\\":\\"2026-01-05T00:00:00.000\\",\\"icon\\":58144}]", '
        '"_meta": {"app": "Kaji Finance"}}';
    expect(await BackupService.importFromJsonString(payload), isTrue);
    final rows = await SecureDbService.loadTable(SecureDbTables.tx);
    expect(rows.length, 1);
    expect(rows.single['id'], 't1');
    final exported = await BackupService.exportToJson();
    expect(exported.contains('kaji_tx'), isTrue);
    expect(exported.contains('t1'), isTrue);
  });

  group('restore bertahap P8 (validasi sebelum tulis)', () {
    Future<void> seedWallet() async {
      await SecureDbService.upsertRow(SecureDbTables.wallets, {
        'id': 'w-seed',
        'name': 'Seed',
        'number': '• 0',
        'icon': 1,
        'balance': 9000,
        'initial_balance': 9000,
        'color': 1,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('kaji_account', 'Seed');
    }

    test('entitas korup struktural ditolak, data existing utuh', () async {
      SharedPreferences.setMockInitialValues({});
      await SecureDbService.useInMemory();
      await seedWallet();
      const bad =
          '{"kaji_tx": "{\\"bukan\\":\\"list\\"}", "kaji_account": "X"}';
      expect(await BackupService.importFromJsonString(bad), isFalse);
      final wallets = await SecureDbService.loadTable(SecureDbTables.wallets);
      expect(wallets.length, 1);
      expect(wallets.single['id'], 'w-seed');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('kaji_account'), 'Seed');
    });

    test('entitas tanpa baris valid ditolak, data existing utuh', () async {
      SharedPreferences.setMockInitialValues({});
      await SecureDbService.useInMemory();
      await seedWallet();
      const bad = '{"kaji_tx": "[{\\"id\\":\\"x\\",\\"title\\":\\"Rusak\\"}]"}';
      expect(await BackupService.importFromJsonString(bad), isFalse);
      final wallets = await SecureDbService.loadTable(SecureDbTables.wallets);
      expect(wallets.length, 1);
      expect(wallets.single['id'], 'w-seed');
    });

    test('referensi yatim diterima dengan peringatan', () async {
      SharedPreferences.setMockInitialValues({});
      await SecureDbService.useInMemory();
      const payload = '{"kaji_wl": "[{\\"id\\":\\"w1\\",\\"name\\":\\"BCA\\",'
          '\\"number\\":\\"• 1\\",\\"icon\\":1,\\"balance\\":1000000,'
          '\\"initial_balance\\":1000000,\\"color\\":1}]", '
          '"kaji_tx": "[{\\"id\\":\\"t1\\",\\"title\\":\\"X\\",'
          '\\"category\\":\\"Other\\",\\"account\\":\\"BCA\\",'
          '\\"amount\\":1000,\\"type\\":1,'
          '\\"date\\":\\"2026-01-05T00:00:00.000\\",\\"icon\\":1,'
          '\\"fromWalletId\\":\\"w-hantu\\"}]"}';
      expect(await BackupService.importFromJsonString(payload), isTrue);
      expect((await SecureDbService.loadTable(SecureDbTables.tx)).length, 1);
    });
  });

  group('invarian finansial backup P8 (peringatan, tak memblokir)', () {
    String txRow(
      String id,
      String account,
      int amount,
      int type, {
      String? fromId,
      String? toId,
    }) {
      final ids = [
        if (fromId != null) '"fromWalletId":"$fromId"',
        if (toId != null) '"toWalletId":"$toId"',
      ].join(',');
      return '{"id":"$id","title":"T","category":"Other",'
          '"account":"$account","amount":$amount,"type":$type,'
          '"date":"2026-01-05T00:00:00.000","icon":1'
          '${ids.isEmpty ? '' : ',$ids'}}';
    }

    String wlRow(String id, String name, int balance, int initial) =>
        '{"id":"$id","name":"$name","number":"• 1","icon":1,'
        '"balance":$balance,"initial_balance":$initial,"color":1}';

    test('konsisten → tanpa peringatan', () {
      final entities = {
        'kaji_wl': '[${wlRow('w1', 'BCA', 800000, 1000000)}]',
        'kaji_tx': '[${txRow('t1', 'BCA', 200000, 1, fromId: 'w1')}]',
        'kaji_goals': '[{"id":"g1","name":"Tab","target":1000000,'
            '"saved":300000,"icon":1,"color":1,'
            '"createdAt":"2026-01-01T00:00:00.000"}]',
      };
      expect(
        BackupService.validateBackupInvariants(
          entities,
          exportedAt: DateTime(2026, 1, 15),
        ),
        isEmpty,
      );
    });

    test('drift wallet/goal terdeteksi sebagai peringatan', () {
      final entities = {
        'kaji_wl': '[${wlRow('w1', 'BCA', 700000, 1000000)}]',
        'kaji_tx': '[${txRow('t1', 'BCA', 200000, 1, fromId: 'w1')}]',
        'kaji_goals': '[{"id":"g1","name":"Tab","target":1000000,'
            '"saved":999999,"icon":1,"color":1,'
            '"createdAt":"2026-01-01T00:00:00.000"}]',
      };
      final warnings = BackupService.validateBackupInvariants(entities);
      expect(warnings.length, 2);
      expect(warnings.any((w) => w.startsWith('wallet BCA')), isTrue);
      expect(warnings.any((w) => w.startsWith('goal Tab')), isTrue);
    });

    test('baris legacy tanpa initial_balance dilewati (bukan warning)', () {
      final entities = {
        'kaji_wl': '[{"id":"w1","name":"BCA","number":"• 1","icon":1,'
            '"balance":800000,"color":1}]',
        'kaji_tx': '[${txRow('t1', 'BCA', 200000, 1, fromId: 'w1')}]',
      };
      expect(BackupService.validateBackupInvariants(entities), isEmpty);
    });

    test('budget bulan ekspor: cocok vs drift', () {
      Map<String, String> entities(int spent) => {
            'kaji_bd': '[{"id":"b1","name":"Makan","icon":1,'
                '"spent":$spent,"budget_limit":500000}]',
            'kaji_tx': '[${txRow('t1', 'Makan', 50000, 1, fromId: 'w9')}]',
          };
      expect(
        BackupService.validateBackupInvariants(
          entities(50000),
          exportedAt: DateTime(2026, 1, 15),
        ),
        isEmpty,
      );
      final warnings = BackupService.validateBackupInvariants(
        entities(12345),
        exportedAt: DateTime(2026, 1, 15),
      );
      expect(warnings.length, 1);
      expect(warnings.single.startsWith('budget Makan'), isTrue);
    });
  });

  group('KAJI3 AES-256-GCM (Phase 6)', () {
    const plain = '{"kaji_account": "Ani", "_meta": {"app": "Kaji Finance"}}';

    test('round-trip via Async + prefix KAJI3', () async {
      final enc = await BackupService.encryptBackupAsync(plain, '123456');
      expect(enc.startsWith('KAJI3:'), isTrue);
      expect(BackupService.isEncryptedBackup(enc), isTrue);
      expect(await BackupService.decryptBackupAsync(enc, '123456'), plain);
    });

    test('password salah → null (fail-closed)', () async {
      final enc = await BackupService.encryptBackupV3(plain, '123456');
      expect(await BackupService.decryptBackupV3(enc, '654321'), isNull);
    });

    test('ciphertext diubah → null (tag menolak)', () async {
      final enc = await BackupService.encryptBackupV3(plain, '123456');
      final parts = enc.split(':');
      // parts: KAJI3, kdfId, salt, nonce, cipher, tag (prefix menempel).
      final cipherBytes = base64Decode(parts[4]);
      cipherBytes[0] = cipherBytes[0] ^ 0xFF;
      final tampered = [
        parts[0],
        parts[1],
        parts[2],
        parts[3],
        base64Encode(cipherBytes),
        parts[5],
      ].join(':');
      expect(await BackupService.decryptBackupV3(tampered, '123456'), isNull);
    });

    test('tag diubah → null', () async {
      final enc = await BackupService.encryptBackupV3(plain, '123456');
      final parts = enc.split(':');
      final tagBytes = base64Decode(parts[5]);
      tagBytes[0] = tagBytes[0] ^ 0xFF;
      final tampered = [
        parts[0],
        parts[1],
        parts[2],
        parts[3],
        parts[4],
        base64Encode(tagBytes),
      ].join(':');
      expect(await BackupService.decryptBackupV3(tampered, '123456'), isNull);
    });

    test('format korup / KDF asing → null', () async {
      expect(
        await BackupService.decryptBackupV3('KAJI3:buruk', '123456'),
        isNull,
      );
      expect(
        await BackupService.decryptBackupV3(
          'KAJI3:kdf-asing:AAAAAAAAAAAAAAAAAAAAAA:AAAAAAAAAAAAAAAA:AA:AAAAAAAAAAAAAAAAAAAAAA',
          '123456',
        ),
        isNull,
      );
      expect(
        await BackupService.decryptBackupV3('plaintext-biasa', '123456'),
        isNull,
      );
    });

    test('PIN kosong saat enkripsi → throw', () async {
      expect(
        () => BackupService.encryptBackupV3(plain, ''),
        throwsArgumentError,
      );
    });

    test('dispatch Async: KAJI3 + KAJI1/2 terdeteksi', () async {
      final enc3 = await BackupService.encryptBackupV3(plain, '123456');
      expect(await BackupService.decryptBackupAsync(enc3, '123456'), plain);
      // Legacy sinkron tetap menolak KAJI3 (jalur decrypt-only KAJI1/2).
      expect(BackupService.decryptBackup(enc3, '123456'), isNull);
      expect(BackupService.decryptBackup('KAJI2:buruk', '123456'), isNull);
    });
  });

  test('import tidak pernah mengaktifkan PIN', () async {
    SharedPreferences.setMockInitialValues({});
    const payload =
        '{"kaji_tx": "[]", "kaji_pin": "9999", "kaji_pin_enabled": true}';
    expect(await BackupService.importFromJsonString(payload), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('kaji_pin'), isFalse);
    expect(prefs.getBool('kaji_pin_enabled'), isFalse);
  });
}
