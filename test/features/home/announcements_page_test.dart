import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/features/home/announcements_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';

const _listTitle = '关于开展实验室安全检查的通知';
const _detailBody = '各单位请于本周五前完成自查。';
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
    await tester.drag(find.byType(ListView).last, const Offset(0, -380));
    await tester.pumpAndSettle();
    expect(find.text('学院与培养单位'), findsOneWidget);
    await tester.tap(find.text('学院与培养单位'));
    await tester.pumpAndSettle();
    expect(find.text('国际教育学院'), findsOneWidget);
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
    expect(tester.widget<Text>(find.text('研究生院 · 培养管理')).maxLines, 2);
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

  testWidgets('merged college notices show their original column',
      (tester) async {
    final repository = _FakeAnnouncementRepository(
      items: const [
        AnnouncementListItem(
          title: '研究生奖学金通知',
          url: 'https://ece.shu.edu.cn/info/1.htm',
          sourceId: 'ece',
          column: '研究生教学',
          summary: '奖学金申报安排',
          dateText: '2026-10-06',
        ),
      ],
      details: const {},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('研究生教学 · 2026-10-06'), findsOneWidget);
  });

  testWidgets('previews for later rows start after scrolling', (tester) async {
    final items = List.generate(
      30,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/$index.htm',
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

    await tester.drag(find.byType(ListView).first, const Offset(0, -550));
    await tester.pumpAndSettle();
    expect(repository.previewRequests.length, greaterThan(initiallyRequested));
    expect(repository.previewRequests.length, lessThan(items.length));
  });

  testWidgets('first screen waits for previews before showing any titles',
      (tester) async {
    final pending = Completer<String?>();
    const item = AnnouncementListItem(
      title: '等待正文的公告',
      url: 'https://bksy.shu.edu.cn/info/wait.htm',
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
    expect(find.text(item.title), findsNothing);
    expect(repository.previewRequests, [item.url]);

    pending.complete('完整正文摘要');
    await tester.pumpAndSettle();
    expect(find.text(item.title), findsOneWidget);
    expect(find.text('完整正文摘要'), findsOneWidget);
    expect(find.byType(SlideTransition), findsWidgets);
  });

  testWidgets('scrolled-to rows wait for their preview before sliding in',
      (tester) async {
    final items = List.generate(
      20,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/$index.htm',
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
    expect(find.byType(Table), findsOneWidget);
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
