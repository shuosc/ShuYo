import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_exception.dart';
import 'recording_timetable_data.dart';

class RecordingCourseCount {
  const RecordingCourseCount({required this.playable, required this.lessonIds});

  final int playable;
  final Set<int> lessonIds;
}

/// A single render revision. Lazy list delegates must retain these collections
/// while newer requests update the controller behind a scrolling viewport.
class RecordingCatalogViewData {
  RecordingCatalogViewData(RecordingCatalogController controller)
      : terms = List.unmodifiable(controller.terms),
        courses = List.unmodifiable(controller.courses),
        visibleCourses = controller.visibleCourses,
        visibleIndexes = controller.visibleIndexes,
        selectedTermId = controller.selectedTermId,
        error = controller.error,
        loading = controller.loading,
        showLoadingProgress = controller.showLoadingProgress,
        lessonCounts = Map.unmodifiable(controller.lessonCounts),
        courseLessons = Map.unmodifiable(controller.courseLessons),
        failedLessonCounts = Set.unmodifiable(controller.failedLessonCounts),
        requestedLessonCounts =
            Set.unmodifiable(controller.requestedLessonCounts),
        pendingLessonCounts = Set.unmodifiable(controller.pendingLessonCounts);

  final List<VodTerm> terms;
  final List<VodCourse> courses;
  final List<VodCourse> visibleCourses;
  final Map<int, int> visibleIndexes;
  final int? selectedTermId;
  final Object? error;
  final bool loading;
  final bool showLoadingProgress;
  final Map<int, RecordingCourseCount> lessonCounts;
  final Map<int, List<VodLesson>> courseLessons;
  final Set<int> failedLessonCounts;
  final Set<int> requestedLessonCounts;
  final Set<int> pendingLessonCounts;

  bool hasCompleteAvailability(VodCourse course) =>
      lessonCounts.containsKey(course.teachingClassId) &&
      requestedLessonCounts.contains(course.teachingClassId) &&
      !pendingLessonCounts.contains(course.teachingClassId);

  bool hasPlayableCourse(VodCourse course) =>
      lessonCounts[course.teachingClassId]?.lessonIds.isNotEmpty == true ||
      course.liveLesson?.isLiveAvailable == true && course.liveLesson!.id > 0;
}

/// Owns catalog requests and derived data without depending on a widget/frame.
/// A course completion changes its own immutable catalog, while timetable
/// indexing is lazy so the hidden timetable never competes with list scrolling.
class RecordingCatalogController extends ChangeNotifier {
  RecordingCatalogController(this.repository,
      {required this.onSessionInvalidated});

  final VodRepository repository;
  final Future<void> Function(bool ssoExpired) onSessionInvalidated;
  List<VodTerm> terms = const [];
  List<VodCourse> courses = const [];
  List<VodCourse> visibleCourses = const [];
  Map<int, int> visibleIndexes = const {};
  final lessonCounts = <int, RecordingCourseCount>{};
  final courseLessons = <int, List<VodLesson>>{};
  final failedLessonCounts = <int>{};
  final requestedLessonCounts = <int>{};
  final pendingLessonCounts = <int>{};
  final _queue = <({VodCourse course, int revision, bool force})>[];
  final _activeKeys = <({int termId, int classId})>{};
  int _active = 0;
  int _revision = 0;
  bool _disposed = false;
  int? selectedTermId;
  Object? error;
  bool loading = false;
  bool pullRefreshing = false;
  Completer<void>? _completion;
  RecordingTimetableData? _timetable;

  bool get isLoading => loading || pendingLessonCounts.isNotEmpty;
  bool get showLoadingProgress => isLoading && !pullRefreshing;
  VodTerm? get selectedTerm =>
      terms.where((term) => term.id == selectedTermId).firstOrNull;
  RecordingTimetableData get timetable => _timetable ??= RecordingTimetableData(
      term: selectedTerm, courses: courses, lessonsByCourse: courseLessons);

  bool _isCurrent(int revision) => !_disposed && revision == _revision;

  void _publish({bool dataChanged = false}) {
    if (_disposed) return;
    if (dataChanged) {
      _timetable = null;
      visibleCourses = List.unmodifiable(courses.where((course) =>
          lessonCounts.containsKey(course.teachingClassId) ||
          failedLessonCounts.contains(course.teachingClassId)));
      visibleIndexes = Map.unmodifiable({
        for (var index = 0; index < visibleCourses.length; index++)
          visibleCourses[index].teachingClassId: index,
      });
    }
    notifyListeners();
  }

  void clear({bool clearTerms = true}) {
    _revision++;
    _complete(force: true);
    loading = false;
    error = null;
    courses = const [];
    if (clearTerms) {
      terms = const [];
      selectedTermId = null;
    }
    lessonCounts.clear();
    courseLessons.clear();
    failedLessonCounts.clear();
    requestedLessonCounts.clear();
    pendingLessonCounts.clear();
    _queue.clear();
    _publish(dataChanged: true);
  }

