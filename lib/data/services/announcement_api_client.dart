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
import '../models/announcement_target.dart';
import 'announcement_article_parser.dart';
import 'announcement_exception.dart';
import 'announcement_export_metadata.dart';
import 'announcement_list_parser.dart';
import 'announcement_memory_cache.dart';
import 'announcement_order.dart';
import 'announcement_request_client.dart';
import 'http_timeout.dart';

export 'announcement_exception.dart';

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

/// Coordinates shared downloads and pure parsers. UI and list membership do
/// not select a department parser or maintain a second publication-date cache.
class AnnouncementApiClient {
  AnnouncementApiClient({
    http.Client? httpClient,
    bool ownsHttpClient = true,
    Duration requestTimeout = HttpTimeout.normal,
    Duration operationTimeout = HttpTimeout.composed,
    Duration retryBaseDelay = const Duration(milliseconds: 250),
    int maxRequestAttempts = 3,
    DateTime Function()? now,
  })  : _requests = AnnouncementRequestClient(
            httpClient: httpClient,
            ownsHttpClient: ownsHttpClient,
            requestTimeout: requestTimeout,
            operationTimeout: operationTimeout,
            retryBaseDelay: retryBaseDelay,
            maxAttempts: maxRequestAttempts,
            now: now),
        _now = now ?? DateTime.now,
        _articles = AnnouncementMemoryCache<_ArticleState>(
            maxEntries: 300,
            maxBytes: 1024 * 1024,
            sizeOf: (state) => state.bytes,
            now: now);

  static const _maxConcurrentParses = 4;
  static const _maxConcurrentDetailParses = _maxConcurrentParses - 1;
  static const _failureCooldown = Duration(seconds: 15);
  final AnnouncementRequestClient _requests;
  final DateTime Function() _now;
  final AnnouncementMemoryCache<_ArticleState> _articles;
  final Map<String, Future<AnnouncementArticlePage>> _pendingPages = {};
  final Map<String, Future<AnnouncementArticlePage>> _pendingBodies = {};
  final Map<String, Future<AnnouncementMetadata>> _pendingMetadata = {};
  final Map<String, int> _activeDetails = {};
  final Queue<Completer<void>> _listParseWaiters = Queue();
  final Queue<Completer<void>> _detailParseWaiters = Queue();
  int _activeParses = 0;
  int _activeDetailParses = 0;
  bool _closed = false;

  void clearResponseCache() {
    _requests.clearResponseCache();
    _articles.clear();
    _pendingPages.clear();
    _pendingBodies.clear();
    _pendingMetadata.clear();
  }

  void invalidateArticles(Iterable<String> urls) {
    final keys = urls.map(announcementUrlKey).toSet();
    final transportUrls = <String>{...keys};
    for (final key in keys) {
      final exportUrl = _articles.lookup(key)?.value.page?.exportUrl;
      if (exportUrl != null) transportUrls.add(exportUrl.toString());
      _pendingPages.remove(key);
      _pendingBodies.remove(key);
      _pendingMetadata.remove(key);
    }
    _articles.removeWhere((key, _) => keys.contains(key));
    _requests.invalidateUrls(transportUrls);
  }

