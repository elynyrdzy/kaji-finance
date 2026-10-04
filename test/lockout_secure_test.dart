import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/auth_service.dart';
import 'package:kaji_finance/services/domain_errors.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R3: lockout di flutter_secure_storage, fail-closed bila baca gagal.
///
/// Catatan: di `flutter test` backend secure storage tak dijamin ada;
/// implementasi menangkap kegagalan platform dan fail-closed (terkunci),
/// sehingga asersi di bawah deterministik di semua lingkungan.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SecureDbService.useInMemory();
  });

  group('durasi backoff satu sumber kebenaran', () {
    test('streak 0/1/2 -> 30/60/300, jenuh di 300', () {
      expect(AuthService.lockoutSecondsForStreak(0), 30);
      expect(AuthService.lockoutSecondsForStreak(1), 60);
      expect(AuthService.lockoutSecondsForStreak(2), 300);
      expect(AuthService.lockoutSecondsForStreak(99), 300);
      expect(AuthService.maxPinAttempts, 5);
    });
  });

  group('fail-closed scope tak valid', () {
    test('loadLockout scope traversal -> terkunci', () async {
      final s = await AuthService.loadLockout(scope: '../evil');
      expect(s.failed, AuthService.maxPinAttempts);
      expect(s.untilMs, greaterThan(0));
    });

    test('saveLockout scope traversal -> throw', () async {
      expect(
        () => AuthService.saveLockout(
          untilMs: 0,
          failed: 0,
          streak: 0,
          scope: '/abs',
        ),
        throwsA(isA<SecureStorageException>()),
      );
    });

    test('clearLockout scope traversal -> no-throw no-op', () async {
      await AuthService.clearLockout(scope: 'a/b');
    });

    test('clearLockout scope default -> tak pernah throw', () async {
      await AuthService.clearLockout();
    });
  });
}
