import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/features/home/academic_schedule_editor_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets('tapping empty space unfocuses the name and preserves its text',
      (tester) async {
    await _pumpEditor(tester, conflictValidator: (_) => const []);
    final courseName = find.byType(TextFormField);
    await tester.enterText(courseName, '测试课程');
    await tester.pump();
    final focus = _inputFocus(tester, courseName);
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(courseName);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    final bounds = tester.getRect(courseName);
    await tester.tapAt(Offset(bounds.left - 8, bounds.center.dy));
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.widget<TextFormField>(courseName).controller!.text, '测试课程');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a section heading dismisses the name input',
      (tester) async {
    await _pumpEditor(tester, conflictValidator: (_) => const []);
    final courseName = find.byType(TextFormField);
    await tester.showKeyboard(courseName);
    final focus = _inputFocus(tester, courseName);
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.text('时段1'));
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus transfers to other inputs and dismisses outside them',
      (tester) async {
    await _pumpEditor(tester, conflictValidator: (_) => const []);
    final courseName = find.byType(TextFormField);
    final credit = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.keyboardType ==
            const TextInputType.numberWithOptions(decimal: true));
    await tester.showKeyboard(courseName);
    final nameFocus = _inputFocus(tester, courseName);

    await tester.tap(credit);
    await tester.pumpAndSettle();
    final creditFocus = _inputFocus(tester, credit);
    expect(nameFocus.hasFocus, isFalse);
    expect(creditFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('时段1'));
    await tester.pumpAndSettle();
    expect(creditFocus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('time selectors dismiss the active text input', (tester) async {
    await _pumpEditor(tester, conflictValidator: (_) => const []);

    final courseName = find.byType(TextFormField);
    await tester.tap(courseName);
    await tester.showKeyboard(courseName);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('周数'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('schedule conflicts keep the editor open', (tester) async {
    var validationCount = 0;
    await _pumpEditor(
      tester,
      conflictValidator: (result) {
        validationCount++;
        expect(result.courseName, '测试课程');
        return const ['已有课程 · 周一 第1-2节（1-16周）'];
      },
    );

    await tester.enterText(find.byType(TextFormField), '测试课程');
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();

    expect(validationCount, 1);
    expect(find.text('存在时段冲突'), findsOneWidget);

    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();

    expect(find.text('添加课程'), findsOneWidget);
    expect(find.text('测试课程'), findsOneWidget);
  });
}

FocusNode _inputFocus(WidgetTester tester, Finder input) => tester
    .widget<EditableText>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    )
    .focusNode;

Future<void> _pumpEditor(
  WidgetTester tester, {
  required List<String> Function(ScheduleCourseEditorResult result)
      conflictValidator,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: AcademicScheduleEditorPage(
        maxWeek: 16,
        initialWeek: 1,
        initialWeekday: 1,
        initialStartSection: 1,
        colorful: false,
        palette: const [Colors.blue],
        conflictValidator: conflictValidator,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
