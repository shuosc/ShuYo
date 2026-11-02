import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/vod_url_resolver.dart';
import '../models/course_recording.dart';
import '../models/vod_ppt.dart';
import '../models/vod_search_result.dart';
import '../services/academic_account_store.dart';
import '../services/vod_api_client.dart';
import '../services/vod_recording_cache.dart';

/// Availability of the server-provided recording URLs, not media playback.
enum VodRecordingAvailability { available, unavailable, unknown }

/// Account-scoped metadata and persistent recording links for API outages.
class VodRepository {
  static int _nextPlaybackVersion = 0;
  static final _savedPlaybackVersions = <String, int>{};
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
  final _pptSlides = <int, _Cached<List<VodPptSlide>>>{};
  final _cachedPlaybackAvailability = <String, _Cached<Set<String>>>{};
  final _catalog = <int, _Cached<List<VodCourse>>>{};
  final _catalogPreview = <int, List<VodCourse>>{};
  final _courseProgress = <String, List<VodCourse>>{};
  final _courseListeners = <String, Set<void Function(List<VodCourse>)>>{};
  final _liveGrants = <int>{};
  static final _warmingQueue = <_RecordingWarmRequest>[];
  static final _lastWarmAttempts = <String, (DateTime, bool)>{};
  static final _availabilityAttempts =
      <String, (DateTime, VodRecordingAvailability)>{};
  @visibleForTesting
  static Duration warmingRequestSpacing = const Duration(milliseconds: 500);
  @visibleForTesting
  static Duration warmingSuccessTtl = const Duration(hours: 6);
  @visibleForTesting
  static Duration warmingFailureTtl = const Duration(minutes: 2);
  static DateTime? _nextWarmStart;
  static Timer? _warmingTimer;
  final _warmingPending = <String, Future<void>>{};
  int _forceWarmSequence = 0;
  int _probeSequence = 0;
  final _warmingTasks = <Future<void>>{};
  final _ownWarmStates = <String, _OwnWarmState>{};
  static int _activeWarmRequests = 0;
  _Cached<List<VodTerm>>? _terms;
  int _generation = 0;
  bool _disposed = false;

  VodApiClient get _client {
    if (_disposed) throw const VodSessionExpiredException();
    return _apiClient ??= _clientFactory();
  }

  bool get useWebVpn => _client.useWebVpn;

