import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const _course = VodCourse(
  teachingClassId: 42,
  termId: 7,
  name: '程序设计',
  code: 'CS101',
  teacherNames: ['教师甲'],
);
const _lesson = VodLesson(
  id: 123,
  teachingClassId: 42,
  name: '程序设计',
  isPlayable: true,
);

class _FakeClient extends VodApiClient {
  _FakeClient({this.coursesFuture}) : super(headersLoader: (_) async => {});

  Future<List<VodCourse>>? coursesFuture;
  Future<List<VodLesson>>? liveFuture;
  Future<List<VodLesson>>? lessonsFuture;
  void Function(List<VodCourse>)? publishCourses;
  void Function(List<VodLesson>)? publishLive;
  int courseRequests = 0;
  int lessonRequests = 0;
  int liveRequests = 0;
  int playbackRequests = 0;
  List<VodLesson> liveLessons = [];

  @override
  Future<List<VodLesson>> fetchLiveLessons({
    required int termId,
    int? teachingClassId,
    void Function(List<VodLesson>)? onProgress,
  }) async {
    liveRequests++;
    publishLive = onProgress;
    final lessons = await (liveFuture ?? Future.value(liveLessons));
    return lessons
        .where((lesson) =>
            teachingClassId == null ||
            lesson.teachingClassId == teachingClassId)
        .toList();
  }

  @override
  Future<List<VodCourse>> fetchCourses({
    required int termId,
    void Function(List<VodCourse>)? onProgress,
  }) async {
    courseRequests++;
    publishCourses = onProgress;
    final pending = coursesFuture;
    return pending == null ? [_course] : await pending;
  }

  @override
  Future<List<VodLesson>> fetchLessons(VodCourse course) async {
    lessonRequests++;
    return await (lessonsFuture ?? Future.value([_lesson]));
  }

  @override
  Future<VodPlayback> fetchPlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    playbackRequests++;
    return VodPlayback(
      lessonId: lesson.id,
      teachingClassId: course.teachingClassId,
      title: course.name,
      views: [
        VodView(
          viewNumber: 7,
          url: Uri.https(
              'media.example', '/clip.mp4', {'grant': '$playbackRequests'}),
        ),
      ],
    );
  }
}

