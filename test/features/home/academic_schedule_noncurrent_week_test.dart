import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_schedule_display_settings_service.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('schedule info shows the cached synchronization time',
      (tester) async {
    final repository = AcademicScheduleRepository();
    await tester.pumpWidget(MaterialApp(
      home: AcademicSchedulePage(
        repository: repository,
        notificationService:
            AcademicScheduleNotificationService(repository: repository),
        widgetService: AcademicScheduleWidgetService(repository: repository),
        onLoginRequired: () async {},
        initialState: AcademicScheduleCacheState(
          schedule: _schedule,
          weekState: ScheduleWeekState(
            currentWeek: 1,
            anchorMonday:
                AcademicScheduleRepository.startOfWeek(DateTime.now()),
          ),
        ),
      ),
    ));

    expect(find.byIcon(Icons.people_outlined), findsOneWidget);

    await tester.tap(find.byTooltip('课表信息说明'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '应用每次获取的课表信息为当时教务系统中数据，并非实时更新\n\n'
        '因此当发生课程变更、教室变更等情况，需手动进行刷新\n\n'
        '同步于 2026-08-31 00:00',
      ),
      findsOneWidget,
    );
  });

  testWidgets('custom photo uses stronger theme color for schedule dates',
      (tester) async {
    const background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 100,
      background: Color(0xFF777777),
      surface: Color(0xFFBBBBBB),
      text: Colors.black,
      accent: Colors.blue,
    );
    final repository = AcademicScheduleRepository(
      apiClient: AcademicScheduleApiClient(
        authService: _FakeAcademicAuthService(),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      theme: background.theme.themeData(),
      builder: (_, child) => CustomBackgroundFrame(
        settings: background,
        child: child!,
      ),
      home: AcademicSchedulePage(
        repository: repository,
        notificationService:
            AcademicScheduleNotificationService(repository: repository),
        widgetService: AcademicScheduleWidgetService(repository: repository),
        onLoginRequired: () async {},
        initialState: AcademicScheduleCacheState(
          schedule: _schedule,
          weekState: ScheduleWeekState(
            currentWeek: 1,
            anchorMonday:
                AcademicScheduleRepository.startOfWeek(DateTime.now()),
          ),
        ),
      ),
    ));
    await tester.pump();

    final dates = find.byWidgetPredicate((widget) =>
        widget is Text &&
        RegExp(r'^\d{1,2}/\d{1,2}$').hasMatch(widget.data ?? ''));
    expect(dates, findsWidgets);
    for (final date in tester.widgetList<Text>(dates)) {
      expect(date.style?.color, background.text);
    }
  });

  testWidgets(
      'shows non-current-week courses unless a current course occupies the slot',
      (tester) async {
    final restoreFlutterError = _ignoreListTileBackgroundWarning();
    addTearDown(restoreFlutterError);
    final repository = AcademicScheduleRepository(
      apiClient: AcademicScheduleApiClient(
        authService: _FakeAcademicAuthService(),
      ),
    );
    final state = AcademicScheduleCacheState(
      schedule: _schedule,
      weekState: ScheduleWeekState(
        currentWeek: 1,
        anchorMonday: AcademicScheduleRepository.startOfWeek(DateTime.now()),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AcademicSchedulePage(
          repository: repository,
          notificationService:
              AcademicScheduleNotificationService(repository: repository),
          widgetService: AcademicScheduleWidgetService(repository: repository),
          onLoginRequired: () async {},
          initialState: state,
          initialDisplayState: const AcademicScheduleDisplayState(
            settings: AcademicScheduleDisplaySettings(
              colorful: true,
              showTeacher: false,
            ),
            courseColorValues: {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('本周课程'), findsOneWidget);
    expect(find.text('下周课程'), findsOneWidget);
    expect(find.text('被本周课程覆盖'), findsNothing);
    final nonCurrentBlock = find.byKey(
      const ValueKey('schedule-course-next'),
    );
    expect(nonCurrentBlock, findsOneWidget);
    final nonCurrentMaterial = tester.widget<Material>(
      find.descendant(of: nonCurrentBlock, matching: find.byType(Material)),
    );
    expect(
      nonCurrentMaterial.color,
      const Color(0xFFBDBDBD),
    );

    await tester.tap(find.text('下周课程'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    expect(find.text('显示非本周课程'), findsOneWidget);
    await tester.tap(find.text('显示非本周课程'));
    await tester.ensureVisible(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('本周课程'), findsOneWidget);
    expect(find.text('下周课程'), findsNothing);
  });

  testWidgets('shows credit directly below course metadata in display order',
      (tester) async {
    final restoreFlutterError = _ignoreListTileBackgroundWarning();
    addTearDown(restoreFlutterError);
    final repository = AcademicScheduleRepository(
      apiClient: AcademicScheduleApiClient(
        authService: _FakeAcademicAuthService(),
      ),
    );
    final state = AcademicScheduleCacheState(
      schedule: _schedule,
      weekState: ScheduleWeekState(
        currentWeek: 1,
        anchorMonday: AcademicScheduleRepository.startOfWeek(DateTime.now()),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AcademicSchedulePage(
          repository: repository,
          notificationService:
              AcademicScheduleNotificationService(repository: repository),
          widgetService: AcademicScheduleWidgetService(repository: repository),
          onLoginRequired: () async {},
          initialState: state,
          initialDisplayState: const AcademicScheduleDisplayState(
            settings: AcademicScheduleDisplaySettings(
              colorful: false,
              showTeacher: false,
              showCredit: true,
            ),
            courseColorValues: {},
          ),
        ),
      ),
    );
    await tester.pump();

    final currentCourseBlock = find.byKey(
      const ValueKey('schedule-course-current'),
    );
    final creditText = find.descendant(
      of: currentCourseBlock,
      matching: find.text('2'),
    );
    expect(creditText, findsOneWidget);
    expect(find.text('张老师'), findsNothing);
    expect(find.text('课堂提示'), findsNothing);
    expect(
      tester.getTopLeft(creditText).dy,
      greaterThan(tester.getTopLeft(find.text('本周课程')).dy),
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    expect(find.text('显示学分'), findsOneWidget);
    await tester.tap(find.text('显示教师'));
    await tester.tap(find.text('显示备注'));
    await tester.ensureVisible(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('张老师'), findsOneWidget);
    expect(find.text('课堂提示'), findsOneWidget);
    expect(creditText, findsOneWidget);
    expect(
      tester.getTopLeft(creditText).dy,
      greaterThan(tester.getTopLeft(find.text('张老师')).dy),
    );
  });

  testWidgets('keeps selected fields and fits note above location',
      (tester) async {
    final restoreFlutterError = _ignoreListTileBackgroundWarning();
    addTearDown(restoreFlutterError);
    final repository = AcademicScheduleRepository(
      apiClient: AcademicScheduleApiClient(
        authService: _FakeAcademicAuthService(),
      ),
    );
    const note = '带好实验报告并提前完成预习，课前检查设备和资料，课后提交实验记录';
    final schedule = _schedule.copyWith(sessions: [
      _session(
        id: 'two-sections',
        name: '课程',
        weekday: 1,
        weeks: const [1],
        teacherName: '张老师',
        credit: '2',
        location: 'A101',
        note: note,
      ),
      _session(
        id: 'one-section',
        name: '单节课程',
        weekday: 2,
        weeks: const [1],
        teacherName: '李老师',
        credit: '1',
        location: 'B202',
        note: note,
        endSection: 1,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: AcademicSchedulePage(
        repository: repository,
        notificationService:
            AcademicScheduleNotificationService(repository: repository),
        widgetService: AcademicScheduleWidgetService(repository: repository),
        onLoginRequired: () async {},
        initialState: AcademicScheduleCacheState(
          schedule: schedule,
          weekState: ScheduleWeekState(
            currentWeek: 1,
            anchorMonday:
                AcademicScheduleRepository.startOfWeek(DateTime.now()),
          ),
        ),
        initialDisplayState: const AcademicScheduleDisplayState(
          settings: AcademicScheduleDisplaySettings(
            colorful: true,
            showTeacher: true,
            showCredit: true,
            showNote: true,
          ),
          courseColorValues: {},
        ),
      ),
    ));
    await tester.pump();

    for (final id in ['two-sections', 'one-section']) {
      final block = find.byKey(ValueKey('schedule-course-$id'));
      final noteWidget = tester.widget<Text>(
        find.descendant(of: block, matching: find.text(note)),
      );
      if (id == 'two-sections') {
        expect(noteWidget.maxLines, 3);
      } else {
        expect(noteWidget.maxLines, lessThan(3));
      }
      expect(
        find.descendant(
            of: block,
            matching: find.text(id == 'two-sections' ? '张老师' : '李老师')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: block, matching: find.text(id == 'two-sections' ? '2' : '1')),
        findsOneWidget,
      );
      final location = find.descendant(
        of: block,
        matching: find.text(id == 'two-sections' ? 'A101' : 'B202'),
      );
      expect(location, findsOneWidget);
      expect(
          tester.getTopLeft(location).dy,
          greaterThan(tester
              .getTopLeft(find.descendant(of: block, matching: find.text(note)))
              .dy));
      expect(tester.getBottomRight(location).dy,
          lessThanOrEqualTo(tester.getBottomRight(block).dy));
    }
    expect(tester.takeException(), isNull);
  });
}

void Function() _ignoreListTileBackgroundWarning() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().startsWith(
          'ListTile background color or ink splashes may be invisible.',
        )) {
      return;
    }
    previous?.call(details);
  };
  return () => FlutterError.onError = previous;
}

class _FakeAcademicAuthService implements AcademicAuthService {
  @override
  Future<bool> restoreAcademicCookies({Uri? targetUri}) async => false;

  @override
  Future<void> clearAccount({bool sessionExpired = false}) async {}

  @override
  Future<Set<String>> clearCookies() async => {};

  @override
  Future<void> markLoggedIn() async {}

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => null;

  @override
  Future<String?> cookieHeaderForIdentityVerification(
          {required Uri targetUri}) async =>
      null;

  @override
  Future<bool> hasWebVpnSession() async => false;

  @override
  Future<bool> hasAcademicSession() async => false;

  @override
  Future<WebVpnSessionStatus> validateDirectAcademicSession() async =>
      WebVpnSessionStatus.loginRequired;

  @override
  Future<WebVpnSessionStatus> validateWebVpnSession() async =>
      WebVpnSessionStatus.loginRequired;
}

CourseSession _session({
  required String id,
  required String name,
  required int weekday,
  required List<int> weeks,
  String teacherName = '',
  String credit = '',
  String location = '',
  String note = '',
  int endSection = 2,
}) {
  return CourseSession(
    id: id,
    courseName: name,
    courseCode: id,
    teacherName: teacherName,
    campus: '',
    location: location,
    weekday: weekday,
    startSection: 1,
    endSection: endSection,
    sections: [for (var section = 1; section <= endSection; section++) section],
    weeks: weeks,
    weekText: weeks.join(','),
    credit: credit,
    note: note,
  );
}

final _schedule = AcademicSchedule(
  term: const AcademicTerm(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋',
    studentName: '',
    studentId: '',
    className: '',
  ),
  sessions: [
    _session(
      id: 'current',
      name: '本周课程',
      weekday: 1,
      weeks: const [1],
      teacherName: '张老师',
      credit: '2',
      note: '课堂提示',
    ),
    _session(id: 'covered', name: '被本周课程覆盖', weekday: 1, weeks: const [2]),
    _session(id: 'next', name: '下周课程', weekday: 2, weeks: const [2]),
  ],
  untimedCourses: const [],
  fetchedAt: DateTime(2026, 8, 31),
);
