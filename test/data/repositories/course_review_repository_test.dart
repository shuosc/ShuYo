import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/models/course_review.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/course_review_repository.dart';
import 'package:shuyo/data/services/course_review_api_client.dart';
import 'package:shuyo/data/services/student_identity_service.dart';

AcademicSchedule _schedule(String name) => AcademicSchedule(
      term: const AcademicTerm(
        yearCode: '2026',
        termCode: '3',
        academicYearName: '2026-2027',
        termName: '秋',
        studentName: '',
        studentId: 'TEST_STUDENT',
        className: '',
      ),
      sessions: [
        CourseSession.fromJson({
          'id': name,
          'courseName': name,
          'courseCode': 'CODE-$name',
          'teachingClassId': 'CLASS-$name',
          'teacherName': '测试教师',
          'weekday': 1,
          'startSection': 1,
          'endSection': 2,
          'sections': [1, 2],
          'weeks': [1],
        }),
      ],
      untimedCourses: const [],
      fetchedAt: DateTime(2026, 11, 12),
    );

class _PrimaryScheduleRepository extends AcademicScheduleRepository {
  final schedule = _schedule('常用课程');
  int loads = 0;

  @override
  Future<AcademicSchedule?> loadCachedSchedule() async {
    loads++;
    return schedule;
  }
}

class _ReviewApi extends CourseReviewApiClient {
  final lookups = <List<RateScheduleCourse>>[];

  final configRequests = <Completer<RateCatalogConfig>>[];

  @override
  Future<RateCatalogConfig> fetchConfig() {
    final request = Completer<RateCatalogConfig>();
    configRequests.add(request);
    return request.future;
  }

  @override
  Future<List<RateLookupResult>> lookup(
      List<RateScheduleCourse> courses) async {
    lookups.add(courses);
    return [
      for (final course in courses)
        RateLookupResult(
          status: RateLookupStatus.search,
          unit: null,
          courseId: '',
          units: const [],
          query: course.courseName,
        ),
    ];
  }
}

