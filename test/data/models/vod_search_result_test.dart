import 'package:flutter_test/flutter_test.dart';
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

  test('search candidates may request details without invented VOD flags', () {
    final result = VodSearchResult.fromJson({
      'id': 123,
      'teclId': 42,
      'acteId': 7,
      'subjName': '程序设计',
      'courseStatus': 2,
      'hasPrivilege': false,
    });

    expect(result.lesson.isPlayable, isTrue);
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
}
