import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 standar (RFC 2898), implementasi sinkron bersama.
///
/// Dipakai backup KAJI2/KAJI3 (via `BackupService`) dan hash PIN v2 (via
/// `AuthService`) agar tidak ada duplikasi konstruksi KDF. Untuk beban
/// puluhan ribu iterasi, pemanggil WAJIB menjalankannya di isolate
/// (`compute`) supaya tak menjank UI di HP low-end.
List<int> pbkdf2HmacSha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int dkLen,
) {
  final hmac = Hmac(sha256, password);
  const hashLen = 32;
  final blocks = (dkLen + hashLen - 1) ~/ hashLen;
  final out = <int>[];
  for (var i = 1; i <= blocks; i++) {
    final blockIn = <int>[
      ...salt,
      (i >> 24) & 0xFF,
      (i >> 16) & 0xFF,
      (i >> 8) & 0xFF,
      i & 0xFF,
    ];
    var u = hmac.convert(blockIn).bytes;
    final block = List<int>.from(u);
    for (var n = 1; n < iterations; n++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < block.length; j++) {
        block[j] ^= u[j];
      }
    }
    out.addAll(block);
  }
  return out.sublist(0, dkLen);
}

/// Heksadesa lower-case tanpa prefix (format simpan hash PIN v2).
String hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
