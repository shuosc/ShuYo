import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_schedule_display_settings_service.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/calendar_date_picker.dart';
import 'package:shuyo/shared/widgets/date_picker_dialog.dart';

void main() {
  testWidgets('start date uses the shared calendar and preserves Monday rules',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = _ScheduleRepository();
    final firstMonday = DateTime(2026, 10, 5);
    await repository.setFirstWeekStart(firstMonday);
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
            anchorMonday: firstMonday,
          ),
        ),
        initialDisplayState: const AcademicScheduleDisplayState(
          settings: AcademicScheduleDisplaySettings(
            colorful: false,
            showTeacher: true,
          ),
          courseColorValues: {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置开学日期'));
    await tester.pumpAndSettle();

    expect(find.byType(ShuYoDatePickerDialog), findsOneWidget);
    expect(find.text('选择开学日期'), findsOneWidget);
    final calendar = tester.widget<ShuYoCalendarDatePicker>(
      find.byType(ShuYoCalendarDatePicker),
    );
    expect(calendar.firstDate, DateTime(2000));
    expect(calendar.lastDate, DateTime(2100, 12, 31));
    expect(calendar.selectedDate, firstMonday);
    expect(calendar.selectableDayPredicate!(firstMonday), isTrue);
    expect(
      calendar.selectableDayPredicate!(DateTime(2026, 10, 6)),
      isFalse,
    );

    await tester.tap(find.descendant(
      of: find.byType(ShuYoDatePickerDialog),
      matching: find.text('12'),
    ));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(
      (await repository.loadWeekState()).firstWeekStart,
      DateTime(2026, 10, 12),
    );

    await tester.tap(find.byTooltip('设置开学日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(ShuYoDatePickerDialog),
      matching: find.text('19'),
    ));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      (await repository.loadWeekState()).firstWeekStart,
      DateTime(2026, 10, 12),
    );
    expect(tester.takeException(), isNull);
  });

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
    final second =
        await AcademicScheduleDisplaySettingsService().loadCourseColors();
    expect(second['MATH101'], isNot(assigned));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新课表'));
    await tester.pumpAndSettle();
    expect(find.text('确认更新'), findsOneWidget);
    expect(find.text('点击确定后将与教务系统中课表同步，不会保留本地编辑'), findsOneWidget);
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
