import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_episode_navigation.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _CountingLessons extends ListBase<VodLesson> {
  _CountingLessons(this._values);

  final List<VodLesson> _values;
  int reads = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => throw UnsupportedError('immutable fixture');

  @override
  VodLesson operator [](int index) {
    reads++;
    return _values[index];
  }

  @override
  void operator []=(int index, VodLesson value) =>
      throw UnsupportedError('immutable fixture');
}

class _TimelinePlayer extends PlatformPlayer {
  _TimelinePlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(duration: const Duration(minutes: 1));
  }

  void update({Duration? position, Duration? buffer, Duration? duration}) {
    state =
        state.copyWith(position: position, buffer: buffer, duration: duration);
    if (position != null) positionController.add(position);
    if (buffer != null) bufferController.add(buffer);
    if (duration != null) durationController.add(duration);
  }
}

class _VideoState extends VideoState {}

VodLesson _lesson(int id, {String classroom = 'A101'}) => VodLesson(
      id: id,
      teachingClassId: 10,
      name: '课次 $id',
      classroom: classroom,
      isPlayable: true,
      sectionLabel: '第1节',
    );

void main() {
  test('navigation reuses both orders and numbers within a classroom', () {
    final lessons = _CountingLessons([
      _lesson(4),
      _lesson(3, classroom: 'B202'),
      _lesson(2),
      _lesson(1),
    ]);
    final room = _CountingLessons([lessons[0], lessons[2], lessons[3]]);
    final cache = RecordingEpisodeNavigationCache();
    final navigation = cache.resolve(
        lessons: lessons,
        episodeLessons: room,
        selectedLessonId: 2,
        newestFirst: true);
    expect(navigation.older!.id, 1);
    expect(navigation.newer!.id, 4);
    expect(navigation.panelLessons.map((lesson) => lesson.id), [4, 2, 1]);
    expect(navigation.episodeNumbers, {4: 3, 2: 2, 1: 1});
    expect(navigation.panelIndexByLessonId[2], 1);
    final lessonReads = lessons.reads;
    final roomReads = room.reads;
    for (var tick = 0; tick < 120; tick++) {
      final current = cache.resolve(
          lessons: lessons,
          episodeLessons: room,
          selectedLessonId: 2,
          newestFirst: true);
      expect(current, same(navigation));
      expect(current.newer!.id, 4);
      expect(current.older!.id, 1);
    }
    expect(lessons.reads, lessonReads);
    expect(room.reads, roomReads);

    final reversed = cache.resolve(
        lessons: lessons,
        episodeLessons: room,
        selectedLessonId: 2,
        newestFirst: false);
    expect(reversed.panelLessons.map((lesson) => lesson.id), [1, 2, 4]);
    expect(reversed.episodeNumbers, navigation.episodeNumbers);
    expect(reversed.newer!.id, 4);
    expect(reversed.older!.id, 1);

    final changed = cache.resolve(
        lessons: lessons,
        episodeLessons: room,
        selectedLessonId: 4,
        newestFirst: false);
    expect(changed.newer, isNull);
    expect(changed.older!.id, 2);
    expect(changed.panelIndexByLessonId[4], 2);
  });

  test('navigation skips unavailable lessons and does not invent a selection',
      () {
    final cache = RecordingEpisodeNavigationCache();
    final lessons = [
      _lesson(4),
      const VodLesson(
          id: 3,
          teachingClassId: 10,
          name: '结束直播',
          isPlayable: false,
          isLive: true),
      _lesson(2),
      _lesson(1),
    ];
    final selected = cache.resolve(
        lessons: lessons,
        episodeLessons: null,
        selectedLessonId: 2,
        newestFirst: true);
    expect(selected.newer!.id, 4);
    expect(selected.older!.id, 1);
    final unknown = cache.resolve(
        lessons: lessons,
        episodeLessons: null,
        selectedLessonId: 99,
        newestFirst: true);
    expect(unknown.hasCurrent, isFalse);
    expect(unknown.newer, isNull);
    expect(unknown.older, isNull);
    expect(unknown.panelIndexByLessonId[99], isNull);
  });

  testWidgets(
      'timeline events update progress without rebuilding fullscreen episodes',
      (tester) async {
    tester.view.physicalSize = const Size(873, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _TimelinePlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final lessons = _CountingLessons([
      for (var id = 240; id >= 1; id--) _lesson(id),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecordingVideoControls(
          state: _VideoState(),
          player: player,
          title: '课程录播',
          loading: false,
          failure: null,
          views: const [],
          selectedView: 0,
          fullscreen: true,
          lessons: lessons,
          episodeLessons: lessons,
          selectedLessonId: 240,
          onLessonSelected: (_) {},
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byTooltip('选集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final episodeFinder = find.byKey(const ValueKey('fullscreen-lesson-240'));
    final episode = tester.widget<ListTile>(episodeFinder);
    final panelFinder =
        find.byKey(const ValueKey('recording-fullscreen-episode-panel'));
    final panel = tester.widget<Material>(panelFinder);
    final readsBeforeTicks = lessons.reads;

    for (var tick = 1; tick <= 12; tick++) {
      platform.update(
        position: Duration(seconds: tick),
        buffer: const Duration(seconds: 30),
        duration: const Duration(minutes: 3),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ListTile>(episodeFinder), same(episode));
      expect(tester.widget<Material>(panelFinder), same(panel));
    }
    expect(lessons.reads, readsBeforeTicks,
        reason: 'position, buffer and duration do not traverse the catalog');
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 12000);
    expect(slider.secondaryTrackValue, 30000);
    expect(slider.max, 180000);
    expect(find.text('00:12/03:00', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
