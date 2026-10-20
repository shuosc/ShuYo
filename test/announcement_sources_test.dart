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
    expect(AnnouncementSource.inGroup(AnnouncementSourceGroup.campus),
        hasLength(17));
    expect(AnnouncementSource.inGroup(AnnouncementSourceGroup.college),
        hasLength(33));
    expect(
        AnnouncementSource.all.any((source) => source.id == 'modart'), isFalse);
    expect(
        AnnouncementSource.all.any((source) => source.id == 'shvfs'), isFalse);
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
    expect(computer.listUrls, ['https://cs.shu.edu.cn/index/zytz.htm']);
    expect(computer.columnNames, ['重要通知']);
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
    expect(
        detail.blocks.where((block) => block.isText).single.value, '评审结果如下：');
    expect(detail.blocks.where((block) => block.isTable).single.rows, [
      ['姓名', '学院'],
      ['张同学', '理学院'],
    ]);
    expect(detail.blocks.where((block) => block.isLink).single.value,
        'https://xgb.shu.edu.cn/files/result.pdf');
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
    expect(firstPage.items.map((item) => item.title), ['关于教师教学设计竞赛的通知']);
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

  test('cached computer news is removed with its retired source', () async {
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
    expect(cached.map((item) => item.title), ['重要通知']);
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
    expect(await first.menuExpansion(),
        (favorites: true, campus: true, college: false));
    await first.saveMenuExpansion(AnnouncementMenuSection.favorites, false);
    await first.saveMenuExpansion(AnnouncementMenuSection.campus, false);
    await first.saveMenuExpansion(AnnouncementMenuSection.college, true);

    final second = AnnouncementRepository();
    expect(await second.menuExpansion(),
        (favorites: false, campus: false, college: true));
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
