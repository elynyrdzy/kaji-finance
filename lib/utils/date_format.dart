import 'package:intl/intl.dart';

/// SATU-SATUNYA tempat format tanggal di Kaji Finance (§19).
///
/// Contoh id: `7 Sep 2026, 14:28`, `7 September 2026`,
/// `Senin, 7 September 2026`. Bahasa memengaruhi nama hari/bulan.
/// Selalu aman: fallback en → default bila simbol locale belum di-init
/// (mencegah LocaleDataException di device/test).
class AppDates {
  const AppDates._();

  static String _fmt(String pattern, DateTime date, String lang) {
    final code = lang == 'en' ? 'en' : 'id';
    try {
      return DateFormat(pattern, code).format(date);
    } catch (_) {
      try {
        return DateFormat(pattern, 'en').format(date);
      } catch (_) {
        return DateFormat(pattern).format(date);
      }
    }
  }

  /// `7 Sep 2026, 14:28`
  static String dateTimeShort(DateTime d, String lang) =>
      _fmt('d MMM yyyy, HH:mm', d, lang);

  /// `7 September 2026`
  static String dateLong(DateTime d, String lang) =>
      _fmt('d MMMM yyyy', d, lang);

  /// `7 Sep 2026`
  static String dateShort(DateTime d, String lang) =>
      _fmt('d MMM yyyy', d, lang);

  /// `Senin, 7 September 2026`
  static String weekdayLong(DateTime d, String lang) =>
      _fmt('EEEE, d MMMM yyyy', d, lang);

  /// `Sep 2026` / month-year title
  static String monthYear(DateTime d, String lang) =>
      _fmt('MMMM yyyy', d, lang);

  /// `Sep 2026` compact
  static String monthYearShort(DateTime d, String lang) =>
      _fmt('MMM yyyy', d, lang);

  /// Pola arbitrer dengan fallback aman (pengganti pemformatan manual
  /// DateFormat di widget — cegah LocaleDataException).
  static String pattern(String pattern, DateTime date, String lang) =>
      _fmt(pattern, date, lang);

  /// `7 Sep, 14:28` — ubin transaksi ringkas
  static String tileDate(DateTime d, String lang) =>
      _fmt('d MMM, HH:mm', d, lang);

  /// Group transaksi: Hari ini / Kemarin / tanggal penuh.
  static String dayGroup(DateTime d, String lang) {
    final now = DateTime.now();
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(d.year, d.month, d.day);
    final diff = a.difference(b).inDays;
    if (diff == 0) return lang == 'id' ? 'HARI INI' : 'TODAY';
    if (diff == 1) return lang == 'id' ? 'KEMARIN' : 'YESTERDAY';
    return _fmt('d MMMM yyyy', d, lang).toUpperCase();
  }
}
