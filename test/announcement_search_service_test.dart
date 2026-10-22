import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';
import 'package:shuyo/data/services/announcement_search_service.dart';

class _ScriptedClient extends AnnouncementApiClient {
  _ScriptedClient({
    required this.id,
    required this.request,
    required this.page,
    this.body,
    this.onClose,
  });

  final int id;
  final Future<http.Response> Function(int id, String url) request;
  final AnnouncementSearchColumnPage Function(String url) page;
  final Future<String> Function(String url)? body;
  final void Function()? onClose;

  @override
  Future<http.Response> fetchSearchResponse(String url) => request(id, url);

  @override
  Future<AnnouncementSearchColumnPage> parseSearchColumnResponse({
    required http.Response response,
    required AnnouncementSource source,
    required String url,
    required String column,
  }) async =>
      page(url);

  @override
  Future<String> parseSearchDetailText({
    required http.Response response,
    required AnnouncementListItem item,
  }) async =>
      await body?.call(item.url) ?? response.body;

  @override
  Future<DateTime?> parseFilmSearchDate(http.Response response) async =>
      DateTime.tryParse(response.body);

  @override
  void close() {
    onClose?.call();
    super.close();
  }
}

class _SearchClient extends AnnouncementApiClient {
  _SearchClient(this.onClose,
      {this.onFetch, this.reverseOrder = false, this.bodyGate});

  final void Function() onClose;
  final Future<void> Function(String url)? onFetch;
  final bool reverseOrder;
  final Completer<void>? bodyGate;
  final requests = <String>[];

  @override
  Future<http.Response> fetchSearchResponse(String url) async {
    requests.add(url);
    await onFetch?.call(url);
    return http.Response('<html></html>', 200);
  }

  @override
  Future<AnnouncementSearchColumnPage> parseSearchColumnResponse({
    required http.Response response,
    required AnnouncementSource source,
    required String url,
    required String column,
  }) async {
    if (bodyGate != null) {
      return const AnnouncementSearchColumnPage([
        AnnouncementListItem(title: '文章一', url: 'https://example.org/1'),
        AnnouncementListItem(title: '文章二', url: 'https://example.org/2'),
      ], null);
    }
    if (reverseOrder) {
      return AnnouncementSearchColumnPage([
        AnnouncementListItem(
          title: '关键旧文',
          url: 'https://example.org/old',
          publishedAt: DateTime(2025, 1, 1),
        ),
        AnnouncementListItem(
          title: '关键新文',
          url: 'https://example.org/new',
          publishedAt: DateTime(2026, 1, 1),
        ),
      ], null);
    }
    final secondPage = url.endsWith('/2');
    return AnnouncementSearchColumnPage(
      [
        AnnouncementListItem(
          title:
              '关键 ${column.isEmpty ? 'a' : column} ${secondPage ? '2' : '1'}',
          url: '$url/article',
          sourceId: source.id,
        ),
      ],
      secondPage ? null : '$url/2',
    );
  }

