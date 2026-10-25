import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/features/home/campus_card_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _rechargeEntry = 'https://pay.shu.edu.cn/epay/home/IndexLoginWXCorp';
const _urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openPage(
    WidgetTester tester, {
    Future<bool> Function()? onLogin,
  }) async {
    tester.view.physicalSize = const Size(440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: CampusCardPage(onLogin: onLogin ?? () async => false),
    ));
    await tester.pumpAndSettle();
  }

  void mockLauncher(
    WidgetTester tester,
    Future<Object?> Function(MethodCall) handler,
  ) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncher, handler);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_urlLauncher, null));
  }

  testWidgets('recharge opens the campus app even when card queries need login',
      (tester) async {
    final launched = <MethodCall>[];
    var loginCount = 0;
    mockLauncher(tester, (call) async {
      launched.add(call);
      return true;
    });
    await openPage(tester, onLogin: () async {
      loginCount++;
      return false;
    });

    expect(find.text('校园卡查询需要重新验证校园账户'), findsWidgets);
    expect(find.text('打开校园一卡通后，点击「账户充值」。'), findsOneWidget);
    await tester.tap(find.text('前往企业微信充值'));
    await tester.pumpAndSettle();

    expect(loginCount, 0);
    expect(launched, hasLength(1));
    expect(launched.single.method, 'launch');
    final arguments = launched.single.arguments as Map<Object?, Object?>;
    final outer = Uri.parse(arguments['url']! as String);
    expect(outer.scheme, 'wxwork');
    expect(outer.host, 'jump');
    expect(outer.path, isEmpty);
    expect(outer.queryParameters, {
      'target': 'jump_to_third_app',
      'businessid': '5629500339709576',
    });
    expect(outer.userInfo, isEmpty);
    expect(arguments['useWebView'], isFalse);
    expect(arguments['useSafariVC'], isFalse);
  });

  for (final throwsOnLaunch in [false, true]) {
    testWidgets(
        'failed launch ${throwsOnLaunch ? 'exception' : 'result'} offers copying the stable entry',
        (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>;
            copied.add(arguments['text']! as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      mockLauncher(tester, (call) async {
        if (throwsOnLaunch) {
          throw PlatformException(code: 'no_handler');
        }
        return false;
      });
      await openPage(tester);

      await tester.tap(find.text('前往企业微信充值'));
      await tester.pumpAndSettle();

      expect(find.text('无法打开企业微信，请确认已安装企业微信'), findsOneWidget);
      expect(copied, isEmpty);
      await tester.tap(find.text('复制入口'));
      await tester.pumpAndSettle();

      expect(copied, [_rechargeEntry]);
      expect(find.text('已复制充值入口，请在企业微信中打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('repeated taps do not open multiple enterprise WeChat windows',
      (tester) async {
    final completion = Completer<bool>();
    var launchCount = 0;
    mockLauncher(tester, (call) {
      launchCount++;
      return completion.future;
    });
    await openPage(tester);

    await tester.tap(find.text('前往企业微信充值'));
    await tester.tap(find.text('前往企业微信充值'));
    await tester.pump();
    expect(launchCount, 1);

    completion.complete(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
