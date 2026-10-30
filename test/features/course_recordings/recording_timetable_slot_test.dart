import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_data.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_slot.dart';

void main() {
  const course = VodCourse(teachingClassId: 10, termId: 1, name: '课程');

  RecordingTimetableEntry entry(int id,
          {String section = '', DateTime? begin}) =>
      RecordingTimetableEntry(
        course: course,
        lesson: VodLesson(
          id: id,
          teachingClassId: 10,
          name: '课次 $id',
          isPlayable: true,
          sectionLabel: section,
          beginTime: begin,
        ),
        number: id,
      );

  test('each two-section pair uses its first standard section start time', () {
    final slots = recordingTimetableSlots([
      for (var section = 12; section >= 1; section--)
        entry(section, section: '第$section节'),
    ]);
    expect(slots.map((slot) => slot.key),
        ['1-2', '3-4', '5-6', '7-8', '9-10', '11-12']);
    expect(slots.map((slot) => slot.sectionLabel),
        ['1-2节', '3-4节', '5-6节', '7-8节', '9-10节', '11-12节']);
    expect(slots.map((slot) => slot.timeLabel),
        ['8:00', '10:00', '13:00', '15:00', '18:00', '20:00']);
    for (var index = 0; index < slots.length; index++) {
      final firstSection = index * 2 + 1;
      final range = AcademicScheduleRepository.sectionTimes[firstSection]!;
      expect(slots[index].timeLabel,
          '${range.$1}:${range.$2.toString().padLeft(2, '0')}');
      expect(slots[index].entries.map((item) => item.lesson.id),
          [firstSection + 1, firstSection]);
    }
  });

  test('the second section still labels its group with the pair start time',
      () {
    final slot = recordingTimetableSlots([
      entry(1, section: '第2节', begin: DateTime(2026, 10, 30, 8, 55)),
    ]).single;
    expect(slot.key, '1-2');
    expect(slot.sectionLabel, '1-2节');
    expect(slot.timeLabel, '8:00');
  });

  test('section ranges use their first section and never duplicate an episode',
      () {
    final entries = [
      entry(1, section: '第1-2节'),
      entry(2, section: '第2-4节'),
      entry(3, section: ' 第 5 至 6 节 '),
      entry(4, section: '7–8节课'),
      entry(5, section: '第9～12节'),
    ];
    final slots = recordingTimetableSlots(entries);
    expect(slots.map((slot) => slot.key), ['1-2', '5-6', '7-8', '9-10']);
    expect(slots.first.entries.map((item) => item.lesson.id), [1, 2]);
    expect(slots.expand((slot) => slot.entries), hasLength(entries.length));
  });

  test('an explicit valid section wins over a contradictory actual start', () {
    final slot = recordingTimetableSlots([
      entry(1, section: '第2节', begin: DateTime(2026, 10, 30, 20, 10)),
    ]).single;
    expect(slot.key, '1-2');
    expect(slot.timeLabel, '8:00');
  });

  test('missing section metadata infers each pair only inside its class times',
      () {
    final slots = recordingTimetableSlots([
      for (final section in AcademicScheduleRepository.sectionTimes.entries)
        entry(section.key,
            begin: DateTime(2026, 10, 30, section.value.$1, section.value.$2)),
    ]);
    expect(slots.map((slot) => slot.key),
        ['1-2', '3-4', '5-6', '7-8', '9-10', '11-12']);
    expect(slots.every((slot) => slot.entries.length == 2), isTrue);
  });

  test('class start is included and class end is excluded', () {
    final slots = recordingTimetableSlots([
      entry(1, begin: DateTime(2026, 10, 30, 8)),
      entry(2, begin: DateTime(2026, 10, 30, 8, 44, 59, 999, 999)),
      entry(3, begin: DateTime(2026, 10, 30, 8, 45)),
      entry(4, begin: DateTime(2026, 10, 30, 8, 55)),
      entry(5, begin: DateTime(2026, 10, 30, 9, 40)),
    ]);
    expect(slots.map((slot) => slot.key), ['1-2', 'time-0845', 'time-0940']);
    expect(slots.first.entries.map((item) => item.lesson.id), [1, 2, 4]);
    expect(slots[1].timeLabel, '8:45');
    expect(slots[2].timeLabel, '9:40');
  });

  test('breaks and nonstandard times remain independent other time groups', () {
    final slots = recordingTimetableSlots([
      entry(1, begin: DateTime(2026, 10, 30, 22, 5)),
      entry(2, begin: DateTime(2026, 10, 30, 12, 15)),
      entry(3, begin: DateTime(2026, 10, 30, 7, 30)),
      entry(4, begin: DateTime(2026, 10, 30, 8, 50)),
      entry(5, begin: DateTime(2026, 10, 30, 12, 15, 30)),
      entry(6, section: '第5节'),
    ]);
    expect(slots.map((slot) => slot.key),
        ['time-0730', 'time-0850', 'time-1215', '5-6', 'time-2205']);
    expect(slots.map((slot) => slot.timeLabel),
        ['7:30', '8:50', '12:15', '13:00', '22:05']);
    expect(slots[2].entries.map((item) => item.lesson.id), [2, 5]);
    expect(
        slots
            .where((slot) => slot.key.startsWith('time-'))
            .every((slot) => slot.sectionLabel == '其他时段'),
        isTrue);
    expect(slots.expand((slot) => slot.entries), hasLength(6));
  });

  test('invalid section metadata falls back to actual classroom intervals', () {
    final slots = recordingTimetableSlots([
      for (final (index, label) in [
        '第0节',
        '第13节',
        '第2-1节',
        '第1-13节',
        '第99节',
        '无效节次',
      ].indexed)
        entry(index + 1, section: label, begin: DateTime(2026, 10, 30, 10, 10)),
    ]);
    expect(slots.single.key, '3-4');
    expect(slots.single.entries, hasLength(6));
  });

  test('UTC and offset dates infer school time even across the date boundary',
      () {
    final slots = recordingTimetableSlots([
      entry(1, begin: DateTime.utc(2026, 10, 29, 23, 45)),
      entry(2, begin: DateTime.utc(2026, 10, 30, 0, 10)),
      entry(3, begin: DateTime.parse('2026-10-30T08:55:00+08:00')),
    ]);
    expect(slots.map((slot) => slot.key), ['time-0745', '1-2']);
    expect(slots.first.timeLabel, '7:45');
    expect(slots.last.timeLabel, '8:00');
    expect(slots.last.entries.map((item) => item.lesson.id), [2, 3]);
  });

  test(
      'same-group entries sort by actual school datetime without changing input',
      () {
    final entries = [
      entry(1, section: '第2节', begin: DateTime(2026, 10, 30, 8, 55)),
      entry(2, section: '第1节', begin: DateTime.utc(2026, 10, 30, 0)),
      entry(3, section: '第1节', begin: DateTime(2026, 10, 30, 8)),
      entry(4, section: '第2节', begin: DateTime(2026, 10, 29, 8, 55)),
      entry(5, section: '第1节'),
    ];
    final original = List<RecordingTimetableEntry>.of(entries);
    final slot = recordingTimetableSlots(entries).single;
    expect(slot.entries.map((item) => item.lesson.id), [4, 2, 3, 1, 5]);
    expect(entries, orderedEquals(original));
    expect(slot.entries[1], same(entries[1]));
  });

  test('unknown times stay visible after known groups and use a stable key',
      () {
    final slots = recordingTimetableSlots([
      entry(1),
      entry(2, section: '第13节'),
      entry(3, section: '第12节'),
      entry(4, begin: DateTime(2026, 10, 30, 23, 59)),
    ]);
    expect(
        slots.map((slot) => slot.key), ['11-12', 'time-2359', 'time-unknown']);
    expect(slots.last.sectionLabel, '其他时段');
    expect(slots.last.timeLabel, '待定');
    expect(slots.last.entries.map((item) => item.lesson.id), [1, 2]);
    expect(slots.first.timeLabel, '20:00');
    expect(slots.expand((slot) => slot.entries), hasLength(4));
  });

  test('returned groups and entries are immutable snapshots', () {
    final entries = [entry(1, section: '第1节')];
    final slots = recordingTimetableSlots(entries);
    entries.clear();
    expect(slots.single.entries.single.lesson.id, 1);
    expect(() => slots.clear(), throwsUnsupportedError);
    expect(() => slots.single.entries.clear(), throwsUnsupportedError);
    final empty = recordingTimetableSlots([]);
    expect(empty, isEmpty);
    expect(() => empty.clear(), throwsUnsupportedError);
  });
}
