import 'dart:async';

import '../../core/vod_url_resolver.dart';
import '../models/course_recording.dart';
import '../models/vod_search_result.dart';
import '../services/academic_account_store.dart';
import '../services/vod_api_client.dart';
import '../services/vod_recording_cache.dart';

/// Account-scoped metadata and persistent recording links for API outages.
class VodRepository {
  VodRepository({
    VodApiClient? apiClient,
    VodApiClient Function()? clientFactory,
    VodRecordingCache? recordingCache,
    Future<String?> Function()? studentIdLoader,
    this.cacheDuration = const Duration(minutes: 3),
  })  : _apiClient = apiClient,
        _clientFactory = clientFactory ?? VodApiClient.new,
        _recordingCache = recordingCache ?? VodRecordingCache(),
        _studentIdLoader =
            studentIdLoader ?? AcademicAccountStore().loadStudentId;

  VodApiClient? _apiClient;
  final VodApiClient Function() _clientFactory;
  final Duration cacheDuration;
  final VodRecordingCache _recordingCache;
  final Future<String?> Function() _studentIdLoader;
  final _pending = <String, Future<Object?>>{};
  final _courses = <int, _Cached<List<VodCourse>>>{};
  final _lessons = <int, _Cached<List<VodLesson>>>{};
  final _previewLessons = <String, _Cached<List<VodLesson>>>{};
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

