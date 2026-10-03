import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/academic_schedule.dart';
import '../services/academic_account_store.dart';
import '../services/academic_schedule_api_client.dart';

class ScheduleWeekState {
  const ScheduleWeekState({
    required this.currentWeek,
    required this.anchorMonday,
  });

  final int currentWeek;
  final DateTime anchorMonday;

  /// Returns the unclamped teaching week for the date's calendar fields.
  ///
  /// UTC dates are used only for calendar arithmetic, not to convert either
  /// value's instant or timezone. This keeps whole weeks stable across DST.
  int weekForDate(DateTime date) {
    final day = DateTime.utc(date.year, date.month, date.day);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final anchor =
        DateTime.utc(anchorMonday.year, anchorMonday.month, anchorMonday.day);
    return currentWeek + monday.difference(anchor).inDays ~/ 7;
  }

  DateTime get firstWeekStart =>
      anchorMonday.subtract(Duration(days: (currentWeek - 1) * 7));
}

class ScheduleHomeSummary {
  const ScheduleHomeSummary(this.text);

  final String text;
}

class AcademicScheduleCacheState {
  const AcademicScheduleCacheState({
    required this.schedule,
    required this.weekState,
  });

  final AcademicSchedule? schedule;
  final ScheduleWeekState weekState;
}

