import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_video_controls.dart';

class _SafeAreaPlayer extends PlatformPlayer {
  _SafeAreaPlayer() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      position: const Duration(minutes: 12),
      duration: const Duration(minutes: 90),
    );
  }

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }
}

class _SafeAreaVideoState extends VideoState {
  @override
  Future<void> toggleFullscreen() async {}

  @override
  Future<void> exitFullscreen() async {}
}

const _lessons = [
  VodLesson(id: 2, teachingClassId: 10, name: '第二节', isPlayable: true),
  VodLesson(id: 1, teachingClassId: 10, name: '第一节', isPlayable: true),
];

Widget _controls({
  required Player player,
  required Size size,
  required EdgeInsets viewPadding,
  bool fullscreen = true,
  bool dual = false,
  String title = '电路与模拟电子技术',
  String? termLabel,
  VodLesson? selectedLesson,
  TextScaler textScaler = TextScaler.noScaling,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: size,
            padding: EdgeInsets.zero,
            viewPadding: viewPadding,
            textScaler: textScaler),
        child: Scaffold(
          body: RecordingVideoControls(
            state: _SafeAreaVideoState(),
            fullscreen: fullscreen,
            player: player,
            title: title,
            termLabel: termLabel,
            loading: false,
            failure: null,
            views: [
              VodView(
                  viewNumber: 1,
                  url: Uri.https('media.example', '/classroom'),
                  displayLabel: '教室'),
              VodView(
                  viewNumber: 5,
                  url: Uri.https('media.example', '/ppt'),
                  displayLabel: 'PPT'),
            ],
            selectedView: 0,
            lessons: _lessons,
            selectedLessonId: 2,
            selectedLesson: selectedLesson,
            onLessonSelected: (_) {},
            onBack: () {},
            onDualChanged: (_) {},
            dualEnabled: dual,
            secondaryView: const ColoredBox(color: Colors.blue),
            primaryView: const ColoredBox(
                key: ValueKey('safe-area-primary-picture'),
                color: Colors.black),
          ),
        ),
      ),
    );

