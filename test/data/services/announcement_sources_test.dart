import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

void main() {
  test('large article tables parse outside the UI isolate', () async {
    const item = AnnouncementListItem(
      title: '大型名单',
      url: 'https://www.shu.edu.cn/info/1001/large.htm',
    );
    final rows = [
      for (var index = 0; index < 250; index++)
        '<tr><td>编号 $index 学生名单和材料审核结果</td>'
            '<td>院系 $index 专业方向与报名状态</td></tr>',
    ].join();
    final html = '<div class="v_news_content"><table>$rows</table></div>';
    expect(utf8.encode(html).length, greaterThan(16384));
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async => http.Response(
            html,
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          )),
    );

    final detail = await client.fetchDetail(item);
    final table = detail.blocks.singleWhere((block) => block.isTable);
    expect(table.rows, hasLength(250));
    expect(table.rows.first.first, contains('编号 0'));
    expect(table.rows.last.last, contains('院系 249'));
    client.close();
  });

  test('Film Academy article metadata completes undated list entries',
      () async {
    final source = AnnouncementSource.byId('sfa');
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        final html = path.contains('/info/')
            ? '<span class="Head">${path.endsWith('/new.htm') ? '新公告' : '旧公告'}</span>'
                '<table><tr valign="middle" height="20"><td>'
                '<span>创建时间：</span><span>${path.endsWith('/new.htm') ? '2026年10月20日 08:00' : '2026年09月10日 09:00'}</span>'
                '<font face=""><span>${path.endsWith('/new.htm') ? '王超' : '李华'}</span>'
                '<font face="Times New Roman"><span>浏览次数：</span></font>'
                '</font></td></tr></table>'
                '<div class="v_news_content"><p>正文</p></div>'
            : '<div class="right">'
                '<li class="notice-item"><a class="notice-title" href="/info/1212/old.htm">旧公告</a></li>'
                '<li class="notice-item"><a class="notice-title" href="/info/1212/new.htm">新公告</a></li>'
                '<li class="notice-item"><a class="notice-title" href="https://example.org/external">外链</a></li>'
                '</div>';
        return http.Response(html, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );

    final page = await client.fetchPage(source: source);
    expect(page.items.map((item) => item.title), ['新公告', '外链', '旧公告']);
    expect(page.items.first.publishedAt, DateTime(2026, 10, 20));
    expect(page.items.first.dateText, '2026-10-20');
    final external = page.items.singleWhere((item) => item.title == '外链');
    expect(external.dateText, isEmpty);
    expect(external.publishedAt, DateTime(2026, 10, 19));
    final detail = await client.fetchDetail(page.items.first);
    expect(detail.dateText, '2026-10-20');
    expect(detail.author, '王超');
    expect(detail.title, '新公告');
    client.close();
  });

  test('undated Film Academy links keep their source positions', () async {
    final source = AnnouncementSource.byId('sfa');
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/info/')) {
          final date = path.endsWith('/new.htm')
              ? '2026年10月20日 08:00'
              : '2026年10月10日 08:00';
          return http.Response(
              '<table><tr valign="middle" height="20">'
              '<td><span>创建时间：</span><span>$date</span></td>'
              '</tr></table><div class="v_news_content"><p>正文</p></div>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'});
        }
        return http.Response(
            '<div class="right">'
            '<li class="notice-item"><a class="notice-title" href="/info/new.htm">新公告</a></li>'
            '<li class="notice-item"><a class="notice-title" href="https://example.org/a">外链甲</a></li>'
            '<li class="notice-item"><a class="notice-title" href="https://example.org/b">外链乙</a></li>'
            '<li class="notice-item"><a class="notice-title" href="/info/old.htm">旧公告</a></li>'
            '<li class="notice-item"><a class="notice-title" href="https://example.org/c">外链丙</a></li>'
            '</div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );

    final page = await client.fetchPage(source: source);
    expect(page.items.map((item) => item.title),
        ['新公告', '外链甲', '外链乙', '旧公告', '外链丙']);
    expect(
        page.items.map((item) => item.publishedAt),
        orderedEquals([
          DateTime(2026, 10, 20),
          DateTime(2026, 10, 16, 16),
          DateTime(2026, 10, 13, 8),
          DateTime(2026, 10, 10),
          DateTime(2026, 10, 9),
        ]));
    expect(
        page.items
            .where((item) => item.title.startsWith('外链'))
            .every((item) => item.dateText.isEmpty),
        isTrue);
    client.close();
  });

  test('Xiangying list retains cross-subdomain details and pagination',
      () async {
    final source = AnnouncementSource.byId('xiangying');
    expect(source.group, AnnouncementSourceGroup.college);
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final secondPage = request.url.path.endsWith('/5.htm');
        final html = '<div class="wList-lb"><ul>'
            '<li id="line_u5_0"><a href="https://scie.shu.edu.cn/info/1070/${secondPage ? 40075 : 46185}.htm">'
            '${secondPage ? '历史安排' : '春季安排'}</a><i>${secondPage ? '2023-09-05' : '2026-03-27'}</i></li>'
            '</ul></div>'
            '<a href="${secondPage ? '4.htm' : 'tzgg/5.htm'}" class="Next">下页</a>';
        return http.Response(html, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );

    final first = await client.fetchPage(source: source);
    expect(
        first.items.single.url, 'https://scie.shu.edu.cn/info/1070/46185.htm');
    expect(first.items.single.publishedAt, DateTime(2026, 3, 27));
    expect(first.nextPageUrls,
        ['https://xiangying.shu.edu.cn/syxgzlpzd/tzgg/5.htm']);

    final second = await client.fetchPage(
      source: source,
      pageUrls: first.nextPageUrls,
    );
    expect(
        second.items.single.url, 'https://scie.shu.edu.cn/info/1070/40075.htm');
    expect(second.nextPageUrls,
        ['https://xiangying.shu.edu.cn/syxgzlpzd/tzgg/4.htm']);
  });

  test('Xiangying article body parses on the linked SCIE subdomain', () async {
    const item = AnnouncementListItem(
      title: '春季学期自习辅导安排表',
      url: 'https://scie.shu.edu.cn/info/1070/46185.htm',
      sourceId: 'xiangying',
      dateText: '2026-03-27',
    );
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        expect(request.url.toString(), item.url);
        return http.Response(
          '<div id="vsb_content_1"><div class="v_news_content">'
          '<p>春季学期安排正文</p></div></div>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );

    final detail = await client.fetchDetail(item);
    expect(detail.title, item.title);
    expect(detail.dateText, item.dateText);
    expect(detail.blocks.single.value, '春季学期安排正文');
  });

  test('Vancouver Film School news parses cards and follows Node_page',
      () async {
    final source = AnnouncementSource.byId('shvfs');
    expect(source.group, AnnouncementSourceGroup.college);
    expect(source.adapter.hideListColumn, isTrue);
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final secondPage = request.url.queryParameters['Node_page'] == '2';
        final media = request.url.path.endsWith('/8');
        final category = media ? '媒体关注' : '学院动态';
        final articleId = media ? 1600 : 1624;
        final html = '<ul class="news-main-list"><li class="pr">'
            '<div class="news-item-info">'
            '<h2>${secondPage ? '第二页' : '首页'}$category</h2>'
            '<span>${media ? '2026-08-20' : '2026-10-16'}</span>'
            '<p>学院新闻摘要</p>'
            '<div class="news-go-more"><a href="/site/newsDetail/$articleId">查看详情+</a></div>'
            '</div></li></ul>'
            '<ul class="yiiPager"><li class="next"><a href="/site/news/${media ? 8 : 4}?Node_page=${secondPage ? 3 : 2}">加载更多</a></li></ul>';
        return http.Response(html, 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );

    final first = await client.fetchPage(source: source);
    expect(first.items.map((item) => item.title), ['首页学院动态', '首页媒体关注']);
    expect(first.items.map((item) => item.column), ['学院动态', '媒体关注']);
    expect(first.items.first.url, 'https://www.shvfs.cn/site/newsDetail/1624');
    expect(first.items.last.url, 'https://www.shvfs.cn/site/newsDetail/1600');
    expect(first.items.first.summary, '学院新闻摘要');
    expect(first.items.first.publishedAt, DateTime(2026, 10, 16));
    expect(first.nextPageUrls, [
      'https://www.shvfs.cn/site/news/4?Node_page=2',
      'https://www.shvfs.cn/site/news/8?Node_page=2',
    ]);

    final second = await client.fetchPage(
      source: source,
      pageUrls: first.nextPageUrls,
    );
    expect(second.items.map((item) => item.title), ['第二页学院动态', '第二页媒体关注']);
    expect(second.nextPageUrls, [
      'https://www.shvfs.cn/site/news/4?Node_page=3',
      'https://www.shvfs.cn/site/news/8?Node_page=3',
    ]);
  });

  test('Vancouver Film School detail parses its own article layout', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<header class="n-detail-title"><h2>电影课堂新实践</h2>'
      '<p>时间：2026-10-16</p></header>'
      '<div class="news-detail-infowrap">'
      '<p><span>第一段正文，供列表显示。</span></p>'
      '<p>查看<a href="/site/newsDetail/1600">相关报道</a></p>'
      '<p><span><img src="/uploads/news/photo.jpg"></span></p>'
      '</div>',
      url: 'https://www.shvfs.cn/site/newsDetail/1624',
      sourceId: 'shvfs',
      fallbackTitle: '列表标题',
      fallbackDateText: '2026-10-15',
    );

    expect(detail.title, '电影课堂新实践');
    expect(detail.dateText, '2026-10-16');
    expect(detail.publishedAt, DateTime(2026, 10, 16));
    expect(detail.author, isEmpty);
    expect(
        detail.blocks
            .where((block) => block.isText)
            .map((block) => block.value),
        ['第一段正文，供列表显示。', '查看相关报道']);
    expect(detail.blocks.where((block) => block.isImage).single.value,
        'https://www.shvfs.cn/uploads/news/photo.jpg');
    expect(
      detail.blocks
          .expand((block) => block.parts)
          .where((part) => part.url.isNotEmpty)
          .single
          .url,
      'https://www.shvfs.cn/site/newsDetail/1600',
    );
  });

  test('Vancouver Film School preview uses article body over list excerpt',
      () async {
    const item = AnnouncementListItem(
      title: '电影课堂新实践',
      url: 'https://www.shvfs.cn/site/newsDetail/1624',
      sourceId: 'shvfs',
      summary: '列表页摘要',
    );
    final requests = <Uri>[];
    final repository = AnnouncementRepository(
      apiClient: AnnouncementApiClient(
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            '<header class="n-detail-title"><h2>电影课堂新实践</h2></header>'
            '<div class="news-detail-infowrap"><p>正文首段，生成列表概览。</p></div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      ),
    );

    expect(await repository.loadPreview(item), '正文首段，生成列表概览。');
    expect(requests, [Uri.parse(item.url)]);
  });

  test('HR notices follow the VSB Next link', () async {
    final source = AnnouncementSource.byId('hr');
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async => http.Response(
            '<table class="artlist"><tr id="line_u1_0"><td>'
            '<a href="../info/1001/1.htm">人事通知</a></td>'
            '<td>2026-10-08</td></tr></table>'
            '<a href="xwgg/50.htm" class="Next">下页</a>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          )),
    );
    final page = await client.fetchPage(source: source);
    expect(page.nextPageUrls, ['https://hr.shu.edu.cn/xwgg1/xwgg/50.htm']);
  });

  test('inline article markup does not add spaces between Chinese characters',
      () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content"><p>关于<span>做好</span><strong>年度</strong>考核</p>'
      '<p>第二段 <span>保留</span> 原有空格</p></div>',
      url: 'https://hr.shu.edu.cn/info/1001/1.htm',
    );
    expect(
        detail.blocks
            .where((block) => block.isText)
            .map((block) => block.value),
        ['关于做好年度考核', '第二段 保留 原有空格']);
  });

  test('article links, plain URLs and email remain in paragraph order', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content"><p>请见<a href="/guide.htm">办理指南</a>，'
      '访问 https://example.org/help 或联系 office@example.org。</p></div>',
      url: 'https://hr.shu.edu.cn/info/1001/1.htm',
    );
    final paragraph = detail.blocks.single;
    expect(paragraph.value,
        '请见办理指南，访问 https://example.org/help 或联系 office@example.org。');
    expect(
        paragraph.parts
            .where((part) => part.url.isNotEmpty)
            .map((part) => (part.text, part.url)),
        [
          ('办理指南', 'https://hr.shu.edu.cn/guide.htm'),
          ('https://example.org/help', 'https://example.org/help'),
          ('office@example.org', 'mailto:office@example.org'),
        ]);
  });

  test('campus and department sources extract dated article links', () {
    final samples = <String, String>{
      'shu': '<div class="ej_main"><div class="list"><ul><li><a '
          'href="/info/1.htm"><p class="bt">官网通知</p><p class="sj">'
          '2026.10.06</p><p class="zy">摘要</p></a></li></ul></div></div>',
      'bksy': '<div class="only-list"><ul><li><a href="../info/2.htm">'
          '本科生通知</a> 2026年10月6日</li></ul></div>',
      'xgb': '<table class="ArtList"><tr><td><a class="linkfont1" '
          'href="/info/3.htm">本科生处通知</a></td><td><span '
          'class="linkfont1">2026-10-06</span></td></tr></table>',
      'dwygb': '<table class="ArtList"><tr><td><a class="linkfont1" '
          'href="/info/4.htm">研工部通知</a></td><td><span '
          'class="linkfont1">2026-10-06</span></td></tr></table>',
      'gs': '<table><tr id="line_u1_0"><td><a href="/info/5.htm">'
          '研究生培养通知</a></td><td>2026/10/06 09:00:00</td></tr></table>',
      'cwc': '<div class="list-centre-right-down"><ul><li class="clearfix">'
          '<a href="/info/6.htm">财务通知</a><p '
          'class="list-centre-right-down-p">2026-10-06</p>'
          '</li></ul></div>',
      'lib': '<div class="right-list"><ul><li><a href="/info/7.htm">'
          '图书馆通知</a><span>2026-10-06</span></li></ul></div>',
      'kyglb': '<div class="list fl"><ul><li><a href="/info/8.htm">'
          '科研管理通知</a><span>2026-10-06</span></li></ul></div>',
      'baoweichu': '<div class="only-list1"><ul><li>'
          '<a href="/info/9.htm">保卫处通知</a> 2026-10-06</li></ul></div>',
      'its': '<div class="only-list1"><ul><li id="line_u4_0">'
          '<a href="../info/1095/6422.htm" target="_blank">'
          '网络故障紧急通知</a><span>2026-09-22</span>'
          '</li></ul></div>',
      'youth': '<div class="right-list"><ul><li>'
          '<a href="../info/1010/22105.htm">团委通知</a>'
          '<span>2026-09-20</span></li></ul></div>'
          '<a class="Next" href="tzgg/38.htm">下页</a>',
      'global': '<li id="line_u8_0"><a href="../info/1003/16043.htm">'
          '国际部通知</a><span>2026年09月22日</span></li>',
      'hbb': '<li id="line_u5_0"><a href="info/1005/10946.htm">'
          '后勤通知</a><span>2026-10-16</span></li>',
      'xyy': '<table><tr id="line_u3_0"><td><a href="../info/1090/5436.htm">'
          '校医院通知</a></td><td>2026-08-29</td></tr></table>',
      'archive': '<li id="line_u4_0"><a href="../../info/1013/22026.htm">'
          '档案馆通知</a><span>2026-05-11</span></li>',
      'sbc': '<li id="line_u5_0"><a href="../info/1004/11324.htm">'
          '实验室通知<span>2026-10-15</span></a></li>',
      'hr': '<table class="artlist"><tr id="line_u1_0">'
          '<td><a href="../info/1001/1.htm">人事处通知</a></td>'
          '<td>2026-10-08</td></tr></table>',
    };

    for (final entry in samples.entries) {
      final source = AnnouncementSource.byId(entry.key);
      final items = AnnouncementApiClient.parseAnnouncementList(
        entry.value,
        baseUrl: source.listUrl,
        source: source,
      );
      expect(items, hasLength(1), reason: source.id);
      expect(items.single.url,
          startsWith('https://${Uri.parse(source.listUrl).host}/'));
      expect(
          items.single.publishedAt,
          switch (source.id) {
            'its' => DateTime(2026, 9, 22),
            'youth' => DateTime(2026, 9, 20),
            'global' => DateTime(2026, 9, 22),
            'hbb' => DateTime(2026, 10, 16),
            'xyy' => DateTime(2026, 8, 29),
            'archive' => DateTime(2026, 5, 11),
            'sbc' => DateTime(2026, 10, 15),
            'hr' => DateTime(2026, 10, 8),
            _ => DateTime(2026, 10, 6),
          });
      expect(items.single.sourceId, source.id);
    }

    final youth = AnnouncementSource.byId('youth');
    expect(
      AnnouncementApiClient.parseAnnouncementList(
        samples['youth']!,
        baseUrl: youth.listUrl,
        source: youth,
      ).single.url,
      'https://youth.shu.edu.cn/info/1010/22105.htm',
    );
  });

  test('youth notices parse and follow their pagination link', () async {
    final source = AnnouncementSource.byId('youth');
    final html = '<div class="right-list"><ul><li>'
        '<a href="../info/1010/22125.htm">团委通知</a>'
        '<span>2026-10-12</span></li></ul></div>'
        '<a class="Next" href="tzgg/38.htm">下页</a>';
    final client = AnnouncementApiClient(
      httpClient: MockClient(
        (request) async => http.Response.bytes(utf8.encode(html), 200),
      ),
    );

    final page = await client.fetchPage(source: source);

    expect(page.items, hasLength(1));
    expect(page.items.single.title, '团委通知');
    expect(
        page.items.single.url, 'https://youth.shu.edu.cn/info/1010/22125.htm');
    expect(page.nextPageUrls, ['https://youth.shu.edu.cn/syxzlly/tzgg/38.htm']);
  });

  test('college catalog and additional HTML layouts parse correctly', () {
    expect(AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolPortal),
        hasLength(4));
    expect(AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolDepartment),
        hasLength(19));
    expect(AnnouncementSource.inGroup(AnnouncementSourceGroup.college),
        hasLength(35));
    expect(
        AnnouncementSource.inGroup(AnnouncementSourceGroup.researchInstitute),
        hasLength(14));
    expect(AnnouncementSource.byId('mgi').group,
        AnnouncementSourceGroup.researchInstitute);
    expect(AnnouncementSource.byId('museum').group,
        AnnouncementSourceGroup.schoolDepartment);
    expect(AnnouncementSource.byId('jgzx').group,
        AnnouncementSourceGroup.researchInstitute);
    expect(AnnouncementSource.byId('youth').name, '上海大学共青团委员会');
    expect(AnnouncementSource.byId('bkzsw').name, '本科生招生网');
    expect(AnnouncementSource.byId('yingxin').name, '迎新网');
    expect(
        AnnouncementSource.all.any((source) => source.id == 'modart'), isTrue);
    expect(
        AnnouncementSource.all.any((source) => source.id == 'shvfs'), isTrue);
    final library = AnnouncementSource.byId('lib');
    expect(library.listUrls, [
      'https://lib.shu.edu.cn/sho/ggxx.htm',
      'https://lib.shu.edu.cn/sho/zydt.htm'
    ]);
    expect(library.columnNames, ['通知公告', '资源动态']);
    final resourceUpdates = AnnouncementApiClient.parseAnnouncementList(
      '<div class="right-list"><ul><li id="line_u6_0">'
      '<a href="../info/1023/6924.htm">数据库试用通知</a>'
      '<span>2026/04/20</span></li></ul></div>',
      baseUrl: library.listUrls[1],
      source: library,
      column: library.columnNames[1],
    );
    expect(resourceUpdates.single.url,
        'https://lib.shu.edu.cn/info/1023/6924.htm');
    expect(resourceUpdates.single.column, '资源动态');
    final samples = <String, String>{
      'cie': '<ul class="listPage"><li><a href="/info/1.htm">学院通知'
          '</a><span>2026/10/06</span></li></ul>',
      'cla': '<ul class="sj-list-ul"><li id="line_u1_0">'
          '<a href="/info/1.htm">文学院通知<p>2026-10-06</p></a></li></ul>',
      'ece': '<ul class="rightList"><li><a href="/info/1.htm">'
          '环化学院通知<span>2026-10-06</span></a></li></ul>',
      'mat': '<ul class="rightList"><li><a href="/info/1.htm">'
          '材料学院通知<span>2026-10-06</span></a></li></ul>',
      'mba': '<ul class="news-list"><li class="news-item" '
          "onclick=\"window.open('/info/1.htm','_self')\">"
          '<div class="news-title">MBA通知</div><div class="date-box">'
          '<span class="date-day">06</span><span class="date-ym">2026-10'
          '</span></div></li></ul>',
      'scicol': '<li id="line_u1_0"><a href="/info/1.htm">'
          '理学院通知<i>2026-10-06</i></a></li>',
      'smes': '<li id="line_u1_0"><a href="/info/1.htm">'
          '力工学院通知<span>2026-10-06</span></a></li>',
      'sjc': '<div class="jjyRight fr"><li class="clearfix">'
          '<a href="/info/1.htm">新传学院通知</a>'
          '<span class="fr">2026-10-06</span></li></div>',
    };
    for (final entry in samples.entries) {
      final source = AnnouncementSource.byId(entry.key);
      final items = AnnouncementApiClient.parseAnnouncementList(
        entry.value,
        baseUrl: source.listUrl,
        source: source,
      );
      expect(items, hasLength(1), reason: entry.key);
      expect(items.single.publishedAt, DateTime(2026, 10, 6));
      expect(items.single.title, isNot(contains('2026-10-06')));
    }
  });

  test('school portals, departments, and institutes have stable menu order',
      () {
    expect(
      AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolPortal)
          .map((source) => source.id),
      ['shu', 'bkzsw', 'yjszs', 'yingxin'],
    );
    expect(
      AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolDepartment)
          .map((source) => source.id),
      [
        'bksy',
        'gs',
        'xgb',
        'dwygb',
        'youth',
        'kyglb',
        'global',
        'alumni',
        'shuedf',
        'hr',
        'cwc',
        'sbc',
        'lib',
        'archive',
        'museum',
        'its',
        'hbb',
        'baoweichu',
        'xyy',
      ],
    );
    expect(
      AnnouncementSource.inGroup(AnnouncementSourceGroup.researchInstitute)
          .map((source) => source.id),
      [
        'mgi',
        'suitm',
        'jhai',
        'igs',
        'ihe',
        'cast',
        'icn',
        'adri',
        'jgzx',
        'suns',
        'skl4nm',
        'sklar',
        'sklass',
        'fpd',
      ],
    );
  });

  test('display laboratory columns parse dates and paginate independently',
      () async {
    final source = AnnouncementSource.byId('fpd');
    expect(source.group, AnnouncementSourceGroup.researchInstitute);
    expect(source.columnNames, ['通知公告', '新闻中心', '学术交流']);
    expect(source.listUrls, [
      'https://fpd.shu.edu.cn/kfyjl/tzgg.htm',
      'https://fpd.shu.edu.cn/kfyjl/xwzx.htm',
      'https://fpd.shu.edu.cn/kfyjl/xsjl1.htm',
    ]);
    final samples = [
      (
        path: 'tzgg',
        section: '1111',
        article: '4704',
        title: '开放课题申请通知',
        date: '2026-09-07',
        next: '3'
      ),
      (
        path: 'xwzx',
        section: '1113',
        article: '4684',
        title: '学术委员会会议',
        date: '2026-01-16',
        next: '11'
      ),
      (
        path: 'xsjl1',
        section: '1112',
        article: '4524',
        title: '生物3D打印学术交流',
        date: '2024-03-05',
        next: '1'
      ),
    ];
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final sample = samples.singleWhere(
          (sample) => request.url.path.endsWith('/${sample.path}.htm'),
        );
        final html = '<ul id="second_artlist"><li id="line_u4_0">'
            '<a href="../info/${sample.section}/${sample.article}.htm">${sample.title}</a>'
            '&nbsp;${sample.date}&nbsp;</li></ul>'
            '<a class="Next" href="${sample.path}/${sample.next}.htm">下页</a>';
        return http.Response.bytes(utf8.encode(html), 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }),
    );

    final page = await client.fetchPage(source: source);
    expect(page.items.map((item) => item.title), [
      '开放课题申请通知',
      '学术委员会会议',
      '生物3D打印学术交流',
    ]);
    expect(page.items.map((item) => item.column), source.columnNames);
    expect(page.items.map((item) => item.dateText),
        ['2026-09-07', '2026-01-16', '2024-03-05']);
    expect(page.items.first.url, 'https://fpd.shu.edu.cn/info/1111/4704.htm');
    expect(page.nextPageUrls, [
      'https://fpd.shu.edu.cn/kfyjl/tzgg/3.htm',
      'https://fpd.shu.edu.cn/kfyjl/xwzx/11.htm',
      'https://fpd.shu.edu.cn/kfyjl/xsjl1/1.htm',
    ]);
  });

  test('admissions sources include each requested column once', () {
    final undergraduate = AnnouncementSource.byId('bkzsw');
    expect(undergraduate.listUrls, hasLength(10));
    expect(undergraduate.listUrls.toSet(), hasLength(10));
    expect(undergraduate.columnNames, [
      '最新公告',
      '秋季统考',
      '春季招生',
      '综合评价录取',
      '艺术类',
      '保送生',
      '插班生',
      '二学位',
      '高校专项计划',
      '港澳台招生',
    ]);
    expect(undergraduate.listUrls[6], 'https://bkzsw.shu.edu.cn/zsjz/cbs.htm');
    final graduate = AnnouncementSource.byId('yjszs');
    expect(graduate.listUrls, [
      'https://yjszs.shu.edu.cn/cd/tzgg.htm',
      'https://yjszs.shu.edu.cn/cd/zsdt.htm',
    ]);
    expect(graduate.columnNames, ['通知公告', '招生动态']);
    final welcome = AnnouncementSource.byId('yingxin');
    expect(welcome.listUrls, [
      'https://yingxin.shu.edu.cn/tzgg.htm',
      'https://yingxin.shu.edu.cn/rxxz.htm',
    ]);
    expect(welcome.columnNames, ['通知公告', '入学须知']);
  });

  test('welcome site list parses dates without adding them to titles',
      () async {
    final source = AnnouncementSource.byId('yingxin');
    const noticeHtml = '<ul><li id="line_u2_0" class="lb-li">'
        '<a href="info/1008/2695.htm">校园无线网使用指南'
        '<span>2026-08-30</span></a></li></ul>'
        '<a class="Next" href="tzgg/1.htm">下页</a>';
    const instructionsHtml = '<ul><li id="line_u2_0" class="lb-li">'
        '<a href="info/1007/2515.htm">第二学士学位报到须知'
        '<span>2026-08-01</span></a></li></ul>';
    final requests = <String>[];
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        requests.add(request.url.toString());
        return http.Response.bytes(
            utf8.encode(request.url.path == '/rxxz.htm'
                ? instructionsHtml
                : noticeHtml),
            200);
      }),
    );
    final page = await client.fetchPage(source: source);
    expect(requests, unorderedEquals(source.listUrls));
    expect(page.items.map((item) => item.title), ['校园无线网使用指南', '第二学士学位报到须知']);
    expect(page.items.map((item) => item.column), ['通知公告', '入学须知']);
    expect(page.items.first.publishedAt, DateTime(2026, 8, 30));
    expect(
        page.items.first.url, 'https://yingxin.shu.edu.cn/info/1008/2695.htm');
    expect(page.nextPageUrls.first, 'https://yingxin.shu.edu.cn/tzgg/1.htm');
    client.close();
  });

  test('translational medicine columns parse and paginate', () async {
    final source = AnnouncementSource.byId('suitm');
    expect(source.listUrls, [
      'https://suitm.shu.edu.cn/syzl/xwdt.htm',
      'https://suitm.shu.edu.cn/tzgg.htm',
      'https://suitm.shu.edu.cn/kycg.htm',
    ]);
    expect(source.columnNames, ['新闻动态', '通知公告', '科研成果']);
    final requests = <String>[];
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        requests.add(request.url.toString());
        final path = request.url.path;
        final id = path.contains('xwdt')
            ? '1'
            : path.contains('tzgg')
                ? '2'
                : '3';
        final html = '<ul class="listUL"><li id="line_u5_0">'
            '<div class="listItem"><a href="info/1085/$id.htm">'
            '<div class="whitespace">栏目文章$id</div>'
            '<div class="abstract">2026/04/10</div>'
            '</a></div></li></ul>'
            '<a class="Next" href="${path.split('/').last.replaceFirst('.htm', '')}/3.htm">下页</a>';
        return http.Response.bytes(utf8.encode(html), 200);
      }),
    );
    final page = await client.fetchPage(source: source);
    expect(requests, unorderedEquals(source.listUrls));
    expect(page.items.map((item) => item.title), ['栏目文章1', '栏目文章2', '栏目文章3']);
    expect(page.items.map((item) => item.column), source.columnNames);
    expect(page.items.every((item) => item.dateText == '2026-04-10'), isTrue);
    expect(page.nextPageUrls, [
      'https://suitm.shu.edu.cn/syzl/xwdt/3.htm',
      'https://suitm.shu.edu.cn/tzgg/3.htm',
      'https://suitm.shu.edu.cn/kycg/3.htm',
    ]);
    client.close();
  });

  test('admissions list layouts skip mobile duplicates and follow pagination',
      () async {
    final undergraduate = AnnouncementSource.byId('bkzsw');
    const undergraduateHtml = '<div class="list-rContent-down">'
        '<li id="line_u5_0"><a href="../info/7743/38680.htm">'
        '本科招生章程</a><i>2026-05-19</i></li></div>'
        '<div class="mobile"><li id="line_u6_0">'
        '<a href="../info/7743/38680.htm">本科招生章程</a>'
        '<i>2026-05-19</i></li></div>'
        '<a class="Next" href="qjtk/3.htm">下页</a>';
    final graduate = AnnouncementSource.byId('yjszs');
    const graduateHtml = '<div class="dec-listPage"><div class="list-right">'
        '<ul class="clearfix"><li class="clearfix"><a href="../info/1003/8914.htm">'
        '<h3>上海大学报考点报名公告</h3><span>[2026/10/08]</span>'
        '</a></li></ul></div><span class="p_next p_fun">'
        '<a href="tzgg/4.htm">下页</a></span></div>'
        '<div class="mob-listPage"><li class="clearfix">'
        '<a href="../info/1003/8914.htm">上海大学报考点报名公告</a>'
        '</li></div>';
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async => http.Response.bytes(
            utf8.encode(request.url.host == 'bkzsw.shu.edu.cn'
                ? undergraduateHtml
                : graduateHtml),
            200,
          )),
    );
    final undergraduatePage = await client.fetchPage(
      source: undergraduate,
      pageUrls: [
        null,
        undergraduate.listUrls[1],
        ...List<String?>.filled(8, null)
      ],
    );
    expect(undergraduatePage.items, hasLength(1));
    expect(undergraduatePage.items.single.title, '本科招生章程');
    expect(undergraduatePage.items.single.column, '秋季统考');
    expect(undergraduatePage.items.single.publishedAt, DateTime(2026, 5, 19));
    expect(undergraduatePage.items.single.url,
        'https://bkzsw.shu.edu.cn/info/7743/38680.htm');
    expect(undergraduatePage.nextPageUrls[1],
        'https://bkzsw.shu.edu.cn/zsjz/qjtk/3.htm');

    final graduatePage = await client.fetchPage(
      source: graduate,
      pageUrls: [graduate.listUrl, null],
    );
    expect(graduatePage.items, hasLength(1));
    expect(graduatePage.items.single.title, '上海大学报考点报名公告');
    expect(graduatePage.items.single.dateText, '2026-10-08');
    expect(graduatePage.items.single.url,
        'https://yjszs.shu.edu.cn/info/1003/8914.htm');
    expect(
        graduatePage.nextPageUrls[0], 'https://yjszs.shu.edu.cn/cd/tzgg/4.htm');
    client.close();
  });

  test('new school list formats and computer notice source parse', () {
    const addedIds = <String>{
      'cs',
      'ai',
      'medicine',
      'music',
      'safa',
      'cce',
      'zhgy',
      'sfa',
      'mkszyxy',
      'law',
      'schim',
      'soe',
      'silc',
      'auto',
      'bio',
      'ulisboas',
      'utseus',
    };
    expect(addedIds, hasLength(17));
    for (final id in addedIds) {
      expect(
          AnnouncementSource.byId(id).group, AnnouncementSourceGroup.college);
    }
    final samples = <String, String>{
      'cs': '<div class="tzgg"><li><a href="/info/1.htm">'
          '<div class="tz-d"><b>06</b><span>2026-10</span></div>'
          '<div class="tz-tx"><h3>重要通知</h3></div></a></li></div>',
      'ai': '<ul class="listUL"><ul class="listUL"><li>'
          '<a href="/info/1.htm"><div class="whitespace">未来技术学院通知</div>'
          '<p class="day">2026年10月06日</p></a></li></ul></ul>',
      'medicine': '<ul class="listPageList"><li>'
          '<a href="/info/1.htm"><p>医学院通知</p><span>摘要</span></a>'
          '<div>2026-10-06</div></li></ul>',
      'cce': '<div class="listR-lb"><li><a href="/info/1.htm">'
          '继续教育通知</a><i>2026-10-06</i></li></div>',
    };
    for (final entry in samples.entries) {
      final source = AnnouncementSource.byId(entry.key);
      final items = AnnouncementApiClient.parseAnnouncementList(
        entry.value,
        baseUrl: source.listUrl,
        source: source,
      );
      expect(items, hasLength(1), reason: entry.key);
      expect(items.single.publishedAt, DateTime(2026, 10, 6));
    }
    final computer = AnnouncementSource.byId('cs');
    expect(computer.listUrls, [
      'https://cs.shu.edu.cn/index/zytz.htm',
      'https://cs.shu.edu.cn/index/xwdt.htm',
    ]);
    expect(computer.columnNames, ['重要通知', '新闻动态']);
    final news = AnnouncementApiClient.parseAnnouncementList(
      '<div class="xw-lt"><li><a href="/info/1061/1431.htm">'
      '<div class="xw-tx"><h3>学院新闻</h3><p>新闻摘要</p></div>'
      '<div class="xw-date"><b>21</b><span>2026-10</span></div>'
      '</a></li></div>',
      baseUrl: computer.listUrls[1],
      source: computer,
      column: '新闻动态',
    );
    expect(news.single.title, '学院新闻');
    expect(news.single.dateText, '2026-10-21');
    expect(news.single.column, '新闻动态');
  });

  test('alumni and foundation notices parse dates and follow pagination',
      () async {
    final cases = [
      (
        AnnouncementSource.byId('alumni'),
        '<li id="line_u5_0"><a href="../info/1021/8756.htm">'
            '奖学金通知</a><span>2025-11-25</span></li>'
            '<span class="p_pages"><a href="tzgg/10.htm">下页</a></span>',
        'https://alumni.shu.edu.cn/xwggzx/tzgg/10.htm',
        'https://alumni.shu.edu.cn/info/1021/8756.htm',
        '2025-11-25',
      ),
      (
        AnnouncementSource.byId('shuedf'),
        '<ul class="listUL"><li id="line_u4_0"><div class="listItem">'
            '<a href="../info/1005/2785.htm"><div class="whitespace">'
            '基金会声明</div><div class="abstract">2025/09/25</div>'
            '</a></div></li></ul>'
            '<a class="Next" href="tzgg/5.htm">下页</a>',
        'https://shuedf.shu.edu.cn/sylm/tzgg/5.htm',
        'https://shuedf.shu.edu.cn/info/1005/2785.htm',
        '2025-09-25',
      ),
    ];
    for (final (source, html, nextUrl, articleUrl, date) in cases) {
      expect(source.group, AnnouncementSourceGroup.schoolDepartment);
      final client = AnnouncementApiClient(
        httpClient: MockClient((_) async => http.Response(
              html,
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            )),
      );
      final page = await client.fetchPage(source: source);
      expect(page.items, hasLength(1), reason: source.id);
      expect(page.items.single.url, articleUrl);
      expect(page.items.single.dateText, date);
      expect(page.nextPageUrls.single, nextUrl);
      client.close();
    }
  });

  test('undated college lists keep source order without guessing from titles',
      () async {
    final source = AnnouncementSource.byId('sfa');
    const html = '<div class="right"><ul>'
        '<li class="notice-item"><a class="notice-title" href="/a.htm">'
        '2025-2026学年第一条通知</a></li>'
        '<li class="notice-item"><a class="notice-title" href="/b.htm">'
        '第二条公告</a></li></ul></div>';
    final client =
        AnnouncementApiClient(httpClient: MockClient((request) async {
      return http.Response.bytes(utf8.encode(html), 200);
    }));
    final items = await client.fetchAnnouncements(source: source);
    expect(items.map((item) => item.title), ['2025-2026学年第一条通知', '第二条公告']);
    expect(items.every((item) => item.publishedAt == null), isTrue);
    final sinoEuropean = AnnouncementApiClient.parseAnnouncementList(
      '<div class="content-box fr zsxx">'
      '<li id="line_u1_0"><a href="/info/1.htm">'
      '2027年推免公告</a></li></div>',
      baseUrl: AnnouncementSource.byId('utseus').listUrl,
      source: AnnouncementSource.byId('utseus'),
    );
    expect(sinoEuropean.single.publishedAt, isNull);
    expect(sinoEuropean.single.title, '2027年推免公告');
  });

  test('student columns from one college are merged by date', () async {
    final source = AnnouncementSource.byId('mat');
    final first = '<ul class="rightList"><li><a href="/a.htm">'
        '本科生奖学金通知<span>2026-10-05</span></a></li></ul>';
    final second = '<ul class="rightList"><li><a href="/b.htm">'
        '研究生奖学金通知<span>2026-10-06</span></a></li></ul>';
    final requests = <String>[];
    final client =
        AnnouncementApiClient(httpClient: MockClient((request) async {
      requests.add(request.url.toString());
      final body =
          request.url.toString() == source.listUrls.first ? first : second;
      return http.Response.bytes(utf8.encode(body), 200);
    }));
    final items = await client.fetchAnnouncements(source: source);
    expect(requests, unorderedEquals(source.listUrls));
    expect(items.map((item) => item.title), ['研究生奖学金通知', '本科生奖学金通知']);
    expect(items.map((item) => item.column), ['通知公告(研究生)', '通知公告(本科生)']);
    expect(AnnouncementListItem.fromJson(items.first.toJson()).column,
        '通知公告(研究生)');
  });

  test('selected college columns retain every title regardless of topic',
      () async {
    final source = AnnouncementSource.byId('ece');
    final first = '<ul class="rightList">'
        '<li><a href="/news.htm">学院教学新闻<span>2026-10-06</span></a></li>'
        '<li><a href="/teacher.htm">关于教师课程建设的通知'
        '<span>2026-10-05</span></a></li></ul>';
    final second = '<ul class="rightList"><li><a href="/student.htm">'
        '研究生奖学金通知<span>2026-10-04</span></a></li></ul>';
    final client =
        AnnouncementApiClient(httpClient: MockClient((request) async {
      final body =
          request.url.toString() == source.listUrls.first ? first : second;
      return http.Response.bytes(utf8.encode(body), 200);
    }));
    final items = await client.fetchAnnouncements(source: source);
    expect(items.map((item) => item.title), [
      '学院教学新闻',
      '关于教师课程建设的通知',
      '研究生奖学金通知',
    ]);
    expect(items.map((item) => item.column), [
      '本科生教学',
      '本科生教学',
      '研究生教学',
    ]);
  });

  test('detail parser keeps text, tables and links in the article body', () {
    const html = '<div class="v_news_content">'
        '<p>评审结果如下：</p>'
        '<table><tr><th>姓名</th><th>学院</th></tr>'
        '<tr><td>张同学</td><td>理学院</td></tr></table>'
        '<p><a href="/files/result.pdf">下载名单</a></p>'
        '</div>';
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      html,
      url: 'https://xgb.shu.edu.cn/info/1.htm',
      fallbackTitle: '评审公示',
    );
    expect(detail.title, '评审公示');
    expect(detail.blocks.where((block) => block.isText).first.value, '评审结果如下：');
    expect(detail.blocks.where((block) => block.isTable).single.rows, [
      ['姓名', '学院'],
      ['张同学', '理学院'],
    ]);
    expect(detail.blocks.where((block) => block.isLink).single.value,
        'https://xgb.shu.edu.cn/files/result.pdf');
  });

  test('film notice keeps paragraphs separated by br tags', () {
    const html = '<div id="vsb_content"><div class="v_news_content">'
        '影视艺术技术学院2014年硕士研究生第二批次复试通知<br><br>'
        '根据学校工作部署，相关事宜通知如下：<br><br>'
        '1、复试通知书：上午领取。<br>'
        '2、笔试时间：上午9时40分。<br><br>'
        '5：应带证件：请参照研究生院要求。<br><br><br>'
        '上海大学影视艺术技术学院<br>研究生工作办公室<br>2014年4月18日'
        '</div></div>';
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      html,
      url: 'https://sfa.shu.edu.cn/info/1212/5796.htm',
      sourceId: 'sfa',
    );
    expect(
        detail.blocks
            .where((block) => block.isText)
            .map((block) => block.value),
        [
          '影视艺术技术学院2014年硕士研究生第二批次复试通知',
          '根据学校工作部署，相关事宜通知如下：',
          '1、复试通知书：上午领取。\n2、笔试时间：上午9时40分。',
          '5：应带证件：请参照研究生院要求。',
          '上海大学影视艺术技术学院\n研究生工作办公室\n2014年4月18日',
        ]);
  });

  test('film attachments remain available and WeChat parsing is disabled', () {
    final film = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content"><p>详见附件</p></div>'
      '<a href="/system/_content/download.jsp?'
      'urltype=news.DownloadAttachUrl&amp;wbfileid=1">公告.pdf</a>',
      url: 'https://sfa.shu.edu.cn/info/1.htm',
    );
    expect(film.blocks.any((block) => block.isLink && block.label == '公告.pdf'),
        isTrue);

    final wechat = AnnouncementApiClient.parseAnnouncementDetail(
      '<h1 id="activity-name">学院新闻</h1>'
      '<div id="js_content"><p>正文内容</p>'
      '<p><img data-src="https://example.com/image.jpg"></p></div>',
      url: 'https://mp.weixin.qq.com/s/example',
      fallbackTitle: '微信公众号列表标题',
    );
    expect(wechat.title, '微信公众号列表标题');
    expect(wechat.blocks, isEmpty);
  });

  test('URL endings and split mail links follow their actual targets', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content">'
      '<p>网址 https://example.org/@team/help)，另见 '
      'https://example.org/wiki/Topic_(test)。</p>'
      '<p>邮箱：<a href="mailto:info@mathworks.cn">i</a>'
      '<a href="mailto:info@mathworks.cn">nfo@mathworks.cn</a></p>'
      '<p><a href="https://ww2.mathworks.cn/matlabcentral/answers/102901-how-do-i-update-the-license-file-used-by-the-network-license-manager">'
      'https://ww2.mathworks.cn/matlabcentral/answers/102901-how-do-i-update-the-license-file-used-by-the-network-license-manager</a></p>'
      '<p>直接写 mailto:staff@example.org，且网址跨标签 '
      'https://example.<span>org/path</span>。</p></div>',
      url: 'https://newits.shu.edu.cn/info/1095/6152.htm',
    );
    final links = detail.blocks
        .expand((block) => block.parts)
        .where((part) => part.url.isNotEmpty)
        .map((part) => (part.text, part.url))
        .toList();
    expect(links, [
      ('https://example.org/@team/help', 'https://example.org/@team/help'),
      (
        'https://example.org/wiki/Topic_(test)',
        'https://example.org/wiki/Topic_(test)'
      ),
      ('info@mathworks.cn', 'mailto:info@mathworks.cn'),
      (
        'https://ww2.mathworks.cn/matlabcentral/answers/102901-how-do-i-update-the-license-file-used-by-the-network-license-manager',
        'https://ww2.mathworks.cn/matlabcentral/answers/102901-how-do-i-update-the-license-file-used-by-the-network-license-manager'
      ),
      ('mailto:staff@example.org', 'mailto:staff@example.org'),
      ('https://example.org/path', 'https://example.org/path'),
    ]);
  });

  test('plain URL ends before adjacent Chinese article text', () {
    const url = 'https://exam.shu.edu.cn/Web/BSStudent/StudentFirstPage.aspx';
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content">'
      '<p>缴费方式（网址：$url），通过社会考生入口缴费。</p>'
      '<p>登录网站：$url下载并打印纸质准考证。</p>'
      '</div>',
      url: 'https://cce.shu.edu.cn/info/1464/20944.htm',
      sourceId: 'cce',
    );

    expect(
        detail.blocks
            .where((block) => block.isText)
            .map((block) => block.value),
        [
          '缴费方式（网址：$url），通过社会考生入口缴费。',
          '登录网站：$url下载并打印纸质准考证。',
        ]);
    final links = detail.blocks
        .expand((block) => block.parts)
        .where((part) => part.url.isNotEmpty)
        .toList();
    expect(
        links.map((part) => (part.text, part.url)), [(url, url), (url, url)]);
    expect(detail.blocks.last.parts.last.text, '下载并打印纸质准考证。');
    expect(detail.blocks.last.parts.last.url, isEmpty);
  });

  test('student office author uses the page author link', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<span id="dnn_ctr60125_ArtDetail_lblDatePosted">2026/10/19</span>'
      '<a id="dnn_ctr60125_ArtDetail_hypFirst">李博</a>'
      '<div class="v_news_content"><p>公示正文</p></div>',
      url: 'https://xgb.shu.edu.cn/info/1003/46124.htm',
      sourceId: 'xgb',
    );
    expect(detail.author, '李博');
  });

  test('VSB metadata rows show authors for IT, international and archives', () {
    for (final (sourceId, url, name) in [
      ('its', 'https://newits.shu.edu.cn/info/1095/6152.htm', '何梅'),
      ('its', 'https://newits.shu.edu.cn/info/1095/6432.htm', '吕露'),
      ('global', 'https://global.shu.edu.cn/info/1003/16043.htm', '朱珈仪'),
      ('archive', 'https://dangan.shu.edu.cn/info/1013/22126.htm', '张文燕'),
    ]) {
      final detail = AnnouncementApiClient.parseAnnouncementDetail(
        '<table><tr valign="middle" height="20"><td>'
        '<span>创建时间：</span><span>2026/09/22</span>'
        '<font face=""><span>$name</span>'
        '<font face="Times New Roman"><span>浏览次数：</span></font>'
        '</font></td></tr></table>'
        '<div class="v_news_content"><p>正文</p></div>',
        url: url,
        sourceId: sourceId,
      );
      expect(detail.author, name);
    }
  });

  test('attachment list entries remain standalone links', () {
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      '<div class="v_news_content"><ul><li>附件：'
      '<a href="/files/form.docx">申请表</a></li></ul></div>',
      url: 'https://hr.shu.edu.cn/info/1001/1.htm',
    );
    expect(detail.blocks.where((block) => block.isLink).single.label, '申请表');
    expect(detail.blocks.where((block) => block.isText).single.value, '• 附件：');
  });

  test('detail parser displays PDF pages and retains the original attachment',
      () {
    const html = '<table><tr><td class="NewsBody">'
        '<div id="vsb_content"><p><script>'
        'var vsb_pdf_image_data = ["/__local/page1.jpg", "/__local/page2.jpg"];'
        'showVsbpdfIframe("/__local/notice.pdf","100%","600");'
        '</script></p></div>'
        '<ul><li>附件<a href="/system/_content/download.jsp?'
        'urltype=news.DownloadAttachUrl&amp;wbfileid=1">附件.zip</a></li></ul>'
        '</td></tr></table>';
    final detail = AnnouncementApiClient.parseAnnouncementDetail(
      html,
      url: 'https://gs.shu.edu.cn/info/1.htm',
      fallbackTitle: '研究生通知',
    );
    expect(detail.blocks.where((block) => block.isImage).length, 2);
    expect(detail.blocks.where((block) => block.isText), isEmpty);
    expect(
        detail.blocks
            .where((block) => block.isLink)
            .map((block) => block.label),
        containsAll(['查看原始 PDF', '附件.zip']));
    final pdf = detail.blocks.firstWhere(
      (block) => block.isLink && block.label == '查看原始 PDF',
    );
    expect(pdf.value, 'https://gs.shu.edu.cn/__local/notice.pdf');
  });

  test('fetches one source page at a time and returns the next-page cursor',
      () async {
    final today = DateTime.now();
    final date = '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    final first = '<div class="only-list"><ul>'
        '<li><a href="/old.htm">旧通知</a> 2020年01月01日</li>'
        '<li><a href="/staff.htm">关于教师教学设计竞赛的通知</a> $date</li>'
        '</ul></div><div class="fanye"><a href="tzgg/2.htm">下页</a></div>';
    final second = '<div class="only-list"><ul>'
        '<li><a href="/student.htm">本科生选课通知</a> $date</li>'
        '</ul></div>';
    final requested = <Uri>[];
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        requested.add(request.url);
        if (request.url.toString() == AnnouncementSource.byId('bksy').listUrl) {
          return http.Response.bytes(utf8.encode(first), 200);
        }
        if (request.url.toString() ==
            'https://bksy.shu.edu.cn/index/tzgg/2.htm') {
          return http.Response.bytes(utf8.encode(second), 200);
        }
        return http.Response('missing', 404);
      }),
    );

    final firstPage = await client.fetchPage(
      source: AnnouncementSource.byId('bksy'),
    );
    expect(requested, hasLength(1));
    expect(firstPage.items.map((item) => item.title), ['关于教师教学设计竞赛的通知', '旧通知']);
    expect(
        firstPage.nextPageUrls, ['https://bksy.shu.edu.cn/index/tzgg/2.htm']);

    final secondPage = await client.fetchPage(
      source: AnnouncementSource.byId('bksy'),
      pageUrls: firstPage.nextPageUrls,
    );
    expect(requested, hasLength(2));
    expect(secondPage.items.map((item) => item.title), ['本科生选课通知']);
  });

  test(
      'each page fetch is complete and the list can continue past thirty items',
      () async {
    final today = DateTime.now();
    final date = '${today.year}.${today.month}.${today.day}';
    var requests = 0;
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        requests++;
        final rows = List.generate(
          15,
          (index) => '<li><a href="/info/$requests-$index.htm">'
              '<p class="bt">公告 $requests-$index</p>'
              '<p class="sj">$date</p></a></li>',
        ).join();
        final html = '<div class="ej_main"><div class="list"><ul>'
            '$rows</ul></div></div><span class="p_pages">'
            '<a href="next$requests.htm">下页</a></span>';
        return http.Response.bytes(utf8.encode(html), 200);
      }),
    );

    final firstPage = await client.fetchPage();
    expect(requests, 1);
    expect(firstPage.items, hasLength(15));
    final secondPage = await client.fetchPage(
      pageUrls: firstPage.nextPageUrls,
    );
    expect(requests, 2);
    expect(secondPage.items, hasLength(15));
    expect(
      {...firstPage.items, ...secondPage.items}.length,
      30,
    );
  });

  test('default source and cached lists are independent', () async {
    SharedPreferences.setMockInitialValues({
      'announcements.list.cache': jsonEncode([
        const AnnouncementListItem(
          title: '官网旧缓存',
          url: 'https://www.shu.edu.cn/old.htm',
        ).toJson(),
      ]),
    });
    final api = _FakeAnnouncementApiClient();
    final repository = AnnouncementRepository(apiClient: api);
    expect(
        (await repository.loadCachedAnnouncements(
          source: AnnouncementSource.official,
        ))
            .single
            .title,
        '官网旧缓存');

    final bksy = AnnouncementSource.byId('bksy');
    await repository.setDefaultSource(bksy);
    await repository.fetchAnnouncements();
    expect(api.requested, ['bksy']);
    expect((await repository.homeSummary()).text, startsWith('本科生院 · '));
    expect(
        (await repository.loadCachedAnnouncements(
          source: AnnouncementSource.official,
        ))
            .single
            .title,
        '官网旧缓存');
  });

  test('Film Academy refreshes caches from before date inference', () async {
    final source = AnnouncementSource.byId('sfa');
    SharedPreferences.setMockInitialValues({
      'announcements.cacheVersion.sfa': 6,
      'announcements.lastRefreshAt.sfa': DateTime.now().toIso8601String(),
      'announcements.list.cache.sfa': jsonEncode([
        const AnnouncementListItem(
          title: '无日期外链',
          url: 'https://example.org/old-link',
          sourceId: 'sfa',
        ).toJson(),
      ]),
    });
    final api = _FakeAnnouncementApiClient();
    await AnnouncementRepository(apiClient: api)
        .fetchAnnouncements(source: source);
    expect(api.requested, ['sfa']);
  });

  test('cached computer news remains available after restoring its column',
      () async {
    SharedPreferences.setMockInitialValues({
      'announcements.list.cache.cs': jsonEncode([
        const AnnouncementListItem(
          title: '学院新闻',
          url: 'https://cs.shu.edu.cn/info/news.htm',
          sourceId: 'cs',
          column: '新闻动态',
        ).toJson(),
        const AnnouncementListItem(
          title: '重要通知',
          url: 'https://cs.shu.edu.cn/info/notice.htm',
          sourceId: 'cs',
          column: '重要通知',
        ).toJson(),
      ]),
    });
    final repository = AnnouncementRepository();
    final cached = await repository.loadCachedAnnouncements(
      source: AnnouncementSource.byId('cs'),
    );
    expect(cached.map((item) => item.title), ['学院新闻', '重要通知']);
  });

  test('restored computer news refreshes a cache from the notice-only version',
      () async {
    final source = AnnouncementSource.byId('cs');
    SharedPreferences.setMockInitialValues({
      'announcements.cacheVersion.cs': 5,
      'announcements.lastRefreshAt.cs': DateTime.now().toIso8601String(),
      'announcements.list.cache.cs': jsonEncode([
        const AnnouncementListItem(
          title: '旧重要通知',
          url: 'https://cs.shu.edu.cn/info/old.htm',
          sourceId: 'cs',
          column: '重要通知',
        ).toJson(),
      ]),
    });
    final api = _FakeAnnouncementApiClient();
    await AnnouncementRepository(apiClient: api)
        .fetchAnnouncements(source: source);
    expect(api.requested, ['cs']);
  });

  test('favorites persist independently and allow multiple sources', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = AnnouncementRepository();
    await repository.toggleFavoriteSource(AnnouncementSource.byId('bksy'));
    await repository.toggleFavoriteSource(AnnouncementSource.byId('mat'));
    expect(await AnnouncementRepository().favoriteSourceIds(), {'bksy', 'mat'});
    expect(
        (await repository.defaultSource()).id, AnnouncementSource.officialId);

    await repository.toggleFavoriteSource(AnnouncementSource.byId('bksy'));
    expect(await AnnouncementRepository().favoriteSourceIds(), {'mat'});
  });

  test('menu group expansion persists across repository instances', () async {
    SharedPreferences.setMockInitialValues({});
    final first = AnnouncementRepository();
    expect(await first.menuExpansion(), (
      favorites: true,
      schoolPortal: true,
      college: false,
      researchInstitute: false,
      schoolDepartment: true,
    ));
    await first.saveMenuExpansion(AnnouncementMenuSection.favorites, false);
    await first.saveMenuExpansion(AnnouncementMenuSection.schoolPortal, false);
    await first.saveMenuExpansion(AnnouncementMenuSection.college, true);
    await first.saveMenuExpansion(
        AnnouncementMenuSection.researchInstitute, true);
    await first.saveMenuExpansion(
        AnnouncementMenuSection.schoolDepartment, false);

    final second = AnnouncementRepository();
    expect(await second.menuExpansion(), (
      favorites: false,
      schoolPortal: false,
      college: true,
      researchInstitute: true,
      schoolDepartment: false,
    ));
  });

  test('new portal group respects a previously collapsed school group',
      () async {
    SharedPreferences.setMockInitialValues({
      'announcements.menu.expanded.schoolDepartment': false,
    });
    final expansion = await AnnouncementRepository().menuExpansion();
    expect(expansion.schoolPortal, isFalse);
    expect(expansion.schoolDepartment, isFalse);
  });

  test('detail previews are queued three at a time and reused', () async {
    final api = _QueuedPreviewApiClient();
    final repository = AnnouncementRepository(apiClient: api);
    final items = List.generate(
      5,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/$index.htm',
        sourceId: 'bksy',
      ),
    );
    final futures = items.map(repository.loadPreview).toList();
    expect(api.requested, hasLength(3));
    final openedDetail = repository.fetchDetail(items.first);
    expect(api.requested, hasLength(3));

    api.complete(items[0].url, '第一条正文摘要');
    expect((await openedDetail).blocks.single.value, '第一条正文摘要');
    await futures[0];
    await Future<void>.delayed(Duration.zero);
    expect(api.requested, hasLength(4));

    for (final item in items.skip(1)) {
      while (!api.requested.contains(item.url)) {
        await Future<void>.delayed(Duration.zero);
      }
      api.complete(item.url, '${item.title}正文');
    }
    await Future.wait(futures);
    expect(await repository.loadPreview(items.first), '第一条正文摘要');
    expect((await repository.fetchDetail(items.first)).blocks.single.value,
        '第一条正文摘要');
    expect(api.requested, hasLength(5));
  });

  test('a fast scroll keeps the preview request backlog bounded', () async {
    final api = _QueuedPreviewApiClient();
    final repository = AnnouncementRepository(apiClient: api);
    final items = List.generate(
      50,
      (index) => AnnouncementListItem(
        title: '公告 $index',
        url: 'https://bksy.shu.edu.cn/info/1000/$index.htm',
        sourceId: 'bksy',
      ),
    );
    final requests = items.map(repository.loadPreview).toList();
    expect(api.requested, hasLength(3));
    expect(await requests.last, isNull);

    for (final item in items.take(27)) {
      while (!api.requested.contains(item.url)) {
        await Future<void>.delayed(Duration.zero);
      }
      api.complete(item.url, item.title);
    }
    await Future.wait(requests);
    expect(api.requested, hasLength(27));
  });

  test('image-only and PDF announcements use type labels in the list',
      () async {
    final api = _QueuedPreviewApiClient();
    final repository = AnnouncementRepository(apiClient: api);
    const pdf = AnnouncementListItem(
      title: 'PDF 通知',
      url: 'https://cwc.shu.edu.cn/info/pdf.htm',
      sourceId: 'cwc',
    );
    const image = AnnouncementListItem(
      title: '图片通知',
      url: 'https://bksy.shu.edu.cn/info/image.htm',
      sourceId: 'bksy',
    );
    final pdfPreview = repository.loadPreview(pdf);
    final imagePreview = repository.loadPreview(image);
    api.completeBlocks(pdf.url, const [
      AnnouncementContentBlock.image('https://cwc.shu.edu.cn/page.jpg'),
      AnnouncementContentBlock.link(
        'https://cwc.shu.edu.cn/notice.pdf',
        label: '查看原始 PDF',
      ),
    ]);
    api.completeBlocks(image.url, const [
      AnnouncementContentBlock.image('https://bksy.shu.edu.cn/image.jpg'),
    ]);
    expect(await pdfPreview, '[PDF文件]');
    expect(await imagePreview, '[图片]');
  });
}

