import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_search_service.dart';
import 'package:shuyo/features/home/announcements_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/date_picker_dialog.dart';

const _listTitle = '关于开展实验室安全检查的通知';
const _detailBody = '各单位请于本周五前完成自查';

const _listItem = AnnouncementListItem(
  title: _listTitle,
  url: 'https://www.shu.edu.cn/info/1051/1.htm',
);

class _FakeAnnouncementRepository extends AnnouncementRepository {
  _FakeAnnouncementRepository({
    required this.items,
    required this.details,
    this.previewFutures = const {},
    this.cardFutures = const {},
  });

  final List<AnnouncementListItem> items;
  final Map<String, AnnouncementDetail> details;
  final Map<String, Future<String?>> previewFutures;
  final Map<String, Future<AnnouncementCardData>> cardFutures;
  final cardRequests = <String>[];
  int detailRequestCount = 0;
  final previewRequests = <String>[];
  AnnouncementSource currentDefault = AnnouncementSource.official;
  final favoriteIds = <String>{};
  final sectionExpansion = <AnnouncementMenuSection, bool>{};
  final requestedSources = <String>[];

  @override
  Future<AnnouncementCardData> loadCard(AnnouncementListItem item) async {
    cardRequests.add(item.url);
    final pendingCard = cardFutures[item.url];
    if (pendingCard != null) return pendingCard;
    final pending = previewFutures[item.url];
    if (pending == null) {
      final blocks =
          details[item.title]?.blocks ?? const <AnnouncementContentBlock>[];
      final summary = item.summary.isNotEmpty
          ? item.summary
          : blocks
                  .where((block) => block.isText)
                  .map((block) => block.value)
                  .firstOrNull ??
              '';
      return AnnouncementCardData(
          summary: summary,
          dateText: item.dateText,
          publishedAt: item.publishedAt);
    }
    previewRequests.add(item.url);
    return AnnouncementCardData(
      summary: await pending ?? item.summary,
      dateText: item.dateText,
      publishedAt: item.publishedAt,
    );
  }

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

http.Response _searchResponse(
  List<Map<String, Object?>> records, {
  int? total,
  int current = 0,
}) =>
    http.Response(
      jsonEncode({
        'code': '0000',
        'data': {
          'page': {
            'total': total ?? records.length,
            'size': 50,
            'current': current,
            'records': records,
          },
        },
      }),
      200,
      headers: {'content-type': 'application/json;charset=utf-8'},
    );

Map<String, Object?> _searchRecord({
  String sourceId = 'shu',
  required String title,
  String url = 'https://www.shu.edu.cn/info/1051/1.htm',
  String? summary = '公告概览',
  String date = '2026-10-25 12:00:00',
}) =>
    {
      'index': 'article_data',
      'owner': AnnouncementSource.byId(sourceId).searchOwner,
      'title': title,
      'url': url,
      'column': sourceId == 'bksy' ? '1015' : '1051',
      'columnName': '通知公告',
      'createDate': date,
      if (summary != null) 'intro': summary,
    };

Future<void> _startAnnouncementSearch(
  WidgetTester tester, {
  String query = '目标词',
}) async {
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.byTooltip('开始搜索'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
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

Future<void> _scrollToSearchSource(WidgetTester tester, String name) async {
  final scrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable));
  await tester.scrollUntilVisible(find.text(name), 180, scrollable: scrollable);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('resolved dates sort results and month headers together',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    const first = AnnouncementListItem(
        title: '公告旧', url: 'https://example.org/older', sourceId: 'shu');
    const second = AnnouncementListItem(
        title: '公告新', url: 'https://example.org/newer', sourceId: 'shu');
    final older = Completer<AnnouncementCardData>();
    final newer = Completer<AnnouncementCardData>();
    final repository = _FakeAnnouncementRepository(
        items: const [first, second],
        details: const {},
        cardFutures: {first.url: older.future, second.url: newer.future});
    await tester.pumpWidget(MaterialApp(
        home: AnnouncementSearchPage(repository: repository, isDemo: true)));
    await _startAnnouncementSearch(tester, query: '公告');
    older.complete(AnnouncementCardData(
        summary: '旧摘要', publishedAt: DateTime(2026, 9, 1)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('公告旧'), findsOneWidget);
    expect(find.text('公告新'), findsNothing);
    newer.complete(AnnouncementCardData(
        summary: '新摘要', publishedAt: DateTime(2026, 10, 1)));
    await tester.pumpAndSettle();
    expect(find.text('公告旧'), findsOneWidget);
    expect(find.text('公告新'), findsOneWidget);
    final october = find.text('2026年10月');
    final september = find.text('2026年9月');
    expect(october, findsOneWidget);
    expect(september, findsOneWidget);
    expect(tester.getTopLeft(october).dy,
        lessThan(tester.getTopLeft(find.text('公告新')).dy));
    expect(tester.getTopLeft(find.text('公告新')).dy,
        lessThan(tester.getTopLeft(september).dy));
    expect(tester.getTopLeft(september).dy,
        lessThan(tester.getTopLeft(find.text('公告旧')).dy));
  });

  testWidgets('newer search results wait without hiding existing cards',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'bksy'],
    });
    const newerUrl = 'https://www.shu.edu.cn/info/1051/new.htm';
    final newerCard = Completer<AnnouncementCardData>();
    final secondPage = Completer<http.Response>();
    final repository = _FakeAnnouncementRepository(
        items: const [],
        details: const {},
        cardFutures: {newerUrl: newerCard.future});
    final service = AnnouncementSearchService(
        clientFactory: () => MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if ((body['page'] as Map<String, dynamic>)['current'] == 1) {
                return secondPage.future;
              }
              return _searchResponse([
                _searchRecord(
                    title: '目标词 原公告',
                    url: 'https://www.shu.edu.cn/info/1051/old.htm',
                    date: '2026-09-01 12:00:00'),
                _searchRecord(
                    sourceId: 'bksy',
                    title: '目标词 本科生院',
                    url: 'https://bksy.shu.edu.cn/info/1015/old.htm',
                    date: '2026-09-01 12:00:00'),
              ], total: 51);
            }));
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
        home: AnnouncementSearchPage(
            repository: repository, searchService: service)));
    await _startAnnouncementSearch(tester);
    expect(find.text('目标词 原公告'), findsOneWidget);
    expect(find.text('目标词 本科生院'), findsOneWidget);
    secondPage.complete(_searchResponse([
      _searchRecord(
          title: '目标词 新公告', url: newerUrl, date: '2026-10-01 12:00:00'),
    ], total: 51, current: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('目标词 新公告'), findsNothing);
    expect(find.text('目标词 原公告'), findsOneWidget);
    expect(find.text('目标词 本科生院'), findsOneWidget);
    newerCard.complete(AnnouncementCardData(
        summary: '新摘要', publishedAt: DateTime(2026, 10, 1)));
    await tester.pumpAndSettle();
    expect(find.text('目标词 新公告'), findsOneWidget);
    expect(find.text('目标词 原公告'), findsOneWidget);
    expect(find.text('目标词 本科生院'), findsOneWidget);
    expect(tester.getTopLeft(find.text('目标词 新公告')).dy,
        lessThan(tester.getTopLeft(find.text('目标词 原公告')).dy));
    expect(find.text('2026年10月'), findsOneWidget);
  });

  testWidgets('search cards enter in order with their resolved months',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    const first = AnnouncementListItem(
        title: '公告甲', url: 'https://example.org/first', sourceId: 'shu');
    const second = AnnouncementListItem(
        title: '公告乙', url: 'https://example.org/second', sourceId: 'shu');
    final firstCard = Completer<AnnouncementCardData>();
    final secondCard = Completer<AnnouncementCardData>();
    final repository = _FakeAnnouncementRepository(items: const [
      first,
      second
    ], details: const {}, cardFutures: {
      first.url: firstCard.future,
      second.url: secondCard.future
    });
    await tester.pumpWidget(MaterialApp(
        home: AnnouncementSearchPage(repository: repository, isDemo: true)));
    await _startAnnouncementSearch(tester, query: '公告');
    expect(repository.cardRequests, [first.url, second.url]);
    secondCard.complete(AnnouncementCardData(
        summary: '第二条摘要', publishedAt: DateTime(2026, 9, 1)));
    await tester.pump();
    await tester.pump();
    expect(find.text('公告乙'), findsNothing);
    expect(find.text('2026年9月'), findsNothing);
    firstCard.complete(AnnouncementCardData(
        summary: '第一条摘要', publishedAt: DateTime(2026, 10, 1)));
    await tester.pumpAndSettle();
    expect(find.text('公告甲'), findsOneWidget);
    expect(find.text('公告乙'), findsOneWidget);
    expect(find.text('2026年10月'), findsOneWidget);
    expect(find.text('2026年9月'), findsOneWidget);
    expect(tester.getTopLeft(find.text('公告甲')).dy,
        lessThan(tester.getTopLeft(find.text('公告乙')).dy));
  });

  testWidgets(
      'search scope is selectable inline and obsolete controls stay absent',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
      'announcements.search.fast': true,
      'announcements.search.strength': 5,
      'announcements.search.retryFailures': false,
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索强度'), findsNothing);
    expect(find.textContaining('Fast模式'), findsNothing);
    expect(find.byTooltip('取消搜索'), findsNothing);
    expect(find.byTooltip('更多'), findsNothing);
    expect(find.text('失败重试'), findsNothing);
    expect(
        find.byKey(const ValueKey('announcement-search-scope')), findsNothing);
    expect(find.byTooltip('搜索范围'), findsNothing);
    expect(find.text('搜索范围'), findsNothing);
    expect(find.text('搜索强度'), findsNothing);
    expect(find.text('失败重试'), findsNothing);
    final title = find.byKey(const ValueKey('announcement-search-title-scope'));
    final body = find.byKey(const ValueKey('announcement-search-body-scope'));
    expect(tester.widget<FilterChip>(title).selected, isTrue);
    expect(tester.widget<FilterChip>(body).selected, isFalse);
    expect(find.widgetWithText(FilterChip, '标题'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '内容'), findsOneWidget);
    await tester.tap(body);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(body).selected, isTrue);
  });

  testWidgets('obsolete retry preference does not disable transient recovery',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
      'announcements.search.retryFailures': false,
    });
    var requests = 0;
    final service = AnnouncementSearchService(
      retryBaseDelay: Duration.zero,
      clientFactory: () => MockClient((request) async {
        requests++;
        if (requests == 1) return http.Response('unavailable', 503);
        return _searchResponse([
          _searchRecord(title: '目标词 恢复后的公告'),
        ]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('目标词 恢复后的公告'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('失败重试'), findsNothing);
  });

  testWidgets('tapping blank search page space dismisses the query keyboard',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.enterText(field, '保留搜索关键词');
    await tester.pump();
    final input = tester.widget<TextField>(field);
    expect(input.focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    final bottom = tester.getBottomLeft(find.byType(Scaffold)).dy;
    await tester.tapAt(Offset(8, bottom - 24));
    await tester.pump();

    expect(input.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(input.controller!.text, '保留搜索关键词');
  });

  testWidgets('search field and inline scope match the app input style',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final theme = ShuYoThemes.byId(ShuYoThemes.defaultId).themeData();
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.labelText, '搜索公告关键词');
    expect(field.decoration!.hintText, isNull);
    expect(field.decoration!.prefixIcon, isNull);
    final decoration = tester
        .widget<InputDecorator>(find.descendant(
          of: find.byType(TextField),
          matching: find.byType(InputDecorator),
        ))
        .decoration;
    expect(decoration.filled, isFalse);
    expect(decoration.enabledBorder, theme.inputDecorationTheme.enabledBorder);
    expect(decoration.focusedBorder, theme.inputDecorationTheme.focusedBorder);
    final count = find.byKey(const ValueKey('announcement-search-found-count'));
    final title = find.byKey(const ValueKey('announcement-search-title-scope'));
    final body = find.byKey(const ValueKey('announcement-search-body-scope'));
    expect(tester.getCenter(title).dy, closeTo(tester.getCenter(count).dy, 1));
    expect(tester.getCenter(body).dy, closeTo(tester.getCenter(count).dy, 1));
    expect(
        tester.getTopLeft(title).dx, greaterThan(tester.getTopRight(count).dx));
    expect(
        tester.getTopLeft(body).dx, greaterThan(tester.getTopRight(title).dx));
    expect(tester.getBottomRight(body).dx, lessThanOrEqualTo(304));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'malformed API response reports one failure without a retry action',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    var requests = 0;
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response('invalid JSON', 200);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    expect(find.text('1 项解析失败'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(SnackBar), matching: find.text('1 项解析失败')),
        findsOneWidget);
    expect(find.text('没有找到公告'), findsOneWidget);
    expect(find.text('继续失败项'), findsNothing);
    expect(requests, 1);
  });

  testWidgets(
      'API snippets highlight every literal term without another article preview request',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
      'announcements.search.includeBody': true,
    });
    final requests = <http.Request>[];
    final repository = _repositoryWith();
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return _searchResponse([
          _searchRecord(
            title: '普通公告',
            summary: '<em>目标</em>内容，与 C++ 及 c++ 相关的目标',
          ),
        ]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: repository,
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester, query: '目标 C++');
    expect(find.text('普通公告'), findsOneWidget);
    final snippet = find.text('目标内容，与 C++ 及 c++ 相关的目标');
    expect(snippet, findsOneWidget);
    final preview = tester.widget<Text>(snippet);
    final primary = Theme.of(tester.element(snippet)).colorScheme.primary;
    final highlighted = (preview.textSpan! as TextSpan)
        .children!
        .whereType<TextSpan>()
        .where((span) => span.style?.color == primary)
        .map((span) => span.text);
    expect(highlighted, ['目标', 'C++', 'c++', '目标']);
    expect(preview.maxLines, 2);
    expect(preview.overflow, TextOverflow.ellipsis);
    expect(repository.previewRequests, isEmpty);
    expect(requests, hasLength(1));
    final requestBody =
        jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(requestBody['owner'], AnnouncementSource.official.searchOwner);
    expect(requestBody['searchScope'], 3);
  });

  testWidgets(
      'search detail receives the active query rather than edited input',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await _startAnnouncementSearch(tester, query: '实验室');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '下次查询');
    await tester.tap(find.text(_listTitle));
    await tester.pumpAndSettle();
    final detail = tester.widget<AnnouncementDetailPage>(
      find.byType(AnnouncementDetailPage),
    );
    expect(detail.highlightQuery, '实验室');
    expect(find.text(_detailBody), findsOneWidget);
  });

  testWidgets('search result waits for its card preview before entering',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    const title = '目标词 上海大学官网';
    const url = 'https://www.shu.edu.cn/info/1051/1.htm';
    final pendingPreview = Completer<String?>();
    final repository = _FakeAnnouncementRepository(
      items: const [],
      previewFutures: {url: pendingPreview.future},
      details: const {},
    );
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async => _searchResponse([
            _searchRecord(title: title, url: url, summary: null),
          ])),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: repository,
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    expect(find.text(title), findsNothing);
    expect(find.text('正文概览一段'), findsNothing);
    pendingPreview.complete('正文概览一段');
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(find.text('正文概览一段'), findsOneWidget);
    expect(repository.previewRequests, [url]);
  });

  testWidgets('search retains shared URLs under their respective departments',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'bksy'],
    });
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async => _searchResponse([
            _searchRecord(title: '目标词 上海大学官网'),
            _searchRecord(sourceId: 'bksy', title: '目标词 本科生院'),
            _searchRecord(title: '目标词 新标题'),
          ])),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    expect(find.text('目标词 上海大学官网'), findsOneWidget);
    expect(find.text('目标词 本科生院'), findsOneWidget);
    expect(find.text('目标词 新标题'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(
            const ValueKey<String>('announcement-search-found-count'),
          ))
          .data,
      '3',
    );
  });

  testWidgets('API pages append seamlessly without changing the input style',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final secondPage = Completer<http.Response>();
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final page = body['page'] as Map<String, dynamic>;
        if (page['current'] == 1) return secondPage.future;
        return _searchResponse([
          for (var index = 0; index < 50; index++)
            _searchRecord(
              title: '目标词 公告 $index',
              url: 'https://www.shu.edu.cn/info/1051/$index.htm',
            ),
        ], total: 51);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await tester.pumpAndSettle();
    final inputFinder = find.byType(TextField);
    final inputElement = tester.element(inputFinder);
    final initialInput = tester.widget<TextField>(inputFinder);
    expect(initialInput.readOnly, isFalse);
    final decoratorFinder = find.descendant(
      of: inputFinder,
      matching: find.byType(InputDecorator),
    );
    final initialDecoration =
        tester.widget<InputDecorator>(decoratorFinder).decoration;
    await _startAnnouncementSearch(tester);
    expect(find.text('目标词 公告 0'), findsOneWidget);
    final searchingInput = tester.widget<TextField>(inputFinder);
    expect(tester.element(inputFinder), same(inputElement));
    expect(searchingInput.readOnly, isTrue);
    expect(searchingInput.enabled, isNot(false));
    expect(searchingInput.decoration, initialInput.decoration);
    final searchingDecoration =
        tester.widget<InputDecorator>(decoratorFinder).decoration;
    expect(searchingDecoration.enabled, isTrue);
    expect(searchingDecoration.enabledBorder, initialDecoration.enabledBorder);
    expect(searchingDecoration.focusedBorder, initialDecoration.focusedBorder);
    expect(searchingDecoration.fillColor, initialDecoration.fillColor);
    expect(searchingInput.controller!.text, '目标词');
    expect(tester.widget<EditableText>(find.byType(EditableText)).readOnly,
        isTrue);
    expect(find.byTooltip('取消搜索'), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.ancestor(
            of: find.byTooltip('开始搜索'),
            matching: find.byType(IconButton),
          ))
          .onPressed,
      isNull,
    );
    expect(
        tester
            .widget<Text>(find.byKey(
              const ValueKey<String>('announcement-search-found-count'),
            ))
            .data,
        '50');
    final scrollView = find.byType(CustomScrollView).last;
    await tester.drag(scrollView, const Offset(0, -260));
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)),
    );
    final offset = scrollable.position.pixels;
    final retainedTitle = tester.widget<Text>(
      find.textContaining('目标词 公告 ').hitTestable().first,
    );
    final retainedText =
        retainedTitle.data ?? retainedTitle.textSpan!.toPlainText();
    secondPage.complete(_searchResponse([
      _searchRecord(
        title: '目标词 最后一条公告',
        url: 'https://www.shu.edu.cn/info/1051/50.htm',
        date: '2026-10-24 12:00:00',
      ),
    ], total: 51, current: 1));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, offset);
    expect(
        tester
            .widget<Text>(find.byKey(
              const ValueKey<String>('announcement-search-found-count'),
            ))
            .data,
        '51');
    final completedInput = tester.widget<TextField>(inputFinder);
    expect(tester.element(inputFinder), same(inputElement));
    expect(completedInput.readOnly, isFalse);
    expect(completedInput.enabled, isNot(false));
    expect(completedInput.decoration, initialInput.decoration);
    expect(completedInput.controller!.text, '目标词');
    expect(find.text(retainedText), findsOneWidget);
  });

  testWidgets('search updates wait while a detail route covers results',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final secondPage = Completer<http.Response>();
    const firstTitle = '目标词 公告 0';
    final repository = _FakeAnnouncementRepository(
      items: const [],
      details: {
        firstTitle: const AnnouncementDetail(
          title: firstTitle,
          url: 'https://www.shu.edu.cn/info/1051/0.htm',
          blocks: [AnnouncementContentBlock.text('文章正文')],
        ),
      },
    );
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if ((body['page'] as Map<String, dynamic>)['current'] == 1) {
          return secondPage.future;
        }
        return _searchResponse([
          for (var index = 0; index < 50; index++)
            _searchRecord(
              title: '目标词 公告 $index',
              url: 'https://www.shu.edu.cn/info/1051/$index.htm',
            ),
        ], total: 51);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: repository,
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    Text foundCount() => tester.widget<Text>(find.byKey(
          const ValueKey<String>('announcement-search-found-count'),
          skipOffstage: false,
        ));
    expect(foundCount().data, '50');
    await tester.tap(find.text(firstTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AnnouncementDetailPage), findsOneWidget);
    final coveredList = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView, skipOffstage: false),
    );
    secondPage.complete(_searchResponse([
      _searchRecord(
          title: '目标词 稍后到达的公告', url: 'https://www.shu.edu.cn/info/1051/50.htm'),
    ], total: 51, current: 1));
    await tester.pump(const Duration(milliseconds: 700));
    expect(foundCount().data, '50');
    expect(
        identical(
            coveredList,
            tester.widget<CustomScrollView>(
              find.byType(CustomScrollView, skipOffstage: false),
            )),
        isTrue);
    Navigator.of(tester.element(find.byType(AnnouncementDetailPage))).pop();
    await tester.pumpAndSettle();
    expect(foundCount().data, '51');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
  });

  testWidgets('updating one department preserves the other department sliver',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'bksy'],
    });
    final secondPage = Completer<http.Response>();
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if ((body['page'] as Map<String, dynamic>)['current'] == 1) {
          return secondPage.future;
        }
        return _searchResponse([
          _searchRecord(title: '目标词 上海大学官网'),
          for (var index = 0; index < 49; index++)
            _searchRecord(
              sourceId: 'bksy',
              title: '目标词 本科生院 $index',
              url: 'https://bksy.shu.edu.cn/info/1015/$index.htm',
            ),
        ], total: 51);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    final officialSliver = tester.widget<SliverMainAxisGroup>(
      find.byType(SliverMainAxisGroup).first,
    );
    secondPage.complete(_searchResponse([
      _searchRecord(
          sourceId: 'bksy',
          title: '目标词 本科生院 新公告',
          url: 'https://bksy.shu.edu.cn/info/1015/50.htm'),
    ], total: 51, current: 1));
    await tester.pumpAndSettle();
    expect(
        identical(
            officialSliver,
            tester.widget<SliverMainAxisGroup>(
              find.byType(SliverMainAxisGroup).first,
            )),
        isTrue);
  });

  testWidgets(
      'search locks scope while source changes apply to the next request',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'bksy'],
    });
    final firstPage = Completer<http.Response>();
    final requests = <Map<String, dynamic>>[];
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (requests.length == 1) return firstPage.future;
        return _searchResponse([]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    Future<void> pumpOverlay() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tester.tap(find.byTooltip('筛选部门'));
    await pumpOverlay();
    await _scrollToSearchSource(tester, '本科生院');
    await tester.tap(find.text('本科生院'));
    await pumpOverlay();
    await tester.tapAt(const Offset(8, 8));
    await pumpOverlay();
    final bodyScope = find.byKey(
      const ValueKey('announcement-search-body-scope'),
    );
    final titleScope = find.byKey(
      const ValueKey('announcement-search-title-scope'),
    );
    expect(tester.widget<FilterChip>(titleScope).onSelected, isNull);
    expect(tester.widget<FilterChip>(bodyScope).onSelected, isNull);
    await tester.tap(titleScope);
    await tester.tap(bodyScope);
    await pumpOverlay();
    expect(tester.widget<FilterChip>(titleScope).selected, isTrue);
    expect(tester.widget<FilterChip>(bodyScope).selected, isFalse);
    expect((requests.single['owner'] as String).split(',').toSet(), {
      AnnouncementSource.official.searchOwner,
      AnnouncementSource.byId('bksy').searchOwner,
    });
    expect(requests.single['searchScope'], 1);
    firstPage.complete(_searchResponse([
      _searchRecord(sourceId: 'bksy', title: '目标词 本科生院公告'),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('目标词 本科生院公告'), findsOneWidget);
    expect(tester.widget<FilterChip>(titleScope).onSelected, isNotNull);
    expect(tester.widget<FilterChip>(bodyScope).onSelected, isNotNull);
    expect(tester.widget<FilterChip>(bodyScope).selected, isFalse);
    await tester.tap(bodyScope);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(bodyScope).selected, isTrue);
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last['owner'], AnnouncementSource.official.searchOwner);
    expect(requests.last['searchScope'], 3);
    expect(find.text('目标词 本科生院公告'), findsNothing);
  });

  testWidgets('search begins with no departments selected', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '公告');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pump();
    expect(find.text('请至少选择一个部门'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('time presets reuse the department filter panel style',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      const ValueKey('announcement-search-time-filter'),
    ));
    await tester.pumpAndSettle();
    final timeMenu = find.byKey(
      const ValueKey('announcement-search-time-menu'),
    );
    final timeMaterial = tester.widget<Material>(find
        .descendant(
          of: timeMenu,
          matching: find.byType(Material),
        )
        .first);
    final timePosition = tester.getTopRight(timeMenu);
    final timeWidth = tester.getSize(timeMenu).width;
    expect(timeMaterial.elevation, 12);
    expect(timeMaterial.borderRadius, BorderRadius.circular(16));
    expect(timeMaterial.clipBehavior, Clip.antiAlias);
    expect(find.byType(PopupMenuButton), findsNothing);
    for (final preset in ['all', 'week', 'month', 'year', 'custom']) {
      expect(find.byKey(ValueKey('announcement-search-time-$preset')),
          findsOneWidget);
    }
    expect(
      tester
          .widget<ListTile>(find.byKey(
            const ValueKey('announcement-search-time-all'),
          ))
          .selected,
      isTrue,
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(timeMenu, findsNothing);
    await tester.tap(find.byTooltip('筛选部门'));
    await tester.pumpAndSettle();
    final sourceMenu = find.byKey(announcementSourceMenuKey);
    final sourceMaterial = tester.widget<Material>(find
        .descendant(
          of: sourceMenu,
          matching: find.byType(Material),
        )
        .first);
    expect(tester.getTopRight(sourceMenu), timePosition);
    expect(tester.getSize(sourceMenu).width, timeWidth);
    expect(sourceMaterial.elevation, timeMaterial.elevation);
    expect(sourceMaterial.borderRadius, timeMaterial.borderRadius);
    expect(sourceMaterial.clipBehavior, timeMaterial.clipBehavior);
    expect(sourceMaterial.color, timeMaterial.color);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AppBar time choices snapshot dates for the next search',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final firstPage = Completer<http.Response>();
    final requests = <Map<String, dynamic>>[];
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (requests.length == 1) return firstPage.future;
        return _searchResponse([]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip('搜索时间：时间不限'), findsOneWidget);
    Future<void> choose(String label) async {
      await tester.tap(find.byKey(
        const ValueKey('announcement-search-time-filter'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('announcement-search-time-menu')),
          findsOneWidget);
      expect(find.byType(CheckedPopupMenuItem), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await choose('近一周');
    await _startAnnouncementSearch(tester);
    final today = DateUtils.dateOnly(DateTime.now());
    String apiDay(DateTime day) =>
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final weekBegin = DateTime(today.year, today.month, today.day - 6);
    expect(requests.single['searchDateType'], 'custom');
    expect(requests.single['beginDate'], '${apiDay(weekBegin)} 00:00:00');
    expect(requests.single['endDate'], '${apiDay(today)} 23:59:59');

    await choose('时间不限');
    expect(requests, hasLength(1));
    expect(requests.single['beginDate'], '${apiDay(weekBegin)} 00:00:00');
    firstPage.complete(_searchResponse([]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.containsKey('beginDate'), isFalse);
    expect(requests.last['searchDateType'], 'custom');
    expect(find.text('公告数'), findsOneWidget);
  });

  testWidgets('custom time picker sends both inclusive calendar dates',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final requests = <Map<String, dynamic>>[];
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _searchResponse([]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      const ValueKey('announcement-search-time-filter'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      const ValueKey('announcement-search-time-custom'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ShuYoDatePickerDialog), findsOneWidget);
    final year = DateTime.now().year - 1;
    final localizations = MaterialLocalizations.of(
      tester.element(find.byType(ShuYoDatePickerDialog)),
    );
    await tester.tap(find.text(localizations.formatMonthYear(DateTime.now())));
    await tester.pumpAndSettle();
    final chosenYear = find.descendant(
      of: find.byType(YearPicker),
      matching: find.text('$year'),
    );
    await tester.ensureVisible(chosenYear);
    await tester.tap(chosenYear);
    await tester.pumpAndSettle();
    for (var month = DateTime.now().month; month > 1; month--) {
      await tester.tap(find.byTooltip(localizations.previousMonthTooltip));
      await tester.pumpAndSettle();
    }
    for (final day in [2, 5]) {
      final cell = find.byKey(ValueKey<DateTime>(DateTime(year, 1, day)));
      if (cell.hitTestable().evaluate().isEmpty) {
        final scroll = find
            .descendant(
              of: find.byType(ShuYoDatePickerDialog),
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        await tester.drag(scroll, const Offset(0, -100));
        await tester.pumpAndSettle();
      }
      await tester.tap(cell);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.text('确定'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(ShuYoDatePickerDialog), findsNothing);
    expect(find.byTooltip('搜索时间：$year/01/02—$year/01/05'), findsOneWidget);
    await _startAnnouncementSearch(tester);
    expect(requests.single['beginDate'], '$year-01-02 00:00:00');
    expect(requests.single['endDate'], '$year-01-05 23:59:59');
  });

  testWidgets('rapid historical pages keep offscreen search articles lazy',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    const count = 1440;
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final current =
            (body['page'] as Map<String, dynamic>)['current'] as int;
        final start = current * 50;
        return _searchResponse([
          for (var index = start; index < start + 50 && index < count; index++)
            _searchRecord(
              title: '目标词 历史公告 $index',
              url: 'https://www.shu.edu.cn/info/1051/$index.htm',
              date:
                  '${DateTime(2026, 10 - index ~/ 12).toIso8601String().substring(0, 10)} 12:00:00',
            ),
        ], total: count, current: current);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    final firstApplied = int.parse(tester
        .widget<Text>(find.byKey(
          const ValueKey<String>('announcement-search-found-count'),
        ))
        .data!);
    expect(firstApplied, greaterThan(0));
    expect(firstApplied, lessThan(count));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(
            const ValueKey<String>('announcement-search-found-count'),
          ))
          .data,
      '$count',
    );
    expect(
      find.textContaining('目标词 历史公告 ', skipOffstage: false),
      findsAtLeastNWidgets(1),
    );
    // This used to mount one animated article per historical month even
    // with cacheExtent zero; the list now builds only its visible children.
    expect(
      find.textContaining('目标词 历史公告 ', skipOffstage: false).evaluate().length,
      lessThan(20),
    );
    expect(find.byType(SliverMainAxisGroup), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    final scrollView = find.byType(CustomScrollView).last;
    await tester.drag(scrollView, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('arriving search pages wait until an active drag ends',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final nextPage = Completer<http.Response>();
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if ((body['page'] as Map<String, dynamic>)['current'] == 1) {
          return nextPage.future;
        }
        return _searchResponse([
          for (var index = 0; index < 50; index++)
            _searchRecord(
              title: '目标词 滚动公告 $index',
              url: 'https://www.shu.edu.cn/info/1051/$index.htm',
            ),
        ], total: 51);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester);
    Text count() => tester.widget<Text>(find.byKey(
          const ValueKey<String>('announcement-search-found-count'),
        ));
    expect(count().data, '50');
    final scrollView = find.byType(CustomScrollView).last;
    final gesture = await tester.startGesture(tester.getCenter(scrollView));
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    nextPage.complete(_searchResponse([
      _searchRecord(
        title: '目标词 拖动后追加公告',
        url: 'https://www.shu.edu.cn/info/1051/50.htm',
      ),
    ], total: 51, current: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(count().data, '50');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(count().data, '51');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
  });

  testWidgets('a fast new search completes after resetting a scrolled list',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    final service = AnnouncementSearchService(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final query = body['keyWord'] as String;
        return _searchResponse([
          for (var index = 0; index < 50; index++)
            _searchRecord(
              title: '$query 公告 $index',
              url: 'https://www.shu.edu.cn/info/1051/$index.htm',
            ),
        ]);
      }),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        searchService: service,
      ),
    ));
    await _startAnnouncementSearch(tester, query: '第一轮');
    await tester.pumpAndSettle();
    final scrollView = find.byType(CustomScrollView).last;
    await tester.drag(scrollView, const Offset(0, -300));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, greaterThan(0));

    await tester.enterText(find.byType(TextField), '第二轮');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // A ScrollEnd caused by resetting the previous list must not leave the
    // next run's fast response waiting behind an obsolete frame callback.
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    expect(find.text('第二轮 公告 0'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(
            const ValueKey<String>('announcement-search-found-count'),
          ))
          .data,
      '50',
    );
  });

  testWidgets('title match and searched count use the theme color',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu']
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.enterText(find.byType(TextField), '实验室');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text(_listTitle));
    final primary =
        Theme.of(tester.element(find.text(_listTitle))).colorScheme.primary;
    final colors = tester.element(find.text(_listTitle)).shuyoColors;
    expect(
      (title.textSpan! as TextSpan)
          .children!
          .whereType<TextSpan>()
          .singleWhere((span) => span.text == '实验室')
          .style!
          .color,
      primary,
    );
    Text number(String key) =>
        tester.widget<Text>(find.byKey(ValueKey<String>(key)));
    expect(number('announcement-search-found-count').data, '1');
    expect(number('announcement-search-found-count').style!.color, primary);
    expect(number('announcement-search-total-count').data, '1');
    expect(number('announcement-search-total-count').style!.color,
        colors.textPrimary);
    expect(number('announcement-search-total-count').style!.fontSize, 18);
    expect(number('announcement-search-found-count').style!.fontSize, 26);
    expect(find.text('公告数'), findsOneWidget);
    expect(
        tester.widget<Text>(find.text('/')).style!.color, colors.textPrimary);
    expect(
      tester
          .widget<FilterChip>(find.byKey(
            const ValueKey('announcement-search-title-scope'),
          ))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(find.byKey(
            const ValueKey('announcement-search-body-scope'),
          ))
          .selected,
      isFalse,
    );
    expect(find.text('搜到'), findsNothing);
    expect(find.text('搜寻'), findsNothing);
    expect(
        tester
            .getSize(find.byKey(
                const ValueKey<String>('announcement-search-found-count')))
            .width,
        lessThan(42));
    expect(number('announcement-search-found-count').style!.fontFeatures,
        contains(const FontFeature.tabularFigures()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search controls stay visible while results scroll',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu']
    });
    final items = [
      for (var index = 0; index < 30; index++)
        AnnouncementListItem(
          title: '公告 $index',
          url: 'https://example.org/$index',
          summary: '概览',
        ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository:
            _FakeAnnouncementRepository(items: items, details: const {}),
        isDemo: true,
      ),
    ));
    await tester.enterText(find.byType(TextField), '公告');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(Scrollbar), findsOneWidget);
    await tester.drag(
        find.byType(CustomScrollView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(
        find.descendant(
          of: find.byTooltip('开始搜索'),
          matching: find.byIcon(Icons.search),
        ),
        findsOneWidget);
  });

  testWidgets('interleaved dates still produce one header per department',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['bksy', 'xgb', 'sfs']
    });
    final repository = _FakeAnnouncementRepository(
      items: [
        AnnouncementListItem(
          title: '公告甲新',
          url: 'https://example.org/a-new',
          sourceId: 'bksy',
          summary: '概览',
          publishedAt: DateTime(2026, 10, 3),
        ),
        AnnouncementListItem(
          title: '公告乙',
          url: 'https://example.org/b',
          sourceId: 'xgb',
          summary: '概览',
          publishedAt: DateTime(2026, 10, 4),
        ),
        AnnouncementListItem(
          title: '公告甲旧',
          url: 'https://example.org/a-old',
          sourceId: 'bksy',
          summary: '概览',
          publishedAt: DateTime(2026, 10, 1),
        ),
        AnnouncementListItem(
          title: '公告丙',
          url: 'https://example.org/c',
          sourceId: 'sfs',
          summary: '概览',
          publishedAt: DateTime(2026, 10, 5),
        ),
      ],
      details: const {},
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: repository, isDemo: true),
    ));
    await tester.enterText(find.byType(TextField), '公告');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();

    expect(find.text('本科生院'), findsOneWidget);
    expect(find.text('本科生工作处'), findsOneWidget);
    expect(tester.getTopLeft(find.text('公告甲新')).dy,
        lessThan(tester.getTopLeft(find.text('公告甲旧')).dy));
    expect(tester.getTopLeft(find.text('公告乙')).dy,
        lessThan(tester.getTopLeft(find.text('公告甲旧')).dy));
    await tester.drag(
        find.byType(CustomScrollView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('外国语学院'), findsOneWidget);
    expect(find.text('公告丙'), findsOneWidget);
  });

  testWidgets('search department and month pin independently', (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['xgb', 'bksy']
    });
    final items = [
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '十月公告 $index',
          url: 'https://example.org/xgb/oct/$index',
          sourceId: 'xgb',
          publishedAt: DateTime(2026, 10, 20 - index),
          summary: '公告概览',
        ),
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '九月公告 $index',
          url: 'https://example.org/xgb/sep/$index',
          sourceId: 'xgb',
          publishedAt: DateTime(2026, 9, 20 - index),
          summary: '公告概览',
        ),
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '八月公告 $index',
          url: 'https://example.org/bksy/aug/$index',
          sourceId: 'bksy',
          publishedAt: DateTime(2026, 8, 20 - index),
          summary: '公告概览',
        ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository:
            _FakeAnnouncementRepository(items: items, details: const {}),
        isDemo: true,
      ),
    ));
    await tester.enterText(find.byType(TextField), '公告');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    final scrollView = find.byType(CustomScrollView).last;
    await tester.drag(scrollView, const Offset(0, -400));
    await tester.pumpAndSettle();
    final octoberDepartment = find.byKey(
      const ValueKey('announcement-sticky-department-本科生工作处'),
    );
    final octoberMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生工作处-2026年10月'),
    );
    expect(tester.getTopLeft(octoberDepartment).dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
    expect(tester.getTopLeft(octoberMonth).dy,
        closeTo(tester.getBottomLeft(octoberDepartment).dy, 1));
    expect(tester.getSize(octoberDepartment).height,
        tester.getSize(octoberMonth).height);
    expect(tester.getSize(octoberDepartment).width,
        tester.getSize(octoberMonth).width);
    expect(find.text('2026年10月'), findsOneWidget);

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)),
    );
    final septemberDepartment = find.byKey(
      const ValueKey('announcement-sticky-department-本科生工作处'),
    );
    final septemberMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生工作处-2026年9月'),
    );
    for (var i = 0; i < 20 && septemberMonth.evaluate().isEmpty; i++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(tester.getTopLeft(septemberDepartment).dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
    expect(tester.getTopLeft(septemberMonth).dy,
        closeTo(tester.getBottomLeft(septemberDepartment).dy, 1));
    final augustDepartment = find.byKey(
      const ValueKey('announcement-sticky-department-本科生院'),
    );
    final augustMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生院-2026年8月'),
    );
    for (var i = 0; i < 20 && augustMonth.evaluate().isEmpty; i++) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(tester.getTopLeft(augustDepartment).dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
    expect(tester.getTopLeft(augustMonth).dy,
        closeTo(tester.getBottomLeft(augustDepartment).dy, 1));
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets(
      'inline search scope chips preserve body matching and saved selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    final bodyScope = find.byKey(
      const ValueKey('announcement-search-body-scope'),
    );
    await tester.tap(bodyScope);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _detailBody);
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text(_listTitle), findsOneWidget);
    expect(find.text('上海大学官网'), findsOneWidget);
    expect(
        find.descendant(
          of: find.byType(CustomScrollView).last,
          matching: find.text(_detailBody),
        ),
        findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('announcements.search.includeBody'), isTrue);
    expect(tester.widget<FilterChip>(bodyScope).selected, isTrue);
    expect(find.byTooltip('搜索范围'), findsNothing);
  });

  testWidgets('search scope allows content only and requires one selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
      'announcements.search.includeTitle': false,
      'announcements.search.includeBody': true,
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    final titleScope = find.byKey(
      const ValueKey('announcement-search-title-scope'),
    );
    final bodyScope = find.byKey(
      const ValueKey('announcement-search-body-scope'),
    );
    expect(tester.widget<FilterChip>(titleScope).selected, isFalse);
    expect(tester.widget<FilterChip>(bodyScope).selected, isTrue);

    await tester.enterText(find.byType(TextField), '实验室');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text(_listTitle), findsNothing);

    await tester.enterText(find.byType(TextField), _detailBody);
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text(_listTitle), findsOneWidget);

    await tester.tap(bodyScope);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('announcements.search.includeTitle'), isFalse);
    expect(prefs.getBool('announcements.search.includeBody'), isFalse);
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pump();
    expect(find.text('请至少选择一个搜索范围'), findsOneWidget);
  });

  testWidgets('search source menu filters departments and updates badge',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'bksy'],
    });
    final repository = _FakeAnnouncementRepository(
      items: const [
        AnnouncementListItem(
          title: '官网公告',
          url: 'https://example.org/official',
          sourceId: 'shu',
        ),
        AnnouncementListItem(
          title: '本科生院公告',
          url: 'https://example.org/bksy',
          sourceId: 'bksy',
        ),
      ],
      details: const {},
    );
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: repository, isDemo: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byTooltip('筛选部门'));
    await tester.pumpAndSettle();
    expect(find.byKey(announcementSourceMenuKey), findsOneWidget);
    expect(find.text('收藏'), findsNothing);
    await _scrollToSearchSource(tester, '本科生院');
    expect(find.text('本科生院'), findsOneWidget);
    await _scrollToSearchSource(tester, '本科生院');
    await tester.tap(find.text('本科生院'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('本科生院'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '公告');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text('官网公告'), findsOneWidget);
    expect(find.text('本科生院公告'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getStringList('announcements.search.selectedSources'), ['shu']);
  });

  testWidgets('filter icon shows a small plain theme-colored ALL or count',
      (tester) async {
    void checkLabel(String label) {
      final filter = find.byTooltip('筛选部门');
      final textFinder = find.descendant(
        of: filter,
        matching: find.text(label),
      );
      final iconFinder = find.descendant(
        of: filter,
        matching: find.byIcon(Icons.filter_list),
      );
      final buttonFinder = find.ancestor(
        of: filter,
        matching: find.byType(IconButton),
      );
      final text = tester.widget<Text>(textFinder);
      final theme = Theme.of(tester.element(filter));
      expect(text.style!.color, theme.colorScheme.primary);
      expect(text.style!.fontSize, 10);
      expect(text.style!.fontWeight, FontWeight.w600);
      expect(iconFinder, findsOneWidget);
      expect(buttonFinder, findsOneWidget);
      expect(tester.getRect(textFinder).right,
          lessThan(tester.getRect(iconFinder).right + 8));
      expect(tester.getRect(textFinder).bottom,
          lessThan(tester.getRect(iconFinder).bottom + 6));
      expect(
          (tester.getCenter(iconFinder) - tester.getCenter(buttonFinder))
              .distance,
          lessThan(1));
      expect(tester.getCenter(textFinder).dx,
          greaterThan(tester.getCenter(iconFinder).dx));
      expect(tester.getCenter(textFinder).dy,
          greaterThan(tester.getCenter(iconFinder).dy));
      expect(
          find.byKey(
              const ValueKey<String>('announcement-search-filter-badge')),
          findsNothing);
    }

    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': [
        for (final source
            in AnnouncementSource.all.where((source) => source.supportsSearch))
          source.id
      ]
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    checkLabel('ALL');

    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': [
        for (final source in AnnouncementSource.all.take(12)) source.id,
      ],
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        key: UniqueKey(),
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    checkLabel('12');
  });

  testWidgets('source group checkboxes select and clear a whole group',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': <String>[],
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(
        repository: _repositoryWith(),
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选部门'));
    await tester.pumpAndSettle();

    final portalCheckbox = find.byKey(
        const ValueKey<String>('announcement-search-group-schoolPortal'));
    expect(tester.widget<Checkbox>(portalCheckbox).value, isFalse);
    await tester.tap(portalCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(portalCheckbox).value, isTrue);
    expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey<String>(
                'announcement-search-group-administrativeDepartment')))
            .value,
        isFalse);
    await tester.tap(portalCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校门户'));
    await tester.pumpAndSettle();

    final schoolCheckbox = find.byKey(const ValueKey<String>(
        'announcement-search-group-administrativeDepartment'));
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isFalse);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isTrue);
    expect(
        find.text(
            '${AnnouncementSource.inGroup(AnnouncementSourceGroup.administrativeDepartment).length}'),
        findsOneWidget);
    await _scrollToSearchSource(tester, '本科生院');
    await tester.tap(find.text('本科生院'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isNull);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isTrue);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isFalse);

    await tester.scrollUntilVisible(find.text('行政部门'), -180,
        scrollable: find.descendant(
            of: find.byKey(announcementSourceMenuKey),
            matching: find.byType(Scrollable)));
    await tester.tap(find.text('行政部门'));
    await tester.pumpAndSettle();
    final collegeCheckbox =
        find.byKey(const ValueKey<String>('announcement-search-group-college'));
    await tester.tap(collegeCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(collegeCheckbox).value, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getStringList('announcements.search.selectedSources')!.toSet(),
        AnnouncementSource.inGroup(AnnouncementSourceGroup.college)
            .where((source) => source.supportsSearch)
            .map((source) => source.id)
            .toSet());
  });

  testWidgets('unsupported saved search sources are removed and disabled',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu', 'shvfs'],
    });
    final repository = _repositoryWith();
    repository.sectionExpansion[AnnouncementMenuSection.schoolPortal] = false;
    repository.sectionExpansion[
        AnnouncementMenuSection.administrativeDepartment] = false;
    repository.sectionExpansion[AnnouncementMenuSection.college] = true;
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: repository, isDemo: true),
    ));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getStringList('announcements.search.selectedSources'), ['shu']);
    await tester.tap(find.byTooltip('筛选部门'));
    await tester.pumpAndSettle();
    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
    final sourceName = AnnouncementSource.byId('shvfs').name;
    await tester.scrollUntilVisible(find.text(sourceName), 300,
        scrollable: menuScrollable);
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text(sourceName),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(row).enabled, isFalse);
    expect(tester.widget<ListTile>(row).onTap, isNull);
    final checkbox = tester.widget<Checkbox>(find.descendant(
      of: row,
      matching: find.byType(Checkbox),
    ));
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNull);
    await tester.tap(find.text(sourceName));
    await tester.pumpAndSettle();
    expect(
        prefs.getStringList('announcements.search.selectedSources'), ['shu']);
  });
}
