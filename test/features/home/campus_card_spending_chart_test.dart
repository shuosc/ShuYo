import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/campus_card.dart';
import 'package:shuyo/data/services/campus_card_service.dart'
    show CampusCardAuthRequiredException, CampusCardException;
import 'package:shuyo/features/home/campus_card_spending_chart.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

final _end = DateTime(2026, 1, 3);

CampusCardBill _bill(String date, double amount) => CampusCardBill(
      name: '测试消费',
      payTime: date,
      amount: amount,
    );

List<CampusCardBill> _bills() => [
      _bill('2025-12-28 00:00:00', 1.25),
      _bill('2025-12-28 00:00:00', 1.25),
      _bill('2026-01-03 23:59:59', 4.2),
      _bill('2025-12-10 12:00:00', 12),
    ];

void main() {
  group('daily spending aggregation', () {
    test('uses inclusive calendar dates, fills gaps and keeps repeated charges',
        () {
      final result = aggregateCampusCardDailySpending([
        ..._bills(),
        _bill('2025-12-28 12:00:00', -99),
        _bill('2025-12-29', 0),
        _bill('2025-12-27 23:59:59', 40),
        _bill('2026-01-04 00:00:00', 50),
        _bill('2025-12-32 12:00:00', 60),
        _bill('2026-01-03 24:00:00', 70),
        _bill('2026-01-03 12:60:00', 80),
        _bill('not-a-date', 90),
        _bill('2026-01-03', double.nan),
        _bill('2026-01-03', double.infinity),
      ], endDate: DateTime(2026, 1, 3, 8), days: 7);

      expect(result, hasLength(7));
      expect(result.first.date, DateTime(2025, 12, 28));
      expect(result.last.date, _end);
      expect(result.map((day) => day.amount), [2.5, 0, 0, 0, 0, 0, 4.2]);
      expect(result.map((day) => day.creditAmount), [99, 0, 0, 0, 0, 0, 0]);
      expect(() => result.clear(), throwsUnsupportedError);
    });

    test('30 days crosses leap day and rejects normalized impossible dates',
        () {
      final result = aggregateCampusCardDailySpending([
        _bill('2024-02-01', 0.1),
        _bill('2024-02-01', 0.2),
        _bill('2024-02-29  12:00:00', 2),
        _bill('2024-03-01T23:59:59', 3),
        _bill('2024-02-30 12:00:00', 100),
        _bill('2024-01-31', 100),
      ], endDate: DateTime.utc(2024, 3, 1, 1), days: 30);
      expect(result.first.date, DateTime(2024, 2, 1));
      expect(result[28].date, DateTime(2024, 2, 29));
      expect(result[28].amount, 2);
      expect(result.last.amount, 3);
      expect(result.first.amount, closeTo(0.3, 0.000001));
    });

    test('spending and incoming funds never cancel and duplicates remain', () {
      final result = aggregateCampusCardDailySpending([
        _bill('2026-01-03', 10),
        _bill('2026-01-03', 4),
        _bill('2026-01-03', -50),
        _bill('2026-01-03', -3),
        _bill('2026-01-03', -3),
        _bill('2026-01-03', -0.0),
        _bill('2026-01-04', -999),
        _bill('2025-12-32', -999),
        _bill('2026-01-03', double.negativeInfinity),
      ], endDate: _end, days: 7);
      expect(result.last.amount, 14);
      expect(result.last.creditAmount, 56);
      expect(result.take(6).map((day) => day.creditAmount), everyElement(0));
    });

    test('empty input is zero-filled and invalid day counts are rejected', () {
      final result =
          aggregateCampusCardDailySpending(const [], endDate: _end, days: 7);
      expect(result.map((day) => day.amount), everyElement(0));
      expect(result.map((day) => day.creditAmount), everyElement(0));
      expect(
          () => aggregateCampusCardDailySpending(const [],
              endDate: _end, days: 0),
          throwsArgumentError);
    });
  });

  testWidgets('defaults to seven days and switches locally to thirty days',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, bills: _bills());
      expect(find.text('消费趋势'), findsOneWidget);
      expect(find.byKey(const ValueKey('campus-card-chart-selected-date')),
          findsNothing);
      expect(find.text('消费'), findsOneWidget);
      expect(find.text('充值'), findsOneWidget);
      expect(find.semantics.byLabel(RegExp(r'^202[56]年.*，充值入账 ¥ ')),
          findsExactly(7));
      expect(find.semantics.byLabel('2025年12月10日，充值入账 ¥ 0.00，消费 ¥ 12.00'),
          findsNothing);

      await tester
          .tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
      await tester.pump();
      expect(find.semantics.byLabel(RegExp(r'^202[56]年.*，充值入账 ¥ ')),
          findsExactly(30));
      final olderDay =
          find.semantics.byLabel('2025年12月10日，充值入账 ¥ 0.00，消费 ¥ 12.00');
      final node = olderDay.evaluate().single;
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(find.text('2025-12-10'), findsOneWidget);
      expect(_selectedValue(tester, 'amount'), '¥ 12.00');

      await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-7')));
      await tester.pump();
      expect(find.byKey(const ValueKey('campus-card-chart-selected-date')),
          findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('tap and horizontal drag select dates at both plot edges',
      (tester) async {
    await _pump(tester, bills: [
      ..._bills(),
      _bill('2025-12-28 12:00:00', -20),
    ]);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final chart = find.byKey(const ValueKey('campus-card-spending-chart'));
    final chartBounds = tester.getRect(chart);
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    expect(tester.getRect(plot), bounds);
    expect(tester.getRect(chart), chartBounds);
    expect(
        tester
            .getBottomRight(
                find.byKey(const ValueKey('campus-card-chart-selection')))
            .dy,
        lessThanOrEqualTo(bounds.top));
    expect(find.text('2025-12-28'), findsOneWidget);
    expect(_selectedValue(tester, 'amount'), '¥ 2.50');
    expect(_selectedValue(tester, 'credit-amount'), '¥ 20.00');
    final date = find.byKey(const ValueKey('campus-card-chart-selected-date'));
    final spending =
        find.byKey(const ValueKey('campus-card-chart-selected-amount-row'));
    final credit = find
        .byKey(const ValueKey('campus-card-chart-selected-credit-amount-row'));
    expect(tester.getTopRight(date).dx,
        lessThanOrEqualTo(tester.getTopLeft(credit).dx));
    expect(
        tester.getCenter(date).dy,
        closeTo(
            (tester.getTopLeft(credit).dy + tester.getBottomLeft(spending).dy) /
                2,
            0.01));
    final dateCenter = tester.getCenter(date).dx;
    expect(tester.getTopLeft(spending).dy,
        greaterThan(tester.getBottomLeft(credit).dy));
    expect(find.descendant(of: spending, matching: find.text('消费')),
        findsOneWidget);
    expect(
        find.descendant(of: credit, matching: find.text('充值')), findsOneWidget);
    expect(
        find.descendant(
            of: credit, matching: find.byIcon(Icons.arrow_upward_rounded)),
        findsOneWidget);
    expect(
        find.descendant(
            of: spending, matching: find.byIcon(Icons.arrow_downward_rounded)),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('campus-card-chart-currency')), findsNothing);

    final drag =
        await tester.startGesture(Offset(bounds.left + 1, bounds.center.dy));
    await drag.moveTo(Offset(bounds.right - 1, bounds.center.dy));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(find.text('2026-01-03'), findsOneWidget);
    expect(_selectedValue(tester, 'amount'), '¥ 4.20');
    expect(_selectedValue(tester, 'credit-amount'), '¥ 0.00');
    expect(tester.getCenter(date).dx, closeTo(dateCenter, 0.01));
    expect(tester.getRect(plot), bounds);
    expect(tester.getRect(chart), chartBounds);
  });

  testWidgets('taps ease the unchanged underline and crossfade bar highlights',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final original = _recordedUnderline(tester);
    final bars = _recordedBars(tester);
    final step = bars[1].shape.left - bars[0].shape.left;
    final targetX = original.start.dx - step;
    await tester.tapAt(Offset(
        bounds.left + (original.start.dx + original.end.dx) / 2 - step,
        bounds.center.dy));
    await tester.pump();
    expect(find.text('2026-01-02'), findsOneWidget);
    expect(_recordedUnderline(tester).start, original.start);

    await tester.pump(const Duration(milliseconds: 55));
    final moving = _recordedUnderline(tester);
    final eased = Curves.easeOutCubic.transform(55 / 220);
    expect(moving.start.dx, closeTo(original.start.dx - step * eased, .01));
    _expectUnderlineStyle(moving, original);
    final movingBars = _recordedBars(tester);
    expect(movingBars[5].color.a, greaterThan(.55));
    expect(movingBars[5].color.a, lessThan(1));
    expect(movingBars[6].color.a, greaterThan(.55));
    expect(movingBars[6].color.a, lessThan(1));
    final movingSpending = _recordedOutlines(tester);
    expect(movingSpending[5].color.a, greaterThan(.75));
    expect(movingSpending[5].color.a, lessThan(1));
    expect(movingSpending[6].color.a, greaterThan(.75));
    expect(movingSpending[6].color.a, lessThan(1));

    await tester.pumpAndSettle();
    final settled = _recordedUnderline(tester);
    expect(settled.start.dx, closeTo(targetX, .01));
    _expectUnderlineStyle(settled, original);
    expect(_recordedBars(tester)[5].color.a, 1);
    expect(_recordedBars(tester)[6].color.a, closeTo(.55, .001));
    expect(_recordedOutlines(tester)[5].color.a, 1);
    expect(_recordedOutlines(tester)[6].color.a, closeTo(.75, .001));
  });

  testWidgets('rapid taps retarget the underline from its current position',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final original = _recordedUnderline(tester);
    final bars = _recordedBars(tester);
    final step = bars[1].shape.left - bars[0].shape.left;
    final lastX = (original.start.dx + original.end.dx) / 2;
    await tester
        .tapAt(Offset(bounds.left + lastX - step * 6, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final interrupted = _recordedUnderline(tester);

    await tester
        .tapAt(Offset(bounds.left + lastX - step * 2, bounds.center.dy));
    await tester.pump();
    expect(_recordedUnderline(tester).start, interrupted.start);
    expect(find.text('2026-01-01'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 55));
    final reversed = _recordedUnderline(tester);
    expect(reversed.start.dx, greaterThan(interrupted.start.dx));
    expect(reversed.start.dx, lessThan(original.start.dx - step * 2));
    await tester.pumpAndSettle();
    expect(_recordedUnderline(tester).start.dx,
        closeTo(original.start.dx - step * 2, .01));
    _expectUnderlineStyle(_recordedUnderline(tester), original);
  });

  testWidgets('dragging follows the finger without lag and snaps on release',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final chart = find.byKey(const ValueKey('campus-card-spending-chart'));
    final chartBounds = tester.getRect(chart);
    final original = _recordedUnderline(tester);
    final bars = _recordedBars(tester);
    final step = bars[1].shape.left - bars[0].shape.left;
    final firstX = (original.start.dx + original.end.dx) / 2 - step * 6;
    final gesture = await tester
        .startGesture(Offset(bounds.left + firstX, bounds.center.dy));
    await gesture
        .moveTo(Offset(bounds.left + firstX + step * 3.25, bounds.center.dy));
    await tester.pump();
    final dragging = _recordedUnderline(tester);
    expect((dragging.start.dx + dragging.end.dx) / 2,
        closeTo(firstX + step * 3.25, .01));
    expect(find.text('2025-12-31'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 80));
    expect(_recordedUnderline(tester).start, dragging.start);

    await gesture
        .moveTo(Offset(bounds.left + firstX + step * 2.25, bounds.center.dy));
    await tester.pump();
    final painter = tester.widget<CustomPaint>(plot).painter;
    await gesture
        .moveTo(Offset(bounds.left + firstX + step * 2.4, bounds.center.dy));
    await tester.pump();
    expect(tester.widget<CustomPaint>(plot).painter, same(painter),
        reason:
            'Moving inside a date should only repaint, not rebuild the chart');
    final beforeRelease = _recordedUnderline(tester);
    expect((beforeRelease.start.dx + beforeRelease.end.dx) / 2,
        closeTo(firstX + step * 2.4, .01));
    expect(find.text('2025-12-30'), findsOneWidget);
    _expectUnderlineStyle(beforeRelease, original);

    await gesture.up();
    await tester.pump();
    expect(_recordedUnderline(tester).start, beforeRelease.start);
    await tester.pump(const Duration(milliseconds: 55));
    expect(
        _recordedUnderline(tester).start.dx, lessThan(beforeRelease.start.dx));
    await tester.pumpAndSettle();
    final settled = _recordedUnderline(tester);
    expect((settled.start.dx + settled.end.dx) / 2,
        closeTo(firstX + step * 2, .01));
    _expectUnderlineStyle(settled, original);
    expect(tester.getRect(plot), bounds);
    expect(tester.getRect(chart), chartBounds);
    expect(tester.takeException(), isNull);
  });

  for (final days in [7, 30]) {
    testWidgets('dragging clamps and cancellation snaps in the $days-day view',
        (tester) async {
      await _pump(tester, bills: _motionBills(), disableAnimations: false);
      if (days == 30) {
        await tester
            .tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
        await tester.pumpAndSettle();
      }
      final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
      final bounds = tester.getRect(plot);
      final original = _recordedUnderline(tester);
      final bars = _recordedBars(tester);
      final step = bars[1].shape.left - bars[0].shape.left;
      final firstX =
          bars.first.shape.left + (original.end.dx - original.start.dx) / 2;
      final gesture = await tester.startGesture(bounds.center);
      await gesture.moveTo(Offset(bounds.left - 80, bounds.center.dy));
      await tester.pump();
      expect(_recordedUnderline(tester).start.dx,
          closeTo(bars.first.shape.left, .01));
      _expectUnderlineStyle(_recordedUnderline(tester), original);

      await gesture.moveTo(Offset(bounds.right + 80, bounds.center.dy));
      await tester.pump();
      expect(_recordedUnderline(tester).start.dx,
          closeTo(bars.last.shape.left, .01));
      await gesture
          .moveTo(Offset(bounds.left + firstX + step * 1.3, bounds.center.dy));
      await tester.pump();
      final beforeCancel = _recordedUnderline(tester);
      expect(beforeCancel.start.dx,
          closeTo(bars.first.shape.left + step * 1.3, .01));
      await gesture.cancel();
      await tester.pump();
      expect(_recordedUnderline(tester).start, beforeCancel.start);
      await tester.pumpAndSettle();
      expect(_recordedUnderline(tester).start.dx,
          closeTo(bars[1].shape.left, .01));
      _expectUnderlineStyle(_recordedUnderline(tester), original);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'range changes retire motion without reusing old column positions',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 55));
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    final thirtyDayLine = _recordedUnderline(tester);
    final thirtyDayBars = _recordedBars(tester);
    expect(thirtyDayBars, hasLength(30));
    expect(thirtyDayLine.start.dx, closeTo(thirtyDayBars[23].shape.left, .01));
    expect(find.byKey(const ValueKey('campus-card-chart-selected-date')),
        findsNothing);
    await tester.pumpAndSettle();
    expect(_recordedUnderline(tester).start, thirtyDayLine.start);

    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-7')));
    await tester.pumpAndSettle();
    expect(_recordedUnderline(tester).start.dx,
        closeTo(_recordedBars(tester).first.shape.left, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshing the same snapshot does not restart selection motion',
      (tester) async {
    final bills = _motionBills();
    await _pump(tester, bills: bills, disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final original = _recordedUnderline(tester);
    final targetX = _recordedBars(tester).first.shape.left;
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 55));
    final moving = _recordedUnderline(tester);
    final oldPainter = tester.widget<CustomPaint>(plot).painter!;
    await _pump(tester, bills: bills, loading: true, disableAnimations: false);
    expect(_recordedUnderline(tester).start, moving.start);
    expect(tester.widget<CustomPaint>(plot).painter!.shouldRepaint(oldPainter),
        isFalse);
    await tester.pump(const Duration(milliseconds: 55));
    expect(
        _recordedUnderline(tester).start.dx,
        closeTo(
            original.start.dx +
                (targetX - original.start.dx) *
                    Curves.easeOutCubic.transform(.5),
            .01));
    await tester.pumpAndSettle();
    expect(_recordedUnderline(tester).start.dx, closeTo(targetX, .01));
  });

  testWidgets(
      'reduced motion snaps both ongoing and new selections immediately',
      (tester) async {
    final bills = _motionBills();
    await _pump(tester, bills: bills, disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 55));
    await _pump(tester, bills: bills, disableAnimations: true);
    expect(_recordedUnderline(tester).start.dx,
        closeTo(_recordedBars(tester).first.shape.left, .01));
    expect(tester.hasRunningAnimations, isFalse);

    await tester.tapAt(Offset(bounds.right - 1, bounds.center.dy));
    await tester.pump();
    expect(_recordedUnderline(tester).start.dx,
        closeTo(_recordedBars(tester).last.shape.left, .01));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('vertical scrolling does not reveal or animate a date selection',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    final original = _recordedUnderline(tester);
    final gesture = await tester.startGesture(bounds.center);
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('campus-card-chart-selected-date')),
        findsNothing);
    expect(_recordedUnderline(tester).start, original.start);
  });

  testWidgets('disposing a chart during selection motion cancels its ticker',
      (tester) async {
    await _pump(tester, bills: _motionBills(), disableAnimations: false);
    final bounds =
        tester.getRect(find.byKey(const ValueKey('campus-card-chart-plot')));
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 55));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen readers announce recharge before spending',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, bills: [
        _bill('2026-01-03', 10),
        _bill('2026-01-03', -20),
      ]);
      final day = find.semantics.byLabel('2026年1月3日，充值入账 ¥ 20.00，消费 ¥ 10.00');
      final node = day.evaluate().single;
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(find.semantics.byLabel('2026-01-03，充值 ¥ 20.00，消费 ¥ 10.00'),
          findsOneWidget);
      expect(_selectedValue(tester, 'credit-amount'), '¥ 20.00');
      expect(_selectedValue(tester, 'amount'), '¥ 10.00');
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('screen readers can select a zero-spending day', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, bills: _bills());
      final label = find.semantics.byLabel('2025年12月29日，充值入账 ¥ 0.00，消费 ¥ 0.00');
      final node = label.evaluate().single;
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      expect(find.text('2025-12-29'), findsOneWidget);
      expect(_selectedValue(tester, 'amount'), '¥ 0.00');
      expect(
          label
              .evaluate()
              .single
              .getSemanticsData()
              .flagsCollection
              .isSelected
              .toBoolOrNull(),
          isTrue);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('initial loading reserves chart space and errors hide amounts',
      (tester) async {
    var retries = 0;
    await _pump(tester, bills: null, loading: true);
    expect(find.byKey(const ValueKey('campus-card-chart-loading')),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-chart-plot')), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-chart-selected-amount')),
        findsNothing);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('campus-card-chart-loading')))
            .height,
        greaterThanOrEqualTo(184));
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    expect(find.text('¥ 4.20'), findsNothing);

    await _pump(tester,
        bills: _bills(),
        error: StateError('private diagnostic'),
        onRetry: () => retries++);
    expect(find.text('消费趋势暂时无法加载'), findsOneWidget);
    expect(find.textContaining('private diagnostic'), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-chart-plot')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-retry')));
    expect(retries, 1);

    await _pump(tester, bills: _bills());
    expect(
        find.byKey(const ValueKey('campus-card-chart-plot')), findsOneWidget);
    expect(find.text('消费'), findsOneWidget);
  });

  testWidgets('refresh retains completed chart, selection and painter data',
      (tester) async {
    final bills = _bills();
    await _pump(tester, bills: bills);
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final bounds = tester.getRect(plot);
    await tester.tapAt(Offset(bounds.left + 1, bounds.center.dy));
    await tester.pump();
    final oldPainter = tester.widget<CustomPaint>(plot).painter!;
    final selectedDate = tester
        .widget<Text>(
            find.byKey(const ValueKey('campus-card-chart-selected-date')))
        .data;
    final chartSize = tester
        .getSize(find.byKey(const ValueKey('campus-card-spending-chart')));

    await _pump(tester, bills: bills, loading: true);
    final newPainter = tester.widget<CustomPaint>(plot).painter!;
    expect(newPainter.shouldRepaint(oldPainter), isFalse);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('campus-card-spending-chart'))),
        chartSize);
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('campus-card-chart-selected-date')))
            .data,
        selectedDate);
    expect(
        find.byKey(const ValueKey('campus-card-chart-loading')), findsNothing);
    expect(find.text('充值含其他入账（如退款）'), findsNothing);

    // An account reset removes the snapshot even if loading has stopped.
    await _pump(tester, bills: null);
    expect(plot, findsNothing);
    expect(find.text('暂无消费趋势'), findsOneWidget);
  });

  testWidgets('an empty completed snapshot remains visible during refresh',
      (tester) async {
    const bills = <CampusCardBill>[];
    await _pump(tester, bills: bills);
    expect(find.text('近7天暂无收支'), findsOneWidget);
    await _pump(tester, bills: bills, loading: true);
    expect(find.text('近7天暂无收支'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('campus-card-chart-plot')), findsOneWidget);
  });

  testWidgets('authentication and account mismatch expose the login action',
      (tester) async {
    var logins = 0;
    for (final error in [
      const CampusCardAuthRequiredException(),
      const CampusCardException('accountMismatch', 'private identity'),
    ]) {
      await _pump(tester,
          bills: _bills(), error: error, onRetry: () => logins++);
      expect(find.text('登录校园账户'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.byKey(const ValueKey('campus-card-chart-selected-amount')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('campus-card-chart-retry')));
      await tester.pump();
    }
    expect(logins, 2);
  });

  testWidgets(
      'empty and single-series data preserve recharge and spending styles',
      (tester) async {
    await _pump(tester, bills: const []);
    expect(find.text('近7天暂无收支'), findsOneWidget);
    await _selectLastDay(tester);
    expect(_selectedValue(tester, 'amount'), '¥ 0.00');
    await _pump(tester, bills: [_bill('2026-01-03', -120)]);
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    await _selectLastDay(tester);
    expect(find.byKey(const ValueKey('campus-card-chart-empty')), findsNothing);
    expect(_selectedValue(tester, 'amount'), '¥ 0.00');
    expect(_selectedValue(tester, 'credit-amount'), '¥ 120.00');
    expect(_recordedBars(tester), hasLength(1));
    expect(_recordedOutlines(tester), isEmpty);

    await _pump(tester, bills: [_bill('2026-01-03', 120)]);
    await _selectLastDay(tester);
    expect(_selectedValue(tester, 'amount'), '¥ 120.00');
    expect(_selectedValue(tester, 'credit-amount'), '¥ 0.00');
    expect(_recordedBars(tester), isEmpty);
    expect(_recordedOutlines(tester), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px with large text and a single spending day remains usable',
      (tester) async {
    await _pump(tester, bills: [_bill('2026-01-03', 123.45)], textScale: 2);
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final plotBounds = tester.getRect(plot);
    final chart = find.byKey(const ValueKey('campus-card-spending-chart'));
    final chartBounds = tester.getRect(chart);
    await _selectLastDay(tester);
    expect(tester.getRect(plot), plotBounds);
    expect(tester.getRect(chart), chartBounds);
    expect(_selectedValue(tester, 'amount'), '¥ 123.45');
    expect(
        tester
            .getBottomRight(
                find.byKey(const ValueKey('campus-card-chart-selection')))
            .dy,
        lessThanOrEqualTo(tester
            .getTopLeft(find.byKey(const ValueKey('campus-card-chart-plot')))
            .dy));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('campus-card-chart-plot')))
            .height,
        150);
    await tester.ensureVisible(
        find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    await _selectLastDay(tester);
    expect(_selectedValue(tester, 'amount'), '¥ 123.45');
    expect(tester.takeException(), isNull);
  });

  testWidgets('chart starts with legend and without persistent metrics',
      (tester) async {
    await _pump(tester, bills: [
      _bill('2026-01-03', 21),
      _bill('2026-01-03', -50),
    ]);
    expect(find.text('消费'), findsOneWidget);
    expect(find.text('充值'), findsOneWidget);
    final spending = find.byKey(const ValueKey('campus-card-chart-legend-消费'));
    final credit = find.byKey(const ValueKey('campus-card-chart-legend-充值'));
    expect(tester.getTopLeft(spending).dy,
        greaterThan(tester.getBottomLeft(credit).dy));
    expect(tester.getTopLeft(credit).dx, tester.getTopLeft(spending).dx);
    expect(
        find.byKey(const ValueKey('campus-card-chart-currency')), findsNothing);
    expect(find.text('消费合计'), findsNothing);
    expect(find.text('日均消费'), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-chart-selected-date')),
        findsNothing);
    expect(find.textContaining('充值含其他'), findsNothing);
  });

  testWidgets(
      'daily grouped columns use theme tokens and a shared zero baseline',
      (tester) async {
    await _pump(tester, bills: [
      _bill('2026-01-03', 10),
      _bill('2026-01-03', -20),
    ]);
    final bars = _recordedBars(tester);
    final outlines = _recordedOutlines(tester);
    final colors = ShuYoThemes.byId(ShuYoThemes.defaultId).colors;
    expect(bars, hasLength(1));
    expect(bars[0].color.toARGB32(), colors.accent.toARGB32());
    expect(outlines, hasLength(1));
    expect(outlines.single.color.toARGB32(), colors.accent.toARGB32());
    final spendingLegend = tester.widget<Container>(
        find.byKey(const ValueKey('campus-card-chart-legend-消费')));
    final creditLegend = tester.widget<Container>(
        find.byKey(const ValueKey('campus-card-chart-legend-充值')));
    expect((creditLegend.decoration! as BoxDecoration).border, isNull);
    expect((creditLegend.decoration! as BoxDecoration).color, colors.accent);
    expect((spendingLegend.decoration! as BoxDecoration).border, isNotNull);
    expect((spendingLegend.decoration! as BoxDecoration).color, isNull);
    expect(
        ((spendingLegend.decoration! as BoxDecoration).border! as Border)
            .top
            .color
            .toARGB32(),
        colors.accent.toARGB32());
    await _selectLastDay(tester);
    expect(
        tester
            .widget<Text>(find.byKey(
                const ValueKey('campus-card-chart-selected-credit-amount')))
            .style!
            .color!
            .toARGB32(),
        colors.accent.toARGB32());
    final creditShape = bars.single.shape;
    final spendingShape =
        outlines.single.shape.inflate(outlines.single.strokeWidth / 2);
    expect(creditShape.bottom, closeTo(spendingShape.bottom, 0.001));
    expect(spendingShape.height / creditShape.height, closeTo(0.5, 0.001));
    expect(creditShape.right, lessThan(spendingShape.left));
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    expect(plot, paintsExactlyCountTimes(#drawPath, 0));
    expect(plot, paintsExactlyCountTimes(#drawCircle, 0));
    await _pump(tester, themeId: 'ink_teal', bills: [
      _bill('2026-01-03', 10),
      _bill('2026-01-03', -20),
    ]);
    await tester.pumpAndSettle();
    final darkBars = _recordedBars(tester);
    final darkColors = ShuYoThemes.byId('ink_teal').colors;
    expect(darkBars[0].color.toARGB32(), darkColors.accent.toARGB32());
    final darkOutlines = _recordedOutlines(tester);
    expect(darkBars, hasLength(1));
    expect(darkOutlines.single.color.toARGB32(), darkColors.accent.toARGB32());
    expect(darkOutlines.single.color.toARGB32(),
        isNot(outlines.single.color.toARGB32()));
    await _pump(tester, themeId: ShuYoThemes.systemDarkId, bills: [
      _bill('2026-01-03', 10),
      _bill('2026-01-03', -20),
    ]);
    await tester.pumpAndSettle();
    final similarThemeBars = _recordedBars(tester);
    final similarThemeOutlines = _recordedOutlines(tester);
    final similarColors = ShuYoThemes.byId(ShuYoThemes.systemDarkId).colors;
    expect(
        similarThemeBars[0].color.toARGB32(), similarColors.accent.toARGB32());
    expect(similarThemeBars, hasLength(1));
    expect(similarThemeOutlines.single.color.toARGB32(),
        similarColors.accent.toARGB32());
  });

  testWidgets(
      'thirty paired columns stay separate on narrow screens and select by day',
      (tester) async {
    await _pump(tester, textScale: 2, bills: [
      for (var index = 0; index < 30; index++) ...[
        _bill(DateTime(2026, 1, 3 - 29 + index).toIso8601String(), index + 1.0),
        _bill(DateTime(2026, 1, 3 - 29 + index).toIso8601String(),
            -(index + 1.0) * 2),
      ],
    ]);
    await tester.tap(find.byKey(const ValueKey('campus-card-chart-range-30')));
    await tester.pump();
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    await tester.ensureVisible(plot);
    final bars = _recordedBars(tester);
    final outlines = _recordedOutlines(tester);
    expect(bars, hasLength(30));
    expect(outlines, hasLength(30));
    for (var index = 0; index < outlines.length; index++) {
      final outline = outlines[index];
      expect(outline.strokeWidth, greaterThan(0));
      expect(outline.shape.width, greaterThan(outline.strokeWidth));
      expect(outline.shape.height, greaterThan(outline.strokeWidth));
      final spendingShape = outline.shape.inflate(outline.strokeWidth / 2);
      expect(bars[index].shape.right, lessThan(spendingShape.left));
      expect(bars[index].shape.bottom, closeTo(spendingShape.bottom, .001));
      expect(
          spendingShape.height / bars[index].shape.height, closeTo(.5, .001));
    }
    final width = tester.getSize(plot).width;
    for (var index = 0; index < bars.length; index++) {
      final rect = bars[index].shape;
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
      if (index > 0) expect(bars[index - 1].shape.right, lessThan(rect.left));
    }
    final localCenter = bars[14].shape.outerRect.center;
    await tester.tapAt(tester.getTopLeft(plot) + localCenter);
    await tester.pump();
    expect(find.text('2025-12-19'), findsOneWidget);
    expect(_selectedValue(tester, 'amount'), '¥ 15.00');
    expect(_selectedValue(tester, 'credit-amount'), '¥ 30.00');
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest selection follows a new end date', (tester) async {
    await _pump(tester, bills: _bills());
    await _selectLastDay(tester);
    await _pump(tester,
        bills: [_bill('2026-01-04', 5)], endDate: DateTime(2026, 1, 4));
    expect(find.text('2026-01-04'), findsOneWidget);
    expect(_selectedValue(tester, 'amount'), '¥ 5.00');
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required List<CampusCardBill>? bills,
  DateTime? endDate,
  bool loading = false,
  Object? error,
  VoidCallback? onRetry,
  double textScale = 1,
  String? themeId,
  bool disableAnimations = true,
}) async {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(themeId ?? ShuYoThemes.defaultId).themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations),
      child: child!,
    ),
    home: Scaffold(
        body: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: CampusCardSpendingChart(
        bills: bills,
        endDate: endDate ?? _end,
        loading: loading,
        error: error,
        onRetry: onRetry,
      ),
    )),
  ));
  await tester.pump();
}

