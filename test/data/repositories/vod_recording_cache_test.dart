import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/vod_url_resolver.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';
import 'package:shuyo/data/services/secure_app_store.dart';

const _term = VodTerm(
  id: 7,
  name: '2026-2027学年第1学期',
  academicYear: '2026-2027',
  termNumber: 1,
  isCurrent: true,
);
const _course = VodCourse(
  teachingClassId: 42,
  termId: 7,
  name: '程序设计',
  teachingClassName: '程序设计教学班甲',
  code: 'CS101',
  teacherNames: ['教师甲'],
  lessonCount: 1,
);
const _lesson = VodLesson(
  id: 123,
  teachingClassId: 42,
  name: '程序设计',
  isPlayable: true,
  isListed: true,
  weekNumber: 7,
  sectionLabel: '第4节',
  classroom: 'DJ203',
);
const _liveLesson = VodLesson(
  id: 456,
  teachingClassId: 42,
  name: '程序设计直播',
  isPlayable: true,
  isLive: true,
);

VodPlayback _playback(
  String version, {
  bool vpn = false,
  bool live = false,
  Map<String, String> headers = const {},
}) =>
    VodPlayback(
      lessonId: live ? _liveLesson.id : _lesson.id,
      teachingClassId: _course.teachingClassId,
      title: _course.name,
      description: '测试课程介绍',
      voiceChannel: 7,
      isLive: live,
      views: [
        VodView(
          viewNumber: 7,
          displayLabel: '合成画面',
          url: VodUrlResolver.resolveMediaUrl(
            'https://vrmvod.cc.shu.edu.cn:40443/vod/cache-test/$version.mp4',
            useWebVpn: vpn,
          ),
          httpHeaders: headers,
        ),
      ],
    );

class _CacheClient extends VodApiClient {
  _CacheClient({bool vpn = false})
      : super(useWebVpn: vpn, headersLoader: (_) async => {});

  Object? failure;
  String version = 'first';
  Future<VodPlayback> Function()? onPlayback;
  Map<String, String> freshHeaders = {};
  Map<String, String> storedPlaybackHeaders = {};
  final headerTargets = <Uri>[];
  int termRequests = 0;
  int courseRequests = 0;
  int lessonRequests = 0;
  int liveRequests = 0;
  int playbackRequests = 0;
  int livePlaybackRequests = 0;
  int searchRequests = 0;

  void _checkFailure() {
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<List<VodTerm>> fetchTerms() async {
    termRequests++;
    _checkFailure();
    return [_term];
  }

  @override
  Future<List<VodCourse>> fetchCourses({
    required int termId,
    void Function(List<VodCourse>)? onProgress,
  }) async {
    courseRequests++;
    _checkFailure();
    onProgress?.call([_course]);
    return [_course];
  }

  @override
  Future<List<VodLesson>> fetchLessons(VodCourse course) async {
    lessonRequests++;
    _checkFailure();
    return [_lesson];
  }

  @override
  Future<List<VodLesson>> fetchLiveLessons({
    required int termId,
    int? teachingClassId,
    void Function(List<VodLesson>)? onProgress,
  }) async {
    liveRequests++;
    _checkFailure();
    return [];
  }

  @override
  Future<List<VodSearchResult>> searchLessons({
    required int termId,
    required String keyword,
  }) async {
    searchRequests++;
    _checkFailure();
    return [const VodSearchResult(course: _course, lesson: _lesson)];
  }

  @override
  Future<List<VodSearchResult>> searchCoursesByKeyword({
    required int termId,
    required String keyword,
  }) async =>
      const [];

  @override
  Future<VodPlayback> fetchPlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    playbackRequests++;
    final loader = onPlayback;
    if (loader != null) return loader();
    _checkFailure();
    return _playback(version, vpn: useWebVpn, headers: storedPlaybackHeaders);
  }

  @override
  Future<VodPlayback> fetchLivePlayback({
    required VodCourse course,
    required VodLesson lesson,
    VodLiveProtocol protocol = VodLiveProtocol.hls,
  }) async {
    livePlaybackRequests++;
    _checkFailure();
    return _playback('live', vpn: useWebVpn, live: true);
  }

  @override
  Future<Map<String, String>> mediaHeadersFor(Uri target) async {
    headerTargets.add(target);
    return Map.of(freshHeaders);
  }
}

VodRepository _repository(_CacheClient client,
        {String account = 'student-a'}) =>
    VodRepository(
      apiClient: client,
      studentIdLoader: () async => account,
    );

Future<VodPlayback> _prepare(VodRepository repository) =>
    repository.preparePlayback(course: _course, lesson: _lesson);

