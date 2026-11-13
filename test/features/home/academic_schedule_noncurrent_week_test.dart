import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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

  testWidgets('uses the same text styles for single and multi-section courses',
      (tester) async {
    await _pumpCourseLayout(tester, [
      for (final singleSection in [false, true])
        _session(
          id: singleSection ? 'one-section' : 'two-sections',
          name: '课程',
          weekday: singleSection ? 2 : 1,
          weeks: const [1],
          teacherName: '教师',
          note: '备注',
          endSection: singleSection ? 1 : 2,
        ),
    ]);

    for (final value in ['课程', '教师', '备注']) {
      final single = tester.widget<Text>(_courseText('one-section', value));
      final multiple = tester.widget<Text>(_courseText('two-sections', value));
      expect(single.style, multiple.style);
      expect(single.style!.fontSize, value == '课程' ? 11.5 : 10.5);
      if (value != '教师') expect(single.style!.height, 1.2);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('ellipsizes long titles without shrinking the text',
      (tester) async {
    const name = '课程名称较长时应当自然换行并在超过行数后显示省略号';
    await _pumpCourseLayout(tester, [
      for (final singleSection in [false, true])
        _session(
          id: singleSection ? 'one-section' : 'two-sections',
          name: name,
          weekday: singleSection ? 2 : 1,
          weeks: const [1],
          location: 'A101',
          endSection: singleSection ? 1 : 2,
        ),
    ]);

    for (final id in ['one-section', 'two-sections']) {
      final title = _courseText(id, name);
      final text = tester.widget<Text>(title);
      expect(text.style!.fontSize, 11.5);
      expect(text.maxLines, id == 'one-section' ? 2 : 3);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
          isTrue);
      expect(_courseText(id, 'A101'), findsOneWidget);
      _expectCourseContentFits(tester, id);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses remaining space for notes above the location',
      (tester) async {
    const note = '带好实验报告并提前完成预习，课前检查设备和资料，课后提交实验记录';
    await _pumpCourseLayout(tester, [
      _session(
        id: 'one-section',
        name: '课程',
        weekday: 1,
        weeks: const [1],
        location: 'A101',
        note: note,
        endSection: 1,
      ),
    ]);

    final noteText = _courseText('one-section', note);
    expect(tester.widget<Text>(noteText).maxLines, inInclusiveRange(1, 2));
    expect(
      tester.getBottomRight(noteText).dy,
      lessThanOrEqualTo(
          tester.getTopLeft(_courseText('one-section', 'A101')).dy),
    );
    _expectCourseContentFits(tester, 'one-section');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hides notes and credit before the teacher or location',
      (tester) async {
    const note = '带好实验报告并提前完成预习，课前检查设备和资料，课后提交实验记录';
    await _pumpCourseLayout(tester, [
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
        name: '单节课程名称需要占据两行',
        weekday: 2,
        weeks: const [1],
        teacherName: '李老师',
        credit: '1',
        location: 'B202',
        note: note,
        endSection: 1,
      ),
    ]);

    expect(tester.widget<Text>(_courseText('two-sections', note)).maxLines, 3);
    expect(_courseText('two-sections', '张老师'), findsOneWidget);
    expect(_courseText('two-sections', '2'), findsOneWidget);
    expect(_courseText('two-sections', 'A101'), findsOneWidget);
    expect(
      tester.getBottomRight(_courseText('two-sections', note)).dy,
      lessThanOrEqualTo(
          tester.getTopLeft(_courseText('two-sections', 'A101')).dy),
    );

    expect(_courseText('one-section', note), findsNothing);
    expect(_courseText('one-section', '1'), findsNothing);
    expect(_courseText('one-section', '李老师'), findsOneWidget);
    expect(_courseText('one-section', 'B202'), findsOneWidget);
    for (final id in ['two-sections', 'one-section']) {
      _expectCourseContentFits(tester, id);
    }
    expect(tester.takeException(), isNull);

    await tester.tap(_courseBlock('one-section'));
    await tester.pumpAndSettle();
    final details = find.byType(BottomSheet);
    for (final value in ['单节课程名称需要占据两行', '李老师', '1 学分', 'B202', note]) {
      expect(find.descendant(of: details, matching: find.text(value)),
          findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final textScale in [1.5, 6.0]) {
    testWidgets('keeps narrow course blocks bounded at text scale $textScale',
        (tester) async {
      const name = '课程名称较长时应当使用省略号';
      await _pumpCourseLayout(tester, [
        _session(
          id: 'one-section',
          name: name,
          weekday: 1,
          weeks: const [1],
          teacherName: '教师',
          credit: '2',
          location: 'A101',
          note: '备注',
          endSection: 1,
        ),
      ]);
      final block = tester.widget<Widget>(_courseBlock('one-section'));

      // Isolate the block from page headers when exercising extreme text scales.
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(child: SizedBox(width: 40, height: 63, child: block)),
        ),
      ));

      final title = tester.widget<Text>(_courseText('one-section', name));
      expect(title.style!.fontSize, 11.5);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(_courseText('one-section', '教师'), findsNothing);
      expect(_courseText('one-section', '2'), findsNothing);
      expect(_courseText('one-section', '备注'), findsNothing);
      expect(_courseText('one-section', 'A101'),
          textScale == 1.5 ? findsOneWidget : findsNothing);
      _expectCourseContentFits(tester, 'one-section');
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pumpCourseLayout(
  WidgetTester tester,
  List<CourseSession> sessions,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(_ignoreListTileBackgroundWarning());
  final repository = AcademicScheduleRepository(
    apiClient:
        AcademicScheduleApiClient(authService: _FakeAcademicAuthService()),
  );
  await tester.pumpWidget(MaterialApp(
    home: AcademicSchedulePage(
      repository: repository,
      notificationService:
          AcademicScheduleNotificationService(repository: repository),
      widgetService: AcademicScheduleWidgetService(repository: repository),
      onLoginRequired: () async {},
      initialState: AcademicScheduleCacheState(
        schedule: _schedule.copyWith(sessions: sessions),
        weekState: ScheduleWeekState(
          currentWeek: 1,
          anchorMonday: AcademicScheduleRepository.startOfWeek(DateTime.now()),
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
}

Finder _courseBlock(String id) => find.byKey(ValueKey('schedule-course-$id'));

Finder _courseText(String id, String value) =>
    find.descendant(of: _courseBlock(id), matching: find.text(value));

void _expectCourseContentFits(WidgetTester tester, String id) {
  final block = _courseBlock(id);
  expect(
      find.descendant(of: block, matching: find.byType(SingleChildScrollView)),
      findsNothing);
  final bounds = tester.getRect(block);
  final texts = find.descendant(of: block, matching: find.byType(Text));
  for (final element in texts.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.top, greaterThanOrEqualTo(bounds.top));
    expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 0.01));
  }
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
