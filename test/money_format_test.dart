import 'package:flutter_test/flutter_test.dart';
import 'package:kaji_finance/services/money.dart';
import 'package:kaji_finance/utils/money_format.dart';

/// Vektor §57: satu-satunya format yang benar untuk IDR.
void main() {
  group('MoneyFormat.format (IDR penuh)', () {
    test('0 → Rp 0 (tanpa ,00)', () {
      expect(MoneyFormat.format(0), 'Rp 0');
    });
    test('35000 → Rp 35.000', () {
      expect(MoneyFormat.format(35000), 'Rp 35.000');
    });
    test('729000 → Rp 729.000', () {
      expect(MoneyFormat.format(729000), 'Rp 729.000');
    });
    test('8500000 → Rp 8.500.000', () {
      expect(MoneyFormat.format(8500000), 'Rp 8.500.000');
    });
    test('12450000 → Rp 12.450.000', () {
      expect(MoneyFormat.format(12450000), 'Rp 12.450.000');
    });
  });

  group('MoneyFormat.signed (§14)', () {
    test('income 8500000 → + Rp 8.500.000', () {
      expect(MoneyFormat.signed(8500000, 'income'), '+ Rp 8.500.000');
    });
    test('expense 35000 → - Rp 35.000', () {
      expect(MoneyFormat.signed(35000, 'expense'), '- Rp 35.000');
    });
    test('transfer/balance tanpa tanda', () {
      expect(MoneyFormat.signed(100000, 'transfer'), 'Rp 100.000');
      expect(MoneyFormat.signed(2300000, 'balance'), 'Rp 2.300.000');
    });
  });

  group('MoneyFormat.compact (ruang sempit saja)', () {
    test('8500000 → Rp 8,5 jt', () {
      expect(MoneyFormat.compact(8500000), 'Rp 8,5 jt');
    });
    test('729000 → Rp 729 rb', () {
      expect(MoneyFormat.compact(729000), 'Rp 729 rb');
    });
    test('di bawah 1000 tampil penuh', () {
      expect(MoneyFormat.compact(500), 'Rp 500');
    });
  });

  group('MoneyFormat.parse (input user)', () {
    test('8.500.000 → 8500000', () {
      expect(MoneyFormat.parse('8.500.000'), 8500000);
    });
    test('Rp 8.500.000 → 8500000', () {
      expect(MoneyFormat.parse('Rp 8.500.000'), 8500000);
    });
    test('kosong → 0', () {
      expect(MoneyFormat.parse(''), 0);
    });
  });

  group('Phase 4: presisi integer (tanpa debu float)', () {
    test('parse mengembalikan int', () {
      expect(MoneyFormat.parse('8.500.000'), isA<int>());
    });
    test('kurs asing pecahan dibulatkan tunggal: 10.50 USD → 168000', () {
      expect(MoneyFormat.parse('10.50', currency: 'USD'), 168000);
    });
    test('debu binary 0.1 USD tersimpan tepat 1600', () {
      // 0.1 * 16000 = 1600.0000000000001 dalam binary — harus 1600.
      expect(MoneyFormat.toBaseMinorUnits(0.1, currency: 'USD'), 1600);
    });
    test('toBaseMinorUnits non-finite → 0', () {
      expect(MoneyFormat.toBaseMinorUnits(double.infinity), 0);
      expect(MoneyFormat.toBaseMinorUnits(double.nan, currency: 'USD'), 0);
    });
    test('Money.roundBase deterministik', () {
      expect(Money.roundBase(50000.5), 50001);
      expect(Money.roundBase(-50000.5), -50001);
      expect(Money.roundBase(0.49), 0);
    });
  });
}
