import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

const _utseusUrl = 'https://utseus.shu.edu.cn/info/1010/6186.htm';
const _utseusTitle = '中欧学院2027年接收推荐免试攻读硕士学位研究生复试工作办法';
const _officialUrl = 'https://www.shu.edu.cn/info/1051/402205.htm';
const _officialTitle = '关于发布区人大代表换届选举选民名单（一号公告）的通知';
const _bkzswUrl = 'https://bkzsw.shu.edu.cn/info/1798/38490.htm';

String _article({
  String title = _utseusTitle,
  int tree = 1010,
  int news = 6186,
  int owner = 1430791623,
  String date = '',
  String author = '',
  String department = '',
  String body = '<p>公告正文，落款日期为2026-09-16。</p>',
}) =>
    '''
<html><head><meta name="pageTitle" content="$title"></head><body>
<script>_jsq_($tree,'/content.jsp',$news,$owner)</script>
<div class="nry"><h1>$title</h1><p class="xx">
<span>发布时间：$date</span><span>作者：$author</span>
<span>部门：$department</span></p>
<div class="v_news_content">$body</div></div></body></html>
''';

http.Response _html(String body) => http.Response(body, 200,
    headers: {'content-type': 'text/html; charset=utf-8'});

http.Response _export({
  String title = _utseusTitle,
  String timestamp = '2026-09-18 10:00:36',
  String author = '赵凌',
  String department = '',
}) {
  final header = '<div align="center"><p><h1>$title</h1></p>'
      ' $author $timestamp $department </div>';
  final encoded = utf8.encode(header).map((byte) {
    if (byte < 0x80 && byte != 0x3d) return String.fromCharCode(byte);
    return '=${byte.toRadixString(16).padLeft(2, '0')}';
  }).join();
  return _mimeResponse(encoded, charset: 'UTF-8');
}

http.Response _mimeResponse(String header, {String charset = 'GBK'}) =>
    http.Response.bytes(
      ascii.encode('Mime-Version: 1.0\r\n'
          'Content-Type: multipart/related; boundary="test-metadata"\r\n\r\n'
          '--test-metadata\r\n'
          'Content-Type: text/html; charset=$charset\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n\r\n'
          '${header.replaceAll('\n', '\r\n')}'),
      200,
      headers: {'content-type': 'application/msword'},
    );

const _officialGbkHeader = '''
<div align=3D"center"><p><h1>=B9=D8=D3=DA=B7=A2=B2=BC=C7=F8=C8=CB=B4=F3=B4=
=FA=B1=ED=BB=BB=BD=EC=D1=A1=BE=D9=D1=A1=C3=F1=C3=FB=B5=A5=A3=A8=D2=BB=BA=C5=
=B9=AB=B8=E6=A3=A9=B5=C4=CD=A8=D6=AA</h1></p> =BA=AB=CF=FE=CF=BC  2026-10-2=
6 19:46:41  =B5=B3=CE=AF=D0=FB=B4=AB=B2=BF </div>''';

bool _isExport(http.Request request) =>
    request.url.path == '/system/resource/news/newstoword.jsp';

AnnouncementApiClient _client(
  FutureOr<http.Response> Function(http.Request) handler,
) {
  final client = AnnouncementApiClient(
    httpClient: MockClient((request) async => handler(request)),
    maxRequestAttempts: 1,
    retryBaseDelay: Duration.zero,
  );
  addTearDown(client.close);
  return client;
}

const _utseusItem = AnnouncementListItem(
  title: _utseusTitle,
  url: _utseusUrl,
  sourceId: 'utseus',
);

