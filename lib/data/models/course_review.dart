import 'common.dart';

List<JsonMap> _maps(Object? value) =>
    (value as List? ?? const []).whereType<JsonMap>().toList(growable: false);

double? _score(Object? value) => value is num ? value.toDouble() : null;

class RateCourseRef {
  const RateCourseRef({
    required this.id,
    required this.name,
    required this.college,
    required this.credits,
  });

  final String id;
  final String name;
  final String college;
  final String credits;

  /// 课程号 · 学院 · 学分, skipping empty parts.
  String get metaText => [
        id,
        college,
        if (credits.isNotEmpty) '$credits 学分',
      ].where((part) => part.isNotEmpty).join(' · ');

  factory RateCourseRef.fromJson(JsonMap json) => RateCourseRef(
        id: stringValue(json['id']),
        name: stringValue(json['name']),
        college: stringValue(json['college']),
        credits: stringValue(json['credits']),
      );
}

class RateTeacherRef {
  const RateTeacherRef({
    required this.id,
    required this.name,
    required this.college,
    required this.title,
    required this.duplicateName,
  });

  final String id;
  final String name;
  final String college;
  final String title;
  final bool duplicateName;

  /// Teachers sharing a name are told apart by college, then title.
  String get displayName {
    if (!duplicateName) return name;
    final hint = college.isNotEmpty ? college : title;
    return hint.isEmpty ? name : '$name（$hint）';
  }

  factory RateTeacherRef.fromJson(JsonMap json) => RateTeacherRef(
        id: stringValue(json['id']),
        name: stringValue(json['name']),
        college: stringValue(json['college']),
        title: stringValue(json['title']),
        duplicateName: boolValue(json['duplicateName']),
      );
}

/// One course taught by one teacher: the thing that is reviewed.
class RateUnit {
  const RateUnit({
    required this.id,
    required this.isCoTeacher,
    required this.reviewCount,
    required this.average,
    required this.lastReviewedAt,
    required this.course,
    required this.teacher,
  });

  final String id;
  final bool isCoTeacher;
  final int reviewCount;

  /// Mean score on the 6.0–10.0 display scale; null without reviews.
  final double? average;
  final DateTime? lastReviewedAt;
  final RateCourseRef course;
  final RateTeacherRef teacher;

  factory RateUnit.fromJson(JsonMap json) => RateUnit(
        id: stringValue(json['id']),
        isCoTeacher: stringValue(json['role']) == 'co',
        reviewCount: intValue(json['reviewCount']),
        average: _score(json['average']),
        lastReviewedAt: dateValue(json['lastReviewedAt']),
        course: RateCourseRef.fromJson(json['course'] as JsonMap? ?? const {}),
        teacher:
            RateTeacherRef.fromJson(json['teacher'] as JsonMap? ?? const {}),
      );
}

class RateCourseSummary {
  const RateCourseSummary({
    required this.course,
    required this.teacherCount,
    required this.reviewCount,
    required this.average,
  });

  final RateCourseRef course;
  final int teacherCount;
  final int reviewCount;
  final double? average;

  factory RateCourseSummary.fromJson(JsonMap json) => RateCourseSummary(
        course: RateCourseRef.fromJson(json),
        teacherCount: intValue(json['teacherCount']),
        reviewCount: intValue(json['reviewCount']),
        average: _score(json['average']),
      );
}

class RateTeacherSummary {
  const RateTeacherSummary({
    required this.teacher,
    required this.courseCount,
    required this.reviewCount,
    required this.average,
  });

  final RateTeacherRef teacher;
  final int courseCount;
  final int reviewCount;
  final double? average;

  factory RateTeacherSummary.fromJson(JsonMap json) => RateTeacherSummary(
        teacher: RateTeacherRef.fromJson(json),
        courseCount: intValue(json['courseCount']),
        reviewCount: intValue(json['reviewCount']),
        average: _score(json['average']),
      );
}

