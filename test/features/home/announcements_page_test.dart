import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';
import 'package:shuyo/features/home/announcements_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';

const _listTitle = '关于开展实验室安全检查的通知';
const _detailBody = '各单位请于本周五前完成自查';
const _imageUrl = 'https://www.shu.edu.cn/__local/0/94/a.png';

const _listItem = AnnouncementListItem(
  title: _listTitle,
  url: 'https://www.shu.edu.cn/info/1051/1.htm',
);

class _FakeAnnouncementRepository extends AnnouncementRepository {
  _FakeAnnouncementRepository({
    required this.items,
    required this.details,
    this.previewFutures = const {},
  });

  final List<AnnouncementListItem> items;
  final Map<String, AnnouncementDetail> details;
  final Map<String, Future<String?>> previewFutures;
  int detailRequestCount = 0;
  final previewRequests = <String>[];
  AnnouncementSource currentDefault = AnnouncementSource.official;
  final favoriteIds = <String>{};
  final sectionExpansion = <AnnouncementMenuSection, bool>{};
  final requestedSources = <String>[];

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    requestedSources.add((source ?? currentDefault).id);
    return items;
  }

  @override
  Future<AnnouncementSource> defaultSource() async => currentDefault;

  @override
  Future<void> setDefaultSource(AnnouncementSource source) async {
    currentDefault = source;
  }

  @override
  Future<Set<String>> favoriteSourceIds() async => {...favoriteIds};

  @override
  Future<Set<String>> toggleFavoriteSource(AnnouncementSource source) async {
    if (!favoriteIds.add(source.id)) favoriteIds.remove(source.id);
    return {...favoriteIds};
  }

  @override
  Future<AnnouncementMenuExpansion> menuExpansion() async => (
        favorites: sectionExpansion[AnnouncementMenuSection.favorites] ?? true,
        campus: sectionExpansion[AnnouncementMenuSection.campus] ?? true,
        college: sectionExpansion[AnnouncementMenuSection.college] ?? false,
      );

  @override
  Future<void> saveMenuExpansion(
    AnnouncementMenuSection section,
    bool expanded,
  ) async {
    sectionExpansion[section] = expanded;
  }

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async {
    detailRequestCount++;
    return details[item.title]!;
  }

  @override
  Future<String?> loadPreview(AnnouncementListItem item) async {
    previewRequests.add(item.url);
    final pending = previewFutures[item.url];
    if (pending != null) return pending;
    final blocks =
        details[item.title]?.blocks ?? const <AnnouncementContentBlock>[];
    for (final block in blocks) {
      if (block.isText) return block.value;
    }
    return null;
  }
}

class _ShortPageAnnouncementRepository extends _FakeAnnouncementRepository {
  _ShortPageAnnouncementRepository()
      : super(
          items: const [],
          details: const {},
        );

  int pagesLoaded = 0;

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    if (loadNextPage) pagesLoaded++;
    return [
      const AnnouncementListItem(
        title: '第一页公告',
        url: 'https://example.org/first',
      ),
      if (pagesLoaded > 0)
        const AnnouncementListItem(
          title: '第二页公告',
          url: 'https://example.org/second',
        ),
    ];
  }

  @override
  bool hasMoreAnnouncements({AnnouncementSource? source}) => pagesLoaded == 0;
}

_FakeAnnouncementRepository _repositoryWith({
  List<AnnouncementContentBlock> blocks = const [
    AnnouncementContentBlock.text(_detailBody),
  ],
}) {
  return _FakeAnnouncementRepository(
    items: const [_listItem],
    details: {
      _listTitle: AnnouncementDetail(
        title: _listTitle,
        url: _listItem.url,
        blocks: blocks,
      ),
    },
  );
}

