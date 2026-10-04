import 'package:intl/intl.dart';

import '../services/money.dart';

/// SATU-SATUNYA tempat format uang di Kaji Finance.
///
/// Aturan (§13–§17 + P3-kurs, Phase 4):
/// - Penyimpanan SELALU integer rupiah ([Money.minorUnits]). Seluruh API di
///   sini menerima/mengembalikan `int` — tidak ada `double` otoritatif.
/// - `toBaseMinorUnits` adalah SATU-SATUNYA titik pembulatan tampil→simpan
///   (delegasi ke [Money.roundBase]); aritmetika ledger eksak.
/// - IDR default: `Rp 12.450.000` (titik ribuan, spasi setelah Rp, 0 desimal).
/// - Nol: `Rp 0` (tanpa `,00`).
/// - Income: `+ Rp 8.500.000`, Expense: `- Rp 35.000`,
///   Transfer/Saldo/Sisa: `Rp ...` tanpa tanda.
/// - Compact (`Rp 8,5 jt` / `Rp 729 rb`) HANYA untuk ruang sempit,
///   tidak untuk nilai primer.
/// - Kurs asing memakai pola `SIMBOL 1,234` agar konsisten.
class MoneyFormat {
  const MoneyFormat._();

  /// Kode kurs aktif aplikasi (diubah via Pengaturan → Mata Uang,
  /// disimpan `kaji_currency`). Widget yang memanggil tanpa argumen
  /// otomatis mengikuti pilihan ini.
  static String activeCurrency = 'IDR';

  /// Kurs yang didukung + simbol tampilannya.
  static const Map<String, String> symbols = {
    'IDR': 'Rp',
    'USD': '\$',
    'EUR': '€',
    'JPY': '¥',
    'SGD': 'S\$',
    'MYR': 'RM',
  };

  /// Nilai tukar: rupiah per 1 unit kurs (P3-kurs). IDR selalu 1.
  /// Default = estimasi kasar — user wajib sesuaikan di Pengaturan.
  /// Disinkron dari AppSettingsProvider saat aplikasi dimuat/diubah.
  static Map<String, double> rates = {
    'IDR': 1,
    'USD': 16000,
    'EUR': 17500,
    'JPY': 110,
    'SGD': 12000,
    'MYR': 3400,
  };

  /// Timpa seluruh tabel rate (dipakai AppSettingsProvider setelah load).
  /// Entri tak dikenal/tak valid diabaikan; IDR dipaksa 1.
  static void setRates(Map<String, double> next) {
    for (final code in symbols.keys) {
      final v = next[code];
      if (v != null && v.isFinite && v > 0) rates[code] = v;
    }
    rates['IDR'] = 1;
  }

  static double rateOf(String code) {
    final v = rates[code];
    if (v == null || !v.isFinite || v <= 0) return 1;
    return v;
  }

  /// Nilai tampil → basis simpan (minor units IDR, integer). Input formulir
  /// selalu dalam kurs aktif, jadi simpan hasil konversinya. Pembulatan
  /// tunggal + clamp di [Money.roundBase] — mis. debu binary 0.1 USD
  /// (1600.0000000000001) tersimpan tepat 1600.
  static int toBaseMinorUnits(num displayAmount, {String? currency}) {
    final v = displayAmount.toDouble();
    return Money.roundBase(v * rateOf(currency ?? activeCurrency));
  }

  /// Basis simpan (minor units IDR) → nilai tampil. Tanpa pembulatan di
  /// sini — pemanggil (format/compact) yang membulatkan.
  static double fromBase(int baseAmount, {String? currency}) =>
      baseAmount / rateOf(currency ?? activeCurrency);

  /// Batas nominal dalam **unit mata uang tampil**, untuk input keypad.
  ///
  /// Ditaruh di sini (bukan di tiap sheet) karena keypad transaksi/tagihan/
  /// hutang semuanya punya aturan ini dan sebelumnya berbeda-beda: keypad
  /// menolak digit ke-12 sementara chip tambah cepat memakai clamp 12 digit.
  /// Akibatnya chip bisa membuat nilai yang keypad tak bisa tidalkan.
  /// 12 digit IDR = 999 miliar, jauh di atas ambang wajar, jadi ini murni
  /// pagar overflow — bukan batas bisnis.
  static const int maxDisplayAmount = 999999999999;
  static const int maxDisplayDigits = 12;

  /// True bila [digits] masih muat di [maxDisplayAmount]. Pemanggil yang
  /// mengabaikannya (drop digit) dan memberi umpan balik ke user — diam saja
  /// bikin keyboard terlihat macet.
  static bool displayDigitsAllowed(int digits) => digits <= maxDisplayDigits;

  static List<String> get supported => symbols.keys.toList();

  static String symbolOf(String code) => symbols[code] ?? code;

  /// Income `+ ...`, expense `- ...`, lainnya polos.
  static String format(int amount, {String? currency}) {
    final code = currency ?? activeCurrency;
    final v = fromBase(amount, currency: code);
    final rounded = v.isFinite ? v.round() : 0;
    if (code == 'IDR') return 'Rp ${_group(rounded, '.')}';
    return '${symbolOf(code)} ${_group(rounded, ',')}';
  }

  static String formatRp(int amount) => format(amount, currency: 'IDR');

