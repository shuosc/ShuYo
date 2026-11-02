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
  final _pendingLivePreviews = <(int, int), Completer<List<VodLesson>>>{};
  final extraMatches = <(int, int), String>{};
  int visibleCourseCount = 0;
  int availableCourseCount = 0;
  String? activeKeyword;
  Object? error;
  bool searching = false;
  bool loadingCourses = false;
  bool needsLogin = false;

  Future<List<VodLesson>>? pendingLivePreview((int, int) key) {
    final pending = _pendingLivePreviews[key];
    return pending == null || pending.isCompleted ? null : pending.future;
  }

  void _finishPendingLivePreviews() {
    for (final pending in _pendingLivePreviews.values) {
      if (!pending.isCompleted) pending.complete(const []);
    }
    _pendingLivePreviews.clear();
  }

  bool _isCurrent(int value) => !_disposed && value == revision;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void clear({bool requireLogin = false}) {
    revision++;
    _finishPendingLivePreviews();
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
      // A current live hit is already enough to open the player. The full
      // preview still loads in the existing queue and fills in recordings.
      final liveCourses = <(int, int), VodCourse>{};
      for (final key in groups.keys) {
        final course = preferred[key]!.course;
        final catalog = VodRepository.mergeSearchLessons(
            course, groups[key]!.map((result) => result.lesson), const []);
        final live =
            catalog.where((lesson) => lesson.isLiveAvailable).firstOrNull;
        if (live == null) continue;
        courseLessons[key] = catalog;
        availableCourseCount++;
        _pendingLivePreviews[key] = Completer<List<VodLesson>>();
        liveCourses[key] = course.withLiveLesson(live);
      }
      // Keep the service ranking within each group, but put active live
      // courses first so their preview requests are not stuck behind VODs.
      courses = List.unmodifiable([
        for (final key in groups.keys)
          if (liveCourses.containsKey(key)) liveCourses[key]!,
        for (final key in groups.keys)
          if (!liveCourses.containsKey(key)) preferred[key]!.course,
      ]);
      visibleCourseCount = liveCourses.length;
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
          } on VodWebVpnAuthRequiredException {
            rethrow;
          } on VodCampusAuthRequiredException {
            rethrow;
          } on Object {
            lessons = const [];
          }
          if (!_isCurrent(current)) return;
          final key = (course.termId, course.teachingClassId);
          final catalog = VodRepository.mergeSearchLessons(
              course, groups[key]!.map((result) => result.lesson), lessons);
          final hadLessons = courseLessons[key]?.isNotEmpty ?? false;
          courseLessons[key] = catalog;
          final live =
              catalog.where((lesson) => lesson.isLiveAvailable).firstOrNull;
          if (live != null) {
            courses = List.unmodifiable([
              for (final currentCourse in courses)
                if ((currentCourse.termId, currentCourse.teachingClassId) ==
                    key)
                  currentCourse.withLiveLesson(live)
                else
                  currentCourse,
            ]);
          }
          if (!hadLessons && catalog.isNotEmpty) availableCourseCount++;
          if (hadLessons && catalog.isEmpty) availableCourseCount--;
          final pendingLive = _pendingLivePreviews.remove(key);
          if (pendingLive != null && !pendingLive.isCompleted) {
            pendingLive.complete(catalog);
          }
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
    } on VodWebVpnSessionExpiredException catch (failure) {
      if (_isCurrent(current)) error = failure;
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
        _finishPendingLivePreviews();
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
    _finishPendingLivePreviews();
    super.dispose();
  }
}