  Future<bool> hasCachedRecordings() async {
    final generation = _generation;
    final account = await _cacheAccount();
    _checkGeneration(generation);
    if (account == null) return false;
    final saved = await _recordingCache.savedLessons(account, useWebVpn, null);
    _checkGeneration(generation);
    return account == await _cacheAccount() && saved.isNotEmpty;
  }

  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) {
    final cached = _terms;
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return Future.value(cached.value);
    }
    final generation = _generation;
    return _run('terms', () async {
      final result = await _withLocalFallback<List<VodTerm>>(
        'terms',
        _client.fetchTerms,
        (terms) => terms.map(VodRecordingCache.termJson).toList(),
        (data) => _decodeList(data, VodTerm.fromJson),
      );
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
      final result = await _withLocalFallback<List<VodCourse>>(
        'courses:$termId',
        () => _client.fetchCourses(termId: termId, onProgress: publish),
        (courses) => courses.map(VodRecordingCache.courseJson).toList(),
        (data) => _decodeList(data, VodCourse.fromJson)
            .where((course) =>
                course.termId == termId && course.teachingClassId > 0)
            .toList(growable: false),
        saved: (account, vpn) async {
          final records =
              await _recordingCache.savedLessons(account, vpn, termId);
          return _decodeList(records.map((item) => item['course']).toList(),
              VodCourse.fromJson);
        },
        merge: (cached, saved) => List.unmodifiable({
          for (final course in [...cached, ...saved])
            course.teachingClassId: course,
        }.values),
      );
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
            .catchError((Object error) async {
          if (!_canUseLocalFallback(error) || !await hasCachedRecordings()) {
            throw error;
          }
          return <VodLesson>[];
        }).then(liveReady),
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
      _client
          .fetchLiveLessons(
              termId: course.termId, teachingClassId: course.teachingClassId)
          .catchError((Object error) async {
        if (!_canUseLocalFallback(error) || !await hasCachedRecordings()) {
          throw error;
        }
        return <VodLesson>[];
      }),
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

  /// Filters an already loaded catalog locally.
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

  Future<List<VodSearchResult>> searchLessons({
    required int termId,
    required String keyword,
  }) {
    final query = keyword.trim();
    if (termId <= 0 || query.runes.length < 2) {
      return Future.error(const VodApiException('请输入至少 2 个字的课程或教师关键词'));
    }
    return _run('search:$termId:$query',
        () => _client.searchLessons(termId: termId, keyword: query));
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
      final result = await _withLocalFallback<List<VodLesson>>(
        'lessons:${course.teachingClassId}',
        () => _client.fetchLessons(course),
        (lessons) => lessons
            .where((lesson) => !lesson.isLive)
            .map(VodRecordingCache.lessonJson)
            .toList(),
        (data) => _decodeList(data, VodRecordingCache.lessonFromJson)
            .where((lesson) =>
                lesson.id > 0 &&
                lesson.teachingClassId == course.teachingClassId)
            .toList(growable: false),
        saved: (account, vpn) async {
          final records =
              await _recordingCache.savedLessons(account, vpn, course.termId);
          return _decodeList(
              records
                  .where((item) =>
                      (item['course'] as Map?)?['teclId'] ==
                      course.teachingClassId)
                  .map((item) => item['lesson'])
                  .toList(),
              VodRecordingCache.lessonFromJson);
        },
        merge: (cached, saved) => List.unmodifiable({
          for (final lesson in [...cached, ...saved]) lesson.id: lesson,
        }.values),
      );
      _checkGeneration(generation);
      _lessons[course.teachingClassId] = _Cached(result);
      return result;
    });
  }

  /// The preview catalog is independent of the account's own course list.
  Future<List<VodLesson>> loadPreviewLessons(
    VodCourse course, {
    bool forceRefresh = false,
  }) async {
    if (course.termId <= 0 || course.teachingClassId <= 0) {
      throw const VodInvalidResponseException();
    }
    final generation = _generation;
    final account = await _cacheAccount();
    _checkGeneration(generation);
    final vpn = _client.useWebVpn;
    final key = 'preview:${course.termId}:${course.teachingClassId}';
    final scopedKey =
        '${Uri.encodeComponent(account ?? '')}:${vpn ? 'webvpn' : 'direct'}:$key';
    final cached = _previewLessons[scopedKey];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return cached.value;
    }
    return _run(scopedKey, () async {
      final result = await _withLocalFallback<List<VodLesson>>(
        key,
        () async {
          if (account != await _cacheAccount()) {
            throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
          }
          _checkGeneration(generation);
          final lessons = await _client.fetchPreviewLessons(course);
          _checkGeneration(generation);
          if (account != await _cacheAccount()) {
            throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
          }
          return lessons;
        },
        (lessons) => lessons.map(VodRecordingCache.lessonJson).toList(),
        (data) {
          final lessons = _decodeList(data, VodRecordingCache.lessonFromJson);
          if (lessons.any((lesson) =>
              lesson.id <= 0 ||
              lesson.teachingClassId != course.teachingClassId)) {
            throw const FormatException('录播缓存课次不匹配');
          }
          return lessons;
        },
      );
      _checkGeneration(generation);
      if (account != await _cacheAccount()) {
        throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
      }
      _checkGeneration(generation);
      _previewLessons[scopedKey] = _Cached(result);
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
    if (lesson.isLive && !lesson.canPlay) {
      throw const VodApiException('这节课当前暂无可用的播放资源');
    }
    _checkGeneration(generation);
    // Refresh links each time; coalesce simultaneous taps and fall back to the
    // last server-issued recording links when the API is unavailable.
    final playback = await _run(
        'playback:${course.teachingClassId}:${lesson.id}:${lesson.isLive}:$protocol',
        () => lesson.isLive
            ? _client.fetchLivePlayback(
                course: course, lesson: lesson, protocol: protocol)
            : _withLocalFallback<VodPlayback>(
                'playback:${course.teachingClassId}:${lesson.id}',
                () => _client.fetchPlayback(course: course, lesson: lesson),
                (playback) => {
                  'course': VodRecordingCache.courseJson(course),
                  'lesson': VodRecordingCache.lessonJson(lesson),
                  'playback': VodRecordingCache.playbackJson(playback),
                },
                (data) => _restorePlayback(data, course, lesson),
              ));
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

  static bool _canUseLocalFallback(Object error) =>
      error is VodApiException &&
      error is! VodSessionExpiredException &&
      error is! VodPermissionException &&
      (error.statusCode == null ||
          error.statusCode == 0 ||
          error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode! >= 500);

  Future<String?> _cacheAccount() async {
    try {
      final account = (await _studentIdLoader())?.trim();
      return account == null || account.isEmpty ? null : account;
    } on Object {
      return null;
    }
  }

  Future<T> _withLocalFallback<T>(
    String key,
    Future<T> Function() loader,
    Object Function(T) encode,
    FutureOr<T> Function(Object?) decode, {
    Future<T> Function(String account, bool vpn)? saved,
    T Function(T cached, T saved)? merge,
  }) async {
    final generation = _generation;
    final accountFuture = _cacheAccount();
    final vpn = _client.useWebVpn;
    try {
      final result = await loader();
      _checkGeneration(generation);
      final account = await accountFuture;
      _checkGeneration(generation);
      if (account != null && account == await _cacheAccount()) {
        _checkGeneration(generation);
        await _recordingCache.save(account, vpn, key, encode(result));
      }
      _checkGeneration(generation);
      return result;
    } on Object catch (error, stack) {
      _checkGeneration(generation);
      final account = await accountFuture;
      _checkGeneration(generation);
      if (account == null || !_canUseLocalFallback(error)) rethrow;
      T? fallback;
      try {
        final raw = await _recordingCache.load(account, vpn, key);
        if (raw != null) fallback = await decode(raw);
        if (saved != null && merge != null) {
          final additional = await saved(account, vpn);
          final combined =
              merge(fallback ?? await decode(const []), additional);
          // A missing snapshot and no saved lessons cannot turn an outage into
          // a successful empty response.
          if (raw != null || additional is List && additional.isNotEmpty) {
            fallback = combined;
          }
        }
      } on Object {
        // Corrupt or unsupported local entries preserve the original error.
      }
      _checkGeneration(generation);
      if (account != await _cacheAccount()) {
        throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
      }
      _checkGeneration(generation);
      if (fallback != null) return fallback;
      Error.throwWithStackTrace(error, stack);
    }
  }

  static List<T> _decodeList<T>(
      Object? data, T Function(Map<String, dynamic>) parse) {
    if (data is! List) throw const FormatException('无效录播缓存');
    return List.unmodifiable(data.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('无效录播缓存');
      }
      return parse(item);
    }));
  }

  Future<VodPlayback> _restorePlayback(
      Object? raw, VodCourse course, VodLesson lesson) async {
    if (raw is! Map || raw['playback'] is! Map) {
      throw const FormatException('无效录播缓存');
    }
    final data = raw['playback'] as Map;
    if (data['lessonId'] != lesson.id ||
        data['teachingClassId'] != course.teachingClassId ||
        (raw['course'] as Map?)?['acteId'] != course.termId) {
      throw const FormatException('录播缓存课次不匹配');
    }
    final rawViews = data['views'];
    if (rawViews is! List || rawViews.isEmpty) {
      throw const FormatException('录播缓存没有资源');
    }
    final views = <VodView>[];
    for (final item in rawViews) {
      if (item is! Map ||
          item['url'] is! String ||
          item['viewNumber'] is! int) {
        throw const FormatException('无效录播缓存视角');
      }
      final uri = VodUrlResolver.resolveMediaUrl(item['url'] as String,
          useWebVpn: _client.useWebVpn);
      final headers =
          Map<String, String>.of(await _client.mediaHeadersFor(uri));
      headers.removeWhere((name, _) =>
          name.toLowerCase() == 'jwt-token' ||
          name.toLowerCase() == 'authorization');
      views.add(VodView(
        viewNumber: item['viewNumber'] as int,
        url: uri,
        displayLabel: item['label'] as String?,
        httpHeaders: Map.unmodifiable(headers),
      ));
    }
    return VodPlayback(
      lessonId: lesson.id,
      teachingClassId: course.teachingClassId,
      title: data['title'] as String,
      description: data['description'] as String? ?? '',
      voiceChannel: data['voiceChannel'] as int?,
      views: List.unmodifiable(views),
    );
  }

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
    _previewLessons.clear();
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
