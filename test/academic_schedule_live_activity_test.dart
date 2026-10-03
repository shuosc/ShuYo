import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.shuyo/course_live_activity');
  const alarmChannel = MethodChannel('work.shuyo.app/early_class_alarms');
  const notificationChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // The notification plugin rejects past dates against the real clock, so the
  // schedule uses a far-future Monday. 07:00 in Shanghai, before section 1.
  final now = DateTime.utc(2100, 1, 3, 23);
  final anchorMonday = DateTime(2100, 1, 4);

  late AcademicScheduleRepository repository;
  late AcademicScheduleNotificationService notifications;
  late List<Map<Object?, Object?>> scheduledNotifications;
  late List<int> cancelledNotifications;
  late List<Object> pendingNotifications;

  Future<void> saveSettingsSheet(WidgetTester tester) async {
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    // Saving crosses modal animations and platform futures. Drain both the
    // widget test clock and the real event queue until the completion message.
    for (var i = 0; i < 10; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      if (find.byType(SnackBar).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  }

  void mockNativeSync(Map<String, Object> Function(List<Object?>) respond) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') {
        return true;
      }
      return respond((call.arguments as Map)['courses'] as List<Object?>);
    });
  }

  Future<void> enableBoth(List<CourseSession> sessions) async {
    await repository.saveCachedSchedule(_schedule(sessions));
    await repository.setCurrentWeek(1, now: anchorMonday);
    await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
        enabled: true,
        liveActivityEnabled: true,
        leadMinutes: 20,
      ),
    );
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    repository = AcademicScheduleRepository(
      apiClient: _UnusedAcademicScheduleApiClient(),
    );
    notifications = AcademicScheduleNotificationService(
      repository: repository,
      liveActivityChannel: channel,
    );
    scheduledNotifications = [];
    cancelledNotifications = [];
    pendingNotifications = [];
    messenger.setMockMethodCallHandler(alarmChannel, (_) async => false);
    messenger.setMockMethodCallHandler(notificationChannel, (call) async {
      switch (call.method) {
        case 'initialize':
        case 'requestPermissions':
          return true;
        case 'checkPermissions':
          return {'isEnabled': true};
        case 'pendingNotificationRequests':
          return pendingNotifications;
        case 'zonedSchedule':
          scheduledNotifications.add(call.arguments as Map<Object?, Object?>);
        case 'cancel':
          cancelledNotifications.add(call.arguments as int);
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(alarmChannel, null);
    messenger.setMockMethodCallHandler(notificationChannel, null);
  });

  test('plans occurrences in Shanghai time with the shared lead', () async {
    await enableBoth([_session()]);
    late Map<Object?, Object?> course;
    mockNativeSync((courses) {
      course = courses.single! as Map<Object?, Object?>;
      return {'activitiesEnabled': true, 'scheduledOccurrenceIDs': <String>[]};
    });

    await notifications.syncScheduleReminders(now: now);
    DateTime instant(String key) =>
        DateTime.fromMillisecondsSinceEpoch(course[key]! as int, isUtc: true);

    expect(instant('startsAt'), DateTime.utc(2100, 1, 4));
    expect(instant('visibleFrom'), DateTime.utc(2100, 1, 3, 23, 40));
    expect(instant('expiresAt'), DateTime.utc(2100, 1, 4, 0, 5));
  });

  test('only unaccepted courses fall back to ordinary notifications', () async {
    await enableBoth([
      for (var section = 1; section <= 7; section++)
        _session(id: 'session-$section', start: section, end: section),
    ]);
    // The system accepts only the first two activities.
    mockNativeSync((courses) => {
          'activitiesEnabled': true,
          'scheduledOccurrenceIDs': [
            for (final course in courses.take(2))
              (course! as Map)['occurrenceID'] as String,
          ],
        });

    expect(await notifications.syncScheduleReminders(now: now), 5);
    expect(scheduledNotifications.map((item) => item['payload']), [
      for (var section = 3; section <= 7; section++) 'course:session-$section',
    ]);
    expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
  });

  test('courses beyond the live planning queue still get ordinary reminders',
      () async {
    await enableBoth([
      for (var weekday = 1; weekday <= 7; weekday++)
        for (var section = 1; section <= 7; section++)
          _session(
            id: 'session-$weekday-$section',
            weekday: weekday,
            start: section,
            end: section,
            weeks: const [1, 2],
          ),
    ]);
    late List<Object?> planned;
    mockNativeSync((courses) {
      planned = courses;
      return {
        'activitiesEnabled': true,
        'scheduledOccurrenceIDs': [
          for (final course in courses) (course! as Map)['occurrenceID'],
        ],
      };
    });
    // There are 98 occurrences across two weeks, of which 64 are accepted.
    expect(await notifications.syncScheduleReminders(now: now), 34);
    expect(planned, hasLength(64));
    final starts =
        planned.map((course) => (course! as Map)['startsAt'] as int).toList();
    expect(starts, orderedEquals([...starts]..sort()));
    expect(scheduledNotifications, hasLength(34));
  });

  test('reservation is matched by occurrence rather than recurring session',
      () async {
    await enableBoth([
      _session(weeks: const [1, 2])
    ]);
    mockNativeSync((courses) => {
          'activitiesEnabled': true,
          'scheduledOccurrenceIDs': [(courses.first! as Map)['occurrenceID']],
        });

    expect(await notifications.syncScheduleReminders(now: now), 1);
    expect(scheduledNotifications.single['payload'], 'course:session');
    expect(scheduledNotifications.single['scheduledDateTime'],
        contains('2100-01-11'));
  });

  test('a later successful reservation removes its fallback notification',
      () async {
    await enableBoth([_session()]);
    mockNativeSync((_) => {
          'activitiesEnabled': true,
          'scheduledOccurrenceIDs': <String>[],
        });
    expect(await notifications.syncScheduleReminders(now: now), 1);
    pendingNotifications = [
      {'id': 420000, 'title': '课程', 'body': '', 'payload': 'course:session'},
    ];
    scheduledNotifications.clear();
    mockNativeSync((courses) => {
          'activitiesEnabled': true,
          'scheduledOccurrenceIDs': [(courses.single! as Map)['occurrenceID']],
        });

    expect(await notifications.syncScheduleReminders(now: now), 0);
    expect(cancelledNotifications, [420000]);
    expect(scheduledNotifications, isEmpty);
    expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
  });

  test('turning the parent reminder off clears live plans and notifications',
      () async {
    await enableBoth([_session()]);
    final saved = await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
        enabled: false,
        liveActivityEnabled: true,
        leadMinutes: 20,
      ),
    );
    expect(saved.liveActivityEnabled, isFalse);
    late Map<Object?, Object?> sync;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      sync = call.arguments as Map<Object?, Object?>;
      return {'activitiesEnabled': true, 'scheduledOccurrenceIDs': <String>[]};
    });
    messenger.setMockMethodCallHandler(notificationChannel, (call) async {
      if (call.method == 'pendingNotificationRequests') {
        return [
          {'id': 420000, 'title': '课程', 'body': '', 'payload': ''}
        ];
      }
      if (call.method == 'cancel') {
        cancelledNotifications.add(call.arguments as int);
      }
      return null;
    });
    expect(await notifications.syncScheduleReminders(now: now), 0);
    expect(sync['enabled'], isFalse);
    expect(sync['courses'], isEmpty);
    expect(cancelledNotifications, [420000]);
    expect((await notifications.loadSettings()).liveActivityEnabled, isFalse);
  });

  test('legacy live-only settings are inactive while the parent is off',
      () async {
    SharedPreferences.setMockInitialValues({
      'academic.schedule.notifications.enabled': false,
      'academic.schedule.liveActivity.enabled': true,
    });
    expect((await notifications.loadSettings()).liveActivityEnabled, isFalse);
  });

  test('native failure uses ordinary reminders without disabling live mode',
      () async {
    await enableBoth([_session()]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') return true;
      throw PlatformException(code: 'sync_failed');
    });
    expect(await notifications.syncScheduleReminders(now: now), 1);
    expect(scheduledNotifications.single['payload'], 'course:session');
    expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
  });

  test('turning live mode off restores ordinary notifications', () async {
    await enableBoth([_session()]);
    await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
          enabled: true, leadMinutes: 20),
    );
    mockNativeSync((courses) {
      expect(courses, isEmpty);
      return {'activitiesEnabled': true, 'scheduledOccurrenceIDs': <String>[]};
    });
    expect(await notifications.syncScheduleReminders(now: now), 1);
    expect(scheduledNotifications.single['payload'], 'course:session');
  });

  test(
      'support probe failure does not block synchronization or change live mode',
      () async {
    await enableBoth([_session()]);
    var synchronized = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') {
        throw PlatformException(code: 'availability_failed');
      }
      synchronized = true;
      return {
        'activitiesEnabled': true,
        'scheduledOccurrenceIDs': [
          for (final course in (call.arguments as Map)['courses'] as List)
            (course as Map)['occurrenceID'],
        ],
      };
    });

    expect(await notifications.supportsCourseLiveActivities(), isFalse);
    expect(await notifications.syncScheduleReminders(now: now), 0);
    expect(synchronized, isTrue);
    expect(scheduledNotifications, isEmpty);
    expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
  });

  test('a missing native implementation disables live mode', () async {
    await enableBoth([_session()]);
    messenger.setMockMethodCallHandler(channel, null);

    expect(await notifications.supportsCourseLiveActivities(), isFalse);
    expect(await notifications.syncScheduleReminders(now: now), 1);
    expect((await notifications.loadSettings()).liveActivityEnabled, isFalse);
  });

  test('an older sync cannot rearm activities after the parent is turned off',
      () async {
    await enableBoth([_session()]);
    final synchronizing = Completer<void>();
    final releaseSync = Completer<void>();
    final nativeSyncs = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (!synchronizing.isCompleted) {
        synchronizing.complete();
        await releaseSync.future;
      }
      nativeSyncs.add(call.arguments as Map<Object?, Object?>);
      return {'activitiesEnabled': true};
    });

    final olderSync = notifications.syncScheduleReminders(now: now);
    await synchronizing.future;
    await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
          enabled: false, leadMinutes: 20),
    );
    final disableSync = notifications.syncScheduleReminders(now: now);
    releaseSync.complete();
    await Future.wait([olderSync, disableSync]);

    expect(nativeSyncs.last['enabled'], isFalse);
    expect(nativeSyncs.last['courses'], isEmpty);
    expect(scheduledNotifications, isEmpty);
  });

  test('disabled system Live Activities fall back to regular reminders',
      () async {
    await enableBoth([_session()]);
    mockNativeSync((_) => {
          'activitiesEnabled': false,
          'scheduledOccurrenceIDs': <String>[],
        });

    expect(await notifications.syncScheduleReminders(now: now), 1);
    expect((await notifications.loadSettings()).liveActivityEnabled, isFalse);
  });

  test('an old disallowed response cannot restore the parent reminder',
      () async {
    await enableBoth([_session()]);
    final synchronizing = Completer<void>();
    final releaseSync = Completer<void>();
    final nativeSyncs = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (!synchronizing.isCompleted) {
        synchronizing.complete();
        await releaseSync.future;
      }
      nativeSyncs.add(call.arguments as Map<Object?, Object?>);
      return {'activitiesEnabled': false};
    });

    final olderSync = notifications.syncScheduleReminders(now: now);
    await synchronizing.future;
    await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
          enabled: false, leadMinutes: 30),
    );
    final disableSync = notifications.syncScheduleReminders(now: now);
    releaseSync.complete();
    await Future.wait([olderSync, disableSync]);

    expect(nativeSyncs.last['enabled'], isFalse);
    expect(nativeSyncs.last['courses'], isEmpty);
    expect(scheduledNotifications, isEmpty);
    final settings = await notifications.loadSettings();
    expect(settings.enabled, isFalse);
    expect(settings.leadMinutes, 30);
  });

  test('an old disallowed response cannot clear a newer live opt-in',
      () async {
    await enableBoth([_session()]);
    final synchronizing = Completer<void>();
    final releaseSync = Completer<void>();
    final nativeSyncs = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      nativeSyncs.add(arguments);
      if (!synchronizing.isCompleted) {
        synchronizing.complete();
        await releaseSync.future;
        return {'activitiesEnabled': false};
      }
      return {
        'activitiesEnabled': true,
        'scheduledOccurrenceIDs': [
          for (final course in arguments['courses'] as List)
            (course as Map)['occurrenceID'],
        ],
      };
    });

    final olderSync = notifications.syncScheduleReminders(now: now);
    await synchronizing.future;
    await notifications.saveSettings(
      const AcademicScheduleNotificationSettings(
        enabled: true,
        liveActivityEnabled: true,
        leadMinutes: 30,
      ),
    );
    final newerSync = notifications.syncScheduleReminders(now: now);
    releaseSync.complete();
    await Future.wait([olderSync, newerSync]);

    expect(nativeSyncs.last['enabled'], isTrue);
    expect(nativeSyncs.last['courses'], hasLength(1));
    final settings = await notifications.loadSettings();
    expect(settings.enabled, isTrue);
    expect(settings.liveActivityEnabled, isTrue);
    expect(settings.leadMinutes, 30);
  });

  testWidgets('saving after a failed support probe preserves live mode',
      (tester) async {
    await enableBoth([_session()]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isAvailable') {
        throw PlatformException(code: 'availability_failed');
      }
      return {'activitiesEnabled': true, 'scheduledOccurrenceIDs': <String>[]};
    });
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: AcademicSchedulePage(
        repository: repository,
        notificationService: notifications,
        widgetService: AcademicScheduleWidgetService(repository: repository),
        onLoginRequired: () async {},
        initialState: await repository.loadCachedState(now: anchorMonday),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通知设置'));
    await tester.pumpAndSettle();
    expect(find.text('课程实时活动'), findsNothing);
    await saveSettingsSheet(tester);
    expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'live switch depends on parent and has its own information button',
      (tester) async {
    try {
      mockNativeSync((_) => {
            'activitiesEnabled': true,
            'scheduledOccurrenceIDs': <String>[],
          });
      await repository.saveCachedSchedule(_schedule([_session()]));
      await repository.setCurrentWeek(1, now: anchorMonday);
      await tester.pumpWidget(MaterialApp(
        theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
        home: AcademicSchedulePage(
          repository: repository,
          notificationService: notifications,
          widgetService: AcademicScheduleWidgetService(repository: repository),
          onLoginRequired: () async {},
          initialState: await repository.loadCachedState(now: anchorMonday),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知设置'));
      await tester.pumpAndSettle();

      expect(find.text('课程开始前提醒'), findsOneWidget);

      expect(find.text('课程实时活动'), findsNothing);
      expect(find.byTooltip('实时活动说明'), findsNothing);
      await tester.tap(find.byTooltip('提醒说明'));
      await tester.pumpAndSettle();
      expect(find.text('课程提醒说明'), findsOneWidget);
      expect(
          find.text(
              '系统最多同时保留 64 条最近的课程提醒。打开 ShuYo 后，应用会自动补充后续提醒。\n\n因此记得时不时上线一下哦~'),
          findsOneWidget);
      expect(find.textContaining('实时活动创建失败的课程仍使用普通课程通知'), findsNothing);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('课程开始前提醒'));
      await tester.pumpAndSettle();
      expect(find.text('课程实时活动'), findsOneWidget);
      await tester.tap(find.byTooltip('实时活动说明'));
      await tester.pumpAndSettle();
      expect(find.text('课程实时活动说明'), findsOneWidget);
      expect(find.textContaining('实时活动创建失败的课程仍使用普通课程通知'), findsOneWidget);
      expect(find.textContaining('打开 ShuYo 后，应用会自动补充后续课程的实时活动预约。'),
          findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SwitchListTile>(
                  find.widgetWithText(SwitchListTile, '课程实时活动'))
              .value,
          isFalse);
      await tester.tap(find.text('课程实时活动'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SwitchListTile>(
                  find.widgetWithText(SwitchListTile, '课程实时活动'))
              .value,
          isTrue);

      await saveSettingsSheet(tester);
      expect((await notifications.loadSettings()).liveActivityEnabled, isTrue);
      expect(find.textContaining('课程实时活动已开启，提前 20 分钟显示'), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知设置'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('课程开始前提醒'));
      await tester.pumpAndSettle();
      expect(find.text('课程实时活动'), findsNothing);
      await tester.tap(find.text('课程开始前提醒'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<SwitchListTile>(
                  find.widgetWithText(SwitchListTile, '课程实时活动'))
              .value,
          isFalse);

      await tester.tap(find.text('课程开始前提醒'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = await notifications.loadSettings();
      expect(saved.enabled, isFalse);
      expect(saved.liveActivityEnabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

AcademicSchedule _schedule(List<CourseSession> sessions) => AcademicSchedule(
      term: const AcademicTerm(
        yearCode: '2026',
        termCode: '3',
        academicYearName: '2026-2027',
        termName: '秋',
        studentName: '',
        studentId: '',
        className: '',
      ),
      sessions: sessions,
      untimedCourses: const [],
      fetchedAt: DateTime(2100, 1, 1),
    );

CourseSession _session({
  String id = 'session',
  int start = 1,
  int end = 2,
  int weekday = DateTime.monday,
  List<int> weeks = const [1],
}) =>
    CourseSession(
      id: id,
      courseName: '高等数学',
      courseCode: '',
      teacherName: '',
      campus: '宝山',
      location: 'D101',
      weekday: weekday,
      startSection: start,
      endSection: end,
      sections: [start, end],
      weeks: weeks,
      weekText: '',
      credit: '',
      note: '',
    );

class _UnusedAcademicScheduleApiClient implements AcademicScheduleApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Network access was not expected');
}
