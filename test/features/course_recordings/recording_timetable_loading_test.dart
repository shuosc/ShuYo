import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/features/course_recordings/recording_catalog_controller.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_data.dart';

const _term = VodTerm(id: 7, name: '当前学期', isCurrent: true);
const _otherTerm = VodTerm(id: 6, name: '其他学期');
final _date = DateTime(2026, 11, 2);

class _Repository extends VodRepository {
  int generation = 0;

  @override
  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) async =>
      [_term, _otherTerm];

  @override
  Future<List<VodCourse>> loadCatalog(
      {required int termId,
      bool forceRefresh = false,
      void Function(List<VodCourse>)? onProgress}) async {
    generation++;
    return [VodCourse(teachingClassId: termId, termId: termId, name: '课程')];
  }

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
          {bool forceRefresh = false}) async =>
      [
        VodLesson(
            id: generation,
            teachingClassId: course.teachingClassId,
            name: '课次 $generation',
            isPlayable: true,
            beginTime: _date)
      ];

  @override
  Future<void> warmOwnRecordings(List<VodTerm> terms,
      {int? preferredTermId, bool forceRefresh = false}) async {}
}

class _Worker {
  final inputs = <RecordingTimetableInput>[];
  final completions = <Completer<RecordingTimetableData>>[];
  int active = 0;
  int maxActive = 0;

  Future<RecordingTimetableData> call(RecordingTimetableInput input) {
    inputs.add(input);
    final completion = Completer<RecordingTimetableData>();
    completions.add(completion);
    active++;
    if (active > maxActive) maxActive = active;
    return completion.future.whenComplete(() => active--);
  }

  RecordingTimetableData finish(int index) {
    final input = inputs[index];
    final data = RecordingTimetableData(
        term: input.term,
        courses: input.courses,
        lessonsByCourse: input.lessonsByCourse,
        now: _date);
    completions[index].complete(data);
    return data;
  }
}

