import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _SeekPlayer extends PlatformPlayer {
  _SeekPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(duration: const Duration(minutes: 90));
  }

  final positions = <Duration>[];
  int playbackChanges = 0;
  bool publishSeekPosition = true;

  void emitPosition(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> seek(Duration position) async {
    positions.add(position);
    if (publishSeekPosition) emitPosition(position);
  }

  @override
  Future<void> play() async => playbackChanges++;

  @override
  Future<void> pause() async => playbackChanges++;

  @override
  Future<void> playOrPause() async => playbackChanges++;
}

class _EmbeddedVideoState extends VideoState {
  @override
  bool isFullscreen() => false;
}

Widget _controls(
  Player player, {
  Future<void> Function(Duration position)? onSeek,
  Widget? primaryView,
  int? selectedLessonId,
  bool loading = false,
  bool fullscreen = false,
}) =>
    MaterialApp(
      home: Scaffold(
        body: RecordingVideoControls(
          state: _EmbeddedVideoState(),
          player: player,
          title: '课程录播',
          loading: loading,
          failure: null,
          views: const [],
          selectedView: 0,
          selectedLessonId: selectedLessonId,
          fullscreen: fullscreen,
          onSeek: onSeek,
          primaryView: primaryView,
        ),
      ),
    );

void main() {
  testWidgets('slider previews and final seek keep a paused recording paused',
      (tester) async {
    final platform = _SeekPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    var slider = tester.widget<Slider>(find.byType(Slider));

    slider.onChangeStart!(10000);
    slider.onChanged!(20000);
    await tester.pump();
    expect(platform.positions, [const Duration(seconds: 20)]);
    slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(30000);
    slider.onChanged!(40000);
    await tester.pump(const Duration(milliseconds: 90));
    expect(platform.positions.last, const Duration(seconds: 40));
    slider.onChangeEnd!(45123);
    await tester.pump();
    expect(platform.positions.last, const Duration(milliseconds: 45123));
    expect(platform.state.playing, isFalse);
    expect(platform.playbackChanges, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'seek callback can synchronize both players without duplicate seek',
      (tester) async {
    final platform = _SeekPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final positions = <Duration>[];
    await tester.pumpWidget(_controls(player, onSeek: (position) async {
      positions.add(position);
    }));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(10000);
    slider.onChanged!(20000);
    await tester.pump();
    slider.onChangeEnd!(25123);
    await tester.pump();
    expect(positions, [
      const Duration(seconds: 20),
      const Duration(milliseconds: 25123),
    ]);
    expect(platform.positions, isEmpty);
    expect(platform.playbackChanges, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('release stays at the target until the player reports it',
      (tester) async {
    final platform = _SeekPlayer()..publishSeekPosition = false;
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(0);
    slider.onChanged!(20000);
    await tester.pump();
    slider.onChangeEnd!(45123);
    await tester.pump();
    await tester.pump();
    expect(platform.positions.last, const Duration(milliseconds: 45123));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 45123);

    platform.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 45123);

    platform.emitPosition(const Duration(milliseconds: 45200));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 45200);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
        '${fullscreen ? 'fullscreen' : 'portrait'} drag cannot jump back when old positions arrive',
        (tester) async {
      tester.view.physicalSize =
          fullscreen ? const Size(873, 393) : const Size(393, 221);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = _SeekPlayer()..publishSeekPosition = false;
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);
      await tester.pumpWidget(_controls(player, fullscreen: fullscreen));
      final sliderFinder = find.byType(Slider);
      final rect = tester.getRect(sliderFinder);
      final gesture = await tester
          .startGesture(Offset(rect.left + rect.width * .25, rect.center.dy));
      await gesture.moveBy(Offset(rect.width * .3, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump();
      final target = platform.positions.last;
      expect(target, greaterThan(Duration.zero));
      expect(tester.widget<Slider>(sliderFinder).value,
          closeTo(target.inMilliseconds.toDouble(), 1));

      platform.emitPosition(Duration.zero);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Slider>(sliderFinder).value,
          closeTo(target.inMilliseconds.toDouble(), 1));
      platform.emitPosition(target);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Slider>(sliderFinder).value,
          closeTo(target.inMilliseconds.toDouble(), 1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a newer drag ignores the previous seek position',
      (tester) async {
    final platform = _SeekPlayer()..publishSeekPosition = false;
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    var slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(0);
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await tester.pump();
    await tester.pump();
    slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(45000);
    slider.onChanged!(80000);
    platform.emitPosition(const Duration(seconds: 45));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 80000);
    slider.onChangeEnd!(80000);
    await tester.pump();
    await tester.pump();
    platform.emitPosition(const Duration(seconds: 80));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 80000);
    expect(platform.positions.last, const Duration(seconds: 80));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a seek with no position report eventually follows the player',
      (tester) async {
    final platform = _SeekPlayer()..publishSeekPosition = false;
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(0);
    slider.onChangeEnd!(45000);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 45000);
    await tester.pump(const Duration(seconds: 8));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('loading another lesson clears the pending seek', (tester) async {
    final platform = _SeekPlayer()..publishSeekPosition = false;
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, selectedLessonId: 1));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(0);
    slider.onChangeEnd!(45000);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 45000);
    await tester
        .pumpWidget(_controls(player, selectedLessonId: 2, loading: true));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing primary player rebinds progress updates',
      (tester) async {
    final first = _SeekPlayer();
    final second = _SeekPlayer();
    final firstPlayer = Player(platformPlayer: first);
    final secondPlayer = Player(platformPlayer: second);
    addTearDown(firstPlayer.dispose);
    addTearDown(secondPlayer.dispose);
    await tester.pumpWidget(_controls(firstPlayer));
    await tester.pumpWidget(_controls(secondPlayer));
    await second.seek(const Duration(seconds: 30));
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('primary texture cannot receive gestures through player controls',
      (tester) async {
    final player = Player(platformPlayer: _SeekPlayer());
    addTearDown(player.dispose);
    var textureTaps = 0;
    await tester.pumpWidget(_controls(
      player,
      primaryView: GestureDetector(
        onTap: () => textureTaps++,
        child: const ColoredBox(color: Colors.blue),
      ),
    ));
    await tester.tapAt(const Offset(400, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(textureTaps, 0);
    expect(
        tester
            .widget<SlideTransition>(
                find.byKey(const ValueKey('recording-top-controls-transition')))
            .position
            .value
            .dy,
        -1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