class RateCourseDetail {
  const RateCourseDetail({required this.course, required this.units});

  final RateCourseRef course;
  final List<RateUnit> units;

  factory RateCourseDetail.fromJson(JsonMap json) => RateCourseDetail(
        course: RateCourseRef.fromJson(json),
        units: _maps(json['units']).map(RateUnit.fromJson).toList(),
      );
}

class RateTeacherDetail {
  const RateTeacherDetail({required this.teacher, required this.units});

  final RateTeacherRef teacher;
  final List<RateUnit> units;

  factory RateTeacherDetail.fromJson(JsonMap json) => RateTeacherDetail(
        teacher: RateTeacherRef.fromJson(json),
        units: _maps(json['units']).map(RateUnit.fromJson).toList(),
      );
}

class RateOptionStat {
  const RateOptionStat({
    required this.key,
    required this.label,
    required this.count,
    required this.percent,
    required this.top,
  });

  final String key;
  final String label;
  final int count;
  final int percent;
  final bool top;

  factory RateOptionStat.fromJson(JsonMap json) => RateOptionStat(
        key: stringValue(json['key']),
        label: stringValue(json['label']),
        count: intValue(json['count']),
        percent: intValue(json['percent']),
        top: boolValue(json['top']),
      );
}

class RateQuestionStat {
  const RateQuestionStat({
    required this.key,
    required this.title,
    required this.multiple,
    required this.answered,
    required this.options,
  });

  final String key;
  final String title;
  final bool multiple;
  final int answered;
  final List<RateOptionStat> options;

  factory RateQuestionStat.fromJson(JsonMap json) => RateQuestionStat(
        key: stringValue(json['key']),
        title: stringValue(json['title']),
        multiple: boolValue(json['multiple']),
        answered: intValue(json['answered']),
        options: _maps(json['options']).map(RateOptionStat.fromJson).toList(),
      );
}

class RateUnitDetail {
  const RateUnitDetail({required this.unit, required this.stats});

  final RateUnit unit;
  final List<RateQuestionStat> stats;

  factory RateUnitDetail.fromJson(JsonMap json) => RateUnitDetail(
        unit: RateUnit.fromJson(json),
        stats: _maps(json['stats']).map(RateQuestionStat.fromJson).toList(),
      );
}

class RateOption {
  const RateOption({required this.key, required this.label});

  final String key;
  final String label;

  factory RateOption.fromJson(JsonMap json) => RateOption(
        key: stringValue(json['key']),
        label: stringValue(json['label']),
      );
}

class RateQuestion {
  const RateQuestion({
    required this.key,
    required this.title,
    required this.multiple,
    required this.required,
    required this.options,
    this.description,
    this.maxSelections,
  });

  static const overallKey = 'overall';

  final String key;
  final String title;
  final bool multiple;
  final bool required;
  final List<RateOption> options;
  final String? description;
  final int? maxSelections;

  bool get isOverall => key == overallKey;

  /// An empty server description deliberately hides the hint. Only older
  /// configurations without a description use the compatibility text.
  String get displayDescription =>
      description ??
      (isOverall
          ? (required ? '必答' : '可跳过')
          : [
              multiple ? '可多选' : '单选',
              if (multiple && maxSelections != null) '最多$maxSelections项',
              required ? '必答' : '可跳过',
            ].join('，'));

  factory RateQuestion.fromJson(JsonMap json) {
    final maxSelections = intValue(json['maxSelections']);
    return RateQuestion(
      key: stringValue(json['key']),
      title: stringValue(json['title']),
      multiple: boolValue(json['multiple']),
      required: boolValue(json['required']),
      options: _maps(json['options']).map(RateOption.fromJson).toList(),
      description: json['description'] as String?,
      maxSelections: maxSelections > 0 ? maxSelections : null,
    );
  }
}