Future<String?> _storedJson() async => (await SharedPreferences.getInstance())
    .getString(VodRecordingCache.storageKey);

void main() {
  setUp(() => VodRecordingCache.legacyStoreFactory = SecureAppStore.new);
  tearDown(() => VodRecordingCache.legacyStoreFactory = null);
  setUp(() => SharedPreferences.setMockInitialValues({
        AcademicAccountStore.studentIdKey: 'student-a',
      }));

  test('first playback survives dispose and repository recreation', () async {
    final online = _CacheClient();
    final original = VodRepository(apiClient: online);
    final first = await _prepare(original);
    expect(await _storedJson(), isNotNull);
    expect(jsonDecode((await _storedJson())!), isA<Map>());
    original.dispose();

    final offline = _CacheClient()..failure = const VodNetworkException();
    final restored = VodRepository(apiClient: offline);
    addTearDown(restored.dispose);
    final playback = await _prepare(restored);

    expect(offline.playbackRequests, 1);
    expect(playback.lessonId, _lesson.id);
    expect(playback.teachingClassId, _course.teachingClassId);
    expect(playback.title, first.title);
    expect(playback.description, first.description);
    expect(playback.voiceChannel, first.voiceChannel);
    expect(playback.views.single.url, first.views.single.url);
    expect(playback.views.single.displayLabel, '合成画面');
    expect(playback.isLive, isFalse);
  });

  test('a recording with stale generation status can cache and restore links',
      () async {
    const candidate = VodLesson(
      id: 123,
      teachingClassId: 42,
      name: '程序设计',
      isPlayable: false,
      isGenerating: true,
      isListed: true,
    );
    final original = _repository(_CacheClient());
    final first =
        await original.preparePlayback(course: _course, lesson: candidate);
    original.dispose();

    final client = _CacheClient()..failure = const VodNetworkException();
    final restored = _repository(client);
    addTearDown(restored.dispose);
    final playback =
        await restored.preparePlayback(course: _course, lesson: candidate);
    expect(client.playbackRequests, 1);
    expect(playback.views.single.url, first.views.single.url);
    final courses = await restored.loadCatalog(termId: _course.termId);
    final lessons = await restored.loadCourseLessons(courses.single);
    expect(lessons.single.isPlayable, isFalse);
    expect(lessons.single.canPlay, isTrue);
  });

  test('new server links replace persisted links and are preferred next outage',
      () async {
    final client = _CacheClient();
    final original = _repository(client);
    final first = await _prepare(original);
    client.version = 'latest';
    final latest = await _prepare(original);
    expect(client.playbackRequests, 2);
    expect(latest.views.single.url, isNot(first.views.single.url));
    original.dispose();

    final restored = _repository(_CacheClient()
      ..failure = const VodApiException('平台故障', statusCode: 503));
    addTearDown(restored.dispose);
    expect(
        (await _prepare(restored)).views.single.url, latest.views.single.url);
    expect(await _storedJson(), contains('/latest.mp4'));
    expect(await _storedJson(), isNot(contains('/first.mp4')));
  });

  test('damaged storage cannot prevent a fresh playback from succeeding',
      () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(VodRecordingCache.storageKey, '{broken-json');
    final repository = _repository(_CacheClient());
    addTearDown(repository.dispose);

    expect((await _prepare(repository)).views.single.url.path,
        '/vod/cache-test/first.mp4');
    expect(await repository.hasCachedRecordings(), isTrue);
    expect(jsonDecode((await _storedJson())!), isA<Map>());
  });

  test('an unreadable cache preserves the original API error during an outage',
      () async {
    final original = _repository(_CacheClient());
    await _prepare(original);
    original.dispose();
    await (await SharedPreferences.getInstance())
        .setString(VodRecordingCache.storageKey, '{broken-json');

    const error = VodNetworkException();
    final repository = _repository(_CacheClient()..failure = error);
    addTearDown(repository.dispose);
    await expectLater(_prepare(repository), throwsA(same(error)));
    expect(await repository.hasCachedRecordings(), isFalse);
  });

  test('malformed playback entries are never used as a fallback', () async {
    await VodRecordingCache().save('student-a', false, 'playback:42:123', {
      'course': {'acteId': 7},
      'playback': {
        'lessonId': 123,
        'teachingClassId': 42,
        'views': [],
      },
    });
    const error = VodNetworkException();
    final repository = _repository(_CacheClient()..failure = error);
    addTearDown(repository.dispose);
    await expectLater(_prepare(repository), throwsA(same(error)));
  });

  test('recording cache isolates accounts and direct versus WebVPN transport',
      () async {
    final direct = _repository(_CacheClient());
    final directUrl = (await _prepare(direct)).views.single.url;
    direct.dispose();

    final otherAccount = _repository(
        _CacheClient()..failure = const VodNetworkException(),
        account: 'student-b');
    addTearDown(otherAccount.dispose);
    expect(await otherAccount.hasCachedRecordings(), isFalse);
    await expectLater(
        _prepare(otherAccount), throwsA(isA<VodNetworkException>()));

    final vpnOffline = _repository(
        _CacheClient(vpn: true)..failure = const VodNetworkException());
    addTearDown(vpnOffline.dispose);
    expect(await vpnOffline.hasCachedRecordings(), isFalse);
    await expectLater(
        _prepare(vpnOffline), throwsA(isA<VodNetworkException>()));

    final vpnOnline = _repository(_CacheClient(vpn: true)..version = 'vpn');
    final vpnUrl = (await _prepare(vpnOnline)).views.single.url;
    vpnOnline.dispose();
    expect(vpnUrl.host, VodUrlResolver.mediaWebVpnHost);
    final directOffline =
        _repository(_CacheClient()..failure = const VodNetworkException());
    addTearDown(directOffline.dispose);
    expect((await _prepare(directOffline)).views.single.url, directUrl);
    expect((await _prepare(vpnOffline)).views.single.url, vpnUrl);
  });

  test('restored media uses current target headers without persisting secrets',
      () async {
    final online = _CacheClient()
      ..storedPlaybackHeaders = {
        'Cookie': 'old-media-cookie',
        'jwt-token': 'old-business-jwt',
        'Authorization': 'old-authorization',
      };
    final original = _repository(online);
    await _prepare(original);
    original.dispose();
    final storedBefore = (await _storedJson())!;
    for (final secret in [
      'Cookie',
      'old-media-cookie',
      'jwt-token',
      'old-business-jwt',
      'Authorization',
      'old-authorization',
    ]) {
      expect(storedBefore, isNot(contains(secret)));
    }

    final offline = _CacheClient()
      ..failure = const VodNetworkException()
      ..freshHeaders = {
        'Cookie': 'new-media-cookie',
        'X-Media-Session': 'current-session',
        'JWT-Token': 'never-forward-jwt',
        'Authorization': 'never-forward-authorization',
      };
    final restored = _repository(offline);
    addTearDown(restored.dispose);
    final first = await _prepare(restored);
    expect(first.views.single.httpHeaders, {
      'Cookie': 'new-media-cookie',
      'X-Media-Session': 'current-session',
    });
    offline.freshHeaders = {'Cookie': 'newer-media-cookie'};
    final second = await _prepare(restored);
    expect(second.views.single.httpHeaders, {'Cookie': 'newer-media-cookie'});
    expect(offline.headerTargets,
        [first.views.single.url, second.views.single.url]);
    expect(await _storedJson(), storedBefore);
  });

  final denied = <String, VodApiException>{
    'expired session': const VodSessionExpiredException(),
    'denied permission': const VodPermissionException(),
    'HTTP 401': const VodApiException('需要登录', statusCode: 401),
    'HTTP 403': const VodApiException('没有权限', statusCode: 403),
  };
  for (final entry in denied.entries) {
    test('${entry.key} never falls back to a cached recording', () async {
      final original = _repository(_CacheClient());
      await _prepare(original);
      original.dispose();

      final client = _CacheClient()..failure = entry.value;
      final repository = _repository(client);
      addTearDown(repository.dispose);
      await expectLater(_prepare(repository), throwsA(same(entry.value)));
      expect(client.headerTargets, isEmpty);
    });
  }

  test('clear rejects stale playback without disturbing a new pending request',
      () async {
    final oldStarted = Completer<void>();
    final oldResponse = Completer<VodPlayback>();
    final newStarted = Completer<void>();
    final newResponse = Completer<VodPlayback>();
    final oldClient = _CacheClient()
      ..onPlayback = () {
        oldStarted.complete();
        return oldResponse.future;
      };
    final newClient = _CacheClient()
      ..onPlayback = () {
        newStarted.complete();
        return newResponse.future;
      };
    final repository = VodRepository(
      apiClient: oldClient,
      clientFactory: () => newClient,
      studentIdLoader: () async => 'student-a',
    );
    addTearDown(repository.dispose);
    final stale = _prepare(repository);
    final rejected =
        expectLater(stale, throwsA(isA<VodSessionExpiredException>()));
    await oldStarted.future;
    repository.clear();
    final fresh = _prepare(repository);
    await newStarted.future;
    oldResponse.complete(_playback('stale'));
    await rejected;
    final joined = _prepare(repository);
    expect(newClient.playbackRequests, 1);
    newResponse.complete(_playback('new-session'));
    expect(
        (await fresh).views.single.url.path, '/vod/cache-test/new-session.mp4');
    expect((await joined).views.single.url.path,
        '/vod/cache-test/new-session.mp4');
    expect(await _storedJson(), contains('/new-session.mp4'));
    expect(await _storedJson(), isNot(contains('/stale.mp4')));
  });

  test('disposed pending playback cannot overwrite a replacement repository',
      () async {
    final started = Completer<void>();
    final response = Completer<VodPlayback>();
    final oldClient = _CacheClient()
      ..onPlayback = () {
        started.complete();
        return response.future;
      };
    final original = _repository(oldClient);
    final stale = _prepare(original);
    final rejected =
        expectLater(stale, throwsA(isA<VodSessionExpiredException>()));
    await started.future;
    original.dispose();
    final replacement = _repository(_CacheClient()..version = 'replacement');
    addTearDown(replacement.dispose);
    await _prepare(replacement);
    response.complete(_playback('disposed'));
    await rejected;

    final offline =
        _repository(_CacheClient()..failure = const VodNetworkException());
    addTearDown(offline.dispose);
    expect((await _prepare(offline)).views.single.url.path,
        '/vod/cache-test/replacement.mp4');
    expect(await _storedJson(), isNot(contains('/disposed.mp4')));
  });

  test('live playback never persists a media link or creates an offline grant',
      () async {
    final online = _CacheClient();
    final original = _repository(online);
    final playback =
        await original.preparePlayback(course: _course, lesson: _liveLesson);
    expect(playback.isLive, isTrue);
    expect(online.livePlaybackRequests, 1);
    expect(await _storedJson(), isNull);
    expect(await original.hasCachedRecordings(), isFalse);
    original.dispose();

    final offline =
        _repository(_CacheClient()..failure = const VodNetworkException());
    addTearDown(offline.dispose);
    await expectLater(
        offline.preparePlayback(course: _course, lesson: _liveLesson),
        throwsA(isA<VodNetworkException>()));
    expect(await _storedJson(), isNull);
  });

  test('terms, catalog, lessons and video reopen when all APIs are down',
      () async {
    final original = _repository(_CacheClient());
    expect((await original.loadTerms()).single.id, _term.id);
    expect((await original.loadCatalog(termId: 7)).single.teachingClassId,
        _course.teachingClassId);
    expect((await original.loadCourseLessons(_course)).single.id, _lesson.id);
    await _prepare(original);
    original.dispose();

    final offlineClient = _CacheClient()..failure = const VodNetworkException();
    final restored = _repository(offlineClient);
    addTearDown(restored.dispose);
    final terms = await restored.loadTerms();
    final courses = await restored.loadCatalog(termId: terms.single.id);
    final lessons = await restored.loadCourseLessons(courses.single);
    final playback = await restored.preparePlayback(
        course: courses.single, lesson: lessons.single);

    expect(terms.single.academicYear, _term.academicYear);
    expect(terms.single.termNumber, _term.termNumber);
    expect(courses.single.teacherNames, _course.teacherNames);
    expect(courses.single.code, _course.code);
    expect(lessons.single.id, _lesson.id);
    expect(lessons.single.sectionLabel, _lesson.sectionLabel);
    expect(lessons.single.classroom, _lesson.classroom);
    expect(playback.views.single.url.path, '/vod/cache-test/first.mp4');
    expect(offlineClient.termRequests, 1);
    expect(offlineClient.courseRequests, 1);
    expect(offlineClient.lessonRequests, 1);
    expect(offlineClient.playbackRequests, 1);
    expect(offlineClient.liveRequests, greaterThanOrEqualTo(2));
  });

  test('search-only playback is discoverable in the offline recording catalog',
      () async {
    final online = _CacheClient();
    final original = _repository(online);
    final result =
        (await original.searchLessons(termId: 7, keyword: '程序')).single;
    await original.preparePlayback(
        course: result.course, lesson: result.lesson);
    expect(online.courseRequests, 0);
    expect(online.lessonRequests, 0);
    original.dispose();

    final offline =
        _repository(_CacheClient()..failure = const VodNetworkException());
    addTearDown(offline.dispose);
    expect(await offline.hasCachedRecordings(), isTrue);
    final courses = await offline.loadCatalog(termId: 7);
    expect(courses.single.teachingClassId, result.course.teachingClassId);
    final lessons = await offline.loadCourseLessons(courses.single);
    expect(lessons.single.id, result.lesson.id);
    final playback = await offline.preparePlayback(
        course: courses.single, lesson: lessons.single);
    expect(playback.views.single.url.path, '/vod/cache-test/first.mp4');
  });
}
