import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/widgets/schedule_week_switcher.dart';

void main() {
  testWidgets(
      'navigation preserves disabled boundaries and updated week labels',
      (tester) async {
    var previousCount = 0;
    var nextCount = 0;
    await tester.pumpWidget(_switcher(
      week: 1,
      onPrevious: null,
      onNext: () => nextCount++,
    ));

    expect(find.text('第 1 周'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_left),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('下一周'));
    expect(nextCount, 1);

    await tester.pumpWidget(_switcher(
      week: 20,
      onPrevious: () => previousCount++,
      onNext: null,
    ));
    await tester.pumpAndSettle();

    expect(find.text('第 20 周'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('上一周'));
    expect(previousCount, 1);
  });

  testWidgets('quick switching can be disabled without disabling week buttons',
      (tester) async {
    var previousCount = 0;
    var nextCount = 0;
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      enableQuickSwitch: false,
      onPrevious: () => previousCount++,
      onNext: () => nextCount++,
      onQuickWeekSelected: selectedWeeks.add,
    ));

    await tester.drag(find.text('第 5 周'), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(find.text('第 5 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(selectedWeeks, isEmpty);
    await tester.tap(find.byTooltip('上一周'));
    await tester.tap(find.byTooltip('下一周'));
    expect(previousCount, 1);
    expect(nextCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabling quick switching during a drag removes the preview',
      (tester) async {
    var previousCount = 0;
    var nextCount = 0;
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 5 周')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 20 周'), findsOneWidget);

    await tester.pumpWidget(_switcher(
      week: 5,
      enableQuickSwitch: false,
      onPrevious: () => previousCount++,
      onNext: () => nextCount++,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('第 20 周'), findsNothing);
    expect(find.text('第 5 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selectedWeeks, isEmpty);
    await tester.tap(find.byTooltip('上一周'));
    await tester.tap(find.byTooltip('下一周'));
    expect(previousCount, 1);
    expect(nextCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal dragging previews then commits a clamped week',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      onQuickWeekSelected: selectedWeeks.add,
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 5 周')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsOneWidget);
    expect(find.text('第 20 周'), findsOneWidget);
    expect(selectedWeeks, isEmpty);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_left),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(selectedWeeks, [20]);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(find.text('第 20 周'), findsNothing);
    expect(find.text('第 5 周'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shrinking the range during a drag clamps preview and selection',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 5 周')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 20 周'), findsOneWidget);

    await tester.pumpWidget(_switcher(
      week: 5,
      maxWeek: 8,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('第 20 周'), findsNothing);
    expect(find.text('第 8 周'), findsOneWidget);
    expect(selectedWeeks, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selectedWeeks, [8]);
    expect(find.text('第 8 周'), findsNothing);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shrinking to one week cancels the preview and allows later drags',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 5 周')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 20 周'), findsOneWidget);

    await tester.pumpWidget(_switcher(
      week: 1,
      maxWeek: 1,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    await tester.pumpAndSettle();

    expect(find.text('第 20 周'), findsNothing);
    expect(find.text('第 1 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selectedWeeks, isEmpty);

    await tester.pumpWidget(_switcher(
      week: 1,
      maxWeek: 3,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    final nextGesture = await tester.startGesture(
      tester.getCenter(find.text('第 1 周')),
    );
    await nextGesture.moveBy(const Offset(24, 0));
    await nextGesture.moveBy(const Offset(400, 0));
    await nextGesture.up();
    await tester.pumpAndSettle();

    expect(selectedWeeks, [3]);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal dragging also clamps to the first week',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 10,
      onQuickWeekSelected: selectedWeeks.add,
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 10 周')),
    );
    await gesture.moveBy(const Offset(-24, 0));
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 1 周'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(selectedWeeks, [1]);
    expect(find.text('第 1 周'), findsNothing);
    expect(find.text('第 10 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing during a drag removes the preview overlay',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 5,
      onQuickWeekSelected: selectedWeeks.add,
    ));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 5 周')),
    );
    await gesture.moveBy(const Offset(24, 0));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(find.byType(Text), findsNothing);
    expect(selectedWeeks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-week schedule does not start quick switching',
      (tester) async {
    final selectedWeeks = <int>[];
    await tester.pumpWidget(_switcher(
      week: 1,
      maxWeek: 1,
      onPrevious: null,
      onNext: null,
      onQuickWeekSelected: selectedWeeks.add,
    ));

    await tester.drag(find.text('第 1 周'), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(find.text('第 1 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(selectedWeeks, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Widget _switcher({
  required int week,
  int maxWeek = 20,
  bool enableQuickSwitch = true,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  ValueChanged<int>? onQuickWeekSelected,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ScheduleWeekSwitcher(
        week: week,
        maxWeek: maxWeek,
        enableQuickSwitch: enableQuickSwitch,
        onPrevious: onPrevious,
        onNext: onNext,
        onQuickWeekSelected: onQuickWeekSelected ?? (_) {},
      ),
    ),
  );
}
