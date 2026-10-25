import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';
import 'package:shuyo/data/services/announcement_search_service.dart';
import 'package:shuyo/features/home/announcements_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

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
        schoolPortal:
            sectionExpansion[AnnouncementMenuSection.schoolPortal] ?? true,
        college: sectionExpansion[AnnouncementMenuSection.college] ?? false,
        researchInstitute:
            sectionExpansion[AnnouncementMenuSection.researchInstitute] ??
                false,
        schoolDepartment:
            sectionExpansion[AnnouncementMenuSection.schoolDepartment] ?? true,
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

class _DeferredPageAnnouncementRepository extends _FakeAnnouncementRepository {
  _DeferredPageAnnouncementRepository({super.previewFutures})
      : super(
          items: const [_listItem],
          details: {
            _listTitle: AnnouncementDetail(
              title: _listTitle,
              url: _listItem.url,
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
  testWidgets('retry settings persist and obsolete search controls are absent',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['shu'],
      'announcements.search.fast': true,
      'announcements.search.strength': 5,
    });
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementSearchPage(repository: _repositoryWith(), isDemo: true),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索强度'), findsNothing);
    expect(find.textContaining('Fast模式'), findsNothing);
    expect(find.byTooltip('取消搜索'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('搜索范围'), findsOneWidget);
    expect(find.text('搜索强度'), findsNothing);
    await tester.tap(find.text('失败重试'));
    await tester.pumpAndSettle();
    final retry = find.widgetWithText(SwitchListTile, '失败重试');
    expect(tester.widget<SwitchListTile>(retry).value, isTrue);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('announcements.search.retryFailures'), isFalse);
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
    expect(find.text('没有找到公告'), findsOneWidget);
    expect(find.text('继续失败项'), findsNothing);
    expect(requests, 1);
  });

