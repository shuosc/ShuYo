import 'common.dart';

class AcademicTerm {
  const AcademicTerm({
    required this.yearCode,
    required this.termCode,
    required this.academicYearName,
    required this.termName,
    required this.studentName,
    required this.studentId,
    required this.className,
    this.admissionYearCode = '',
  });

  final String yearCode;
  final String termCode;
  final String academicYearName;
  final String termName;
  final String studentName;
  final String studentId;
  final String className;
  final String admissionYearCode;

  String get displayName {
    final year = academicYearName.isEmpty ? yearCode : academicYearName;
    if (termName.isEmpty) {
      return year;
    }
    return '$year $termName';
  }

  factory AcademicTerm.fromJson(JsonMap json) {
    return AcademicTerm(
      yearCode: stringValue(json['XNM']),
      termCode: stringValue(json['XQM']),
      academicYearName: stringValue(json['XNMC']),
      termName: stringValue(json['XQMMC']),
      studentName: stringValue(json['XM']),
      studentId: stringValue(json['XH']),
      className: stringValue(json['BJMC']),
      admissionYearCode: stringValue(json['NJDM_ID']),
    );
  }

  JsonMap toJson() {
    return {
      'yearCode': yearCode,
      'termCode': termCode,
      'academicYearName': academicYearName,
      'termName': termName,
      'studentName': studentName,
      'studentId': studentId,
      'className': className,
      if (admissionYearCode.isNotEmpty) 'admissionYearCode': admissionYearCode,
    };
  }

  factory AcademicTerm.fromCache(JsonMap json) {
    return AcademicTerm(
      yearCode: stringValue(json['yearCode']),
      termCode: stringValue(json['termCode']),
      academicYearName: stringValue(json['academicYearName']),
      termName: stringValue(json['termName']),
      studentName: stringValue(json['studentName']),
      studentId: stringValue(json['studentId']),
      className: stringValue(json['className']),
      admissionYearCode: stringValue(json['admissionYearCode']),
    );
  }
}

class CourseSession {
  const CourseSession({
    required this.id,
    required this.courseName,
    required this.courseCode,
    required this.teacherName,
    required this.campus,
    required this.location,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.sections,
    required this.weeks,
    required this.weekText,
    required this.credit,
    required this.note,
    this.teachingClassId = '',
  });

  final String id;
  final String courseName;
  final String courseCode;
  // jxb_id from the academic system; empty for manual and older cached courses.
  final String teachingClassId;
  final String teacherName;
  final String campus;
  final String location;
  final int weekday;
  final int startSection;
  final int endSection;
  final List<int> sections;
  final List<int> weeks;
  final String weekText;
  final String credit;
  final String note;

  bool get isManual =>
      id.startsWith(manualIdPrefix) || courseCode == manualCode;

  bool occursInWeek(int week) => weeks.isEmpty || weeks.contains(week);

  String get sectionText {
    if (startSection <= 0 || endSection <= 0) {
      return '';
    }
    if (startSection == endSection) {
      return '第$startSection节';
    }
    return '第$startSection-$endSection节';
  }

  String get placeText {
    if (campus.isEmpty) {
      return location;
    }
    if (location.isEmpty) {
      return campus;
    }
    return '$campus $location';
  }

  JsonMap toJson() {
    return {
      'id': id,
      'courseName': courseName,
      'courseCode': courseCode,
      'teacherName': teacherName,
      'campus': campus,
      'location': location,
      'weekday': weekday,
      'startSection': startSection,
      'endSection': endSection,
      'sections': sections,
      'weeks': weeks,
      'weekText': weekText,
      'credit': credit,
      'note': note,
      if (teachingClassId.isNotEmpty) 'teachingClassId': teachingClassId,
    };
  }

  factory CourseSession.fromJson(JsonMap json) {
    return CourseSession(
      id: stringValue(json['id']),
      courseName: stringValue(json['courseName']),
      courseCode: stringValue(json['courseCode']),
      teacherName: stringValue(json['teacherName']),
      campus: stringValue(json['campus']),
      location: stringValue(json['location']),
      weekday: intValue(json['weekday']),
      startSection: intValue(json['startSection']),
      endSection: intValue(json['endSection']),
      sections: _intList(json['sections']),
      weeks: _intList(json['weeks']),
      weekText: stringValue(json['weekText']),
      credit: stringValue(json['credit']),
      note: stringValue(json['note']),
      teachingClassId: stringValue(json['teachingClassId']),
    );
  }

  static const manualIdPrefix = 'manual:';
  static const manualCode = '_manual';
}

class UntimedCourse {
  const UntimedCourse({
    required this.id,
    required this.courseName,
    required this.teacherName,
    required this.campus,
    required this.weeks,
    required this.weekText,
    required this.summary,
    required this.credit,
  });

  final String id;
  final String courseName;
  final String teacherName;
  final String campus;
  final List<int> weeks;
  final String weekText;
  final String summary;
  final String credit;

