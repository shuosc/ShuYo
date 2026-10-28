import '../models/course_recording.dart';
import '../services/vod_api_client.dart';

/// Account-scoped, short-lived metadata only. Signed media is never cached.
class VodRepository {
  VodRepository({
    VodApiClient? apiClient,
    VodApiClient Function()? clientFactory,
    this.cacheDuration = const Duration(minutes: 3),
  })  : _apiClient = apiClient,
        _clientFactory = clientFactory ?? VodApiClient.new;

  VodApiClient? _apiClient;
  final VodApiClient Function() _clientFactory;
  final Duration cacheDuration;
  final _pending = <String, Future<Object?>>{};
  final _courses = <int, _Cached<List<VodCourse>>>{};
  final _lessons = <int, _Cached<List<VodLesson>>>{};
  final _catalog = <int, _Cached<List<VodCourse>>>{};
  final _liveGrants = <int>{};
  _Cached<List<VodTerm>>? _terms;
  int _generation = 0;
  bool _disposed = false;

  VodApiClient get _client {
    if (_disposed) throw const VodSessionExpiredException();
    return _apiClient ??= _clientFactory();
  }

  bool get useWebVpn => _client.useWebVpn;

  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) {
    final cached = _terms;
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _run('terms', () async {
      final result = await _client.fetchTerms();
      _checkGeneration(generation);
      _terms = _Cached(result);
      return result;
    });
  }

  Future<List<VodCourse>> loadCourses({
    required int termId,
    bool forceRefresh = false,
  }) {
    final cached = _courses[termId];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _run('courses:$termId', () async {
      final result = await _client.fetchCourses(termId: termId);
      _checkGeneration(generation);
      _courses[termId] = _Cached(result);
      return result;
    });
  }

  Future<List<VodCourse>> loadCatalog(
      {required int termId, bool forceRefresh = false}) {
    final cached = _catalog[termId];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) <
            const Duration(seconds: 30)) {
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _run('catalog:$termId', () async {
      final results = await Future.wait<Object>([
        loadCourses(termId: termId, forceRefresh: forceRefresh),
        _client.fetchLiveLessons(termId: termId),
      ]);
      _checkGeneration(generation);
      final courses = {
        for (final course in results[0] as List<VodCourse>)
          course.teachingClassId: course
      };
      for (final lesson in results[1] as List<VodLesson>) {
        final course = courses[lesson.teachingClassId] ?? lesson.catalogCourse;
        if (course == null || course.termId != termId) {
          throw const VodInvalidResponseException();
        }
        final existing = course.liveLesson;
        if (existing == null ||
            (lesson.beginTime?.millisecondsSinceEpoch ?? 0) >
                (existing.beginTime?.millisecondsSinceEpoch ?? 0)) {
          courses[course.teachingClassId] = course.withLiveLesson(lesson);
        }
      }
      final ordered = [
        ...courses.values.where((course) => course.isLive),
        ...courses.values.where((course) => !course.isLive)
      ];
      final result = List<VodCourse>.unmodifiable(ordered);
      _catalog[termId] = _Cached(result);
      return result;
    });
  }

  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    final generation = _generation;
    await _requireCatalogCourse(course);
    final live = await _client.fetchLiveLessons(
        termId: course.termId, teachingClassId: course.teachingClassId);
    List<VodLesson> recordings;
    try {
      recordings = await loadLessons(course, forceRefresh: forceRefresh);
    } on VodPermissionException {
      if (live.isEmpty) rethrow;
      recordings = const [];
    }
    _checkGeneration(generation);
    final combined = {
      for (final lesson in recordings) lesson.id: lesson,
      for (final lesson in live) lesson.id: lesson
    };
    final ordered = combined.values.toList()
      ..sort((first, second) {
        final byTime = (second.beginTime?.millisecondsSinceEpoch ?? 0)
            .compareTo(first.beginTime?.millisecondsSinceEpoch ?? 0);
        return byTime == 0 ? second.id.compareTo(first.id) : byTime;
      });
    return List.unmodifiable(ordered);
  }

  /// Search is deliberately limited to the ordinary authorized catalog.
  List<VodCourse> filterCourses(
    List<VodCourse> courses, {
    String keyword = '',
    String? teacher,
  }) {
    final query = keyword.trim().toLowerCase();
    final selectedTeacher = teacher?.trim();
    return List.unmodifiable(courses.where((course) {
      if (selectedTeacher != null &&
          selectedTeacher.isNotEmpty &&
          !course.teacherNames.contains(selectedTeacher)) {
        return false;
      }
      if (query.isEmpty) return true;
      return [
        course.name,
        course.teachingClassName,
        course.code,
        ...course.teacherNames,
      ].any((value) => value.toLowerCase().contains(query));
    }));
  }

  Future<List<VodLesson>> loadLessons(
    VodCourse course, {
    bool forceRefresh = false,
  }) async {
    final generation = _generation;
    await _requireCatalogCourse(course);
    _checkGeneration(generation);
    final cached = _lessons[course.teachingClassId];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return cached.value;
    }
    return _run('lessons:${course.teachingClassId}', () async {
      final result = await _client.fetchLessons(course);
      _checkGeneration(generation);
      _lessons[course.teachingClassId] = _Cached(result);
      return result;
    });
  }

  Future<VodPlayback> preparePlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    final generation = _generation;
    await _requireCatalogCourse(course);
    final lessons = lesson.isLive
        ? await loadCourseLessons(course, forceRefresh: true)
        : await loadLessons(course);
    if (!lessons.any((candidate) =>
        candidate.id == lesson.id &&
        candidate.teachingClassId == course.teachingClassId &&
        candidate.canPlay &&
        candidate.isLive == lesson.isLive)) {
      throw const VodPermissionException('这节课不在当前账号的可观看录播列表中');
    }
    _checkGeneration(generation);
    // Coalesce a double tap, but never keep the resulting signed URLs.
    final playback = await _run(
        'playback:${course.teachingClassId}:${lesson.id}:${lesson.isLive}',
        () => lesson.isLive
            ? _client.fetchLivePlayback(course: course, lesson: lesson)
            : _client.fetchPlayback(course: course, lesson: lesson));
    _checkGeneration(generation);
    if (lesson.isLive) _liveGrants.add(lesson.id);
    return playback;
  }

  Future<void> keepLiveAlive(VodCourse course, VodLesson lesson) async {
    if (!lesson.isLiveAvailable || !_liveGrants.contains(lesson.id)) {
      throw const VodPermissionException();
    }
    final generation = _generation;
    await _client.keepLiveAlive(course, lesson);
    _checkGeneration(generation);
  }

  Future<Map<String, String>> mediaHeadersFor(Uri target) =>
      _client.mediaHeadersFor(target);

  Future<void> _requireCatalogCourse(VodCourse course) async {
    final generation = _generation;
    final courses = _catalog[course.termId]?.value ??
        await loadCourses(termId: course.termId);
    _checkGeneration(generation);
    if (!courses.any((candidate) =>
        candidate.teachingClassId == course.teachingClassId &&
        candidate.termId == course.termId)) {
      throw const VodPermissionException('这门课不在当前账号的可观看课程列表中');
    }
  }

  bool _isFresh<T>(_Cached<T> cached) =>
      DateTime.now().difference(cached.createdAt) < cacheDuration;

  Future<T> _run<T>(String key, Future<T> Function() loader) {
    if (_disposed) throw const VodSessionExpiredException();
    final existing = _pending[key];
    if (existing != null) return existing.then((value) => value as T);
    final generation = _generation;
    late final Future<T> future;
    future = Future.sync(loader).then((result) {
      _checkGeneration(generation);
      return result;
    }).whenComplete(() {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
    _pending[key] = future;
    return future;
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw const VodSessionExpiredException('账号或连接方式已改变，请重新加载录播课程');
    }
  }

  /// Call after login, logout, account switch, or direct/WebVPN change.
  ///
  /// In-flight results are rejected and cannot populate the next session.
  void clear() {
    _generation++;
    _pending.clear();
    _terms = null;
    _courses.clear();
    _catalog.clear();
    _liveGrants.clear();
    _lessons.clear();
    _apiClient?.dispose();
    _apiClient = null;
  }

  void dispose() {
    clear();
    _disposed = true;
  }
}

class _Cached<T> {
  _Cached(this.value) : createdAt = DateTime.now();

  final T value;
  final DateTime createdAt;
}
