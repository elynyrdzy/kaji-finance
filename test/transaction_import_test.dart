import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/models/transaction_model.dart';
import 'package:kaji_finance/providers/finance_provider.dart';
import 'package:kaji_finance/services/secure_db_service.dart';
import 'package:kaji_finance/services/transaction_import_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FinanceProvider memuat async di konstruktor — tunggu sebelum assert.
Future<FinanceProvider> freshImportProvider() async {
  SharedPreferences.setMockInitialValues({});
  await SecureDbService.useInMemory();
  final fp = FinanceProvider();
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return fp;
}

void main() {
  group('TransactionImportService.parseStaging (tahap MEMORI)', () {
    test('list murni 2 baris valid', () {
      const raw = '''
[{"id":"a1","title":"Gaji","category":"Income","account":"BCA",
"amount":5000000,"type":0,"date":"2026-01-10T09:00:00.000","icon":58136},
{"id":"a2","title":"Kopi","category":"Food & Drinks","account":"BCA",
"amount":20000,"type":1,"date":"2026-01-11T08:00:00.000","icon":58136}]''';
      final s = TransactionImportService.parseStaging(raw);
      expect(s.valid.length, 2);
      expect(s.invalid, 0);
      expect(s.valid.first.type, TransactionType.income);
      expect(s.valid.last.type, TransactionType.expense);
    });

    test('backup penuh kaji_tx string-encoded', () {
      const raw = '{"kaji_tx": "[{\\"id\\":\\"t1\\",\\"title\\":\\"Gaji\\",'
          '\\"category\\":\\"Income\\",\\"account\\":\\"BCA\\",\\"amount\\":1000,'
          '\\"type\\":0,\\"date\\":\\"2026-02-01T00:00:00.000\\",\\"icon\\":1}]",'
          ' "_meta": {"app": "Kaji Finance"}}';
      final s = TransactionImportService.parseStaging(raw);
      expect(s.valid.length, 1);
      expect(s.valid.single.id, 't1');
    });

    test('objek {"transactions": [...]} dan satu objek tunggal', () {
      const wrapped = '''
{"transactions": [{"title":"Jajan","category":"Food",
"account":"Cash","amount":15000,"type":"pengeluaran",
"date":"2026-03-01T00:00:00.000"}]}''';
      final w = TransactionImportService.parseStaging(wrapped);
      expect(w.valid.length, 1);
      expect(w.valid.single.type, TransactionType.expense);

      const single = '''
{"title":"Bonus","category":"Income","account":"BCA",
"amount":"Rp 50.000","type":"pemasukan","date":"2026-03-02T00:00:00.000"}''';
      final one = TransactionImportService.parseStaging(single);
      expect(one.valid.length, 1);
      expect(one.valid.single.amount, 50000);
      // ID dibuat otomatis bila tak ada.
      expect(one.valid.single.id.isNotEmpty, isTrue);
    });

    test('baris rusak di-skip tanpa gugurkan yang valid', () {
      const raw = '''
[{"title":"Valid","category":"Other","account":"Cash",
"amount":1000,"type":1,"date":"2026-01-01T00:00:00.000"},
{"title":"Rusak","category":"Other","account":"Cash",
"amount":-5,"type":1,"date":"2026-01-01T00:00:00.000"},
"bukan-map",
{"title":"TanpaNominal","category":"Other","account":"Cash",
"type":1,"date":"2026-01-01T00:00:00.000"}]''';
      final s = TransactionImportService.parseStaging(raw);
      expect(s.valid.length, 1);
      expect(s.invalid, 3);
    });

    test('bukan-JSON dan bentuk tak dikenal → invalid', () {
      final bad = TransactionImportService.parseStaging('bukan-json{{{');
      expect(bad.valid, isEmpty);
      expect(bad.invalid, 1);
      final unknown = TransactionImportService.parseStaging('{"aneh": 1}');
      expect(unknown.valid, isEmpty);
    });
  });

  group('FinanceProvider.importTransactions (tahap ENKRIPSI + SQL)', () {
    test('gabung baru + skip duplikat + saldo konsisten', () async {
      final fp = await freshImportProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 123',
          Icons.account_balance_wallet,
          const Color(0xFF1A4D8F),
          1000000,
        ),
        isTrue,
      );
      const raw = '''
[{"id":"i1","title":"Gaji","category":"Income","account":"BCA",
"amount":2000000,"type":0,"date":"2026-01-10T09:00:00.000","icon":1},
{"id":"i2","title":"Kopi","category":"Food & Drinks","account":"BCA",
"amount":20000,"type":1,"date":"2026-01-11T08:00:00.000","icon":1}]''';
      final staging = TransactionImportService.parseStaging(raw);
      final r1 = await fp.importTransactions(staging.valid);
      expect(r1.imported, 2);
      expect(r1.skippedDuplicates, 0);
      expect(fp.transactions.length, 2);
      // 1jt + 2jt − 20rb.
      expect(fp.balance, 2980000);

      // Impor ulang file sama → semua duplikat, saldo tak berubah.
      final r2 = await fp.importTransactions(staging.valid);
      expect(r2.imported, 0);
      expect(r2.skippedDuplicates, 2);
      expect(fp.transactions.length, 2);
      expect(fp.balance, 2980000);
    });

    test('tersimpan terenkripsi di SQL (bisa dibaca ulang)', () async {
      final fp = await freshImportProvider();
      const raw = '''
[{"id":"s1","title":"Gaji","category":"Income","account":"BCA",
"amount":100000,"type":0,"date":"2026-01-10T09:00:00.000","icon":1}]''';
      final staging = TransactionImportService.parseStaging(raw);
      await fp.importTransactions(staging.valid);
      final rows = await SecureDbService.loadTable(SecureDbTables.tx);
      expect(rows.any((r) => r['id'] == 's1'), isTrue);
    });

    test('staging kosong → hasil nol tanpa efek', () async {
      final fp = await freshImportProvider();
      final res = await fp.importTransactions([]);
      expect(res.imported, 0);
      expect(fp.transactions, isEmpty);
    });

    test('impor besar 500 baris: atomik + saldo tepat', () async {
      final fp = await freshImportProvider();
      expect(
        await fp.addWallet(
          'BCA',
          '• 123',
          Icons.account_balance_wallet,
          const Color(0xFF1A4D8F),
          0,
        ),
        isTrue,
      );
      final buf = StringBuffer('[');
      for (var i = 0; i < 500; i++) {
        if (i > 0) buf.write(',');
        buf.write(
          '{"id":"bulk$i","title":"T$i","category":"Other",'
          '"account":"BCA","amount":1000,"type":${i.isEven ? 0 : 1},'
          '"date":"2026-01-10T09:00:00.000","icon":1}',
        );
      }
      buf.write(']');
      final staging = TransactionImportService.parseStaging(buf.toString());
      expect(staging.valid.length, 500);
      expect(staging.invalid, 0);
      final res = await fp.importTransactions(staging.valid);
      expect(res.imported, 500);
      expect(fp.transactions.length, 500);
      // 250 income − 250 expense, @1000 → net 0.
      expect(fp.balance, 0);
      expect((await fp.reconcileAll()).ok, isTrue);
    });

    test(
      'overdraft historis diizinkan eksplisit (beda dari input manual)',
      () async {
        final fp = await freshImportProvider();
        expect(
          await fp.addWallet(
            'BCA',
            '• 123',
            Icons.account_balance_wallet,
            const Color(0xFF1A4D8F),
            100000,
          ),
          isTrue,
        );
        // Input manual guard menolak — bukti policy berbeda.
        expect(
          await fp.addTransaction(
            title: 'Besar',
            category: 'Other',
            account: 'BCA',
            amount: 500000,
            type: TransactionType.expense,
            icon: Icons.more_horiz,
          ),
          isFalse,
        );
        const raw = '''
[{"id":"h1","title":"Lampau","category":"Other","account":"BCA",
"amount":500000,"type":1,"date":"2025-01-10T09:00:00.000","icon":1}]''';
        final staging = TransactionImportService.parseStaging(raw);
        final res = await fp.importTransactions(staging.valid);
        expect(res.imported, 1);
        // Fakta masa lalu boleh negatif — eksplisit, bukan silent.
        expect(fp.wallets.singleWhere((w) => w.name == 'BCA').balance, -400000);
      },
    );

    test('tipe tak dikenal + tanggal rusak di-skip dengan laporan', () {
      const raw = '''
[{"id":"v1","title":"Ok","category":"Other","account":"Cash",
"amount":1000,"type":1,"date":"2026-01-01T00:00:00.000","icon":1},
{"id":"x1","title":"TipeAneh","category":"Other","account":"Cash",
"amount":1000,"type":"ngawur","date":"2026-01-01T00:00:00.000","icon":1},
{"id":"x2","title":"TglRusak","category":"Other","account":"Cash",
"amount":1000,"type":1,"date":"kapan-kapan","icon":1}]''';
      final s = TransactionImportService.parseStaging(raw);
      expect(s.valid.length, 1);
      expect(s.invalid, 2);
    });
  });

  group('parseTransactionsCsv', () {
    test('round-trip format ekspor (termasuk koma dalam kutip)', () {
      const raw = 'id,title,category,account,amount,type,date,tag,note\n'
          'a1,Gaji,Income,BCA,5000000,income,2026-01-10T09:00:00.000,,\n'
          '"a2","Kopi, Susu","Food & Drinks",BCA,20000,expense,2026-01-11T08:00:00.000,Qris,\n';
      final s = TransactionImportService.parseTransactionsCsv(raw);
      expect(s.valid.length, 2);
      expect(s.invalid, 0);
      expect(s.valid.first.id, 'a1');
      expect(s.valid.first.type, TransactionType.income);
      expect(s.valid.last.title, 'Kopi, Susu');
      expect(s.valid.last.tag, 'Qris');
      expect(s.valid.last.note, isNull);
    });

    test('baris rusak di-skip, header asing ditolak', () {
      const raw = 'id,title,category,account,amount,type,date,tag,note\n'
          'b1,Valid,Other,Cash,1000,1,2026-01-01T00:00:00.000,,\n'
          'b2,Rusak,Other,Cash,-5,1,2026-01-01T00:00:00.000,,\n';
      final bad = TransactionImportService.parseTransactionsCsv(raw);
      expect(bad.valid.length, 1);
      expect(bad.invalid, 1);
      final unknown = TransactionImportService.parseTransactionsCsv(
        'a,b,c\n1,2,3\n',
      );
      expect(unknown.valid, isEmpty);
    });
  });

  group('envelope Backup Transaksi (tabungan ikut)', () {
    test('parse membawa goals + wallets', () {
      const raw = '{"kind":"kaji-tx-backup","transactions":['
          '{"id":"t1","title":"Gaji","category":"Income","account":"Cash",'
          '"amount":100000,"type":0,"date":"2026-01-10T00:00:00.000","icon":1}],'
          '"goals":[{"id":"g1","name":"Tab","target":1000000,"saved":5000,'
          '"icon":1,"color":4279913871,"deadline":null,'
          '"createdAt":"2026-01-01T00:00:00.000"}],'
          '"wallets":[{"id":"w1","name":"Cash","number":"• 0000","icon":1,'
          '"balance":90000,"color":4279913871}]}';
      final s = TransactionImportService.parseStaging(raw);
      expect(s.valid.length, 1);
      expect(s.goals.length, 1);
      expect(s.wallets.length, 1);
      expect(s.goals.single.saved, 5000);
    });

    test('impor goals + wallets tanpa hitung ganda', () async {
      final fp = await freshImportProvider();
      const raw = '{"transactions":['
          '{"id":"t1","title":"Gaji","category":"Income","account":"Cash",'
          '"amount":100000,"type":0,"date":"2026-01-10T00:00:00.000","icon":1}],'
          '"goals":[{"id":"g1","name":"Tab","target":1000000,"saved":5000,'
          '"icon":1,"color":4279913871,"deadline":null,'
          '"createdAt":"2026-01-01T00:00:00.000"}],'
          '"wallets":[{"id":"w1","name":"Cash","number":"• 0000","icon":1,'
          '"balance":90000,"color":4279913871}]}';
      final s = TransactionImportService.parseStaging(raw);
      final res = await fp.importTransactions(
        s.valid,
        goals: s.goals,
        wallets: s.wallets,
      );
      expect(res.imported, 1);
      expect(res.importedGoals, 1);
      expect(res.importedWallets, 1);
      // Dompet baru: saldo backup final, bukan + delta lagi.
      expect(fp.wallets.singleWhere((e) => e.id == 'w1').balance, 90000);
      expect(fp.savingsGoals.singleWhere((e) => e.id == 'g1').saved, 5000);
      // Impor ulang: semua duplikat, saldo tetap.
      final res2 = await fp.importTransactions(
        s.valid,
        goals: s.goals,
        wallets: s.wallets,
      );
      expect(res2.imported, 0);
      expect(res2.importedGoals, 0);
      expect(res2.importedWallets, 0);
      expect(fp.wallets.singleWhere((e) => e.id == 'w1').balance, 90000);
    });
  });
}
