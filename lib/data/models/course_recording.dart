import 'common.dart';

/// A term as returned by the recording platform (its IDs differ from JWXT).
class VodTerm {
  const VodTerm({
    required this.id,
    required this.name,
    this.isCurrent = false,
    this.startDate,
    this.endDate,
  });

  factory VodTerm.fromJson(JsonMap json) {
    final year = stringValue(json['acyeCode']).trim();
    final number = intValue(json['acteTerm']);
    return VodTerm(
      id: intValue(json['id']),
      name: year.isEmpty ? '第$number学期' : '$year学年第$number学期',
      isCurrent: json['currentTerm'] == true,
      startDate: vodDateValue(json['acteBeginDate']),
      endDate: vodDateValue(json['acteEndDate']),
    );
  }

  final int id;
  final String name;
  final bool isCurrent;
  final DateTime? startDate;
  final DateTime? endDate;
}

/// One teaching class from the account's ordinary VOD catalog.
///
/// The response's `id` is a lesson ID; only `teclId` identifies this class.
class VodCourse {
  const VodCourse({
    required this.teachingClassId,
    required this.termId,
    required this.name,
    this.teachingClassName = '',
    this.code = '',
    this.teacherNames = const [],
    this.lessonCount = 0,
    this.coverUrl,
  });

  factory VodCourse.fromJson(JsonMap json) {
    final subjectName = stringValue(json['subjName']).trim();
    final className = stringValue(json['teclName']).trim();
    return VodCourse(
      teachingClassId: intValue(json['teclId']),
      termId: intValue(json['acteId']),
      name: subjectName.isNotEmpty ? subjectName : className,
      teachingClassName: className,
      code: stringValue(json['subjCode']),
      teacherNames: List.unmodifiable(
        (json['teacNames'] as List? ?? const [])
            .map((name) => stringValue(name).trim())
            .where((name) => name.isNotEmpty)
            .toSet(),
      ),
      lessonCount: intValue(json['courTimes']),
      coverUrl: _optionalString(json['teclImgUrl']),
    );
  }

  final int teachingClassId;
  final int termId;
  final String name;
  final String teachingClassName;
  final String code;
  final List<String> teacherNames;
  final int lessonCount;
  final String? coverUrl;

  String get teacherLabel => teacherNames.join('、');
}

/// A scheduled lesson. Only completed, enabled, undeleted recordings are shown.
class VodLesson {
  const VodLesson({
    required this.id,
    required this.teachingClassId,
    required this.name,
    required this.isPlayable,
    this.beginTime,
    this.endTime,
    this.weekNumber = 0,
    this.sectionLabel = '',
    this.classroom = '',
    this.watchPercent,
  });

  factory VodLesson.fromJson(JsonMap json) {
    final section = intValue(json['letiNumber']);
    final generated = intValue(json['vodStatus'], -1) == 5;
    return VodLesson(
      id: intValue(json['id']),
      teachingClassId: intValue(json['teclId']),
      name: stringValue(json['subjName'], stringValue(json['teclName'])),
      beginTime: vodDateValue(json['courBeginTime']),
      endTime: vodDateValue(json['courEndTime']),
      weekNumber: intValue(json['weekNo'], intValue(json['weekNumber'])),
      sectionLabel: section > 0 ? '第$section节' : '',
      classroom: stringValue(json['clroName']),
      watchPercent: _optionalString(json['watchPercent']),
      isPlayable: generated &&
          intValue(json['vodEnable'], -1) == 1 &&
          intValue(json['vodClickEnable'], -1) == 1 &&
          intValue(json['vodDeleteStatus'], -1) == 0,
    );
  }

  final int id;
  final int teachingClassId;
  final String name;
  final DateTime? beginTime;
  final DateTime? endTime;
  final int weekNumber;
  final String sectionLabel;
  final String classroom;
  final String? watchPercent;
  final bool isPlayable;
}

class VodView {
  const VodView({
    required this.viewNumber,
    required this.url,
    this.httpHeaders = const {},
  });

  final int viewNumber;

  /// Ephemeral signed URL. Never persist, log, or use as a cache key.
  final Uri url;

  /// Headers scoped to this media target, never copied from the API request.
  final Map<String, String> httpHeaders;

  String get label => switch (viewNumber) {
        1 => '教师视角 1',
        2 => '教师视角 2',
        3 => '学生视角 1',
        4 => '学生视角 2',
        5 => 'PPT',
        6 => '电子白板',
        7 => '合成画面',
        _ => '视角 $viewNumber',
      };
}

/// Held by a player route only; obtaining another playback rechecks permission.
class VodPlayback {
  const VodPlayback({
    required this.lessonId,
    required this.teachingClassId,
    required this.title,
    required this.views,
    this.lastPosition = Duration.zero,
    this.voiceChannel,
  });

  final int lessonId;
  final int teachingClassId;
  final String title;
  final List<VodView> views;
  final Duration lastPosition;
  final int? voiceChannel;
}

DateTime? vodDateValue(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

String? _optionalString(Object? value) {
  final text = stringValue(value).trim();
  return text.isEmpty ? null : text;
}
