import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/features/home/academic_schedule_editor_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
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
