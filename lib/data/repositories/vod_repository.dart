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
  final _catalogPreview = <int, List<VodCourse>>{};
  final _courseProgress = <String, List<VodCourse>>{};
  final _courseListeners = <String, Set<void Function(List<VodCourse>)>>{};
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
    void Function(List<VodCourse>)? onProgress,
  }) {
    final cached = _courses[termId];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      onProgress?.call(cached.value);
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _runCourses('courses:$termId', (publish) async {
      final result =
          await _client.fetchCourses(termId: termId, onProgress: publish);
      _checkGeneration(generation);
      _courses[termId] = _Cached(result);
      return result;
    }, onProgress: onProgress);
  }

  Future<List<VodCourse>> loadCatalog({
    required int termId,
    bool forceRefresh = false,
    void Function(List<VodCourse>)? onProgress,
  }) {
    final cached = _catalog[termId];
    if (!forceRefresh &&
        cached != null &&
        !_pending.containsKey('catalog:$termId') &&
        DateTime.now().difference(cached.createdAt) <
            const Duration(seconds: 30)) {
      _catalogPreview.remove(termId);
      onProgress?.call(cached.value);
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _runCourses('catalog:$termId', (publish) async {
      List<VodCourse> recordings = const [];
      List<VodLesson> live = const [];
      List<VodCourse> merge() {
        _checkGeneration(generation);
        final courses = {
          for (final course in recordings) course.teachingClassId: course
        };
        for (final lesson in live) {
          final course =
              courses[lesson.teachingClassId] ?? lesson.catalogCourse;
          if (course == null ||
              course.termId != termId ||
              course.teachingClassId != lesson.teachingClassId) {
            throw const VodInvalidResponseException();
          }
          final existing = course.liveLesson;
          if (existing == null ||
              (lesson.beginTime?.millisecondsSinceEpoch ?? 0) >
                  (existing.beginTime?.millisecondsSinceEpoch ?? 0)) {
            courses[course.teachingClassId] = course.withLiveLesson(lesson);
          }
        }
        return List<VodCourse>.unmodifiable([
          ...courses.values.where((course) => course.isLive),
          ...courses.values.where((course) => !course.isLive),
        ]);
      }

      void recordingsReady(List<VodCourse> snapshot) {
        recordings = snapshot;
        final result = merge();
        _catalogPreview[termId] = result;
        publish(result);
      }

      void liveReady(List<VodLesson> snapshot) {
        live = snapshot;
        final result = merge();
        _catalogPreview[termId] = result;
        publish(result);
      }

      await Future.wait([
        loadCourses(
          termId: termId,
          forceRefresh: forceRefresh,
          onProgress: recordingsReady,
        ).then(recordingsReady),
        _client
            .fetchLiveLessons(termId: termId, onProgress: liveReady)
            .then(liveReady),
      ]);
      final result = merge();
      _catalog[termId] = _Cached(result);
      _catalogPreview.remove(termId);
      return result;
    }, onProgress: onProgress);
  }

  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    final generation = _generation;
    await _requireCatalogCourse(course);
    VodPermissionException? recordingPermission;
    Future<List<VodLesson>> recordings() async {
      try {
        return await loadLessons(course, forceRefresh: forceRefresh);
      } on VodPermissionException catch (error) {
        recordingPermission = error;
        return const [];
      }
    }

    final results = await Future.wait([
      _client.fetchLiveLessons(
          termId: course.termId, teachingClassId: course.teachingClassId),
      recordings(),
    ]);
    _checkGeneration(generation);
    final live = results[0];
    final permission = recordingPermission;
    if (permission != null && live.isEmpty) throw permission;
    final combined = {
      for (final lesson in results[1]) lesson.id: lesson,
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
  }) =>
      _preparePlayback(course: course, lesson: lesson);

  Future<VodPlayback> prepareLivePlaybackWithProtocol({
    required VodCourse course,
    required VodLesson lesson,
    required VodLiveProtocol protocol,
  }) =>
      _preparePlayback(course: course, lesson: lesson, protocol: protocol);

  Future<VodPlayback> _preparePlayback({
    required VodCourse course,
    required VodLesson lesson,
    VodLiveProtocol protocol = VodLiveProtocol.hls,
  }) async {
    final generation = _generation;
    if (course.teachingClassId <= 0 ||
        course.termId <= 0 ||
        lesson.id <= 0 ||
        lesson.teachingClassId != course.teachingClassId) {
      throw const VodInvalidResponseException('课次与所选教学班不一致，请刷新重试');
    }
    if (!lesson.canPlay) {
      throw const VodApiException('这节课当前暂无可用的播放资源');
    }
    _checkGeneration(generation);
    // Coalesce a double tap, but never keep the resulting signed URLs.
    final playback = await _run(
        'playback:${course.teachingClassId}:${lesson.id}:${lesson.isLive}:$protocol',
        () => lesson.isLive
            ? _client.fetchLivePlayback(
                course: course, lesson: lesson, protocol: protocol)
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
    final courses = _catalogPreview[course.termId] ??
        _catalog[course.termId]?.value ??
        _courseProgress['courses:${course.termId}'] ??
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

  Future<List<VodCourse>> _runCourses(
    String key,
    Future<List<VodCourse>> Function(void Function(List<VodCourse>)) loader, {
    void Function(List<VodCourse>)? onProgress,
  }) {
    final listeners = _courseListeners.putIfAbsent(key, () => {});
    if (onProgress != null) {
      listeners.add(onProgress);
      final snapshot = _courseProgress[key];
      if (snapshot != null) onProgress(snapshot);
    }
    final generation = _generation;
    return _run(
        key,
        () => loader((snapshot) {
              _checkGeneration(generation);
              final result = List<VodCourse>.unmodifiable(snapshot);
              _courseProgress[key] = result;
              for (final listener in listeners.toList(growable: false)) {
                listener(result);
              }
            })).whenComplete(() {
      if (onProgress != null) listeners.remove(onProgress);
      if (listeners.isEmpty && identical(_courseListeners[key], listeners)) {
        _courseListeners.remove(key);
        _courseProgress.remove(key);
      }
    });
  }

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
    _catalogPreview.clear();
    _courseProgress.clear();
    _courseListeners.clear();
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
