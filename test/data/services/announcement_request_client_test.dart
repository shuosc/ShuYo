import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';
import 'package:shuyo/data/services/announcement_request_client.dart';

void main() {
  test('metadata stops a chunked export immediately after its header',
      () async {
    var cancelled = false;
    var aborted = false;
    final body = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final network = _HandlerClient((request, _) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return http.StreamedResponse(body.stream, 200,
          request: request,
          headers: {'content-type': 'application/octet-stream'});
    });
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    var completed = false;
    final response = client
        .getMetadataPrefix('https://a.test/export',
            isComplete: (bytes) => utf8.decode(bytes).endsWith('</header>'))
        .then((value) {
      completed = true;
      return value;
    });
    await _flush();
    body.add(utf8.encode('<header>2026-10-26'));
    await _flush();
    expect(completed, isFalse);
    body.add(utf8.encode('</header>'));
    await _flush();
    expect((await response).body, '<header>2026-10-26</header>');
    expect(cancelled, isTrue);
    expect(aborted, isTrue);
    body.add(List.filled(1024 * 1024, 65));
    await body.close();
  });

  test(
      'metadata bounds oversized chunks and does not cache incomplete '
      'prefixes', () async {
    final network = _HandlerClient((request, _) async => _response(
          request,
          '0123456789',
          headers: {'content-type': 'application/msword'},
        ));
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await client.getMetadataPrefix(
        'https://a.test/export',
        isComplete: (_) => false,
        maxBytes: 5,
      );
      expect(response.body, '01234');
    }
    expect(network.requests, hasLength(2));
  });

  test('metadata deduplicates, caches and stays isolated from full HTML',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    bool complete(List<int> bytes) => bytes.isNotEmpty;
    const url = 'https://a.test/shared';
    final first = client.getMetadataPrefix('$url#one', isComplete: complete);
    final second = client.getMetadataPrefix('$url#two', isComplete: complete);
    expect(network.requests, hasLength(1));
    expect(network.requests.single.url.toString(), url);
    network.complete(0, 'metadata');
    expect((await first).body, 'metadata');
    expect((await second).body, 'metadata');
    final full = client.get(url, priority: AnnouncementRequestPriority.detail);
    expect(network.requests, hasLength(2));
    network.complete(1, 'complete HTML document');
    expect((await full).body, 'complete HTML document');
    expect((await client.getMetadataPrefix(url, isComplete: complete)).body,
        'metadata');
    expect(
        (await client.get(url, priority: AnnouncementRequestPriority.detail))
            .body,
        'complete HTML document');
    expect(network.requests, hasLength(2));
  });

  test('metadata timeout cancels a body that never finishes', () async {
    var cancelled = false;
    var aborted = false;
    final body = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final network = _HandlerClient((request, _) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return http.StreamedResponse(body.stream, 200,
          headers: {'content-type': 'application/msword'});
    });
    final client = AnnouncementRequestClient(
      httpClient: network,
      requestTimeout: const Duration(milliseconds: 15),
      maxAttempts: 1,
    );
    addTearDown(client.close);
    final result = expectLater(
        client.getMetadataPrefix('https://a.test/export',
            isComplete: (_) => false),
        throwsA(isA<TimeoutException>()));
    await result;
    expect(cancelled, isTrue);
    expect(aborted, isTrue);
    await body.close();
  });

  test('metadata refresh does not reuse or cache an older prefix', () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    bool complete(List<int> bytes) => bytes.isNotEmpty;
    const url = 'https://a.test/export';
    final old = client.getMetadataPrefix(url, isComplete: complete);
    client.clearResponseCache();
    final fresh = client.getMetadataPrefix(url, isComplete: complete);
    expect(network.requests, hasLength(2));
    network.complete(0, 'old');
    expect((await old).body, 'old');
    final duplicate = client.getMetadataPrefix(url, isComplete: complete);
    expect(network.requests, hasLength(2));
    network.complete(1, 'fresh');
    expect((await fresh).body, 'fresh');
    expect((await duplicate).body, 'fresh');
    expect((await client.getMetadataPrefix(url, isComplete: complete)).body,
        'fresh');
    expect(network.requests, hasLength(2));
  });

  test('fragment variants share transport while consumers parse separately',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    final first = client.withResponse(
      'https://a.test/list.htm#first',
      (response) async => 'college:${response.body}',
    );
    final second = client.withResponse(
      'https://a.test/list.htm#second',
      (response) async => 'department:${response.body}',
    );
    expect(network.requests, hasLength(1));
    expect(network.requests.single.url.fragment, isEmpty);
    expect(network.requests.single.url.toString(), 'https://a.test/list.htm');
    network.releaseAll('shared');
    expect(await first, 'college:shared');
    expect(await second, 'department:shared');
  });

  test('list requests bypass response cache while details reuse and expire',
      () async {
    var now = DateTime(2026, 10, 25);
    final network = _HandlerClient(
        (request, count) async => _response(request, 'version $count'));
    final client = AnnouncementRequestClient(
      httpClient: network,
      now: () => now,
    );
    addTearDown(client.close);
    const url = 'https://a.test/page.htm';
    expect((await client.get(url)).body, 'version 1');
    expect((await client.get(url)).body, 'version 2');
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 3',
    );
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 3',
    );
    expect((await client.get(url)).body, 'version 4');
    now = now.add(const Duration(minutes: 5));
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 5',
    );
  });

  test('failed in-flight requests are removed and can be requested again',
      () async {
    final network = _HandlerClient((request, count) async {
      if (count == 1) throw StateError('failed');
      return _response(request, 'recovered');
    });
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    await expectLater(client.get('https://a.test/one'), throwsStateError);
    expect((await client.get('https://a.test/one')).body, 'recovered');
    expect(network.requests, hasLength(2));
  });

  test('parse failures evict downloaded HTML before a later retry', () async {
    final network = _HandlerClient(
        (request, count) async => _response(request, 'version $count'));
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    const url = 'https://a.test/detail';
    await expectLater(
      client.withResponse<void>(
        url,
        (_) async => throw StateError('broken article'),
        priority: AnnouncementRequestPriority.detail,
      ),
      throwsStateError,
    );
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 2',
    );
  });

  test('a parse failure from before refresh keeps the refreshed HTML cache',
      () async {
    final network = _HandlerClient(
        (request, count) async => _response(request, 'version $count'));
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    const url = 'https://a.test/detail';
    final parsing = Completer<void>();
    final parseGate = Completer<void>();
    final old = expectLater(
      client.withResponse<void>(
        url,
        (_) async {
          parsing.complete();
          await parseGate.future;
          throw StateError('old article parse failed');
        },
        priority: AnnouncementRequestPriority.detail,
      ),
      throwsStateError,
    );
    await parsing.future;
    client.clearResponseCache();
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 2',
    );
    parseGate.complete();
    await old;
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'version 2',
    );
    expect(network.requests, hasLength(2));
  });

  test('network and host limits reserve capacity and prioritize list pages',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(
      httpClient: network,
      maxConcurrentRequests: 3,
      maxConcurrentRequestsPerHost: 2,
    );
    addTearDown(client.close);
    final requests = <Future<http.Response>>[
      client.get('https://a.test/detail1',
          priority: AnnouncementRequestPriority.detail),
      client.get('https://a.test/detail2',
          priority: AnnouncementRequestPriority.detail),
      client.get('https://b.test/detail',
          priority: AnnouncementRequestPriority.detail),
      client.get('https://c.test/detail',
          priority: AnnouncementRequestPriority.detail),
      client.get('https://a.test/list'),
      client.get('https://b.test/list'),
    ];
    expect(network.requests.map((request) => request.url.toString()), [
      'https://a.test/detail1',
      'https://b.test/detail',
      'https://a.test/list',
    ]);
    network.complete(2, 'first list');
    await _flush();
    expect(network.requests.last.url.toString(), 'https://b.test/list');
    expect(network.requests, hasLength(4));
    network.releaseAll();
    await Future.wait(requests);
  });

  test('default host limit preserves three previews and a list request',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(httpClient: network);
    addTearDown(client.close);
    final requests = [
      for (var index = 0; index < 4; index++)
        client.get('https://a.test/detail$index',
            priority: AnnouncementRequestPriority.detail),
      client.get('https://a.test/list'),
    ];
    expect(network.requests.map((request) => request.url.path), [
      '/detail0',
      '/detail1',
      '/detail2',
      '/list',
    ]);
    network.releaseAll();
    await Future.wait(requests);
  });

  test('a queued detail upgraded to list immediately uses reserved capacity',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(
      httpClient: network,
      maxConcurrentRequestsPerHost: 2,
    );
    addTearDown(client.close);
    final first = client.get('https://a.test/detail',
        priority: AnnouncementRequestPriority.detail);
    final second = client.get('https://a.test/shared',
        priority: AnnouncementRequestPriority.detail);
    expect(network.requests, hasLength(1));
    final list = client.get('https://a.test/shared');
    expect(network.requests, hasLength(2));
    expect(network.requests.last.url.path, '/shared');
    network.releaseAll();
    await Future.wait([first, second, list]);
  });

  test('response parse backlog pauses further network admission', () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(
      httpClient: network,
      maxConcurrentRequests: 1,
      maxPendingResponses: 1,
      maxPendingResponseBytes: 1,
    );
    addTearDown(client.close);
    final parsing = Completer<void>();
    final parseGate = Completer<void>();
    final first = client.withResponse('https://a.test/one', (response) async {
      parsing.complete();
      await parseGate.future;
      return response.body;
    });
    network.complete(0, 'larger than budget');
    await parsing.future;
    final second = client.get('https://b.test/two');
    await _flush();
    expect(network.requests, hasLength(1));
    parseGate.complete();
    expect(await first, 'larger than budget');
    await _flush();
    expect(network.requests, hasLength(2));
    network.releaseAll();
    await second;
  });

  test('request timeout triggers the underlying AbortableRequest', () async {
    var aborted = false;
    final network = _HandlerClient((request, _) {
      expect(request, isA<http.AbortableRequest>());
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return Completer<http.StreamedResponse>().future;
    });
    final client = AnnouncementRequestClient(
      httpClient: network,
      requestTimeout: const Duration(milliseconds: 15),
      operationTimeout: const Duration(milliseconds: 100),
      maxAttempts: 1,
    );
    addTearDown(client.close);
    await expectLater(
        client.get('https://a.test/slow'), throwsA(isA<TimeoutException>()));
    expect(aborted, isTrue);
  });

  test('timeout includes a response body that stops producing bytes', () async {
    var aborted = false;
    final body = StreamController<List<int>>();
    final network = _HandlerClient((request, _) async {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
        unawaited(body.close());
      });
      return http.StreamedResponse(body.stream, 200);
    });
    final client = AnnouncementRequestClient(
      httpClient: network,
      requestTimeout: const Duration(milliseconds: 15),
      maxAttempts: 1,
    );
    addTearDown(client.close);
    await expectLater(client.get('https://a.test/slow-body'),
        throwsA(isA<TimeoutException>()));
    expect(aborted, isTrue);
  });

  testWidgets(
      'close aborts active work and clears timers without owning client',
      (tester) async {
    var aborted = false;
    final network = _HandlerClient((request, _) {
      (request as http.AbortableRequest).abortTrigger!.then((_) {
        aborted = true;
      });
      return Completer<http.StreamedResponse>().future;
    });
    final client = AnnouncementRequestClient(
      httpClient: network,
      ownsHttpClient: false,
      maxConcurrentRequests: 1,
    );
    final first =
        expectLater(client.get('https://a.test/one'), throwsStateError);
    final second =
        expectLater(client.get('https://b.test/two'), throwsStateError);
    expect(network.requests, hasLength(1));
    client.close();
    await Future.wait([first, second]);
    expect(aborted, isTrue);
    expect(network.closeCount, 0);
    await expectLater(client.get('https://c.test/three'), throwsStateError);
  });

  for (final responseCase in [
    (status: 404, contentType: 'text/html'),
    (status: 200, contentType: 'application/pdf'),
    (status: 200, contentType: 'application/msword'),
  ]) {
    test(
        'headers stop unreadable ${responseCase.status} '
        '${responseCase.contentType} response bodies', () async {
      var cancelled = false;
      var aborted = false;
      final body = StreamController<List<int>>(onCancel: () {
        cancelled = true;
      });
      final network = _HandlerClient((request, _) async {
        (request as http.AbortableRequest).abortTrigger!.then((_) {
          aborted = true;
        });
        return http.StreamedResponse(
          body.stream,
          responseCase.status,
          headers: {
            'content-type': responseCase.contentType,
            'retry-after': '1',
            'x-server': 'kept',
          },
          reasonPhrase: 'original reason',
          request: request,
        );
      });
      final client = AnnouncementRequestClient(httpClient: network);
      addTearDown(client.close);
      final response = await client.get('https://a.test/unneeded');
      expect(response.statusCode, responseCase.status);
      expect(response.headers['x-server'], 'kept');
      expect(response.headers['retry-after'], '1');
      expect(response.reasonPhrase, 'original reason');
      expect(response.bodyBytes, isEmpty);
      expect(cancelled, isTrue);
      expect(aborted, isTrue);
      await body.close();
    });
  }

  test('transient responses retry finitely and release network slots',
      () async {
    final paths = <String, int>{};
    final network = _HandlerClient((request, _) async {
      final count = paths.update(request.url.path, (value) => value + 1,
          ifAbsent: () => 1);
      return _response(request, 'body',
          status: request.url.path == '/recover' && count == 2 ? 200 : 503);
    });
    final client = AnnouncementRequestClient(
      httpClient: network,
      retryBaseDelay: const Duration(milliseconds: 2),
      maxAttempts: 2,
    );
    addTearDown(client.close);
    expect((await client.get('https://a.test/recover')).statusCode, 200);
    expect(paths['/recover'], 2);
    expect((await client.get('https://a.test/fail')).statusCode, 503);
    expect(paths['/fail'], 2);
  });

  test('Retry-After cooling does not block other hosts or wait indefinitely',
      () async {
    final network = _HandlerClient((request, _) async => _response(
          request,
          'body',
          status: request.url.host == 'a.test' ? 429 : 200,
          headers: {'retry-after': '1'},
        ));
    final client = AnnouncementRequestClient(
      httpClient: network,
      operationTimeout: const Duration(milliseconds: 80),
      maxConcurrentRequests: 1,
    );
    addTearDown(client.close);
    expect((await client.get('https://a.test/rate-limited')).statusCode, 429);
    final cooling = expectLater(
        client.get('https://a.test/another'), throwsA(isA<TimeoutException>()));
    expect((await client.get('https://b.test/available')).statusCode, 200);
    await cooling;
    expect(network.requests, hasLength(2));
  });

  test('refresh generation rejects stale cache writes and in-flight cleanup',
      () async {
    final network = _GatedClient();
    final client = AnnouncementRequestClient(
      httpClient: network,
      maxConcurrentRequestsPerHost: 3,
    );
    addTearDown(client.close);
    const url = 'https://a.test/detail';
    final old = client.get(url, priority: AnnouncementRequestPriority.detail);
    client.clearResponseCache();
    final fresh = client.get(url, priority: AnnouncementRequestPriority.detail);
    expect(network.requests, hasLength(2));
    network.complete(0, 'old');
    expect((await old).body, 'old');
    final sameFresh =
        client.get(url, priority: AnnouncementRequestPriority.detail);
    expect(network.requests, hasLength(2));
    network.complete(1, 'fresh');
    expect((await fresh).body, 'fresh');
    expect((await sameFresh).body, 'fresh');
    expect(
      (await client.get(url, priority: AnnouncementRequestPriority.detail))
          .body,
      'fresh',
    );
    expect(network.requests, hasLength(2));
  });

  test('ordinary details preserve 404 and 410 unavailable semantics', () async {
    final network = _HandlerClient((request, _) async => _response(
          request,
          '',
          status: int.parse(request.url.path.substring(1)),
        ));
    final api = AnnouncementApiClient(httpClient: network);
    addTearDown(api.close);
    for (final status in [404, 410]) {
      await expectLater(
        api.fetchDetail(AnnouncementListItem(
            title: 'missing', url: 'https://a.test/$status')),
        throwsA(isA<AnnouncementUnavailableException>().having(
          (error) => error.statusCode,
          'statusCode',
          status,
        )),
      );
    }
  });

  test('ordinary details detect HTML unavailable responses in parsing',
      () async {
    final network = _HandlerClient((request, _) async => _response(
          request,
          '<title>404错误提示</title><body>系统提示：您访问的页面未找到</body>',
        ));
    final api = AnnouncementApiClient(httpClient: network);
    addTearDown(api.close);
    await expectLater(
      api.fetchDetail(const AnnouncementListItem(
          title: 'missing', url: 'https://a.test/missing')),
      throwsA(isA<AnnouncementUnavailableException>()),
    );
  });

  test('film metadata and ordinary detail reuse a single article download',
      () async {
    final source = AnnouncementSource.byId('sfa');
    final network = _HandlerClient((request, _) async => _response(
          request,
          request.url.path.contains('/info/')
              ? '<span class="Head">电影通知</span>'
                  '<table><tr valign="middle" height="20"><td>'
                  '<span>创建时间：</span><span>2026年10月20日 08:00</span>'
                  '</td></tr></table>'
                  '<div class="v_news_content"><p>电影正文</p></div>'
              : '<div class="right"><li class="notice-item">'
                  '<a class="notice-title" href="/info/1212/one.htm">电影通知</a>'
                  '</li></div>',
        ));
    final api = AnnouncementApiClient(httpClient: network);
    addTearDown(api.close);
    final page = await api.fetchPage(source: source);
    expect(page.items.single.publishedAt, isNull);
    expect(network.requests, hasLength(1));
    final dated = await api.fetchPublicationDate(page.items.single);
    expect(dated!.publishedAt, DateTime(2026, 10, 20));
    final detail = await api.fetchDetail(page.items.single);
    expect(detail.blocks.single.value, '电影正文');
    expect(
        network.requests
            .where((request) => request.url.path.contains('/info/')),
        hasLength(1));
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

http.StreamedResponse _response(
  http.BaseRequest request,
  String body, {
  int status = 200,
  Map<String, String>? headers,
}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
      headers: {'content-type': 'text/html; charset=utf-8', ...?headers},
    );

class _HandlerClient extends http.BaseClient {
  _HandlerClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest, int) handler;
  final List<http.BaseRequest> requests = [];
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request, requests.length);
  }

  @override
  void close() => closeCount++;
}

class _GatedClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final List<Completer<http.StreamedResponse>> _gates = [];
  bool _autoComplete = false;
  String _body = 'body';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    final gate = Completer<http.StreamedResponse>();
    _gates.add(gate);
    if (_autoComplete) gate.complete(_response(request, _body));
    return gate.future;
  }

  void complete(int index, String body) {
    _gates[index].complete(_response(requests[index], body));
  }

  void releaseAll([String body = 'body']) {
    _body = body;
    _autoComplete = true;
    for (var index = 0; index < _gates.length; index++) {
      if (!_gates[index].isCompleted) complete(index, body);
    }
  }
}
