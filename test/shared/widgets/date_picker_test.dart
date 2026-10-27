import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/calendar_date_picker.dart';
import 'package:shuyo/shared/widgets/date_picker.dart';
import 'package:shuyo/shared/widgets/date_picker_dialog.dart';
import 'package:table_calendar/table_calendar.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    required ValueChanged<DateTime?> onResult,
    DateTime? initialDate,
    DateTime? firstDate,
    DateTime? lastDate,
    SelectableDayPredicate? selectableDayPredicate,
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(402, 874),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
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
            onPressed: () async => onResult(await showShuYoDatePicker(
              context: context,
              initialDate: initialDate ?? DateTime(2025, 1, 2),
              firstDate: firstDate ?? DateTime(2020),
              lastDate: lastDate ?? DateTime(2026, 12, 31),
              selectableDayPredicate: selectableDayPredicate,
              title: '选择开学日期',
            )),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> selectDay(WidgetTester tester, DateTime day) async {
    final target = find.byKey(ValueKey<DateTime>(DateUtils.dateOnly(day)));
    final scroll = find
        .descendant(
          of: find.byType(ShuYoDatePickerDialog),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    for (var attempt = 0;
        target.hitTestable().evaluate().isEmpty && attempt < 10;
        attempt++) {
      await tester.drag(scroll, const Offset(0, -100));
      await tester.pumpAndSettle();
    }
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  MaterialLocalizations localizations(WidgetTester tester) =>
      MaterialLocalizations.of(
          tester.element(find.byType(ShuYoDatePickerDialog)));

  TableCalendar<void> calendar(WidgetTester tester) =>
      tester.widget<TableCalendar<void>>(find.byType(TableCalendar<void>));

  testWidgets('uses the shared shell and confirms one date without input',
      (tester) async {
    DateTime? result;
    await open(tester, onResult: (value) => result = value);

    expect(find.byType(ShuYoDatePickerDialog), findsOneWidget);
    expect(find.byType(ShuYoCalendarDatePicker), findsOneWidget);
    expect(find.text('选择开学日期'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(InputDatePickerFormField), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    await selectDay(tester, DateTime(2025, 1, 6));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, DateTime(2025, 1, 6));
    expect(find.byType(ShuYoDatePickerDialog), findsNothing);
  });

  testWidgets('Monday-only schedule selection ignores other weekdays',
      (tester) async {
    DateTime? result;
    await open(
      tester,
      initialDate: DateTime(2025, 1, 6),
      selectableDayPredicate: (day) => day.weekday == DateTime.monday,
      onResult: (value) => result = value,
    );
    await selectDay(tester, DateTime(2025, 1, 7));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, DateTime(2025, 1, 6));
  });

  testWidgets('first and last dates are inclusive', (tester) async {
    DateTime? result;
    final first = DateTime(2025, 1, 10);
    final last = DateTime(2025, 1, 20);
    await open(tester,
        initialDate: first,
        firstDate: first,
        lastDate: last,
        onResult: (value) => result = value);
    await selectDay(tester, last);
    await selectDay(tester, DateTime(2025, 1, 21));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, last);
  });

  testWidgets('cancel returns no date after choosing a different day',
      (tester) async {
    var completed = false;
    DateTime? result;
    await open(tester, onResult: (value) {
      result = value;
      completed = true;
    });
    await selectDay(tester, DateTime(2025, 1, 6));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('month and year navigation do not replace the selected date',
      (tester) async {
    DateTime? result;
    final selected = DateTime(2025, 1, 2);
    await open(tester,
        initialDate: selected, onResult: (value) => result = value);
    await tester.tap(find.byTooltip(localizations(tester).nextMonthTooltip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(
        localizations(tester).formatMonthYear(calendar(tester).focusedDay)));
    await tester.pumpAndSettle();
    final year = find.descendant(
      of: find.byType(YearPicker),
      matching: find.text('2024'),
    );
    await tester.ensureVisible(year);
    await tester.tap(year);
    await tester.pumpAndSettle();
    expect(calendar(tester).focusedDay.year, 2024);
    expect(calendar(tester).focusedDay.month, 2);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, selected);
  });

  testWidgets('large text on a short screen keeps date and buttons reachable',
      (tester) async {
    await open(tester,
        size: const Size(320, 402), textScale: 2, onResult: (_) {});
    expect(tester.takeException(), isNull);
    await selectDay(tester, DateTime(2025, 1, 6));
    await tester.ensureVisible(find.text('确定'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byType(ShuYoDatePickerDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large double-digit dates stay on one line inside their cells',
      (tester) async {
    await open(tester,
        initialDate: DateTime(2025, 1, 13),
        size: const Size(320, 640),
        textScale: 3,
        onResult: (_) {});
    for (final day in [13, 30]) {
      final cell = find.byKey(ValueKey<DateTime>(DateTime(2025, 1, day)));
      final text = find.descendant(of: cell, matching: find.byType(RichText));
      expect(text, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(text);
      expect(paragraph.text.toPlainText(), '$day');
      final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 2));
      expect(boxes, hasLength(1), reason: 'the two digits share one line');
      final cellBounds = tester.getRect(cell).inflate(0.5);
      final textBounds = tester.getRect(text);
      expect(cellBounds.contains(textBounds.topLeft), isTrue);
      expect(cellBounds.contains(textBounds.bottomRight), isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('single date uses the shared haptic policy on $platform',
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
          initialDate: DateTime(2025, 1, 6),
          firstDate: DateTime(2024),
          selectableDayPredicate: (day) => day.weekday == DateTime.monday,
          platform: platform,
          onResult: (_) {});
      final count = platform == TargetPlatform.android ? 1 : 0;
      calls.clear();

      await selectDay(tester, DateTime(2025, 1, 7));
      expect(calls, isEmpty, reason: 'disabled weekday');
      await selectDay(tester, DateTime(2025, 1, 13));
      expect(calls, hasLength(count), reason: 'choosing a valid day');
      calls.clear();
      await tester.tap(find.byTooltip(localizations(tester).nextMonthTooltip));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'changing month');
      await tester.tap(find.text(
          localizations(tester).formatMonthYear(calendar(tester).focusedDay)));
      await tester.pumpAndSettle();
      expect(calls, hasLength(count), reason: 'opening year selection');
      calls.clear();
      final year = find.descendant(
        of: find.byType(YearPicker),
        matching: find.text('2024'),
      );
      await tester.ensureVisible(year);
      await tester.tap(year);
      await tester.pumpAndSettle();
      expect(calls, hasLength(count), reason: 'choosing a year');
      expect(calendar(tester).focusedDay.year, 2024);
      expect(tester.takeException(), isNull);
    });
  }
}
