import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/client_user_agent.dart';
import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'http_timeout.dart';

class AnnouncementApiException implements Exception {
  const AnnouncementApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    final code = statusCode;
    if (code == null) {
      return message;
    }
    return '$message ($code)';
  }
}

class AnnouncementPageBatch {
  const AnnouncementPageBatch(
      {required this.items, required this.nextPageUrls});

  final List<AnnouncementListItem> items;
  final List<String?> nextPageUrls;
}

class AnnouncementApiClient {
  AnnouncementApiClient({http.Client? httpClient})
      : _httpClient = httpClient ?? IOClient(HttpClient());

  final http.Client _httpClient;

  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource source = AnnouncementSource.official,
  }) async =>
      (await fetchPage(source: source)).items;

  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    final requestedUrls = pageUrls ?? source.listUrls;
    final columns = await Future.wait(List.generate(
      requestedUrls.length,
      (index) async {
        final pageUrl = requestedUrls[index];
        if (pageUrl == null) {
          return (
            items: <AnnouncementListItem>[],
            nextPageUrl: null as String?,
            error: null as Object?,
          );
        }
        final column =
            index < source.columnNames.length ? source.columnNames[index] : '';
        try {
          final response = await _getHtml(pageUrl);
          final html = _decodeHtml(response);
          final items = parseAnnouncementList(html,
              baseUrl: pageUrl, source: source, column: column);
          if (items.isEmpty) {
            throw const AnnouncementApiException(
              '公告页面结构已变化，请稍后再试',
            );
          }
          return (
            items: items,
            nextPageUrl: _nextPageUrl(html, baseUrl: pageUrl, source: source),
            error: null as Object?,
          );
        } on Object catch (error) {
          return (
            items: <AnnouncementListItem>[],
            nextPageUrl: pageUrl,
            error: error,
          );
        }
      },
    ));
    final activeColumns = requestedUrls.whereType<String>().length;
    final failedColumns = [
      for (var index = 0; index < columns.length; index++)
        if (requestedUrls[index] != null && columns[index].error != null)
          columns[index],
    ];
    if (activeColumns > 0 && failedColumns.length == activeColumns) {
      throw failedColumns.first.error!;
    }
    final found = columns.expand((column) => column.items);

    final unique = <String, AnnouncementListItem>{};
    for (final item in found) {
      unique.putIfAbsent(_announcementUrlKey(item.url), () => item);
    }
    final items = unique.values.toList();
    final sourceOrder = {
      for (var index = 0; index < items.length; index++)
        _announcementUrlKey(items[index].url): index,
    };
    items.sort((a, b) {
      final left = a.publishedAt;
      final right = b.publishedAt;
      if (left == null) {
        return right == null
            ? sourceOrder[_announcementUrlKey(a.url)]!
                .compareTo(sourceOrder[_announcementUrlKey(b.url)]!)
            : 1;
      }
      if (right == null) return -1;
      final dateOrder = right.compareTo(left);
      return dateOrder != 0
          ? dateOrder
          : sourceOrder[_announcementUrlKey(a.url)]!
              .compareTo(sourceOrder[_announcementUrlKey(b.url)]!);
    });
    return AnnouncementPageBatch(
      items: items,
      nextPageUrls: [
        for (var index = 0; index < columns.length; index++)
          requestedUrls[index] == null ? null : columns[index].nextPageUrl,
      ],
    );
  }

  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async {
    final response = await _getHtml(item.url);
    return parseAnnouncementDetail(
      _decodeHtml(response),
      url: item.url,
      fallbackTitle: item.title,
      fallbackDateText: item.dateText,
      fallbackPublishedAt: item.publishedAt,
    );
  }

  static List<AnnouncementListItem> parseAnnouncementList(
    String html, {
    required String baseUrl,
    AnnouncementSource source = AnnouncementSource.official,
    String column = '',
  }) {
    final document = html_parser.parse(html);
    final rows = switch (source.format) {
      AnnouncementListFormat.shuHome => document
              .querySelector('.ej_main .list')
              ?.querySelectorAll('ul > li > a') ??
          const <dom.Element>[],
      AnnouncementListFormat.onlyList => document
              .querySelector('div.only-list, div.only-list1')
              ?.querySelectorAll('li') ??
          const <dom.Element>[],
      AnnouncementListFormat.artList =>
        document.querySelectorAll('table.ArtList'),
      AnnouncementListFormat.vsbTable =>
        document.querySelectorAll('tr[id^="line_u"]'),
      AnnouncementListFormat.centreList => document
              .querySelector('div.list-centre-right-down')
              ?.querySelectorAll('li.clearfix') ??
          const <dom.Element>[],
      AnnouncementListFormat.rightList =>
        document.querySelector('div.right-list')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.rightListUl =>
        document.querySelector('ul.rightList')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.vsbNewList =>
        document.querySelectorAll('li[id^="line_u"]'),
      AnnouncementListFormat.listPage =>
        document.querySelector('ul.listPage')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.sjList => document
              .querySelector('ul.sj-list-ul')
              ?.querySelectorAll('li[id^="line_u"]') ??
          const <dom.Element>[],
      AnnouncementListFormat.bareSpanList =>
        document.querySelectorAll('li[id^="line_u"]'),
      AnnouncementListFormat.mbaList => document
              .querySelector('ul.news-list')
              ?.querySelectorAll('li.news-item') ??
          const <dom.Element>[],
      AnnouncementListFormat.sjcList => document
              .querySelector('div.jjyRight.fr')
              ?.querySelectorAll('li.clearfix') ??
          const <dom.Element>[],
      AnnouncementListFormat.nestedListUl =>
        document.querySelector('ul.listUL ul.listUL')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.xwLt =>
        document.querySelector('div.xw-lt, div.tzgg')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.listPageList =>
        document.querySelector('ul.listPageList')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.listRLb =>
        document.querySelector('div.listR-lb')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.filmNotice =>
        document.querySelectorAll('div.right li.notice-item'),
      AnnouncementListFormat.contentBoxList => document
              .querySelector('div.content-box.fr.zsxx')
              ?.querySelectorAll('li[id^="line_u"]') ??
          const <dom.Element>[],
      AnnouncementListFormat.unorderedList =>
        document.querySelector('div.list.fl > ul')?.querySelectorAll('li') ??
            const <dom.Element>[],
    };
    final items = <AnnouncementListItem>[];
    for (final row in rows) {
      final anchor = switch (source.format) {
        AnnouncementListFormat.artList => row.querySelector('a.linkfont1'),
        AnnouncementListFormat.filmNotice =>
          row.querySelector('a.notice-title'),
        _ => row.localName == 'a' ? row : row.querySelector('a'),
      };
      if (anchor == null && source.format != AnnouncementListFormat.mbaList) {
        continue;
      }
      final titleNode = switch (source.format) {
        AnnouncementListFormat.shuHome => row.querySelector('.bt'),
        AnnouncementListFormat.artList => row.querySelector('a.linkfont1'),
        AnnouncementListFormat.mbaList => row.querySelector('div.news-title'),
        AnnouncementListFormat.nestedListUl => row.querySelector('.whitespace'),
        AnnouncementListFormat.xwLt => row.querySelector('h3'),
        AnnouncementListFormat.listPageList => anchor?.querySelector('p'),
        _ => anchor,
      };
      final dateNode = switch (source.format) {
        AnnouncementListFormat.shuHome => row.querySelector('.sj'),
        AnnouncementListFormat.artList => row.querySelector('span.linkfont1'),
        AnnouncementListFormat.vsbTable => _secondTableCell(row),
        AnnouncementListFormat.centreList =>
          row.querySelector('p.list-centre-right-down-p'),
        AnnouncementListFormat.rightList ||
        AnnouncementListFormat.rightListUl ||
        AnnouncementListFormat.listPage ||
        AnnouncementListFormat.bareSpanList =>
          row.querySelector('span'),
        AnnouncementListFormat.vsbNewList => row.querySelector('i'),
        AnnouncementListFormat.sjList => row.querySelector('p'),
        AnnouncementListFormat.mbaList => row.querySelector('div.date-box'),
        AnnouncementListFormat.sjcList => row.querySelector('span.fr'),
        AnnouncementListFormat.nestedListUl => row.querySelector('.day'),
        AnnouncementListFormat.xwLt => row.querySelector('.xw-date, .tz-d'),
        AnnouncementListFormat.listPageList => row.querySelector('div'),
        AnnouncementListFormat.listRLb => row.querySelector('i'),
        AnnouncementListFormat.filmNotice ||
        AnnouncementListFormat.contentBoxList =>
          null,
        AnnouncementListFormat.unorderedList => row.querySelector('span'),
        AnnouncementListFormat.onlyList => null,
      };
      final rawDate = switch (source.format) {
        AnnouncementListFormat.mbaList => _mbaDate(row),
        AnnouncementListFormat.xwLt => _xwLtDate(row),
        _ => _cleanText(dateNode?.text),
      };
      var title = _cleanText(titleNode?.text);
      if (rawDate.isNotEmpty &&
          title.endsWith(rawDate) &&
          (source.format == AnnouncementListFormat.sjList ||
              source.format == AnnouncementListFormat.rightListUl ||
              source.format == AnnouncementListFormat.vsbNewList ||
              source.format == AnnouncementListFormat.bareSpanList)) {
        title = title.substring(0, title.length - rawDate.length).trim();
      }
      final href = source.format == AnnouncementListFormat.mbaList
          ? RegExp(r'''window\.open\(["']([^"']+)["']''')
                  .firstMatch(row.attributes['onclick'] ?? '')
                  ?.group(1) ??
              ''
          : anchor?.attributes['href'] ?? '';
      final url = _resolveUrl(baseUrl, href);
      if (title.isEmpty || url.isEmpty) continue;
      final dateInput = rawDate.isNotEmpty
          ? rawDate
          : source.format == AnnouncementListFormat.filmNotice ||
                  source.format == AnnouncementListFormat.contentBoxList
              ? ''
              : row.text;
      final publishedAt = _parseDate(dateInput);
      items.add(AnnouncementListItem(
        title: title,
        url: url,
        summary: switch (source.format) {
          AnnouncementListFormat.shuHome =>
            _cleanText(row.querySelector('.zy')?.text),
          AnnouncementListFormat.xwLt =>
            _cleanText(row.querySelector('.xw-tx p, .tz-tx p')?.text),
          AnnouncementListFormat.listPageList =>
            _cleanText(anchor?.querySelector('span')?.text),
          AnnouncementListFormat.filmNotice =>
            _cleanText(row.querySelector('.notice-content')?.text),
          _ => '',
        },
        dateText: publishedAt == null
            ? rawDate
            : '${publishedAt.year.toString().padLeft(4, '0')}-'
                '${publishedAt.month.toString().padLeft(2, '0')}-'
                '${publishedAt.day.toString().padLeft(2, '0')}',
        publishedAt: publishedAt,
        sourceId: source.id,
        column: column,
      ));
    }
    return items;
  }

  static String? _nextPageUrl(
    String html, {
    required String baseUrl,
    required AnnouncementSource source,
  }) {
    final document = html_parser.parse(html);
    final selector = switch (source.format) {
      AnnouncementListFormat.shuHome => 'span.p_pages a',
      AnnouncementListFormat.onlyList => 'div.fanye a',
      AnnouncementListFormat.artList => 'a.Next',
      AnnouncementListFormat.vsbTable => 'span.p_next a',
      AnnouncementListFormat.centreList => 'a.Next',
      AnnouncementListFormat.rightList => 'div.right-list a',
      AnnouncementListFormat.rightListUl ||
      AnnouncementListFormat.listPage ||
      AnnouncementListFormat.unorderedList =>
        'span.p_pages a',
      AnnouncementListFormat.vsbNewList ||
      AnnouncementListFormat.sjList ||
      AnnouncementListFormat.bareSpanList ||
      AnnouncementListFormat.mbaList ||
      AnnouncementListFormat.sjcList =>
        'a.Next',
      AnnouncementListFormat.nestedListUl ||
      AnnouncementListFormat.listPageList ||
      AnnouncementListFormat.listRLb ||
      AnnouncementListFormat.contentBoxList =>
        'a.Next',
      AnnouncementListFormat.xwLt => 'span.p_pages a',
      AnnouncementListFormat.filmNotice => 'span.p_next a',
    };
    final links = document.querySelectorAll(selector);
    for (final link in links) {
      if (_cleanText(link.text) != '下页' && _cleanText(link.text) != '下一页') {
        continue;
      }
      final next = _resolveUrl(baseUrl, link.attributes['href'] ?? '');
      if (next.isNotEmpty &&
          next != baseUrl &&
          Uri.parse(next).host == Uri.parse(source.listUrl).host) {
        return next;
      }
    }
    return null;
  }

  static dom.Element? _secondTableCell(dom.Element row) {
    final cells = row.querySelectorAll('td');
    return cells.length > 1 ? cells[1] : null;
  }

  static String _mbaDate(dom.Element row) {
    final day = _cleanText(row.querySelector('.date-day')?.text);
    final yearMonth = _cleanText(row.querySelector('.date-ym')?.text);
    if (day.isNotEmpty && yearMonth.isNotEmpty) {
      return '$yearMonth-$day';
    }
    return _cleanText(row.querySelector('div.date-box')?.text);
  }

  static String _xwLtDate(dom.Element row) {
    final box = row.querySelector('.xw-date, .tz-d');
    final day = _cleanText(box?.querySelector('b')?.text);
    final yearMonth = _cleanText(box?.querySelector('span')?.text);
    return day.isNotEmpty && yearMonth.isNotEmpty
        ? '$yearMonth-$day'
        : _cleanText(box?.text);
  }

  Future<http.Response> _getHtml(String url) async {
    final response = await HttpTimeout.request(
      _httpClient.get(
        Uri.parse(url),
        headers: {
          'accept': 'text/html,application/xhtml+xml',
          'user-agent': ClientUserAgent.mobileBrowser,
        },
      ),
      message: '通知公告请求超时，请稍后再试',
    );
    _ensureSuccess(response);
    return response;
  }

  static AnnouncementDetail parseAnnouncementDetail(
    String html, {
    required String url,
    String fallbackTitle = '',
    String fallbackDateText = '',
    DateTime? fallbackPublishedAt,
  }) {
    final document = html_parser.parse(html);
    final root = document.querySelector('.nry');
    final title = _cleanText(
      root?.querySelector('h1')?.text ??
          document.querySelector('#activity-name')?.text,
    );
    final metadata = _parseMetadata(root?.querySelector('.xx'));
    final dateText =
        metadata.dateText.isNotEmpty ? metadata.dateText : fallbackDateText;
    final contentRoot = root?.querySelector('.v_news_content') ??
        document.querySelector('.v_news_content') ??
        document.querySelector('#vsb_content') ??
        document.querySelector('#js_content');
    final blocks = contentRoot == null
        ? <AnnouncementContentBlock>[]
        : _parseContentBlocks(contentRoot, baseUrl: url);
    final linked = blocks
        .where((block) => block.isLink)
        .map((block) => block.value)
        .toSet();
    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      if (!href.contains('DownloadAttachUrl')) continue;
      final link = _resolveUrl(url, href);
      if (link.isEmpty || !linked.add(link)) continue;
      blocks.add(AnnouncementContentBlock.link(
        link,
        label:
            _cleanText(anchor.text).isEmpty ? '查看附件' : _cleanText(anchor.text),
      ));
    }
    return AnnouncementDetail(
      title: title.isNotEmpty ? title : fallbackTitle,
      url: url,
      dateText: dateText,
      publishedAt: _parseDate(dateText) ?? fallbackPublishedAt,
      author: metadata.author,
      department: metadata.department,
      blocks: blocks,
    );
  }

  static List<AnnouncementContentBlock> _parseContentBlocks(
    dom.Element root, {
    required String baseUrl,
  }) {
    final blocks = <AnnouncementContentBlock>[];
    final linked = <String>{};
    final imaged = <String>{};

    void addImage(dom.Element image) {
      final src = image.attributes['orisrc'] ??
          image.attributes['data-src'] ??
          image.attributes['src'] ??
          image.attributes['vurl'] ??
          '';
      final imageUrl = _resolveUrl(baseUrl, src);
      if (imageUrl.isEmpty || !imaged.add(imageUrl)) return;
      blocks.add(AnnouncementContentBlock.image(
        imageUrl,
        alt: _cleanText(image.attributes['alt'] ?? image.attributes['title']),
      ));
    }

    void addLink(dom.Element anchor) {
      final link = _resolveUrl(baseUrl, anchor.attributes['href'] ?? '');
      if (link.isEmpty || !linked.add(link)) return;
      blocks.add(AnnouncementContentBlock.link(
        link,
        label:
            _cleanText(anchor.text).isEmpty ? '查看附件' : _cleanText(anchor.text),
      ));
    }

    // VSB renders some PDFs through JavaScript. The page embeds image URLs for
    // each PDF page, which can be displayed with the same image widget as photos.
    for (final script in root.querySelectorAll('script')) {
      final code = script.text;
      final pdf = RegExp(r'''showVsbpdfIframe\(\s*["']([^"']+\.pdf)''',
              caseSensitive: false)
          .firstMatch(code);
      if (pdf == null) continue;
      for (final match in RegExp(r'''["']([^"']+\.(?:jpg|jpeg|png))["']''',
              caseSensitive: false)
          .allMatches(code)) {
        final imageUrl = _resolveUrl(baseUrl, match.group(1) ?? '');
        if (imageUrl.isEmpty || !imaged.add(imageUrl)) continue;
        blocks.add(AnnouncementContentBlock.image(imageUrl));
      }
      final pdfUrl = _resolveUrl(baseUrl, pdf.group(1) ?? '');
      if (pdfUrl.isNotEmpty && linked.add(pdfUrl)) {
        blocks.add(AnnouncementContentBlock.link(
          pdfUrl,
          label: '查看原始 PDF',
        ));
      }
    }

    void visit(dom.Element element) {
      final tag = element.localName;
      if (tag == 'style' || tag == 'script') return;
      if (tag == 'table') {
        final rows = element
            .querySelectorAll('tr')
            .map((row) {
              return row.children
                  .where((cell) =>
                      cell.localName == 'td' || cell.localName == 'th')
                  .map((cell) => _cleanText(_visibleText(cell)))
                  .toList();
            })
            .where((row) => row.any((cell) => cell.isNotEmpty))
            .toList();
        if (rows.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.table(rows));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        for (final anchor in element.querySelectorAll('a[href]')) {
          addLink(anchor);
        }
        return;
      }
      if (tag == 'img') {
        addImage(element);
        return;
      }
      if (tag == 'a') {
        addLink(element);
        return;
      }
      if (tag == 'p' || tag == 'li' || tag == 'h2' || tag == 'h3') {
        final text = _cleanText(_visibleText(element));
        final anchors = element.querySelectorAll('a[href]');
        if (text.isNotEmpty &&
            !(anchors.length == 1 && _cleanText(anchors.single.text) == text)) {
          blocks.add(AnnouncementContentBlock.text(
            tag == 'li' ? '• $text' : text,
          ));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        for (final anchor in anchors) {
          addLink(anchor);
        }
        return;
      }
      for (final child in element.children) {
        visit(child);
      }
    }

    for (final child in root.children) {
      visit(child);
    }
    if (blocks.isEmpty) {
      final text = _cleanText(_visibleText(root));
      if (text.isNotEmpty) blocks.add(AnnouncementContentBlock.text(text));
    }
    return blocks;
  }

  static String _visibleText(dom.Node node) {
    if (node is dom.Text) return node.text;
    if (node is! dom.Element ||
        node.localName == 'script' ||
        node.localName == 'style') {
      return '';
    }
    return node.nodes.map(_visibleText).join(' ');
  }

  static _AnnouncementMetadata _parseMetadata(dom.Element? element) {
    var dateText = '';
    var author = '';
    var department = '';
    for (final span in element?.querySelectorAll('span') ?? const []) {
      final text = _cleanText(span.text);
      if (text.startsWith('发布时间：')) {
        dateText = text.substring('发布时间：'.length).trim();
      } else if (text.startsWith('投稿：')) {
        author = text.substring('投稿：'.length).trim();
      } else if (text.startsWith('部门：')) {
        department = text.substring('部门：'.length).trim();
      }
    }
    return _AnnouncementMetadata(
      dateText: dateText,
      author: author,
      department: department,
    );
  }

  static DateTime? _parseDate(String value) {
    final match =
        RegExp(r'(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})').firstMatch(value);
    if (match == null) {
      return null;
    }
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day);
  }

  static String _resolveUrl(String baseUrl, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('javascript:')) {
      return '';
    }
    try {
      final resolved = Uri.parse(baseUrl).resolve(trimmed);
      return resolved.scheme == 'https' || resolved.scheme == 'http'
          ? resolved.toString()
          : '';
    } on FormatException {
      return '';
    }
  }

  static String _cleanText(String? value) {
    return (value ?? '')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AnnouncementApiException(
        '通知公告请求失败',
        statusCode: response.statusCode,
      );
    }
  }

  static String _decodeHtml(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}

class _AnnouncementMetadata {
  const _AnnouncementMetadata({
    required this.dateText,
    required this.author,
    required this.department,
  });

  final String dateText;
  final String author;
  final String department;
}

String _announcementUrlKey(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri == null ? url.trim() : uri.replace(fragment: '').toString();
}
