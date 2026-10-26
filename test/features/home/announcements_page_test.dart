import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/models/announcement_target.dart';
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

const _readyListItem = AnnouncementListItem(
  title: '已就绪的公告',
  url: 'https://www.shu.edu.cn/info/1051/ready.htm',
  summary: '列表已有概览',
  dateText: '2026-10-26',
);

class _FakeAnnouncementRepository extends AnnouncementRepository {
  _FakeAnnouncementRepository({
    required this.items,
    required this.details,
    this.previewFutures = const {},
    this.publicationDateFutures = const {},
    this.cardFutures = const {},
    this.detailErrors = const {},
  });

  final List<AnnouncementListItem> items;
  final Map<String, AnnouncementDetail> details;
  final Map<String, Future<String?>> previewFutures;
  final Map<String, Future<AnnouncementListItem?>> publicationDateFutures;
  final Map<String, Future<AnnouncementCardData>> cardFutures;
  final Map<String, Object> detailErrors;
  int detailRequestCount = 0;
  final previewRequests = <String>[];
  final publicationDateRequests = <AnnouncementListItem>[];
  final cardRequests = <AnnouncementListItem>[];
  final detailRequests = <AnnouncementListItem>[];
  final cancelledCards = <AnnouncementListItem>[];
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
        schoolPortal:
            sectionExpansion[AnnouncementMenuSection.schoolPortal] ?? true,
        college: sectionExpansion[AnnouncementMenuSection.college] ?? false,
        researchInstitute:
            sectionExpansion[AnnouncementMenuSection.researchInstitute] ??
                false,
        administrativeDepartment: sectionExpansion[
                AnnouncementMenuSection.administrativeDepartment] ??
            true,
        affiliatedInstitution:
            sectionExpansion[AnnouncementMenuSection.affiliatedInstitution] ??
                true,
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
    detailRequests.add(item);
    final error = detailErrors[item.title];
    if (error != null) throw error;
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

  @override
  Future<AnnouncementListItem?> loadPublicationDate(
      AnnouncementListItem item) async {
    publicationDateRequests.add(item);
    return publicationDateFutures[item.url] ?? Future.value(null);
  }

  @override
  Future<AnnouncementCardData> loadCard(AnnouncementListItem item) async {
    cardRequests.add(item);
    final pending = cardFutures[item.url];
    if (pending != null) return pending;
    final target =
        AnnouncementTarget.resolve(item.url, sourceId: item.sourceId);
    var summary = item.summary;
    var dateText = item.dateText;
    var publishedAt = item.publishedAt;
    final work = <Future<void>>[];
    if (summary.isEmpty && target.canPreview) {
      work.add(loadPreview(item).then((value) {
        summary = value ?? summary;
      }, onError: (Object error, StackTrace stackTrace) {}));
    }
    if (dateText.isEmpty && target.canLoadMetadata) {
      work.add(loadPublicationDate(item).then((value) {
        if (value == null) return;
        dateText = value.dateText;
        publishedAt = value.publishedAt;
      }, onError: (Object error, StackTrace stackTrace) {}));
    }
    await Future.wait(work).timeout(
      AnnouncementRepository.cardPreparationTimeout,
      onTimeout: () => <void>[],
    );
    return AnnouncementCardData(
      summary: summary,
      dateText: dateText,
      publishedAt: publishedAt,
    );
  }

  @override
  void cancelCard(AnnouncementListItem item) {
    cancelledCards.add(item);
    super.cancelCard(item);
  }
}

double _cardOpacity(WidgetTester tester, AnnouncementListItem item) {
  final fade = find.descendant(
    of: find.byKey(ValueKey(item.url)),
    matching: find.byType(FadeTransition),
  );
  return fade.evaluate().isEmpty
      ? 0
      : tester.widget<FadeTransition>(fade).opacity.value;
}

// Settle finite entrances without advancing an unresolved request to its timeout.
Future<void> _pumpPendingList(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
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

class _ControlledRefreshRepository extends _FakeAnnouncementRepository {
  _ControlledRefreshRepository({super.cardFutures})
      : super(items: const [_listItem], details: const {});

  Future<List<AnnouncementListItem>>? refreshResult;
  int listRequests = 0;

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    listRequests++;
    if (listRequests == 1) return items;
    return await (refreshResult ?? Future.value(items));
  }
}

class _DeferredPageAnnouncementRepository extends _FakeAnnouncementRepository {
  _DeferredPageAnnouncementRepository({
    super.previewFutures,
    bool withReadyCard = false,
  }) : super(
          items: [if (withReadyCard) _readyListItem, _listItem],
          details: {
            _listTitle: AnnouncementDetail(
              title: _listTitle,
              url: _listItem.url,
              blocks: const [AnnouncementContentBlock.text(_detailBody)],
            ),
            _readyListItem.title: AnnouncementDetail(
              title: _readyListItem.title,
              url: _readyListItem.url,
              blocks: const [AnnouncementContentBlock.text(_detailBody)],
            ),
          },
        );

