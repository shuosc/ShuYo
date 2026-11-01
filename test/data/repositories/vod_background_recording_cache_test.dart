import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';

const _term = VodTerm(id: 7, name: '第一学期');
const _otherTerm = VodTerm(id: 8, name: '第二学期');
const _course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');
const _otherCourse = VodCourse(teachingClassId: 43, termId: 8, name: '另一课程');

VodLesson _lesson(int id, {int courseId = 42}) => VodLesson(
      id: id,
      teachingClassId: courseId,
      name: '课次 $id',
      isPlayable: false,
      isListed: false,
    );

VodPlayback _playback(VodCourse course, VodLesson lesson, String version) =>
    VodPlayback(
      lessonId: lesson.id,
      teachingClassId: course.teachingClassId,
      title: lesson.name,
      views: [
        VodView(
          viewNumber: 1,
          url: Uri.parse('https://vrmvod.cc.shu.edu.cn:40443/vod/$version.mp4'),
        ),
      ],
    );

class _Client extends VodApiClient {
  _Client() : super(headersLoader: (_) async => {});

  final requestedLessons = <int>[];
  final requestedTerms = <int>[];
  final requestedClasses = <int>[];
  final failedTerms = <int>{};
  bool includeExtraLesson = false;
  Future<List<VodCourse>> Function(int)? onCourses;
  Future<VodPlayback> Function(VodCourse, VodLesson)? onPlayback;

  @override
  Future<List<VodCourse>> fetchCourses({
    required int termId,
    void Function(List<VodCourse>)? onProgress,
  }) async {
    requestedTerms.add(termId);
    if (failedTerms.contains(termId)) throw const VodNetworkException();
    if (onCourses != null) return onCourses!(termId);
    return termId == 7 ? [_course] : [_otherCourse];
  }

  @override
  Future<List<VodLesson>> fetchPreviewLessons(VodCourse course) async => [];

  @override
  Future<List<VodLesson>> fetchLessons(VodCourse course) async {
    requestedClasses.add(course.teachingClassId);
    return [
      _lesson(course.teachingClassId * 10, courseId: course.teachingClassId),
      if (includeExtraLesson)
        _lesson(course.teachingClassId * 10 + 1,
            courseId: course.teachingClassId),
    ];
  }

  @override
  Future<VodPlayback> fetchPlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) {
    requestedLessons.add(lesson.id);
    return onPlayback?.call(course, lesson) ??
        Future.value(_playback(course, lesson, 'fresh'));
  }
}

class _BlockedStore extends SecureAppStore {
  final started = Completer<void>();
  final release = Completer<void>();
  String? value;
  bool blockNext = true;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String content) async {
    if (blockNext) {
      blockNext = false;
      started.complete();
      await release.future;
    }
    value = content;
  }
}

