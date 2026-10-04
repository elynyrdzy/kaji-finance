/// Allowlist ID profil (fail-closed): huruf kecil, angka, strip, 1–32.
/// Menutup traversal (`../`, `/`, absolut) ke nama file DB & kunci prefs.
/// ID `default` lolos (6 huruf). UUID baru tanpa-strip (32 hex) lolos;
/// UUID lama ber-strip (36) DITOLAK → dilewati saat load (orphan, tak dihapus).
final RegExp profileIdPattern = RegExp(r'^[a-z0-9-]{1,32}$');

/// True bila [id] lolos allowlist.
bool isValidProfileId(String id) => profileIdPattern.hasMatch(id);

/// Throw [FormatException] bila [id] tak valid (fail-closed).
void requireValidProfileId(String id) {
  if (!isValidProfileId(id)) {
    throw FormatException('invalid profile id: $id');
  }
}

/// Aturan scope kunci TUNGGAL untuk isolasi profil (dipakai prefs,
/// secure storage, dan database):
/// profil `default` memakai kunci polos (data lama tanpa migrasi),
/// profil lain memakai prefix `p_<id>_`.
String scopedProfileKey(String profileId, String key) {
  requireValidProfileId(profileId);
  return profileId == 'default' ? key : 'p_${profileId}_$key';
}

/// Nama file database per profil (default mewarisi nama lama).
/// Fail-closed: ID tak valid → throw (jangan bentuk path traversal).
String profileDbFileName(String profileId) {
  requireValidProfileId(profileId);
  return profileId == 'default' ? 'kaji_finance.db' : 'kaji_$profileId.db';
}

class ProfileModel {
  /// 'default' untuk profil bawaan (mewarisi seluruh data lama).
  final String id;
  final String name;

  /// Warna avatar (ARGB int) untuk daftar profil.
  final int color;
  final DateTime createdAt;

  const ProfileModel({
    required this.id,
    required this.name,
    required this.color,
    required this.createdAt,
  });

  bool get isDefault => id == 'default';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'createdAt': createdAt.toIso8601String(),
      };

  /// Backward compatibility: entri profil lawas menyimpan `kind`
  /// (`"personal"` / `"company"`). Field itu **sengaja diabaikan**, bukan
  /// di-error — profil lama hasil migrasi harus tetap termuat utuh.
  /// Menghapus toleransi ini akan membuat semua profil lawas orphan.
  factory ProfileModel.fromJson(Map<String, dynamic> j) {
    final rawId = j['id'];
    // R2 fail-closed: ID tak valid (traversal/tipe salah) → throw agar
    // pemanggil (ProfileService.profiles) melewati entri korup ini.
    if (rawId is! String || !isValidProfileId(rawId)) {
      throw FormatException('invalid profile id: $rawId');
    }
    return ProfileModel(
      id: rawId,
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? (j['name'] as String).trim()
          : 'Profil',
      color: (j['color'] as num?)?.toInt() ?? 0xFF1A4D8F,
      createdAt: j['createdAt'] == null
          ? DateTime.now()
          : DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now(),
    );
  }
}
