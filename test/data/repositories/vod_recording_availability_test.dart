import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';

const _course = VodCourse(teachingClassId: 4108, termId: 4, name: '日本动漫文化');
VodLesson _lesson(int id) => VodLesson(
    id: id,
    teachingClassId: 4108,
    name: '课次',
    isPlayable: false,
    isListed: false);

class _Client extends VodApiClient {
  _Client({bool vpn = false})
      : super(headersLoader: (_) async => {}, useWebVpn: vpn);
  final calls = <int>[];
  Future<VodPlayback> Function(VodLesson)? respond;

  @override
  Future<VodPlayback> fetchPlayback(
      {required VodCourse course, required VodLesson lesson}) {
    calls.add(lesson.id);
    return respond?.call(lesson) ??
        Future.value(VodPlayback(
            lessonId: lesson.id,
            teachingClassId: course.teachingClassId,
            title: lesson.name,
            views: [
              VodView(
                  viewNumber: 1, url: Uri.parse('https://example.com/a.mp4'))
            ]));
  }

  @override
  Future<void> checkPlaybackUrls(
      {required VodCourse course, required VodLesson lesson}) async {
    await fetchPlayback(course: course, lesson: lesson);
  }

  @override
  Future<Map<String, String>> mediaHeadersFor(Uri target) async => {};
}