class _FakeAnnouncementApiClient extends AnnouncementApiClient {
  final requested = <String>[];

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    requested.add(source.id);
    return AnnouncementPageBatch(
      items: [
        AnnouncementListItem(
          title: '${source.name}新通知',
          url: '${source.listUrl}/new',
          sourceId: source.id,
        ),
      ],
      nextPageUrls: List<String?>.filled(source.listUrls.length, null),
    );
  }

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource source = AnnouncementSource.official,
  }) async {
    requested.add(source.id);
    return [
      AnnouncementListItem(
        title: '${source.name}新通知',
        url: '${source.listUrl}/new',
        sourceId: source.id,
      ),
    ];
  }
}

class _QueuedPreviewApiClient extends AnnouncementApiClient {
  final requested = <String>[];
  final pending = <String, Completer<AnnouncementDetail>>{};

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    requested.add(item.url);
    final completer = Completer<AnnouncementDetail>();
    pending[item.url] = completer;
    return completer.future;
  }

  void complete(String url, String body) {
    completeBlocks(url, [AnnouncementContentBlock.text(body)]);
  }

  void completeBlocks(String url, List<AnnouncementContentBlock> blocks) {
    pending.remove(url)!.complete(AnnouncementDetail(
          title: '公告',
          url: url,
          blocks: blocks,
        ));
  }
}
