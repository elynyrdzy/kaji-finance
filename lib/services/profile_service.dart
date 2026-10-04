import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/profile_model.dart';
import 'audit_service.dart';
import 'secure_db_service.dart';

/// Registry + isolasi profil akun lokal.
///
/// Semua kunci data lewat [scopedProfileKey] (lihat profile_model):
/// profil `default` polos, sisanya ber-prefix. Kunci registry di bawah
/// SENGAJA tak pernah di-scope (global).
///
/// PIN selalu dikelola AuthService (satu algoritma hash); service ini
/// hanya memverifikasi via AuthService ber-scope eksplisit dari UI.
class ProfileService {
  ProfileService._();

  static const defaultId = 'default';
  static const maxProfiles = 5;

  /// Warna avatar pilihan saat buat profil (disimpan sebagai ARGB).
  static const List<Color> avatarColors = [
    Color(0xFF1A4D8F),
    Color(0xFF0E7C5B),
    Color(0xFF8A5A00),
    Color(0xFF9C3D2E),
    Color(0xFF6C4FC4),
    Color(0xFF0077B6),
  ];

  static const _kProfiles = 'kaji_profiles';
  static const _kActive = 'kaji_active_profile';

  /// Kunci preferensi (polos) yang ikut diduplikat saat clone profil.
  /// SENGAJA tanpa kunci PIN/biometrik: profil salinan mulai tanpa kunci,
  /// dan tanpa lockout/debug (state perangkat).
  static const List<String> cloneablePrefKeys = [
    'kaji_allowance',
    'kaji_account',
    'kaji_balvis',
    'kaji_onb',
    'kaji_lang',
    'kaji_currency',
    'kaji_lock_timeout',
    'kaji_rates',
    'kaji_exp_enabled',
    'kaji_exp_flags',
    'kaji_digest_enabled',
    'kaji_digest_h',
    'kaji_digest_m',
    'kaji_digest_opt_b',
    'kaji_digest_opt_g',
    'kaji_digest_opt_w',
    'kaji_digest_opt_n',
    'kaji_budget_alert',
    'kaji_budget_notified',
  ];

  static const _uuid = Uuid();
  static const _sec = FlutterSecureStorage();

  /// Profil aktif proses ini. WAJIB diisi via [init] sebelum akses data.
  static String activeId = defaultId;

  static bool get isDefault => activeId == defaultId;

  static String scoped(String key) => scopedProfileKey(activeId, key);

