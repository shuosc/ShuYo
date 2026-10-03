import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import '../models/academic_schedule.dart';
import '../repositories/academic_schedule_repository.dart';

class AcademicScheduleNotificationSettings {
  const AcademicScheduleNotificationSettings({
    required this.enabled,
    required this.leadMinutes,
    this.liveActivityEnabled = false,
  });

  final bool enabled;
  final int leadMinutes;
  final bool liveActivityEnabled;

  AcademicScheduleNotificationSettings copyWith({
    bool? enabled,
    int? leadMinutes,
    bool? liveActivityEnabled,
  }) {
    return AcademicScheduleNotificationSettings(
      enabled: enabled ?? this.enabled,
      leadMinutes: leadMinutes ?? this.leadMinutes,
      liveActivityEnabled: liveActivityEnabled ?? this.liveActivityEnabled,
    );
  }
}

class AcademicScheduleAlarmSettings {
  const AcademicScheduleAlarmSettings({
    required this.enabled,
    required this.leadMinutes,
    this.vibrationEnabled = false,
  });

  final bool enabled;
  final int leadMinutes;
  final bool vibrationEnabled;

  AcademicScheduleAlarmSettings copyWith({
    bool? enabled,
    int? leadMinutes,
    bool? vibrationEnabled,
  }) {
    return AcademicScheduleAlarmSettings(
      enabled: enabled ?? this.enabled,
      leadMinutes: leadMinutes ?? this.leadMinutes,
      vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
    );
  }
}

class AcademicScheduleNotificationService {
  AcademicScheduleNotificationService({
    required AcademicScheduleRepository repository,
    Future<SharedPreferences> Function()? preferencesLoader,
    FlutterLocalNotificationsPlugin? notifications,
    MethodChannel? alarmChannel,
    MethodChannel? liveActivityChannel,
  })  : _repository = repository,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _notifications = notifications ?? FlutterLocalNotificationsPlugin(),
        _alarmChannel = alarmChannel ??
            const MethodChannel('work.shuyo.app/early_class_alarms'),
        _liveActivityChannel = liveActivityChannel ??
            const MethodChannel('work.shuyo.app/course_live_activity');

  static const _enabledKey = 'academic.schedule.notifications.enabled';
  static const _leadMinutesKey = 'academic.schedule.notifications.leadMinutes';
  static const _liveActivityEnabledKey =
      'academic.schedule.liveActivity.enabled';
  static const _alarmEnabledKey = 'academic.schedule.alarms.enabled';
  static const _alarmLeadMinutesKey = 'academic.schedule.alarms.leadMinutes';
  static const _alarmVibrationEnabledKey =
      'academic.schedule.alarms.vibrationEnabled';
  static const _channelId = 'course_reminders';
  static const _baseNotificationId = 420000;
  static const _maxPendingReminders = 64;
  static const _maxLiveActivities = 64;
  // Keeps a just-started course so a resume can update its activity.
  static const _liveActivityRetention = Duration(minutes: 5);

  final AcademicScheduleRepository _repository;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final FlutterLocalNotificationsPlugin _notifications;
  final MethodChannel _alarmChannel;
  final MethodChannel _liveActivityChannel;
  bool _initialized = false;
  int _settingsRevision = 0;
  Future<void> _reminderSync = Future<void>.value();

  Future<AcademicScheduleNotificationSettings> loadSettings() async {
    final prefs = await _preferencesLoader();
    final enabled = prefs.getBool(_enabledKey) ?? false;
    return AcademicScheduleNotificationSettings(
      // Keep reminders disabled until the user turns them on manually.
      enabled: enabled,
      leadMinutes: prefs.getInt(_leadMinutesKey) ?? 20,
      liveActivityEnabled:
          enabled && (prefs.getBool(_liveActivityEnabledKey) ?? false),
    );
  }

  Future<AcademicScheduleNotificationSettings> saveSettings(
    AcademicScheduleNotificationSettings settings,
  ) async {
    _settingsRevision++;
    final prefs = await _preferencesLoader();
    final normalized = settings.copyWith(
      leadMinutes: settings.leadMinutes.clamp(15, 120),
      liveActivityEnabled: settings.enabled && settings.liveActivityEnabled,
    );
    await prefs.setBool(_enabledKey, normalized.enabled);
    await prefs.setInt(_leadMinutesKey, normalized.leadMinutes);
    await prefs.setBool(
        _liveActivityEnabledKey, normalized.liveActivityEnabled);
    return normalized;
  }