void main() {
  test('loading a list does not fetch article HTML or export metadata',
      () async {
    final source = AnnouncementSource.byId('utseus');
    final requests = <Uri>[];
    final api = _client((request) {
      requests.add(request.url);
      return _html('<div class="content-box fr zsxx"><ul>'
          '<li id="line_u1_0"><a href="$_utseusUrl">$_utseusTitle</a></li>'
          '</ul></div>');
    });

    final page = await api.fetchPage(source: source);

    expect(page.items.single.url, _utseusUrl);
    expect(page.items.single.dateText, isEmpty);
    expect(requests.map((url) => url.toString()), [source.listUrl]);
  });

  test('UTSEUS empty HTML date is shared between list enrichment and detail',
      () async {
    final requests = <Uri>[];
    final api = _client((request) {
      requests.add(request.url);
      return _isExport(request) ? _export() : _html(_article());
    });

    final datedItem = await api.fetchPublicationDate(_utseusItem);
    final detail = await api.fetchDetail(datedItem!);

    expect(datedItem.dateText, '2026-09-18');
    expect(datedItem.publishedAt, DateTime(2026, 9, 18));
    expect(detail.dateText, datedItem.dateText);
    expect(detail.author, '赵凌');
    expect(detail.department, isEmpty);
    expect(
        requests.where((url) => url.path.contains('newstoword')), hasLength(1));
    expect(requests.where((url) => url.toString() == _utseusUrl), hasLength(1));
    expect(detail.blocks.any((block) => block.value.contains('2026-09-16')),
        isTrue);
  });

  test('official GBK export supplies author and department absent from HTML',
      () async {
    final api = _client((request) => _isExport(request)
        ? _mimeResponse(_officialGbkHeader)
        : _html(_article(
            title: _officialTitle,
            tree: 1051,
            news: 402205,
            owner: 1864855249,
          )));

    final detail = await api.fetchDetail(const AnnouncementListItem(
      title: _officialTitle,
      url: _officialUrl,
    ));

    expect(detail.dateText, '2026-10-26');
    expect(detail.author, '韩晓霞');
    expect(detail.department, '党委宣传部');
    expect(detail.blocks.any((block) => block.value.contains('公告正文')), isTrue);
  });

  test('empty legacy metadata still keeps the declared original title',
      () async {
    final api = _client((request) => _isExport(request)
        ? _export()
        : _html('<meta name="pageTitle" content="$_utseusTitle">'
            '<script>_jsq_(1010,"/content.jsp",6186,1430791623)</script>'
            '<span class="Head">$_utseusTitle</span>'
            '<table><tr><td><span>发布时间：</span><span></span></td></tr></table>'
            '<div class="v_news_content"><p>正文</p></div>'));
    final detail = await api.fetchDetail(const AnnouncementListItem(
      title: '截断的列表标题',
      url: _utseusUrl,
      sourceId: 'utseus',
    ));
    expect(detail.title, _utseusTitle);
    expect(detail.dateText, '2026-09-18');
    expect(detail.author, '赵凌');
  });

  test('Film Academy linked admissions article keeps its list source identity',
      () async {
    const title = '上海电影学院校考工作安排';
    final requests = <Uri>[];
    final api = _client((request) {
      requests.add(request.url);
      return _isExport(request)
          ? _export(
              title: title,
              timestamp: '2026-03-18 12:00:00',
              author: '招生办公室',
              department: '本科生招生网',
            )
          : _html(_article(
              title: title,
              tree: 1798,
              news: 38490,
              owner: 1364902694,
            ));
    });
    const item = AnnouncementListItem(
      title: title,
      url: _bkzswUrl,
      sourceId: 'sfa',
      column: '本院通知',
      summary: '保留列表摘要',
    );

    final dated = await api.fetchPublicationDate(item);
    final detail = await api.fetchDetail(dated!);

    expect(dated.sourceId, 'sfa');
    expect(dated.column, item.column);
    expect(dated.summary, item.summary);
    expect(dated.dateText, '2026-03-18');
    expect(detail.author, '招生办公室');
    expect(detail.department, '本科生招生网');
    expect(requests.every((url) => url.host == 'bkzsw.shu.edu.cn'), isTrue);
    final export =
        requests.singleWhere((url) => url.path.contains('newstoword'));
    expect(export.queryParameters,
        {'treeid': '1798', 'owner': '1364902694', 'wbnewsid': '38490'});
  });

  test('concurrent callers from different source lists share one URL export',
      () async {
    final exportStarted = Completer<void>();
    final releaseExport = Completer<http.Response>();
    var articleCount = 0;
    var exportCount = 0;
    final api = _client((request) {
      if (_isExport(request)) {
        exportCount++;
        if (!exportStarted.isCompleted) exportStarted.complete();
        return releaseExport.future;
      }
      articleCount++;
      return _html(_article());
    });

    final fromCollege = api.fetchPublicationDate(_utseusItem);
    final fromFilm = api.fetchPublicationDate(const AnnouncementListItem(
      title: _utseusTitle,
      url: _utseusUrl,
      sourceId: 'sfa',
    ));
    await exportStarted.future;
    releaseExport.complete(_export());
    final results = await Future.wait([fromCollege, fromFilm]);

    expect(results.map((item) => item!.sourceId), ['utseus', 'sfa']);
    expect(results.map((item) => item!.dateText), everyElement('2026-09-18'));
    expect(articleCount, 1);
    expect(exportCount, 1);
  });

  for (final failure in ['HTTP failure', 'invalid header', 'wrong title']) {
    test('$failure falls back to HTML date, author and department', () async {
      final api = _client((request) {
        if (!_isExport(request)) {
          return _html(_article(
            date: '2026-09-17',
            author: '原文作者',
            department: '原文部门',
          ));
        }
        return switch (failure) {
          'HTTP failure' => http.Response('temporarily unavailable', 503),
          'invalid header' => http.Response('not a MIME document', 200,
              headers: {'content-type': 'application/msword'}),
          _ => _export(title: '其他文章，不能用它覆盖当前文章'),
        };
      });

      final dated = await api.fetchPublicationDate(_utseusItem);
      final detail = await api.fetchDetail(dated!);

      expect(dated.dateText, '2026-09-17');
      expect(detail.dateText, '2026-09-17');
      expect(detail.author, '原文作者');
      expect(detail.department, '原文部门');
      expect(detail.hasContent, isTrue);
    });
  }

  test('non-VSB Vancouver article uses its HTML without requesting an export',
      () async {
    const url = 'https://www.shvfs.cn/site/newsDetail/1624';
    final requests = <Uri>[];
    final api = _client((request) {
      requests.add(request.url);
      return _html('<header class="n-detail-title">'
          '<h2>温哥华电影学院新闻</h2><p>时间：2026-10-20</p></header>'
          '<div class="news-detail-infowrap"><p>原站新闻正文</p></div>');
    });

    final detail = await api.fetchDetail(const AnnouncementListItem(
      title: '温哥华电影学院新闻',
      url: url,
      sourceId: 'shvfs',
    ));

    expect(detail.dateText, '2026-10-20');
    expect(detail.hasContent, isTrue);
    expect(requests.map((request) => request.toString()), [url]);
  });

  test(
      'metadata export preserves original text, images, tables and attachments',
      () async {
    final api = _client((request) => _isExport(request)
        ? _export()
        : _html(_article(
            body: '<p>详见附件，以下为原站正文。</p>'
                '<p><img src="/images/original.png" alt="原图"></p>'
                '<table><tr><td>原始表格</td><td>保留内容</td></tr></table>'
                '<a href="/system/_content/download.jsp?urltype=news.'
                'DownloadAttachUrl&amp;wbfileid=123">附件.pdf</a>',
          )));

    final detail = await api.fetchDetail(_utseusItem);

    expect(detail.dateText, '2026-09-18');
    expect(detail.blocks.any((block) => block.value.contains('原站正文')), isTrue);
    expect(detail.blocks.where((block) => block.isImage).single.value,
        'https://utseus.shu.edu.cn/images/original.png');
    expect(detail.blocks.any((block) => block.isTable), isTrue);
    expect(
      detail.blocks.where((block) => block.isLink).map((block) => block.value),
      contains('https://utseus.shu.edu.cn/system/_content/download.jsp?'
          'urltype=news.DownloadAttachUrl&wbfileid=123'),
    );
  });

  test('clearing response cache also refreshes unified publication metadata',
      () async {
    var exportCount = 0;
    var articleCount = 0;
    final api = _client((request) {
      if (_isExport(request)) {
        exportCount++;
        return _export(
            timestamp: exportCount == 1
                ? '2026-09-18 10:00:36'
                : '2026-10-26 09:00:00');
      }
      articleCount++;
      return _html(_article());
    });

    expect(
        (await api.fetchPublicationDate(_utseusItem))!.dateText, '2026-09-18');
    api.clearResponseCache();
    expect(
        (await api.fetchPublicationDate(_utseusItem))!.dateText, '2026-10-26');
    expect((await api.fetchDetail(_utseusItem)).dateText, '2026-10-26');
    expect(articleCount, 2);
    expect(exportCount, 2);
  });

  test(
      'pre-refresh metadata cannot overwrite newer metadata after it completes',
      () async {
    final oldExportStarted = Completer<void>();
    final releaseOldExport = Completer<http.Response>();
    var exportCount = 0;
    var articleCount = 0;
    final api = _client((request) {
      if (_isExport(request)) {
        exportCount++;
        if (exportCount == 1) {
          oldExportStarted.complete();
          return releaseOldExport.future;
        }
        return _export(timestamp: '2026-10-26 09:00:00', author: '刷新后作者');
      }
      articleCount++;
      return _html(_article());
    });

    final oldTask = api.fetchPublicationDate(_utseusItem);
    await oldExportStarted.future;
    api.clearResponseCache();
    final newItem = await api.fetchPublicationDate(_utseusItem);
    expect(newItem!.dateText, '2026-10-26');
    releaseOldExport.complete(_export());
    expect((await oldTask)!.dateText, '2026-09-18');

    final detail = await api.fetchDetail(_utseusItem);
    expect(detail.dateText, '2026-10-26');
    expect(detail.author, '刷新后作者');
    expect(articleCount, 2);
    expect(exportCount, 2);
  });
}
