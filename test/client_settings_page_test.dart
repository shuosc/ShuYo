import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/client_backend_repository.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/features/settings/client_settings_page.dart';
import 'package:shuyo/core/client_app_info.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('settings hides logout entry when no account is active',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ClientSettingsPage(
          settingsService: ClientSettingsService(),
          scheduleNotificationService: AcademicScheduleNotificationService(
            repository: AcademicScheduleRepository(
              apiClient: AcademicScheduleApiClient(
                authService: _FakeAcademicAuthService(),
                httpClient: MockClient(
                  (_) async => http.Response('{}', 200),
                ),
              ),
            ),
          ),
          backendRepository: ClientBackendRepository(),
          selectedThemeId: 'default',
          followSystemTheme: false,
          onThemeChanged: (_) async {},
          onFollowSystemThemeChanged: (_) async {},
        ),
      ),
    );

    expect(find.text('退出乐乎论坛账户'), findsNothing);
    expect(find.text('退出上大校园账户'), findsNothing);
    expect(find.text('问题与反馈'), findsNothing);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('关于ShuYo'), findsOneWidget);
  });

  testWidgets('settings no longer exposes WebVPN controls', (tester) async {
    await _pumpSettings(tester);

    expect(find.text('WebVPN代理'), findsNothing);
    expect(find.text('自动使用WebVPN代理'), findsNothing);
  });

  testWidgets('about page exposes project privacy and support information',
      (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.text('关于ShuYo'));
    await tester.pumpAndSettle();

    expect(
      find.image(const AssetImage('assets/images/icon_light.png')),
      findsOneWidget,
    );
    expect(find.text(ClientAppInfo.appName), findsOneWidget);
    expect(
      find.text(
        '版本 ${ClientAppInfo.version}（${ClientAppInfo.buildNumber}）',
      ),
      findsOneWidget,
    );
    expect(find.text('源代码'), findsOneWidget);
    expect(find.text('GNU General Public License v3.0'), findsOneWidget);
    expect(find.text('第三方开源许可'), findsOneWidget);
    expect(find.text('贡献者'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    expect(find.text('权限说明'), findsOneWidget);
    expect(find.text('使用条款'), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.text('问题与反馈'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
  });

  testWidgets('about page explains Android permissions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await _pumpSettings(tester);
      await tester.tap(find.text('关于ShuYo'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('权限说明'), 250);
      await tester.tap(find.text('权限说明'));
      await tester.pumpAndSettle();

      expect(find.text('网络访问'), findsOneWidget);
      expect(find.text('通知'), findsOneWidget);
      expect(find.text('精确闹钟'), findsOneWidget);
      expect(find.text('照片与图片'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('开机后恢复提醒'), 200);
      expect(find.text('开机后恢复提醒'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('about page explains iOS-specific permissions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpSettings(tester);
      await tester.tap(find.text('关于ShuYo'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('权限说明'), 250);
      await tester.tap(find.text('权限说明'));
      await tester.pumpAndSettle();

      expect(find.text('闹钟'), findsOneWidget);
      expect(find.textContaining('AlarmKit'), findsOneWidget);
      expect(find.text('精确闹钟'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(find.text('开机后恢复提醒'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('demo about page hides online support actions', (tester) async {
    await _pumpSettings(tester, isDemo: true);
    await tester.tap(find.text('关于ShuYo'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();

    expect(find.text('问题与反馈'), findsNothing);
    expect(find.text('检查更新'), findsNothing);
  });

  testWidgets('logout entry reuses the supplied account logout handlers',
      (tester) async {
    var academicLogoutCalls = 0;
    var forumLogoutCalls = 0;
    await _pumpSettings(
      tester,
      hasAcademicAccount: true,
      hasForumAccount: true,
      onAcademicLogout: () async {
        academicLogoutCalls++;
        return true;
      },
      onForumLogout: () async {
        forumLogoutCalls++;
        return true;
      },
    );

    final clearCache = find.text('清除缓存');
    final logout = find.text('退出登录');
    expect(logout, findsOneWidget);
    expect(tester.getTopLeft(logout).dy,
        greaterThan(tester.getTopLeft(clearCache).dy));

    await tester.tap(logout);
    await tester.pumpAndSettle();
    expect(find.text('选择要退出的账户'), findsOneWidget);
    expect(find.text('上大校园账户'), findsOneWidget);
    expect(find.text('乐乎账户'), findsOneWidget);

    await tester.tap(find.text('上大校园账户'));
    await tester.pumpAndSettle();
    expect(find.text('退出上大校园账户？'), findsOneWidget);
    expect(academicLogoutCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(academicLogoutCalls, 1);
    expect(forumLogoutCalls, 0);
    expect(find.text('已退出上大校园账户'), findsOneWidget);

    await tester.tap(logout);
    await tester.pumpAndSettle();
    final academicTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '上大校园账户'),
    );
    expect(academicTile.enabled, isFalse);
    await tester.tap(find.text('乐乎账户'));
    await tester.pumpAndSettle();
    expect(find.text('退出乐乎论坛账户？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(forumLogoutCalls, 1);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  bool isDemo = false,
  bool hasAcademicAccount = false,
  bool hasForumAccount = false,
  Future<bool> Function()? onAcademicLogout,
  Future<bool> Function()? onForumLogout,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ClientSettingsPage(
        settingsService: ClientSettingsService(),
        scheduleNotificationService: AcademicScheduleNotificationService(
          repository: AcademicScheduleRepository(
            apiClient: AcademicScheduleApiClient(
              authService: _FakeAcademicAuthService(),
              httpClient: MockClient((_) async => http.Response('{}', 200)),
            ),
          ),
        ),
        backendRepository: ClientBackendRepository(),
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        hasAcademicAccount: hasAcademicAccount,
        hasForumAccount: hasForumAccount,
        onAcademicLogout: onAcademicLogout,
        onForumLogout: onForumLogout,
        isDemo: isDemo,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeAcademicAuthService implements AcademicAuthService {
  @override
  Future<void> clearAccount() async {}

  @override
  Future<Set<String>> clearCookies() async => {};

  @override
  Future<void> markLoggedIn() async {}

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => null;

  @override
  Future<bool> hasWebVpnSession() async => false;

  @override
  Future<bool> hasAcademicSession() async => false;

  @override
  Future<WebVpnSessionStatus> validateDirectAcademicSession() async =>
      WebVpnSessionStatus.loginRequired;

  @override
  Future<WebVpnSessionStatus> validateWebVpnSession() async =>
      WebVpnSessionStatus.loginRequired;
}