void main() {
  test('small timetable finishes synchronously without a loading frame', () {
    final future = loadRecordingTimetable(RecordingTimetableInput(
        term: _term, courses: const [], lessonsByCourse: const {}, now: _date));
    expect(future, isA<SynchronousFuture<RecordingTimetableData>>());
    var completed = false;
    future.then((_) => completed = true);
    expect(completed, isTrue);
  });

  test('large timetable worker preserves aggregation and numbering', () async {
    const course = VodCourse(teachingClassId: 7, termId: 7, name: '课程');
    final input = RecordingTimetableInput(
        term: _term,
        courses: const [course],
        lessonsByCourse: {
          7: List.unmodifiable([
            for (var id = 1; id <= 250; id++)
              VodLesson(
                  id: id,
                  teachingClassId: 7,
                  name: '课次 $id',
                  isPlayable: true,
                  beginTime: _date.add(Duration(days: id % 12, minutes: id)))
          ])
        },
        now: _date);
    final future = loadRecordingTimetable(input);
    expect(future, isNot(isA<SynchronousFuture<RecordingTimetableData>>()));
    final actual = await future;
    final expected = RecordingTimetableData(
        term: input.term,
        courses: input.courses,
        lessonsByCourse: input.lessonsByCourse,
        now: input.now);
    expect(actual.firstWeekMonday, expected.firstWeekMonday);
    expect(actual.maxWeek, expected.maxWeek);
    expect(actual.initialWeek, expected.initialWeek);
    for (var day = 0; day < 12; day++) {
      final date = _date.add(Duration(days: day));
      expect(
          actual
              .entriesFor(date)
              .map((entry) => (entry.lesson.id, entry.number)),
          expected
              .entriesFor(date)
              .map((entry) => (entry.lesson.id, entry.number)));
    }
  });

  test('one revision shares a future and caches the completed snapshot',
      () async {
    final repository = _Repository();
    final worker = _Worker();
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {}, timetableLoader: worker.call);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.load();
    final first = controller.loadTimetable();
    expect(controller.loadTimetable(), same(first));
    expect(worker.inputs, hasLength(1));
    final result = worker.finish(0);
    expect(await first, same(result));
    expect(controller.timetable, same(result));
    expect(controller.loadTimetable(), same(first));
  });

  test('burst revisions run one worker and skip superseded queued inputs',
      () async {
    final repository = _Repository();
    final worker = _Worker();
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {}, timetableLoader: worker.call);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.load();
    final first = controller.loadTimetable();
    final middle = <Future<RecordingTimetableData>>[];
    for (var revision = 0; revision < 30; revision++) {
      await controller.load(force: true);
      middle.add(controller.loadTimetable());
    }
    await controller.load(force: true);
    final latest = controller.loadTimetable();
    expect(worker.inputs, hasLength(1));
    final firstResult = worker.finish(0);
    await first;
    // The old same-term viewport keeps a usable snapshot while the newest
    // revision is prepared; it must not briefly become an empty timetable.
    for (final skipped in middle) {
      expect(await skipped, same(firstResult));
    }
    expect(worker.inputs, hasLength(2));
    expect(worker.inputs.last.lessonsByCourse[7]!.single.id, 32);
    expect(worker.active, 1);
    expect(worker.maxActive, 1);
    expect(controller.loadTimetable(), same(latest));
    final latestResult = worker.finish(1);
    expect(await latest, same(latestResult));
    expect(controller.timetable, same(latestResult));
  });

  test('term changes wait for the worker without reusing another term',
      () async {
    final repository = _Repository();
    final worker = _Worker();
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {}, timetableLoader: worker.call);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.load();
    final first = controller.loadTimetable();
    await controller.load(termId: 6);
    final next = controller.loadTimetable();
    worker.finish(0);
    await first;
    await Future<void>.value();
    expect(worker.inputs, hasLength(2));
    expect(worker.inputs.last.term!.id, 6);
    expect(worker.maxActive, 1);
    final result = worker.finish(1);
    expect(await next, same(result));
    expect(result.entriesFor(_date).single.course.termId, 6);
    expect(controller.timetable, same(result));
  });

  test('superseded term queues cannot receive the active term snapshot',
      () async {
    final repository = _Repository();
    final worker = _Worker();
    final controller = RecordingCatalogController(repository,
        onSessionInvalidated: (_) async {}, timetableLoader: worker.call);
    addTearDown(controller.dispose);
    addTearDown(repository.dispose);
    await controller.load();
    final first = controller.loadTimetable();
    await controller.load(termId: 6);
    final skipped = controller.loadTimetable();
    await controller.load(termId: 7);
    final latest = controller.loadTimetable();
    worker.finish(0);
    await first;
    expect((await skipped).hasDatedLessons, isFalse);
    expect(worker.inputs, hasLength(2));
    expect(worker.inputs.last.term!.id, 7);
    worker.finish(1);
    await latest;
    expect(worker.maxActive, 1);
  });

  for (final dispose in [false, true]) {
    test('${dispose ? 'dispose' : 'clear'} prevents queued timetable work',
        () async {
      final repository = _Repository();
      final worker = _Worker();
      final controller = RecordingCatalogController(repository,
          onSessionInvalidated: (_) async {}, timetableLoader: worker.call);
      var disposed = false;
      addTearDown(() {
        if (!disposed) controller.dispose();
      });
      addTearDown(repository.dispose);
      await controller.load();
      final first = controller.loadTimetable();
      await controller.load(force: true);
      final queued = controller.loadTimetable();
      if (dispose) {
        controller.dispose();
        disposed = true;
      } else {
        controller.clear();
      }
      worker.finish(0);
      await first;
      await queued;
      expect(worker.inputs, hasLength(1));
      expect(worker.active, 0);
      if (!dispose) {
        final fresh = controller.loadTimetable();
        expect(worker.inputs, hasLength(2));
        expect(worker.inputs.last.term, isNull);
        expect(worker.inputs.last.lessonsByCourse, isEmpty);
        final empty = worker.finish(1);
        expect(await fresh, same(empty));
        expect(controller.timetable.hasDatedLessons, isFalse);
      }
    });
  }
}
