import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/vod_ppt.dart';
import 'package:shuyo/features/course_recordings/recording_notes_panel.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  VodPptSlide slide(int id, {bool image = false, String? text}) => VodPptSlide(
        id: '$id',
        imageUrl: image ? Uri.parse('https://example.test/ppt/$id.jpg') : null,
        position: Duration(minutes: id),
        text: text ?? '第 $id 页：牛顿运动定律及其应用。',
      );

  Widget app({
    List<VodPptSlide> slides = const [],
    bool loading = false,
    String? error,
    Future<void> Function()? onRefresh,
    ValueChanged<Duration>? onSeek,
    Future<Map<String, String>> Function(Uri)? headersLoader,
    ThemeData? theme,
    double textScale = 1,
    bool canSeek = true,
  }) =>
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: RecordingNotesPanel(
              slides: slides,
              loading: loading,
              error: error,
              onRefresh: onRefresh ?? () async {},
              onSeek: onSeek ?? (_) {},
              headersLoader: headersLoader,
              canSeek: canSeek,
            ),
          ),
        ),
      );

  testWidgets('loading, unavailable content, and request failure are distinct',
      (tester) async {
    await tester.pumpWidget(app(loading: true));
    expect(find.text('正在获取 PPT 笔记'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('当前课次暂无 PPT 笔记'), findsNothing);

    await tester.pumpWidget(app());
    expect(find.text('当前课次暂无 PPT 笔记'), findsOneWidget);
    expect(find.text('录播平台尚未提供这节课的 PPT 识别内容'), findsOneWidget);
    expect(find.text('重试'), findsNothing);

    await tester.pumpWidget(app(error: 'timeout'));
    expect(find.text('PPT 笔记加载失败'), findsOneWidget);
    expect(find.text('timeout'), findsOneWidget);
    expect(find.text('当前课次暂无 PPT 笔记'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull to refresh works for empty, failed and populated notes',
      (tester) async {
    var refreshes = 0;
    Future<void> refresh() async {
      refreshes++;
    }

    for (final panel in [
      app(onRefresh: refresh),
      app(error: 'timeout', onRefresh: refresh),
      app(slides: [slide(1)], onRefresh: refresh),
    ]) {
      await tester.pumpWidget(panel);
      await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
          const Offset(0, 350));
      await tester.pumpAndSettle();
    }
    expect(refreshes, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR text is selectable and timestamps seek the current slide',
      (tester) async {
    final positions = <Duration>[];
    await tester.pumpWidget(app(
      slides: [
        slide(1),
        const VodPptSlide(
          id: 'long',
          imageUrl: null,
          position: Duration(hours: 1, minutes: 2, seconds: 3),
          text: '能量守恒定律',
        ),
      ],
      onSeek: positions.add,
    ));
    expect(find.text('按时间排序'), findsOneWidget);
    expect(find.text('PPT 第 1 页'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.text('01:00'), findsOneWidget);
    expect(find.text('1:02:03'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-note-seek-long')));
    expect(positions, [const Duration(hours: 1, minutes: 2, seconds: 3)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('77 PPT attachments obtain credentials only as rows appear',
      (tester) async {
    final requests = <Uri>[];
    final pending = Completer<Map<String, String>>();
    await tester.pumpWidget(app(
      slides: List.generate(77, (index) => slide(index + 1, image: true)),
      headersLoader: (url) {
        requests.add(url);
        return pending.future;
      },
    ));
    await tester.pump();
    expect(requests, isNotEmpty);
    expect(requests.length, lessThan(6));
    expect(find.byKey(const ValueKey('recording-note-77')), findsNothing);
    final before = requests.length;
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, -700));
    await tester.pump();
    expect(requests.length, greaterThan(before));
    expect(requests.length, lessThan(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'copy uses the full OCR text and seek waits until playback is ready',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final positions = <Duration>[];
    final note = slide(1, text: '第一段 OCR 文字\n第二段 OCR 文字');
    await tester.pumpWidget(app(
      slides: [note],
      canSeek: false,
      onSeek: positions.add,
    ));
    final seek = find.byKey(const ValueKey('recording-note-seek-1'));
    expect(tester.widget<TextButton>(seek).onPressed, isNull);
    await tester.tap(seek);
    expect(positions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('recording-note-copy-1')));
    await tester.pump();
    expect(copied, note.text);
    expect(find.text('已复制 PPT 笔记'), findsOneWidget);
    await tester.pumpWidget(app(slides: [note], onSeek: positions.add));
    expect(tester.widget<TextButton>(seek).onPressed, isNotNull);
    await tester.tap(seek);
    expect(positions, [note.position]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment errors leave OCR text usable and preview opens large',
      (tester) async {
    final requested = <Completer<Map<String, String>>>[];
    await tester.pumpWidget(app(
      slides: [slide(1, image: true)],
      headersLoader: (_) {
        final pending = Completer<Map<String, String>>();
        requested.add(pending);
        return pending.future;
      },
    ));
    requested.single.completeError(StateError('expired credentials'));
    await tester.pump();
    expect(find.text('PPT 预览暂不可用'), findsOneWidget);
    expect(find.text('第 1 页：牛顿运动定律及其应用。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-note-image-1')));
    await tester.pump();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(requested, hasLength(2));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    requested.last.completeError(StateError('late completion after close'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late image-header result cannot replace another lesson',
      (tester) async {
    final oldHeaders = Completer<Map<String, String>>();
    final newHeaders = Completer<Map<String, String>>();
    await tester.pumpWidget(app(
      slides: [slide(1, image: true)],
      headersLoader: (_) => oldHeaders.future,
    ));
    await tester.pumpWidget(app(
      slides: [slide(2, image: true)],
      headersLoader: (_) => newHeaders.future,
    ));
    oldHeaders.completeError(StateError('old lesson'));
    await tester.pump();
    expect(find.text('PPT 预览暂不可用'), findsNothing);
    expect(find.text('第 2 页：牛顿运动定律及其应用。'), findsOneWidget);
    newHeaders.completeError(StateError('new lesson'));
    await tester.pump();
    expect(find.text('PPT 预览暂不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark narrow layout supports large text and long OCR passages',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dark = ShuYoThemes.all
        .firstWhere((theme) => theme.colors.brightness == Brightness.dark);
    await tester.pumpWidget(app(
      theme: dark.themeData(),
      textScale: 2.2,
      slides: [
        VodPptSlide(
          id: 'long',
          imageUrl: null,
          position: const Duration(hours: 1, minutes: 2, seconds: 3),
          text: List.filled(12, '中文长段落与 English words 可以选择复制。').join('\n'),
        ),
      ],
    ));
    expect(find.text('1:02:03'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app(theme: dark.themeData(), textScale: 2.2));
    expect(tester.takeException(), isNull);
  });
}
