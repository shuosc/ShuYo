import '../../data/models/course_recording.dart';

class RecordingTimetableEntry {
  const RecordingTimetableEntry({
    required this.course,
    required this.lesson,
    required this.number,
  });

  final VodCourse course;
  final VodLesson lesson;
  final int number;
}

class RecordingTimetableData {
  factory RecordingTimetableData({
    required VodTerm? term,
    required List<VodCourse> courses,
    required Map<int, List<VodLesson>> lessonsByCourse,
    DateTime? now,
  }) {
    final today = _schoolDate(now ?? DateTime.now().toUtc());
    final teachingWeekCount = term?.teachingWeekCount;
    final entriesByDate = <DateTime, List<RecordingTimetableEntry>>{};
    final anchorCounts = <DateTime, int>{};
    final includedCourses = <int>{};
    for (final course in courses) {
      if (course.teachingClassId <= 0 ||
          term != null && course.termId != term.id ||
          !includedCourses.add(course.teachingClassId)) {
        continue;
      }
      final lessonsById = <int, VodLesson>{};
      for (final lesson
          in lessonsByCourse[course.teachingClassId] ?? const <VodLesson>[]) {
        if (_isListedLesson(lesson, course)) lessonsById[lesson.id] = lesson;
      }
      final live = course.liveLesson;
      if (live != null && _isListedLesson(live, course)) {
        lessonsById.putIfAbsent(live.id, () => live);
      }
      final lessons = lessonsById.values.toList()
        ..sort((first, second) {
          final byTime = _lessonTime(second).compareTo(_lessonTime(first));
          return byTime == 0 ? second.id.compareTo(first.id) : byTime;
        });
      for (var index = 0; index < lessons.length; index++) {
        final lesson = lessons[index];
        final begin = lesson.beginTime;
        if (begin == null) continue;
        final date = _schoolDate(begin);
        entriesByDate.putIfAbsent(date, () => []).add(RecordingTimetableEntry(
              course: course,
              lesson: lesson,
              number: lessons.length - index,
            ));
        if (lesson.weekNumber > 0 &&
            lesson.weekNumber <= (teachingWeekCount ?? 53)) {
          final anchor =
              _addDays(_mondayFor(date), -(lesson.weekNumber - 1) * 7);
          anchorCounts.update(anchor, (count) => count + 1, ifAbsent: () => 1);
        }
      }
    }
    final dates = entriesByDate.keys.toList()..sort();
    final termStart = term?.startDate;
    final termEnd = term?.endDate;
    final startDate = termStart == null ? null : _schoolDate(termStart);
    final endDate = termEnd == null ? null : _schoolDate(termEnd);
    final anchors = anchorCounts.keys.toList()
      ..sort((first, second) {
        final byCount = anchorCounts[second]!.compareTo(anchorCounts[first]!);
        if (byCount != 0) return byCount;
        if (startDate != null) {
          final byDistance = _daysBetween(first, startDate)
              .abs()
              .compareTo(_daysBetween(second, startDate).abs());
          if (byDistance != 0) return byDistance;
        }
        return first.compareTo(second);
      });
    var firstMonday = anchors.firstOrNull ??
        _mondayFor(startDate ?? dates.firstOrNull ?? endDate ?? today);
    if (teachingWeekCount == null &&
        dates.isNotEmpty &&
        dates.first.isBefore(firstMonday)) {
      firstMonday = _mondayFor(dates.first);
    }
    var maxWeek = teachingWeekCount ?? 1;
    if (teachingWeekCount == null) {
      for (final date in [
        if (startDate != null) startDate,
        if (endDate != null &&
            (startDate == null || !endDate.isBefore(startDate)))
          endDate,
        if (dates.isNotEmpty) dates.last,
      ]) {
        final week = _weekFor(firstMonday, date);
        if (week > maxWeek) maxWeek = week;
      }
    }
    final selectableDates = dates.where((date) {
      final week = _weekFor(firstMonday, date);
      return week >= 1 && week <= maxWeek;
    }).toList();
    final currentWeek = _weekFor(firstMonday, today);
    var initialWeek = currentWeek.clamp(1, maxWeek);
    var initialWeekday = today.weekday;
    if (selectableDates.isNotEmpty &&
        (currentWeek < 1 || currentWeek > maxWeek)) {
      final boundaryDate =
          currentWeek < 1 ? selectableDates.first : selectableDates.last;
      initialWeek = _weekFor(firstMonday, boundaryDate).clamp(1, maxWeek);
      initialWeekday = boundaryDate.weekday;
    }
    for (final entries in entriesByDate.values) {
      entries.sort((first, second) {
        final byTime =
            _lessonTime(first.lesson).compareTo(_lessonTime(second.lesson));
        if (byTime != 0) return byTime;
        final byCourse = first.course.teachingClassId
            .compareTo(second.course.teachingClassId);
        return byCourse == 0
            ? first.lesson.id.compareTo(second.lesson.id)
            : byCourse;
      });
    }
    return RecordingTimetableData._(
      firstWeekMonday: firstMonday,
      maxWeek: maxWeek,
      initialWeek: initialWeek,
      initialWeekday: initialWeekday,
      entriesByDate: Map.unmodifiable({
        for (final entry in entriesByDate.entries)
          entry.key: List<RecordingTimetableEntry>.unmodifiable(entry.value),
      }),
    );
  }

