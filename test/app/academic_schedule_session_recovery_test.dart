import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/auth/native_login_page.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

final _callback =
    Uri.parse('https://jwxt.shu.edu.cn/jwglxt/ticketlogin?ticket=fake');
final _jwxt = Uri.parse('https://jwxt.shu.edu.cn/jwglxt/');

class _Account extends UnifiedAccountService {
  int authorizations = 0;
  Uri? callback = _callback;
  Object? error;
  Completer<Uri?>? pending;

  @override
  Future<Uri?> authorizeAcademic() async {
    authorizations++;
    if (pending != null) return pending!.future;
    if (error != null) throw error!;
    return callback;
  }
}

class _NativeAuth extends AcademicNativeAuthService {
  int exchanges = 0;
  int publications = 0;

  @override
  Future<void> completeLogin(Uri callback, {bool publish = true}) async {
    expect(callback, _callback);
    expect(publish, isFalse);
    exchanges++;
  }

  @override
  Future<void> publishSessionCookies() async {
    publications++;
    await SessionCookieJar.shared.setCookie(const SessionCookie(
      name: 'JSESSIONID',
      value: 'fresh-session',
      domain: 'jwxt.shu.edu.cn',
    ));
  }
}

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<List<PendingNotificationRequest>>
      pendingNotificationRequests() async => [];
}

class _Repository extends AcademicScheduleRepository {
  _Repository(AcademicScheduleApiClient api) : super(apiClient: api);

  bool backgroundDiscovery = false;

  @override
  bool get supportsTermDiscovery => backgroundDiscovery;
}

