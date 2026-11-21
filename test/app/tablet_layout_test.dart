import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/demo/demo_data_bundle.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/home/home_dashboard_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

final _rail = find.byType(NavigationRail);
final _bottomBar = find.byType(BottomNavigationBar);
final _schedule = find.byType(AcademicSchedulePage);
final _verticalScroll = find.byKey(
  const PageStorageKey('academic-schedule-vertical-scroll'),
);
final _horizontalScroll = find.byKey(
  const PageStorageKey('academic-schedule-horizontal-scroll'),
);
final _sundayCourse = find.byKey(const ValueKey('schedule-course-sunday'));

Finder _railTab(AppTab tab) =>
    find.descendant(of: _rail, matching: find.text(tab.label));

Finder _day(String label) =>
    find.descendant(of: _schedule, matching: find.text(label));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tablet rail and seven-day schedule work in both orientations',
      (tester) async {
    await _pumpDemoApp(tester, const Size(744, 1133));
    final rail = tester.widget<NavigationRail>(_rail);
    expect(rail.selectedIndex, AppTab.home.index);
    expect(_bottomBar, findsNothing);
    final tabCenters =
        AppTab.values.map((tab) => tester.getCenter(_railTab(tab))).toList();
    expect(tabCenters.map((center) => center.dx).toSet(), hasLength(1));
    for (var index = 1; index < tabCenters.length; index++) {
      expect(tabCenters[index].dy, greaterThan(tabCenters[index - 1].dy));
    }

    await tester.tap(_railTab(AppTab.schedule));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationRail>(_rail).selectedIndex,
        AppTab.schedule.index);

    _expectVisibleWeek(tester);
    await tester.tap(_sundayCourse);
    await tester.pumpAndSettle();
    expect(find.text('周日 第1-2节 每周'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1210, 834);
    await tester.pumpAndSettle();
    _expectVisibleWeek(tester);
    final sundayTop = tester.getTopLeft(_day('周日'));
    final nextWeekTop = tester.getTopLeft(find.byTooltip('下一周'));
    final courseTop = tester.getTopLeft(_sundayCourse);
    await tester.drag(_verticalScroll, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_sundayCourse).dy, lessThan(courseTop.dy));
    expect(tester.getTopLeft(_day('周日')), sundayTop);
    expect(tester.getTopLeft(find.byTooltip('下一周')), nextWeekTop);

    expect(_day('9/6').hitTestable(), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(_day('第 1 周')));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(70, 0));
    await tester.pumpAndSettle();
    final preview = find.textContaining(RegExp(r'^第 \d+ 周$'));
    expect(preview, findsOneWidget);
    final previewText = tester.widget<Text>(preview).data!;
    expect(previewText, isNot('第 1 周'));
    expect(tester.getCenter(preview).dx,
        closeTo(tester.getCenter(_schedule).dx, 0.001));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_day(previewText), findsOneWidget);
  });

  testWidgets('tablet keeps all days visible with larger text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpDemoApp(tester, const Size(744, 1133));
    await tester.tap(_railTab(AppTab.schedule));
    await tester.pumpAndSettle();
    _expectVisibleWeek(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow tablet windows preserve the active tab and week',
      (tester) async {
    await _pumpDemoApp(tester, const Size(1210, 834));
    final dashboard = find.byType(HomeDashboardPage);
    final panelWidth = 1210 - tester.getRect(_rail).right;
    expect(tester.getSize(dashboard).width, lessThan(panelWidth));
    await tester.tap(_railTab(AppTab.schedule));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 周'), findsOneWidget);
    final scheduleState = tester.state(_schedule);

    tester.view.physicalSize = const Size(540, 834);
    await tester.pumpAndSettle();
    expect(_rail, findsNothing);
    expect(tester.widget<BottomNavigationBar>(_bottomBar).currentIndex,
        AppTab.schedule.index);
    expect(_horizontalScroll, findsOneWidget);
    expect(_day('周日').hitTestable(), findsNothing);
    expect(tester.state(_schedule), same(scheduleState));
    expect(find.text('第 2 周'), findsOneWidget);

    tester.view.physicalSize = const Size(834, 1210);
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationRail>(_rail).selectedIndex,
        AppTab.schedule.index);
    expect(_horizontalScroll, findsNothing);
    expect(tester.state(_schedule), same(scheduleState));
    expect(find.text('第 2 周'), findsOneWidget);
    await tester.tap(_railTab(AppTab.progress));
    await tester.pumpAndSettle();
    expect(find.text('平均绩点'), findsOneWidget);
    await tester.tap(_railTab(AppTab.schedule));
    await tester.pumpAndSettle();
    expect(find.text('第 2 周'), findsOneWidget);
  });

  testWidgets(
      'phones retain bottom tabs and a swipeable weekend in both orientations',
      (tester) async {
    await _pumpDemoApp(tester, const Size(393, 852));
    expect(_bottomBar, findsOneWidget);
    expect(_rail, findsNothing);
    await tester
        .tap(find.descendant(of: _bottomBar, matching: find.text('日程')));
    await tester.pumpAndSettle();
    expect(_day('周五').hitTestable(), findsOneWidget);
    expect(_day('周日').hitTestable(), findsNothing);

    await tester.dragFrom(tester.getCenter(_day('周五')), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(_day('周日').hitTestable(), findsOneWidget);
    expect(_sundayCourse.hitTestable(), findsOneWidget);

    tester.view.physicalSize = const Size(852, 393);
    await tester.pumpAndSettle();
    expect(_rail, findsNothing);
    expect(tester.widget<BottomNavigationBar>(_bottomBar).currentIndex,
        AppTab.schedule.index);
    expect(_horizontalScroll, findsOneWidget);
  });
}