  /// Income `+ ...`, expense `- ...`, lainnya polos.
  static String signed(int amount, String kind, {String? currency}) {
    final base = format(amount.abs(), currency: currency);
    switch (kind) {
      case 'income':
        return '+ $base';
      case 'expense':
        return '- $base';
      default:
        return base;
    }
  }

  /// Compact hanya untuk label sempit (sumbu chart, chip).
  /// IDR: 8.500.000 → `Rp 8,5 jt`, 729.000 → `Rp 729 rb`, <1000 → penuh.
  /// Kurs lain: pola singkat `SIMBOL 8,5 jt/rb` mengikuti simbol aktif.
  /// [amount] minor units IDR — dikonversi dulu seperti [format].
  static String compact(int amount, {String? currency}) {
    final code = currency ?? activeCurrency;
    final sym = symbolOf(code);
    final display = fromBase(amount, currency: code);
    final v = display.abs().round();
    final neg = display < 0 ? '-' : '';
    if (code != 'IDR') {
      if (v >= 1000000) return '$neg$sym ${_trim1(v / 1000000, ',')}M';
      if (v >= 1000) return '$neg$sym ${_trim1(v / 1000, ',')}K';
      return '$neg$sym $v';
    }
    if (v >= 1000000) {
      final t = v / 1000000;
      final s = _trim1(t, ',');
      return '${neg}Rp $s jt';
    }
    if (v >= 1000) {
      final t = v / 1000;
      final s = _trim1(t, ',');
      return '${neg}Rp $s rb';
    }
    return '${neg}Rp $v';
  }

  /// Parse input user: `8.500.000`, `8,500,000`, `Rp 8.500.000` → 8500000.
  /// Awalan simbol kurs apa pun (Rp, $, €, ¥, S$, RM, IDR, ...) dibuang —
  /// huruf di tengah teks (mis. "Top Up") tidak ikut terhapus.
  /// Hasil SELALU minor units IDR: input dalam kurs aktif dikali rate lalu
  /// dibulatkan tunggal via [toBaseMinorUnits] (P4: tanpa debu pecahan).
  static int parse(String raw, {String? currency}) {
    var s = raw.trim();
    if (s.isEmpty) return 0;
    // Deteksi minus sebelum simbol dibuang ("- Rp ..." / "$ -5" tetap negatif).
    final neg = s.startsWith('-') || s.contains('- ');
    // Buang awalan simbol/non-digit (Rp, IDR, $, S$, RM, €, ¥).
    s = s.replaceFirst(RegExp(r'^[^0-9]+', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[^0-9.,]'), '');
    final code = currency ?? activeCurrency;
    if (s.contains('.') && s.contains(',')) {
      final lastDot = s.lastIndexOf('.');
      final lastComma = s.lastIndexOf(',');
      if (lastDot > lastComma) {
        // e.g. 1,234.56
        s = s.replaceAll(',', '');
      } else {
        // e.g. 1.234,56
        s = s.replaceAll('.', '').replaceAll(',', '.');
      }
    } else if (s.contains('.')) {
      final parts = s.split('.');
      if (code != 'IDR' &&
          code != 'JPY' &&
          parts.length == 2 &&
          parts[1].length <= 2 &&
          parts[0].length <= 3) {
        // Desimal pada mata uang asing (mis. 10.50 atau 9.99).
        // Batas parts[0] ≤ 3 digit mencegah "1.000" (ribuan) dibaca 1.0.
      } else if (parts.length > 2) {
        // Pemisah ribuan ganda: 1.000.000
        s = s.replaceAll('.', '');
      } else if (code == 'IDR' || code == 'JPY') {
        // Pemisah ribuan IDR/JPY: 10.000
        s = s.replaceAll('.', '');
      } else if (parts.length == 2 && parts[1].length == 3) {
        // Kelompok ribuan gaya titik pada kurs asing: 1.000 → 1000.
        s = s.replaceAll('.', '');
      }
    } else if (s.contains(',')) {
      final parts = s.split(',');
      if (parts.length == 2 && parts[1].length <= 2) {
        // Desimal koma: 10,50 -> 10.50
        s = s.replaceAll(',', '.');
      } else {
        // Pemisah ribuan koma: 1,000
        s = s.replaceAll(',', '');
      }
    }
    final v = double.tryParse(s) ?? 0;
    final base = toBaseMinorUnits(v, currency: currency);
    return neg ? -base : base;
  }

  // --- internal ---

  static String _group(int v, String sep) {
    final neg = v < 0;
    var s = v.abs().toString();
    final buf = StringBuffer();
    var count = 0;
    for (var i = s.length - 1; i >= 0; i--) {
      buf.write(s[i]);
      count++;
      if (count % 3 == 0 && i != 0) buf.write(sep);
    }
    final grouped = buf.toString().split('').reversed.join('');
    return neg ? '-$grouped' : grouped;
  }

  static String _trim1(double v, String decimalSep) {
    final s = v.toStringAsFixed(1).replaceAll('.', decimalSep);
    return s.endsWith('${decimalSep}0') ? s.substring(0, s.length - 2) : s;
  }

  /// Helper uji cepat di widget lawas yang masih memakai NumberFormat.
  static NumberFormat get idDecimal => NumberFormat.decimalPattern('id_ID');
}
