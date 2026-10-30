import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _InteractionPlayer extends PlatformPlayer {
  _InteractionPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(duration: const Duration(minutes: 90));
  }

  int toggles = 0;
  final seeks = <Duration>[];
  final rates = <double>[];
  Completer<void>? rateGate;

  @override
  Future<void> playOrPause() async {
    toggles++;
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    await rateGate?.future;
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }
}

class _InteractionVideoState extends VideoState {}

Widget _controls(
  Player player, {
  bool fullscreen = false,
  bool isLive = false,
  bool dualEnabled = false,
  VoidCallback? onSwapViews,
  ValueChanged<String>? onAspectChanged,
  ValueChanged<VodLiveProtocol>? onLiveProtocolChanged,
  Widget? failure,
  bool? livePlaying,
  VoidCallback? onLiveTogglePlayback,
  EdgeInsets safeInsets = EdgeInsets.zero,
  VodLesson? selectedLesson,
}) =>
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(viewPadding: safeInsets),
          child: RecordingVideoControls(
            state: _InteractionVideoState(),
            player: player,
            title: '课程录播',
            loading: false,
            failure: failure,
            views: dualEnabled
                ? [
                    VodView(
                        viewNumber: 1,
                        url: Uri.parse('https://example.test/classroom')),
                    VodView(
                        viewNumber: 5,
                        url: Uri.parse('https://example.test/ppt')),
                  ]
                : const [],
            selectedView: 0,
            fullscreen: fullscreen,
            isLive: isLive,
            livePlaying: livePlaying,
            onLiveTogglePlayback: onLiveTogglePlayback,
            onLiveProtocolChanged: onLiveProtocolChanged,
            selectedLesson: selectedLesson,
            dualEnabled: dualEnabled,
            secondaryView:
                dualEnabled ? const ColoredBox(color: Colors.blue) : null,
            secondaryLabel: 'PPT',
            onSwapViews: onSwapViews,
            onAspectChanged: onAspectChanged,
          ),
        ),
      ),
    );