  Future<AcademicScheduleNotificationSettings> saveSettingsAndSync(
    AcademicScheduleNotificationSettings settings, {
    bool requestPermission = false,
  }) async {
    var next = settings;
    if (next.enabled) {
      final notificationAllowed = await _ensureNotificationPermission(
        request: requestPermission,
      );
      final exactAllowed = notificationAllowed &&
          await _ensureExactAlarmPermission(request: requestPermission);
      if (!notificationAllowed || !exactAllowed) {
        next = next.copyWith(enabled: false);
      }
    }
    await saveSettings(next);
    await syncScheduleReminders(requestPermission: false);
    // Syncing turns Live Activities off when the system disallows them.
    return loadSettings();
  }

  Future<bool> supportsCourseLiveActivities() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    try {
      return await _liveActivityChannel.invokeMethod<bool>('isAvailable') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Set<String>> _syncCourseLiveActivities(DateTime now) async {
    final settingsRevision = _settingsRevision;
    final settings = await loadSettings();
    final enabled = settings.liveActivityEnabled;
    final supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final courses = enabled && supported
        ? await _upcomingLiveActivities(settings.leadMinutes, now)
        : const <Object>[];
    Map<String, Object?>? response;
    if (supported) {
      try {
        response = await _liveActivityChannel
            .invokeMapMethod<String, Object?>('sync', {
          'enabled': enabled,
          'courses': courses,
        });
      } on MissingPluginException {
        // A missing native implementation is unsupported, not a retryable
        // ActivityKit failure.
      }
    }
    // Unsupported platform, missing native implementation, and a disallowed
    // system all fall back to ordinary reminders through this single write.
    if (enabled && response?['activitiesEnabled'] != true) {
      final prefs = await _preferencesLoader();
      // An older native response must not overwrite settings saved while this
      // sync was awaiting ActivityKit. The next queued sync uses those settings.
      if (settingsRevision == _settingsRevision) {
        await prefs.setBool(_liveActivityEnabledKey, false);
      }
    }
    if (!enabled || response?['activitiesEnabled'] != true) {
      return const <String>{};
    }
    return (response?['scheduledOccurrenceIDs'] as List? ?? const [])
        .whereType<String>()
        .toSet();
  }

  Future<bool> supportsEarlyClassAlarms() async {
    if (kIsWeb) {
      return false;
    }
    try {
      return await _alarmChannel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  bool get supportsAlarmRingtoneCustomization =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> loadAlarmRingtoneName() async {
    if (!supportsAlarmRingtoneCustomization) {
      return null;
    }
    try {
      final value = await _alarmChannel.invokeMethod<Map<Object?, Object?>>(
        'getRingtone',
      );
      return value?['name']?.toString();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String?> pickAlarmRingtone() async {
    if (!supportsAlarmRingtoneCustomization) {
      return null;
    }
    final value = await _alarmChannel.invokeMethod<Map<Object?, Object?>>(
      'pickRingtone',
    );
    return value?['name']?.toString();
  }

  Future<AcademicScheduleAlarmSettings> loadAlarmSettings() async {
    final prefs = await _preferencesLoader();
    return AcademicScheduleAlarmSettings(
      enabled: prefs.getBool(_alarmEnabledKey) ?? false,
      leadMinutes: prefs.getInt(_alarmLeadMinutesKey) ?? 20,
      vibrationEnabled: prefs.getBool(_alarmVibrationEnabledKey) ?? false,
    );
  }

  Future<AcademicScheduleAlarmSettings> saveAlarmSettings(
    AcademicScheduleAlarmSettings settings,
  ) async {
    final prefs = await _preferencesLoader();
    final normalized = settings.copyWith(
      leadMinutes: settings.leadMinutes.clamp(15, 120),
    );
    await prefs.setBool(_alarmEnabledKey, normalized.enabled);
    await prefs.setInt(_alarmLeadMinutesKey, normalized.leadMinutes);
    await prefs.setBool(
      _alarmVibrationEnabledKey,
      normalized.vibrationEnabled,
    );
    return normalized;
  }

  Future<AcademicScheduleAlarmSettings> saveAlarmSettingsAndSync(
    AcademicScheduleAlarmSettings settings, {
    bool requestPermission = false,
  }) async {
    var next = settings;
    if (next.enabled && requestPermission) {
      final allowed =
          await _alarmChannel.invokeMethod<bool>('requestAuthorization') ??
              false;
      if (!allowed) {
        next = next.copyWith(enabled: false);
      }
    }
    await saveAlarmSettings(next);
    await syncEarlyClassAlarms();
    return loadAlarmSettings();
  }

  Future<int> syncEarlyClassAlarms({DateTime? now}) async {
    if (!await supportsEarlyClassAlarms()) {
      return 0;
    }
    await _ensureInitialized();
    final settings = await loadAlarmSettings();
    final schedule =
        settings.enabled ? await _repository.loadCachedSchedule() : null;
    final alarms = <_EarlyClassAlarm>[];
    if (schedule != null) {
      final weekState = await _repository.loadWeekState();
      alarms.addAll(
        _upcomingEarlyClassAlarms(
          schedule: schedule,
          weekState: weekState,
          leadMinutes: settings.leadMinutes,
          vibrationEnabled: settings.vibrationEnabled,
          now: now ?? DateTime.now(),
        ),
      );
    }
    final count = await _alarmChannel.invokeMethod<int>('sync', {
          'alarms': alarms.map((alarm) => alarm.toMap()).toList(),
        }) ??
        0;
    if (count < 0) {
      if (settings.enabled) {
        await saveAlarmSettings(settings.copyWith(enabled: false));
      }
      return 0;
    }
    return count;
  }

  Future<int> syncScheduleReminders(
      {bool requestPermission = false, DateTime? now}) async {
    final operation = _reminderSync.then((_) => _syncScheduleReminders(
          requestPermission: requestPermission,
          now: now,
        ));
    // Serialize edits and settings changes; an older sync must not rearm a
    // reminder after a newer request has cancelled it.
    _reminderSync = operation.then<void>((_) {}, onError: (Object error) {});
    return operation;
  }

  Future<int> _syncScheduleReminders(
      {required bool requestPermission, DateTime? now}) async {
    final instant = now ?? DateTime.now();
    try {
      await syncEarlyClassAlarms();
    } on PlatformException {
      // Local notification syncing remains independent of AlarmKit.
    }
    await _ensureInitialized();
    var liveActivityOccurrences = const <String>{};
    try {
      liveActivityOccurrences = await _syncCourseLiveActivities(instant);
    } on PlatformException {
      // Keep Live Activities enabled for retry, and use ordinary reminders until
      // the native implementation confirms which courses it has reserved.
    }
    await _cancelCourseReminders();

    final settings = await loadSettings();
    if (!settings.enabled) {
      return 0;
    }
    final allowed = await _ensureNotificationPermission(
      request: requestPermission,
    );
    if (!allowed) {
      return 0;
    }
    final exactAllowed = await _ensureExactAlarmPermission(
      request: requestPermission,
    );
    if (!exactAllowed) {
      return 0;
    }

    final schedule = await _repository.loadCachedSchedule();
    if (schedule == null) {
      return 0;
    }
    final weekState = await _repository.loadWeekState(
        now: timezone.TZDateTime.from(instant, timezone.local));
    final reminders = _upcomingReminders(
      schedule: schedule,
      weekState: weekState,
      leadMinutes: settings.leadMinutes,
      now: instant,
    )
        .where((reminder) =>
            !liveActivityOccurrences.contains(reminder.occurrenceID))
        .take(_maxPendingReminders)
        .toList();

    for (var index = 0; index < reminders.length; index++) {
      final reminder = reminders[index];
      await _notifications.zonedSchedule(
        id: _baseNotificationId + index,
        title: reminder.session.courseName,
        body: reminder.body(settings.leadMinutes),
        scheduledDate: timezone.TZDateTime.from(
          reminder.fireTime,
          timezone.local,
        ),
        notificationDetails: _notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'course:${reminder.session.id}',
      );
    }
    return reminders.length;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    timezone_data.initializeTimeZones();
    timezone.setLocalLocation(timezone.getLocation('Asia/Shanghai'));
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
    );
    _initialized = true;
  }

  Future<bool> _ensureNotificationPermission({required bool request}) async {
    await _ensureInitialized();
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final androidEnabled = await android?.areNotificationsEnabled();
    if (androidEnabled == false && request) {
      final granted = await android?.requestNotificationsPermission();
      if (granted == false) {
        return false;
      }
    } else if (androidEnabled == false) {
      return false;
    }

    final ios = _notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      if (!request) {
        final permissions = await ios.checkPermissions();
        if (permissions?.isEnabled == false) {
          return false;
        }
      } else {
        final iosGranted = await ios.requestPermissions(
          alert: true,
          sound: true,
        );
        if (iosGranted == false) {
          return false;
        }
      }
    }

    if (request) {
      final macOS = _notifications.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      final macOSGranted = await macOS?.requestPermissions(
        alert: true,
        sound: true,
      );
      if (macOSGranted == false) {
        return false;
      }
    }

    return true;
  }

  Future<bool> _ensureExactAlarmPermission({required bool request}) async {
    await _ensureInitialized();
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final canScheduleExact = await android?.canScheduleExactNotifications();
    if (canScheduleExact == false && request) {
      final granted = await android?.requestExactAlarmsPermission();
      if (granted == false) {
        return false;
      }
    } else if (canScheduleExact == false) {
      return false;
    }
    return true;
  }

  Future<void> _cancelCourseReminders() async {
    final pending = await _notifications.pendingNotificationRequests();
    for (final request in pending) {
      final isCourseReminder = request.id >= _baseNotificationId &&
          request.id < _baseNotificationId + _maxPendingReminders;
      if (isCourseReminder) {
        await _notifications.cancel(id: request.id);
      }
    }
  }

  Iterable<_EarlyClassAlarm> _upcomingEarlyClassAlarms({
    required AcademicSchedule schedule,
    required ScheduleWeekState weekState,
    required int leadMinutes,
    required bool vibrationEnabled,
    required DateTime now,
  }) sync* {
    for (final day in _upcomingCourseDays(schedule, weekState, now)) {
      final earliest =
          day.where((course) => course.start.hour < 12).firstOrNull;
      if (earliest == null) {
        continue;
      }
      final session = earliest.session;
      final fireTime = earliest.start.subtract(Duration(minutes: leadMinutes));
      if (fireTime.isAfter(now.add(const Duration(seconds: 30)))) {
        yield _EarlyClassAlarm(
          id: earliest.id,
          title: session.courseName.isEmpty ? '早课' : session.courseName,
          fireTime: fireTime,
          courseTime: earliest.start,
          courseEndTime: earliest.end,
          sectionText: session.sectionText,
          campus: session.campus,
          location: session.location,
          teacherName: session.teacherName,
          vibrationEnabled: vibrationEnabled,
        );
      }
    }
  }

  Iterable<_CourseReminder> _upcomingReminders({
    required AcademicSchedule schedule,
    required ScheduleWeekState weekState,
    required int leadMinutes,
    required DateTime now,
  }) {
    return _upcomingCourseDays(schedule, weekState, now)
        .expand((day) => day)
        .map((course) => _CourseReminder(
              occurrenceID: course.id,
              session: course.session,
              fireTime: course.start.subtract(Duration(minutes: leadMinutes)),
            ))
        .where((reminder) =>
            reminder.fireTime.isAfter(now.add(const Duration(seconds: 30))));
  }

  Future<List<Map<String, Object>>> _upcomingLiveActivities(
    int leadMinutes,
    DateTime now,
  ) async {
    final schedule = await _repository.loadCachedSchedule();
    if (schedule == null) {
      return const [];
    }
    final weekState = await _repository.loadWeekState(
        now: timezone.TZDateTime.from(now, timezone.local));
    return _upcomingCourseDays(schedule, weekState, now)
        .expand((day) => day)
        .where((course) =>
            course.end != null &&
            course.start.add(_liveActivityRetention).isAfter(now))
        .take(_maxLiveActivities)
        .map((course) => {
              'occurrenceID': course.id,
              'courseName': course.session.courseName.isEmpty
                  ? '课程'
                  : course.session.courseName,
              'location': course.session.location.isEmpty
                  ? '地点待定'
                  : course.session.location,
              'campus': course.session.campus,
              'startsAt': course.start.millisecondsSinceEpoch,
              'endsAt': course.end!.millisecondsSinceEpoch,
              'visibleFrom': course.start
                  .subtract(Duration(minutes: leadMinutes))
                  .millisecondsSinceEpoch,
              'expiresAt': course.start
                  .add(_liveActivityRetention)
                  .millisecondsSinceEpoch,
            })
        .toList();
  }

  /// Course occurrences in Shanghai time, by teaching day from today, sorted
  /// by start time.
  Iterable<List<_CourseOccurrence>> _upcomingCourseDays(
    AcademicSchedule schedule,
    ScheduleWeekState weekState,
    DateTime now,
  ) sync* {
    final shanghaiNow = timezone.TZDateTime.from(now, timezone.local);
    // Calendar arithmetic uses UTC dates to avoid the device's timezone/DST.
    final today =
        DateTime.utc(shanghaiNow.year, shanghaiNow.month, shanghaiNow.day);
    final maxDays = schedule.maxWeek * 7 + 7;
    for (var dayOffset = 0; dayOffset < maxDays; dayOffset++) {
      final day = today.add(Duration(days: dayOffset));
      final week = weekState.weekForDate(day);
      if (week < 1) {
        continue;
      }
      if (schedule.isVacationWeek(week)) {
        break;
      }
      timezone.TZDateTime at(int hour, int minute) => timezone.TZDateTime(
          timezone.local, day.year, day.month, day.day, hour, minute);
      final courses = <_CourseOccurrence>[];
      for (final session in schedule.sessions) {
        final startRange =
            AcademicScheduleRepository.sectionTimes[session.startSection];
        if (session.weekday != day.weekday ||
            !session.occursInWeek(week) ||
            startRange == null) {
          continue;
        }
        final endRange =
            AcademicScheduleRepository.sectionTimes[session.endSection];
        courses.add(_CourseOccurrence(
          session: session,
          start: at(startRange.$1, startRange.$2),
          end: endRange == null ? null : at(endRange.$3, endRange.$4),
        ));
      }
      yield courses..sort((a, b) => a.start.compareTo(b.start));
    }
  }

  static const _notificationDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      '课程提醒',
      channelDescription: '在课程开始前提醒',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );
}

class _CourseOccurrence {
  const _CourseOccurrence({
    required this.session,
    required this.start,
    required this.end,
  });

  final CourseSession session;
  final DateTime start;
  final DateTime? end;

  String get id => '${session.id}-${start.millisecondsSinceEpoch}';
}

class _CourseReminder {
  const _CourseReminder({
    required this.occurrenceID,
    required this.session,
    required this.fireTime,
  });

  final String occurrenceID;
  final CourseSession session;
  final DateTime fireTime;

  String body(int leadMinutes) {
    final location = session.placeText.isEmpty ? '' : ' · ${session.placeText}';
    return '$leadMinutes 分钟后开始$location';
  }
}

class _EarlyClassAlarm {
  const _EarlyClassAlarm({
    required this.id,
    required this.title,
    required this.fireTime,
    required this.courseTime,
    required this.courseEndTime,
    required this.sectionText,
    required this.campus,
    required this.location,
    required this.teacherName,
    required this.vibrationEnabled,
  });

  final String id;
  final String title;
  final DateTime fireTime;
  final DateTime courseTime;
  final DateTime? courseEndTime;
  final String sectionText;
  final String campus;
  final String location;
  final String teacherName;
  final bool vibrationEnabled;

  Map<String, Object> toMap() => {
        'id': id,
        'title': title,
        'fireTime': fireTime.millisecondsSinceEpoch,
        'courseTime': courseTime.millisecondsSinceEpoch,
        if (courseEndTime != null)
          'courseEndTime': courseEndTime!.millisecondsSinceEpoch,
        'sectionText': sectionText,
        'campus': campus,
        'location': location,
        'teacherName': teacherName,
        'vibrationEnabled': vibrationEnabled,
      };
}
