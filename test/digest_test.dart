import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/notification_service.dart';

void main() {
  group('budgetAlertLevel', () {
    test('batas tier 0/50/80/100%', () {
      expect(NotificationService.budgetAlertLevel(0.0), 0);
      expect(NotificationService.budgetAlertLevel(0.49), 0);
      expect(NotificationService.budgetAlertLevel(0.5), 1);
      expect(NotificationService.budgetAlertLevel(0.79), 1);
      expect(NotificationService.budgetAlertLevel(0.8), 2);
      expect(NotificationService.budgetAlertLevel(0.99), 2);
      expect(NotificationService.budgetAlertLevel(1.0), 3);
      expect(NotificationService.budgetAlertLevel(1.5), 3);
    });
  });

  group('stableId', () {
    test('deterministik lintas panggil dalam rentang', () {
      final a = NotificationService.stableId('budget:abc');
      expect(a, NotificationService.stableId('budget:abc'));
      expect(a >= 0 && a <= 0x7fffffff, isTrue);
      expect(NotificationService.stableId('budget:abd') == a, isFalse);
    });
  });

  group('composeDigest', () {
    test('lengkap id memuat semua baris', () {
      final c = NotificationService.composeDigest(
        const DigestData(
          spentToday: 50000,
          daysSinceLastTx: 3,
          allowanceLeft: 100000,
          goalsDue: [
            GoalDue(name: 'Motor', daysLeft: 5, remaining: 200000),
            GoalDue(name: 'Darurat', daysLeft: -2, remaining: 50000),
          ],
          lowWallets: [WalletLow(name: 'Cash', balance: 10000)],
        ),
        const DigestOptions(),
        'id',
      );
      expect(c.title, 'Ringkasan Kaji Finance');
      expect(c.body.contains('Rp 50.000'), isTrue);
      expect(c.body.contains('Rp 100.000'), isTrue);
      expect(c.body.contains('3 hari'), isTrue);
      expect(c.body.contains('Motor'), isTrue);
      expect(c.body.contains('lewat 2 hari'), isTrue);
      expect(c.body.contains('Cash'), isTrue);
    });

    test('opsi mati + tanpa data → hanya baris belanja', () {
      const opts = DigestOptions(
        budget: false,
        goals: false,
        wallets: false,
        nudge: false,
      );
      final c = NotificationService.composeDigest(
        const DigestData(
          spentToday: 0,
          daysSinceLastTx: -1,
          allowanceLeft: null,
        ),
        opts,
        'en',
      );
      expect(c.title, 'Kaji Finance digest');
      expect(c.body, 'Spent today: Rp 0');
    });
  });

  group('nextDailyOccurrence', () {
    test('hari ini bila jam masih depan, besok bila lewat/sama', () {
      final now = DateTime(2026, 5, 1, 10, 0);
      expect(
        NotificationService.nextDailyOccurrence(now, 20, 0),
        DateTime(2026, 5, 1, 20, 0),
      );
      expect(
        NotificationService.nextDailyOccurrence(now, 9, 30),
        DateTime(2026, 5, 2, 9, 30),
      );
      expect(
        NotificationService.nextDailyOccurrence(now, 10, 0),
        DateTime(2026, 5, 2, 10, 0),
      );
    });
  });
}