  bool occursInWeek(int week) => weeks.isEmpty || weeks.contains(week);

  JsonMap toJson() {
    return {
      'id': id,
      'courseName': courseName,
      'teacherName': teacherName,
      'campus': campus,
      'weeks': weeks,
      'weekText': weekText,
      'summary': summary,
      'credit': credit,
    };
  }

  factory UntimedCourse.fromJson(JsonMap json) {
    return UntimedCourse(
      id: stringValue(json['id']),
      courseName: stringValue(json['courseName']),
      teacherName: stringValue(json['teacherName']),
      campus: stringValue(json['campus']),
      weeks: _intList(json['weeks']),
      weekText: stringValue(json['weekText']),
      summary: stringValue(json['summary']),
      credit: stringValue(json['credit']),
    );
  }
}

class AcademicSchedule {
  const AcademicSchedule({
    required this.term,
    required this.sessions,
    required this.untimedCourses,
    required this.fetchedAt,
    this.teachingWeekCount,
  });

  final AcademicTerm term;
  final List<CourseSession> sessions;
  final List<UntimedCourse> untimedCourses;
  final DateTime fetchedAt;
  final int? teachingWeekCount;

  AcademicSchedule copyWith({
    AcademicTerm? term,
    List<CourseSession>? sessions,
    List<UntimedCourse>? untimedCourses,
    DateTime? fetchedAt,
    int? teachingWeekCount,
  }) {
    return AcademicSchedule(
      term: term ?? this.term,
      sessions: sessions ?? this.sessions,
      untimedCourses: untimedCourses ?? this.untimedCourses,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      teachingWeekCount: teachingWeekCount ?? this.teachingWeekCount,
    );
  }

  int get maxWeek {
    if (teachingWeekCount != null) return teachingWeekCount!.clamp(1, 32);
    final values = <int>[];
    for (final session in sessions) {
      values.addAll(session.weeks);
    }
    for (final course in untimedCourses) {
      values.addAll(course.weeks);
    }
    if (values.isEmpty) {
      return term.termName == '夏' ? 4 : 16;
    }
    return values.reduce((a, b) => a > b ? a : b).clamp(1, 32);
  }

  int get vacationWeek => maxWeek + 1;

  // Week 0 represents the vacation before the first teaching week.
  bool isVacationWeek(int week) => week < 1 || week >= vacationWeek;

  List<CourseSession> sessionsForWeek(int week) {
    if (isVacationWeek(week)) {
      return const [];
    }
    return sessions.where((session) => session.occursInWeek(week)).toList()
      ..sort((a, b) {
        final weekday = a.weekday.compareTo(b.weekday);
        if (weekday != 0) {
          return weekday;
        }
        return a.startSection.compareTo(b.startSection);
      });
  }

  List<UntimedCourse> untimedForWeek(int week) {
    if (isVacationWeek(week)) {
      return const [];
    }
    return untimedCourses.where((course) => course.occursInWeek(week)).toList();
  }

  JsonMap toJson() {
    return {
      'term': term.toJson(),
      'sessions': sessions.map((session) => session.toJson()).toList(),
      'untimedCourses':
          untimedCourses.map((course) => course.toJson()).toList(),
      'fetchedAt': fetchedAt.toIso8601String(),
      if (teachingWeekCount != null) 'teachingWeekCount': teachingWeekCount,
    };
  }

