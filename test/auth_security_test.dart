import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/audit_service.dart';
import 'package:kaji_finance/services/auth_service.dart';
import 'package:kaji_finance/services/domain_errors.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P7: hardening autentikasi — fail-closed, hash v2, constant-time.
///
/// Catatan: tidak ada `flutter test` lokal di sesi ini (instruksi user);
/// file ini diverifikasi via `flutter analyze` + CI.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
    await AuthService.clearPin();
  });

  group('PIN v2 (Phase 7)', () {
    test('round-trip set/verify + format berversi', () async {
      await AuthService.setPin('123456');
      expect(await AuthService.isPinEnabled(), isTrue);
      final stored = await AuthService.getPin();
      expect(stored, isNotNull);
      expect(stored!.startsWith('v2:'), isTrue);
      expect(stored.contains('123456'), isFalse);
      expect(await AuthService.verifyPin('123456'), isTrue);
    });

    test('PIN salah / scope asing / kosong → false (fail-closed)', () async {
      await AuthService.setPin('123456');
      expect(await AuthService.verifyPin('654321'), isFalse);
      expect(await AuthService.verifyPin('12345'), isFalse);
      expect(await AuthService.verifyPin('1234567'), isFalse);
      expect(await AuthService.verifyPin('', scope: 'nope'), isFalse);
    });

    test('tanpa PIN tersimpan → false', () async {
      expect(await AuthService.verifyPin('123456'), isFalse);
      expect(await AuthService.getPin(), isNull);
    });

    test('clearPin menonaktifkan + verify false', () async {
      await AuthService.setPin('123456');
      await AuthService.clearPin();
      expect(await AuthService.isPinEnabled(), isFalse);
      expect(await AuthService.verifyPin('123456'), isFalse);
    });

    test('bio butuh PIN dulu (tak melemahkan model)', () async {
      expect(await AuthService.setBioEnabled(true), isFalse);
      await AuthService.setPin('123456');
      // Gerbang bio = keberadaan PIN (pemeriksaan biometrik perangkat
      // terjadi saat authenticate, bukan saat enable).
      expect(await AuthService.setBioEnabled(true), isTrue);
      expect(await AuthService.isBioEnabled(), isTrue);
    });

    test('pin_changed tercatat tanpa secret', () async {
      await AuthService.setPin('123456');
      final events = await AuditService.recent(limit: 10);
      final logged = events.where((e) => e.action == AuditAction.pinChanged);
      expect(logged, isNotEmpty);
      for (final e in logged) {
        expect(e.toString().contains('123456'), isFalse);
      }
    });
  });

  group('SecureStorageException', () {
    test('pesan aman untuk UI', () {
      const e = SecureStorageException(details: 'keystore X');
      expect(e.userMessage.isNotEmpty, isTrue);
      expect(e.userMessage.contains('keystore'), isFalse);
      expect(e, isA<KajiException>());
    });
  });
}
