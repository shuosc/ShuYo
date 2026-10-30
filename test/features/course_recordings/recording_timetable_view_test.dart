import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_course_title.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_data.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_view.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _course = VodCourse(
  teachingClassId: 101,
  termId: 7,
  name: '程序设计与计算思维',
  code: 'CS101',
  teacherNames: ['教师甲'],
);

final _term = VodTerm(
  id: 7,
  name: '2026-2027学年第1学期',
  isCurrent: true,
  startDate: DateTime(2026, 10, 19),
  endDate: DateTime(2026, 11, 1),
);

VodLesson _lesson(
  int id,
  int day, {
  int hour = 8,
  int week = 1,
  int? section = 1,
  String classroom = '',
  bool playable = true,
  bool generating = false,
}) =>
    VodLesson(
      id: id,
      teachingClassId: 101,
      name: _course.name,
      beginTime: DateTime(2026, 10, day, hour),
      endTime: DateTime(2026, 10, day, hour + 1),
      weekNumber: week,
      sectionLabel: section == null ? '' : '第$section节',
      classroom: classroom,
      isPlayable: playable,
      isGenerating: generating,
      isListed: true,
    );

RecordingTimetableData _data({
  List<VodLesson> lessons = const [],
  VodTerm? term,
  DateTime? now,
}) =>
    RecordingTimetableData(
      term: term ?? _term,
      courses: const [_course],
      lessonsByCourse: {101: lessons},
      now: now ?? DateTime(2026, 10, 21, 12),
    );

Future<void> _mount(
  WidgetTester tester,
  RecordingTimetableData data, {
  bool loading = false,
  bool refreshEnabled = true,
  bool disableAnimations = false,
  int failedCourseCount = 0,
  double textScale = 1,
  String themeId = 'light',
  Future<void> Function()? onRefresh,
  ValueChanged<RecordingTimetableEntry>? onLessonSelected,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(themeId).themeData(),
    home: MediaQuery(
      data: MediaQueryData(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: RecordingTimetableView(
          data: data,
          loading: loading,
          refreshEnabled: refreshEnabled,
          failedCourseCount: failedCourseCount,
          onRefresh: onRefresh ?? () async {},
          onLessonSelected: onLessonSelected ?? (_) {},
        ),
      ),
    ),
  ));
}

Finder _day(String date) => find.byKey(ValueKey('timetable-day-$date'));

Finder _entry(int lessonId) =>
    find.byKey(ValueKey('timetable-entry-101-$lessonId'));

void _expectCompactMetadata(Finder entry) {
  final removedMetadata =
      RegExp(r'第\s*\d+\s*周|\d{1,2}:\d{2}|录播回放|正在直播|回放生成中|暂不可看|直播已结束');
  expect(
      find.descendant(
          of: entry, matching: find.textContaining(removedMetadata)),
      findsNothing);
}

Semantics _daySemantics(WidgetTester tester, String date) =>
    tester.widget<Semantics>(find
        .ancestor(
          of: _day(date),
          matching: find.byWidgetPredicate((widget) =>
              widget is Semantics && widget.properties.selected != null),
        )
        .first);