void main() {
  late _PrimaryScheduleRepository primary;
  late _ReviewApi api;
  late StudentIdentityService identity;

  setUp(() {
    primary = _PrimaryScheduleRepository();
    api = _ReviewApi();
    identity = StudentIdentityService();
    addTearDown(identity.dispose);
  });

  CourseReviewRepository repository({
    Future<AcademicSchedule?> Function()? scheduleLoader,
  }) {
    final result = CourseReviewRepository(
      apiClient: api,
      studentIdentityService: identity,
      scheduleRepository: primary,
      scheduleLoader: scheduleLoader,
    );
    addTearDown(result.dispose);
    return result;
  }

  const firstConfig = RateCatalogConfig(
    questions: [],
    categories: [],
    feedbackKinds: [],
  );
  final secondConfig = RateCatalogConfig.fromJson({
    'questions': [
      {'key': 'difficulty', 'title': '课程难度', 'multiple': false},
    ],
  });

  test('configuration requests share in-flight work and cache success',
      () async {
    final repo = repository();
    final pending = repo.config();
    expect(repo.config(), same(pending));
    expect(repo.config(forceRefresh: true), same(pending));
    expect(api.configRequests, hasLength(1));
    api.configRequests.single.complete(firstConfig);
    expect(await pending, same(firstConfig));
    expect(await repo.config(), same(firstConfig));
    expect(api.configRequests, hasLength(1));
  });

  test('entry refresh replaces the cache and shares concurrent refreshes',
      () async {
    final repo = repository();
    final initial = repo.config();
    api.configRequests.single.complete(firstConfig);
    await initial;

    final refresh = repo.config(forceRefresh: true);
    expect(api.configRequests, hasLength(2));
    expect(repo.config(forceRefresh: true), same(refresh));
    expect(repo.config(), same(refresh));
    api.configRequests.last.complete(secondConfig);
    expect(await refresh, same(secondConfig));
    expect(await repo.config(), same(secondConfig));
    expect(api.configRequests, hasLength(2));
  });

  test('a failed refresh is surfaced instead of silently using stale questions',
      () async {
    final repo = repository();
    final initial = repo.config();
    api.configRequests.single.complete(firstConfig);
    await initial;

    final refresh = repo.config(forceRefresh: true);
    final failure = expectLater(refresh, throwsStateError);
    api.configRequests.last
        .completeError(StateError('configuration unavailable'));
    await failure;

    final retry = repo.config(forceRefresh: true);
    expect(api.configRequests, hasLength(3));
    api.configRequests.last.complete(secondConfig);
    expect(await retry, same(secondConfig));
  });

  test('initial configuration failures can be retried', () async {
    final repo = repository();
    final pending = repo.config();
    final failure = expectLater(pending, throwsStateError);
    api.configRequests.single
        .completeError(StateError('configuration unavailable'));
    await failure;
    final retry = repo.config();
    expect(api.configRequests, hasLength(2));
    api.configRequests.last.complete(firstConfig);
    expect(await retry, same(firstConfig));
  });

  test('the default source remains the primary schedule', () async {
    final courses = await repository().scheduleCourses();
    expect(courses.single.courseName, '常用课程');
    expect(primary.loads, 1);
  });

  test('lookup uses the supplied viewed schedule without reading the primary',
      () async {
    final repo = repository(scheduleLoader: () async => _schedule('历史课程'));
    final matches = await repo.matchSchedule();
    expect(matches.single.course.courseName, '历史课程');
    expect(api.lookups.single.single.courseName, '历史课程');
    expect(primary.loads, 0);
  });

  test('the source is read again after switching or editing courses', () async {
    var selected = _schedule('历史课程');
    final repo = repository(scheduleLoader: () async => selected);
    expect((await repo.scheduleCourses()).single.courseName, '历史课程');
    selected = _schedule('同一学期修改后的课程');
    expect((await repo.scheduleCourses()).single.courseName, '同一学期修改后的课程');
    selected = primary.schedule;
    expect((await repo.scheduleCourses()).single.courseName, '常用课程');
    expect(primary.loads, 0);
  });

  test('a missing selected schedule does not fall back to the primary',
      () async {
    final repo = repository(scheduleLoader: () async => null);
    expect(await repo.matchSchedule(), isEmpty);
    expect(primary.loads, 0);
    expect(api.lookups, isEmpty);
  });

  test('an empty selected schedule clears courses without calling lookup',
      () async {
    final empty = _schedule('空课表').copyWith(sessions: []);
    final repo = repository(scheduleLoader: () async => empty);
    expect(await repo.matchSchedule(), isEmpty);
    expect(primary.loads, 0);
    expect(api.lookups, isEmpty);
  });

  test('a source error does not substitute courses from the primary', () async {
    final repo = repository(
      scheduleLoader: () async => throw StateError('schedule unavailable'),
    );
    expect(await repo.matchSchedule(), isEmpty);
    expect(primary.loads, 0);
    expect(api.lookups, isEmpty);
  });

  test('supplied schedules retain deduplication, ordering and manual courses',
      () async {
    final base = _schedule('教务课程');
    final session = base.sessions.single;
    final manual = CourseSession.fromJson({
      ...session.toJson(),
      'id': 'manual:course',
      'courseCode': CourseSession.manualCode,
      'courseName': ' 手动课程 ',
      'teachingClassId': '',
      'weekday': 2,
    });
    final selected = base.copyWith(
      sessions: [manual, session, session],
      untimedCourses: [
        UntimedCourse.fromJson({
          'id': 'untimed',
          'courseName': ' 实践课 ',
          'teacherName': '测试教师',
        }),
      ],
    );
    final courses = await repository(scheduleLoader: () async => selected)
        .scheduleCourses();
    expect(courses.map((course) => course.courseName), ['教务课程', '手动课程', '实践课']);
    expect(courses[0].teachingClassId, session.teachingClassId);
    expect(courses[1].courseCode, isEmpty);
    expect(courses[2].courseCode, isEmpty);
    expect(primary.loads, 0);
  });
}
