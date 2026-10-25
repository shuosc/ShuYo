import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_search_worker.dart';

AnnouncementSource _source(HttpServer server) => AnnouncementSource(
      id: 'local-worker-test',
      name: '本地测试栏目',
      listUrl: 'http://127.0.0.1:${server.port}/list',
      adapter: const AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    );

Future<void> _respond(HttpRequest request, String html,
    {int statusCode = HttpStatus.ok}) async {
  request.response.statusCode = statusCode;
  request.response.headers.contentType = ContentType.html;
  request.response.write(html);
  await request.response.close();
}

void main() {
  test('worker sends article matches and a finished progress', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) => _respond(request,
        '<div class="only-list"><ul><li><a href="/article">目标标题</a></li></ul></div>'));
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    final run = service.startSearch(
      query: '目标',
      sources: [_source(server)],
      retryFailures: false,
    );
    final updates = <String>[];
    final subscription = run.updates.listen((progress) {
      updates.add(progress.isFinished ? 'finished' : 'running');
    });
    addTearDown(subscription.cancel);
    final finalProgress =
        await run.finished.timeout(const Duration(seconds: 10));
    expect(finalProgress.isComplete, isTrue);
    expect(finalProgress.matchedArticles, 1);
    expect(finalProgress.newMatches.single.title, '目标标题');
    await Future<void>.delayed(Duration.zero);
    expect(updates, isNotEmpty);
    expect(updates.last, 'finished');
  });

  test('worker cancels a pending request without blocking the caller',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      try {
        await _respond(request,
            '<div class="only-list"><li><a href="/article">目标</a></li></div>');
      } on Object {
        // Cancelling the request can close the socket first.
      }
    });
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    final run = service.startSearch(
      query: '目标',
      sources: [_source(server)],
      retryFailures: false,
    );
    await entered.future.timeout(const Duration(seconds: 10));
    run.cancel();
    final finalProgress =
        await run.finished.timeout(const Duration(seconds: 1));
    expect(finalProgress.isFinished, isTrue);
    expect(finalProgress.isComplete, isFalse);
    release.complete();
  });

  test('worker finishes failed pages and remains available for a new search',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var fail = true;
    server.listen((request) => _respond(
          request,
          fail
              ? ''
              : '<div class="only-list"><li><a href="/article">目标标题</a></li></div>',
          statusCode: fail ? HttpStatus.serviceUnavailable : HttpStatus.ok,
        ));
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    final run = service.startSearch(
      query: '目标',
      sources: [_source(server)],
      retryFailures: false,
    );
    final finalStates = <bool>[];
    final subscription = run.updates.listen((progress) {
      if (progress.isFinished) finalStates.add(progress.isComplete);
    });
    addTearDown(subscription.cancel);
    final first = await run.finished.timeout(const Duration(seconds: 10));
    expect(first.isComplete, isFalse);
    expect(first.unfinishedCount, 1);
    expect(run.canResume, isFalse);

    fail = false;
    final second = await service
        .startSearch(
          query: '目标',
          sources: [_source(server)],
          retryFailures: false,
        )
        .finished
        .timeout(const Duration(seconds: 10));
    expect(second.isComplete, isTrue);
    expect(second.matchedArticles, 1);
    await Future<void>.delayed(Duration.zero);
    expect(finalStates, [false]);
  });

  test('worker reports terminal parse failures separately from timeouts',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var invalid = true;
    var requests = 0;
    server.listen((request) async {
      requests++;
      await _respond(
        request,
        invalid
            ? '<html><body>unexpected layout</body></html>'
            : '<div class="only-list"><li><a href="/article">目标标题</a></li></div>',
      );
    });
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    final first = await service
        .startSearch(
          query: '目标',
          sources: [_source(server)],
          retryFailures: true,
        )
        .finished
        .timeout(const Duration(seconds: 10));
    expect(first.isFinished, isTrue);
    expect(first.isComplete, isFalse);
    expect(first.parseFailureCount, 1);
    expect(first.timeoutFailureCount, 0);
    expect(first.failedPages, 1);
    expect(requests, 1);

    invalid = false;
    final second = await service
        .startSearch(
          query: '目标',
          sources: [_source(server)],
          retryFailures: true,
        )
        .finished
        .timeout(const Duration(seconds: 10));
    expect(second.isComplete, isTrue);
    expect(second.parseFailureCount, 0);
    expect(second.matchedArticles, 1);
  });

  test('one worker keeps parsed article text for a later query', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var articleRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/article') {
        articleRequests++;
        await _respond(
            request, '<div class="v_news_content">第一个关键词 第二个关键词</div>');
      } else {
        await _respond(request,
            '<div class="only-list"><li><a href="/article">普通公告</a></li></div>');
      }
    });
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    for (final query in ['第一个', '第二个']) {
      final run = service.startSearch(
        query: query,
        includeBody: true,
        sources: [_source(server)],
        retryFailures: false,
      );
      final result = await run.finished.timeout(const Duration(seconds: 10));
      expect(result.isComplete, isTrue);
      expect(result.matchedArticles, 1);
    }
    expect(articleRequests, 1);
  });

  test('ALL body search preserves every department without extra requests',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestedPaths = <String>[];
    server.listen((request) async {
      final path = request.uri.path;
      requestedPaths.add(path);
      if (path.startsWith('/list/')) {
        final id = path.split('/').last;
        await _respond(
            request,
            '<div class="only-list"><ul>'
            '<li><a href="/article/title/$id">目标标题 $id</a></li>'
            '<li><a href="/article/body/$id">普通公告 $id</a></li>'
            '</ul></div>');
      } else if (path.startsWith('/article/body/')) {
        await _respond(request, '<div class="v_news_content">正文包含目标词</div>');
      } else {
        await _respond(request, 'unexpected', statusCode: HttpStatus.notFound);
      }
    });
    final sources = [
      for (var index = 0; index < 64; index++)
        AnnouncementSource(
          id: 'worker-$index',
          name: '部门 $index',
          listUrl: 'http://127.0.0.1:${server.port}/list/$index',
          adapter: const AnnouncementSourceAdapter(
              listFormat: AnnouncementListFormat.onlyList),
        ),
    ];
    final service = AnnouncementSearchWorkerService();
    addTearDown(service.dispose);
    final run = service.startSearch(
      query: '目标',
      includeBody: true,
      strength: 5,
      fast: true,
      sources: sources,
      retryFailures: false,
    );
    final matches = <String>{};
    final subscription = run.updates.listen((progress) {
      matches.addAll(progress.newMatches.map((item) => item.sourceId));
    });
    addTearDown(subscription.cancel);
    final result = await run.finished.timeout(const Duration(seconds: 20));
    expect(result.isComplete, isTrue);
    expect(result.completedPages, 64);
    expect(result.matchedArticles, 128);
    expect(matches, {for (final source in sources) source.id});
    expect(requestedPaths.where((path) => path.startsWith('/list/')),
        hasLength(64));
    expect(requestedPaths.where((path) => path.startsWith('/article/body/')),
        hasLength(64));
    expect(requestedPaths, hasLength(128));
  });
}
