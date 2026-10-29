import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/models/academic_progress.dart';
import 'package:shuyo/data/models/academic_ranking.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_progress_repository.dart';
import 'package:shuyo/data/repositories/academic_ranking_repository.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/campus_card_service.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/auth/native_login_page.dart';
import 'package:shuyo/features/home/academic_progress_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';

final _schedule = AcademicSchedule(
  term: const AcademicTerm(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋',
    studentName: '',
    studentId: 'DEMO0001',
    className: '',
  ),
  sessions: const [],
  untimedCourses: const [],
  fetchedAt: DateTime(2026, 9, 1),
);

class _TrackingSchedule extends AcademicScheduleRepository {
  int requests = 0;
  bool expired = false;
  bool unavailable = false;

  @override
  Future<AcademicSchedule> refreshSchedule() async {
    requests++;
    if (expired) throw const AcademicAuthException();
    if (unavailable) throw const AcademicApiException('offline');
    await saveCachedSchedule(_schedule);
    return _schedule;
  }
}

class _TrackingProgress extends AcademicProgressRepository {
  int requests = 0;
  bool expired = false;

  @override
  Future<AcademicProgress> refreshProgress() async {
    requests++;
    if (expired) throw const AcademicAuthException();
    final progress = DemoAcademicProgressRepository().progress;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AcademicProgressRepository.cacheKey, jsonEncode(progress.toJson()));
    return progress;
  }
}

class _TrackingRanking extends AcademicRankingRepository {
  int requests = 0;
  bool expired = false;
  Completer<AcademicRanking>? pending;

  @override
  Future<AcademicRanking> refreshRanking() async {
    requests++;
    if (pending != null) return pending!.future;
    if (expired) throw const AcademicAuthException();
    final ranking = DemoAcademicRankingRepository().ranking;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AcademicRankingRepository.cacheKey, jsonEncode(ranking.toJson()));
    return ranking;
  }
}

class _LocalAuth extends AcademicAuthService {
  _LocalAuth()
      : super(cookieLoader: (_) async => [], cookieSetter: (_) async {});

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => 'JSESSIONID=test';

  @override
  Future<bool> restoreAcademicCookies({Uri? targetUri}) async => true;
}

class _LocalUnifiedAccount extends UnifiedAccountService {
  @override
  Future<WebVpnRecoveryOutcome> recoverWebVpn() async =>
      WebVpnRecoveryOutcome.unavailable;

  @override
  Future<Uri?> authorizeAcademic() async => null;

  @override
  Future<Uri?> authorizeCampusCard() async {
    // Model an unavailable card service while keeping the campus login valid.
    throw const CampusCardException('unavailable', '校园卡服务暂不可用');
  }
}

