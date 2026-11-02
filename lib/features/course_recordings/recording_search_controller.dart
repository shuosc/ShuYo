import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/course_recording.dart';
import '../../data/models/vod_search_result.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';
import 'recording_lesson_selection.dart';

typedef _CourseKey = (int, int);
typedef _LiveCandidate = (_CourseKey, VodCourse, VodLesson);

class _PreparedSearch {
  const _PreparedSearch(this.results, this.groups, this.courses,
      this.liveCandidates, this.extraMatches);

  final List<VodSearchResult> results;
  final Map<_CourseKey, List<VodSearchResult>> groups;
  final List<VodCourse> courses;
  final List<_LiveCandidate> liveCandidates;
  final Map<_CourseKey, String> extraMatches;
}

// Pure data work; large responses are prepared on a worker isolate.
_PreparedSearch _prepareSearch((List<VodSearchResult>, String) input) {
  final (response, query) = input;
  final preferred = <_CourseKey, VodSearchResult>{};
  for (final result in response) {
    final course = result.course;
    if (![
      course.name,
      course.teachingClassName,
      course.code,
      result.courseNumber,
      ...course.teacherNames
    ].any((value) => value.toLowerCase().contains(query))) {
      continue;
    }
    preferred
        .putIfAbsent((course.termId, course.teachingClassId), () => result);
  }
  final results = <VodSearchResult>[];
  final groups = <_CourseKey, List<VodSearchResult>>{};
  for (final result in response) {
    final key = (result.course.termId, result.course.teachingClassId);
    if (!preferred.containsKey(key)) continue;
    results.add(result);
    groups.putIfAbsent(key, () => []).add(result);
  }
  final liveCourses = <_CourseKey, VodCourse>{};
  final liveCandidates = <_LiveCandidate>[];
  for (final key in groups.keys) {
    final course = preferred[key]!.course;
    final catalog = VodRepository.mergeSearchLessons(
        course, groups[key]!.map((result) => result.lesson), const []);
    final live = catalog.where((lesson) => lesson.isLiveAvailable).firstOrNull;
    if (live != null) {
      liveCandidates.add((key, course, live));
      liveCourses[key] = course;
    }
  }
  return _PreparedSearch(
      results,
      groups,
      [
        for (final key in groups.keys)
          if (liveCourses.containsKey(key)) liveCourses[key]!,
        for (final key in groups.keys)
          if (!liveCourses.containsKey(key)) preferred[key]!.course,
      ],
      liveCandidates,
      {
        for (final entry in preferred.entries)
          entry.key: [
            if (entry.value.course.teachingClassName.isNotEmpty &&
                entry.value.course.teachingClassName !=
                    entry.value.course.name &&
                entry.value.course.teachingClassName
                    .toLowerCase()
                    .contains(query))
              entry.value.course.teachingClassName,
            if (entry.value.courseNumber.isNotEmpty &&
                entry.value.courseNumber != entry.value.course.code &&
                entry.value.courseNumber.toLowerCase().contains(query))
              entry.value.courseNumber,
          ].join(' · '),
      });
}

class RecordingSearchViewData {
  RecordingSearchViewData(RecordingSearchController controller)
      : selectedTermId = controller.selectedTermId,
        revision = controller.revision,
        courses = List.unmodifiable(controller.courses.where((course) =>
            controller.courseLessons
                .containsKey((course.termId, course.teachingClassId)))),
        courseLessons = Map.unmodifiable(controller.courseLessons),
        extraMatches = Map.unmodifiable(controller.extraMatches),
        visibleCourseCount = controller.visibleCourseCount,
        totalCourseCount = controller.courses.length,
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
  final int totalCourseCount;
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
      final input = (response, query);
      final prepared = response.length >= 80
          ? await compute(_prepareSearch, input, debugLabel: 'vod-search-group')
          : _prepareSearch(input);
      if (!_isCurrent(current)) return;
      final groups = prepared.groups;
      final verifiedLive = <int>{};
      List<VodLesson> seedsFor((int, int) key) => [
            for (final result in groups[key]!)
              if (!result.lesson.isLive ||
                  verifiedLive.contains(result.lesson.id))
                result.lesson,
          ];
      results = List.unmodifiable(prepared.results);
      // Source live status is a discovery hint. A small independent metadata
      // check enables a real device source without waiting for VOD previews.
      for (final key in groups.keys) {
        _pendingLivePreviews[key] = Completer<List<VodLesson>>();
      }
      // Keep the service ranking within each group, but put active live
      // courses first so their preview requests are not stuck behind VODs.
      final liveCandidates = prepared.liveCandidates;
      courses = List.unmodifiable(prepared.courses);
      visibleCourseCount = 0;
      extraMatches.addAll(prepared.extraMatches);
      searching = false;
      loadingCourses = courses.isNotEmpty;
      _publish();
      final pending = courses;
      var nextCourse = 0;
      final previewReady = <(int, int)>{};
      final generatingReady = <(int, int)>{};
      final generatingTasks = <Future<void>>[];
      var nextLive = 0;
      var completedWork = 0;
      Future<void>? pendingYield;
      Future<void>? yieldIfBusy() {
        if (pendingYield != null) return pendingYield;
        if (++completedWork < 12) return null;
        completedWork = 0;
        // Cache hits can otherwise create an unbounded microtask chain and
        // starve pointer events, route transitions, and animation frames.
        return pendingYield = Future<void>.delayed(Duration.zero).then((_) {
          pendingYield = null;
        });
      }

