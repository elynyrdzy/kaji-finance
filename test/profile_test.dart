import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/profile_model.dart';
import 'package:kaji_finance/services/profile_service.dart';

void main() {
  group('scopedProfileKey', () {
    test('default polos, profil lain ber-prefix', () {
      expect(scopedProfileKey('default', 'kaji_tx'), 'kaji_tx');
      expect(scopedProfileKey('abc123', 'kaji_tx'), 'p_abc123_kaji_tx');
      expect(profileDbFileName('default'), 'kaji_finance.db');
      expect(profileDbFileName('abc123'), 'kaji_abc123.db');
    });
  });

  group('ProfileModel', () {
    test('round-trip id/name/warna/tanggal', () {
      final p = ProfileModel(
        id: 'x1',
        name: 'Usaha',
        color: 0xFF1A4D8F,
        createdAt: DateTime(2026, 1, 2),
      );
      final back = ProfileModel.fromJson(Map<String, dynamic>.from(p.toJson()));
      expect(back.id, 'x1');
      expect(back.name, 'Usaha');
      expect(back.color, 0xFF1A4D8F);
      expect(back.createdAt, DateTime(2026, 1, 2));
      expect(back.isDefault, isFalse);
    });

    test('toJson tidak lagi menulis field kind', () {
      final p = ProfileModel(
        id: 'x1',
        name: 'Usaha',
        color: 1,
        createdAt: DateTime(2026, 1, 2),
      );
      expect(p.toJson().containsKey('kind'), isFalse);
    });

    /// REGRESI MIGRASI: profil lawas menyimpan `kind`. Penghapusan fitur
    /// perusahaan TIDAK boleh membuat profil lama gagal dimuat — field
    /// `kind` harus diabaikan, bukan digagalkan.
    test('profil lawas kind=company tetap termuat utuh (migrasi lossless)', () {
      final back = ProfileModel.fromJson({
        'id': 'legacyco',
        'name': 'Toko Saya',
        'kind': 'company',
        'color': 0xFF0E7C5B,
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(back.id, 'legacyco');
      expect(back.name, 'Toko Saya');
      expect(back.color, 0xFF0E7C5B);
      expect(back.createdAt, DateTime(2026, 1, 1));
    });

    test('profil lawas tanpa field kind tetap termuat', () {
      final back = ProfileModel.fromJson({
        'id': 'nokind',
        'name': 'Tanpa Jenis',
        'color': 5,
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(back.id, 'nokind');
      expect(back.name, 'Tanpa Jenis');
    });

    test('kind asing diabaikan, nama kosong → Profil', () {
      final back = ProfileModel.fromJson({
        'id': 'y',
        'name': '  ',
        'kind': 'alien',
        'color': 1,
        'createdAt': '2026-01-01T00:00:00.000',
      });
      expect(back.name, 'Profil');
    });

    test('id invalid tetap fail-closed (tidak dilempar jadi lolos)', () {
      expect(
        () => ProfileModel.fromJson({'id': '../etc', 'name': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('ProfileService', () {
    test('default aktif di isolat baru', () {
      expect(ProfileService.activeId, ProfileService.defaultId);
      expect(ProfileService.scoped('kaji_lang'), 'kaji_lang');
    });
  });
}
