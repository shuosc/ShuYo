import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/confirmation_window.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_schedule_display_settings_service.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets(
      'update asks before replacing edits; random colors use the palette',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    final palette =
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.schedulePalette;
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: AcademicSchedulePage(
        repository: repository,
        notificationService: _NoopNotifications(repository),
        widgetService: _NoopWidget(repository),
        onLoginRequired: () async {},
        initialState: AcademicScheduleCacheState(
          schedule: _schedule,
          weekState: ScheduleWeekState(
              currentWeek: 1,
              anchorMonday:
                  AcademicScheduleRepository.startOfWeek(DateTime.now())),
        ),
        initialDisplayState: const AcademicScheduleDisplayState(
          settings: AcademicScheduleDisplaySettings(
              colorful: false, showTeacher: true),
          courseColorValues: {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('更新课表'), findsOneWidget);
    expect(find.text('随机颜色'), findsOneWidget);
    expect(tester.getTopLeft(find.text('更新课表')).dy,
        lessThan(tester.getTopLeft(find.text('随机颜色')).dy));
    await tester.tap(find.text('随机颜色'));
    await tester.pumpAndSettle();
    expect(find.text('确认随机颜色'), findsOneWidget);
    expect(find.textContaining('点击确定后将为当前学期所有课程随机分配配色。'),
        findsOneWidget);
    expect(find.textContaining('同时打开多彩显示。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final state = await AcademicScheduleDisplaySettingsService().loadState();
    expect(state.settings.colorful, isTrue);
    final assigned = state.courseColorValues['MATH101'];
    expect(assigned, isNotNull);
    expect(palette.map((color) => color.toARGB32()), contains(assigned));
    final hash = 'MATH101'
        .codeUnits
        .fold<int>(0, (sum, unit) => (sum + unit) & 0x7fffffff);
    expect(assigned, isNot(palette[hash % palette.length].toARGB32()));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机颜色'));
    await tester.pumpAndSettle();
    // Still inside the five-minute window opened by the confirmation above.
    expect(find.text('确认随机颜色'), findsNothing);
    final second =
        await AcademicScheduleDisplaySettingsService().loadCourseColors();
    expect(second['MATH101'], isNot(assigned));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新课表'));
    await tester.pumpAndSettle();
    expect(find.text('确认更新'), findsOneWidget);
    expect(find.text('点击确定后将更新正在查看的这一学期，不会保留本地编辑。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.refreshCalls, 0);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(repository.refreshCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'manual courses keep their automatic color across repeated renames',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    await _pumpColorSchedule(tester, repository, _manualSchedule);
    final originalColor = _courseFill(tester, 'manual:color-1');

    for (final name in ['测试课程2', '测试课程3']) {
      await _renameCourse(tester, name);
      for (final id in ['manual:color-1', 'manual:color-2']) {
        expect(_courseFill(tester, id), originalColor);
      }
      final colors =
          await AcademicScheduleDisplaySettingsService().loadCourseColors();
      expect(colors[name], originalColor.toARGB32());
      final cached = await repository.loadCachedState();
      expect(cached.schedule!.sessions.map((session) => session.courseName),
          everyElement(name));
    }

    final cached = await repository.loadCachedState();
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpColorSchedule(tester, repository, cached.schedule!);
    for (final id in ['manual:color-1', 'manual:color-2']) {
      expect(_courseFill(tester, id), originalColor);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming with colorful display off preserves the assigned color',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    await _pumpColorSchedule(tester, repository, _manualSchedule);
    final originalColor = _courseFill(tester, 'manual:color-1');

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpColorSchedule(tester, repository, _manualSchedule,
        colorful: false);
    await _renameCourse(tester, '测试课程2');
    final colors =
        await AcademicScheduleDisplaySettingsService().loadCourseColors();
    expect(colors['测试课程2'], originalColor.toARGB32());

    final cached = await repository.loadCachedState();
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpColorSchedule(tester, repository, cached.schedule!);
    expect(_courseFill(tester, 'manual:color-1'), originalColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming preserves custom colors and still accepts a new color',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    final palette =
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.schedulePalette;
    final service = AcademicScheduleDisplaySettingsService();
    await service.saveCourseColor('测试课程1', palette[0].toARGB32());
    await _pumpColorSchedule(tester, repository, _manualSchedule);

    await _renameCourse(tester, '测试课程2');
    expect(_courseFill(tester, 'manual:color-1'), palette[0]);
    expect((await service.loadCourseColors())['测试课程2'], palette[0].toARGB32());

    await _renameCourse(tester, '测试课程3', colorIndex: 1);
    for (final id in ['manual:color-1', 'manual:color-2']) {
      expect(_courseFill(tester, id), palette[1]);
    }
    expect((await service.loadCourseColors())['测试课程3'], palette[1].toARGB32());
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving an unchanged name does not pin its automatic color',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    await _pumpColorSchedule(tester, repository, _manualSchedule);
    final originalColor = _courseFill(tester, 'manual:color-1');

    await _renameCourse(tester, '测试课程1');
    expect(_courseFill(tester, 'manual:color-1'), originalColor);
    expect(await AcademicScheduleDisplaySettingsService().loadCourseColors(),
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the color confirmation leaves colors untouched',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: AcademicSchedulePage(
        repository: repository,
        notificationService: _NoopNotifications(repository),
        widgetService: _NoopWidget(repository),
        onLoginRequired: () async {},
        initialState: AcademicScheduleCacheState(
          schedule: _schedule,
          weekState: ScheduleWeekState(
              currentWeek: 1,
              anchorMonday:
                  AcademicScheduleRepository.startOfWeek(DateTime.now())),
        ),
        initialDisplayState: const AcademicScheduleDisplayState(
          settings: AcademicScheduleDisplaySettings(
              colorful: true, showTeacher: true),
          courseColorValues: {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机颜色'));
    await tester.pumpAndSettle();
    expect(find.text('确认随机颜色'), findsOneWidget);
    // Nothing has been overridden yet, so the warning line stays out.
    expect(find.textContaining('已手动设置的颜色会被覆盖'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认随机颜色'), findsNothing);
    expect(await AcademicScheduleDisplaySettingsService().loadCourseColors(),
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('randomizing keeps colors of courses outside the viewing term',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    final palette =
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.schedulePalette;
    final otherTermColor = palette[3].toARGB32();
    await AcademicScheduleDisplaySettingsService()
        .saveCourseColor('OTHER999', otherTermColor);
    await _pumpColorSchedule(tester, repository, _schedule);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机颜色'));
    await tester.pumpAndSettle();
    // OTHER999 is not on screen, so nothing visible is being overwritten.
    expect(find.textContaining('已手动设置的颜色会被覆盖'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final colors =
        await AcademicScheduleDisplaySettingsService().loadCourseColors();
    expect(colors['OTHER999'], otherTermColor);
    expect(palette.map((color) => color.toARGB32()),
        contains(colors['MATH101']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the snack bar undo restores colors and the color mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    final service = AcademicScheduleDisplaySettingsService();
    final palette =
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.schedulePalette;
    final manual = palette[3].toARGB32();
    await service.saveCourseColor('MATH101', manual);
    await _pumpColorSchedule(tester, repository, _schedule, colorful: false);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('随机颜色'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已手动设置的颜色会被覆盖'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect((await service.loadState()).settings.colorful, isTrue);
    expect((await service.loadCourseColors())['MATH101'], isNot(manual));

    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect((await service.loadCourseColors())['MATH101'], manual);
    expect((await service.loadState()).settings.colorful, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('a confirmed reassignment covers the next five minutes only', () {
    final confirmedAt = DateTime(2026, 11, 14, 12);
    const window = Duration(minutes: 5);
    expect(
      isConfirmationFresh(
          confirmedAt: null, now: confirmedAt, window: window),
      isFalse,
    );
    expect(
      isConfirmationFresh(
        confirmedAt: confirmedAt,
        now: confirmedAt.add(const Duration(minutes: 4, seconds: 59)),
        window: window,
      ),
      isTrue,
    );
    expect(
      isConfirmationFresh(
        confirmedAt: confirmedAt,
        now: confirmedAt.add(const Duration(minutes: 5)),
        window: window,
      ),
      isFalse,
    );
    // A clock that jumps backwards must not suppress the dialog.
    expect(
      isConfirmationFresh(
        confirmedAt: confirmedAt,
        now: confirmedAt.subtract(const Duration(seconds: 1)),
        window: window,
      ),
      isFalse,
    );
  });
}

Future<void> _pumpColorSchedule(
  WidgetTester tester,
  AcademicScheduleRepository repository,
  AcademicSchedule schedule, {
  bool colorful = true,
}) async {
  final display = await AcademicScheduleDisplaySettingsService().loadState();
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
    home: AcademicSchedulePage(
      repository: repository,
      notificationService: _NoopNotifications(repository),
      widgetService: _NoopWidget(repository),
      onLoginRequired: () async {},
      initialState: AcademicScheduleCacheState(
        schedule: schedule,
        weekState: ScheduleWeekState(
          currentWeek: 1,
          anchorMonday: AcademicScheduleRepository.startOfWeek(DateTime.now()),
        ),
      ),
      initialDisplayState: AcademicScheduleDisplayState(
        settings: display.settings.copyWith(colorful: colorful),
        courseColorValues: display.courseColorValues,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Color _courseFill(WidgetTester tester, String id) => tester
    .widget<Material>(find
        .descendant(
          of: find.byKey(ValueKey('schedule-course-$id')),
          matching: find.byType(Material),
        )
        .first)
    .color!;

Future<void> _renameCourse(
  WidgetTester tester,
  String name, {
  int? colorIndex,
}) async {
  await tester
      .tap(find.byKey(const ValueKey('schedule-course-manual:color-1')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), name);
  if (colorIndex != null) {
    await tester.tap(find.text('颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(InkWell),
        )
        .at(colorIndex));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.widgetWithText(TextButton, '保存'));
  await tester.pumpAndSettle();
}

class _ScheduleRepository extends AcademicScheduleRepository {
  int refreshCalls = 0;

  @override
  Future<AcademicSchedule> refreshSchedule() async {
    refreshCalls++;
    return _schedule;
  }
}

class _NoopNotifications extends AcademicScheduleNotificationService {
  _NoopNotifications(AcademicScheduleRepository repository)
      : super(repository: repository);

  @override
  Future<int> syncScheduleReminders(
          {bool requestPermission = false, DateTime? now}) async =>
      0;
}

class _NoopWidget extends AcademicScheduleWidgetService {
  _NoopWidget(AcademicScheduleRepository repository)
      : super(repository: repository);

  @override
  Future<void> syncSchedule(
      {required AcademicSchedule? schedule,
      required ScheduleWeekState? weekState,
      DateTime? now}) async {}
}

final _schedule = AcademicSchedule(
  term: const AcademicTerm(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋',
    studentName: '测试',
    studentId: '12345678',
    className: '一班',
  ),
  sessions: const [
    CourseSession(
      id: 'course-1',
      courseName: '数学',
      courseCode: 'MATH101',
      teacherName: '老师',
      campus: '宝山',
      location: '一教',
      weekday: 1,
      startSection: 1,
      endSection: 2,
      sections: [1, 2],
      weeks: [],
      weekText: '每周',
      credit: '3',
      note: '',
    )
  ],
  untimedCourses: const [],
  fetchedAt: DateTime.utc(2026, 10, 8),
);

final _manualSchedule = _schedule.copyWith(sessions: [
  for (var weekday = 1; weekday <= 2; weekday++)
    CourseSession(
      id: 'manual:color-$weekday',
      courseName: '测试课程1',
      courseCode: CourseSession.manualCode,
      teacherName: '',
      campus: '',
      location: '',
      weekday: weekday,
      startSection: 1,
      endSection: 1,
      sections: const [1],
      weeks: const [1, 2],
      weekText: '1-2周',
      credit: '',
      note: '',
    ),
]);