void main() {
  late _Account account;
  late _NativeAuth native;
  late AcademicAuthService auth;
  late _Repository repository;
  late StartupOnboardingController controller;
  late List<String> requests;
  late bool rejectFreshSession;
  final scheduleJson =
      File('test/fixtures/academic_schedule/historical_schedule.json')
          .readAsStringSync();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    FlutterLocalNotificationsPlatform.instance = _Notifications();
    SharedPreferences.setMockInitialValues({});
    SessionCookieJar.shared.resetForTesting();
    await AcademicAccountStore().saveStudentId('TEST_STUDENT');
    account = _Account();
    native = _NativeAuth();
    controller = StartupOnboardingController();
    requests = [];
    rejectFreshSession = false;
    auth = AcademicAuthService(directSessionValidator: (header) async {
      expect(header, contains('JSESSIONID=fresh-session'));
      expect(header, isNot(contains('expired-scoped-session')));
      return WebVpnSessionStatus.valid;
    });
    final api = AcademicScheduleApiClient(
      authService: auth,
      httpClient: MockClient((request) async {
        requests.add(request.method);
        final authenticated =
            request.headers['cookie'] == 'JSESSIONID=fresh-session';
        if (!authenticated || rejectFreshSession) {
          return http.Response('', 901, request: request);
        }
        if (request.method == 'GET') {
          return http.Response(
            '<input name="xnm" value="2025"><input name="xqm" value="3">',
            200,
            request: request,
          );
        }
        return http.Response(scheduleJson, 200,
            headers: {'content-type': 'application/json;charset=UTF-8'},
            request: request);
      }),
    );
    repository = _Repository(api);
    await repository.saveCachedSchedule(AcademicScheduleParser.parse(
        jsonDecode(scheduleJson) as Map<String, dynamic>));
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    controller.dispose();
    native.dispose();
    SessionCookieJar.shared.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('work.shuyo.app/early_class_alarms'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('work.shuyo.app/course_live_activity'), null);
  });

  Future<void> showShell(WidgetTester tester, {int loginSignal = 0}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('work.shuyo.app/early_class_alarms'),
      (_) async => false,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('work.shuyo.app/course_live_activity'),
      (call) async =>
          call.method == 'isAvailable' ? false : {'activitiesEnabled': false},
    );
    // Initialize the shared jar inside this test's fake-async zone.
    await SessionCookieJar.shared.setCookie(const SessionCookie(
      name: 'JSESSIONID',
      value: 'expired-scoped-session',
      domain: 'jwxt.shu.edu.cn',
      path: '/jwglxt',
    ));
    await SessionCookieJar.shared.setCookie(const SessionCookie(
      name: 'SHU_OAUTH2',
      value: 'live-sso',
      domain: 'newsso.shu.edu.cn',
    ));
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: loginSignal,
        initialHasAcademicSession: true,
        initialAcademicStudentId: 'TEST_STUDENT',
        onboardingController: controller,
        scheduleRepository: repository,
        academicAuthService: auth,
        academicNativeAuthServiceFactory: () => native,
        unifiedAccountService: account,
        initialOpenSchedule: true,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> refresh(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  Future<void> closeShell(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('901 refresh reuses SSO and retains the requesting page',
      (tester) async {
    await showShell(tester);
    final pageState = tester.state(find.byType(AcademicSchedulePage));
    await refresh(tester);
    expect(account.authorizations, 1);
    expect(native.exchanges, 1);
    expect(native.publications, 1);
    expect(requests, ['POST', 'POST']);
    expect(tester.state(find.byType(AcademicSchedulePage)), same(pageState));
    expect(await AcademicAccountStore().loadStudentId(), 'TEST_STUDENT');
    expect(find.byType(NativeLoginPage), findsNothing);
    expect(find.textContaining('课表已同步'), findsOneWidget);
    final cookies = await SessionCookieJar.shared.getCookies(domain: _jwxt);
    expect(cookies.map((cookie) => cookie.value), ['fresh-session']);
    expect(
      (await SessionCookieJar.shared
              .getCookies(domain: Uri.parse('https://newsso.shu.edu.cn/')))
          .single
          .value,
      'live-sso',
    );
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets('a rejected initial sync does not sign out an otherwise live SSO',
      (tester) async {
    await showShell(tester);
    rejectFreshSession = true;
    await showShell(tester, loginSignal: 1);
    expect(account.authorizations, 1);
    expect(native.exchanges, 1);
    expect(requests, ['POST', 'POST']);
    expect(await AcademicAccountStore().loadStudentId(), 'TEST_STUDENT');
    expect(await AcademicAccountStore().isSessionExpired(), isFalse);
    expect(await repository.loadCachedSchedule(), isNotNull);
    expect(find.byType(NativeLoginPage), findsNothing);
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets('startup discovery recovers once and resumes its queue',
      (tester) async {
    repository.backgroundDiscovery = true;
    await showShell(tester);
    expect(account.authorizations, 1);
    expect(native.exchanges, 1);
    expect(repository.discoveryState.value.requiresLogin, isFalse);
    expect(requests.where((method) => method == 'GET'), hasLength(2));
    expect(await AcademicAccountStore().loadStudentId(), 'TEST_STUDENT');
    expect(find.byType(NativeLoginPage), findsNothing);
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets('manual refresh shares an in-flight background SSO recovery',
      (tester) async {
    repository.backgroundDiscovery = true;
    final pending = Completer<Uri?>();
    account.pending = pending;
    await showShell(tester);
    expect(account.authorizations, 1);
    await refresh(tester);
    expect(account.authorizations, 1);
    pending.complete(_callback);
    await tester.pumpAndSettle();
    expect(account.authorizations, 1);
    expect(native.exchanges, 1);
    expect(find.textContaining('课表已同步'), findsOneWidget);
    expect(repository.discoveryState.value.requiresLogin, isFalse);
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets(
      'persistent 901 does not repeatedly authorize background discovery',
      (tester) async {
    repository.backgroundDiscovery = true;
    rejectFreshSession = true;
    await showShell(tester);
    expect(account.authorizations, 1);
    expect(native.exchanges, 1);
    expect(repository.discoveryState.value.requiresLogin, isTrue);
    expect(requests, ['GET', 'GET']);
    expect(await repository.loadCachedSchedule(), isNotNull);
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets('uncertain SSO result preserves the account and cached timetable',
      (tester) async {
    repository.backgroundDiscovery = true;
    account.error = StateError('network unavailable');
    await showShell(tester);
    expect(account.authorizations, 1);
    expect(native.exchanges, 0);
    expect(await AcademicAccountStore().loadStudentId(), 'TEST_STUDENT');
    expect(await repository.loadCachedSchedule(), isNotNull);
    expect(find.byType(NativeLoginPage), findsNothing);
    expect(
        (await SessionCookieJar.shared.getCookies(domain: _jwxt)).single.value,
        'expired-scoped-session');
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });

  testWidgets(
      'expired SSO marks background expiry without opening a login page',
      (tester) async {
    repository.backgroundDiscovery = true;
    account.callback = null;
    await showShell(tester);
    expect(account.authorizations, 1);
    expect(native.exchanges, 0);
    expect(await AcademicAccountStore().isSessionExpired(), isTrue);
    expect(await repository.loadCachedSchedule(), isNotNull);
    expect(find.byType(NativeLoginPage), findsNothing);
    expect(tester.takeException(), isNull);
    await closeShell(tester);
  });
}