Future<void> _openDetail(
    WidgetTester tester, AnnouncementRepository repository) async {
  await tester.pumpWidget(
    MaterialApp(home: AnnouncementsPage(repository: repository)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(_listTitle));
}

void main() {
  testWidgets('school notice tap surface spans the screen width',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: _repositoryWith()),
    ));
    await tester.pumpAndSettle();
    final ripple = find
        .ancestor(
          of: find.text(_listTitle),
          matching: find.byType(InkWell),
        )
        .first;
    expect(tester.getRect(ripple).left, 0);
    expect(tester.getSize(ripple).width, 320);
  });

  testWidgets('favorites are independent from the current and default source',
      (tester) async {
    final repository = _repositoryWith();
    await tester.pumpWidget(
      MaterialApp(
        home: AnnouncementsPage(key: UniqueKey(), repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.requestedSources, ['shu']);

    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(
        tester.getTopLeft(find.text('收藏')).dx,
        greaterThan(
            tester.view.physicalSize.width / tester.view.devicePixelRatio / 2));
    expect(find.byType(ModalBarrier), findsWidgets);
    expect(find.byIcon(Icons.star), findsNothing);
    expect(find.textContaining('设为默认'), findsNothing);
    await tester.tap(find.byTooltip('收藏本科生院'));
    await tester.pumpAndSettle();
    expect(repository.favoriteIds, {'bksy'});
    expect(repository.currentDefault.id, 'shu');
    expect(repository.requestedSources, ['shu']);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsNWidgets(2));
    expect(find.text('本科生院'), findsNWidgets(2));
    final star = find.byIcon(Icons.star).first;
    expect(tester.widget<Icon>(star).color,
        Theme.of(tester.element(star)).colorScheme.primary);
    expect(find.text(_listTitle), findsOneWidget);

    await tester.tap(find.byTooltip('收藏本科生工作处'));
    await tester.pumpAndSettle();
    expect(repository.favoriteIds, {'bksy', 'xgb'});
    expect(find.byIcon(Icons.star), findsNWidgets(4));

    await tester.tap(find.text('本科生院').first);
    await tester.pumpAndSettle();
    expect(repository.requestedSources.last, 'bksy');

    await tester.pumpWidget(
      MaterialApp(
        home: AnnouncementsPage(key: UniqueKey(), repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.requestedSources.last, 'shu');
  });

  testWidgets('source menu scrolls and college group folds', (tester) async {
    final repository = _repositoryWith();
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(ListView).last).height,
      lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.8),
    );
    expect(find.text('国际教育学院'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('学院与培养单位'),
      200,
      scrollable: find.descendant(
        of: find.byKey(announcementSourceMenuKey),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    expect(find.text('学院与培养单位'), findsOneWidget);
    await tester.tap(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('国际教育学院'),
      140,
      scrollable: find.descendant(
        of: find.byKey(announcementSourceMenuKey),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('国际教育学院'), findsOneWidget);
    await tester.ensureVisible(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    expect(find.text('国际教育学院'), findsNothing);
    expect(
        repository.sectionExpansion[AnnouncementMenuSection.college], isFalse);
  });

  testWidgets('source menu restores all group states when reopened',
      (tester) async {
    final repository = _repositoryWith();
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏'), findsOneWidget);
    expect(find.text('上海大学官网'), findsOneWidget);
    expect(find.text('国际教育学院'), findsNothing);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('校级与公共服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    expect(repository.sectionExpansion, {
      AnnouncementMenuSection.favorites: false,
      AnnouncementMenuSection.campus: false,
      AnnouncementMenuSection.college: true,
    });

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏'), findsNothing);
    expect(find.text('上海大学官网'), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('国际教育学院'), findsOneWidget);
  });

  testWidgets('source menu stays narrow with a dismissible left mask',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = _repositoryWith();
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();

    final menu = find.byKey(announcementSourceMenuKey);
    expect(tester.getSize(menu).width, 264);
    expect(tester.getTopLeft(menu).dx, closeTo(390 - 264 - 12, 1));
    expect(find.descendant(of: menu, matching: find.byType(Scrollbar)),
        findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('研究生院'),
      140,
      scrollable: find.descendant(of: menu, matching: find.byType(Scrollable)),
    );
    expect(tester.widget<Text>(find.text('研究生院')).maxLines, 2);
    await tester.scrollUntilVisible(
      find.byTooltip('收藏本科生院'),
      140,
      scrollable: find.descendant(of: menu, matching: find.byType(Scrollable)),
    );
    await tester.ensureVisible(find.byTooltip('收藏本科生院'));
    await tester.pumpAndSettle();
    final starButton = find
        .ancestor(
          of: find.byTooltip('收藏本科生院'),
          matching: find.byType(IconButton),
        )
        .first;
    expect(tester.getSize(starButton), const Size.square(40));
    expect(tester.widget<IconButton>(starButton).style?.shape?.resolve({}),
        isA<CircleBorder>());
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    expect(tester.getSize(menu).width, closeTo(320 * 0.68, 0.1));
    expect(tester.getTopLeft(menu).dx, closeTo(320 - 320 * 0.68 - 12, 1));
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
  });

  testWidgets('Vancouver Film School cards hide both column labels',
      (tester) async {
    final repository = _FakeAnnouncementRepository(
      items: const [
        AnnouncementListItem(
          title: '电影学院新闻',
          url: 'https://www.shvfs.cn/site/newsDetail/1',
          sourceId: 'shvfs',
          column: '学院动态',
          summary: '学院新闻摘要',
          dateText: '2026-10-06',
        ),
        AnnouncementListItem(
          title: '媒体报道',
          url: 'https://www.shvfs.cn/site/newsDetail/2',
          sourceId: 'shvfs',
          column: '媒体关注',
          summary: '媒体新闻摘要',
          dateText: '2026-10-05',
        ),
      ],
      details: const {},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026-10-06'), findsOneWidget);
    expect(find.text('2026-10-05'), findsOneWidget);
    expect(find.textContaining('学院动态'), findsNothing);
    expect(find.textContaining('媒体关注'), findsNothing);
  });

  testWidgets('previews for later rows start after scrolling', (tester) async {
    final items = List.generate(
      30,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/1000/$index.htm',
        sourceId: 'bksy',
      ),
    );
    final repository =
        _FakeAnnouncementRepository(items: items, details: const {});
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final initiallyRequested = repository.previewRequests.length;
    expect(initiallyRequested, greaterThan(0));
    expect(initiallyRequested, lessThan(items.length));

    await tester.drag(find.byType(ListView).first, const Offset(0, -1150));
    await tester.pumpAndSettle();
    expect(repository.previewRequests.length, greaterThan(initiallyRequested));
    expect(repository.previewRequests.length, lessThan(items.length));
  });

  testWidgets('list appears while the first preview is still loading',
      (tester) async {
    final pending = Completer<String?>();
    const item = AnnouncementListItem(
      title: '等待正文的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/wait.htm',
      sourceId: 'bksy',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      previewFutures: {item.url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    expect(find.byType(ListView), findsWidgets);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.text(item.title), findsNothing);
    expect(repository.previewRequests, [item.url]);

    pending.complete('完整正文摘要');
    await tester.pumpAndSettle();
    expect(find.text(item.title), findsOneWidget);
    expect(find.text('完整正文摘要'), findsOneWidget);
    expect(find.byType(SlideTransition), findsWidgets);
  });

  testWidgets('notices reveal in date order despite out-of-order previews',
      (tester) async {
    final pending = Completer<String?>();
    final oldItem = AnnouncementListItem(
      title: '旧通知',
      url: 'https://bksy.shu.edu.cn/info/1000/old.htm',
      sourceId: 'bksy',
      publishedAt: DateTime(2025, 1, 1),
      summary: '已有概览',
    );
    final newItem = AnnouncementListItem(
      title: '新通知',
      url: 'https://bksy.shu.edu.cn/info/1000/new.htm',
      sourceId: 'bksy',
      publishedAt: DateTime(2026, 1, 1),
    );
    final repository = _FakeAnnouncementRepository(
      items: [oldItem, newItem],
      details: const {},
      previewFutures: {newItem.url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('旧通知'), findsNothing);
    expect(find.text('新通知'), findsNothing);
    pending.complete('新通知概览');
    await tester.pumpAndSettle();
    expect(find.text('新通知'), findsOneWidget);
    expect(find.text('旧通知'), findsOneWidget);
    expect(tester.getTopLeft(find.text('新通知')).dy,
        lessThan(tester.getTopLeft(find.text('旧通知')).dy));
  });

  testWidgets('short previews keep the original compact card layout',
      (tester) async {
    const shortItem = AnnouncementListItem(
      title: '短公告',
      url: 'https://bksy.shu.edu.cn/info/1000/short.htm',
      sourceId: 'bksy',
      summary: '已结束。',
    );
    const longItem = AnnouncementListItem(
      title: '长公告',
      url: 'https://bksy.shu.edu.cn/info/1000/long.htm',
      sourceId: 'bksy',
      summary: '这是一段明显超过一行的公告概览，需要在列表卡片中显示两行内容，'
          '用来验证短概览不会被强制撑到同样的高度。'
          '这是一段明显超过一行的公告概览，需要在列表卡片中显示两行内容，'
          '用来验证短概览不会被强制撑到同样的高度。',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [shortItem, longItem],
      details: const {},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(ValueKey(shortItem.url))).height,
        lessThan(tester.getSize(find.byKey(ValueKey(longItem.url))).height));
    expect(find.byType(Scrollbar), findsOneWidget);
  });

  testWidgets('slow short previews fill the card without an empty text area',
      (tester) async {
    final pending = Completer<String?>();
    const item = AnnouncementListItem(
      title: '慢正文通知',
      url: 'https://bksy.shu.edu.cn/info/1000/slow.htm',
      sourceId: 'bksy',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      previewFutures: {item.url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text(item.title), findsOneWidget);
    pending.complete('延迟返回的概览');
    await tester.pumpAndSettle();
    expect(find.text('延迟返回的概览'), findsOneWidget);
    expect(
        tester.getSize(find.byKey(ValueKey(item.url))).height, lessThan(104));
  });

  testWidgets('scrolled-to rows wait for their preview before sliding in',
      (tester) async {
    final items = List.generate(
      20,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/1000/$index.htm',
        sourceId: 'bksy',
      ),
    );
    final pending = Completer<String?>();
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
      previewFutures: {items[10].url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(repository.previewRequests, isNot(contains(items[10].url)));

    await tester.scrollUntilVisible(
      find.byKey(ValueKey(items[10].url)),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(repository.previewRequests, contains(items[10].url));
    expect(find.text(items[10].title), findsNothing);

    pending.complete('滚动后才加载的摘要');
    await tester.pumpAndSettle();
    expect(find.text(items[10].title), findsOneWidget);
    expect(find.text('滚动后才加载的摘要'), findsOneWidget);
  });

  testWidgets('share button copies the article URL', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final repository = _repositoryWith();
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: _listItem),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复制公告链接'));
    await tester.pump();
    expect(copied, _listItem.url);
    expect(find.text('公告链接已复制'), findsOneWidget);
  });

  testWidgets('opening the original page requires confirmation',
      (tester) async {
    final repository = _repositoryWith();
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: _listItem),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看原文'));
    await tester.pumpAndSettle();
    expect(find.text('跳转浏览器'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('跳转浏览器'), findsNothing);
  });

  testWidgets('inline links retain their matching icons in article text',
      (tester) async {
    final repository = _repositoryWith(blocks: const [
      AnnouncementContentBlock.text(
        '联系 office@example.org 或查看说明',
        parts: [
          AnnouncementInlinePart('联系 '),
          AnnouncementInlinePart('office@example.org',
              url: 'mailto:office@example.org'),
          AnnouncementInlinePart(' 或查看'),
          AnnouncementInlinePart('说明', url: 'https://example.org/help'),
        ],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: _listItem),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsAtLeastNWidgets(2));
    expect(find.byType(SelectableText), findsWidgets);
    final paragraph = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((widget) =>
            widget.textSpan
                ?.toPlainText()
                .replaceAll('\u200B', '')
                .contains('office@example.org') ==
            true);
    final link = (paragraph.textSpan!.children!.last as TextSpan).children!.last
        as TextSpan;
    expect(
        link.style?.decorationColor,
        Theme.of(tester.element(find.byType(SelectableText).first))
            .colorScheme
            .primary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment and PDF links keep their standalone buttons',
      (tester) async {
    final repository = _repositoryWith(blocks: const [
      AnnouncementContentBlock.link('https://example.org/notice.pdf',
          label: '查看原始 PDF'),
      AnnouncementContentBlock.link('https://example.org/attachment.docx',
          label: '下载附件'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: _listItem),
    ));
    await tester.pumpAndSettle();

    for (final label in ['查看原始 PDF', '下载附件']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextButton),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<TextButton>(button).style, isNull);
      expect(
        find.descendant(of: button, matching: find.byIcon(Icons.open_in_new)),
        findsOneWidget,
      );
    }
  });

  testWidgets('split mail anchors render as one inline mail link',
      (tester) async {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content"><p>邮箱：'
      '<a href="mailto:info@mathworks.cn">i</a>'
      '<a href="mailto:info@mathworks.cn">nfo@mathworks.cn</a></p></div>',
      url: _listItem.url,
      fallbackTitle: _listTitle,
    );
    final repository = _FakeAnnouncementRepository(
      items: const [_listItem],
      details: {_listTitle: detail},
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: _listItem),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    final paragraph = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .singleWhere((widget) =>
            widget.textSpan
                ?.toPlainText()
                .replaceAll('\u200B', '')
                .contains('info@mathworks.cn') ==
            true);
    expect(
        paragraph.textSpan!
            .toPlainText()
            .replaceAll('\uFFFC', '')
            .replaceAll('\u200B', ''),
        '邮箱：info@mathworks.cn');
  });

  testWidgets('non-info announcement links skip parsing and open externally',
      (tester) async {
    const item = AnnouncementListItem(
      title: '关于2026年下半年博士后人员高级专业技术职务申报的通知',
      url: 'https://hr.shu.edu.cn/content.jsp?urltype=news.NewsContentUrl'
          '&wbtreeid=1029&wbnewsid=8469',
      sourceId: 'hr',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          blocks: const [AnnouncementContentBlock.text('申报详情')],
        ),
      },
    );
    const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
    String? openedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncher,
      (call) async {
        openedUrl = (call.arguments as Map<Object?, Object?>)['url'] as String?;
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncher, null));
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();

    expect(find.byType(AnnouncementDetailPage), findsNothing);
    expect(repository.detailRequestCount, 0);
    expect(repository.previewRequests, isEmpty);
    expect(openedUrl, item.url);
  });

  testWidgets('Vancouver Film School detail opens in app with body preview',
      (tester) async {
    const item = AnnouncementListItem(
      title: '电影课堂的新实践',
      url: 'https://www.shvfs.cn/site/newsDetail/1624',
      sourceId: 'shvfs',
      summary: '列表页摘要',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          blocks: const [AnnouncementContentBlock.text('从正文解析出的两行概览')],
        ),
      },
    )..currentDefault = AnnouncementSource.byId('shvfs');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(repository.previewRequests, [item.url]);
    expect(find.text('从正文解析出的两行概览'), findsOneWidget);
    expect(find.text('列表页摘要'), findsNothing);
    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
    expect(repository.detailRequestCount, 1);
  });

  testWidgets('short first announcement page loads history automatically',
      (tester) async {
    final repository = _ShortPageAnnouncementRepository();
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(repository.pagesLoaded, 1);
    expect(find.text('第二页公告'), findsOneWidget);
  });

  testWidgets('cross-subdomain info articles try in-app detail parsing',
      (tester) async {
    const items = [
      AnnouncementListItem(
        title: '翔英学院通知',
        url: 'https://scie.shu.edu.cn/info/1070/46185.htm',
        sourceId: 'xiangying',
      ),
      AnnouncementListItem(
        title: 'HTML 格式通知',
        url: 'https://other.shu.edu.cn/info/1003/16043.html',
        sourceId: 'hr',
      ),
      AnnouncementListItem(
        title: 'HMTL 格式通知',
        url: 'https://other.shu.edu.cn/info/1003/16043.hmtl',
        sourceId: 'hr',
      ),
    ];
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: {
        for (final item in items)
          item.title: AnnouncementDetail(
            title: item.title,
            url: item.url,
            blocks: const [AnnouncementContentBlock.text('跨站正文')],
          ),
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(
        repository.previewRequests, containsAll(items.map((item) => item.url)));
    for (final item in items) {
      await tester.tap(find.text(item.title));
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDetailPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(repository.detailRequestCount, items.length);
  });

  testWidgets('incomplete info URLs open outside the app', (tester) async {
    const item = AnnouncementListItem(
      title: '跨站公告',
      url: 'https://other.shu.edu.cn/info/1.htm',
      sourceId: 'hr',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
    );
    const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
    String? openedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncher,
      (call) async {
        openedUrl = (call.arguments as Map<Object?, Object?>)['url'] as String?;
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncher, null));
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();

    expect(find.byType(AnnouncementDetailPage), findsNothing);
    expect(repository.detailRequestCount, 0);
    expect(openedUrl, item.url);
  });

  testWidgets('unparsed WeChat articles open their original link externally',
      (tester) async {
    const item = AnnouncementListItem(
      title: '微信公众号公告',
      url: 'https://mp.weixin.qq.com/s/example',
      sourceId: 'hr',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          blocks: const [],
        ),
      },
    );
    const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
    String? openedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncher,
      (call) async {
        openedUrl = (call.arguments as Map<Object?, Object?>)['url'] as String?;
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncher, null));
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();

    expect(repository.detailRequestCount, 0);
    expect(openedUrl, item.url);
    expect(find.byType(AnnouncementDetailPage), findsNothing);
  });

  testWidgets('unparsed articles fall back to the original link',
      (tester) async {
    const item = AnnouncementListItem(
      title: '无法解析正文的公告',
      url: 'https://hr.shu.edu.cn/info/1000/1.htm',
      sourceId: 'hr',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          blocks: const [],
        ),
      },
    );
    const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
    String? openedUrl;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncher,
      (call) async {
        openedUrl = (call.arguments as Map<Object?, Object?>)['url'] as String?;
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(urlLauncher, null));
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();

    expect(repository.detailRequestCount, 1);
    expect(openedUrl, item.url);
    expect(find.byType(AnnouncementDetailPage), findsNothing);
  });

  testWidgets('announcement separators remain in presets and hide in custom',
      (tester) async {
    final repository = _FakeAnnouncementRepository(
      items: const [
        _listItem,
        AnnouncementListItem(
          title: '第二条公告',
          url: 'https://www.shu.edu.cn/info/1051/2.htm',
        ),
      ],
      details: const {},
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsOneWidget);

    const theme = CustomBackground(
      imagePath: '',
      opacity: 0,
      background: Color(0xFFF8F8F8),
      surface: Colors.white,
      text: Colors.black,
      accent: Colors.blue,
    );
    await tester.pumpWidget(MaterialApp(
      theme: theme.theme.themeData(),
      builder: (_, child) => CustomBackgroundFrame(
        settings: theme,
        child: child!,
      ),
      home: AnnouncementsPage(repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('detail body waits for the push animation', (tester) async {
    final repository = _repositoryWith();
    await _openDetail(tester, repository);

    await tester.pump();
    // The request is fired on the first frame, but the body waits for the
    // transition to finish.
    expect(repository.detailRequestCount, 1);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final detailText = find.descendant(
      of: find.byType(AnnouncementDetailPage),
      matching: find.text(_detailBody),
    );
    expect(detailText, findsNothing);

    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(detailText, findsOneWidget);
  });

  testWidgets('loading state can reuse its layer during the transition',
      (tester) async {
    final repository = _repositoryWith();
    await _openDetail(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // The loading state carries its own repaint boundary, so the transition
    // does not drag the whole page into a repaint.
    expect(
      find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('detail images are decoded at the displayed width',
      (tester) async {
    final repository = _repositoryWith(
      blocks: const [
        AnnouncementContentBlock.text(_detailBody),
        AnnouncementContentBlock.image(_imageUrl),
      ],
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());

    final context = tester.element(find.byType(Image));
    final displayPixels = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (provider as ResizeImage).width!;
    // Decoded at the displayed width: below the screen's pixel width, but not
    // small enough to look blurry.
    expect(decodeWidth, lessThanOrEqualTo(displayPixels.round()));
    expect(decodeWidth, greaterThan((displayPixels * 0.8).round()));
    expect(image.frameBuilder, isNotNull);
  });

  testWidgets('detail tables remain readable inside the app', (tester) async {
    final repository = _repositoryWith(
      blocks: const [
        AnnouncementContentBlock.text('评审结果'),
        AnnouncementContentBlock.table([
          ['姓名', '学院'],
          ['张同学', '理学院'],
        ]),
      ],
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('评审结果'), findsOneWidget);
    expect(find.text('张同学'), findsOneWidget);
    expect(find.text('理学院'), findsOneWidget);
  });

  testWidgets('detail images reserve height before they are decoded',
      (tester) async {
    final repository = _repositoryWith(
      blocks: const [
        AnnouncementContentBlock.text(_detailBody),
        AnnouncementContentBlock.image(_imageUrl),
      ],
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    final placeholder = find.byKey(announcementImagePlaceholderKey);
    if (placeholder.evaluate().isEmpty) {
      // If the image fails first it renders through errorBuilder, which also
      // rules out a zero height.
      expect(find.text('图片加载失败'), findsOneWidget);
      return;
    }
    expect(tester.getSize(placeholder).height, greaterThan(0));
  });
}
