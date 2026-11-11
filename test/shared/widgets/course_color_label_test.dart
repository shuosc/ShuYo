import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/shared/theme/course_color.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/course_color_label.dart';

void main() {
  testWidgets('course markers reuse schedule colors and ignore title changes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: const [
          CourseColorLabel(code: ' CS101 ', name: '程序设计', child: Text('课程列表')),
          CourseColorLabel(code: 'CS101', name: '不同标题', child: Text('播放页')),
        ]),
      ),
    ));
    final labels = find.byType(CourseColorLabel);
    final context = tester.element(labels.first);
    final expected = context.shuyoColors.schedulePalette[8];
    expect(courseColorForSeed(context, 'CS101'), expected);
    for (final label in [labels.first, labels.last]) {
      final bar = find.descendant(of: label, matching: find.byType(Container));
      final decoration =
          tester.widget<Container>(bar).decoration as BoxDecoration;
      expect(decoration.color, expected);
      expect(tester.getSize(bar), const Size(3, 18));
    }
  });

  testWidgets(
      'missing course codes fall back to trimmed names on narrow layouts',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          child: CourseColorLabel(
            code: ' ',
            name: ' 程序设计 ',
            child: Text('较长的课程名称用于测试多行标题', textScaler: TextScaler.linear(2)),
          ),
        ),
      ),
    ));
    final label = find.byType(CourseColorLabel);
    final bar = find.descendant(of: label, matching: find.byType(Container));
    final decoration =
        tester.widget<Container>(bar).decoration as BoxDecoration;
    expect(decoration.color, courseColorForSeed(tester.element(label), '程序设计'));
    expect(tester.takeException(), isNull);
  });
}
