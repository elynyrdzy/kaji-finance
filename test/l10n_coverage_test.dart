import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/l10n/app_strings.dart';

/// Kunci l10n yang **sengaja** tidak dirujuk langsung di kode.
///
/// Hampir semua kunci harus muncul sebagai literal pertama pada
/// `AppStrings.get('<key>')` / `AppStrings.fill('<key>')`. Kunci di bawah
/// ini sudah dihapus dari UI, atau memang tidak pernah dipakai dan
/// sengaja disimpan untuk dipakai ulang (mis. pesan error yang selama ini
/// belum ada tempatnya).
const Set<String> _allowUnused = {
  // Belum ada tempat di UI saat ini; sengaja disimpan untuk
  // komponen dialog/error berikutnya.
  'loadError',
  'pinHint',
  'pinMust46',
  'version',
};

/// Kunci yang dirujuk secara DINAMIS (bukan literal), jadi tidak bisa
/// ditemukan oleh pencarian string biasa.
const Set<String> _dynamicRefs = {
  'week',
  'month',
  'quarter',
  'year',
  'templateSaved',
  'templateFull',
  'filterFrom',
  'filterTo',
  'debtDueAt',
  'debtBorrowedAt',
  'debugUnlocked',
  'debugLocked',
  'transactions',
  'wallets',
  'categoryBudgets',
  'savingsGoals',
  'customCategories',
  'profileCantDeleteLast',
};

void main() {
  group('AppStrings', () {
    test('setiap kunci punya terjemahan di id dan en', () {
      // Dijaga oleh app_strings_test.dart; di sini cukup memastikan
      // allowlist di atas benar-benar ada (salah ketik = test gagal).
      for (final k in _allowUnused) {
        expect(
          AppStrings.get(k, 'id'),
          isNot(k),
          reason: 'kunci allowlist "$k" tidak ada di app_strings.dart',
        );
      }
    });

    test('tidak ada kunci mati yang tak diizinkan', () {
      final source = _collectSource();
      final unused = <String>[];
      for (final key in AppStrings.allKeys) {
        if (_allowUnused.contains(key) || _dynamicRefs.contains(key)) continue;
        if (!source.contains("'$key'")) unused.add(key);
      }
      expect(
        unused,
        isEmpty,
        reason: 'Kunci l10n berikut tidak pernah dirujuk di lib/ atau '
            'test/. Tambahkan ke _allowUnused bila memang sengaja, '
            'atau hapus dari app_strings.dart.\n'
            'Ditemukan ${unused.length}: ${unused.join(', ')}',
      );
    });
  });
}

/// Gabungkan seluruh sumber Dart di lib/ + test/ agar pencarian kunci
/// menangkap pemakaian multi-baris (mis. `AppStrings.fill(\n  'key',`).
String _collectSource() {
  final buffer = StringBuffer();
  for (final dir in ['lib', 'test', 'tool']) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('app_strings.dart')) continue;
      buffer.writeln(f.readAsStringSync());
    }
  }
  return buffer.toString();
}
