import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_exception.dart';
import 'package:shuyo/features/course_recordings/recording_catalog_controller.dart';
import 'package:shuyo/features/course_recordings/recording_search_controller.dart';

const _term = VodTerm(id: 7, name: '2026-2027学年第1学期', isCurrent: true);

VodCourse _course(int id, {int term = 7}) => VodCourse(
    teachingClassId: id, termId: term, name: '程序设计 $id', code: 'CS$id');

VodLesson _lesson(int id) => VodLesson(
    id: id,
    teachingClassId: id,
    name: '课次 $id',
    isPlayable: true,
    beginTime: DateTime(2026, 10, 1, 8));

class _Repository extends VodRepository {
  final previews = <int>[];
  final counts = <int>[];
  final pending = <int, Completer<List<VodLesson>>>{};
  Future<List<VodSearchResult>> Function(int term, String keyword)? search;
  Future<List<VodTerm>> Function()? termsLoader;
  Future<List<VodCourse>> Function()? catalogLoader;
  List<VodCourse> courses = [for (var id = 1; id <= 5; id++) _course(id)];

  @override
  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) async =>
      await termsLoader?.call() ?? [_term];

  @override
  Future<List<VodCourse>> loadCatalog(
          {required int termId,
          bool forceRefresh = false,
          void Function(List<VodCourse>)? onProgress}) async =>
      await catalogLoader?.call() ?? courses;

  @override
  Future<void> warmOwnRecordings(List<VodTerm> terms,
      {int? preferredTermId, bool forceRefresh = false}) async {}

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    counts.add(course.teachingClassId);
    return await pending[course.teachingClassId]?.future ??
        [_lesson(course.teachingClassId)];
  }

  @override
  Future<List<VodLesson>> loadPreviewLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    previews.add(course.teachingClassId);
    return await pending[course.teachingClassId]?.future ??
        [_lesson(course.teachingClassId)];
  }

  @override
  Future<List<VodSearchResult>> searchLessons(
          {required int termId, required String keyword}) async =>
      await search?.call(termId, keyword) ??
      [
        for (final course in courses)
          VodSearchResult(
              course: course, lesson: _lesson(course.teachingClassId))
      ];
}

Future<void> _drain() async {
  // Flush async repository chains without a Flutter frame or animation clock.
  for (var turn = 0; turn < 20; turn++) {
    await Future<void>.value();
  }
}

