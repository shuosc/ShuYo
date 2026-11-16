import 'package:html/parser.dart' as html_parser;

import 'common.dart';
import 'course_recording.dart';

/// A lesson returned by the recording platform's keyword search.
///
/// Search usually omits recording generation/deletion flags. [lesson] is a
/// playback candidate whose live or recording status comes from the search
/// response. The viewer endpoint still validates its identity and availability
/// when the user opens the result.
class VodSearchResult {
  const VodSearchResult(
      {required this.course, required this.lesson, this.courseNumber = ''});

  factory VodSearchResult.fromJson(JsonMap json, {VodTerm? term}) {
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
    final recording = VodLesson.fromJson(json);
    final status = json['courseStatus'];
    final isLive = const {0, '0', 1, '1'}.contains(status);
    return VodSearchResult(
      course: course,
      courseNumber: _plainText(json['courseNo']),
      lesson: isLive
          ? VodLesson.fromLiveJson({
              // Keep the supplied live window independent from the timetable;
              // the actual broadcast may continue beyond the lesson end.
              ...json,
              'subjName': name,
              'teclName': className,
              'subjCode': course.code,
              'teacNames': course.teacherNames,
              // Search's current-live state maps to the live catalog enum.
              // Explicit enable/disable flags, when supplied, still apply.
              'liveType': status == 0 || status == '0' ? 0 : 1,
              'clroName': _plainText(json['clroName']),
            }, term: term)
          : VodLesson(
              id: intValue(json['id']),
              teachingClassId: course.teachingClassId,
              name: name,
              // Search is discovery metadata. Missing VOD flags are not proof
              // that a recording exists; resolve the viewer catalog/details.
              isPlayable: recording.isPlayable,
              isGenerating: recording.isGenerating,
              isListed: recording.isListed,
              beginTime: vodDateValue(json['courBeginTime']),
              endTime: vodDateValue(json['courEndTime']),
              weekNumber: recording.weekNumber,
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