  factory AcademicSchedule.fromJson(JsonMap json) {
    return AcademicSchedule(
      term: AcademicTerm.fromCache(json['term'] as JsonMap? ?? const {}),
      sessions: (json['sessions'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(CourseSession.fromJson)
          .toList(),
      untimedCourses: (json['untimedCourses'] as List? ?? const [])
          .whereType<JsonMap>()
          .map(UntimedCourse.fromJson)
          .toList(),
      fetchedAt: DateTime.tryParse(stringValue(json['fetchedAt'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      teachingWeekCount: json['teachingWeekCount'] is int
          ? json['teachingWeekCount'] as int
          : null,
    );
  }
}

class AcademicScheduleParser {
  const AcademicScheduleParser._();

  static AcademicSchedule parse(JsonMap json, {DateTime? fetchedAt}) {
    final term = AcademicTerm.fromJson(json['xsxx'] as JsonMap? ?? const {});
    final sessions = <CourseSession>[];
    final untimed = <UntimedCourse>[];

    final kbList = json['kbList'] as List? ?? const [];
    for (var index = 0; index < kbList.length; index++) {
      final raw = kbList[index];
      if (raw is! JsonMap) {
        continue;
      }
      final sections = _sections(raw);
      final weeks = _weeks(raw['oldzc'], stringValue(raw['zcd']));
      final startSection = sections.isEmpty ? 0 : sections.first;
      final endSection = sections.isEmpty ? 0 : sections.last;
      sessions.add(
        CourseSession(
          id: _id(raw, index),
          courseName: stringValue(raw['kcmc']),
          courseCode: stringValue(raw['kch_id'], stringValue(raw['kch'])),
          teacherName: stringValue(raw['xm'], stringValue(raw['jsxm'])),
          campus: stringValue(raw['xqmc']),
          location: stringValue(raw['cdmc']),
          weekday: intValue(raw['xqj']),
          startSection: startSection,
          endSection: endSection,
          sections: sections,
          weeks: weeks,
          weekText: stringValue(raw['zcd']),
          credit: stringValue(raw['xf']),
          note: stringValue(raw['xkbz'], stringValue(raw['qqqh'])),
          teachingClassId: stringValue(raw['jxb_id']),
        ),
      );
    }

    final sjkList = json['sjkList'] as List? ?? const [];
    for (var index = 0; index < sjkList.length; index++) {
      final raw = sjkList[index];
      if (raw is! JsonMap) {
        continue;
      }
      final weekText = stringValue(raw['qsjsz'], stringValue(raw['zcd']));
      untimed.add(
        UntimedCourse(
          id: 'untimed-${stringValue(raw['kcmc'])}-$index',
          courseName: stringValue(raw['kcmc']),
          teacherName: stringValue(raw['jsxm'], stringValue(raw['xm'])),
          campus: stringValue(raw['xqmc']),
          weeks: parseWeeks(weekText),
          weekText: weekText,
          summary: stringValue(raw['qtkcgs'], stringValue(raw['sjkcgs'])),
          credit: stringValue(raw['xf']),
        ),
      );
    }

    return AcademicSchedule(
      term: term,
      sessions: sessions,
      untimedCourses: untimed,
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }

  static List<int> parseBitmask(Object? value, {int max = 32}) {
    final mask = intValue(value);
    if (mask <= 0) {
      return const [];
    }
    final values = <int>[];
    for (var index = 0; index < max; index++) {
      if ((mask & (1 << index)) != 0) {
        values.add(index + 1);
      }
    }
    return values;
  }

  static List<int> parseWeeks(String text) {
    final normalized =
        text.replaceAll('，', ',').replaceAll('、', ',').replaceAll(' ', '');
    if (normalized.isEmpty) {
      return const [];
    }
    final oddOnly = normalized.contains('单');
    final evenOnly = normalized.contains('双');
    final values = <int>{};

    for (final match in RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(normalized)) {
      final start = int.tryParse(match.group(1) ?? '') ?? 0;
      final end = int.tryParse(match.group(2) ?? '') ?? 0;
      if (start <= 0 || end <= 0) {
        continue;
      }
      for (var week = start; week <= end; week++) {
        if (_weekMatchesPattern(week, oddOnly, evenOnly)) {
          values.add(week);
        }
      }
    }

    final withoutRanges = normalized.replaceAll(RegExp(r'\d+\s*-\s*\d+'), '');
    for (final match in RegExp(r'\d+').allMatches(withoutRanges)) {
      final week = int.tryParse(match.group(0) ?? '') ?? 0;
      if (week > 0 && _weekMatchesPattern(week, oddOnly, evenOnly)) {
        values.add(week);
      }
    }

    final sorted = values.toList()..sort();
    return sorted;
  }

  static bool _weekMatchesPattern(int week, bool oddOnly, bool evenOnly) {
    if (oddOnly && week.isEven) {
      return false;
    }
    if (evenOnly && week.isOdd) {
      return false;
    }
    return true;
  }

  static List<int> _weeks(Object? bitmask, String fallbackText) {
    final byMask = parseBitmask(bitmask, max: 32);
    if (byMask.isNotEmpty) {
      return byMask;
    }
    return parseWeeks(fallbackText);
  }

  static List<int> _sections(JsonMap raw) {
    final byMask = parseBitmask(raw['oldjc'], max: 16);
    if (byMask.isNotEmpty) {
      return byMask;
    }
    final text = stringValue(raw['jcs'], stringValue(raw['jc']));
    final match = RegExp(r'(\d+)(?:\s*-\s*(\d+))?').firstMatch(text);
    if (match == null) {
      return const [];
    }
    final start = int.tryParse(match.group(1) ?? '') ?? 0;
    final end = int.tryParse(match.group(2) ?? '') ?? start;
    if (start <= 0 || end <= 0) {
      return const [];
    }
    return [for (var section = start; section <= end; section++) section];
  }

  static String _id(JsonMap raw, int index) {
    final code = stringValue(raw['jxb_id'], stringValue(raw['kch_id']));
    final weekday = stringValue(raw['xqj']);
    final sections = stringValue(raw['jcs'], stringValue(raw['oldjc']));
    final weeks = stringValue(raw['oldzc'], stringValue(raw['zcd']));
    return '$code-$weekday-$sections-$weeks-$index';
  }
}

List<int> _intList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map(intValue).where((item) => item > 0).toList();
}