void main() {
  testWidgets('term accompanies the fullscreen title using episode text style',
      (tester) async {
    const size = Size(873, 393);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    addTearDown(player.dispose);
    final lesson = VodLesson(
        id: 2,
        teachingClassId: 10,
        name: '第二节',
        isPlayable: true,
        beginTime: DateTime(2026, 10, 29, 13),
        endTime: DateTime(2026, 10, 29, 13, 45));
    await tester.pumpWidget(_controls(
        player: player,
        size: size,
        viewPadding: const EdgeInsets.fromLTRB(44, 12, 44, 24),
        termLabel: '26-27 秋季',
        selectedLesson: lesson));
    await tester.pump();

    final title = find.byKey(const ValueKey('recording-fullscreen-title'));
    final term = find.byKey(const ValueKey('recording-fullscreen-term'));
    final metadata =
        find.byKey(const ValueKey('recording-fullscreen-episode-heading'));
    final termText = tester.widget<Text>(term);
    final metadataText = tester.widget<Text>(metadata);
    expect(termText.data, '26-27 秋季');
    expect(termText.style!.fontSize, 12);
    expect(termText.style!.fontSize, metadataText.style!.fontSize);
    expect(termText.style!.color, metadataText.style!.color);
    expect(tester.getTopLeft(term).dx,
        greaterThanOrEqualTo(tester.getTopRight(title).dx + 12));
    expect(
        tester.getTopLeft(term).dy, lessThan(tester.getBottomRight(title).dy));
    expect(tester.getBottomRight(term).dy,
        greaterThan(tester.getTopLeft(title).dy));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_controls(
        player: player,
        size: size,
        viewPadding: EdgeInsets.zero,
        fullscreen: false,
        termLabel: '26-27 秋季',
        selectedLesson: lesson));
    expect(term, findsNothing);
    expect(find.text('26-27 秋季'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'long fullscreen title and term scroll inside the safe title area',
      (tester) async {
    const size = Size(600, 320);
    const insets = EdgeInsets.fromLTRB(44, 12, 44, 24);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    addTearDown(player.dispose);
    await tester.pumpWidget(_controls(
        player: player,
        size: size,
        viewPadding: insets,
        title: '电路与模拟电子技术以及课程名称较长情况下的播放器顶部课程信息',
        termLabel: '26-27 秋季',
        textScaler: const TextScaler.linear(2)));
    await tester.pump();

    final term = find.byKey(const ValueKey('recording-fullscreen-term'));
    final scroll =
        find.ancestor(of: term, matching: find.byType(SingleChildScrollView));
    expect(scroll, findsOneWidget);
    expect(tester.widget<SingleChildScrollView>(scroll).scrollDirection,
        Axis.horizontal);
    final titleArea = tester.getRect(scroll);
    expect(titleArea.left, greaterThanOrEqualTo(insets.left + 10));
    expect(titleArea.right, lessThanOrEqualTo(size.width - insets.right - 10));
    expect(tester.getRect(find.byTooltip('更多设置')).right,
        lessThanOrEqualTo(size.width - insets.right - 10));
    await tester.drag(scroll, const Offset(-2000, 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(term).right, lessThanOrEqualTo(titleArea.right + 1));
    expect(tester.getRect(term).left, greaterThanOrEqualTo(titleArea.left));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fullscreen in [false, true]) {
    for (final size in [const Size(320, 221), const Size(873, 393)]) {
      testWidgets(
          'bold larger time stays on one line at double text scale ($fullscreen, $size)',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final platform = _SafeAreaPlayer();
        platform.state =
            platform.state.copyWith(position: const Duration(minutes: 65));
        final player = Player(platformPlayer: platform);
        await tester.pumpWidget(_controls(
            player: player,
            size: size,
            viewPadding: EdgeInsets.zero,
            fullscreen: fullscreen,
            textScaler: const TextScaler.linear(2)));
        await tester.pump();

        final time = find.byKey(const ValueKey('recording-playback-time'));
        final label = tester.widget<Text>(
            find.descendant(of: time, matching: find.byType(Text)));
        expect(label.textSpan!.toPlainText(), '1:05:00/1:30:00');
        expect(label.maxLines, 1);
        expect(label.style!.fontWeight, FontWeight.w600);
        expect(label.style!.fontSize, fullscreen ? 14 : 13);
        final controls = tester
            .getRect(find.byKey(const ValueKey('recording-bottom-controls')));
        final timeRect = tester.getRect(time);
        expect(timeRect.left, greaterThanOrEqualTo(controls.left));
        expect(timeRect.right, lessThanOrEqualTo(controls.right));
        if (!fullscreen) {
          expect(tester.getRect(find.byTooltip('下一集')).right,
              lessThanOrEqualTo(tester.getRect(find.byTooltip('播放速度')).left));
        }
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      });
    }
  }

  for (final insets in [
    const EdgeInsets.fromLTRB(44, 12, 0, 24),
    const EdgeInsets.fromLTRB(0, 12, 44, 24),
    const EdgeInsets.fromLTRB(44, 12, 44, 24),
  ]) {
    testWidgets(
        'fullscreen controls respect cutouts without lifting over the bottom inset $insets',
        (tester) async {
      const size = Size(873, 393);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = Player(platformPlayer: _SafeAreaPlayer());
      await tester.pumpWidget(
          _controls(player: player, size: size, viewPadding: insets));
      await tester.pump();

      final back = tester.getRect(find.byTooltip('退出全屏').first);
      final bottom = tester
          .getRect(find.byKey(const ValueKey('recording-bottom-controls')));
      expect(back.left, greaterThanOrEqualTo(insets.left + 10));
      expect(back.top, greaterThanOrEqualTo(insets.top + 10));
      expect(bottom.left, greaterThanOrEqualTo(insets.left + 10));
      expect(bottom.right, lessThanOrEqualTo(size.width - insets.right - 10));
      expect(bottom.bottom, size.height - 12);
      expect(
          tester
              .getRect(find.byKey(const ValueKey('safe-area-primary-picture'))),
          Offset.zero & size);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  }

  testWidgets('portrait controls do not consume viewPadding a second time',
      (tester) async {
    const size = Size(393, 221);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    await tester.pumpWidget(_controls(
        player: player,
        size: size,
        fullscreen: false,
        viewPadding: const EdgeInsets.fromLTRB(0, 44, 0, 34)));
    await tester.pump();

    final back = tester.getRect(find.byTooltip('返回课程列表'));
    final bottom =
        tester.getRect(find.byKey(const ValueKey('recording-bottom-controls')));
    expect(back.top, 12);
    expect(bottom.bottom, size.height - 12);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('floating view stays inside every viewPadding edge when dragged',
      (tester) async {
    const size = Size(873, 393);
    const insets = EdgeInsets.fromLTRB(44, 20, 32, 24);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = Player(platformPlayer: _SafeAreaPlayer());
    await tester.pumpWidget(
        _controls(player: player, size: size, viewPadding: insets, dual: true));
    await tester.pump();
    final floating = find.byKey(const ValueKey('recording-secondary-view'));

    await tester.drag(floating, const Offset(-2000, -1000));
    await tester.pump(const Duration(milliseconds: 350));
    var rect = tester.getRect(floating);
    expect(rect.left, greaterThanOrEqualTo(insets.left + 8));
    expect(rect.top, greaterThanOrEqualTo(insets.top + 8));

    await tester.drag(floating, const Offset(2000, 1000));
    await tester.pump(const Duration(milliseconds: 350));
    rect = tester.getRect(floating);
    expect(rect.right, lessThanOrEqualTo(size.width - insets.right - 8));
    expect(rect.bottom, lessThanOrEqualTo(size.height - insets.bottom - 8));
    expect(rect.size, const Size(200, 112.5));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  for (final size in [const Size(873, 393), const Size(320, 221)]) {
    testWidgets('episode drawer respects viewPadding at $size', (tester) async {
      const insets = EdgeInsets.fromLTRB(44, 12, 44, 24);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = Player(platformPlayer: _SafeAreaPlayer());
      await tester.pumpWidget(
          _controls(player: player, size: size, viewPadding: insets));
      await tester.pump();

      await tester.ensureVisible(find.byTooltip('选集'));
      await tester.pump();
      await tester.tap(find.byTooltip('选集'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final close = tester.getRect(find.byTooltip('收起选集'));
      final episodes =
          tester.getRect(find.byKey(const ValueKey('fullscreen-episode-list')));
      expect(
          tester
              .widget<ListView>(
                  find.byKey(const ValueKey('fullscreen-episode-list')))
              .padding,
          EdgeInsets.zero);
      expect(close.top, greaterThanOrEqualTo(insets.top));
      expect(close.right, lessThanOrEqualTo(size.width - insets.right));
      expect(episodes.bottom, lessThanOrEqualTo(size.height - insets.bottom));
      expect(episodes.right, lessThanOrEqualTo(size.width - insets.right));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  }
}
