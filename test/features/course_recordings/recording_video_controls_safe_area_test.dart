import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _SafeAreaPlayer extends PlatformPlayer {
  _SafeAreaPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 90),
    );
  }

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }
}

class _SafeAreaVideoState extends VideoState {
  @override
  Future<void> toggleFullscreen() async {}

  @override
  Future<void> exitFullscreen() async {}
}

const _lessons = [
  VodLesson(id: 2, teachingClassId: 10, name: '第二节', isPlayable: true),
  VodLesson(id: 1, teachingClassId: 10, name: '第一节', isPlayable: true),
];

Widget _controls({
  required Player player,
  required Size size,
  required EdgeInsets viewPadding,
  bool fullscreen = true,
  bool dual = false,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: size, padding: EdgeInsets.zero, viewPadding: viewPadding),
        child: Scaffold(
          body: RecordingVideoControls(
            state: _SafeAreaVideoState(),
            fullscreen: fullscreen,
            player: player,
            title: '电路与模拟电子技术',
            loading: false,
            failure: null,
            views: [
              VodView(
                  viewNumber: 1,
                  url: Uri.https('media.example', '/classroom'),
                  displayLabel: '教室'),
              VodView(
                  viewNumber: 5,
                  url: Uri.https('media.example', '/ppt'),
                  displayLabel: 'PPT'),
            ],
            selectedView: 0,
            lessons: _lessons,
            selectedLessonId: 2,
            onLessonSelected: (_) {},
            onBack: () {},
            onDualChanged: (_) {},
            dualEnabled: dual,
            secondaryView: const ColoredBox(color: Colors.blue),
            primaryView: const ColoredBox(
                key: ValueKey('safe-area-primary-picture'),
                color: Colors.black),
          ),
        ),
      ),
    );

void main() {
  for (final insets in [
    const EdgeInsets.fromLTRB(44, 12, 0, 24),
    const EdgeInsets.fromLTRB(0, 12, 44, 24),
    const EdgeInsets.fromLTRB(44, 12, 44, 24),
  ]) {
    testWidgets(
        'fullscreen controls respect viewPadding $insets with zero padding',
        (tester) async {
      const size = Size(873, 393);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = Player(platformPlayer: _SafeAreaPlayer());
      await tester.pumpWidget(
          _controls(player: player, size: size, viewPadding: insets));
      await tester.pump();

      final back = tester.getRect(find.byTooltip('退出全屏').first);
      final bottom = tester
          .getRect(find.byKey(const ValueKey('recording-bottom-controls')));
      expect(back.left, greaterThanOrEqualTo(insets.left + 10));
      expect(back.top, greaterThanOrEqualTo(insets.top + 10));
      expect(bottom.left, greaterThanOrEqualTo(insets.left + 10));
      expect(bottom.right, lessThanOrEqualTo(size.width - insets.right - 10));
      expect(
          bottom.bottom, lessThanOrEqualTo(size.height - insets.bottom - 12));
      expect(
          tester
              .getRect(find.byKey(const ValueKey('safe-area-primary-picture'))),
          Offset.zero & size);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  }

  testWidgets('portrait controls do not consume viewPadding a second time',
      (tester) async {
    const size = Size(393, 221);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    await tester.pumpWidget(_controls(
        player: player,
        size: size,
        fullscreen: false,
        viewPadding: const EdgeInsets.fromLTRB(0, 44, 0, 34)));
    await tester.pump();

    final back = tester.getRect(find.byTooltip('返回课程列表'));
    final bottom =
        tester.getRect(find.byKey(const ValueKey('recording-bottom-controls')));
    expect(back.top, 4);
    expect(bottom.bottom, size.height - 12);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('floating view stays inside every viewPadding edge when dragged',
      (tester) async {
    const size = Size(873, 393);
    const insets = EdgeInsets.fromLTRB(44, 20, 32, 24);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    await tester.pumpWidget(
        _controls(player: player, size: size, viewPadding: insets, dual: true));
    await tester.pump();
    final floating = find.byKey(const ValueKey('recording-secondary-view'));

    await tester.drag(floating, const Offset(-2000, -1000));
    await tester.pump(const Duration(milliseconds: 350));
    var rect = tester.getRect(floating);
    expect(rect.left, greaterThanOrEqualTo(insets.left + 8));
    expect(rect.top, greaterThanOrEqualTo(insets.top + 8));

    await tester.drag(floating, const Offset(2000, 1000));
    await tester.pump(const Duration(milliseconds: 350));
    rect = tester.getRect(floating);
    expect(rect.right, lessThanOrEqualTo(size.width - insets.right - 8));
    expect(rect.bottom, lessThanOrEqualTo(size.height - insets.bottom - 8));
    expect(rect.size, const Size(200, 112.5));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  for (final size in [const Size(873, 393), const Size(320, 221)]) {
    testWidgets('episode drawer respects viewPadding at $size', (tester) async {
      const insets = EdgeInsets.fromLTRB(44, 12, 44, 24);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = Player(platformPlayer: _SafeAreaPlayer());
      await tester.pumpWidget(
          _controls(player: player, size: size, viewPadding: insets));
      await tester.pump();

      await tester.ensureVisible(find.byTooltip('选集'));
      await tester.pump();
      await tester.tap(find.byTooltip('选集'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final close = tester.getRect(find.byTooltip('收起选集'));
      final episodes =
          tester.getRect(find.byKey(const ValueKey('fullscreen-episode-list')));
      expect(
          tester
              .widget<ListView>(
                  find.byKey(const ValueKey('fullscreen-episode-list')))
              .padding,
          EdgeInsets.zero);
      expect(close.top, greaterThanOrEqualTo(insets.top));
      expect(close.right, lessThanOrEqualTo(size.width - insets.right));
      expect(episodes.bottom, lessThanOrEqualTo(size.height - insets.bottom));
      expect(episodes.right, lessThanOrEqualTo(size.width - insets.right));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  }
}
