import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_episode_catalog.dart';
import 'package:shuyo/features/course_recordings/recording_episode_metadata.dart';

VodLesson _lesson(
  int id, {
  int teachingClassId = 42,
  String classroom = 'A101',
  DateTime? beginTime,
  String section = '第1节',
  bool isPlayable = true,
  bool isLive = false,
}) =>
    VodLesson(
      id: id,
      teachingClassId: teachingClassId,
      name: '课程',
      classroom: classroom,
      beginTime: beginTime,
      endTime: beginTime?.add(const Duration(minutes: 45)),
      sectionLabel: section,
      isPlayable: isPlayable,
      isLive: isLive,
    );

class _ReadCountingLessons extends ListBase<VodLesson> {
  _ReadCountingLessons(this._lessons);

  final List<VodLesson> _lessons;
  int reads = 0;

  @override
  int get length => _lessons.length;

  @override
  set length(int value) => throw UnsupportedError('immutable fixture');

  @override
  VodLesson operator [](int index) {
    reads++;
    return _lessons[index];
  }

  @override
  void operator []=(int index, VodLesson value) =>
      throw UnsupportedError('immutable fixture');
}

void main() {
  test('keeps playback candidates and sorts rooms with unknown last', () {
    final time = DateTime(2026, 10, 27, 8);
    final catalog = RecordingEpisodeCatalog(lessons: [
      _lesson(2, classroom: ' B202 ', beginTime: time),
      _lesson(1, classroom: 'A101', beginTime: time),
      _lesson(3, classroom: ' ', isPlayable: false),
      _lesson(4, classroom: 'A101', isLive: true, isPlayable: false),
      _lesson(0),
      _lesson(8, teachingClassId: 99),
    ], teachingClassId: 42);

    expect(catalog.lessons.map((lesson) => lesson.id), [2, 1, 4, 3]);
    expect(catalog.classrooms, ['A101', 'B202', '']);
    expect(catalog.classroom('B202').newestFirst.single.id, 2);
    expect(catalog.metadataFor(catalog.lessons.first)!.classroom, 'B202');
    expect(catalog.classroom('unavailable'),
        same(RecordingClassroomEpisodes.empty));
  });

  test('room episode numbers stay chronological in either month order', () {
    final catalog = RecordingEpisodeCatalog(lessons: [
      _lesson(1, beginTime: DateTime(2026, 9, 22)),
      _lesson(2, beginTime: DateTime(2026, 10, 27)),
      _lesson(3, beginTime: DateTime(2026, 10, 28)),
      _lesson(4, classroom: 'B202', beginTime: DateTime(2026, 10, 29)),
      _lesson(5),
    ], teachingClassId: 42);
    final room = catalog.classroom('A101');

    expect(room.newestFirst.map((lesson) => lesson.id), [3, 2, 1, 5]);
    expect(room.oldestFirst.map((lesson) => lesson.id), [5, 1, 2, 3]);
    expect(room.episodeNumbers, {3: 4, 2: 3, 1: 2, 5: 1});
    expect(catalog.classroom('B202').episodeNumbers, {4: 1});
    expect(room.newestMonths.map((month) => month.month),
        [(2026, 10), (2026, 9), null]);
    expect(room.oldestMonths.map((month) => month.month),
        [null, (2026, 9), (2026, 10)]);
    expect(room.newestMonths.first.lessons.map((lesson) => lesson.id), [3, 2]);
    expect(room.oldestMonths.last.lessons.map((lesson) => lesson.id), [2, 3]);
    expect(room.newestMonths.first.indexByLessonId, {3: 0, 2: 1});
    expect(room.oldestMonths.last.indexByLessonId, {2: 0, 3: 1});
  });

  test('latest matching identity and explicit room preserve season selection',
      () {
    final stale = _lesson(1, classroom: 'Old');
    final latest = _lesson(1, classroom: 'B202');
    final live = _lesson(1, classroom: 'C303', isLive: true);
    final catalog = RecordingEpisodeCatalog(lessons: [
      latest,
      live,
      _lesson(2, classroom: 'A101'),
    ], teachingClassId: 42);

    expect(catalog.selectionFor(stale), same(latest));
    expect(catalog.selectionFor(live), same(live));
    expect(catalog.activeClassroom(current: stale), 'B202');
    expect(catalog.activeClassroom(current: live), 'C303');
    expect(catalog.activeClassroom(current: stale, selected: 'A101'), 'A101');
    expect(catalog.activeClassroom(current: stale, selected: 'Old'), 'B202');
    expect(catalog.activeClassroom(current: _lesson(99, classroom: 'Gone')),
        'A101');
  });

  test('overview and formatted text are scoped to each classroom', () {
    final first = _lesson(1,
        classroom: ' A101 ',
        beginTime: DateTime(2026, 10, 27, 8, 5),
        section: '第1-2节');
    final catalog = RecordingEpisodeCatalog(lessons: [
      first,
      _lesson(2, beginTime: DateTime(2026, 11, 3), section: '第3节'),
      _lesson(3,
          classroom: 'B202',
          beginTime: DateTime(2026, 10, 29),
          section: '第7-8节'),
      _lesson(4, beginTime: DateTime(2026, 10, 31), section: '第5节'),
    ], teachingClassId: 42);

    final firstRoom = catalog.classroom('A101').overviewDays.single;
    final secondRoom = catalog.classroom('B202').overviewDays.single;
    expect(firstRoom.weekday, DateTime.tuesday);
    expect(firstRoom.sections, {1, 2, 3});
    expect(secondRoom.weekday, DateTime.thursday);
    expect(secondRoom.sections, {7, 8});
    final metadata = catalog.metadataFor(first)!;
    expect(metadata.heading, '周二 · 第1-2节');
    expect(metadata.time, '08:05-08:50');
    expect(metadata.dateAndTime, '10-27 08:05-08:50');
    expect(metadata.details, 'A101 · 10-27 08:05-08:50');
    expect(metadata.fullscreenHeading, '周二 · 第1-2节 (08:05-08:50)');
    expect(RecordingEpisodeMetadata(first), same(metadata),
        reason: 'fullscreen controls reuse the prepared immutable text too');
  });

  test('repeated UI reads reuse a revision without traversing lesson source',
      () {
    final source = _ReadCountingLessons([
      for (var index = 0; index < 240; index++)
        _lesson(index + 1,
            beginTime: DateTime(2026, 9, 1).add(Duration(days: index))),
    ]);
    final cache = RecordingEpisodeCatalogCache();
    final catalog = cache.resolve(lessons: source, teachingClassId: 42);
    final readsAfterPreparation = source.reads;
    expect(readsAfterPreparation, greaterThanOrEqualTo(240));
    final room = catalog.classroom('A101');
    final newest = room.newestFirst;
    final oldest = room.oldestFirst;
    final months = room.newestMonths;
    final numbers = room.episodeNumbers;
    final days = room.overviewDays;

    for (var frame = 0; frame < 120; frame++) {
      final snapshot = cache.resolve(lessons: source, teachingClassId: 42);
      expect(snapshot, same(catalog));
      final selection = snapshot.classroom(
          snapshot.activeClassroom(current: newest.first, selected: 'A101'));
      expect(selection, same(room));
      expect(selection.newestFirst, same(newest));
      expect(selection.oldestFirst, same(oldest));
      expect(selection.newestMonths, same(months));
      expect(selection.episodeNumbers, same(numbers));
      expect(selection.overviewDays, same(days));
      expect(snapshot.metadataFor(newest.first),
          same(catalog.metadataFor(newest.first)));
    }
    expect(source.reads, readsAfterPreparation,
        reason: 'scroll, playback and tab updates must not redo catalog work');

    final replacement = cache
        .resolve(lessons: [_lesson(1, classroom: 'B202')], teachingClassId: 42);
    expect(replacement, isNot(same(catalog)));
    expect(replacement.classrooms, ['B202']);
    final otherClass = cache.resolve(lessons: source, teachingClassId: 99);
    expect(otherClass.lessons, isEmpty);
    expect(source.reads, greaterThan(readsAfterPreparation));
  });

  test('published collections cannot be changed by rendering widgets', () {
    final catalog = RecordingEpisodeCatalog(lessons: [
      _lesson(1, beginTime: DateTime(2026, 10, 27)),
    ], teachingClassId: 42);
    final room = catalog.classroom('A101');
    expect(() => catalog.lessons.clear(), throwsUnsupportedError);
    expect(() => catalog.classrooms.clear(), throwsUnsupportedError);
    expect(() => room.newestFirst.clear(), throwsUnsupportedError);
    expect(() => room.oldestFirst.clear(), throwsUnsupportedError);
    expect(() => room.episodeNumbers.clear(), throwsUnsupportedError);
    expect(() => room.overviewDays.clear(), throwsUnsupportedError);
    expect(() => room.overviewDays.single.sections.clear(),
        throwsUnsupportedError);
    expect(() => room.newestMonths.clear(), throwsUnsupportedError);
    expect(
        () => room.oldestMonths.single.lessons.clear(), throwsUnsupportedError);
    expect(() => room.newestMonths.single.indexByLessonId.clear(),
        throwsUnsupportedError);
  });
}
