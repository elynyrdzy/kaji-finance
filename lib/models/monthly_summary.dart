/// Monthly income/expense summary value object (rupiah utuh, Phase 4).
class MonthlySummary {
  final int year;
  final int month;
  final int income;
  final int expense;
  final int transactionCount;
  final String? topExpenseCategory;
  final int topExpenseAmount;

  const MonthlySummary({
    required this.year,
    required this.month,
    required this.income,
    required this.expense,
    required this.transactionCount,
    this.topExpenseCategory,
    this.topExpenseAmount = 0,
  });

  int get net => income - expense;
  double get savingsRate => income <= 0 ? 0 : (net / income).clamp(0, 1);

  @override
  String toString() =>
      'MonthlySummary($year-$month income=$income expense=$expense net=$net count=$transactionCount)';
}
