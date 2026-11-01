import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/course_recording.dart';
import '../../data/models/vod_search_result.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';

class RecordingSearchViewData {
  RecordingSearchViewData(RecordingSearchController controller)
      : selectedTermId = controller.selectedTermId,
        revision = controller.revision,
        courses = controller.courses,
        courseLessons = Map.unmodifiable(controller.courseLessons),
        extraMatches = Map.unmodifiable(controller.extraMatches),
        visibleCourseCount = controller.visibleCourseCount,
        availableCourseCount = controller.availableCourseCount,
        activeKeyword = controller.activeKeyword,
        error = controller.error,
        searching = controller.searching,
        loadingCourses = controller.loadingCourses,
        needsLogin = controller.needsLogin,
        hasResults = controller.results.isNotEmpty;

  final int selectedTermId;
  final int revision;
  final List<VodCourse> courses;
  final Map<(int, int), List<VodLesson>> courseLessons;
  final Map<(int, int), String> extraMatches;
  final int visibleCourseCount;
  final int availableCourseCount;
  final String? activeKeyword;
  final Object? error;
  final bool searching;
  final bool loadingCourses;
  final bool needsLogin;
  final bool hasResults;
}

/// Search, matching, bounded metadata requests and cancellation live outside
/// the widget tree. No row construction or animation drives the worker queue.
class RecordingSearchController extends ChangeNotifier {
  RecordingSearchController(this.repository,
      {required this.selectedTermId, this.onSessionInvalidated});

  final VodRepository repository;
  final Future<void> Function(bool ssoExpired)? onSessionInvalidated;
  int selectedTermId;
  int revision = 0;
  bool _disposed = false;
  List<VodSearchResult> results = const [];
  List<VodCourse> courses = const [];
  final courseLessons = <(int, int), List<VodLesson>>{};
  final extraMatches = <(int, int), String>{};
  int visibleCourseCount = 0;
  int availableCourseCount = 0;
  String? activeKeyword;
  Object? error;
  bool searching = false;
  bool loadingCourses = false;
  bool needsLogin = false;

  bool _isCurrent(int value) => !_disposed && value == revision;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void clear({bool requireLogin = false}) {
    revision++;
    results = const [];
    courses = const [];
    courseLessons.clear();
    extraMatches.clear();
    visibleCourseCount = 0;
    availableCourseCount = 0;
    activeKeyword = null;
    error = null;
    searching = false;
    loadingCourses = false;
    if (requireLogin) needsLogin = true;
    _publish();
  }

  void selectTerm(int termId) {
    selectedTermId = termId;
    clear();
  }

  void sessionRecovered(bool recovered) {
    if (_disposed) return;
    needsLogin = !recovered;
    _publish();
  }

  Future<void> search(String keyword, {bool forceRefresh = false}) async {
    if (_disposed || needsLogin) return;
    final query = keyword.trim().toLowerCase();
    if (query.isEmpty) {
      clear();
      return;
    }
    clear();
    final current = revision;
    activeKeyword = keyword.trim();
    searching = true;
    _publish();
    try {
      final response = await repository.searchLessons(
          termId: selectedTermId, keyword: keyword.trim());
      if (!_isCurrent(current)) return;
      final matchingClasses = <(int, int)>{};
      final preferred = <(int, int), VodSearchResult>{};
      for (final result in response) {
        if (!_matches(result, query)) continue;
        final key = (result.course.termId, result.course.teachingClassId);
        matchingClasses.add(key);
        preferred.putIfAbsent(key, () => result);
      }
      final groups = <(int, int), List<VodSearchResult>>{};
      results = List.unmodifiable(response.where((result) => matchingClasses
          .contains((result.course.termId, result.course.teachingClassId))));
      for (final result in results) {
        groups.putIfAbsent(
            (result.course.termId, result.course.teachingClassId),
            () => []).add(result);
      }
      courses = List.unmodifiable([
        for (final key in groups.keys) preferred[key]!.course,
      ]);
      for (final entry in preferred.entries) {
        final course = entry.value.course;
        final courseNumber = entry.value.courseNumber;
        extraMatches[entry.key] = [
          if (course.teachingClassName.isNotEmpty &&
              course.teachingClassName != course.name &&
              course.teachingClassName.toLowerCase().contains(query))
            course.teachingClassName,
          if (courseNumber.isNotEmpty &&
              courseNumber != course.code &&
              courseNumber.toLowerCase().contains(query))
            courseNumber,
        ].join(' · ');
      }
      searching = false;
      loadingCourses = courses.isNotEmpty;
      _publish();
      final pending = courses;
      var nextCourse = 0;
      Future<void> loadNext() async {
        while (_isCurrent(current) && nextCourse < pending.length) {
          final course = pending[nextCourse++];
          List<VodLesson> lessons;
          try {
            lessons = await repository.loadPreviewLessons(course,
                forceRefresh: forceRefresh);
          } on VodSessionExpiredException {
            rethrow;
          } on VodCampusAuthRequiredException {
            rethrow;
          } on Object {
            lessons = const [];
          }
          if (!_isCurrent(current)) return;
          final catalog = <int, VodLesson>{
            for (final lesson in lessons)
              if (lesson.id > 0 &&
                  !lesson.isLive &&
                  lesson.teachingClassId == course.teachingClassId)
                lesson.id: lesson,
          }.values.toList()
            ..sort((a, b) {
              final byTime = (b.beginTime?.millisecondsSinceEpoch ?? 0)
                  .compareTo(a.beginTime?.millisecondsSinceEpoch ?? 0);
              return byTime == 0 ? b.id.compareTo(a.id) : byTime;
            });
          courseLessons[(course.termId, course.teachingClassId)] =
              List.unmodifiable(catalog);
          if (catalog.isNotEmpty) availableCourseCount++;
          // Requests may finish out of order; reveal only the completed prefix.
          while (visibleCourseCount < courses.length) {
            final next = courses[visibleCourseCount];
            if (!courseLessons
                .containsKey((next.termId, next.teachingClassId))) {
              break;
            }
            visibleCourseCount++;
          }
          _publish();
        }
      }

      await Future.wait([
        for (var worker = 0; worker < 3 && worker < pending.length; worker++)
          loadNext(),
      ], eagerError: true);
    } on VodSessionExpiredException catch (failure) {
      if (!_isCurrent(current)) return;
      clear(requireLogin: true);
      await onSessionInvalidated?.call(failure.ssoExpired);
    } on VodCampusAuthRequiredException catch (failure) {
      if (!_isCurrent(current)) return;
      clear(requireLogin: true);
      await onSessionInvalidated?.call(failure.ssoExpired);
    } on Object catch (failure) {
      if (_isCurrent(current)) error = failure;
    } finally {
      if (_isCurrent(current)) {
        searching = false;
        loadingCourses = false;
        _publish();
      }
    }
  }

  bool _matches(VodSearchResult result, String query) {
    final course = result.course;
    return [
      course.name,
      course.teachingClassName,
      course.code,
      result.courseNumber,
      ...course.teacherNames,
    ].any((value) => value.toLowerCase().contains(query));
  }

  @override
  void dispose() {
    _disposed = true;
    revision++;
    super.dispose();
  }
}
