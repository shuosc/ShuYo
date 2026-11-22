import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/shuyo_app.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/app_data_migration_service.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';

void main() {
  testWidgets('stored graduate system limits phone, tablet, and startup tabs',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'ShuYo',
      packageName: 'work.shuyo.app',
      version: '0.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({
      AppDataMigrationService.schemaVersionKey:
          AppDataMigrationService.currentSchemaVersion,
    });
    SessionCookieJar.shared.resetForTesting();
    addTearDown(SessionCookieJar.shared.resetForTesting);
    await ClientSettingsService().saveStartupOnboardingCompleted(true);
    await ClientSettingsService().saveStartupTab(AppTab.rate);
    await AcademicAccountStore().saveSystem(CampusSystem.graduate);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const ShuYoApp());
    await tester.pumpAndSettle();
    expect(find.text('启动失败'), findsNothing);
    final bottomBar = find.byType(BottomNavigationBar);
    final phone = tester.widget<BottomNavigationBar>(bottomBar);
    expect(phone.items.map((item) => item.label), ['首页', '日程']);
    expect(phone.currentIndex, 0);
    expect(find.text('点击同步研究生课表'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启动显示'));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('日程'), findsOneWidget);
    expect(find.text('学业'), findsNothing);
    expect(find.text('课评'), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: bottomBar, matching: find.text('日程')));
    await tester.pumpAndSettle();
    expect(find.byType(AcademicSchedulePage), findsOneWidget);
    expect(find.text('同步课表'), findsOneWidget);
    expect(find.text('选择学期'), findsOneWidget);

    tester.view.physicalSize = const Size(820, 1100);
    await tester.pumpAndSettle();
    final tablet = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(tablet.destinations.map((item) => (item.label as Text).data),
        ['首页', '日程']);
    expect(tablet.selectedIndex, 1);
  });
}