void main() {
  testWidgets('shows all seven dates and chronological lessons without covers',
      (tester) async {
    await _mount(tester,
        _data(lessons: [_lesson(2, 21, hour: 10, section: 3), _lesson(1, 21)]));

    expect(find.byKey(const ValueKey('timetable-weekdays')), findsOneWidget);
    for (var day = 19; day <= 25; day++) {
      expect(_day('2026-10-$day'), findsOneWidget);
    }
    expect(find.text('周六'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-21').properties.selected, isTrue);
    expect(_daySemantics(tester, '2026-10-21').properties.onTap, isNotNull);
    expect(tester.getTopLeft(_entry(1)).dy,
        lessThan(tester.getTopLeft(_entry(2)).dy));
    expect(find.text('1-2节'), findsOneWidget);
    expect(find.text('8:00'), findsOneWidget);
    expect(find.text('3-4节'), findsOneWidget);
    expect(find.byKey(const ValueKey('timetable-slot-3-4')), findsOneWidget);
    expect(find.byType(RecordingCourseTitle), findsNWidgets(2));
    expect(find.textContaining('CS101 · 教师甲'), findsNWidgets(2));
    expect(find.textContaining('第 1 集'), findsOneWidget);
    expect(find.textContaining('第 2 集'), findsOneWidget);
    expect(find.descendant(of: _entry(1), matching: find.textContaining('第1节')),
        findsOneWidget);
    expect(find.descendant(of: _entry(2), matching: find.textContaining('第3节')),
        findsOneWidget);
    _expectCompactMetadata(_entry(1));
    _expectCompactMetadata(_entry(2));
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'description orders classroom section and episode with scoped colors',
      (tester) async {
    for (final themeId in [ShuYoThemes.defaultId, ShuYoThemes.systemDarkId]) {
      for (final playable in [true, false]) {
        await _mount(
            tester,
            _data(lessons: [
              _lesson(1, 21, classroom: '宝山 A101', playable: playable),
            ]),
            themeId: themeId);
        final context = tester.element(_entry(1));
        final colors = context.shuyoColors;
        final secondary = playable ? colors.textSecondary : colors.textMuted;
        final primary = Theme.of(context).colorScheme.primary;
        final title = tester.widget<RecordingCourseTitle>(find.descendant(
            of: _entry(1), matching: find.byType(RecordingCourseTitle)));

        expect(title.description, isA<Text>());
        final description = title.description! as Text;
        expect(description.data, isNull);
        expect(description.textSpan!.toPlainText(), '宝山 A101 · 第1节 · 第 1 集');
        expect(description.style!.color, secondary);
        final spans =
            (description.textSpan! as TextSpan).children!.cast<TextSpan>();
        expect(spans, hasLength(5));
        expect(spans[0].text, '宝山 A101');
        expect(spans[0].style!.color, playable ? primary : colors.textMuted);
        expect(spans[1].text, ' · ');
        expect(spans[1].style, isNull);
        expect(spans[2].text, '第1节');
        expect(spans[2].style!.color,
            playable ? colors.textPrimary : colors.textMuted);
        expect(spans[3].text, ' · ');
        expect(spans[3].style, isNull);
        expect(spans[4].text, '第 1 集');
        expect(spans[4].style!.color,
            playable ? colors.textPrimary : colors.textMuted);
        _expectCompactMetadata(_entry(1));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('description omits missing fields without stray separators',
      (tester) async {
    final cases = <({String classroom, int? section, String description})>[
      (classroom: '', section: 1, description: '第1节 · 第 1 集'),
      (classroom: '嘉定 J201', section: null, description: '嘉定 J201 · 第 1 集'),
      (classroom: '', section: null, description: '第 1 集'),
    ];
    for (final testCase in cases) {
      await _mount(
          tester,
          _data(lessons: [
            _lesson(1, 21,
                classroom: testCase.classroom, section: testCase.section),
          ]));
      final title = tester.widget<RecordingCourseTitle>(find.descendant(
          of: _entry(1), matching: find.byType(RecordingCourseTitle)));
      expect(title.description, isA<Text>());
      final description = title.description! as Text;
      expect(description.textSpan!.toPlainText(), testCase.description);
      expect(description.style!.color,
          tester.element(_entry(1)).shuyoColors.textSecondary);
      final spans =
          (description.textSpan! as TextSpan).children!.cast<TextSpan>();
      final expectedSpanCount = (testCase.classroom.isEmpty ? 0 : 2) +
          (testCase.section == null ? 0 : 2) +
          1;
      expect(spans, hasLength(expectedSpanCount));
      expect(spans.last.text, '第 1 集');
      expect(spans.last.style!.color,
          tester.element(_entry(1)).shuyoColors.textPrimary);
      if (testCase.section != null) {
        final sectionSpan =
            spans.singleWhere((span) => span.text == '第${testCase.section}节');
        expect(sectionSpan.style!.color,
            tester.element(_entry(1)).shuyoColors.textPrimary);
      }
      _expectCompactMetadata(_entry(1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'same-slot courses share one marker and keep the original bare rows',
      (tester) async {
    const secondCourse = VodCourse(
      teachingClassId: 102,
      termId: 7,
      name: '线性代数',
      code: 'MA102',
      teacherNames: ['教师乙'],
    );
    final secondLesson = VodLesson(
      id: 2,
      teachingClassId: 102,
      name: secondCourse.name,
      isPlayable: true,
      beginTime: DateTime(2026, 10, 21, 9),
      weekNumber: 1,
      sectionLabel: '第2节',
    );
    await _mount(
      tester,
      RecordingTimetableData(
        term: _term,
        courses: const [_course, secondCourse],
        lessonsByCourse: {
          101: [_lesson(1, 21)],
          102: [secondLesson]
        },
        now: DateTime(2026, 10, 21, 12),
      ),
    );

    final secondEntry = find.byKey(const ValueKey('timetable-entry-102-2'));
    expect(find.byKey(const ValueKey('timetable-slot-1-2')), findsOneWidget);
    expect(find.text('1-2节'), findsOneWidget);
    expect(find.text('8:00'), findsOneWidget);
    expect(find.byType(SliverPersistentHeader), findsOneWidget);
    expect(secondEntry, findsOneWidget);
    for (final entry in [_entry(1), secondEntry]) {
      final row = tester.widget<ListTile>(entry);
      expect(row.contentPadding,
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8));
      expect(row.enabled, isTrue);
      expect(row.onTap, isNotNull);
      expect(row.title, isA<RecordingCourseTitle>());
      expect((row.title! as RecordingCourseTitle).description, isNotNull);
      _expectCompactMetadata(entry);
      expect(
          find.descendant(
              of: entry, matching: find.byType(RecordingStatusIcon)),
          findsOneWidget);
      expect(
          find.descendant(
              of: entry, matching: find.byIcon(Icons.chevron_right)),
          findsOneWidget);
      expect(
        find.ancestor(
          of: entry,
          matching: find.byWidgetPredicate((widget) =>
              widget is Material && widget.shape is RoundedRectangleBorder),
        ),
        findsNothing,
      );
    }
    expect(find.byType(Card), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'slot labels pin inside their group and the next group replaces them',
      (tester) async {
    await _mount(
        tester,
        _data(lessons: [
          for (var index = 0; index < 12; index++) _lesson(index + 1, 21),
          for (var index = 0; index < 12; index++)
            _lesson(index + 101, 21, hour: 10, section: 3),
        ]));
    final list = find.byKey(const PageStorageKey('timetable-list-2026-10-21'));
    final firstSlot = find.byKey(const ValueKey('timetable-slot-1-2'));
    final secondSlot = find.byKey(const ValueKey('timetable-slot-3-4'));
    final viewportTop = tester.getRect(list).top;
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();

    final pinnedTop = tester.getRect(firstSlot).top;
    expect(pinnedTop, inInclusiveRange(viewportTop - 1, viewportTop + 20));
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getRect(firstSlot).top, closeTo(pinnedTop, 1));
    expect(find.text('1-2节'), findsOneWidget);

    var secondPinned = false;
    for (var step = 0; step < 20; step++) {
      await tester.drag(list, const Offset(0, -120));
      await tester.pumpAndSettle();
      if (secondSlot.evaluate().isNotEmpty &&
          (tester.getRect(secondSlot).top - pinnedTop).abs() <= 1) {
        secondPinned = true;
        break;
      }
    }

    expect(secondPinned, isTrue);
    expect(find.text('3-4节'), findsOneWidget);
    expect(find.byType(SliverPersistentHeader, skipOffstage: false),
        findsNWidgets(2));
    if (firstSlot.evaluate().isNotEmpty) {
      expect(
          tester.getRect(firstSlot).bottom, lessThanOrEqualTo(viewportTop + 1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('lessons without a section stay in the other-time group',
      (tester) async {
    await _mount(
        tester, _data(lessons: [_lesson(1, 21, hour: 12, section: null)]));

    expect(find.text('其他时段'), findsOneWidget);
    expect(_entry(1), findsOneWidget);
    expect(find.text('1-2节'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'date buttons animate pages and swipes stay within Monday to Sunday',
      (tester) async {
    await _mount(
        tester,
        _data(lessons: [
          _lesson(1, 21),
          _lesson(2, 25),
          _lesson(3, 26, week: 2),
        ]));
    final pageView = find.byKey(const ValueKey('timetable-pageview'));
    final controller = tester.widget<PageView>(pageView).controller!;
    expect(controller.page, 2);

    await tester.tap(_day('2026-10-25'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(controller.page, greaterThan(2));
    expect(controller.page, lessThan(6));
    await tester.pumpAndSettle();
    expect(controller.page, 6);
    expect(_entry(2), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-25').properties.selected, isTrue);

    await tester.drag(pageView, const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 6);
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-25').properties.selected, isTrue);
    expect(_entry(2), findsOneWidget);

    await tester.tap(_day('2026-10-19'));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    await tester.drag(pageView, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-19').properties.selected, isTrue);
    expect(_day('2026-10-26'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'only week arrows change weeks while keeping the selected weekday',
      (tester) async {
    await _mount(tester, _data(), disableAnimations: true);

    await tester.drag(find.text('第 1 周'), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 1 周'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-week-scrubber')), findsNothing);
    expect(_daySemantics(tester, '2026-10-21').properties.selected, isTrue);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.chevron_left))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();

    expect(find.text('第 2 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-28').properties.selected, isTrue);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.chevron_right))
            .onPressed,
        isNull);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    await tester.drag(find.text('第 2 周'), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(find.text('第 2 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-28').properties.selected, isTrue);
    await tester.tap(find.byTooltip('上一周'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-21').properties.selected, isTrue);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only playable lessons open and unavailable lessons stay grey',
      (tester) async {
    final selected = <RecordingTimetableEntry>[];
    final playable = _lesson(1, 21);
    final unavailableLive = VodLesson(
      id: 4,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: false,
      isLive: true,
      beginTime: DateTime(2026, 10, 21, 14),
      weekNumber: 1,
      sectionLabel: '第1节',
    );
    await _mount(
      tester,
      _data(lessons: [
        playable,
        _lesson(2, 21, hour: 10, playable: false, generating: true),
        _lesson(3, 21, hour: 12, playable: false),
        unavailableLive,
      ]),
      onLessonSelected: selected.add,
    );

    await tester.tap(_entry(1));
    expect(selected.single.lesson, same(playable));
    expect(selected.single.lesson.id, 1);
    expect(selected.single.course.teachingClassId, 101);
    expect(
        find.descendant(
            of: _entry(1), matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    _expectCompactMetadata(_entry(1));
    for (final lessonId in [2, 3, 4]) {
      final entry = _entry(lessonId);
      final row = tester.widget<ListTile>(entry);
      expect(row.onTap, isNull);
      expect(row.enabled, isFalse);
      expect(row.trailing, isNull);
      expect(
          find.descendant(
              of: entry, matching: find.byIcon(Icons.chevron_right)),
          findsNothing);
      _expectCompactMetadata(entry);
      await tester.tap(entry);
    }
    expect(selected, hasLength(1));
    expect(find.descendant(of: _entry(2), matching: find.byType(ColorFiltered)),
        findsOneWidget);
    final colors = tester.element(_entry(2)).shuyoColors;
    final disabledTitle = tester.widget<ColorFiltered>(
        find.descendant(of: _entry(2), matching: find.byType(ColorFiltered)));
    expect(disabledTitle.colorFilter,
        ColorFilter.mode(colors.textMuted, BlendMode.srcIn));
    final disabledIcon = tester.widget<RecordingStatusIcon>(find.descendant(
        of: _entry(2), matching: find.byType(RecordingStatusIcon)));
    expect(disabledIcon.enabled, isFalse);
    expect(disabledIcon.disabledColor, colors.textMuted);
    final disabledLiveIcon = tester.widget<RecordingStatusIcon>(find.descendant(
        of: _entry(4), matching: find.byType(RecordingStatusIcon)));
    expect(disabledLiveIcon.isLive, isTrue);
    expect(disabledLiveIcon.enabled, isFalse);
    expect(disabledLiveIcon.disabledColor, colors.textMuted);
    expect(find.descendant(of: _entry(4), matching: find.byType(ColorFiltered)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'loading stays blank while failures keep refreshable partial content',
      (tester) async {
    var refreshes = 0;
    await _mount(tester, _data(), loading: true, refreshEnabled: false);
    expect(find.text('当天暂无课程'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);

    await _mount(tester, _data(),
        failedCourseCount: 1, onRefresh: () async => refreshes++);
    await tester.pumpAndSettle();
    expect(find.text('1 门课程课次暂未加载，下拉重试'), findsOneWidget);
    expect(find.text('当天暂无已加载课程'), findsOneWidget);
    expect(find.text('当天暂无课程'), findsNothing);
    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(refreshes, 1);

    await _mount(tester, _data(lessons: [_lesson(1, 21)]),
        failedCourseCount: 1);
    await tester.pumpAndSettle();
    expect(_entry(1), findsOneWidget);
    expect(
        find.byKey(const ValueKey('timetable-load-warning')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live status uses its animated icon without redundant text',
      (tester) async {
    final selected = <RecordingTimetableEntry>[];
    final live = VodLesson(
      id: 20,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: true,
      isLive: true,
      beginTime: DateTime(2026, 10, 21, 8),
      weekNumber: 1,
      sectionLabel: '第1节',
      classroom: '宝山 A101',
    );
    await _mount(tester, _data(lessons: [live]),
        onLessonSelected: selected.add);

    _expectCompactMetadata(_entry(20));
    final statusIcon =
        tester.widget<RecordingStatusIcon>(find.byType(RecordingStatusIcon));
    expect(statusIcon.isLive, isTrue);
    expect(statusIcon.enabled, isTrue);
    expect(find.textContaining('宝山 A101'), findsOneWidget);
    expect(find.textContaining('第1节'), findsOneWidget);
    expect(find.textContaining('第 1 集'), findsOneWidget);
    expect(
        find.descendant(
            of: _entry(20), matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    await tester.tap(_entry(20));
    expect(selected.single.lesson, same(live));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'UTC lessons stay on the school day without repeating week or exact time',
      (tester) async {
    final lesson = VodLesson(
      id: 30,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: true,
      beginTime: DateTime.utc(2026, 10, 18, 16, 30),
      weekNumber: 1,
      sectionLabel: '第1节',
      classroom: '嘉定 J201',
    );
    await _mount(
        tester, _data(lessons: [lesson], now: DateTime(2026, 10, 19, 8)));

    expect(_daySemantics(tester, '2026-10-19').properties.selected, isTrue);
    expect(_entry(30), findsOneWidget);
    _expectCompactMetadata(_entry(30));
    expect(find.textContaining('嘉定 J201'), findsOneWidget);
    expect(find.textContaining('第1节'), findsOneWidget);
    expect(find.descendant(of: _entry(30), matching: find.textContaining('周日')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'interrupting date animation keeps the settled page and date linked',
      (tester) async {
    await _mount(tester, _data(lessons: [_lesson(1, 21)]));
    await tester.tap(_day('2026-10-25'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    await tester.drag(find.byType(PageView), const Offset(420, 0));
    await tester.pumpAndSettle();

    final page = tester
        .widget<PageView>(find.byType(PageView))
        .controller!
        .page!
        .round();
    final date = DateTime(2026, 10, 19 + page);
    final dateKey =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    expect(_daySemantics(tester, dateKey).properties.selected, isTrue);
    expect(page, inInclusiveRange(0, 6));
    expect(find.text('第 1 周'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rapid date taps and week changes interrupt the previous animation',
      (tester) async {
    await _mount(tester, _data());
    await tester.tap(_day('2026-10-25'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_day('2026-10-19'));
    await tester.pumpAndSettle();

    expect(_daySemantics(tester, '2026-10-19').properties.selected, isTrue);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    await tester.tap(_day('2026-10-25'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();

    expect(find.text('第 2 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-11-01').properties.selected, isTrue);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('progressive anchor changes preserve the selected real date',
      (tester) async {
    const floatingTerm = VodTerm(id: 7, name: '学期');
    await _mount(tester, _data(term: floatingTerm, lessons: [_lesson(1, 21)]));
    await tester.tap(_day('2026-10-25'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    await _mount(
        tester,
        _data(term: floatingTerm, lessons: [
          _lesson(2, 12),
          _lesson(1, 21, week: 2),
          _lesson(3, 25, week: 2),
        ]));
    await tester.pumpAndSettle();

    expect(find.text('第 2 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-25').properties.selected, isTrue);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 6);
    expect(_entry(3), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first dated response initializes an untouched historical term',
      (tester) async {
    final now = DateTime(2027, 1, 20);
    await _mount(tester, _data(now: now), loading: true);
    await _mount(tester, _data(now: now, lessons: [_lesson(1, 19)]));
    await tester.pumpAndSettle();

    expect(find.text('第 1 周'), findsOneWidget);
    expect(_daySemantics(tester, '2026-10-19').properties.selected, isTrue);
    expect(_entry(1), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'historical batches select the same final boundary in either order',
      (tester) async {
    final now = DateTime(2027, 1, 20);
    final earlier = _lesson(1, 19);
    final later = _lesson(2, 28, week: 2);
    final completeData = _data(now: now, lessons: [earlier, later]);
    final expectedDate = completeData.dateFor(
      completeData.initialWeek,
      completeData.initialWeekday,
    );
    expect(expectedDate, DateTime(2026, 10, 28));
    final finalPages = <double>[];

    for (final firstBatch in [earlier, later]) {
      await _mount(tester, _data(now: now), loading: true);
      await _mount(tester, _data(now: now, lessons: [firstBatch]),
          loading: true);
      await tester.pumpAndSettle();
      await _mount(tester, completeData);
      await tester.pumpAndSettle();

      expect(_daySemantics(tester, '2026-10-28').properties.selected, isTrue);
      expect(_entry(2), findsOneWidget);
      finalPages.add(
          tester.widget<PageView>(find.byType(PageView)).controller!.page!);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }

    expect(finalPages, [2, 2]);
  });

  testWidgets('each date restores its vertical scroll position',
      (tester) async {
    await _mount(
        tester,
        _data(lessons: [
          for (var index = 0; index < 15; index++)
            _lesson(index + 1, 21, hour: index),
          _lesson(100, 22),
        ]),
        disableAnimations: true);
    final list = find.byKey(const PageStorageKey('timetable-list-2026-10-21'));
    await tester.drag(list, const Offset(0, -650));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ))
        .position
        .pixels;
    expect(position, greaterThan(0));
    await tester.tap(_day('2026-10-25'));
    await tester.pumpAndSettle();
    await tester.tap(_day('2026-10-21'));
    await tester.pumpAndSettle();

    expect(
        tester
            .state<ScrollableState>(find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            ))
            .position
            .pixels,
        closeTo(position, .1));
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一周'));
    await tester.pumpAndSettle();
    expect(
        tester
            .state<ScrollableState>(find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            ))
            .position
            .pixels,
        closeTo(position, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '320 pixel layout and double text keep all dates and course rows usable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
        tester,
        _data(lessons: [
          _lesson(1, 21),
          _lesson(2, 21, hour: 12, playable: false, generating: true),
        ]),
        textScale: 2);
    await tester.pumpAndSettle();

    expect(_day('2026-10-25'), findsOneWidget);
    expect(tester.getRect(_day('2026-10-25')).right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    await tester.tap(_day('2026-10-25'));
    await tester.pumpAndSettle();
    expect(find.text('当天暂无课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
