import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/recurring_bill.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/notification_service.dart';
import 'package:kaji_finance/services/profile_service.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecurringBill _bill({
  String id = 'b1',
  String name = 'Listrik PLN',
  int amount = 150000,
  RecurringPeriod period = RecurringPeriod.monthly,
  int dueDay = 20,
  int dueMonth = 1,
  String category = 'Bills & Utilities',
  String wallet = 'BCA',
  bool autoCreate = false,
  bool active = true,
  String? lastPostedKey,
}) =>
    RecurringBill(
      id: id,
      name: name,
      amount: amount,
      period: period,
      dueDay: dueDay,
      dueMonth: dueMonth,
      category: category,
      wallet: wallet,
      icon: Icons.bolt,
      autoCreate: autoCreate,
      active: active,
      lastPostedKey: lastPostedKey,
      createdAt: DateTime(2026, 1, 1),
    );

Future<FinanceProvider> _freshProvider() async {
  SharedPreferences.setMockInitialValues({});
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

void main() {
  group('Penjadwalan murni', () {
    test('mingguan: hari ini bila weekday cocok, maju bila lewat', () {
      // Senin 2026-09-28? 2026-09-30 = Rabu. Pakai tanggal eksplisit.
      final wed = DateTime(2026, 9, 30); // Rabu (weekday 3)
      expect(wed.weekday, 3);
      expect(
        _bill(period: RecurringPeriod.weekly, dueDay: 3).nextDue(wed),
        DateTime(2026, 9, 30),
      );
      expect(
        _bill(period: RecurringPeriod.weekly, dueDay: 5).nextDue(wed),
        DateTime(2026, 10, 2),
      );
      expect(
        _bill(period: RecurringPeriod.weekly, dueDay: 1).nextDue(wed),
        DateTime(2026, 10, 5),
      );
    });

    test('bulanan: tgl 31 dijepit ke panjang bulan + rollover', () {
      final b = _bill(dueDay: 31);
      // Jan 15 → Jan 31
      expect(b.nextDue(DateTime(2026, 1, 15)), DateTime(2026, 1, 31));
      // Jatuh tempo hari ini = hari ini (tidak rollover)
      expect(b.nextDue(DateTime(2026, 1, 31, 12)), DateTime(2026, 1, 31));
      // Feb 1 → Feb 28 (2026 bukan kabisat, dijepit)
      expect(b.nextDue(DateTime(2026, 2, 1)), DateTime(2026, 2, 28));
      // Feb 28 → Feb 28 (hari ini)
      expect(b.nextDue(DateTime(2026, 2, 28)), DateTime(2026, 2, 28));
      // Des 31 malam → Des 31 (hari ini)
      expect(b.nextDue(DateTime(2026, 12, 31, 23)), DateTime(2026, 12, 31));
      // Rollover: lewat tanggal → bulan/tahun berikut
      final mid = _bill(dueDay: 15);
      expect(mid.nextDue(DateTime(2026, 1, 20)), DateTime(2026, 2, 15));
      expect(mid.nextDue(DateTime(2026, 12, 20)), DateTime(2027, 1, 15));
    });

    test('tahunan: bulan+tanggal, rollover tahun', () {
      final b = _bill(period: RecurringPeriod.yearly, dueDay: 17, dueMonth: 8);
      expect(b.nextDue(DateTime(2026, 1, 1)), DateTime(2026, 8, 17));
      expect(b.nextDue(DateTime(2026, 8, 17)), DateTime(2026, 8, 17));
      expect(b.nextDue(DateTime(2026, 8, 18)), DateTime(2027, 8, 17));
    });

    test('daysUntilDue 0 = hari ini', () {
      final now = DateTime.now();
      final b = _bill(dueDay: now.day);
      expect(b.daysUntilDue(now), 0);
      expect(b.nextDue(now), DateTime(now.year, now.month, now.day));
    });

    test('periodKeyFor unik per kemunculan', () {
      expect(
        RecurringBill.periodKeyFor(
          RecurringPeriod.monthly,
          DateTime(2026, 9, 5),
        ),
        'M2026-09',
      );
      expect(
        RecurringBill.periodKeyFor(
          RecurringPeriod.monthly,
          DateTime(2026, 10, 5),
        ),
        isNot(
          RecurringBill.periodKeyFor(
            RecurringPeriod.monthly,
            DateTime(2026, 9, 5),
          ),
        ),
      );
      expect(
        RecurringBill.periodKeyFor(
          RecurringPeriod.yearly,
          DateTime(2026, 8, 17),
        ),
        'Y2026',
      );
      final w1 = RecurringBill.periodKeyFor(
        RecurringPeriod.weekly,
        DateTime(2026, 9, 30),
      );
      final w2 = RecurringBill.periodKeyFor(
        RecurringPeriod.weekly,
        DateTime(2026, 10, 1),
      );
      expect(w1, w2); // satu pekan Senin yang sama
      expect(
        RecurringBill.periodKeyFor(
          RecurringPeriod.weekly,
          DateTime(2026, 10, 6),
        ),
        isNot(w1),
      );
    });

    test('isOverdue hanya autoCreate + lewat hari + belum posting', () {
      final now = DateTime.now();
      final yesterdayWd = now.subtract(const Duration(days: 1)).weekday;
      final overdue = _bill(
        period: RecurringPeriod.weekly,
        dueDay: yesterdayWd,
        autoCreate: true,
      );
      expect(overdue.isOverdue(now), isTrue);
      // Sudah dibukukan → tidak overdue.
      final occ = overdue.lastOccurrence(now)!;
      final posted = overdue.copyWith(
        lastPostedKey: RecurringBill.periodKeyFor(overdue.period, occ),
      );
      expect(posted.isOverdue(now), isFalse);
      // Reminder-only tak pernah overdue.
      expect(overdue.copyWith(autoCreate: false).isOverdue(now), isFalse);
      // Nonaktif tak pernah overdue.
      expect(overdue.copyWith(active: false).isOverdue(now), isFalse);
    });
  });

  group('Serialisasi & preset', () {
    test('roundtrip toJson/fromJson', () {
      final b = _bill(autoCreate: true, lastPostedKey: 'M2026-09');
      final back = RecurringBill.fromJson(
        Map<String, dynamic>.from(b.toJson()),
      );
      expect(back, isNotNull);
      expect(back!.id, 'b1');
      expect(back.amount, 150000);
      expect(back.period, RecurringPeriod.monthly);
      expect(back.autoCreate, isTrue);
      expect(back.lastPostedKey, 'M2026-09');
    });

    test('fromJson korup → null (bukan crash)', () {
      expect(RecurringBill.fromJson({}), isNull);
      expect(RecurringBill.fromJson({'id': 'x', 'name': 'y'}), isNull);
      expect(
        RecurringBill.fromJson({
          'id': 'x',
          'name': 'y',
          'category': 'c',
          'wallet': 'w',
          'period': 99,
        }),
        isNull,
      );
    });

    test('validasi menolak nama/amount/dompet kosong', () {
      expect(_bill().isValid, isTrue);
      expect(_bill(name: '  ').isValid, isFalse);
      expect(_bill(amount: 0).isValid, isFalse);
      expect(_bill(amount: -5).isValid, isFalse);
      expect(_bill(wallet: '').isValid, isFalse);
      expect(_bill(period: RecurringPeriod.weekly, dueDay: 8).isValid, isFalse);
    });

    test('preset khas Indonesia: 7 template valid jadwalnya', () {
      final presets = RecurringBillPresets.templates();
      expect(presets.length, 7);
      final names = presets.map((e) => e.name).toSet();
      expect(
        names,
        containsAll([
          'Kos / Kontrakan',
          'Listrik PLN',
          'PDAM / Air',
          'BPJS Kesehatan',
          'Pulsa / Paket Data',
          'Internet / WiFi',
          'Langganan Aplikasi',
        ]),
      );
      for (final p in presets) {
        expect(p.dueDay >= 1 && p.dueDay <= 31, isTrue);
        // nextDue tak boleh throw untuk hari ini.
        expect(() => p.nextDue(DateTime.now()), returnsNormally);
      }
    });
  });

  group('PrefsRecurringBillStore', () {
    test('simpan/muat roundtrip ter-scope profil', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsRecurringBillStore();
      await store.save([_bill(), _bill(id: 'b2', name: 'Kos')]);
      final loaded = await store.load();
      expect(loaded.length, 2);
      expect(loaded.map((e) => e.id).toSet(), {'b1', 'b2'});
    });

    test('entri korup di-skip, bukan gugurkan daftar', () async {
      final prefs = await SharedPreferences.getInstance();
      // Nota: mock sudah di-set pada test sebelumnya? Isolasi per-test:
      SharedPreferences.setMockInitialValues({});
      final p2 = await SharedPreferences.getInstance();
      final good = _bill().toJson();
      await p2.setString(
        PrefsRecurringBillStore.keyFor(ProfileService.activeId),
        jsonEncode([
          good,
          {'sampah': true},
          'bukan-map',
        ]),
      );
      final loaded = await PrefsRecurringBillStore().load();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'b1');
      expect(prefs, isNotNull); // cegah unused
    });
  });

  group('FinanceRecurring provider', () {
    test('CRUD + validasi + duplikat', () async {
      final fp = await _freshProvider();
      expect(await fp.addRecurringBill(_bill(name: '  ')), isFalse);
      expect(await fp.addRecurringBill(_bill(amount: 0)), isFalse);
      expect(await fp.addRecurringBill(_bill()), isTrue);
      // Duplikat nama+periode ditolak.
      expect(await fp.addRecurringBill(_bill(id: 'b9')), isFalse);
      // Nama sama beda periode boleh.
      expect(
        await fp.addRecurringBill(
          _bill(id: 'b10', period: RecurringPeriod.yearly, dueMonth: 8),
        ),
        isTrue,
      );
      expect(fp.recurringBills.length, 2);
      // Update invalid ditolak.
      expect(await fp.updateRecurringBill('b1', _bill(amount: -1)), isFalse);
      expect(await fp.updateRecurringBill('b1', _bill(amount: 200000)), isTrue);
      expect(fp.recurringBills.firstWhere((e) => e.id == 'b1').amount, 200000);
      // Toggle aktif.
      expect(await fp.setRecurringBillActive('b1', false), isTrue);
      expect(fp.recurringBills.firstWhere((e) => e.id == 'b1').active, isFalse);
      // Hapus.
      expect(await fp.removeRecurringBill('b1'), isTrue);
      expect(await fp.removeRecurringBill('b1'), isFalse);
    });

    test('estimasi bulanan + dueWithin terurut', () async {
      final fp = await _freshProvider();
      await fp.addRecurringBill(
        _bill(
          id: 'm',
          period: RecurringPeriod.monthly,
          amount: 120000,
          dueDay: 28,
        ),
      );
      await fp.addRecurringBill(
        _bill(
          id: 'w',
          name: 'Mingguan',
          period: RecurringPeriod.weekly,
          amount: 12000,
          dueDay: DateTime.now().weekday,
        ),
      );
      await fp.addRecurringBill(
        _bill(
          id: 'y',
          name: 'Tahunan',
          period: RecurringPeriod.yearly,
          amount: 1200000,
          dueDay: 1,
          dueMonth: 1,
        ),
      );
      // 120000 + 12000*52/12=52000 + 1200000/12=100000
      expect(fp.estimatedMonthlyRecurring, 120000 + 52000 + 100000);
      final due = fp.recurringDueWithin(days: 3);
      expect(due.map((e) => e.id), contains('w'));
      for (var i = 1; i < due.length; i++) {
        expect(
          due[i - 1].daysUntilDue(DateTime.now()) <=
              due[i].daysUntilDue(DateTime.now()),
          isTrue,
        );
      }
    });

    test('processDueBills membukukan 1x + idempoten', () async {
      final fp = await _freshProvider();
      await fp.addWallet(
        'BCA',
        '• 1234',
        Icons.account_balance,
        const Color(0xFF1A4D8F),
        10000000,
      );
      final yesterdayWd =
          DateTime.now().subtract(const Duration(days: 1)).weekday;
      await fp.addRecurringBill(
        _bill(
          period: RecurringPeriod.weekly,
          dueDay: yesterdayWd,
          amount: 50000,
          autoCreate: true,
        ),
      );
      final r1 = await fp.processDueBills();
      expect(r1.posted, 1);
      expect(fp.transactions.where((t) => t.title == 'Listrik PLN').length, 1);
      // Jalan kedua: tidak dobel (kunci periode sudah tercatat).
      final r2 = await fp.processDueBills();
      expect(r2.posted, 0);
      expect(fp.transactions.where((t) => t.title == 'Listrik PLN').length, 1);
      // Tagihan reminder-only tak dibukukan.
      await fp.addRecurringBill(
        _bill(
          id: 'r',
          name: 'Netflix',
          period: RecurringPeriod.weekly,
          dueDay: yesterdayWd,
          amount: 60000,
          autoCreate: false,
        ),
      );
      final r3 = await fp.processDueBills();
      expect(r3.posted, 0);
      expect(fp.transactions.where((t) => t.title == 'Netflix'), isEmpty);
    });

    test('dampak anggaran 50/80/100% + baris digest', () async {
      final fp = await _freshProvider();
      await fp.addBudgetCategory(name: 'Bills & Utilities', limit: 100000);
      await fp.addRecurringBill(_bill(amount: 60000));
      final impacts = fp.recurringBudgetImpacts();
      expect(impacts.length, 1);
      expect(impacts.first.level, 1); // 60% → tier setengah
      expect(impacts.first.projectedPct, closeTo(0.6, 0.0001));
      // Baris digest hanya untuk jatuh tempo <=3 hari: tambah tagihan yang jatuh tempo hari ini.
      final now = DateTime.now();
      await fp.addRecurringBill(
        _bill(id: 'net', name: 'Internet', amount: 100000, dueDay: now.day),
      );
      final lines = fp.recurringDigestLines('id', now: now);
      expect(lines, isNotEmpty);
      expect(lines.any((l) => l.contains('Internet')), isTrue);
      final linesEn = fp.recurringDigestLines('en', now: now);
      expect(linesEn.any((l) => l.contains('Internet')), isTrue);
    });
  });

  group('Notifikasi tagihan', () {
    test('ID stabil per (bill, H-x) + beda slot beda ID', () {
      final a = NotificationService.recurringReminderId('b1', 3);
      expect(a, NotificationService.recurringReminderId('b1', 3));
      expect(a >= 0 && a <= 0x7fffffff, isTrue);
      expect(NotificationService.recurringReminderId('b1', 1) == a, isFalse);
      expect(NotificationService.recurringReminderId('b2', 3) == a, isFalse);
    });
  });
}
