import 'campus_card.dart';

/// The last completed data for each section of the campus-card home page.
class CampusCardSnapshot {
  const CampusCardSnapshot({
    required this.studentId,
    this.balance,
    this.recent,
    this.chart,
  });

  static const version = 1;
  final String studentId;
  final CampusCardBalanceSnapshot? balance;
  final CampusCardRecentSnapshot? recent;
  final CampusCardChartSnapshot? chart;

  factory CampusCardSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != version) {
      throw const FormatException('Unsupported campus-card cache');
    }
    return CampusCardSnapshot(
      studentId: _text(json['studentId']),
      balance: json['balance'] == null
          ? null
          : CampusCardBalanceSnapshot.fromJson(_map(json['balance'])),
      recent: json['recent'] == null
          ? null
          : CampusCardRecentSnapshot.fromJson(_map(json['recent'])),
      chart: json['chart'] == null
          ? null
          : CampusCardChartSnapshot.fromJson(_map(json['chart'])),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'studentId': studentId,
        if (balance != null) 'balance': balance!.toJson(),
        if (recent != null) 'recent': recent!.toJson(),
        if (chart != null) 'chart': chart!.toJson(),
      };

  /// Merge sections separately so a late disk read cannot replace fresh data.
  CampusCardSnapshot merge(CampusCardSnapshot other) {
    if (studentId != other.studentId) return this;
    final nextBalance = other.balance != null &&
            (balance == null ||
                other.balance!.queriedAt.isAfter(balance!.queriedAt))
        ? other.balance
        : balance;
    final nextRecent = other.recent != null &&
            (recent == null ||
                other.recent!.queriedAt.isAfter(recent!.queriedAt))
        ? other.recent
        : recent;
    final nextChart = other.chart != null &&
            (chart == null || other.chart!.queriedAt.isAfter(chart!.queriedAt))
        ? other.chart
        : chart;
    if (identical(nextBalance, balance) &&
        identical(nextRecent, recent) &&
        identical(nextChart, chart)) {
      return this;
    }
    return CampusCardSnapshot(
      studentId: studentId,
      balance: nextBalance,
      recent: nextRecent,
      chart: nextChart,
    );
  }
}

class CampusCardBalanceSnapshot {
  const CampusCardBalanceSnapshot({
    required this.balance,
    required this.queriedAt,
  });

  final double balance;
  final DateTime queriedAt;

  factory CampusCardBalanceSnapshot.fromJson(Map<String, dynamic> json) =>
      CampusCardBalanceSnapshot(
        balance: _number(json['balance']),
        queriedAt: _date(json['queriedAt']),
      );

  Map<String, dynamic> toJson() => {
        'balance': balance,
        'queriedAt': queriedAt.toIso8601String(),
      };

  CampusCardInfo toCard(String studentId) => CampusCardInfo(
        studentId: studentId,
        name: '',
        status: '',
        balance: balance,
        validUntil: '',
      );
}

/// Row balances belong to this ledger, not to the latest balance header.
class CampusCardRecentSnapshot {
  CampusCardRecentSnapshot({
    required List<CampusCardBill> bills,
    required List<double?> balances,
    required this.startDate,
    required this.endDate,
    required this.queriedAt,
    this.balance,
  })  : assert(bills.length == balances.length),
        bills = List.unmodifiable(bills.take(limit)),
        balances = List.unmodifiable(balances.take(limit));

  static const limit = 5;
  final List<CampusCardBill> bills;
  final List<double?> balances;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime queriedAt;
  final CampusCardBalanceSnapshot? balance;

  factory CampusCardRecentSnapshot.fromJson(Map<String, dynamic> json) {
    final bills = _bills(json['bills']);
    final balances = (json['balances'] as List)
        .map((value) => value == null ? null : _number(value))
        .toList();
    final start = _date(json['startDate']);
    final end = _date(json['endDate']);
    if (bills.length > limit ||
        bills.length != balances.length ||
        start.isAfter(end)) {
      throw const FormatException('Invalid campus-card preview');
    }
    return CampusCardRecentSnapshot(
      bills: bills,
      balances: balances,
      startDate: start,
      endDate: end,
      queriedAt: _date(json['queriedAt']),
      balance: json['balance'] == null
          ? null
          : CampusCardBalanceSnapshot.fromJson(_map(json['balance'])),
    );
  }

  Map<String, dynamic> toJson() => {
        'bills': bills.map(_billJson).toList(),
        'balances': balances,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate.toIso8601String(),
        'queriedAt': queriedAt.toIso8601String(),
        if (balance != null) 'balance': balance!.toJson(),
      };
}

class CampusCardChartSnapshot {
  CampusCardChartSnapshot({
    required List<CampusCardBill> bills,
    required this.endDate,
    required this.queriedAt,
  }) : bills = List.unmodifiable(bills);

  final List<CampusCardBill> bills;
  final DateTime endDate;
  final DateTime queriedAt;

  factory CampusCardChartSnapshot.fromJson(Map<String, dynamic> json) =>
      CampusCardChartSnapshot(
        bills: _bills(json['bills']),
        endDate: _date(json['endDate']),
        queriedAt: _date(json['queriedAt']),
      );

  Map<String, dynamic> toJson() => {
        'bills': bills.map(_billJson).toList(),
        'endDate': endDate.toIso8601String(),
        'queriedAt': queriedAt.toIso8601String(),
      };
}

Map<String, dynamic> _map(Object? value) => value as Map<String, dynamic>;

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid campus-card cache text');
  }
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const FormatException('Invalid campus-card cache amount');
  }
  return value.toDouble();
}

DateTime _date(Object? value) => DateTime.parse(_text(value));

List<CampusCardBill> _bills(Object? value) => (value as List).map((item) {
      final json = _map(item);
      return CampusCardBill(
        name: _text(json['name']),
        payTime: _text(json['payTime']),
        amount: _number(json['amount']),
      );
    }).toList();

Map<String, dynamic> _billJson(CampusCardBill bill) => {
      'name': bill.name,
      'payTime': bill.payTime,
      'amount': bill.amount,
    };
