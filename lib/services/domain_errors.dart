/// Typed domain errors untuk Kaji Finance.
///
/// Prinsip:
/// - Jangan `catch (_) {}` untuk operasi penting: lempar/tangani error
///   bertipe agar pemanggil bisa bedakan "saldo kurang" vs "DB rusak" vs
///   "backup dipalsukan".
/// - Pesan ke user ([userMessage]) aman & mudah dipahami (Indonesia),
///   tanpa detail teknis.
/// - Detail teknis hanya di [details] untuk debug logging, jangan tampilkan
///   PIN / key / password / data pribadi.
sealed class KajiException implements Exception {
  const KajiException(this.userMessage, {this.details});

  /// Pesan aman untuk UI.
  final String userMessage;

  /// Detail teknis untuk debug log saja (boleh null).
  final String? details;

  @override
  String toString() => '$runtimeType: $userMessage'
      '${details == null ? '' : ' ($details)'}';
}

/// Saldo dompet / goal tidak cukup untuk operasi.
class InsufficientFundsException extends KajiException {
  const InsufficientFundsException({super.details})
      : super('Saldo tidak mencukupi untuk operasi ini.');
}

/// Input transaksi / wallet / budget / goal tidak valid.
class InvalidTransactionException extends KajiException {
  const InvalidTransactionException(super.userMessage, {super.details});
}

/// File backup rusak / tidak bisa diparse / checksum tidak cocok.
class BackupCorruptedException extends KajiException {
  const BackupCorruptedException({super.details})
      : super('File backup rusak dan tidak bisa dibaca.');
}

/// Ekspor backup gagal — file TIDAK dibuat. Dipakai agar backup finansial
/// fail-closed: lebih baik tidak ada file daripada file "valid" yang
/// datanya hilang sebagian.
class BackupExportException extends KajiException {
  const BackupExportException(super.userMessage, {super.details});
}

/// Password backup salah atau tag autentikasi tidak valid.
class BackupAuthenticationException extends KajiException {
  const BackupAuthenticationException({super.details})
      : super('Password backup salah atau file telah diubah.');
}

/// Migrasi schema / data lama gagal.
class MigrationException extends KajiException {
  const MigrationException(super.userMessage, {super.details});
}

/// Rekonsiliasi ledger vs projection gagal / mismatch terdeteksi.
class ReconciliationException extends KajiException {
  const ReconciliationException(super.userMessage, {super.details});
}

/// Secure storage (Keystore/Keychain) gagal — FAIL CLOSED.
class SecureStorageException extends KajiException {
  const SecureStorageException({super.details})
      : super('Penyimpanan aman tidak tersedia. Operasi dibatalkan.');
}

/// Bungkus kegagalan database generik dengan konteks operasi.
///
/// Nama diawali `Kaji` agar tidak tabrakan dengan `DatabaseException`
/// milik sqflite (`package:sqflite_common`).
class KajiDatabaseException extends KajiException {
  const KajiDatabaseException(
    super.userMessage, {
    this.operation,
    super.details,
  });

  /// Nama operasi, mis. `db_upsert(transactions)`.
  final String? operation;
}