void main() {
  test('live courses start preview first and are revealed before VODs',
      () async {
    final live = VodLesson(
      id: 50,
      teachingClassId: 5,
      name: '程序设计 5',
      isPlayable: true,
      isLive: true,
      liveEndTime: DateTime.now().add(const Duration(hours: 1)),
    );
    final repository = _Repository()
      ..search = ((_, __) async => [
            for (var id = 1; id <= 5; id++)
              VodSearchResult(course: _course(id), lesson: _lesson(id)),
            VodSearchResult(course: _course(5), lesson: live),
          ])
      ..pending.addAll(
          {for (var id = 1; id <= 5; id++) id: Completer<List<VodLesson>>()});
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    final search = controller.search('程序');
    await _drain();
    expect(repository.previews, [5, 1, 2]);
    expect(controller.courses.map((course) => course.teachingClassId),
        [5, 1, 2, 3, 4]);
    expect(controller.visibleCourseCount, 1);
    expect(controller.courses.first.isLive, isTrue);
    expect(controller.courseLessons[(7, 5)], [live]);
    final pendingLive = controller.pendingLivePreview((7, 5));
    expect(pendingLive, isNotNull);

    repository.pending[5]!.complete([_lesson(5)]);
    await _drain();
    expect(controller.visibleCourseCount, 1);
    expect(controller.courses.first.isLive, isTrue);
    expect(
        controller.courseLessons[(7, 5)]!.any((item) => item.isLive), isTrue);
    expect((await pendingLive!).map((lesson) => lesson.id), [5, 50]);
    expect(controller.pendingLivePreview((7, 5)), isNull);
    expect(controller.availableCourseCount, 1);
    for (var id = 1; id <= 4; id++) {
      repository.pending[id]!.complete([_lesson(id)]);
    }
    await search;
    expect(repository.previews, [5, 1, 2, 3, 4]);
    expect(controller.visibleCourseCount, 5);
  });

  test('live-only search uses its hit with one existing preview request',
      () async {
    final course = _course(1);
    final live = VodLesson(
      id: 10,
      teachingClassId: 1,
      name: course.name,
      isPlayable: true,
      isLive: true,
      liveEndTime: DateTime.now().add(const Duration(hours: 1)),
    );
    final repository = _Repository()
      ..search = ((_, __) async => [
            VodSearchResult(course: course, lesson: live),
            VodSearchResult(course: course, lesson: live),
          ])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');

    expect(repository.previews, [1]);
    expect(repository.counts, isEmpty);
    expect(controller.courses.single.liveLesson, same(live));
    expect(controller.courses.single.isLive, isTrue);
    expect(controller.courseLessons[(7, 1)], [live]);
    expect(controller.visibleCourseCount, 1);
    expect(controller.availableCourseCount, 1);
  });

  test('live hit replaces the same-ID preview generation placeholder',
      () async {
    final course = _course(1);
    final live = VodLesson(
        id: 10,
        teachingClassId: 1,
        name: course.name,
        isPlayable: true,
        isLive: true,
        liveEndTime: DateTime.now().add(const Duration(hours: 1)));
    final generating = VodLesson(
        id: 10,
        teachingClassId: 1,
        name: course.name,
        isPlayable: false,
        isGenerating: true);
    final repository = _Repository()
      ..search =
          ((_, __) async => [VodSearchResult(course: course, lesson: live)])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([generating]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');

    expect(controller.courseLessons[(7, 1)], [live]);
    expect(repository.previews, [1]);
    expect(controller.courses.single.isLive, isTrue);
  });

  test('generating-only search keeps preview state instead of candidate flags',
      () async {
    final course = _course(1);
    final generating = VodLesson(
        id: 1,
        teachingClassId: 1,
        name: course.name,
        isPlayable: false,
        isGenerating: true);
    final repository = _Repository()
      ..search = ((_, __) async => [
            VodSearchResult(course: course, lesson: _lesson(1)),
          ])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([generating]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');

    expect(controller.courseLessons[(7, 1)], [generating]);
    expect(controller.courses.single.isLive, isFalse);
    expect(controller.availableCourseCount, 1);
    expect(repository.previews, [1]);
    expect(repository.counts, isEmpty);
  });

  test('expired live search hit leaves the preview recording authoritative',
      () async {
    final course = _course(1);
    final expired = VodLesson(
        id: 1,
        teachingClassId: 1,
        name: course.name,
        isPlayable: true,
        isLive: true,
        liveEndTime: DateTime.now().subtract(const Duration(minutes: 1)));
    final recording = _lesson(1);
    final repository = _Repository()
      ..search =
          ((_, __) async => [VodSearchResult(course: course, lesson: expired)])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([recording]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');

    expect(controller.courseLessons[(7, 1)], [recording]);
    expect(controller.courses.single.isLive, isFalse);
    expect(repository.previews, [1]);
  });

  for (final previewContainsRecording in [false, true]) {
    test(
        'explicit generating hit ${previewContainsRecording ? 'yields to' : 'supplements'} preview metadata',
        () async {
      final course = _course(1);
      final generating = VodLesson(
          id: 1,
          teachingClassId: 1,
          name: course.name,
          isPlayable: false,
          isGenerating: true);
      final recording = _lesson(1);
      final repository = _Repository()
        ..search = ((_, __) async => [
              VodSearchResult(course: course, lesson: generating),
            ])
        ..pending[1] = (Completer<List<VodLesson>>()
          ..complete(previewContainsRecording ? [recording] : []));
      final controller =
          RecordingSearchController(repository, selectedTermId: 7);
      addTearDown(controller.dispose);
      addTearDown(repository.dispose);

      await controller.search('程序');

      expect(controller.courseLessons[(7, 1)],
          [previewContainsRecording ? recording : generating]);
      expect(controller.visibleCourseCount, 1);
      expect(controller.availableCourseCount, 1);
      expect(repository.previews, [1]);
      expect(repository.counts, isEmpty);
    });
  }

  for (final failure in [
    const VodWebVpnSessionExpiredException(),
    const VodWebVpnAuthRequiredException(),
  ]) {
    test('search preview ${failure.runtimeType} retains completed courses',
        () async {
      final repository = _Repository()
        ..courses = [_course(1), _course(2)]
        ..pending.addAll({
          1: Completer<List<VodLesson>>(),
          2: Completer<List<VodLesson>>(),
        });
      final invalidations = <bool>[];
      final controller = RecordingSearchController(repository,
          selectedTermId: 7,
          onSessionInvalidated: (expired) async => invalidations.add(expired));
      addTearDown(controller.dispose);
      addTearDown(repository.dispose);
      final search = controller.search('程序');
      await _drain();
      repository.pending[1]!.complete([_lesson(1)]);
      await _drain();
      final completedLessons = controller.courseLessons[(7, 1)];
      repository.pending[2]!.completeError(failure);
      await search;
      expect(controller.error, same(failure));
      expect(controller.needsLogin, isFalse);
      expect(invalidations, isEmpty);
      expect(controller.courses, repository.courses);
      expect(controller.courseLessons[(7, 1)], same(completedLessons));
      expect(controller.courseLessons.containsKey((7, 2)), isFalse);
      expect(controller.visibleCourseCount, 1);
      expect(controller.loadingCourses, isFalse);
    });
  }

  for (final source in ['terms', 'courses', 'lessons']) {
    for (final failure in [
      const VodWebVpnSessionExpiredException(),
      const VodWebVpnAuthRequiredException(),
    ]) {
      test(
          'catalog $source ${failure.runtimeType} preserves course data and identity',
          () async {
        final repository = _Repository()..courses = [_course(1)];
        final invalidations = <bool>[];
        final controller = RecordingCatalogController(repository,
            onSessionInvalidated: (expired) async =>
                invalidations.add(expired));
        addTearDown(controller.dispose);
        addTearDown(repository.dispose);
        await controller.load();
        final oldLessons = controller.courseLessons[1];
        if (source == 'terms') {
          repository.termsLoader = () async => throw failure;
        } else if (source == 'courses') {
          repository.catalogLoader = () async => throw failure;
        } else {
          repository.pending[1] = Completer<List<VodLesson>>();
        }
        final refresh = controller.load(force: true);
        if (source == 'lessons') {
          await _drain();
          repository.pending[1]!.completeError(failure);
        }
        await refresh;
        expect(controller.error, same(failure));
        expect(invalidations, isEmpty);
        expect(controller.terms, [_term]);
        expect(controller.selectedTermId, 7);
        expect(controller.courses, same(repository.courses));
        expect(controller.courseLessons[1], same(oldLessons));
        expect(controller.isLoading, isFalse);
      });
    }
  }

  test('search queue progresses without frames and keeps ranking stable',
      () async {
    final repository = _Repository()
      ..pending.addAll(
          {for (var id = 1; id <= 5; id++) id: Completer<List<VodLesson>>()});
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final search = controller.search('程序');
    await _drain();
    expect(repository.previews, [1, 2, 3]);
    repository.pending[2]!.complete([_lesson(2)]);
    await _drain();
    expect(repository.previews, [1, 2, 3, 4]);
    expect(controller.visibleCourseCount, 0);
    expect(controller.availableCourseCount, 1);
    repository.pending[1]!.complete([_lesson(1)]);
    repository.pending[3]!.complete([]);
    await _drain();
    expect(controller.visibleCourseCount, 3);
    expect(controller.availableCourseCount, 2);
    repository.pending[4]!.completeError(const VodNetworkException());
    repository.pending[5]!.complete([_lesson(5)]);
    await search;
    expect(controller.visibleCourseCount, 5);
    expect(controller.availableCourseCount, 3);
    expect(controller.courseLessons[(7, 4)], isEmpty);
    expect(controller.loadingCourses, isFalse);
  });

  test(
      'clearing a search stops queued work and discards late authentication failure',
      () async {
    final repository = _Repository()
      ..pending.addAll(
          {for (var id = 1; id <= 3; id++) id: Completer<List<VodLesson>>()});
    final expired = <bool>[];
    final controller = RecordingSearchController(repository,
        selectedTermId: 7,
        onSessionInvalidated: (value) async => expired.add(value));
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final search = controller.search('程序');
    await _drain();
    controller.selectTerm(8);
    repository.pending[1]!.completeError(const VodSessionExpiredException());
    repository.pending[2]!.complete([_lesson(2)]);
    repository.pending[3]!.complete([_lesson(3)]);
    await search;
    expect(repository.previews, [1, 2, 3]);
    expect(controller.selectedTermId, 8);
    expect(controller.courses, isEmpty);
    expect(controller.needsLogin, isFalse);
    expect(expired, isEmpty);
  });

  test('new search keeps its results when an older search finishes', () async {
    final old = Completer<List<VodSearchResult>>();
    final repository = _Repository()
      ..search = (term, keyword) async {
        if (keyword == '旧课') return await old.future;
        return [VodSearchResult(course: _course(2), lesson: _lesson(2))];
      };
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final first = controller.search('旧课');
    await controller.search('程序');
    old.complete([VodSearchResult(course: _course(1), lesson: _lesson(1))]);
    await first;
    expect(controller.courses.single.teachingClassId, 2);
    expect(controller.availableCourseCount, 1);
    expect(controller.activeKeyword, '程序');
    expect(repository.previews, [2]);
  });

  test(
      'catalog retains unchanged course metadata and indexes timetable on demand',
      () async {
    final repository = _Repository()
      ..pending.addAll(
          {for (var id = 1; id <= 5; id++) id: Completer<List<VodLesson>>()});
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {});
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final load = controller.load();
    await _drain();
    expect(repository.counts, [1, 2, 3]);
    repository.pending[1]!.complete([_lesson(1)]);
    await _drain();
    final count = controller.lessonCounts[1];
    final lessons = controller.courseLessons[1];
    final timetable = controller.timetable;
    expect(identical(controller.timetable, timetable), isTrue);
    repository.pending[2]!.complete([]);
    await _drain();
    expect(identical(controller.lessonCounts[1], count), isTrue);
    expect(identical(controller.courseLessons[1], lessons), isTrue);
    expect(identical(controller.timetable, timetable), isFalse);
    for (var id = 3; id <= 5; id++) {
      repository.pending[id]!.complete([_lesson(id)]);
    }
    await load;
    expect(controller.visibleCourses.map((course) => course.teachingClassId),
        [1, 2, 3, 4, 5]);
    expect(controller.visibleIndexes[5], 4);
    expect(controller.isLoading, isFalse);
  });

  test('disposing a catalog completes refresh and cancels queued metadata work',
      () async {
    final repository = _Repository()
      ..pending.addAll(
          {for (var id = 1; id <= 3; id++) id: Completer<List<VodLesson>>()});
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {});
    addTearDown(repository.dispose);
    final load = controller.load(fromPull: true);
    await _drain();
    expect(repository.counts, [1, 2, 3]);
    controller.dispose();
    await load;
    for (var id = 1; id <= 3; id++) {
      repository.pending[id]!.complete([_lesson(id)]);
    }
    await _drain();
    expect(repository.counts, [1, 2, 3]);
    expect(controller.courseLessons, isEmpty);
  });
}
