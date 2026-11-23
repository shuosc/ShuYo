import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/data/demo/demo_session.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/auth/native_login_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';
import 'package:shuyo/shared/widgets/webvpn_toggle.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('account manager distinguishes expiration and restored login',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(
      academicLoggedIn: false,
      academicSessionExpired: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('已登录'), findsNothing);
    controller.updateAccountStatus(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsNothing);
    expect(find.text('已登录'), findsOneWidget);
  });

  testWidgets('account manager keeps campus account and WebVPN controls',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(
      academicLoggedIn: true,
      webVpnEnabled: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('本科生系统'), findsOneWidget);
    expect(find.text('使用WebVPN连接'), findsOneWidget);
    expect(find.textContaining('乐乎'), findsNothing);
  });

  testWidgets('account manager edits nickname and preferred campus',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    controller.updateProfile(
      studentId: '25120000',
      nickname: null,
      preferredCampus: '宝山',
    );
    controller.setProfileChangeHandlers(
      onNicknameChanged: (value) async {
        final nickname = value?.trim();
        controller.updateProfile(
          studentId: '25120000',
          nickname: nickname?.isEmpty == true ? null : nickname,
          preferredCampus: controller.preferredCampus,
        );
        return true;
      },
      onCampusChanged: (campus) async {
        controller.updateProfile(
          studentId: '25120000',
          nickname: controller.nickname,
          preferredCampus: campus,
        );
        return true;
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('25120000'), findsOneWidget);
    expect(find.text('校区：宝山'), findsOneWidget);
    final nicknameRect = tester.getRect(find.byKey(const Key('nickname-edit')));
    final campusRect = tester.getRect(find.byKey(const Key('campus-select')));
    expect(campusRect.left - nicknameRect.right, closeTo(16, 1));
    expect((nicknameRect.left + campusRect.right) / 2, closeTo(400, 1));

    await tester.tap(find.byKey(const Key('nickname-edit')));
    await tester.pumpAndSettle();
    expect(find.text('留空将恢复显示学号'), findsNothing);
    await tester.enterText(find.byType(TextFormField), ' 小明 ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.nickname, '小明');
    expect(controller.academicStudentId, '25120000');
    expect(find.text('小明'), findsOneWidget);

    await tester.tap(find.byKey(const Key('campus-select')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    final campusItem = find.widgetWithText(PopupMenuItem<String>, '嘉定');
    expect(tester.getTopLeft(campusItem).dy,
        greaterThanOrEqualTo(campusRect.bottom));
    await tester.tap(campusItem);
    await tester.pumpAndSettle();
    expect(controller.preferredCampus, '嘉定');
    expect(find.text('校区：嘉定'), findsOneWidget);
  });

  testWidgets('nickname and campus stay on one row on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    controller.updateProfile(
      studentId: '25120000',
      nickname: '一个比较长的昵称用于测试窄屏布局',
      preferredCampus: '宝山东区',
    );
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();

    final nicknameRect = tester.getRect(find.byKey(const Key('nickname-edit')));
    final campusRect = tester.getRect(find.byKey(const Key('campus-select')));
    expect(nicknameRect.right, lessThan(campusRect.left));
    expect(nicknameRect.center.dy, closeTo(campusRect.center.dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending WebVPN can be retried while its switch is already on',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    var recoveryRequests = 0;
    controller.setWebVpnChangeHandler((enabled) async {
      if (enabled) recoveryRequests++;
      return true;
    });
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(
      academicLoggedIn: true,
      webVpnEnabled: true,
      webVpnPendingRecovery: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用WebVPN连接 · 登录待恢复'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('使用WebVPN连接 · 登录待恢复'), const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复WebVPN登录'));
    await tester.pumpAndSettle();
    expect(recoveryRequests, 1);
  });

  testWidgets('account manager shows WebVPN progress below the switch',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    final pending = Completer<bool>();
    controller.setWebVpnChangeHandler((_) => pending.future);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用WebVPN连接'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('使用WebVPN连接'), const Offset(0, -240));
    await tester.pumpAndSettle();
    final description = find.text('启用后，可使用外部网络访问校内服务');
    final descriptionWidth = tester.getSize(description).width;
    final serviceStatus = find.text('暂时无法获取WebVPN服务状态');
    final statusTop = tester.getTopLeft(serviceStatus).dy;

    await tester.tap(find.descendant(
      of: find.byType(WebVpnToggle),
      matching: find.byType(Switch),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(
        of: find.byType(WebVpnToggle),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.descendant(
            of: find.byType(WebVpnToggle),
            matching: find.byType(CircularProgressIndicator),
          ))
          .dy,
      greaterThan(tester.getBottomLeft(find.byType(Switch)).dy),
    );
    expect(tester.getTopLeft(serviceStatus).dy, statusTop);
    expect(
      tester
          .getBottomLeft(find.descendant(
            of: find.byType(WebVpnToggle),
            matching: find.byType(CircularProgressIndicator),
          ))
          .dy,
      lessThan(statusTop),
    );
    expect(tester.getSize(description).width, descriptionWidth);

    pending.complete(false);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(serviceStatus).dy, statusTop);
  });

  testWidgets('first launch introduces campus features', (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: false,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用ShuYo'), findsOneWidget);
    expect(find.textContaining('乐乎'), findsNothing);
  });

  testWidgets('first run selects a system before offering ShuYo verification',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: false,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        notificationPermissionRequester: () async => false,
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    await tester.pumpAndSettle();
    final welcomeButton =
        tester.getRect(find.widgetWithText(FilledButton, '继续'));
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('开启通知权限'), findsOneWidget);
    final notificationButton =
        tester.getRect(find.widgetWithText(FilledButton, '继续'));
    expect(notificationButton, welcomeButton);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('账号管理'), findsOneWidget);
    expect(find.text('请选择你的身份'), findsOneWidget);
    expect(find.text('ShuYo 认证'), findsNothing);
    for (final system in CampusSystem.values) {
      final style = tester.widget<Text>(find.text(system.label)).style;
      expect(style?.fontSize, 16);
      expect(style?.fontWeight, FontWeight.w600);
    }
    await tester.tap(find.text('本科生系统'));
    await tester.pumpAndSettle();
    final login = find.byType(NativeLoginPage);
    expect(tester.widget<NativeLoginPage>(login).destination,
        NativeLoginDestination.academic);
    expect(find.text('本科生系统'), findsOneWidget);
    Navigator.of(tester.element(login)).pop(NativeLoginResult.authenticated);
    await tester.pumpAndSettle();
    expect(find.text('ShuYo 认证'), findsOneWidget);
    final identityButton =
        tester.getRect(find.widgetWithText(FilledButton, '确认'));
    expect(identityButton, welcomeButton);
    expect(
      find.text('ShuYo 服务器会临时使用你当前校园系统的会话向学校核实学号。认证后可使用问题反馈等功能。'),
      findsOneWidget,
    );
    expect(tester.getTopLeft(find.text('暂不')).dy,
        lessThan(tester.getTopLeft(find.text('确认')).dy));
    expect(
      tester.getTopLeft(find.widgetWithText(FilledButton, '确认')).dy -
          tester.getBottomLeft(find.widgetWithText(TextButton, '暂不')).dy,
      closeTo(14, 1),
    );
    expect(find.text('隐私政策'), findsNothing);
    expect(find.textContaining('点击即同意'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('暂不'));
    await tester.pumpAndSettle();
    expect(await identity.hasAnsweredConsent(), isTrue);
    expect(await identity.hasConsent(), isFalse);
    expect(find.text('账号管理'), findsNothing);
    expect(
        await ClientSettingsService().loadStartupOnboardingCompleted(), isTrue);
  });

  testWidgets('graduate first run offers the same optional ShuYo verification',
      (tester) async {
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    CampusSystem? completedSystem;
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: false,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (system) => completedSystem = system,
        notificationPermissionRequester: () async => true,
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    await tester.pumpAndSettle();
    for (var index = 0; index < 2; index++) {
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();
    final login = find.byType(NativeLoginPage);
    expect(tester.widget<NativeLoginPage>(login).destination,
        NativeLoginDestination.graduate);
    expect(find.text('研究生系统'), findsOneWidget);
    expect(find.text('使用上海大学统一认证账户来访问各类校园服务'), findsOneWidget);
    expect(find.text('使用企业微信登录'), findsOneWidget);
    Navigator.of(tester.element(login)).pop(NativeLoginResult.authenticated);
    await tester.pumpAndSettle();
    expect(completedSystem, CampusSystem.graduate);
    expect(find.text('ShuYo 认证'), findsOneWidget);
    expect(await identity.hasAnsweredConsent(), isFalse);
    await tester.tap(find.text('暂不'));
    await tester.pumpAndSettle();
    expect(await identity.hasAnsweredConsent(), isTrue);
    expect(await identity.hasConsent(), isFalse);
    expect(
        await ClientSettingsService().loadStartupOnboardingCompleted(), isTrue);
  });

  testWidgets('graduate system selection accepts the offline demo credentials',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    CampusSystem? completedSystem;
    var demoLogins = 0;
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: false,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (system) => completedSystem = system,
        onDemoLogin: () async {
          demoLogins++;
        },
        notificationPermissionRequester: () async => false,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    await tester.pumpAndSettle();
    for (var index = 0; index < 2; index++) {
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    final submit = find.widgetWithText(FilledButton, '继续');
    await tester.enterText(fields.first, DemoSession.username);
    await tester.enterText(fields.last, 'wrong');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('演示账号密码不正确'), findsOneWidget);
    expect(demoLogins, 0);

    await tester.enterText(fields.last, DemoSession.password);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(demoLogins, 1);
    expect(completedSystem, isNull);
    expect(find.byType(NativeLoginPage), findsNothing);
  });

  testWidgets('graduate logout allows demo login from the same account page',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    controller.setAccountLogoutHandlers(onAcademicLogout: () async {
      controller.updateAccountStatus(academicLoggedIn: false);
      return true;
    });
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        campusSystem: CampusSystem.graduate,
        onAcademicLoginCompleted: (_) => fail('Unexpected campus login'),
        onDemoLogin: DemoSession.enable,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('已登录'), findsOneWidget);

    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();
    expect(find.text('确认退出'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);

    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, DemoSession.username);
    await tester.enterText(fields.last, DemoSession.password);
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await tester.pumpAndSettle();
    expect(await DemoSession.isEnabled(), isTrue);
    expect(controller.accountManagerOpen, isFalse);
    expect(find.byType(NativeLoginPage), findsNothing);
  });

  testWidgets('graduate session recovery does not accept the demo credentials',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: false,
        campusSystem: CampusSystem.graduate,
        onAcademicLoginCompleted: (_) => fail('Unexpected campus login'),
        onDemoLogin: () async => fail('Unexpected demo login'),
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(
      academicLoggedIn: false,
      academicSessionExpired: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, DemoSession.username);
    await tester.enterText(fields.last, DemoSession.password);
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await tester.pumpAndSettle();
    expect(find.text('请使用校园账户登录'), findsOneWidget);
    expect(find.byType(NativeLoginPage), findsOneWidget);
  });

  testWidgets('switching keeps the previous system until login succeeds',
      (tester) async {
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await identity.declineConsent();
    var current = CampusSystem.undergraduate;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (_, setState) {
        return StartupOnboarding(
          initiallyCompleted: true,
          initialAcademicLoggedIn: true,
          campusSystem: current,
          onAcademicLoginCompleted: (system) =>
              setState(() => current = system),
          studentIdentityService: identity,
          controller: controller,
          child: const Scaffold(body: Text('主页')),
        );
      }),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('本科生系统'), findsOneWidget);
    await tester.tap(find.text('切换登录系统'));
    await tester.pumpAndSettle();
    expect(find.text('请选择你的身份'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();
    final login = find.byType(NativeLoginPage);
    Navigator.of(tester.element(login)).pop();
    await tester.pumpAndSettle();
    expect(current, CampusSystem.undergraduate);
    await tester.tap(find.text('研究生系统'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(login)).pop(NativeLoginResult.authenticated);
    await tester.pumpAndSettle();
    expect(current, CampusSystem.graduate);
    expect(find.text('研究生系统'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    expect(find.text('未认证'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('student-identity-status')), findsOneWidget);
    expect(find.text('切换登录系统'), findsOneWidget);
  });

  testWidgets('existing users get the same identity choice once',
      (tester) async {
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: true,
        onAcademicLoginCompleted: (_) {},
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('ShuYo 认证'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(await identity.hasConsent(), isTrue);
    expect(find.text('未认证'), findsOneWidget);
    expect(tester.widget<Text>(find.text('未认证')).style?.color, Colors.black);
    final status = find.byKey(const ValueKey('student-identity-status'));
    expect(status, findsOneWidget);
    expect(
      find.descendant(of: status, matching: find.byIcon(Icons.cancel)),
      findsOneWidget,
    );
    expect(tester.getTopLeft(status).dy,
        greaterThan(tester.getBottomLeft(find.text('账号管理')).dy));
    expect(tester.getCenter(status).dx, closeTo(400, 1));
    controller.dismissAccountManager();
    await tester.pumpAndSettle();
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    expect(find.text('ShuYo 认证'), findsNothing);
  });

  testWidgets('account manager back button returns to earlier pages',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'shuyo.student.identity.choice.v1': true,
    });
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: false);
    await tester.pumpAndSettle();
    expect(find.text('账号管理'), findsOneWidget);
    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.text('开启通知权限'), findsOneWidget);
    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用ShuYo'), findsOneWidget);
    expect(find.byTooltip('返回上一页'), findsNothing);
  });

  testWidgets('declining once leaves an account-manager retry entry',
      (tester) async {
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不'));
    await tester.pumpAndSettle();
    expect(await identity.hasConsent(), isFalse);
    controller.dismissAccountManager();
    await tester.pumpAndSettle();
    controller.openAccountManager(academicLoggedIn: false);
    await tester.pumpAndSettle();
    expect(find.text('未认证'), findsOneWidget);
    await tester.tap(find.text('未认证'));
    await tester.pumpAndSettle();
    expect(find.text('认证状态'), findsOneWidget);
    await tester.tap(find.text('尝试认证'));
    await tester.pumpAndSettle();
    expect(find.text('身份验证'), findsOneWidget);
    expect(await identity.hasConsent(), isFalse);
    await tester.tap(find.text('暂不'));
    await tester.pumpAndSettle();
    expect(await identity.hasConsent(), isFalse);
  });

  testWidgets('verified status uses the theme color below the title',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.lastStudentIdKey: '23123456',
      'shuyo.student.identity.consent.v1': true,
      'shuyo.student.session.v1': jsonEncode({
        'token': 'a' * 43,
        'studentId': '23123456',
        'maskedStudentId': '23****56',
        'expiresAt': '2099-01-01T00:00:00Z',
      }),
    });
    final controller = StartupOnboardingController();
    final identity = StudentIdentityService();
    addTearDown(controller.dispose);
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: true,
        initialAcademicLoggedIn: false,
        onAcademicLoginCompleted: (_) {},
        studentIdentityService: identity,
        controller: controller,
        child: const Scaffold(body: Text('主页')),
      ),
    ));
    controller.openAccountManager(academicLoggedIn: false);
    await tester.pumpAndSettle();
    expect(find.text('已认证'), findsOneWidget);
    final status = find.byKey(const ValueKey('student-identity-status'));
    expect(tester.getTopLeft(status).dy,
        greaterThan(tester.getBottomLeft(find.text('账号管理')).dy));
    expect(
      tester.widget<Text>(find.text('已认证')).style?.color,
      Theme.of(tester.element(status)).colorScheme.primary,
    );
    expect(
      find.descendant(of: status, matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
  });
}