  @override
  Future<String> parseSearchDetailText({
    required http.Response response,
    required AnnouncementListItem item,
  }) async {
    await bodyGate?.future;
    return '';
  }

  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  test('Modart searches all three columns and follows each page cursor',
      () async {
    final source = AnnouncementSource.byId('modart');
    expect(source.group, AnnouncementSourceGroup.college);
    expect(source.columnNames, ['通知公告', '学院新闻', '时尚资讯']);
    expect(source.listUrls, [
      'https://modart.shu.edu.cn/tzgg.htm',
      'https://modart.shu.edu.cn/xyzx/xyxw.htm',
      'https://modart.shu.edu.cn/xyzx/sszx1.htm',
    ]);

    final newsNext = 'https://modart.shu.edu.cn/xyzx/xyxw/10.htm';
    final fashionNext = 'https://modart.shu.edu.cn/xyzx/sszx1/32.htm';
    final pages = <String, (String, String?)>{
      source.listUrls[0]: ('目标公告', null),
      source.listUrls[1]: ('目标新闻', 'xyxw/10.htm'),
      source.listUrls[2]: ('目标时尚资讯', 'sszx1/32.htm'),
      newsNext: ('目标历史新闻', null),
      fashionNext: ('目标历史资讯', null),
    };
    final requested = <String>[];
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => AnnouncementApiClient(
        httpClient: http_testing.MockClient((request) async {
          final url = request.url.toString();
          requested.add(url);
          final page = pages[url];
          if (page == null) return http.Response('missing', 404);
          final next =
              page.$2 == null ? '' : '<a class="Next" href="${page.$2}">下页</a>';
          return http.Response(
            '<ul class="rightList"><li id="line_u6_0">'
            '<a href="/info/1087/${requested.length}.htm">${page.$1}</a>'
            '<span>2026年10月20日</span></li></ul>$next',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      ),
    );

    final result = await service
        .startSearch(query: '目标', strength: 5, batchPause: Duration.zero)
        .finished;
    expect(result.isComplete, isTrue);
    expect(result.completedPages, 5,
        reason: 'requested: $requested; failed: ${result.failedPages}; '
            'last error: ${result.lastError}');
    expect(result.discoveredArticles, 5);
    expect(result.matchedArticles, 5);
    expect(requested, unorderedEquals(pages.keys));
    service.dispose();
  });

  test('strength profiles have the planned fixed pool and host limits', () {
    expect(
      AnnouncementSearchProfile.profiles
          .map((profile) => [
                profile.clientCount,
                profile.pagePause.inMilliseconds,
                profile.hostLimit,
                profile.networkLimit,
                profile.firstPageLimit,
              ])
          .toList(),
      [
        [24, 25000, 2, 4, 2],
        [40, 16000, 2, 6, 3],
        [64, 11000, 2, 8, 4],
        [96, 7000, 2, 12, 5],
        [144, 4000, 3, 16, 6],
        [200, 0, 3, 24, 6],
      ],
    );
    expect(
      AnnouncementSearchProfile.profiles
          .map((profile) =>
              [profile.desiredBodyParses, profile.desiredTotalParses])
          .toList(),
      [
        [1, 3],
        [2, 4],
        [3, 5],
        [4, 6],
        [5, 8],
        [6, 10],
      ],
    );
  });

  test('each strength protects first pages then reaches its full budget',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 60; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.test/list',
          adapter: adapter,
        ),
    ];
    for (var strength = 0;
        strength < AnnouncementSearchProfile.profiles.length;
        strength++) {
      final profile = AnnouncementSearchProfile.forStrength(strength);
      final firstGate = Completer<void>();
      final bodyGate = Completer<void>();
      final firstPhaseFull = Completer<void>();
      final fullBudget = Completer<void>();
      var activeLists = 0;
      var activeBodies = 0;
      var parsedLists = 0;
      var firstPhaseBodyPeak = 0;
      final service = AnnouncementSearchService(
        sources: sources,
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, url) async {
            if (url.endsWith('/list')) {
              final index = int.parse(Uri.parse(url)
                  .host
                  .replaceFirst('host', '')
                  .replaceFirst('.test', ''));
              if (index < 2) return http.Response('ok', 200);
              activeLists++;
              if (activeLists == profile.firstPageLimit &&
                  !firstPhaseFull.isCompleted) {
                firstPhaseFull.complete();
              }
              await firstGate.future;
              activeLists--;
            } else {
              activeBodies++;
              if (parsedLists < sources.length - sources.length ~/ 10 &&
                  activeBodies > firstPhaseBodyPeak) {
                firstPhaseBodyPeak = activeBodies;
              }
              if (activeBodies == profile.networkLimit &&
                  !fullBudget.isCompleted) {
                fullBudget.complete();
              }
              await bodyGate.future;
              activeBodies--;
            }
            return http.Response('ok', 200);
          },
          page: (url) {
            parsedLists++;
            return AnnouncementSearchColumnPage([
              AnnouncementListItem(title: 'plain', url: '$url/article'),
            ], null);
          },
          body: (_) async => '',
        ),
      );
      final run = service.startSearch(
          query: 'target', includeBody: true, strength: strength);
      try {
        await firstPhaseFull.future.timeout(const Duration(seconds: 3));
        expect(activeLists, profile.firstPageLimit);
        expect(run.networkLimit, profile.networkLimit);
        firstGate.complete();
        await fullBudget.future.timeout(const Duration(seconds: 3));
        expect(parsedLists, sources.length);
        expect(firstPhaseBodyPeak,
            lessThanOrEqualTo(max(1, profile.firstPageLimit ~/ 4)));
        expect(activeBodies, profile.networkLimit);
      } finally {
        if (!firstGate.isCompleted) firstGate.complete();
        bodyGate.complete();
        expect((await run.finished).isComplete, isTrue);
        service.dispose();
      }
    }
  });

  test('90 percent coverage releases body budget but reserves first-page slots',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 30; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.test/list',
          adapter: adapter,
        ),
    ];
    final failFirstAttempt = Completer<void>();
    final retryGate = Completer<void>();
    final slowFirstPages = Completer<void>();
    final bodyGate = Completer<void>();
    final bodiesAtLimit = Completer<void>();
    final retryStarted = Completer<void>();
    var failingAttempts = 0;
    var activeBodies = 0;
    var peakBodies = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/list')) {
            final index = int.parse(Uri.parse(url)
                .host
                .replaceFirst('host', '')
                .replaceFirst('.test', ''));
            if (index == 27) {
              failingAttempts++;
              if (failingAttempts == 1) {
                await failFirstAttempt.future;
                throw const SocketException('connection reset by peer');
              }
              if (!retryStarted.isCompleted) retryStarted.complete();
              await retryGate.future;
            } else if (index >= 28) {
              await slowFirstPages.future;
            }
          } else {
            activeBodies++;
            if (activeBodies > peakBodies) peakBodies = activeBodies;
            if (activeBodies == 18 && !bodiesAtLimit.isCompleted) {
              bodiesAtLimit.complete();
            }
            await bodyGate.future;
            activeBodies--;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: 'plain', url: '$url/article'),
        ], null),
        body: (_) async => '',
      ),
    );
    final run = service.startSearch(
      query: 'target',
      includeBody: true,
      strength: 5,
    );
    try {
      await bodiesAtLimit.future.timeout(const Duration(seconds: 3));
      expect(activeBodies, 18);
      expect(peakBodies, 18);
      failFirstAttempt.complete();
      await retryStarted.future.timeout(const Duration(seconds: 2));
      expect(activeBodies, 18);
      expect(failingAttempts, 2);
    } finally {
      if (!failFirstAttempt.isCompleted) failFirstAttempt.complete();
      retryGate.complete();
      slowFirstPages.complete();
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('cold startup admits two hosts before any response', () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 20; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.test/list',
          adapter: adapter,
        ),
    ];
    final gate = Completer<void>();
    final twoStarted = Completer<void>();
    var started = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          started++;
          if (started == 2 && !twoStarted.isCompleted) twoStarted.complete();
          await gate.future;
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: '$url/article'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '命中', strength: 5);
    try {
      await twoStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(started, 2);
    } finally {
      gate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('stalled startup probes admit another host and cancel stops the timer',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 10; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.test/list',
          adapter: adapter,
        ),
    ];
    final firstGate = Completer<void>();
    final thirdStarted = Completer<void>();
    var started = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          started++;
          if (started == 3 && !thirdStarted.isCompleted) {
            thirdStarted.complete();
          }
          if (url.contains('host0.test') || url.contains('host1.test')) {
            await firstGate.future;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: '$url/article'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '命中', strength: 5);
    try {
      await thirdStarted.future.timeout(const Duration(seconds: 2));
      expect(started, greaterThanOrEqualTo(3));
      run.cancel();
      final countAtCancel = started;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(started, countAtCancel);
      expect((await run.finished).isFinished, isTrue);
    } finally {
      firstGate.complete();
      service.dispose();
    }
  });

  test('a cold host uses one connection until its first response', () async {
    final source = AnnouncementSource(
      id: 'cold',
      name: 'Cold',
      listUrl: 'https://cold.test/list0',
      additionalListUrls: [
        for (var index = 1; index < 6; index++) 'https://cold.test/list$index',
      ],
      adapter: const AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final firstGate = Completer<void>();
    final warmGate = Completer<void>();
    final firstStarted = Completer<void>();
    final warmedToLimit = Completer<void>();
    var started = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          started++;
          if (url.endsWith('list0')) {
            firstStarted.complete();
            await firstGate.future;
          } else {
            if (started == 4 && !warmedToLimit.isCompleted) {
              warmedToLimit.complete();
            }
            await warmGate.future;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: '$url/article'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '命中', strength: 5);
    try {
      await firstStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(started, 1);
      firstGate.complete();
      await warmedToLimit.future.timeout(const Duration(seconds: 2));
      expect(started, 4);
    } finally {
      if (!firstGate.isCompleted) firstGate.complete();
      warmGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('Retry-After is preserved and malformed hints keep the HTTP error',
      () async {
    Future<AnnouncementApiException> failure(String header) async {
      final client = AnnouncementApiClient(
        httpClient: http_testing.MockClient((_) async => http.Response(
              'limited',
              429,
              headers: {'retry-after': header},
            )),
      );
      try {
        await client.fetchSearchResponse('https://example.org/list');
        throw StateError('Expected the request to fail');
      } on AnnouncementApiException catch (error) {
        return error;
      } finally {
        client.close();
      }
    }

    final valid = await failure('3');
    expect(valid.statusCode, 429);
    expect(valid.retryAfter, const Duration(seconds: 3));
    final malformed = await failure('not a date');
    expect(malformed.statusCode, 429);
    expect(malformed.retryAfter, isNull);
  });

  test('search stops downloading a non-HTML response after its headers',
      () async {
    var cancelled = false;
    var bodyDelivered = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () {
        scheduleMicrotask(() {
          if (cancelled) return;
          bodyDelivered = true;
          body.add(List<int>.filled(1024 * 1024, 1));
          body.close();
        });
      },
      onCancel: () => cancelled = true,
    );
    final client = AnnouncementApiClient(
      httpClient: http_testing.MockClient.streaming((request, _) async {
        expect(request.method, 'GET');
        expect(request.headers['accept'], contains('text/html'));
        return http.StreamedResponse(body.stream, 200,
            headers: {'content-type': 'application/pdf'});
      }),
    );
    final response =
        await client.fetchSearchResponse('https://example.org/attachment');
    await Future<void>.delayed(Duration.zero);
    expect(response.bodyBytes, isEmpty);
    expect(cancelled, isTrue);
    expect(bodyDelivered, isFalse);
    client.close();
  });

  test('search downloads HTML when it is the requested list or article',
      () async {
    final client = AnnouncementApiClient(
      httpClient: http_testing.MockClient.streaming((_, __) async =>
          http.StreamedResponse(
              Stream.value(utf8.encode('<html>ok</html>')), 200,
              headers: {'content-type': 'text/html; charset=utf-8'})),
    );
    final response =
        await client.fetchSearchResponse('https://example.org/article.htm');
    expect(utf8.decode(response.bodyBytes), '<html>ok</html>');
    client.close();
  });

  test('Ultra keeps independent hosts active within its global budget',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 80; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.example/list',
          adapter: adapter,
        ),
    ];
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    var active = 0;
    var peak = 0;
    var clients = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: clients++,
        request: (_, url) {
          if (url.endsWith('/list')) {
            return Future.value(http.Response('ok', 200));
          }
          active++;
          if (active > peak) peak = active;
          if (active == 24 && !started.isCompleted) started.complete();
          return gate.future.whenComplete(() => active--);
        },
        page: (url) => AnnouncementSearchColumnPage(
            [AnnouncementListItem(title: 'plain', url: '$url/article')], null),
      ),
    );
    final run =
        service.startSearch(query: 'target', includeBody: true, strength: 5);
    await started.future.timeout(const Duration(seconds: 2));
    expect(run.clientCount, 200);
    expect(clients, 56);
    expect(run.networkLimit, 24);
    expect(active, 24);
    gate.complete(http.Response('ok', 200));
    final result = await run.finished;
    expect(result.isComplete, isTrue);
    expect(result.requestCount, 160);
    expect(peak, 24);
    service.dispose();
  });

  test('ALL starts every first page while a slow department is still pending',
      () async {
    final firstPages = {
      for (final source in AnnouncementSource.all) ...source.listUrls,
    };
    final startedUrls = <String>{};
    final allStarted = Completer<void>();
    final releaseSlow = Completer<void>();
    final slowUrl = AnnouncementSource.all.first.listUrl;
    final service = AnnouncementSearchService(
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          startedUrls.add(url);
          if (startedUrls.length == firstPages.length &&
              !allStarted.isCompleted) {
            allStarted.complete();
          }
          if (url == slowUrl) await releaseSlow.future;
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: '$url/article'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '命中', strength: 5);
    try {
      await allStarted.future.timeout(const Duration(seconds: 2));
      expect(startedUrls, firstPages);
      expect(run.networkLimit, 24);
    } finally {
      releaseSlow.complete();
      final result = await run.finished;
      expect(result.isComplete, isTrue);
      expect(result.requestCount, firstPages.length);
      service.dispose();
    }
  });

  test('same-host requests respect the cap and rotate departments', () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      const AnnouncementSource(
        id: 'a',
        name: 'A',
        listUrl: 'https://same.test/a1',
        additionalListUrls: ['https://same.test/a2', 'https://same.test/a3'],
        adapter: adapter,
      ),
      for (var index = 1; index <= 29; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://same.test/s$index',
          adapter: adapter,
        ),
    ];
    final sourceByUrl = <String, String>{
      for (final source in sources)
        for (final url in source.listUrls) url: source.id,
    };
    final starts = <String>[];
    final clientSources = <int, Set<String>>{};
    var active = 0;
    var peak = 0;
    var created = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: created++,
        request: (id, url) async {
          starts.add(url);
          clientSources.putIfAbsent(id, () => {}).add(sourceByUrl[url]!);
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 3));
          active--;
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage(
            [AnnouncementListItem(title: '命中', url: '$url/article')], null),
      ),
    );
    final result = await service
        .startSearch(query: '命中', strength: 0, batchPause: Duration.zero)
        .finished;
    expect(result.isComplete, isTrue);
    expect(result.requestCount, 32);
    expect(created, 24);
    expect(peak, lessThanOrEqualTo(2));
    expect(starts.take(3).map((url) => sourceByUrl[url]), ['a', 's1', 's2']);
    expect(clientSources.values.any((ids) => ids.length > 1), isTrue);
    service.dispose();
  });

  test('handshake and socket faults reduce same-host admission', () async {
    final hostLimit = AnnouncementSearchProfile.forStrength(5).hostLimit;
    for (final error in <Object>[
      const HandshakeException('connection terminated during handshake'),
      const SocketException('connection reset by peer'),
    ]) {
      final source = AnnouncementSource(
        id: 'fault',
        name: 'Fault',
        listUrl: 'https://fault.test/list0',
        additionalListUrls: [
          for (var index = 1; index < hostLimit + 4; index++)
            'https://fault.test/list$index',
        ],
        adapter: const AnnouncementSourceAdapter(
            listFormat: AnnouncementListFormat.onlyList),
      );
      final gate = Completer<void>();
      final failed = Completer<void>();
      var started = 0;
      final service = AnnouncementSearchService(
        sources: [source],
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, url) async {
            started++;
            if (url.endsWith('list0')) {
              failed.complete();
              throw error;
            }
            await gate.future;
            return http.Response('ok', 200);
          },
          page: (url) => AnnouncementSearchColumnPage([
            AnnouncementListItem(title: '命中', url: '$url/article'),
          ], null),
        ),
      );
      final run = service.startSearch(
        query: '命中',
        strength: 5,
        retryFailures: false,
      );
      try {
        await failed.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(started, 1);
      } finally {
        gate.complete();
        expect((await run.finished).failedPages, 1);
        service.dispose();
      }
    }
  });

  test('one Ultra department can use three same-host requests', () async {
    final source = AnnouncementSource(
      id: 'college',
      name: 'College',
      listUrl: 'https://college.test/list0',
      additionalListUrls: [
        for (var index = 1; index < 20; index++)
          'https://college.test/list$index',
      ],
      adapter: const AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final gate = Completer<void>();
    final started = Completer<void>();
    var active = 0;
    var peak = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('list0')) return http.Response('ok', 200);
          active++;
          if (active > peak) peak = active;
          if (active == 3 && !started.isCompleted) started.complete();
          await gate.future;
          active--;
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: '$url/article'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '命中', strength: 5);
    try {
      await started.future.timeout(const Duration(seconds: 2));
      expect(run.networkLimit, 24);
      expect(peak, 3);
    } finally {
      gate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('column pause delays the next list page while body gets a turn',
      () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final starts = <String, DateTime>{};
    final order = <String>[];
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          starts[url] = DateTime.now();
          order.add(url);
          return http.Response('ok', 200);
        },
        page: (url) => url.endsWith('/1')
            ? const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                    title: 'plain', url: 'https://example.org/article'),
              ], 'https://example.org/2')
            : const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                    title: 'hit', url: 'https://example.org/title'),
              ], null),
        body: (_) async => '',
      ),
    );
    final result = await service
        .startSearch(
          query: 'hit',
          includeBody: true,
          fast: true,
          strength: 0,
          batchPause: const Duration(milliseconds: 30),
        )
        .finished;
    expect(result.isComplete, isTrue);
    expect(order, [
      'https://example.org/1',
      'https://example.org/article',
      'https://example.org/2',
    ]);
    expect(
      starts['https://example.org/2']!
          .difference(starts['https://example.org/1']!)
          .inMilliseconds,
      greaterThanOrEqualTo(25),
    );
    service.dispose();
  });

  test('Fast shortens the default column pause without skipping pages',
      () async {
    const source = AnnouncementSource(
      id: 'paced',
      name: 'Paced',
      listUrl: 'https://paced.test/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );

    Future<Duration> pageGap(bool fast) async {
      final starts = <String, DateTime>{};
      final service = AnnouncementSearchService(
        sources: [source],
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, url) async {
            starts[url] = DateTime.now();
            return http.Response('ok', 200);
          },
          page: (url) => AnnouncementSearchColumnPage(
            [AnnouncementListItem(title: '命中', url: '$url/article')],
            url.endsWith('/1') ? 'https://paced.test/2' : null,
          ),
        ),
      );
      final result = await service
          .startSearch(query: '命中', strength: 4, fast: fast)
          .finished;
      expect(result.isComplete, isTrue);
      expect(result.completedPages, 2);
      service.dispose();
      return starts['https://paced.test/2']!
          .difference(starts['https://paced.test/1']!);
    }

    final normal = await pageGap(false);
    final fast = await pageGap(true);
    expect(normal.inMilliseconds, greaterThanOrEqualTo(3950));
    expect(fast.inMilliseconds, lessThan(normal.inMilliseconds - 600));
  });

  test('failed list page ends the run and a new search reuses fetched history',
      () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final requests = <String>[];
    var recover = false;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          requests.add(url);
          if (url.endsWith('/2') && !recover) throw StateError('offline');
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage(
          [AnnouncementListItem(title: '匹配', url: '$url/article')],
          url.endsWith('/1') ? 'https://example.org/2' : null,
        ),
      ),
    );
    final run = service.startSearch(
      query: '匹配',
      strength: 0,
      retryFailures: false,
      batchPause: Duration.zero,
    );
    final partial = await run.finished;
    expect(partial.isComplete, isFalse);
    expect(partial.isFinished, isTrue);
    expect(partial.failedPages, 1);
    expect(partial.completedPages, 1);
    expect(partial.discoveredArticles, 1);
    expect(requests, ['https://example.org/1', 'https://example.org/2']);
    expect(run.canResume, isFalse);

    recover = true;
    final complete = await service
        .startSearch(
          query: '匹配',
          strength: 0,
          retryFailures: false,
          batchPause: Duration.zero,
        )
        .finished;
    expect(complete.isComplete, isTrue);
    expect(complete.completedPages, 2);
    expect(complete.discoveredArticles, 2);
    expect(requests, [
      'https://example.org/1',
      'https://example.org/2',
      'https://example.org/2',
    ]);

    final cached = await service
        .startSearch(
          query: '匹配',
          strength: 0,
          retryFailures: false,
          batchPause: Duration.zero,
        )
        .finished;
    expect(cached.isComplete, isTrue);
    expect(cached.requestCount, 0);
    expect(cached.cacheHits, greaterThanOrEqualTo(2));
    service.dispose();
  });

  test('failed body ends the run and a later search can match it', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var recover = false;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/article') && !recover) {
            throw StateError('offline');
          }
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通标题', url: 'https://example.org/article')
        ], null),
        body: (_) async => '正文关键词',
      ),
    );
    final run = service.startSearch(
      query: '关键词',
      includeBody: true,
      strength: 0,
      retryFailures: false,
    );
    final matches = <AnnouncementListItem>[];
    final subscription =
        run.updates.listen((progress) => matches.addAll(progress.newMatches));
    final partial = await run.finished;
    expect(partial.failedArticles, 1);
    expect(matches, isEmpty);
    expect(run.canResume, isFalse);
    recover = true;
    final complete = await service
        .startSearch(
          query: '关键词',
          includeBody: true,
          strength: 0,
          retryFailures: false,
        )
        .finished;
    expect(complete.isComplete, isTrue);
    expect(complete.matchedArticles, 1);
    await subscription.cancel();
    service.dispose();
  });

  test('FAST looks ahead several pages and releases title hits early',
      () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );

    Future<(List<String>, bool)> runCase(bool fast) async {
      final bodyGate = Completer<void>();
      final bodyStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final thirdStarted = Completer<void>();
      final matches = <String>[];
      final service = AnnouncementSearchService(
        sources: [source],
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, url) async {
            if (url == 'https://example.org/2' && !secondStarted.isCompleted) {
              secondStarted.complete();
            }
            if (url == 'https://example.org/3' && !thirdStarted.isCompleted) {
              thirdStarted.complete();
            }
            return http.Response('ok', 200);
          },
          page: (url) {
            if (url.endsWith('/1')) {
              return const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                  title: 'first',
                  url: 'https://example.org/article',
                ),
                AnnouncementListItem(
                  title: 'hit second',
                  url: 'https://example.org/title',
                ),
              ], 'https://example.org/2');
            }
            if (url.endsWith('/2')) {
              return const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                  title: 'hit third',
                  url: 'https://example.org/third',
                ),
              ], 'https://example.org/3');
            }
            return const AnnouncementSearchColumnPage([
              AnnouncementListItem(
                title: 'hit fourth',
                url: 'https://example.org/fourth',
              ),
            ], null);
          },
          body: (_) async {
            if (!bodyStarted.isCompleted) bodyStarted.complete();
            await bodyGate.future;
            return 'hit';
          },
        ),
      );
      final run = service.startSearch(
        query: 'hit',
        includeBody: true,
        fast: fast,
        strength: 0,
        batchPause: Duration.zero,
      );
      final subscription = run.updates.listen((progress) {
        matches.addAll(progress.newMatches.map((item) => item.title));
      });
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      if (fast) {
        await secondStarted.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await thirdStarted.future.timeout(const Duration(seconds: 2));
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(secondStarted.isCompleted, isFalse);
      }
      final overlapped = secondStarted.isCompleted;
      bodyGate.complete();
      final result = await run.finished;
      expect(result.isComplete, isTrue);
      await subscription.cancel();
      service.dispose();
      return (matches, overlapped);
    }

    final normal = await runCase(false);
    final fast = await runCase(true);
    expect(normal.$2, isFalse);
    expect(fast.$2, isTrue);
    expect(normal.$1.first, 'hit second');
    expect(fast.$1.first, 'hit second');
    expect(
        normal.$1.toSet(), {'first', 'hit second', 'hit third', 'hit fourth'});
    expect(fast.$1.toSet(), normal.$1.toSet());
  });

  test('Fast next list starts before a backlog of article bodies', () async {
    const source = AnnouncementSource(
      id: 'fast',
      name: 'Fast',
      listUrl: 'https://same.test/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final bodyGate = Completer<void>();
    final bodyStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.contains('/article/')) {
            if (!bodyStarted.isCompleted) bodyStarted.complete();
            await bodyGate.future;
          }
          if (url == 'https://same.test/2' && !secondStarted.isCompleted) {
            secondStarted.complete();
          }
          return http.Response('ok', 200);
        },
        page: (url) => url.endsWith('/1')
            ? AnnouncementSearchColumnPage([
                for (var index = 0; index < 12; index++)
                  AnnouncementListItem(
                      title: 'plain $index',
                      url: 'https://same.test/article/$index'),
              ], 'https://same.test/2')
            : const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                    title: 'target', url: 'https://same.test/target'),
              ], null),
        body: (_) async => '',
      ),
    );
    final run = service.startSearch(
      query: 'target',
      includeBody: true,
      fast: true,
      strength: 0,
      batchPause: Duration.zero,
    );
    try {
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      await secondStarted.future.timeout(const Duration(seconds: 2));
      expect(run.networkLimit, 4);
    } finally {
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('unfinished first pages reserve global network slots from bodies',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 12; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: index == 0
              ? 'https://first.test/list0'
              : 'https://same.test/list$index',
          adapter: adapter,
        ),
    ];
    final firstGate = Completer<void>();
    final bodyGate = Completer<void>();
    final firstBodyStarted = Completer<void>();
    var activeBodies = 0;
    var peakBodies = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.startsWith('https://same.test/list')) {
            await firstGate.future;
          } else if (url.contains('/article/')) {
            activeBodies++;
            if (activeBodies > peakBodies) peakBodies = activeBodies;
            if (activeBodies == 1 && !firstBodyStarted.isCompleted) {
              firstBodyStarted.complete();
            }
            await bodyGate.future;
            activeBodies--;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage(
          url.endsWith('list0')
              ? [
                  for (var index = 0; index < 12; index++)
                    AnnouncementListItem(
                        title: 'plain $index',
                        url: 'https://body$index.test/article/$index'),
                ]
              : [AnnouncementListItem(title: 'target', url: '$url/target')],
          null,
        ),
        body: (_) async => '',
      ),
    );
    final run = service.startSearch(
      query: 'target',
      includeBody: true,
      strength: 0,
    );
    try {
      await firstBodyStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(peakBodies, 1);
    } finally {
      firstGate.complete();
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('a recovered body does not hide later ready matches', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/1',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var bodyAttempts = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/article') && ++bodyAttempts <= 4) {
            throw StateError('temporary');
          }
          return http.Response('ok', 200);
        },
        page: (url) => url.endsWith('/1')
            ? const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                    title: 'first', url: 'https://example.org/article'),
                AnnouncementListItem(
                    title: 'hit second', url: 'https://example.org/title'),
              ], 'https://example.org/2')
            : const AnnouncementSearchColumnPage([
                AnnouncementListItem(
                    title: 'hit third', url: 'https://example.org/third'),
              ], null),
        body: (_) async => 'hit',
      ),
    );
    final run = service.startSearch(
      query: 'hit',
      includeBody: true,
      fast: true,
      strength: 0,
      batchPause: Duration.zero,
    );
    final matches = <String>[];
    final subscription = run.updates.listen((progress) {
      matches.addAll(progress.newMatches.map((item) => item.title));
    });
    final result = await run.finished;
    expect(result.isComplete, isTrue);
    expect(bodyAttempts, 5);
    expect(matches, ['hit second', 'hit third', 'first']);
    await subscription.cancel();
    service.dispose();
  });

  test('film date and body share the same fetched article', () async {
    const source = AnnouncementSource(
      id: 'sfa',
      name: '电影学院',
      listUrl: 'https://film.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.filmNotice),
    );
    final requests = <String>[];
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          requests.add(url);
          return http.Response(
              url.endsWith('.htm') ? '2026-10-20' : 'list', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通标题', url: 'https://film.test/story.htm')
        ], null),
        body: (_) async => '目标词',
      ),
    );
    final run = service.startSearch(
      query: '目标词',
      includeBody: true,
      strength: 0,
    );
    final matches = <AnnouncementListItem>[];
    final subscription =
        run.updates.listen((progress) => matches.addAll(progress.newMatches));
    final result = await run.finished;
    expect(result.isComplete, isTrue);
    expect(result.requestCount, 2);
    expect(result.cacheHits, greaterThanOrEqualTo(1));
    expect(requests.where((url) => url.endsWith('.htm')), hasLength(1));
    expect(matches.single.publishedAt, DateTime(2026, 10, 20));
    expect(matches.single.summary, '目标词');
    await subscription.cancel();
    service.dispose();
  });

  test('Film Academy title hit does not wait for article date requests',
      () async {
    const source = AnnouncementSource(
      id: 'sfa',
      name: '电影学院',
      listUrl: 'https://film.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.filmNotice),
    );
    final dateGate = Completer<void>();
    final titleHit = Completer<AnnouncementListItem>();
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('.htm')) await dateGate.future;
          return http.Response('2026-10-22', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '目标词公告',
              url: 'https://film.test/story.htm',
              sourceId: 'sfa'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '目标词', strength: 5);
    final subscription = run.updates.listen((progress) {
      for (final item in progress.newMatches) {
        if (!titleHit.isCompleted) titleHit.complete(item);
      }
    });
    try {
      expect((await titleHit.future.timeout(const Duration(seconds: 2))).title,
          '目标词公告');
    } finally {
      dateGate.complete();
      expect((await run.finished).isComplete, isTrue);
      await subscription.cancel();
      service.dispose();
    }
  });

  test('Film Academy search estimates undated external position', () async {
    const source = AnnouncementSource(
      id: 'sfa',
      name: '电影学院',
      listUrl: 'https://film.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.filmNotice),
    );
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async => http.Response(
            url.endsWith('/new.htm')
                ? '2026-10-20'
                : url.endsWith('/old.htm')
                    ? '2026-10-10'
                    : 'list',
            200),
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '目标词新公告',
              url: 'https://film.test/new.htm',
              sourceId: 'sfa'),
          AnnouncementListItem(
              title: '目标词外链',
              url: 'https://external.test/story',
              sourceId: 'sfa'),
          AnnouncementListItem(
              title: '目标词旧公告',
              url: 'https://film.test/old.htm',
              sourceId: 'sfa'),
        ], null),
      ),
    );
    final latest = <String, AnnouncementListItem>{};
    final run = service.startSearch(query: '目标词', strength: 5);
    final subscription = run.updates.listen((progress) {
      for (final item in progress.newMatches) {
        latest[item.title] = item;
      }
    });
    expect((await run.finished).isComplete, isTrue);
    expect(latest['目标词外链']?.publishedAt, DateTime(2026, 10, 15));
    expect(latest['目标词外链']?.dateText, isEmpty);
    await subscription.cancel();
    service.dispose();
  });

  test('body matches reuse one request and carry a readable preview', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var requests = 0;
    var bodyParses = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          requests++;
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通标题', url: 'https://example.org/article')
        ], null),
        body: (_) async {
          bodyParses++;
          return 'Alpha Beta，正文概览';
        },
      ),
    );
    final firstRun =
        service.startSearch(query: 'ALPHA', includeBody: true, strength: 0);
    final firstMatches = <AnnouncementListItem>[];
    final firstSubscription = firstRun.updates
        .listen((progress) => firstMatches.addAll(progress.newMatches));
    final first = await firstRun.finished;
    await firstSubscription.cancel();
    final secondRun =
        service.startSearch(query: 'beta', includeBody: true, strength: 0);
    final secondMatches = <AnnouncementListItem>[];
    final secondSubscription = secondRun.updates
        .listen((progress) => secondMatches.addAll(progress.newMatches));
    final second = await secondRun.finished;
    await secondSubscription.cancel();
    expect(first.matchedArticles, 1);
    expect(second.matchedArticles, 1);
    expect(firstMatches.single.summary, 'Alpha Beta，正文概览');
    expect(secondMatches.single.summary, 'Alpha Beta，正文概览');
    expect(requests, 2);
    expect(bodyParses, 1);
    expect(second.requestCount, 0);
    service.dispose();
  });

  test('content-only search checks bodies even when titles match', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, __) async => http.Response('ok', 200),
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '目标标题', url: 'https://example.org/title'),
          AnnouncementListItem(title: '普通标题', url: 'https://example.org/body'),
        ], null),
        body: (url) async => url.endsWith('/body') ? '目标正文' : '其他内容',
      ),
    );
    final run = service.startSearch(
      query: '目标',
      includeTitle: false,
      includeBody: true,
      strength: 0,
    );
    final matches = <AnnouncementListItem>[];
    final subscription = run.updates.listen(
      (progress) => matches.addAll(progress.newMatches),
    );
    final result = await run.finished;
    await subscription.cancel();
    expect(result.matchedArticles, 1);
    expect(matches.single.title, '普通标题');
    service.dispose();
  });

  test('body text survives raw HTML cache eviction for the next query',
      () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var articleRequests = 0;
    final largeHtml =
        http.Response.bytes(List<int>.filled(17 * 1024 * 1024, 65), 200);
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/article.htm')) {
            articleRequests++;
            return largeHtml;
          }
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通标题',
              url: 'https://example.org/article.htm',
              sourceId: 'a'),
        ], null),
        body: (_) async => 'alpha beta',
      ),
    );
    final first = await service
        .startSearch(query: 'alpha', includeBody: true, strength: 5)
        .finished;
    final second = await service
        .startSearch(query: 'beta', includeBody: true, strength: 5)
        .finished;
    expect(first.matchedArticles, 1);
    expect(second.matchedArticles, 1);
    expect(articleRequests, 1);
    expect(second.cacheHits, greaterThanOrEqualTo(1));
    service.dispose();
  });

  test('searchable table cells remain in parsed body text', () async {
    final client = AnnouncementApiClient();
    const item = AnnouncementListItem(
      title: '普通标题',
      url: 'https://example.org/article',
    );
    final text = await client.parseSearchDetailText(
      response: http.Response(
        '<div class="nry"><table><tr><td>table needle</td></tr></table></div>',
        200,
        headers: {'content-type': 'text/html'},
      ),
      item: item,
    );
    expect(text, contains('table needle'));
    client.close();
  });

  test('body text keeps article tables and alt text without site chrome',
      () async {
    const item = AnnouncementListItem(
      title: '普通标题',
      url: 'https://example.org/article.htm',
      sourceId: 'shu',
    );
    final client = AnnouncementApiClient();
    final response = http.Response.bytes(
      utf8.encode('<div class="nry"><div class="xx">菜单关键词</div>'
          '<div class="v_news_content">'
          '<p>各单位请查看 MixedCase <a href="/a">目标</a><a href="/b">词</a></p>'
          '<table><tr><td>表格关键</td><td>内容</td></tr></table>'
          '<img alt="图片说明"></div></div>'),
      200,
      headers: {'content-type': 'text/html'},
    );
    final text =
        await client.parseSearchDetailText(response: response, item: item);
    expect(text, contains('目标词'));
    expect(text, contains('MixedCase'));
    expect(text, contains('表格关键 内容'));
    expect(text, contains('图片说明'));
    expect(text, isNot(contains('菜单关键词')));
    client.close();
  });

  test('unknown article layout is a parse failure, but documents are skipped',
      () async {
    final client = AnnouncementApiClient();
    const item = AnnouncementListItem(
      title: '普通标题',
      url: 'https://example.org/article.htm',
    );
    await expectLater(
      client.parseSearchDetailText(
        response: http.Response(
            '<html><body>unexpected layout</body></html>', 200,
            headers: {'content-type': 'text/html'}),
        item: item,
      ),
      throwsA(isA<AnnouncementSearchParseException>()),
    );
    expect(
      await client.parseSearchDetailText(
        response: http.Response.bytes(const [37, 80, 68, 70], 200,
            headers: {'content-type': 'application/pdf'}),
        item: item,
      ),
      isEmpty,
    );
    client.close();
  });

  test('a parse failure is counted once and does not block another department',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    const sources = [
      AnnouncementSource(
          id: 'bad',
          name: 'Bad',
          listUrl: 'https://example.org/bad',
          adapter: adapter),
      AnnouncementSource(
          id: 'good',
          name: 'Good',
          listUrl: 'https://example.org/good',
          adapter: adapter),
    ];
    final requests = <String>[];
    final service = AnnouncementSearchService(
      sources: sources,
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          requests.add(url);
          return http.Response('ok', 200);
        },
        page: (url) {
          if (url.endsWith('/bad')) {
            throw const AnnouncementSearchParseException('invalid list');
          }
          return const AnnouncementSearchColumnPage([
            AnnouncementListItem(
              title: '目标公告',
              url: 'https://example.org/article',
              sourceId: 'good',
            ),
          ], null);
        },
      ),
    );
    final result = await service
        .startSearch(query: '目标', strength: 5, retryFailures: true)
        .finished;
    expect(requests.where((url) => url.endsWith('/bad')), hasLength(1));
    expect(result.parseFailureCount, 1);
    expect(result.timeoutFailureCount, 0);
    expect(result.failedPages, 1);
    expect(result.matchedArticles, 1);
    expect(result.retryCount, 0);
    expect(result.isFinished, isTrue);
    expect(result.isComplete, isFalse);
    service.dispose();
  });

  test('timeout retries follow the setting and count exhausted timeouts',
      () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    Future<AnnouncementSearchProgress> search(
        {required bool retryFailures, required int failCount}) async {
      var attempts = 0;
      final service = AnnouncementSearchService(
        sources: [source],
        retryBaseDelay: Duration.zero,
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, url) async {
            if (url.endsWith('/article')) {
              attempts++;
              if (attempts <= failCount) {
                throw TimeoutException('request timed out');
              }
            }
            return http.Response('ok', 200);
          },
          page: (_) => const AnnouncementSearchColumnPage([
            AnnouncementListItem(
              title: '普通公告',
              url: 'https://example.org/article',
              sourceId: 'a',
            ),
          ], null),
          body: (_) async => '目标正文',
        ),
      );
      final result = await service
          .startSearch(
            query: '目标',
            includeBody: true,
            strength: 0,
            retryFailures: retryFailures,
          )
          .finished;
      expect(attempts, retryFailures ? 3 : 1);
      service.dispose();
      return result;
    }

    final recovered = await search(retryFailures: true, failCount: 2);
    expect(recovered.isComplete, isTrue);
    expect(recovered.matchedArticles, 1);
    expect(recovered.retryCount, 2);
    expect(recovered.timeoutFailureCount, 0);
    final exhausted = await search(retryFailures: false, failCount: 3);
    expect(exhausted.isFinished, isTrue);
    expect(exhausted.isComplete, isFalse);
    expect(exhausted.failedArticles, 1);
    expect(exhausted.timeoutFailureCount, 1);
    expect(exhausted.parseFailureCount, 0);
  });

  test('automatic retries include a final recovery round', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var attempts = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, __) async {
          attempts++;
          if (attempts <= 4) throw StateError('temporary');
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: 'https://example.org/article')
        ], null),
      ),
    );
    final result = await service.startSearch(query: '命中', strength: 0).finished;
    expect(result.isComplete, isTrue);
    expect(result.requestCount, 5);
    expect(result.retryCount, 4);
    service.dispose();
  });

  test('missing article HTML is reported once without pointless retries',
      () async {
    const source = AnnouncementSource(
      id: 'college',
      name: 'College',
      listUrl: 'https://college.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var articleRequests = 0;
    final matches = <AnnouncementListItem>[];
    final service = AnnouncementSearchService(
      sources: [source],
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/missing.htm')) {
            articleRequests++;
            throw const AnnouncementApiException('missing', statusCode: 404);
          }
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通文章',
              url: 'https://college.test/missing.htm',
              sourceId: 'college'),
          AnnouncementListItem(
              title: '目标词通知',
              url: 'https://college.test/hit.htm',
              sourceId: 'college'),
        ], null),
      ),
    );
    final run =
        service.startSearch(query: '目标词', includeBody: true, strength: 5);
    final subscription =
        run.updates.listen((progress) => matches.addAll(progress.newMatches));
    final result = await run.finished;
    expect(result.completedPages, 1);
    expect(result.failedArticles, 1);
    expect(articleRequests, 1);
    expect(matches.map((item) => item.title), ['目标词通知']);
    await subscription.cancel();
    service.dispose();
  });

  test('simultaneous consumers coalesce one URL', () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    const url = 'https://example.org/shared';
    const sources = [
      AnnouncementSource(id: 'a', name: 'A', listUrl: url, adapter: adapter),
      AnnouncementSource(id: 'b', name: 'B', listUrl: url, adapter: adapter),
    ];
    var requests = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, __) async {
          requests++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: 'https://example.org/article')
        ], null),
      ),
    );
    final result = await service.startSearch(query: '命中', strength: 0).finished;
    expect(result.isComplete, isTrue);
    expect(requests, 1);
    expect(result.cacheHits, 1);
    expect(result.discoveredArticles, 2);
    service.dispose();
  });

  test('a shared article URL does not hide a hit in another department',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    const sources = [
      AnnouncementSource(
          id: 'a', name: 'A', listUrl: 'https://a.test/list', adapter: adapter),
      AnnouncementSource(
          id: 'b', name: 'B', listUrl: 'https://b.test/list', adapter: adapter),
    ];
    final firstParsed = Completer<void>();
    final matches = <AnnouncementListItem>[];
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.contains('b.test')) await firstParsed.future;
          return http.Response('ok', 200);
        },
        page: (url) {
          if (url.contains('a.test')) {
            if (!firstParsed.isCompleted) firstParsed.complete();
            return const AnnouncementSearchColumnPage([
              AnnouncementListItem(
                  title: '普通标题',
                  url: 'https://shared.test/article',
                  sourceId: 'a')
            ], null);
          }
          return const AnnouncementSearchColumnPage([
            AnnouncementListItem(
                title: '目标词通知',
                url: 'https://shared.test/article',
                sourceId: 'b')
          ], null);
        },
      ),
    );
    final run = service.startSearch(query: '目标词', strength: 5);
    final subscription =
        run.updates.listen((progress) => matches.addAll(progress.newMatches));
    final result = await run.finished;
    expect(result.isComplete, isTrue);
    expect(result.discoveredArticles, 2);
    expect(matches.map((item) => item.sourceId), ['b']);
    await subscription.cancel();
    service.dispose();
  });

  test('different titles for one URL remain searchable across columns',
      () async {
    const source = AnnouncementSource(
      id: 'college',
      name: 'College',
      listUrl: 'https://college.test/column-a',
      additionalListUrls: ['https://college.test/column-b'],
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final firstParsed = Completer<void>();
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('column-b')) await firstParsed.future;
          return http.Response('ok', 200);
        },
        page: (url) {
          if (url.endsWith('column-a')) {
            if (!firstParsed.isCompleted) firstParsed.complete();
          }
          return AnnouncementSearchColumnPage([
            AnnouncementListItem(
                title: url.endsWith('column-a') ? '普通标题' : '目标词标题',
                url: 'https://college.test/shared.htm',
                sourceId: 'college'),
          ], null);
        },
      ),
    );
    final run = service.startSearch(query: '目标词', strength: 5);
    final matches = <AnnouncementListItem>[];
    final subscription =
        run.updates.listen((progress) => matches.addAll(progress.newMatches));
    final result = await run.finished;
    expect(result.isComplete, isTrue);
    expect(matches.map((item) => item.title), ['目标词标题']);
    await subscription.cancel();
    service.dispose();
  });

  test('a slow department cannot delay another department first-page hit',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    const sources = [
      AnnouncementSource(
          id: 'slow',
          name: 'Slow',
          listUrl: 'https://slow.test/list',
          adapter: adapter),
      AnnouncementSource(
          id: 'fast',
          name: 'Fast',
          listUrl: 'https://fast.test/list',
          adapter: adapter),
    ];
    final slowGate = Completer<void>();
    final hit = Completer<AnnouncementListItem>();
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.contains('slow.test')) await slowGate.future;
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: url.contains('fast.test') ? '目标词' : '普通',
              url: '$url/article',
              sourceId: url.contains('fast.test') ? 'fast' : 'slow'),
        ], null),
      ),
    );
    final run = service.startSearch(query: '目标词', strength: 5);
    final subscription = run.updates.listen((progress) {
      for (final item in progress.newMatches) {
        if (!hit.isCompleted) hit.complete(item);
      }
    });
    expect((await hit.future.timeout(const Duration(seconds: 2))).sourceId,
        'fast');
    slowGate.complete();
    expect((await run.finished).isComplete, isTrue);
    await subscription.cancel();
    service.dispose();
  });

  test('a first-page title hit appears while earlier article body is slow',
      () async {
    const source = AnnouncementSource(
      id: 'college',
      name: 'College',
      listUrl: 'https://college.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final bodyGate = Completer<void>();
    final bodyStarted = Completer<void>();
    final titleHit = Completer<AnnouncementListItem>();
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, __) async => http.Response('ok', 200),
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通文章',
              url: 'https://college.test/slow.htm',
              sourceId: 'college'),
          AnnouncementListItem(
              title: '目标词公告',
              url: 'https://college.test/hit.htm',
              sourceId: 'college'),
        ], null),
        body: (_) async {
          if (!bodyStarted.isCompleted) bodyStarted.complete();
          await bodyGate.future;
          return '';
        },
      ),
    );
    final run =
        service.startSearch(query: '目标词', includeBody: true, strength: 5);
    final subscription = run.updates.listen((progress) {
      for (final item in progress.newMatches) {
        if (!titleHit.isCompleted) titleHit.complete(item);
      }
    });
    try {
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      expect((await titleHit.future.timeout(const Duration(seconds: 2))).title,
          '目标词公告');
    } finally {
      bodyGate.complete();
      await run.finished;
      await subscription.cancel();
      service.dispose();
    }
  });

  test('ALL body search shows the last department first-page title hit early',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 64; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: 'https://host$index.test/list',
          adapter: adapter,
        ),
    ];
    final bodyGate = Completer<void>();
    final hit = Completer<AnnouncementListItem>();
    var created = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () {
        created++;
        return _ScriptedClient(
          id: 0,
          request: (_, __) async => http.Response('ok', 200),
          page: (url) {
            final index = int.parse(Uri.parse(url)
                .host
                .replaceAll('host', '')
                .replaceAll('.test', ''));
            return AnnouncementSearchColumnPage([
              AnnouncementListItem(
                title: index == 63 ? '目标词首篇' : '普通文章',
                url: index == 0 || index == 63
                    ? 'https://shared.test/article.htm'
                    : 'https://host$index.test/article.htm',
                sourceId: 's$index',
              ),
            ], null);
          },
          body: (_) async {
            await bodyGate.future;
            return '';
          },
        );
      },
    );
    final run = service.startSearch(
      query: '目标词',
      includeBody: true,
      strength: 5,
      fast: true,
    );
    final subscription = run.updates.listen((progress) {
      for (final item in progress.newMatches) {
        if (!hit.isCompleted) hit.complete(item);
      }
    });
    try {
      expect((await hit.future.timeout(const Duration(seconds: 3))).sourceId,
          's63');
      expect(run.networkLimit, 24);
      expect(run.clientCount, 200);
      expect(created, 56);
    } finally {
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      await subscription.cancel();
      service.dispose();
    }
  });

  test('body search requests only list pages and HTML article URLs', () async {
    const source = AnnouncementSource(
      id: 'college',
      name: 'College',
      listUrl: 'https://college.test/list.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final requested = <String>[];
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          requested.add(url);
          return http.Response('ok', 200);
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: '普通文章',
              url: 'https://college.test/article.htm',
              sourceId: 'college'),
          AnnouncementListItem(
              title: '附件',
              url: 'https://college.test/file.pdf',
              sourceId: 'college'),
          AnnouncementListItem(
              title: '图片',
              url: 'https://college.test/image.jpg',
              sourceId: 'college'),
        ], null),
        body: (_) async => '目标词',
      ),
    );
    final result = await service
        .startSearch(query: '目标词', includeBody: true, strength: 5)
        .finished;
    expect(result.isComplete, isTrue);
    expect(requested, contains('https://college.test/list.htm'));
    expect(requested, contains('https://college.test/article.htm'));
    expect(requested, hasLength(2));
    service.dispose();
  });

  test('cancellation closes the pool and ignores late responses', () async {
    const source = AnnouncementSource(
      id: 'a',
      name: 'A',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final started = Completer<void>();
    final gate = Completer<http.Response>();
    var created = 0;
    var closed = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: created++,
        request: (_, __) {
          if (!started.isCompleted) started.complete();
          return gate.future;
        },
        page: (_) => const AnnouncementSearchColumnPage([
          AnnouncementListItem(title: '命中', url: 'https://example.org/article')
        ], null),
        onClose: () => closed++,
      ),
    );
    // The scripted client has no transport to abort; the session must still
    // suppress its completion after cancellation.
    final run = service.startSearch(query: '命中', strength: 0);
    final updates = <AnnouncementSearchProgress>[];
    final done = Completer<void>();
    run.updates.listen(updates.add, onDone: done.complete);
    await started.future;
    expect(created, 24);
    run.cancel();
    await done.future;
    expect(closed, 24);
    final count = updates.length;
    gate.complete(http.Response('ok', 200));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(updates, hasLength(count));
    expect(run.canResume, isFalse);
    service.dispose();
  });

  test('selected sources limit requests while preparing the fixed pool',
      () async {
    const first = AnnouncementSource(
      id: 'first',
      name: '第一部门',
      listUrl: 'https://example.org/first',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    const second = AnnouncementSource(
      id: 'second',
      name: '第二部门',
      listUrl: 'https://example.org/second',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final clients = <_SearchClient>[];
    final service = AnnouncementSearchService(
      sources: [first, second],
      clientFactory: () {
        final client = _SearchClient(() {});
        clients.add(client);
        return client;
      },
    );
    await service
        .startSearch(
            query: '关键',
            sources: [second],
            strength: 0,
            batchPause: Duration.zero)
        .updates
        .toList();
    expect(clients, hasLength(24));
    final requests = clients.expand((client) => client.requests).toList();
    expect(requests, contains('https://example.org/second'));
    expect(requests, isNot(contains('https://example.org/first')));
    service.dispose();
  });

  test('pool retries and paginates each column independently', () async {
    const source = AnnouncementSource(
      id: 'test',
      name: '测试部门',
      listUrl: 'https://example.org/a',
      additionalListUrls: ['https://second.example.org/b'],
      columnNames: ['栏目一', '栏目二'],
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final clients = <_SearchClient>[];
    var closed = 0;
    final firstRoundStarted = Completer<void>();
    final firstPageUrls = <String>{};
    var firstColumnAttempts = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () {
        final client = _SearchClient(
          () => closed++,
          onFetch: (url) async {
            expect(clients.length, 24);
            if (url.endsWith('/a') || url.endsWith('/b')) {
              firstPageUrls.add(url);
              if (firstPageUrls.length == 2 && !firstRoundStarted.isCompleted) {
                firstRoundStarted.complete();
              }
              await firstRoundStarted.future;
              if (url.endsWith('/a')) {
                firstColumnAttempts++;
                if (firstColumnAttempts == 1) {
                  throw StateError('temporary failure');
                }
              }
            } else {
              expect(firstRoundStarted.isCompleted, isTrue);
            }
          },
        );
        clients.add(client);
        return client;
      },
    );
    final session = service.startSearch(
      query: '关键',
      strength: 0,
      batchPause: Duration.zero,
    );
    final updates = await session.updates.toList();
    final matches = [for (final update in updates) ...update.newMatches];

    expect(clients.length, 24);
    expect(closed, 24);
    expect(matches.length, 4);
    expect(updates.last.completedPages, 4);
    expect(updates.last.failedPages, 0);
    expect(
        clients
            .expand((client) => client.requests)
            .where((url) => url.endsWith('/a'))
            .length,
        2);
    service.dispose();
  });

  test('articles within a page are searched newest first', () async {
    const source = AnnouncementSource(
      id: 'test',
      name: '测试部门',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _SearchClient(() {}, reverseOrder: true),
    );
    final updates = await service
        .startSearch(query: '关键', strength: 0, batchPause: Duration.zero)
        .updates
        .toList();
    expect(
      [
        for (final update in updates)
          ...update.newMatches.map((item) => item.title)
      ],
      ['关键新文', '关键旧文'],
    );
    service.dispose();
  });

  test('page discovery increases total before body scanning finishes',
      () async {
    const source = AnnouncementSource(
      id: 'test',
      name: '测试部门',
      listUrl: 'https://example.org/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final gate = Completer<void>();
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _SearchClient(() {}, bodyGate: gate),
    );
    final observed = Completer<AnnouncementSearchProgress>();
    final done = Completer<void>();
    service
        .startSearch(query: '正文', includeBody: true, strength: 0)
        .updates
        .listen(
      (progress) {
        if (progress.discoveredArticles == 2 &&
            progress.scannedArticles == 0 &&
            !observed.isCompleted) {
          observed.complete(progress);
        }
      },
      onDone: done.complete,
    );
    final progress = await observed.future.timeout(const Duration(seconds: 2));
    expect(progress.discoveredArticles, 2);
    expect(progress.scannedArticles, 0);
    gate.complete();
    await done.future;
    service.dispose();
  });

  test('cached 90 percent coverage can start bodies during cold admission',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    final sources = [
      for (var index = 0; index < 30; index++)
        AnnouncementSource(
          id: 's$index',
          name: 'S$index',
          listUrl: index < 27
              ? 'https://fast$index.test/list'
              : 'https://slow$index.test/list',
          adapter: adapter,
        ),
    ];
    final slowPages = Completer<void>();
    final bodyGate = Completer<void>();
    final bodyStarted = Completer<void>();
    final service = AnnouncementSearchService(
      sources: sources,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.contains('slow') && url.endsWith('/list')) {
            await slowPages.future;
          } else if (url.endsWith('/article')) {
            if (!bodyStarted.isCompleted) bodyStarted.complete();
            await bodyGate.future;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(title: 'plain', url: '$url/article'),
        ], null),
        body: (_) async => '',
      ),
    );
    expect(
      (await service
              .startSearch(
                  query: 'target',
                  strength: 5,
                  sources: sources.take(27).toList())
              .finished)
          .isComplete,
      isTrue,
    );
    final run =
        service.startSearch(query: 'target', includeBody: true, strength: 5);
    try {
      await bodyStarted.future.timeout(const Duration(seconds: 3));
      expect(slowPages.isCompleted, isFalse);
    } finally {
      slowPages.complete();
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });

  test('first-page final recovery runs while other bodies are pending',
      () async {
    const adapter =
        AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.onlyList);
    const sources = [
      AnnouncementSource(
          id: 'retry',
          name: 'Retry',
          listUrl: 'https://retry.test/list',
          adapter: adapter),
      AnnouncementSource(
          id: 'body',
          name: 'Body',
          listUrl: 'https://body.test/list',
          adapter: adapter),
    ];
    final bodyGate = Completer<void>();
    final bodyStarted = Completer<void>();
    final recoveryStarted = Completer<void>();
    var attempts = 0;
    final service = AnnouncementSearchService(
      sources: sources,
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url == 'https://retry.test/list') {
            attempts++;
            if (attempts <= 4) throw StateError('temporary');
            if (!recoveryStarted.isCompleted) recoveryStarted.complete();
          } else if (url.endsWith('/article')) {
            if (!bodyStarted.isCompleted) bodyStarted.complete();
            await bodyGate.future;
          }
          return http.Response('ok', 200);
        },
        page: (url) => AnnouncementSearchColumnPage([
          AnnouncementListItem(
              title: url.contains('retry.test') ? 'target' : 'plain',
              url: '$url/article'),
        ], null),
        body: (_) async => '',
      ),
    );
    final run =
        service.startSearch(query: 'target', includeBody: true, strength: 5);
    try {
      await bodyStarted.future.timeout(const Duration(seconds: 2));
      await recoveryStarted.future.timeout(const Duration(seconds: 3));
      expect(bodyGate.isCompleted, isFalse);
      expect(attempts, 5);
    } finally {
      bodyGate.complete();
      final result = await run.finished;
      expect(result.isComplete, isTrue);
      expect(result.matchedArticles, 1);
      service.dispose();
    }
  });

  test('failed first-page final recovery is not retried at settlement',
      () async {
    const source = AnnouncementSource(
      id: 'retry',
      name: 'Retry',
      listUrl: 'https://retry.test/list',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    var attempts = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      retryBaseDelay: Duration.zero,
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, __) async {
          attempts++;
          throw StateError('temporary');
        },
        page: (_) => const AnnouncementSearchColumnPage([], null),
      ),
    );
    final result =
        await service.startSearch(query: 'target', strength: 5).finished;
    expect(attempts, 5);
    expect(result.failedPages, 1);
    expect(result.retryCount, 4);
    service.dispose();
  });

  test('body parse concurrency grows from Low to Ultra within CPU budget',
      () async {
    const source = AnnouncementSource(
      id: 'parse',
      name: 'Parse',
      listUrl: 'https://list.test/one',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );

    Future<int> peakFor(int strength) async {
      final profile = AnnouncementSearchProfile.forStrength(strength);
      final total = min(
          profile.desiredTotalParses, max(2, Platform.numberOfProcessors - 1));
      final expectedBody = min(profile.desiredBodyParses, total - 1);
      final bodyGate = Completer<void>();
      final saturated = Completer<void>();
      var active = 0;
      var peak = 0;
      final service = AnnouncementSearchService(
        sources: [source],
        clientFactory: () => _ScriptedClient(
          id: 0,
          request: (_, __) async => http.Response('ok', 200),
          page: (_) => AnnouncementSearchColumnPage([
            for (var index = 0; index < 12; index++)
              AnnouncementListItem(
                  title: 'plain', url: 'https://body$index.test/article'),
          ], null),
          body: (_) async {
            active++;
            if (active > peak) peak = active;
            if (active == expectedBody && !saturated.isCompleted) {
              saturated.complete();
            }
            await bodyGate.future;
            active--;
            return '';
          },
        ),
      );
      final run = service.startSearch(
          query: 'target', includeBody: true, strength: strength);
      try {
        await saturated.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(peak, expectedBody);
      } finally {
        bodyGate.complete();
        expect((await run.finished).isComplete, isTrue);
        service.dispose();
      }
      return peak;
    }

    final low = await peakFor(0);
    final ultra = await peakFor(5);
    expect(low, 1);
    if (Platform.numberOfProcessors >= 3) {
      expect(ultra, greaterThan(low));
    } else {
      expect(ultra, 1);
    }
  });

  test('a list parse advances while Ultra body parses are saturated', () async {
    const source = AnnouncementSource(
      id: 'parse',
      name: 'Parse',
      listUrl: 'https://list.test/one',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );
    final profile = AnnouncementSearchProfile.forStrength(5);
    final total = min(
        profile.desiredTotalParses, max(2, Platform.numberOfProcessors - 1));
    final expectedBody = min(profile.desiredBodyParses, total - 1);
    final bodyGate = Completer<void>();
    final saturated = Completer<void>();
    final secondParsed = Completer<void>();
    var activeBodies = 0;
    final service = AnnouncementSearchService(
      sources: [source],
      clientFactory: () => _ScriptedClient(
        id: 0,
        request: (_, url) async {
          if (url.endsWith('/two')) await saturated.future;
          return http.Response('ok', 200);
        },
        page: (url) {
          if (url.endsWith('/two')) {
            if (!secondParsed.isCompleted) secondParsed.complete();
            return const AnnouncementSearchColumnPage([], null);
          }
          return AnnouncementSearchColumnPage([
            for (var index = 0; index < 12; index++)
              AnnouncementListItem(
                  title: 'plain', url: 'https://body$index.test/article'),
          ], 'https://list.test/two');
        },
        body: (_) async {
          activeBodies++;
          if (activeBodies == expectedBody && !saturated.isCompleted) {
            saturated.complete();
          }
          await bodyGate.future;
          activeBodies--;
          return '';
        },
      ),
    );
    final run = service.startSearch(
      query: 'target',
      includeBody: true,
      fast: true,
      strength: 5,
      batchPause: Duration.zero,
    );
    try {
      await saturated.future.timeout(const Duration(seconds: 3));
      await secondParsed.future.timeout(const Duration(seconds: 3));
      expect(bodyGate.isCompleted, isFalse);
      expect(activeBodies, expectedBody);
    } finally {
      bodyGate.complete();
      expect((await run.finished).isComplete, isTrue);
      service.dispose();
    }
  });
}
