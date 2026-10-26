import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

const _url = 'https://utseus.shu.edu.cn/info/1010/6186.htm';
const _item = AnnouncementListItem(
    title: 'Pipeline notice', url: _url, sourceId: 'utseus');

String _article(String text,
        {int tree = 1010, int news = 6186, int owner = 1430791623}) =>
    '<meta name="pageTitle" content="Pipeline notice">'
    '<script>_jsq_($tree,\'/content.jsp\',$news,$owner)</script>'
    '<div class="nry"><h1>Pipeline notice</h1>'
    '<div class="v_news_content"><p>$text</p></div></div>';

String _export() => 'Mime-Version: 1.0\r\n'
    'Content-Type: multipart/related; boundary="metadata"\r\n\r\n'
    '--metadata\r\nContent-Type: text/html; charset=UTF-8\r\n'
    'Content-Transfer-Encoding: quoted-printable\r\n\r\n'
    '<div align="center"><p><h1>Pipeline notice</h1></p>'
    ' Author 2026-09-18 10:00:36 Department </div>';

AnnouncementListItem _listedFrom(String sourceId) => AnnouncementListItem(
    title: _item.title, url: _item.url, sourceId: sourceId);

void main() {
  test(
      'preview and date share one original request across lists without waiting for export',
      () async {
    final network = _ControlledClient();
    final api = _api(network);
    var dateCompleted = false;
    final preview = api.fetchPreview(_item);
    final dated = api.fetchPublicationDate(_listedFrom('sfa')).then((value) {
      dateCompleted = true;
      return value;
    });
    await _until(() => network.requests.length == 1);
    network.requests.single.complete(_article('立即取得的概览'));

    expect(await preview.timeout(const Duration(seconds: 3)), '立即取得的概览');
    await _until(() => network.requests.length == 2);
    expect(network.requests.last.isExport, isTrue);
    expect(dateCompleted, isFalse);
    network.requests.last.complete(_export());

    final resolved = await dated;
    expect(resolved!.dateText, '2026-09-18');
    expect(resolved.sourceId, 'sfa');
    expect(resolved.url, _url);
    expect(await api.fetchPreview(_listedFrom('bkzsw')), '立即取得的概览');
    expect((await api.fetchPublicationDate(_item))!.dateText, '2026-09-18');
    expect(network.requests, hasLength(2));
  });

  test(
      'list fields avoid network and a summary-only request never starts an export',
      () async {
    final network = _ControlledClient();
    final api = _api(network);
    final complete = AnnouncementListItem(
        title: _item.title,
        url: _url,
        sourceId: 'utseus',
        summary: '列表现有概览',
        dateText: '2026-09-18',
        publishedAt: DateTime(2026, 9, 18));
    expect(await api.fetchPreview(complete), '列表现有概览');
    expect(await api.fetchPublicationDate(complete), same(complete));
    expect(network.requests, isEmpty);

    final preview = api.fetchPreview(_item);
    await _until(() => network.requests.isNotEmpty);
    network.requests.single.complete(_article('仅提取原文概览'));
    expect(await preview, '仅提取原文概览');
    expect(await api.fetchPreview(_listedFrom('sfa')), '仅提取原文概览');
    expect(network.requests, hasLength(1));
    expect(network.requests.single.isExport, isFalse);
  });

  test(
      'scoped invalidation rejects stale writes and keeps unrelated source caches',
      () async {
    final network = _ControlledClient();
    final api = _api(network);
    const other = AnnouncementListItem(
        title: 'Other source',
        url: 'https://hr.shu.edu.cn/info/1001/111.htm',
        sourceId: 'hr');
    final otherPreview = api.fetchPreview(other);
    await _until(() => network.requests.length == 1);
    network.requests[0].complete(_article('其他来源缓存'));
    expect(await otherPreview, '其他来源缓存');

    final stale = api.fetchPreview(_item);
    await _until(() => network.requests.length == 2);
    api.invalidateArticles(['$_url#refresh']);
    final fresh = api.fetchPreview(_item);
    await _until(() => network.requests.length == 3);
    network.requests[2].complete(_article('刷新后的概览'));
    expect(await fresh, '刷新后的概览');
    network.requests[1].complete(_article('过期的概览'));
    expect(await stale, '过期的概览');

    expect(await api.fetchPreview(_item), '刷新后的概览');
    expect(await api.fetchPreview(other), '其他来源缓存');
    expect(network.requests, hasLength(3));
  });

  test(
      'optional cancellation removes queued and reading work without negative caching',
      () async {
    final network = _ControlledClient();
    final api = _api(network);
    final items = List.generate(
        4,
        (index) => AnnouncementListItem(
            title: 'Queued $index',
            url: 'https://utseus.shu.edu.cn/info/1010/${6200 + index}.htm',
            sourceId: 'utseus'));
    final previews = items.map(api.fetchPreview).toList();
    await _until(() => network.requests.length == 3);
    api.cancelOptionalArticle(items[3].url);
    expect(await previews[3], isNull);
    expect(
        network.requests
            .any((request) => request.request.url.toString() == items[3].url),
        isFalse);
    api.cancelOptionalArticle(items[0].url);
    expect(await previews[0], isNull);
    expect(network.requests[0].aborted, isTrue);

    final readingRetry = api.fetchPreview(items[0]);
    await _until(() => network.requests.length == 4);
    network.requests[3].complete(_article('取消后立即重试成功'));
    expect(await readingRetry, '取消后立即重试成功');
    final queuedRetry = api.fetchPreview(items[3]);
    await _until(() => network.requests.length == 5);
    network.requests[4].complete(_article('原队列任务重新加载成功'));
    expect(await queuedRetry, '原队列任务重新加载成功');
    for (var index = 1; index < 3; index++) {
      network.requests[index].complete(_article('其余公告'));
      expect(await previews[index], '其余公告');
    }
  });

  test(
      'a detail reader protects the shared original and export from card cancellation',
      () async {
    final network = _ControlledClient();
    final api = _api(network);
    final preview = api.fetchPreview(_item);
    final detail = api.fetchDetail(_item);
    await _until(() => network.requests.length == 1);
    api.cancelOptionalArticle(_url);
    expect(network.requests.single.aborted, isFalse);
    network.requests.single.complete(_article('详情与卡片共用原文'));
    await _until(() => network.requests.length == 2);
    api.cancelOptionalArticle(_url);
    expect(network.requests.last.aborted, isFalse);
    network.requests.last.complete(_export());

    expect(await preview, '详情与卡片共用原文');
    final resolved = await detail;
    expect(resolved.blocks.single.value, '详情与卡片共用原文');
    expect(resolved.dateText, '2026-09-18');
    expect(resolved.author, 'Author');
    expect(network.requests, hasLength(2));
  });

  test(
      'failed optional work cools down for 15 seconds and explicit refresh retries immediately',
      () async {
    var now = DateTime(2026, 10, 27);
    var fail = true;
    var originals = 0;
    var exports = 0;
    final api = AnnouncementApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path.contains('newstoword')) {
            exports++;
            return http.Response(_export(), 200,
                headers: {'content-type': 'application/msword'});
          }
          originals++;
          return http.Response(fail ? '' : _article('恢复后的概览'), fail ? 404 : 200,
              headers: {'content-type': 'text/html; charset=utf-8'});
        }),
        now: () => now,
        maxRequestAttempts: 1,
        retryBaseDelay: Duration.zero);
    addTearDown(api.close);
    final failed = await Future.wait<Object?>(
        [api.fetchPreview(_item), api.fetchPublicationDate(_item)]);
    expect(failed, [null, null]);
    fail = false;
    now = now.add(const Duration(seconds: 14));
    expect(await api.fetchPreview(_item), isNull);
    expect(await api.fetchPublicationDate(_item), isNull);
    expect(originals, 1);
    now = now.add(const Duration(seconds: 2));
    expect(await api.fetchPreview(_item), '恢复后的概览');
    expect((await api.fetchPublicationDate(_item))!.dateText, '2026-09-18');
    expect(originals, 2);
    expect(exports, 1);

    api.invalidateArticles([_url]);
    fail = true;
    expect(await api.fetchPreview(_item), isNull);
    fail = false;
    api.clearResponseCache();
    expect((await api.fetchPublicationDate(_item))!.dateText, '2026-09-18');
    expect(originals, 4);
    expect(exports, 2);
  });

  test('close settles pending consumers and aborts active transport', () async {
    final network = _ControlledClient();
    final api = _api(network);
    const other = AnnouncementListItem(
        title: 'Detail',
        url: 'https://hr.shu.edu.cn/info/1001/111.htm',
        sourceId: 'hr');
    final preview = api.fetchPreview(_item);
    final metadata = api.fetchPublicationDate(_item);
    final detail =
        expectLater(api.fetchDetail(other), throwsA(isA<StateError>()));
    await _until(() => network.requests.length == 2);
    api.close();
    expect(await preview, isNull);
    expect(await metadata, isNull);
    await detail;
    expect(network.requests.every((request) => request.aborted), isTrue);
    expect(network.closed, 1);
    expect(await api.fetchPreview(_item), isNull);
    expect(network.requests, hasLength(2));
  });

  test(
      'an invalid export title is retried after cooldown without downloading original HTML again',
      () async {
    var now = DateTime(2026, 10, 27);
    var validExport = false;
    var originals = 0;
    var exports = 0;
    final api = AnnouncementApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path.contains('newstoword')) {
            exports++;
            return http.Response(
                validExport
                    ? _export()
                    : _export()
                        .replaceAll('Pipeline notice', 'Unrelated article'),
                200,
                headers: {'content-type': 'application/msword'});
          }
          originals++;
          return http.Response(_article('有效原文'), 200,
              headers: {'content-type': 'text/html; charset=utf-8'});
        }),
        now: () => now,
        maxRequestAttempts: 1,
        retryBaseDelay: Duration.zero);
    addTearDown(api.close);

    expect(await api.fetchPublicationDate(_item), isNull);
    validExport = true;
    now = now.add(const Duration(seconds: 14));
    expect(await api.fetchPublicationDate(_item), isNull);
    expect(exports, 1);
    now = now.add(const Duration(seconds: 2));
    expect((await api.fetchPublicationDate(_item))?.dateText, '2026-09-18');
    expect(originals, 1);
    expect(exports, 2);
  });

  test(
      'redirected articles use the final site for metadata, body and relative assets',
      () async {
    for (final vancouver in [false, true]) {
      final finalUrl = vancouver
          ? 'https://www.shvfs.cn/site/newsDetail/1624'
          : 'https://www.shu.edu.cn/info/1051/402205.htm';
      final requests = <http.BaseRequest>[];
      final network = _RedirectingClient((request) {
        requests.add(request);
        if (request.url.path.contains('newstoword')) {
          return http.StreamedResponse(
              Stream.value(utf8.encode(_export())), 200,
              headers: {'content-type': 'application/msword'},
              request: request);
        }
        final html = vancouver
            ? '<header class="n-detail-title"><h2>Pipeline notice</h2>'
                '<p>时间：2026-09-18</p></header>'
                '<div class="news-detail-infowrap"><p>真实落地正文</p>'
                '<img src="/uploads/photo.jpg"></div>'
            : _article('真实落地正文<img src="/uploads/photo.jpg">',
                tree: 1051, news: 402205, owner: 1864855249);
        return _FinalUrlResponse(
            Stream.value(utf8.encode(html)), Uri.parse(finalUrl),
            request: request);
      });
      final api = _api(network);
      const listed = AnnouncementListItem(
          title: 'Pipeline notice',
          url: 'https://sfa.shu.edu.cn/info/1212/44034.htm',
          sourceId: 'sfa');
      final dated = await api.fetchPublicationDate(listed);
      final detail = await api.fetchDetail(listed);
      expect(dated!.sourceId, 'sfa');
      expect(dated.url, listed.url);
      expect(dated.dateText, '2026-09-18');
      expect(detail.url, finalUrl);
      expect(detail.blocks.firstWhere((block) => block.isText).value, '真实落地正文');
      expect(detail.blocks.singleWhere((block) => block.isImage).value,
          '${Uri.parse(finalUrl).origin}/uploads/photo.jpg');
      final metadataRequests =
          requests.where((request) => request.url.path.contains('newstoword'));
      if (vancouver) {
        expect(metadataRequests, isEmpty);
      } else {
        expect(metadataRequests.single.url.host, 'www.shu.edu.cn');
        expect(metadataRequests.single.url.queryParameters,
            {'treeid': '1051', 'owner': '1864855249', 'wbnewsid': '402205'});
        expect(detail.department, 'Department');
      }
      expect(
          requests.where((request) => !request.url.path.contains('newstoword')),
          hasLength(1));
    }
  });
}

