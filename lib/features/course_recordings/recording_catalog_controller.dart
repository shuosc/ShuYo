import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_exception.dart';
import 'recording_lesson_selection.dart';
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
      recordingCourseHasCompleteAvailability(
        lessonsLoaded: lessonCounts.containsKey(course.teachingClassId),
        requested: requestedLessonCounts.contains(course.teachingClassId),
        pending: pendingLessonCounts.contains(course.teachingClassId),
      );

  bool hasPlayableCourse(VodCourse course) => recordingCourseHasPlayable(
        hasPlayableLessons:
            lessonCounts[course.teachingClassId]?.lessonIds.isNotEmpty == true,
        liveLesson: course.liveLesson,
      );
}

/// Owns catalog requests and derived data without depending on a widget/frame.
/// A course completion changes its own immutable catalog, while timetable
/// indexing is lazy so the hidden timetable never competes with list scrolling.
class RecordingCatalogController extends ChangeNotifier {
  RecordingCatalogController(this.repository,
      {required this.onSessionInvalidated,
      Future<RecordingTimetableData> Function(RecordingTimetableInput)
          timetableLoader = loadRecordingTimetable})
      : _timetableLoader = timetableLoader;

  final VodRepository repository;
  final Future<void> Function(bool ssoExpired) onSessionInvalidated;
  final Future<RecordingTimetableData> Function(RecordingTimetableInput)
      _timetableLoader;
  List<VodTerm> terms = const [];
  List<VodCourse> courses = const [];
  List<VodCourse> _visibleCourses = const [];
  Map<int, int> _visibleIndexes = const {};
  bool _visibleDirty = false;
  bool _publishScheduled = false;
  Timer? _drainTimer;
  int _completionsSinceYield = 0;
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
  // Pull-to-refresh replaces content without a top progress bar. A normal load
  // (first entry or a term switch) keeps it until pending counts settle.
  bool _progressSuppressed = false;
  Completer<void>? _completion;
  RecordingTimetableData? _timetable;
  Future<RecordingTimetableData>? _timetableFuture;
  Future<RecordingTimetableData>? _timetableWork;
  int? _timetableWorkTermId;
  int _dataRevision = 0;

  bool get isLoading => loading || pendingLessonCounts.isNotEmpty;
  bool get showLoadingProgress => isLoading && !_progressSuppressed;
  VodTerm? get selectedTerm =>
      terms.where((term) => term.id == selectedTermId).firstOrNull;
  List<VodCourse> get visibleCourses {
    _updateVisibleCourses();
    return _visibleCourses;
  }

  Map<int, int> get visibleIndexes {
    _updateVisibleCourses();
    return _visibleIndexes;
  }

  void _updateVisibleCourses() {
    if (!_visibleDirty) return;
    _visibleDirty = false;
    // Live courses stay pinned above recordings. The repository already
    // partitions its snapshots; repeating it here keeps ordering stable while
    // lesson counts arrive out of order.
    bool counted(VodCourse course) =>
        lessonCounts.containsKey(course.teachingClassId) ||
        failedLessonCounts.contains(course.teachingClassId);
    _visibleCourses = List.unmodifiable([
      ...courses.where((course) => course.isLive && counted(course)),
      ...courses.where((course) => !course.isLive && counted(course)),
    ]);
    _visibleIndexes = Map.unmodifiable({
      for (var index = 0; index < _visibleCourses.length; index++)
        _visibleCourses[index].teachingClassId: index,
    });
  }

  RecordingTimetableData get timetable => _timetable ??= RecordingTimetableData(
      term: selectedTerm, courses: courses, lessonsByCourse: courseLessons);

