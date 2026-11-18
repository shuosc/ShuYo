import '../models/campus_card.dart';
import '../services/campus_card_service.dart';

class DemoCampusCardRepository implements CampusCardDataSource {
  const DemoCampusCardRepository();

  static const card = CampusCardInfo(
    studentId: 'DEMO0001',
    name: '演示用户',
    status: '正常',
    balance: 87.60,
    validUntil: '',
  );

  // Place the ledger relative to today so the chart and history presets can
  // all be explored whenever the reviewer opens the demo.
  static const _transactions = <(int, int, int, String, double)>[
    (1, 18, 12, '宝山校区第一食堂', 13.50),
    (1, 12, 6, '宝山校区第二食堂', 11.80),
    (2, 8, 45, '校园卡充值', -35.00),
    (3, 12, 25, '宝山校区第一食堂', 14.20),
    (4, 16, 33, '校园超市', 5.50),
    (5, 18, 7, '宝山校区第三食堂', 16.50),
    (6, 12, 11, '宝山校区第二食堂', 12.80),
    (9, 13, 1, '自助打印', 3.00),
    (12, 12, 17, '宝山校区第一食堂', 12.50),
    (17, 18, 22, '宝山校区第三食堂', 15.90),
    (21, 10, 16, '校园卡充值', -40.00),
    (25, 12, 8, '宝山校区第二食堂', 10.80),
    (41, 12, 21, '延长校区食堂', 13.20),
    (67, 15, 6, '校园超市', 8.00),
    (91, 9, 11, '校园卡充值', -50.00),
    (156, 13, 15, '自助打印', 2.50),
    (203, 12, 3, '宝山校区第一食堂', 12.60),
  ];

  @override
  Future<CampusCardInfo> fetchCardInfo() async => card;

  @override
  Future<List<CampusCardBill>> fetchBills({
    required DateTime startDate,
    required DateTime endDate,
    void Function(List<CampusCardBill>)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (shouldCancel?.call() ?? false) {
      throw const CampusCardException('cancelled', '消费记录查询已取消');
    }
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day + 1);
    if (!start.isBefore(end)) {
      throw const CampusCardException('invalidDates', '开始日期不能晚于结束日期');
    }
    final today = DateTime.now();
    final bills = <CampusCardBill>[];
    for (final (daysAgo, hour, minute, name, amount) in _transactions) {
      final time =
          DateTime(today.year, today.month, today.day - daysAgo, hour, minute);
      if (!time.isBefore(start) && time.isBefore(end)) {
        bills.add(CampusCardBill(
          name: name,
          payTime: time.toString().split('.').first,
          amount: amount,
        ));
      }
    }
    return List.unmodifiable(bills);
  }
}
