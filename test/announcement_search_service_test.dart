import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_search_service.dart';

const _first = AnnouncementSource(
  id: 'first',
  name: '第一部门',
  listUrl: 'https://first.shu.edu.cn/notices.htm',
  searchOwner: '10001',
  searchColumnIds: ['1015'],
  adapter:
      AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList),
);
const _second = AnnouncementSource(
  id: 'second',
  name: '第二部门',
  listUrl: 'https://second.shu.edu.cn/notices.htm',
  searchOwner: '10002',
  searchColumnIds: ['1029'],
  adapter: AnnouncementSourceAdapter(
    listFormat: AnnouncementListFormat.onlyList,
    hideListColumn: true,
  ),
);

Map<String, Object?> _record(
  int id, {
  String owner = '10001',
  int column = 1015,
  String? title,
  String? url,
}) =>
    {
      'index': 'article_data',
      'owner': int.parse(owner),
      'column': column,
      'columnName': '通知公告',
      'id': id,
      'title': title ?? '目标公告 $id',
      'url': url ?? '//first.shu.edu.cn/info/$column/$id.htm',
      'createDate': '2026-10-25 15:00:00',
      'intro': '正文含有<span style="color:red">目标</span> &amp; 概览',
    };

http.Response _page(
  List<Map<String, Object?>>? records, {
  int current = 0,
  int size = 50,
  int? total,
}) =>
    http.Response.bytes(
        utf8.encode(jsonEncode({
          'code': '0000',
          'data': {
            'page': {
              'current': current,
              'size': size,
              'total': total ?? records?.length ?? 0,
              'records': records,
            },
          },
        })),
        200,
        headers: {'content-type': 'application/json;charset=UTF-8'});

