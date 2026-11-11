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
  VodRecordingAvailability candidateAvailability =
      VodRecordingAvailability.available;
  final verifiedCandidates = <int>[];
  final generating = <int, Completer<List<VodLesson>>>{};
  bool liveAvailable = true;
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
  Future<List<VodLesson>> loadSearchLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    previews.add(course.teachingClassId);
    return await pending[course.teachingClassId]?.future ??
        [_lesson(course.teachingClassId)];
  }

  @override
  Future<bool> verifyLiveSearchLesson(
          VodCourse course, VodLesson lesson) async =>
      liveAvailable;

  @override
  Future<List<VodLesson>> loadGeneratingLessons(VodCourse course,
          {bool forceRefresh = false}) async =>
      await generating[course.teachingClassId]?.future ?? const [];

  @override
  Future<void> verifyCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {required void Function(int, VodRecordingAvailability) onResult,
      required bool Function() isCurrent,
      bool fresh = false,
      bool forceRefresh = false}) async {
    for (final lesson in lessons) {
      verifiedCandidates.add(lesson.id);
      if (isCurrent()) onResult(lesson.id, candidateAvailability);
    }
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
  test('source live with no devices does not come back as a one-lesson seed',
      () async {
    final hit = VodSearchResult.fromJson({
      'id': 283850,
      'teclId': 1,
      'acteId': 7,
      'subjName': '程序设计 1',
      'courseStatus': 0,
    });
    final repository = _Repository()
      ..liveAvailable = false
      ..search = ((_, __) async => [hit])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.search('程序');
    expect(controller.courseLessons[(7, 1)], isEmpty);
    expect(controller.availableCourseCount, 0);
    expect(controller.courses.single.isLive, isFalse);
    expect(repository.verifiedCandidates, isEmpty);
  });

  test('generation is published before an unrelated earlier preview completes',
      () async {
    final repository = _Repository()
      ..courses = [_course(1), _course(2)]
      ..pending[1] = Completer<List<VodLesson>>()
      ..pending[2] = Completer<List<VodLesson>>()
      ..generating[1] = Completer<List<VodLesson>>()
      ..generating[2] = Completer<List<VodLesson>>();
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final searching = controller.search('程序');
    await _drain();
    const generating = VodLesson(
        id: 281778,
        teachingClassId: 2,
        name: '程序设计 2',
        isPlayable: false,
        isGenerating: true);
    repository.generating[2]!.complete([generating]);
    await _drain();
    expect(controller.courseLessons[(7, 2)], [generating]);
    expect(controller.courseLessons.containsKey((7, 1)), isFalse);
    expect(
        RecordingSearchViewData(controller).courses.single.teachingClassId, 2);
    expect(controller.visibleCourseCount, 1);
    repository.pending[2]!.complete([_lesson(2)]);
    await _drain();
    expect(controller.courseLessons[(7, 2)], contains(generating));
    repository.pending[1]!.complete([_lesson(1)]);
    repository.generating[1]!.complete([]);
    await searching;
  });

  test('late generation cannot disable a preview recording and clear drops it',
      () async {
    final repository = _Repository()
      ..courses = [_course(1)]
      ..generating[1] = Completer<List<VodLesson>>();
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    final searching = controller.search('程序');
    await _drain();
    expect(controller.courseLessons[(7, 1)]!.single.isPlayable, isTrue);
    repository.generating[1]!.complete([
      const VodLesson(
          id: 1,
          teachingClassId: 1,
          name: '程序设计',
          isPlayable: false,
          isGenerating: true),
    ]);
    await searching;
    expect(controller.courseLessons[(7, 1)]!.single.isGenerating, isFalse);
    final pending = Completer<List<VodLesson>>();
    repository.generating[1] = pending;
    final nextSearch = controller.search('程序');
    await _drain();
    controller.clear();
    pending.complete([
      const VodLesson(
          id: 2,
          teachingClassId: 1,
          name: '程序设计',
          isPlayable: false,
          isGenerating: true),
    ]);
    await nextSearch;
    expect(controller.courseLessons, isEmpty);
  });

  test('recording search hit needs verified URLs when its preview is empty',
      () async {
    final hit = VodSearchResult.fromJson({
      'id': 19,
      'teclId': 1,
      'acteId': 7,
      'subjName': '程序设计 1',
      'courseStatus': 2,
    });
    final repository = _Repository()
      ..search = ((_, __) async => [hit])
      ..pending[1] = (Completer<List<VodLesson>>()..complete([]));
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');

    expect(controller.courseLessons[(7, 1)], [hit.lesson]);
    expect(controller.courseLessons[(7, 1)]!.single.canPlay, isTrue);
    expect(controller.visibleCourseCount, 1);
    expect(controller.availableCourseCount, 1);
    expect(repository.verifiedCandidates, [19]);
  });

  for (final availability in [
    VodRecordingAvailability.unavailable,
    VodRecordingAvailability.unknown,
  ]) {
    test('empty preview plus $availability source does not invent one lesson',
        () async {
      final hit = VodSearchResult.fromJson({
        'id': 19,
        'teclId': 1,
        'acteId': 7,
        'subjName': '程序设计 1',
        'courseStatus': 2,
      });
      final repository = _Repository()
        ..candidateAvailability = availability
        ..search = ((_, __) async => [hit])
        ..pending[1] = (Completer<List<VodLesson>>()..complete([]));
      final controller =
          RecordingSearchController(repository, selectedTermId: 7);
      addTearDown(controller.dispose);
      addTearDown(repository.dispose);
      await controller.search('程序');
      expect(controller.courseLessons[(7, 1)], isEmpty);
      expect(controller.availableCourseCount, 0);
      expect(controller.visibleCourseCount, 1);
      expect(repository.verifiedCandidates, [19]);
    });
  }

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
    expect(controller.courseLessons[(7, 5)]!.map((lesson) => lesson.id), [50]);
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
    expect(controller.availableCourseCount, 0);
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
      expect(controller.availableCourseCount, previewContainsRecording ? 1 : 0);
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
    expect(controller.visibleCourseCount, 1);
    expect(controller.availableCourseCount, 1);
    repository.pending[1]!.complete([_lesson(1)]);
    repository.pending[3]!.complete([]);
    await _drain();
    expect(controller.visibleCourseCount, 3);
    expect(controller.availableCourseCount, 3);
    repository.pending[4]!.completeError(const VodNetworkException());
    repository.pending[5]!.complete([_lesson(5)]);
    await search;
    expect(controller.visibleCourseCount, 5);
    expect(controller.availableCourseCount, 5);
    expect(controller.courseLessons[(7, 4)]!.single.id, 4);
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

  test('cached search yields to events and stops its remaining queue on clear',
      () async {
    final repository = _Repository()
      ..courses = [for (var id = 1; id <= 70; id++) _course(id)];
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    final search = controller.search('程序');
    await Future<void>.delayed(Duration.zero);
    expect(repository.previews, isNotEmpty);
    expect(repository.previews.length, lessThan(70));
    controller.clear();
    final requestsAtClear = repository.previews.length;
    await search;
    expect(repository.previews.length, requestsAtClear);
    expect(controller.courses, isEmpty);
    expect(controller.courseLessons, isEmpty);
  });

  test('large search groups on a worker and keeps all matching courses',
      () async {
    final repository = _Repository()
      ..courses = [for (var id = 1; id <= 100; id++) _course(id)];
    final controller = RecordingSearchController(repository, selectedTermId: 7);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    await controller.search('程序');
    expect(controller.courses.length, 100);
    expect(controller.visibleCourseCount, 100);
    expect(controller.availableCourseCount, 100);
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

  test('cached catalog yields and stops queued work when cleared', () async {
    final repository = _Repository()
      ..courses = [for (var id = 1; id <= 70; id++) _course(id)];
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {});
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);

    final load = controller.load();
    await Future<void>.delayed(Duration.zero);
    expect(repository.counts, isNotEmpty);
    expect(repository.counts.length, lessThan(70));
    controller.clear();
    final requestsAtClear = repository.counts.length;
    await load;
    await Future<void>.delayed(Duration.zero);
    expect(repository.counts.length, requestsAtClear);
    expect(controller.visibleCourses, isEmpty);
  });
}