void main() {
  for (final liveFirst in [false, true]) {
    test(
        'lesson sources start concurrently when ${liveFirst ? 'live' : 'recordings'} finish first',
        () async {
      final client = _FakeClient();
      final repository = VodRepository(apiClient: client);
      addTearDown(repository.dispose);
      await repository.loadCatalog(termId: 7);
      final live = Completer<List<VodLesson>>();
      final recordings = Completer<List<VodLesson>>();
      client
        ..liveFuture = live.future
        ..lessonsFuture = recordings.future;
      final result = repository.loadCourseLessons(_course);
      await Future<void>.delayed(Duration.zero);
      expect(client.liveRequests, 2);
      expect(client.lessonRequests, 1);
      if (liveFirst) {
        live.complete([]);
      } else {
        recordings.complete([_lesson]);
      }
      await Future<void>.delayed(Duration.zero);
      expect(client.liveRequests, 2);
      expect(client.lessonRequests, 1);
      if (liveFirst) {
        recordings.complete([_lesson]);
      } else {
        live.complete([]);
      }
      expect(await result, [_lesson]);
    });
  }

  for (final hasLive in [false, true]) {
    test(
        'recording permission fallback requires ${hasLive ? 'available' : 'nonempty'} live lessons',
        () async {
      final client = _FakeClient();
      final repository = VodRepository(apiClient: client);
      addTearDown(repository.dispose);
      await repository.loadCatalog(termId: 7);
      final recordings = Completer<List<VodLesson>>();
      const liveLesson = VodLesson(
        id: 900,
        teachingClassId: 42,
        name: '直播课程',
        isPlayable: true,
        isLive: true,
        catalogCourse: _course,
      );
      client
        ..liveLessons = hasLive ? [liveLesson] : []
        ..lessonsFuture = recordings.future;
      final result = repository.loadCourseLessons(_course);
      final checked = expectLater(
        result,
        hasLive
            ? completion([liveLesson])
            : throwsA(isA<VodPermissionException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.lessonRequests, 1);
      recordings.completeError(const VodPermissionException());
      await checked;
    });
  }

  test('recorded courses publish and can open while live loading is pending',
      () async {
    final courses = Completer<List<VodCourse>>();
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient(coursesFuture: courses.future)
      ..liveFuture = live.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final snapshots = <List<VodCourse>>[];
    final result = repository.loadCatalog(termId: 7, onProgress: snapshots.add);
    client.publishCourses!([_course]);
    expect(snapshots.last, [_course]);
    expect(() => snapshots.last.add(_course), throwsUnsupportedError);
    expect(await repository.loadLessons(_course), [_lesson]);
    expect(client.courseRequests, 1);
    courses.complete([_course]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last, [_course]);
    live.complete([]);
    expect(await result, [_course]);
  });

  test('live-first progress merges later recordings without losing live state',
      () async {
    final courses = Completer<List<VodCourse>>();
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient(coursesFuture: courses.future)
      ..liveFuture = live.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    const liveLesson = VodLesson(
      id: 123,
      teachingClassId: 42,
      name: '程序设计',
      isPlayable: true,
      isLive: true,
      catalogCourse: VodCourse(teachingClassId: 42, termId: 7, name: '直播信息'),
    );
    final snapshots = <List<VodCourse>>[];
    final result = repository.loadCatalog(termId: 7, onProgress: snapshots.add);
    live.complete([liveLesson]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.single.name, '直播信息');
    expect(snapshots.last.single.isLive, isTrue);
    client.publishCourses!([
      const VodCourse(teachingClassId: 99, termId: 7, name: '仅录播课程'),
      _course,
    ]);
    expect(snapshots.last.map((course) => course.teachingClassId), [42, 99]);
    expect(snapshots.last.first.name, _course.name);
    expect(snapshots.last.first.code, _course.code);
    expect(snapshots.last.first.liveLesson, liveLesson);
    courses.complete([_course]);
    expect((await result).single.liveLesson, liveLesson);
  });

  test('late live results update existing courses and move them to the top',
      () async {
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient(
        coursesFuture: Future.value([
      const VodCourse(teachingClassId: 99, termId: 7, name: '仅录播课程'),
      _course,
    ]))
      ..liveFuture = live.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final snapshots = <List<VodCourse>>[];
    final result = repository.loadCatalog(termId: 7, onProgress: snapshots.add);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.map((course) => course.teachingClassId), [99, 42]);
    const liveLesson = VodLesson(
      id: 123,
      teachingClassId: 42,
      name: '程序设计',
      isPlayable: true,
      isLive: true,
      catalogCourse: _course,
    );
    live.complete([liveLesson]);
    final courses = await result;
    expect(courses.map((course) => course.teachingClassId), [42, 99]);
    expect(courses.first.liveLesson, liveLesson);
    expect(courses.first.code, _course.code);
    expect(snapshots.last.map((course) => course.teachingClassId), [42, 99]);
  });

  test('joined catalog readers receive the current and subsequent progress',
      () async {
    final courses = Completer<List<VodCourse>>();
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient(coursesFuture: courses.future)
      ..liveFuture = live.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final firstProgress = <List<VodCourse>>[];
    final secondProgress = <List<VodCourse>>[];
    final first =
        repository.loadCatalog(termId: 7, onProgress: firstProgress.add);
    client.publishCourses!([_course]);
    final second =
        repository.loadCatalog(termId: 7, onProgress: secondProgress.add);
    expect(secondProgress.single, [_course]);
    expect(client.courseRequests, 1);
    courses.complete([_course]);
    live.complete([]);
    expect(await first, [_course]);
    expect(await second, [_course]);
    expect(secondProgress.length, firstProgress.length);
    final cached = <List<VodCourse>>[];
    expect(await repository.loadCatalog(termId: 7, onProgress: cached.add),
        [_course]);
    expect(cached.single, [_course]);
    expect(client.courseRequests, 1);
  });

  test('a failed source keeps authorized successful partial courses usable',
      () async {
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient()..liveFuture = live.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final snapshots = <List<VodCourse>>[];
    final result = repository.loadCatalog(termId: 7, onProgress: snapshots.add);
    final rejected = expectLater(result, throwsA(isA<VodNetworkException>()));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last, [_course]);
    live.completeError(const VodNetworkException());
    await rejected;
    expect(await repository.loadLessons(_course), [_lesson]);
    expect(client.courseRequests, 1);
  });

  test('clear rejects stale partial callbacks and discards their permissions',
      () async {
    final courses = Completer<List<VodCourse>>();
    final live = Completer<List<VodLesson>>();
    final client = _FakeClient(coursesFuture: courses.future)
      ..liveFuture = live.future;
    final repository = VodRepository(
      apiClient: client,
      clientFactory: () => _FakeClient(coursesFuture: Future.value([])),
    );
    addTearDown(repository.dispose);
    final snapshots = <List<VodCourse>>[];
    final result = repository.loadCatalog(termId: 7, onProgress: snapshots.add);
    final rejected =
        expectLater(result, throwsA(isA<VodSessionExpiredException>()));
    client.publishCourses!([_course]);
    final published = snapshots.length;
    repository.clear();
    expect(() => client.publishCourses!([_course]),
        throwsA(isA<VodSessionExpiredException>()));
    courses.complete([_course]);
    live.complete([]);
    await rejected;
    expect(snapshots.length, published);
    await expectLater(repository.loadLessons(_course),
        throwsA(isA<VodPermissionException>()));
  });

  test(
      'unified catalog keeps live-only classes and combines live and recorded episodes',
      () async {
    final client = _FakeClient()
      ..liveLessons = [
        VodLesson(
            id: 123,
            teachingClassId: 42,
            name: '程序设计',
            isPlayable: true,
            isLive: true,
            beginTime: DateTime(2026, 10, 28),
            catalogCourse: _course),
        const VodLesson(
            id: 900,
            teachingClassId: 99,
            name: '仅直播课程',
            isPlayable: true,
            isLive: true,
            catalogCourse:
                VodCourse(teachingClassId: 99, termId: 7, name: '仅直播课程')),
      ];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final courses = await repository.loadCatalog(termId: 7);
    expect(
        courses.map((course) => course.teachingClassId), containsAll([42, 99]));
    expect(courses.every((course) => course.isLive), isTrue);
    expect(courses.firstWhere((course) => course.teachingClassId == 42).code,
        'CS101');
    final lessons = await repository.loadCourseLessons(_course);
    expect(lessons, hasLength(1));
    expect(lessons.single.id, 123);
    expect(lessons.single.isLive, isTrue);
  });

  test('concurrent catalog reads share one request', () async {
    final response = Completer<List<VodCourse>>();
    final client = _FakeClient(coursesFuture: response.future);
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final first = repository.loadCourses(termId: 7);
    final second = repository.loadCourses(termId: 7);
    await Future<void>.delayed(Duration.zero);
    expect(client.courseRequests, 1);
    response.complete([_course]);
    expect(await first, [_course]);
    expect(await second, [_course]);
    await repository.loadCourses(termId: 7);
    expect(client.courseRequests, 1);
  });

  test(
      'clear rejects stale results before they can populate a new account cache',
      () async {
    final response = Completer<List<VodCourse>>();
    final oldClient = _FakeClient(coursesFuture: response.future);
    final nextClient = _FakeClient(coursesFuture: Future.value([]));
    final repository = VodRepository(
      apiClient: oldClient,
      clientFactory: () => nextClient,
    );
    addTearDown(repository.dispose);
    final oldRequest = repository.loadCourses(termId: 7);
    final rejected =
        expectLater(oldRequest, throwsA(isA<VodSessionExpiredException>()));
    repository.clear();
    response.complete([_course]);
    await rejected;
    expect(await repository.loadCourses(termId: 7), isEmpty);
    expect(nextClient.courseRequests, 1);
  });

  test('search matches course, code and teacher inside the authorized list',
      () {
    final repository = VodRepository(apiClient: _FakeClient());
    addTearDown(repository.dispose);
    expect(repository.filterCourses([_course], keyword: 'CS101'), [_course]);
    expect(repository.filterCourses([_course], keyword: '教师甲'), [_course]);
    expect(repository.filterCourses([_course], teacher: '教师甲'), [_course]);
    expect(repository.filterCourses([_course], teacher: '教师乙'), isEmpty);
    expect(repository.filterCourses([_course], keyword: '不存在'), isEmpty);
  });

  test('an arbitrary class outside the normal catalog cannot load lessons',
      () async {
    final client = _FakeClient();
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(
      repository.loadLessons(const VodCourse(
        teachingClassId: 999,
        termId: 7,
        name: '课表外课程',
      )),
      throwsA(isA<VodPermissionException>()),
    );
    expect(client.lessonRequests, 0);
  });

  test('arbitrary lesson IDs never reach the playback details endpoint',
      () async {
    final client = _FakeClient();
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(
      repository.preparePlayback(
        course: _course,
        lesson: const VodLesson(
          id: 999,
          teachingClassId: 42,
          name: '其他课次',
          isPlayable: true,
        ),
      ),
      throwsA(isA<VodPermissionException>()),
    );
    expect(client.playbackRequests, 0);
  });

  test('subsequent playback requests obtain fresh permission and signed URLs',
      () async {
    final client = _FakeClient();
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final first =
        await repository.preparePlayback(course: _course, lesson: _lesson);
    final second =
        await repository.preparePlayback(course: _course, lesson: _lesson);
    expect(first.views.single.url, isNot(second.views.single.url));
    expect(client.playbackRequests, 2);
    expect(client.courseRequests, 1);
    expect(client.lessonRequests, 1);
  });
}