void main() {
  test('calendar date range includes the complete last day in API requests',
      () async {
    Map? sent;
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((request) async {
        sent = jsonDecode(request.body) as Map;
        return _page([_record(1)]);
      }),
    );
    addTearDown(service.dispose);
    final result = await service
        .startSearch(
          query: '目标',
          dateRange: AnnouncementSearchDateRange(
            begin: DateTime(2026, 10, 23, 16),
            end: DateTime(2026, 10, 23),
          ),
        )
        .finished;
    expect(result.isComplete, isTrue);
    expect(sent!['searchDateType'], 'custom');
    expect(sent!['beginDate'], '2026-10-23 00:00:00');
    expect(sent!['endDate'], '2026-10-23 23:59:59');
  });

  test('unrestricted search freezes campus time across all API pages',
      () async {
    var clock = DateTime.utc(2026, 10, 25, 16, 30, 6);
    final bodies = <Map>[];
    final service = AnnouncementSearchService(
      sources: const [_first],
      now: () => clock,
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        bodies.add(body);
        final current = body['page']['current'] as int;
        clock = DateTime.utc(2026, 10, 27);
        return _page([_record(current + 1)],
            current: current, size: 1, total: 2);
      }),
    );
    addTearDown(service.dispose);
    final result = await service.startSearch(query: '目标').finished;
    expect(result.isComplete, isTrue);
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(body['searchDateType'], 'custom');
      expect(body.containsKey('beginDate'), isFalse);
      expect(body['endDate'], '2026-10-26 00:30:06');
    }
  });

  test('date range may have only an upper or lower bound', () async {
    final bodies = <Map>[];
    final service = AnnouncementSearchService(
      sources: const [_first],
      now: () => DateTime.utc(2026, 10, 25, 16, 30, 6),
      clientFactory: () => MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map);
        return _page([]);
      }),
    );
    addTearDown(service.dispose);
    await service
        .startSearch(
          query: '目标',
          dateRange: AnnouncementSearchDateRange(end: DateTime(2026, 10, 23)),
        )
        .finished;
    await service
        .startSearch(
          query: '目标',
          dateRange: AnnouncementSearchDateRange(begin: DateTime(2026, 10, 23)),
        )
        .finished;
    expect(bodies[0].containsKey('beginDate'), isFalse);
    expect(bodies[0]['endDate'], '2026-10-23 23:59:59');
    expect(bodies[1]['beginDate'], '2026-10-23 00:00:00');
    expect(bodies[1]['endDate'], '2026-10-26 00:30:06');
  });

  test('reversed date range is rejected before creating a request', () {
    var created = 0;
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () {
        created++;
        return MockClient((_) async => _page([]));
      },
    );
    addTearDown(service.dispose);
    expect(
      () => service.startSearch(
        query: '目标',
        dateRange: AnnouncementSearchDateRange(
          begin: DateTime(2026, 10, 24),
          end: DateTime(2026, 10, 23),
        ),
      ),
      throwsArgumentError,
    );
    expect(created, 0);
  });

  test('lifecycle cancellation aborts the transport and closes its client',
      () async {
    final client = _TrackingClient();
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => client,
    );
    addTearDown(service.dispose);
    final run = service.startSearch(query: '目标');
    final request = await client.started.future;
    service.dispose();
    await request.abortTrigger;
    expect(client.closed, isTrue);
    expect((await run.finished).isComplete, isFalse);
    client.response.complete(http.StreamedResponse(const Stream.empty(), 200));
    await Future<void>.delayed(Duration.zero);
  });

  test('every request explicitly scopes owners, columns and article index',
      () async {
    final requests = <http.Request>[];
    final service = AnnouncementSearchService(
      sources: const [_first, _second],
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        return _page([_record(1)]);
      }),
    );
    addTearDown(service.dispose);
    final result = await service.startSearch(query: ' 目标 ').finished;
    expect(result.isComplete, isTrue);
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(),
        'https://www.shu.edu.cn/aop_component/webber/search/search/search/queryPage');
    expect(request.headers['owner'], '1864855249');
    expect(request.headers['Authorization'], 'preview');
    expect(request.headers['allsite'], '1');
    final body = jsonDecode(request.body) as Map;
    expect(body['owner'], '10001,10002');
    expect(body['columnId'], '1015,1029');
    expect(body['aliasName'], 'article_data');
    expect(body['keyWord'], '目标');
    expect(body['searchOperator'], 1);
    expect(body['searchKeyWord'], isTrue);
    expect(body['orderType'], 'date');
    expect(body['page'], {'current': 0, 'size': 50});
  });

  test('title, body and combined scopes map to the API without article GETs',
      () async {
    final scopes = <int>[];
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((request) async {
        expect(request.method, 'POST');
        scopes.add((jsonDecode(request.body) as Map)['searchScope'] as int);
        return _page([_record(1)]);
      }),
    );
    addTearDown(service.dispose);
    for (final scope in [(true, false), (false, true), (true, true)]) {
      expect(
          (await service
                  .startSearch(
                    query: '目标',
                    includeTitle: scope.$1,
                    includeBody: scope.$2,
                  )
                  .finished)
              .matchedArticles,
          1);
    }
    expect(scopes, [1, 2, 3]);
  });

  test('streams a page before the next page completes and honors server size',
      () async {
    final next = Completer<http.Response>();
    final firstUpdate = Completer<AnnouncementSearchProgress>();
    final nextStarted = Completer<void>();
    final requested = <int>[];
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((request) async {
        final current =
            (jsonDecode(request.body) as Map)['page']['current'] as int;
        requested.add(current);
        if (current == 0) {
          return _page([_record(1), _record(2)], size: 2, total: 3);
        }
        nextStarted.complete();
        return next.future;
      }),
    );
    addTearDown(service.dispose);
    final run = service.startSearch(query: '目标');
    final updates = <AnnouncementSearchProgress>[];
    run.updates.listen((progress) {
      updates.add(progress);
      if (!firstUpdate.isCompleted) firstUpdate.complete(progress);
    });
    final initial = await firstUpdate.future;
    await nextStarted.future;
    expect(initial.newMatches, hasLength(2));
    expect(initial.isFinished, isFalse);
    expect(initial.discoveredArticles, 3);
    expect(initial.totalPages, 2);
    next.complete(_page([_record(3)], current: 1, size: 2, total: 3));
    final result = await run.finished;
    await Future<void>.delayed(Duration.zero);
    expect(result.isComplete, isTrue);
    expect(result.matchedArticles, 3);
    expect(requested, [0, 1]);
    expect(updates.map((p) => p.newMatches.length), [2, 1]);
  });

  test('filters owner/column cross-products, other indexes and duplicate URLs',
      () async {
    final service = AnnouncementSearchService(
      sources: const [_first, _second],
      clientFactory: () => MockClient((_) async => _page([
            _record(1),
            _record(1, url: '//first.shu.edu.cn/info/1015/1.htm#section'),
            _record(2, owner: '10001', column: 1029),
            _record(3, owner: '10002', column: 1015),
            _record(4, owner: '99999'),
            {..._record(5), 'index': 'article_file'},
            _record(6, owner: '10002', column: 1029, url: '/info/1029/6.htm'),
          ])),
    );
    addTearDown(service.dispose);
    final run = service.startSearch(query: '目标');
    final items = <String>[];
    run.updates.listen((p) => items.addAll(p.newMatches.map((a) => a.url)));
    final result = await run.finished;
    await Future<void>.delayed(Duration.zero);
    expect(result.matchedArticles, 2);
    expect(items, [
      'https://first.shu.edu.cn/info/1015/1.htm',
      'https://second.shu.edu.cn/info/1029/6.htm',
    ]);
  });

  test(
      'normalizes highlights, entities, summaries, dates and merged column display',
      () async {
    final service = AnnouncementSearchService(
      sources: const [_second],
      clientFactory: () => MockClient((_) async => _page([
            _record(1,
                owner: '10002',
                column: 1029,
                title: '关于<span style="color:red">目标</span> &amp; 通知',
                url: '/info/1029/1.htm'),
          ])),
    );
    addTearDown(service.dispose);
    final run = service.startSearch(query: '目标');
    final update = run.updates.first;
    await run.finished;
    final item = (await update).newMatches.single;
    expect(item.title, '关于目标 & 通知');
    expect(item.summary, '正文含有目标 & 概览');
    expect(item.dateText, '2026-10-25');
    expect(item.publishedAt, DateTime(2026, 10, 25, 15));
    expect(item.sourceId, 'second');
    expect(item.column, isEmpty);
  });

  test(
      'empty, unsupported or unconfigured source selections never reach network',
      () {
    var created = 0;
    final service = AnnouncementSearchService(clientFactory: () {
      created++;
      return MockClient((_) async => _page([]));
    });
    addTearDown(service.dispose);
    for (final sources in <List<AnnouncementSource>>[
      [],
      [AnnouncementSource.byId('shvfs')],
      [
        const AnnouncementSource(
            id: 'no-column',
            name: '',
            listUrl: '',
            searchOwner: '1',
            adapter: AnnouncementSourceAdapter(
                listFormat: AnnouncementListFormat.onlyList))
      ],
    ]) {
      expect(() => service.startSearch(query: '目标', sources: sources),
          throwsArgumentError);
    }
    expect(() => service.startSearch(query: ' ', sources: [_first]),
        throwsArgumentError);
    expect(
        () => service.startSearch(
            query: '目标',
            sources: [_first],
            includeTitle: false,
            includeBody: false),
        throwsArgumentError);
    expect(created, 0);
  });

  test('an empty successful result can contain null records', () async {
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((_) async => _page(null)),
    );
    addTearDown(service.dispose);
    final result = await service.startSearch(query: '目标').finished;
    expect(result.isComplete, isTrue);
    expect(result.matchedArticles, 0);
    expect(result.discoveredArticles, 0);
  });

  test('transient failure retries only the failed API page', () async {
    var attempts = 0;
    final service = AnnouncementSearchService(
      sources: const [_first],
      retryBaseDelay: Duration.zero,
      clientFactory: () => MockClient((_) async =>
          ++attempts < 3 ? http.Response('busy', 503) : _page([_record(1)])),
    );
    addTearDown(service.dispose);
    final result = await service.startSearch(query: '目标').finished;
    expect(result.isComplete, isTrue);
    expect(result.requestCount, 3);
    expect(result.retryCount, 2);
  });

  test('later page failure keeps earlier streamed results and ends incomplete',
      () async {
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((request) async =>
          (jsonDecode(request.body) as Map)['page']['current'] == 0
              ? _page([_record(1)], size: 1, total: 2)
              : http.Response('unavailable', 503)),
    );
    addTearDown(service.dispose);
    final run = service.startSearch(query: '目标', retryFailures: false);
    final results = <String>[];
    run.updates.listen((p) => results.addAll(p.newMatches.map((r) => r.title)));
    final result = await run.finished;
    expect(result.isFinished, isTrue);
    expect(result.isComplete, isFalse);
    expect(result.matchedArticles, 1);
    expect(result.failedPages, 1);
    expect(result.requestCount, 2);
    expect(results, ['目标公告 1']);
  });

  for (final invalid in [
    '<html>login</html>',
    '{"code":"9999","data":null}',
    '{"code":"0000","data":{}}',
    '{"code":"0000","data":{"page":{"current":0,"size":50,"total":9,"records":[]}}}',
  ]) {
    test('HTTP 200 invalid envelope is terminal: $invalid', () async {
      var attempts = 0;
      final service = AnnouncementSearchService(
        sources: const [_first],
        retryBaseDelay: Duration.zero,
        clientFactory: () => MockClient((_) async {
          attempts++;
          return http.Response(invalid, 200);
        }),
      );
      addTearDown(service.dispose);
      final result = await service.startSearch(query: '目标').finished;
      expect(result.isComplete, isFalse);
      expect(result.isFinished, isTrue);
      expect(result.failedPages, 1);
      expect(attempts, 1);
    });
  }

  test('request timeout is bounded and classified separately', () async {
    final response = Completer<http.Response>();
    final service = AnnouncementSearchService(
      sources: const [_first],
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: () => MockClient((_) => response.future),
    );
    addTearDown(service.dispose);
    final result =
        await service.startSearch(query: '目标', retryFailures: false).finished;
    expect(result.isComplete, isFalse);
    expect(result.timeoutFailureCount, 1);
    response.complete(_page([_record(1)]));
  });

  test('replacing a query cancels the old run and ignores its delayed response',
      () async {
    final delayed = Completer<http.Response>();
    final entered = Completer<void>();
    var clients = 0;
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => ++clients == 1
          ? MockClient((_) {
              entered.complete();
              return delayed.future;
            })
          : MockClient((_) async => _page([_record(2)])),
    );
    addTearDown(service.dispose);
    final old = service.startSearch(query: '旧词');
    final oldTitles = <String>[];
    old.updates
        .listen((p) => oldTitles.addAll(p.newMatches.map((a) => a.title)));
    await entered.future;
    final latest = service.startSearch(query: '新词');
    expect((await old.finished).isComplete, isFalse);
    expect((await latest.finished).matchedArticles, 1);
    delayed.complete(_page([_record(1)]));
    await Future<void>.delayed(Duration.zero);
    expect(oldTitles, isEmpty);
  });

  test('disposal ends an in-flight request and prevents later searches',
      () async {
    final delayed = Completer<http.Response>();
    final entered = Completer<void>();
    final service = AnnouncementSearchService(
      sources: const [_first],
      clientFactory: () => MockClient((_) {
        entered.complete();
        return delayed.future;
      }),
    );
    final run = service.startSearch(query: '目标');
    await entered.future;
    service.dispose();
    expect((await run.finished).isFinished, isTrue);
    expect(() => service.startSearch(query: '下一次'), throwsStateError);
    delayed.complete(_page([_record(1)]));
    await Future<void>.delayed(Duration.zero);
  });
}

class _TrackingClient extends http.BaseClient {
  final started = Completer<http.AbortableRequest>();
  final response = Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    started.complete(request as http.AbortableRequest);
    return response.future;
  }

  @override
  void close() => closed = true;
}
