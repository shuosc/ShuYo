import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'announcement_film_date_order.dart';
import 'announcement_request_client.dart';
import 'http_timeout.dart';

class AnnouncementApiException implements Exception {
  const AnnouncementApiException(this.message,
      {this.statusCode, this.retryAfter});

  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() {
    final code = statusCode;
    if (code == null) {
      return message;
    }
    return '$message ($code)';
  }
}

/// The server confirms that this announcement no longer exists.
class AnnouncementUnavailableException extends AnnouncementApiException {
  const AnnouncementUnavailableException({super.statusCode}) : super('公告失效');
}

class AnnouncementPageBatch {
  const AnnouncementPageBatch(
      {required this.items, required this.nextPageUrls});

  final List<AnnouncementListItem> items;
  final List<String?> nextPageUrls;
}

class AnnouncementColumnPage {
  const AnnouncementColumnPage(this.items, this.nextPageUrl);

  final List<AnnouncementListItem> items;
  final String? nextPageUrl;
}

class AnnouncementApiClient {
  AnnouncementApiClient({
    http.Client? httpClient,
    bool ownsHttpClient = true,
    Duration requestTimeout = HttpTimeout.normal,
    Duration operationTimeout = HttpTimeout.composed,
    Duration retryBaseDelay = const Duration(milliseconds: 250),
    int maxRequestAttempts = 3,
    DateTime Function()? now,
  }) : _requests = AnnouncementRequestClient(
          httpClient: httpClient,
          ownsHttpClient: ownsHttpClient,
          requestTimeout: requestTimeout,
          operationTimeout: operationTimeout,
          retryBaseDelay: retryBaseDelay,
          maxAttempts: maxRequestAttempts,
          now: now,
        );

  static const _maxConcurrentParses = 4;
  static const _maxConcurrentDetailParses = _maxConcurrentParses - 1;
  final AnnouncementRequestClient _requests;
  final Queue<Completer<void>> _listParseWaiters = Queue();
  final Queue<Completer<void>> _detailParseWaiters = Queue();
  int _activeParses = 0;
  int _activeDetailParses = 0;
  bool _closed = false;

  void clearResponseCache() => _requests.clearResponseCache();

  void close() {
    if (_closed) return;
    _closed = true;
    _requests.close();
    for (final queue in [_listParseWaiters, _detailParseWaiters]) {
      while (queue.isNotEmpty) {
        queue.removeFirst().complete();
      }
    }
  }

