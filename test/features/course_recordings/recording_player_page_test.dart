import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_ppt.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_live_stream_proxy.dart';
import 'package:shuyo/data/services/vod_webrtc_session.dart';
import 'package:shuyo/features/course_recordings/recording_episode_sort_icon.dart';
import 'package:shuyo/features/course_recordings/recording_episode_tile.dart';
import 'package:shuyo/features/course_recordings/recording_course_overview.dart';
import 'package:shuyo/features/course_recordings/recording_playback_status.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_layout.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/course_color_label.dart';

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
  int stops = 0;
  final opened = <Playable>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  final audioTracks = <AudioTrack>[];
  Completer<void>? openGate;
  Completer<void>? seekGate;
  Completer<void>? volumeGate;
  Completer<void>? stopGate;
  Completer<void>? pauseGate;
  bool failStop = false;
  bool failNextVolume = false;
  bool publishSeekPosition = true;
  bool publishVolumeState = true;
  double appliedVolume = 100;
  VoidCallback? onVolumeApplied;

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
    await pauseGate?.future;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    if (failStop) throw StateError('stop failed');
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    await volumeGate?.future;
    if (failNextVolume) {
      failNextVolume = false;
      throw StateError('volume unavailable');
    }
    appliedVolume = volume;
    if (publishVolumeState) {
      state = state.copyWith(volume: volume);
      volumeController.add(volume);
    }
    onVolumeApplied?.call();
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    audioTracks.add(track);
    throw UnsupportedError('Audio track selection is unavailable');
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
    if (publishSeekPosition) emitPosition(position);
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
  int catalogRequests = 0;
  final catalog = Completer<List<VodLesson>>();
  Future<List<VodLesson>>? refreshCatalog;
  final playback = Completer<VodPlayback>();
  final requested = <VodLesson>[];

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) {
    catalogRequests++;
    return forceRefresh ? refreshCatalog ?? catalog.future : catalog.future;
  }

  @override
  Future<VodPlayback> preparePlayback(
      {required VodCourse course, required VodLesson lesson}) {
    requested.add(lesson);
    return playback.future;
  }
}

class _DeniedCatalogRepository extends _PendingCatalogRepository {
  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) {
    catalogRequests++;
    return Future.error(const VodPermissionException());
  }
}

class _WebVpnHeartbeatRepository extends _PendingCatalogRepository {
  bool restored = false;
  int heartbeats = 0;

  @override
  bool get useWebVpn => true;

  @override
  Future<void> keepLiveAlive(VodCourse course, VodLesson lesson) async {
    heartbeats++;
    if (!restored) throw const VodWebVpnSessionExpiredException();
  }
}

class _PendingPreviewRepository extends VodRepository {
  final catalog = Completer<List<VodLesson>>();
  Future<List<VodLesson>>? refreshCatalog;
  final requests = <({bool forceRefresh, int courseId})>[];
  final playback = <int, Completer<VodPlayback>>{};
  final requested = <int>[];
  final warmed = <List<VodLesson>>[];

