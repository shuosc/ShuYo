import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/data/models/home_layout.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/features/home/home_layout_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpShell(WidgetTester tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: ShuYoThemes.defaultId,
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
  }

  testWidgets(
      'settings retains access to the persisted layout without a footer',
      (tester) async {
    final service = ClientSettingsService();
    final normal = HomeLayout.defaults().setEnabled(HomeModule.otp, false);
    await service.saveHomeLayout(normal);
    await pumpShell(tester);
    expect(find.text('自定义首页'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('首页布局'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeLayoutPage), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('module:campus_card')),
      matching: find.byType(Checkbox),
    ));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('你好，小明！'), findsOneWidget);
    expect(find.text('校园卡'), findsNothing);
    expect((await service.loadHomeLayout()).toJson(), normal.toJson());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpShell(tester);
    expect(find.text('校园卡'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('首页布局'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeLayoutPage), findsOneWidget);
    final checkbox = find.descendant(
      of: find.byKey(const ValueKey('module:campus_card')),
      matching: find.byType(Checkbox),
    );
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('校园卡'), -180);
    expect(find.text('校园卡'), findsOneWidget);
  });
}
