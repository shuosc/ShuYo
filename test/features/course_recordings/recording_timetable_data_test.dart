import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_data.dart';

void main() {
  const course = VodCourse(teachingClassId: 10, termId: 1, name: '课程');
  final today = DateTime(2026, 10, 30, 12);

  VodLesson lesson(
    int id,
    DateTime? date, {
    int teachingClassId = 10,
    int week = 0,
    bool playable = true,
    bool generating = false,
    bool listed = false,
    bool live = false,
  }) =>
      VodLesson(
        id: id,
        teachingClassId: teachingClassId,
        name: '课次 $id',
        beginTime: date,
        weekNumber: week,
        isPlayable: playable,
        isGenerating: generating,
        isListed: listed,
        isLive: live,
      );

  RecordingTimetableData dataFor(
    List<VodLesson> lessons, {
    VodTerm? term,
    DateTime? now,
  }) =>
      RecordingTimetableData(
        term: term,
        courses: const [course],
        lessonsByCourse: {10: lessons},
        now: now ?? today,
      );

  test('valid week numbers take precedence over the term start date', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 10, 26, 8), week: 8),
      lesson(2, DateTime(2026, 11, 1, 8), week: 8),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 1),
          endDate: DateTime(2027, 1, 10),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
    expect(data.maxWeek, 18);
    expect(data.initialWeek, 8);
    expect(data.initialWeekday, DateTime.friday);
    expect(data.weekFor(DateTime(2026, 11, 1)), 8);
    expect(data.weekFor(DateTime(2026, 11, 2)), 9);
  });

  test('the most consistent week anchor wins over an outlying week number', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 10, 26), week: 8),
      lesson(2, DateTime(2026, 11, 2), week: 9),
      lesson(3, DateTime(2026, 11, 3), week: 2),
    ]);
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
    expect(data.maxWeek, 9);
  });

  test('tied week anchors use proximity to the term start', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 10, 26), week: 8),
      lesson(2, DateTime(2026, 11, 2), week: 2),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 8),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
  });

  test('missing and invalid week numbers fall back to the term start', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 10, 26), week: -1),
      lesson(2, DateTime(2026, 10, 27), week: 999),
      lesson(3, DateTime(2026, 10, 28)),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 9),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
    expect(data.maxWeek, 8);
  });

  test('missing term dates use the earliest actual lesson, across years', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 12, 31, 10)),
      lesson(2, DateTime(2027, 1, 11, 9)),
    ], now: DateTime(2027, 1, 4));
    expect(data.firstWeekMonday, DateTime(2026, 12, 28));
    expect(data.maxWeek, 3);
    expect(data.initialWeek, 2);
    expect(data.dateFor(1, DateTime.sunday), DateTime(2027, 1, 3));
    expect(data.dateFor(2, DateTime.monday), DateTime(2027, 1, 4));
    expect(data.weekFor(DateTime(2026, 12, 27)), 0);
    expect(data.weekFor(DateTime(2026, 12, 20)), -1);
  });

  test('empty data falls back to the current school week without lessons', () {
    final data = dataFor([], now: DateTime.utc(2026, 11, 1, 17));
    expect(data.firstWeekMonday, DateTime(2026, 11, 2));
    expect(data.maxWeek, 1);
    expect(data.initialWeek, 1);
    expect(data.initialWeekday, DateTime.monday);
    expect(data.hasDatedLessons, isFalse);
    expect(data.entriesFor(data.dateFor(1, DateTime.monday)), isEmpty);
  });

  test('default current date agrees with the current school day', () {
    final before = DateTime.now().toUtc().add(const Duration(hours: 8));
    final data = RecordingTimetableData(
      term: null,
      courses: const [],
      lessonsByCourse: const {},
    );
    final after = DateTime.now().toUtc().add(const Duration(hours: 8));
    final selectedDate = data.dateFor(data.initialWeek, data.initialWeekday);
    expect(
        selectedDate,
        anyOf(
          DateTime(before.year, before.month, before.day),
          DateTime(after.year, after.month, after.day),
        ));
  });

  test('term dates provide selectable weeks without inventing lessons', () {
    final data = dataFor([],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 9),
          endDate: DateTime(2027, 1, 10),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
    expect(data.maxWeek, 18);
    expect(data.initialWeek, 8);
    expect(data.hasDatedLessons, isFalse);
    expect(data.entriesFor(today), isEmpty);
  });

  test('end-only and reversed term dates do not create an invalid range', () {
    final endOnly = dataFor([],
        term: VodTerm(
          id: 1,
          name: '学期',
          endDate: DateTime(2026, 10, 4),
        ));
    expect(endOnly.firstWeekMonday, DateTime(2026, 9, 28));
    expect(endOnly.maxWeek, 1);
    final reversed = dataFor([],
        term: VodTerm(
          id: 1,
          name: '学期',
          startDate: DateTime(2026, 10, 26),
          endDate: DateTime(2026, 9, 7),
        ));
    expect(reversed.firstWeekMonday, DateTime(2026, 10, 26));
    expect(reversed.maxWeek, 1);
  });

  test('week range includes lessons beyond the advertised end of term', () {
    final data = dataFor([
      lesson(1, DateTime(2027, 1, 20, 10)),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 7),
          endDate: DateTime(2027, 1, 10),
        ));
    expect(data.maxWeek, 20);
    expect(data.entriesFor(data.dateFor(20, DateTime.wednesday)), hasLength(1));
  });

  test('actual lessons before the term start remain in a reachable week', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 8, 30, 10)),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 9),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 8, 24));
    expect(data.maxWeek, 3);
    expect(data.initialWeek, 1);
    expect(data.initialWeekday, DateTime.sunday);
    expect(
        data.entriesFor(data.dateFor(1, DateTime.sunday)).single.lesson.id, 1);
  });

  test('inconsistent week metadata cannot hide an earlier dated lesson', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 9, 1, 8)),
      lesson(2, DateTime(2026, 10, 26, 8), week: 1),
    ]);
    expect(data.firstWeekMonday, DateTime(2026, 8, 31));
    expect(data.maxWeek, 9);
    expect(data.weekFor(DateTime(2026, 9, 1)), 1);
    expect(
        data.entriesFor(data.dateFor(1, DateTime.tuesday)).single.lesson.id, 1);
  });

  test('UTC and offset timestamps use the school date and keep weekends', () {
    final data = dataFor([
      lesson(1, DateTime.utc(2026, 10, 30, 23)),
      lesson(2, DateTime.parse('2026-11-01T08:00:00+08:00')),
      lesson(3, DateTime(2026, 11, 1, 23)),
    ]);
    expect(data.entriesFor(DateTime(2026, 10, 30)), isEmpty);
    expect(data.entriesFor(DateTime(2026, 10, 31)).single.lesson.id, 1);
    expect(
        data.entriesFor(DateTime(2026, 11, 1)).map((entry) => entry.lesson.id),
        [2, 3]);
    expect(data.entriesFor(DateTime.utc(2026, 10, 31, 18)), hasLength(2));
    expect(data.dateFor(1, DateTime.saturday), DateTime(2026, 10, 31));
    expect(data.dateFor(1, DateTime.sunday), DateTime(2026, 11, 1));
  });

  test('term UTC dates use the same school wall dates as lessons', () {
    final data = dataFor([],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime.utc(2026, 9, 6, 16),
          endDate: DateTime.utc(2026, 9, 20, 16),
        ));
    expect(data.firstWeekMonday, DateTime(2026, 9, 7));
    expect(data.maxWeek, 3);
  });

  test('only available catalog courses and their own lesson IDs are used', () {
    final data = RecordingTimetableData(
      term: const VodTerm(id: 1, name: '学期'),
      courses: const [
        course,
        course,
        VodCourse(teachingClassId: 20, termId: 2, name: '其他学期'),
        VodCourse(teachingClassId: 0, termId: 1, name: '无效课程'),
      ],
      lessonsByCourse: {
        10: [
          lesson(1, today),
          lesson(2, today, teachingClassId: 20),
          lesson(0, today),
          lesson(-1, today),
        ],
        20: [lesson(3, today, teachingClassId: 20)],
        30: [lesson(4, today, teachingClassId: 30)],
      },
      now: today,
    );
    final entry = data.entriesFor(today).single;
    expect(entry.course, same(course));
    expect(entry.lesson.id, 1);
    expect(entry.number, 1);
  });

  test('same lesson ID in different courses remains isolated', () {
    final data = RecordingTimetableData(
      term: null,
      courses: const [
        course,
        VodCourse(teachingClassId: 20, termId: 1, name: '第二课程'),
      ],
      lessonsByCourse: {
        10: [lesson(1, today)],
        20: [lesson(1, today, teachingClassId: 20)],
      },
      now: today,
    );
    expect(data.entriesFor(today).map((entry) => entry.course.teachingClassId),
        [10, 20]);
    expect(data.entriesFor(today).map((entry) => entry.number), [1, 1]);
  });

  test('generating and listed nonplayable lessons remain in the timetable', () {
    final data = dataFor([
      lesson(1, today),
      lesson(2, today, playable: false, generating: true),
      lesson(3, today, playable: false, listed: true),
      lesson(4, today, playable: false, live: true),
      lesson(5, today, playable: false),
    ]);
    final entries = data.entriesFor(today);
    expect(entries.map((entry) => entry.lesson.id), [1, 2, 3, 4]);
    expect(entries.map((entry) => entry.number), [1, 2, 3, 4]);
    expect(entries[1].lesson.canPlay, isFalse);
    expect(entries[2].lesson.canPlay, isFalse);
  });

  test('undated lessons do not invent a date or an anchor but retain numbering',
      () {
    final data = dataFor([
      lesson(1, null, week: 8),
      lesson(2, today),
    ]);
    expect(data.firstWeekMonday, DateTime(2026, 10, 26));
    expect(data.entriesFor(today).single.number, 2);
    final undated = dataFor([lesson(1, null, week: 8)]);
    expect(undated.hasDatedLessons, isFalse);
    expect(undated.firstWeekMonday, DateTime(2026, 10, 26));
    expect(undated.maxWeek, 1);
  });

  test('liveLesson supplements an unloaded catalog without duplicates', () {
    final live = lesson(2, today, live: true);
    final liveCourse = course.withLiveLesson(live);
    final incomplete = RecordingTimetableData(
      term: null,
      courses: [liveCourse],
      lessonsByCourse: const {},
      now: today,
    );
    expect(incomplete.entriesFor(today).single.lesson, same(live));
    final recording = lesson(2, today);
    final complete = RecordingTimetableData(
      term: null,
      courses: [liveCourse],
      lessonsByCourse: {
        10: [recording, recording],
      },
      now: today,
    );
    expect(complete.entriesFor(today).single.lesson, same(recording));
    expect(complete.entriesFor(today).single.number, 1);
  });

  test('a liveLesson from a different teaching class is not supplemented', () {
    final data = RecordingTimetableData(
      term: null,
      courses: [
        course
            .withLiveLesson(lesson(1, today, teachingClassId: 20, live: true)),
      ],
      lessonsByCourse: const {},
      now: today,
    );
    expect(data.hasDatedLessons, isFalse);
  });

  test('episodes number chronologically while each day sorts by school time',
      () {
    final data = dataFor([
      lesson(40, DateTime(2026, 10, 29, 9)),
      lesson(20, DateTime.utc(2026, 10, 30, 0)),
      lesson(10, DateTime(2026, 10, 30, 9)),
      lesson(30, DateTime(2026, 10, 30, 9)),
      lesson(50, DateTime(2026, 10, 30, 10)),
      lesson(60, DateTime(2026, 11, 2, 8)),
    ]);
    final entries = data.entriesFor(today);
    expect(entries.map((entry) => entry.lesson.id), [20, 10, 30, 50]);
    expect(entries.map((entry) => entry.number), [2, 3, 4, 5]);
    expect(data.entriesFor(DateTime(2026, 11, 2)).single.number, 6);
    expect(data.entriesFor(DateTime(2026, 10, 29)).single.number, 1);
  });

  test(
      'historical terms select the last content week instead of empty end weeks',
      () {
    final data = dataFor([
      lesson(1, DateTime(2026, 9, 8, 8)),
      lesson(2, DateTime(2026, 9, 25, 10)),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 7),
          endDate: DateTime(2027, 1, 10),
        ),
        now: DateTime(2027, 2, 1));
    expect(data.maxWeek, 18);
    expect(data.initialWeek, 3);
    expect(data.initialWeekday, DateTime.friday);
    expect(data.entriesFor(data.dateFor(data.initialWeek, data.initialWeekday)),
        hasLength(1));
  });

  test('future terms select the first week and weekday with content', () {
    final data = dataFor([
      lesson(1, DateTime(2026, 9, 25, 10)),
      lesson(2, DateTime(2026, 10, 6, 10)),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          startDate: DateTime(2026, 9, 7),
          endDate: DateTime(2027, 1, 10),
        ),
        now: DateTime(2026, 8, 1));
    expect(data.initialWeek, 3);
    expect(data.initialWeekday, DateTime.friday);
  });

  test('an in-range current week stays selected even when it has no recordings',
      () {
    final data = dataFor([
      lesson(1, DateTime(2026, 10, 1)),
      lesson(2, DateTime(2026, 11, 9)),
    ]);
    expect(data.initialWeek, 5);
    expect(data.initialWeekday, DateTime.friday);
    expect(data.entriesFor(today), isEmpty);
  });

  for (final scheme in [
    (
      year: '2024-2025',
      start: DateTime(2024, 9, 2),
      weeks: 10,
      terms: [1, 2, 3]
    ),
    (year: '2025-2026', start: DateTime(2025, 9, 1), weeks: 16, terms: [1, 2]),
  ]) {
    for (final termNumber in scheme.terms) {
      test('${scheme.year} term $termNumber fixes its selectable week range',
          () {
        final data = dataFor([],
            term: VodTerm(
              id: 1,
              name: '学期',
              academicYear: scheme.year,
              termNumber: termNumber,
              startDate: scheme.start,
              endDate: scheme.start.add(const Duration(days: 25 * 7 - 1)),
            ),
            now: scheme.start.add(const Duration(days: 30 * 7)));

        expect(data.firstWeekMonday, scheme.start);
        expect(data.maxWeek, scheme.weeks);
        expect(data.initialWeek, scheme.weeks);
        expect(data.dateFor(scheme.weeks, DateTime.sunday),
            scheme.start.add(Duration(days: scheme.weeks * 7 - 1)));
        expect(data.hasDatedLessons, isFalse);
        expect(data.entriesFor(data.dateFor(scheme.weeks, DateTime.sunday)),
            isEmpty);
        expect(() => data.dateFor(0, DateTime.monday), throwsRangeError);
        expect(() => data.dateFor(scheme.weeks + 1, DateTime.monday),
            throwsRangeError);
      });
    }
  }

  test('known teaching weeks are not shortened by an early advertised end', () {
    final start = DateTime(2025, 9, 1);
    final data = dataFor([],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          academicYear: '2025-2026',
          termNumber: 1,
          startDate: start,
          endDate: start.add(const Duration(days: 6)),
        ),
        now: DateTime(2025, 10, 20));

    expect(data.maxWeek, 16);
    expect(data.initialWeek, 8);
    expect(data.entriesFor(data.dateFor(16, DateTime.sunday)), isEmpty);
  });

  test('known schemes retain bounded navigation when date metadata is missing',
      () {
    for (final scheme in [
      (year: '2024-2025', weeks: 10),
      (year: '2025-2026', weeks: 16),
    ]) {
      final term = VodTerm(
        id: 1,
        name: '秋季学期',
        academicYear: scheme.year,
        termNumber: 1,
      );
      final current = DateTime(2025, 10, 21);
      final empty = dataFor([], term: term, now: current);
      expect(empty.firstWeekMonday, DateTime(2025, 10, 20));
      expect(empty.maxWeek, scheme.weeks);
      expect(empty.initialWeek, 1);

      final anchored = dataFor([
        lesson(1, DateTime(2025, 10, 20), week: 8),
      ], term: term, now: current);
      expect(anchored.firstWeekMonday, DateTime(2025, 9, 1));
      expect(anchored.maxWeek, scheme.weeks);
      expect(anchored.initialWeek, 8);

      final outlying = dataFor([
        lesson(1, DateTime(2025, 10, 20), week: scheme.weeks + 4),
      ], term: term, now: current);
      expect(outlying.firstWeekMonday, DateTime(2025, 10, 20));
      expect(outlying.maxWeek, scheme.weeks);
      expect(outlying.entriesFor(DateTime(2025, 10, 20)), hasLength(1));
    }
  });

  test('known ranges reject contradictory week numbers as range extensions',
      () {
    for (final scheme in [
      (year: '2024-2025', weeks: 10),
      (year: '2025-2026', weeks: 16),
    ]) {
      final data = dataFor([
        lesson(1, DateTime(2025, 10, 20), week: 8),
        lesson(2, DateTime(2025, 10, 27), week: 9),
        lesson(3, DateTime(2025, 10, 28), week: 2),
        lesson(4, DateTime(2025, 10, 29), week: scheme.weeks + 4),
      ],
          term: VodTerm(
            id: 1,
            name: '秋季学期',
            academicYear: scheme.year,
            termNumber: 1,
            startDate: DateTime(2025, 9, 1),
            endDate: DateTime(2026, 1, 18),
          ),
          now: DateTime(2025, 10, 30));

      expect(data.firstWeekMonday, DateTime(2025, 9, 1));
      expect(data.maxWeek, scheme.weeks);
      expect(data.initialWeek, 9);
      expect(data.weekFor(DateTime(2025, 10, 29)), 9);
      expect(data.entriesFor(DateTime(2025, 10, 29)).single.lesson.weekNumber,
          scheme.weeks + 4);
      expect(() => data.dateFor(scheme.weeks + 1, 1), throwsRangeError);
    }
  });

  test(
      'out-of-range real lessons stay stored without shifting known boundaries',
      () {
    final before = DateTime(2025, 8, 18);
    final inside = DateTime(2025, 9, 8);
    final after = DateTime(2026, 1, 12);
    final data = dataFor([
      lesson(1, before),
      lesson(2, inside, week: 2),
      lesson(3, after, week: 20),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          academicYear: '2025-2026',
          termNumber: 1,
          startDate: DateTime(2025, 9, 1),
          endDate: DateTime(2026, 1, 18),
        ),
        now: DateTime(2026, 2, 1));

    expect(data.firstWeekMonday, DateTime(2025, 9, 1));
    expect(data.maxWeek, 16);
    expect(data.weekFor(before), -1);
    expect(data.weekFor(after), 20);
    expect(data.entriesFor(before).single.lesson.id, 1);
    expect(data.entriesFor(inside).single.lesson.id, 2);
    expect(data.entriesFor(after).single.lesson.id, 3);
    expect(data.entriesFor(after).single.number, 3);
    expect(data.initialWeek, 2);
    expect(data.initialWeekday, DateTime.monday);
    expect(
        data
            .entriesFor(data.dateFor(data.initialWeek, data.initialWeekday))
            .single
            .lesson
            .id,
        2);
    expect(() => data.dateFor(20, DateTime.monday), throwsRangeError);
  });

  test('only out-of-range lessons cannot create additional selectable weeks',
      () {
    final outside = DateTime(2026, 1, 12);
    final data = dataFor([
      lesson(1, outside, week: 20),
    ],
        term: VodTerm(
          id: 1,
          name: '秋季学期',
          academicYear: '2025-2026',
          termNumber: 1,
          startDate: DateTime(2025, 9, 1),
          endDate: DateTime(2026, 1, 18),
        ),
        now: DateTime(2026, 2, 1));

    expect(data.firstWeekMonday, DateTime(2025, 9, 1));
    expect(data.maxWeek, 16);
    expect(data.initialWeek, 16);
    expect(data.hasDatedLessons, isTrue);
    expect(data.entriesFor(outside).single.lesson.id, 1);
    expect(data.entriesFor(data.dateFor(data.initialWeek, data.initialWeekday)),
        isEmpty);
  });

  test('summer and unknown schemes retain their inferred ranges', () {
    final start = DateTime(2025, 9, 1);
    final lastLesson = start.add(const Duration(days: 21 * 7));
    for (final scheme in [
      (year: '2024-2025', term: 4),
      (year: '2025-2026', term: 3),
      (year: '', term: 1),
      (year: '未知学年', term: 2),
      (year: '2025-2026', term: 5),
    ]) {
      final data = dataFor([lesson(1, lastLesson)],
          term: VodTerm(
            id: 1,
            name: '学期',
            academicYear: scheme.year,
            termNumber: scheme.term,
            startDate: start,
            endDate: start.add(const Duration(days: 19 * 7 - 1)),
          ),
          now: start);

      expect(data.firstWeekMonday, start);
      expect(data.maxWeek, 22);
      expect(
          data.entriesFor(data.dateFor(22, DateTime.monday)).single.lesson.id,
          1);
    }
  });

  test(
      'summer remains free to infer a short term instead of a fixed week count',
      () {
    final data = dataFor([],
        term: VodTerm(
          id: 1,
          name: '夏季学期',
          academicYear: '2025-2026',
          termNumber: 3,
          startDate: DateTime(2026, 7, 6),
          endDate: DateTime(2026, 7, 26),
        ));

    expect(data.maxWeek, 3);
    expect(() => data.dateFor(4, DateTime.monday), throwsRangeError);
  });

  test('results are immutable snapshots and dateFor validates its range', () {
    final lessons = [lesson(1, today)];
    final data = dataFor(lessons);
    lessons.clear();
    expect(data.entriesFor(today), hasLength(1));
    expect(() => data.entriesFor(today).clear(), throwsUnsupportedError);
    expect(() => data.entriesFor(DateTime(2026, 11, 1)).clear(),
        throwsUnsupportedError);
    expect(() => data.dateFor(0, 1), throwsRangeError);
    expect(() => data.dateFor(data.maxWeek + 1, 1), throwsRangeError);
    expect(() => data.dateFor(1, 0), throwsRangeError);
    expect(() => data.dateFor(1, 8), throwsRangeError);
  });
}
