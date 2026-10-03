import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../models/academic_schedule.dart';
import '../repositories/academic_schedule_repository.dart';

class AcademicScheduleWidgetService {
  AcademicScheduleWidgetService(
      {required AcademicScheduleRepository repository})
      : _repository = repository;

  static const snapshotKey = 'academic_schedule_widget_snapshot';
  static const iosAppGroupId = 'group.work.shuyo.app';
  static const iosWidgetKind = 'ScheduleWidget';
  static const _androidWidgetNames = [
    'ScheduleWidgetSmallProvider',
    'ScheduleWidgetProvider',
    'ScheduleWidgetLargeProvider',
  ];

  final AcademicScheduleRepository _repository;

  Future<void> syncFromCache({DateTime? now}) async {
    if (!_supportsHomeWidget) {
      return;
    }
    try {
      final schedule = await _repository.loadCachedSchedule();
      final weekState = await _repository.loadWeekState(now: now);
      await syncSchedule(schedule: schedule, weekState: weekState, now: now);
    } on Object {
      // 小组件同步不能影响 App 内课表读取。
    }
  }

  Future<void> syncSchedule({
    required AcademicSchedule? schedule,
    required ScheduleWeekState? weekState,
    DateTime? now,
  }) async {
    if (!_supportsHomeWidget) {
      return;
    }
    final snapshot = buildSnapshot(
      schedule: schedule,
      weekState: weekState,
      now: now,
    );
    try {
      await HomeWidget.saveWidgetData<String>(
        snapshotKey,
        jsonEncode(snapshot),
        appGroupId: Platform.isIOS ? iosAppGroupId : null,
      );
      if (Platform.isIOS) {
        await HomeWidget.updateWidget(iOSName: iosWidgetKind);
      } else {
        for (final widgetName in _androidWidgetNames) {
          await HomeWidget.updateWidget(
            name: widgetName,
            androidName: widgetName,
            qualifiedAndroidName: 'work.shuyo.app.$widgetName',
          );
        }
      }
    } on MissingPluginException {
      // 测试环境或不支持桌面小组件的运行时可能没有插件注册。
    } on PlatformException {
      // 系统小组件刷新失败时保留 App 内行为。
    } on Object {
      // 不让厂商桌面兼容问题影响主流程。
    }
  }

  @visibleForTesting
  static Map<String, dynamic> buildSnapshot({
    required AcademicSchedule? schedule,
    required ScheduleWeekState? weekState,
    DateTime? now,
  }) {
    final capturedAt = now ?? DateTime.now();
    if (schedule == null || weekState == null) {
      return {
        'schema': 1,
        'hasSchedule': false,
        'updatedAt': capturedAt.toIso8601String(),
      };
    }

    final activeWeek =
        weekState.weekForDate(capturedAt).clamp(0, schedule.vacationWeek);

    return {
      'schema': 1,
      'hasSchedule': true,
      'updatedAt': capturedAt.toIso8601String(),
      'fetchedAt': schedule.fetchedAt.toIso8601String(),
      'term': schedule.term.displayName,
      'maxWeek': schedule.maxWeek,
      'currentWeek': weekState.currentWeek,
      'activeWeek': activeWeek,
      'anchorMonday': weekState.anchorMonday.toIso8601String(),
      'summary': AcademicScheduleRepository.summaryFor(
        schedule,
        week: activeWeek,
        now: capturedAt,
      ),
      'sessions': schedule.sessions
          .map(_sessionSnapshot)
          .whereType<Map<String, dynamic>>()
          .toList(),
    };
  }

  static Map<String, dynamic>? _sessionSnapshot(CourseSession session) {
    if (session.weekday < DateTime.monday ||
        session.weekday > DateTime.sunday ||
        session.startSection <= 0 ||
        session.endSection <= 0) {
      return null;
    }
    final start = AcademicScheduleRepository.sectionStartTime(
      session.startSection,
      _sampleDay,
    );
    final end = AcademicScheduleRepository.sectionEndTime(
      session.endSection,
      _sampleDay,
    );
    if (start == null || end == null) {
      return null;
    }

    return {
      'id': session.id,
      'name': session.courseName,
      'teacher': session.teacherName,
      'location': session.placeText,
      'room': session.location,
      'meta': _courseMeta(session),
      'weekday': session.weekday,
      'startSection': session.startSection,
      'endSection': session.endSection,
      'sectionText': session.sectionText,
      'weeks': session.weeks,
      'startMinute': _minuteOfDay(start),
      'endMinute': _minuteOfDay(end),
      'startText': _timeText(start),
      'endText': _timeText(end),
    };
  }

  static String _courseMeta(CourseSession session) {
    final parts = [
      if (session.placeText.isNotEmpty) session.placeText,
      if (session.teacherName.isNotEmpty) session.teacherName,
    ];
    return parts.join(' · ');
  }

  static int _minuteOfDay(DateTime value) => value.hour * 60 + value.minute;

  static String _timeText(DateTime value) {
    return '${_pad(value.hour)}:${_pad(value.minute)}';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static bool get _supportsHomeWidget {
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  static final _sampleDay = DateTime(2000);
}
