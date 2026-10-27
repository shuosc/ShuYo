import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
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
  );
  const unrelated = VodLesson(
    id: 104,
    teachingClassId: 999,
    name: '其他教学班',
    isPlayable: true,
  );

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
    expect(find.text('选集（2）'), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-103')), findsNothing);
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
    expect(find.text('10:00 / 1:30:00'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
