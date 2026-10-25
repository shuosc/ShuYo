import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/calendar_date_picker.dart';
import 'package:shuyo/shared/widgets/date_picker_dialog.dart';
import 'package:shuyo/shared/widgets/date_range_picker.dart';
import 'package:table_calendar/table_calendar.dart';

void main() {
  final initialRange = DateTimeRange(
    start: DateTime(2025, 1, 2),
    end: DateTime(2025, 1, 5),
  );

  Future<void> open(
    WidgetTester tester, {
    required ValueChanged<DateTimeRange?> onResult,
    Size size = const Size(402, 874),
    Locale? locale,
    DateTimeRange? range,
    bool emptySelection = false,
    DateTime? firstDate,
    DateTime? lastDate,
    double textScale = 1,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId)
          .themeData()
          .copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showShuYoDateRangePicker(
                context: context,
                initialRange: emptySelection ? null : range ?? initialRange,
                firstDate: firstDate ?? DateTime(2020),
                lastDate: lastDate ?? DateTime(2026, 12, 31),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Finder dialogSurface() => find
      .descendant(
        of: find.byType(ShuYoDatePickerDialog),
        matching: find.byWidgetPredicate(
          (widget) => widget is Container && widget.decoration is BoxDecoration,
        ),
      )
      .first;

  void expectBounded(WidgetTester tester) {
    final bounds = tester.getRect(dialogSurface());
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(bounds.left, greaterThanOrEqualTo(20));
    expect(bounds.top, greaterThan(0));
    expect(bounds.right, lessThanOrEqualTo(viewport.width - 20));
    expect(bounds.bottom, lessThan(viewport.height));
    expect(bounds.width, lessThanOrEqualTo(400));
  }

  MaterialLocalizations localizations(WidgetTester tester) =>
      MaterialLocalizations.of(
        tester.element(find.byType(ShuYoDatePickerDialog)),
      );

  Future<Finder> revealDay(WidgetTester tester, DateTime day) async {
    final cell = find.byKey(ValueKey<DateTime>(DateUtils.dateOnly(day)));
    final scroll = find
        .descendant(
          of: find.byType(ShuYoDatePickerDialog),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    for (var attempt = 0;
        cell.hitTestable().evaluate().isEmpty && attempt < 10;
        attempt++) {
      await tester.drag(scroll, const Offset(0, -100));
      await tester.pumpAndSettle();
    }
    return cell;
  }

  Future<void> selectDay(WidgetTester tester, DateTime day) async {
    final cell = await revealDay(tester, day);
    await tester.tap(cell);
    await tester.pumpAndSettle();
  }

  Future<void> nextMonth(WidgetTester tester) async {
    final next = find.byTooltip(localizations(tester).nextMonthTooltip);
    await tester.ensureVisible(next);
    await tester.tap(next);
    await tester.pumpAndSettle();
  }

  Future<void> openYearPicker(WidgetTester tester) async {
    final title =
        localizations(tester).formatMonthYear(calendar(tester).focusedDay);
    final target = find.text(title);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> selectYear(WidgetTester tester, int value) async {
    final year = find.descendant(
      of: find.byType(YearPicker),
      matching: find.text('$value'),
    );
    await tester.ensureVisible(year);
    await tester.tap(year);
    await tester.pumpAndSettle();
  }

  testWidgets('uses the timetable shell without any manual input mode',
      (tester) async {
    await open(tester, onResult: (_) {});

    expect(find.byType(ShuYoDatePickerDialog), findsOneWidget);
    expect(find.byType(ShuYoCalendarDatePicker), findsOneWidget);
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(InputDatePickerFormField), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.calendar_today), findsNothing);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    final surface = tester.widget<Container>(dialogSurface());
    final decoration = surface.decoration! as BoxDecoration;
    final colors = tester.element(dialogSurface()).shuyoColors;
    expect(dialog.backgroundColor, Colors.transparent);
    expect(dialog.elevation, 0);
    expect(decoration.color, colors.surface);
    expect(decoration.borderRadius, BorderRadius.circular(8));
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '确定'), findsOneWidget);
    expectBounded(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar permits a range containing a single day',
      (tester) async {
    DateTimeRange? result;
    await open(tester, onResult: (value) => result = value);
    final day = DateTime(2025, 1, 12);
    await selectDay(tester, day);
    expect(calendar(tester).rangeStartDay, day);
    expect(calendar(tester).rangeEndDay, isNull);
    await selectDay(tester, day);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, DateTimeRange(start: day, end: day));
  });

  testWidgets('endpoint text shares the header row without card styling',
      (tester) async {
    await open(tester, onResult: (_) {});
    final title = tester.getRect(find.text('选择日期范围'));
    expect(find.text('开始日期'), findsNothing);
    expect(find.text('结束日期'), findsNothing);
    for (final key in ['date-range-start', 'date-range-end']) {
      final endpoint = find.byKey(ValueKey(key));
      final bounds = tester.getRect(endpoint);
      expect(bounds.left, greaterThanOrEqualTo(title.right));
      expect(bounds.top, lessThan(title.bottom));
      expect(bounds.bottom, greaterThan(title.top));
      final endpointWidget = tester.widget(endpoint);
      final buttonFinder = endpointWidget is TextButton
          ? endpoint
          : find.descendant(of: endpoint, matching: find.byType(TextButton));
      expect(buttonFinder, findsOneWidget);
      final material = tester.widget<Material>(find
          .descendant(of: buttonFinder, matching: find.byType(Material))
          .first);
      expect(material.color == null || material.color!.a == 0, isTrue,
          reason: 'endpoint text has no filled background');
      final shape = material.shape;
      if (shape is OutlinedBorder) {
        expect(shape.side.style, BorderStyle.none,
            reason: 'endpoint text has no outline');
      }
    }
    await tester.tap(find.byKey(const ValueKey('date-range-end')));
    await tester.pumpAndSettle();
    await selectDay(tester, DateTime(2025, 1, 9));
    expect(calendar(tester).rangeStartDay, initialRange.start);
    expect(calendar(tester).rangeEndDay, DateTime(2025, 1, 9));
    await tester.tap(find.byKey(const ValueKey('date-range-start')));
    await tester.pumpAndSettle();
    await selectDay(tester, DateTime(2025, 1, 3));
    expect(calendar(tester).rangeStartDay, DateTime(2025, 1, 3));
    expect(calendar(tester).rangeEndDay, DateTime(2025, 1, 9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty selection displays both endpoints and requires both',
      (tester) async {
    DateTimeRange? result;
    await open(
      tester,
      emptySelection: true,
      onResult: (value) => result = value,
    );
    final confirm = find.widgetWithText(FilledButton, '确定');
    final start = find.byKey(const ValueKey('date-range-start'));
    final end = find.byKey(const ValueKey('date-range-end'));
    expect(
        find.descendant(of: start, matching: find.text('未选择')), findsOneWidget);
    expect(
        find.descendant(of: end, matching: find.text('未选择')), findsOneWidget);
    expect(calendar(tester).rangeStartDay, isNull);
    expect(calendar(tester).rangeEndDay, isNull);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await selectDay(tester, DateTime(2026, 12, 2));
    expect(calendar(tester).rangeStartDay, DateTime(2026, 12, 2));
    expect(calendar(tester).rangeEndDay, isNull);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await selectDay(tester, DateTime(2026, 12, 5));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(
        result,
        DateTimeRange(
            start: DateTime(2026, 12, 2), end: DateTime(2026, 12, 5)));
  });

  testWidgets('year navigation preserves the chosen range', (tester) async {
    DateTimeRange? result;
    await open(
      tester,
      firstDate: DateTime(1900),
      onResult: (value) => result = value,
    );
    await openYearPicker(tester);
    expect(find.byType(YearPicker), findsOneWidget);
    await selectYear(tester, 2024);

    expect(find.byType(YearPicker), findsNothing);
    expect(calendar(tester).focusedDay.year, 2024);
    expect(calendar(tester).focusedDay.month, initialRange.start.month);
    expect(calendar(tester).rangeStartDay, initialRange.start);
    expect(calendar(tester).rangeEndDay, initialRange.end);
    await selectDay(tester, DateTime(2024, 1, 6));
    await selectDay(tester, DateTime(2024, 1, 9));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result,
        DateTimeRange(start: DateTime(2024, 1, 6), end: DateTime(2024, 1, 9)));
  });

  testWidgets('normalizes endpoints selected in reverse order', (tester) async {
    DateTimeRange? result;
    await open(tester, onResult: (value) => result = value);
    await selectDay(tester, DateTime(2025, 1, 20));
    await selectDay(tester, DateTime(2025, 1, 10));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(
        result,
        DateTimeRange(
            start: DateTime(2025, 1, 10), end: DateTime(2025, 1, 20)));
  });

  testWidgets('editing an endpoint preserves the other selected endpoint',
      (tester) async {
    DateTimeRange? result;
    await open(tester, onResult: (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('date-range-end')));
    await tester.pumpAndSettle();
    await selectDay(tester, DateTime(2025, 1, 9));
    expect(calendar(tester).rangeStartDay, DateTime(2025, 1, 2));
    expect(calendar(tester).rangeEndDay, DateTime(2025, 1, 9));
    await tester.tap(find.byKey(const ValueKey('date-range-start')));
    await tester.pumpAndSettle();
    await selectDay(tester, DateTime(2025, 1, 3));
    expect(calendar(tester).rangeStartDay, DateTime(2025, 1, 3));
    expect(calendar(tester).rangeEndDay, DateTime(2025, 1, 9));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result,
        DateTimeRange(start: DateTime(2025, 1, 3), end: DateTime(2025, 1, 9)));
  });

  testWidgets('keeps the start date when choosing an end in the next month',
      (tester) async {
    DateTimeRange? result;
    await open(tester, onResult: (value) => result = value);
    await selectDay(tester, DateTime(2025, 1, 30));
    await nextMonth(tester);
    expect(calendar(tester).rangeStartDay, DateTime(2025, 1, 30));
    await selectDay(tester, DateTime(2025, 2, 3));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result,
        DateTimeRange(start: DateTime(2025, 1, 30), end: DateTime(2025, 2, 3)));
  });

  testWidgets('permits inclusive bounds and ignores disabled dates',
      (tester) async {
    DateTimeRange? result;
    final first = DateTime(2025, 1, 10);
    final last = DateTime(2025, 2, 5);
    await open(
      tester,
      range: DateTimeRange(
          start: DateTime(2025, 1, 12), end: DateTime(2025, 1, 15)),
      firstDate: first,
      lastDate: last,
      onResult: (value) => result = value,
    );
    await selectDay(tester, DateTime(2025, 1, 9));
    expect(calendar(tester).rangeStartDay, DateTime(2025, 1, 12));
    expect(calendar(tester).rangeEndDay, DateTime(2025, 1, 15));
    await selectDay(tester, first);
    await nextMonth(tester);
    await selectDay(tester, DateTime(2025, 2, 6));
    expect(calendar(tester).rangeEndDay, isNull);
    await selectDay(tester, last);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, DateTimeRange(start: first, end: last));
  });

  testWidgets('cancelling does not apply changed dates', (tester) async {
    var completed = false;
    DateTimeRange? result;
    await open(tester, onResult: (value) {
      completed = true;
      result = value;
    });
    await selectDay(tester, DateTime(2025, 1, 3));
    await selectDay(tester, DateTime(2025, 1, 6));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
    expect(find.byType(ShuYoDatePickerDialog), findsNothing);
  });

  for (final viewport in [
    const Size(874, 402),
    const Size(320, 640),
    const Size(320, 402),
  ]) {
    testWidgets('calendar stays bounded and scrollable in $viewport',
        (tester) async {
      await open(tester,
          size: viewport, locale: const Locale('zh', 'CN'), onResult: (_) {});
      expectBounded(tester);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.byType(ShuYoDatePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text retains reachable endpoints calendar and actions',
      (tester) async {
    await open(tester,
        size: const Size(320, 640),
        locale: const Locale('zh', 'CN'),
        textScale: 2,
        onResult: (_) {});
    expectBounded(tester);
    expect(tester.takeException(), isNull);
    for (final target in [
      find.byKey(const ValueKey('date-range-start')),
      find.byKey(const ValueKey('date-range-end')),
      find.text('确定'),
    ]) {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    final day = await revealDay(tester, DateTime(2025, 1, 12));
    expect(day.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('range calendar applies the shared haptic policy on $platform',
        (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') calls.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await open(tester,
          firstDate: DateTime(2024),
          lastDate: DateTime(2026, 12, 31),
          platform: platform,
          onResult: (_) {});
      final count = platform == TargetPlatform.android ? 1 : 0;
      calls.clear();

      await selectDay(tester, DateTime(2025, 1, 6));
      expect(calls, hasLength(count), reason: 'choosing a day');
      calls.clear();
      await nextMonth(tester);
      expect(calls, isEmpty, reason: 'changing month');
      await openYearPicker(tester);
      expect(calls, hasLength(count), reason: 'opening year selection');
      calls.clear();
      await selectYear(tester, 2024);
      expect(calls, hasLength(count), reason: 'choosing a year');
      calls.clear();
      await selectDay(tester, DateTime(2024, 2, 6));
      expect(calls, hasLength(count), reason: 'choosing the end day');
    });
  }
}

TableCalendar<void> calendar(WidgetTester tester) =>
    tester.widget<TableCalendar<void>>(find.byType(TableCalendar<void>));