  /// Muat registry + aktif; buat profil default bila belum ada.
  /// Dipanggil sekali di main() sebelum runApp.
  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      if ((await profiles()).isEmpty) {
        await _saveAll([
          ProfileModel(
            id: defaultId,
            name: 'Profil Utama',
            color: avatarColors.first.toARGB32(),
            createdAt: DateTime.now(),
          ),
        ]);
        // Sengaja tidak fail-closed di jalur ini: error sudah di-noteError,
        // dan init tetap lanjut dengan profil default in-memory agar app
        // tidak soft-lock di layar pertama.
      }
      final saved = p.getString(_kActive);
      final ids = (await profiles()).map((e) => e.id).toSet();
      activeId = (saved != null && ids.contains(saved)) ? saved : defaultId;
    } catch (_) {
      activeId = defaultId;
    }
  }

  static Future<List<ProfileModel>> profiles() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kProfiles);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final out = <ProfileModel>[];
      for (final e in list) {
        try {
          if (e is Map<String, dynamic>) {
            out.add(ProfileModel.fromJson(e));
          }
        } catch (err) {
          SecureDbService.noteError(
            'Profil: parse entri profil dilewati: $err',
          );
        }
      }
      return out;
    } catch (e) {
      SecureDbService.noteError('Profil: baca registry gagal: $e');
      return [];
    }
  }

  static Future<ProfileModel?> byId(String id) async => _byId(id);

  static Future<ProfileModel?> _byId(String id) async {
    for (final pr in await profiles()) {
      if (pr.id == id) return pr;
    }
    return null;
  }

  /// Simpan registry. Return FALSE bila gagal — pemanggil WAJIB
  /// menghormatinya (return null/false ke UI), bukan menganggap sukses.
  /// Sebelumnya error hanya dicatat (noteError) dan caller tetap menerima
  /// objek sukses, sehingga UI menampilkan profil yang tidak pernah
  /// tersimpan di disk.
  static Future<bool> _saveAll(List<ProfileModel> list) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kProfiles,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
      return true;
    } catch (e) {
      SecureDbService.noteError('Profil: simpan registry gagal: $e');
      return false;
    }
  }

  /// Buat profil baru (kosong, tanpa PIN). Return null bila nama
  /// kosong/duplikat atau kuota penuh. PIN diatur terpisah setelah
  /// beralih via sheet PIN standar (satu algoritma hash).
  static Future<ProfileModel?> create({
    required String name,
    required int color,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) return null;
    final list = await profiles();
    if (list.length >= maxProfiles) return null;
    if (list.any((e) => e.name.toLowerCase() == clean.toLowerCase())) {
      return null;
    }
    final pr = ProfileModel(
      // R2: UUID tanpa-strip = 32 hex → lolos allowlist 1–32.
      // UUID ber-strip (36) akan ditolak fromJson (fail-closed).
      id: _uuid.v4().replaceAll('-', ''),
      name: clean,
      color: color,
      createdAt: DateTime.now(),
    );
    list.add(pr);
    // Fail-closed: registry gagal tersimpan → profil tidak jadi dibuat.
    if (!await _saveAll(list)) return null;
    // P5: jejak ke scope aktif (DB profil baru belum ada saat create).
    try {
      await AuditService.log(
        action: AuditAction.profileCreated,
        entityType: 'profile',
        entityId: pr.id,
        metadata: {'name': clean},
      );
    } catch (_) {
      // best-effort: audit gagal → profil tetap jadi.
    }
    return pr;
  }

  /// Ganti nama profil. Return false bila duplikat/kosong/tak ada.
  static Future<bool> rename(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return false;
    final list = await profiles();
    final idx = list.indexWhere((e) => e.id == id);
    if (idx == -1) return false;
    if (list.any(
      (e) => e.id != id && e.name.toLowerCase() == clean.toLowerCase(),
    )) {
      return false;
    }
    list[idx] = ProfileModel(
      id: list[idx].id,
      name: clean,
      color: list[idx].color,
      createdAt: list[idx].createdAt,
    );
    // Fail-closed: return false bila registry gagal tersimpan.
    return _saveAll(list);
  }

  /// Jadikan [id] aktif. Pemanggil lalu WAJIB:
  /// SecureDbService.useProfile(id) + reload provider (lihat Settings).
  /// R2 fail-closed: ID tak valid → false tanpa menyentuh state.
  static Future<bool> setActive(String id) async {
    if (!isValidProfileId(id)) return false;
    final target = await _byId(id);
    if (target == null) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kActive, id);
    } catch (_) {
      return false;
    }
    activeId = id;
    return true;
  }

  /// Hapus profil + SELURUH datanya (DB, kunci secure, prefs ber-prefix).
  /// Profil default tak bisa dihapus; butuh ≥2 profil. Bila yang dihapus
  /// sedang aktif, aktif dipindah ke default dulu (return id pengganti).
  /// R2 fail-closed: ID tak valid → null tanpa menyentuh filesystem.
  static Future<String?> remove(String id) async {
    if (!isValidProfileId(id)) return null;
    if (id == defaultId) return null;
    final list = await profiles();
    if (!list.any((e) => e.id == id) || list.length < 2) return null;
    String? switchedTo;
    if (activeId == id) {
      await setActive(defaultId);
      switchedTo = defaultId;
    }
    // Simpan registry DULU. Bila gagal (mis. disk penuh), hapus profil
    // DIBATALKAN — data tetap utuh dan user bisa retry. Urutan sebaliknya
    // (hapus data dulu, baru registry) membuat kegagalan menyisakan
    // registry yang menunjuk ke data yang sudah hilang.
    list.removeWhere((e) => e.id == id);
    if (!await _saveAll(list)) return null;
    // Setelah registry tersimpan, hapus artefak data profil (DB, kunci
    // secure, prefs ber-prefix). Ini best-effort: kegagalan meninggalkan
    // file yatim, tidak meninggalkan registry palsu.
    await _deleteProfileData(id);
    // P5: jejak ke scope aktif pasca-switch (DB profil terhapus tak bisa
    // menyimpan trail-nya sendiri).
    try {
      await AuditService.log(
        action: AuditAction.profileDeleted,
        entityType: 'profile',
        entityId: id,
      );
    } catch (_) {
      // best-effort.
    }
    return switchedTo ?? activeId;
  }

  /// Bersihkan artefak data satu profil. Best-effort per langkah.
  /// R2 fail-closed: ID tak valid → no-op (jangan hapus file arbitrer).
  /// R3: sapu juga kunci lockout secure (failed/lockout/streak).
  static Future<void> _deleteProfileData(String id) async {
    if (!isValidProfileId(id)) return;
    String dbName;
    try {
      dbName = profileDbFileName(id);
    } on FormatException {
      return;
    }
    try {
      final dir = await getDatabasesPath();
      final f = File('$dir/$dbName');
      if (await f.exists()) await f.delete();
    } catch (_) {
      // best-effort: hapus file DB gagal → orphan dibersihkan manual (fungsi ini best-effort).
    }
    for (final k in [
      'kaji_db_key',
      'kaji_pin',
      // R3: lockout kini di secure storage — ikut dibersihkan.
      'kaji_lockout_until',
      'kaji_failed_attempts',
      'kaji_lockout_streak',
    ]) {
      try {
        await _sec.delete(key: scopedProfileKey(id, k));
      } catch (_) {
        // best-effort: hapus kunci gagal → sisa keystore dibersihkan manual.
      }
    }
    try {
      final p = await SharedPreferences.getInstance();
      final prefix = 'p_${id}_';
      final doomed = p.getKeys().where((k) => k.startsWith(prefix)).toList();
      for (final k in doomed) {
        try {
          await p.remove(k);
        } catch (_) {
          // best-effort: hapus kunci prefs gagal → sisa prefix dibersihkan manual.
        }
      }
    } catch (_) {
      // best-effort: sapu prefs gagal → sisa prefix dibersihkan manual.
    }
  }
}
