import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_episode_navigation.dart';
import 'package:shuyo/features/course_recordings/recording_playback_status.dart';
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

  void update(
      {Duration? position,
      Duration? buffer,
      Duration? duration,
      bool? playing,
      bool? buffering,
      double? rate}) {
    state = state.copyWith(
        position: position,
        buffer: buffer,
        duration: duration,
        playing: playing,
        buffering: buffering,
        rate: rate);
    if (position != null) positionController.add(position);
    if (buffer != null) bufferController.add(buffer);
    if (duration != null) durationController.add(duration);
    if (playing != null) playingController.add(playing);
    if (buffering != null) bufferingController.add(buffering);
    if (rate != null) rateController.add(rate);
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
    platform.update(playing: true, buffering: true, rate: 2);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<ListTile>(episodeFinder), same(episode));
    expect(tester.widget<Material>(panelFinder), same(panel));
    expect(lessons.reads, readsBeforeTicks);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(find.text('2.0X'), findsOneWidget);
    final loading = tester.widget<RecordingPlaybackLoading>(
        find.byType(RecordingPlaybackLoading));
    expect(loading.buffering, isTrue);
    expect(loading.buffered, const Duration(seconds: 30));

    platform.update(buffer: const Duration(milliseconds: 30900));
    await tester.pump();
    await tester.pump();
    expect(
        tester.widget<RecordingPlaybackLoading>(
            find.byType(RecordingPlaybackLoading)),
        same(loading),
        reason:
            'loading text depends on displayed seconds, not raw buffer ticks');
    platform.update(playing: false, buffering: false, rate: 1);
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(find.text('1.0X'), findsOneWidget);
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    expect(tester.widget<ListTile>(episodeFinder), same(episode));
    expect(tester.widget<Material>(panelFinder), same(panel));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('display seconds deduplicate without rounding slider progress',
      (tester) async {
    tester.view.physicalSize = const Size(873, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _TimelinePlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final seeks = <Duration>[];
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
        onSeek: (position) async {
          seeks.add(position);
        },
      ),
    )));
    platform.update(
        position: const Duration(milliseconds: 10100),
        buffer: const Duration(milliseconds: 30100),
        duration: const Duration(minutes: 3));
    await tester.pump();
    await tester.pump();
    final timeFinder = find.descendant(
        of: find.byKey(const ValueKey('recording-playback-time')),
        matching: find.byType(Text));
    final time = tester.widget<Text>(timeFinder);
    expect(find.text('00:10/03:00', findRichText: true), findsOneWidget);
    for (var milliseconds = 10200; milliseconds <= 10900; milliseconds += 100) {
      platform.update(position: Duration(milliseconds: milliseconds));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Text>(timeFinder), same(time));
      expect(tester.widget<Slider>(find.byType(Slider)).value, milliseconds);
    }
    platform.update(buffer: const Duration(milliseconds: 31250));
    await tester.pump();
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.secondaryTrackValue, 31250);
    expect(tester.widget<Text>(timeFinder), same(time));
    platform.update(
        position: const Duration(milliseconds: 10900),
        buffer: const Duration(milliseconds: 31250),
        duration: const Duration(minutes: 3));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)), same(slider));
    expect(tester.widget<Text>(timeFinder), same(time));
    platform.update(position: const Duration(milliseconds: 11001));
    await tester.pump();
    await tester.pump();
    expect(find.text('00:11/03:00', findRichText: true), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 11001);
    final seekSlider = tester.widget<Slider>(find.byType(Slider));
    seekSlider.onChangeStart!(23877);
    seekSlider.onChanged!(23877);
    seekSlider.onChangeEnd!(23877);
    await tester.pump();
    await tester.pump();
    expect(seeks.last, const Duration(milliseconds: 23877),
        reason: 'display-only seconds never quantize the final seek command');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('loading follows the visible player independently of the clock',
      (tester) async {
    tester.view.physicalSize = const Size(873, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final primary = _TimelinePlayer();
    final clock = _TimelinePlayer();
    final primaryPlayer = Player(platformPlayer: primary);
    final clockPlayer = Player(platformPlayer: clock);
    addTearDown(primaryPlayer.dispose);
    addTearDown(clockPlayer.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: RecordingVideoControls(
        state: _VideoState(),
        player: primaryPlayer,
        timelinePlayer: clockPlayer,
        title: '课程录播',
        loading: false,
        failure: null,
        views: const [],
        selectedView: 0,
        fullscreen: true,
      ),
    )));
    clock.update(position: const Duration(milliseconds: 7123));
    primary.update(
        playing: true,
        buffering: true,
        buffer: const Duration(milliseconds: 11900));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 7123);
    expect(find.text('00:07/01:00', findRichText: true), findsOneWidget);
    final loading = tester.widget<RecordingPlaybackLoading>(
        find.byType(RecordingPlaybackLoading));
    expect(loading.buffered, const Duration(seconds: 11));
    clock.update(playing: false, buffering: false);
    await tester.pump();
    await tester.pump();
    expect(
        tester.widget<RecordingPlaybackLoading>(
            find.byType(RecordingPlaybackLoading)),
        same(loading));
    primary.update(buffering: false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('inactive loading projection preserves the live control viewport',
      (tester) async {
    const viewport = Size(393, 221);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _TimelinePlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var toggles = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecordingVideoControls(
          state: _VideoState(),
          player: player,
          title: '直播课程',
          loading: false,
          failure: null,
          views: const [],
          selectedView: 0,
          isLive: true,
          livePlaying: true,
          onLiveTogglePlayback: () => toggles++,
          onLiveProtocolChanged: (_) {},
        ),
      ),
    ));
    final surface = find.byKey(const ValueKey('recording-control-surface'));
    expect(tester.getSize(surface), viewport);
    expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
    expect(find.byTooltip('直播线路').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(toggles, 1);
    platform.update(playing: true, buffering: true);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(surface), viewport);
    expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    platform.update(buffering: false);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(surface), viewport);
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
