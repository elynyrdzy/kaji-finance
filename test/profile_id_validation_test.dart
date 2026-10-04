import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/profile_model.dart';

/// R2: allowlist profileId `^[a-z0-9-]{1,32}$`, fail-closed.
void main() {
  group('isValidProfileId', () {
    test('menerima default + id sehat', () {
      expect(isValidProfileId('default'), isTrue);
      expect(isValidProfileId('abc123'), isTrue);
      expect(isValidProfileId('a'), isTrue);
      expect(isValidProfileId('x' * 32), isTrue);
      expect(isValidProfileId('a-b-c-1'), isTrue);
    });

    test('menolak traversal + absolut + karakter liar', () {
      for (final bad in [
        '../evil',
        '..',
        '/',
        '/abs/path',
        'a/b',
        'a\\b',
        '',
        'x' * 33,
        'ABC',
        'a b',
        'a_b',
        'a.b',
        '550e8400-e29b-41d4-a716-446655440000', // uuid 36 ber-strip
      ]) {
        expect(isValidProfileId(bad), isFalse, reason: bad);
      }
    });
  });

  group('ProfileModel.fromJson fail-closed', () {
    test('id traversal melempar FormatException', () {
      for (final bad in ['../evil', '/abs', 'a/b', '']) {
        expect(
          () => ProfileModel.fromJson({
            'id': bad,
            'name': 'X',
            'kind': 'personal',
            'color': 1,
            'createdAt': '2026-01-01T00:00:00.000',
          }),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('id valid lolos', () {
      final p = ProfileModel.fromJson({
        'id': 'abc-123',
        'name': 'Usaha',
        'kind': 'company',
        'color': 1,
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(p.id, 'abc-123');
    });
  });

  group('profileDbFileName fail-closed', () {
    test('default + id sehat', () {
      expect(profileDbFileName('default'), 'kaji_finance.db');
      expect(profileDbFileName('abc123'), 'kaji_abc123.db');
    });

    test('traversal melempar (tak bentuk path)', () {
      for (final bad in ['../evil', '/abs', 'a/b', 'x' * 33]) {
        expect(
          () => profileDbFileName(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('scopedProfileKey fail-closed', () {
    test('traversal melempar', () {
      expect(
        () => scopedProfileKey('../evil', 'kaji_tx'),
        throwsFormatException,
      );
      expect(scopedProfileKey('default', 'kaji_tx'), 'kaji_tx');
    });
  });
}
