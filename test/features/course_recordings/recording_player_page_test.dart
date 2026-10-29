import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/features/course_recordings/recording_playback_status.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

class _PlatformPlayer extends PlatformPlayer {
  _PlatformPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      position: const Duration(minutes: 65),
      duration: const Duration(minutes: 90),
    );
  }
  Duration? lastSeek;
  double? lastRate;
  int toggles = 0;
  int plays = 0;
  int pauses = 0;
  final opened = <Playable>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  Completer<void>? openGate;
  Completer<void>? seekGate;

  void emitBuffer(Duration value) => bufferController.add(value);

  void emitBuffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }

  void emitError(String value) => errorController.add(value);

  void emitPosition(Duration value) {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable);
    await openGate?.future;
    state = state.copyWith(
      playing: play,
      width: 1280,
      height: 720,
      position: playable is Media ? playable.start : null,
    );
    widthController.add(1280);
    heightController.add(720);
    playingController.add(play);
  }

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
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  @override
  Future<void> playOrPause() async {
    toggles++;
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    lastSeek = position;
    await seekGate?.future;
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    lastRate = rate;
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }
}

class _VideoOutput extends PlatformVideoController {
  _VideoOutput(Player player, int texture, {Completer<void>? firstFrame})
      : super(player, const VideoControllerConfiguration()) {
    id.value = texture;
    rect.value = const Rect.fromLTWH(0, 0, 1280, 720);
    if (firstFrame == null) {
      waitUntilFirstFrameRenderedCompleter.complete();
    } else {
      firstFrame.future.then((_) {
        waitUntilFirstFrameRenderedCompleter.complete();
      });
    }
  }

  @override
  Future<void> setSize({int? width, int? height}) async {}
}

class _VideoController implements VideoController {
  _VideoController(this.player, int texture, {Completer<void>? firstFrame}) {
    final output = _VideoOutput(player, texture, firstFrame: firstFrame);
    platform.complete(output);
    notifier.value = output;
    id = output.id;
    rect = output.rect;
    player.platform!.release.add(() async {
      notifier.dispose();
      output.dispose();
    });
  }

  @override
  final Player player;
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  late final ValueNotifier<int?> id;
  @override
  late final ValueNotifier<Rect?> rect;
  @override
  Future<void> get waitUntilFirstFrameRendered async =>
      (await platform.future).waitUntilFirstFrameRendered;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlaybackHarness {
  _PlaybackHarness({this.primaryOpen, this.secondaryOpen, this.secondaryFrame});

  final Completer<void>? primaryOpen;
  final Completer<void>? secondaryOpen;
  final Completer<void>? secondaryFrame;
  final platforms = <_PlatformPlayer>[];
  final controllers = <_VideoController>[];

  Player createPlayer() {
    final platform = _PlatformPlayer();
    if (platforms.isEmpty) platform.openGate = primaryOpen;
    if (platforms.length == 1) platform.openGate = secondaryOpen;
    platforms.add(platform);
    return Player(platformPlayer: platform);
  }

  VideoController createController(Player player) {
    final controller = _VideoController(player, controllers.length + 1,
        firstFrame: controllers.length == 1 ? secondaryFrame : null);
    controllers.add(controller);
    return controller;
  }
}

class _PendingCatalogRepository extends VodRepository {
  final catalog = Completer<List<VodLesson>>();
  final playback = Completer<VodPlayback>();
  final requested = <VodLesson>[];

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
          {bool forceRefresh = false}) =>
      catalog.future;

  @override
  Future<VodPlayback> preparePlayback(
      {required VodCourse course, required VodLesson lesson}) {
    requested.add(lesson);
    return playback.future;
  }
}

class _VideoState extends VideoState {
  _VideoState({this.fullscreen = false});

  bool fullscreen;

  @override
  bool isFullscreen() => fullscreen;

  @override
  Future<void> toggleFullscreen() async => fullscreen = !fullscreen;

  @override
  Future<void> exitFullscreen() async => fullscreen = false;
}