class RateCategory {
  const RateCategory({
    required this.key,
    required this.title,
    required this.subcategories,
  });

  final String key;
  final String title;
  final List<String> subcategories;

  factory RateCategory.fromJson(JsonMap json) => RateCategory(
        key: stringValue(json['key']),
        title: stringValue(json['title']),
        subcategories: (json['subcategories'] as List? ?? const [])
            .map((item) => stringValue(item))
            .where((item) => item.isNotEmpty)
            .toList(),
      );
}

class RateFeedbackKind {
  const RateFeedbackKind({required this.key, required this.label});

  final String key;
  final String label;

  factory RateFeedbackKind.fromJson(JsonMap json) => RateFeedbackKind(
        key: stringValue(json['key']),
        label: stringValue(json['label']),
      );
}

class RateCatalogConfig {
  const RateCatalogConfig({
    required this.questions,
    required this.categories,
    required this.feedbackKinds,
  });

  final List<RateQuestion> questions;
  final List<RateCategory> categories;
  final List<RateFeedbackKind> feedbackKinds;

  factory RateCatalogConfig.fromJson(JsonMap json) => RateCatalogConfig(
        questions: _maps(json['questions']).map(RateQuestion.fromJson).toList(),
        categories:
            _maps(json['categories']).map(RateCategory.fromJson).toList(),
        feedbackKinds: _maps(json['feedbackKinds'])
            .map(RateFeedbackKind.fromJson)
            .toList(),
      );
}

class RateRankingPreview {
  const RateRankingPreview({
    required this.key,
    required this.title,
    required this.total,
    required this.items,
  });

  final String key;
  final String title;
  final int total;
  final List<RateUnit> items;

  factory RateRankingPreview.fromJson(JsonMap json) => RateRankingPreview(
        key: stringValue(json['key']),
        title: stringValue(json['title']),
        total: intValue(json['total']),
        items: _maps(json['items']).map(RateUnit.fromJson).toList(),
      );
}

class RateCollege {
  const RateCollege({required this.name, required this.courseCount});

  final String name;
  final int courseCount;

  factory RateCollege.fromJson(JsonMap json) => RateCollege(
        name: stringValue(json['name']),
        courseCount: intValue(json['courseCount']),
      );
}

class RateHome {
  const RateHome({
    required this.recent,
    required this.rankings,
    required this.colleges,
  });

  final List<RateUnit> recent;
  final List<RateRankingPreview> rankings;
  final List<RateCollege> colleges;

  factory RateHome.fromJson(JsonMap json) => RateHome(
        recent: _maps(json['recent']).map(RateUnit.fromJson).toList(),
        rankings:
            _maps(json['rankings']).map(RateRankingPreview.fromJson).toList(),
        colleges: _maps(json['colleges']).map(RateCollege.fromJson).toList(),
      );
}

class RateRankingResult {
  const RateRankingResult({
    required this.key,
    required this.title,
    required this.subcategories,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.items,
  });

  final String key;
  final String title;
  final List<String> subcategories;
  final int total;
  final int page;
  final int pageSize;
  final List<RateUnit> items;

  bool get hasMore => page * pageSize < total;

  factory RateRankingResult.fromJson(JsonMap json) => RateRankingResult(
        key: stringValue(json['key']),
        title: stringValue(json['title']),
        subcategories: RateCategory.fromJson(json).subcategories,
        total: intValue(json['total']),
        page: intValue(json['page'], 1),
        pageSize: intValue(json['pageSize'], 20),
        items: _maps(json['items']).map(RateUnit.fromJson).toList(),
      );
}

class RateSearchResult {
  const RateSearchResult({
    required this.units,
    required this.courses,
    required this.teachers,
  });

  static const empty = RateSearchResult(units: [], courses: [], teachers: []);

  final List<RateUnit> units;
  final List<RateCourseSummary> courses;
  final List<RateTeacherSummary> teachers;

