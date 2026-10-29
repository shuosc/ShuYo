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

  @override
  Future<void> seek(Duration position) async {
    positions.add(position);
    state = state.copyWith(position: position);
    positionController.add(position);
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
}) =>
    MaterialApp(
      home: Scaffold(
        body: RecordingVideoControls(
          state: _EmbeddedVideoState(),
          player: player,
          title: '课程录播',
          loading: false,
          failure: null,
          views: const [],
          selectedView: 0,
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
    await tester.pump(const Duration(milliseconds: 400));
    expect(textureTaps, 0);
    expect(
        tester
            .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('recording-controls-overlay')))
            .opacity,
        0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
