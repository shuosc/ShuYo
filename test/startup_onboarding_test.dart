import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/client_backend.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';
import 'package:shuyo/features/auth/native_login_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget app({
    required bool completed,
    bool academicLoggedIn = false,
    ForumAccountStatus forumStatus = ForumAccountStatus.signedOut,
    StartupOnboardingController? controller,
    Future<bool> Function()? onAcademicLogout,
    Future<bool> Function()? onForumLogout,
    Future<bool?> Function()? notificationPermissionRequester,
  }) {
    return MaterialApp(
      home: StartupOnboarding(
        initiallyCompleted: completed,
        initialAcademicLoggedIn: academicLoggedIn,
        initialForumStatus: forumStatus,
        onAcademicLoginCompleted: () {},
        onForumLoginCompleted: () {},
        onAcademicLogout: onAcademicLogout,
        onForumLogout: onForumLogout,
        notificationPermissionRequester: notificationPermissionRequester,
        controller: controller ?? StartupOnboardingController(),
        child: const Scaffold(body: Text('主页')),
      ),
    );
  }

  testWidgets('shows onboarding while logged out', (tester) async {
    await tester.pumpWidget(app(completed: false));

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('欢迎使用ShuYo'), findsOneWidget);
    final panel = find.byKey(const ValueKey('startup-onboarding-panel'));
    final initialTop = tester.getTopLeft(panel).dy;

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final middleTop = tester.getTopLeft(panel).dy;
    await tester.pumpAndSettle();
    final finalTop = tester.getTopLeft(panel).dy;

    expect(middleTop, lessThan(initialTop));
    expect(finalTop, lessThan(middleTop));
    expect(find.textContaining('继续即表示您已同意'), findsOneWidget);
    final termsTop = tester.getTopLeft(find.textContaining('继续即表示您已同意')).dy;
    final continueTop = tester.getTopLeft(find.text('继续')).dy;
    expect(termsTop, lessThan(continueTop));
    expect(
      tester.getSize(find.byType(Image).first).width,
      greaterThan(tester.getSize(find.byIcon(Icons.calendar_month)).width),
    );
  });

  testWidgets('does not dismiss first-run onboarding from the barrier',
      (tester) async {
    await tester.pumpWidget(app(completed: false));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(16, 16));
    await tester.pumpAndSettle();

    expect(find.text('欢迎使用ShuYo'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'client.onboarding.startup.completed',
      ),
      isFalse,
    );
  });

  testWidgets('does not dismiss first-run onboarding by dragging the handle',
      (tester) async {
    await tester.pumpWidget(app(completed: false));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('startup-onboarding-drag-handle')),
      const Offset(0, 180),
    );
    await tester.pumpAndSettle();

    expect(find.text('欢迎使用ShuYo'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
  });

  testWidgets('skips onboarding after it has been completed', (tester) async {
    await tester.pumpWidget(app(completed: true));

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('欢迎使用ShuYo'), findsNothing);
  });

  testWidgets('first-run account page only exposes the academic account',
      (tester) async {
    await tester.pumpWidget(app(completed: false, academicLoggedIn: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(find.text('上大校园账户'), findsOneWidget);
    expect(find.text('乐乎账户'), findsNothing);
    expect(find.text('使用WebVPN连接'), findsNothing);
    expect(find.text('跳过'), findsNothing);
  });

  testWidgets('blocks direct forum login with certificate notice',
      (tester) async {
    final controller = StartupOnboardingController();
    await tester.pumpWidget(app(
      completed: true,
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.directLoginUnavailable,
      controller: controller,
    ));
    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.directLoginUnavailable,
    );
    await tester.pumpAndSettle();

    expect(find.text('暂不可登录'), findsOneWidget);
    await tester.tap(find.text('乐乎账户'));
    await tester.pumpAndSettle();
    expect(
      find.text('iOS暂时仅支持开启webvpn访问'),
      findsOneWidget,
    );
    expect(find.byType(NativeLoginPage), findsNothing);
  });

  testWidgets('second and third pages can return to the previous page',
      (tester) async {
    await tester.pumpWidget(app(completed: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('开启通知权限'), findsOneWidget);
    expect(find.byTooltip('返回上一页'), findsOneWidget);

    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用ShuYo'), findsOneWidget);

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('账号管理'), findsOneWidget);

    await tester.tap(find.byTooltip('返回上一页'));
    await tester.pumpAndSettle();
    expect(find.text('开启通知权限'), findsOneWidget);
  });

  testWidgets('requests notification permission when continuing page two',
      (tester) async {
    var requestCount = 0;
    await tester.pumpWidget(
      app(
        completed: false,
        notificationPermissionRequester: () async {
          requestCount++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(requestCount, 0);

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(requestCount, 1);
    expect(find.text('账号管理'), findsOneWidget);
  });

  testWidgets('shows permission denial above the onboarding panel',
      (tester) async {
    await tester.pumpWidget(
      app(
        completed: false,
        notificationPermissionRequester: () async => false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    expect(find.text('通知权限未开启，可稍后在系统设置中开启'), findsOneWidget);
  });

  testWidgets('reopens completed onboarding on the account page',
      (tester) async {
    final controller = StartupOnboardingController();
    await tester.pumpWidget(
      app(
        completed: true,
        academicLoggedIn: true,
        forumStatus: ForumAccountStatus.loggedIn,
        controller: controller,
      ),
    );

    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.loggedIn,
    );
    await tester.pumpAndSettle();

    expect(find.text('账号管理'), findsOneWidget);
    expect(find.text('已登录'), findsNWidgets(2));
    expect(find.text('完成'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
  });

  testWidgets('account manager shows persistent WebVPN controls and status',
      (tester) async {
    final controller = StartupOnboardingController();
    await tester.pumpWidget(app(
      completed: true,
      academicLoggedIn: true,
      controller: controller,
    ));
    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.signedOut,
      webVpnEnabled: true,
      webVpnServiceStatus: WebVpnServiceStatus(
        state: WebVpnServiceState.available,
        checkedAt: DateTime.now(),
        statusSince: null,
        lastSuccessAt: null,
        latencyMs: 20,
        reason: 'ok',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('使用WebVPN连接'), findsOneWidget);
    await tester.ensureVisible(find.text('使用WebVPN连接'));
    await tester.tap(find.text('使用WebVPN连接'));
    await tester.pumpAndSettle();
    expect(find.text('当前WebVPN服务可用'), findsOneWidget);
    expect(find.textContaining('最近检查：'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('关闭后需重新登录论坛账户'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('enabling WebVPN confirms when the direct forum is logged in',
      (tester) async {
    final controller = StartupOnboardingController();
    var changeRequested = false;
    controller.setWebVpnChangeHandler((enabled) async {
      changeRequested = true;
      return true;
    });
    await tester.pumpWidget(app(
      completed: true,
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.loggedIn,
      controller: controller,
    ));
    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.loggedIn,
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('使用WebVPN连接'));
    await tester.tap(find.text('使用WebVPN连接'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('开启WebVPN连接'), findsOneWidget);
    expect(find.text('开启后需要重新登录论坛账户'), findsOneWidget);
    expect(changeRequested, isFalse);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(changeRequested, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await tester.pumpAndSettle();
    expect(changeRequested, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('keeps forum account status synchronized while manager is open',
      (tester) async {
    final controller = StartupOnboardingController();
    var reconnectTapped = false;
    await tester.pumpWidget(
      app(
        completed: true,
        academicLoggedIn: true,
        forumStatus: ForumAccountStatus.connectionUnavailable,
        controller: controller,
      ),
    );

    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.connectionUnavailable,
    );
    controller.setForumReconnectHandler(() => reconnectTapped = true);
    await tester.pumpAndSettle();

    expect(find.text('连接异常'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    await tester.tap(find.text('乐乎账户'));
    expect(reconnectTapped, isTrue);

    controller.updateAccountStatus(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.connecting,
    );
    await tester.pump();
    expect(find.text('正在连接'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.updateAccountStatus(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.reauthenticationRequired,
    );
    await tester.pump();
    expect(find.text('登录已失效'), findsOneWidget);

    controller.updateAccountStatus(
      academicLoggedIn: false,
      forumStatus: ForumAccountStatus.waitingForAcademicLogin,
    );
    await tester.pump();
    expect(find.text('等待校园账户登录'), findsOneWidget);
    expect(find.text('已登录'), findsNothing);

    controller.updateAccountStatus(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.loggedIn,
    );
    await tester.pump();
    expect(find.text('已登录'), findsNWidgets(2));
    expect(find.text('账号管理'), findsOneWidget);
  });

  testWidgets('logged-in accounts can be logged out from account management',
      (tester) async {
    final controller = StartupOnboardingController();
    var academicLoggedOut = false;
    var forumLoggedOut = false;
    await tester.pumpWidget(
      app(
        completed: true,
        academicLoggedIn: true,
        forumStatus: ForumAccountStatus.loggedIn,
        controller: controller,
        onAcademicLogout: () async {
          academicLoggedOut = true;
          return true;
        },
        onForumLogout: () async {
          forumLoggedOut = true;
          return true;
        },
      ),
    );

    controller.openAccountManager(
      academicLoggedIn: true,
      forumStatus: ForumAccountStatus.loggedIn,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('上大校园账户'));
    await tester.pumpAndSettle();
    expect(find.text('退出上大校园账户？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(academicLoggedOut, isTrue);
    expect(forumLoggedOut, isFalse);
    expect(find.text('已退出上大校园账户'), findsOneWidget);

    await tester.tap(find.text('乐乎账户'));
    await tester.pumpAndSettle();
    expect(find.text('退出乐乎论坛账户？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(forumLoggedOut, isTrue);
    expect(find.text('已退出乐乎论坛账户'), findsOneWidget);
  });

  testWidgets('defers account notifications triggered during a widget update',
      (tester) async {
    final controller = StartupOnboardingController();

    Widget buildApp(int signal) => MaterialApp(
          home: StartupOnboarding(
            initiallyCompleted: true,
            initialAcademicLoggedIn: false,
            initialForumStatus: ForumAccountStatus.signedOut,
            onAcademicLoginCompleted: () {},
            onForumLoginCompleted: () {},
            controller: controller,
            child: _ControllerUpdateProbe(
              controller: controller,
              signal: signal,
            ),
          ),
        );

    await tester.pumpWidget(buildApp(0));
    await tester.pumpWidget(buildApp(1));
    await tester.pumpAndSettle();

    expect(controller.academicLoggedIn, isTrue);
    expect(controller.forumStatus, ForumAccountStatus.loggedIn);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps onboarding content top-aligned on an iPhone 17 viewport',
      (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(completed: false));
    await tester.pumpAndSettle();

    final titleBottom = tester.getBottomLeft(find.text('欢迎使用ShuYo')).dy;
    final firstItemTop = tester.getTopLeft(find.text('课表与空教室')).dy;
    final secondItemTop = tester.getTopLeft(find.text('乐乎论坛')).dy;
    expect(
      tester.getTopLeft(find.byIcon(Icons.calendar_month)).dx,
      greaterThanOrEqualTo(56),
    );
    final pages = find.byKey(const ValueKey('startup-onboarding-pages'));
    final initialPagesSize = tester.getSize(pages);
    final terms = find.textContaining('继续即表示您已同意');
    expect(find.ancestor(of: terms, matching: pages), findsOneWidget);
    expect(firstItemTop - titleBottom, lessThan(60));
    expect(secondItemTop - firstItemTop, greaterThanOrEqualTo(76));

    final panelTopBefore = tester
        .getTopLeft(find.byKey(const ValueKey('startup-onboarding-panel')))
        .dy;
    await tester.tap(find.text('继续'));
    await tester.pump(const Duration(milliseconds: 160));
    final panelTopDuring = tester
        .getTopLeft(find.byKey(const ValueKey('startup-onboarding-panel')))
        .dy;
    expect(panelTopDuring, panelTopBefore);
    await tester.pumpAndSettle();
    expect(terms.hitTestable(), findsNothing);
    expect(tester.getSize(pages), initialPagesSize);
    expect(find.byIcon(Icons.notifications_active_outlined), findsNothing);
    final notificationCopy = tester.widget<Text>(
      find.textContaining('ShuYo 会发送上课提醒，请在下一步中授予'),
    );
    expect(notificationCopy.textAlign, TextAlign.center);
    expect(notificationCopy.style?.fontSize, 16);

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(tester.getSize(pages), initialPagesSize);
    expect(
      tester.getTopLeft(find.byIcon(Icons.school_outlined)).dx,
      greaterThanOrEqualTo(40),
    );
    expect(tester.takeException(), isNull);
  });
}

class _ControllerUpdateProbe extends StatefulWidget {
  const _ControllerUpdateProbe({
    required this.controller,
    required this.signal,
  });

  final StartupOnboardingController controller;
  final int signal;

  @override
  State<_ControllerUpdateProbe> createState() => _ControllerUpdateProbeState();
}

class _ControllerUpdateProbeState extends State<_ControllerUpdateProbe> {
  @override
  void didUpdateWidget(covariant _ControllerUpdateProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.signal != oldWidget.signal) {
      widget.controller.updateAccountStatus(
        academicLoggedIn: true,
        forumStatus: ForumAccountStatus.loggedIn,
      );
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('主页'));
}