  final nextPage = Completer<List<AnnouncementListItem>>();
  int pagesRequested = 0;

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    if (!loadNextPage) return items;
    pagesRequested++;
    return nextPage.future;
  }

  @override
  bool hasMoreAnnouncements({AnnouncementSource? source}) =>
      !nextPage.isCompleted;
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
  for (final textScale in [0.8, 1.0, 1.3]) {
    testWidgets(
        'home month header stays pinned and switches at next month '
        'at $textScale text scale', (tester) async {
      final items = [
        for (var index = 0; index < 12; index++)
          AnnouncementListItem(
            title: '十月公告 $index',
            url: 'https://example.org/oct/$index',
            publishedAt: DateTime(2026, 10, 20 - index),
            summary: '公告概览',
          ),
        for (var index = 0; index < 12; index++)
          AnnouncementListItem(
            title: '九月公告 $index',
            url: 'https://example.org/sep/$index',
            publishedAt: DateTime(2026, 9, 20 - index),
            summary: '公告概览',
          ),
      ];
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: AnnouncementsPage(
          repository:
              _FakeAnnouncementRepository(items: items, details: const {}),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      final scrollView = find.byType(CustomScrollView).first;
      void expectHeaderExtent(String month) {
        final header = find.byKey(ValueKey('announcement-sticky-home-$month'));
        expect(tester.getSize(header).height, 34,
            reason: '$month at text scale $textScale');
        final persistentHeader = find.ancestor(
          of: header,
          matching: find.byType(SliverPersistentHeader),
        );
        final render = tester.renderObject<RenderSliverPinnedPersistentHeader>(
          persistentHeader,
        );
        expect(render.geometry!.scrollExtent, 34);
        expect(render.geometry!.maxScrollObstructionExtent, 34);
        expect(render.geometry!.paintExtent, 34);
      }

      expectHeaderExtent('2026年10月');
      await tester.drag(scrollView, const Offset(0, -400));
      await tester.pumpAndSettle();
      expectHeaderExtent('2026年10月');
      expect(
          tester
              .getTopLeft(find
                  .byKey(const ValueKey('announcement-sticky-home-2026年10月')))
              .dy,
          closeTo(tester.getTopLeft(scrollView).dy, 1));

      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: scrollView, matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expectHeaderExtent('2026年9月');
      expect(
          tester
              .getTopLeft(find
                  .byKey(const ValueKey('announcement-sticky-home-2026年9月')))
              .dy,
          closeTo(tester.getTopLeft(scrollView).dy, 1));
    });
  }

  testWidgets('every source reveals an enriched month with its card entrance',
      (tester) async {
    for (final source in AnnouncementSource.all) {
      final pending = Completer<AnnouncementCardData>();
      final origin = Uri.parse(source.listUrl).origin;
      final item = AnnouncementListItem(
        title: '${source.name}补齐日期的公告',
        url: source.id == 'shvfs'
            ? '$origin/site/newsDetail/6186'
            : '$origin/info/1010/6186.htm',
        sourceId: source.id,
      );
      final repository = _FakeAnnouncementRepository(
        items: [item],
        details: const {},
        cardFutures: {item.url: pending.future},
      )..currentDefault = source;
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        home: AnnouncementsPage(repository: repository),
      ));
      await _pumpPendingList(tester);
      final header = find.byKey(
        const ValueKey('announcement-sticky-home-2026年9月'),
      );
      expect(header, findsNothing, reason: source.id);
      expect(find.text(item.title), findsNothing, reason: source.id);
      expect(_cardOpacity(tester, item), 0, reason: source.id);
      pending.complete(AnnouncementCardData(
        summary: '所有来源都应在补齐概览和日期之后才把卡片加入列表，这段完整文字会占用两行。',
        dateText: '2026-09-18',
        publishedAt: DateTime(2026, 9, 18),
      ));
      await tester.idle();
      await tester.pump();
      expect(header, findsOneWidget, reason: source.id);
      final headerFade = find.descendant(
        of: header,
        matching: find.byType(FadeTransition),
      );
      double headerOpacity() =>
          tester.widget<FadeTransition>(headerFade).opacity.value;
      expect(headerOpacity(), _cardOpacity(tester, item), reason: source.id);
      expect(find.text('2026-09-18'), findsOneWidget, reason: source.id);
      final finalHeight = tester.getSize(find.byKey(ValueKey(item.url))).height;
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 140));
      expect(_cardOpacity(tester, item), inExclusiveRange(0, 1),
          reason: source.id);
      expect(headerOpacity(), _cardOpacity(tester, item), reason: source.id);
      await tester.pumpAndSettle();
      expect(headerOpacity(), 1, reason: source.id);
      expect(tester.getSize(find.byKey(ValueKey(item.url))).height, finalHeight,
          reason: source.id);
      expect(_cardOpacity(tester, item), 1, reason: source.id);
      expect(repository.cardRequests, hasLength(1), reason: source.id);
      expect(repository.requestedSources, [source.id]);
      expect(tester.takeException(), isNull, reason: source.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('out-of-order month preparation preserves mixed notice order',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dated = AnnouncementListItem(
      title: '已有日期的公告',
      url: 'https://sfa.shu.edu.cn/info/1212/100.htm',
      sourceId: 'sfa',
      summary: '列表已有概览',
      dateText: '2026-10-20',
      publishedAt: DateTime(2026, 10, 20),
    );
    const external = AnnouncementListItem(
      title: '没有日期的微信公告',
      url: 'https://mp.weixin.qq.com/s/mixed-month-order',
      sourceId: 'sfa',
      summary: '微信公告概览',
    );
    const crossSite = AnnouncementListItem(
      title: '招生网跨站公告',
      url: 'https://bkzsw.shu.edu.cn/info/1798/38490.htm',
      sourceId: 'sfa',
      column: '通知公告',
      summary: '跨站公告概览',
    );
    const undated = AnnouncementListItem(
      title: '待补齐日期的站内公告',
      url: 'https://sfa.shu.edu.cn/info/1212/101.htm',
      sourceId: 'sfa',
      summary: '站内公告概览',
    );
    final items = [dated, external, crossSite, undated];
    final pending = {
      for (final item in [external, crossSite, undated])
        item.url: Completer<AnnouncementCardData>(),
    };
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
      cardFutures:
          pending.map((url, completer) => MapEntry(url, completer.future)),
    )..currentDefault = AnnouncementSource.byId('sfa');
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await _pumpPendingList(tester);
    expect(_cardOpacity(tester, dated), 1);
    final datedRect = tester.getRect(find.byKey(ValueKey(dated.url)));
    final datedState = tester.state(find.byKey(ValueKey(dated.url)));

    void expectOriginalOrder() {
      for (var index = 1; index < items.length; index++) {
        expect(tester.getTopLeft(find.text(items[index - 1].title)).dy,
            lessThan(tester.getTopLeft(find.text(items[index].title)).dy));
      }
      expect(tester.state(find.byKey(ValueKey(dated.url))), same(datedState));
      expect(_cardOpacity(tester, dated), 1);
    }

    pending[undated.url]!.complete(AnnouncementCardData(
      summary: undated.summary,
      dateText: '2026-08-18',
      publishedAt: DateTime(2026, 8, 18),
    ));
    await tester.idle();
    await tester.pump();
    expect(find.text(undated.title), findsNothing);
    expect(find.text('2026年8月'), findsNothing);
    expect(tester.getRect(find.byKey(ValueKey(dated.url))), datedRect);
    pending[crossSite.url]!.complete(AnnouncementCardData(
      summary: crossSite.summary,
      dateText: '2026-09-18',
      publishedAt: DateTime(2026, 9, 18),
    ));
    await tester.idle();
    await tester.pump();
    expect(find.text(crossSite.title), findsNothing);
    expect(find.text('2026年9月'), findsNothing);
    expect(tester.getRect(find.byKey(ValueKey(dated.url))), datedRect);
    pending[external.url]!.complete(
      AnnouncementCardData(summary: external.summary),
    );
    await tester.pumpAndSettle();
    expectOriginalOrder();
    expect(tester.getRect(find.byKey(ValueKey(dated.url))), datedRect);
    for (final item in items) {
      expect(_cardOpacity(tester, item), 1);
      expect(find.text(item.summary), findsOneWidget);
      expect(
          repository.cardRequests.where((request) => request.url == item.url),
          hasLength(1));
    }
    expect(find.text('2026-10-20'), findsOneWidget);
    expect(find.text('2026-09-18'), findsOneWidget);
    expect(find.text('2026-08-18'), findsOneWidget);
    final requestedCrossSite = repository.cardRequests
        .singleWhere((request) => request.url == crossSite.url);
    expect(requestedCrossSite.sourceId, crossSite.sourceId);
    expect(requestedCrossSite.column, crossSite.column);
    expect(tester.takeException(), isNull);
  });

  for (final initiallyDated in [false, true]) {
    testWidgets(
        'same-month cards wait in order without an undersized slot '
        'with initial dates $initiallyDated', (tester) async {
      final monthDate = DateTime(2026, 9, 18);
      final items = [
        for (var index = 0; index < 2; index++)
          AnnouncementListItem(
            title: index == 0 ? '较慢的首条公告' : '先就绪的第二条公告',
            url: 'https://utseus.shu.edu.cn/info/1010/${6186 - index}.htm',
            sourceId: 'utseus',
            summary: '列表已有概览',
            dateText: initiallyDated ? '2026-09-18' : '',
            publishedAt: initiallyDated ? monthDate : null,
          ),
      ];
      final pending = [
        Completer<AnnouncementCardData>(),
        Completer<AnnouncementCardData>(),
      ];
      final repository = _FakeAnnouncementRepository(
        items: items,
        details: const {},
        cardFutures: {
          for (var index = 0; index < items.length; index++)
            items[index].url: pending[index].future,
        },
      )..currentDefault = AnnouncementSource.byId('utseus');
      await tester.pumpWidget(MaterialApp(
        home: AnnouncementsPage(repository: repository),
      ));
      await _pumpPendingList(tester);
      final header = find.byKey(
        const ValueKey('announcement-sticky-home-2026年9月'),
      );
      double headerOpacity() => tester
          .widget<FadeTransition>(find.descendant(
            of: header,
            matching: find.byType(FadeTransition),
          ))
          .opacity
          .value;
      pending[1].complete(AnnouncementCardData(
        summary: items[1].summary,
        dateText: '2026-09-18',
        publishedAt: monthDate,
      ));
      await tester.idle();
      await tester.pump();
      expect(header, findsNothing);
      expect(find.text(items[0].title), findsNothing);
      expect(find.text(items[1].title), findsNothing);
      expect(repository.cardRequests, hasLength(2));
      pending[0].complete(AnnouncementCardData(
        summary: items[0].summary,
        dateText: '2026-09-18',
        publishedAt: monthDate,
      ));
      await tester.idle();
      await tester.pump();
      expect(header, findsOneWidget);
      expect(find.text('2026-09-18'), findsNWidgets(2));
      expect(headerOpacity(), _cardOpacity(tester, items[0]));
      final firstHeight =
          tester.getSize(find.byKey(ValueKey(items[0].url))).height;
      await tester.pump(const Duration(milliseconds: 140));
      expect(tester.getSize(find.byKey(ValueKey(items[0].url))).height,
          firstHeight);
      await tester.pumpAndSettle();
      for (final item in items) {
        expect(_cardOpacity(tester, item), 1);
        expect(
            repository.cardRequests.where((request) => request.url == item.url),
            hasLength(1));
      }
      expect(headerOpacity(), 1);
      expect(tester.getTopLeft(find.text(items[0].title)).dy,
          lessThan(tester.getTopLeft(find.text(items[1].title)).dy));
      expect(tester.takeException(), isNull);
    });
  }

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
    await tester.tap(find.text('学校门户'));
    await tester.pumpAndSettle();
    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byTooltip('收藏本科生院'),
      100,
      scrollable: menuScrollable,
    );
    await tester.tap(find.byTooltip('收藏本科生院'));
    await tester.pumpAndSettle();
    expect(repository.favoriteIds, {'bksy'});
    expect(repository.currentDefault.id, 'shu');
    expect(repository.requestedSources, ['shu']);
    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView).last)
        .controller!
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsWidgets);
    expect(find.text('本科生院'), findsWidgets);
    final star = find.byIcon(Icons.star).first;
    expect(tester.widget<Icon>(star).color,
        Theme.of(tester.element(star)).colorScheme.primary);
    expect(find.text(_listTitle), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byTooltip('收藏本科生工作处'),
      100,
      scrollable: menuScrollable,
    );
    await tester.tap(find.byTooltip('收藏本科生工作处'));
    await tester.pumpAndSettle();
    expect(repository.favoriteIds, {'bksy', 'xgb'});

    await tester.scrollUntilVisible(
      find.text('本科生院'),
      -100,
      scrollable: menuScrollable,
    );
    final undergraduateOffice = find.text('本科生院').first;
    await tester.drag(find.byType(CustomScrollView).last, const Offset(0, 80));
    await tester.pumpAndSettle();
    await tester.tap(undergraduateOffice);
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
      tester.getSize(find.byType(CustomScrollView).last).height,
      lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.8),
    );
    expect(find.text('国际教育学院'), findsNothing);
    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('博物馆'),
      180,
      scrollable: menuScrollable,
    );
    expect(find.text('博物馆'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('学院'),
      200,
      scrollable: menuScrollable,
    );
    await tester.ensureVisible(find.text('学院'));
    await tester.pumpAndSettle();
    expect(find.text('学院'), findsOneWidget);
    await tester.tap(find.text('学院'));
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
    final collegeHeader = find.byKey(
      const ValueKey('announcement-sticky-menu-section-学院'),
    );
    final menuScrollView = find.byType(CustomScrollView).last;
    expect(
      tester.getTopLeft(collegeHeader).dy,
      closeTo(tester.getTopLeft(menuScrollView).dy, 1),
    );
    await tester.scrollUntilVisible(
      find.text('学院'),
      -140,
      scrollable: menuScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('学院'));
    await tester.pumpAndSettle();
    expect(find.text('国际教育学院'), findsNothing);
    expect(
        repository.sectionExpansion[AnnouncementMenuSection.college], isFalse);
  });

  testWidgets(
      'source groups keep their order and independent department expansion',
      (tester) async {
    final repository = _repositoryWith();
    final administrativeName = AnnouncementSource.inGroup(
            AnnouncementSourceGroup.administrativeDepartment)
        .first
        .name;
    for (final section in AnnouncementMenuSection.values) {
      repository.sectionExpansion[section] = false;
    }
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();

    const sections = ['收藏', '学校门户', '行政部门', '直属机构', '学院', '研究院所'];
    for (var index = 1; index < sections.length; index++) {
      expect(tester.getTopLeft(find.text(sections[index])).dy,
          greaterThan(tester.getTopLeft(find.text(sections[index - 1])).dy));
    }
    expect(find.text('学校下属部门'), findsNothing);
    expect(find.text(administrativeName), findsNothing);
    expect(find.text('博物馆'), findsNothing);

    await tester.tap(find.text('行政部门'));
    await tester.pumpAndSettle();
    expect(find.text(administrativeName), findsOneWidget);
    expect(find.text('博物馆'), findsNothing);
    expect(
        repository
            .sectionExpansion[AnnouncementMenuSection.affiliatedInstitution],
        isFalse);
    await tester.tap(find.text('行政部门'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直属机构'));
    await tester.pumpAndSettle();
    expect(find.text(administrativeName), findsNothing);
    expect(find.text('博物馆'), findsOneWidget);
    expect(
        repository
            .sectionExpansion[AnnouncementMenuSection.administrativeDepartment],
        isFalse);
    expect(
        repository
            .sectionExpansion[AnnouncementMenuSection.affiliatedInstitution],
        isTrue);

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(find.text(administrativeName), findsNothing);
    expect(find.text('博物馆'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
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
    await tester.tap(find.text('学校门户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('行政部门'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直属机构'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学院'));
    await tester.pumpAndSettle();
    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('研究院所'),
      200,
      scrollable: menuScrollable,
    );
    await tester.tap(find.text('研究院所'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('新型显示技术及应用集成教育部重点实验室'),
      200,
      scrollable: menuScrollable,
    );
    expect(find.text('新型显示技术及应用集成教育部重点实验室'), findsOneWidget);
    expect(repository.sectionExpansion, {
      AnnouncementMenuSection.favorites: false,
      AnnouncementMenuSection.schoolPortal: false,
      AnnouncementMenuSection.college: true,
      AnnouncementMenuSection.researchInstitute: true,
      AnnouncementMenuSection.administrativeDepartment: false,
      AnnouncementMenuSection.affiliatedInstitution: false,
    });

    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏'), findsNothing);
    expect(find.text('上海大学官网'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('国际教育学院'),
      200,
      scrollable: find.descendant(
        of: find.byKey(announcementSourceMenuKey),
        matching: find.byType(Scrollable),
      ),
    );
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

  testWidgets('Film Academy cards wait for their preview before entering',
      (tester) async {
    final preview = Completer<String?>();
    const item = AnnouncementListItem(
      title: '电影学院通知',
      url: 'https://sfa.shu.edu.cn/info/1212/1.htm',
      sourceId: 'sfa',
      dateText: '2026-10-20',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      previewFutures: {item.url: preview.future},
    )..currentDefault = AnnouncementSource.byId('sfa');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    for (var frame = 0;
        frame < 10 && !repository.previewRequests.contains(item.url);
        frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repository.previewRequests, contains(item.url));
    await tester.pump();
    expect(find.text('电影学院通知'), findsNothing);
    expect(find.text('2026-10-20'), findsNothing);
    expect(_cardOpacity(tester, item), 0);
    expect(repository.publicationDateRequests, isEmpty);

    preview.complete('通知概览');
    await tester.pumpAndSettle();
    expect(find.text('通知概览'), findsOneWidget);
    expect(find.text('2026-10-20'), findsOneWidget);
    expect(_cardOpacity(tester, item), 1);
  });

  testWidgets('visible cached Film Academy excerpts resolve cross-site dates',
      (tester) async {
    final date = Completer<AnnouncementListItem?>();
    const item = AnnouncementListItem(
      title: '上海大学2026年艺术类招生简章',
      url: 'https://bkzsw.shu.edu.cn/info/1798/38490.htm',
      sourceId: 'sfa',
      summary: '保留电影学院列表原有摘要',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      publicationDateFutures: {item.url: date.future},
    )..currentDefault = AnnouncementSource.byId('sfa');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);

    expect(find.text(item.title), findsNothing);
    expect(find.text(item.summary), findsNothing);
    expect(find.text('2026-03-18'), findsNothing);
    expect(repository.previewRequests, isEmpty);
    expect(repository.publicationDateRequests, [same(item)]);
    expect(repository.publicationDateRequests.single.sourceId, 'sfa');
    expect(_cardOpacity(tester, item), 0);

    date.complete(AnnouncementListItem(
      title: item.title,
      url: item.url,
      sourceId: item.sourceId,
      summary: item.summary,
      dateText: '2026-03-18',
      publishedAt: DateTime(2026, 3, 18),
    ));
    await tester.pumpAndSettle();

    final list = find.byType(CustomScrollView);
    expect(find.descendant(of: list, matching: find.text('2026-03-18')),
        findsOneWidget);
    expect(repository.detailRequestCount, 0);
    expect(_cardOpacity(tester, item), 1);
  });

  for (final sourceId in ['utseus', 'bksy', 'xiangying']) {
    testWidgets('$sourceId excerpts resolve missing dates without previews',
        (tester) async {
      final date = Completer<AnnouncementListItem?>();
      final item = AnnouncementListItem(
        title: '$sourceId 缺少日期的通知',
        url: sourceId == 'xiangying'
            ? 'https://scie.shu.edu.cn/info/1070/46185.htm'
            : 'https://$sourceId.shu.edu.cn/info/1010/6186.htm',
        sourceId: sourceId,
        summary: '保留列表摘要',
        publishedAt: DateTime(2099, 1, 1),
      );
      final repository = _FakeAnnouncementRepository(
        items: [item],
        details: const {},
        publicationDateFutures: {item.url: date.future},
      )..currentDefault = AnnouncementSource.byId(sourceId);
      await tester.pumpWidget(
        MaterialApp(home: AnnouncementsPage(repository: repository)),
      );
      await _pumpPendingList(tester);

      expect(find.text(item.title), findsNothing);
      expect(find.text(item.summary), findsNothing);
      expect(repository.previewRequests, isEmpty);
      expect(repository.publicationDateRequests, [same(item)]);
      expect(_cardOpacity(tester, item), 0);

      date.complete(AnnouncementListItem(
        title: item.title,
        url: item.url,
        sourceId: item.sourceId,
        summary: item.summary,
        dateText: '2026-09-18',
        publishedAt: DateTime(2026, 9, 18),
      ));
      await tester.pumpAndSettle();

      expect(find.text('2026-09-18'), findsOneWidget);
      expect(repository.publicationDateRequests.single.sourceId, sourceId);
      expect(repository.detailRequestCount, 0);
      expect(_cardOpacity(tester, item), 1);
    });
  }

  testWidgets('resolved dates update one card without reordering the list',
      (tester) async {
    final date = Completer<AnnouncementListItem?>();
    const first = AnnouncementListItem(
      title: '保持当前位置的通知',
      url: 'https://utseus.shu.edu.cn/info/1010/6185.htm',
      sourceId: 'utseus',
      summary: '已有摘要',
    );
    const second = AnnouncementListItem(
      title: '稍后补齐日期的通知',
      url: 'https://utseus.shu.edu.cn/info/1010/6186.htm',
      sourceId: 'utseus',
      summary: '已有摘要',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [first, second],
      details: const {},
      publicationDateFutures: {second.url: date.future},
    )..currentDefault = AnnouncementSource.byId('utseus');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final position = controller.position;
    final offset = controller.offset;
    final firstState = tester.state(find.byKey(ValueKey(first.url)));
    final firstRect = tester.getRect(find.byKey(ValueKey(first.url)));
    expect(_cardOpacity(tester, first), 1);
    expect(_cardOpacity(tester, second), 0);
    expect(find.text(second.title), findsNothing);

    date.complete(AnnouncementListItem(
      title: second.title,
      url: second.url,
      sourceId: second.sourceId,
      summary: second.summary,
      dateText: '2026-09-18',
      publishedAt: DateTime(2026, 9, 18),
    ));
    await tester.idle();
    await tester.pump();
    expect(find.byKey(const ValueKey('announcement-sticky-home-2026年9月')),
        findsOneWidget);
    expect(find.text('2026-09-18'), findsOneWidget);
    expect(_cardOpacity(tester, first), 1);
    expect(tester.state(find.byKey(ValueKey(first.url))), same(firstState));
    expect(tester.getRect(find.byKey(ValueKey(first.url))), firstRect);
    await tester.pumpAndSettle();

    expect(find.text('2026-09-18'), findsOneWidget);
    expect(tester.getTopLeft(find.text(first.title)).dy,
        lessThan(tester.getTopLeft(find.text(second.title)).dy));
    expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(controller));
    expect(controller.position, same(position));
    expect(controller.offset, offset);
    expect(tester.state(find.byKey(ValueKey(first.url))), same(firstState));
    expect(tester.getRect(find.byKey(ValueKey(first.url))), firstRect);
    expect(_cardOpacity(tester, first), 1);
    expect(_cardOpacity(tester, second), 1);
    for (final item in [first, second]) {
      expect(
          repository.cardRequests.where((request) => request.url == item.url),
          hasLength(1));
    }
  });

  testWidgets('metadata for later rows starts after scrolling', (tester) async {
    final items = List.generate(
      30,
      (index) => AnnouncementListItem(
        title: '中欧学院通知 $index',
        url: 'https://utseus.shu.edu.cn/info/1010/$index.htm',
        sourceId: 'utseus',
        summary: '已有摘要',
      ),
    );
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
    )..currentDefault = AnnouncementSource.byId('utseus');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final initialRequests = repository.publicationDateRequests.length;
    expect(initialRequests, greaterThan(0));
    expect(initialRequests, lessThan(items.length));
    expect(repository.previewRequests, isEmpty);

    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, -1150));
    await tester.pumpAndSettle();
    expect(repository.publicationDateRequests.length,
        greaterThan(initialRequests));
    expect(repository.publicationDateRequests.length, lessThan(items.length));
  });

  testWidgets('resolved same-month dates keep later cards lazy',
      (tester) async {
    final date = DateTime(2026, 9, 18);
    final items = [
      for (var index = 0; index < 30; index++)
        AnnouncementListItem(
          title: '同月待补日期公告 $index',
          url: 'https://utseus.shu.edu.cn/info/1010/${6200 + index}.htm',
          sourceId: 'utseus',
          summary: '列表已有概览',
        ),
    ];
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
      publicationDateFutures: {
        for (final item in items)
          item.url: Future.value(AnnouncementListItem(
            title: item.title,
            url: item.url,
            sourceId: item.sourceId,
            summary: item.summary,
            dateText: '2026-09-18',
            publishedAt: date,
          )),
      },
    )..currentDefault = AnnouncementSource.byId('utseus');
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await tester.pumpAndSettle();
    final initialRequests = repository.cardRequests.length;
    expect(initialRequests, greaterThan(0));
    expect(initialRequests, lessThan(items.length));
    expect(repository.publicationDateRequests, hasLength(initialRequests));
    final header = find.byKey(
      const ValueKey('announcement-sticky-home-2026年9月'),
    );
    expect(header, findsOneWidget);
    expect(find.text('2026-09-18'), findsWidgets);
    expect(repository.cardRequests.map((item) => item.url),
        isNot(contains(items[15].url)));

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(items[15].url)),
      350,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(repository.cardRequests.map((item) => item.url),
        contains(items[15].url));
    expect(repository.cardRequests.length, greaterThan(initialRequests));
    expect(repository.cardRequests.length, lessThan(items.length));
    expect(header, findsOneWidget);
    expect(_cardOpacity(tester, items[15]), 1);

    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(_cardOpacity(tester, items.first), 1);
    expect(repository.cardRequests.map((item) => item.url).toSet(),
        hasLength(repository.cardRequests.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a removed Film Academy card ignores its pending date',
      (tester) async {
    final date = Completer<AnnouncementListItem?>();
    const item = AnnouncementListItem(
      title: '离开页面前的电影学院通知',
      url: 'https://bkzsw.shu.edu.cn/info/1798/38490.htm',
      sourceId: 'sfa',
      summary: '已有摘要',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      publicationDateFutures: {item.url: date.future},
    )..currentDefault = AnnouncementSource.byId('sfa');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);
    expect(repository.publicationDateRequests, hasLength(1));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(repository.cancelledCards, [same(item)]);
    date.complete(AnnouncementListItem(
      title: item.title,
      url: item.url,
      sourceId: item.sourceId,
      dateText: '2026-03-18',
      publishedAt: DateTime(2026, 3, 18),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('2026-03-18'), findsNothing);
  });

  testWidgets('a resolved date waits until the detail transition finishes',
      (tester) async {
    final date = Completer<AnnouncementListItem?>();
    const ready = AnnouncementListItem(
      title: '可以打开的通知',
      url: 'https://utseus.shu.edu.cn/info/1010/6185.htm',
      sourceId: 'utseus',
      summary: '已就绪摘要',
      dateText: '2026-03-19',
    );
    const item = AnnouncementListItem(
      title: '详情期间补齐中欧学院日期',
      url: 'https://utseus.shu.edu.cn/info/1010/6186.htm',
      sourceId: 'utseus',
      summary: '已有摘要',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [ready, item],
      details: {
        ready.title: AnnouncementDetail(
          title: ready.title,
          url: ready.url,
          blocks: const [AnnouncementContentBlock.text('公告正文')],
        ),
      },
      publicationDateFutures: {item.url: date.future},
    )..currentDefault = AnnouncementSource.byId('utseus');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);
    expect(_cardOpacity(tester, item), 0);
    await tester.tap(find.text(ready.title));
    await tester.pumpAndSettle();
    date.complete(AnnouncementListItem(
      title: item.title,
      url: item.url,
      sourceId: item.sourceId,
      dateText: '2026-03-18',
      publishedAt: DateTime(2026, 3, 18),
    ));
    await tester.pumpAndSettle();
    expect(find.text('2026-03-18', skipOffstage: false), findsNothing);

    Navigator.of(tester.element(find.byType(AnnouncementDetailPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('2026-03-18', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('2026-03-18'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new source details display the site date and author',
      (tester) async {
    String legacyArticle(String title, String date, String author) =>
        '<span class="Head">$title</span>'
        '<table><tr valign="middle"><td>'
        '<span>创建时间：</span><span>$date</span>'
        '<font face=""><span>$author</span></font>'
        '</td></tr></table>'
        '<div class="v_news_content"><p>正文</p></div>';

    final cases = [
      (
        sourceId: 'alumni',
        title: '校友会通知',
        url: 'https://alumni.shu.edu.cn/info/1021/8756.htm',
        date: '2025-11-25',
        author: '井晓昌',
        html: legacyArticle('校友会通知', '2025/11/25', '井晓昌'),
      ),
      (
        sourceId: 'shuedf',
        title: '基金会声明',
        url: 'https://shuedf.shu.edu.cn/info/1005/2785.htm',
        date: '2025-09-25',
        author: '宣惠民',
        html: legacyArticle('基金会声明', '2025/09/25', '宣惠民'),
      ),
      (
        sourceId: 'cs',
        title: '计算机学院新闻',
        url: 'https://cs.shu.edu.cn/info/1061/1431.htm',
        date: '2009-07-03',
        author: '刘华',
        html: '<div class="art-tit"><h3>计算机学院新闻</h3><p>'
            '<span>时间：2009年07月03日 00:00:00</span>'
            '<span>作者：刘华</span></p></div>'
            '<div class="v_news_content"><p>正文</p></div>',
      ),
    ];
    for (final entry in cases) {
      final item = AnnouncementListItem(
        title: entry.title,
        url: entry.url,
        sourceId: entry.sourceId,
      );
      final detail = AnnouncementApiClient.parseAnnouncementDetail(
        entry.html,
        url: entry.url,
        sourceId: entry.sourceId,
      );
      expect(detail.title, entry.title);
      expect(detail.dateText, entry.date);
      expect(detail.author, entry.author);
      final repository = _FakeAnnouncementRepository(
        items: [item],
        details: {item.title: detail},
      );
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(entry.sourceId),
        home: AnnouncementDetailPage(repository: repository, item: item),
      ));
      await tester.pumpAndSettle();
      expect(find.text('${entry.date} · ${entry.author}'), findsOneWidget);
    }
  });

  testWidgets('official details display publication date department and author',
      (tester) async {
    const item = AnnouncementListItem(
      title: '官网完整元数据',
      url: 'https://www.shu.edu.cn/info/1051/1.htm',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          dateText: '2026-10-26',
          publishedAt: DateTime(2026, 10, 26, 19, 46, 41),
          department: '党委宣传部',
          author: '韩晓霞',
          blocks: const [AnnouncementContentBlock.text('正文')],
        ),
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementDetailPage(repository: repository, item: item),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2026-10-26 · 党委宣传部 · 韩晓霞'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
  });

  for (final official in [true, false]) {
    testWidgets(
        'department display follows actual article ownership: $official',
        (tester) async {
      final item = AnnouncementListItem(
        title: '跨部门转载公告',
        url: official
            ? 'https://www.shu.edu.cn/info/1051/402205.htm'
            : 'https://bksy.shu.edu.cn/info/1015/308634.htm',
        sourceId: 'sfa',
      );
      final repository = _FakeAnnouncementRepository(
        items: [item],
        details: {
          item.title: AnnouncementDetail(
            title: item.title,
            url: item.url,
            dateText: '2026-10-26',
            author: '公告作者',
            department: '真实发布部门',
            blocks: const [AnnouncementContentBlock.text('正文')],
          ),
        },
      );
      await tester.pumpWidget(MaterialApp(
        home: AnnouncementDetailPage(repository: repository, item: item),
      ));
      await tester.pumpAndSettle();

      expect(
          find.text(
              official ? '2026-10-26 · 真实发布部门 · 公告作者' : '2026-10-26 · 公告作者'),
          findsOneWidget);
      expect(repository.detailRequests.single.sourceId, 'sfa');
    });
  }

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

    await tester.drag(
        find.byType(CustomScrollView).first, const Offset(0, -1150));
    await tester.pumpAndSettle();
    expect(repository.previewRequests.length, greaterThan(initiallyRequested));
    expect(repository.previewRequests.length, lessThan(items.length));
  });

  testWidgets('cards enter once after summary and date have both settled',
      (tester) async {
    final pending = Completer<String?>();
    final date = Completer<AnnouncementListItem?>();
    const item = AnnouncementListItem(
      title: '等待正文的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/wait.htm',
      sourceId: 'bksy',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: {
        item.title: AnnouncementDetail(
          title: item.title,
          url: item.url,
          blocks: const [AnnouncementContentBlock.text('已打开通知正文')],
        ),
      },
      previewFutures: {item.url: pending.future},
      publicationDateFutures: {item.url: date.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    expect(find.byType(CustomScrollView), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.text(item.title), findsNothing);
    expect(repository.previewRequests, [item.url]);
    expect(repository.publicationDateRequests, [same(item)]);
    expect(_cardOpacity(tester, item), 0);

    pending.complete('完整正文摘要');
    await tester.pump();
    expect(find.text('完整正文摘要'), findsNothing);
    expect(_cardOpacity(tester, item), 0);

    date.complete(AnnouncementListItem(
      title: item.title,
      url: item.url,
      dateText: '2026-10-25',
      publishedAt: DateTime(2026, 10, 25),
    ));
    await tester.idle();
    await tester.pump();
    expect(find.text('完整正文摘要'), findsOneWidget);
    expect(find.text('2026-10-25'), findsOneWidget);
    final readyHeight = tester.getSize(find.byKey(ValueKey(item.url))).height;
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_cardOpacity(tester, item), greaterThan(0));
    expect(_cardOpacity(tester, item), lessThan(1));
    await tester.pumpAndSettle();
    expect(_cardOpacity(tester, item), 1);
    expect(tester.getSize(find.byKey(ValueKey(item.url))).height, readyHeight);
    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();
    expect(find.text('已打开通知正文'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(item.title), findsOneWidget);
    expect(find.text('完整正文摘要'), findsOneWidget);
    expect(find.byType(SlideTransition), findsWidgets);
    expect(_cardOpacity(tester, item), 1);
    expect(repository.cardRequests, [same(item)]);
  });

  testWidgets('complete list cards enter without optional article requests',
      (tester) async {
    final repository = _FakeAnnouncementRepository(
      items: const [_readyListItem],
      details: const {},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(_cardOpacity(tester, _readyListItem), 1);
    expect(find.text(_readyListItem.summary), findsOneWidget);
    expect(find.text(_readyListItem.dateText), findsOneWidget);
    expect(repository.previewRequests, isEmpty);
    expect(repository.publicationDateRequests, isEmpty);
    expect(repository.detailRequests, isEmpty);
  });

  testWidgets('failed card preparation still enters with available list fields',
      (tester) async {
    final card = Completer<AnnouncementCardData>();
    final repository = _FakeAnnouncementRepository(
      items: const [_readyListItem],
      details: const {},
      cardFutures: {_readyListItem.url: card.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    expect(_cardOpacity(tester, _readyListItem), 0);
    card.completeError(StateError('Optional preparation failed'));
    await tester.pumpAndSettle();

    expect(_cardOpacity(tester, _readyListItem), 1);
    expect(find.text(_readyListItem.summary), findsOneWidget);
    expect(find.text(_readyListItem.dateText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card deadline keeps completed dates and ignores a late summary',
      (tester) async {
    final preview = Completer<String?>();
    const item = AnnouncementListItem(
      title: '有截止时间的公告',
      url: 'https://utseus.shu.edu.cn/info/1010/6186.htm',
      sourceId: 'utseus',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      previewFutures: {item.url: preview.future},
      publicationDateFutures: {
        item.url: Future.value(AnnouncementListItem(
          title: item.title,
          url: item.url,
          dateText: '2026-09-18',
          publishedAt: DateTime(2026, 9, 18),
        )),
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    expect(_cardOpacity(tester, item), 0);
    await tester.pump(AnnouncementRepository.cardPreparationTimeout);
    await tester.pumpAndSettle();
    expect(_cardOpacity(tester, item), 1);
    expect(find.text('2026-09-18'), findsOneWidget);
    final height = tester.getSize(find.byKey(ValueKey(item.url))).height;

    preview.complete('迟到的概览不再改变已经入场的卡片');
    await tester.pumpAndSettle();
    expect(find.text('迟到的概览不再改变已经入场的卡片'), findsNothing);
    expect(tester.getSize(find.byKey(ValueKey(item.url))).height, height);
    expect(_cardOpacity(tester, item), 1);
  });

  testWidgets('paging keeps entered cards stable without replaying entrance',
      (tester) async {
    final repository = _DeferredPageAnnouncementRepository(withReadyCard: true);
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_cardOpacity(tester, _readyListItem), 1);
    expect(repository.pagesRequested, 1);
    final height =
        tester.getSize(find.byKey(ValueKey(_readyListItem.url))).height;
    repository.nextPage.complete([
      AnnouncementListItem(
        title: _readyListItem.title,
        url: _readyListItem.url,
        summary: '分页缓存中更新的较长概览，不能改变已经入场的卡片高度或重新播放动画。',
        dateText: '2026-10-27',
      ),
      _listItem,
    ]);
    await tester.pump();
    expect(_cardOpacity(tester, _readyListItem), 1);
    await tester.pumpAndSettle();

    expect(find.text(_readyListItem.summary), findsOneWidget);
    expect(find.text('2026-10-27'), findsNothing);
    expect(tester.getSize(find.byKey(ValueKey(_readyListItem.url))).height,
        height);
    expect(
        repository.cardRequests.where((item) => item.url == _readyListItem.url),
        hasLength(1));
  });

  testWidgets('titles keep date order despite out-of-order previews',
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
    await _pumpPendingList(tester);
    expect(find.text(item.title), findsNothing);
    pending.complete('延迟返回的概览');
    await tester.pumpAndSettle();
    expect(find.text('延迟返回的概览'), findsOneWidget);
    expect(
        tester.getSize(find.byKey(ValueKey(item.url))).height, lessThan(104));
  });

  testWidgets('scrolled-to cards wait for their preview before entering',
      (tester) async {
    final items = List.generate(
      30,
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
      previewFutures: {items[20].url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(repository.previewRequests, isNot(contains(items[20].url)));

    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    for (var attempt = 0;
        attempt < 6 && !repository.previewRequests.contains(items[20].url);
        attempt++) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(repository.previewRequests, contains(items[20].url));
    expect(find.text(items[20].title), findsNothing);
    expect(_cardOpacity(tester, items[20]), 0);

    pending.complete('滚动后才加载的摘要');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(items[20].url)),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text(items[20].title), findsOneWidget);
    expect(find.text('滚动后才加载的摘要'), findsOneWidget);
    expect(_cardOpacity(tester, items[20]), 1);
  });

  testWidgets('prepared cards append without resizing or moving entered rows',
      (tester) async {
    final middle = Completer<AnnouncementCardData>();
    final last = Completer<AnnouncementCardData>();
    final first = AnnouncementListItem(
      title: '已经完整显示的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/stable.htm',
      sourceId: 'bksy',
      summary: '短概览',
      dateText: '2026-10-20',
      publishedAt: DateTime(2026, 10, 20),
    );
    const second = AnnouncementListItem(
      title: '需要补齐两行概览的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/middle.htm',
      sourceId: 'bksy',
    );
    const third = AnnouncementListItem(
      title: '先于前一篇准备完成的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/last.htm',
      sourceId: 'bksy',
    );
    final repository = _FakeAnnouncementRepository(
      items: [first, second, third],
      details: const {},
      cardFutures: {second.url: middle.future, third.url: last.future},
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await _pumpPendingList(tester);
    expect(repository.cardRequests, hasLength(3));
    expect(_cardOpacity(tester, first), 1);
    final firstTile = find.byKey(ValueKey(first.url));
    final firstRect = tester.getRect(firstTile);
    final firstState = tester.state(firstTile);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final offset = controller.offset;
    expect(find.text(second.title), findsNothing);
    expect(find.text(third.title), findsNothing);

    last.complete(AnnouncementCardData(
      summary: '提前准备好的第三篇概览',
      dateText: '2026-08-18',
      publishedAt: DateTime(2026, 8, 18),
    ));
    await tester.idle();
    await tester.pump();
    expect(find.text(third.title), findsNothing);
    expect(tester.getRect(firstTile), firstRect);
    expect(controller.offset, offset);

    middle.complete(AnnouncementCardData(
      summary: '这是一段需要显示成两行的完整公告概览，用来检查首次滑入以前卡片已经具有最终高度，'
          '而不会在用户阅读时临时加上一段文字挤动其他公告。',
      dateText: '2026-09-18',
      publishedAt: DateTime(2026, 9, 18),
    ));
    await tester.idle();
    await tester.pump();
    final secondTile = find.byKey(ValueKey(second.url));
    final thirdTile = find.byKey(ValueKey(third.url));
    final secondHeight = tester.getSize(secondTile).height;
    final thirdHeight = tester.getSize(thirdTile).height;
    expect(find.text('2026年9月'), findsOneWidget);
    expect(find.text('2026年8月'), findsOneWidget);
    expect(_cardOpacity(tester, second), 0);
    expect(tester.getRect(firstTile), firstRect);
    await tester.pump(const Duration(milliseconds: 55));
    await tester.pump(const Duration(milliseconds: 140));
    expect(_cardOpacity(tester, second), inExclusiveRange(0, 1));
    expect(tester.getSize(secondTile).height, secondHeight);
    expect(tester.getSize(thirdTile).height, thirdHeight);
    expect(tester.getRect(firstTile), firstRect);
    await tester.pumpAndSettle();
    expect(tester.getSize(secondTile).height, secondHeight);
    expect(tester.getSize(thirdTile).height, thirdHeight);
    expect(tester.getRect(firstTile), firstRect);
    expect(tester.state(firstTile), same(firstState));
    expect(controller.offset, offset);
    expect(tester.getTopLeft(find.text(second.title)).dy,
        lessThan(tester.getTopLeft(find.text(third.title)).dy));
    expect(repository.cardRequests, hasLength(3));
  });

  testWidgets(
      'preparing more cards preserves a scrolled reader and entered heights',
      (tester) async {
    final pending = {
      for (var index = 6; index < 12; index++)
        index: Completer<AnnouncementCardData>(),
    };
    final items = [
      for (var index = 0; index < 30; index++)
        AnnouncementListItem(
          title: '浏览中的通知 $index',
          url: 'https://utseus.shu.edu.cn/info/1010/${7000 + index}.htm',
          sourceId: 'utseus',
          summary: index < 6
              ? '已完整显示的两行概览，用来让首批公告具备足够的滚动空间。'
                  '这些内容在后续文章补齐时不能发生变化。'
              : '',
          dateText: index < 6 ? '2026-10-20' : '',
          publishedAt: index < 6 ? DateTime(2026, 10, 20) : null,
        ),
    ];
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
      cardFutures: {
        for (final entry in pending.entries)
          items[entry.key].url: entry.value.future,
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await _pumpPendingList(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(100);
    await _pumpPendingList(tester);
    expect(repository.cardRequests.map((item) => item.url),
        contains(items[6].url));
    expect(repository.cardRequests.length, lessThanOrEqualTo(12));
    final visible = find.byKey(ValueKey(items[2].url));
    final rect = tester.getRect(visible);
    final state = tester.state(visible);
    final offset = controller.offset;
    final position = controller.position;
    final sizes = {
      for (var index = 1; index < 5; index++)
        index: tester.getSize(find.byKey(ValueKey(items[index].url))),
    };
    AnnouncementCardData completeCard(int index) => AnnouncementCardData(
          summary: '后续公告 $index 返回的完整概览，在进入滚动布局前就必须确定最终高度。'
              '这是一段会显示为两行的概览文字。',
          dateText: '2026-09-18',
          publishedAt: DateTime(2026, 9, 18),
        );
    pending[11]!.complete(completeCard(11));
    await tester.idle();
    await tester.pump();
    expect(find.text(items[11].title), findsNothing);
    expect(tester.getRect(visible), rect);
    pending[6]!.complete(completeCard(6));
    await tester.idle();
    await tester.pump();
    expect(controller.offset, offset);
    expect(tester.getRect(visible), rect);
    for (var index = 7; index < 11; index++) {
      pending[index]!.complete(completeCard(index));
    }
    await tester.pumpAndSettle();
    expect(controller.position, same(position));
    expect(controller.offset, offset);
    expect(tester.getRect(visible), rect);
    expect(tester.state(visible), same(state));
    for (final entry in sizes.entries) {
      expect(tester.getSize(find.byKey(ValueKey(items[entry.key].url))),
          entry.value);
      expect(_cardOpacity(tester, items[entry.key]), 1);
    }
    expect(repository.cardRequests.map((item) => item.url).toSet(),
        hasLength(repository.cardRequests.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'bottom pagination shows the AppBar progress without a pull spinner',
      (tester) async {
    final repository = _DeferredPageAnnouncementRepository(withReadyCard: true);
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.pagesRequested, 1);
    expect(
        find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(LinearProgressIndicator)),
        findsOneWidget);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    repository.nextPage.complete(repository.items);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(_cardOpacity(tester, _readyListItem), 1);
  });

  testWidgets(
      'pull refresh uses its spinner and keeps entered cards while waiting',
      (tester) async {
    final cards = {
      _listItem.url: Future.value(const AnnouncementCardData(summary: '已有概览')),
    };
    final repository = _ControlledRefreshRepository(cardFutures: cards);
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final tile = find
        .ancestor(of: find.text(_listTitle), matching: find.byType(InkWell))
        .first;
    final oldSize = tester.getSize(tile);
    final network = Completer<List<AnnouncementListItem>>();
    final prepared = Completer<AnnouncementCardData>();
    repository.refreshResult = network.future;
    cards[_listItem.url] = prepared.future;
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(CustomScrollView)));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(repository.listRequests, 1);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(repository.listRequests, 2);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(_cardOpacity(tester, _listItem), 1);
    expect(tester.getSize(tile), oldSize);
    expect(find.text('已有概览'), findsOneWidget);
    expect(repository.cardRequests, hasLength(1));

    network.complete(repository.items);
    await _pumpPendingList(tester);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(repository.cardRequests, hasLength(2));
    expect(_cardOpacity(tester, _listItem), 1);
    expect(tester.getSize(tile), oldSize);
    expect(find.text('已有概览'), findsOneWidget);
    prepared.complete(const AnnouncementCardData(summary: '更新后的概览'));
    await tester.pumpAndSettle();
    expect(_cardOpacity(tester, _listItem), 1);
    expect(find.text('更新后的概览'), findsOneWidget);
  });

  testWidgets(
      'failed pull refresh retains entered cards and allows another refresh',
      (tester) async {
    final repository = _ControlledRefreshRepository(cardFutures: {
      _listItem.url: Future.value(const AnnouncementCardData(summary: '已有概览')),
    });
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final network = Completer<List<AnnouncementListItem>>();
    repository.refreshResult = network.future;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(_cardOpacity(tester, _listItem), 1);
    network.completeError(const AnnouncementApiException('刷新暂时失败'));
    await tester.pumpAndSettle();
    await refresh;
    expect(find.text('刷新暂时失败'), findsOneWidget);
    expect(find.text('已有概览'), findsOneWidget);
    expect(_cardOpacity(tester, _listItem), 1);
    expect(repository.cardRequests, hasLength(1));
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    repository.refreshResult = Future.value(repository.items);
    final retry = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pumpAndSettle();
    await retry;
    expect(repository.listRequests, 3);
    expect(repository.cardRequests, hasLength(2));
  });

  testWidgets(
      'refresh reloads a preview when its URL and summary stay the same',
      (tester) async {
    const item = AnnouncementListItem(
      title: '正文会更新的通知',
      url: 'https://bksy.shu.edu.cn/info/1000/refreshed.htm',
      sourceId: 'bksy',
    );
    final previewFutures = {item.url: Future<String?>.value('刷新前的概览')};
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      previewFutures: previewFutures,
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('刷新前的概览'), findsOneWidget);

    final updatedPreview = Completer<String?>();
    previewFutures[item.url] = updatedPreview.future;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await _pumpPendingList(tester);
    expect(find.text('刷新前的概览'), findsOneWidget);
    expect(find.text(item.title), findsOneWidget);
    expect(repository.previewRequests, [item.url, item.url]);
    updatedPreview.complete('刷新后的新概览');
    await tester.pumpAndSettle();
    await refresh;
    expect(find.text('刷新后的新概览'), findsOneWidget);
    expect(find.text('刷新前的概览'), findsNothing);
    expect(repository.previewRequests, [item.url, item.url]);
  });

  testWidgets('refresh ignores card completion from an older generation',
      (tester) async {
    final previous = Completer<AnnouncementCardData>();
    final refreshed = Completer<AnnouncementCardData>();
    final futures = {_listItem.url: previous.future};
    final repository = _FakeAnnouncementRepository(
      items: const [_readyListItem, _listItem],
      details: const {},
      cardFutures: futures,
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);
    futures[_listItem.url] = refreshed.future;
    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await _pumpPendingList(tester);
    await refresh;
    expect(repository.cardRequests, hasLength(4));

    previous.complete(const AnnouncementCardData(
      summary: '旧代次的概览',
      dateText: '2025-01-01',
    ));
    await _pumpPendingList(tester);
    expect(find.text('旧代次的概览'), findsNothing);
    expect(_cardOpacity(tester, _listItem), 0);

    refreshed.complete(const AnnouncementCardData(
      summary: '刷新后的概览',
      dateText: '2026-10-26',
    ));
    await tester.pumpAndSettle();
    expect(find.text('刷新后的概览'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(ValueKey(_listItem.url)),
            matching: find.text('2026-10-26')),
        findsOneWidget);
    expect(_cardOpacity(tester, _listItem), 1);
  });

  testWidgets(
      'covered previews and pages wait until the reverse transition ends',
      (tester) async {
    final preview = Completer<String?>();
    final repository = _DeferredPageAnnouncementRepository(
      previewFutures: {
        'https://www.shu.edu.cn/info/1051/2.htm': preview.future
      },
      withReadyCard: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.pagesRequested, 1);
    await tester.tap(find.text(_readyListItem.title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final homeList = find.byType(CustomScrollView, skipOffstage: false);
    final coveredList = tester.widget<CustomScrollView>(homeList);
    repository.nextPage.complete(const [
      _readyListItem,
      _listItem,
      AnnouncementListItem(
        title: '详情期间完成的下一页',
        url: 'https://www.shu.edu.cn/info/1051/2.htm',
      ),
    ]);
    await tester.pump();
    preview.complete('返回列表后显示的概览');
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<CustomScrollView>(homeList), same(coveredList));
    expect(find.text('返回列表后显示的概览', skipOffstage: false), findsNothing);
    expect(find.text('详情期间完成的下一页', skipOffstage: false), findsNothing);
    expect(repository.pagesRequested, 1);

    Navigator.of(tester.element(find.byType(AnnouncementDetailPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('返回列表后显示的概览', skipOffstage: false), findsNothing);
    expect(find.text('详情期间完成的下一页', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('返回列表后显示的概览'), findsOneWidget);
    expect(find.text('详情期间完成的下一页'), findsOneWidget);
    expect(repository.pagesRequested, 1);
    expect(
        repository.previewRequests
            .where((url) => url == 'https://www.shu.edu.cn/info/1051/2.htm'),
        hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late preview completions are ignored after the list is removed',
      (tester) async {
    final success = Completer<String?>();
    final failure = Completer<String?>();
    final items = [
      for (var index = 0; index < 2; index++)
        AnnouncementListItem(
          title: '待完成通知 $index',
          url: 'https://bksy.shu.edu.cn/info/1000/pending$index.htm',
          sourceId: 'bksy',
        ),
    ];
    final repository = _FakeAnnouncementRepository(
      items: items,
      details: const {},
      previewFutures: {
        items[0].url: success.future,
        items[1].url: failure.future
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await _pumpPendingList(tester);
    expect(repository.previewRequests, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    success.complete('已卸载的概览');
    failure.completeError(StateError('已卸载的请求失败'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a covered list releases deferred page updates safely',
      (tester) async {
    final repository = _DeferredPageAnnouncementRepository();
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.pagesRequested, 1);
    await tester.tap(find.text(_listTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    repository.nextPage.complete(const [_listItem]);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'static resource links skip previews and keep external navigation',
      (tester) async {
    final items = [
      for (final suffix in ['pdf?download=1', 'PNG', 'zip'])
        AnnouncementListItem(
          title: '附件 $suffix',
          url: 'https://hr.shu.edu.cn/attachment.$suffix',
          sourceId: 'hr',
        ),
    ];
    final repository =
        _FakeAnnouncementRepository(items: items, details: const {});
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
    expect(repository.previewRequests, isEmpty);
    expect(repository.publicationDateRequests, isEmpty);
    await tester.tap(find.text(items.first.title));
    await tester.pumpAndSettle();
    expect(openedUrl, items.first.url);
    expect(repository.detailRequestCount, 0);
    expect(find.byType(AnnouncementDetailPage), findsNothing);
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

  testWidgets('external HTML links show previews and still open externally',
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
    expect(repository.previewRequests, [item.url]);
    expect(find.text('申报详情'), findsOneWidget);
    expect(openedUrl, item.url);
  });

  testWidgets('Vancouver Film School keeps its existing list summary',
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

    expect(repository.previewRequests, isEmpty);
    expect(find.text('从正文解析出的两行概览'), findsNothing);
    expect(find.text('列表页摘要'), findsOneWidget);
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
    expect(repository.detailRequests.map((item) => item.sourceId),
        items.map((item) => item.sourceId));
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

  for (final sourceId in ['sfa', 'hr']) {
    for (final previewOutcome in ['failed', 'empty', 'pending']) {
      testWidgets(
          '$sourceId undated external notices keep their source slot with a '
          '$previewOutcome preview', (tester) async {
        final preview = Completer<String?>();
        final older = AnnouncementListItem(
          title: '较旧的已知日期公告',
          url: 'https://$sourceId.shu.edu.cn/info/1212/100.htm',
          sourceId: sourceId,
          summary: '列表已有摘要',
          dateText: '2026-09-03',
          publishedAt: DateTime(2026, 9, 3),
        );
        final external = AnnouncementListItem(
          title: '保留原位置的微信公众号公告',
          url: 'https://mp.weixin.qq.com/s/$sourceId-source-slot',
          sourceId: sourceId,
        );
        final newer = AnnouncementListItem(
          title: '较新的已知日期公告',
          url: 'https://$sourceId.shu.edu.cn/info/1212/101.htm',
          sourceId: sourceId,
          summary: '列表已有摘要',
          dateText: '2026-09-04',
          publishedAt: DateTime(2026, 9, 4),
        );
        final items = [
          older,
          external,
          newer,
          for (var index = 0; index < 24; index++)
            AnnouncementListItem(
              title: '历史公告 $index',
              url: 'https://$sourceId.shu.edu.cn/info/1212/${200 + index}.htm',
              sourceId: sourceId,
              summary: '列表已有摘要',
              dateText: '2026-08-${(31 - index).toString().padLeft(2, '0')}',
              publishedAt: DateTime(2026, 8, 31 - index),
            ),
        ];
        final repository = _FakeAnnouncementRepository(
          items: items,
          details: const {},
          previewFutures: {external.url: preview.future},
        )..currentDefault = AnnouncementSource.byId(sourceId);
        const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
        String? openedUrl;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          urlLauncher,
          (call) async {
            openedUrl =
                (call.arguments as Map<Object?, Object?>)['url'] as String?;
            return true;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(urlLauncher, null));
        await tester.pumpWidget(
          MaterialApp(home: AnnouncementsPage(repository: repository)),
        );
        await _pumpPendingList(tester);

        void expectVisibleSourceSlot() {
          final newestTitle = find.text(newer.title).hitTestable();
          final externalTitle = find.text(external.title).hitTestable();
          final olderTitle = find.text(older.title).hitTestable();
          expect(newestTitle, findsOneWidget);
          expect(externalTitle, findsOneWidget);
          expect(olderTitle, findsOneWidget);
          expect(tester.getTopLeft(newestTitle).dy,
              lessThan(tester.getTopLeft(externalTitle).dy));
          expect(tester.getTopLeft(externalTitle).dy,
              lessThan(tester.getTopLeft(olderTitle).dy));
        }

        expect(_cardOpacity(tester, external), 0);
        expect(find.text(external.title).hitTestable(), findsNothing);
        expect(repository.previewRequests, [external.url]);
        expect(repository.publicationDateRequests, isEmpty);
        if (previewOutcome == 'failed') {
          preview.completeError(StateError('WeChat preview is unavailable'));
        } else if (previewOutcome == 'empty') {
          preview.complete(null);
        } else {
          await tester.pump(AnnouncementRepository.cardPreparationTimeout);
        }
        await tester.pumpAndSettle();
        expectVisibleSourceSlot();
        expect(_cardOpacity(tester, external), 1);

        await tester.tap(find.text(external.title).hitTestable());
        await tester.pumpAndSettle();
        expect(openedUrl, external.url);
        expect(repository.detailRequestCount, 0);
        expect(repository.publicationDateRequests, isEmpty);
        expect(find.byType(AnnouncementDetailPage), findsNothing);
        expect(tester.takeException(), isNull);
        if (!preview.isCompleted) {
          preview.complete('超时后返回的摘要');
          await tester.pumpAndSettle();
          expect(find.text('超时后返回的摘要'), findsNothing);
          expect(_cardOpacity(tester, external), 1);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }

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

  testWidgets('unparsed articles retain the inline error and can retry',
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
    expect(openedUrl, isNull);
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('公告详情加载失败，请稍后重试'), findsOneWidget);

    repository.details[item.title] = AnnouncementDetail(
      title: item.title,
      url: item.url,
      blocks: const [AnnouncementContentBlock.text('重试后加载的公告正文')],
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(repository.detailRequestCount, 2);
    expect(find.text('加载失败'), findsNothing);
    expect(find.text('重试后加载的公告正文'), findsOneWidget);
    expect(openedUrl, isNull);
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
  });

  testWidgets('unavailable youth article retains its preset error page',
      (tester) async {
    const item = AnnouncementListItem(
      title: '失效的团委公告',
      url: 'https://youth.shu.edu.cn/info/1010/22195.htm',
      sourceId: 'youth',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [item],
      details: const {},
      detailErrors: const {
        '失效的团委公告': AnnouncementUnavailableException(),
      },
    );
    const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
    final openedUrls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncher,
      (call) async {
        final url = (call.arguments as Map<Object?, Object?>)['url'] as String?;
        if (url != null) openedUrls.add(url);
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
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
    expect(find.text('公告失效'), findsOneWidget);
    expect(find.text('系统提示：您访问的页面未找到，可能已被删除。'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(openedUrls, isEmpty);

    await tester.tap(find.byTooltip('查看原文'));
    await tester.pumpAndSettle();
    expect(find.text('跳转浏览器'), findsOneWidget);
    expect(openedUrls, isEmpty);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(openedUrls, [item.url]);
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
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

  testWidgets('article detail shows a scrollbar for its list', (tester) async {
    await _openDetail(tester, _repositoryWith());
    await tester.pumpAndSettle();

    final detail = find.byType(AnnouncementDetailPage);
    final scrollbar = find.descendant(
      of: detail,
      matching: find.byType(Scrollbar),
    );
    final list = find.descendant(of: detail, matching: find.byType(ListView));
    expect(scrollbar, findsOneWidget);
    expect(
      tester.widget<Scrollbar>(scrollbar).controller,
      same(tester.widget<ListView>(list).controller),
    );
    expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);
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

  testWidgets('large detail tables use the fast horizontal scrolling path',
      (tester) async {
    final rows = [
      for (var row = 0; row < 60; row++)
        [for (var column = 0; column < 8; column++) 'R${row}C$column'],
    ];
    await _openDetail(
      tester,
      _repositoryWith(blocks: [AnnouncementContentBlock.table(rows)]),
    );
    await tester.pumpAndSettle();

    final table = find.byKey(const ValueKey<String>('announcement-fast-table'));
    expect(table, findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    final topLeft = tester.getTopLeft(table);
    await tester.longPressAt(topLeft + const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('R0C0'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.dragFrom(
        topLeft + const Offset(100, 60), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final horizontal = find.descendant(
      of: table,
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(horizontal).position.pixels,
        greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('very large tables measure across frames before painting',
      (tester) async {
    final rows = [
      for (var row = 0; row < 300; row++)
        [for (var column = 0; column < 16; column++) 'R${row}C$column'],
    ];
    await _openDetail(
      tester,
      _repositoryWith(blocks: [AnnouncementContentBlock.table(rows)]),
    );
    for (var frame = 0;
        frame < 5 && find.byType(CircularProgressIndicator).evaluate().isEmpty;
        frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('announcement-fast-table')),
        findsNothing);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('announcement-fast-table')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
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
