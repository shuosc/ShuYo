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
  _Cached<List<VodTerm>>? _terms;
  int _generation = 0;
  bool _disposed = false;

  VodApiClient get _client {
    if (_disposed) throw const VodSessionExpiredException();
    return _apiClient ??= _clientFactory();
  }

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
    final lessons = await loadLessons(course);
    if (!lessons.any((candidate) =>
        candidate.id == lesson.id &&
        candidate.teachingClassId == course.teachingClassId &&
        candidate.isPlayable)) {
      throw const VodPermissionException('这节课不在当前账号的可观看录播列表中');
    }
    _checkGeneration(generation);
    // Coalesce a double tap, but never keep the resulting signed URLs.
    return _run('playback:${course.teachingClassId}:${lesson.id}',
        () => _client.fetchPlayback(course: course, lesson: lesson));
  }

  Future<void> _requireCatalogCourse(VodCourse course) async {
    final generation = _generation;
    final courses = await loadCourses(termId: course.termId);
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
