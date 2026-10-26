import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_list_parser.dart';

typedef _ListSample = ({String html, String pagination, String summary});

// Minimal real template shapes, including the two templates whose lists do
// not expose publication dates. They intentionally keep dates in different
// parts of a row and place a decoy mobile row outside the desktop containers.
const _samples = <AnnouncementListFormat, _ListSample>{
  AnnouncementListFormat.shuHome: (
    html: '<div class="ej_main"><div class="list"><ul><li><a '
        'href="../info/1010/1.htm"><p class="bt">公告标题</p>'
        '<p class="sj">2026.10.06</p><p class="zy">列表概览</p>'
        '</a></li></ul></div></div>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '列表概览',
  ),
  AnnouncementListFormat.onlyList: (
    html: '<div class="only-list1"><ul><li>'
        '<a href="../info/1010/1.htm">公告标题</a> 2026年10月6日'
        '</li></ul></div>',
    pagination: '<div class="fanye"><a href="../next.htm">下一页</a></div>',
    summary: '',
  ),
  AnnouncementListFormat.artList: (
    html: '<table class="ArtList"><tr><td>'
        '<a class="linkfont1" href="../info/1010/1.htm">公告标题</a>'
        '</td><td><span class="linkfont1">2026-10-06</span>'
        '</td></tr></table>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.vsbTable: (
    html: '<table><tr id="line_u1_0"><td>'
        '<a href="../info/1010/1.htm">公告标题</a></td>'
        '<td>2026/10/06 09:00:00</td></tr></table>',
    pagination: '<span class="p_next"><a href="../next.htm">下一页</a></span>',
    summary: '',
  ),
  AnnouncementListFormat.centreList: (
    html: '<div class="list-centre-right-down"><ul><li class="clearfix">'
        '<a href="../info/1010/1.htm">公告标题</a>'
        '<p class="list-centre-right-down-p">2026-10-06</p>'
        '</li></ul></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.rightList: (
    html: '<div class="right-list"><ul><li>'
        '<a href="../info/1010/1.htm">公告标题</a>'
        '<span>2026-10-06</span></li></ul></div>',
    pagination: '<div class="right-list"><a href="../next.htm">下页</a></div>',
    summary: '',
  ),
  AnnouncementListFormat.rightListUl: (
    html: '<ul class="rightList"><li><a href="../info/1010/1.htm">'
        '公告标题<span>2026-10-06</span></a></li></ul>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '',
  ),
  AnnouncementListFormat.vsbNewList: (
    html: '<li id="line_u1_0"><a href="../info/1010/1.htm">'
        '公告标题<i>2026-10-06</i></a></li>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.listPage: (
    html: '<ul class="listPage"><li>'
        '<a href="../info/1010/1.htm">公告标题</a>'
        '<span>2026/10/06</span></li></ul>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '',
  ),
  AnnouncementListFormat.sjList: (
    html: '<ul class="sj-list-ul"><li id="line_u1_0">'
        '<a href="../info/1010/1.htm">公告标题<p>2026-10-06</p>'
        '</a></li></ul>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.bareSpanList: (
    html: '<li id="line_u1_0"><a href="../info/1010/1.htm">'
        '公告标题<span>2026-10-06</span></a></li>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '',
  ),
  AnnouncementListFormat.mbaList: (
    html: '<ul class="news-list"><li class="news-item" '
        'onclick="window.open(\'../info/1010/1.htm\',\'_self\')">'
        '<div class="news-title">公告标题</div><div class="date-box">'
        '<span class="date-day">06</span><span class="date-ym">2026-10</span>'
        '</div></li></ul>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.sjcList: (
    html: '<div class="jjyRight fr"><li class="clearfix">'
        '<a href="../info/1010/1.htm">公告标题</a>'
        '<span class="fr">2026-10-06</span></li></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.nestedListUl: (
    html: '<ul class="listUL"><ul class="listUL"><li>'
        '<a href="../info/1010/1.htm"><div class="whitespace">公告标题</div>'
        '<p class="day">2026年10月06日</p></a></li></ul></ul>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.xwLt: (
    html: '<div class="tzgg"><li><a href="../info/1010/1.htm">'
        '<div class="tz-d"><b>06</b><span>2026-10</span></div>'
        '<div class="tz-tx"><h3>公告标题</h3><p>列表概览</p></div>'
        '</a></li></div>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '列表概览',
  ),
  AnnouncementListFormat.listPageList: (
    html: '<ul class="listPageList"><li><a href="../info/1010/1.htm">'
        '<p>公告标题</p><span>列表概览</span></a><div>2026-10-06</div>'
        '</li></ul>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '列表概览',
  ),
  AnnouncementListFormat.listRLb: (
    html: '<div class="listR-lb"><li>'
        '<a href="../info/1010/1.htm">公告标题</a><i>2026-10-06</i>'
        '</li></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.filmNotice: (
    html: '<div class="right"><li class="notice-item">'
        '<a class="notice-title" href="../info/1010/1.htm">公告标题</a>'
        '<p class="notice-content">列表概览</p></li></div>',
    pagination: '<span class="p_next"><a href="../next.htm">下页</a></span>',
    summary: '列表概览',
  ),
  AnnouncementListFormat.contentBoxList: (
    html: '<div class="content-box fr zsxx"><li id="line_u1_0">'
        '<a href="../info/1010/1.htm">公告标题</a></li></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.unorderedList: (
    html: '<div class="list fl"><ul><li>'
        '<a href="../info/1010/1.htm">公告标题</a><span>2026-10-06</span>'
        '</li></ul></div>',
    pagination: '<span class="p_pages"><a href="../next.htm">下页</a></span>',
    summary: '',
  ),
  AnnouncementListFormat.shvfsNews: (
    html: '<ul class="news-main-list"><li class="pr">'
        '<div class="news-item-info"><h2>公告标题</h2>'
        '<span>2026-10-06</span><p>列表概览</p></div>'
        '<div class="news-go-more"><a href="../info/1010/1.htm">了解更多</a>'
        '</div></li></ul>',
    pagination: '<ul class="yiiPager"><li class="next">'
        '<a href="../next.htm">加载更多</a></li></ul>',
    summary: '列表概览',
  ),
  AnnouncementListFormat.whitespaceList: (
    html: '<ul class="listUL"><li><div class="listItem">'
        '<a href="../info/1010/1.htm"><div class="whitespace">公告标题</div>'
        '<div class="abstract">2026/10/06</div></a></div></li></ul>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.newsBodyList: (
    html: '<div class="news-body"><li>'
        '<a href="../info/1010/1.htm">公告标题</a>'
        '<span class="news-data">2026-10-06</span></li></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.undergraduateAdmissions: (
    html: '<div class="list-rContent-down"><li id="line_u5_0">'
        '<a href="../info/1010/1.htm">公告标题</a><i>2026-10-06</i>'
        '</li></div><div class="mobile"><li id="line_u6_0">'
        '<a href="../info/1010/1.htm">移动端重复</a><i>2026-10-06</i>'
        '</li></div>',
    pagination: '<a class="Next" href="../next.htm">下页</a>',
    summary: '',
  ),
  AnnouncementListFormat.graduateAdmissions: (
    html: '<div class="dec-listPage"><div class="list-right">'
        '<ul class="clearfix"><li class="clearfix">'
        '<a href="../info/1010/1.htm"><h3>公告标题</h3>'
        '<span>[2026/10/06]</span></a></li></ul></div></div>'
        '<div class="mob-listPage"><li class="clearfix">'
        '<a href="../info/1010/1.htm">移动端重复</a></li></div>',
    pagination: '<div class="dec-listPage"><span class="p_next">'
        '<a href="../next.htm">下页</a></span></div>',
    summary: '',
  ),
};