  /// Reuse one future for a catalog revision. A newer catalog may supersede a
  /// worker without allowing its eventual result to replace the current cache.
  /// Superseded queued reads settle with a previous same-term snapshot; the
  /// viewport observes the latest future instead of starting obsolete workers.
  Future<RecordingTimetableData> loadTimetable() {
    final pending = _timetableFuture;
    if (pending != null) return pending;
    final cached = _timetable;
    if (cached != null) {
      return _timetableFuture = SynchronousFuture(cached);
    }
    final revision = _dataRevision;
    final input = RecordingTimetableInput(
      term: selectedTerm,
      courses: courses,
      lessonsByCourse: courseLessons,
    );
    final active = _timetableWork;
    final activeTermId = _timetableWorkTermId;
    // Sorting cannot be cancelled once handed to another isolate. Wait for the
    // single in-flight worker, then start only the newest requested revision.
    return _timetableFuture = active == null
        ? _loadTimetable(input, revision)
        : active.then(
            (data) => _loadTimetable(input, revision,
                obsoleteFallback: activeTermId == input.term?.id ? data : null),
            onError: (Object _, StackTrace __) =>
                _loadTimetable(input, revision));
  }

  Future<RecordingTimetableData> _loadTimetable(
      RecordingTimetableInput input, int revision,
      {RecordingTimetableData? obsoleteFallback}) {
    if (_disposed || revision != _dataRevision) {
      // The corresponding viewport has already moved on. Settle its old future
      // without sorting obsolete lessons or exposing another term's snapshot.
      return SynchronousFuture(obsoleteFallback ??
          RecordingTimetableData(
              term: input.term, courses: const [], lessonsByCourse: const {}));
    }
    RecordingTimetableData cache(RecordingTimetableData data) {
      if (!_disposed && revision == _dataRevision) _timetable = data;
      return data;
    }

    final loading = _timetableLoader(input);
    if (loading is SynchronousFuture<RecordingTimetableData>) {
      return loading.then(cache);
    }
    late final Future<RecordingTimetableData> work;
    work = loading.then((data) {
      if (identical(_timetableWork, work)) _timetableWork = null;
      return cache(data);
    }, onError: (Object error, StackTrace stack) {
      if (identical(_timetableWork, work)) _timetableWork = null;
      Error.throwWithStackTrace(error, stack);
    });
    _timetableWork = work;
    _timetableWorkTermId = input.term?.id;
    return work;
  }

  bool _isCurrent(int revision) => !_disposed && revision == _revision;

  void _publish({bool dataChanged = false}) {
    if (_disposed) return;
    if (dataChanged) {
      _timetable = null;
      _timetableFuture = null;
      _dataRevision++;
      _visibleDirty = true;
    }
    // A warm cache can finish many course requests in the same event turn.
    // Publish once for that batch and build the index only when it is read.
    if (!_publishScheduled) {
      _publishScheduled = true;
      scheduleMicrotask(() {
        _publishScheduled = false;
        if (!_disposed) notifyListeners();
      });
    }
  }

  void clear({bool clearTerms = true}) {
    _revision++;
    _cancelDrain();
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
    // Pull-to-refresh only waits for the catalog request. Pending lesson counts
    // keep running in the background so rows can recover one by one.
    if (_disposed || fromPull && (loading || pullRefreshing)) return;
    _complete(force: true);
    final completion = Completer<void>();
    _completion = completion;
    final revision = ++_revision;
    _cancelDrain();
    loading = true;
    pullRefreshing = fromPull;
    _progressSuppressed = fromPull;
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
    // Lesson counts are a background refinement; the pull gesture ends with
    // the catalog request so the list unlocks while counts settle.
    if (!force && loading) return;
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
    if (_drainTimer != null) return;
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
      if (++_completionsSinceYield >= 8 && _queue.isNotEmpty) {
        _completionsSinceYield = 0;
        _drainTimer ??= Timer(Duration.zero, () {
          _drainTimer = null;
          _drain();
        });
      } else {
        _drain();
      }
    }
  }

  bool hasCompleteAvailability(VodCourse course) =>
      recordingCourseHasCompleteAvailability(
        lessonsLoaded: lessonCounts.containsKey(course.teachingClassId),
        requested: requestedLessonCounts.contains(course.teachingClassId),
        pending: pendingLessonCounts.contains(course.teachingClassId),
      );

  bool hasPlayableCourse(VodCourse course) => recordingCourseHasPlayable(
        hasPlayableLessons:
            lessonCounts[course.teachingClassId]?.lessonIds.isNotEmpty == true,
        liveLesson: course.liveLesson,
      );

  void _cancelDrain() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _completionsSinceYield = 0;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _cancelDrain();
    _queue.clear();
    _complete(force: true);
    super.dispose();
  }
}