class _CatalogRepository extends VodRepository {
  _CatalogRepository(this.episodes);
  final List<VodLesson> episodes;
  final requested = <VodLesson>[];

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
          {bool forceRefresh = false}) async =>
      episodes;

  @override
  Future<VodPlayback> preparePlayback(
      {required VodCourse course, required VodLesson lesson}) async {
    requested.add(lesson);
    throw const VodPermissionException();
  }
}

void main() {
  const course = VodCourse(
    teachingClassId: 10,
    termId: 7,
    name: '电路与模拟电子技术',
    teacherNames: ['授课教师'],
  );
  final first = VodLesson(
    id: 101,
    teachingClassId: 10,
    name: course.name,
    isPlayable: true,
    beginTime: DateTime(2026, 9, 14, 8),
  );
  final second = VodLesson(
    id: 102,
    teachingClassId: 10,
    name: course.name,
    isPlayable: true,
    beginTime: DateTime(2026, 9, 21, 8),
  );
  const unavailable = VodLesson(
    id: 103,
    teachingClassId: 10,
    name: '尚未生成的课次',
    isPlayable: false,
    isGenerating: true,
  );
  const unrelated = VodLesson(
    id: 104,
    teachingClassId: 999,
    name: '其他教学班',
    isPlayable: true,
  );

  Widget controlPage({
    required Player player,
    required _VideoState state,
    List<VodLesson> lessons = const [],
    int? selectedId,
    ValueChanged<VodLesson>? onLesson,
    VoidCallback? onBack,
    bool dual = false,
    ValueChanged<bool>? onDualChanged,
    VoidCallback? onSwap,
    ValueChanged<String>? onAspect,
    List<VodView>? views,
    ValueChanged<bool>? onPanelVisibilityChanged,
    bool loading = false,
    Widget? failure,
    VoidCallback? onReload,
  }) =>
      MaterialApp(
          home: Scaffold(
              body: RecordingVideoControls(
        state: state,
        fullscreen: state.fullscreen,
        player: player,
        title: course.name,
        loading: loading,
        failure: failure,
        views: views ??
            [
              VodView(
                  viewNumber: 1,
                  url: Uri.https('media.example', '/classroom'),
                  displayLabel: '教室'),
              VodView(
                  viewNumber: 5,
                  url: Uri.https('media.example', '/ppt'),
                  displayLabel: 'PPT')
            ],
        selectedView: 0,
        lessons: lessons,
        selectedLessonId: selectedId,
        onLessonSelected: onLesson,
        onBack: onBack,
        dualEnabled: dual,
        onDualChanged: onDualChanged ?? (_) {},
        secondaryView: const ColoredBox(color: Colors.blue),
        secondaryLabel: 'PPT',
        onSwapViews: onSwap,
        onAspectChanged: onAspect,
        onEpisodePanelVisibilityChanged: onPanelVisibilityChanged,
        onReload: onReload,
      )));

  testWidgets('buffering indicator and track follow the current player',
      (tester) async {
    final primary = _PlatformPlayer();
    primary.state = primary.state.copyWith(
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 30),
      buffering: true,
    );
    final secondary = _PlatformPlayer();
    secondary.state = secondary.state.copyWith(buffering: false);
    final firstPlayer = Player(platformPlayer: primary);
    final secondPlayer = Player(platformPlayer: secondary);
    addTearDown(firstPlayer.dispose);
    addTearDown(secondPlayer.dispose);
    var reloads = 0;
    await tester.pumpWidget(controlPage(
      player: firstPlayer,
      state: _VideoState(),
      onReload: () => reloads++,
    ));
    expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    expect(find.text('00:30'), findsOneWidget);
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 30000);
    await tester.tap(find.byKey(const ValueKey('recording-loading-indicator')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(reloads, 1);
    primary.state = primary.state.copyWith(buffer: const Duration(seconds: 42));
    primary.emitBuffer(const Duration(seconds: 42));
    await tester.pump();
    await tester.pump();
    expect(find.text('00:42'), findsOneWidget);
    expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue, 42000);

    await tester
        .pumpWidget(controlPage(player: secondPlayer, state: _VideoState()));
    await tester.pump();
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    primary.emitBuffering(true);
    await tester.pump();
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    secondary.state =
        secondary.state.copyWith(buffering: true, buffer: Duration.zero);
    secondary.emitBuffering(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('加载中...'), findsOneWidget);
    await tester.pumpWidget(controlPage(
      player: secondPlayer,
      state: _VideoState(),
      failure: const Text('播放失败'),
    ));
    expect(find.text('播放失败'), findsOneWidget);
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('player option menus use translucent readable backgrounds',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    String? aspect;
    await tester.pumpWidget(controlPage(
      player: player,
      state: _VideoState(fullscreen: true),
      onAspect: (value) => aspect = value,
    ));
    final menus = find.byWidgetPredicate((widget) => widget is PopupMenuButton);
    for (final menu in tester.widgetList<PopupMenuButton>(menus)) {
      expect(menu.color, Colors.black.withValues(alpha: .8));
      expect(menu.surfaceTintColor, Colors.transparent);
      expect(menu.requestFocus, isFalse);
    }
    expect(menus, findsNWidgets(2));
    expect(find.byTooltip('播放设置'), findsNothing);
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    await tester.tap(find.byTooltip('画面比例'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final choice = find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<String> && widget.value == '4:3');
    final label = tester
        .widget<Text>(find.descendant(of: choice, matching: find.text('4:3')));
    expect(label.style?.color, Colors.white);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(aspect, '4:3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [
    const Size(320, 180),
    const Size(393, 221),
    const Size(873, 393),
  ]) {
    final fullscreen = size.width >= 600;
    testWidgets(
        '${fullscreen ? 'fullscreen' : 'portrait'} controls at ${size.width} match the reference grouping and spacing',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = Player(platformPlayer: _PlatformPlayer());
      addTearDown(player.dispose);
      await tester.pumpWidget(controlPage(
          player: player,
          state: _VideoState(fullscreen: fullscreen),
          lessons: [second, first],
          selectedId: first.id,
          onAspect: (_) {}));
      final row = tester
          .getRect(find.byKey(const ValueKey('recording-bottom-controls')));
      final time =
          tester.getRect(find.byKey(const ValueKey('recording-playback-time')));
      final play = tester.getRect(find.byTooltip('暂停'));
      final previous = tester.getRect(find.byTooltip('上一集'));
      final next = tester.getRect(find.byTooltip('下一集'));
      final episodes = tester.getRect(find.byTooltip('选集'));
      final speed = tester.getRect(find.byTooltip('播放速度'));
      final expand =
          tester.getRect(find.byTooltip(fullscreen ? '退出全屏' : '全屏').last);
      expect(play.right, lessThanOrEqualTo(time.left));
      expect(time.right, lessThanOrEqualTo(previous.left));
      expect(previous.right, lessThanOrEqualTo(next.left));
      expect(next.right, lessThanOrEqualTo(episodes.left));
      expect(episodes.right, lessThanOrEqualTo(speed.left));
      expect(speed.right, lessThanOrEqualTo(expand.left));
      for (final button in [play, previous, next, episodes, expand]) {
        expect(button.height, 34);
        expect(button.center.dy, row.center.dy);
      }
      expect(row.bottom, tester.view.physicalSize.height - 12);
      expect(find.text('1:05:00'), findsOneWidget);
      expect(find.text('1:30:00'), findsOneWidget);
      expect(find.text('选集'), findsNothing);
      expect(find.byTooltip('播放设置'), findsNothing);
      expect(find.byType(PopupMenuButton<int>), findsNothing);
      expect(
          find.text(course.name), fullscreen ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'paused video toggles both overlays and embedded back leaves the page',
      (tester) async {
    final platform = _PlatformPlayer();
    platform.state = platform.state.copyWith(playing: false);
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var backs = 0;
    await tester.pumpWidget(controlPage(
        player: player, state: _VideoState(), onBack: () => backs++));
    expect(find.byType(AppBar), findsNothing);
    await tester.tapAt(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        tester
            .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('recording-controls-overlay')))
            .opacity,
        0);
    await tester.tapAt(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        tester
            .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('recording-controls-overlay')))
            .opacity,
        1);
    await tester.tap(find.byTooltip('返回课程列表'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(backs, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'fullscreen navigation skips unavailable episodes and drawer keeps them disabled',
      (tester) async {
    final platform = _PlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    VodLesson? selected;
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        lessons: [second, unavailable, first],
        selectedId: first.id,
        onLesson: (lesson) => selected = lesson));
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '上一集'))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('下一集'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(selected?.id, second.id);
    await tester.tap(find.byTooltip('选集'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final pending = find.byKey(ValueKey('fullscreen-lesson-${unavailable.id}'));
    expect(tester.widget<ListTile>(pending).enabled, isFalse);
    await tester.tap(pending);
    expect(selected?.id, second.id);
    await tester.tap(find.byKey(ValueKey('fullscreen-lesson-${second.id}')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-episode-list')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('back dismisses the fullscreen episode panel before leaving',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    final panelStates = <bool>[];
    addTearDown(player.dispose);
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        lessons: [first, second],
        selectedId: first.id,
        onPanelVisibilityChanged: panelStates.add));
    await tester.tap(find.byTooltip('选集'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(panelStates, [true]);
    expect(
        find.byKey(const ValueKey('fullscreen-episode-list')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-episode-list')), findsNothing);
    expect(panelStates, [true, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'secondary view is fixed size, draggable and exchanges views on tap',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    var swaps = 0;
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        dual: true,
        onSwap: () => swaps++));
    final floating = find.byKey(const ValueKey('recording-secondary-view'));
    expect(find.descendant(of: floating, matching: find.byType(IconButton)),
        findsNothing);
    expect(find.descendant(of: floating, matching: find.byType(Slider)),
        findsNothing);
    final original = tester.getRect(floating);
    await tester.drag(floating, const Offset(-200, 80));
    await tester.pump();
    final moved = tester.getRect(floating);
    expect(moved.size, original.size);
    expect(moved.left, lessThan(original.left));
    await tester.tap(floating);
    await tester.pump(const Duration(milliseconds: 350));
    expect(swaps, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen dual-view button toggles its icon and floating view',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    final changes = <bool>[];
    var dual = false;
    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      return controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        dual: dual,
        onDualChanged: (value) => setState(() {
          changes.add(value);
          dual = value;
        }),
      );
    }));

    expect(
        find.byKey(const ValueKey('recording-secondary-view')), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '开启双视角'))
            .isSelected,
        isFalse);
    await tester.tap(find.byTooltip('开启双视角'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(changes, [true]);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '关闭双视角'))
            .isSelected,
        isTrue);
    expect(
        find.byKey(const ValueKey('recording-secondary-view')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭双视角'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(changes, [true, false]);
    expect(
        find.byKey(const ValueKey('recording-secondary-view')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'single-view episodes hide the floating view but retain the preference',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    final videoState = _VideoState(fullscreen: true);
    final singleView =
        VodView(viewNumber: 1, url: Uri.https('media.example', '/classroom'));
    addTearDown(player.dispose);
    await tester.pumpWidget(controlPage(
        player: player, state: videoState, dual: true, views: [singleView]));
    expect(
        find.byKey(const ValueKey('recording-secondary-view')), findsNothing);
    expect(find.byTooltip('关闭双视角'), findsNothing);
    await tester
        .pumpWidget(controlPage(player: player, state: videoState, dual: true));
    expect(
        find.byKey(const ValueKey('recording-secondary-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen back button exits fullscreen', (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    final videoState = _VideoState(fullscreen: true);
    addTearDown(player.dispose);
    await tester.pumpWidget(controlPage(player: player, state: videoState));
    await tester.tap(find.byTooltip('退出全屏').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(videoState.fullscreen, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'fullscreen exposes supported aspect ratios without invented quality choices',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    String? aspect;
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        onAspect: (value) => aspect = value));
    expect(find.text('清晰度'), findsNothing);
    await tester.tap(find.byTooltip('画面比例'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<String> && widget.value == '4:3'));
    await tester.pumpAndSettle();
    expect(aspect, '4:3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Widget page({
    required Future<VodPlayback> Function(VodLesson) load,
    Future<bool> Function()? login,
    VodLesson? initial,
    _PlaybackHarness? harness,
  }) =>
      MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: RecordingPlayerPage(
          course: course,
          lessons: [first, second, unavailable, unrelated],
          initialLesson: initial ?? first,
          loadPlayback: load,
          onSessionExpired: login,
          playerFactory: harness?.createPlayer,
          videoControllerFactory: harness?.createController,
        ),
      );

  VodPlayback playback(VodLesson lesson) => VodPlayback(
        lessonId: lesson.id,
        teachingClassId: course.teachingClassId,
        title: course.name,
        isLive: lesson.isLive,
        views: [
          VodView(viewNumber: 1, url: Uri.https('media.example', '/classroom')),
          VodView(viewNumber: 5, url: Uri.https('media.example', '/ppt')),
          VodView(viewNumber: 3, url: Uri.https('media.example', '/students')),
        ],
      );

  testWidgets('player errors during opening replace loading and can retry',
      (tester) async {
    final pendingOpen = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    var loads = 0;
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async {
        loads++;
        return playback(lesson);
      },
    ));
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    expect(harness.platforms, hasLength(1));
    expect(harness.platforms.first.opened, hasLength(1));
    expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    harness.platforms.first.emitError('sensitive media URL');
    await tester.pump();
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    expect(find.textContaining('sensitive media URL'), findsNothing);
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    pendingOpen.complete();
    await tester.pumpAndSettle();
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(harness.platforms.first.opened, hasLength(2));
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final live in [false, true]) {
    testWidgets(
        '${live ? 'live' : 'recording'} reuses both decoders across PIP swaps and fullscreen',
        (tester) async {
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final harness = _PlaybackHarness();
      final lesson = live
          ? VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isPlayable: true,
              isLive: true)
          : first;
      var loads = 0;
      await tester.pumpWidget(page(
          initial: lesson,
          harness: harness,
          load: (lesson) async {
            loads++;
            return playback(lesson);
          }));
      await tester.pumpAndSettle();
      expect(harness.platforms, hasLength(2));
      final classroom = harness.platforms[0];
      final ppt = harness.platforms[1];
      expect(classroom.opened, hasLength(1));
      expect(ppt.opened, hasLength(1));
      expect((classroom.opened.single as Media).uri,
          'https://media.example/classroom');
      expect((ppt.opened.single as Media).uri, 'https://media.example/ppt');
      expect(classroom.state.volume, 100);
      expect(ppt.state.volume, 0);
      expect(ppt.state.playing, isTrue);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byTooltip('播放设置'), findsNothing);

      await tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .state
          .enterFullscreen();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('开启双视角'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      await classroom.setVolume(37);
      await tester.pump();
      expect(classroom.state.playing, isFalse);
      expect(ppt.state.playing, isFalse);
      final plays = [classroom.plays, ppt.plays];
      final seeks = [classroom.seeks.length, ppt.seeks.length];
      final floating = find.byKey(const ValueKey('recording-secondary-view'));
      expect(floating, findsOneWidget);
      expect(find.descendant(of: floating, matching: find.byType(IconButton)),
          findsNothing);
      await tester.tap(floating);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      var controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(identical(controls.player.platform, ppt), isTrue);
      expect(controls.selectedView, 1);
      expect(classroom.state.volume, 0);
      expect(ppt.state.volume, 37);
      expect(classroom.state.playing, isFalse);
      expect(ppt.state.playing, isFalse);
      expect([classroom.plays, ppt.plays], plays);
      expect([classroom.seeks.length, ppt.seeks.length], seeks);

      if (!live) {
        await tester.tap(find.byTooltip('播放'));
        await tester.pump(const Duration(milliseconds: 350));
        expect([classroom.toggles, ppt.toggles], [1, 1]);
        expect(classroom.state.playing, isTrue);
        expect(ppt.state.playing, isTrue);
        await tester.tap(find.byTooltip('暂停'));
        await tester.pump(const Duration(milliseconds: 350));
        expect([classroom.toggles, ppt.toggles], [1, 2]);
        expect(classroom.state.playing, isFalse);
        expect(ppt.state.playing, isFalse);
        await tester.tap(find.byTooltip('播放速度'));
        await tester.pumpAndSettle();
        await tester.tap(find.byWidgetPredicate((widget) =>
            widget is CheckedPopupMenuItem<double> && widget.value == 1.5));
        await tester.pumpAndSettle();
        expect(ppt.lastRate, 1.5);
        expect(classroom.lastRate, 1.5);
        await controls.onSeek!(const Duration(minutes: 10));
        await tester.pump();
        expect(ppt.lastSeek, const Duration(minutes: 10));
        expect(classroom.lastSeek, const Duration(minutes: 10));
        expect(ppt.state.playing, isFalse);
        expect(classroom.state.playing, isFalse);
      }
      final pauses = [classroom.pauses, ppt.pauses];
      await controls.state.exitFullscreen();
      await tester.pumpAndSettle();
      expect([classroom.pauses, ppt.pauses], pauses);
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, 1);
      expect(identical(controls.player.platform, ppt), isTrue);
      expect(
          identical(tester.widget<Video>(find.byType(Video)).controller,
              harness.controllers.first),
          isTrue);
      await controls.state.enterFullscreen();
      await tester.pumpAndSettle();
      expect([classroom.pauses, ppt.pauses], pauses);
      expect(find.byKey(const ValueKey('recording-secondary-view')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recording-secondary-view')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, 0);
      expect(classroom.state.volume, 37);
      expect(ppt.state.volume, 0);
      expect(loads, 1);
      expect(classroom.opened, hasLength(1));
      expect(ppt.opened, hasLength(1));
      expect(tester.takeException(), isNull);
      await controls.state.exitFullscreen();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets(
      'swaps wait for alignment without reversing the clock or reopening',
      (tester) async {
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final harness = _PlaybackHarness();
    var loads = 0;
    await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async {
          loads++;
          return playback(lesson);
        }));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    await classroom.pause();
    await tester.pumpAndSettle();
    classroom.seeks.clear();
    ppt.seeks.clear();
    ppt.state = ppt.state.copyWith(position: const Duration(seconds: 8));
    final pendingSeek = Completer<void>();
    ppt.seekGate = pendingSeek;
    classroom.emitPosition(const Duration(seconds: 10));
    await tester.pump();
    expect(ppt.seeks, [const Duration(seconds: 10)]);
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pump();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 0);
    ppt.emitBuffering(true);
    pendingSeek.complete();
    ppt.seekGate = null;
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 0);
    ppt.emitBuffering(false);
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    expect(identical(controls.player.platform, ppt), isTrue);
    expect(ppt.state.position, const Duration(seconds: 10));
    expect(classroom.seeks, isEmpty);
    classroom.emitPosition(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(classroom.state.position, const Duration(seconds: 11));
    expect(ppt.state.position, const Duration(seconds: 11));
    expect(classroom.seeks, isEmpty);
    expect(
        ppt.seeks, [const Duration(seconds: 10), const Duration(seconds: 11)]);
    classroom.emitPosition(const Duration(milliseconds: 11400));
    await tester.pumpAndSettle();
    expect(ppt.state.position, const Duration(milliseconds: 11400));
    final seeks = [classroom.seeks.length, ppt.seeks.length];
    controls.onSwapViews!();
    await tester.pumpAndSettle();
    expect([classroom.seeks.length, ppt.seeks.length], seeks);
    expect(classroom.state.playing, isFalse);
    expect(ppt.state.playing, isFalse);
    expect(loads, 1);
    expect(harness.platforms, hasLength(2));
    expect(classroom.opened, hasLength(1));
    expect(ppt.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('secondary open and first frame never block the primary',
      (tester) async {
    final secondaryOpen = Completer<void>();
    final secondaryFrame = Completer<void>();
    final harness = _PlaybackHarness(
        secondaryOpen: secondaryOpen, secondaryFrame: secondaryFrame);
    var loads = 0;
    await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async {
          loads++;
          return playback(lesson);
        }));
    await tester.pump();
    await tester.pump();
    expect(harness.platforms, hasLength(2));
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.loading, isFalse);
    expect(harness.platforms.first.state.playing, isTrue);
    expect(harness.platforms.last.opened, hasLength(1));
    controls.onSwapViews!();
    await tester.pump();
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        0);

    secondaryOpen.complete();
    await tester.pump();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pump();
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        0);
    secondaryFrame.complete();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        1);
    expect(loads, 1);
    expect(harness.platforms.map((platform) => platform.opened.length), [1, 1]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
      'dual view retries only a failed secondary and reuses it when ready',
      (tester) async {
    final secondaryOpen = Completer<void>();
    final harness = _PlaybackHarness(secondaryOpen: secondaryOpen);
    var loads = 0;
    await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async {
          loads++;
          return playback(lesson);
        }));
    await tester.pump();
    await tester.pump();
    secondaryOpen.completeError(StateError('secondary unavailable'));
    await tester.pumpAndSettle();
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.failure, isNull);
    expect(harness.platforms.first.state.playing, isTrue);
    harness.platforms.last.openGate = null;
    controls.onDualChanged!(true);
    await tester.pumpAndSettle();
    expect(harness.platforms.map((platform) => platform.opened.length), [1, 2]);
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onDualChanged!(false);
    await tester.pump();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onDualChanged!(true);
    await tester.pumpAndSettle();
    expect(harness.platforms.map((platform) => platform.opened.length), [1, 2]);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('live seed prepares playback while its catalog is pending',
      (tester) async {
    const live = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: '直播',
        isPlayable: true,
        isLive: true);
    final repository = _PendingCatalogRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
          course: course.withLiveLesson(live), repository: repository),
    ));
    await tester.pump();
    expect(repository.catalog.isCompleted, isFalse);
    expect(repository.requested.map((lesson) => lesson.id), [106]);
    repository.catalog.complete([live, first]);
    await tester.pump();
    expect(repository.requested, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    repository.playback.completeError(const VodNetworkException());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'direct course page prioritizes live and keeps newest generating episode disabled',
      (tester) async {
    final pending = VodLesson(
        id: 105,
        teachingClassId: 10,
        name: course.name,
        isPlayable: false,
        isGenerating: true,
        beginTime: DateTime(2026, 10, 28, 12));
    final live = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true,
        beginTime: DateTime(2026, 10, 28, 10));
    final repository = _CatalogRepository([first, live, pending]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!),
      home: RecordingPlayerPage(course: course, repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(repository.requested.single.id, 106);
    final generatedRow = find.byKey(const ValueKey('recording-lesson-105'));
    expect(tester.widget<ListTile>(generatedRow).enabled, isFalse);
    expect(tester.widget<ListTile>(generatedRow).onTap, isNull);
    final liveRow = find.byKey(const ValueKey('recording-lesson-106'));
    expect(tester.getTopLeft(generatedRow).dy,
        lessThan(tester.getTopLeft(liveRow).dy));
    expect(find.text('课程介绍'), findsOneWidget);
    expect(find.text('回放生成中'), findsOneWidget);
    expect(
        find.descendant(
            of: liveRow, matching: find.byType(RecordingStatusIcon)),
        findsOneWidget);
    await tester.tap(generatedRow);
    await tester.pump();
    expect(repository.requested, hasLength(1));
  });

  testWidgets(
      'a course containing only generating episodes never asks for playback',
      (tester) async {
    final repository = _CatalogRepository([unavailable]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(course: course, repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(repository.requested, isEmpty);
    expect(find.text('回放生成中，生成后可观看'), findsOneWidget);
    expect(find.text('选集（1）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission failure stays in the viewer and hides raw errors',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(page(load: (lesson) async {
      calls++;
      throw const VodPermissionException(
        'https://media.example/video.mp4?signature=private-value',
      );
    }));
    await tester.pump();

    expect(calls, 1);
    expect(find.text('当前账号没有这节录播的观看权限。'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
    expect(find.text('选集（3）'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('recording-lesson-103')), 100,
        scrollable: find.byType(Scrollable).last);
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('recording-lesson-103')))
            .enabled,
        isFalse);
    expect(find.byKey(const ValueKey('recording-lesson-104')), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late lesson error cannot replace the selected lesson result',
      (tester) async {
    final firstRequest = Completer<VodPlayback>();
    final secondRequest = Completer<VodPlayback>();
    final requested = <int>[];
    await tester.pumpWidget(page(load: (lesson) {
      requested.add(lesson.id);
      return lesson.id == first.id ? firstRequest.future : secondRequest.future;
    }));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recording-lesson-102')));
    await tester.pump();
    expect(requested, [101, 102]);

    secondRequest.completeError(const VodNetworkException());
    await tester.pump();
    expect(find.text('暂时无法连接录播平台，请检查网络后重试。'), findsOneWidget);
    firstRequest.completeError(const VodPermissionException());
    await tester.pump();
    expect(find.text('暂时无法连接录播平台，请检查网络后重试。'), findsOneWidget);
    expect(find.text('当前账号没有这节录播的观看权限。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired sessions recover only after the login button is pressed',
      (tester) async {
    var loginCalls = 0;
    var playbackCalls = 0;
    await tester.pumpWidget(page(
      load: (lesson) async {
        playbackCalls++;
        throw const VodSessionExpiredException();
      },
      login: () async {
        loginCalls++;
        return true;
      },
    ));
    await tester.pump();
    expect(loginCalls, 0);
    expect(playbackCalls, 1);

    await tester.tap(find.text('重新登录'));
    await tester.pump();
    expect(loginCalls, 1);
    expect(playbackCalls, 2);
    expect(find.text('校园账户登录已失效，请重新登录。'), findsOneWidget);
  });

  testWidgets('rejects ungenerated initial lessons without requesting playback',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(page(
      initial: unavailable,
      load: (lesson) async {
        calls++;
        throw const VodNetworkException();
      },
    ));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('这节录播暂时无法观看，请稍后重试。'), findsOneWidget);
  });

  testWidgets('a response for a different lesson is never sent to the decoder',
      (tester) async {
    await tester.pumpWidget(page(load: (lesson) async {
      return VodPlayback(
        lessonId: second.id,
        teachingClassId: course.teachingClassId,
        title: course.name,
        views: [
          VodView(
            viewNumber: 1,
            url: Uri.parse('https://media.example/recording.mp4'),
          ),
        ],
      );
    }));
    await tester.pump();
    expect(find.text('这节录播暂时无法观看，请稍后重试。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a route while metadata is pending is safe',
      (tester) async {
    final pending = Completer<VodPlayback>();
    await tester.pumpWidget(page(load: (_) => pending.future));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(const VodNetworkException());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful playback controls fit 320 pixels at double text size',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _PlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: RecordingVideoControls(
            state: _VideoState(),
            player: player,
            title: '电路与模拟电子技术',
            loading: false,
            failure: null,
            views: [
              VodView(
                  viewNumber: 1, url: Uri.https('media.example', '/teacher')),
              VodView(viewNumber: 5, url: Uri.https('media.example', '/ppt')),
            ],
            selectedView: 0,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('1:05:00'), findsOneWidget);
    expect(find.text('1:30:00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(platform.toggles, 1);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.tap(find.byTooltip('播放速度'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<double> && widget.value == 1.5));
    await tester.pumpAndSettle();
    expect(platform.lastRate, 1.5);

    expect(find.byTooltip('播放设置'), findsNothing);
    expect(find.byType(PopupMenuButton<int>), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'live controls hide seeking and speed and reconnect at the live edge',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _PlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var reconnects = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
          body: SizedBox(
              height: 180,
              child: RecordingVideoControls(
                state: _VideoState(),
                player: player,
                title: '正在直播',
                loading: false,
                failure: null,
                views: const [],
                selectedView: 0,
                isLive: true,
                onReconnect: () => reconnects++,
              ))),
    ));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(find.byTooltip('播放速度'), findsNothing);
    expect(find.text('● 直播'), findsOneWidget);
    await tester.tap(find.byTooltip('回到直播'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(reconnects, 1);
    expect(platform.lastSeek, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact fullscreen controls keep seek progress within the video',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = _PlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: RecordingVideoControls(
            state: _VideoState(fullscreen: true),
            fullscreen: true,
            player: player,
            title: '电路与模拟电子技术',
            loading: false,
            failure: null,
            views: const [],
            selectedView: 0,
          ),
        ),
      ),
    ));
    await tester.pump();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(const Duration(minutes: 10).inMilliseconds.toDouble());
    await tester.pump();
    slider.onChangeEnd!(const Duration(minutes: 10).inMilliseconds.toDouble());
    await tester.pump();
    expect(platform.lastSeek, const Duration(minutes: 10));
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('1:30:00'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