  const RecordingTimetableData._({
    required this.firstWeekMonday,
    required this.maxWeek,
    required this.initialWeek,
    required this.initialWeekday,
    required Map<DateTime, List<RecordingTimetableEntry>> entriesByDate,
  }) : _entriesByDate = entriesByDate;

  final DateTime firstWeekMonday;
  final int maxWeek;
  final int initialWeek;
  final int initialWeekday;
  final Map<DateTime, List<RecordingTimetableEntry>> _entriesByDate;

  bool get hasDatedLessons => _entriesByDate.isNotEmpty;

  int weekFor(DateTime date) => _weekFor(firstWeekMonday, _schoolDate(date));

  DateTime dateFor(int week, int weekday) {
    RangeError.checkValueInInterval(week, 1, maxWeek, 'week');
    RangeError.checkValueInInterval(weekday, 1, 7, 'weekday');
    return _addDays(firstWeekMonday, (week - 1) * 7 + weekday - 1);
  }

  List<RecordingTimetableEntry> entriesFor(DateTime date) =>
      _entriesByDate[_schoolDate(date)] ?? const [];
}

bool _isListedLesson(VodLesson lesson, VodCourse course) =>
    lesson.id > 0 &&
    lesson.teachingClassId == course.teachingClassId &&
    (lesson.isPlayable ||
        lesson.isGenerating ||
        lesson.isListed ||
        lesson.isLive);

int _lessonTime(VodLesson lesson) {
  final begin = lesson.beginTime;
  if (begin == null) return 0;
  final schoolTime = begin.isUtc ? begin.add(const Duration(hours: 8)) : begin;
  return DateTime.utc(
    schoolTime.year,
    schoolTime.month,
    schoolTime.day,
    schoolTime.hour,
    schoolTime.minute,
    schoolTime.second,
    schoolTime.millisecond,
    schoolTime.microsecond,
  ).millisecondsSinceEpoch;
}

DateTime _schoolDate(DateTime date) {
  final schoolTime = date.isUtc ? date.add(const Duration(hours: 8)) : date;
  return DateTime(schoolTime.year, schoolTime.month, schoolTime.day);
}

DateTime _addDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

DateTime _mondayFor(DateTime date) =>
    _addDays(date, DateTime.monday - date.weekday);

int _daysBetween(DateTime first, DateTime second) =>
    DateTime.utc(second.year, second.month, second.day)
        .difference(DateTime.utc(first.year, first.month, first.day))
        .inDays;

int _weekFor(DateTime firstMonday, DateTime date) =>
    (_daysBetween(firstMonday, date) / 7).floor() + 1;
