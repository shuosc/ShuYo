import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/services/announcement_article_parser.dart';
import 'package:shuyo/data/services/announcement_exception.dart';

const _url = 'https://bkzsw.shu.edu.cn/info/1798/38490.htm';

String _page(String body, {String metadata = ''}) =>
    '<meta name="pageTitle" content="文章标题">'
    '<div class="nry"><h1>文章标题</h1><div class="xx">$metadata</div>'
    '<div class="v_news_content">$body</div></div>'
    '<script>_jsq_(1798,\'/content.jsp\',38490,1364902694)</script>';

void main() {
  test(
      'one original-page parse supplies title, native fields and export identity',
      () {
    final result = AnnouncementArticleParser.parse(
      _page('<p>第一段公告正文。</p>',
          metadata: '<span>发布时间：2026年03月18日 12:00</span>'
              '<span>作者：张三</span><span>部门：宣传部</span>'),
      url: _url,
      sourceId: 'sfa',
    );
    expect(result.title, '文章标题');
    expect(result.summary, '第一段公告正文。');
    expect(result.metadata.title, '文章标题');
    expect(result.metadata.dateText, '2026-03-18');
    expect(result.metadata.publishedAt, DateTime(2026, 3, 18));
    expect(result.metadata.author, '张三');
    expect(result.metadata.department, '宣传部');
    expect(
        result.exportUrl?.removeFragment().toString(),
        'https://bkzsw.shu.edu.cn/system/resource/news/newstoword.jsp?'
        'treeid=1798&owner=1364902694&wbnewsid=38490');
    expect(result.hasContent, isTrue);
    expect(result.blocks.single.value, '第一段公告正文。');
  });

  test('legacy dates merge field by field with modern author and department',
      () {
    final html = '<table><tr valign="middle"><td>'
        '<span>发布时间：</span><span>2026/03/18</span>'
        '<font face=""><span id="article_lblTimes">'
        '<script>_showDynClicks("wbnews",1,2)</script></span></font>'
        '</td></tr></table>'
        '${_page('<p>正文</p>', metadata: '<span>作者：补全作者</span>'
            '<span>部门：补全部门</span>')}';
    final result = AnnouncementArticleParser.parse(html, url: _url);
    expect(result.metadata.dateText, '2026-03-18');
    expect(result.metadata.author, '补全作者');
    expect(result.metadata.department, '补全部门');
  });

  test('article ownership selects Vancouver content across list sources', () {
    const html = '<header class="n-detail-title"><h2>温哥华文章</h2>'
        '<p>时间：2026-10-06 09:00</p></header>'
        '<div class="news-detail-infowrap"><p>温哥华正文</p></div>'
        '<div class="v_news_content"><p>无关VSB内容</p></div>';
    final result = AnnouncementArticleParser.parse(html,
        url: 'https://www.shvfs.cn/site/newsDetail/1624', sourceId: 'sfa');
    expect(result.title, '温哥华文章');
    expect(result.metadata.dateText, '2026-10-06');
    expect(result.blocks.single.value, '温哥华正文');
    expect(result.exportUrl, isNull);
    final linkedVsb = AnnouncementArticleParser.parse(_page('<p>招生网正文</p>'),
        url: _url, sourceId: 'shvfs');
    expect(linkedVsb.blocks.single.value, '招生网正文');
  });

  test('lightweight parsing returns a bounded excerpt without article blocks',
      () {
    final text = List.filled(3000, '正文内容').join();
    final result = AnnouncementArticleParser.parse(
        _page('<h2>文章标题</h2><p>$text</p>'
            '<table><tr><td rowspan="1000">不需要构建的表格</td></tr></table>'),
        url: _url,
        includeBody: false);
    expect(result.summary, '${text.substring(0, 110)}…');
    expect(result.summary.length, 111);
    expect(result.blocks, isEmpty);
    expect(result.hasContent, isFalse);
    expect(result.exportUrl, isNotNull);
  });

  for (final sample in [
    (
      body:
          '<script>showVsbpdfIframe("/files/notice.pdf","/page1.jpg")</script>',
      summary: '[PDF文件]'
    ),
    (body: '<p><a href="/files/notice.pdf">附件.pdf</a></p>', summary: '[PDF文件]'),
    (body: '<p><img data-src="/photo.jpg"></p>', summary: '[图片]'),
    (body: '<table><tr><td>姓名</td><td>结果</td></tr></table>', summary: '[表格]'),
    (
      body: '<table><tr><td><p>单元格布局正文</p></td></tr></table>',
      summary: '单元格布局正文'
    ),
  ]) {
    test('lightweight and full parsing agree on ${sample.summary}', () {
      final html = _page(sample.body);
      final preview =
          AnnouncementArticleParser.parse(html, url: _url, includeBody: false);
      final article = AnnouncementArticleParser.parse(html, url: _url);
      expect(preview.summary, sample.summary);
      expect(preview.summary, article.summary);
      expect(preview.blocks, isEmpty);
      expect(article.hasContent, isTrue);
    });
  }

  test('readable text takes priority over PDF and image markers', () {
    final body = '<img src="/photo.jpg"><p>可读公告正文</p>'
        '<script>showVsbpdfIframe("/files/notice.pdf")</script>';
    for (final includeBody in [false, true]) {
      final result = AnnouncementArticleParser.parse(_page(body),
          url: _url, includeBody: includeBody);
      expect(result.summary, '可读公告正文');
    }
  });

  test('Word styles beside an attachment never become visible article text',
      () {
    final html = _page('<p><style><!-- p.MsoNormal { margin: 0; } '
        '@list l0 { mso-list-id: 123; } --></style>'
        '<script>editorInternalCode()</script>'
        '<span retain="true"><img '
        'src="/system/resource/images/fileTypeImages/icon_rar.gif">'
        '<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&id=1">'
        '申请材料.rar</a></span></p><div><p>请按通知提交申请材料。</p></div>');
    for (final includeBody in [false, true]) {
      final result = AnnouncementArticleParser.parse(html,
          url: 'https://utseus.shu.edu.cn/info/1010/4276.htm',
          includeBody: includeBody);
      expect(result.summary, '请按通知提交申请材料。');
      if (!includeBody) continue;
      expect(result.blocks.where((block) => block.isText).single.value,
          '请按通知提交申请材料。');
      expect(result.blocks.where((block) => block.isLink).single.label,
          '申请材料.rar');
      expect(result.blocks.where((block) => block.isImage), isEmpty);
    }
  });

  test('attachment surrounding text preserves a repeated attachment label', () {
    final html = _page('<p>请下载申请表.docx：'
        '<a href="/files/form.docx">申请表.docx</a>并按要求填写。</p>');
    final result = AnnouncementArticleParser.parse(html, url: _url);
    expect(result.blocks.first.value, '请下载申请表.docx：并按要求填写。');
    expect(result.blocks.last.label, '申请表.docx');
  });

  test('CMS attachment icons are omitted while links and article images remain',
      () {
    final attachments = [
      for (final extension in [
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'rar',
        'zip'
      ])
        '<p><span retain="true"><img '
            'orisrc="/system/resource/images/fileTypeImages/icon_$extension.gif" '
            'src="/placeholder.gif">'
            '<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&id=$extension">'
            '申请材料.$extension</a></span></p>',
    ].join();
    final html = _page('$attachments<p>申请材料说明</p>'
        '<p><img src="/__local/2/E0/CA/notice.gif"></p>'
        '<p><img src="/uploads/icon_pdf.gif"></p>');
    final result = AnnouncementArticleParser.parse(html,
        url: 'https://utseus.shu.edu.cn/info/1010/4116.htm');
    expect(result.blocks.where((block) => block.isLink), hasLength(9));
    expect(
        result.blocks
            .where((block) => block.isImage)
            .map((block) => block.value),
        [
          'https://utseus.shu.edu.cn/__local/2/E0/CA/notice.gif',
          'https://utseus.shu.edu.cn/uploads/icon_pdf.gif'
        ]);
    expect(result.summary, '申请材料说明');
  });

  for (final attribute in ['src', 'data-src', 'orisrc', 'vurl']) {
    test('a CMS icon alone is not a preview image ($attribute)', () {
      final html = _page('<p><img $attribute="'
          'https://utseus.shu.edu.cn/system/resource/images/FILETYPEIMAGES/icon_docx.gif?v=2"></p>');
      for (final includeBody in [false, true]) {
        final result = AnnouncementArticleParser.parse(html,
            url: _url, includeBody: includeBody);
        expect(result.summary, isEmpty);
        expect(result.blocks, isEmpty);
      }
    });
  }

  test('full articles preserve PDF pages, external attachments and table spans',
      () {
    final html = '${_page('<p>公告正文</p>'
            '<script>showVsbpdfIframe("/files/notice.pdf","/page1.jpg","/page2.png")</script>'
            '<table><tr><td rowspan="2">专业</td><td>人数</td></tr>'
            '<tr><td>3</td></tr></table>')}'
        '<ul><li><a href="/system/_content/download.jsp?urltype=DownloadAttachUrl&amp;id=3">'
        '附件下载</a></li></ul>';
    final result = AnnouncementArticleParser.parse(html, url: _url);
    expect(
        result.blocks
            .where((block) => block.isImage)
            .map((block) => block.value),
        [
          'https://bkzsw.shu.edu.cn/page1.jpg',
          'https://bkzsw.shu.edu.cn/page2.png',
        ]);
    expect(
        result.blocks
            .where((block) => block.isLink)
            .map((block) => block.label),
        ['查看原始 PDF', '附件下载']);
    final table = result.blocks.singleWhere((block) => block.isTable);
    expect(table.cells.first.rowSpan, 2);
    expect(table.rows, [
      ['专业', '人数'],
      ['', '3']
    ]);
    expect(result.blocks.where((block) => block.isText).single.value, '公告正文');
  });

  test(
      'malformed layout tables preserve nested data tables and later paragraphs',
      () {
    const html = '<table class="shuArticle">'
        '<div class="v_news_content"><p>第一段</p>'
        '<table><tr><td>姓名</td><td>结果</td></tr></table>'
        '<p>最后一段</p></div></table>';
    final result = AnnouncementArticleParser.parse(html, url: _url);
    expect(result.blocks.map((block) => block.type), [
      AnnouncementContentType.text,
      AnnouncementContentType.table,
      AnnouncementContentType.text,
    ]);
    expect(result.blocks.last.value, '最后一段');
    expect(
        AnnouncementArticleParser.parse(html, url: _url, includeBody: false)
            .summary,
        result.summary);
  });

  test('body labels and view counters never supply article authors', () {
    final result = AnnouncementArticleParser.parse(
        _page(
            '<p><span>作者：</span><span>正文人物</span></p>'
            '<table><tr valign="middle"><td><span>创建时间：</span><span>2099/01/01</span>'
            '<font face=""><span>表格人物</span></font></td></tr></table>',
            metadata: '<span>发布时间：2026-03-18</span>'
                '<span id="article_lblTimes"><script>_showDynClicks(1,2,3)</script></span>'),
        url: _url);
    expect(result.metadata.author, isEmpty);
    expect(result.metadata.dateText, '2026-03-18');
  });

  test('compatibility entry point preserves list fallbacks when absent in HTML',
      () {
    final result = AnnouncementArticleParser.parseAnnouncementDetail(
        '<div class="v_news_content"><p>正文</p></div>',
        url: _url,
        fallbackTitle: '列表标题',
        fallbackDateText: '2026-03-18',
        fallbackPublishedAt: DateTime(1999));
    expect(result.title, '列表标题');
    expect(result.dateText, '2026-03-18');
    expect(result.publishedAt, DateTime(2026, 3, 18));
  });

  test('one provided DOM supplies body, summary, identity and native metadata',
      () {
    final document = html_parser.parse(
        _page('<p>已解析的正文</p>', metadata: '<span>发布时间：2026-03-18</span>'));
    final result = AnnouncementArticleParser.parse('',
        url: _url, parsedDocument: document);
    expect(result.title, '文章标题');
    expect(result.summary, '已解析的正文');
    expect(result.metadata.dateText, '2026-03-18');
    expect(result.exportUrl, isNotNull);
  });

  for (final includeBody in [false, true]) {
    test(
        'HTTP-200 missing article messages are unavailable (body=$includeBody)',
        () {
      expect(
          () => AnnouncementArticleParser.parse(
              '<div class="content">没有找到文章ID</div>',
              url: _url,
              includeBody: includeBody),
          throwsA(isA<AnnouncementUnavailableException>()));
      expect(
          AnnouncementArticleParser.parse(_page('<p>如提示“没有找到文章ID”请联系管理员。</p>'),
                  url: _url, includeBody: includeBody)
              .summary,
          '如提示“没有找到文章ID”请联系管理员。');
    });
  }

  for (final body in [
    '<p>第一段</p><p>第二段</p>',
    '<div>第一行<br>第二行<br><br>第三行</div>',
    '<p>请访问<a href="https://example.org">办理入口</a>办理。</p>',
    '<ul><li>第一项</li><li>第二项</li></ul>',
    '<p>附件：<a href="/guide.pdf">指南.pdf</a></p>',
    '<div><span>第一段</span><span>第二段</span></div>',
    '<p>  多个\n 空格&nbsp;的正文 </p>',
  ]) {
    test('bounded excerpt preserves visible text: $body', () {
      final html = _page(body);
      final full = AnnouncementArticleParser.parse(html, url: _url);
      final preview =
          AnnouncementArticleParser.parse(html, url: _url, includeBody: false);
      expect(preview.summary, full.summary);
    });
  }
}
