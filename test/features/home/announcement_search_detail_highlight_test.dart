import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/features/home/announcements_page.dart';

const _primary = Color(0xff854321);
const _item = AnnouncementListItem(
  title: '测试公告',
  url: 'https://www.shu.edu.cn/info/1051/1.htm',
);

class _DetailRepository extends AnnouncementRepository {
  _DetailRepository(this.detail);
  final AnnouncementDetail detail;

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async =>
      detail;
}

class _PendingDetailRepository extends AnnouncementRepository {
  final result = Completer<AnnouncementDetail>();

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) =>
      result.future;
}

Widget _app(
  List<AnnouncementContentBlock> blocks, {
  String query = '',
  String title = '测试公告',
  double textScale = 1,
}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _primary)
              .copyWith(primary: _primary)),
      home: AnnouncementDetailPage(
        repository: _DetailRepository(AnnouncementDetail(
          title: title,
          url: _item.url,
          blocks: blocks,
        )),
        item: _item,
        highlightQuery: query,
      ),
    );

List<TextSpan> _spans(InlineSpan span) => [
      if (span is TextSpan) span,
      if (span is TextSpan)
        for (final child in span.children ?? const <InlineSpan>[])
          ..._spans(child),
    ];

RenderEditable _editable(WidgetTester tester, Finder finder) {
  final render = tester.renderObject(finder);
  RenderEditable? result;
  void visit(RenderObject node) {
    if (node is RenderEditable) {
      result ??= node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(render);
  return result!;
}

Future<void> _waitForBody(WidgetTester tester) async {
  for (var frame = 0;
      frame < 20 &&
          find
              .byKey(const ValueKey('announcement-search-matched-article'))
              .evaluate()
              .isEmpty;
      frame++) {
    await tester.pump();
  }
}

Future<void> _settleArticle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

Future<void> _waitForPrefixMetrics(WidgetTester tester) async {
  for (var frame = 0;
      frame < 100 && find.byType(SliverVariedExtentList).evaluate().isEmpty;
      frame++) {
    await tester.pump();
  }
  expect(find.byType(SliverVariedExtentList), findsWidgets);
}

void main() {
  testWidgets('search match content still waits for the route push animation',
      (tester) async {
    final detail = AnnouncementDetail(
      title: _item.title,
      url: _item.url,
      blocks: [
        for (var index = 0; index < 100; index++)
          AnnouncementContentBlock.text('普通段落 $index'),
        const AnnouncementContentBlock.text('搜索目标'),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () {
                      Navigator.of(context).push<void>(PageRouteBuilder<void>(
                        transitionDuration: const Duration(milliseconds: 500),
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            AnnouncementDetailPage(
                                repository: _DetailRepository(detail),
                                item: _item,
                                highlightQuery: '目标'),
                      ));
                    },
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('announcement-search-matched-article')),
        findsNothing);
    await tester.pump(const Duration(milliseconds: 430));
    await _waitForBody(tester);
    await _waitForPrefixMetrics(tester);
    final scroll = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('announcement-search-matched-article')));
    expect(scroll.controller!.offset, 0);
    expect(tester.getTopLeft(find.text('测试公告')).dy, lessThan(100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(scroll.controller!.offset, 0);
    await _settleArticle(tester);
    expect(find.byKey(const ValueKey('announcement-search-matched-article')),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow request finishes before the visible pause starts',
      (tester) async {
    final repository = _PendingDetailRepository();
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(
        repository: repository,
        item: _item,
        highlightQuery: '目标',
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.result.complete(AnnouncementDetail(
      title: _item.title,
      url: _item.url,
      blocks: [
        for (var index = 0; index < 100; index++)
          AnnouncementContentBlock.text('普通段落 $index'),
        const AnnouncementContentBlock.text('搜索目标'),
        for (var index = 0; index < 20; index++)
          AnnouncementContentBlock.text('后续段落 $index'),
      ],
    ));
    await _waitForBody(tester);
    await _waitForPrefixMetrics(tester);
    final scroll = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('announcement-search-matched-article')));
    expect(scroll.controller!.offset, 0);
    expect(find.text(_item.title), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(scroll.controller!.offset, 0);
    await _settleArticle(tester);
    expect(scroll.controller!.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  for (final duringAnimation in [false, true]) {
    testWidgets(
        'user scrolling cancels pending match navigation during ${duringAnimation ? 'animation' : 'pause'}',
        (tester) async {
      await tester.pumpWidget(_app([
        for (var index = 0; index < 100; index++)
          AnnouncementContentBlock.text('普通段落 $index'),
        const AnnouncementContentBlock.text('搜索目标'),
        for (var index = 0; index < 30; index++)
          AnnouncementContentBlock.text('后续段落 $index'),
      ], query: '目标'));
      await _waitForBody(tester);
      await _waitForPrefixMetrics(tester);
      final article = find.byType(CustomScrollView);
      final controller = tester.widget<CustomScrollView>(article).controller!;
      if (duringAnimation) {
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, greaterThan(0));
      }
      await tester.drag(article, const Offset(0, -120));
      await tester.pumpAndSettle();
      final offset = controller.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offset, offset);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disposing the detail page cancels its pending reading pause',
      (tester) async {
    await tester.pumpWidget(_app(const [
      AnnouncementContentBlock.text('普通段落'),
      AnnouncementContentBlock.text('搜索目标'),
    ], query: '目标'));
    await _waitForBody(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an asynchronously laid out prefix table does not move the final match',
      (tester) async {
    await tester.pumpWidget(_app([
      AnnouncementContentBlock.table([
        for (var row = 0; row < 180; row++)
          [for (var column = 0; column < 8; column++) '项目 $row / $column'],
      ]),
      const AnnouncementContentBlock.text('这里是搜索目标的位置'),
      for (var index = 0; index < 30; index++)
        AnnouncementContentBlock.text('后续段落 $index'),
    ], query: '目标'));
    await _waitForBody(tester);
    final article = find.byType(CustomScrollView);
    final controller = tester.widget<CustomScrollView>(article).controller!;
    expect(controller.offset, 0);
    // Advance the reading pause without draining the table's asynchronous
    // layout frames; its final height can replace the placeholder mid-scroll.
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await _settleArticle(tester);
    final target = find.byWidgetPredicate((widget) =>
        widget is SelectableText &&
        widget.textSpan?.toPlainText() == '这里是搜索目标的位置');
    expect(target, findsOneWidget);
    final editable = _editable(tester, target);
    final box = editable
        .getBoxesForSelection(
            const TextSelection(baseOffset: 5, extentOffset: 7))
        .first;
    final y = editable.localToGlobal(Offset(0, box.top)).dy;
    expect(
        y,
        closeTo(
            tester.getTopLeft(article).dy +
                controller.position.viewportDimension * 0.18,
            1));
    await tester.drag(article, const Offset(0, -100));
    await tester.pumpAndSettle();
    final offset = controller.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.offset, offset);
    expect(tester.takeException(), isNull);
  });

  for (final configuration in [
    (width: 320.0, scale: 1.0),
    (width: 420.0, scale: 1.6)
  ]) {
    testWidgets(
        'measured prefix matches natural Chinese layout at ${configuration.width}px and scale ${configuration.scale}',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(configuration.width, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const paragraph =
          '中文换行验证：这段文字包含不同长度的句子，验证搜索定位之前的正文高度。English wrapping 12345。\n';
      const blocks = [
        AnnouncementContentBlock.text(paragraph),
        AnnouncementContentBlock.text('搜索目标'),
      ];
      final target = find.byWidgetPredicate((widget) =>
          widget is SelectableText &&
          widget.textSpan?.toPlainText() == paragraph);
      await tester.pumpWidget(_app(blocks, textScale: configuration.scale));
      await tester.pumpAndSettle();
      final naturalHeight = _editable(tester, target).size.height;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
          _app(blocks, query: '目标', textScale: configuration.scale));
      await _waitForBody(tester);
      await _waitForPrefixMetrics(tester);
      final measuredHeight = _editable(tester, target).size.height;
      expect(measuredHeight, closeTo(naturalHeight, 0.01));
      await _settleArticle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('article heading pauses before a genuine scroll to a block match',
      (tester) async {
    await tester.pumpWidget(_app([
      for (var index = 0; index < 100; index++)
        AnnouncementContentBlock.text('命中前的普通段落 $index'),
      const AnnouncementContentBlock.text('这里包含搜索目标'),
      for (var index = 0; index < 30; index++)
        AnnouncementContentBlock.text('后续普通段落 $index'),
    ], query: '搜索目标'));
    final article = find.byKey(
      const ValueKey('announcement-search-matched-article'),
    );
    await _waitForBody(tester);
    await _waitForPrefixMetrics(tester);
    final controller = tester.widget<CustomScrollView>(article).controller!;
    expect(controller.offset, 0);
    expect(tester.getTopLeft(find.text('测试公告')).dy, lessThan(100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.offset, 0);
    expect(controller.position.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(controller.offset, 0);
    expect(controller.position.isScrollingNotifier.value, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    final intermediate = controller.offset;
    expect(intermediate, greaterThan(0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(intermediate));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real match offset still scrolls through intermediate frames',
      (tester) async {
    final paragraph = '${List.filled(100, '普通文字内容。').join()}这里包含搜索目标';
    await tester.pumpWidget(_app([
      for (var index = 0; index < 100; index++)
        AnnouncementContentBlock.text('命中前的普通段落 $index'),
      AnnouncementContentBlock.text(paragraph),
      for (var index = 0; index < 30; index++)
        AnnouncementContentBlock.text('后续普通段落 $index'),
    ], query: '搜索目标'));
    final article = find.byKey(
      const ValueKey('announcement-search-matched-article'),
    );
    await _waitForBody(tester);
    await _waitForPrefixMetrics(tester);
    await tester.pump(const Duration(milliseconds: 260));
    // The first animation tick establishes its timestamp before elapsed time.
    await tester.pump();
    final controller = tester.widget<CustomScrollView>(article).controller!;
    final initialOffset = controller.offset;
    expect(initialOffset, 0);
    expect(controller.position.isScrollingNotifier.value, isTrue);

    await tester.pump(const Duration(milliseconds: 100));
    final intermediateOffset = controller.offset;
    expect(intermediateOffset, greaterThan(initialOffset));
    expect(controller.position.isScrollingNotifier.value, isTrue);

    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(intermediateOffset));
    final target = find.byWidgetPredicate((widget) =>
        widget is SelectableText &&
        widget.textSpan?.toPlainText() == paragraph);
    final editable = _editable(tester, target);
    final start = paragraph.indexOf('搜索目标');
    final box = editable
        .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 4))
        .first;
    final matchY = editable.localToGlobal(Offset(0, box.top)).dy;
    expect(
        matchY,
        closeTo(
            tester.getTopLeft(article).dy +
                controller.position.viewportDimension * 0.18,
            1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
    expect(find.byType(SelectableText).evaluate().length, lessThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'distant first body match scrolls into place with lazy prior blocks',
      (tester) async {
    final blocks = [
      for (var index = 0; index < 700; index++)
        AnnouncementContentBlock.text('普通段落 $index。这里是与检索无关的公告正文。'),
      const AnnouncementContentBlock.text('先找到 Beta，随后是 alpha，最后又有 Beta。'),
      for (var index = 0; index < 50; index++)
        AnnouncementContentBlock.text('后续段落 $index'),
    ];
    await tester.pumpWidget(_app(blocks, query: 'alpha beta'));
    await _settleArticle(tester);

    final target = find.byWidgetPredicate((widget) =>
        widget is SelectableText &&
        widget.textSpan?.toPlainText() == blocks[700].value);
    expect(target, findsOneWidget);
    final text = tester.widget<SelectableText>(target);
    final colored = _spans(text.textSpan!)
        .where((span) => span.style?.color == _primary)
        .toList();
    expect(colored.map((span) => span.text), ['Beta']);
    expect(find.byType(SelectableText).evaluate().length, lessThan(40));
    final editable = _editable(tester, target);
    final box = editable
        .getBoxesForSelection(
            const TextSelection(baseOffset: 4, extentOffset: 8))
        .first;
    final y = editable.localToGlobal(Offset(0, box.top)).dy;
    expect(y, greaterThan(70));
    expect(y, lessThan(300));
    final view = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('announcement-search-matched-article')));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await _settleArticle(tester);
    final offset = view.controller!.offset;
    await tester.pump(const Duration(seconds: 1));
    expect(view.controller!.offset, offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'match deep inside one paragraph scrolls the matching line into view',
      (tester) async {
    final prefix = List.filled(100, '这是一段普通文字。').join();
    final paragraph = '$prefix 搜索目标 后续文字 搜索目标';
    await tester.pumpWidget(_app([
      AnnouncementContentBlock.text(paragraph),
      const AnnouncementContentBlock.text('结束'),
    ], query: '搜索目标'));
    await _settleArticle(tester);

    final target = find.byWidgetPredicate((widget) =>
        widget is SelectableText &&
        widget.textSpan?.toPlainText() == paragraph);
    final editable = _editable(tester, target);
    final start = paragraph.indexOf('搜索目标');
    final box = editable
        .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 4))
        .first;
    final y = editable.localToGlobal(Offset(0, box.top)).dy;
    expect(y, greaterThan(70));
    // Near the article end, the ordinary scroll bounds keep the line lower
    // instead of adding blank content merely to center the search hit.
    expect(y, lessThan(550));
    final scroll =
        tester.widget<CustomScrollView>(find.byType(CustomScrollView));
    expect(scroll.controller!.offset, greaterThan(0));
    expect(scroll.controller!.offset,
        closeTo(scroll.controller!.position.maxScrollExtent, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlighted inline links retain their recognizer and icon',
      (tester) async {
    await tester.pumpWidget(_app(const [
      AnnouncementContentBlock.text('请访问搜索目标了解详情。', parts: [
        AnnouncementInlinePart('请访问'),
        AnnouncementInlinePart('搜索目标', url: 'https://www.shu.edu.cn/'),
        AnnouncementInlinePart('了解详情。'),
      ]),
    ], query: '目标'));
    await _settleArticle(tester);
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    final match =
        _spans(text.textSpan!).singleWhere((span) => span.text == '目标');
    expect(match.style?.color, _primary);
    expect(match.style?.fontWeight, FontWeight.w600);
    expect(match.recognizer, isA<TapGestureRecognizer>());
    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('title-only match is colored and stays at the article heading',
      (tester) async {
    await tester.pumpWidget(_app(const [AnnouncementContentBlock.text('正文')],
        query: '测试', title: '测试公告测试'));
    await _settleArticle(tester);
    final title = tester.widget<Text>(find.byWidgetPredicate((widget) =>
        widget is Text && widget.textSpan?.toPlainText() == '测试公告测试'));
    expect(
        _spans(title.textSpan!)
            .where((span) => span.style?.color == _primary)
            .map((span) => span.text),
        ['测试', '测试']);
    expect(
        tester.widget<ListView>(find.byType(ListView)).controller!.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'all title terms are colored even when the body has a different first match',
      (tester) async {
    await tester.pumpWidget(_app([
      for (var index = 0; index < 50; index++)
        AnnouncementContentBlock.text('普通段落 $index'),
      const AnnouncementContentBlock.text('正文先找到目标，随后还有 Alpha。'),
      for (var index = 0; index < 30; index++)
        AnnouncementContentBlock.text('后续段落 $index'),
    ], title: 'Alpha 公告目标 Beta 目标', query: 'alpha beta 目标'));
    await _waitForBody(tester);
    final title = tester.widget<Text>(find.byWidgetPredicate((widget) =>
        widget is Text &&
        widget.textSpan?.toPlainText() == 'Alpha 公告目标 Beta 目标'));
    expect(
        _spans(title.textSpan!)
            .where((span) => span.style?.color == _primary)
            .map((span) => span.text),
        ['Alpha', '目标', 'Beta', '目标']);
    await _settleArticle(tester);
    final body = tester.widget<SelectableText>(find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.textSpan?.toPlainText() == '正文先找到目标，随后还有 Alpha。'));
    expect(
        _spans(body.textSpan!)
            .where((span) => span.style?.color == _primary)
            .map((span) => span.text),
        ['目标']);
    final article =
        tester.widget<CustomScrollView>(find.byType(CustomScrollView));
    expect(article.controller!.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  for (final query in ['', '不存在']) {
    testWidgets('query "$query" keeps the ordinary article list at its top',
        (tester) async {
      await tester.pumpWidget(_app([
        for (var index = 0; index < 100; index++)
          AnnouncementContentBlock.text('普通正文 $index'),
      ], query: query));
      await _settleArticle(tester);
      expect(find.byType(CustomScrollView), findsNothing);
      expect(
          tester.widget<ListView>(find.byType(ListView)).controller!.offset, 0);
      expect(find.text('测试公告'), findsOneWidget);
      final text =
          tester.widget<SelectableText>(find.byType(SelectableText).first);
      expect(
          _spans(text.textSpan!).where((span) => span.style?.color == _primary),
          isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('first match in a small table is colored and scrolled into view',
      (tester) async {
    await tester.pumpWidget(_app([
      for (var index = 0; index < 100; index++)
        AnnouncementContentBlock.text('普通正文 $index'),
      AnnouncementContentBlock.table([
        [for (var column = 0; column < 12; column++) '项目 $column'],
        [
          for (var column = 0; column < 12; column++)
            column == 11 ? '首个目标，随后目标' : '普通 $column'
        ],
      ]),
    ], query: '目标'));
    await _settleArticle(tester);
    final target = find.byWidgetPredicate((widget) =>
        widget is SelectableText &&
        widget.textSpan?.toPlainText() == '首个目标，随后目标');
    final text = tester.widget<SelectableText>(target);
    expect(
        _spans(text.textSpan!)
            .where((span) => span.style?.color == _primary)
            .map((span) => span.text),
        ['目标']);
    final editable = _editable(tester, target);
    final box = editable
        .getBoxesForSelection(
            const TextSelection(baseOffset: 2, extentOffset: 4))
        .first;
    final y = editable.localToGlobal(Offset(0, box.top)).dy;
    expect(y, greaterThan(70));
    // At the article end the natural bounds keep this short table lower in
    // the viewport, without adding empty space below the content.
    expect(y, lessThan(550));
    final x = editable.localToGlobal(Offset(box.left, 0)).dx;
    expect(x, greaterThanOrEqualTo(20));
    expect(x, lessThan(780));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'large table retains fast painting and reveals a distant matching cell',
      (tester) async {
    await tester.pumpWidget(_app([
      AnnouncementContentBlock.table([
        for (var row = 0; row < 150; row++)
          [
            for (var column = 0; column < 8; column++)
              row == 120 && column == 7 ? '首个目标，随后目标' : '$row / $column'
          ],
      ]),
    ], query: '目标'));
    final fast = find.byKey(const ValueKey('announcement-fast-table'));
    await _waitForBody(tester);
    for (var frame = 0; frame < 100 && fast.evaluate().isEmpty; frame++) {
      await tester.pump();
    }
    final beforePause = tester.widget<SingleChildScrollView>(find.descendant(
        of: fast, matching: find.byType(SingleChildScrollView)));
    expect(beforePause.controller!.offset, 0);
    final article = tester.widget<CustomScrollView>(
        find.byKey(const ValueKey('announcement-search-matched-article')));
    expect(article.controller!.offset, 0);
    expect(tester.getTopLeft(find.text('测试公告')).dy, lessThan(100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(beforePause.controller!.offset, 0);
    expect(article.controller!.offset, 0);
    await _settleArticle(tester);
    expect(fast, findsOneWidget);
    final paintFinder =
        find.descendant(of: fast, matching: find.byType(CustomPaint));
    final dynamic painter = tester.widget<CustomPaint>(paintFinder).painter!;
    final dynamic layout = painter.layout;
    final dynamic cell = (layout.cells as List).singleWhere(
        (dynamic entry) => entry.cell.row == 120 && entry.cell.column == 7);
    final TextPainter textPainter = layout.painterFor(cell) as TextPainter;
    expect(
        _spans(textPainter.text!)
            .where((span) => span.style?.color == _primary)
            .map((span) => span.text),
        ['目标']);
    final horizontal = tester.widget<SingleChildScrollView>(find.descendant(
        of: fast, matching: find.byType(SingleChildScrollView)));
    expect(horizontal.controller!.offset, greaterThan(0));
    final rect = cell.rect as Rect;
    final render = tester.renderObject<RenderBox>(paintFinder);
    final y = render.localToGlobal(Offset(0, rect.top)).dy;
    expect(y, greaterThan(40));
    expect(y, lessThan(300));
    expect(find.byType(SelectableText).evaluate().length, lessThan(10));
    expect(tester.takeException(), isNull);
  });
}