class _StubNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<List<PendingNotificationRequest>>
      pendingNotificationRequests() async => [];
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance = _StubNotifications();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => switch (call.method) {
        'initialize' => true,
        'pendingNotificationRequests' => [],
        _ => null,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('work.shuyo.app/early_class_alarms'),
      (call) async => call.method == 'isAvailable' ? false : 0,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('work.shuyo.app/early_class_alarms'),
      null,
    );
  });

  Widget shell({
    required StartupOnboardingController controller,
    required _TrackingSchedule schedule,
    required _TrackingProgress progress,
    required _TrackingRanking ranking,
    required _LocalAuth auth,
    int signal = 0,
    bool loggedIn = false,
  }) =>
      MaterialApp(
        home: AppShell(
          initialWebVpnEnabled: false,
          selectedThemeId: 'default',
          followSystemTheme: false,
          onThemeChanged: (_) async {},
          onFollowSystemThemeChanged: (_) async {},
          academicLoginSignal: signal,
          initialHasAcademicSession: loggedIn,
          initialAcademicStudentId: loggedIn ? 'DEMO0001' : null,
          onboardingController: controller,
          scheduleRepository: schedule,
          progressRepository: progress,
          rankingRepository: ranking,
          academicAuthService: auth,
          unifiedAccountService: _LocalUnifiedAccount(),
        ),
      );

  for (final firstLogin in [true, false]) {
    testWidgets('login syncs all data only on first login: $firstLogin',
        (tester) async {
      final controller = StartupOnboardingController();
      final schedule = _TrackingSchedule();
      final progress = _TrackingProgress();
      final ranking = _TrackingRanking();
      final auth = _LocalAuth();
      final account = AcademicAccountStore();
      if (!firstLogin) await account.takeInitialSync('DEMO0001');
      await tester.pumpWidget(shell(
          controller: controller,
          schedule: schedule,
          progress: progress,
          ranking: ranking,
          auth: auth));
      await tester.pumpAndSettle();
      await account.saveStudentId('DEMO0001');
      await tester.pumpWidget(shell(
          controller: controller,
          schedule: schedule,
          progress: progress,
          ranking: ranking,
          auth: auth,
          signal: 1));
      await tester.pumpAndSettle();
      expect(schedule.requests, firstLogin ? 1 : 0);
      expect(progress.requests, firstLogin ? 1 : 0);
      expect(ranking.requests, firstLogin ? 1 : 0);
      expect(find.text('你好，DEMO0001！'), findsOneWidget);
      if (!firstLogin) {
        expect(find.text('登录已恢复，请再次点击刷新更新数据'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      controller.dispose();
    });
  }

  testWidgets(
      'failed initial schedule sync does not prevent extras or repeat on re-login',
      (tester) async {
    final controller = StartupOnboardingController();
    final schedule = _TrackingSchedule()..unavailable = true;
    final progress = _TrackingProgress();
    final ranking = _TrackingRanking();
    final auth = _LocalAuth();
    final account = AcademicAccountStore();
    await tester.pumpWidget(shell(
        controller: controller,
        schedule: schedule,
        progress: progress,
        ranking: ranking,
        auth: auth));
    await tester.pumpAndSettle();
    await account.saveStudentId('DEMO0001');
    await tester.pumpWidget(shell(
        controller: controller,
        schedule: schedule,
        progress: progress,
        ranking: ranking,
        auth: auth,
        signal: 1));
    await tester.pumpAndSettle();
    expect(schedule.requests, 1);
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    expect(await schedule.loadCachedSchedule(), isNull);
    expect(await progress.loadCachedProgress(), isNotNull);
    expect(await ranking.loadCachedRanking(), isNotNull);
    await account.clear(sessionExpired: true);
    await account.saveStudentId('DEMO0001');
    await tester.pumpWidget(shell(
        controller: controller,
        schedule: schedule,
        progress: progress,
        ranking: ranking,
        auth: auth,
        signal: 2));
    await tester.pumpAndSettle();
    expect(schedule.requests, 1);
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    controller.dispose();
  });

  for (final tab in ['学业', '日程']) {
    for (final authenticate in [false, true]) {
      testWidgets(
          '$tab expired refresh handles login, authenticate=$authenticate',
          (tester) async {
        final controller = StartupOnboardingController();
        final schedule = _TrackingSchedule()..expired = true;
        final progress = _TrackingProgress()..expired = true;
        final ranking = _TrackingRanking()..expired = true;
        final auth = _LocalAuth();
        final account = AcademicAccountStore();
        await account.saveStudentId('DEMO0001');
        await account.takeInitialSync('DEMO0001');
        await schedule.saveCachedSchedule(_schedule);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(AcademicProgressRepository.cacheKey,
            jsonEncode(DemoAcademicProgressRepository().progress.toJson()));
        await tester.pumpWidget(shell(
            controller: controller,
            schedule: schedule,
            progress: progress,
            ranking: ranking,
            auth: auth,
            loggedIn: true));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        if (tab == '学业') {
          expect(progress.requests, 1);
          expect(ranking.requests, 1);
          expect(find.byType(NativeLoginPage), findsNothing);
          expect(controller.academicLoggedIn, isTrue);
        }
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tab == '学业' ? '刷新学业信息' : '更新课表'));
        if (tab == '日程') {
          await tester.pumpAndSettle();
          await tester.tap(find.text('确定'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(NativeLoginPage), findsOneWidget);
        expect(controller.academicLoggedIn, isFalse);
        expect(controller.academicSessionExpired, isTrue);
        expect(await account.loadStudentId(), isNull);
        expect(await account.isSessionExpired(), isTrue);
        expect(progress.requests, tab == '学业' ? 2 : 0);
        expect(ranking.requests, tab == '学业' ? 2 : 0);
        if (authenticate) await account.saveStudentId('DEMO0001');
        Navigator.of(tester.element(find.byType(NativeLoginPage))).pop(
          authenticate ? NativeLoginResult.authenticated : null,
        );
        await tester.pumpAndSettle();
        expect(find.byType(NativeLoginPage), findsNothing);
        expect(schedule.requests, tab == '日程' ? 1 : 0);
        final academicRequests = tab == '学业' ? (authenticate ? 3 : 2) : 0;
        expect(progress.requests, academicRequests);
        expect(ranking.requests, academicRequests);
        expect(controller.academicLoggedIn, authenticate);
        expect(controller.academicSessionExpired, !authenticate);
        expect(
            tester
                .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
                .currentIndex,
            tab == '学业' ? AppTab.progress.index : AppTab.schedule.index);
        if (tab == '学业') expect(find.text('学业总览'), findsOneWidget);
        await tester.tap(find.text('首页').last);
        await tester.pumpAndSettle();
        expect(
            find.text(authenticate ? '你好，DEMO0001！' : '重新登录'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        controller.dispose();
      });
    }
  }

  testWidgets('academic authentication failure does not wait for ranking',
      (tester) async {
    final progress = _TrackingProgress()..expired = true;
    final ranking = _TrackingRanking()..pending = Completer<AcademicRanking>();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AcademicProgressRepository.cacheKey,
        jsonEncode(DemoAcademicProgressRepository().progress.toJson()));
    await AcademicAccountStore().saveStudentId('DEMO0001');
    var loginRequests = 0;
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: progress,
        rankingRepository: ranking,
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        autoRefreshEnabled: false,
        restoreSession: () async {},
        onLoginRequired: () async => loginRequests++,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新学业信息'));
    await tester.pumpAndSettle();

    expect(loginRequests, 1);
    expect(ranking.pending!.isCompleted, isFalse);
    ranking.pending!.completeError(const AcademicAuthException());
    await tester.pumpAndSettle();
    expect(loginRequests, 1);
  });
}
