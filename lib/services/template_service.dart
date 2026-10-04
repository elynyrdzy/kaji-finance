import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile_model.dart';
import 'profile_service.dart';
import 'secure_db_service.dart';

/// Satu template transaksi favorit (nominal basis IDR, ikon = codePoint).
class TxTemplate {
  final String id;
  final String title;
  final String category;
  final String account;

  /// Nominal basis IDR rupiah utuh (Phase 4).
  final int amount;
  final int type;
  final int icon;
  const TxTemplate({
    required this.id,
    required this.title,
    required this.category,
    required this.account,
    required this.amount,
    required this.type,
    required this.icon,
  });

  factory TxTemplate.create({
    required String title,
    required String category,
    required String account,
    required int amount,
    required int type,
    required int icon,
  }) =>
      TxTemplate(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        category: category,
        account: account,
        amount: amount,
        type: type,
        icon: icon,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'account': account,
        'amount': amount,
        'type': type,
        'icon': icon,
      };

  static TxTemplate? fromJson(Map<String, dynamic> j) {
    try {
      final id = '${j['id'] ?? ''}';
      final title = '${j['title'] ?? ''}';
      final category = '${j['category'] ?? ''}';
      if (id.isEmpty || title.isEmpty || category.isEmpty) return null;
      return TxTemplate(
        id: id,
        title: title,
        category: category,
        account: '${j['account'] ?? ''}',
        // P4: template lama pecahan dibulatkan ke rupiah utuh.
        amount: ((j['amount'] as num?) ?? 0).round(),
        type: ((j['type'] as num?) ?? 1).toInt().clamp(0, 2),
        icon: ((j['icon'] as num?) ?? 0).toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Template favorit per profil (maks 12, SharedPreferences ter-scope).
/// Tanpa skema DB: entri korup di-skip, bukan menggugurkan daftar.
class TemplateService {
  TemplateService._();
  static const maxTemplates = 12;

  static String _key(String profileId) =>
      scopedProfileKey(profileId, 'kaji_tx_templates');

  static Future<List<TxTemplate>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(ProfileService.activeId));
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final out = <TxTemplate>[];
      for (final e in list) {
        try {
          if (e is Map<String, dynamic>) {
            final t = TxTemplate.fromJson(e);
            if (t != null) out.add(t);
          }
        } catch (_) {
          continue;
        }
      }
      return out;
    } catch (e) {
      SecureDbService.noteError('Template: baca gagal: $e');
      return [];
    }
  }

  /// True bila tersimpan (atau duplikat persis = noop sukses).
  /// False hanya bila kuota penuh.
  static Future<bool> save(TxTemplate t) async {
    try {
      final list = await load();
      if (list.any(
        (e) =>
            e.title == t.title &&
            e.category == t.category &&
            e.account == t.account &&
            e.amount == t.amount &&
            e.type == t.type,
      )) {
        return true;
      }
      if (list.length >= maxTemplates) return false;
      list.add(t);
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key(ProfileService.activeId),
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
      return true;
    } catch (e) {
      SecureDbService.noteError('Template: simpan gagal: $e');
      return false;
    }
  }

  static Future<void> remove(String id) async {
    try {
      final list = await load();
      list.removeWhere((e) => e.id == id);
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key(ProfileService.activeId),
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      SecureDbService.noteError('Template: hapus gagal: $e');
    }
  }
}