class _CountingStore extends SecureAppStore {
  String? value;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String key, String content) async {
    writes++;
    value = content;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodRepository.warmingRequestSpacing = Duration.zero;
    VodRepository.warmingSuccessTtl = Duration.zero;
    VodRepository.warmingFailureTtl = Duration.zero;
  });

  test('nearby background links share persistent writes and remain readable',
      () async {
    final store = _CountingStore();
    final cache = VodRecordingCache(store: store);
    final client = _Client();
    final repository = VodRepository(
        apiClient: client,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final lessons = List.generate(100, (index) => _lesson(index + 1));

    await repository.warmCourseRecordings(_course, lessons);
    await repository.waitForBackgroundWarming();

    expect(client.requestedLessons.length, 100);
    // Each recording used to read, decode and rewrite the entire cache.
    expect(store.writes, lessThan(20));
    final saved = await cache.savedLessons('account', false, 7);
    expect(saved.length, 100);
    expect(saved.map((entry) => (entry['lesson'] as Map)['id']).toSet(),
        lessons.map((lesson) => lesson.id).toSet());
  });

  test('a batch drops entries invalidated during asynchronous encoding',
      () async {
    final cache = VodRecordingCache(store: _CountingStore());
    var checks = 0;
    final writes = <Future<void>>[
      cache.save('account', false, 'invalidated', 'old', canWrite: () {
        checks++;
        return checks == 1;
      }),
      for (var i = 0; i < 100; i++) cache.save('account', false, 'valid:$i', i),
    ];

    await Future.wait(writes);

    expect(checks, greaterThanOrEqualTo(2));
    expect(await cache.load('account', false, 'invalidated'), isNull);
    expect(await cache.load('account', false, 'valid:99'), 99);
  });

  test('same-value successor survives when an earlier entry is invalidated',
      () async {
    final cache = VodRecordingCache(store: _CountingStore());
    var firstValid = true;
    var laterChecks = 0;
    final blocked = Completer<void>();
    final release = Completer<void>();
    final first = cache.save('account', false, 'same', 'value',
        canCommit: () => firstValid);
    final second =
        cache.save('account', false, 'same', 'value', canWrite: () async {
      laterChecks++;
      if (laterChecks == 2) {
        blocked.complete();
        await release.future;
      }
      return true;
    });
    await blocked.future;
    firstValid = false;
    release.complete();
    await Future.wait([first, second]);

    expect(await cache.load('account', false, 'same'), 'value');
  });

  test('completed attempts are deduplicated across repositories; force retries',
      () async {
    VodRepository.warmingSuccessTtl = const Duration(hours: 1);
    VodRepository.warmingFailureTtl = const Duration(hours: 1);
    final firstClient = _Client();
    final secondClient = _Client();
    final first = VodRepository(
        apiClient: firstClient, studentIdLoader: () async => 'account');
    final second = VodRepository(
        apiClient: secondClient, studentIdLoader: () async => 'account');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.warmCourseRecordings(_course, [_lesson(8001)]);
    await second.warmCourseRecordings(_course, [_lesson(8001)]);
    expect(firstClient.requestedLessons, [8001]);
    expect(secondClient.requestedLessons, isEmpty);
    await second.warmCourseRecordings(_course, [_lesson(8001)],
        forceRefresh: true);
    expect(secondClient.requestedLessons, [8001]);

    secondClient.onPlayback =
        (_, __) => Future.error(const VodNetworkException());
    await second.warmCourseRecordings(_course, [_lesson(8002)]);
    await second.warmCourseRecordings(_course, [_lesson(8002)]);
    expect(secondClient.requestedLessons, [8001, 8002]);
    await second.warmCourseRecordings(_course, [_lesson(8002)],
        forceRefresh: true);
    expect(secondClient.requestedLessons, [8001, 8002, 8002]);
  });

  test('background spacing does not queue a foreground playback request',
      () async {
    VodRepository.warmingRequestSpacing = const Duration(milliseconds: 150);
    final client = _Client();
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final warming = repository
        .warmCourseRecordings(_course, [_lesson(8101), _lesson(8102)]);
    while (!client.requestedLessons.contains(8101)) {
      await Future<void>.delayed(Duration.zero);
    }
    final foreground =
        repository.preparePlayback(course: _course, lesson: _lesson(8199));
    while (!client.requestedLessons.contains(8199)) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(client.requestedLessons, [8101, 8199]);
    await Future.wait([foreground, warming]);
    expect(client.requestedLessons, [8101, 8199, 8102]);
  });

  test('forced warming waits for a pending warm and fetches a fresh link',
      () async {
    VodRepository.warmingSuccessTtl = const Duration(hours: 1);
    final client = _Client();
    final first = Completer<VodPlayback>();
    var calls = 0;
    client.onPlayback = (course, lesson) => ++calls == 1
        ? first.future
        : Future.value(_playback(course, lesson, 'new'));
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final original = repository.warmCourseRecordings(_course, [_lesson(8201)]);
    while (calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final refresh = repository.warmCourseRecordings(_course, [_lesson(8201)],
        forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    first.complete(_playback(_course, _lesson(8201), 'old'));
    await Future.wait(
        [original, refresh, repository.waitForBackgroundWarming()]);
    expect(calls, 2);
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    final restored = await repository.preparePlayback(
        course: _course, lesson: _lesson(8201));
    expect(restored.views.single.url.path, '/vod/new.mp4');
  });

  test('forced warming waits for pending foreground playback before fetching',
      () async {
    final client = _Client();
    final first = Completer<VodPlayback>();
    var calls = 0;
    client.onPlayback = (course, lesson) => ++calls == 1
        ? first.future
        : Future.value(_playback(course, lesson, 'new'));
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final foreground =
        repository.preparePlayback(course: _course, lesson: _lesson(8202));
    while (calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final refresh = repository.warmCourseRecordings(_course, [_lesson(8202)],
        forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    first.complete(_playback(_course, _lesson(8202), 'old'));
    await Future.wait([foreground, refresh]);
    expect(calls, 2);
  });

  test('warming coalesced with successful foreground uses success cooldown',
      () async {
    VodRepository.warmingSuccessTtl = const Duration(hours: 1);
    VodRepository.warmingFailureTtl = Duration.zero;
    final client = _Client();
    final first = Completer<VodPlayback>();
    client.onPlayback = (_, __) => first.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final foreground =
        repository.preparePlayback(course: _course, lesson: _lesson(8203));
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final warming = repository.warmCourseRecordings(_course, [_lesson(8203)]);
    await Future<void>.delayed(Duration.zero);
    first.complete(_playback(_course, _lesson(8203), 'fresh'));
    await Future.wait([foreground, warming]);
    await repository.warmCourseRecordings(_course, [_lesson(8203)]);
    expect(client.requestedLessons, [8203]);
  });

  test('session change cancels forced warming waiting on foreground playback',
      () async {
    final client = _Client();
    final first = Completer<VodPlayback>();
    client.onPlayback = (_, __) => first.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final foreground =
        repository.preparePlayback(course: _course, lesson: _lesson(8204));
    final foregroundCheck =
        expectLater(foreground, throwsA(isA<VodSessionExpiredException>()));
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final refresh = repository.warmCourseRecordings(_course, [_lesson(8204)],
        forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    repository.clear();
    first.complete(_playback(_course, _lesson(8204), 'old'));
    await Future.wait([foregroundCheck, refresh]);
    expect(client.requestedLessons, [8204]);
  });

  test('invalidated newer response does not suppress an older valid write',
      () async {
    final store = _BlockedStore();
    final cache = VodRecordingCache(store: store);
    final blocked = cache.save('account', false, 'block', 1);
    await store.started.future;
    final oldClient = _Client();
    final newClient = _Client();
    final oldReply = Completer<VodPlayback>();
    oldClient.onPlayback = (_, __) => oldReply.future;
    newClient.onPlayback =
        (course, lesson) async => _playback(course, lesson, 'new');
    final older = VodRepository(
        apiClient: oldClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    final newer = VodRepository(
        apiClient: newClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(older.dispose);
    addTearDown(newer.dispose);
    final old = older.preparePlayback(course: _course, lesson: _lesson(8205));
    while (oldClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final newRequest =
        newer.preparePlayback(course: _course, lesson: _lesson(8205));
    final newCheck =
        expectLater(newRequest, throwsA(isA<VodSessionExpiredException>()));
    while (newClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    newer.clear();
    oldReply.complete(_playback(_course, _lesson(8205), 'old'));
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await Future.wait([blocked, old, newCheck]);
    oldClient.onPlayback = (_, __) => Future.error(const VodNetworkException());
    final saved =
        await older.preparePlayback(course: _course, lesson: _lesson(8205));
    expect(saved.views.single.url.path, '/vod/old.mp4');
  });

  test('one batch keeps newest request despite reversed response order',
      () async {
    final store = _BlockedStore();
    final cache = VodRecordingCache(store: store);
    final blocked = cache.save('account', false, 'block', 1);
    await store.started.future;
    final oldClient = _Client();
    final newClient = _Client();
    final oldReply = Completer<VodPlayback>();
    oldClient.onPlayback = (_, __) => oldReply.future;
    newClient.onPlayback =
        (course, lesson) async => _playback(course, lesson, 'new');
    final older = VodRepository(
        apiClient: oldClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    final newer = VodRepository(
        apiClient: newClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(older.dispose);
    addTearDown(newer.dispose);
    final old = older.preparePlayback(course: _course, lesson: _lesson(8206));
    while (oldClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final fresh = newer.preparePlayback(course: _course, lesson: _lesson(8206));
    while (newClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    oldReply.complete(_playback(_course, _lesson(8206), 'old'));
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await Future.wait([blocked, old, fresh]);
    oldClient.onPlayback = (_, __) => Future.error(const VodNetworkException());
    final saved =
        await older.preparePlayback(course: _course, lesson: _lesson(8206));
    expect(saved.views.single.url.path, '/vod/new.mp4');
  });

  test('clearing a repository during another entry check rejects its write',
      () async {
    final cache = VodRecordingCache(store: _CountingStore());
    final client = _Client();
    final repository = VodRepository(
        apiClient: client,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(_course, [_lesson(1)]);
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    var checks = 0;
    final blocked = Completer<void>();
    final release = Completer<void>();
    final later = cache.save('other', false, 'other', 1, canWrite: () async {
      checks++;
      if (checks == 2) {
        blocked.complete();
        await release.future;
      }
      return true;
    });
    await blocked.future;
    repository.clear();
    release.complete();
    await Future.wait([warming, later, repository.waitForBackgroundWarming()]);

    expect(await cache.load('account', false, 'playback:42:1'), isNull);
    expect(await cache.load('other', false, 'other'), 1);
  });

  test(
      'warms every valid recording including missing or stale status; errors are isolated',
      () async {
    final client = _Client()
      ..onPlayback = (course, lesson) async {
        if (lesson.id == 2) throw const VodNetworkException();
        return _playback(course, lesson, 'fresh');
      };
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final statusSeven = VodLesson.fromJson({
      'id': 3,
      'teclId': 42,
      'vodStatus': 7,
      'vodEnable': 1,
      'vodDeleteStatus': 0,
    });

    await repository.warmCourseRecordings(_course, [
      _lesson(1),
      _lesson(2),
      statusSeven,
      _lesson(0),
      _lesson(4, courseId: 999),
      const VodLesson(
          id: 5,
          teachingClassId: 42,
          name: '直播',
          isPlayable: true,
          isLive: true),
    ]);

    expect(client.requestedLessons.toSet(), {1, 2, 3});
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    expect(
        (await repository.preparePlayback(course: _course, lesson: statusSeven))
            .views
            .single
            .url
            .path,
        '/vod/fresh.mp4');
    await expectLater(
        repository.preparePlayback(course: _course, lesson: _lesson(2)),
        throwsA(isA<VodNetworkException>()));
  });

  test('warms all terms and courses from the account catalog', () async {
    final client = _Client();
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);

    await repository.warmOwnRecordings([_term, _otherTerm]);

    expect(client.requestedTerms.toSet(), {7, 8});
    expect(client.requestedClasses.toSet(), {42, 43});
    expect(client.requestedLessons.toSet(), {420, 430});
  });

  test(
      'clearing during a pending forced course refresh prevents a new session request',
      () async {
    final oldClient = _Client();
    final newClient = _Client();
    final pending = Completer<List<VodCourse>>();
    oldClient.onCourses = (_) => pending.future;
    final repository = VodRepository(
        apiClient: oldClient,
        clientFactory: () => newClient,
        studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final initial = repository.loadCourses(termId: 7);
    final refresh = repository.loadCourses(termId: 7, forceRefresh: true);
    final checkInitial =
        expectLater(initial, throwsA(isA<VodSessionExpiredException>()));
    final checkRefresh =
        expectLater(refresh, throwsA(isA<VodSessionExpiredException>()));
    repository.clear();
    pending.complete([_course]);
    await Future.wait([checkInitial, checkRefresh]);
    expect(newClient.requestedTerms, isEmpty);
  });

  test('a failed term does not prevent warming a later term', () async {
    final client = _Client()..failedTerms.add(7);
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);

    await repository.warmOwnRecordings([_term, _otherTerm]);

    expect(client.requestedTerms, [7, 8]);
    expect(client.requestedLessons, [430]);
  });

  test(
      'limits concurrent URL requests and does not block an active playback request',
      () async {
    final client = _Client();
    final pending = <int, Completer<VodPlayback>>{};
    var concurrent = 0;
    var peak = 0;
    client.onPlayback = (course, lesson) {
      concurrent++;
      if (concurrent > peak) peak = concurrent;
      final completer = Completer<VodPlayback>();
      pending[lesson.id] = completer;
      return completer.future.whenComplete(() => concurrent--);
    };
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final lessons = List.generate(7, (i) => _lesson(i + 1));
    final warming = repository.warmCourseRecordings(_course, lessons);
    await Future<void>.delayed(Duration.zero);
    expect(pending.length, 1);

    // A user request for an in-flight lesson reuses that request without
    // waiting for the rest of the background queue.
    final selected =
        repository.preparePlayback(course: _course, lesson: lessons.first);
    pending[1]!.complete(_playback(_course, lessons.first, 'selected'));
    expect((await selected).views.single.url.path, '/vod/selected.mp4');
    while (client.requestedLessons.length < lessons.length) {
      await Future<void>.delayed(Duration.zero);
      for (final id in pending.keys.toList()) {
        if (!pending[id]!.isCompleted) {
          pending[id]!.complete(_playback(_course, _lesson(id), 'fresh'));
        }
      }
    }
    for (final id in pending.keys.toList()) {
      if (!pending[id]!.isCompleted) {
        pending[id]!.complete(_playback(_course, _lesson(id), 'fresh'));
      }
    }
    await warming;
    expect(peak, lessThanOrEqualTo(1));
  });

  test('refresh updates stored links and later network failures use the newest',
      () async {
    final client = _Client();
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final lesson = _lesson(1);
    client.onPlayback =
        (course, lesson) async => _playback(course, lesson, 'first');
    await repository.warmCourseRecordings(_course, [lesson]);
    client.onPlayback =
        (course, lesson) async => _playback(course, lesson, 'newest');
    await repository.warmCourseRecordings(_course, [lesson]);
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    expect(
        (await repository.preparePlayback(course: _course, lesson: lesson))
            .views
            .single
            .url
            .path,
        '/vod/newest.mp4');
  });

  test('background work can finish before its owner releases resources',
      () async {
    final client = _Client();
    final pending = Completer<VodPlayback>();
    client.onPlayback = (_, __) => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(_course, [_lesson(1)]);
    var finished = false;
    final wait = repository.waitForBackgroundWarming().then((_) {
      finished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.requestedLessons, [1]);
    expect(finished, isFalse);
    pending.complete(_playback(_course, _lesson(1), 'fresh'));
    await Future.wait([warming, wait]);
    expect(finished, isTrue);
  });

  test('forced refresh schedules one fresh scan after an ongoing scan',
      () async {
    final client = _Client();
    final first = Completer<VodPlayback>();
    client.onPlayback = (course, lesson) =>
        lesson.id == 420 && !first.isCompleted
            ? first.future
            : Future.value(_playback(course, lesson, 'refreshed'));
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final initial = repository.warmOwnRecordings([_term]);
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    client.includeExtraLesson = true;
    final refresh = repository.warmOwnRecordings([_term], forceRefresh: true);
    final refreshAgain =
        repository.warmOwnRecordings([_term], forceRefresh: true);
    first.complete(_playback(_course, _lesson(420), 'old'));
    await Future.wait([initial, refresh, refreshAgain]);
    expect(client.requestedTerms, [7, 7]);
    expect(client.requestedClasses, [42, 42]);
    expect(client.requestedLessons, [420, 420, 421]);
  });

  test('a refresh during a forced scan schedules another forced scan',
      () async {
    final client = _Client();
    final first = Completer<VodPlayback>();
    client.onPlayback = (course, lesson) =>
        lesson.id == 420 && !first.isCompleted
            ? first.future
            : Future.value(_playback(course, lesson, 'fresh'));
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final refresh = repository.warmOwnRecordings([_term], forceRefresh: true);
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    client.includeExtraLesson = true;
    final again = repository.warmOwnRecordings([_term], forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    first.complete(_playback(_course, _lesson(420), 'old'));
    await Future.wait([refresh, again]);
    expect(client.requestedTerms, [7, 7]);
    expect(client.requestedLessons, [420, 420, 421]);
  });

  test('logout while a link write is queued prevents its persistence',
      () async {
    final store = _BlockedStore();
    final cache = VodRecordingCache(store: store);
    final blocked = cache.save('account', false, 'block', 1);
    await store.started.future;
    final client = _Client();
    final repository = VodRepository(
        apiClient: client,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(_course, [_lesson(1)]);
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    await AcademicAccountStore().clear();
    store.release.complete();
    await Future.wait([blocked, warming]);
    expect(await cache.load('account', false, 'playback:42:1'), isNull);
  });

  test('a queued older link cannot replace a later successful response',
      () async {
    final store = _BlockedStore();
    final cache = VodRecordingCache(store: store);
    final blocked = cache.save('account', false, 'block', 1);
    await store.started.future;
    final oldClient = _Client()
      ..onPlayback = (course, lesson) async => _playback(course, lesson, 'old');
    final newClient = _Client()
      ..onPlayback = (course, lesson) async => _playback(course, lesson, 'new');
    final oldRepository = VodRepository(
        apiClient: oldClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    final newRepository = VodRepository(
        apiClient: newClient,
        recordingCache: cache,
        studentIdLoader: () async => 'account');
    addTearDown(oldRepository.dispose);
    addTearDown(newRepository.dispose);
    final old = oldRepository.warmCourseRecordings(_course, [_lesson(1)]);
    while (oldClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    final newer = newRepository.warmCourseRecordings(_course, [_lesson(1)]);
    while (newClient.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await Future.wait([blocked, old, newer]);
    newClient.onPlayback = (_, __) => Future.error(const VodNetworkException());
    expect(
        (await newRepository.preparePlayback(
                course: _course, lesson: _lesson(1)))
            .views
            .single
            .url
            .path,
        '/vod/new.mp4');
  });

  test('switching accounts away and back cancels the earlier session',
      () async {
    final accountStore = AcademicAccountStore();
    await accountStore.saveStudentId('account');
    final client = _Client();
    final pending = Completer<VodPlayback>();
    client.onPlayback = (_, __) => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: accountStore.loadStudentId);
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(_course, [_lesson(1)]);
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await accountStore.saveStudentId('other');
    await accountStore.saveStudentId('account');
    pending.complete(_playback(_course, _lesson(1), 'old'));
    await warming;
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    await expectLater(
        repository.preparePlayback(course: _course, lesson: _lesson(1)),
        throwsA(isA<VodNetworkException>()));
  });

  test('an older repository response cannot overwrite a newer link', () async {
    final older = _Client();
    final newer = _Client();
    final oldReply = Completer<VodPlayback>();
    final newReply = Completer<VodPlayback>();
    older.onPlayback = (_, __) => oldReply.future;
    newer.onPlayback = (_, __) => newReply.future;
    final first =
        VodRepository(apiClient: older, studentIdLoader: () async => 'account');
    final second =
        VodRepository(apiClient: newer, studentIdLoader: () async => 'account');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final oldRequest = first.warmCourseRecordings(_course, [_lesson(1)]);
    while (older.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    // Foreground playback is allowed to run while an older warming request
    // is in flight, even though background requests themselves are serial.
    final newRequest =
        second.preparePlayback(course: _course, lesson: _lesson(1));
    while (newer.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    newReply.complete(_playback(_course, _lesson(1), 'newest'));
    await newRequest;
    oldReply.complete(_playback(_course, _lesson(1), 'old'));
    await oldRequest;
    newer.onPlayback = (_, __) => Future.error(const VodNetworkException());
    expect(
        (await second.preparePlayback(course: _course, lesson: _lesson(1)))
            .views
            .single
            .url
            .path,
        '/vod/newest.mp4');
  });

  test('the background concurrency limit is shared by repositories', () async {
    final firstClient = _Client();
    final secondClient = _Client();
    final pending = <int, Completer<VodPlayback>>{};
    Future<VodPlayback> open(VodCourse course, VodLesson lesson) {
      final completer = Completer<VodPlayback>();
      pending[lesson.id] = completer;
      return completer.future;
    }

    firstClient.onPlayback = open;
    secondClient.onPlayback = open;
    final first = VodRepository(
        apiClient: firstClient, studentIdLoader: () async => 'account');
    final second = VodRepository(
        apiClient: secondClient, studentIdLoader: () async => 'account');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstWarm = first
        .warmCourseRecordings(_course, [_lesson(1), _lesson(2), _lesson(3)]);
    final secondWarm = second
        .warmCourseRecordings(_course, [_lesson(4), _lesson(5), _lesson(6)]);
    await Future<void>.delayed(Duration.zero);
    expect(pending.length, 1);
    expect(secondClient.requestedLessons, isEmpty);
    for (var id = 1; id <= 6; id++) {
      while (!pending.containsKey(id)) {
        await Future<void>.delayed(Duration.zero);
      }
      pending[id]!.complete(_playback(_course, _lesson(id), 'fresh'));
    }
    await Future.wait([firstWarm, secondWarm]);
    expect(secondClient.requestedLessons, [4, 5, 6]);
  });

  test('a logout cancels warming even if the same account immediately returns',
      () async {
    final client = _Client();
    final pending = Completer<VodPlayback>();
    client.onPlayback = (_, __) => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(
        _course, List.generate(6, (i) => _lesson(i + 1)));
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await AcademicAccountStore().clear();
    pending.complete(_playback(_course, _lesson(1), 'old'));
    await warming;
    expect(client.requestedLessons.length, 1);
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    await expectLater(
        repository.preparePlayback(course: _course, lesson: _lesson(1)),
        throwsA(isA<VodNetworkException>()));
  });

  test('a foreground request coalesced by warming cannot cache after logout',
      () async {
    final client = _Client();
    final pending = Completer<VodPlayback>();
    client.onPlayback = (_, __) => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final foreground =
        repository.preparePlayback(course: _course, lesson: _lesson(1));
    final foregroundCheck =
        expectLater(foreground, throwsA(isA<VodSessionExpiredException>()));
    while (client.requestedLessons.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final warming = repository.warmCourseRecordings(_course, [_lesson(1)]);
    await Future<void>.delayed(Duration.zero);
    expect(client.requestedLessons, [1]);
    await AcademicAccountStore().clear();
    pending.complete(_playback(_course, _lesson(1), 'old'));
    await Future.wait([foregroundCheck, warming]);
    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    await expectLater(
        repository.preparePlayback(course: _course, lesson: _lesson(1)),
        throwsA(isA<VodNetworkException>()));
  });

  test(
      'an account switch between scheduling and request cannot use the new account',
      () async {
    var calls = 0;
    final client = _Client();
    final repository = VodRepository(
        apiClient: client,
        studentIdLoader: () async {
          calls++;
          return calls <= 2 ? 'old' : 'new';
        });
    addTearDown(repository.dispose);
    await repository.warmCourseRecordings(_course, [_lesson(1)]);
    expect(client.requestedLessons, isEmpty);
  });

  test(
      'account switch cancels remaining work and cannot cache the prior response',
      () async {
    var account = 'old';
    final client = _Client();
    final pending = Completer<VodPlayback>();
    client.onPlayback = (_, __) => pending.future;
    final repository =
        VodRepository(apiClient: client, studentIdLoader: () async => account);
    addTearDown(repository.dispose);
    final warming = repository.warmCourseRecordings(
        _course, List.generate(7, (i) => _lesson(i + 1)));
    await Future<void>.delayed(Duration.zero);
    expect(client.requestedLessons.length, 1);
    account = 'new';
    pending.complete(_playback(_course, _lesson(1), 'old'));
    await warming;
    expect(client.requestedLessons.length, 1);

    client.onPlayback = (_, __) => Future.error(const VodNetworkException());
    await expectLater(
        repository.preparePlayback(course: _course, lesson: _lesson(1)),
        throwsA(isA<VodNetworkException>()));
  });
}
