import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
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
  List<VodCourse> courses = [for (var id = 1; id <= 5; id++) _course(id)];

  @override
  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) async => [_term];

  @override
  Future<List<VodCourse>> loadCatalog(
          {required int termId,
          bool forceRefresh = false,
          void Function(List<VodCourse>)? onProgress}) async =>
      courses;

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