  @override
  Future<void> warmCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {bool forceRefresh = false}) async {
    warmed.add(List.of(lessons));
  }

  @override
  Future<List<VodLesson>> loadAndWarmSearchLessons(
      VodCourse course, List<VodLesson> seed,
      {bool forceRefresh = false}) async {
    final lessons =
        await loadPreviewLessons(course, forceRefresh: forceRefresh);
    final merged = <(int, bool), VodLesson>{
      for (final lesson in seed) (lesson.id, lesson.isLive): lesson,
      for (final lesson in lessons) (lesson.id, lesson.isLive): lesson,
    };
    await warmCourseRecordings(course, merged.values.toList());
    return lessons;
  }

  @override
  Future<List<VodLesson>> loadPreviewLessons(VodCourse course,
      {bool forceRefresh = false}) {
    requests
        .add((forceRefresh: forceRefresh, courseId: course.teachingClassId));
    return forceRefresh ? refreshCatalog ?? catalog.future : catalog.future;
  }

  @override
  Future<VodPlayback> preparePlayback(
      {required VodCourse course, required VodLesson lesson}) {
    requested.add(lesson.id);
    if (playback[lesson.id]?.isCompleted ?? true) {
      playback[lesson.id] = Completer<VodPlayback>();
    }
    return playback[lesson.id]!.future;
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

class _ProtocolRepository extends VodRepository {
  final requested = <VodLiveProtocol>[];
  bool allowPlayback = false;
  int heartbeats = 0;

  @override
  Future<void> keepLiveAlive(VodCourse course, VodLesson lesson) async {
    heartbeats++;
  }

  @override
  Future<VodPlayback> prepareLivePlaybackWithProtocol({
    required VodCourse course,
    required VodLesson lesson,
    required VodLiveProtocol protocol,
  }) async {
    requested.add(protocol);
    if (!allowPlayback) throw const VodPermissionException();
    final source = VodWebRtcSource(
        signalingUri: Uri.parse('wss://example.test/live'),
        deviceId: 'camera',
        accountToken: 'test',
        stunServer: '',
        useWebVpn: false);
    return VodPlayback(
        lessonId: lesson.id,
        teachingClassId: course.teachingClassId,
        title: course.name,
        isLive: true,
        views: [
          VodView(
              viewNumber: 1,
              url: Uri.https('media.example', '/live'),
              webRtcSource: protocol == VodLiveProtocol.webRtc ? source : null),
        ]);
  }
}

class _FakeRtcSession extends VodWebRtcSession {
  _FakeRtcSession(super.source);
  int starts = 0;
  int pauses = 0;
  bool disposed = false;
  bool failDisposal = false;
  Completer<void>? disposalGate;
  final volumes = <double>[];
  final audioEnabled = <bool>[];
  double? initialVolume;
  bool? initialAudioEnabled;

  @override
  Future<void> start() async {
    starts++;
    initialVolume = volumes.lastOrNull;
    initialAudioEnabled = audioEnabled.lastOrNull;
    state.value = VodWebRtcState.playing;
  }

  @override
  Future<void> setAudioEnabled(bool enabled) async => audioEnabled.add(enabled);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> pause() async {
    pauses++;
    if (!disposed) state.value = VodWebRtcState.paused;
  }

  @override
  Future<void> play() async {
    if (!disposed) state.value = VodWebRtcState.playing;
  }

  @override
  Future<void> dispose() async {
    await disposalGate?.future;
    disposed = true;
    state.value = VodWebRtcState.disposed;
    state.dispose();
    if (failDisposal) throw StateError('RTC disposal failed');
  }
}

class _FakeLiveProxy extends VodLiveStreamProxy {
  _FakeLiveProxy({this.openGate})
      : super(useWebVpn: false, headersLoader: (_) async => const {});
  final Completer<void>? openGate;
  int opens = 0;
  bool disposed = false;

  @override
  Future<Uri> open(Uri source) async {
    opens++;
    await openGate?.future;
    return source;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const course = VodCourse(
    teachingClassId: 10,
    termId: 7,
    name: '电路与模拟电子技术',
    teacherNames: ['授课教师'],
    code: 'EE102',
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
    ThemeData? theme,
    List<VodLesson> lessons = const [],
    List<VodLesson>? episodeLessons,
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
          theme: theme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!),
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
            episodeLessons: episodeLessons,
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

  testWidgets('fullscreen title shows the selected lesson metadata',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    final lesson = VodLesson(
        id: 501,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        beginTime: DateTime(2026, 10, 29, 13),
        endTime: DateTime(2026, 10, 29, 13, 45),
        weekNumber: 6,
        sectionLabel: '第5节');
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        lessons: [lesson, first],
        selectedId: lesson.id));
    final title = tester
        .widget<Text>(find.byKey(const ValueKey('recording-fullscreen-title')));
    expect(title.data, course.name);
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(find.text('第6周 周四 · 第5节 (13:00-13:45)'), findsOneWidget);
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        lessons: [lesson, first],
        selectedId: first.id));
    expect(find.text('周一 (08:00)'), findsOneWidget);
    expect(find.textContaining('第6周'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    final choice = find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String> && widget.value == '4:3');
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
      final speed = tester.getRect(find.byTooltip('播放速度'));
      final expand =
          tester.getRect(find.byTooltip(fullscreen ? '退出全屏' : '全屏').last);
      expect(play.right, lessThanOrEqualTo(time.left));
      expect(time.left - play.right, 0);
      expect(previous.left - time.right, 0);
      expect(time.right, lessThanOrEqualTo(previous.left));
      expect(previous.right, lessThanOrEqualTo(next.left));
      final episodes = fullscreen ? tester.getRect(find.byTooltip('选集')) : null;
      if (episodes != null) {
        expect(next.right, lessThanOrEqualTo(episodes.left));
        expect(episodes.right, lessThanOrEqualTo(speed.left));
      } else {
        expect(find.byTooltip('选集'), findsNothing);
        expect(next.right, lessThanOrEqualTo(speed.left));
      }
      expect(speed.right, lessThanOrEqualTo(expand.left));
      for (final button in [
        play,
        previous,
        next,
        if (episodes != null) episodes,
        expand
      ]) {
        expect(button.height, button == play ? 34 : 30);
        expect(button.center.dy, row.center.dy);
      }
      expect(row.bottom, tester.view.physicalSize.height - 12);
      final timeLabel = find.text('1:05:00/1:30:00');
      expect(timeLabel, findsOneWidget);
      expect(tester.widget<Text>(timeLabel).maxLines, 1);
      expect(time.center.dy, row.center.dy);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        tester
            .widget<SlideTransition>(
                find.byKey(const ValueKey('recording-top-controls-transition')))
            .position
            .value
            .dy,
        -1);
    await tester.tapAt(const Offset(400, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        tester
            .widget<SlideTransition>(
                find.byKey(const ValueKey('recording-top-controls-transition')))
            .position
            .value
            .dy,
        0);
    await tester.tap(find.byTooltip('返回课程列表'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(backs, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen navigation skips and disables generating recordings',
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
    expect(tester.widget<ListTile>(pending).onTap, isNull);
    await tester.tap(pending);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(selected?.id, second.id);
    expect(
        find.byKey(const ValueKey('fullscreen-episode-list')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('fullscreen-lesson-${second.id}')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-episode-list')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'previous and next respect selected classrooms even when current is hidden',
      (tester) async {
    final older = VodLesson(
        id: 201,
        teachingClassId: 10,
        name: '课程',
        classroom: 'A101',
        isPlayable: true,
        beginTime: DateTime(2026, 9, 1));
    final hidden = VodLesson(
        id: 202,
        teachingClassId: 10,
        name: '课程',
        classroom: 'B202',
        isPlayable: true,
        beginTime: DateTime(2026, 9, 2));
    final newer = VodLesson(
        id: 203,
        teachingClassId: 10,
        name: '课程',
        classroom: 'A101',
        isPlayable: true,
        beginTime: DateTime(2026, 9, 3));
    final unavailable = VodLesson(
        id: 204,
        teachingClassId: 10,
        name: '课程',
        classroom: 'A101',
        isPlayable: false,
        isGenerating: true,
        beginTime: DateTime(2026, 9, 4));
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    VodLesson? selected;
    Widget controls(List<VodLesson> filtered, {bool fullscreen = false}) =>
        controlPage(
            player: player,
            state: _VideoState(fullscreen: fullscreen),
            lessons: [unavailable, newer, hidden, older],
            episodeLessons: filtered,
            selectedId: hidden.id,
            onLesson: (lesson) => selected = lesson);
    await tester.pumpWidget(controls([unavailable, newer, older]));
    await tester.tap(find.byTooltip('上一集'));
    expect(selected?.id, older.id);
    await tester.tap(find.byTooltip('下一集'));
    expect(selected?.id, newer.id);
    await tester
        .pumpWidget(controls([unavailable, newer, older], fullscreen: true));
    await tester.tap(find.byTooltip('上一集'));
    expect(selected?.id, older.id);
    await tester.tap(find.byTooltip('下一集'));
    expect(selected?.id, newer.id);
    await tester.pumpWidget(controls([], fullscreen: true));
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '上一集'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '下一集'))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen episode toolbar navigates and reverses the list',
      (tester) async {
    tester.view.physicalSize = const Size(873, 393);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessons = List.generate(
        30,
        (index) => VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: '课程',
            isPlayable: true,
            beginTime: DateTime(2026, 9, 30).subtract(Duration(days: index))));
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(controlPage(
        player: player,
        state: _VideoState(fullscreen: true),
        lessons: lessons,
        selectedId: 215));
    await tester.tap(find.byTooltip('选集'));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('fullscreen-episode-list'));
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.offset, 15 * 80);
    await tester.tap(find.byTooltip('跳至底部'));
    await tester.pump();
    expect(controller.offset, controller.position.maxScrollExtent);
    await tester.tap(find.byTooltip('跳至顶部'));
    await tester.pump();
    expect(controller.offset, 0);
    await tester.tap(find.byTooltip('跳至当前'));
    await tester.pump();
    expect(controller.offset, 15 * 80);
    await tester.tap(find.byTooltip('切换为正序'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换为倒序'), findsOneWidget);
    expect(controller.offset, 14 * 80);
    await tester.tap(find.byTooltip('收起选集'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fullscreen-episode-list')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen episode panel uses theme colors in light and dark',
      (tester) async {
    final player = Player(platformPlayer: _PlatformPlayer());
    addTearDown(player.dispose);
    for (final theme in ShuYoThemes.all) {
      await tester.pumpWidget(controlPage(
          player: player,
          state: _VideoState(fullscreen: true),
          theme: theme.themeData(),
          lessons: [second, first],
          selectedId: first.id));
      await tester.tap(find.byTooltip('选集'));
      await tester.pumpAndSettle();
      final panel =
          find.byKey(const ValueKey('recording-fullscreen-episode-panel'));
      final colors = tester.element(panel).shuyoColors;
      expect(tester.widget<Material>(panel).color, colors.surface);
      final separator = tester.widget<Divider>(
          find.descendant(of: panel, matching: find.byType(Divider)));
      expect(separator.indent, 16);
      expect(separator.endIndent, 16);
      final heading = find.descendant(of: panel, matching: find.text('选集'));
      expect(tester.widget<Text>(heading).style!.color, colors.textPrimary);
      expect(tester.widget<Text>(heading).style!.fontWeight, FontWeight.w600);
      expect(find.text('剧集'), findsNothing);
      final glyph = find.descendant(
          of: panel, matching: find.byType(RecordingEpisodeSortIcon));
      final glyphText = tester.widgetList<Text>(
          find.descendant(of: glyph, matching: find.byType(Text)));
      expect(glyphText.map((text) => text.style!.color),
          everyElement(colors.textPrimary));
      final tile = tester.widget<ListTile>(
          find.byKey(const ValueKey('fullscreen-lesson-102')));
      expect((tile.title! as Text).style!.color, colors.textPrimary);
      expect((tile.subtitle! as Text).style!.color, colors.textSecondary);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
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
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String> && widget.value == '4:3'));
    await tester.pumpAndSettle();
    expect(aspect, '4:3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Widget page({
    required Future<VodPlayback> Function(VodLesson) load,
    Future<List<VodPptSlide>> Function(int)? loadNotes,
    Future<bool> Function()? login,
    Future<bool> Function()? webVpnRecovery,
    VodLesson? initial,
    _PlaybackHarness? harness,
    VodRepository? repository,
    VodLiveStreamProxy Function(VodRepository)? liveProxyFactory,
    VodWebRtcSession Function(VodWebRtcSource)? webRtcSessionFactory,
    List<VodLesson>? lessons,
    EdgeInsets insets = EdgeInsets.zero,
  }) =>
      MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                disableAnimations: true, padding: insets, viewPadding: insets),
            child: child!),
        home: RecordingPlayerPage(
          course: course,
          lessons: lessons ?? [first, second, unavailable, unrelated],
          initialLesson: initial ?? first,
          skipInitialCatalogLoad: repository is _ProtocolRepository,
          loadPlayback: load,
          repository: repository,
          liveProxyFactory: liveProxyFactory ??
              (repository == null ? null : (_) => _FakeLiveProxy()),
          webRtcSessionFactory: webRtcSessionFactory,
          loadNotes: loadNotes,
          onSessionExpired: login,
          onWebVpnSessionExpired: webVpnRecovery,
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

  void prepareNotesPortrait(WidgetTester tester) {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
  }

  String notesTabLabel(WidgetTester tester) {
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('recording-notes-tab-label')));
    return text.data ?? text.textSpan!.toPlainText();
  }

  const note = VodPptSlide(
    id: 'first-note',
    imageUrl: null,
    position: Duration(seconds: 12),
    text: '当前课次第一张 PPT 的识别文字',
  );
  const anotherNote = VodPptSlide(
    id: 'second-note',
    imageUrl: null,
    position: Duration(seconds: 24),
    text: '当前课次第二张 PPT 的识别文字',
  );

  testWidgets(
      'entry starts requests but defers decoders until the slide settles',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    var playbackRequests = 0;
    final content = (page(
      harness: harness,
      load: (lesson) async {
        playbackRequests++;
        return playback(lesson);
      },
      loadNotes: (_) async => [],
    ) as MaterialApp)
        .home!;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: false),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(PageRouteBuilder<void>(
                    transitionDuration: const Duration(milliseconds: 400),
                    pageBuilder: (context, animation, secondary) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: true),
                      child: content,
                    ),
                    transitionsBuilder: (_, animation, secondary, child) =>
                        SlideTransition(
                      position: animation.drive(Tween<Offset>(
                          begin: const Offset(1, 0), end: Offset.zero)),
                      child: child,
                    ),
                  )),
                  child: const Text('打开课程'),
                ),
              )),
    ));
    await tester.tap(find.text('打开课程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(playbackRequests, 1);
    expect(harness.platforms, isEmpty);
    expect(find.byKey(const ValueKey('course-player-episodes')), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(harness.platforms, isNotEmpty);
    expect(
        find.byKey(const ValueKey('course-player-episodes')), findsOneWidget);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'notes completion leaves video and introduction widgets untouched',
      (tester) async {
    prepareNotesPortrait(tester);
    final pending = Completer<List<VodPptSlide>>();
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async => playback(lesson),
      loadNotes: (_) => pending.future,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final video = tester.widget<Video>(find.byType(Video));
    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    final introduction = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('course-player-episodes')));
    final opens =
        harness.platforms.map((player) => player.opened.length).toList();
    pending.complete([note, anotherNote]);
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 2');
    expect(tester.widget<Video>(find.byType(Video)), same(video));
    expect(tester.widget<TabBarView>(find.byType(TabBarView)), same(tabView));
    expect(
        tester.widget<CustomScrollView>(
            find.byKey(const ValueKey('course-player-episodes'))),
        same(introduction));
    expect(harness.platforms.map((player) => player.opened.length), opens);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'portrait notes tabs show OCR count and preserve playback across taps and swipes',
      (tester) async {
    prepareNotesPortrait(tester);
    final pending = Completer<List<VodPptSlide>>();
    final harness = _PlaybackHarness();
    final noteRequests = <int>[];
    var playbackRequests = 0;
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async {
        playbackRequests++;
        return playback(lesson);
      },
      loadNotes: (id) {
        noteRequests.add(id);
        return pending.future;
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final tabs = find.byType(TabBar);
    final header = find.byKey(const ValueKey('recording-player-header'));
    expect(tester.getSize(tabs), const Size(192, 45));
    expect(tester.getTopLeft(tabs).dx, 0);
    expect(tester.getTopLeft(tabs).dy,
        closeTo(tester.getBottomLeft(header).dy, .01));
    expect(tester.widget<TabBar>(tabs).controller!.index, 0);
    expect(notesTabLabel(tester), '笔记');
    final videoState = tester.state(find.byType(Video));
    final videoController = tester.widget<Video>(find.byType(Video)).controller;

    pending.complete([note, anotherNote]);
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 2');
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(tabs).controller!.index, 1);
    expect(find.text(note.text), findsOneWidget);
    expect(noteRequests, [first.id]);
    final opens =
        harness.platforms.map((player) => player.opened.length).toList();
    for (final player in harness.platforms) {
      player.seeks.clear();
    }
    await tester
        .tap(find.byKey(const ValueKey('recording-note-open-first-note')));
    await tester.pumpAndSettle();
    final seek = find.byKey(const ValueKey('recording-note-seek-first-note'));
    await tester.ensureVisible(seek);
    await tester.tap(seek);
    await tester.pumpAndSettle();
    expect(
        harness.platforms.every((player) => player.seeks.length == 1), isTrue);
    expect(harness.platforms.map((player) => player.seeks.single),
        everyElement(note.position));
    expect(find.byKey(const ValueKey('recording-note-detail-first-note')),
        findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-note-detail-first-note')),
        findsNothing);
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(tabs).controller!.index, 0);
    await tester.drag(find.byType(TabBarView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(tabs).controller!.index, 1);
    await tester.drag(find.byType(TabBarView), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(tabs).controller!.index, 0);
    expect(noteRequests, [first.id]);
    expect(playbackRequests, 1);
    expect(harness.platforms.map((player) => player.opened.length), opens);
    expect(identical(tester.state(find.byType(Video)), videoState), isTrue);
    expect(
        tester.widget<Video>(find.byType(Video)).controller, videoController);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'switching lessons clears notes count and rejects a late previous lesson response',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final oldLessonRequest = Completer<List<VodPptSlide>>();
    final currentLessonRequest = Completer<List<VodPptSlide>>();
    final requested = <int>[];
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async => playback(lesson),
      loadNotes: (id) {
        requested.add(id);
        if (requested.length == 1) return Future.value([note, anotherNote]);
        return id == second.id
            ? oldLessonRequest.future
            : currentLessonRequest.future;
      },
    ));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 2');
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLessonSelected!(second);
    await tester.pump();
    expect(notesTabLabel(tester), '笔记');
    expect(find.text(note.text), findsNothing);
    expect(
        find.byKey(const ValueKey('recording-notes-loading')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLessonSelected!(first);
    await tester.pump();
    expect(notesTabLabel(tester), '笔记');
    currentLessonRequest.complete([note]);
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 1');
    expect(find.text(note.text), findsOneWidget);
    oldLessonRequest.complete([anotherNote, anotherNote]);
    await tester.pumpAndSettle();
    expect(requested, [first.id, second.id, first.id]);
    expect(notesTabLabel(tester), '笔记 1');
    expect(find.text(note.text), findsOneWidget);
    expect(find.text(anotherNote.text), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'live notes show zero and explain that live streams have no notes',
      (tester) async {
    prepareNotesPortrait(tester);
    var noteRequests = 0;
    final live = VodLesson(
        id: first.id,
        teachingClassId: course.teachingClassId,
        name: '直播课次',
        isLive: true,
        isPlayable: true);
    await tester.pumpWidget(page(
      initial: live,
      lessons: [live],
      load: (_) async => throw const VodNetworkException(),
      loadNotes: (_) async {
        noteRequests++;
        return [note];
      },
    ));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 0');
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(find.text('直播没有笔记'), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-error')), findsNothing);
    expect(find.byKey(const ValueKey('recording-notes-loading')), findsNothing);
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(noteRequests, 0);
    expect(notesTabLabel(tester), '笔记 0');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty notes show zero while failed notes omit unknown count',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final requested = <int>[];
    var secondAttempts = 0;
    var playbackRequests = 0;
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async {
        playbackRequests++;
        return playback(lesson);
      },
      loadNotes: (id) async {
        requested.add(id);
        if (id == first.id) return [];
        if (secondAttempts++ == 0) throw const VodNetworkException();
        return [note];
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 0');
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsOneWidget);
    expect(find.text('当前课次暂无 PPT 笔记'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(requested, [first.id, first.id]);
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLessonSelected!(second);
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记');
    expect(find.byKey(const ValueKey('recording-notes-error')), findsOneWidget);
    final opens =
        harness.platforms.map((player) => player.opened.length).toList();
    expect(find.text('重试'), findsNothing);
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 1');
    expect(find.text(note.text), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 1');
    expect(requested, [first.id, first.id, second.id, second.id, second.id]);
    expect(playbackRequests, 2);
    expect(harness.platforms.map((player) => player.opened.length), opens);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (description, accepted) in [
    ('successful empty', true),
    ('rejected', false),
  ]) {
    testWidgets(
        '$description PPT response reaches the correct player notes state',
        (tester) async {
      prepareNotesPortrait(tester);
      final requests = <int>[];
      final httpClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/course/ai/ppt');
        requests.add(int.parse(request.url.queryParameters['courseId']!));
        return http.Response(
          jsonEncode({
            'status': 200,
            'code': null,
            'ok': accepted,
            'dataOk': false,
            'data': null,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(httpClient.close);
      final repository = VodRepository(
        apiClient: VodApiClient(
          httpClient: httpClient,
          headersLoader: (_) async => {},
          uriResolver: (path, query) => Uri.https('vod.example', path, query),
          useWebVpn: false,
        ),
      );
      addTearDown(repository.dispose);
      final harness = _PlaybackHarness();
      var playbackRequests = 0;
      await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async {
          playbackRequests++;
          return playback(lesson);
        },
        loadNotes: (id) => repository.loadPptSlides(id, forceRefresh: true),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
      await tester.pumpAndSettle();
      expect(notesTabLabel(tester), accepted ? '笔记 0' : '笔记');
      expect(find.byKey(const ValueKey('recording-notes-empty')),
          accepted ? findsOneWidget : findsNothing);
      expect(find.byKey(const ValueKey('recording-notes-error')),
          accepted ? findsNothing : findsOneWidget);
      expect(requests, [first.id]);
      final opens =
          harness.platforms.map((player) => player.opened.length).toList();

      await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
          const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(requests, [first.id, first.id]);
      expect(notesTabLabel(tester), accepted ? '笔记 0' : '笔记');
      expect(find.byKey(const ValueKey('recording-notes-empty')),
          accepted ? findsOneWidget : findsNothing);
      expect(find.byKey(const ValueKey('recording-notes-error')),
          accepted ? findsNothing : findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(playbackRequests, 1);
      expect(harness.platforms.map((player) => player.opened.length), opens);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a pending pull refresh cannot overwrite a new lesson',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingRefresh = Completer<List<VodPptSlide>>();
    var firstRequests = 0;
    await tester.pumpWidget(page(
      harness: _PlaybackHarness(),
      load: (lesson) async => playback(lesson),
      loadNotes: (id) {
        if (id == second.id) return Future.value([anotherNote]);
        if (firstRequests++ == 0) return Future.value([note]);
        return pendingRefresh.future;
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(firstRequests, 2);
    expect(find.text(note.text), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-loading')), findsNothing);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLessonSelected!(second);
    await tester.pump(const Duration(milliseconds: 300));
    pendingRefresh.complete([note]);
    await tester.pumpAndSettle();
    expect(find.text(anotherNote.text), findsOneWidget);
    expect(find.text(note.text), findsNothing);
    expect(notesTabLabel(tester), '笔记 1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unavailable notes loader is an error rather than empty notes',
      (tester) async {
    prepareNotesPortrait(tester);
    await tester.pumpWidget(page(
      harness: _PlaybackHarness(),
      load: (lesson) async => playback(lesson),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-notes-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsNothing);
    expect(notesTabLabel(tester), '笔记');
    expect(find.text('暂时无法加载这节课的 PPT 笔记，请稍后下拉重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failure in <(VodApiException, String)>[
    (const VodNetworkException(), '暂时无法加载这节课的 PPT 笔记，请稍后下拉重试'),
    (const VodSessionExpiredException(), '校园账户登录已失效，请重新进入录播平台后重试'),
    (const VodPermissionException(), '平台暂未允许读取这节课的 PPT 笔记，请稍后下拉重试'),
    (const VodInvalidResponseException(), '平台返回的 PPT 笔记数据异常，请稍后下拉重试'),
  ]) {
    testWidgets('${failure.$1.runtimeType} is not displayed as no notes',
        (tester) async {
      prepareNotesPortrait(tester);
      await tester.pumpWidget(page(
        harness: _PlaybackHarness(),
        load: (lesson) async => playback(lesson),
        loadNotes: (_) async => throw failure.$1,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('recording-notes-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-notes-empty')), findsNothing);
      expect(find.text(failure.$2), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(notesTabLabel(tester), '笔记');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed refresh replaces a previous empty result with an error',
      (tester) async {
    prepareNotesPortrait(tester);
    var requests = 0;
    await tester.pumpWidget(page(
      harness: _PlaybackHarness(),
      load: (lesson) async => playback(lesson),
      loadNotes: (_) async {
        if (++requests == 2) throw const VodNetworkException();
        return [];
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsOneWidget);
    expect(notesTabLabel(tester), '笔记 0');
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-notes-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsNothing);
    expect(notesTabLabel(tester), '笔记');
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(requests, 3);
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-error')), findsNothing);
    expect(notesTabLabel(tester), '笔记 0');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty notes stay visible while pull refresh is pending',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingRefresh = Completer<List<VodPptSlide>>();
    var requests = 0;
    await tester.pumpWidget(page(
      harness: _PlaybackHarness(),
      load: (lesson) async => playback(lesson),
      loadNotes: (_) =>
          ++requests == 1 ? Future.value([]) : pendingRefresh.future,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(notesTabLabel(tester), '笔记 0');
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 2);
    expect(find.byKey(const ValueKey('recording-notes-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-loading')), findsNothing);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(notesTabLabel(tester), '笔记 0');
    pendingRefresh.complete([note]);
    await tester.pumpAndSettle();
    expect(find.text(note.text), findsOneWidget);
    expect(notesTabLabel(tester), '笔记 1');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed pull refresh retains existing notes and reports failure',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingRefresh = Completer<List<VodPptSlide>>();
    var requests = 0;
    await tester.pumpWidget(page(
      harness: _PlaybackHarness(),
      load: (lesson) async => playback(lesson),
      loadNotes: (_) =>
          ++requests == 1 ? Future.value([note]) : pendingRefresh.future,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(requests, 2);
    expect(find.text(note.text), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-loading')), findsNothing);
    expect(notesTabLabel(tester), '笔记 1');
    pendingRefresh.completeError(const VodNetworkException());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(note.text), findsOneWidget);
    expect(notesTabLabel(tester), '笔记 1');
    expect(find.text('暂时无法加载这节课的 PPT 笔记，请稍后下拉重试'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'session recovery automatically reloads notes for the same lesson',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    var playbackRequests = 0;
    var noteRequests = 0;
    var loginRequests = 0;
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async {
        if (playbackRequests++ == 0) {
          throw const VodSessionExpiredException();
        }
        return playback(lesson);
      },
      loadNotes: (_) async {
        if (noteRequests++ == 0) {
          throw const VodSessionExpiredException();
        }
        return [note];
      },
      login: () async {
        loginRequests++;
        return true;
      },
    ));
    await tester.pumpAndSettle();
    expect(playbackRequests, 1);
    expect(noteRequests, 1);
    expect(loginRequests, 0);
    expect(notesTabLabel(tester), '笔记');
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-notes-error')), findsOneWidget);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(loginRequests, 1);
    expect(playbackRequests, 2);
    expect(noteRequests, 2);
    expect(notesTabLabel(tester), '笔记 1');
    expect(find.text(note.text), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-notes-error')), findsNothing);
    expect(harness.platforms, hasLength(2));
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving the player safely ignores pending notes completion',
      (tester) async {
    prepareNotesPortrait(tester);
    final pending = Completer<List<VodPptSlide>>();
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
      harness: harness,
      load: (lesson) async => playback(lesson),
      loadNotes: (_) => pending.future,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        find.byKey(const ValueKey('recording-notes-loading')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete([note]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  for (final webVpn in [false, true]) {
    testWidgets(
        '${webVpn ? 'WebVPN' : 'campus'} recovery uses its own callback and retries only once',
        (tester) async {
      var campusRecoveries = 0;
      var webVpnRecoveries = 0;
      var playbackCalls = 0;
      var restored = false;
      await tester.pumpWidget(page(
        load: (_) async {
          playbackCalls++;
          if (webVpn) throw const VodWebVpnSessionExpiredException();
          throw const VodSessionExpiredException();
        },
        login: () async {
          campusRecoveries++;
          return restored;
        },
        webVpnRecovery: () async {
          webVpnRecoveries++;
          return restored;
        },
      ));
      await tester.pumpAndSettle();
      final action = find.text(webVpn ? '恢复连接' : '重新登录');
      expect(campusRecoveries, 0);
      expect(webVpnRecoveries, 0);
      expect(playbackCalls, 1);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(campusRecoveries, webVpn ? 0 : 1);
      expect(webVpnRecoveries, webVpn ? 1 : 0);
      expect(playbackCalls, 1);
      restored = true;
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(campusRecoveries, webVpn ? 0 : 2);
      expect(webVpnRecoveries, webVpn ? 2 : 0);
      expect(playbackCalls, 2);
      expect(action, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(playbackCalls, 2);
      expect(campusRecoveries, webVpn ? 0 : 2);
      expect(webVpnRecoveries, webVpn ? 2 : 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('WebVPN recovery is available without a campus login callback',
      (tester) async {
    var recoveryCalls = 0;
    var playbackCalls = 0;
    await tester.pumpWidget(page(
      load: (_) async {
        playbackCalls++;
        throw const VodWebVpnSessionExpiredException();
      },
      webVpnRecovery: () async {
        recoveryCalls++;
        return true;
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复连接'));
    await tester.pumpAndSettle();
    expect(recoveryCalls, 1);
    expect(playbackCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('campus recovery never uses the WebVPN callback as a fallback',
      (tester) async {
    var recoveryCalls = 0;
    await tester.pumpWidget(page(
      load: (_) async => throw const VodSessionExpiredException(),
      webVpnRecovery: () async {
        recoveryCalls++;
        return true;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('校园账户登录已失效，请重新登录。'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    expect(find.text('恢复连接'), findsNothing);
    expect(recoveryCalls, 0);
    expect(tester.takeException(), isNull);
  });

  for (final protocol in VodLiveProtocol.values) {
    testWidgets('saved ${protocol.name} is used for the first live request',
        (tester) async {
      prepareNotesPortrait(tester);
      SharedPreferences.setMockInitialValues({
        'vod.player.defaultLiveProtocol': protocol.name,
      });
      final harness = _PlaybackHarness();
      final repository = _ProtocolRepository()..allowPlayback = true;
      final lesson = VodLesson(
          id: 106,
          teachingClassId: 10,
          name: course.name,
          isLive: true,
          isPlayable: true);
      var hlsRequests = 0;
      await tester.pumpWidget(page(
        initial: lesson,
        lessons: [lesson],
        harness: harness,
        repository: repository,
        webRtcSessionFactory: _FakeRtcSession.new,
        loadNotes: (_) async => [],
        load: (selected) async {
          hlsRequests++;
          return playback(selected);
        },
      ));
      await tester.pumpAndSettle();
      var controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.liveProtocol, protocol);
      expect(hlsRequests, protocol == VodLiveProtocol.hls ? 1 : 0);
      expect(repository.requested,
          protocol == VodLiveProtocol.hls ? isEmpty : [protocol]);
      final next = VodLiveProtocol.values[(protocol.index + 1) % 3];
      controls.onPreferencesChanged!(
          controls.preferences.copyWith(defaultLiveProtocol: next));
      await tester.pumpAndSettle();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.liveProtocol, protocol,
          reason: 'Changing a default must not interrupt the active stream');
      expect(hlsRequests + repository.requested.length, 1);
      expect(
          (await SharedPreferences.getInstance())
              .getString('vod.player.defaultLiveProtocol'),
          next.name);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final protocol in <VodLiveProtocol?>[null, ...VodLiveProtocol.values]) {
    final label = protocol?.name ?? 'recording';
    testWidgets(
        '$label ignores visible focus loss and suspends once in background',
        (tester) async {
      prepareNotesPortrait(tester);
      SharedPreferences.setMockInitialValues({
        'vod.player.defaultLiveProtocol': protocol?.name ?? 'hls',
      });
      final harness = _PlaybackHarness();
      final repository = _ProtocolRepository()..allowPlayback = true;
      final sessions = <_FakeRtcSession>[];
      final lesson = protocol == null
          ? first
          : VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isLive: true,
              isPlayable: true);
      var requests = 0;
      await tester.pumpWidget(page(
        initial: lesson,
        lessons: [lesson],
        harness: harness,
        repository: protocol == null ? null : repository,
        webRtcSessionFactory: (source) {
          final session = _FakeRtcSession(source);
          sessions.add(session);
          return session;
        },
        loadNotes: (_) async => [],
        load: (selected) async {
          requests++;
          return playback(selected);
        },
      ));
      await tester.pumpAndSettle();
      final video = tester.widget<Video>(find.byType(Video).first);
      expect(video.pauseUponEnteringBackgroundMode, isFalse);
      expect(video.resumeUponEnteringForegroundMode, isFalse);
      final beforePauses = harness.platforms.map((p) => p.pauses).toList();
      final observer = tester.state(find.byType(RecordingPlayerPage))
          as WidgetsBindingObserver;
      final initialRequests = requests + repository.requested.length;
      observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(harness.platforms.map((p) => p.pauses), beforePauses);
      expect(sessions.every((s) => s.pauses == 0), isTrue);
      expect(requests + repository.requested.length, initialRequests);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive
      ]) {
        observer.didChangeAppLifecycleState(state);
        await tester.pump();
      }
      expect(harness.platforms.map((p) => p.pauses),
          beforePauses.map((count) => count + 1));
      expect(sessions.every((s) => s.pauses == 1), isTrue);
      expect(requests + repository.requested.length, initialRequests);
      expect(harness.platforms.every((p) => !p.state.playing), isTrue);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(requests + repository.requested.length,
          initialRequests + (protocol == null ? 0 : 1));
      if (protocol == null) {
        expect(harness.platforms.every((p) => p.state.playing), isTrue);
        expect(harness.platforms.every((p) => p.opened.length == 1), isTrue);
      } else if (protocol == VodLiveProtocol.webRtc) {
        expect(sessions.first.disposed, isTrue);
        expect(sessions.last.state.value, VodWebRtcState.playing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final protocol in VodLiveProtocol.values) {
    testWidgets(
        '${protocol.name} resumes after repeated returns and a late pause',
        (tester) async {
      prepareNotesPortrait(tester);
      SharedPreferences.setMockInitialValues({
        'vod.player.defaultLiveProtocol': protocol.name,
      });
      final harness = _PlaybackHarness();
      final repository = _ProtocolRepository()..allowPlayback = true;
      final lesson = VodLesson(
          id: 106,
          teachingClassId: 10,
          name: course.name,
          isLive: true,
          isPlayable: true);
      var hlsRequests = 0;
      await tester.pumpWidget(page(
        initial: lesson,
        lessons: [lesson],
        harness: harness,
        repository: repository,
        loadNotes: (_) async => [],
        webRtcSessionFactory: _FakeRtcSession.new,
        load: (selected) async {
          hlsRequests++;
          return playback(selected);
        },
      ));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      for (final platform in harness.platforms) {
        platform.pauseGate = gate;
      }
      final observer = tester.state(find.byType(RecordingPlayerPage))
          as WidgetsBindingObserver;
      for (var i = 0; i < 3; i++) {
        observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
      }
      gate.complete();
      await tester.pumpAndSettle();
      final controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.failure, isNull);
      expect(
          protocol == VodLiveProtocol.webRtc
              ? controls.livePlaying
              : harness.platforms.first.state.playing,
          isTrue);
      expect(hlsRequests + repository.requested.length, 2,
          reason: 'Only the final return may reconnect this stream');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a default changed on a recording applies when entering live',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    final live = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isLive: true,
        isPlayable: true);
    await tester.pumpWidget(page(
      initial: first,
      lessons: [first, live],
      harness: harness,
      repository: repository,
      loadNotes: (_) async => [],
      load: (selected) async => playback(selected),
    ));
    await tester.pumpAndSettle();
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onPreferencesChanged!(controls.preferences
        .copyWith(defaultLiveProtocol: VodLiveProtocol.flv));
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onLessonSelected!(live);
    await tester.pumpAndSettle();
    expect(repository.requested, [VodLiveProtocol.flv]);
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .liveProtocol,
        VodLiveProtocol.flv);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final secondary in [false, true]) {
    testWidgets(
        'late ${secondary ? 'secondary' : 'primary'} open after timeout '
        'cannot restart in the background', (tester) async {
      prepareNotesPortrait(tester);
      final gate = Completer<void>();
      final harness = _PlaybackHarness(
          primaryOpen: secondary ? null : gate,
          secondaryOpen: secondary ? gate : null);
      await tester.pumpWidget(
          page(harness: harness, load: (selected) async => playback(selected)));
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      final opening = harness.platforms[secondary ? 1 : 0];
      expect(opening.opened, hasLength(1));
      await tester.pump(const Duration(seconds: 26));
      await tester.pump();
      final observer = tester.state(find.byType(RecordingPlayerPage))
          as WidgetsBindingObserver;
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(opening.state.playing, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'manual live pause survives return and later play keeps heartbeats',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isLive: true,
        isPlayable: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      loadNotes: (_) async => [],
      load: (selected) async => playback(selected),
    ));
    await tester.pumpAndSettle();
    await harness.platforms.first.pause();
    await tester.pumpAndSettle();
    final requests = repository.heartbeats;
    final observer = tester.state(find.byType(RecordingPlayerPage))
        as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(harness.platforms.first.state.playing, isFalse);
    expect(repository.heartbeats, requests);
    await harness.platforms.first.play();
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(repository.heartbeats, requests + 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recording resumes after a slow pause and repeated quick returns',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (selected) async => playback(selected)));
    await tester.pumpAndSettle();
    final main = harness.platforms.first;
    final originalPosition = main.state.position;
    await main.setRate(1.5);
    await tester.pumpAndSettle();
    final pauseGate = Completer<void>();
    for (final player in harness.platforms) {
      player.pauseGate = pauseGate;
    }
    final observer = tester.state(find.byType(RecordingPlayerPage))
        as WidgetsBindingObserver;
    for (var i = 0; i < 3; i++) {
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
    }
    pauseGate.complete();
    await tester.pumpAndSettle();
    expect(harness.platforms.every((p) => p.state.playing), isTrue);
    expect(main.state.position, originalPosition);
    expect(main.state.rate, 1.5);
    expect(harness.platforms.every((p) => p.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final returnBeforeOpen in [false, true]) {
    testWidgets(
        'recording native open respects background and return '
        'beforeOpen=$returnBeforeOpen', (tester) async {
      prepareNotesPortrait(tester);
      final openGate = Completer<void>();
      final harness = _PlaybackHarness(primaryOpen: openGate);
      await tester.pumpWidget(
          page(harness: harness, load: (selected) async => playback(selected)));
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      expect(harness.platforms.first.opened, hasLength(1));
      final observer = tester.state(find.byType(RecordingPlayerPage))
          as WidgetsBindingObserver;
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      if (returnBeforeOpen) {
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
      }
      openGate.complete();
      await tester.pumpAndSettle();
      expect(harness.platforms.first.state.playing, returnBeforeOpen);
      if (!returnBeforeOpen) {
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
      }
      expect(harness.platforms.every((p) => p.state.playing), isTrue);
      expect(harness.platforms.every((p) => p.opened.length == 1), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('manually paused recording stays paused after returning',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (selected) async => playback(selected)));
    await tester.pumpAndSettle();
    await harness.platforms.first.pause();
    await tester.pumpAndSettle();
    final observer = tester.state(find.byType(RecordingPlayerPage))
        as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(harness.platforms.every((p) => !p.state.playing), isTrue);
    expect(harness.platforms.every((p) => p.opened.length == 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final live in [false, true]) {
    testWidgets(
        '${live ? 'live' : 'recording'} loading keeps its foreground resume intent',
        (tester) async {
      prepareNotesPortrait(tester);
      final harness = _PlaybackHarness();
      final pending = Completer<VodPlayback>();
      final lesson = live
          ? VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isLive: true,
              isPlayable: true)
          : first;
      var requests = 0;
      await tester.pumpWidget(page(
        initial: lesson,
        harness: harness,
        load: (selected) {
          requests++;
          return requests == 1
              ? pending.future
              : Future.value(playback(selected));
        },
      ));
      await tester.pump();
      expect(requests, 1);
      expect(harness.platforms, isEmpty);
      final observer = tester.state(find.byType(RecordingPlayerPage))
          as WidgetsBindingObserver;
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests, live ? 2 : 1);

      pending.complete(playback(lesson));
      await tester.pumpAndSettle();
      expect(harness.platforms, hasLength(2));
      expect(harness.platforms.every((player) => player.opened.length == 1),
          isTrue);
      expect(harness.platforms.every((player) => player.state.playing), isTrue);
      expect(requests, live ? 2 : 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a manually paused live lesson stays paused after foregrounding',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isLive: true,
        isPlayable: true);
    var requests = 0;
    await tester.pumpWidget(page(
      initial: lesson,
      harness: harness,
      load: (selected) async {
        requests++;
        return playback(selected);
      },
    ));
    await tester.pumpAndSettle();
    for (final platform in harness.platforms) {
      await platform.pause();
    }
    await tester.pumpAndSettle();
    final observer = tester.state(find.byType(RecordingPlayerPage))
        as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(harness.platforms.every((player) => !player.state.playing), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live playback uses the detail window after the lesson has ended',
      (tester) async {
    prepareNotesPortrait(tester);
    final now = DateTime.now();
    final lesson = VodLesson(
      id: 106,
      teachingClassId: 10,
      name: course.name,
      isLive: true,
      isPlayable: true,
      endTime: now.subtract(const Duration(minutes: 1)),
    );
    final harness = _PlaybackHarness();
    var requests = 0;
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      load: (selected) async {
        requests++;
        return VodPlayback(
          lessonId: selected.id,
          teachingClassId: 10,
          title: course.name,
          isLive: true,
          liveEndTime: now.add(const Duration(minutes: 5)),
          views: playback(selected).views,
        );
      },
    ));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(harness.platforms, isNotEmpty);
    expect(harness.platforms.first.state.playing, isTrue);
    expect(find.text('这节课当前暂无可用的播放资源'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final live in [false, true]) {
    testWidgets(
        '${live ? 'live' : 'recording'} portrait scrolling collapses only while paused without reopening',
        (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final harness = _PlaybackHarness();
      final initial = live
          ? VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isLive: true,
              isPlayable: true)
          : first;
      var loads = 0;
      await tester.pumpWidget(page(
        initial: initial,
        lessons: [
          initial,
          for (var index = 0; index < 30; index++)
            VodLesson(
                id: 200 + index,
                teachingClassId: 10,
                name: course.name,
                beginTime: DateTime(2026, 8, index + 1),
                isPlayable: true),
        ],
        harness: harness,
        insets: const EdgeInsets.only(top: 44, bottom: 34),
        load: (lesson) async {
          loads++;
          return playback(lesson);
        },
      ));
      await tester.pumpAndSettle();
      final videoState = tester.state(find.byType(Video));
      final host = tester.widget<Video>(find.byType(Video)).controller;
      final platforms = harness.platforms;
      tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .onSwapViews!();
      await tester.pumpAndSettle();
      final swappedControls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(swappedControls.selectedView, 1);
      final pauses = platforms.map((player) => player.pauses).toList();
      final header = find.byKey(const ValueKey('recording-player-header'));
      final list = find.byKey(const ValueKey('course-player-episodes'));
      expect(tester.getTopLeft(header).dy, 44);
      expect(tester.getSize(header).height, closeTo(393 * 9 / 16, .01));
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getSize(header).height, closeTo(393 * 9 / 16, .01));
      expect(platforms.map((player) => player.pauses), pauses);
      await (swappedControls.timelinePlayer ?? swappedControls.player).pause();
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getSize(header).height, kToolbarHeight);
      expect(
          tester
              .widget<Opacity>(
                  find.byKey(const ValueKey('recording-collapsed-toolbar')))
              .opacity,
          1);
      final pausedCounts = platforms.map((player) => player.pauses).toList();
      await tester.tap(find.byKey(const ValueKey('recording-resume-player')));
      await tester.pumpAndSettle();
      expect(tester.getSize(header).height, closeTo(393 * 9 / 16, .01));
      expect(platforms.every((player) => player.state.playing), isTrue);
      expect(platforms.map((player) => player.pauses), pausedCounts);
      expect(loads, 1);
      expect(platforms, hasLength(2));
      expect(platforms.every((player) => player.opened.length == 1), isTrue);
      expect(identical(tester.state(find.byType(Video)), videoState), isTrue);
      expect(
          identical(tester.widget<Video>(find.byType(Video)).controller, host),
          isTrue);
      final controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      await controls.state.enterFullscreen();
      await tester.pumpAndSettle();
      await controls.state.exitFullscreen();
      await tester.pumpAndSettle();
      expect(platforms.map((player) => player.pauses), pausedCounts);
      expect(loads, 1);
      expect(platforms.every((player) => player.opened.length == 1), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'fullscreen round trips retain both tab scrolls and an open note detail',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    var playbackRequests = 0;
    var noteRequests = 0;
    final slides = List.generate(
      40,
      (index) => VodPptSlide(
        id: 'retained-$index',
        imageUrl: null,
        position: Duration(seconds: index * 30),
        text: List.generate(100, (line) => '第 $index 页的第 $line 行完整笔记正文。')
            .join('\n'),
      ),
    );
    await tester.pumpWidget(page(
      harness: harness,
      lessons: [
        first,
        for (var index = 0; index < 60; index++)
          VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: course.name,
            beginTime: DateTime(2026, 8, index + 1),
            isPlayable: true,
          ),
      ],
      load: (lesson) async {
        playbackRequests++;
        return playback(lesson);
      },
      loadNotes: (_) async {
        noteRequests++;
        return slides;
      },
    ));
    await tester.pumpAndSettle();

    ScrollPosition scrollPosition(Finder view) => tester
        .state<ScrollableState>(
          find.descendant(of: view, matching: find.byType(Scrollable)).first,
        )
        .position;
    final introduction = find.byKey(const ValueKey('course-player-episodes'));
    await tester.drag(introduction, const Offset(0, -650));
    await tester.pumpAndSettle();
    final introductionPosition = scrollPosition(introduction);
    final introductionOffset = introductionPosition.pixels;
    expect(introductionOffset, greaterThan(100));

    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    final notes = find.byKey(const ValueKey('recording-notes-scroll'));
    await tester.drag(notes, const Offset(0, -450));
    await tester.pumpAndSettle();
    final notesPosition = scrollPosition(notes);
    final notesOffset = notesPosition.pixels;
    expect(notesOffset, greaterThan(100));
    final selectedSlide = slides.firstWhere((slide) => find
        .byKey(ValueKey('recording-note-open-${slide.id}'))
        .hitTestable()
        .evaluate()
        .isNotEmpty);
    await tester
        .tap(find.byKey(ValueKey('recording-note-open-${selectedSlide.id}')));
    await tester.pumpAndSettle();
    final detailScroll = find
        .byKey(ValueKey('recording-note-detail-scroll-${selectedSlide.id}'));
    await tester.drag(detailScroll, const Offset(0, -620));
    await tester.pumpAndSettle();
    final detailPosition = scrollPosition(detailScroll);
    final detailOffset = detailPosition.pixels;
    expect(detailOffset, greaterThan(100));
    final portraitLayout = tester.state(find.byType(RecordingPlayerLayout));
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    final videoState = tester.state(find.byType(Video));
    final opens =
        harness.platforms.map((player) => player.opened.length).toList();
    final pauses = harness.platforms.map((player) => player.pauses).toList();

    // Cover both the native fullscreen route and the actual orientation resize.
    for (var roundTrip = 0; roundTrip < 2; roundTrip++) {
      await tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .state
          .enterFullscreen();
      tester.view.physicalSize = const Size(852, 393);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(RecordingPlayerLayout, skipOffstage: false)),
        same(portraitLayout),
      );
      expect(detailPosition.pixels, closeTo(detailOffset, .01));
      expect(tabs.index, 1);
      await tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .state
          .exitFullscreen();
      tester.view.physicalSize = const Size(393, 852);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('recording-note-detail-${selectedSlide.id}')),
          findsOneWidget);
      expect(scrollPosition(detailScroll), same(detailPosition));
      expect(detailPosition.pixels, closeTo(detailOffset, .01));
      expect(notesPosition.pixels, closeTo(notesOffset, .01));
      expect(tabs.index, 1);
      expect(tester.state(find.byType(Video)), same(videoState));
    }

    // Back closes the original detail history entry, then the notes list and
    // introduction reveal their own retained scroll positions.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-note-detail-${selectedSlide.id}')),
        findsNothing);
    expect(scrollPosition(notes), same(notesPosition));
    expect(notesPosition.pixels, closeTo(notesOffset, .01));
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    expect(
        scrollPosition(introduction).pixels, closeTo(introductionOffset, .01));
    expect(playbackRequests, 1);
    expect(noteRequests, 1);
    expect(harness.platforms.map((player) => player.opened.length), opens);
    expect(harness.platforms.map((player) => player.pauses), pauses);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'changing lessons in fullscreen clears only the previous note details',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final noteRequests = <int>[];
    await tester.pumpWidget(page(
      harness: harness,
      lessons: [first, second],
      load: (lesson) async => playback(lesson),
      loadNotes: (id) async {
        noteRequests.add(id);
        return id == first.id ? [note] : [anotherNote];
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-notes-tab-label')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('recording-note-open-first-note')));
    await tester.pumpAndSettle();
    final portraitLayout = tester.state(find.byType(RecordingPlayerLayout));
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .enterFullscreen();
    tester.view.physicalSize = const Size(852, 393);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('fullscreen-lesson-${second.id}')));
    await tester.pumpAndSettle();
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .exitFullscreen();
    tester.view.physicalSize = const Size(393, 852);
    await tester.pumpAndSettle();
    expect(
        tester.state(find.byType(RecordingPlayerLayout)), same(portraitLayout));
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(find.byKey(const ValueKey('recording-note-detail-first-note')),
        findsNothing);
    expect(find.byKey(const ValueKey('recording-note-open-second-note')),
        findsOneWidget);
    expect(noteRequests, [first.id, second.id]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'fullscreen size changes preserve the video host and both streams',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    final hostState = tester.state(find.byType(Video));
    final hostController = tester.widget<Video>(find.byType(Video)).controller;
    final pauses = harness.platforms.map((player) => player.pauses).toList();
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .enterFullscreen();
    tester.view.physicalSize = const Size(852, 393);
    await tester.pumpAndSettle();
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .exitFullscreen();
    tester.view.physicalSize = const Size(393, 852);
    await tester.pumpAndSettle();
    expect(identical(tester.state(find.byType(Video)), hostState), isTrue);
    expect(tester.widget<Video>(find.byType(Video)).controller, hostController);
    expect(loads, 1);
    expect(harness.platforms, hasLength(2));
    expect(harness.platforms.map((player) => player.pauses), pauses);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'large episode groups only lay out visible rows and still navigate',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessons = List.generate(
        240,
        (index) => VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: course.name,
            isPlayable: true,
            beginTime: DateTime(2026, 9, 1, 8).add(Duration(minutes: index))));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lessons[120],
        lessons: lessons,
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingEpisodeTile).evaluate().length, lessThan(20));
    expect(find.byKey(const ValueKey('recording-lesson-320')), findsNothing);
    await tester.drag(find.byKey(const ValueKey('course-player-episodes')),
        const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingEpisodeTile).evaluate().length, lessThan(20));
    await tester.tap(find.byTooltip('跳至底部'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-200')), findsOneWidget);
    await tester.tap(find.byTooltip('跳至当前'));
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('recording-lesson-320'));
    expect(current, findsOneWidget);
    expect(tester.getTopLeft(current).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomLeft(current).dy, lessThanOrEqualTo(852));
    expect(find.byType(RecordingEpisodeTile).evaluate().length, lessThan(20));
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'episode toolbar stays pinned and navigates and reverses the list',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessons = List.generate(
        30,
        (index) => VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: course.name,
            isPlayable: true,
            beginTime: DateTime(2026, 9, 1).add(Duration(days: index))));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lessons[15],
        lessons: lessons,
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('course-player-episodes'));
    final toolbar = find.byKey(const ValueKey('recording-episode-header'));
    expect(find.text('选集'), findsOneWidget);
    final separators = tester
        .widgetList<Divider>(
            find.descendant(of: list, matching: find.byType(Divider)))
        .toList();
    expect(separators.length, lessThan(lessons.length - 1));
    expect(separators, isNotEmpty);
    for (final separator in separators) {
      expect(separator.indent, 16);
      expect(separator.endIndent, 16);
    }
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('recording-lesson-229')),
            matching: find.text('30')),
        findsOneWidget);
    await tester.drag(list, const Offset(0, -700));
    await tester.pumpAndSettle();
    final pinnedTop = tester.getTopLeft(toolbar).dy;
    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar).dy, closeTo(pinnedTop, 1));
    expect(tester.widget<Material>(toolbar).elevation, greaterThan(0));
    await tester.tap(find.byTooltip('跳至底部'));
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('recording-lesson-200'));
    expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(852));
    await tester.tap(find.byTooltip('跳至当前'));
    await tester.pumpAndSettle();
    final current = find.byKey(const ValueKey('recording-lesson-215'));
    expect(tester.getTopLeft(current).dy, greaterThanOrEqualTo(pinnedTop));
    expect(tester.getBottomLeft(current).dy, lessThanOrEqualTo(852));
    await tester.tap(find.byTooltip('切换为正序'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('recording-lesson-215')),
            matching: find.text('16')),
        findsOneWidget);
    await tester.tap(find.byTooltip('跳至顶部'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(last).dy, greaterThanOrEqualTo(pinnedTop));
    expect(find.byKey(const ValueKey('recording-lesson-229')), findsNothing);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'episode month headers pin below the toolbar and follow the active group',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessons = List.generate(
        30,
        (index) => VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: course.name,
            isPlayable: true,
            beginTime: DateTime(2026, 9 + index ~/ 10, 1 + index % 10)));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lessons[15],
        lessons: lessons,
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final toolbar = find.byKey(const ValueKey('recording-episode-header'));
    final september = find.byKey(
        const ValueKey('recording-episode-month:(2026, 9)'),
        skipOffstage: false);
    final october = find.byKey(
        const ValueKey('recording-episode-month:(2026, 10)'),
        skipOffstage: false);
    final november = find.byKey(
        const ValueKey('recording-episode-month:(2026, 11)'),
        skipOffstage: false);
    expect(find.descendant(of: november, matching: find.text('2026年11月')),
        findsOneWidget);
    expect(tester.getSize(november).height, 34);
    expect(
        tester
            .widgetList<SliverMainAxisGroup>(
                find.byType(SliverMainAxisGroup, skipOffstage: false))
            .map((group) => group.key),
        [
          const ValueKey('recording-episode-month-group:(2026, 11)'),
          const ValueKey('recording-episode-month-group:(2026, 10)'),
          const ValueKey('recording-episode-month-group:(2026, 9)'),
        ]);
    final novemberDelegate = tester.widget<SliverPersistentHeader>(find
        .ancestor(of: november, matching: find.byType(SliverPersistentHeader)));
    expect(novemberDelegate.pinned, isTrue);
    expect(
        find.ancestor(of: november, matching: find.byType(SliverMainAxisGroup)),
        findsOneWidget);

    await tester.tap(find.byTooltip('跳至底部'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(september).dy,
        closeTo(tester.getBottomLeft(toolbar).dy, 1));
    expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('recording-lesson-200')))
            .dy,
        lessThanOrEqualTo(852));

    await tester.tap(find.byTooltip('跳至当前'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(october).dy,
        closeTo(tester.getBottomLeft(toolbar).dy, 1));
    expect(tester.getBottomLeft(november).dy,
        lessThanOrEqualTo(tester.getTopLeft(october).dy));
    final current = find.byKey(const ValueKey('recording-lesson-215'));
    expect(tester.getTopLeft(current).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(october).dy));

    await tester.tap(find.byTooltip('切换为正序'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('跳至顶部'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<SliverMainAxisGroup>(
                find.byType(SliverMainAxisGroup, skipOffstage: false))
            .map((group) => group.key),
        [
          const ValueKey('recording-episode-month-group:(2026, 9)'),
          const ValueKey('recording-episode-month-group:(2026, 10)'),
          const ValueKey('recording-episode-month-group:(2026, 11)'),
        ]);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('recording-lesson-200'),
                skipOffstage: false),
            matching: find.text('1', skipOffstage: false),
            skipOffstage: false),
        findsOneWidget);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('episodes without dates retain a separate month group',
      (tester) async {
    final dated = VodLesson(
        id: 201,
        teachingClassId: 10,
        name: course.name,
        beginTime: DateTime(2026, 10, 1),
        isPlayable: true);
    final undated = VodLesson(
        id: 202, teachingClassId: 10, name: course.name, isPlayable: true);
    await tester.pumpWidget(page(
        initial: dated,
        lessons: [dated, undated],
        load: (_) async => throw const VodInvalidResponseException()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find
        .byKey(const ValueKey('recording-lesson-202'), skipOffstage: false));
    await tester.pumpAndSettle();
    final unknown = find.byKey(const ValueKey('recording-episode-month:null'),
        skipOffstage: false);
    expect(find.descendant(of: unknown, matching: find.text('日期未知')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-201')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-202')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'classroom selection stays pinned and numbers episodes within each room',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessons = List.generate(
        30,
        (index) => VodLesson(
            id: 200 + index,
            teachingClassId: 10,
            name: course.name,
            isPlayable: true,
            classroom: index.isEven ? 'A101' : 'B202',
            beginTime: DateTime(2026, 9, 1).add(Duration(days: index))));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lessons[15],
        lessons: lessons,
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('recording-episode-header'));
    final classrooms = find.byKey(const ValueKey('recording-classroom-filter'));
    final roomB = find.byKey(const ValueKey('recording-classroom:B202'));
    expect(tester.widget<ChoiceChip>(roomB).selected, isTrue);
    final roomA = find.byKey(const ValueKey('recording-classroom:A101'));
    expect(tester.widget<ChoiceChip>(roomA).selected, isFalse);
    await tester.tap(roomA);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(roomB).selected, isFalse);
    expect(tester.widget<ChoiceChip>(roomA).selected, isTrue);
    expect(find.byKey(const ValueKey('recording-lesson-215')), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('recording-lesson-228')),
            matching: find.text('15')),
        findsOneWidget);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    await tester.tap(roomA);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(roomA).selected, isTrue);
    expect(find.byKey(const ValueKey('recording-lesson-228')), findsOneWidget);
    expect(find.text('没有符合教室筛选的课次'), findsNothing);
    await tester.tap(find.byTooltip('跳至当前'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('当前课次不在教室筛选结果中'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-215')), findsOneWidget);
    expect(tester.widget<ChoiceChip>(roomB).selected, isTrue);
    expect(tester.widget<ChoiceChip>(roomA).selected, isFalse);
    final list = find.byKey(const ValueKey('course-player-episodes'));
    await tester.drag(list, const Offset(0, -700));
    await tester.pumpAndSettle();
    final pinned = tester.getTopLeft(header).dy;
    final playerTabs = find.byKey(const ValueKey('recording-player-tabs'));
    expect(pinned, closeTo(tester.getBottomLeft(playerTabs).dy, .01));
    final surface = tester.widget<Material>(
        find.byKey(const ValueKey('recording-scroll-surface')));
    expect(surface.color, Theme.of(tester.element(header)).colorScheme.surface);
    expect(tester.getTopLeft(classrooms).dy, closeTo(pinned, .01));
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy, closeTo(pinned, .01));
    expect(tester.getTopLeft(classrooms).dy, closeTo(pinned, .01));
    await harness.platforms.first.pause();
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header).dy,
        closeTo(tester.getBottomLeft(playerTabs).dy, .01));
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen episode drawer shares classroom selection',
      (tester) async {
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final lessons = [
      VodLesson(
          id: 201,
          teachingClassId: 10,
          name: '课程',
          classroom: 'A101',
          beginTime: DateTime(2026, 9, 1),
          isPlayable: true),
      VodLesson(
          id: 202,
          teachingClassId: 10,
          name: '课程',
          classroom: 'B202',
          beginTime: DateTime(2026, 9, 2),
          isPlayable: true),
      VodLesson(
          id: 203,
          teachingClassId: 10,
          name: '课程',
          beginTime: DateTime(2026, 9, 3),
          isPlayable: true),
    ];
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lessons.first,
        lessons: lessons,
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-classroom:B202')));
    await tester.pumpAndSettle();
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    await controls.state.enterFullscreen();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选集'));
    await tester.pumpAndSettle();
    final selectedEpisode = find.byKey(const ValueKey('fullscreen-lesson-202'));
    expect(selectedEpisode, findsOneWidget);
    expect(find.byKey(const ValueKey('fullscreen-lesson-201')), findsNothing);
    expect(find.byKey(const ValueKey('fullscreen-lesson-203')), findsNothing);
    expect(find.descendant(of: selectedEpisode, matching: find.text('1')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('recording-classroom-filter')), findsNothing);
    await tester.tap(find.byTooltip('切换为正序'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换为倒序'), findsOneWidget);
    await tester.tap(find.byTooltip('收起选集'));
    await tester.pumpAndSettle();
    await controls.state.exitFullscreen();
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换为倒序'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('recording-classroom:B202')))
            .selected,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('recording-classroom:A101')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-201')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-202')), findsNothing);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a single classroom hides the classroom selection row',
      (tester) async {
    const lesson = VodLesson(
        id: 201,
        teachingClassId: 10,
        name: '课程',
        classroom: 'A101',
        isPlayable: true);
    final harness = _PlaybackHarness();
    await tester.pumpWidget(page(
        initial: lesson,
        lessons: [lesson],
        harness: harness,
        load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('recording-classroom-filter')), findsNothing);
    expect(
        find.byKey(const ValueKey('recording-classroom:A101')), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-201')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'classroom selection updates the course overview without playback',
      (tester) async {
    final roomA = VodLesson(
      id: 201,
      teachingClassId: 10,
      name: course.name,
      classroom: 'A101',
      isPlayable: true,
      beginTime: DateTime(2026, 9, 7),
      sectionLabel: '第1节',
    );
    final roomB = VodLesson(
      id: 202,
      teachingClassId: 10,
      name: course.name,
      classroom: 'B202',
      isPlayable: true,
      beginTime: DateTime(2026, 9, 9),
      sectionLabel: '第4节',
    );
    final harness = _PlaybackHarness();
    final requested = <int>[];
    await tester.pumpWidget(page(
        initial: roomA,
        lessons: [roomA, roomB],
        harness: harness,
        load: (lesson) async {
          requested.add(lesson.id);
          return playback(lesson);
        }));
    await tester.pumpAndSettle();
    RecordingCourseOverview overview() => tester
        .widget<RecordingCourseOverview>(find.byType(RecordingCourseOverview));
    expect(overview().days.map((day) => day.weekday), [DateTime.monday]);
    expect(overview().days.single.sections, {1});

    await tester.tap(find.byKey(const ValueKey('recording-classroom:B202')));
    await tester.pumpAndSettle();
    expect(overview().days.map((day) => day.weekday), [DateTime.wednesday]);
    expect(overview().days.single.sections, {4});
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.episodeLessons!.map((lesson) => lesson.id), [202]);

    await tester.tap(find.byKey(const ValueKey('recording-classroom:A101')));
    await tester.pumpAndSettle();
    expect(overview().days.map((day) => day.weekday), [DateTime.monday]);
    expect(overview().days.single.sections, {1});
    expect(requested, [201]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('portrait nested episode list keeps pull-to-refresh working',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PendingCatalogRepository();
    repository.catalog.complete([first, second]);
    repository.playback.complete(playback(first));
    final refresh = Completer<List<VodLesson>>();
    repository.refreshCatalog = refresh.future;
    final harness = _PlaybackHarness();
    await tester.pumpWidget(MaterialApp(
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        repository: repository,
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pumpAndSettle();
    expect(repository.catalogRequests, 1);
    await tester.drag(find.byKey(const ValueKey('course-player-episodes')),
        const Offset(0, 400));
    for (var frame = 0; frame < 20 && repository.catalogRequests < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(repository.catalogRequests, 2);
    final progress = find.byKey(const ValueKey('recording-catalog-progress'));
    expect(progress, findsNothing);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(repository.catalogRequests, 2);
    refresh.complete([first, second]);
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(repository.requested, hasLength(1));
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  const nonSeekableWarnings = [
    'Cannot seek in this stream.',
    "You can force it with '--force-seekable=yes'.",
  ];

  testWidgets('switching a loading live stream waits for its native open',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    expect(harness.platforms.first.opened, hasLength(1));
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    await tester.pump();
    await tester.pump();
    expect(harness.platforms.first.stops, 1);
    expect(repository.requested, isEmpty);

    pendingOpen.complete();
    await tester.pump();
    await tester.pump();
    expect(repository.requested, [VodLiveProtocol.webRtc]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed media stop prevents WebRTC initialization',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    final primary = harness.platforms.first;
    expect(primary.opened, hasLength(1));
    primary.failStop = true;
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    await tester.pump();
    await tester.pump();
    expect(primary.stops, 1);
    expect(repository.requested, isEmpty);
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    pendingOpen.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid protocol changes wait for the same opening stream',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    expect(harness.platforms.first.opened, hasLength(1));
    final change = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!;
    change(VodLiveProtocol.webRtc);
    await tester.pump();
    change(VodLiveProtocol.hls);
    change(VodLiveProtocol.webRtc);
    await tester.pump();
    expect(repository.requested, isEmpty);
    pendingOpen.complete();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
    }
    expect(repository.requested, [VodLiveProtocol.webRtc]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a timed out native stop still blocks WebRTC on retry',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final pendingStop = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    final primary = harness.platforms.first;
    expect(primary.opened, hasLength(1));
    primary.stopGate = pendingStop;
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(repository.requested, isEmpty);
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(primary.stops, 1);
    expect(repository.requested, isEmpty);
    pendingOpen.complete();
    pendingStop.complete();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
    }
    expect(repository.requested, [VodLiveProtocol.webRtc]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a stale live proxy cannot start its old decoder',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingProxy = Completer<void>();
    final proxy = _FakeLiveProxy(openGate: pendingProxy);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      liveProxyFactory: (_) => proxy,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20 && proxy.opens == 0; attempt++) {
      await tester.pump();
    }
    expect(proxy.opens, 1);
    await tester.pump();
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    await tester.pump();
    expect(proxy.disposed, isFalse);
    expect(repository.requested, isEmpty);
    pendingProxy.complete();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
    }
    expect(harness.platforms.first.opened, isEmpty);
    expect(proxy.disposed, isTrue);
    expect(repository.requested, [VodLiveProtocol.webRtc]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving a loading live stream drains it before closing proxy',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final proxy = _FakeLiveProxy();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final repository = _ProtocolRepository();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      liveProxyFactory: (_) => proxy,
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
      if (harness.platforms.isNotEmpty &&
          harness.platforms.first.opened.isNotEmpty) {
        break;
      }
    }
    final player = harness.platforms.first;
    expect(player.opened, hasLength(1));
    expect(proxy.opens, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(player.stops, greaterThanOrEqualTo(1));
    expect(proxy.disposed, isFalse);
    pendingOpen.complete();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
    }
    expect(player.stops, greaterThanOrEqualTo(2));
    expect(player.state.playing, isFalse);
    expect(proxy.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all live protocol pairs can switch without changing the view',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    final sessions = <_FakeRtcSession>[];
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    var hlsRequests = 0;
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      webRtcSessionFactory: (source) {
        final session = _FakeRtcSession(source);
        sessions.add(session);
        return session;
      },
      load: (selected) async {
        hlsRequests++;
        return VodPlayback(
            lessonId: selected.id,
            teachingClassId: course.teachingClassId,
            title: course.name,
            isLive: true,
            views: [
              VodView(viewNumber: 1, url: Uri.https('media.example', '/live'))
            ]);
      },
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    expect(hlsRequests, 1);
    final sequence = [
      VodLiveProtocol.flv,
      VodLiveProtocol.webRtc,
      VodLiveProtocol.hls,
      VodLiveProtocol.webRtc,
      VodLiveProtocol.flv,
      VodLiveProtocol.hls,
    ];
    for (final protocol in sequence) {
      tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .onLiveProtocolChanged!(protocol);
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull, reason: protocol.name);
      final controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.liveProtocol, protocol);
      expect(controls.failure, isNull,
          reason:
              '${protocol.name}: ${(controls.failure as RecordingPlaybackMessage?)?.message}');
    }
    expect(hlsRequests, 3);
    expect(repository.requested, [
      VodLiveProtocol.flv,
      VodLiveProtocol.webRtc,
      VodLiveProtocol.webRtc,
      VodLiveProtocol.flv,
    ]);
    expect(sessions, hasLength(2));
    expect(sessions.every((session) => session.starts == 1 && session.disposed),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('RTC applies media volume before first start and follows changes',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    final sessions = <_FakeRtcSession>[];
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      webRtcSessionFactory: (source) {
        final session = _FakeRtcSession(source);
        sessions.add(session);
        return session;
      },
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    await harness.platforms.first.setVolume(37);
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    final session = sessions.single;
    expect(session.initialVolume, 37);
    expect(session.initialAudioEnabled, isTrue);
    await harness.platforms.first.setVolume(62);
    await tester.pump();
    expect(session.volumes.last, 62);
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.flv);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    expect(session.disposed, isTrue);
    final applied = session.volumes.length;
    await harness.platforms.first.setVolume(40);
    await tester.pump();
    expect(session.volumes.length, applied);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed RTC teardown does not skip player cleanup on exit',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    _FakeRtcSession? session;
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      webRtcSessionFactory: (source) => session = _FakeRtcSession(source),
      load: (selected) async => playback(selected),
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    expect(session?.starts, 1);
    session!.failDisposal = true;
    final player = harness.platforms.first;
    final previousStops = player.stops;
    await tester.pumpWidget(const SizedBox.shrink());
    for (var attempt = 0; attempt < 15; attempt++) {
      await tester.pump();
    }
    expect(session!.disposed, isTrue);
    expect(player.stops, greaterThan(previousStops));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a timed out RTC teardown blocks other protocols on retry',
      (tester) async {
    prepareNotesPortrait(tester);
    final harness = _PlaybackHarness();
    final repository = _ProtocolRepository()..allowPlayback = true;
    _FakeRtcSession? session;
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    var hlsRequests = 0;
    await tester.pumpWidget(page(
      initial: lesson,
      lessons: [lesson],
      harness: harness,
      repository: repository,
      webRtcSessionFactory: (source) => session = _FakeRtcSession(source),
      load: (selected) async {
        hlsRequests++;
        return playback(selected);
      },
      loadNotes: (_) async => [],
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.webRtc);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    expect(session?.starts, 1);
    final disposal = Completer<void>();
    session!.disposalGate = disposal;
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onLiveProtocolChanged!(VodLiveProtocol.hls);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(hlsRequests, 1);
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(hlsRequests, 1);
    disposal.complete();
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump();
    }
    expect(hlsRequests, 2);
    expect(session!.disposed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live surface seek warnings keep loading and both decoders alive',
      (tester) async {
    prepareNotesPortrait(tester);
    final pendingOpen = Completer<void>();
    final harness = _PlaybackHarness(primaryOpen: pendingOpen);
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    var loads = 0;
    await tester.pumpWidget(page(
      initial: lesson,
      harness: harness,
      load: (selected) async {
        loads++;
        return playback(selected);
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
    final primary = harness.platforms.single;
    final controller = harness.controllers.single;
    expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    for (final warning in nonSeekableWarnings) {
      primary.emitError(warning);
      await tester.pump();
      expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsNothing);
      expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    }

    pendingOpen.complete();
    await tester.pumpAndSettle();
    expect(harness.platforms, hasLength(2));
    expect(harness.platforms.first, same(primary));
    expect(harness.controllers.first, same(controller));
    final secondary = harness.platforms[1];
    for (final warning in nonSeekableWarnings) {
      secondary.emitError(warning);
      await tester.pumpAndSettle();
      expect(secondary.state.playing, isTrue);
      expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsNothing);
    }
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(loads, 1);
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .failure,
        isNull);

    primary.emitError('Failed to open decoder.');
    await tester.pumpAndSettle();
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
    expect(harness.platforms.first, same(primary));
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (var index = 0; index < nonSeekableWarnings.length; index++) {
    testWidgets('recording surface seek warning ${index + 1} remains a failure',
        (tester) async {
      prepareNotesPortrait(tester);
      final harness = _PlaybackHarness();
      await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async => playback(lesson),
      ));
      await tester.pumpAndSettle();
      harness.platforms.first.emitError(nonSeekableWarnings[index]);
      await tester.pumpAndSettle();
      expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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
      expect(
          tester
              .widget<ColoredBox>(find.descendant(
                  of: floating, matching: find.byType(ColoredBox)))
              .color,
          Colors.transparent);
      expect(find.descendant(of: floating, matching: find.byType(IconButton)),
          findsNothing);
      final controlStack = tester.widget<Stack>(
          find.ancestor(of: floating, matching: find.byType(Stack)).first);
      final secondarySurface = controlStack.children.indexWhere(
          (child) => child.key == ObjectKey(harness.controllers[1]));
      final primarySurface = controlStack.children.indexWhere(
          (child) => child.key == ObjectKey(harness.controllers[0]));
      final controlsOverlay = controlStack.children.indexWhere((child) =>
          child is Positioned &&
          child.child is IgnorePointer &&
          (child.child as IgnorePointer).child is ClipRect);
      expect(primarySurface, lessThan(controlsOverlay));
      expect(secondarySurface, greaterThan(controlsOverlay));
      expect(
          secondarySurface,
          lessThan(controlStack.children.indexWhere((child) =>
              child.key == const ValueKey('recording-secondary-view'))));
      for (final frame in tester.widgetList<DecoratedBox>(
          find.descendant(of: floating, matching: find.byType(DecoratedBox)))) {
        expect((frame.decoration as BoxDecoration).boxShadow, isNull);
      }
      final hostVideo = tester.element(find.byType(Video));
      final hostState = tester.state(find.byType(Video));
      final hostTexture = tester.element(find.byWidgetPredicate(
          (widget) => widget is Texture && widget.textureId == 1));
      final secondaryTexture = tester.element(find.byWidgetPredicate(
          (widget) => widget is Texture && widget.textureId == 2));
      final surfaces = {
        for (final controller in harness.controllers)
          controller: tester.element(find.byKey(ObjectKey(controller))),
      };
      expect(
          find.descendant(
              of: find.byKey(ObjectKey(harness.controllers.first)),
              matching: find.byType(Texture)),
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
      expect(tester.element(find.byType(Video)), same(hostVideo));
      expect(tester.state(find.byType(Video)), same(hostState));
      expect(hostTexture.mounted, isTrue);
      expect(
          tester.element(find.byWidgetPredicate(
              (widget) => widget is Texture && widget.textureId == 2)),
          same(secondaryTexture));
      for (final controller in harness.controllers) {
        expect(tester.element(find.byKey(ObjectKey(controller))),
            same(surfaces[controller]));
      }

      if (!live) {
        await tester.tap(find.byTooltip('播放'));
        await tester.pump(const Duration(milliseconds: 350));
        expect([classroom.toggles, ppt.toggles], [2, 0]);
        expect(classroom.state.playing, isTrue);
        expect(ppt.state.playing, isTrue);
        await tester.tap(find.byTooltip('暂停'));
        await tester.pump(const Duration(milliseconds: 350));
        expect([classroom.toggles, ppt.toggles], [3, 0]);
        expect(classroom.state.playing, isFalse);
        expect(ppt.state.playing, isFalse);
        await tester.tap(find.byTooltip('播放速度'));
        await tester.pumpAndSettle();
        await tester.tap(find.byWidgetPredicate((widget) =>
            widget is PopupMenuItem<double> && widget.value == 1.5));
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

  for (final live in [false, true]) {
    testWidgets(
        '${live ? 'live' : 'recording'} rapid swaps preserve both streams',
        (tester) async {
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final harness = _PlaybackHarness();
      final initial = live
          ? VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isPlayable: true,
              isLive: true)
          : first;
      var loads = 0;
      await tester.pumpWidget(page(
          initial: initial,
          harness: harness,
          load: (lesson) async {
            loads++;
            return playback(lesson);
          }));
      await tester.pumpAndSettle();
      final classroom = harness.platforms[0];
      final ppt = harness.platforms[1];
      await tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
          .state
          .enterFullscreen();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('开启双视角'));
      await tester.pumpAndSettle();
      final textures = tester
          .widgetList<Texture>(find.byType(Texture))
          .map((texture) => texture.textureId)
          .toList()
        ..sort();
      expect(textures, [1, 2]);
      final hostVideo = tester.element(find.byType(Video));
      final hostState = tester.state(find.byType(Video));
      final hostTexture = tester.element(find.byWidgetPredicate(
          (widget) => widget is Texture && widget.textureId == 1));
      final secondaryTexture = tester.element(find.byWidgetPredicate(
          (widget) => widget is Texture && widget.textureId == 2));
      final surfaces = {
        for (final controller in harness.controllers)
          controller: tester.element(find.byKey(ObjectKey(controller))),
      };
      var controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      classroom.state =
          classroom.state.copyWith(position: const Duration(seconds: 10));
      ppt.state = ppt.state.copyWith(position: const Duration(seconds: 8));
      classroom.seeks.clear();
      ppt.seeks.clear();
      final gate = Completer<void>();
      classroom.volumeGate = gate;
      controls.onSwapViews!();
      await tester.pump();
      for (var index = 0; index < 9; index++) {
        controls.onSwapViews!();
      }
      gate.complete();
      classroom.volumeGate = null;
      await tester.pumpAndSettle();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, 0);
      expect(classroom.state.volume, 100);
      expect(ppt.state.volume, 0);
      expect(classroom.state.playing, isTrue);
      expect(ppt.state.playing, isTrue);
      expect(classroom.seeks, isEmpty);
      expect(ppt.seeks, isEmpty);
      expect(classroom.opened, hasLength(1));
      expect(ppt.opened, hasLength(1));
      for (var index = 0; index < 11; index++) {
        controls.onSwapViews!();
      }
      await tester.pumpAndSettle();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, 1);
      expect(classroom.state.volume, 0);
      expect(ppt.state.volume, 100);
      expect(classroom.state.playing, isTrue);
      expect(ppt.state.playing, isTrue);
      final swappedTextures = tester
          .widgetList<Texture>(find.byType(Texture))
          .map((texture) => texture.textureId)
          .toList()
        ..sort();
      expect(swappedTextures, [1, 1, 2]);
      expect(tester.element(find.byType(Video)), same(hostVideo));
      expect(tester.state(find.byType(Video)), same(hostState));
      expect(hostTexture.mounted, isTrue);
      expect(
          tester.element(find.byWidgetPredicate(
              (widget) => widget is Texture && widget.textureId == 2)),
          same(secondaryTexture));
      for (final controller in harness.controllers) {
        expect(tester.element(find.byKey(ObjectKey(controller))),
            same(surfaces[controller]));
      }
      expect(classroom.seeks, isEmpty);
      expect(ppt.seeks, isEmpty);
      expect(classroom.opened, hasLength(1));
      expect(ppt.opened, hasLength(1));
      expect(loads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('long press changes both streams and restores the prior speed',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    await controls.player.setRate(1.5);
    await tester.pump();
    await tester.pump();
    expect(harness.platforms.map((player) => player.state.rate), [1.5, 1.5]);
    final surface = find.byKey(const ValueKey('recording-control-surface'));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(harness.platforms.map((player) => player.state.rate), [3, 3]);
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(harness.platforms.map((player) => player.state.rate), [1.5, 1.5]);
    expect(
        harness.platforms.every((player) => player.opened.length == 1), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('playing position jitter does not repeatedly seek either stream',
      (tester) async {
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    classroom.state =
        classroom.state.copyWith(position: const Duration(seconds: 10));
    ppt.state =
        ppt.state.copyWith(position: const Duration(milliseconds: 9600));
    classroom.seeks.clear();
    ppt.seeks.clear();
    for (var index = 0; index < 10; index++) {
      classroom.emitPosition(Duration(milliseconds: 10000 + index * 100));
      ppt.emitPosition(Duration(milliseconds: 9600 + index * 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(classroom.seeks, isEmpty);
    expect(ppt.seeks, isEmpty);
    expect(classroom.state.playing, isTrue);
    expect(ppt.state.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sustained drift never starts an automatic seek on either stream',
      (tester) async {
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    classroom.state =
        classroom.state.copyWith(position: const Duration(seconds: 10));
    ppt.state = ppt.state.copyWith(position: const Duration(seconds: 8));
    classroom.seeks.clear();
    ppt.seeks.clear();
    classroom.emitPosition(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 799));
    expect(ppt.seeks, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(ppt.seeks, isEmpty);
    classroom.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(ppt.seeks, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(ppt.seeks, isEmpty);
    expect(classroom.seeks, isEmpty);
    expect(classroom.state.playing, isTrue);
    expect(ppt.state.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a transient volume failure retries audio without undoing the view',
      (tester) async {
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    ppt.failNextVolume = true;
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pump();
    await tester.pump();
    final updated = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(updated.selectedView, 1);
    expect(classroom.state.volume, 0);
    expect(ppt.state.volume, 100);
    expect(classroom.state.playing, isTrue);
    expect(ppt.state.playing, isTrue);
    expect(find.text('视频暂时无法播放，可刷新播放地址后重试。'), findsNothing);
    expect(classroom.opened, hasLength(1));
    expect(ppt.opened, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dual view does not undo a seek while positions catch up',
      (tester) async {
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .enterFullscreen();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开启双视角'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-secondary-view')));
    await tester.pumpAndSettle();
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(identical(controls.player.platform, ppt), isTrue);
    classroom.state =
        classroom.state.copyWith(position: const Duration(seconds: 10));
    ppt.state = ppt.state.copyWith(position: const Duration(seconds: 10));
    classroom.publishSeekPosition = false;
    ppt.publishSeekPosition = false;
    classroom.seeks.clear();
    ppt.seeks.clear();

    await controls.onSeek!(const Duration(seconds: 50));
    ppt.emitPosition(const Duration(seconds: 50));
    await tester.pump();
    await tester.pump();
    expect(ppt.seeks, [const Duration(seconds: 50)]);
    expect(classroom.seeks, [const Duration(seconds: 50)]);
    await controls.onSeek!(const Duration(seconds: 70));
    classroom.emitPosition(const Duration(seconds: 50));
    ppt.emitPosition(const Duration(seconds: 50));
    await tester.pump();
    await tester.pump();
    expect(
        ppt.seeks, [const Duration(seconds: 50), const Duration(seconds: 70)]);
    expect(classroom.seeks,
        [const Duration(seconds: 50), const Duration(seconds: 70)]);

    ppt.emitPosition(const Duration(seconds: 70));
    classroom.emitPosition(const Duration(seconds: 70));
    await tester.pump();
    await tester.pump();
    ppt.publishSeekPosition = true;
    classroom.emitPosition(const Duration(seconds: 72));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(ppt.seeks, [
      const Duration(seconds: 50),
      const Duration(seconds: 70),
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a slow secondary cannot rewind the acknowledged main view',
      (tester) async {
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    await tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .state
        .enterFullscreen();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开启双视角'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-secondary-view')));
    await tester.pumpAndSettle();
    final controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    classroom.state =
        classroom.state.copyWith(position: const Duration(seconds: 10));
    ppt.state = ppt.state.copyWith(position: const Duration(seconds: 10));
    classroom.publishSeekPosition = false;
    ppt.publishSeekPosition = false;
    classroom.seeks.clear();
    ppt.seeks.clear();

    await controls.onSeek!(const Duration(seconds: 50));
    ppt.emitPosition(const Duration(seconds: 50));
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(ppt.seeks, [const Duration(seconds: 50)]);
    expect(classroom.seeks, [const Duration(seconds: 50)]);
    expect(
        identical(
            tester
                .widget<RecordingVideoControls>(
                    find.byType(RecordingVideoControls))
                .timelinePlayer!
                .platform,
            ppt),
        isTrue);
    expect(classroom.opened, hasLength(1));
    expect(ppt.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed muted timeline falls back to the healthy main player',
      (tester) async {
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pumpAndSettle();
    classroom.emitError('old timeline failed');
    await tester.pumpAndSettle();

    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    expect(identical(controls.timelinePlayer!.platform, ppt), isTrue);
    ppt.emitPosition(const Duration(seconds: 40));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 40000);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pumpAndSettle();
    expect(ppt.state.playing, isFalse);
    expect(classroom.opened, hasLength(1));
    expect(ppt.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'unsupported audio selection does not block opening or view swaps',
      (tester) async {
    final harness = _PlaybackHarness();
    var loads = 0;
    await tester.pumpWidget(page(
        harness: harness,
        load: (lesson) async {
          loads++;
          return playback(lesson);
        }));
    await tester.pumpAndSettle();

    expect(harness.platforms, hasLength(2));
    expect(harness.platforms.map((player) => player.audioTracks),
        everyElement(isEmpty));
    expect(harness.platforms.map((player) => player.state.track.audio.id),
        ['auto', 'auto']);
    expect(harness.platforms.every((player) => player.state.playing), isTrue);
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    for (var index = 0; index < 3; index++) {
      controls.onSwapViews!();
      await tester.pumpAndSettle();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, (index + 1) % 2);
    }

    expect(harness.platforms.map((player) => player.opened.length), [1, 1]);
    expect(harness.platforms.map((player) => player.audioTracks),
        everyElement(isEmpty));
    expect(harness.platforms.map((player) => player.appliedVolume), [0, 100]);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('100 immediate swaps preserve transport and delayed commands',
      (tester) async {
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
    classroom.emitPosition(const Duration(seconds: 30));
    ppt.emitPosition(const Duration(seconds: 20));
    await classroom.setVolume(37);
    await tester.pump();
    final plays = harness.platforms.map((player) => player.plays).toList();
    final pauses = harness.platforms.map((player) => player.pauses).toList();
    classroom.seeks.clear();
    ppt.seeks.clear();
    final surfaceElements = <VideoController, Element>{
      for (final controller in harness.controllers)
        controller: tester.element(find.byKey(ObjectKey(controller))),
    };
    final hostVideo = tester.element(find.byType(Video));
    final hostState = tester.state(find.byType(Video));
    final hostTexture = tester.element(find.byWidgetPredicate(
        (widget) => widget is Texture && widget.textureId == 1));
    final secondaryTexture = tester.element(find.byWidgetPredicate(
        (widget) => widget is Texture && widget.textureId == 2));
    final audibleCounts = <int>[];
    void checkExclusiveAudio() {
      audibleCounts.add(
          harness.platforms.where((player) => player.appliedVolume > 0).length);
    }

    classroom.onVolumeApplied = checkExclusiveAudio;
    ppt.onVolumeApplied = checkExclusiveAudio;
    checkExclusiveAudio();
    final volumeGate = Completer<void>();
    final seekGate = Completer<void>();
    classroom.volumeGate = volumeGate;
    ppt.volumeGate = volumeGate;
    classroom.seekGate = seekGate;
    ppt.seekGate = seekGate;
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    final pendingSeek = controls.onSeek!(const Duration(seconds: 60));

    for (var index = 0; index < 100; index++) {
      controls.onSwapViews!();
      await tester.pump();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
      expect(controls.selectedView, (index + 1) % 2);
      expect(identical(controls.timelinePlayer!.platform, classroom), isTrue);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 30000);
      expect(tester.element(find.byType(Video)), same(hostVideo));
      expect(tester.state(find.byType(Video)), same(hostState));
      expect(hostTexture.mounted, isTrue);
      expect(
          tester.element(find.byWidgetPredicate(
              (widget) => widget is Texture && widget.textureId == 2)),
          same(secondaryTexture));
      for (final controller in harness.controllers) {
        expect(tester.element(find.byKey(ObjectKey(controller))),
            same(surfaceElements[controller]));
      }
    }
    expect(classroom.seeks, [const Duration(seconds: 60)]);
    expect(ppt.seeks, [const Duration(seconds: 60)]);
    expect(harness.platforms.map((player) => player.plays), plays);
    expect(harness.platforms.map((player) => player.pauses), pauses);
    expect(harness.platforms.map((player) => player.opened.length), [1, 1]);
    expect(harness.platforms.map((player) => player.audioTracks),
        everyElement(isEmpty));
    expect(loads, 1);

    volumeGate.complete();
    classroom.volumeGate = null;
    ppt.volumeGate = null;
    await tester.pump();
    await tester.pump();
    seekGate.complete();
    classroom.seekGate = null;
    ppt.seekGate = null;
    await pendingSeek;
    await tester.pumpAndSettle();

    expect(classroom.appliedVolume, 37);
    expect(ppt.appliedVolume, 0);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 60000);
    expect(audibleCounts, everyElement(lessThanOrEqualTo(1)));
    expect(harness.platforms.map((player) => player.plays), plays);
    expect(harness.platforms.map((player) => player.pauses), pauses);
    expect(harness.platforms.map((player) => player.opened.length), [1, 1]);
    expect(classroom.seeks, [const Duration(seconds: 60)]);
    expect(ppt.seeks, [const Duration(seconds: 60)]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale unmute and stale volume state cannot reclaim audio roles',
      (tester) async {
    final harness = _PlaybackHarness();
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pumpAndSettle();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    await classroom.setVolume(37);
    classroom.publishVolumeState = false;
    ppt.publishVolumeState = false;
    final audibleCounts = <int>[];
    void checkExclusiveAudio() {
      audibleCounts.add(
          harness.platforms.where((player) => player.appliedVolume > 0).length);
    }

    classroom.onVolumeApplied = checkExclusiveAudio;
    ppt.onVolumeApplied = checkExclusiveAudio;
    checkExclusiveAudio();
    final gate = Completer<void>();
    ppt.volumeGate = gate;
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pump();
    expect(ppt.volumes.last, 37);

    for (var index = 0; index < 99; index++) {
      controls.onSwapViews!();
      await tester.pump();
      controls = tester
          .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    }
    expect(controls.selectedView, 0);
    gate.complete();
    ppt.volumeGate = null;
    await tester.pumpAndSettle();
    expect(classroom.appliedVolume, 37);
    expect(ppt.appliedVolume, 0);

    controls.onSwapViews!();
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    expect(ppt.state.volume, 0);
    expect(ppt.appliedVolume, 37);
    controls.onSwapViews!();
    await tester.pumpAndSettle();
    expect(classroom.appliedVolume, 37);
    expect(ppt.appliedVolume, 0);
    expect(audibleCounts, everyElement(lessThanOrEqualTo(1)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'initial warm alignment settles before a pending view is promoted',
      (tester) async {
    final secondaryOpen = Completer<void>();
    final secondaryFrame = Completer<void>();
    final harness = _PlaybackHarness(
        secondaryOpen: secondaryOpen, secondaryFrame: secondaryFrame);
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pump();
    await tester.pump();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    classroom.emitPosition(const Duration(seconds: 3));
    final seekGate = Completer<void>();
    ppt.seekGate = seekGate;
    ppt.publishSeekPosition = false;
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    secondaryOpen.complete();
    await tester.pump();
    await tester.pump();
    classroom.emitPosition(const Duration(seconds: 6));
    secondaryFrame.complete();
    await tester.pump();
    await tester.pump();

    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 0);
    expect(ppt.seeks, [const Duration(seconds: 6)]);
    expect(ppt.appliedVolume, 0);
    seekGate.complete();
    ppt.seekGate = null;
    await tester.pump();
    await tester.pump();
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        0);

    ppt.emitPosition(const Duration(seconds: 6));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    expect(ppt.appliedVolume, 100);
    expect(classroom.appliedVolume, 0);
    expect(ppt.state.position, classroom.state.position);
    classroom.emitPosition(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(ppt.seeks, [const Duration(seconds: 6)]);
    expect(classroom.seeks, isEmpty);
    expect(classroom.opened, hasLength(1));
    expect(ppt.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a manual seek during warming cannot promote its obsolete target',
      (tester) async {
    final frame = Completer<void>();
    final harness = _PlaybackHarness(secondaryFrame: frame);
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pump();
    await tester.pump();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    ppt.publishSeekPosition = false;
    classroom.emitPosition(const Duration(seconds: 6));
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    frame.complete();
    await tester.pump();
    await tester.pump();
    expect(ppt.seeks, [const Duration(seconds: 6)]);

    await controls.onSeek!(const Duration(seconds: 60));
    ppt.emitPosition(const Duration(seconds: 6));
    await tester.pump();
    await tester.pump();
    expect(
        ppt.seeks, [const Duration(seconds: 6), const Duration(seconds: 60)]);
    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        0);
    expect(ppt.appliedVolume, 0);

    ppt.emitPosition(const Duration(seconds: 60));
    await tester.pump();
    await tester.pumpAndSettle();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    expect(ppt.state.position, classroom.state.position);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 60000);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('warm alignment times out without promoting an unconfirmed view',
      (tester) async {
    final frame = Completer<void>();
    final harness = _PlaybackHarness(secondaryFrame: frame);
    await tester.pumpWidget(
        page(harness: harness, load: (lesson) async => playback(lesson)));
    await tester.pump();
    await tester.pump();
    final classroom = harness.platforms[0];
    final ppt = harness.platforms[1];
    ppt.publishSeekPosition = false;
    classroom.emitPosition(const Duration(seconds: 6));
    tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
        .onSwapViews!();
    frame.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<RecordingVideoControls>(find.byType(RecordingVideoControls))
            .selectedView,
        0);
    expect(ppt.appliedVolume, 0);
    expect(ppt.seeks, [const Duration(seconds: 6)]);
    expect(classroom.state.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing lessons during a delayed mute restores desired audio',
      (tester) async {
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
    await classroom.setVolume(37);
    final mute = Completer<void>();
    classroom.volumeGate = mute;
    var controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    controls.onSwapViews!();
    await tester.pump();
    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedView, 1);
    controls.onLessonSelected!(second);
    await tester.pump();
    await tester.pump();
    mute.complete();
    classroom.volumeGate = null;
    await tester.pumpAndSettle();

    controls = tester
        .widget<RecordingVideoControls>(find.byType(RecordingVideoControls));
    expect(controls.selectedLessonId, second.id);
    expect(controls.player.state.volume, 37);
    expect(
        harness.platforms.map((player) => player.appliedVolume).toList()
          ..sort(),
        [0, 37]);
    expect(harness.platforms, hasLength(2));
    expect(classroom.opened, hasLength(2));
    expect(ppt.opened, hasLength(2));
    expect(loads, 2);
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
    controls.onSwapViews!();
    await tester.pump();
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

  for (final preview in [false, true]) {
    testWidgets(
        '${preview ? 'preview' : 'course'} uses the preloaded catalog until a manual refresh',
        (tester) async {
      final regular = _PendingCatalogRepository();
      final search = _PendingPreviewRepository();
      regular.refreshCatalog = Future.value([first, second]);
      search.refreshCatalog = Future.value([first, second]);
      final repository = preview ? search : regular;
      final requested = <int>[];
      final harness = _PlaybackHarness();
      addTearDown(regular.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: RecordingPlayerPage(
          course: course,
          lessons: [first, second],
          initialLesson: first,
          loadCourseCatalog: !preview,
          loadPreviewCatalog: preview,
          skipInitialCatalogLoad: true,
          repository: repository,
          loadPlayback: (lesson) async {
            requested.add(lesson.id);
            return playback(lesson);
          },
          playerFactory: harness.createPlayer,
          videoControllerFactory: harness.createController,
        ),
      ));
      await tester.pumpAndSettle();
      expect(regular.catalogRequests, 0);
      expect(search.requests, isEmpty);
      expect(requested, [first.id]);
      expect(
          find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      if (preview) {
        expect(search.requests.single.forceRefresh, isTrue);
      } else {
        expect(regular.catalogRequests, 1);
      }
      expect(requested, [first.id]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('preloaded catalog selects a valid lesson without an initial one',
      (tester) async {
    final repository = _PendingCatalogRepository();
    final requested = <int>[];
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RecordingPlayerPage(
        course: course,
        lessons: [unrelated, first, second],
        skipInitialCatalogLoad: true,
        repository: repository,
        loadPlayback: (lesson) async {
          requested.add(lesson.id);
          return playback(lesson);
        },
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pumpAndSettle();
    expect(repository.catalogRequests, 0);
    expect(requested, [second.id]);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty preloaded catalog shows empty state and permits refresh',
      (tester) async {
    final repository = _PendingCatalogRepository();
    repository.refreshCatalog = Future.value([first]);
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RecordingPlayerPage(
        course: course,
        skipInitialCatalogLoad: true,
        repository: repository,
        loadPlayback: (lesson) async => playback(lesson),
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pumpAndSettle();
    expect(repository.catalogRequests, 0);
    expect(find.text('暂无可观看的视频'), findsOneWidget);
    await tester.tap(find.text('刷新选集'));
    await tester.pumpAndSettle();
    expect(repository.catalogRequests, 1);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('preloaded search playback can recover an expired session',
      (tester) async {
    final repository = _PendingPreviewRepository();
    repository.refreshCatalog = Future.value([first, second]);
    final harness = _PlaybackHarness();
    var attempts = 0;
    var recoveries = 0;
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        lessons: [first],
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        skipInitialCatalogLoad: true,
        repository: repository,
        onSessionExpired: () async {
          recoveries++;
          return true;
        },
        loadPlayback: (lesson) async {
          if (++attempts == 1) throw const VodSessionExpiredException();
          return playback(lesson);
        },
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pumpAndSettle();
    expect(repository.requests, isEmpty);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(attempts, 2);
    expect(repository.requests.single.forceRefresh, isTrue);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final denied in [false, true]) {
    testWidgets(
        'search result skips the ordinary catalog and ${denied ? 'preserves playback denial' : 'plays its initial lesson'}',
        (tester) async {
      final repository = _PendingCatalogRepository();
      final harness = _PlaybackHarness();
      addTearDown(repository.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: RecordingPlayerPage(
          course: course,
          initialLesson: first,
          loadCourseCatalog: false,
          repository: repository,
          playerFactory: harness.createPlayer,
          videoControllerFactory: harness.createController,
        ),
      ));
      await tester.pump();
      expect(repository.catalogRequests, 0);
      expect(repository.requested, [first]);
      if (denied) {
        repository.playback.completeError(const VodPermissionException());
      } else {
        repository.playback.complete(playback(first));
      }
      await tester.pumpAndSettle();
      expect(repository.catalogRequests, 0);
      expect(find.text('选集'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsNothing);
      if (denied) {
        expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
        expect(harness.platforms, isEmpty);
      } else {
        expect(harness.platforms.first.opened, hasLength(1));
        expect(find.byType(RecordingPlaybackLoading), findsNothing);
        expect(find.byTooltip('暂停'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('preview without an initial lesson selects and plays a lesson',
      (tester) async {
    final repository = _PendingPreviewRepository();
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pump();
    expect(repository.requested, isEmpty);
    expect(repository.warmed, isEmpty);
    expect(find.byType(RecordingPlaybackLoading), findsOneWidget);
    repository.catalog.complete([first, second]);
    await tester.pump();
    await tester.pump();
    expect(repository.requested, [102]);
    expect(repository.warmed.single.map((lesson) => lesson.id), [101, 102]);
    repository.playback[102]!.complete(playback(second));
    await tester.pumpAndSettle();
    expect(harness.platforms.first.opened, hasLength(1));
    expect(find.byKey(const ValueKey('recording-lesson-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty preview stops loading and permits a refresh',
      (tester) async {
    final repository = _PendingPreviewRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
      ),
    ));
    repository.catalog.complete([]);
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    expect(find.text('暂无可观看的视频'), findsOneWidget);
    expect(find.text('刷新选集'), findsOneWidget);
    repository.refreshCatalog = Future.value([first]);
    await tester.tap(find.text('刷新选集'));
    await tester.pump();
    await tester.pump();
    expect(repository.requests.last.forceRefresh, isTrue);
    expect(repository.requested, [101]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview failure without a selection stops loading and retries',
      (tester) async {
    final repository = _PendingPreviewRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
      ),
    ));
    repository.catalog.completeError(const VodNetworkException());
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPlaybackLoading), findsNothing);
    expect(find.text('暂时无法连接录播平台，请检查网络后重试。'), findsOneWidget);
    repository.refreshCatalog = Future.value([first]);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(repository.requests.last.forceRefresh, isTrue);
    expect(repository.requested, [101]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview can complete background warming after the route closes',
      (tester) async {
    final repository = _PendingPreviewRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
      ),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    repository.catalog.complete([first, second]);
    await tester.pump();
    expect(repository.warmed.single.map((lesson) => lesson.id), [101, 102]);
    expect(repository.requested, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview merges seed and current selection without reopening',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const statusUnknown = VodLesson(
      id: 105,
      teachingClassId: 10,
      name: '状态未知',
      isPlayable: false,
    );
    const detailedSecond = VodLesson(
      id: 102,
      teachingClassId: 10,
      name: '课程详情',
      isPlayable: true,
      classroom: 'B202',
    );
    final repository = _PendingPreviewRepository();
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        lessons: [first, second],
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pump();
    expect(repository.requested, [101]);
    expect(repository.requests.single.forceRefresh, isFalse);
    expect(find.byKey(const ValueKey('recording-catalog-progress')),
        findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('recording-lesson-102')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recording-lesson-102')));
    await tester.pump();
    expect(repository.requested, [101, 102]);
    repository.catalog.complete([detailedSecond, statusUnknown]);
    await tester.pump();
    expect(
        find.byKey(const ValueKey('recording-catalog-progress')), findsNothing);
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('搜索课次'), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-101')), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-105')), findsNothing);
    final detail = tester
        .widget<ListTile>(find.byKey(const ValueKey('recording-lesson-102')))
        .subtitle! as Text;
    expect(detail.textSpan!.toPlainText(), contains('B202'));
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('recording-classroom:B202')))
            .selected,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('recording-classroom:')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recording-lesson-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-105')), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('recording-lesson-105')))
            .enabled,
        isTrue);
    expect(repository.requested, [101, 102]);
    repository.playback[101]!.complete(playback(first));
    repository.playback[102]!.complete(playback(second));
    await tester.pumpAndSettle();
    expect(harness.platforms.first.opened, hasLength(1));
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recording-classroom:B202')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('recording-lesson-102')))
            .selected,
        isTrue);
    repository.refreshCatalog = Future.value([statusUnknown]);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(repository.requests.last.forceRefresh, isTrue);
    expect(repository.requested, [101, 102]);
    expect(find.byKey(const ValueKey('recording-lesson-101')), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-classroom:')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-105')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsNothing);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview failure preserves playback failure and permits refresh',
      (tester) async {
    final repository = _PendingPreviewRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        lessons: [first, second],
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
      ),
    ));
    await tester.pump();
    repository.playback[101]!.completeError(const VodPermissionException());
    await tester.pump();
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
    repository.catalog.completeError(const VodNetworkException());
    await tester.pump();
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
    expect(find.text('选集刷新失败，请稍后下拉重试'), findsOneWidget);
    expect(repository.requested, [101]);
    repository.refreshCatalog = Future.value([]);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(repository.requests.last.forceRefresh, isTrue);
    expect(repository.requested, [101]);
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final alreadyPlaying in [false, true]) {
    testWidgets(
        'preview session expiry preserves ${alreadyPlaying ? 'playing' : 'pending'} playback',
        (tester) async {
      final repository = _PendingPreviewRepository();
      final harness = _PlaybackHarness();
      addTearDown(repository.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: RecordingPlayerPage(
          course: course,
          initialLesson: first,
          loadCourseCatalog: false,
          loadPreviewCatalog: true,
          repository: repository,
          playerFactory: harness.createPlayer,
          videoControllerFactory: harness.createController,
        ),
      ));
      await tester.pump();
      if (alreadyPlaying) {
        repository.playback[101]!.complete(playback(first));
        await tester.pump();
        await tester.pump();
      }
      final pauses = alreadyPlaying ? harness.platforms.first.pauses : 0;
      repository.catalog.completeError(const VodSessionExpiredException());
      await tester.pump();
      expect(find.text('校园账户登录已失效，请重新登录。'), findsNothing);
      if (!alreadyPlaying) {
        repository.playback[101]!.complete(playback(first));
        await tester.pumpAndSettle();
      } else {
        expect(harness.platforms.first.pauses, pauses);
      }
      expect(harness.platforms.first.opened, hasLength(1));
      expect(harness.platforms.first.state.playing, isTrue);
      expect(repository.requested, [101]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('session recovery ignores the old preview and reloads it',
      (tester) async {
    final repository = _PendingPreviewRepository();
    final updated = Completer<List<VodLesson>>();
    repository.refreshCatalog = updated.future;
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        loadCourseCatalog: false,
        loadPreviewCatalog: true,
        repository: repository,
        onSessionExpired: () async => true,
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pump();
    repository.playback[101]!.completeError(const VodSessionExpiredException());
    await tester.pump();
    await tester.tap(find.text('重新登录'));
    await tester.pump();
    await tester.pump();
    expect(repository.requested, [101, 101]);
    expect(repository.requests.map((request) => request.forceRefresh),
        [false, true]);
    repository.catalog.completeError(const VodSessionExpiredException());
    repository.playback[101]!.complete(playback(first));
    updated.complete([second]);
    await tester.pumpAndSettle();
    expect(find.text('校园账户登录已失效，请重新登录。'), findsNothing);
    expect(find.byKey(const ValueKey('recording-lesson-102')), findsOneWidget);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(repository.requested, [101, 101]);
    expect(tester.takeException(), isNull);
  });

  for (final playbackDenied in [false, true]) {
    testWidgets(
        'immediate catalog denial preserves a pending recording request '
        'when playback ${playbackDenied ? 'is denied' : 'succeeds'}',
        (tester) async {
      final repository = _DeniedCatalogRepository();
      final harness = _PlaybackHarness();
      addTearDown(repository.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: RecordingPlayerPage(
          course: course,
          initialLesson: first,
          repository: repository,
          playerFactory: harness.createPlayer,
          videoControllerFactory: harness.createController,
        ),
      ));
      await tester.pump();
      expect(repository.catalogRequests, 1);
      expect(repository.requested, [first]);
      expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsNothing);
      expect(find.text('选集刷新失败，请稍后下拉重试'), findsNothing);
      if (playbackDenied) {
        repository.playback.completeError(const VodPermissionException());
      } else {
        repository.playback.complete(playback(first));
      }
      await tester.pumpAndSettle();
      if (playbackDenied) {
        expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
        expect(harness.platforms, isEmpty);
      } else {
        expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsNothing);
        expect(harness.platforms.first.opened, hasLength(1));
        expect(harness.platforms.first.state.playing, isTrue);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('late catalog denial does not stop an opened recording',
      (tester) async {
    final repository = _PendingCatalogRepository();
    final harness = _PlaybackHarness();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
        course: course,
        initialLesson: first,
        repository: repository,
        playerFactory: harness.createPlayer,
        videoControllerFactory: harness.createController,
      ),
    ));
    await tester.pump();
    repository.playback.complete(playback(first));
    await tester.pump();
    await tester.pump();
    final platform = harness.platforms.first;
    expect(platform.state.playing, isTrue);
    final pauses = platform.pauses;
    repository.catalog.completeError(const VodPermissionException());
    await tester.pumpAndSettle();
    expect(platform.state.playing, isTrue);
    expect(platform.pauses, pauses);
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsNothing);
    expect(find.text('选集刷新失败，请稍后下拉重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('catalog session expiry still interrupts a pending recording',
      (tester) async {
    final repository = _PendingCatalogRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(
          course: course, initialLesson: first, repository: repository),
    ));
    await tester.pump();
    repository.catalog.completeError(const VodSessionExpiredException());
    await tester.pumpAndSettle();
    expect(find.text('校园账户登录已失效，请重新登录。'), findsOneWidget);
    repository.playback.complete(playback(first));
    await tester.pump();
    expect(find.text('校园账户登录已失效，请重新登录。'), findsOneWidget);
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
    final progress = find.byKey(const ValueKey('recording-catalog-progress'));
    final banner = find.byKey(const ValueKey('recording-course-banner'));
    expect(progress, findsOneWidget);
    expect(tester.getBottomLeft(progress).dy,
        lessThanOrEqualTo(tester.getTopLeft(banner).dy));
    await tester.drag(find.byKey(const ValueKey('course-player-episodes')),
        const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.catalogRequests, 1);
    expect(progress, findsOneWidget);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(repository.catalogRequests, 1);
    repository.catalog.complete([live, first]);
    await tester.pump();
    expect(progress, findsNothing);
    expect(repository.requested, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    repository.playback.completeError(const VodNetworkException());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('course heading enlarges title and omits classroom metadata',
      (tester) async {
    final classroomOne = VodLesson(
      id: 201,
      teachingClassId: 10,
      name: '第一节',
      isPlayable: true,
      classroom: ' A101 ',
      beginTime: DateTime(2026, 10, 27),
      sectionLabel: '第1节',
    );
    final classroomTwo = VodLesson(
      id: 202,
      teachingClassId: 10,
      name: '第二节',
      isPlayable: true,
      classroom: 'B202',
      beginTime: DateTime(2026, 10, 29),
      sectionLabel: '第3节',
    );
    const repeatedClassroom = VodLesson(
      id: 203,
      teachingClassId: 10,
      name: '第三节',
      isPlayable: false,
      isGenerating: true,
      classroom: 'A101',
    );
    const unrelatedClassroom = VodLesson(
      id: 204,
      teachingClassId: 999,
      name: '其他班',
      isPlayable: true,
      classroom: 'C303',
    );
    final repository = _CatalogRepository([
      classroomOne,
      classroomTwo,
      repeatedClassroom,
      unrelatedClassroom,
    ]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!),
      home: RecordingPlayerPage(
        course: course,
        term: const VodTerm(
            id: 7,
            name: '2026-2027学年第1学期',
            academicYear: '2026-2027',
            termNumber: 1),
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();

    final label = find.byType(CourseColorLabel);
    final name = find.descendant(of: label, matching: find.text(course.name));
    final code =
        find.descendant(of: label, matching: find.text('EE102 · 授课教师'));
    expect(name, findsOneWidget);
    expect(code, findsOneWidget);
    expect(tester.getTopLeft(code).dy, greaterThan(tester.getTopLeft(name).dy));
    expect(tester.widget<Text>(code).style!.fontSize!,
        lessThan(tester.widget<Text>(name).style!.fontSize!));
    expect(tester.widget<Text>(name).style!.fontSize, 19);
    expect(tester.widget<Text>(code).style!.fontSize, 14);
    expect(find.descendant(of: label, matching: find.text('26-27 秋季')),
        findsNothing);
    expect(find.text('A101/B202'), findsNothing);
    final banner = find.byKey(const ValueKey('recording-course-banner'));
    final overview = find.descendant(
        of: banner, matching: find.byType(RecordingCourseOverview));
    expect(overview, findsOneWidget);
    final overviewTitle = tester
        .widget<Text>(find.descendant(of: overview, matching: find.text('概览')));
    final classroomTitle = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('recording-classroom-filter')),
        matching: find.text('教室')));
    final episodeTitle = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('recording-episode-header')),
        matching: find.text('选集')));
    for (final heading in [overviewTitle, classroomTitle, episodeTitle]) {
      expect(heading.style!.fontWeight, FontWeight.w600);
      expect(heading.style!.fontSize, overviewTitle.style!.fontSize);
    }
    expect(find.text('剧集'), findsNothing);
    expect(
        tester
            .widget<RecordingCourseOverview>(overview)
            .days
            .map((day) => day.weekday),
        [4]);
    expect(tester.widget<RecordingCourseOverview>(overview).term?.id, 7);
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('recording-course-overview-term')))
            .textSpan!
            .toPlainText(),
        '2026-2027 学年 秋季学期');
    expect(
        find.ancestor(
            of: overview, matching: find.byType(SliverPersistentHeader)),
        findsNothing);
    final separators =
        find.descendant(of: banner, matching: find.byType(Divider));
    expect(separators, findsNWidgets(2));
    expect(tester.getBottomLeft(separators.first).dy,
        lessThanOrEqualTo(tester.getTopLeft(overview).dy));
    expect(tester.getTopLeft(separators.last).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(overview).dy));
    expect(
        tester.getBottomLeft(banner).dy -
            tester.getBottomLeft(separators.last).dy,
        8);
    expect(find.descendant(of: banner, matching: find.textContaining('A101')),
        findsNothing);
    expect(find.textContaining('C303'), findsNothing);
    expect(find.textContaining('课程代码'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'direct course page prioritizes live and disables a generating episode',
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
    expect(find.text('课程介绍'), findsNothing);
    expect(
        find.descendant(
            of: liveRow, matching: find.byType(RecordingStatusIcon)),
        findsOneWidget);
    await tester.tap(generatedRow);
    await tester.pump();
    expect(repository.requested.map((lesson) => lesson.id), [106]);
  });

  testWidgets(
      'explicit generating initial lessons cannot bypass disabled selection',
      (tester) async {
    prepareNotesPortrait(tester);
    for (final isPlayable in [false, true]) {
      final pending = VodLesson(
          id: 105,
          teachingClassId: 10,
          name: course.name,
          isPlayable: isPlayable,
          isGenerating: true);
      final requested = <VodLesson>[];
      await tester.pumpWidget(page(
        initial: pending,
        lessons: [pending, first],
        harness: _PlaybackHarness(),
        load: (lesson) async {
          requested.add(lesson);
          return playback(lesson);
        },
      ));
      await tester.pumpAndSettle();
      expect(requested, [first]);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    final pending = VodLesson(
        id: 105,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isGenerating: true);
    var requests = 0;
    await tester.pumpWidget(page(
        initial: pending,
        lessons: [pending],
        load: (lesson) async {
          requests++;
          return playback(lesson);
        }));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('回放生成中，生成后可观看'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a course containing only generating episodes waits without playback',
      (tester) async {
    final repository = _CatalogRepository([unavailable]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!),
      home: RecordingPlayerPage(course: course, repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(repository.requested, isEmpty);
    expect(find.text('回放生成中，生成后可观看'), findsOneWidget);
    final row = tester.widget<ListTile>(
        find.byKey(ValueKey('recording-lesson-${unavailable.id}')));
    expect(row.enabled, isFalse);
    expect(row.onTap, isNull);
    expect(find.text('选集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a course with unknown recording status requests playback',
      (tester) async {
    const unknown = VodLesson(
        id: 110, teachingClassId: 10, name: '状态未知', isPlayable: false);
    final repository = _CatalogRepository([first, unknown]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: RecordingPlayerPage(course: course, repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(repository.requested, [first]);
    final row =
        find.byKey(const ValueKey('recording-lesson-110'), skipOffstage: false);
    expect(tester.widget<ListTile>(row).enabled, isTrue);
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
    expect(repository.requested, [first, unknown]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a generated recording is selected before a newer candidate',
      (tester) async {
    final pending = VodLesson(
      id: 105,
      teachingClassId: 10,
      name: course.name,
      isPlayable: false,
      isGenerating: true,
      beginTime: DateTime(2026, 10, 28),
    );
    final repository = _CatalogRepository([first, pending]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!),
      home: RecordingPlayerPage(course: course, repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(repository.requested, [first]);
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
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
    expect(find.text('选集'), findsOneWidget);
    await tester.ensureVisible(find
        .byKey(const ValueKey('recording-lesson-103'), skipOffstage: false));
    await tester.pump();
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('recording-lesson-103')))
            .enabled,
        isFalse);
    expect(find.byKey(const ValueKey('recording-lesson-104')), findsNothing);

    await tester.ensureVisible(find.text('重试'));
    await tester.pump();
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
    expect(find.text('无法获取这节录播的播放地址，请稍后重试。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final live in [false, true]) {
    testWidgets(
        'WebVPN ${live ? 'live' : 'recording'} failure restores before retrying playback',
        (tester) async {
      prepareNotesPortrait(tester);
      final harness = _PlaybackHarness();
      final lesson = live
          ? VodLesson(
              id: 106,
              teachingClassId: 10,
              name: course.name,
              isPlayable: true,
              isLive: true)
          : first;
      final restoration = Completer<bool>();
      var recoveryCalls = 0;
      var playbackCalls = 0;
      await tester.pumpWidget(page(
        initial: lesson,
        harness: harness,
        load: (selected) async {
          playbackCalls++;
          if (playbackCalls == 1) {
            throw const VodWebVpnSessionExpiredException();
          }
          return playback(selected);
        },
        login: () {
          recoveryCalls++;
          return restoration.future;
        },
      ));
      await tester.pumpAndSettle();
      expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsOneWidget);
      expect(find.text('重新登录'), findsNothing);
      expect(find.text('校园账户登录已失效，请重新登录。'), findsNothing);
      expect(recoveryCalls, 0);
      expect(playbackCalls, 1);
      await tester.tap(find.text('恢复连接'));
      await tester.pump();
      expect(recoveryCalls, 1);
      expect(playbackCalls, 1);
      restoration.complete(true);
      await tester.pumpAndSettle();
      expect(playbackCalls, 2);
      expect(recoveryCalls, 1);
      expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsNothing);
      expect(harness.platforms.first.opened, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'WebVPN catalog expiry exposes connection recovery and reloads lessons',
      (tester) async {
    prepareNotesPortrait(tester);
    final repository = _PendingCatalogRepository()
      ..refreshCatalog = Future.value([first]);
    final harness = _PlaybackHarness();
    var recoveries = 0;
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RecordingPlayerPage(
      course: course,
      repository: repository,
      onSessionExpired: () async {
        recoveries++;
        return true;
      },
      loadPlayback: (lesson) async => playback(lesson),
      playerFactory: harness.createPlayer,
      videoControllerFactory: harness.createController,
    )));
    await tester.pump();
    repository.catalog.completeError(const VodWebVpnSessionExpiredException());
    await tester.pumpAndSettle();
    expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    await tester.tap(find.text('恢复连接'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(repository.catalogRequests, 2);
    expect(harness.platforms.first.opened, hasLength(1));
    expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'WebVPN heartbeat expiry uses connection recovery without campus login',
      (tester) async {
    prepareNotesPortrait(tester);
    final repository = _WebVpnHeartbeatRepository();
    final harness = _PlaybackHarness();
    final lesson = VodLesson(
        id: 106,
        teachingClassId: 10,
        name: course.name,
        isPlayable: true,
        isLive: true);
    var recoveries = 0;
    var playbackCalls = 0;
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: RecordingPlayerPage(
          course: course,
          repository: repository,
          lessons: [lesson],
          initialLesson: lesson,
          skipInitialCatalogLoad: true,
          onSessionExpired: () async {
            recoveries++;
            repository.restored = true;
            return true;
          },
          loadPlayback: (selected) async {
            playbackCalls++;
            return VodPlayback(
                lessonId: selected.id,
                teachingClassId: 10,
                title: course.name,
                isLive: true,
                views: [
                  VodView(
                      viewNumber: 1,
                      url: Uri.parse(
                          'https://rtc.cc.shu.edu.cn:32001/live.m3u8'))
                ]);
          },
          playerFactory: harness.createPlayer,
          videoControllerFactory: harness.createController,
        )));
    await tester.pumpAndSettle();
    expect(repository.heartbeats, 1);
    expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    await tester.tap(find.text('恢复连接'));
    // The live relay closes a real loopback listener before reopening media.
    for (var attempt = 0; attempt < 20 && playbackCalls < 2; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(playbackCalls, 2);
    expect(repository.heartbeats, 2);
    expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('never requests playback for a generating-only initial lesson',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(page(
      initial: unavailable,
      lessons: [unavailable],
      load: (lesson) async {
        calls++;
        throw const VodNetworkException();
      },
    ));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('回放生成中，生成后可观看'), findsOneWidget);
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
    final time = find.text('1:05:00/1:30:00');
    expect(time, findsOneWidget);
    expect(tester.widget<Text>(time).maxLines, 1);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(platform.toggles, 1);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.tap(find.byTooltip('播放速度'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<double> && widget.value == 1.5));
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
    expect(find.text('● 直播中'), findsOneWidget);
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
    final time = find.text('10:00/1:30:00');
    expect(time, findsOneWidget);
    expect(tester.widget<Text>(time).maxLines, 1);
    expect(find.byTooltip('退出全屏'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
