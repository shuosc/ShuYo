import '../../data/models/course_recording.dart';

typedef RecordingCourseDay = ({int weekday, Set<int> sections});

final _sectionPattern =
    RegExp(r'^第?\s*(\d{1,2})(?:\s*[-–—~～至]\s*(\d{1,2}))?\s*节(?:课)?$');

/// Builds the immutable timetable summary when the lesson catalog changes.
///
/// This contains no Flutter dependency so preparing course data does not need
/// a widget build, a scroll notification, or a mounted route.
List<RecordingCourseDay> recordingCourseDays(Iterable<VodLesson> lessons) {
  final days = <int, Set<int>>{};
  for (final lesson in lessons) {
    final begin = lesson.beginTime;
    final match = _sectionPattern.firstMatch(lesson.sectionLabel.trim());
    if (begin == null || match == null) continue;
    final first = int.parse(match[1]!);
    final last = int.parse(match[2] ?? match[1]!);
    if (first < 1 || last < first || last > 12) continue;
    final schoolDate =
        begin.isUtc ? begin.add(const Duration(hours: 8)) : begin;
    if (schoolDate.weekday > DateTime.friday) continue;
    final sections = days.putIfAbsent(schoolDate.weekday, () => <int>{});
    for (var section = first; section <= last; section++) {
      sections.add(section);
    }
  }
  final weekdays = days.keys.toList()..sort();
  return List.unmodifiable([
    for (final weekday in weekdays)
      (weekday: weekday, sections: Set<int>.unmodifiable(days[weekday]!)),
  ]);
}
