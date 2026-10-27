import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/services/academic_profile_preferences.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/auth/native_login_page.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/home/academic_progress_page.dart';
import 'package:shuyo/features/home/shuyo_content_page.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home campus card refresh shows its feedback inline',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: true,
        initialAcademicStudentId: '25120000',
        onboardingController: controller,
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('刷新校园卡余额'));
    await tester.tap(find.byTooltip('刷新校园卡余额'));
    await tester.pumpAndSettle();
    expect(find.text('演示模式暂不支持校园卡查询'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('home recording entry opens its own login and returns to home',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: false,
        initialAcademicStudentId: null,
        onboardingController: controller,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('课程录播'), 180);
    await tester.tap(find.text('课程录播'));
    await tester.pumpAndSettle();
    expect(find.byType(CourseRecordingsPage), findsOneWidget);
    expect(find.text('登录校园账户'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(
        tester
            .widget<CourseRecordingsPage>(find.byType(CourseRecordingsPage))
            .useWebVpn,
        isFalse);
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeLoginPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CourseRecordingsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('课程录播'), findsOneWidget);
  });

  testWidgets('library booking opens with the latest account campus preference',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: false,
        initialAcademicStudentId: null,
        initialPreferredCampus: '宝山东区',
        onboardingController: controller,
      ),
    ));
    await tester.pumpAndSettle();
    expect(await controller.savePreferredCampus('延长'), isTrue);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('图书馆预约'), 180);
    await tester.pumpAndSettle();
    await tester.tap(find.text('图书馆预约'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<LibraryBookingPage>(find.byType(LibraryBookingPage))
            .initialCampus,
        '延长');
    expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index, 1);
    await tester.ensureVisible(find.text('嘉定校区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('嘉定校区'));
    await tester.pumpAndSettle();
    expect(await AcademicProfilePreferences().loadPreferredCampus(), '延长');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('图书馆预约'));
    await tester.pumpAndSettle();
    expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('opens the schedule from the home row and third tab',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: true,
        initialAcademicStudentId: '25120000',
        initialNickname: '小明',
        onboardingController: controller,
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    final navigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(navigation.items.map((item) => item.label).toList(),
        ['首页', '课评', '学业', '日程']);
    expect(find.text('你好，小明！'), findsOneWidget);
    await tester.tap(find.text('今日课程'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        AppTab.schedule.index);
    expect(find.byType(AcademicSchedulePage), findsOneWidget);
    expect(find.byTooltip('课表信息说明'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.byTooltip('通知'), findsNothing);

    for (final label in ['学业', '首页', '日程']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
              .currentIndex,
          ['首页', '课评', '学业', '日程'].indexOf(label));
      if (label == '学业') {
        expect(find.byType(AcademicProgressPage), findsOneWidget);
        expect(find.byTooltip('更多'), findsOneWidget);
      }
    }
    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('通知'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('使用提示'), findsOneWidget);
    expect(find.text('系统公告'), findsOneWidget);
    expect(find.byType(ShuyoContentPage), findsOneWidget);
  });

  testWidgets('starts on the schedule tab for a widget launch', (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: true,
        initialAcademicStudentId: '25120000',
        onboardingController: controller,
        initialOpenSchedule: true,
        initialStartupTab: AppTab.progress,
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        AppTab.schedule.index);
    expect(find.byType(AcademicSchedulePage), findsOneWidget);
  });

  for (final tab in [AppTab.progress, AppTab.schedule]) {
    testWidgets('starts on the preferred ${tab.label} tab', (tester) async {
      final controller = StartupOnboardingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: AppShell(
          initialWebVpnEnabled: false,
          selectedThemeId: 'default',
          followSystemTheme: false,
          onThemeChanged: (_) async {},
          onFollowSystemThemeChanged: (_) async {},
          academicLoginSignal: 0,
          initialHasAcademicSession: true,
          initialAcademicStudentId: '25120000',
          onboardingController: controller,
          initialStartupTab: tab,
          isDemo: true,
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        tab.index,
      );
      expect(
        tab == AppTab.progress
            ? find.byType(AcademicProgressPage)
            : find.byType(AcademicSchedulePage),
        findsOneWidget,
      );
    });
  }

  testWidgets('changing startup display does not switch the current tab',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: true,
        initialAcademicStudentId: '25120000',
        onboardingController: controller,
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学业'));
    await tester.pumpAndSettle();
    expect(await ClientSettingsService().loadStartupTab(), AppTab.progress);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .currentIndex,
      AppTab.home.index,
    );
  });
}
