import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/demo/demo_data_bundle.dart';
import 'package:shuyo/data/services/academic_profile_preferences.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/features/home/academic_progress_page.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/home/shuyo_content_page.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

import '../support/academic_schedule_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('demo campus card refreshes and opens offline history',
      (tester) async {
    final demo = await tester.runAsync(DemoDataBundle.load);
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
        isDemo: true,
        demoData: demo!,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('刷新校园卡余额'));
    await tester.tap(find.byTooltip('刷新校园卡余额'));
    await tester.pumpAndSettle();
    expect(find.text('当前余额：¥87.60'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('校园卡'));
    await tester.pumpAndSettle();
    expect(find.text('¥ 87.60'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('campus-card-chart-plot')), findsOneWidget);
    expect(find.byKey(const ValueKey('campus-card-recharge')), findsNothing);

    final historyButton = find.byKey(const ValueKey('campus-card-history'));
    await tester.scrollUntilVisible(
      historyButton,
      160,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('campus-card-scroll-view')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(historyButton);
    await tester.pumpAndSettle();
    expect(find.text('历史消费'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('campus-card-history-tab-credit')));
    await tester.pumpAndSettle();
    expect(find.text('校园卡充值'), findsOneWidget);
    expect(find.text('+ ¥35.00'), findsOneWidget);
    expect(find.text('宝山校区第一食堂'), findsNothing);
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
    final demo = (await tester.runAsync(DemoDataBundle.load))!;
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
        initialAcademicStudentId: demo.schedule.term.studentId,
        initialNickname: demo.schedule.term.studentName,
        onboardingController: controller,
        isDemo: true,
        demoData: demo,
      ),
    ));
    await tester.pumpAndSettle();
    final navigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(navigation.items.map((item) => item.label).toList(),
        ['首页', '课评', '学业', '日程']);
    expect(find.text('你好，演示同学！'), findsOneWidget);
    expect(find.textContaining('08:00 · 面向对象程序设计'), findsOneWidget);
    await tester.tap(find.text('9月1日课程'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        AppTab.schedule.index);
    expect(find.byType(AcademicSchedulePage), findsOneWidget);
    expect(find.text(demo.schedule.term.displayName), findsOneWidget);
    expect(find.byTooltip('课表信息说明'), findsOneWidget);
    expect(find.byTooltip('分享与导入'), findsNothing);
    expect(scheduleMoreButton, findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.byTooltip('通知'), findsNothing);

    await tester.tap(find.byTooltip('设置开学日期'));
    await tester.pumpAndSettle();
    expect(find.text('选择开学日期'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await openScheduleMenu(tester);
    expect(find.text('通知设置'), findsNothing);
    await tester.tap(scheduleRefreshAction);
    await tester.pumpAndSettle();
    await tester.tap(scheduleRefreshConfirmButton);
    await tester.pumpAndSettle();

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
        expect(find.text('平均绩点'), findsOneWidget);
        expect(find.text('学院排名'), findsOneWidget);
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
    expect(await ClientSettingsService().loadStartupTab(isDemo: true),
        AppTab.progress);
    expect(await ClientSettingsService().loadStartupTab(), AppTab.home);

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