Animation<Offset> _transition(WidgetTester tester, {bool top = true}) => tester
    .widget<SlideTransition>(find.byKey(ValueKey(top
        ? 'recording-top-controls-transition'
        : 'recording-bottom-controls-transition')))
    .position;

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('control bar uses the upstream progress and button dimensions',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, fullscreen: true));
    final track =
        tester.getRect(find.byKey(const ValueKey('recording-seek-track')));
    final row =
        tester.getRect(find.byKey(const ValueKey('recording-bottom-controls')));
    expect(track.height, 14);
    expect(row.top - track.bottom, 7);
    expect(row.height, 34);
    expect(tester.getSize(find.byTooltip('播放')), const Size(42, 34));
    expect(tester.getSize(find.byTooltip('退出全屏').last).height, 30);
    expect(tester.getSize(find.byTooltip('更多设置')), const Size(42, 34));
    await tester.pumpWidget(_controls(player));
    await tester.tap(find.byTooltip('更多设置'));
    await tester.pumpAndSettle();
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放信息'), findsOneWidget);
    expect(find.text('播放链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen status appears for recordings and live streams',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    for (final live in [false, true]) {
      await tester
          .pumpWidget(_controls(player, fullscreen: true, isLive: live));
      await tester.pump();
      expect(find.byKey(const ValueKey('recording-fullscreen-bandwidth')),
          findsNothing);
      expect(find.byKey(const ValueKey('recording-fullscreen-clock')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(_controls(player));
    expect(
        find.byKey(const ValueKey('recording-fullscreen-clock')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'quality label is noninteractive and only shown for fullscreen recordings',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, fullscreen: true));
    final label = find.byKey(const ValueKey('recording-quality-label'));
    expect(find.text('1080P'), findsOneWidget);
    expect(
        find.ancestor(
            of: label, matching: find.byType(PopupMenuButton<double>)),
        findsNothing);
    expect(find.ancestor(of: label, matching: find.byType(IconButton)),
        findsNothing);
    expect(tester.getCenter(label).dx,
        greaterThan(tester.getCenter(find.byTooltip('播放速度')).dx));
    expect(tester.getCenter(label).dx,
        lessThan(tester.getCenter(find.byTooltip('退出全屏').last).dx));

    await tester.pumpWidget(_controls(player));
    expect(label, findsNothing);
    await tester.pumpWidget(_controls(player, fullscreen: true, isLive: true));
    expect(label, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen episode heading matches title color', (tester) async {
    await _setSize(tester, const Size(873, 393));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player,
        fullscreen: true,
        selectedLesson: VodLesson(
            id: 1,
            teachingClassId: 2,
            name: '课程',
            isPlayable: true,
            beginTime: DateTime(2026, 10, 29, 13),
            weekNumber: 7)));
    final title = tester
        .widget<Text>(find.byKey(const ValueKey('recording-fullscreen-title')));
    final heading = tester.widget<Text>(
        find.byKey(const ValueKey('recording-fullscreen-episode-heading')));
    expect(heading.style!.color, title.style!.color);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live protocol menu selects FLV and WebRTC', (tester) async {
    await _setSize(tester, const Size(393, 221));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    VodLiveProtocol? selected;
    await tester.pumpWidget(_controls(player,
        isLive: true, onLiveProtocolChanged: (value) => selected = value));
    await tester.tap(find.byTooltip('直播线路'));
    await tester.pumpAndSettle();
    expect(find.text('WebRTC'), findsOneWidget);
    await tester.tap(find.text('FLV'));
    await tester.pumpAndSettle();
    expect(selected, VodLiveProtocol.flv);
    await tester.tap(find.byTooltip('直播线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebRTC'));
    await tester.pumpAndSettle();
    expect(selected, VodLiveProtocol.webRtc);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live failure still allows changing protocol', (tester) async {
    await _setSize(tester, const Size(393, 221));
    final player = Player(platformPlayer: _InteractionPlayer());
    addTearDown(player.dispose);
    VodLiveProtocol? selected;
    await tester.pumpWidget(_controls(player,
        isLive: true,
        failure: const Center(child: Text('WebVPN 暂不支持 WebRTC')),
        onLiveProtocolChanged: (value) => selected = value));
    await tester.tap(find.byTooltip('直播线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FLV'));
    await tester.pumpAndSettle();
    expect(selected, VodLiveProtocol.flv);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('WebRTC playback control uses backend state', (tester) async {
    await _setSize(tester, const Size(393, 221));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var toggles = 0;
    await tester.pumpWidget(_controls(player,
        isLive: true,
        livePlaying: true,
        onLiveTogglePlayback: () => toggles++));
    await tester.tap(find.byTooltip('暂停'));
    expect(toggles, 1);
    expect(platform.toggles, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullscreen in [false, true]) {
    testWidgets(
        '${fullscreen ? 'fullscreen' : 'portrait'} long press temporarily plays at 3x',
        (tester) async {
      await _setSize(
          tester, fullscreen ? const Size(873, 393) : const Size(393, 221));
      final platform = _InteractionPlayer();
      platform.state = platform.state.copyWith(playing: true, rate: 1.5);
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);
      await tester.pumpWidget(_controls(player, fullscreen: fullscreen));
      final gesture = await tester.startGesture(
          fullscreen ? const Offset(400, 170) : const Offset(190, 100));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 150));
      expect(platform.rates, [3]);
      expect(platform.state.rate, 3);
      expect(find.text('3.0倍速中'), findsOneWidget);
      expect(
          tester
              .widget<AnimatedOpacity>(
                  find.byKey(const ValueKey('recording-long-press-speed')))
              .opacity,
          1);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(platform.rates, [3, 1.5]);
      expect(platform.state.rate, 1.5);
      expect(
          tester
              .widget<AnimatedOpacity>(
                  find.byKey(const ValueKey('recording-long-press-speed')))
              .opacity,
          0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('paused and live playback ignore long press speed',
      (tester) async {
    await _setSize(tester, const Size(393, 221));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    await tester.longPressAt(const Offset(190, 100));
    await tester.pump();
    expect(platform.rates, isEmpty);
    platform.state = platform.state.copyWith(playing: true);
    await tester.pumpWidget(_controls(player, isLive: true));
    await tester.longPressAt(const Offset(190, 100));
    await tester.pump();
    expect(platform.rates, isEmpty);
    expect(
        find.byKey(const ValueKey('recording-long-press-speed')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('release waits for slow 3x command before restoring speed',
      (tester) async {
    await _setSize(tester, const Size(393, 221));
    final platform = _InteractionPlayer();
    platform.state = platform.state.copyWith(playing: true, rate: 1.25);
    final gate = Completer<void>();
    platform.rateGate = gate;
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));
    final gesture = await tester.startGesture(const Offset(190, 100));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(platform.rates, [3]);
    platform.rateGate = null;
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(platform.rates, [3, 1.25]);
    expect(platform.state.rate, 1.25);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullscreen in [false, true]) {
    final size = fullscreen ? const Size(873, 393) : const Size(393, 221);
    final firstTap = fullscreen ? const Offset(250, 160) : const Offset(70, 85);
    final reverseTap =
        fullscreen ? const Offset(500, 160) : const Offset(310, 85);
    final mode = fullscreen ? 'fullscreen' : 'portrait';

    testWidgets('$mode taps immediately slide controls in 100 milliseconds',
        (tester) async {
      await _setSize(tester, size);
      final platform = _InteractionPlayer();
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);
      await tester.pumpWidget(_controls(player, fullscreen: fullscreen));

      await tester.tapAt(firstTap);
      await tester.pump();
      expect(_transition(tester).status, AnimationStatus.reverse);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_transition(tester).value.dy, closeTo(-.5, .001));
      expect(_transition(tester, top: false).value.dy, closeTo(.6, .001));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_transition(tester).value.dy, closeTo(-1, .001));
      expect(_transition(tester, top: false).value.dy, closeTo(1.2, .001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(_transition(tester).status, AnimationStatus.dismissed);
      expect(_transition(tester).value, const Offset(0, -1));
      expect(_transition(tester, top: false).value, const Offset(0, 1.2));

      await tester.tapAt(reverseTap);
      await tester.pump();
      expect(_transition(tester).status, AnimationStatus.forward);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_transition(tester).value.dy, closeTo(-.5, .001));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_transition(tester).value.dy, closeTo(0, .001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(_transition(tester).status, AnimationStatus.completed);
      expect(_transition(tester).value, Offset.zero);
      expect(_transition(tester, top: false).value, Offset.zero);
      expect(platform.toggles, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$mode controls reverse smoothly before hiding completes',
        (tester) async {
      await _setSize(tester, size);
      final platform = _InteractionPlayer();
      final player = Player(platformPlayer: platform);
      addTearDown(player.dispose);
      await tester.pumpWidget(_controls(player, fullscreen: fullscreen));

      await tester.tapAt(firstTap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_transition(tester).value.dy, closeTo(-.4, .001));
      await tester.tapAt(reverseTap);
      await tester.pump();
      expect(_transition(tester).status, AnimationStatus.forward);
      expect(_transition(tester).value.dy, closeTo(-.4, .001));
      await tester.pump(const Duration(milliseconds: 40));
      expect(_transition(tester).value.dy, closeTo(0, .001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(_transition(tester).status, AnimationStatus.completed);
      expect(_transition(tester).value, Offset.zero);
      expect(platform.toggles, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'a double tap toggles playback once without delaying the first tap',
      (tester) async {
    await _setSize(tester, const Size(393, 221));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));

    await tester.tapAt(const Offset(160, 100));
    await tester.pump();
    expect(_transition(tester).status, AnimationStatus.reverse);
    expect(platform.toggles, 0);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(160, 100));
    await tester.pump();
    expect(platform.toggles, 1);
    expect(platform.state.playing, isTrue);
    expect(_transition(tester).status, AnimationStatus.forward);
    await tester.pump(kDoubleTapTimeout);
    expect(platform.toggles, 1);
    expect(_transition(tester).value, Offset.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'background drags, slider drags and buttons do not toggle controls',
      (tester) async {
    await _setSize(tester, const Size(393, 221));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player));

    await tester.dragFrom(const Offset(100, 90), const Offset(90, 20));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_transition(tester).value, Offset.zero);
    expect(platform.toggles, 0);

    final slider = find.byType(Slider);
    final sliderRect = tester.getRect(slider);
    final gesture = await tester
        .startGesture(Offset(sliderRect.left + 40, sliderRect.center.dy));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_transition(tester).value, Offset.zero);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(platform.seeks, isNotEmpty);
    expect(platform.toggles, 0);
    expect(_transition(tester).value, Offset.zero);

    await tester.tap(find.byTooltip('播放'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(platform.toggles, 1);
    expect(_transition(tester).value, Offset.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('speed menu uses compact plain rows and changes the actual rate',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(player, fullscreen: true));

    await tester.tap(find.byTooltip('播放速度'));
    await tester.pumpAndSettle();
    final rows = find.byType(PopupMenuItem<double>);
    expect(rows, findsNWidgets(7));
    expect(find.byType(CheckedPopupMenuItem<double>), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    for (final element in rows.evaluate()) {
      final row = element.widget as PopupMenuItem<double>;
      expect(row.height, 35);
      expect(row.padding, const EdgeInsets.only(left: 30));
      expect(tester.getSize(find.byWidget(row)).height, 35);
      expect(tester.getSize(find.byWidget(row)).width, 112);
      final text = tester.widget<Text>(
          find.descendant(of: find.byWidget(row), matching: find.byType(Text)));
      expect(text.style?.fontSize, 13);
    }
    expect(_transition(tester).value, Offset.zero);
    final selectedRow = rows
        .evaluate()
        .map((element) => element.widget as PopupMenuItem<double>)
        .singleWhere((row) => row.value == 1.5);
    await tester.tap(find.byWidget(selectedRow));
    await tester.pumpAndSettle();
    expect(platform.rates, [1.5]);
    expect(platform.state.rate, 1.5);
    expect(platform.toggles, 0);
    expect(_transition(tester).value, Offset.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('aspect menu uses compact plain rows and selects the aspect',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final aspects = <String>[];
    await tester.pumpWidget(
        _controls(player, fullscreen: true, onAspectChanged: aspects.add));

    await tester.tap(find.byTooltip('画面比例'));
    await tester.pumpAndSettle();
    final rows = find.byType(PopupMenuItem<String>);
    expect(rows, findsNWidgets(5));
    expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    for (final element in rows.evaluate()) {
      final row = element.widget as PopupMenuItem<String>;
      expect(tester.getSize(find.byWidget(row)), const Size(112, 35));
      expect(row.padding, const EdgeInsets.only(left: 30));
    }
    expect(_transition(tester).value, Offset.zero);
    await tester.tap(find.text('16:9'));
    await tester.pumpAndSettle();
    expect(aspects, ['16:9']);
    expect(platform.toggles, 0);
    expect(_transition(tester).value, Offset.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('floating view casts a shadow and can cover the bottom controls',
      (tester) async {
    await _setSize(tester, const Size(873, 393));
    final platform = _InteractionPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var swaps = 0;
    await tester.pumpWidget(_controls(player,
        fullscreen: true,
        dualEnabled: true,
        safeInsets: const EdgeInsets.fromLTRB(16, 0, 24, 12),
        onSwapViews: () => swaps++));

    final floating = find.byKey(const ValueKey('recording-secondary-view'));
    final decorations = tester.widgetList<DecoratedBox>(
        find.descendant(of: floating, matching: find.byType(DecoratedBox)));
    final shadows = decorations
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .expand((decoration) => decoration.boxShadow ?? const <BoxShadow>[]);
    expect(shadows, isNotEmpty);
    expect(shadows.single.blurRadius, greaterThan(0));
    expect(shadows.single.color.a, greaterThan(0));

    await tester.drag(floating, const Offset(-1000, 1000));
    await tester.pump();
    final bottomRect = tester.getRect(floating);
    expect(bottomRect.left, closeTo(24, .01));
    expect(bottomRect.bottom, closeTo(373, .01));
    final playCenter = tester.getCenter(find.byTooltip('播放'));
    expect(bottomRect.contains(playCenter), isTrue);
    await tester.tapAt(playCenter);
    await tester.pump();
    expect(swaps, 1);
    expect(platform.toggles, 0);
    expect(_transition(tester).value, Offset.zero);

    await tester.drag(floating, const Offset(1000, -1000));
    await tester.pump();
    expect(tester.getRect(floating).top, closeTo(8, .01));
    expect(tester.getRect(floating).contains(playCenter), isFalse);
    await tester.tapAt(playCenter);
    await tester.pump();
    expect(platform.toggles, 1);
    expect(swaps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
