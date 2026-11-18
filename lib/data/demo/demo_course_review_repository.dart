import '../models/academic_schedule.dart';
import '../models/course_review.dart';
import '../repositories/course_review_repository.dart';
import '../services/client_backend_api_client.dart';

typedef _CatalogUnit = ({
  RateCourseRef course,
  RateTeacherRef teacher,
  int index
});

class DemoCourseReviewRepository extends CourseReviewRepository {
  DemoCourseReviewRepository({
    required AcademicSchedule? schedule,
    required super.scheduleRepository,
    required super.scheduleLoader,
  }) : super.offline() {
    if (schedule == null) return;
    for (final session in schedule.sessions) {
      _addCourse(session.courseCode, session.courseName, session.teacherName,
          session.credit);
    }
    for (final (index, course) in schedule.untimedCourses.indexed) {
      _addCourse('DEMO-S${index + 1}', course.courseName, course.teacherName,
          course.credit);
    }
  }

  static const _colleges = ['计算机学院', '公共基础教学部'];
  static const _category = RateCategory(
    key: 'overall',
    title: '综合评分榜',
    subcategories: _colleges,
  );
  static const _config = RateCatalogConfig(
    questions: [
      RateQuestion(
        key: RateQuestion.overallKey,
        title: '总体评价',
        multiple: false,
        required: true,
        options: [
          RateOption(key: '1', label: '不太推荐'),
          RateOption(key: '2', label: '有待改进'),
          RateOption(key: '3', label: '中规中矩'),
          RateOption(key: '4', label: '值得推荐'),
          RateOption(key: '5', label: '强烈推荐'),
        ],
      ),
      RateQuestion(
        key: 'grading',
        title: '给分倾向',
        multiple: false,
        required: false,
        options: [
          RateOption(key: 'strict', label: '要求严格'),
          RateOption(key: 'fair', label: '给分合理'),
          RateOption(key: 'generous', label: '给分宽松'),
        ],
      ),
      RateQuestion(
        key: 'teaching',
        title: '课堂体验',
        multiple: true,
        required: false,
        maxSelections: 2,
        options: [
          RateOption(key: 'clear', label: '讲解清晰'),
          RateOption(key: 'interactive', label: '互动充分'),
          RateOption(key: 'practical', label: '注重实践'),
          RateOption(key: 'fast', label: '节奏较快'),
        ],
      ),
    ],
    categories: [_category],
    feedbackKinds: [],
  );
  static const _sampleReviews = [
    RateReviewDraft(overall: 5, answers: {
      'grading': ['fair'],
      'teaching': ['clear', 'practical'],
    }),
    RateReviewDraft(overall: 4, answers: {
      'grading': ['fair'],
      'teaching': ['interactive'],
    }),
    RateReviewDraft(overall: 4, answers: {
      'grading': ['strict'],
      'teaching': ['clear'],
    }),
    RateReviewDraft(overall: 3, answers: {
      'grading': ['strict'],
      'teaching': ['fast'],
    }),
    RateReviewDraft(overall: 5, answers: {
      'grading': ['generous'],
      'teaching': ['interactive', 'practical'],
    }),
  ];
  static const _feedbackUnavailable = ClientBackendApiException('演示模式暂不支持课评反馈');

  final _courses = <String, RateCourseRef>{};
  final _teachers = <String, RateTeacherRef>{};
  final _catalog = <String, _CatalogUnit>{};
  final _myReviews = <String, RateMyReview>{};
  final _startedAt = DateTime.now();
  bool _scheduleCollapsed = false;

  void _addCourse(
      String code, String name, String teacherName, String credits) {
    if (name.trim().isEmpty || teacherName.trim().isEmpty) return;
    final college =
        code.startsWith('JBK') || code.startsWith('BBK') || name == '计算思维实训'
            ? _colleges.first
            : _colleges.last;
    final course = _courses.putIfAbsent(
        code,
        () => RateCourseRef(
              id: code,
              name: name,
              college: college,
              credits: credits,
            ));
    final teacher = _teachers.putIfAbsent(
        teacherName,
        () => RateTeacherRef(
              id: 'demo-teacher-${_teachers.length + 1}',
              name: teacherName,
              college: '',
              title: '',
              duplicateName: false,
            ));
    _catalog.putIfAbsent('${course.id}:${teacher.id}',
        () => (course: course, teacher: teacher, index: _catalog.length));
  }

  @override
  void dispose() => _myReviews.clear();

  @override
  Future<bool> loadScheduleCollapsed() async => _scheduleCollapsed;

  @override
  Future<void> saveScheduleCollapsed(bool collapsed) async {
    _scheduleCollapsed = collapsed;
  }

  @override
  Future<RateCatalogConfig> config({bool forceRefresh = false}) async =>
      _config;

