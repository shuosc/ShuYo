import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/wecom_constants.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/data/services/wecom_auth_service.dart';
import 'package:shuyo/features/auth/native_login_page.dart';

/// 企微扫码登录 WebVPN 的产物：握手已在扫码页内完成，回调地址是落地页。
final _webVpnLandingResult = WeComRedeemResult(
  callbackUri: Uri.parse(WeComConstants.webVpnLanding),
  sessionCookies: const [],
);

void main() {
  test('WebVPN WeCom login skips the callback exchange', () {
    expect(
      weComEstablishedWebVpnSession(
        destination: NativeLoginDestination.webVpn,
        weComRedeem: _webVpnLandingResult,
      ),
      isTrue,
    );
    // 教务系统的企微流程只拿到授权码，仍须跟随回调兑换会话。
    expect(
      weComEstablishedWebVpnSession(
        destination: NativeLoginDestination.academic,
        weComRedeem: _webVpnLandingResult,
      ),
      isFalse,
    );
    // 账密登录不经过扫码页，始终需要兑换回调。
    expect(
      weComEstablishedWebVpnSession(
        destination: NativeLoginDestination.webVpn,
        weComRedeem: null,
      ),
      isFalse,
    );
  });

  testWidgets('campus login shows the WeCom login entry button',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: NativeLoginPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用企业微信登录'), findsOneWidget);
  });

  testWidgets('WebVPN login shows the WeCom login entry button',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: NativeLoginPage.webVpn(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用企业微信登录'), findsOneWidget);
  });

  testWidgets('booking login names the feature being authorized',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: NativeLoginPage.there()),
    );
    await tester.pumpAndSettle();
    expect(find.text('登录图书馆预约'), findsOneWidget);
    expect(find.text('使用企业微信登录'), findsOneWidget);
  });

  testWidgets('data deletion uses a separate school login without QR reuse',
      (tester) async {
    final identity = StudentIdentityService();
    addTearDown(identity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: NativeLoginPage.dataDeletion(studentIdentityService: identity),
    ));
    await tester.pumpAndSettle();
    expect(find.text('验证学校身份'), findsOneWidget);
    expect(find.text('重新登录上海大学账户，以确认本人操作'), findsOneWidget);
    expect(find.text('使用企业微信登录'), findsNothing);
  });

  for (final page in const [
    NativeLoginPage(),
    NativeLoginPage.webVpn(),
    NativeLoginPage.there(),
  ]) {
    testWidgets('${page.destination.name} shows hints without changing rows',
        (tester) async {
      await tester.pumpWidget(MaterialApp(home: page));
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      final continueButton = find.widgetWithText(FilledButton, '继续');
      final buttonBefore = tester.getRect(continueButton);
      final dividerBefore = tester.getRect(find.byType(Divider));
      final studentIdLabelColor =
          tester.widget<Text>(find.text('学/工号')).style?.color;
      final passwordLabelColor =
          tester.widget<Text>(find.text('密码')).style?.color;

      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(find.text('请输入学/工号'), findsOneWidget);
      expect(tester.getRect(find.byType(Divider)), dividerBefore);
      expect(tester.getRect(continueButton), buttonBefore);
      expect(tester.widget<Text>(find.text('学/工号')).style?.color,
          studentIdLabelColor);
      expect(tester.widget<Text>(find.text('密码')).style?.color,
          passwordLabelColor);

      await tester.enterText(fields.first, '123456');
      await tester.pumpAndSettle();
      expect(find.text('请输入学/工号'), findsNothing);
      expect(find.text('请输入密码'), findsOneWidget);
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      expect(tester.getRect(find.byType(Divider)), dividerBefore);
      expect(tester.getRect(continueButton), buttonBefore);

      await tester.enterText(fields.last, 'password');
      await tester.pumpAndSettle();
      expect(find.text('请输入密码'), findsNothing);
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      expect(tester.getRect(continueButton), buttonBefore);
    });
  }

  testWidgets('login hint fades in without moving the continue button',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NativeLoginPage()));
    await tester.pumpAndSettle();

    final continueButton = find.widgetWithText(FilledButton, '继续');
    final buttonBefore = tester.getRect(continueButton);
    await tester.tap(continueButton);
    await tester.pump();

    final hintFade = find.ancestor(
      of: find.text('请输入学/工号'),
      matching: find.byType(FadeTransition),
    );
    double hintOpacity() => tester
        .widgetList<FadeTransition>(hintFade)
        .map((fade) => fade.opacity.value)
        .reduce((current, next) => current < next ? current : next);
    expect(hintOpacity(), 0);

    await tester.pump(const Duration(milliseconds: 90));
    final midwayOpacity = hintOpacity();
    expect(midwayOpacity, greaterThan(0));
    expect(midwayOpacity, lessThan(1));
    expect(tester.getRect(continueButton), buttonBefore);

    await tester.pumpAndSettle();
    expect(hintOpacity(), 1);
    expect(tester.getRect(continueButton), buttonBefore);
  });

  testWidgets(
      'credential card keeps labels and reveals password action on focus',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: NativeLoginPage()));
    await tester.pumpAndSettle();

    final title = tester.getRect(find.text('上大校园账户'));
    final body = tester.getRect(find.byType(SingleChildScrollView));
    expect(title.top, lessThan(body.center.dy - 160));
    expect(find.text('学/工号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);

    final passwordAction = find.ancestor(
      of: find.byTooltip('显示密码'),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(passwordAction).opacity, 0);

    await tester.tap(find.byType(TextFormField).last);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(passwordAction).opacity, 1);

    await tester.enterText(find.byType(TextFormField).first, '123456');
    await tester.pumpAndSettle();
    expect(find.text('学/工号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(passwordAction).opacity, 0);

    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.text('上大校园账户'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WeCom login shows loading on its own button and recovers',
      (tester) async {
    final session = Completer<WeComQrSession>();
    var starts = 0;
    await tester.pumpWidget(MaterialApp(
      home: NativeLoginPage(startWeComSession: () {
        starts++;
        return session.future;
      }),
    ));
    await tester.pumpAndSettle();

    final continueButton = find.widgetWithText(FilledButton, '继续');
    final weComButton =
        find.byWidgetPredicate((widget) => widget is OutlinedButton);
    await tester.tap(find.text('使用企业微信登录'));
    await tester.pump();

    expect(find.text('继续'), findsOneWidget);
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(weComButton).onPressed, isNull);
    expect(
      find.descendant(
        of: weComButton,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: continueButton,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );

    await tester.tap(weComButton, warnIfMissed: false);
    await tester.tap(continueButton, warnIfMissed: false);
    await tester.pump();
    expect(starts, 1);

    session.completeError(const WeComAuthException('test', '登录失败'));
    await tester.pumpAndSettle();

    expect(find.text('登录失败'), findsOneWidget);
    expect(find.text('使用企业微信登录'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(weComButton).onPressed, isNotNull);
  });

  testWidgets('credential login loads its own button and restores after error',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final result = Completer<AcademicLoginResult>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: NativeLoginPage(loginForTesting: ({
        required username,
        required password,
      }) {
        calls++;
        return result.future;
      }),
    ));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, 'test-user');
    await tester.enterText(fields.last, 'test-password');
    final continueButton = find.byType(FilledButton);
    final weComButton = find.byType(OutlinedButton);
    await tester.tap(find.text('继续'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(weComButton).onPressed, isNull);
    expect(
        find.descendant(
            of: continueButton,
            matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(
        find.descendant(
            of: weComButton, matching: find.byType(CircularProgressIndicator)),
        findsNothing);
    await tester.tap(continueButton, warnIfMissed: false);
    await tester.tap(weComButton, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    result.completeError(const AcademicNativeAuthException('test', '登录失败'));
    await tester.pumpAndSettle();
    expect(find.text('登录失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(weComButton).onPressed, isNotNull);
  });

  testWidgets(
      'native verification loads the requested button and restores on errors',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final send = Completer<void>();
    final verify = Completer<Uri>();
    var sendCalls = 0;
    var verifyCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: NativeLoginPage(
        loginForTesting: ({required username, required password}) async =>
            const AcademicLoginResult(
          challenge: AcademicLoginChallenge(methods: {
            AcademicVerificationMethod.wecom: 'sample-user',
          }),
        ),
        sendCodeForTesting: (method) {
          expect(method, AcademicVerificationMethod.wecom);
          sendCalls++;
          return send.future;
        },
        verifyCodeForTesting: ({required method, required code}) {
          expect(method, AcademicVerificationMethod.wecom);
          expect(code, '123456');
          verifyCalls++;
          return verify.future;
        },
      ),
    ));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, 'sample-user');
    await tester.enterText(fields.last, 'sample-password');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();

    final sendButton = find.byType(TextButton);
    final verifyButton = find.byType(FilledButton);
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    expect(sendCalls, 1);
    expect(
        find.descendant(
            of: sendButton, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(
        find.descendant(
            of: verifyButton, matching: find.byType(CircularProgressIndicator)),
        findsNothing);
    expect(tester.widget<TextButton>(sendButton).onPressed, isNull);
    expect(tester.widget<FilledButton>(verifyButton).onPressed, isNull);
    await tester.tap(sendButton, warnIfMissed: false);
    await tester.tap(verifyButton, warnIfMissed: false);
    expect(sendCalls, 1);
    expect(verifyCalls, 0);
    send.completeError(const AcademicNativeAuthException('test', '发码失败'));
    await tester.pumpAndSettle();
    expect(find.text('发码失败'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.widget<TextButton>(sendButton).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(verifyButton).onPressed, isNotNull);

    await tester.enterText(find.byType(TextFormField), '123456');
    await tester.tap(find.text('完成验证'));
    await tester.pump();
    expect(verifyCalls, 1);
    expect(
        find.descendant(
            of: verifyButton, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(
        find.descendant(
            of: sendButton, matching: find.byType(CircularProgressIndicator)),
        findsNothing);
    expect(tester.widget<TextButton>(sendButton).onPressed, isNull);
    expect(tester.widget<FilledButton>(verifyButton).onPressed, isNull);
    await tester.tap(verifyButton, warnIfMissed: false);
    expect(verifyCalls, 1);
    verify.completeError(const AcademicNativeAuthException('test', '验证失败'));
    await tester.pumpAndSettle();
    expect(find.text('验证失败'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<TextButton>(sendButton).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(verifyButton).onPressed, isNotNull);
  });
}
