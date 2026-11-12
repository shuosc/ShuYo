import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/client_app_info.dart';
import '../models/academic_schedule.dart';
import '../models/course_review.dart';
import '../services/course_review_api_client.dart';
import '../services/student_identity_service.dart';
import 'academic_schedule_repository.dart';

/// Thrown when a review action needs a verified student first.
class CourseReviewIdentityRequired implements Exception {
  const CourseReviewIdentityRequired();

  @override
  String toString() => '请先完成身份认证';
}

class CourseReviewRepository {
  CourseReviewRepository({
    CourseReviewApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    Future<AcademicSchedule?> Function()? scheduleLoader,
    required this.studentIdentityService,
    required this.scheduleRepository,
    this.isDemo = false,
  })  : _api = apiClient ?? CourseReviewApiClient(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _scheduleLoader =
            scheduleLoader ?? scheduleRepository.loadCachedSchedule;

  static const _scheduleCollapsedKey = 'rate.home.schedule.collapsed';

  final CourseReviewApiClient _api;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final StudentIdentityService studentIdentityService;
  final AcademicScheduleRepository scheduleRepository;
  final Future<AcademicSchedule?> Function() _scheduleLoader;
  final bool isDemo;

  Future<RateCatalogConfig>? _config;

  void dispose() => _api.dispose();

  Future<bool> loadScheduleCollapsed() async {
    try {
      final preferences = await _preferencesLoader();
      return preferences.getBool(_scheduleCollapsedKey) ?? false;
    } on Object {
      return false;
    }
  }

  Future<void> saveScheduleCollapsed(bool collapsed) async {
    final preferences = await _preferencesLoader();
    if (!await preferences.setBool(_scheduleCollapsedKey, collapsed)) {
      throw StateError('课表课程折叠状态保存失败');
    }
  }

  /// Questions and categories rarely change; keep them for the app session
  /// but retry after a failure.
  Future<RateCatalogConfig> config() {
    final pending = _config ??= _api.fetchConfig();
    pending.then((_) {}, onError: (Object _) {
      if (identical(_config, pending)) _config = null;
    });
    return pending;
  }

  Future<RateHome> home() => _api.fetchHome();

  Future<RateSearchResult> search(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value(RateSearchResult.empty);
    return _api
        .search(trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed);
  }

  Future<RateCourseDetail> course(String id) => _api.fetchCourse(id);

  Future<RateTeacherDetail> teacher(String id) => _api.fetchTeacher(id);

  Future<RateUnitDetail> unit(String id) => _api.fetchUnit(id);

  Future<RateRankingResult> ranking(String category,
          {String sub = '', int page = 1}) =>
      _api.fetchRanking(category, sub: sub, page: page);

  Future<List<RateCourseSummary>> collegeCourses(String college) =>
      _api.fetchCollegeCourses(college);

  /// Distinct courses of the supplied schedule, in timetable order.
  Future<List<RateScheduleCourse>> scheduleCourses() async {
    final AcademicSchedule? schedule;
    try {
      schedule = await _scheduleLoader();
    } on Object {
      return const [];
    }
    if (schedule == null) return const [];
    final sessions = [...schedule.sessions]..sort((a, b) {
        final day = a.weekday.compareTo(b.weekday);
        return day != 0 ? day : a.startSection.compareTo(b.startSection);
      });
    final seen = <String>{};
    final courses = <RateScheduleCourse>[];
    void add(RateScheduleCourse course) {
      if (course.courseName.trim().isEmpty) return;
      if (seen.add(course.dedupeKey)) courses.add(course);
    }

    for (final session in sessions) {
      add(RateScheduleCourse(
        teachingClassId: session.teachingClassId,
        courseCode: session.isManual ? '' : session.courseCode,
        courseName: session.courseName.trim(),
        teacherName: session.teacherName.trim(),
      ));
    }
    for (final course in schedule.untimedCourses) {
      add(RateScheduleCourse(
        teachingClassId: '',
        courseCode: '',
        courseName: course.courseName.trim(),
        teacherName: course.teacherName.trim(),
      ));
    }
    return courses.length > 60 ? courses.sublist(0, 60) : courses;
  }

  Future<List<RateScheduleMatch>> matchSchedule() async {
    final courses = await scheduleCourses();
    if (courses.isEmpty) return const [];
    final results = await _api.lookup(courses);
    return [
      for (var i = 0; i < courses.length && i < results.length; i++)
        RateScheduleMatch(course: courses[i], result: results[i]),
    ];
  }

  Future<String> _token() async {
    if (isDemo) throw const CourseReviewIdentityRequired();
    if (!await studentIdentityService.ensureForProtectedAction()) {
      throw const CourseReviewIdentityRequired();
    }
    final session = await studentIdentityService.loadLocalSession();
    if (session == null) throw const CourseReviewIdentityRequired();
    return session.token;
  }

  /// Returns null without a verified session instead of asking for one.
  Future<String?> _quietToken() async {
    if (isDemo) return null;
    try {
      final session = await studentIdentityService.loadLocalSession();
      return session?.token;
    } on Object {
      return null;
    }
  }

  Future<RateMyReview?> myReview(String unitId) async {
    final token = await _quietToken();
    if (token == null) return null;
    return _api.fetchMyReview(token, unitId);
  }

  Future<RateMyReviews> myReviews() async =>
      _api.fetchMyReviews(await _token());

  Future<RateMyReview> saveReview(String unitId, RateReviewDraft draft) async =>
      _api.saveReview(await _token(), unitId, draft);

  Future<void> deleteReview(String unitId) async =>
      _api.deleteReview(await _token(), unitId);

  Future<List<RateFeedbackTicket>> feedback() async =>
      _api.listFeedback(await _token());

  Future<RateFeedbackTicket> feedbackDetail(String id) async =>
      _api.fetchFeedback(await _token(), id);

  Future<RateFeedbackTicket> closeFeedback(String id) async =>
      _api.closeFeedback(await _token(), id);

  Future<String> submitFeedback({
    required String kind,
    required String content,
    String unitId = '',
    String courseId = '',
  }) async =>
      _api.submitFeedback(
        await _token(),
        kind: kind,
        content: content,
        unitId: unitId,
        courseId: courseId,
        appVersion: ClientAppInfo.displayVersion,
        platform: Platform.operatingSystem,
      );
}