class AcademicScheduleRepository {
  AcademicScheduleRepository({
    AcademicScheduleApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _apiClient = apiClient,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const _scheduleKey = 'academic.schedule.cache';
  static const _anchorWeekKey = 'academic.schedule.anchorWeek';
  static const _anchorMondayKey = 'academic.schedule.anchorMonday';

  AcademicScheduleApiClient? _apiClient;
  AcademicScheduleApiClient get _client =>
      _apiClient ??= AcademicScheduleApiClient();
  final Future<SharedPreferences> Function() _preferencesLoader;

  Future<AcademicSchedule?> loadCachedSchedule() async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(_scheduleKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final schedule = AcademicSchedule.fromJson(decoded);
    final studentId = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadDataStudentId();
    if (studentId != null && schedule.term.studentId != studentId) return null;
    return schedule;
  }

  Future<AcademicScheduleCacheState> loadCachedState({DateTime? now}) async {
    final scheduleFuture = loadCachedSchedule();
    final weekStateFuture = loadWeekState(now: now);
    return AcademicScheduleCacheState(
      schedule: await scheduleFuture,
      weekState: await weekStateFuture,
    );
  }

  Future<AcademicSchedule> refreshSchedule() async {
    final hadCachedSchedule = await loadCachedSchedule() != null;
    final schedule = await _client.fetchCurrentSchedule();
    await saveCachedSchedule(schedule);
    if (!hadCachedSchedule) {
      await setCurrentWeek(1);
    }
    return schedule;
  }

  Future<void> saveCachedSchedule(AcademicSchedule schedule) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(_scheduleKey, jsonEncode(schedule.toJson()));
  }

  Future<ScheduleWeekState> loadWeekState({DateTime? now}) async {
    final prefs = await _preferencesLoader();
    final today = now ?? DateTime.now();
    final fallbackMonday = startOfWeek(today);
    return ScheduleWeekState(
      currentWeek: prefs.getInt(_anchorWeekKey) ?? 1,
      anchorMonday: DateTime.tryParse(
            prefs.getString(_anchorMondayKey) ?? '',
          ) ??
          fallbackMonday,
    );
  }

  Future<void> setCurrentWeek(int week, {DateTime? now}) async {
    final prefs = await _preferencesLoader();
    await prefs.setInt(_anchorWeekKey, week);
    await prefs.setString(
      _anchorMondayKey,
      startOfWeek(now ?? DateTime.now()).toIso8601String(),
    );
  }

  Future<void> setFirstWeekStart(DateTime date) async {
    final prefs = await _preferencesLoader();
    await prefs.setInt(_anchorWeekKey, 1);
    await prefs.setString(
      _anchorMondayKey,
      startOfWeek(date).toIso8601String(),
    );
  }

  Future<int> activeWeek(AcademicSchedule schedule, {DateTime? now}) async {
    final state = await loadWeekState(now: now);
    return activeWeekFromState(schedule, state, now: now);
  }

  int activeWeekFromState(
    AcademicSchedule schedule,
    ScheduleWeekState state, {
    DateTime? now,
  }) {
    return state
        .weekForDate(now ?? DateTime.now())
        .clamp(0, schedule.vacationWeek);
  }

  DateTime dateForWeekday({
    required ScheduleWeekState state,
    required int displayedWeek,
    required int weekday,
  }) {
    return state.anchorMonday.add(
      Duration(days: (displayedWeek - state.currentWeek) * 7 + weekday - 1),
    );
  }

  Future<ScheduleHomeSummary> homeSummary({DateTime? now}) async {
    final schedule = await loadCachedSchedule();
    if (schedule == null) {
      return const ScheduleHomeSummary('点击同步教务课表');
    }
    final state = await loadWeekState(now: now);
    final week = activeWeekFromState(schedule, state, now: now);
    final text = summaryFor(schedule, week: week, now: now ?? DateTime.now());
    return ScheduleHomeSummary(text);
  }

  static DateTime startOfWeek(DateTime date) {
    final local = DateTime(date.year, date.month, date.day);
    return local.subtract(Duration(days: local.weekday - 1));
  }

  static String summaryFor(
    AcademicSchedule schedule, {
    required int week,
    required DateTime now,
  }) {
    if (schedule.isVacationWeek(week)) {
      return '假期中';
    }
    final todayCourses = schedule.sessions
        .where((course) =>
            course.weekday == now.weekday && course.occursInWeek(week))
        .toList()
      ..sort((a, b) => a.startSection.compareTo(b.startSection));
    if (todayCourses.isEmpty) {
      return '今日暂无课程';
    }

    for (final course in todayCourses) {
      final end = sectionEndTime(course.endSection, now);
      if (end == null || now.isAfter(end)) {
        continue;
      }
      final start = sectionStartTime(course.startSection, now);
      final prefix =
          start != null && !now.isBefore(start) ? '正在上课' : _timeText(start);
      final location = course.location.isEmpty ? '' : ' ${course.location}';
      return '$prefix · ${course.courseName}$location';
    }
    return '今日的课程已全部结束';
  }

  static DateTime? sectionStartTime(int section, DateTime day) {
    final range = sectionTimes[section];
    if (range == null) {
      return null;
    }
    return DateTime(day.year, day.month, day.day, range.$1, range.$2);
  }

  static DateTime? sectionEndTime(int section, DateTime day) {
    final range = sectionTimes[section];
    if (range == null) {
      return null;
    }
    return DateTime(day.year, day.month, day.day, range.$3, range.$4);
  }

  static String sectionTimeText(int section) {
    final range = sectionTimes[section];
    if (range == null) {
      return '';
    }
    return '${_pad(range.$1)}:${_pad(range.$2)}\n${_pad(range.$3)}:${_pad(range.$4)}';
  }

  static String _timeText(DateTime? value) {
    if (value == null) {
      return '下一节';
    }
    return '${_pad(value.hour)}:${_pad(value.minute)}';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static const sectionTimes = <int, (int, int, int, int)>{
    1: (8, 0, 8, 45),
    2: (8, 55, 9, 40),
    3: (10, 0, 10, 45),
    4: (10, 55, 11, 40),
    5: (13, 0, 13, 45),
    6: (13, 55, 14, 40),
    7: (15, 0, 15, 45),
    8: (15, 55, 16, 40),
    9: (18, 0, 18, 45),
    10: (18, 55, 19, 40),
    11: (20, 0, 20, 45),
    12: (20, 55, 21, 40),
  };
}