  /// PPT notes are requested on demand and kept only in this session's memory.
  Future<List<VodPptSlide>> loadPptSlides(int courseId,
      {bool forceRefresh = false}) {
    final generation = _generation;
    _checkGeneration(generation);
    if (courseId <= 0) {
      return Future.error(const VodInvalidResponseException('请选择有效课次'));
    }
    final key = 'ppt:$courseId';
    if (forceRefresh && _pending.containsKey(key)) {
      return _waitForPending(key).then((_) {
        _checkGeneration(generation);
        return loadPptSlides(courseId, forceRefresh: true);
      });
    }
    final cached = _pptSlides[courseId];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      return Future.value(cached.value);
    }
    return _run(key, () async {
      final result = List<VodPptSlide>.unmodifiable(
          await _client.fetchPptSlides(courseId));
      _checkGeneration(generation);
      _pptSlides[courseId] = _Cached(result);
      return result;
    });
  }

  Future<bool> hasCachedRecordings() async {
    final generation = _generation;
    final account = await _cacheAccount();
    _checkGeneration(generation);
    if (account == null) return false;
    final saved = await _recordingCache.hasSavedLessons(account, useWebVpn);
    _checkGeneration(generation);
    return account == await _cacheAccount() && saved;
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
    final generation = _generation;
    final pendingKey = 'courses:$termId';
    if (forceRefresh && _pending.containsKey(pendingKey)) {
      return _waitForPending(pendingKey).then((_) {
        _checkGeneration(generation);
        return loadCourses(
            termId: termId, forceRefresh: true, onProgress: onProgress);
      });
    }
    final cached = _courses[termId];
    if (!forceRefresh && cached != null && _isFresh(cached)) {
      onProgress?.call(cached.value);
      return Future.value(cached.value);
    }
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
    return _run('search:$termId:$query', () async {
      final client = _client;
      if (!RegExp(r'^[a-zA-Z0-9._/-]+$').hasMatch(query)) {
        return client.searchLessons(termId: termId, keyword: query);
      }

      Future<(List<VodSearchResult>?, Object?, StackTrace?)> attempt(
        Future<List<VodSearchResult>> Function() load,
      ) async {
        try {
          return (await load(), null, null);
        } catch (error, stack) {
          return (null, error, stack);
        }
      }

      final responses = await Future.wait([
        attempt(() => client.searchLessons(termId: termId, keyword: query)),
        attempt(
            () => client.searchCoursesByCode(termId: termId, keyword: query)),
      ]);
      for (final response in responses) {
        final error = response.$2;
        if (error is VodSessionExpiredException ||
            (error is VodApiException && error.statusCode == 401)) {
          Error.throwWithStackTrace(error!, response.$3!);
        }
      }
      final source = responses[0].$1 ?? const <VodSearchResult>[];
      final identifier = responses[1].$1 ?? const <VodSearchResult>[];
      final normalized = query.toLowerCase();
      bool matches(VodSearchResult item) => [
            item.course.name,
            item.course.teachingClassName,
            item.course.code,
            item.courseNumber,
            ...item.course.teacherNames,
          ].any((value) => value.toLowerCase().contains(normalized));
      final matchingClasses = <(int, int)>{
        for (final item in source)
          if (matches(item)) (item.course.termId, item.course.teachingClassId),
      };
      final merged = <VodSearchResult>[
        ...source,
        for (final item in identifier)
          if (matchingClasses
              .add((item.course.termId, item.course.teachingClassId)))
            item,
      ];
      if (!merged.any(matches)) {
        for (final response in responses) {
          if (response.$2 != null) {
            Error.throwWithStackTrace(response.$2!, response.$3!);
          }
        }
      }
      return List.unmodifiable(merged);
    });
  }

  Future<List<VodLesson>> loadLessons(
    VodCourse course, {
    bool forceRefresh = false,
  }) async {
    final generation = _generation;
    await _requireCatalogCourse(course);
    _checkGeneration(generation);
    if (forceRefresh) {
      await _waitForPending('lessons:${course.teachingClassId}');
      _checkGeneration(generation);
    }
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
    if (forceRefresh) {
      await _waitForPending(scopedKey);
      _checkGeneration(generation);
    }
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
        backgroundSave: true,
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

  /// Adds current live search hits to a class's existing preview catalog.
  /// Preview metadata owns recording/generation state; a fresh live hit wins
  /// over its same-ID recording placeholder until the live window ends.
  static List<VodLesson> mergeSearchLessons(
    VodCourse course,
    Iterable<VodLesson> searchLessons,
    Iterable<VodLesson> previewLessons,
  ) {
    bool belongs(VodLesson lesson) =>
        lesson.id > 0 && lesson.teachingClassId == course.teachingClassId;
    final merged = <int, VodLesson>{
      for (final lesson in searchLessons)
        if (belongs(lesson) && !lesson.isLive && lesson.isGenerating)
          lesson.id: lesson,
      for (final lesson in previewLessons)
        if (belongs(lesson) && (!lesson.isLive || lesson.isLiveAvailable))
          lesson.id: lesson,
      for (final lesson in searchLessons)
        if (belongs(lesson) && lesson.isLiveAvailable) lesson.id: lesson,
    }.values.toList()
      ..sort((first, second) {
        final byTime = (second.beginTime?.millisecondsSinceEpoch ?? 0)
            .compareTo(first.beginTime?.millisecondsSinceEpoch ?? 0);
        return byTime == 0 ? second.id.compareTo(first.id) : byTime;
      });
    return List.unmodifiable(merged);
  }

  /// Silently refreshes recording links for every valid lesson of a class.
  /// This never waits for a video player and individual failures are ignored.
  Future<void> warmCourseRecordings(VodCourse course, List<VodLesson> lessons,
          {bool forceRefresh = false}) =>
      _trackWarming(() =>
          _warmCourseRecordings(course, lessons, forceRefresh: forceRefresh));

  /// Loads a searched class and silently warms its recordings, even if the
  /// player is closed before the catalog request completes. The returned future
  /// finishes as soon as the catalog is ready, without waiting for link warming.
  Future<List<VodLesson>> loadAndWarmSearchLessons(
      VodCourse course, List<VodLesson> seed,
      {bool forceRefresh = false}) {
    final generation = _generation;
    final accountEpoch = AcademicAccountStore.sessionEpoch;
    final transportRevision = VodUrlResolver.revision;
    final result = Completer<List<VodLesson>>();
    final initialLessons = List<VodLesson>.of(seed);
    unawaited(_trackWarming(() async {
      String? account;
      List<VodLesson>? preview;
      try {
        account = await _cacheAccount();
        if (!_canContinueWarming(generation, accountEpoch, transportRevision)) {
          throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
        }
        preview = await loadPreviewLessons(course, forceRefresh: forceRefresh);
        if (!_canContinueWarming(generation, accountEpoch, transportRevision) ||
            account != await _cacheAccount() ||
            !_canContinueWarming(generation, accountEpoch, transportRevision)) {
          throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
        }
        result.complete(mergeSearchLessons(course, initialLessons, preview));
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
      if (account == null ||
          !await _warmingAccountMatches(
              generation, accountEpoch, transportRevision, account)) {
        return;
      }
      final liveIds = {
        for (final lesson in initialLessons)
          if (lesson.teachingClassId == course.teachingClassId &&
              lesson.isLiveAvailable)
            lesson.id,
      };
      final lessons = <int, VodLesson>{
        for (final lesson in initialLessons)
          if (lesson.id > 0 &&
              !lesson.isLive &&
              !liveIds.contains(lesson.id) &&
              lesson.teachingClassId == course.teachingClassId)
            lesson.id: lesson,
        for (final lesson in preview ?? <VodLesson>[])
          if (lesson.id > 0 &&
              !lesson.isLive &&
              !liveIds.contains(lesson.id) &&
              lesson.teachingClassId == course.teachingClassId)
            lesson.id: lesson,
      };
      await _warmCourseRecordings(course, lessons.values.toList(),
          forceRefresh: forceRefresh,
          scope: (
            generation: generation,
            accountEpoch: accountEpoch,
            transportRevision: transportRevision,
            account: account,
          ));
    }));
    return result.future;
  }

  /// Checks URLs without persisting them. Fresh checks never reuse warm results.
  /// An expired page/query must return false from [isCurrent], so queued work
  /// is discarded and late responses cannot affect the next result list.
  Future<void> verifyCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {required void Function(int, VodRecordingAvailability) onResult,
      required bool Function() isCurrent,
      bool fresh = false,
      bool forceRefresh = false}) async {
    final generation = _generation;
    final accountEpoch = AcademicAccountStore.sessionEpoch;
    final transportRevision = VodUrlResolver.revision;
    final account = await _cacheAccount();
    if (account == null ||
        !isCurrent() ||
        !_canContinueWarming(generation, accountEpoch, transportRevision) ||
        course.termId <= 0 ||
        course.teachingClassId <= 0) {
      return;
    }
    final vpn = _client.useWebVpn;
    // Search intentionally does not read persistent playback links. Home loads
    // one account/transport snapshot shared across concurrently built rows.
    final cachedLinks = fresh
        ? <String>{}
        : await _cachedAvailableLinks(
            account, vpn, generation, accountEpoch, transportRevision);
    if (!isCurrent() ||
        !await _warmingAccountMatches(
            generation, accountEpoch, transportRevision, account)) {
      return;
    }
    final pending = <Future<void>>[];
    final seen = <int>{};
    for (final lesson in lessons) {
      if (lesson.isLive ||
          lesson.id <= 0 ||
          lesson.teachingClassId != course.teachingClassId ||
          !seen.add(lesson.id)) {
        continue;
      }
      final attemptKey =
          '$accountEpoch:$transportRevision:${vpn ? 1 : 0}:$account:${course.termId}:'
          '${course.teachingClassId}:${lesson.id}';
      final hasCachedLink = cachedLinks
          .contains('${course.termId}:${course.teachingClassId}:${lesson.id}');
      final previous = _availabilityAttempts[attemptKey];
      if (!fresh &&
          !forceRefresh &&
          previous != null &&
          DateTime.now().difference(previous.$1) <
              (previous.$2 == VodRecordingAvailability.available
                  ? warmingSuccessTtl
                  : warmingFailureTtl)) {
        if (isCurrent()) onResult(lesson.id, previous.$2);
        continue;
      }
      if (!fresh && !forceRefresh && hasCachedLink) {
        if (isCurrent()) {
          onResult(lesson.id, VodRecordingAvailability.available);
        }
        continue;
      }
      final request = _RecordingWarmRequest(
          this,
          'probe:${++_probeSequence}',
          attemptKey,
          true,
          generation,
          accountEpoch,
          transportRevision,
          account,
          course,
          lesson,
          probe: true,
          isCurrent: isCurrent,
          fresh: fresh);
      // Search counts should not sit behind home counts or a full-account
      // warmup; home counts also take priority over silent warming.
      final insertBefore = _warmingQueue
          .indexWhere((item) => !item.probe || (fresh && !item.fresh));
      if (insertBefore < 0) {
        _warmingQueue.add(request);
      } else {
        _warmingQueue.insert(insertBefore, request);
      }
      pending.add(request.completion.future.then((_) async {
        if (!request.cancelled &&
            isCurrent() &&
            await _warmingAccountMatches(
                generation, accountEpoch, transportRevision, account) &&
            isCurrent()) {
          onResult(
              lesson.id,
              request.availability == VodRecordingAvailability.unknown &&
                      request.cacheFallbackAllowed &&
                      !fresh &&
                      hasCachedLink
                  ? VodRecordingAvailability.available
                  : request.availability);
        }
      }));
    }
    _drainWarmingQueue();
    await Future.wait(pending);
  }

  Future<Set<String>> _cachedAvailableLinks(String account, bool vpn,
      int generation, int accountEpoch, int transportRevision) async {
    final scope = '$accountEpoch:$transportRevision:${vpn ? 1 : 0}:$account';
    final cached = _cachedPlaybackAvailability[scope];
    if (cached != null && _isFresh(cached)) return cached.value;
    try {
      return await _run<Set<String>>('availability-cache:$scope', () async {
        final entries = await _recordingCache.savedLessons(account, vpn, null);
        if (!await _warmingAccountMatches(
            generation, accountEpoch, transportRevision, account)) {
          return <String>{};
        }
        final result = <String>{};
        for (final raw in entries) {
          final course = raw['course'];
          final lesson = raw['lesson'];
          final playback = raw['playback'];
          if (course is! Map || lesson is! Map || playback is! Map) continue;
          final term = course['acteId'];
          final teachingClass = course['teclId'];
          final lessonId = lesson['id'];
          final views = playback['views'];
          if (term is! int ||
              term <= 0 ||
              teachingClass is! int ||
              teachingClass <= 0 ||
              lessonId is! int ||
              lessonId <= 0 ||
              lesson['teclId'] != teachingClass ||
              playback['lessonId'] != lessonId ||
              playback['teachingClassId'] != teachingClass ||
              playback['title'] is! String ||
              views is! List ||
              views.isEmpty) {
            continue;
          }
          var valid = true;
          for (final view in views) {
            if (view is! Map ||
                view['url'] is! String ||
                view['viewNumber'] is! int) {
              valid = false;
              break;
            }
            try {
              VodUrlResolver.resolveMediaUrl(view['url'] as String,
                  useWebVpn: vpn);
            } on Object {
              valid = false;
              break;
            }
          }
          if (valid) result.add('$term:$teachingClass:$lessonId');
        }
        _cachedPlaybackAvailability[scope] = _Cached(result);
        return result;
      });
    } on Object {
      return <String>{};
    }
  }

  Future<void> _warmCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {required bool forceRefresh,
      ({
        int generation,
        int accountEpoch,
        int transportRevision,
        String account
      })? scope}) async {
    final generation = scope?.generation ?? _generation;
    final accountEpoch =
        scope?.accountEpoch ?? AcademicAccountStore.sessionEpoch;
    final transportRevision =
        scope?.transportRevision ?? VodUrlResolver.revision;
    final account = await _cacheAccount();
    if (!_canContinueWarming(generation, accountEpoch, transportRevision) ||
        account == null ||
        (scope != null && account != scope.account)) {
      return;
    }
    if (course.termId <= 0 || course.teachingClassId <= 0) return;
    final vpn = _client.useWebVpn;
    final requests = <Future<void>>[];
    final seen = <int>{};
    for (final lesson in lessons) {
      if (lesson.isLive ||
          lesson.isGenerating ||
          lesson.id <= 0 ||
          lesson.teachingClassId != course.teachingClassId ||
          !seen.add(lesson.id)) {
        continue;
      }
      final key =
          '$generation:$accountEpoch:$transportRevision:$account:${course.termId}:'
          '${course.teachingClassId}:${lesson.id}';
      final attemptKey =
          '$accountEpoch:$transportRevision:${vpn ? 1 : 0}:$account:${course.termId}:'
          '${course.teachingClassId}:${lesson.id}';
      final lastAttempt = _lastWarmAttempts[attemptKey];
      if (!forceRefresh && lastAttempt != null) {
        final ttl = lastAttempt.$2 ? warmingSuccessTtl : warmingFailureTtl;
        if (DateTime.now().difference(lastAttempt.$1) < ttl) continue;
        _lastWarmAttempts.remove(attemptKey);
      }
      final existing = _warmingPending[key];
      if (existing != null && !forceRefresh) {
        requests.add(existing);
        continue;
      }
      final requestKey =
          existing == null ? key : '$key:force:${++_forceWarmSequence}';
      final request = _RecordingWarmRequest(
          this,
          requestKey,
          attemptKey,
          forceRefresh,
          generation,
          accountEpoch,
          transportRevision,
          account,
          course,
          lesson);
      _warmingPending[requestKey] = request.completion.future;
      _warmingQueue.add(request);
      requests.add(request.completion.future);
    }
    _drainWarmingQueue();
    await Future.wait(requests);
  }

  /// Warms the account's complete course catalog without delaying the UI.
  Future<void> warmOwnRecordings(List<VodTerm> terms,
          {int? preferredTermId, bool forceRefresh = false}) =>
      _trackWarming(() => _warmOwnRecordings(terms,
          preferredTermId: preferredTermId, forceRefresh: forceRefresh));

  Future<void> _warmOwnRecordings(List<VodTerm> terms,
      {int? preferredTermId, required bool forceRefresh}) async {
    final generation = _generation;
    final accountEpoch = AcademicAccountStore.sessionEpoch;
    final transportRevision = VodUrlResolver.revision;
    final account = await _cacheAccount();
    if (!_canContinueWarming(generation, accountEpoch, transportRevision) ||
        account == null) {
      return;
    }
    final key =
        'warm-own:$generation:$accountEpoch:$transportRevision:$account';
    try {
      Future<void> scan(bool forceRefresh) async {
        final seenTerms = <int>{};
        final orderedTerms = [
          ...terms.where((term) => term.id == preferredTermId),
          ...terms
              .where((term) => term.id != preferredTermId && term.isCurrent),
          ...terms
              .where((term) => term.id != preferredTermId && !term.isCurrent),
        ];
        for (final term in orderedTerms) {
          if (!seenTerms.add(term.id) || term.id <= 0) continue;
          if (!await _warmingAccountMatches(
              generation, accountEpoch, transportRevision, account)) {
            return;
          }
          List<VodCourse> courses;
          try {
            courses =
                await loadCourses(termId: term.id, forceRefresh: forceRefresh);
          } on Object {
            continue;
          }
          for (final course in courses) {
            if (!await _warmingAccountMatches(
                generation, accountEpoch, transportRevision, account)) {
              return;
            }
            if (course.termId != term.id || course.teachingClassId <= 0) {
              continue;
            }
            final lessons = <int, VodLesson>{};
            // The regular catalog can omit recordings with outdated status
            // flags, so also try the independent preview catalog.
            try {
              for (final lesson
                  in await loadLessons(course, forceRefresh: forceRefresh)) {
                lessons[lesson.id] = lesson;
              }
            } on Object {
              // Continue with preview if the ordinary list is unavailable.
            }
            if (!await _warmingAccountMatches(
                generation, accountEpoch, transportRevision, account)) {
              return;
            }
            try {
              for (final lesson in await loadPreviewLessons(course,
                  forceRefresh: forceRefresh)) {
                lessons[lesson.id] = lesson;
              }
            } on Object {
              // Ordinary-list recordings can still be warmed.
            }
            if (!await _warmingAccountMatches(
                generation, accountEpoch, transportRevision, account)) {
              return;
            }
            await warmCourseRecordings(course, lessons.values.toList(),
                forceRefresh: forceRefresh);
          }
        }
      }

      final state = _ownWarmStates.putIfAbsent(key, _OwnWarmState.new);
      if (forceRefresh) {
        state.requestedRefresh++;
        state.latestForceScan = () => scan(true);
      }
      var active = state.active;
      if (active == null) {
        final initialNormal = !forceRefresh;
        late final Future<void> operation;
        operation = Future<void>.sync(() async {
          if (initialNormal) await scan(false);
          while (state.completedRefresh < state.requestedRefresh) {
            final target = state.requestedRefresh;
            final nextScan = state.latestForceScan!;
            if (!await _warmingAccountMatches(
                generation, accountEpoch, transportRevision, account)) {
              return;
            }
            await nextScan();
            state.completedRefresh = target;
          }
        }).whenComplete(() {
          if (identical(state.active, operation)) {
            state.active = null;
            if (identical(_ownWarmStates[key], state)) {
              _ownWarmStates.remove(key);
            }
          }
        });
        state.active = operation;
        active = operation;
      }
      await active;
    } on Object {
      // Background work is intentionally invisible to the player and UI.
    }
  }

  bool _canContinueWarming(
          int generation, int accountEpoch, int transportRevision) =>
      !_disposed &&
      generation == _generation &&
      accountEpoch == AcademicAccountStore.sessionEpoch &&
      transportRevision == VodUrlResolver.revision;

  Future<void> _trackWarming(Future<void> Function() run) {
    late final Future<void> task;
    task = Future<void>.sync(run).then<void>((_) {}, onError: (Object _) {})
      ..whenComplete(() => _warmingTasks.remove(task));
    _warmingTasks.add(task);
    return task;
  }

  /// Lets an owning page release the repository after silent warming finishes.
  Future<void> waitForBackgroundWarming() async {
    while (_warmingTasks.isNotEmpty) {
      await Future.wait(_warmingTasks.toList());
    }
  }

  Future<bool> _warmingAccountMatches(int generation, int accountEpoch,
          int transportRevision, String account) async =>
      _canContinueWarming(generation, accountEpoch, transportRevision) &&
      account == await _cacheAccount() &&
      _canContinueWarming(generation, accountEpoch, transportRevision);

  void _drainWarmingQueue() {
    // Drop obsolete page/search probes even if an unrelated request is still
    // active or newer, higher-priority work is ahead of them in the queue.
    final obsolete = _warmingQueue
        .where((request) =>
            !request.owner._canContinueWarming(request.generation,
                request.accountEpoch, request.transportRevision) ||
            (request.isCurrent != null && !request.isCurrent!()))
        .toList();
    for (final request in obsolete) {
      _warmingQueue.remove(request);
      request.owner._finishWarmingRequest(request);
    }
    if (_activeWarmRequests != 0) return;
    while (_warmingQueue.isNotEmpty) {
      final request = _warmingQueue.first;
      final owner = request.owner;
      if (!owner._canContinueWarming(request.generation, request.accountEpoch,
              request.transportRevision) ||
          (request.isCurrent != null && !request.isCurrent!())) {
        _warmingQueue.removeAt(0);
        owner._finishWarmingRequest(request);
        continue;
      }
      final lastAttempt = _lastWarmAttempts[request.attemptKey];
      if (!request.forceRefresh && lastAttempt != null) {
        final ttl = lastAttempt.$2 ? warmingSuccessTtl : warmingFailureTtl;
        if (DateTime.now().difference(lastAttempt.$1) < ttl) {
          _warmingQueue.removeAt(0);
          owner._finishWarmingRequest(request);
          continue;
        }
      }
      final wait = warmingRequestSpacing == Duration.zero
          ? Duration.zero
          : _nextWarmStart?.difference(DateTime.now()) ?? Duration.zero;
      if (wait > Duration.zero) {
        _warmingTimer ??= Timer(wait, () {
          _warmingTimer = null;
          _drainWarmingQueue();
        });
        return;
      }
      _warmingQueue.removeAt(0);
      _nextWarmStart = DateTime.now().add(warmingRequestSpacing);
      _activeWarmRequests++;
      unawaited(owner._executeWarmingRequest(request));
      return;
    }
  }

  Future<void> _executeWarmingRequest(_RecordingWarmRequest request) async {
    var fetched = false;
    try {
      while (await _warmingAccountMatches(request.generation,
          request.accountEpoch, request.transportRevision, request.account)) {
        if (request.isCurrent != null && !request.isCurrent!()) break;
        if (request.probe) {
          try {
            await _client.checkPlaybackUrls(
                course: request.course, lesson: request.lesson);
            request.availability = VodRecordingAvailability.available;
          } on VodNoPlaybackException {
            request.availability = VodRecordingAvailability.unavailable;
          } on Object catch (error) {
            request.availability = VodRecordingAvailability.unknown;
            request.cacheFallbackAllowed = error is TimeoutException ||
                (error is VodApiException &&
                    error is! VodInvalidResponseException &&
                    _canUseLocalFallback(error));
          }
          if (!await _warmingAccountMatches(
              request.generation,
              request.accountEpoch,
              request.transportRevision,
              request.account)) {
            request.cancelled = true;
            break;
          }
          if (!request.fresh &&
              request.availability != VodRecordingAvailability.unknown) {
            _availabilityAttempts[request.attemptKey] =
                (DateTime.now(), request.availability);
          }
          break;
        }
        final playbackKey = _playbackRequestKey(
            request.course, request.lesson, VodLiveProtocol.hls);
        if (request.forceRefresh && _pending.containsKey(playbackKey)) {
          await _waitForPending(playbackKey);
          continue;
        }
        await _preparePlayback(
            course: request.course,
            lesson: request.lesson,
            expectedAccount: request.account,
            onPlaybackFetched: () => fetched = true,
            warmingValid: () => _canContinueWarming(request.generation,
                request.accountEpoch, request.transportRevision));
        break;
      }
    } on Object {
      // One unavailable recording must not prevent other links being cached.
    } finally {
      if (!request.probe &&
          _canContinueWarming(request.generation, request.accountEpoch,
              request.transportRevision)) {
        _lastWarmAttempts[request.attemptKey] = (DateTime.now(), fetched);
        if (fetched) {
          _availabilityAttempts[request.attemptKey] =
              (DateTime.now(), VodRecordingAvailability.available);
        }
      }
      _activeWarmRequests--;
      _finishWarmingRequest(request);
      _drainWarmingQueue();
    }
  }

  void _finishWarmingRequest(_RecordingWarmRequest request) {
    if (identical(_warmingPending[request.key], request.completion.future)) {
      _warmingPending.remove(request.key);
    }
    if (!request.completion.isCompleted) request.completion.complete();
  }

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
    String? expectedAccount,
    bool Function()? warmingValid,
    void Function()? onPlaybackFetched,
  }) async {
    final generation = _generation;
    final accountEpoch = AcademicAccountStore.sessionEpoch;
    final transportRevision = VodUrlResolver.revision;
    bool playbackSessionValid() =>
        accountEpoch == AcademicAccountStore.sessionEpoch &&
        transportRevision == VodUrlResolver.revision &&
        (warmingValid == null || warmingValid());
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
    final result = await _run<_PlaybackResult>(
        _playbackRequestKey(course, lesson, protocol), () async {
      if (lesson.isLive) {
        final playback = await _client.fetchLivePlayback(
            course: course, lesson: lesson, protocol: protocol);
        return _PlaybackResult(playback, true);
      }
      final version = ++_nextPlaybackVersion;
      var fetched = false;
      final playback = await _withLocalFallback<VodPlayback>(
        'playback:${course.teachingClassId}:${lesson.id}',
        () async {
          final playback =
              await _client.fetchPlayback(course: course, lesson: lesson);
          fetched = true;
          return playback;
        },
        (playback) => {
          'course': VodRecordingCache.courseJson(course),
          'lesson': VodRecordingCache.lessonJson(lesson),
          'playback': VodRecordingCache.playbackJson(playback),
        },
        (data) => _restorePlayback(data, course, lesson),
        expectedAccount: expectedAccount,
        warmingValid: playbackSessionValid,
        cacheVersion: version,
        shouldSave: (account, vpn) {
          final key = '${Uri.encodeComponent(account)}:${vpn ? 1 : 0}:'
              '${course.teachingClassId}:${lesson.id}';
          if ((_savedPlaybackVersions[key] ?? 0) > version) return false;
          return true;
        },
        onSaved: (account, vpn) {
          final key = '${Uri.encodeComponent(account)}:${vpn ? 1 : 0}:'
              '${course.teachingClassId}:${lesson.id}';
          if ((_savedPlaybackVersions[key] ?? 0) < version) {
            _savedPlaybackVersions[key] = version;
          }
        },
      );
      return _PlaybackResult(playback, fetched);
    });
    _checkGeneration(generation);
    if (result.fetched) onPlaybackFetched?.call();
    if (lesson.isLive) _liveGrants.add(lesson.id);
    return result.playback;
  }

  String _playbackRequestKey(
          VodCourse course, VodLesson lesson, VodLiveProtocol protocol) =>
      'playback:${AcademicAccountStore.sessionEpoch}:${VodUrlResolver.revision}:'
      '${course.teachingClassId}:${lesson.id}:${lesson.isLive}:$protocol';

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
      error is! VodNoPlaybackException &&
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
    String? expectedAccount,
    bool Function(String account, bool vpn)? shouldSave,
    int? cacheVersion,
    void Function(String account, bool vpn)? onSaved,
    bool Function()? warmingValid,
    bool backgroundSave = false,
  }) async {
    final generation = _generation;
    final accountEpoch = AcademicAccountStore.sessionEpoch;
    final transportRevision = VodUrlResolver.revision;
    final accountFuture = _cacheAccount();
    final vpn = _client.useWebVpn;
    try {
      if ((warmingValid != null && !warmingValid()) ||
          (expectedAccount != null && await accountFuture != expectedAccount) ||
          (warmingValid != null && !warmingValid())) {
        throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
      }
      _checkGeneration(generation);
      final result = await loader();
      _checkGeneration(generation);
      final account = await accountFuture;
      _checkGeneration(generation);
      final currentAccount = await _cacheAccount();
      if ((expectedAccount != null && currentAccount != expectedAccount) ||
          (warmingValid != null && !warmingValid())) {
        throw const VodSessionExpiredException('账号已改变，请重新加载录播课程');
      }
      if (account != null &&
          account == currentAccount &&
          (shouldSave?.call(account, vpn) ?? true)) {
        _checkGeneration(generation);
        bool canCommit() =>
            !_disposed &&
            generation == _generation &&
            accountEpoch == AcademicAccountStore.sessionEpoch &&
            transportRevision == VodUrlResolver.revision &&
            (warmingValid == null || warmingValid()) &&
            (shouldSave?.call(account, vpn) ?? true);

        final deferWrite = expectedAccount != null || backgroundSave;
        final write = _recordingCache.save(account, vpn, key, encode(result),
            background: deferWrite, canWrite: () async {
          if (_disposed ||
              generation != _generation ||
              (warmingValid != null && !warmingValid())) {
            return false;
          }
          if (account != await _cacheAccount()) return false;
          return canCommit();
        },
            canCommit: canCommit,
            version: cacheVersion,
            onCommitted: onSaved == null ? null : () => onSaved(account, vpn));
        if (deferWrite) {
          // Metadata and background links are ready before nearby writes are
          // batched. The owner still waits for persistence before disposal.
          unawaited(_trackWarming(() => write));
        } else {
          await write;
        }
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

  Future<void> _waitForPending(String key) async {
    final pending = _pending[key];
    if (pending == null) return;
    try {
      await pending;
    } on Object {
      // A failed older request must not prevent a fresh request.
    }
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
    final queued = _warmingQueue
        .where((request) => identical(request.owner, this))
        .toList();
    for (final request in queued) {
      _warmingQueue.remove(request);
      _finishWarmingRequest(request);
    }
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
    _pptSlides.clear();
    _cachedPlaybackAvailability.clear();
    _apiClient?.dispose();
    _apiClient = null;
  }

  void dispose() {
    clear();
    _disposed = true;
  }
}

class _RecordingWarmRequest {
  _RecordingWarmRequest(
      this.owner,
      this.key,
      this.attemptKey,
      this.forceRefresh,
      this.generation,
      this.accountEpoch,
      this.transportRevision,
      this.account,
      this.course,
      this.lesson,
      {this.probe = false,
      this.isCurrent,
      this.fresh = false});

  final VodRepository owner;
  final String key;
  final String attemptKey;
  final bool forceRefresh;
  final int generation;
  final int accountEpoch;
  final int transportRevision;
  final String account;
  final VodCourse course;
  final VodLesson lesson;
  final bool probe;
  final bool Function()? isCurrent;
  final bool fresh;
  VodRecordingAvailability availability = VodRecordingAvailability.unknown;
  bool cancelled = false;
  bool cacheFallbackAllowed = false;
  final completion = Completer<void>();
}

class _OwnWarmState {
  Future<void>? active;
  int requestedRefresh = 0;
  int completedRefresh = 0;
  Future<void> Function()? latestForceScan;
}

class _Cached<T> {
  _Cached(this.value) : createdAt = DateTime.now();

  final T value;
  final DateTime createdAt;
}

class _PlaybackResult {
  _PlaybackResult(this.playback, this.fetched);

  final VodPlayback playback;
  final bool fetched;
}
