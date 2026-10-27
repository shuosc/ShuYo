import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/calendar_date_picker.dart';
import 'package:shuyo/shared/widgets/date_picker.dart';
import 'package:shuyo/shared/widgets/date_range_picker.dart';

void main() {
  final initialDate = DateTime(2025, 1, 2);
  final initialRange = DateTimeRange(
    start: initialDate,
    end: DateTime(2025, 1, 5),
  );
  final picker = find.byType(ShuYoCalendarDatePicker);
  final switcher = find.byKey(const ValueKey('shuyo-calendar-mode-switcher'));
  final days = find.byKey(const ValueKey('shuyo-calendar-day-view'));
  final years = find.byKey(const ValueKey('shuyo-calendar-year-view'));

  Future<void> open(
    WidgetTester tester, {
    required bool range,
    required ValueChanged<Object?> onResult,
    bool disableAnimations = false,
    DateTime? firstDate,
    DateTime? lastDate,
    DateTime? singleDate,
    bool emptyRange = false,
  }) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = range
                  ? await showShuYoDateRangePicker(
                      context: context,
                      initialRange: emptyRange ? null : initialRange,
                      firstDate: firstDate ?? DateTime(2020),
                      lastDate: lastDate ?? DateTime(2026, 12, 31),
                    )
                  : await showShuYoDatePicker(
                      context: context,
                      initialDate: singleDate ?? initialDate,
                      firstDate: firstDate ?? DateTime(2020),
                      lastDate: lastDate ?? DateTime(2026, 12, 31),
                    );
              onResult(result);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester tester) async {
    final context = tester.element(picker);
    final month =
        MaterialLocalizations.of(context).formatMonthYear(initialDate);
    await tester.tap(find.descendant(of: picker, matching: find.text(month)));
    await tester.pump();
  }

  FadeTransition viewFade(WidgetTester tester, Finder view) =>
      tester.widget<FadeTransition>(
        find.ancestor(of: view, matching: find.byType(FadeTransition)).first,
      );

  final today = DateTime(2026, 10, 26);
  for (final config in [
    (
      name: 'search range at the final year',
      range: true,
      first: DateTime(1900),
      last: today,
      focus: today,
      disableAnimations: false,
    ),
    (
      name: 'schedule date with years before and after the selection',
      range: false,
      first: DateTime(2000),
      last: DateTime(2100, 12, 31),
      focus: DateTime(2026, 10, 5),
      disableAnimations: false,
    ),
    (
      name: 'single date with the search bounds at the final year',
      range: false,
      first: DateTime(1900),
      last: today,
      focus: today,
      disableAnimations: false,
    ),
    (
      name: 'search range at the final year with animations disabled',
      range: true,
      first: DateTime(1900),
      last: today,
      focus: today,
      disableAnimations: true,
    ),
  ]) {
    testWidgets('${config.name}: year grid starts within its scroll bounds',
        (tester) async {
      await open(tester,
          range: config.range,
          firstDate: config.first,
          lastDate: config.last,
          singleDate: config.focus,
          emptyRange: config.range,
          disableAnimations: config.disableAnimations,
          onResult: (_) {});
      final coreBounds = tester.getRect(picker);
      final surface = find
          .descendant(
            of: find.byType(Dialog),
            matching: find.byWidgetPredicate((widget) =>
                widget is Container && widget.decoration is BoxDecoration),
          )
          .first;
      final dialogBounds = tester.getRect(surface);
      final month = MaterialLocalizations.of(tester.element(picker))
          .formatMonthYear(config.focus);
      await tester.tap(find.descendant(of: picker, matching: find.text(month)));
      await tester.pump();
      final scrollable =
          find.descendant(of: years, matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, greaterThanOrEqualTo(position.minScrollExtent),
          reason: 'the first preparation frame has no underscroll');
      expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent),
          reason: 'the first preparation frame has no overscroll');
      final readyOpacity =
          find.byKey(const ValueKey('shuyo-calendar-year-ready-opacity'));
      expect(tester.widget<Opacity>(readyOpacity).opacity, 0);
      final selectedYear = find.descendant(
          of: years, matching: find.text('${config.focus.year}'));
      expect(selectedYear.hitTestable(), findsNothing);
      expect(
          find.ancestor(
              of: selectedYear,
              matching: find.byWidgetPredicate(
                  (widget) => widget is IgnorePointer && widget.ignoring)),
          findsWidgets);
      expect(
          find.ancestor(
              of: selectedYear,
              matching: find.byWidgetPredicate(
                  (widget) => widget is ExcludeSemantics && widget.excluding)),
          findsWidgets);
      // Complete the invisible preparation layout without advancing the clock.
      // Waiting for animations to settle here would hide the original rebound.
      await tester.pump();
      expect(tester.widget<Opacity>(readyOpacity).opacity, 1);
      Rect? firstYearBounds;
      Rect? firstCellBounds;
      double? firstOffset;
      var elapsed = 0;
      for (final time in [0, 16, 50, 100, 200, 300]) {
        if (time != 0) {
          await tester.pump(Duration(milliseconds: time - elapsed));
        }
        elapsed = time;
        expect(selectedYear, findsOneWidget);
        final yearBounds = tester.getRect(years);
        final cellBounds = tester.getRect(selectedYear);
        firstYearBounds ??= yearBounds;
        firstCellBounds ??= cellBounds;
        firstOffset ??= position.pixels;
        expect(position.pixels, greaterThanOrEqualTo(position.minScrollExtent),
            reason: '$time ms: no initial underscroll');
        expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent),
            reason: '$time ms: no initial overscroll that springs back');
        expect(position.pixels, firstOffset,
            reason: '$time ms: opening the year view does not scroll its grid');
        expect(yearBounds, firstYearBounds,
            reason: '$time ms: the year viewport stays in place');
        expect(cellBounds, firstCellBounds,
            reason: '$time ms: the selected year does not slide vertically');
        expect(tester.getRect(picker), coreBounds);
        expect(tester.getRect(surface), dialogBounds);
      }
      final offsetBeforeDrag = position.pixels;
      await tester.drag(years, const Offset(0, 130));
      await tester.pump();
      expect(position.pixels, lessThan(offsetBeforeDrag),
          reason: 'initial positioning does not prevent normal year scrolling');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final range in [false, true]) {
    final mode = range ? 'range' : 'single date';
    testWidgets('$mode changes calendar and year views with a stable fade',
        (tester) async {
      Object? result;
      await open(tester, range: range, onResult: (value) => result = value);
      final bounds = tester.getRect(picker);
      final animation = tester.widget<AnimatedSwitcher>(switcher);
      expect(animation.duration, const Duration(milliseconds: 200));
      expect(animation.reverseDuration ?? animation.duration,
          const Duration(milliseconds: 200));

      await toggle(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(days, findsOneWidget);
      expect(years, findsOneWidget);
      expect(viewFade(tester, days).opacity.value,
          allOf(greaterThan(0), lessThan(1)));
      expect(viewFade(tester, years).opacity.value,
          allOf(greaterThan(0), lessThan(1)));
      expect(tester.getRect(picker), bounds);
      expect(
          find.descendant(of: switcher, matching: find.byType(SlideTransition)),
          findsNothing);
      expect(
          find.descendant(of: switcher, matching: find.byType(ScaleTransition)),
          findsNothing);
      final outgoingDay = find.byKey(ValueKey<DateTime>(DateTime(2025, 1, 6)));
      expect(outgoingDay.hitTestable(), findsNothing);
      expect(
        find.ancestor(
          of: outgoingDay,
          matching: find.byWidgetPredicate(
              (widget) => widget is IgnorePointer && widget.ignoring),
        ),
        findsWidgets,
      );

      await toggle(tester);
      await tester.pump(const Duration(milliseconds: 40));
      await toggle(tester);
      await tester.pump(const Duration(milliseconds: 40));
      await toggle(tester);
      await tester.pumpAndSettle();
      expect(days, findsOneWidget);
      expect(years, findsNothing);
      expect(tester.getRect(picker), bounds);
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, range ? initialRange : initialDate);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode respects disabled animations without a timed wait',
        (tester) async {
      Object? result;
      await open(tester,
          range: range,
          disableAnimations: true,
          onResult: (value) => result = value);
      expect(tester.widget<AnimatedSwitcher>(switcher).duration, Duration.zero);
      final bounds = tester.getRect(picker);

      await toggle(tester);
      await tester.pump();
      expect(years, findsOneWidget);
      expect(days, findsNothing);
      expect(viewFade(tester, years).opacity.value, 1);
      expect(tester.getRect(picker), bounds);
      await toggle(tester);
      await tester.pump();
      expect(days, findsOneWidget);
      expect(years, findsNothing);
      expect(viewFade(tester, days).opacity.value, 1);
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, range ? initialRange : initialDate);
      expect(tester.takeException(), isNull);
    });
  }
}
