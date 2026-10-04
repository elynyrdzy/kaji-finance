/// Representasi moneter kanonis Kaji Finance (Phase 4).
///
/// SELURUH uang otoritatif disimpan sebagai **integer minor units**
/// (rupiah utuh untuk IDR) — tidak ada `double` sebagai penyimpanan.
///
/// - Aritmetika antar-integer eksak (tanpa debu binary).
/// - Satu-satunya pembulatan ada di perbatasan double→int
///   ([Money.roundBase], dipakai konversi kurs & migrasi data lama):
///   round-half-away deterministik, clamp ke batas, non-finite → 0.
/// - Tidak ada silent rounding di dalam operasi ledger.
class Money {
  /// Rupiah utuh. Boleh negatif untuk selisih/delta; saldo tersimpan
  /// selalu ≥ 0 (ditegakkan di validasi provider, bukan di sini).
  final int minorUnits;

  const Money(this.minorUnits);

  static const zero = Money(0);

  /// Batas besaran (~10^15 rupiah) — jauh di atas data realistis, di bawah
  /// batas int64 SQLite/Dart agar `+`/`-` antar data valid tak overflow.
  static const maxMinorUnits = 999999999999999;

  static int clampAmount(int v) => v.clamp(-maxMinorUnits, maxMinorUnits);

  /// Titik pembulatan tunggal double → minor units.
  static int roundBase(double raw) {
    if (!raw.isFinite) return 0;
    if (raw >= maxMinorUnits) return maxMinorUnits;
    if (raw <= -maxMinorUnits) return -maxMinorUnits;
    return raw.round();
  }

  bool get isZero => minorUnits == 0;
  bool get isNegative => minorUnits < 0;
  bool get isPositive => minorUnits > 0;
  Money get abs => Money(minorUnits.abs());
  Money get negated => Money(-minorUnits);

  Money operator +(Money other) => Money(minorUnits + other.minorUnits);
  Money operator -(Money other) => Money(minorUnits - other.minorUnits);
  bool operator >(Money other) => minorUnits > other.minorUnits;
  bool operator >=(Money other) => minorUnits >= other.minorUnits;
  bool operator <(Money other) => minorUnits < other.minorUnits;
  bool operator <=(Money other) => minorUnits <= other.minorUnits;

  /// Jembatan eksplisit ke double HANYA untuk rasio/chart (bukan storage).
  double toDouble() => minorUnits.toDouble();

  @override
  bool operator ==(Object other) =>
      other is Money && other.minorUnits == minorUnits;

  @override
  int get hashCode => minorUnits.hashCode;

  @override
  String toString() => 'Money($minorUnits)';
}
