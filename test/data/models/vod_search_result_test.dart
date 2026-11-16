import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';

void main() {
  test('search result cleans highlighted course, teachers and lesson metadata',
      () {
    final result = VodSearchResult.fromJson({
      'id': 214134,
      'teclId': 30341,
      'acteId': 7,
      'subjName': '<em>面向对象</em>程序设计 &amp; 实践',
      'teclName': '教学班&nbsp;A',
      'subjCode': 'CS&amp;101',
      'courseNo': 'CS&#45;202',
      'teclCode': 'not-the-subject-code',
      'teacNames': ['<em>李梦甜</em>', ' 李梦甜 ', '杨&#x5029;&#x5029;', ''],
      'teclTeacNames': ['其他教师'],
      'courBeginTime': '2026-10-26 10:55:00',
      'courEndTime': '2026-10-26 11:40:00',
      'weekNumber': 7,
      'week': 1,
      'letiNumber': 4,
      'clroName': 'DJ&#50;03',
      'hasPrivilege': false,
      'courseStatus': 2,
    });

    expect(result.course.teachingClassId, 30341);
    expect(result.course.termId, 7);
    expect(result.course.name, '面向对象程序设计 & 实践');
    expect(result.course.teachingClassName, '教学班 A');
    expect(result.course.code, 'CS&101');
    expect(result.courseNumber, 'CS-202');
    expect(result.course.teacherNames, ['李梦甜', '杨倩倩', '其他教师']);
    expect(result.course.lessonCount, 0);
    expect(result.lesson.id, 214134);
    expect(result.lesson.teachingClassId, result.course.teachingClassId);
    expect(result.lesson.name, result.course.name);
    expect(result.lesson.beginTime, DateTime(2026, 10, 26, 10, 55));
    expect(result.lesson.endTime, DateTime(2026, 10, 26, 11, 40));
    expect(result.lesson.weekNumber, 7);
    expect(result.lesson.sectionLabel, '第4节');
    expect(result.lesson.classroom, 'DJ203');
    expect(
        () => result.course.teacherNames.add('新增教师'), throwsUnsupportedError);
  });

  test('search metadata alone does not claim recording availability', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 2,
      'hasPrivilege': false,
    });

    expect(result.lesson.isPlayable, isFalse);
    expect(result.lesson.isListed, isFalse);
    expect(result.lesson.isGenerating, isFalse);
    expect(result.lesson.isLive, isFalse);
    expect(result.lesson.watchPercent, isNull);
    expect(result.lesson.beginTime, isNull);
    expect(result.lesson.weekNumber, 0);
    expect(result.lesson.sectionLabel, isEmpty);
  });

  test('missing highlighted subject and teacher names use class metadata', () {
    final result = VodSearchResult.fromJson({
      'id': '123',
      'teclId': '42',
      'acteId': '7',
      'subjName': '<em></em> ',
      'teclName': '<em>高等数学</em>B(1)',
      'teacNames': ['', null, 123],
      'teclTeacNames': [' 杨倩倩 ', '杨倩倩'],
      'letiNumber': 0,
    });

    expect(result.course.name, '高等数学B(1)');
    expect(result.course.teacherNames, ['杨倩倩']);
    expect(result.lesson.id, 123);
    expect(result.lesson.sectionLabel, isEmpty);
  });

  test('weekday is not substituted for teaching week', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'week': 3,
    });
    expect(result.lesson.weekNumber, 0);
  });

  for (final status in [0, '0']) {
    test('current live status $status preserves a live playback candidate', () {
      final result = VodSearchResult.fromJson({
        'id': 123,
        'teclId': 42,
        'acteId': 7,
        'subjName': '<em>程序</em>设计',
        'teclName': '教学班&nbsp;A',
        'teacNames': ['<em>教师甲</em>'],
        'teclTeacNames': ['教师乙'],
        'subjCode': 'CS&amp;101',
        'clroName': 'DJ&#50;03',
        'courseStatus': status,
        'hasPrivilege': false,
        'courBeginTime': '2099-11-02 13:00:00',
        'courEndTime': '2099-11-02 13:45:00',
        'weekNumber': 8,
      });

      expect(result.lesson.isLive, isTrue);
      expect(result.lesson.isLiveAvailable, isTrue);
      expect(result.lesson.isListed, isFalse);
      expect(result.lesson.isGenerating, isFalse);
      expect(result.lesson.name, '程序设计');
      expect(result.lesson.classroom, 'DJ203');
      expect(result.lesson.weekNumber, 8);
      expect(result.lesson.liveStartTime, isNull);
      expect(result.lesson.liveEndTime, isNull);
      expect(result.lesson.catalogCourse?.teacherNames, ['教师甲', '教师乙']);
      expect(result.lesson.catalogCourse?.teachingClassName, '教学班 A');
      expect(result.lesson.catalogCourse?.code, 'CS&101');
    });
  }

  test('live search uses the selected term when week metadata is absent', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 0,
      'courBeginTime': '2026-11-02 13:00:00',
    },
        term: VodTerm(
          id: 7,
          name: '秋季学期',
          academicYear: '2026-2027',
          termNumber: 1,
          startDate: DateTime(2026, 9, 14),
        ));
    expect(result.lesson.weekNumber, 8);
  });

  test('upcoming model cannot request recording or live playback', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 1,
      'courBeginTime': '2099-11-02 13:00:00',
      'courEndTime': '2099-11-02 13:45:00',
    });
    expect(result.lesson.isLive, isTrue);
    expect(result.lesson.isPlayable, isFalse);
    expect(result.lesson.canPlay, isFalse);
  });

  for (final disabled in [
    {'liveEnable': 0},
    {'courLiveOpen': 0},
    {'livevodEnable': 0},
    {'liveEndTime': '2020-01-01 13:45:00'},
  ]) {
    test('current-live search still respects unavailable state $disabled', () {
      final result = VodSearchResult.fromJson({
        'id': 123,
        'teclId': 42,
        'acteId': 7,
        'subjName': '程序设计',
        'courseStatus': 0,
        ...disabled,
      });
      expect(result.lesson.isLive, isTrue);
      expect(result.lesson.isLiveAvailable, isFalse);
    });
  }

  test('live window is independent from the scheduled lesson end', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 0,
      'courEndTime': '2099-11-02 13:45:00',
      'liveStartTime': '2099-11-02 12:55:00',
      'liveEndTime': '2099-11-02 13:50:00',
    });
    expect(result.lesson.liveStartTime, DateTime(2099, 11, 2, 12, 55));
    expect(result.lesson.liveEndTime, DateTime(2099, 11, 2, 13, 50));
  });

  test('current live without a live cutoff survives the scheduled lesson end',
      () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 0,
      'courBeginTime': '2020-01-01 13:00:00',
      'courEndTime': '2020-01-01 13:45:00',
    });
    expect(result.lesson.endTime, DateTime(2020, 1, 1, 13, 45));
    expect(result.lesson.liveEndTime, isNull);
    expect(result.lesson.isLiveAvailable, isTrue);
  });

  test('explicit recording generation state is retained without becoming live',
      () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 2,
      'vodEnable': 1,
      'vodDeleteStatus': 0,
      'vodStatus': 3,
      'vodDisplayStatus': 1,
    });
    expect(result.lesson.isLive, isFalse);
    expect(result.lesson.isGenerating, isTrue);
    expect(result.lesson.isListed, isTrue);
    expect(result.lesson.isPlayable, isFalse);
  });
}
