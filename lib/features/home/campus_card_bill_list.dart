import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/campus_card.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';

DateTime? _billDate(CampusCardBill bill) =>
    DateTime.tryParse(bill.payTime.trim().replaceAll(RegExp(r'\s+'), 'T'));

/// Keep equal and unparseable records, retaining their original relative order.
List<CampusCardBill> sortCampusCardBills(Iterable<CampusCardBill> bills) {
  final indexed = [
    for (final entry in bills.indexed)
      (entry.$1, entry.$2, _billDate(entry.$2)),
  ];
  indexed.sort((a, b) {
    final aTime = a.$3;
    final bTime = b.$3;
    final order = aTime == null
        ? (bTime == null ? 0 : 1)
        : bTime == null
            ? -1
            : bTime.compareTo(aTime);
    return order == 0 ? a.$1.compareTo(b.$1) : order;
  });
  return List.unmodifiable(indexed.map((entry) => entry.$2));
}

/// Reconstruct post-transaction balances from a current balance and a
/// contiguous newest-first snapshot. Unknown times and same-time transactions
/// cannot be ordered reliably, so their individual balances are unavailable.
List<double?> campusCardBalances(
  List<CampusCardBill> bills, {
  required double? currentBalance,
  required DateTime? balanceTime,
}) {
  final result = List<double?>.filled(bills.length, null);
  if (currentBalance == null ||
      balanceTime == null ||
      !currentBalance.isFinite) {
    return result;
  }
  final dates = [for (final bill in bills) _billDate(bill)];
  if (dates.any((date) => date == null)) return result;
  var cents = (currentBalance * 100).round();
  for (var index = 0; index < bills.length;) {
    final time = dates[index]!;
    var end = index + 1;
    while (end < bills.length && dates[end] == time) {
      end++;
    }
    if (!time.isAfter(balanceTime)) {
      if (end == index + 1) result[index] = cents / 100;
      for (var i = index; i < end; i++) {
        if (!bills[i].amount.isFinite) return List.filled(bills.length, null);
        // Positive amounts are debits; reverse each change to go backwards.
        cents += (bills[i].amount * 100).round();
      }
    }
    index = end;
  }
  return result;
}

/// The same transaction rows as the home preview, grouped by pinned months.
/// Callers pass the already sorted, locally filtered list.
List<Widget> campusCardBillSlivers(
  List<CampusCardBill> bills, {
  required BuildContext context,
  List<double?>? balances,
  bool retainPreviousBalances = false,
}) {
  final scaledFontSize = MediaQuery.textScalerOf(context).scale(12.5);
  final headerExtent = scaledFontSize > 12.5 ? scaledFontSize * 1.3 + 22 : 38.0;
  final groups = <({
    DateTime? month,
    List<CampusCardBill> bills,
    List<double?> balances
  })>[];
  for (final (index, bill) in bills.indexed) {
    final date = _billDate(bill);
    final month = date == null ? null : DateTime(date.year, date.month);
    if (groups.isEmpty || groups.last.month != month) {
      groups.add(
          (month: month, bills: <CampusCardBill>[], balances: <double?>[]));
    }
    groups.last.bills.add(bill);
    groups.last.balances.add(balances?[index]);
  }
  final slivers = <Widget>[];
  var precedingCount = 0;
  for (final group in groups) {
    // The API does not provide a transaction ID. Include an occurrence index
    // so identical transactions remain separate while cumulative snapshots
    // retain the state of rows already on screen.
    final occurrences = <(String, String, double), int>{};
    final keys = <ValueKey<(String, String, double, int)>>[];
    for (final bill in group.bills) {
      final identity = (bill.name, bill.payTime, bill.amount);
      final occurrence =
          occurrences.update(identity, (value) => value + 1, ifAbsent: () => 0);
      keys.add(ValueKey((bill.name, bill.payTime, bill.amount, occurrence)));
    }
    final indexes = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    final firstIndex = precedingCount;
    precedingCount += group.bills.length;
    slivers.add(
      SliverMainAxisGroup(key: ValueKey(group.month), slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _CampusCardMonthHeaderDelegate(group.month, headerExtent),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.separated(
            itemCount: group.bills.length,
            findItemIndexCallback: (key) => indexes[key],
            itemBuilder: (context, index) => _AnimatedCampusCardBillRow(
              key: keys[index],
              index: firstIndex + index,
              bill: group.bills[index],
              balanceAfter: group.balances[index],
              retainPreviousBalance: retainPreviousBalances,
            ),
            separatorBuilder: (context, index) =>
                const CampusCardBillSeparator(),
          ),
        ),
      ]),
    );
  }
  return slivers;
}