  bool get isEmpty => units.isEmpty && courses.isEmpty && teachers.isEmpty;

  factory RateSearchResult.fromJson(JsonMap json) => RateSearchResult(
        units: _maps(json['units']).map(RateUnit.fromJson).toList(),
        courses:
            _maps(json['courses']).map(RateCourseSummary.fromJson).toList(),
        teachers:
            _maps(json['teachers']).map(RateTeacherSummary.fromJson).toList(),
      );
}

/// A course from the local schedule, sent for matching. It carries no
/// student identity or other schedule fields.
class RateScheduleCourse {
  const RateScheduleCourse({
    required this.teachingClassId,
    required this.courseCode,
    required this.courseName,
    required this.teacherName,
  });

  final String teachingClassId;
  final String courseCode;
  final String courseName;
  final String teacherName;

  String get dedupeKey => teachingClassId.isNotEmpty
      ? 'jxb:$teachingClassId'
      : '$courseCode|$courseName|$teacherName';

  JsonMap toJson() => {
        if (teachingClassId.isNotEmpty) 'teachingClassId': teachingClassId,
        if (courseCode.isNotEmpty) 'courseCode': courseCode,
        if (courseName.isNotEmpty) 'courseName': courseName,
        if (teacherName.isNotEmpty) 'teacherName': teacherName,
      };
}

enum RateLookupStatus { unit, course, search, none }

class RateLookupResult {
  const RateLookupResult({
    required this.status,
    required this.unit,
    required this.courseId,
    required this.units,
    required this.query,
  });

  final RateLookupStatus status;
  final RateUnit? unit;
  final String courseId;

  /// For a combined class: the teachers of this teaching class.
  final List<RateUnit> units;
  final String query;

  factory RateLookupResult.fromJson(JsonMap json) {
    final status = switch (stringValue(json['status'])) {
      'unit' => RateLookupStatus.unit,
      'course' => RateLookupStatus.course,
      'search' => RateLookupStatus.search,
      _ => RateLookupStatus.none,
    };
    final unit = json['unit'];
    return RateLookupResult(
      status: status,
      unit: unit is JsonMap ? RateUnit.fromJson(unit) : null,
      courseId: stringValue(json['courseId']),
      units: _maps(json['units']).map(RateUnit.fromJson).toList(),
      query: stringValue(json['query']),
    );
  }
}

class RateScheduleMatch {
  const RateScheduleMatch({required this.course, required this.result});

  final RateScheduleCourse course;
  final RateLookupResult result;
}

class RateMyReview {
  const RateMyReview({
    required this.id,
    required this.unitId,
    required this.overall,
    required this.answers,
    required this.updatedAt,
  });

  final String id;
  final String unitId;
  final int overall;
  final Map<String, List<String>> answers;
  final DateTime? updatedAt;

  factory RateMyReview.fromJson(JsonMap json) {
    final raw = json['answers'] as JsonMap? ?? const {};
    return RateMyReview(
      id: stringValue(json['id']),
      unitId: stringValue(json['unitId']),
      overall: intValue(json['overall']),
      answers: {
        for (final entry in raw.entries)
          entry.key: (entry.value as List? ?? const [])
              .map((item) => stringValue(item))
              .toList(),
      },
      updatedAt: dateValue(json['updatedAt']),
    );
  }
}

class RateMyReviewItem {
  const RateMyReviewItem({
    required this.id,
    required this.overall,
    required this.hasGrading,
    required this.updatedAt,
    required this.unit,
  });

  final String id;
  final int overall;
  final bool hasGrading;
  final DateTime? updatedAt;
  final RateUnit unit;

  factory RateMyReviewItem.fromJson(JsonMap json) => RateMyReviewItem(
        id: stringValue(json['id']),
        overall: intValue(json['overall']),
        hasGrading: boolValue(json['hasGrading']),
        updatedAt: dateValue(json['updatedAt']),
        unit: RateUnit.fromJson(json['unit'] as JsonMap? ?? const {}),
      );
}

