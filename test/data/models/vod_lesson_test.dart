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
    test('${unavailableCase.key} still prevents playback', () {
      final lesson = VodLesson.fromJson({
        ..._generatedLessonJson,
        'vodClickEnable': 1,
        ...unavailableCase.value,
      });

      expect(lesson.isPlayable, isFalse);
      expect(lesson.canPlay, isFalse);
      expect(lesson.isGenerating, isFalse);
      expect(lesson.statusLabel, '暂不可看');
    });
  }

  test('pending recordings retain generating status without becoming playable',
      () {
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
      expect(lesson.canPlay, isFalse);
      expect(lesson.statusLabel, '回放生成中');
    }
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
