import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_secondary_video.dart';
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

  void updatePlayback({bool? playing, bool? buffering}) {
    state = state.copyWith(playing: playing, buffering: buffering);
    if (playing != null) playingController.add(playing);
    if (buffering != null) bufferingController.add(buffering);
  }

  void showVideo(int width, int height) {
    widthController.add(width);
    heightController.add(height);
  }
}

class _VideoState extends VideoState {}

class _VideoOutput extends PlatformVideoController {
  _VideoOutput(Player player, {int textureId = 123})
      : super(player, const VideoControllerConfiguration()) {
    id.value = textureId;
    rect.value = const Rect.fromLTWH(0, 0, 640, 360);
  }

  @override
  Future<void> setSize({int? width, int? height}) async {}
}

class _VideoController implements VideoController {
  _VideoController(PlatformVideoController output)
      : player = output.player,
        notifier = ValueNotifier<PlatformVideoController?>(output);

  @override
  final Player player;

  @override
  final ValueNotifier<PlatformVideoController?> notifier;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _controls(Player player,
        {bool fullscreen = false,
        bool isLive = false,
        bool loading = false,
        Widget? primaryView,
        List<VideoController> viewControllers = const [],
        VideoController? primaryController,
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
            loading: loading,
            failure: null,
            views: const [],
            selectedView: 0,
            fullscreen: fullscreen,
            isLive: isLive,
            primaryView: primaryView,
            viewControllers: viewControllers,
            primaryController: primaryController,
          ),
        ),
      ),
    );

void main() {
  testWidgets('host texture is single when primary and survives view swaps',
      (tester) async {
    final hostPlatform = _BufferPlayer();
    final otherPlatform = _BufferPlayer();
    final hostPlayer = Player(platformPlayer: hostPlatform);
    final otherPlayer = Player(platformPlayer: otherPlatform);
    final hostOutput = _VideoOutput(hostPlayer);
    final otherOutput = _VideoOutput(otherPlayer, textureId: 124);
    final host = _VideoController(hostOutput);
    final other = _VideoController(otherOutput);
    addTearDown(() async {
      host.notifier.dispose();
      other.notifier.dispose();
      hostOutput.dispose();
      otherOutput.dispose();
      await hostPlayer.dispose();
      await otherPlayer.dispose();
    });
    const videoKey = ValueKey('stable-video-host');
    final hostTexture = find.byWidgetPredicate(
        (widget) => widget is Texture && widget.textureId == 123);
    final otherTexture = find.byWidgetPredicate(
        (widget) => widget is Texture && widget.textureId == 124,
        skipOffstage: false);
    final mask = find.byKey(const ValueKey('recording-live-loading-mask'));
    Widget video({required VideoController primary, bool loading = false}) =>
        MaterialApp(
          home: Scaffold(
            body: Video(
              key: videoKey,
              controller: host,
              wakelock: false,
              controls: (state) => RecordingVideoControls(
                state: state,
                player: identical(primary, host) ? hostPlayer : otherPlayer,
                title: '课程录播',
                loading: loading,
                failure: null,
                views: [
                  VodView(
                      viewNumber: 1, url: Uri.parse('https://example.test/1')),
                  VodView(
                      viewNumber: 2, url: Uri.parse('https://example.test/2')),
                ],
                selectedView: 0,
                fullscreen: true,
                isLive: true,
                dualEnabled: true,
                secondaryView: const SizedBox.expand(),
                viewControllers: [host, other],
                primaryController: primary,
              ),
            ),
          ),
        );

    await tester.pumpWidget(video(primary: host, loading: true));
    hostPlatform.showVideo(640, 360);
    await tester.pump();
    expect(hostTexture, findsOneWidget);
    expect(otherTexture, findsOneWidget);
    expect(mask, findsOneWidget);
    final videoState = tester.state<VideoState>(find.byKey(videoKey));
    final originalHostTexture = tester.element(hostTexture);
    final originalOtherTexture = tester.element(otherTexture);

    await tester.pumpWidget(video(primary: host));
    await tester.pump();
    expect(mask, findsNothing);
    expect(tester.state<VideoState>(find.byKey(videoKey)), same(videoState));
    expect(tester.element(hostTexture), same(originalHostTexture));
    expect(tester.element(otherTexture), same(originalOtherTexture));
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.pumpWidget(video(primary: other, loading: true));
    await tester.pump();
    expect(hostTexture, findsNWidgets(2));
    expect(otherTexture, findsOneWidget);
    expect(tester.state<VideoState>(find.byKey(videoKey)), same(videoState));
    expect(tester.element(otherTexture), same(originalOtherTexture));
    expect(mask, findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.pumpWidget(video(primary: host));
    await tester.pump();
    expect(hostTexture, findsOneWidget);
    expect(tester.element(hostTexture), same(originalHostTexture));
    expect(tester.element(otherTexture), same(originalOtherTexture));
    expect(tester.state<VideoState>(find.byKey(videoKey)), same(videoState));
    expect(mask, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'live loading masks the persistent texture until playback resumes',
      (tester) async {
    final platform = _BufferPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final output = _VideoOutput(player);
    final controller = _VideoController(output);
    addTearDown(() {
      controller.notifier.dispose();
      output.dispose();
    });
    final mask = find.byKey(const ValueKey('recording-live-loading-mask'));
    final spinner = find.byKey(const ValueKey('recording-loading-indicator'));

    Widget controls({bool loading = false}) => _controls(player,
        isLive: true,
        loading: loading,
        primaryView: RecordingSecondaryVideo(controller: controller));
    await tester.pumpWidget(controls(loading: true));
    expect(tester.widget<ColoredBox>(mask).color, Colors.black);
    expect(tester.getRect(mask),
        tester.getRect(find.byType(RecordingVideoControls)));
    expect(spinner, findsOneWidget);
    final textureElement = tester.element(find.byType(Texture));

    await tester.pumpWidget(controls());
    expect(mask, findsNothing);
    expect(tester.element(find.byType(Texture)), same(textureElement));
    platform.updatePlayback(playing: false, buffering: true);
    await tester.pump();
    expect(tester.widget<ColoredBox>(mask).color, Colors.black);
    expect(spinner, findsOneWidget);
    expect(tester.element(find.byType(Texture)), same(textureElement));
    platform.updatePlayback(playing: true, buffering: false);
    await tester.pump();
    expect(mask, findsNothing);
    expect(spinner, findsNothing);
    expect(tester.element(find.byType(Texture)), same(textureElement));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recording loading retains its transparent presentation',
      (tester) async {
    final platform = _BufferPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final mask = find.byKey(const ValueKey('recording-live-loading-mask'));
    final spinner = find.byKey(const ValueKey('recording-loading-indicator'));
    await tester.pumpWidget(_controls(player, loading: true));
    expect(mask, findsNothing);
    expect(spinner, findsOneWidget);
    await tester.pumpWidget(_controls(player));
    platform.updatePlayback(playing: false, buffering: true);
    await tester.pump();
    expect(mask, findsNothing);
    expect(spinner, findsNothing);
    platform.updatePlayback(playing: true);
    await tester.pump();
    expect(mask, findsNothing);
    expect(spinner, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
