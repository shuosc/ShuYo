import 'academic_schedule.dart';
import 'common.dart';

String academicTermKey(String yearCode, String termCode) =>
    '$yearCode:$termCode';

enum ScheduleAvailability { available, empty, failed }

/// A separate record per account and academic term. Remote checks never replace
/// the working copy while it has local edits.
class AcademicScheduleRecord {
  const AcademicScheduleRecord({
    required this.studentId,
    required this.yearCode,
    required this.termCode,
    required this.academicYearName,
    required this.termName,
    required this.availability,
    this.schedule,
    this.remoteSchedule,
    this.checkedAt,
    this.syncedAt,
    this.firstWeekStart,
    this.locallyEdited = false,
    this.lastError,
  });

  final String studentId;
  final String yearCode;
  final String termCode;
  final String academicYearName;
  final String termName;
  final ScheduleAvailability availability;
  final AcademicSchedule? schedule;
  final AcademicSchedule? remoteSchedule;
  final DateTime? checkedAt;
  final DateTime? syncedAt;
  final DateTime? firstWeekStart;
  final bool locallyEdited;
  final String? lastError;

  String get key => academicTermKey(yearCode, termCode);
  String get displayName => '$academicYearName $termName'.trim();
  bool get hasSavedSchedule => schedule != null;
  int get courseCount {
    final value = schedule;
    if (value == null) return 0;
    return {
      for (final course in value.sessions)
        course.courseCode.isEmpty ? course.courseName : course.courseCode,
      for (final course in value.untimedCourses)
        'untimed:${course.courseName}:${course.teacherName}',
    }.length;
  }

  AcademicScheduleRecord copyWith({
    ScheduleAvailability? availability,
    AcademicSchedule? schedule,
    AcademicSchedule? remoteSchedule,
    DateTime? checkedAt,
    DateTime? syncedAt,
    DateTime? firstWeekStart,
    bool? locallyEdited,
    String? lastError,
    bool clearError = false,
  }) =>
      AcademicScheduleRecord(
        studentId: studentId,
        yearCode: yearCode,
        termCode: termCode,
        academicYearName: academicYearName,
        termName: termName,
        availability: availability ?? this.availability,
        schedule: schedule ?? this.schedule,
        remoteSchedule: remoteSchedule ?? this.remoteSchedule,
        checkedAt: checkedAt ?? this.checkedAt,
        syncedAt: syncedAt ?? this.syncedAt,
        firstWeekStart: firstWeekStart ?? this.firstWeekStart,
        locallyEdited: locallyEdited ?? this.locallyEdited,
        lastError: clearError ? null : lastError ?? this.lastError,
      );

  JsonMap toJson() => {
        'studentId': studentId,
        'yearCode': yearCode,
        'termCode': termCode,
        'academicYearName': academicYearName,
        'termName': termName,
        'availability': availability.name,
        if (schedule != null) 'schedule': schedule!.toJson(),
        if (remoteSchedule != null) 'remoteSchedule': remoteSchedule!.toJson(),
        if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
        if (syncedAt != null) 'syncedAt': syncedAt!.toIso8601String(),
        if (firstWeekStart != null)
          'firstWeekStart': firstWeekStart!.toIso8601String(),
        'locallyEdited': locallyEdited,
        if (lastError != null) 'lastError': lastError,
      };

  factory AcademicScheduleRecord.fromJson(JsonMap json) {
    AcademicSchedule? schedule(String key) => json[key] is JsonMap
        ? AcademicSchedule.fromJson(json[key] as JsonMap)
        : null;
    DateTime? date(String key) => DateTime.tryParse(stringValue(json[key]));
    return AcademicScheduleRecord(
      studentId: stringValue(json['studentId']),
      yearCode: stringValue(json['yearCode']),
      termCode: stringValue(json['termCode']),
      academicYearName: stringValue(json['academicYearName']),
      termName: stringValue(json['termName']),
      availability: ScheduleAvailability.values.firstWhere(
        (value) => value.name == json['availability'],
        orElse: () => ScheduleAvailability.failed,
      ),
      schedule: schedule('schedule'),
      remoteSchedule: schedule('remoteSchedule'),
      checkedAt: date('checkedAt'),
      syncedAt: date('syncedAt'),
      firstWeekStart: date('firstWeekStart'),
      locallyEdited: json['locallyEdited'] == true,
      lastError: json['lastError'] as String?,
    );
  }
}

class ScheduleDiscoveryState {
  const ScheduleDiscoveryState({
    this.running = false,
    this.checked = 0,
    this.total = 0,
    this.saved = 0,
    this.failed = 0,
    this.message,
    this.requiresLogin = false,
  });

  final bool running;
  final int checked;
  final int total;
  final int saved;
  final int failed;
  final String? message;
  final bool requiresLogin;

  String get description =>
      message ??
      (running
          ? '已检查 $checked/$total 个学期，已保存 $saved 份课表'
          : failed > 0
              ? '已保存 $saved 份课表，$failed 个学期待重试'
              : '已保存 $saved 份课表');
}