      Future<void> validateLiveNext() async {
        while (_isCurrent(current) && nextLive < liveCandidates.length) {
          final (key, course, live) = liveCandidates[nextLive++];
          final valid = await repository.verifyLiveSearchLesson(course, live);
          if (!_isCurrent(current)) return;
          if (!valid || !live.isLiveAvailable) continue;
          verifiedLive.add(live.id);
          final wasAvailable =
              courseLessons[key]?.any(recordingLessonCanSelect) ?? false;
          courseLessons[key] = VodRepository.mergeSearchLessons(
              course, seedsFor(key), courseLessons[key] ?? const []);
          if (!wasAvailable) availableCourseCount++;
          courses = List.unmodifiable([
            for (final item in courses)
              if ((item.termId, item.teachingClassId) == key)
                item.withLiveLesson(live)
              else
                item,
          ]);
          visibleCourseCount = courseLessons.length;
          _publish();
          final yieldTask = yieldIfBusy();
          if (yieldTask != null) await yieldTask;
        }
      }

      final liveTasks = [
        for (var worker = 0;
            worker < 3 && worker < liveCandidates.length;
            worker++)
          validateLiveNext(),
      ];
      void finishCatalog((int, int) key) {
        if (!previewReady.contains(key) || !generatingReady.contains(key)) {
          return;
        }
        final completer = _pendingLivePreviews.remove(key);
        if (completer != null && !completer.isCompleted) {
          completer.complete(courseLessons[key] ?? const []);
        }
      }

      Future<void> supplement(VodCourse course, (int, int) key) async {
        List<VodLesson> generating;
        try {
          generating = await repository.loadGeneratingLessons(course,
              forceRefresh: forceRefresh);
        } on Object {
          generating = const [];
        }
        if (!_isCurrent(current)) return;
        if (generating.isNotEmpty) {
          courseLessons[key] = VodRepository.mergeSearchLessons(
              course, generating, courseLessons[key] ?? const []);
          // A completed later class is shown immediately; pending earlier
          // classes no longer hide freshly returned generation entries.
          visibleCourseCount = courseLessons.length;
          _publish();
        }
        generatingReady.add(key);
        finishCatalog(key);
      }

      Future<void> loadNext() async {
        while (_isCurrent(current) && nextCourse < pending.length) {
          final course = pending[nextCourse++];
          final key = (course.termId, course.teachingClassId);
          List<VodLesson> lessons;
          try {
            lessons = await repository.resolveSearchLessons(
                course, seedsFor(key),
                forceRefresh: forceRefresh,
                isCurrent: () => _isCurrent(current));
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
          final catalog = VodRepository.mergeSearchLessons(
              course,
              [
                ...seedsFor(key),
                ...?courseLessons[key]?.where((lesson) => lesson.isGenerating),
              ],
              lessons);
          final wasAvailable =
              courseLessons[key]?.any(recordingLessonCanSelect) ?? false;
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
          final isAvailable = catalog.any(recordingLessonCanSelect);
          if (!wasAvailable && isAvailable) availableCourseCount++;
          if (wasAvailable && !isAvailable) availableCourseCount--;
          previewReady.add(key);
          finishCatalog(key);
          visibleCourseCount = courseLessons.length;
          _publish();
          final yieldTask = yieldIfBusy();
          if (yieldTask != null) await yieldTask;
        }
      }

      var nextGenerating = 0;
      Future<void> loadGeneratingNext() async {
        while (_isCurrent(current) && nextGenerating < pending.length) {
          final course = pending[nextGenerating++];
          await supplement(course, (course.termId, course.teachingClassId));
          final yieldTask = yieldIfBusy();
          if (yieldTask != null) await yieldTask;
        }
      }

      generatingTasks.addAll([
        for (var worker = 0; worker < 3 && worker < pending.length; worker++)
          loadGeneratingNext(),
      ]);
      await Future.wait([
        for (var worker = 0; worker < 3 && worker < pending.length; worker++)
          loadNext(),
      ], eagerError: true);
      await Future.wait(generatingTasks);
      await Future.wait(liveTasks);
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

  @override
  void dispose() {
    _disposed = true;
    revision++;
    _finishPendingLivePreviews();
    super.dispose();
  }
}
