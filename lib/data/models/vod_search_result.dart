import 'package:html/parser.dart' as html_parser;

import 'common.dart';
import 'course_recording.dart';

/// A lesson returned by the recording platform's keyword search.
///
/// Search has no recording generation/deletion flags. [lesson] is a candidate
/// that may request playback details; it does not prove a video is available.
/// The playback endpoint remains responsible for validating its identity and
/// returning playable media when the user opens the result.
class VodSearchResult {
  const VodSearchResult(
      {required this.course, required this.lesson, this.courseNumber = ''});

  factory VodSearchResult.fromJson(JsonMap json) {
    final className = _plainText(json['teclName']);
    final subjectName = _plainText(json['subjName']);
    final name = subjectName.isNotEmpty ? subjectName : className;
    final teachers = <String>{
      ..._teacherNames(json['teacNames']),
      ..._teacherNames(json['teclTeacNames']),
    };
    final section = intValue(json['letiNumber']);
    final course = VodCourse(
      teachingClassId: intValue(json['teclId']),
      termId: intValue(json['acteId']),
      name: name,
      teachingClassName: className,
      code: _plainText(json['subjCode']),
      teacherNames: List.unmodifiable(teachers),
    );
    return VodSearchResult(
      course: course,
      courseNumber: _plainText(json['courseNo']),
      lesson: VodLesson(
        id: intValue(json['id']),
        teachingClassId: course.teachingClassId,
        name: name,
        // Permit a detail lookup without inventing the absent VOD flags.
        isPlayable: true,
        beginTime: vodDateValue(json['courBeginTime']),
        endTime: vodDateValue(json['courEndTime']),
        weekNumber: intValue(json['weekNumber']),
        sectionLabel: section > 0 ? '第$section节' : '',
        classroom: _plainText(json['clroName']),
      ),
    );
  }

  final VodCourse course;
  final VodLesson lesson;
  final String courseNumber;

  static List<String> _teacherNames(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable(value
        .whereType<String>()
        .map(_plainText)
        .where((name) => name.isNotEmpty)
        .toSet());
  }

  static String _plainText(Object? value) {
    if (value is! String || value.isEmpty) return '';
    final fragment = html_parser.parseFragment(value);
    for (final element in fragment.querySelectorAll('script, style')) {
      element.remove();
    }
    return (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