class _AnimatedCampusCardBillRow extends StatefulWidget {
  const _AnimatedCampusCardBillRow({
    super.key,
    required this.index,
    required this.bill,
    this.balanceAfter,
    this.retainPreviousBalance = false,
  });

  final int index;
  final CampusCardBill bill;
  final double? balanceAfter;
  final bool retainPreviousBalance;

  @override
  State<_AnimatedCampusCardBillRow> createState() =>
      _AnimatedCampusCardBillRowState();
}

class _AnimatedCampusCardBillRowState extends State<_AnimatedCampusCardBillRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.12, 0),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
        child: FadeTransition(
          opacity: _entrance,
          child: CampusCardBillRow(
              bill: widget.bill,
              balanceAfter: widget.balanceAfter,
              retainPreviousBalance: widget.retainPreviousBalance),
        ),
      );
}

class CampusCardBillSeparator extends StatelessWidget {
  const CampusCardBillSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      CustomBackgroundScope.maybeOf(context) != null
          ? const SizedBox.shrink()
          : Divider(height: 1, color: context.shuyoColors.border);
}

class CampusCardBillRow extends StatefulWidget {
  const CampusCardBillRow({
    super.key,
    required this.bill,
    this.balanceAfter,
    this.retainPreviousBalance = false,
  });

  final CampusCardBill bill;
  final double? balanceAfter;
  final bool retainPreviousBalance;

  @override
  State<CampusCardBillRow> createState() => _CampusCardBillRowState();
}

class _CampusCardBillRowState extends State<CampusCardBillRow> {
  late double? _displayedBalance = widget.balanceAfter;

  @override
  void didUpdateWidget(covariant CampusCardBillRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldBill = oldWidget.bill;
    final newBill = widget.bill;
    if (oldBill.name != newBill.name ||
        oldBill.payTime != newBill.payTime ||
        oldBill.amount != newBill.amount) {
      _displayedBalance = null;
    }
    if (widget.balanceAfter != null || !widget.retainPreviousBalance) {
      _displayedBalance = widget.balanceAfter;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final bill = widget.bill;
    // The portal records debits as positive and credits as negative.
    final balanceChange = -bill.amount;
    final sign = balanceChange > 0
        ? '+ '
        : balanceChange < 0
            ? '- '
            : '';
    final amountText = '$sign¥${balanceChange.abs().toStringAsFixed(2)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: LayoutBuilder(builder: (context, constraints) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bill.name,
                      style: ShuYoTextStyles.title(
                          color: colors.textPrimary,
                          size: 15,
                          weight: FontWeight.w500)),
                  const SizedBox(height: 6),
                  Text(bill.payTime,
                      style:
                          TextStyle(color: colors.textTertiary, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 20),
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: constraints.maxWidth * 0.45),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(amountText,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  Text(
                      _displayedBalance == null
                          ? '余额 —'
                          : '余额 ¥${_displayedBalance!.toStringAsFixed(2)}',
                      textAlign: TextAlign.end,
                      style:
                          TextStyle(color: colors.textTertiary, fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _CampusCardMonthHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _CampusCardMonthHeaderDelegate(this.month, this.extent);

  final DateTime? month;
  final double extent;

  @override
  double get minExtent => maxExtent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      _CampusCardMonthHeader(month: month);

  @override
  bool shouldRebuild(_CampusCardMonthHeaderDelegate oldDelegate) =>
      month != oldDelegate.month || extent != oldDelegate.extent;
}

// Keep theme dependencies on an element inside the cached sliver child so a
// theme change updates an already pinned header without requiring a scroll.
class _CampusCardMonthHeader extends StatelessWidget {
  const _CampusCardMonthHeader({required this.month});

  final DateTime? month;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final date = month;
    final label = date == null ? '日期未知' : '${date.year}年${date.month}月';
    final id = date == null
        ? 'unknown'
        : '${date.year}-${date.month.toString().padLeft(2, '0')}';
    return Material(
      key: ValueKey('campus-card-month-$id'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(
          label,
          style: ShuYoTextStyles.meta(
            color: colors.textSecondary,
            size: 12.5,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
