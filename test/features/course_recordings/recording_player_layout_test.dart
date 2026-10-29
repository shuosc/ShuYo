import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shuyo/features/course_recordings/recording_player_layout.dart';

class _LayoutPlatformPlayer extends PlatformPlayer {
  _LayoutPlatformPlayer({bool playing = false, bool completed = false})
      : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(playing: playing, completed: completed);
  }

  int plays = 0;
  int pauses = 0;
  int opens = 0;
  final seeks = <Duration>[];

  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position, completed: false);
    positionController.add(position);
    completedController.add(false);
  }
}

class _VideoLifecycle {
  int initializations = 0;
  int disposals = 0;
}

class _VideoProbe extends StatefulWidget {
  const _VideoProbe(this.lifecycle);

  final _VideoLifecycle lifecycle;

  @override
  State<_VideoProbe> createState() => _VideoProbeState();
}

class _VideoProbeState extends State<_VideoProbe> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.initializations++;
  }

  @override
  void dispose() {
    widget.lifecycle.disposals++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

const _headerKey = ValueKey('recording-player-header');
const _toolbarKey = ValueKey('recording-collapsed-toolbar');
const _resumeKey = ValueKey('recording-resume-player');
const _insetKey = ValueKey('recording-status-bar-inset');

ScrollController _outerController(WidgetTester tester) => tester
    .widget<NestedScrollView>(
      find.byKey(const ValueKey('recording-player-scroll')),
    )
    .controller!;

double _headerHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(_headerKey)).height;

double _toolbarOpacity(WidgetTester tester) =>
    tester.widget<Opacity>(find.byKey(_toolbarKey)).opacity;

SystemUiOverlayStyle _overlayStyle(WidgetTester tester) => tester
    .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.descendant(
        of: find.byType(RecordingPlayerLayout),
        matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      ),
    )
    .value;