class _Store extends SecureAppStore {
  int writes = 0;
  int reads = 0;
  String? value;
  @override
  Future<String?> read(String key) async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    this.value = value;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodRepository.warmingRequestSpacing = Duration.zero;
    VodRepository.warmingSuccessTtl = const Duration(hours: 6);
    VodRepository.warmingFailureTtl = const Duration(minutes: 2);
  });

  test('checks actual URLs regardless of metadata; errors remain unknown',
      () async {
    final client = _Client();
    final store = _Store();
    client.respond = (lesson) async {
      if (lesson.id == 2) throw const VodNoPlaybackException();
      if (lesson.id == 3) throw const VodNetworkException();
      if (lesson.id == 4) throw const VodSessionExpiredException();
      if (lesson.id == 5) throw const VodInvalidResponseException();
      if (lesson.id == 6) throw const VodPermissionException();
      if (lesson.id == 7) throw TimeoutException('timeout');
      return VodPlayback(
          lessonId: lesson.id,
          teachingClassId: _course.teachingClassId,
          title: lesson.name,
          views: [
            VodView(viewNumber: 1, url: Uri.parse('https://example.com/a.mp4'))
          ]);
    };
    final repo = VodRepository(
        apiClient: client,
        recordingCache: VodRecordingCache(store: store),
        studentIdLoader: () async => 'availability-test');
    addTearDown(repo.dispose);
    final results = <int, VodRecordingAvailability>{};
    await repo.verifyCourseRecordings(
        _course, List.generate(7, (i) => _lesson(i + 1)),
        fresh: true,
        isCurrent: () => true,
        onResult: (id, value) => results[id] = value);
    expect(results, {
      1: VodRecordingAvailability.available,
      2: VodRecordingAvailability.unavailable,
      3: VodRecordingAvailability.unknown,
      4: VodRecordingAvailability.unknown,
      5: VodRecordingAvailability.unknown,
      6: VodRecordingAvailability.unknown,
      7: VodRecordingAvailability.unknown
    });
    expect(store.writes, 0);
  });

  test('playback falls back on outage but not a confirmed empty response',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    final lesson = _lesson(71);
    final playback = VodPlayback(
        lessonId: 71,
        teachingClassId: _course.teachingClassId,
        title: lesson.name,
        views: [
          VodView(
              viewNumber: 1,
              url: Uri.parse('https://vrmvod.cc.shu.edu.cn:40443/vod/a.mp4'))
        ]);
    await cache.save('playback-fallback', false, 'playback:4108:71', {
      'course': VodRecordingCache.courseJson(_course),
      'lesson': VodRecordingCache.lessonJson(lesson),
      'playback': VodRecordingCache.playbackJson(playback),
    });
    final client = _Client()
      ..respond = (_) async => throw const VodNetworkException();
    final repo = VodRepository(
        apiClient: client,
        recordingCache: cache,
        studentIdLoader: () async => 'playback-fallback');
    addTearDown(repo.dispose);
    expect((await repo.preparePlayback(course: _course, lesson: lesson)).views,
        isNotEmpty);
    client.respond = (_) async => throw const VodNoPlaybackException();
    await expectLater(repo.preparePlayback(course: _course, lesson: lesson),
        throwsA(isA<VodNoPlaybackException>()));
  });

  test('negative availability expires on the shorter failure cooldown',
      () async {
    VodRepository.warmingFailureTtl = Duration.zero;
    final client = _Client()
      ..respond = (_) async => throw const VodNoPlaybackException();
    final repo = VodRepository(
        apiClient: client, studentIdLoader: () async => 'short-negative');
    addTearDown(repo.dispose);
    final values = <int, VodRecordingAvailability>{};
    Future<void> check() => repo.verifyCourseRecordings(_course, [_lesson(72)],
        isCurrent: () => true, onResult: (id, status) => values[id] = status);
    await check();
    expect(values[72], VodRecordingAvailability.unavailable);
    client.respond = null;
    await check();
    expect(values[72], VodRecordingAvailability.available);
    await check();
    expect(client.calls, [72, 72]);
  });

  test(
      'fresh search checks again after home warming without persisting the search',
      () async {
    final client = _Client();
    final store = _Store();
    final repo = VodRepository(
        apiClient: client,
        recordingCache: VodRecordingCache(store: store),
        studentIdLoader: () async => 'availability-fresh');
    addTearDown(repo.dispose);
    await repo.warmCourseRecordings(_course, [_lesson(11)]);
    await repo.waitForBackgroundWarming();
    final writes = store.writes;
    final results = <int, VodRecordingAvailability>{};
    await repo.verifyCourseRecordings(_course, [_lesson(11)],
        isCurrent: () => true, onResult: (id, value) => results[id] = value);
    expect(client.calls, [11]);
    final reads = store.reads;
    await repo.verifyCourseRecordings(_course, [_lesson(11)],
        fresh: true,
        isCurrent: () => true,
        onResult: (id, value) => results[id] = value);
    expect(client.calls, [11, 11]);
    expect(results[11], VodRecordingAvailability.available);
    expect(store.writes, writes);
    expect(store.reads, reads);
  });

  test('cold home uses validated same-scope cached links during an outage',
      () async {
    final store = _Store();
    final cache = VodRecordingCache(store: store);
    final lesson = _lesson(51);
    final playback = VodPlayback(
        lessonId: 51,
        teachingClassId: _course.teachingClassId,
        title: lesson.name,
        views: [
          VodView(
              viewNumber: 1,
              url: Uri.parse('https://vrmvod.cc.shu.edu.cn:40443/vod/a.mp4'))
        ]);
    await cache.save('availability-offline', false, 'playback:4108:51', {
      'course': VodRecordingCache.courseJson(_course),
      'lesson': VodRecordingCache.lessonJson(lesson),
      'playback': VodRecordingCache.playbackJson(playback),
    });
    final client = _Client()
      ..respond = (_) async => throw const VodNetworkException();
    final repo = VodRepository(
        apiClient: client,
        recordingCache: cache,
        studentIdLoader: () async => 'availability-offline');
    addTearDown(repo.dispose);
    final values = <int, VodRecordingAvailability>{};
    await repo.verifyCourseRecordings(_course, [lesson, _lesson(52)],
        isCurrent: () => true, onResult: (id, value) => values[id] = value);
    expect(values[51], VodRecordingAvailability.available);
    expect(values[52], VodRecordingAvailability.unknown);
    expect(client.calls, [52]);
    // Manual refresh attempts the server and falls back on a network error.
    await repo.verifyCourseRecordings(_course, [lesson],
        forceRefresh: true,
        isCurrent: () => true,
        onResult: (id, value) => values[id] = value);
    expect(client.calls, [52, 51]);
    expect(values[51], VodRecordingAvailability.available);
    // Search must not use those saved URLs as evidence.
    await repo.verifyCourseRecordings(_course, [lesson],
        fresh: true,
        isCurrent: () => true,
        onResult: (id, value) => values[id] = value);
    expect(values[51], VodRecordingAvailability.unknown);
    client.respond = (_) async => throw const VodPermissionException();
    await repo.verifyCourseRecordings(_course, [lesson],
        forceRefresh: true,
        isCurrent: () => true,
        onResult: (id, value) => values[id] = value);
    expect(values[51], VodRecordingAvailability.unknown);
    client.respond = (_) async => throw const VodNoPlaybackException();
    await repo.verifyCourseRecordings(_course, [lesson],
        forceRefresh: true,
        isCurrent: () => true,
        onResult: (id, value) => values[id] = value);
    expect(values[51], VodRecordingAvailability.unavailable);
    await repo.verifyCourseRecordings(_course, [lesson],
        isCurrent: () => true, onResult: (id, value) => values[id] = value);
    expect(values[51], VodRecordingAvailability.unavailable);

    // Neither a different account nor another transport can reuse either
    // persisted links or the in-memory availability result.
    for (final (account, vpn) in [
      ('another-account', false),
      ('availability-offline', true)
    ]) {
      final otherClient = _Client(vpn: vpn)
        ..respond = (_) async => throw const VodNetworkException();
      final otherRepo = VodRepository(
          apiClient: otherClient,
          recordingCache: cache,
          studentIdLoader: () async => account);
      await otherRepo.verifyCourseRecordings(_course, [lesson],
          isCurrent: () => true, onResult: (id, value) => values[id] = value);
      expect(values[51], VodRecordingAvailability.unknown);
      expect(otherClient.calls, [51]);
      otherRepo.dispose();
    }
  });

  test('cancels queued and in-flight checks when search changes', () async {
    final client = _Client();
    final started = Completer<void>();
    final release = Completer<void>();
    client.respond = (lesson) async {
      started.complete();
      await release.future;
      throw const VodNoPlaybackException();
    };
    final repo = VodRepository(
        apiClient: client, studentIdLoader: () async => 'availability-cancel');
    addTearDown(repo.dispose);
    var current = true;
    final results = <int, VodRecordingAvailability>{};
    final checking = repo.verifyCourseRecordings(
        _course, [_lesson(21), _lesson(22)],
        fresh: true,
        isCurrent: () => current,
        onResult: (id, value) => results[id] = value);
    await started.future;
    current = false;
    release.complete();
    await checking;
    expect(client.calls, [21]);
    expect(results, isEmpty);
  });

  test('search checks run before home checks and silent warming', () async {
    final client = _Client();
    final started = Completer<void>();
    final release = Completer<void>();
    client.respond = (lesson) async {
      if (lesson.id == 31) {
        started.complete();
        await release.future;
      }
      return VodPlayback(
          lessonId: lesson.id,
          teachingClassId: _course.teachingClassId,
          title: lesson.name,
          views: [
            VodView(viewNumber: 1, url: Uri.parse('https://example.com/a.mp4'))
          ]);
    };
    final repo = VodRepository(
        apiClient: client,
        studentIdLoader: () async => 'availability-priority');
    addTearDown(repo.dispose);
    final warming =
        repo.warmCourseRecordings(_course, [_lesson(31), _lesson(32)]);
    await started.future;
    final home = repo.verifyCourseRecordings(_course, [_lesson(33)],
        isCurrent: () => true, onResult: (_, __) {});
    // Let the account lookup enqueue the home request before the search.
    await Future<void>.delayed(Duration.zero);
    final search = repo.verifyCourseRecordings(_course, [_lesson(34)],
        fresh: true, isCurrent: () => true, onResult: (_, __) {});
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await Future.wait([warming, home, search]);
    expect(client.calls, [31, 34, 33, 32]);
  });
}