  Future<void> load(
      {bool force = false, int? termId, bool fromPull = false}) async {
    if (_disposed || fromPull && (isLoading || pullRefreshing)) return;
    _complete(force: true);
    final completion = Completer<void>();
    _completion = completion;
    final revision = ++_revision;
    loading = true;
    pullRefreshing = fromPull;
    error = null;
    if (courses.isEmpty || termId != null && termId != selectedTermId) {
      courses = const [];
      lessonCounts.clear();
      courseLessons.clear();
      failedLessonCounts.clear();
    }
    requestedLessonCounts.clear();
    pendingLessonCounts.clear();
    _queue.clear();
    _publish(dataChanged: true);
    try {
      final nextTerms = await repository.loadTerms(forceRefresh: force);
      if (!_isCurrent(revision)) return;
      var selected = termId ?? selectedTermId;
      if (!nextTerms.any((term) => term.id == selected)) {
        selected = nextTerms.isEmpty
            ? null
            : nextTerms
                .firstWhere((term) => term.isCurrent,
                    orElse: () => nextTerms.first)
                .id;
      }
      if (!force) {
        unawaited(
            repository.warmOwnRecordings(nextTerms, preferredTermId: selected));
      }
      if (selectedTermId != selected) {
        courses = const [];
        lessonCounts.clear();
        courseLessons.clear();
        failedLessonCounts.clear();
      }
      terms = nextTerms;
      selectedTermId = selected;
      _publish(dataChanged: true);
      final nextCourses = selected == null
          ? <VodCourse>[]
          : await repository.loadCatalog(
              termId: selected,
              forceRefresh: force,
              onProgress: (snapshot) {
                if (!_isCurrent(revision)) return;
                if (snapshot.isEmpty && courses.isNotEmpty) return;
                courses = snapshot;
                _schedule(snapshot, revision, force);
                _publish(dataChanged: true);
              });
      if (!_isCurrent(revision)) return;
      if (force) {
        unawaited(repository.warmOwnRecordings(nextTerms,
            preferredTermId: selected, forceRefresh: true));
      }
      courses = nextCourses;
      _schedule(nextCourses, revision, force);
      _publish(dataChanged: true);
    } on VodWebVpnSessionExpiredException catch (failure) {
      if (_isCurrent(revision)) error = failure;
    } on VodSessionExpiredException catch (failure) {
      if (_isCurrent(revision)) {
        await onSessionInvalidated(failure.ssoExpired);
      }
    } on Object catch (failure) {
      if (_isCurrent(revision)) error = failure;
    } finally {
      if (_isCurrent(revision)) {
        loading = false;
        _complete();
        _publish();
      }
    }
    await completion.future;
  }

  void _complete({bool force = false}) {
    if (!force && isLoading) return;
    final completion = _completion;
    _completion = null;
    pullRefreshing = false;
    completion?.complete();
  }

  void _schedule(List<VodCourse> values, int revision, bool force) {
    if (!_isCurrent(revision)) return;
    for (final course in values) {
      if (requestedLessonCounts.add(course.teachingClassId)) {
        pendingLessonCounts.add(course.teachingClassId);
        _queue.add((course: course, revision: revision, force: force));
      }
    }
    _drain();
  }

  void _drain() {
    while (!_disposed && _active < 3 && _queue.isNotEmpty) {
      final next = _queue.indexWhere((request) => !_activeKeys.contains((
            termId: request.course.termId,
            classId: request.course.teachingClassId,
          )));
      if (next < 0) return;
      final request = _queue.removeAt(next);
      if (!_isCurrent(request.revision)) continue;
      _active++;
      _activeKeys.add((
        termId: request.course.termId,
        classId: request.course.teachingClassId,
      ));
      unawaited(_loadCount(request));
    }
  }

  Future<void> _loadCount(
      ({VodCourse course, int revision, bool force}) request) async {
    final id = request.course.teachingClassId;
    try {
      final lessons = await repository.loadCourseLessons(request.course,
          forceRefresh: request.force);
      if (!_isCurrent(request.revision)) return;
      final total = <int>{};
      final playable = <int>{};
      final catalog = <VodLesson>[];
      for (final lesson in lessons) {
        if (lesson.id <= 0 || lesson.teachingClassId != id) continue;
        catalog.add(lesson);
        if (lesson.isLive
            ? lesson.isLiveAvailable
            : lesson.isPlayable || lesson.isGenerating || lesson.isListed) {
          total.add(lesson.id);
        }
        if (!lesson.isLive && lesson.isPlayable) playable.add(lesson.id);
      }
      courseLessons[id] = List.unmodifiable(catalog);
      lessonCounts[id] = RecordingCourseCount(
          playable: playable.length, lessonIds: Set.unmodifiable(total));
      failedLessonCounts.remove(id);
    } on VodWebVpnSessionExpiredException catch (failure) {
      if (_isCurrent(request.revision)) error = failure;
    } on VodWebVpnAuthRequiredException catch (failure) {
      if (_isCurrent(request.revision)) error = failure;
    } on VodSessionExpiredException catch (failure) {
      if (_isCurrent(request.revision)) {
        await onSessionInvalidated(failure.ssoExpired);
      }
    } on Object {
      if (_isCurrent(request.revision)) {
        lessonCounts.remove(id);
        courseLessons.remove(id);
        failedLessonCounts.add(id);
      }
    } finally {
      _active--;
      _activeKeys.remove((termId: request.course.termId, classId: id));
      if (_isCurrent(request.revision)) {
        pendingLessonCounts.remove(id);
        _complete();
        _publish(dataChanged: true);
      }
      _drain();
    }
  }

  bool hasCompleteAvailability(VodCourse course) =>
      lessonCounts.containsKey(course.teachingClassId) &&
      requestedLessonCounts.contains(course.teachingClassId) &&
      !pendingLessonCounts.contains(course.teachingClassId);

  bool hasPlayableCourse(VodCourse course) =>
      lessonCounts[course.teachingClassId]?.lessonIds.isNotEmpty == true ||
      course.liveLesson?.isLiveAvailable == true && course.liveLesson!.id > 0;

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _queue.clear();
    _complete(force: true);
    super.dispose();
  }
}
