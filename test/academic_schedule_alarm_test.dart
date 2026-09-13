import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/client_backend_repository.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/client_settings_service.dart';
import 'package:shuyo/features/settings/client_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.shuyo/early_class_alarms');

  late List<Map<Object?, Object?>> syncedAlarms;
  late List<String> methodCalls;
  late bool alarmAuthorized;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    FlutterLocalNotificationsPlatform.instance = _StubNotificationsPlatform();
    SharedPreferences.setMockInitialValues({});
    syncedAlarms = [];
    methodCalls = [];
    alarmAuthorized = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methodCalls.add(call.method);
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'requestAuthorization':
          return alarmAuthorized;
        case 'sync':
          final arguments = call.arguments as Map<Object?, Object?>;
          syncedAlarms = (arguments['alarms'] as List<Object?>)
              .cast<Map<Object?, Object?>>();
          return alarmAuthorized ? syncedAlarms.length : -1;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('AlarmKit sync schedules only each morning earliest class', () async {
    final repository = AcademicScheduleRepository(
      apiClient: _UnusedAcademicScheduleApiClient(),
    );
    await repository.saveCachedSchedule(_schedule);
    await repository.setCurrentWeek(1, now: DateTime(2026, 8, 31));
    final service = AcademicScheduleNotificationService(
      repository: repository,
      alarmChannel: channel,
    );

    expect(
      await service.loadAlarmSettings(),
      isA<AcademicScheduleAlarmSettings>()
          .having((settings) => settings.enabled, 'enabled', isFalse)
          .having((settings) => settings.leadMinutes, 'leadMinutes', 20),
    );

    await service.saveAlarmSettings(
      const AcademicScheduleAlarmSettings(enabled: true, leadMinutes: 20),
    );
    final count = await service.syncEarlyClassAlarms(
      now: DateTime.utc(2026, 8, 30, 21),
    );

    expect(count, 2);
    expect(syncedAlarms.map((alarm) => alarm['title']), ['高等数学', '大学英语']);
    expect(
      syncedAlarms.map(
        (alarm) => DateTime.fromMillisecondsSinceEpoch(
          alarm['fireTime']! as int,
          isUtc: true,
        ),
      ),
      [DateTime.utc(2026, 8, 30, 23, 40), DateTime.utc(2026, 9, 1, 1, 40)],
    );
  });

  test('AlarmKit sync disables stale setting when permission is revoked',
      () async {
    final service = AcademicScheduleNotificationService(
      repository: AcademicScheduleRepository(
        apiClient: _UnusedAcademicScheduleApiClient(),
      ),
      alarmChannel: channel,
    );
    await service.saveAlarmSettings(
      const AcademicScheduleAlarmSettings(enabled: true, leadMinutes: 20),
    );
    alarmAuthorized = false;

    final saved = await service.saveAlarmSettingsAndSync(
      const AcademicScheduleAlarmSettings(enabled: true, leadMinutes: 30),
    );

    expect(saved.enabled, isFalse);
    expect(saved.leadMinutes, 30);
  });

  testWidgets('iOS 26 settings request AlarmKit permission when enabled',
      (tester) async {
    try {
      final repository = AcademicScheduleRepository(
        apiClient: _UnusedAcademicScheduleApiClient(),
      );
      final alarmService = AcademicScheduleNotificationService(
        repository: repository,
        alarmChannel: channel,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ClientSettingsPage(
            settingsService: ClientSettingsService(),
            scheduleNotificationService: alarmService,
            backendRepository: ClientBackendRepository(),
            selectedThemeId: 'default',
            followSystemTheme: false,
            onThemeChanged: (_) async {},
            onFollowSystemThemeChanged: (_) async {},
          ),
        ),
      );
      await tester.tap(find.text('通知设置'));
      await tester.pumpAndSettle();

      expect(find.text('早课闹钟'), findsOneWidget);
      expect(find.text('闹钟提前时间'), findsNothing);

      await tester.tap(find.text('早课闹钟'));
      await tester.pumpAndSettle();

      expect(methodCalls, contains('requestAuthorization'));
      expect(find.text('闹钟提前时间'), findsOneWidget);
      expect(find.text('20 分钟'), findsOneWidget);

      await tester.tap(find.text('闹钟提前时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('闹钟提前时间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '30');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('30 分钟'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _UnusedAcademicScheduleApiClient extends AcademicScheduleApiClient {
  _UnusedAcademicScheduleApiClient()
      : super(authService: _FakeAcademicAuthService());
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

CourseSession _session({
  required String name,
  required int weekday,
  required int startSection,
}) {
  return CourseSession(
    id: '$name-$weekday-$startSection',
    courseName: name,
    courseCode: '',
    teacherName: '',
    campus: '',
    location: '',
    weekday: weekday,
    startSection: startSection,
    endSection: startSection,
    sections: [startSection],
    weeks: const [1],
    weekText: '1周',
    credit: '',
    note: '',
  );
}

final _schedule = AcademicSchedule(
  term: const AcademicTerm(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋',
    studentName: '',
    studentId: '',
    className: '',
  ),
  sessions: [
    _session(name: '高等数学', weekday: DateTime.monday, startSection: 1),
    _session(name: '线性代数', weekday: DateTime.monday, startSection: 3),
    _session(name: '大学英语', weekday: DateTime.tuesday, startSection: 3),
    _session(name: '体育', weekday: DateTime.wednesday, startSection: 5),
  ],
  untimedCourses: const [],
  fetchedAt: DateTime(2026, 8, 31),
);

class _StubNotificationsPlatform extends FlutterLocalNotificationsPlatform {}
