part of '../finance_provider.dart';

/// Data untuk ringkasan harian terjadwal (extension FinanceProvider).
///
/// Membangun [DigestData] dari state memori — tanpa I/O, tanpa notifikasi
/// langsung. Penjadwalan dilakukan pemanggil (lihat digest_scheduler)
/// agar lapisan provider tetap bebas dari jam/siklus.
extension FinanceDigest on FinanceProvider {
  /// Ambang dompet menipis (minor units IDR). Di bawah ini (tapi > 0)
  /// dompet masuk baris digest. Nilai tetap yang didokumentasikan — bukan
  /// setting, agar permukaan preferensi tidak membengkak.
  static const int lowWalletThreshold = 50000;

  DigestData buildDigestData() {
    final now = DateTime.now();
    var spentToday = 0;
    DateTime? latest;
    for (final t in _transactions) {
      if (latest == null || t.date.isAfter(latest)) latest = t.date;
      if (t.type == TransactionType.expense &&
          t.date.year == now.year &&
          t.date.month == now.month &&
          t.date.day == now.day) {
        spentToday += t.amount;
      }
    }
    var daysSince = -1;
    if (latest != null) {
      final l = DateTime(latest.year, latest.month, latest.day);
      daysSince = DateTime(now.year, now.month, now.day).difference(l).inDays;
    }
    int? allowanceLeft;
    if (monthlyAllowance > 0) {
      final m = monthlySummary();
      final left = monthlyAllowance - m.expense;
      allowanceLeft = left < 0 ? 0 : left;
    }
    // Deadline ≤7 hari (termasuk lewat) + belum tercapai.
    final goalsDue = <GoalDue>[];
    for (final g in _goals) {
      if (g.isCompleted || g.deadline == null) continue;
      final days = g.daysLeft ?? 1 << 30;
      if (days <= 7) {
        goalsDue.add(
          GoalDue(name: g.name, daysLeft: days, remaining: g.remaining),
        );
      }
    }
    goalsDue.sort((a, b) => a.daysLeft.compareTo(b.daysLeft));
    final lowWallets = <WalletLow>[];
    for (final w in _wallets) {
      if (w.balance > 0 && w.balance < lowWalletThreshold) {
        lowWallets.add(WalletLow(name: w.name, balance: w.balance));
      }
    }
    return DigestData(
      spentToday: spentToday,
      daysSinceLastTx: daysSince,
      allowanceLeft: allowanceLeft,
      goalsDue: goalsDue,
      lowWallets: lowWallets,
    );
  }
}