  @override
  Future<RateHome> home() async {
    final units = _units;
    final recent = units
      ..sort((a, b) => b.lastReviewedAt!.compareTo(a.lastReviewedAt!));
    final ranked = _rankedUnits(units);
    return RateHome(
      recent: recent.take(8).toList(),
      rankings: ranked.isEmpty
          ? const []
          : [
              RateRankingPreview(
                key: _category.key,
                title: _category.title,
                total: ranked.length,
                items: ranked.take(6).toList(),
              ),
            ],
      colleges: [
        for (final college in _colleges)
          if (_courses.values.any((course) => course.college == college))
            RateCollege(
                name: college,
                courseCount: _courses.values
                    .where((course) => course.college == college)
                    .length),
      ],
    );
  }

  @override
  Future<RateSearchResult> search(String query) async {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return RateSearchResult.empty;
    final terms = trimmed.split(RegExp(r'\s+'));
    bool matches(String text) => terms.every(text.toLowerCase().contains);
    final units = _units;
    return RateSearchResult(
      units: units
          .where((unit) => matches(
              '${unit.course.name} ${unit.course.id} ${unit.teacher.name}'))
          .toList(),
      courses: [
        for (final course in _courses.values)
          if (matches('${course.id} ${course.name}'))
            _courseSummary(course, units),
      ],
      teachers: [
        for (final teacher in _teachers.values)
          if (matches(teacher.name)) _teacherSummary(teacher, units),
      ],
    );
  }

  @override
  Future<RateCourseDetail> course(String id) async {
    final course = _courses[id];
    if (course == null) throw const ClientBackendApiException('找不到演示课程');
    return RateCourseDetail(
        course: course,
        units: _units.where((unit) => unit.course.id == id).toList());
  }

  @override
  Future<RateTeacherDetail> teacher(String id) async {
    final teacher =
        _teachers.values.where((teacher) => teacher.id == id).firstOrNull;
    if (teacher == null) throw const ClientBackendApiException('找不到演示教师');
    return RateTeacherDetail(
        teacher: teacher,
        units: _units.where((unit) => unit.teacher.id == id).toList());
  }

  @override
  Future<RateUnitDetail> unit(String id) async {
    final catalogUnit = _findUnit(id);
    final reviews = _reviewsFor(id, catalogUnit);
    return RateUnitDetail(
      unit: _unit(id, catalogUnit, reviews),
      stats: [
        for (final question in _config.questions) _stats(question, reviews)
      ],
    );
  }

  @override
  Future<RateRankingResult> ranking(String category,
      {String sub = '', int page = 1}) async {
    if (category != _category.key || page < 1) {
      throw const ClientBackendApiException('找不到演示排行榜');
    }
    const pageSize = 8;
    final ranked = _rankedUnits(
        _units.where((unit) => sub.isEmpty || unit.course.college == sub));
    return RateRankingResult(
      key: category,
      title: _category.title,
      subcategories: _category.subcategories,
      total: ranked.length,
      page: page,
      pageSize: pageSize,
      items: ranked.skip((page - 1) * pageSize).take(pageSize).toList(),
    );
  }

  @override
  Future<List<RateCourseSummary>> collegeCourses(String college) async {
    final units = _units;
    return [
      for (final course in _courses.values)
        if (course.college == college) _courseSummary(course, units)
    ];
  }

  @override
  Future<List<RateScheduleMatch>> matchSchedule() async {
    final courses = await scheduleCourses();
    final units = _units;
    return [
      for (final course in courses)
        RateScheduleMatch(
          course: course,
          result: _match(course, units),
        )
    ];
  }

  RateLookupResult _match(RateScheduleCourse course, List<RateUnit> units) {
    final candidates = units
        .where((unit) => course.courseCode.isNotEmpty
            ? unit.course.id == course.courseCode
            : unit.course.name == course.courseName)
        .toList();
    final matches = candidates
        .where((unit) => unit.teacher.name == course.teacherName)
        .toList();
    return RateLookupResult(
      status: matches.length == 1
          ? RateLookupStatus.unit
          : candidates.isNotEmpty
              ? RateLookupStatus.course
              : RateLookupStatus.search,
      unit: matches.length == 1 ? matches.single : null,
      courseId: candidates.firstOrNull?.course.id ?? '',
      units: matches,
      query: course.courseName,
    );
  }

  @override
  Future<RateMyReview?> myReview(String unitId) async => _myReviews[unitId];

  @override
  Future<RateMyReviews> myReviews() async {
    final reviews = _myReviews.values.toList()
      ..sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
    final units = {for (final unit in _units) unit.id: unit};
    return RateMyReviews(blocked: false, reviews: [
      for (final review in reviews)
        RateMyReviewItem(
          id: review.id,
          overall: review.overall,
          hasGrading: review.answers['grading']?.isNotEmpty == true,
          updatedAt: review.updatedAt,
          unit: units[review.unitId]!,
        ),
    ]);
  }

