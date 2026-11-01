import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/vod_ppt.dart';
import 'package:shuyo/features/course_recordings/recording_notes_panel.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/fullscreen_image_page.dart';

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
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
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

  testWidgets(
      'a note expands full selectable text and can seek the current slide',
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
    expect(find.text('按时间排序'), findsNothing);
    expect(find.text('文字由录播平台自动识别，点击笔记查看全文。'), findsNothing);
    expect(find.text('PPT 第 1 页'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('01:00'), findsOneWidget);
    expect(find.text('1:02:03'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-note-open-long')));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const ValueKey('recording-note-text-long')))
            .data,
        '能量守恒定律');
    await tester.tap(find.byKey(const ValueKey('recording-note-seek-long')));
    await tester.pumpAndSettle();
    expect(positions, [const Duration(hours: 1, minutes: 2, seconds: 3)]);
    expect(find.text('笔记详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'notes show a left thumbnail and a three-line summary on the right',
      (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final note =
        slide(1, text: List.filled(20, '这是一段完整的 PPT 识别内容。').join('\n'));
    await tester.pumpWidget(app(slides: [note]));

    final image = tester
        .getRect(find.byKey(const ValueKey('recording-note-thumbnail-1')));
    final text =
        tester.getRect(find.byKey(const ValueKey('recording-note-summary-1')));
    expect(image.left, 16);
    expect(text.left - image.right, 12);
    expect(text.right, 393 - 16);
    expect(text.top, image.top);
    expect(image.width / image.height, closeTo(16 / 9, .01));
    final summary = tester
        .widget<Text>(find.byKey(const ValueKey('recording-note-summary-1')));
    expect(summary.maxLines, 3);
    expect(summary.overflow, TextOverflow.ellipsis);
    expect(summary.data!.length, lessThan(note.text.length));
    expect(find.text('01'), findsNothing);
    expect(find.text('共 1 条笔记'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const ValueKey('recording-note-text-1')))
            .data,
        note.text);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byKey(const ValueKey('recording-note-open-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'detail actions share the fixed title row without a modal barrier',
      (tester) async {
    await tester.pumpWidget(app(slides: [slide(1)]));
    final barriers = find.byType(ModalBarrier).evaluate().length;
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pumpAndSettle();
    final toolbar = tester
        .getRect(find.byKey(const ValueKey('recording-note-detail-toolbar')));
    final titleStyle = tester.widget<Text>(find.text('笔记详情')).style!;
    expect(titleStyle.fontSize, 14);
    expect(titleStyle.fontWeight, FontWeight.w400);
    expect(titleStyle.height, 1.43);
    expect(titleStyle.letterSpacing, .25);
    final copy =
        tester.getRect(find.byKey(const ValueKey('recording-note-copy-1')));
    final seek =
        tester.getRect(find.byKey(const ValueKey('recording-note-seek-1')));
    final close = tester.getRect(find.byTooltip('关闭'));
    expect(toolbar.height, 45);
    expect(copy.right, lessThanOrEqualTo(seek.left));
    expect(seek.right, lessThanOrEqualTo(close.left));
    for (final rect in [copy, seek, close]) {
      expect(rect.center.dy, closeTo(toolbar.center.dy, 1));
    }
    expect(find.byType(ModalBarrier).evaluate().length, barriers);
    expect(find.byType(FilledButton), findsNothing);
    await tester.drag(
        find.byKey(const ValueKey('recording-note-detail-scroll-1')),
        const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(find.text('笔记详情'), findsOneWidget);
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
    expect(requests.length, lessThan(15));
    expect(find.byKey(const ValueKey('recording-note-77')), findsNothing);
    final before = requests.length;
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, -700));
    await tester.pump();
    expect(requests.length, greaterThan(before));
    expect(requests.length, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning to evicted rows reuses resolved image credentials',
      (tester) async {
    final requests = <Uri, int>{};
    final slides = List.generate(77, (index) => slide(index + 1, image: true));
    await tester.pumpWidget(app(
      slides: slides,
      headersLoader: (url) async {
        requests.update(url, (count) => count + 1, ifAbsent: () => 1);
        return const {};
      },
    ));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const ValueKey('recording-notes-scroll')),
        matching: find.byType(Scrollable)));
    scroll.position.jumpTo(1400);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-note-open-1')), findsNothing);
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-note-open-1')), findsOneWidget);
    expect(requests[slides.first.imageUrl], 1);
    expect(requests.values, everyElement(1));
    expect(requests.length, lessThan(slides.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull refresh renews the lesson image credential cache',
      (tester) async {
    var headers = 0;
    await tester.pumpWidget(app(
      slides: [slide(1, image: true)],
      headersLoader: (_) async {
        headers++;
        return const {};
      },
    ));
    await tester.pumpAndSettle();
    expect(headers, 1);
    await tester.drag(find.byKey(const ValueKey('recording-notes-scroll')),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(headers, 2);
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
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pumpAndSettle();
    final seek = find.byKey(const ValueKey('recording-note-seek-1'));
    expect(tester.widget<IconButton>(seek).onPressed, isNull);
    await tester.tap(seek);
    expect(positions, isEmpty);
    await tester.tap(find.byKey(const ValueKey('recording-note-copy-1')));
    await tester.pump();
    expect(copied, note.text);
    expect(find.byTooltip('已复制'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(slides: [note], onSeek: positions.add));
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(seek).onPressed, isNotNull);
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
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text('第 1 页：牛顿运动定律及其应用。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pump();
    requested.last.completeError(StateError('detail credentials unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('PPT 预览暂不可用'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('recording-note-image-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-note-image-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(FullscreenImagePage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(requested, hasLength(3));
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenImagePage), findsNothing);
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
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    expect(find.text('第 2 页：牛顿运动定律及其应用。'), findsOneWidget);
    newHeaders.completeError(StateError('new lesson'));
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('recording-note-open-long')));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.drag(
        find.byKey(const ValueKey('recording-note-detail-scroll-long')),
        const Offset(0, -400));
    await tester.pumpAndSettle();
    for (final key in [
      'recording-note-copy-long',
      'recording-note-seek-long'
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(640));
    }
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(theme: dark.themeData(), textScale: 2.2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a detail from a previous lesson cannot seek the new lesson',
      (tester) async {
    final positions = <Duration>[];
    await tester.pumpWidget(app(slides: [slide(1)], onSeek: positions.add));
    await tester.tap(find.byKey(const ValueKey('recording-note-open-1')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(slides: [slide(2)], onSeek: positions.add));
    await tester.tap(find.byKey(const ValueKey('recording-note-seek-1')));
    await tester.pumpAndSettle();
    expect(positions, isEmpty);
    expect(find.byKey(const ValueKey('recording-note-open-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
