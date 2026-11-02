import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/vod_url_resolver.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const _course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');
VodLesson _lesson(int id, {int courseId = 42}) =>
    VodLesson(id: id, teachingClassId: courseId, name: '课次', isPlayable: false);

class _Client extends VodApiClient {
  _Client() : super(headersLoader: (_) async => {});

  Future<List<VodLesson>> Function()? onPreview;
  Future<VodPlayback> Function(VodLesson)? onPlayback;
  final requested = <int>[];
  int previews = 0;

  @override
  Future<List<VodLesson>> fetchPreviewLessons(VodCourse course) {
    previews++;
    return onPreview?.call() ?? Future.value([_lesson(2)]);
  }

  @override
  Future<VodPlayback> fetchPlayback(
      {required VodCourse course, required VodLesson lesson}) {
    requested.add(lesson.id);
    return onPlayback?.call(lesson) ??
        Future.value(VodPlayback(
            lessonId: lesson.id,
            teachingClassId: course.teachingClassId,
            title: lesson.name,
            views: [
              VodView(
                  viewNumber: 1,
                  url: Uri.parse('https://example.com/${lesson.id}.mp4')),
            ]));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodRepository.warmingRequestSpacing = Duration.zero;
    VodRepository.warmingSuccessTtl = Duration.zero;
    VodRepository.warmingFailureTtl = Duration.zero;
  });

  test(
      'returns preview before link requests finish and tracks complete warming',
      () async {
    final client = _Client();
    final blocked = Completer<VodPlayback>();
    client.onPlayback = (_) => blocked.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-a');
    addTearDown(repository.dispose);

    final lessons = await repository.loadAndWarmSearchLessons(
        _course, [_lesson(1), _lesson(2), _lesson(3, courseId: 43)]);
    expect(lessons.map((lesson) => lesson.id), [2]);
    var finished = false;
    final waiting = repository.waitForBackgroundWarming().then((_) {
      finished = true;
    });
    while (client.requested.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(finished, isFalse);
    blocked.complete(VodPlayback(
        lessonId: 1,
        teachingClassId: 42,
        title: '课次',
        views: [
          VodView(viewNumber: 1, url: Uri.parse('https://example.com/1'))
        ]));
    await waiting;
    expect(client.requested, [1, 2]);
  });

  test('search live seed survives cached preview without warming its VOD URL',
      () async {
    final live = VodLesson(
        id: 12,
        teachingClassId: 42,
        name: '正在直播',
        isLive: true,
        isPlayable: true,
        liveEndTime: DateTime.now().add(const Duration(hours: 1)));
    final generating = VodLesson(
        id: 12,
        teachingClassId: 42,
        name: '同一课次',
        isPlayable: false,
        isGenerating: true);
    final recording = _lesson(13);
    final client = _Client()..onPreview = () async => [generating, recording];
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-live');
    addTearDown(repository.dispose);
    // The search list has already fetched this preview for its lesson count.
    await repository.loadPreviewLessons(_course);

    final result = await repository.loadAndWarmSearchLessons(_course, [live]);
    await repository.waitForBackgroundWarming();

    expect(result.where((lesson) => lesson.id == 12).single, same(live));
    expect(result, hasLength(2));
    expect(client.previews, 1);
    expect(client.requested, [13]);
    // Live seeds are combined per request rather than saved into the preview.
    expect(
        (await repository.loadPreviewLessons(_course)).first, same(generating));
  });

  test('expired search live seed does not hide a generated preview recording',
      () async {
    final live = VodLesson(
        id: 14,
        teachingClassId: 42,
        name: '直播已结束',
        isLive: true,
        isPlayable: true,
        liveEndTime: DateTime.now().subtract(const Duration(minutes: 1)));
    final recording = _lesson(14);
    final client = _Client()..onPreview = () async => [recording];
    final repository = VodRepository(
        apiClient: client,
        studentIdLoader: () async => 'warm-search-live-expired');
    addTearDown(repository.dispose);

    final result = await repository.loadAndWarmSearchLessons(_course, [live]);
    await repository.waitForBackgroundWarming();

    expect(result, [recording]);
    expect(client.previews, 1);
    expect(client.requested, [14]);
  });

  test('warming skips generating lessons but still requests unknown recordings',
      () async {
    const generating = VodLesson(
        id: 15,
        teachingClassId: 42,
        name: '回放生成中',
        isPlayable: false,
        isGenerating: true);
    final unknown = _lesson(16);
    final client = _Client()..onPreview = () async => [generating, unknown];
    final repository = VodRepository(
        apiClient: client,
        studentIdLoader: () async => 'warm-search-generation');
    addTearDown(repository.dispose);

    final result = await repository.loadAndWarmSearchLessons(_course, []);
    await repository.waitForBackgroundWarming();
    expect(result, contains(generating));
    expect(client.previews, 1);
    expect(client.requested, [16]);

    await repository.warmCourseRecordings(_course, [generating],
        forceRefresh: true);
    expect(client.requested, [16]);
    // Skipping a known generation state must not cache an unavailable result.
    await repository.warmCourseRecordings(_course, [_lesson(15)]);
    expect(client.requested, [16, 15]);
  });

  test('preview failure reaches caller while valid seed is warmed', () async {
    final client = _Client()
      ..onPreview = () => Future.error(const VodNetworkException());
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-b');
    addTearDown(repository.dispose);
    await expectLater(
        repository.loadAndWarmSearchLessons(_course, [_lesson(4)]),
        throwsA(isA<VodNetworkException>()));
    await repository.waitForBackgroundWarming();
    expect(client.requested, [4]);
  });

  test('account change during preview prevents warming either account',
      () async {
    var account = 'warm-search-c';
    final pending = Completer<List<VodLesson>>();
    final client = _Client()..onPreview = () => pending.future;
    final repository =
        VodRepository(apiClient: client, studentIdLoader: () async => account);
    addTearDown(repository.dispose);
    final result = repository.loadAndWarmSearchLessons(_course, [_lesson(5)]);
    final assertion =
        expectLater(result, throwsA(isA<VodSessionExpiredException>()));
    while (client.previews == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    account = 'warm-search-d';
    pending.complete([_lesson(6)]);
    await assertion;
    await repository.waitForBackgroundWarming();
    expect(client.requested, isEmpty);
  });

  test('clearing repository during preview cancels seed and catalog warming',
      () async {
    final pending = Completer<List<VodLesson>>();
    final client = _Client()..onPreview = () => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-e');
    addTearDown(repository.dispose);
    final result = repository.loadAndWarmSearchLessons(_course, [_lesson(7)]);
    final assertion =
        expectLater(result, throwsA(isA<VodSessionExpiredException>()));
    while (client.previews == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    repository.clear();
    pending.complete([_lesson(8)]);
    await assertion;
    await repository.waitForBackgroundWarming();
    expect(client.requested, isEmpty);
  });

  test('transport switch during preview prevents warming', () async {
    final originalTransport = VodUrlResolver.usesWebVpn;
    addTearDown(() => VodUrlResolver.configure(useWebVpn: originalTransport));
    final pending = Completer<List<VodLesson>>();
    final client = _Client()..onPreview = () => pending.future;
    final repository = VodRepository(
        apiClient: client,
        studentIdLoader: () async => 'warm-search-transport');
    addTearDown(repository.dispose);
    final result = repository.loadAndWarmSearchLessons(_course, [_lesson(9)]);
    final assertion =
        expectLater(result, throwsA(isA<VodSessionExpiredException>()));
    while (client.previews == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    VodUrlResolver.configure(useWebVpn: !originalTransport);
    pending.complete([_lesson(10)]);
    await assertion;
    await repository.waitForBackgroundWarming();
    expect(client.requested, isEmpty);
  });

  test('background tracking includes the pending preview', () async {
    final pending = Completer<List<VodLesson>>();
    final client = _Client()..onPreview = () => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-lifetime');
    addTearDown(repository.dispose);
    final result = repository.loadAndWarmSearchLessons(_course, []);
    var finished = false;
    final waiting = repository.waitForBackgroundWarming().then((_) {
      finished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    pending.complete([_lesson(11)]);
    await result;
    await waiting;
    expect(client.requested, [11]);
  });

  test('force refresh reloads preview and warms links again', () async {
    final client = _Client();
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'warm-search-f');
    addTearDown(repository.dispose);
    await repository.loadAndWarmSearchLessons(_course, []);
    await repository.waitForBackgroundWarming();
    await repository.loadAndWarmSearchLessons(_course, [], forceRefresh: true);
    await repository.waitForBackgroundWarming();
    expect(client.previews, 2);
    expect(client.requested, [2, 2]);
  });
}
