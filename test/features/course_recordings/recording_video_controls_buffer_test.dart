import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _BufferPlayer extends PlatformPlayer {
  _BufferPlayer({
    Duration position = Duration.zero,
    Duration buffer = Duration.zero,
    Duration duration = const Duration(minutes: 1),
  }) : super(configuration: const PlayerConfiguration()) {
    state =
        state.copyWith(position: position, buffer: buffer, duration: duration);
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

Widget _controls(Player player,
        {bool fullscreen = false,
        bool isLive = false,
        EdgeInsets insets = EdgeInsets.zero,
        ThemeData? theme}) =>
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(viewPadding: insets),
          child: RecordingVideoControls(
            state: _VideoState(),
            player: player,
            title: '课程录播',
            loading: false,
            failure: null,
            views: const [],
            selectedView: 0,
            fullscreen: fullscreen,
            isLive: isLive,
          ),
        ),
      ),
    );

void main() {
  for (final fullscreen in [false, true]) {
    testWidgets(
        '${fullscreen ? 'fullscreen' : 'portrait'} keeps played, buffered and unbuffered progress visible',
        (tester) async {
      final size = fullscreen ? const Size(873, 393) : const Size(393, 221);
      final insets =
          fullscreen ? const EdgeInsets.only(bottom: 24) : EdgeInsets.zero;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = _BufferPlayer(
          position: const Duration(seconds: 15),
          buffer: const Duration(seconds: 45));
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);
      await tester.pumpWidget(
          _controls(player, fullscreen: fullscreen, insets: insets));
      final slider = tester.widget<Slider>(find.byType(Slider));
      final colors = Theme.of(tester.element(find.byType(Slider))).colorScheme;
      final primary = colors.brightness == Brightness.light
          ? colors.inversePrimary
          : colors.primary;
      expect(slider.value, 15000);
      expect(slider.secondaryTrackValue, 45000);
      expect(slider.activeColor, primary);
      expect(slider.secondaryActiveColor, primary.withValues(alpha: .4));

      await tester.tapAt(Offset(size.width / 2, size.height / 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 101));
      final fade = tester.widget<FadeTransition>(
          find.byKey(const ValueKey('recording-compact-progress-fade')));
      expect(fade.opacity.value, 1);
      final track = find.byKey(const ValueKey('recording-compact-progress'));
      final played = find.byKey(const ValueKey('recording-compact-played'));
      final buffered = find.byKey(const ValueKey('recording-compact-buffered'));
      final unbuffered =
          find.byKey(const ValueKey('recording-compact-unbuffered'));
      expect(tester.getSize(track), Size(size.width, 3.5));
      expect(tester.getRect(track).bottom, size.height);
      expect(tester.getSize(played).width, closeTo(size.width * .25, .01));
      expect(tester.getSize(buffered).width, closeTo(size.width * .75, .01));
      expect(tester.widget<ColoredBox>(played).color, primary);
      expect(tester.widget<ColoredBox>(buffered).color,
          primary.withValues(alpha: .4));
      expect(
          tester.widget<ColoredBox>(unbuffered).color, const Color(0x33FFFFFF));

      platform.update(
          position: const Duration(seconds: 30),
          buffer: const Duration(seconds: 50));
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(played).width, closeTo(size.width * .5, .01));
      expect(tester.getSize(buffered).width, closeTo(size.width * 5 / 6, .01));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tapAt(tester.getCenter(track));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 101));
      expect(fade.opacity.value, 0);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('fullscreen shows a visible buffer on a 50-minute recording',
      (tester) async {
    const size = Size(873, 393);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(
        platformPlayer: _BufferPlayer(
            position: const Duration(minutes: 10),
            buffer: const Duration(minutes: 12),
            duration: const Duration(minutes: 50)));
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, fullscreen: true));

    final sliderFinder = find.byType(Slider);
    final slider = tester.widget<Slider>(sliderFinder);
    expect(slider.value, const Duration(minutes: 10).inMilliseconds);
    expect(
        slider.secondaryTrackValue, const Duration(minutes: 12).inMilliseconds);
    expect(slider.max, const Duration(minutes: 50).inMilliseconds);
    final bufferedWidth = tester.getSize(sliderFinder).width *
        (slider.secondaryTrackValue! - slider.value) /
        (slider.max - slider.min);
    expect(bufferedWidth, greaterThan(30));

    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    final played = find.byKey(const ValueKey('recording-compact-played'));
    final buffered = find.byKey(const ValueKey('recording-compact-buffered'));
    expect(tester.getSize(buffered).width - tester.getSize(played).width,
        closeTo(size.width * 2 / 50, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('buffer never extends behind playback or beyond duration',
      (tester) async {
    final platform = _BufferPlayer(
        position: const Duration(seconds: 40),
        buffer: const Duration(seconds: 10));
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 40000);
    platform.update(buffer: const Duration(minutes: 2));
    await tester.pump();
    await tester.pump();
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 60000);
    platform.update(duration: Duration.zero);
    await tester.pump();
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 0);
    expect(slider.secondaryTrackValue, 0);
    expect(slider.onChanged, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing view follows the current player buffer',
      (tester) async {
    final first = _BufferPlayer(
        position: const Duration(seconds: 10),
        buffer: const Duration(seconds: 20));
    final second = _BufferPlayer(
        position: const Duration(seconds: 30),
        buffer: const Duration(seconds: 50));
    final firstPlayer = Player(platformPlayer: first);
    final secondPlayer = Player(platformPlayer: second);
    addTearDown(firstPlayer.dispose);
    addTearDown(secondPlayer.dispose);
    await tester.pumpWidget(_controls(firstPlayer));
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 20000);
    await tester.tapAt(const Offset(400, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    final track = find.byKey(const ValueKey('recording-compact-progress'));
    final buffered = find.byKey(const ValueKey('recording-compact-buffered'));
    expect(tester.getSize(buffered).width,
        closeTo(tester.getSize(track).width / 3, .01));
    await tester.pumpWidget(_controls(secondPlayer));
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 50000);
    expect(tester.getSize(buffered).width,
        closeTo(tester.getSize(track).width * 5 / 6, .01));
    first.update(buffer: const Duration(seconds: 55));
    await tester.pump();
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 50000);
    second.update(buffer: const Duration(seconds: 55));
    await tester.pump();
    await tester.pump();
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 55000);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dark themes use the primary color for both progress tracks',
      (tester) async {
    final player = Player(
        platformPlayer: _BufferPlayer(
            position: const Duration(seconds: 15),
            buffer: const Duration(seconds: 45)));
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, theme: ThemeData.dark()));
    final slider = tester.widget<Slider>(find.byType(Slider));
    final primary =
        Theme.of(tester.element(find.byType(Slider))).colorScheme.primary;
    expect(slider.activeColor, primary);
    expect(slider.secondaryActiveColor, primary.withValues(alpha: .4));
    expect(
        tester
            .widget<ColoredBox>(
                find.byKey(const ValueKey('recording-compact-played')))
            .color,
        primary);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live playback does not show a recording progress bar',
      (tester) async {
    final player = Player(platformPlayer: _BufferPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, isLive: true));
    expect(find.byType(Slider), findsNothing);
    expect(
        find.byKey(const ValueKey('recording-compact-progress')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('automatically hidden controls leave a visible progress strip',
      (tester) async {
    final platform = _BufferPlayer(
        position: const Duration(seconds: 15),
        buffer: const Duration(seconds: 45));
    platform.state = platform.state.copyWith(playing: true);
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    final fade = tester.widget<FadeTransition>(
        find.byKey(const ValueKey('recording-compact-progress-fade')));
    expect(fade.opacity.value, 1);
    final track = find.byKey(const ValueKey('recording-compact-progress'));
    final played = find.byKey(const ValueKey('recording-compact-played'));
    final buffered = find.byKey(const ValueKey('recording-compact-buffered'));
    expect(tester.getSize(played).width,
        closeTo(tester.getSize(track).width * .25, .01));
    expect(tester.getSize(buffered).width,
        closeTo(tester.getSize(track).width * .75, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