String? _selectedValue(WidgetTester tester, String suffix) => tester
    .widget<Text>(find.byKey(ValueKey('campus-card-chart-selected-$suffix')))
    .data;

Future<void> _selectLastDay(WidgetTester tester) async {
  final bounds =
      tester.getRect(find.byKey(const ValueKey('campus-card-chart-plot')));
  await tester.tapAt(Offset(bounds.right - 1, bounds.center.dy));
  await tester.pump();
}

List<({RRect shape, Color color})> _recordedBars(WidgetTester tester) {
  return _recordedShapes(tester)
      .where((shape) => shape.style == PaintingStyle.fill)
      .map((shape) => (shape: shape.shape, color: shape.color))
      .toList();
}

List<({RRect shape, Color color, double strokeWidth})> _recordedOutlines(
    WidgetTester tester) {
  return _recordedShapes(tester)
      .where((shape) => shape.style == PaintingStyle.stroke)
      .map((shape) => (
            shape: shape.shape,
            color: shape.color,
            strokeWidth: shape.strokeWidth,
          ))
      .toList();
}

List<({RRect shape, Color color, PaintingStyle style, double strokeWidth})>
    _recordedShapes(WidgetTester tester) {
  final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
  final painter = tester.widget<CustomPaint>(plot).painter!;
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, tester.getSize(plot));
  return canvas.invocations
      .where((record) => record.invocation.memberName == #drawRRect)
      .map((record) => (
            shape: record.invocation.positionalArguments[0] as RRect,
            color: (record.invocation.positionalArguments[1] as Paint).color,
            style: (record.invocation.positionalArguments[1] as Paint).style,
            strokeWidth:
                (record.invocation.positionalArguments[1] as Paint).strokeWidth,
          ))
      .toList();
}