Future<void> _pumpLayout(
  WidgetTester tester, {
  Player? player,
  bool canResume = true,
  Future<void> Function()? onResume,
  VoidCallback? onBack,
  _VideoLifecycle? lifecycle,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(393, 852),
        viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: RecordingPlayerLayout(
          video: _VideoProbe(lifecycle ?? _VideoLifecycle()),
          body: ListView.builder(
            key: const ValueKey('recording-test-lesson-list'),
            padding: EdgeInsets.zero,
            itemExtent: 64,
            itemCount: 100,
            itemBuilder: (context, index) => Text('课程 $index'),
          ),
          expandedHeight: 220,
          topInset: 44,
          player: player,
          canResume: canResume,
          onResume: onResume ??
              () async {
                await player?.play();
              },
          onBack: onBack ?? () {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _collapse(WidgetTester tester) async {
  _outerController(tester).jumpTo(164);
  await tester.pump();
}

void main() {
  testWidgets('playing pins the full player while the lesson list scrolls',
      (tester) async {
    final platform = _LayoutPlatformPlayer(playing: true);
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);

    await tester.drag(
      find.byKey(const ValueKey('recording-test-lesson-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(_headerHeight(tester), 220);
    expect(_toolbarOpacity(tester), 0);
    expect(_overlayStyle(tester).statusBarIconBrightness, Brightness.light);
    final inset = tester.widget<ColoredBox>(find.descendant(
      of: find.byKey(_insetKey),
      matching: find.byType(ColoredBox),
    ));
    expect(inset.color, Colors.black);
    expect(find.text('课程 0'), findsNothing);
    expect(platform.plays, 0);
    expect(platform.pauses, 0);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'paused scrolling continuously collapses and fades in the toolbar',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);

    expect(_headerHeight(tester), 220);
    expect(_toolbarOpacity(tester), 0);
    _outerController(tester).jumpTo(82);
    await tester.pump();
    expect(_headerHeight(tester), 138);
    expect(_toolbarOpacity(tester), closeTo(.5, .001));

    await _collapse(tester);
    expect(_headerHeight(tester), kToolbarHeight);
    expect(_toolbarOpacity(tester), 1);
    expect(find.text('继续播放'), findsOneWidget);
    expect(platform.opens, 0);
    expect(platform.plays, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'continue expands for 200ms then resumes only the existing player',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);
    await _collapse(tester);

    await tester.tap(find.byKey(_resumeKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_headerHeight(tester), greaterThan(kToolbarHeight));
    expect(_headerHeight(tester), lessThan(220));
    expect(platform.plays, 0);

    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();
    expect(_headerHeight(tester), 220);
    expect(_toolbarOpacity(tester), 0);
    expect(platform.plays, 1);
    expect(platform.opens, 0);
    expect(platform.pauses, 0);
    expect(platform.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('external playback automatically expands the collapsed player',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);
    await _collapse(tester);

    await player.play();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_headerHeight(tester), greaterThan(kToolbarHeight));
    expect(_headerHeight(tester), lessThan(220));
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();

    expect(_headerHeight(tester), 220);
    expect(_toolbarOpacity(tester), 0);
    expect(platform.plays, 1);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unavailable playback only expands without invoking resume',
      (tester) async {
    var resumes = 0;
    await _pumpLayout(tester, canResume: false, onResume: () async {
      resumes++;
    });
    await _collapse(tester);

    expect(find.text('展开播放器'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.byKey(_resumeKey));
    await tester.pumpAndSettle();

    expect(_headerHeight(tester), 220);
    expect(resumes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('completed playback offers replay using the original callback',
      (tester) async {
    final platform = _LayoutPlatformPlayer(completed: true);
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player, onResume: () async {
      await player.seek(Duration.zero);
      await player.play();
    });
    await _collapse(tester);

    expect(find.text('重新播放'), findsOneWidget);
    expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
    await tester.tap(find.byKey(_resumeKey));
    await tester.pumpAndSettle();

    expect(_headerHeight(tester), 220);
    expect(platform.plays, 1);
    expect(platform.seeks, [Duration.zero]);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('notch inset stays fixed while status colors follow collapse',
      (tester) async {
    await _pumpLayout(tester, canResume: false);
    final theme = Theme.of(tester.element(find.byType(RecordingPlayerLayout)));
    ColoredBox insetBackground() => tester.widget<ColoredBox>(find.descendant(
          of: find.byKey(_insetKey),
          matching: find.byType(ColoredBox),
        ));

    expect(tester.getSize(find.byKey(_insetKey)).height, 44);
    expect(tester.getTopLeft(find.byKey(_headerKey)).dy, 44);
    expect(insetBackground().color, Colors.black);
    expect(_overlayStyle(tester).statusBarIconBrightness, Brightness.light);
    expect(_overlayStyle(tester).statusBarBrightness, Brightness.dark);

    _outerController(tester).jumpTo(41);
    await tester.pump();
    expect(insetBackground().color,
        Color.lerp(Colors.black, theme.colorScheme.surface, .25));
    expect(_overlayStyle(tester).statusBarIconBrightness, Brightness.light);

    _outerController(tester).jumpTo(82);
    await tester.pump();
    expect(_overlayStyle(tester).statusBarIconBrightness, Brightness.dark);
    expect(_overlayStyle(tester).statusBarBrightness, Brightness.light);

    await _collapse(tester);
    expect(insetBackground().color, theme.colorScheme.surface);
    expect(tester.getSize(find.byKey(_insetKey)).height, 44);
    expect(tester.getTopLeft(find.byKey(_headerKey)).dy, 44);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'collapse and resume keep the mounted video state and back action',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    final lifecycle = _VideoLifecycle();
    addTearDown(player.dispose);
    var backs = 0;
    await _pumpLayout(tester,
        player: player, lifecycle: lifecycle, onBack: () => backs++);
    final initialState = tester.state(find.byType(_VideoProbe));

    await _collapse(tester);
    expect(tester.state(find.byType(_VideoProbe)), same(initialState));
    expect(lifecycle.initializations, 1);
    expect(lifecycle.disposals, 0);
    expect(tester.getSize(find.byType(_VideoProbe)).height, 220);
    await tester.tap(find.byTooltip('返回课程列表'));
    expect(backs, 1);

    await tester.tap(find.byKey(_resumeKey));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(_VideoProbe)), same(initialState));
    expect(lifecycle.initializations, 1);
    expect(lifecycle.disposals, 0);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(lifecycle.disposals, 1);
  });

  testWidgets('reduced motion expands immediately before resuming',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player, disableAnimations: true);
    await _collapse(tester);

    await tester.tap(find.byKey(_resumeKey));
    await tester.pump();
    await tester.pump();

    expect(_headerHeight(tester), 220);
    expect(platform.plays, 1);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated resume presses share one playback request',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);
    await _collapse(tester);
    final resume = tester.widget<TextButton>(find.byKey(_resumeKey)).onPressed!;

    resume();
    resume();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    resume();
    expect(platform.plays, 0);
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();

    expect(_headerHeight(tester), 220);
    expect(platform.plays, 1);
    expect(platform.opens, 0);
    expect(platform.seeks, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'expand-only intent does not become playback when readiness changes',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player, canResume: false);
    await _collapse(tester);

    await tester.tap(find.byKey(_resumeKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_headerHeight(tester), greaterThan(kToolbarHeight));
    expect(_headerHeight(tester), lessThan(220));
    await _pumpLayout(tester, player: player, canResume: true);
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();

    expect(_headerHeight(tester), 220);
    expect(platform.plays, 0);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'resuming expands only the header and preserves the lesson offset',
      (tester) async {
    final platform = _LayoutPlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await _pumpLayout(tester, player: player);
    await tester.drag(
      find.byKey(const ValueKey('recording-test-lesson-list')),
      const Offset(0, -1600),
    );
    await tester.pumpAndSettle();
    final nested = tester.state<NestedScrollViewState>(
      find.byKey(const ValueKey('recording-player-scroll')),
    );
    final lessonOffset = nested.innerController.offset;
    expect(lessonOffset, greaterThan(500));
    expect(_headerHeight(tester), kToolbarHeight);

    await tester.tap(find.byKey(_resumeKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_headerHeight(tester), greaterThan(kToolbarHeight));
    expect(_headerHeight(tester), lessThan(220));
    expect(nested.innerController.offset, closeTo(lessonOffset, .001));
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump();

    expect(_headerHeight(tester), 220);
    expect(nested.innerController.offset, closeTo(lessonOffset, .001));
    expect(platform.plays, 1);
    expect(platform.opens, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