void main() {
  test('every registered source and layout has one complete list profile', () {
    expect(AnnouncementListParser.profiles.keys,
        unorderedEquals(AnnouncementListFormat.values));
    expect(_samples.keys, unorderedEquals(AnnouncementListFormat.values));
    expect(AnnouncementSource.all, hasLength(73));
    expect(AnnouncementSource.all.expand((source) => source.listUrls),
        hasLength(118));
  });

  for (final source in AnnouncementSource.all) {
    test('${source.id}: source columns retain the complete list contract', () {
      final sample = _samples[source.adapter.listFormat]!;
      for (var index = 0; index < source.listUrls.length; index++) {
        final baseUrl = source.listUrls[index];
        final column =
            index < source.columnNames.length ? source.columnNames[index] : '';
        final items = AnnouncementListParser.parse(sample.html,
            baseUrl: baseUrl, source: source, column: column);
        expect(items, hasLength(1), reason: '$baseUrl / $column');
        final item = items.single;
        expect(item.title, '公告标题');
        expect(item.url,
            Uri.parse(baseUrl).resolve('../info/1010/1.htm').toString());
        expect(item.summary, sample.summary);
        expect(item.sourceId, source.id);
        expect(item.column, column);
        final undated = source.adapter.listFormat ==
                AnnouncementListFormat.filmNotice ||
            source.adapter.listFormat == AnnouncementListFormat.contentBoxList;
        expect(item.dateText, undated ? '' : '2026-10-06');
        expect(item.publishedAt, undated ? null : DateTime(2026, 10, 6));
        expect(
            AnnouncementListParser.nextPageUrl(sample.pagination,
                baseUrl: baseUrl, source: source),
            Uri.parse(baseUrl).resolve('../next.htm').toString());
      }
    });
  }

  test('undated templates never infer publication dates from article text', () {
    for (final sourceId in ['sfa', 'utseus']) {
      final source = AnnouncementSource.byId(sourceId);
      final html = _samples[source.adapter.listFormat]!
          .html
          .replaceAll('公告标题', '2026-10-06 举行的活动公告')
          .replaceAll('列表概览', '请于2026-10-07前报名');
      final item = AnnouncementListParser.parse(html,
              baseUrl: source.listUrl, source: source)
          .single;
      expect(item.title, '2026-10-06 举行的活动公告');
      expect(item.dateText, isEmpty);
      expect(item.publishedAt, isNull);
    }
  });

  test('list parsing preserves external announcements and rejects invalid URLs',
      () {
    final source = AnnouncementSource.byId('sfa');
    const html = '<div class="right">'
        '<li class="notice-item"><a class="notice-title" '
        'href="https://mp.weixin.qq.com/s/notice">微信通知</a></li>'
        '<li class="notice-item"><a class="notice-title" '
        'href="https://bkzsw.shu.edu.cn/info/1798/38490.htm">招生网通知</a></li>'
        '<li class="notice-item"><a class="notice-title" '
        'href="javascript:void(0)">无效</a></li>'
        '<li class="notice-item"><a class="notice-title" href="">空链接</a></li>'
        '<li class="notice-item"><a class="notice-title" href="/empty.htm"> </a></li>'
        '</div>';
    final items = AnnouncementListParser.parse(html,
        baseUrl: source.listUrl, source: source);
    expect(items.map((item) => item.title), ['微信通知', '招生网通知']);
    expect(items.every((item) => item.sourceId == 'sfa'), isTrue);
    expect(items.every((item) => item.publishedAt == null), isTrue);
  });

  test('pagination skips unsafe, foreign, current and unrelated links', () {
    for (final source in AnnouncementSource.all) {
      final baseUrl = source.listUrl;
      final pagination = _samples[source.adapter.listFormat]!.pagination;
      final invalid = [
        pagination.replaceAll('../next.htm', 'javascript:void(0)'),
        pagination.replaceAll('../next.htm', 'https://example.org/next.htm'),
        pagination.replaceAll('../next.htm', baseUrl),
        pagination
            .replaceAll('下页', '上页')
            .replaceAll('下一页', '上一页')
            .replaceAll('加载更多', '上一页'),
      ].join();
      expect(
          AnnouncementListParser.nextPageUrl(invalid,
              baseUrl: baseUrl, source: source),
          isNull,
          reason: source.id);
      expect(
          AnnouncementListParser.nextPageUrl('$invalid$pagination',
              baseUrl: baseUrl, source: source),
          Uri.parse(baseUrl).resolve('../next.htm').toString(),
          reason: source.id);
    }
  });

  test('a caller can reuse one parsed document for rows and pagination', () {
    final source = AnnouncementSource.official;
    final sample = _samples[source.adapter.listFormat]!;
    final document = html_parser.parse('${sample.html}${sample.pagination}');
    final item = AnnouncementListParser.parse('',
            baseUrl: source.listUrl, parsedDocument: document)
        .single;
    expect(item.title, '公告标题');
    expect(
        AnnouncementListParser.nextPageUrl('',
            baseUrl: source.listUrl, source: source, parsedDocument: document),
        Uri.parse(source.listUrl).resolve('../next.htm').toString());
  });
}