  /// Limits isolate creation after HTTP requests have already been sent.
  /// Keep one slot available for lists while details/previews are saturated.
  Future<T> _withParse<T>(
    Future<T> Function() parse, {
    bool prioritizeList = false,
  }) async {
    if (_closed) throw StateError('AnnouncementApiClient is closed');
    if (_activeParses >= _maxConcurrentParses ||
        (!prioritizeList &&
            _activeDetailParses >= _maxConcurrentDetailParses)) {
      final waiter = Completer<void>();
      (prioritizeList ? _listParseWaiters : _detailParseWaiters).add(waiter);
      await waiter.future;
      if (_closed) throw StateError('AnnouncementApiClient is closed');
    } else {
      _activeParses++;
      if (!prioritizeList) _activeDetailParses++;
    }
    try {
      return await parse();
    } finally {
      _activeParses--;
      if (!prioritizeList) _activeDetailParses--;
      while (!_closed && _activeParses < _maxConcurrentParses) {
        if (_listParseWaiters.isNotEmpty) {
          _activeParses++;
          _listParseWaiters.removeFirst().complete();
        } else if (_detailParseWaiters.isNotEmpty &&
            _activeDetailParses < _maxConcurrentDetailParses) {
          _activeParses++;
          _activeDetailParses++;
          _detailParseWaiters.removeFirst().complete();
        } else {
          break;
        }
      }
    }
  }

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
          // A source can have many columns, all of which may finish loading in
          // one frame. Keep HTML decoding and DOM traversal off the UI isolate.
          final parsed = await _withHtml(
            pageUrl,
            (response) => _withParse(
              () => compute(
                _parseColumn,
                (
                  bytes: response.bodyBytes,
                  url: pageUrl,
                  source: source,
                  column: column
                ),
              ),
              prioritizeList: true,
            ),
          );
          var items = parsed.items;
          if (items.isEmpty) {
            throw const AnnouncementApiException(
              '公告页面结构已变化，请稍后再试',
            );
          }
          if (source.adapter.listFormat == AnnouncementListFormat.filmNotice) {
            items = await _enrichFilmNotices(items, source: source);
          }
          return (
            items: items,
            nextPageUrl: parsed.nextPageUrl,
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
    try {
      return await _withHtml(
        item.url,
        (response) => _withParse(
          () => compute(
            _parseDetailResponse,
            (
              bytes: response.bodyBytes,
              url: item.url,
              title: item.title,
              dateText: item.dateText,
              publishedAt: item.publishedAt,
              sourceId: item.sourceId,
            ),
          ),
        ),
        priority: AnnouncementRequestPriority.detail,
      );
    } on AnnouncementApiException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 410) {
        throw AnnouncementUnavailableException(statusCode: error.statusCode);
      }
      rethrow;
    }
  }

  static List<AnnouncementListItem> parseAnnouncementList(
    String html, {
    required String baseUrl,
    AnnouncementSource source = AnnouncementSource.official,
    String column = '',
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final rows = switch (source.adapter.listFormat) {
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
      AnnouncementListFormat.rightList => document
              .querySelector('div.right-list, div.list-right')
              ?.querySelectorAll('li') ??
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
      AnnouncementListFormat.shvfsNews =>
        document.querySelectorAll('ul.news-main-list > li.pr'),
      AnnouncementListFormat.whitespaceList =>
        document.querySelector('ul.listUL')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.newsBodyList =>
        document.querySelector('.news-body')?.querySelectorAll('li') ??
            const <dom.Element>[],
      AnnouncementListFormat.undergraduateAdmissions => document
              .querySelector('.list-rContent-down')
              ?.querySelectorAll('li[id^="line_u"]') ??
          const <dom.Element>[],
      AnnouncementListFormat.graduateAdmissions => document.querySelectorAll(
          '.dec-listPage .list-right ul.clearfix > li.clearfix'),
    };
    final items = <AnnouncementListItem>[];
    for (final row in rows) {
      final anchor = switch (source.adapter.listFormat) {
        AnnouncementListFormat.artList => row.querySelector('a.linkfont1'),
        AnnouncementListFormat.filmNotice =>
          row.querySelector('a.notice-title'),
        AnnouncementListFormat.shvfsNews =>
          row.querySelector('div.news-go-more a[href]'),
        _ => row.localName == 'a' ? row : row.querySelector('a'),
      };
      if (anchor == null &&
          source.adapter.listFormat != AnnouncementListFormat.mbaList) {
        continue;
      }
      final titleNode = switch (source.adapter.listFormat) {
        AnnouncementListFormat.shuHome => row.querySelector('.bt'),
        AnnouncementListFormat.artList => row.querySelector('a.linkfont1'),
        AnnouncementListFormat.mbaList => row.querySelector('div.news-title'),
        AnnouncementListFormat.nestedListUl => row.querySelector('.whitespace'),
        AnnouncementListFormat.whitespaceList =>
          row.querySelector('.whitespace'),
        AnnouncementListFormat.xwLt => row.querySelector('h3'),
        AnnouncementListFormat.listPageList => anchor?.querySelector('p'),
        AnnouncementListFormat.shvfsNews =>
          row.querySelector('div.news-item-info h2'),
        AnnouncementListFormat.graduateAdmissions => row.querySelector('h3'),
        _ => anchor,
      };
      final dateNode = switch (source.adapter.listFormat) {
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
        AnnouncementListFormat.vsbNewList => row.querySelector('i, span'),
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
        AnnouncementListFormat.shvfsNews =>
          row.querySelector('div.news-item-info > span'),
        AnnouncementListFormat.whitespaceList => row.querySelector('.abstract'),
        AnnouncementListFormat.newsBodyList => row.querySelector('.news-data'),
        AnnouncementListFormat.undergraduateAdmissions =>
          row.querySelector('i'),
        AnnouncementListFormat.graduateAdmissions => row.querySelector('span'),
        AnnouncementListFormat.onlyList => null,
      };
      final rawDate = switch (source.adapter.listFormat) {
        AnnouncementListFormat.mbaList => _mbaDate(row),
        AnnouncementListFormat.xwLt => _xwLtDate(row),
        _ => _cleanText(dateNode?.text),
      };
      var title = _cleanText(titleNode?.text);
      if (rawDate.isNotEmpty &&
          title.endsWith(rawDate) &&
          (source.adapter.listFormat == AnnouncementListFormat.sjList ||
              source.adapter.listFormat == AnnouncementListFormat.rightListUl ||
              source.adapter.listFormat == AnnouncementListFormat.vsbNewList ||
              source.adapter.listFormat ==
                  AnnouncementListFormat.bareSpanList)) {
        title = title.substring(0, title.length - rawDate.length).trim();
      }
      final href = source.adapter.listFormat == AnnouncementListFormat.mbaList
          ? RegExp(r'''window\.open\(["']([^"']+)["']''')
                  .firstMatch(row.attributes['onclick'] ?? '')
                  ?.group(1) ??
              ''
          : anchor?.attributes['href'] ?? '';
      final url = _resolveUrl(baseUrl, href);
      if (title.isEmpty || url.isEmpty) continue;
      final dateInput = rawDate.isNotEmpty
          ? rawDate
          : source.adapter.listFormat == AnnouncementListFormat.filmNotice ||
                  source.adapter.listFormat ==
                      AnnouncementListFormat.contentBoxList
              ? ''
              : row.text;
      final publishedAt = _parseDate(dateInput);
      items.add(AnnouncementListItem(
        title: title,
        url: url,
        summary: switch (source.adapter.listFormat) {
          AnnouncementListFormat.shuHome =>
            _cleanText(row.querySelector('.zy')?.text),
          AnnouncementListFormat.xwLt =>
            _cleanText(row.querySelector('.xw-tx p, .tz-tx p')?.text),
          AnnouncementListFormat.listPageList =>
            _cleanText(anchor?.querySelector('span')?.text),
          AnnouncementListFormat.filmNotice =>
            _cleanText(row.querySelector('.notice-content')?.text),
          AnnouncementListFormat.shvfsNews =>
            _cleanText(row.querySelector('div.news-item-info > p')?.text),
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
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final selector = switch (source.adapter.listFormat) {
      AnnouncementListFormat.shuHome => 'span.p_pages a',
      AnnouncementListFormat.onlyList => 'div.fanye a',
      AnnouncementListFormat.artList => 'a.Next',
      AnnouncementListFormat.vsbTable => 'a.Next, span.p_next a',
      AnnouncementListFormat.centreList => 'a.Next',
      AnnouncementListFormat.rightList =>
        'div.right-list a, div.list-right a, a.Next',
      AnnouncementListFormat.rightListUl => 'span.p_pages a, a.Next',
      AnnouncementListFormat.listPage ||
      AnnouncementListFormat.unorderedList =>
        'span.p_pages a',
      AnnouncementListFormat.bareSpanList => 'a.Next, span.p_pages a',
      AnnouncementListFormat.vsbNewList ||
      AnnouncementListFormat.sjList ||
      AnnouncementListFormat.mbaList ||
      AnnouncementListFormat.sjcList =>
        'a.Next',
      AnnouncementListFormat.nestedListUl ||
      AnnouncementListFormat.listPageList ||
      AnnouncementListFormat.listRLb ||
      AnnouncementListFormat.contentBoxList ||
      AnnouncementListFormat.whitespaceList ||
      AnnouncementListFormat.newsBodyList =>
        'a.Next',
      AnnouncementListFormat.xwLt => 'span.p_pages a',
      AnnouncementListFormat.filmNotice => 'span.p_next a',
      AnnouncementListFormat.shvfsNews => 'ul.yiiPager li.next a',
      AnnouncementListFormat.undergraduateAdmissions => 'a.Next',
      AnnouncementListFormat.graduateAdmissions =>
        '.dec-listPage span.p_next a',
    };
    final links = document.querySelectorAll(selector);
    for (final link in links) {
      if (_cleanText(link.text) != '下页' &&
          _cleanText(link.text) != '下一页' &&
          !(source.adapter.listFormat == AnnouncementListFormat.shvfsNews &&
              _cleanText(link.text) == '加载更多')) {
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

  Future<T> _withHtml<T>(
    String url,
    Future<T> Function(http.Response response) action, {
    AnnouncementRequestPriority priority = AnnouncementRequestPriority.list,
  }) =>
      _requests.withResponse(
        url,
        (response) {
          _ensureSuccess(response);
          return action(response);
        },
        priority: priority,
      );

  Future<List<AnnouncementListItem>> _enrichFilmNotices(
    List<AnnouncementListItem> items, {
    required AnnouncementSource source,
  }) async {
    final result = List<AnnouncementListItem>.of(items);
    final host = Uri.parse(source.listUrl).host;
    for (var start = 0; start < items.length; start += 3) {
      await Future.wait([
        for (var index = start;
            index < items.length && index < start + 3;
            index++)
          () async {
            final item = items[index];
            final uri = Uri.tryParse(item.url);
            if (uri == null || uri.host != host || !uri.path.endsWith('.htm')) {
              return;
            }
            try {
              final metadata = await _withHtml(
                item.url,
                (response) => _withParse(
                  () =>
                      compute(_parseFilmNoticeDateResponse, response.bodyBytes),
                ),
                priority: AnnouncementRequestPriority.detail,
              );
              final date = metadata.publishedAt;
              if (date == null) return;
              result[index] = AnnouncementListItem(
                title: item.title,
                url: item.url,
                summary: item.summary,
                dateText: metadata.dateText,
                publishedAt: date,
                sourceId: item.sourceId,
                column: item.column,
              );
            } on Object {
              // Keep the list entry when one article is unavailable.
            }
          }(),
      ]);
    }
    return inferFilmNoticeDates(result);
  }

  static AnnouncementDetail parseAnnouncementDetail(
    String html, {
    required String url,
    String sourceId = AnnouncementSource.officialId,
    String fallbackTitle = '',
    String fallbackDateText = '',
    DateTime? fallbackPublishedAt,
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? _parseDetailDocument(html);
    if (_isUnavailableAnnouncementPage(html, parsedDocument: document)) {
      throw const AnnouncementUnavailableException();
    }
    final isShvfsNews = sourceId == 'shvfs';
    final legacyMetadata = _parseVsbLegacyMetadata(document);
    final isComputerDetail = sourceId == 'cs';
    final root = document.querySelector('.nry');
    final title = _cleanText(isShvfsNews
        ? document.querySelector('header.n-detail-title > h2')?.text
        : isComputerDetail
            ? document.querySelector('.art-tit h3')?.text
            : root?.querySelector('h1')?.text ??
                (legacyMetadata == null
                    ? null
                    : document.querySelector('.Head')?.text));
    final metadata = isShvfsNews
        ? _AnnouncementMetadata(
            dateText: _cleanText(
              document.querySelector('header.n-detail-title > p')?.text,
            ).replaceFirst(RegExp(r'^时间\s*[:：]\s*'), ''),
            author: '',
            department: '',
          )
        : legacyMetadata ??
            _parseMetadata(
              isComputerDetail
                  ? document.querySelector('.art-tit p')
                  : root?.querySelector('.xx'),
              document: document,
              adapter: AnnouncementSource.byId(sourceId).adapter,
            );
    final dateText =
        metadata.dateText.isNotEmpty ? metadata.dateText : fallbackDateText;
    final contentRoot = isShvfsNews
        ? document.querySelector('div.news-detail-infowrap')
        : root?.querySelector('.v_news_content') ??
            document.querySelector('.v_news_content') ??
            document.querySelector('#vsb_content') ??
            document.querySelector('div[id^="vsb_content_"]');
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

  static dom.Document _parseDetailDocument(String html) {
    // Some VSB templates put the content div directly inside a layout table.
    // Supply its missing cell before HTML parsing can move a nested data table
    // and subsequent paragraphs outside the article body.
    final normalized = html.replaceAllMapped(
      RegExp(
        r'''(<table\b[^>]*\sclass\s*=\s*["'](?:[^"']*\s)?shuArticle(?:\s[^"']*)?["'][^>]*>)(\s*)(?=<div\b)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<tbody><tr><td>${match[2]}',
    );
    return html_parser.parse(normalized);
  }

  static bool _isUnavailableAnnouncementPage(
    String html, {
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final title = _cleanText(document.querySelector('title')?.text);
    final message = _cleanText(document.body?.text);
    final missingArticle = RegExp(r'^没有找到文章\s*ID[。！!]?$');
    return title.contains('404错误提示') ||
        (message.contains('系统提示') && message.contains('您访问的页面未找到')) ||
        document
            .querySelectorAll('.content, .v_news_content, #vsb_content')
            .any(
                (element) => missingArticle.hasMatch(_cleanText(element.text)));
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
      final href = anchor.attributes['href'] ?? '';
      final link =
          href.startsWith('mailto:') ? href : _resolveUrl(baseUrl, href);
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
      if (tag == 'table' && element.classes.contains('shuArticle')) {
        for (final child in element.children) {
          visit(child);
        }
        return;
      }
      if (tag == 'table') {
        if (_isSingleCellLayoutTable(element)) {
          for (final child in element.children) {
            visit(child);
          }
          return;
        }
        final table = _parseTable(element);
        if (table.rows.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.structuredTable(
            rows: table.rows,
            cells: table.cells,
          ));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        for (final anchor in element.querySelectorAll('a[href]')) {
          addLink(anchor);
        }
        return;
      }
      if (tag == 'div' &&
          !element.children.any((child) => const {
                'div',
                'p',
                'table',
                'ul',
                'ol',
                'li',
                'h2',
                'h3'
              }.contains(child.localName))) {
        final separated = _parseBreakSeparatedText(element);
        if (separated != null) {
          blocks.addAll(separated);
          return;
        }
        final parts = _inlineParts(element, baseUrl);
        final text = parts.map((part) => part.text).join();
        if (text.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.text(text, parts: parts));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
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
        final anchors = element.querySelectorAll('a[href]');
        if (anchors.isNotEmpty && anchors.every(_isAttachmentAnchor)) {
          var surroundingText = element.text;
          for (final anchor in anchors) {
            surroundingText = surroundingText.replaceFirst(anchor.text, '');
          }
          final text = _cleanText(surroundingText);
          if (text.isNotEmpty) {
            blocks.add(
                AnnouncementContentBlock.text(tag == 'li' ? '• $text' : text));
          }
          for (final anchor in anchors) {
            addLink(anchor);
          }
          for (final image in element.querySelectorAll('img')) {
            addImage(image);
          }
          return;
        }
        final parts = _inlineParts(element, baseUrl);
        final text = parts.map((part) => part.text).join();
        if (text.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.text(
            tag == 'li' ? '• $text' : text,
            parts: tag == 'li'
                ? [const AnnouncementInlinePart('• '), ...parts]
                : parts,
          ));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
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
      final separated = _parseBreakSeparatedText(root);
      if (separated != null) {
        blocks.addAll(separated);
      } else {
        final text = _cleanText(_visibleText(root));
        if (text.isNotEmpty) blocks.add(AnnouncementContentBlock.text(text));
      }
    }
    return blocks;
  }

  static List<AnnouncementContentBlock>? _parseBreakSeparatedText(
      dom.Element element) {
    if (element.querySelector('br') == null) return null;
    const inlineTags = {
      'span',
      'font',
      'strong',
      'b',
      'em',
      'i',
      'u',
      'sup',
      'sub'
    };

    bool isPlainInline(dom.Node node) {
      if (node is dom.Text) return true;
      if (node is! dom.Element) return false;
      if (node.localName == 'br') return true;
      return inlineTags.contains(node.localName) &&
          node.nodes.every(isPlainInline);
    }

    if (!element.nodes.every(isPlainInline)) return null;

    final source = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        source.write(node.text
            .replaceAll('\u00a0', ' ')
            .replaceAll(RegExp(r'\s+'), ' '));
      } else if (node is dom.Element) {
        if (node.localName == 'br') {
          source.write('\n');
        } else {
          for (final child in node.nodes) {
            append(child);
          }
        }
      }
    }

    for (final node in element.nodes) {
      append(node);
    }
    final blocks = <AnnouncementContentBlock>[];
    for (final paragraph in source.toString().split(RegExp(r'\n{2,}'))) {
      final lines = paragraph
          .split('\n')
          .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((line) => line.isNotEmpty);
      final text = lines.join('\n');
      if (text.isNotEmpty) blocks.add(AnnouncementContentBlock.text(text));
    }
    return blocks.isEmpty ? null : blocks;
  }

  static bool _isAttachmentAnchor(dom.Element anchor) {
    final href = anchor.attributes['href'] ?? '';
    if (href.contains('DownloadAttachUrl')) return true;
    final path = Uri.tryParse(href)?.path.toLowerCase() ?? '';
    return RegExp(r'\.(?:pdf|docx?|xlsx?|pptx?|zip|rar|7z)$').hasMatch(path);
  }

  static List<AnnouncementInlinePart> _inlineParts(
      dom.Element element, String baseUrl) {
    final raw = <AnnouncementInlinePart>[];
    void appendRaw(AnnouncementInlinePart part) {
      if (raw.isNotEmpty && raw.last.url == part.url) {
        final previous = raw.removeLast();
        raw.add(
            AnnouncementInlinePart(previous.text + part.text, url: part.url));
      } else {
        raw.add(part);
      }
    }

    void walk(dom.Node node) {
      if (node is dom.Text) {
        appendRaw(AnnouncementInlinePart(node.text));
      } else if (node is dom.Element) {
        if (const {'script', 'style', 'img'}.contains(node.localName)) return;
        if (node.localName == 'a') {
          final href = node.attributes['href'] ?? '';
          final url =
              href.startsWith('mailto:') ? href : _resolveUrl(baseUrl, href);
          appendRaw(AnnouncementInlinePart(
            node.text.trim().isEmpty ? url : node.text,
            url: url,
          ));
        } else {
          for (final child in node.nodes) {
            walk(child);
          }
        }
      }
    }

    for (final child in element.nodes) {
      walk(child);
    }
    final parts = <AnnouncementInlinePart>[];
    final autoLink = RegExp(
      r"(?:(?:https?://|www\.)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+|mailto:[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
      caseSensitive: false,
    );
    for (final part in raw) {
      final value =
          part.text.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ');
      if (part.url.isNotEmpty) {
        parts.add(AnnouncementInlinePart(value, url: part.url));
        continue;
      }
      var start = 0;
      for (final match in autoLink.allMatches(value)) {
        if (match.start > start) {
          parts
              .add(AnnouncementInlinePart(value.substring(start, match.start)));
        }
        final matched = match.group(0)!;
        final clean = _trimDetectedLink(matched);
        final lower = clean.toLowerCase();
        final url = lower.startsWith('mailto:')
            ? clean
            : lower.startsWith('www.')
                ? 'https://$clean'
                : lower.startsWith('http://') || lower.startsWith('https://')
                    ? clean
                    : 'mailto:$clean';
        parts.add(AnnouncementInlinePart(clean, url: url));
        if (clean.length < matched.length) {
          parts.add(AnnouncementInlinePart(matched.substring(clean.length)));
        }
        start = match.end;
      }
      if (start < value.length) {
        parts.add(AnnouncementInlinePart(value.substring(start)));
      }
    }
    if (parts.isEmpty) return parts;
    final first = parts.first;
    parts[0] = AnnouncementInlinePart(first.text.trimLeft(), url: first.url);
    final last = parts.last;
    parts[parts.length - 1] =
        AnnouncementInlinePart(last.text.trimRight(), url: last.url);
    return parts.where((part) => part.text.isNotEmpty).toList();
  }

  static String _trimDetectedLink(String candidate) {
    var end = candidate.length;
    while (end > 0) {
      final last = candidate[end - 1];
      if ('.!?;:,'.contains(last)) {
        end--;
        continue;
      }
      final opening = switch (last) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        _ => null,
      };
      if (opening == null) break;
      final prefix = candidate.substring(0, end);
      if (opening.allMatches(prefix).length >= last.allMatches(prefix).length) {
        break;
      }
      end--;
    }
    return candidate.substring(0, end);
  }

  static bool _isSingleCellLayoutTable(dom.Element table) {
    final rows = table.querySelectorAll('tr').where((row) {
      return row.parent == table || row.parent?.parent == table;
    }).toList();
    if (rows.length != 1) return false;

    final cells = rows.single.children.where((cell) {
      return cell.localName == 'td' || cell.localName == 'th';
    });
    if (cells.length != 1) return false;

    // Older Word-exported articles use a one-cell table as a layout wrapper
    // around paragraphs and sometimes a separate, real data table.
    const blockTags = {'div', 'p', 'table', 'ul', 'ol', 'li', 'h2', 'h3'};
    return cells.single.children
        .any((child) => blockTags.contains(child.localName));
  }

  static String _visibleText(dom.Node node) {
    if (node is dom.Text) return node.text;
    if (node is! dom.Element ||
        node.localName == 'script' ||
        node.localName == 'style') {
      return '';
    }
    final text = node.nodes.map(_visibleText).join();
    return _isTextBlock(node.localName) ? ' $text ' : text;
  }

  static bool _isTextBlock(String? tag) => const {
        'div',
        'p',
        'li',
        'ul',
        'ol',
        'table',
        'tr',
        'td',
        'th',
        'h1',
        'h2',
        'h3',
        'h4',
        'br',
      }.contains(tag);

  static _ParsedAnnouncementTable _parseTable(dom.Element table) {
    final occupied = <List<bool>>[];
    final cells = <AnnouncementTableCell>[];
    final rows = table.querySelectorAll('tr').where((row) {
      return row.parent == table || row.parent?.parent == table;
    });
    var rowIndex = 0;
    for (final row in rows) {
      while (occupied.length <= rowIndex) {
        occupied.add(<bool>[]);
      }
      var columnIndex = 0;
      final rowCells = row.children
          .where((cell) => cell.localName == 'td' || cell.localName == 'th');
      for (final cell in rowCells) {
        while (columnIndex < occupied[rowIndex].length &&
            occupied[rowIndex][columnIndex]) {
          columnIndex++;
        }
        final text = _cleanText(_visibleText(cell));
        final columnSpan = int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
        final rowSpan = int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1;
        final safeColumnSpan = columnSpan.clamp(1, 64).toInt();
        final safeRowSpan = rowSpan.clamp(1, 1000).toInt();
        cells.add(AnnouncementTableCell(
          row: rowIndex,
          column: columnIndex,
          text: text,
          rowSpan: safeRowSpan,
          columnSpan: safeColumnSpan,
          textAlignment: _tableTextAlignment(cell),
          verticalAlignment: _tableVerticalAlignment(cell),
        ));
        for (var rowOffset = 0; rowOffset < safeRowSpan; rowOffset++) {
          final targetRow = rowIndex + rowOffset;
          while (occupied.length <= targetRow) {
            occupied.add(<bool>[]);
          }
          for (var columnOffset = 0;
              columnOffset < safeColumnSpan;
              columnOffset++) {
            final targetColumn = columnIndex + columnOffset;
            while (occupied[targetRow].length <= targetColumn) {
              occupied[targetRow].add(false);
            }
            occupied[targetRow][targetColumn] = true;
          }
        }
        columnIndex += safeColumnSpan;
      }
      rowIndex++;
    }
    final columnCount = occupied.fold<int>(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    final textGrid = List.generate(
      occupied.length,
      (_) => List<String>.filled(columnCount, ''),
    );
    for (final cell in cells) {
      if (cell.row < textGrid.length && cell.column < columnCount) {
        textGrid[cell.row][cell.column] = cell.text;
      }
    }
    return _ParsedAnnouncementTable(
      rows: textGrid,
      cells: cells,
    );
  }

  static String _tableTextAlignment(dom.Element cell) {
    String? explicitAlignment(dom.Element element) {
      final attribute = _normalizedAlignment(element.attributes['align']);
      if (attribute != null) return attribute;
      if (element.localName == 'center') return 'center';
      return RegExp(r'(?:^|;)\s*text-align\s*:\s*(left|center|right|justify)\b',
              caseSensitive: false)
          .firstMatch(element.attributes['style'] ?? '')
          ?.group(1)
          ?.toLowerCase();
    }

    String? descendantAlignment;
    for (final descendant in cell.querySelectorAll('*')) {
      descendantAlignment =
          explicitAlignment(descendant) ?? descendantAlignment;
    }
    if (descendantAlignment != null) return descendantAlignment;
    for (dom.Element? current = cell;
        current != null;
        current = current.parent) {
      final alignment = explicitAlignment(current);
      if (alignment != null) return alignment;
      if (current.localName == 'table') break;
    }
    return 'left';
  }

  static String _tableVerticalAlignment(dom.Element cell) {
    String? explicitAlignment(dom.Element element) {
      final attribute = (element.attributes['valign'] ?? '').toLowerCase();
      if (const {'top', 'middle', 'bottom'}.contains(attribute)) {
        return attribute;
      }
      return RegExp(
        r'(?:^|;)\s*vertical-align\s*:\s*(top|middle|bottom)\b',
        caseSensitive: false,
      ).firstMatch(element.attributes['style'] ?? '')?.group(1)?.toLowerCase();
    }

    String? descendantAlignment;
    for (final descendant in cell.querySelectorAll('*')) {
      descendantAlignment =
          explicitAlignment(descendant) ?? descendantAlignment;
    }
    if (descendantAlignment != null) return descendantAlignment;
    for (dom.Element? current = cell;
        current != null;
        current = current.parent) {
      final alignment = explicitAlignment(current);
      if (alignment != null) return alignment;
      if (current.localName == 'table') break;
    }
    return 'middle';
  }

  static String? _normalizedAlignment(String? value) {
    final alignment = (value ?? '').toLowerCase();
    return const {'left', 'center', 'right', 'justify'}.contains(alignment)
        ? alignment
        : null;
  }

  static _AnnouncementMetadata _parseMetadata(
    dom.Element? element, {
    required dom.Document document,
    required AnnouncementSourceAdapter adapter,
  }) {
    var dateText = '';
    var author = '';
    var department = '';
    for (final span in element?.querySelectorAll('span') ?? const []) {
      final text = _cleanText(span.text);
      if (text.startsWith('发布时间：')) {
        dateText = text.substring('发布时间：'.length).trim();
      } else if (text.startsWith('时间：')) {
        final value = text.substring('时间：'.length).trim();
        final date = _parseDate(value);
        dateText = date == null
            ? value
            : '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}';
      } else if (text.startsWith('部门：')) {
        department = text.substring('部门：'.length).trim();
      } else if (text.startsWith('部门:')) {
        department = text.substring('部门:'.length).trim();
      }
    }
    final labelElements = <dom.Element>{
      for (final selector in adapter.authorLabelSelectors)
        ...document.querySelectorAll(selector),
    };
    for (final span in labelElements) {
      final text = _cleanText(span.text);
      if (!_isAuthorLabel(text)) continue;
      author = _authorValue(text);
      if (author.isEmpty) {
        final next = _cleanText(span.nextElementSibling?.text);
        if (next.isNotEmpty) author = next;
      }
      if (author.isNotEmpty) break;
    }
    if (author.isEmpty) {
      for (final selector in adapter.authorValueSelectors) {
        for (final element in document.querySelectorAll(selector)) {
          final candidate = _cleanText(element.text);
          if (candidate.isEmpty) continue;
          author =
              _isAuthorLabel(candidate) ? _authorValue(candidate) : candidate;
          if (author.isNotEmpty) break;
        }
        if (author.isNotEmpty) break;
      }
    }
    return _AnnouncementMetadata(
      dateText: dateText,
      author: author,
      department: department,
    );
  }

  static bool _isAuthorLabel(String value) =>
      value.startsWith('投稿：') ||
      value.startsWith('投稿:') ||
      value.startsWith('作者：') ||
      value.startsWith('作者:') ||
      value.startsWith('供稿：') ||
      value.startsWith('供稿:') ||
      value.startsWith('发布人：') ||
      value.startsWith('发布人:') ||
      value.startsWith('发布者：') ||
      value.startsWith('发布者:');

  static _AnnouncementMetadata? _parseVsbLegacyMetadata(dom.Document document) {
    for (final row in document.querySelectorAll('tr[valign="middle"]')) {
      var inArticleBody = false;
      for (var parent = row.parent; parent != null; parent = parent.parent) {
        if (parent.classes.contains('v_news_content') ||
            parent.id.startsWith('vsb_content')) {
          inArticleBody = true;
          break;
        }
      }
      if (inArticleBody) continue;
      final label = row.querySelector('span');
      if (!_cleanText(label?.text).startsWith('创建时间')) continue;
      final date = _parseDate(_cleanText(label?.nextElementSibling?.text));
      return _AnnouncementMetadata(
        dateText: date == null
            ? ''
            : '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}',
        author: _cleanText(row.querySelector('font[face=""] > span')?.text),
        department: '',
      );
    }
    return null;
  }

  static String _authorValue(String value) {
    final separator = value.indexOf(RegExp('[:：]'));
    return separator < 0 ? '' : value.substring(separator + 1).trim();
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
      Duration? retryAfter;
      final header = response.headers['retry-after'];
      if (header != null) {
        final seconds = int.tryParse(header.trim());
        if (seconds != null) {
          retryAfter = Duration(seconds: seconds.clamp(0, 3600));
        } else {
          try {
            final date = HttpDate.parse(header);
            retryAfter = date.difference(DateTime.now());
            if (retryAfter.isNegative) retryAfter = Duration.zero;
          } on FormatException {
            // Ignore malformed server hints.
          } on HttpException {
            // Ignore malformed server hints.
          }
        }
      }
      throw AnnouncementApiException(
        '通知公告请求失败',
        statusCode: response.statusCode,
        retryAfter: retryAfter,
      );
    }
  }
}

AnnouncementDetail _parseDetailResponse(
    ({
      List<int> bytes,
      String url,
      String title,
      String dateText,
      DateTime? publishedAt,
      String sourceId,
    }) request) {
  final html = utf8.decode(request.bytes, allowMalformed: true);
  final document = AnnouncementApiClient._parseDetailDocument(html);
  final detail = AnnouncementApiClient.parseAnnouncementDetail(
    html,
    url: request.url,
    fallbackTitle: request.title,
    fallbackDateText: request.dateText,
    fallbackPublishedAt: request.publishedAt,
    sourceId: request.sourceId,
    parsedDocument: document,
  );
  if (!detail.hasContent) {
    throw const AnnouncementApiException('公告正文无法解析');
  }
  return detail;
}

({String dateText, DateTime? publishedAt}) _parseFilmNoticeDateResponse(
    List<int> bytes) {
  final metadata = AnnouncementApiClient._parseVsbLegacyMetadata(
    html_parser.parse(utf8.decode(bytes, allowMalformed: true)),
  );
  final dateText = metadata?.dateText ?? '';
  return (
    dateText: dateText,
    publishedAt: AnnouncementApiClient._parseDate(dateText),
  );
}

class _ParsedAnnouncementTable {
  const _ParsedAnnouncementTable({required this.rows, required this.cells});

  final List<List<String>> rows;
  final List<AnnouncementTableCell> cells;
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

AnnouncementColumnPage _parseColumn(
  ({
    List<int> bytes,
    String url,
    AnnouncementSource source,
    String column,
  }) request,
) {
  final html = utf8.decode(request.bytes, allowMalformed: true);
  final document = html_parser.parse(html);
  return AnnouncementColumnPage(
    AnnouncementApiClient.parseAnnouncementList(
      html,
      baseUrl: request.url,
      source: request.source,
      column: request.column,
      parsedDocument: document,
    ),
    AnnouncementApiClient._nextPageUrl(
      html,
      baseUrl: request.url,
      source: request.source,
      parsedDocument: document,
    ),
  );
}

String _announcementUrlKey(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri == null ? url.trim() : uri.replace(fragment: '').toString();
}
