import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/client_backend_repository.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/settings/client_settings_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';
import 'package:shuyo/shared/widgets/webvpn_toggle.dart';
import 'package:shuyo/core/client_app_info.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('privacy and deletion stay separate from authentication status',
      (tester) async {
    final identity = StudentIdentityService();
    addTearDown(identity.dispose);
    await _pumpSettings(tester, studentIdentityService: identity);
    await tester.tap(find.text('隐私与数据'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'ShuYo 通过核实学号来确认你的上海大学学生身份。撤销设备认证后，服务器会保留你使用反馈、课表分享等功能产生的数据。'),
        findsOneWidget);
    await tester.tap(find.text('删除 ShuYo 数据'));
    await tester.pumpAndSettle();
    expect(find.text('删除后，你的设备认证将全部失效；服务器当前保存的学号认证记录、反馈、活跃记录、课表分享码将被清除。'),
        findsOneWidget);
    expect(find.text('验证学校身份并继续'), findsOneWidget);
  });

  testWidgets('custom theme opens without a photo and disables opacity',
      (tester) async {
    CustomBackground? saved;
    await _pumpSettings(
      tester,
      onCustomBackgroundChanged: (settings) async => saved = settings,
    );
    await tester.tap(find.text('主题切换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('自定义主题'), 180);
    await tester.tap(find.text('自定义主题'));
    await tester.pumpAndSettle();

    expect(saved?.hasPhoto, isFalse);
    expect(saved?.opacity, 0);
    expect(find.text('选择照片'), findsOneWidget);
    expect(find.text('更换照片'), findsNothing);
    expect(find.text('清除'), findsNothing);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('文字'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
  });

  testWidgets('custom background expands only while selected and keeps edits',
      (tester) async {
    final selected = <String>[];
    CustomBackground? saved;
    final background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 50,
      background: const Color(0xFFF8F8F8),
      surface: Colors.white,
      text: const Color(0xFF171717),
      accent: const Color(0xFF3478D4),
    );
    await _pumpSettings(
      tester,
      customBackground: background,
      onThemeChanged: (id) async => selected.add(id),
      onCustomBackgroundChanged: (settings) async => saved = settings,
    );
    await tester.tap(find.text('主题切换'));
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsNothing);
    await tester.scrollUntilVisible(find.text('自定义主题'), 180);
    expect(find.text('不透明度'), findsNothing);

    await tester.tap(find.text('自定义主题'));
    await tester.pumpAndSettle();
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.text('更换照片'), findsOneWidget);
    expect(find.text('清除'), findsOneWidget);
    expect(find.text('面板'), findsNothing);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('文字'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    expect(tester.widget<Slider>(slider).divisions, isNull);
    expect(tester.widget<Slider>(slider).label, '50%');
    expect(
      tester
          .widget<SliderTheme>(find
              .ancestor(
                of: slider,
                matching: find.byType(SliderTheme),
              )
              .first)
          .data
          .showValueIndicator,
      ShowValueIndicator.onDrag,
    );
    final drag = await tester.startGesture(tester.getCenter(slider));
    await drag.moveBy(Offset(-tester.getSize(slider).width / 5, 0));
    await tester.pump();
    final previewOpacity = tester.widget<Slider>(slider).value.round();
    expect(
      find.byWidgetPredicate((widget) =>
          widget is CustomBackgroundLayer &&
          widget.settings?.opacity == previewOpacity),
      findsOneWidget,
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(saved?.opacity, inInclusiveRange(28, 33));

    await tester.scrollUntilVisible(find.text('浅色'), -180);
    await tester.ensureVisible(find.text('浅色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(find.text('不透明度'), findsNothing);
    await tester.scrollUntilVisible(find.text('自定义主题'), 180);
    await tester.tap(find.text('自定义主题'));
    await tester.pumpAndSettle();
    expect(find.text('不透明度'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, saved!.opacity);
    expect(selected, [
      ShuYoThemes.customBackgroundId,
      ShuYoThemes.defaultId,
      ShuYoThemes.customBackgroundId,
    ]);

    await tester.ensureVisible(find.text('清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(saved?.hasPhoto, isFalse);
    expect(saved?.opacity, 0);
    expect(saved?.accent, background.accent);
    expect(find.text('选择照片'), findsOneWidget);
    expect(find.text('清除'), findsNothing);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });

  testWidgets('switches away from custom on the first selection',
      (tester) async {
    const background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 50,
      background: Color(0xFFF8F8F8),
      surface: Colors.white,
      text: Color(0xFF171717),
      accent: Color(0xFF3478D4),
    );
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    final repository = AcademicScheduleRepository(
      apiClient: AcademicScheduleApiClient(
        authService: _FakeAcademicAuthService(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    var selectedId = ShuYoThemes.customBackgroundId;
    var followSystem = false;
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, rebuild) {
        final theme = followSystem
            ? ShuYoThemes.byId(ShuYoThemes.defaultId)
            : selectedId == ShuYoThemes.customBackgroundId
                ? background.theme
                : ShuYoThemes.byId(selectedId);
        final activeBackground =
            followSystem || selectedId != ShuYoThemes.customBackgroundId
                ? null
                : background;
        return MaterialApp(
          theme: theme.themeData(),
          builder: (_, child) => CustomBackgroundFrame(
            settings: activeBackground,
            child: child!,
          ),
          home: ClientSettingsPage(
            settingsService: ClientSettingsService(),
            scheduleNotificationService:
                AcademicScheduleNotificationService(repository: repository),
            backendRepository: ClientBackendRepository(),
            selectedThemeId: theme.id,
            followSystemTheme: followSystem,
            onThemeChanged: (id) async => rebuild(() {
              selectedId = id;
              followSystem = false;
            }),
            onFollowSystemThemeChanged: (enabled) async => rebuild(() {
              followSystem = enabled;
              if (enabled) selectedId = ShuYoThemes.defaultId;
            }),
            customBackground: background,
            onCustomBackgroundChanged: (_) async {},
            selectedStartupTab: AppTab.home,
            onStartupTabChanged: (_) async {},
            webVpnController: controller,
          ),
        );
      },
    ));
    await tester.tap(find.text('主题切换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('自定义主题'), 180);

    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, '自定义主题'),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );

    await tester.scrollUntilVisible(find.text('自定义主题'), 180);
    await tester.tap(find.text('自定义主题'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('不透明度'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('纸白'), -180);
    await tester.tap(find.text('纸白'));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, '纸白'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(find.text('不透明度'), findsNothing);
  });

  testWidgets('custom color picker supports square, hue, and hex input',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    CustomBackground? saved;
    final background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 50,
      background: const Color(0xFFF8F8F8),
      surface: Colors.white,
      text: const Color(0xFF171717),
      accent: const Color(0xFF3478D4),
    );
    await _pumpSettings(
      tester,
      customBackground: background,
      onCustomBackgroundChanged: (settings) async => saved = settings,
    );
    await tester.tap(find.text('主题切换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('自定义主题'), 180);
    await tester.tap(find.text('自定义主题'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();

    final square = find.byKey(const Key('theme-color-square'));
    final hue = find.byKey(const Key('theme-hue-bar'));
    expect(square, findsOneWidget);
    expect(hue, findsOneWidget);
    await tester.tapAt(tester.getTopLeft(square) + const Offset(100, 70));
    await tester.tapAt(tester.getTopLeft(hue) + const Offset(100, 14));
    await tester.enterText(find.byKey(const Key('theme-hex-field')), 'AA3366');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(saved?.accent, const Color(0xFFAA3366));

    await tester.ensureVisible(find.text('文字'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('theme-hex-field')), 'F8F8F8');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('theme-hex-field')))
          .controller
          ?.text,
      'F8F8F8',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(saved?.text, background.background);
    expect(find.text('文字与背景颜色过于接近'), findsNothing);
  });

  testWidgets('settings hides logout entry when no account is active',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
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
          selectedStartupTab: AppTab.home,
          onStartupTabChanged: (_) async {},
          webVpnController: controller,
        ),
      ),
    );

    expect(find.text('退出上大校园账户'), findsNothing);
    expect(find.text('问题与反馈'), findsNothing);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('通知设置'), findsNothing);
    expect(find.text('课表提醒'), findsNothing);
    expect(find.text('关于ShuYo'), findsOneWidget);
  });

  testWidgets('default announcement setting saves one college source',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpSettings(tester);
    expect(tester.getTopLeft(find.text('主题切换')).dy,
        lessThan(tester.getTopLeft(find.text('默认公告')).dy));
    expect(tester.getTopLeft(find.text('默认公告')).dy,
        lessThan(tester.getTopLeft(find.text('启动显示')).dy));
    await tester.tap(find.text('默认公告'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    await tester.scrollUntilVisible(find.text('材料科学与工程学院'), 200);
    await tester.tap(find.text('材料科学与工程学院'));
    await tester.pumpAndSettle();
    expect((await ClientSettingsService().loadDefaultAnnouncementSource()).id,
        'mat');
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(AnnouncementSource.byId('mat').name, '材料科学与工程学院');
  });

  testWidgets('WebVPN settings shares the account manager state',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    controller.setWebVpnChangeHandler((enabled) async {
      controller.updateAccountStatus(
        academicLoggedIn: false,
        webVpnEnabled: enabled,
      );
      return true;
    });
    await _pumpSettings(tester, webVpnController: controller);

    expect(tester.getTopLeft(find.text('主题切换')).dy,
        lessThan(tester.getTopLeft(find.text('WebVPN连接')).dy));
    await tester.tap(find.text('WebVPN连接'));
    await tester.pumpAndSettle();
    expect(find.text('WebVPN'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.text('WebVPN'));
    await tester.pumpAndSettle();
    expect(controller.webVpnEnabled, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    controller.updateAccountStatus(
      academicLoggedIn: false,
      webVpnEnabled: false,
    );
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('startup display lists tabs and saves the next launch choice',
      (tester) async {
    final service = ClientSettingsService();
    await _pumpSettings(
      tester,
      onStartupTabChanged: service.saveStartupTab,
    );

    expect(tester.getTopLeft(find.text('主题切换')).dy,
        lessThan(tester.getTopLeft(find.text('启动显示')).dy));
    expect(tester.getTopLeft(find.text('启动显示')).dy,
        lessThan(tester.getTopLeft(find.text('WebVPN连接')).dy));
    await tester.tap(find.text('启动显示'));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('日程'), findsOneWidget);

    await tester.tap(find.text('学业'));
    await tester.pumpAndSettle();
    expect(await service.loadStartupTab(), AppTab.progress);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, '学业'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('WebVPN loading drops below the switch and retracts',
      (tester) async {
    final controller = StartupOnboardingController();
    addTearDown(controller.dispose);
    final pending = Completer<bool>();
    controller.setWebVpnChangeHandler((_) => pending.future);
    await _pumpSettings(tester, webVpnController: controller);
    await tester.tap(find.text('WebVPN连接'));
    await tester.pumpAndSettle();
    final labelWidth = tester.getSize(find.text('WebVPN')).width;

    final loader = find.descendant(
      of: find.byType(WebVpnToggle),
      matching: find.byType(CircularProgressIndicator),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(loader, findsOneWidget);
    final fallingTop = tester.getTopLeft(loader).dy;
    await tester.pump(const Duration(milliseconds: 200));
    final restingTop = tester.getTopLeft(loader).dy;
    expect(restingTop, greaterThan(fallingTop));
    expect(
        restingTop, greaterThan(tester.getBottomLeft(find.byType(Switch)).dy));
    expect(tester.getSize(find.text('WebVPN')).width, labelWidth);

    pending.complete(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(loader).dy, lessThan(restingTop));
    await tester.pumpAndSettle();
    expect(loader, findsNothing);
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

  testWidgets('WebVPN session alone uses the full campus logout',
      (tester) async {
    var logoutCalls = 0;
    await _pumpSettings(
      tester,
      hasWebVpnSession: true,
      onAcademicLogout: () async {
        logoutCalls++;
        return true;
      },
    );

    expect(find.text('退出登录'), findsOneWidget);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('确认退出'), findsOneWidget);
    expect(find.text('退出后将需要重新登录，仍可查看已保存的课表和学业信息'), findsOneWidget);
    expect(find.text('选择要退出的会话'), findsNothing);
    expect(logoutCalls, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 0);

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 1);
    expect(find.text('已退出上大校园账户'), findsOneWidget);
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, '退出登录')).onTap,
        isNull);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  bool isDemo = false,
  bool hasAcademicAccount = false,
  bool hasWebVpnSession = false,
  Future<bool> Function()? onAcademicLogout,
  StartupOnboardingController? webVpnController,
  AppTab selectedStartupTab = AppTab.home,
  Future<void> Function(AppTab)? onStartupTabChanged,
  CustomBackground? customBackground,
  Future<void> Function(String)? onThemeChanged,
  Future<void> Function(CustomBackground)? onCustomBackgroundChanged,
  StudentIdentityService? studentIdentityService,
}) async {
  final controller = webVpnController ?? StartupOnboardingController();
  if (webVpnController == null) addTearDown(controller.dispose);
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
        onThemeChanged: onThemeChanged ?? (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        customBackground: customBackground,
        onCustomBackgroundChanged: onCustomBackgroundChanged,
        selectedStartupTab: selectedStartupTab,
        onStartupTabChanged: onStartupTabChanged ?? (_) async {},
        webVpnController: controller,
        hasAcademicAccount: hasAcademicAccount,
        hasWebVpnSession: hasWebVpnSession,
        onAcademicLogout: onAcademicLogout,
        studentIdentityService: studentIdentityService,
        isDemo: isDemo,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeAcademicAuthService implements AcademicAuthService {
  @override
  Future<void> clearAccount({bool sessionExpired = false}) async {}

  @override
  Future<Set<String>> clearCookies() async => {};

  @override
  Future<void> markLoggedIn() async {}

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => null;

  @override
  Future<String?> cookieHeaderForIdentityVerification(
          {required Uri targetUri}) async =>
      null;

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