List<CampusCardBill> _motionBills() => [
      for (var index = 0; index < 30; index++) ...[
        _bill(_end.subtract(Duration(days: index)).toIso8601String(), 1),
        _bill(_end.subtract(Duration(days: index)).toIso8601String(), -2),
      ],
    ];

typedef _RecordedUnderline = ({
  Offset start,
  Offset end,
  Color color,
  double width,
  StrokeCap cap,
});

_RecordedUnderline _recordedUnderline(WidgetTester tester) {
  final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
  final painter = tester.widget<CustomPaint>(plot).painter!;
  final canvas = TestRecordingCanvas();
  painter.paint(canvas, tester.getSize(plot));
  final line = canvas.invocations.singleWhere((record) =>
      record.invocation.memberName == #drawLine &&
      (record.invocation.positionalArguments[2] as Paint).strokeCap ==
          StrokeCap.round);
  final arguments = line.invocation.positionalArguments;
  final paint = arguments[2] as Paint;
  return (
    start: arguments[0] as Offset,
    end: arguments[1] as Offset,
    color: paint.color,
    width: paint.strokeWidth,
    cap: paint.strokeCap,
  );
}

void _expectUnderlineStyle(
    _RecordedUnderline actual, _RecordedUnderline original) {
  expect(actual.start.dy, original.start.dy);
  expect(actual.end.dy, original.end.dy);
  expect(actual.end.dx - actual.start.dx,
      closeTo(original.end.dx - original.start.dx, .001));
  expect(actual.color, original.color);
  expect(actual.width, 2);
  expect(actual.cap, StrokeCap.round);
}