void _expectVisibleWeek(WidgetTester tester) {
  expect(_horizontalScroll, findsNothing);
  final scheduleRect = tester.getRect(_schedule);
  expect(scheduleRect.left, greaterThanOrEqualTo(tester.getRect(_rail).right));
  final centers = <Offset>[];
  for (final label in ['周一', '周二', '周三', '周四', '周五', '周六', '周日']) {
    final header = _day(label);
    expect(header.hitTestable(), findsOneWidget);
    final rect = tester.getRect(header);
    expect(rect.left, greaterThan(scheduleRect.left));
    expect(rect.right, lessThanOrEqualTo(scheduleRect.right));
    centers.add(rect.center);
  }
  final columnWidth = centers[1].dx - centers[0].dx;
  expect(columnWidth, greaterThan(0));
  for (var day = 1; day < centers.length; day++) {
    expect(centers[day].dx - centers[day - 1].dx, closeTo(columnWidth, 0.001));
    expect(centers[day].dy, centers.first.dy);
  }
  expect(tester.getCenter(_sundayCourse).dx, closeTo(centers.last.dx, 0.001));
  expect(_sundayCourse.hitTestable(), findsOneWidget);
}

Future<void> _pumpDemoApp(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final demo = (await tester.runAsync(DemoDataBundle.load))!;
  final repository = DemoAcademicScheduleRepository(
    demo.schedule
        .copyWith(sessions: [...demo.schedule.sessions, _weekendCourse]),
  );
  final onboarding = StartupOnboardingController();
  addTearDown(onboarding.dispose);
  await tester.pumpWidget(MaterialApp(
    home: AppShell(
      initialWebVpnEnabled: false,
      selectedThemeId: 'default',
      followSystemTheme: false,
      onThemeChanged: (_) async {},
      onFollowSystemThemeChanged: (_) async {},
      academicLoginSignal: 0,
      initialHasAcademicSession: true,
      initialAcademicStudentId: demo.schedule.term.studentId,
      onboardingController: onboarding,
      isDemo: true,
      demoData: demo,
      scheduleRepository: repository,
    ),
  ));
  await tester.pumpAndSettle();
}

const _weekendCourse = CourseSession(
  id: 'sunday',
  courseName: '周末实验课',
  courseCode: 'TEST',
  teacherName: '',
  campus: '',
  location: 'D101',
  weekday: DateTime.sunday,
  startSection: 1,
  endSection: 2,
  sections: [1, 2],
  weeks: [],
  weekText: '',
  credit: '',
  note: '',
);
