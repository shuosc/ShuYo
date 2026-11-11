import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';

const _generatedLessonJson = <String, dynamic>{
  'id': 42,
  'teclId': 10,
  'subjName': '程序设计',
  'vodStatus': 5,
  'vodEnable': 1,
  'vodDeleteStatus': 0,
};

void main() {
  final liveTerm = VodTerm.fromJson({
    'id': 7,
    'acyeCode': '2026-2027',
    'acteTerm': 1,
    // The actual term begins at midnight on September 14 in Shanghai.
    'acteBeginDate': 1789315200000,
  });
  const liveJson = <String, dynamic>{
    'id': 84,
    'teclId': 10,
    'acteId': 7,
    'liveType': 0,
    'courBeginTime': '2026-11-02 10:55:00',
    'week': null,
    'weekNo': null,
    'weekNumber': null,
  };

  test('live lessons recover absent teaching weeks from the selected term', () {
    final lesson = VodLesson.fromLiveJson(liveJson, term: liveTerm);
    expect(lesson.weekNumber, 8);
    expect(lesson.beginTime, DateTime(2026, 11, 2, 10, 55));
    expect(lesson.isLive, isTrue);
  });

  test('live teaching weeks honor school dates and Monday boundaries', () {
    for (final entry in <String, int>{
      '2026-11-01T15:59:59Z': 7,
      '2026-11-01T16:00:00Z': 8,
      '2026-11-02T00:00:00+08:00': 8,
      '2026-11-08 23:59:59': 8,
      '2026-11-09 00:00:00': 9,
    }.entries) {
      final lesson = VodLesson.fromLiveJson(
          {...liveJson, 'courBeginTime': entry.key},
          term: liveTerm);
      expect(lesson.weekNumber, entry.value, reason: entry.key);
    }
  });

  test('valid server teaching weeks take precedence over date fallback', () {
    for (final metadata in [
      {'weekNo': 6, 'weekNumber': 7},
      {'weekNo': null, 'weekNumber': '6'},
      {'weekNo': 0, 'weekNumber': 6},
    ]) {
      final lesson =
          VodLesson.fromLiveJson({...liveJson, ...metadata}, term: liveTerm);
      expect(lesson.weekNumber, 6);
    }
  });

  test('weekday metadata is never treated as a live teaching week', () {
    final lesson =
        VodLesson.fromLiveJson({...liveJson, 'week': 1}, term: liveTerm);
    expect(lesson.weekNumber, 8);
    expect(VodLesson.fromLiveJson({...liveJson, 'week': 1}).weekNumber, 0);
  });

  test('live teaching week fallback requires an in-term lesson date', () {
    for (final begin in [null, '2026-09-13 23:59:59', '2027-01-04 00:00:00']) {
      final lesson = VodLesson.fromLiveJson(
          {...liveJson, 'courBeginTime': begin},
          term: liveTerm);
      expect(lesson.weekNumber, 0, reason: '$begin');
    }
    expect(VodLesson.fromLiveJson(liveJson).weekNumber, 0);
  });

  final permissionCases = <String, Map<String, dynamic>>{
    'disabled click metadata': {'vodClickEnable': 0},
    'missing click metadata': {},
    'enabled click metadata': {'vodClickEnable': 1},
    'null click metadata': {'vodClickEnable': null},
  };
  for (final permissionCase in permissionCases.entries) {
    test('generated listed recording plays with ${permissionCase.key}', () {
      final lesson = VodLesson.fromJson({
        ..._generatedLessonJson,
        ...permissionCase.value,
      });

      expect(lesson.isPlayable, isTrue);
      expect(lesson.canPlay, isTrue);
      expect(lesson.isListed, isTrue);
      expect(lesson.isGenerating, isFalse);
      expect(lesson.isLive, isFalse);
      expect(lesson.statusLabel, '录播回放');
    });
  }

  final unavailableCases = <String, Map<String, dynamic>>{
    'unfinished generation': {'vodStatus': 4},
    'missing generation status': {'vodStatus': null},
    'disabled recording': {'vodEnable': 0},
    'missing enabled flag': {'vodEnable': null},
    'deleted recording': {'vodDeleteStatus': 1},
    'missing deletion status': {'vodDeleteStatus': null},
  };
  for (final unavailableCase in unavailableCases.entries) {
    test('${unavailableCase.key} does not prevent a playback lookup', () {
      final lesson = VodLesson.fromJson({
        ..._generatedLessonJson,
        'vodClickEnable': 1,
        ...unavailableCase.value,
      });

      expect(lesson.isPlayable, isFalse);
      expect(lesson.canPlay, isTrue);
      expect(lesson.isGenerating, isFalse);
      expect(lesson.statusLabel, '查看录播');
    });
  }

  test('pending recordings retain generating status while allowing lookup', () {
    for (final generatingFlags in [
      {'vodDisplayStatus': 1},
      {'vodStatusShow': 4},
    ]) {
      final lesson = VodLesson.fromJson({
        ..._generatedLessonJson,
        'vodStatus': 4,
        'vodClickEnable': 0,
        ...generatingFlags,
      });

      expect(lesson.isListed, isTrue);
      expect(lesson.isGenerating, isTrue);
      expect(lesson.isPlayable, isFalse);
      expect(lesson.canPlay, isTrue);
      expect(lesson.statusLabel, '回放生成中');
    }
  });

  test('recording playback lookup requires valid lesson and class IDs', () {
    for (final ids in [
      {'id': 0, 'teclId': 10},
      {'id': -1, 'teclId': 10},
      {'id': 42, 'teclId': 0},
      {'id': 42, 'teclId': -1},
    ]) {
      final lesson = VodLesson.fromJson({..._generatedLessonJson, ...ids});
      expect(lesson.canPlay, isFalse);
    }
    const invalid =
        VodLesson(id: 0, teachingClassId: 10, name: '课程', isPlayable: false);
    expect(invalid.statusLabel, '暂不可看');
  });

  test(
      'completed recordings retain playback status over stale generating flags',
      () {
    final lesson = VodLesson.fromJson({
      ..._generatedLessonJson,
      'vodClickEnable': 0,
      'vodDisplayStatus': 1,
    });

    expect(lesson.isGenerating, isTrue);
    expect(lesson.isPlayable, isTrue);
    expect(lesson.canPlay, isTrue);
    expect(lesson.statusLabel, '录播回放');
  });

  test('live classification and opening flags retain their playback behavior',
      () {
    const liveJson = <String, dynamic>{
      'id': 84,
      'teclId': 10,
      'subjName': '直播课程',
      'liveType': 0,
      'liveEnable': 1,
      'courLiveOpen': 1,
      'livevodEnable': 1,
    };
    final available = VodLesson.fromLiveJson(liveJson);
    expect(available.isLive, isTrue);
    expect(available.isPlayable, isTrue);
    expect(available.canPlay, isTrue);
    expect(available.statusLabel, '正在直播');

    for (final flags in [
      {'liveType': 1},
      {'liveEnable': 0},
      {'courLiveOpen': 0},
      {'livevodEnable': 0},
    ]) {
      final unavailable = VodLesson.fromLiveJson({...liveJson, ...flags});
      expect(unavailable.isLive, isTrue);
      expect(unavailable.isPlayable, isFalse);
      expect(unavailable.canPlay, isFalse);
      expect(unavailable.statusLabel, '直播已结束');
    }

    final ended = VodLesson.fromLiveJson({
      ...liveJson,
      'liveEndTime': DateTime(2000, 1, 1).toIso8601String(),
    });
    expect(ended.isPlayable, isTrue);
    expect(ended.canPlay, isFalse);
    expect(ended.statusLabel, '直播已结束');
  });
}