AnnouncementApiClient _api(http.Client network) {
  final api = AnnouncementApiClient(
      httpClient: network,
      maxRequestAttempts: 1,
      retryBaseDelay: Duration.zero);
  addTearDown(api.close);
  return api;
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Pipeline did not progress');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _ControlledClient extends http.BaseClient {
  final List<_PendingResponse> requests = [];
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final pending = _PendingResponse(request);
    requests.add(pending);
    return http.StreamedResponse(pending.body.stream, 200,
        request: request,
        headers: {
          'content-type': pending.isExport
              ? 'application/msword'
              : 'text/html; charset=utf-8'
        });
  }

  @override
  void close() {
    closed++;
    for (final request in requests) {
      if (!request.body.isClosed) unawaited(request.body.close());
    }
  }
}

class _PendingResponse {
  _PendingResponse(this.request) {
    (request as http.AbortableRequest).abortTrigger!.then((_) {
      aborted = true;
      if (!body.isClosed) {
        body.addError(http.ClientException('Aborted', request.url));
        unawaited(body.close());
      }
    });
  }

  final http.BaseRequest request;
  final body = StreamController<List<int>>();
  bool aborted = false;
  bool get isExport => request.url.path.contains('newstoword');

  void complete(String value) {
    body.add(utf8.encode(value));
    unawaited(body.close());
  }
}

class _RedirectingClient extends http.BaseClient {
  _RedirectingClient(this.handler);
  final http.StreamedResponse Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      handler(request);
}

class _FinalUrlResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _FinalUrlResponse(Stream<List<int>> stream, this.url,
      {required http.BaseRequest request})
      : super(stream, 200,
            request: request,
            headers: {'content-type': 'text/html; charset=utf-8'});
  @override
  final Uri url;
}
