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
  int courseRequests = 0;
  int lessonRequests = 0;
  int playbackRequests = 0;
  List<VodLesson> liveLessons = [];

  @override
  Future<List<VodLesson>> fetchLiveLessons(
          {required int termId, int? teachingClassId}) async =>
      liveLessons
          .where((lesson) =>
              teachingClassId == null ||
              lesson.teachingClassId == teachingClassId)
          .toList();

  @override
  Future<List<VodCourse>> fetchCourses({required int termId}) async {
    courseRequests++;
    final pending = coursesFuture;
    return pending == null ? [_course] : await pending;
  }

  @override
  Future<List<VodLesson>> fetchLessons(VodCourse course) async {
    lessonRequests++;
    return [_lesson];
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
