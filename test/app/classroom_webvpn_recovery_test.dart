import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

class _PendingAccount extends UnifiedAccountService {
  final recovery = Completer<WebVpnRecoveryOutcome>();
  int recoveries = 0;

  @override
  Future<WebVpnRecoveryOutcome> recoverWebVpn() {
    recoveries++;
    return recovery.future;
  }
}

void main() {
  setUp(() {
    SessionCookieJar.shared.resetForTesting();
    ClassroomUrlResolver.configure(useWebVpn: true);
    SharedPreferences.setMockInitialValues({
      'client.network.webvpn.enabled': true,
    });
  });
  tearDown(() => ClassroomUrlResolver.configure(useWebVpn: false));

  testWidgets('automatic recovery cannot undo a user disabling WebVPN',
      (tester) async {
    final controller = StartupOnboardingController();
    final account = _PendingAccount();
    final page = await _openClassroomDuringRecovery(
      tester,
      controller: controller,
      account: account,
    );
    expect(await controller.setWebVpnEnabled(false), isTrue);
    account.recovery.complete(WebVpnRecoveryOutcome.recovered);
    await tester.pumpAndSettle();

    expect(controller.webVpnEnabled, isFalse);
    expect(ClassroomUrlResolver.usesWebVpn, isFalse);
    expect(
      (await ClientSettingsService().loadNetworkSettings()).webVpnEnabled,
      isFalse,
    );
    expect(await page.onWebVpnRecoveryRequired!(false),
        WebVpnRecoveryOutcome.unavailable);
    expect(account.recoveries, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    controller.dispose();
  });

  for (final outcome in [
    WebVpnRecoveryOutcome.alreadyValid,
    WebVpnRecoveryOutcome.recovered,
  ]) {
    testWidgets(
        'manual enable after leaving the classroom ignores a stale recovery: $outcome',
        (tester) async {
      final controller = StartupOnboardingController();
      final account = _PendingAccount();
      await _openClassroomDuringRecovery(
        tester,
        controller: controller,
        account: account,
      );
      // The switch lives outside the classroom page. Its recovery keeps
      // running in AppShell after the user leaves the page.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EmptyClassroomPage), findsNothing);

      expect(await controller.setWebVpnEnabled(false), isTrue);
      expect(ClassroomUrlResolver.usesWebVpn, isFalse);
      final enabling = controller.setWebVpnEnabled(true);
      // A fresh feature operation may still share the in-flight login.
      expect(account.recoveries, 1);
      account.recovery.complete(outcome);
      expect(await enabling, isTrue);
      await tester.pumpAndSettle();

      expect(controller.webVpnEnabled, isTrue);
      expect(ClassroomUrlResolver.usesWebVpn, isTrue);
      expect(
        (await ClientSettingsService().loadNetworkSettings()).webVpnEnabled,
        isTrue,
      );
      expect(account.recoveries, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      controller.dispose();
    });
  }
}

Future<EmptyClassroomPage> _openClassroomDuringRecovery(
  WidgetTester tester, {
  required StartupOnboardingController controller,
  required _PendingAccount account,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppShell(
      initialWebVpnEnabled: true,
      selectedThemeId: 'default',
      followSystemTheme: false,
      onThemeChanged: (_) async {},
      onFollowSystemThemeChanged: (_) async {},
      academicLoginSignal: 0,
      initialHasAcademicSession: false,
      initialAcademicStudentId: null,
      onboardingController: controller,
      unifiedAccountService: account,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('空教室'), 180);
  await tester.tap(find.text('空教室'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  // No stored token: opening the page starts automatic recovery. Keep
  // that recovery pending while the user turns WebVPN off.
  for (var frame = 0; frame < 10 && account.recoveries == 0; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(account.recoveries, 1);
  return tester.widget<EmptyClassroomPage>(find.byType(EmptyClassroomPage));
}