class RateMyReviews {
  const RateMyReviews({required this.blocked, required this.reviews});

  final bool blocked;
  final List<RateMyReviewItem> reviews;

  factory RateMyReviews.fromJson(JsonMap json) => RateMyReviews(
        blocked: boolValue(json['blocked']),
        reviews: _maps(json['reviews']).map(RateMyReviewItem.fromJson).toList(),
      );
}

class RateReviewDraft {
  const RateReviewDraft({required this.overall, required this.answers});

  final int overall;
  final Map<String, List<String>> answers;

  /// Validate the same question snapshot that was shown while answering.
  /// Count unique option keys, matching the server's selection-limit rule.
  ({int questionIndex, String message})? validate(
      List<RateQuestion> questions) {
    for (var index = 0; index < questions.length; index++) {
      final question = questions[index];
      final selected = (question.isOverall
              ? (overall == 0 ? const <String>[] : ['$overall'])
              : answers[question.key] ?? const <String>[])
          .toSet();
      final limit = question.maxSelections;
      final allowed = question.options.map((option) => option.key).toSet();
      final String? message;
      if (question.required && selected.isEmpty) {
        message = '请回答“${question.title}”';
      } else if (!question.multiple && selected.length > 1) {
        message = '“${question.title}”只能选择一项';
      } else if (question.multiple &&
          limit != null &&
          selected.length > limit) {
        message = '“${question.title}”最多选择$limit项';
      } else if (selected.any((key) => !allowed.contains(key))) {
        message = '“${question.title}”包含无效选项，请重新选择';
      } else {
        message = null;
      }
      if (message != null) return (questionIndex: index, message: message);
    }
    return null;
  }

  JsonMap toJson() => {
        'overall': overall,
        // Missing keys preserve newer answers on the server; [] explicitly
        // clears an answer. Never add keys for questions the client did not load.
        'answers': {
          for (final entry in answers.entries) entry.key: entry.value,
        },
      };
}

class RateFeedbackReply {
  const RateFeedbackReply({required this.message, required this.createdAt});

  final String message;
  final DateTime? createdAt;

  factory RateFeedbackReply.fromJson(JsonMap json) => RateFeedbackReply(
        message: stringValue(json['message']),
        createdAt: dateValue(json['createdAt']),
      );
}

class RateFeedbackTicket {
  const RateFeedbackTicket({
    required this.id,
    required this.kindLabel,
    required this.unit,
    required this.course,
    required this.content,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.replies,
  });

  final String id;
  final String kindLabel;
  final RateUnit? unit;
  final RateCourseRef? course;
  final String content;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<RateFeedbackReply> replies;

  String get statusLabel => switch (status) {
        'replied' => '已回复',
        'closed' => '已关闭',
        _ => '待处理',
      };

  String get targetText {
    final linked = unit;
    if (linked != null) {
      return '${linked.course.name} · ${linked.teacher.displayName}';
    }
    final linkedCourse = course;
    return linkedCourse == null
        ? ''
        : '${linkedCourse.name}（${linkedCourse.id}）';
  }

  factory RateFeedbackTicket.fromJson(JsonMap json) {
    final unit = json['unit'];
    final course = json['course'];
    return RateFeedbackTicket(
      id: stringValue(json['id']),
      kindLabel: stringValue(json['kindLabel']),
      unit: unit is JsonMap ? RateUnit.fromJson(unit) : null,
      course: course is JsonMap ? RateCourseRef.fromJson(course) : null,
      content: stringValue(json['content']),
      status: stringValue(json['status'], 'open'),
      createdAt: dateValue(json['createdAt']),
      updatedAt: dateValue(json['updatedAt']),
      replies: _maps(json['replies']).map(RateFeedbackReply.fromJson).toList(),
    );
  }
}