  /// Optional card work may expire while a detail reader still needs the URL.
  void cancelOptionalArticle(String url) {
    final key = announcementUrlKey(url);
    if ((_activeDetails[key] ?? 0) > 0) return;
    final exportUrl = _articles.lookup(key)?.value.page?.exportUrl;
    _pendingPages.remove(key);
    _pendingMetadata.remove(key);
    _requests.cancelUrls([key, if (exportUrl != null) exportUrl.toString()]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _requests.close();
    _articles.clear();
    _pendingPages.clear();
    _pendingBodies.clear();
    _pendingMetadata.clear();
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
          final items = parsed.items;
          if (items.isEmpty) {
            throw const AnnouncementApiException(
              '公告页面结构已变化，请稍后再试',
            );
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
      unique.putIfAbsent(announcementUrlKey(item.url), () => item);
    }
    final items = orderAnnouncements(unique.values);
    return AnnouncementPageBatch(
      items: items,
      nextPageUrls: [
        for (var index = 0; index < columns.length; index++)
          requestedUrls[index] == null ? null : columns[index].nextPageUrl,
      ],
    );
  }

  _ArticleState _state(String key) =>
      _articles.lookup(key)?.value ?? const _ArticleState();

  void _storePage(String key, AnnouncementArticlePage page) {
    final state = _state(key);
    _articles.put(
        key,
        _ArticleState(
            page: AnnouncementArticlePage(
                url: page.url,
                title: page.title,
                summary: page.summary,
                metadata: page.metadata,
                exportUrl: page.exportUrl,
                blocks: const []),
            metadata: state.metadata,
            metadataRetryAt: state.metadataRetryAt));
  }

  Future<AnnouncementArticlePage> _page(AnnouncementListItem item) {
    final key = announcementUrlKey(item.url);
    final state = _state(key);
    if (state.page != null) return Future.value(state.page);
    if (state.previewRetryAt?.isAfter(_now()) ?? false) {
      return Future.error(const AnnouncementApiException('公告信息暂时不可用'));
    }
    final existing = _pendingBodies[key] ?? _pendingPages[key];
    if (existing != null) return existing;
    late final Future<AnnouncementArticlePage> task;
    task = Future<void>.value().then((_) async {
      try {
        final page = await _downloadPage(item, includeBody: false);
        if (!_closed && identical(_pendingPages[key], task)) {
          _storePage(key, page);
        }
        return page;
      } on Object {
        if (!_closed && identical(_pendingPages[key], task)) {
          final current = _state(key);
          _articles.put(
              key,
              _ArticleState(
                  metadata: current.metadata,
                  metadataRetryAt: current.metadataRetryAt,
                  previewRetryAt: _now().add(_failureCooldown)));
        }
        rethrow;
      }
    }).whenComplete(() {
      if (identical(_pendingPages[key], task)) _pendingPages.remove(key);
    });
    _pendingPages[key] = task;
    return task;
  }

  Future<AnnouncementArticlePage> _body(AnnouncementListItem item) {
    final key = announcementUrlKey(item.url);
    final pending = _pendingBodies[key];
    if (pending != null) return pending;
    late final Future<AnnouncementArticlePage> task;
    task = Future<void>.value().then((_) async {
      final page = await _downloadPage(item, includeBody: true);
      if (!_closed && identical(_pendingBodies[key], task)) {
        _storePage(key, page);
      }
      return page;
    }).whenComplete(() {
      if (identical(_pendingBodies[key], task)) _pendingBodies.remove(key);
    });
    _pendingBodies[key] = task;
    return task;
  }

  Future<AnnouncementArticlePage> _downloadPage(AnnouncementListItem item,
          {required bool includeBody}) =>
      _withHtml(
          item.url,
          (response) => _withParse(() async {
                final page = await compute(_parseArticle, (
                  bytes: response.bodyBytes,
                  url: response is http.BaseResponseWithUrl
                      ? (response as http.BaseResponseWithUrl).url.toString()
                      : item.url,
                  sourceId: item.sourceId,
                  includeBody: includeBody
                ));
                if (includeBody && !page.hasContent) {
                  throw const AnnouncementApiException('公告正文无法解析');
                }
                return page;
              }),
          priority: AnnouncementRequestPriority.detail);

  /// A card excerpt never waits for a Word export or parses a complete table.
  Future<String?> fetchPreview(AnnouncementListItem item) async {
    if (item.summary.isNotEmpty) return item.summary;
    if (!AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
        .canPreview) {
      return null;
    }
    try {
      final text = (await _page(item)).summary;
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }

  Future<AnnouncementMetadata> fetchMetadata(AnnouncementListItem item) {
    final target =
        AnnouncementTarget.resolve(item.url, sourceId: item.sourceId);
    if (!target.canLoadMetadata) {
      return Future.value(const AnnouncementMetadata());
    }
    final key = announcementUrlKey(item.url);
    final state = _state(key);
    if (state.metadata != null &&
        (state.metadataRetryAt == null ||
            state.metadataRetryAt!.isAfter(_now()))) {
      return Future.value(state.metadata);
    }
    final pending = _pendingMetadata[key];
    if (pending != null) return pending;
    late final Future<AnnouncementMetadata> task;
    task = Future<void>.value().then((_) async {
      AnnouncementMetadata metadata = const AnnouncementMetadata();
      DateTime? retryAt;
      try {
        final page = await _page(item);
        metadata = page.metadata;
        final exportUrl = page.exportUrl;
        if (exportUrl != null && identical(_pendingMetadata[key], task)) {
          final response = await _requests.getMetadataPrefix(
              exportUrl.toString(),
              isComplete: AnnouncementExportMetadata.isComplete);
          _ensureSuccess(response);
          final exported =
              AnnouncementExportMetadata.tryParse(response.bodyBytes);
          if (exported != null &&
              (page.title.isEmpty ||
                  AnnouncementExportMetadata.matchesTitle(
                      page.title, exported.title))) {
            final date = exported.publishedAt;
            metadata = AnnouncementMetadata(
                    title: exported.title,
                    dateText: exported.dateText,
                    publishedAt: DateTime(date.year, date.month, date.day),
                    author: exported.author,
                    department: exported.department)
                .withFallback(metadata);
          } else {
            // A temporary error document or stale heading must not pin a bad
            // export for the normal five-minute article cache lifetime.
            retryAt = _now().add(_failureCooldown);
            _requests.invalidateUrls([exportUrl.toString()]);
          }
        }
      } on Object {
        retryAt = _now().add(_failureCooldown);
      }
      if (!_closed && identical(_pendingMetadata[key], task)) {
        final current = _state(key);
        _articles.put(
            key,
            _ArticleState(
                page: current.page,
                metadata: metadata,
                previewRetryAt: current.previewRetryAt,
                metadataRetryAt: retryAt));
      }
      return metadata;
    }).whenComplete(() {
      if (identical(_pendingMetadata[key], task)) _pendingMetadata.remove(key);
    });
    _pendingMetadata[key] = task;
    return task;
  }

  /// List membership stays unchanged when a cross-site article supplies a date.
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) async {
    if (item.dateText.isNotEmpty) return item;
    final metadata = await fetchMetadata(item);
    if (metadata.dateText.isEmpty || metadata.publishedAt == null) return null;
    return AnnouncementListItem(
        title: item.title,
        url: item.url,
        summary: item.summary,
        dateText: metadata.dateText,
        publishedAt: metadata.publishedAt,
        sourceId: item.sourceId,
        column: item.column);
  }

  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async {
    final key = announcementUrlKey(item.url);
    _activeDetails.update(key, (value) => value + 1, ifAbsent: () => 1);
    try {
      // Start the body first, so a cold metadata request shares its original
      // download and native parse instead of creating a second DOM task.
      final body = _body(item);
      final metadata = fetchMetadata(item);
      final page = await body;
      final resolved = (await metadata)
          .withFallback(page.metadata)
          .withFallback(AnnouncementMetadata(
              dateText: item.dateText, publishedAt: item.publishedAt));
      return AnnouncementDetail(
          title: page.title.isNotEmpty ? page.title : item.title,
          url: page.url.isNotEmpty ? page.url : item.url,
          blocks: page.blocks,
          dateText: resolved.dateText,
          publishedAt: resolved.publishedAt,
          author: resolved.author,
          department: resolved.department);
    } on AnnouncementApiException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 410) {
        throw AnnouncementUnavailableException(statusCode: error.statusCode);
      }
      rethrow;
    } finally {
      final count = (_activeDetails[key] ?? 1) - 1;
      if (count <= 0) {
        _activeDetails.remove(key);
      } else {
        _activeDetails[key] = count;
      }
    }
  }

  static List<AnnouncementListItem> parseAnnouncementList(
    String html, {
    required String baseUrl,
    AnnouncementSource source = AnnouncementSource.official,
    String column = '',
    dom.Document? parsedDocument,
  }) =>
      AnnouncementListParser.parse(html,
          baseUrl: baseUrl,
          source: source,
          column: column,
          parsedDocument: parsedDocument);

  static AnnouncementDetail parseAnnouncementDetail(
    String html, {
    required String url,
    String sourceId = AnnouncementSource.officialId,
    String fallbackTitle = '',
    String fallbackDateText = '',
    DateTime? fallbackPublishedAt,
    dom.Document? parsedDocument,
  }) =>
      AnnouncementArticleParser.parseAnnouncementDetail(html,
          url: url,
          sourceId: sourceId,
          fallbackTitle: fallbackTitle,
          fallbackDateText: fallbackDateText,
          fallbackPublishedAt: fallbackPublishedAt,
          parsedDocument: parsedDocument);

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
    AnnouncementListParser.nextPageUrl(
      html,
      baseUrl: request.url,
      source: request.source,
      parsedDocument: document,
    ),
  );
}

AnnouncementArticlePage _parseArticle(
        ({
          List<int> bytes,
          String url,
          String sourceId,
          bool includeBody
        }) request) =>
    AnnouncementArticleParser.parse(
        utf8.decode(request.bytes, allowMalformed: true),
        url: request.url,
        sourceId: request.sourceId,
        includeBody: request.includeBody);

class _ArticleState {
  const _ArticleState(
      {this.page, this.metadata, this.previewRetryAt, this.metadataRetryAt});
  final AnnouncementArticlePage? page;
  final AnnouncementMetadata? metadata;
  final DateTime? previewRetryAt;
  final DateTime? metadataRetryAt;
  int get bytes {
    final p = page;
    final m = metadata;
    return 256 +
        ((p?.title.length ?? 0) +
                (p?.summary.length ?? 0) +
                (p?.metadata.author.length ?? 0) +
                (p?.metadata.department.length ?? 0) +
                (p?.exportUrl.toString().length ?? 0) +
                (m?.title.length ?? 0) +
                (m?.dateText.length ?? 0) +
                (m?.author.length ?? 0) +
                (m?.department.length ?? 0)) *
            2;
  }
}
