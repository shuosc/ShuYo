import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_course_overview.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  VodLesson lesson(int id, DateTime? date, String section) => VodLesson(
        id: id,
        teachingClassId: 10,
        name: '课程',
        isPlayable: true,
        beginTime: date,
        sectionLabel: section,
      );

  test('unions paired sections across weeks and sorts weekdays', () {
    final days = recordingCourseDays([
      lesson(1, DateTime(2026, 10, 29), '第3节'),
      lesson(2, DateTime(2026, 10, 27), '第1节'),
      lesson(3, DateTime(2026, 11, 3), '第2节'),
      lesson(4, DateTime(2026, 10, 27), '第5-6节'),
      lesson(5, DateTime(2026, 10, 29), '第11至12节'),
    ]);
    expect(
        days.map((day) => day.weekday), [DateTime.tuesday, DateTime.thursday]);
    expect(days.first.sections, {1, 2, 5, 6});
    expect(days.last.sections, {3, 11, 12});
  });

  test('missing or invalid lesson metadata does not invent a timeslot', () {
    final date = DateTime(2026, 10, 27);
    expect(
        recordingCourseDays([
          lesson(1, null, '第1节'),
          lesson(2, date, ''),
          lesson(3, date, '第0节'),
          lesson(4, date, '第13节'),
          lesson(5, date, '第4-1节'),
        ]),
        isEmpty);
  });

  test('excludes weekend lessons for local and UTC school dates', () {
    final local = recordingCourseDays([
      lesson(1, DateTime(2026, 10, 31, 8), '第1节'),
      lesson(2, DateTime(2026, 11, 1, 8), '第2节'),
    ]);
    expect(local, isEmpty);
    final utc = recordingCourseDays([
      lesson(3, DateTime.utc(2026, 10, 30, 23), '第3节'),
      lesson(4, DateTime.utc(2026, 10, 31, 23), '第4节'),
      lesson(5, DateTime.parse('2026-11-01T08:00:00+08:00'), '第5节'),
    ]);
    expect(utc, isEmpty);
  });

  testWidgets('one occupied section only fills its half of the paired block',
      (tester) async {
    final days = recordingCourseDays([
      lesson(1, DateTime(2026, 10, 30), '第1节'),
      lesson(2, DateTime(2026, 10, 29), '第2节'),
      lesson(3, DateTime(2026, 10, 29), '第7-8节'),
      lesson(4, DateTime(2026, 10, 31), '第3节'),
      lesson(5, DateTime(2026, 11, 1), '第4节'),
    ]);
    expect(days, hasLength(2));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: SizedBox(width: 320, child: RecordingCourseOverview(days: days)),
    )));
    final context = tester.element(find.byType(RecordingCourseOverview));
    final primary = Theme.of(context).colorScheme.primary;
    for (final day in days) {
      for (var section = 1; section <= 12; section++) {
        final half = find.byKey(
            ValueKey('recording-course-section-${day.weekday}-$section'));
        expect(tester.widget<ColoredBox>(half).color,
            day.sections.contains(section) ? primary : Colors.transparent);
        final block = find.byKey(ValueKey(
            'recording-course-slot-${day.weekday}-${(section - 1) ~/ 2}'));
        expect(tester.getSize(half).width,
            closeTo(tester.getSize(block).width / 2, .001));
      }
    }
    expect(find.text('周四'), findsOneWidget);
    expect(find.text('周五'), findsOneWidget);
    expect(find.text('周六'), findsNothing);
    expect(find.text('周日'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline overview header and six blocks fit doubled narrow themes',
      (tester) async {
    final days = recordingCourseDays([
      lesson(1, DateTime(2026, 10, 27), '第1-2节'),
      lesson(2, DateTime(2026, 10, 27), '第5-6节'),
    ]);
    for (final themeId in [ShuYoThemes.defaultId, ShuYoThemes.systemDarkId]) {
      for (final width in [288.0, 320.0]) {
        await tester.pumpWidget(MaterialApp(
          theme: ShuYoThemes.byId(themeId).themeData(),
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: width,
                      child: MediaQuery(
                          data: const MediaQueryData(
                              textScaler: TextScaler.linear(2)),
                          child: RecordingCourseOverview(days: days))))),
        ));
        final context = tester.element(find.byType(RecordingCourseOverview));
        final heading = tester.widget<Text>(find.text('概览'));
        expect(heading.style!.fontWeight, FontWeight.w600);
        expect(heading.style!.color, context.shuyoColors.textPrimary);
        final overview = find.byType(RecordingCourseOverview);
        final header =
            find.byKey(const ValueKey('recording-course-overview-header'));
        final headingFinder = find.text('概览');
        final dayRow = find
            .ancestor(of: find.text('周二'), matching: find.byType(Row))
            .first;
        expect(
            find.ancestor(of: headingFinder, matching: header), findsOneWidget);
        for (var block = 0; block < 6; block++) {
          final label = find.text('${block * 2 + 1}–${block * 2 + 2}');
          expect(find.ancestor(of: label, matching: header), findsOneWidget);
        }
        expect(tester.getRect(header).top,
            closeTo(tester.getRect(overview).top, .001));
        expect(tester.getRect(headingFinder).center.dy,
            closeTo(tester.getRect(header).center.dy, .001));
        expect(tester.getRect(headingFinder).right,
            lessThanOrEqualTo(tester.getRect(overview).left + 40.001));
        expect(tester.getRect(dayRow).top,
            closeTo(tester.getRect(header).bottom + 8, .001));
        expect(
            tester.getSize(overview).height,
            closeTo(
                tester.getSize(header).height +
                    8 +
                    tester.getSize(dayRow).height,
                .001));
        for (var block = 0; block < 6; block++) {
          final cell = tester.widget<Container>(
              find.byKey(ValueKey('recording-course-slot-2-$block')));
          final decoration = cell.foregroundDecoration! as BoxDecoration;
          expect(
              decoration.border, Border.all(color: context.shuyoColors.border));
          for (var half = 0; half < 2; half++) {
            final fill = tester.widget<ColoredBox>(find.byKey(ValueKey(
                'recording-course-section-2-${block * 2 + half + 1}')));
            expect(
                fill.color,
                block == 0 || block == 2
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent);
          }
        }
        expect(find.text('周二'), findsOneWidget);
        expect(find.text('11–12'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