  @override
  Future<RateMyReview> saveReview(String unitId, RateReviewDraft draft) async {
    _findUnit(unitId);
    final error = draft.validate(_config.questions);
    if (error != null) throw ClientBackendApiException(error.message);
    final answers = {
      ...?_myReviews[unitId]?.answers,
      for (final question in _config.questions)
        if (!question.isOverall && draft.answers.containsKey(question.key))
          question.key:
              List<String>.unmodifiable(draft.answers[question.key]!.toSet()),
    };
    return _myReviews[unitId] = RateMyReview(
      id: 'demo-review:$unitId',
      unitId: unitId,
      overall: draft.overall,
      answers: Map.unmodifiable(answers),
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> deleteReview(String unitId) async {
    _myReviews.remove(unitId);
  }

  @override
  Future<List<RateFeedbackTicket>> feedback() async =>
      throw _feedbackUnavailable;

  @override
  Future<RateFeedbackTicket> feedbackDetail(String id) async =>
      throw _feedbackUnavailable;

  @override
  Future<RateFeedbackTicket> closeFeedback(String id) async =>
      throw _feedbackUnavailable;

  @override
  Future<String> submitFeedback({
    required String kind,
    required String content,
    String unitId = '',
    String courseId = '',
  }) async =>
      throw _feedbackUnavailable;

  _CatalogUnit _findUnit(String id) =>
      _catalog[id] ?? (throw const ClientBackendApiException('找不到演示课评'));

  List<RateReviewDraft> _reviewsFor(String id, _CatalogUnit unit) {
    final mine = _myReviews[id];
    return [
      for (var offset = 0; offset < 2 + unit.index % 3; offset++)
        _sampleReviews[(unit.index + offset) % _sampleReviews.length],
      if (mine != null)
        RateReviewDraft(overall: mine.overall, answers: mine.answers),
    ];
  }

  List<RateUnit> get _units => [
        for (final entry in _catalog.entries)
          _unit(entry.key, entry.value, _reviewsFor(entry.key, entry.value))
      ];

  RateUnit _unit(String id, _CatalogUnit unit, List<RateReviewDraft> reviews) =>
      RateUnit(
        id: id,
        isCoTeacher: false,
        reviewCount: reviews.length,
        average: reviews.fold<int>(
                0, (total, review) => total + review.overall + 5) /
            reviews.length,
        lastReviewedAt: _myReviews[id]?.updatedAt ??
            _startedAt.subtract(Duration(hours: unit.index * 4 + 1)),
        course: unit.course,
        teacher: unit.teacher,
      );

  List<RateUnit> _rankedUnits(Iterable<RateUnit> units) => units.toList()
    ..sort((a, b) {
      final order = b.average!.compareTo(a.average!);
      return order != 0 ? order : b.reviewCount.compareTo(a.reviewCount);
    });

  RateCourseSummary _courseSummary(RateCourseRef course, List<RateUnit> units) {
    final matching =
        units.where((unit) => unit.course.id == course.id).toList();
    final (count, average) = _summary(matching);
    return RateCourseSummary(
        course: course,
        teacherCount: matching.length,
        reviewCount: count,
        average: average);
  }

  RateTeacherSummary _teacherSummary(
      RateTeacherRef teacher, List<RateUnit> units) {
    final matching =
        units.where((unit) => unit.teacher.id == teacher.id).toList();
    final (count, average) = _summary(matching);
    return RateTeacherSummary(
        teacher: teacher,
        courseCount: matching.length,
        reviewCount: count,
        average: average);
  }

  (int, double?) _summary(List<RateUnit> units) {
    var count = 0;
    var total = 0.0;
    for (final unit in units) {
      count += unit.reviewCount;
      total += unit.average! * unit.reviewCount;
    }
    return (count, count == 0 ? null : total / count);
  }

  RateQuestionStat _stats(
      RateQuestion question, List<RateReviewDraft> reviews) {
    final answers = [
      for (final review in reviews)
        if (question.isOverall)
          ['${review.overall}']
        else if (review.answers[question.key]?.isNotEmpty == true)
          review.answers[question.key]!
    ];
    final counts = {
      for (final option in question.options)
        option.key:
            answers.where((answer) => answer.contains(option.key)).length
    };
    final mostSelected =
        counts.values.fold<int>(0, (top, count) => count > top ? count : top);
    return RateQuestionStat(
      key: question.key,
      title: question.title,
      multiple: question.multiple,
      answered: answers.length,
      options: [
        for (final option in question.options)
          RateOptionStat(
            key: option.key,
            label: option.label,
            count: counts[option.key]!,
            percent: answers.isEmpty
                ? 0
                : (counts[option.key]! * 100 / answers.length).round(),
            top: mostSelected > 0 && counts[option.key] == mostSelected,
          )
      ],
    );
  }
}