  testWidgets('API snippets display without another article preview request',
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
          _searchRecord(title: '普通公告', summary: '<em>目标</em>内容'),
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
    await _startAnnouncementSearch(tester, query: '目标');
    expect(find.text('普通公告'), findsOneWidget);
    expect(find.text('目标内容'), findsOneWidget);
    expect(repository.previewRequests, isEmpty);
    expect(requests, hasLength(1));
    final requestBody =
        jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(requestBody['owner'], AnnouncementSource.official.searchOwner);
    expect(requestBody['searchScope'], 3);
  });

  testWidgets('title result stays visible while a missing preview loads',
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
    expect(find.text(title), findsOneWidget);
    expect(find.text('正文概览一段'), findsNothing);
    pendingPreview.complete('正文概览一段');
    await tester.pumpAndSettle();
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

  testWidgets('API pages append seamlessly and input unlocks when complete',
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
    await _startAnnouncementSearch(tester);
    expect(find.text('目标词 公告 0'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
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
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
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
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
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

  testWidgets('settings changed during a search apply to the next request',
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
    await tester.tap(find.text('本科生院'));
    await pumpOverlay();
    await tester.tapAt(const Offset(8, 8));
    await pumpOverlay();
    await tester.tap(find.byTooltip('更多'));
    await pumpOverlay();
    await tester.tap(find.text('搜索范围'));
    await pumpOverlay();
    await tester.tap(find.widgetWithText(OutlinedButton, '内容'));
    await tester.tapAt(const Offset(8, 8));
    await pumpOverlay();
    expect(find.text('搜索范围：标题'), findsOneWidget);
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
    expect(find.text('搜索范围：标题+正文'), findsOneWidget);
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
      await tester.tap(find.byWidgetPredicate((widget) =>
          widget is CheckedPopupMenuItem &&
          widget.child is Text &&
          (widget.child! as Text).data == label));
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
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem &&
        widget.child is Text &&
        (widget.child! as Text).data == '自定义日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final year = DateTime.now().year - 1;
    final dateFields = find.descendant(
      of: find.byType(DateRangePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dateFields.at(0), '1/2/$year');
    await tester.enterText(dateFields.at(1), '1/5/$year');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing);
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
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
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
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
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
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
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
    expect(number('announcement-search-total-count').style!.fontSize, 26);
    expect(number('announcement-search-found-count').style!.fontSize, 26);
    expect(find.text('公告数'), findsOneWidget);
    expect(
        tester.widget<Text>(find.text('/')).style!.color, colors.textPrimary);
    expect(find.text('搜索范围：标题'), findsOneWidget);
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
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
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
    expect(tester.getTopLeft(find.text('公告甲旧')).dy,
        lessThan(tester.getTopLeft(find.text('公告乙')).dy));
    await tester.drag(
        find.byType(CustomScrollView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('外国语学院'), findsOneWidget);
    expect(find.text('公告丙'), findsOneWidget);
  });

  testWidgets('home month header stays pinned and switches at next month',
      (tester) async {
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
      home: AnnouncementsPage(
        repository:
            _FakeAnnouncementRepository(items: items, details: const {}),
      ),
    ));
    await tester.pumpAndSettle();
    final scrollView = find.byType(CustomScrollView).first;
    await tester.drag(scrollView, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('announcement-sticky-home-2026年10月')))
            .dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)),
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('announcement-sticky-home-2026年9月')))
            .dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
  });

  testWidgets('search department and month pin independently', (tester) async {
    SharedPreferences.setMockInitialValues({
      'announcements.search.selectedSources': ['bksy', 'xgb']
    });
    final items = [
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '十月公告 $index',
          url: 'https://example.org/bksy/oct/$index',
          sourceId: 'bksy',
          publishedAt: DateTime(2026, 10, 20 - index),
          summary: '公告概览',
        ),
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '九月公告 $index',
          url: 'https://example.org/bksy/sep/$index',
          sourceId: 'bksy',
          publishedAt: DateTime(2026, 9, 20 - index),
          summary: '公告概览',
        ),
      for (var index = 0; index < 12; index++)
        AnnouncementListItem(
          title: '八月公告 $index',
          url: 'https://example.org/xgb/aug/$index',
          sourceId: 'xgb',
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
      const ValueKey('announcement-sticky-department-本科生院'),
    );
    final octoberMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生院-2026年10月'),
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
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final septemberDepartment = find.byKey(
      const ValueKey('announcement-sticky-department-本科生院'),
    );
    final septemberMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生院-2026年9月'),
    );
    expect(tester.getTopLeft(septemberDepartment).dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
    expect(tester.getTopLeft(septemberMonth).dy,
        closeTo(tester.getBottomLeft(septemberDepartment).dy, 1));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final augustDepartment = find.byKey(
      const ValueKey('announcement-sticky-department-本科生工作处'),
    );
    final augustMonth = find.byKey(
      const ValueKey('announcement-sticky-month-本科生工作处-2026年8月'),
    );
    expect(tester.getTopLeft(augustDepartment).dy,
        closeTo(tester.getTopLeft(scrollView).dy, 1));
    expect(tester.getTopLeft(augustMonth).dy,
        closeTo(tester.getBottomLeft(augustDepartment).dy, 1));
    expect(find.text('2026年8月'), findsOneWidget);
  });

  testWidgets('search scope settings preserve body matching and typography',
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
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索范围'));
    await tester.pumpAndSettle();
    final scopeHeading = tester.widget<Text>(find.text('搜索范围'));
    expect(scopeHeading.style?.fontSize, 16.5);
    expect(scopeHeading.style?.fontWeight, FontWeight.w600);
    await tester.tap(find.widgetWithText(OutlinedButton, '内容'));
    await tester.tapAt(const Offset(8, 8));
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
    expect(find.text('搜索范围：标题+正文'), findsOneWidget);
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
    expect(find.text('搜索范围：正文'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '实验室');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text(_listTitle), findsNothing);

    await tester.enterText(find.byType(TextField), _detailBody);
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    expect(find.text(_listTitle), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索范围'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '内容'));
    await tester.tapAt(const Offset(8, 8));
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
    expect(find.text('本科生院'), findsOneWidget);
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
                'announcement-search-group-schoolDepartment')))
            .value,
        isFalse);
    await tester.tap(portalCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校门户'));
    await tester.pumpAndSettle();

    final schoolCheckbox = find.byKey(
        const ValueKey<String>('announcement-search-group-schoolDepartment'));
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isFalse);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isTrue);
    expect(
        find.text(
            '${AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolDepartment).length}'),
        findsOneWidget);
    await tester.tap(find.text('本科生院'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isNull);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isTrue);
    await tester.tap(schoolCheckbox);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(schoolCheckbox).value, isFalse);

    await tester.tap(find.text('学校下属部门'));
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
    repository.sectionExpansion[AnnouncementMenuSection.schoolDepartment] =
        false;
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

  testWidgets('unsupported search source remains selectable in normal browsing',
      (tester) async {
    final repository = _repositoryWith();
    repository.sectionExpansion[AnnouncementMenuSection.schoolPortal] = false;
    repository.sectionExpansion[AnnouncementMenuSection.schoolDepartment] =
        false;
    repository.sectionExpansion[AnnouncementMenuSection.college] = true;
    await tester.pumpWidget(MaterialApp(
      home: AnnouncementsPage(repository: repository),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择公告来源'));
    await tester.pumpAndSettle();
    final source = AnnouncementSource.byId('shvfs');
    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text(source.name), 300,
        scrollable: menuScrollable);
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text(source.name),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(row).enabled, isTrue);
    await tester.tap(find.text(source.name));
    await tester.pumpAndSettle();
    expect(repository.requestedSources.last, source.id);
  });

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

    final menuScrollable = find.descendant(
      of: find.byKey(announcementSourceMenuKey),
      matching: find.byType(Scrollable),
    );
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
    await tester.tap(find.text('学校下属部门'));
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
      AnnouncementMenuSection.schoolDepartment: false,
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

  testWidgets('Film Academy dates appear before article previews finish',
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
    expect(find.text('电影学院通知'), findsOneWidget);
    expect(find.text('2026-10-20'), findsOneWidget);

    preview.complete('通知概览');
    await tester.pumpAndSettle();
    expect(find.text('通知概览'), findsOneWidget);
    expect(find.text('2026-10-20'), findsOneWidget);
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

  testWidgets('title and date stay usable while the first preview is loading',
      (tester) async {
    final pending = Completer<String?>();
    const item = AnnouncementListItem(
      title: '等待正文的公告',
      url: 'https://bksy.shu.edu.cn/info/1000/wait.htm',
      sourceId: 'bksy',
      dateText: '2026-10-25',
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
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(find.text(item.title), findsOneWidget);
    expect(find.text(item.dateText), findsOneWidget);
    expect(repository.previewRequests, [item.url]);
    await tester.pumpAndSettle();
    await tester.tap(find.text(item.title));
    await tester.pumpAndSettle();
    expect(find.text('已打开通知正文'), findsOneWidget);

    pending.complete('完整正文摘要');
    await tester.pump();
    expect(find.text('完整正文摘要', skipOffstage: false), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(item.title), findsOneWidget);
    expect(find.text('完整正文摘要'), findsOneWidget);
    expect(find.byType(SlideTransition), findsWidgets);
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
    expect(find.text('旧通知'), findsOneWidget);
    expect(find.text('新通知'), findsOneWidget);
    expect(tester.getTopLeft(find.text('新通知')).dy,
        lessThan(tester.getTopLeft(find.text('旧通知')).dy));
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

  testWidgets('scrolled-to titles appear before their previews finish',
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
    expect(find.text(items[10].title), findsOneWidget);

    pending.complete('滚动后才加载的摘要');
    await tester.pumpAndSettle();
    expect(find.text(items[10].title), findsOneWidget);
    expect(find.text('滚动后才加载的摘要'), findsOneWidget);
  });

  testWidgets('a preview updates only its card without rebuilding the list',
      (tester) async {
    final pending = Completer<String?>();
    const first = AnnouncementListItem(
      title: '异步概览通知',
      url: 'https://bksy.shu.edu.cn/info/1000/async.htm',
      sourceId: 'bksy',
    );
    const second = AnnouncementListItem(
      title: '保持不变的通知',
      url: 'https://bksy.shu.edu.cn/info/1000/stable.htm',
      sourceId: 'bksy',
      summary: '已有概览',
    );
    final repository = _FakeAnnouncementRepository(
      items: const [first, second],
      details: const {},
      previewFutures: {first.url: pending.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<CustomScrollView>(find.byType(CustomScrollView));
    final unchangedTitle = tester.widget<Text>(find.text(second.title));
    final firstTile = find.byKey(ValueKey(first.url));
    final titleHeight = tester.getSize(firstTile).height;
    pending.complete('稍后补齐的短概览');
    await tester.pumpAndSettle();
    expect(find.text('稍后补齐的短概览'), findsOneWidget);
    expect(tester.widget<CustomScrollView>(find.byType(CustomScrollView)),
        same(list));
    expect(tester.widget<Text>(find.text(second.title)), same(unchangedTitle));
    expect(tester.getSize(firstTile).height, greaterThan(titleHeight));
    expect(tester.getSize(firstTile).height, lessThan(104));
    expect(repository.previewRequests, [first.url]);
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
    await tester.pumpAndSettle();
    await refresh;
    expect(find.text(item.title), findsOneWidget);
    expect(repository.previewRequests, [item.url, item.url]);
    updatedPreview.complete('刷新后的新概览');
    await tester.pumpAndSettle();
    expect(find.text('刷新后的新概览'), findsOneWidget);
    expect(find.text('刷新前的概览'), findsNothing);
    expect(repository.previewRequests, [item.url, item.url]);
  });

  testWidgets(
      'covered previews and pages wait until the reverse transition ends',
      (tester) async {
    final preview = Completer<String?>();
    final repository = _DeferredPageAnnouncementRepository(
      previewFutures: {_listItem.url: preview.future},
    );
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.pagesRequested, 1);
    await tester.tap(find.text(_listTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final homeList = find.byType(CustomScrollView, skipOffstage: false);
    final coveredList = tester.widget<CustomScrollView>(homeList);
    preview.complete('返回列表后显示的概览');
    repository.nextPage.complete(const [
      _listItem,
      AnnouncementListItem(
        title: '详情期间完成的下一页',
        url: 'https://www.shu.edu.cn/info/1051/2.htm',
        summary: '下一页的概览',
      ),
    ]);
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
    expect(repository.previewRequests, [_listItem.url]);
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
    await tester.pumpAndSettle();
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
