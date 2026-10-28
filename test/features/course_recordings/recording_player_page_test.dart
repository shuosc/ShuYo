import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
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

  @override
  Future<void> playOrPause() async {
    toggles++;
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
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
  }) =>
      MaterialApp(
          home: Scaffold(
              body: RecordingVideoControls(
        state: state,
        player: player,
        title: course.name,
        loading: false,
        failure: null,
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
        onViewSelected: (_) {},
        softwareDecoding: false,
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
      )));

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
    await tester.tap(find.text('选集'));
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
    await tester.tap(find.text('选集'));
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
  }) =>
      MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: RecordingPlayerPage(
          course: course,
          lessons: [first, second, unavailable, unrelated],
          initialLesson: initial ?? first,
          loadPlayback: load,
          onSessionExpired: login,
        ),
      );

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
    var selectedView = -1;
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
            onViewSelected: (value) => selectedView = value,
            softwareDecoding: false,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('1:05:00 / 1:30:00'), findsOneWidget);
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

    await tester.tap(find.byTooltip('播放设置'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is CheckedPopupMenuItem<int> && widget.value == 1));
    await tester.pumpAndSettle();
    expect(selectedView, 1);
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
                onViewSelected: (_) {},
                softwareDecoding: false,
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
            player: player,
            title: '电路与模拟电子技术',
            loading: false,
            failure: null,
            views: const [],
            selectedView: 0,
            onViewSelected: (_) {},
            softwareDecoding: false,
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
