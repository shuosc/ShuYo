import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

const _schimItem = AnnouncementListItem(
  title: '2026年研究生校长奖学金文信学院推荐名单公示',
  url: 'https://schim.shu.edu.cn/info/1375/14863.htm',
  sourceId: 'schim',
);

const _youthItem = AnnouncementListItem(
  title: '上海大学2026-2027学年秋季学期常态化社会实践校级立项公示',
  url: 'https://youth.shu.edu.cn/info/1010/22195.htm',
  sourceId: 'youth',
);

const _articleBody = '''
<div id="vsb_content"><div class="v_news_content">
  <p>现将研究生校长奖学金拟推荐名单公示如下。</p>
  <div align="center"><table border="1"><tbody>
    <tr><td><p>学号</p></td><td><p>姓名</p></td><td><p>评审结果</p></td></tr>
    <tr><td><p>24820631</p></td><td><p>张奕萱</p></td><td><p>拟推荐</p></td></tr>
  </tbody></table></div>
  <p>公示时间为2026年9月30日至10月11日。</p>
</div></div>
''';

String _articlePage(String body) => '''
<!doctype html><html><head><title>${_schimItem.title}</title></head><body>
<div class="content"><form name="_newscontent_fromname">
  <table><tbody><tr><td>
    <span class="shuHead">${_schimItem.title}</span>
    <span>发布日期：</span><span>2026/09/30</span>
    <span>投稿：</span><a>元数据作者</a>
  </td></tr></tbody></table>
  $body
</form></div>
<footer><p>页脚版权所有和联系方式</p></footer>
</body></html>
''';

String _malformedArticlePage() => _articlePage('''
<table cellspacing="2" cellpadding="2" width="100%" class="shuArticle">
  $_articleBody
</table>
''');

AnnouncementApiClient _clientFor(String html) => AnnouncementApiClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(html),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );

void _expectCompleteArticle(AnnouncementDetail detail) {
  expect(detail.blocks.map((block) => block.type), [
    AnnouncementContentType.text,
    AnnouncementContentType.table,
    AnnouncementContentType.text,
  ]);
  expect(detail.blocks.first.value, '现将研究生校长奖学金拟推荐名单公示如下。');
  final table = detail.blocks[1];
  expect(table.rows, [
    ['学号', '姓名', '评审结果'],
    ['24820631', '张奕萱', '拟推荐'],
  ]);
  expect(table.cells, hasLength(6));
  expect(detail.blocks.last.value, '公示时间为2026年9月30日至10月11日。');
  final body = detail.blocks.map((block) => block.value).join();
  expect(body, isNot(contains('发布日期')));
  expect(body, isNot(contains('元数据作者')));
  expect(body, isNot(contains('页脚版权所有')));
}

void main() {
  test('malformed shuArticle preserves the table and following paragraphs', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      _malformedArticlePage(),
      url: _schimItem.url,
      sourceId: _schimItem.sourceId,
      fallbackTitle: _schimItem.title,
    );

    _expectCompleteArticle(detail);
  });

  test('fetchDetail repairs malformed shuArticle before isolate parsing',
      () async {
    final client = _clientFor(_malformedArticlePage());
    addTearDown(client.close);

    _expectCompleteArticle(await client.fetchDetail(_schimItem));
  });

  test('a valid shuArticle layout keeps its nested data table', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      _articlePage('''
<table class="shuArticle"><tbody><tr><td>$_articleBody</td></tr></tbody></table>
'''),
      url: _schimItem.url,
      sourceId: _schimItem.sourceId,
    );

    _expectCompleteArticle(detail);
  });

  test('an ordinary article data table keeps its order and cells', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      _articlePage(_articleBody),
      url: _schimItem.url,
      sourceId: _schimItem.sourceId,
    );

    _expectCompleteArticle(detail);
  });

  test('HTTP 200 missing article ID is unavailable despite title and metadata',
      () async {
    final client = _clientFor('''
<!doctype html><html><head>
  <title>${_youthItem.title}-共青团上海大学委员会</title>
  <meta name="pageType" content="3">
  <meta name="pageTitle" content="${_youthItem.title}">
  <meta name="description" content="公示期已结束。">
</head><body><div class="content-page">
  <div class="right-title">首页 - 通知公告 - 正文</div>
  <div class="content">\n没有找到文章ID\n</div>
</div><footer>版权所有 上海大学</footer></body></html>
''');
    addTearDown(client.close);

    await expectLater(
      client.fetchDetail(_youthItem),
      throwsA(isA<AnnouncementUnavailableException>()),
    );
  });

  test('article prose mentioning a missing article ID remains readable',
      () async {
    const paragraph = '如果系统提示“没有找到文章ID”，请联系网站管理员处理。';
    final client = _clientFor('''
<html><head><title>网站使用说明</title></head><body>
<div class="content"><div class="v_news_content"><p>$paragraph</p></div></div>
</body></html>
''');
    addTearDown(client.close);

    final detail = await client.fetchDetail(_youthItem);

    expect(detail.hasContent, isTrue);
    expect(detail.blocks.single.value, paragraph);
  });

  test('an empty article can retry without reusing the failed response',
      () async {
    var requests = 0;
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        requests++;
        return http.Response.bytes(
          utf8.encode(requests == 1
              ? '<html><body>暂未提供正文</body></html>'
              : '<div class="v_news_content"><p>恢复后的正文</p></div>'),
          200,
        );
      }),
    );
    addTearDown(client.close);

    await expectLater(
      client.fetchDetail(_schimItem),
      throwsA(isA<AnnouncementApiException>()),
    );
    final detail = await client.fetchDetail(_schimItem);

    expect(requests, 2);
    expect(detail.blocks.single.value, '恢复后的正文');
  });
}
