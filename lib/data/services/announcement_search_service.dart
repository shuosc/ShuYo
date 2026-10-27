import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'http_timeout.dart';

/// Inclusive calendar dates as chosen in the search page's date picker.
class AnnouncementSearchDateRange {
  const AnnouncementSearchDateRange({this.begin, this.end});

  final DateTime? begin;
  final DateTime? end;

  Map<String, Object> _parameters(DateTime now) {
    final first =
        begin == null ? null : DateTime(begin!.year, begin!.month, begin!.day);
    final last = end == null
        ? null
        : DateTime(end!.year, end!.month, end!.day, 23, 59, 59);
    if (first != null && last != null && first.isAfter(last)) {
      throw ArgumentError('开始日期不能晚于结束日期');
    }
    // VSB expects UTC+8 wall time without a zone suffix. Fix the upper bound
    // once per run, including unrestricted searches, rather than moving the
    // server's "now" on every page. A selected end day includes the whole day.
    final campusNow = now.toUtc().add(const Duration(hours: 8));
    return {
      'searchDateType': 'custom',
      if (first != null) 'beginDate': _format(first),
      'endDate': _format(last ?? campusNow),
    };
  }

  static String _format(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}:'
      '${date.second.toString().padLeft(2, '0')}';
}

/// One page of new results, followed by a terminal update when loading ends.
class AnnouncementSearchProgress {
  const AnnouncementSearchProgress({
    required this.totalPages,
    required this.completedPages,
    required this.discoveredArticles,
    required this.scannedArticles,
    required this.matchedArticles,
    required this.failedPages,
    this.failedArticles = 0,
    this.parseFailureCount = 0,
    this.timeoutFailureCount = 0,
    required this.newMatches,
    required this.fraction,
    required this.isComplete,
    this.isFinished = false,
    this.requestCount = 0,
    this.retryCount = 0,
    this.lastError,
  });

  final int totalPages;
  final int completedPages;
  final int discoveredArticles;
  final int scannedArticles;
  final int matchedArticles;
  final int failedPages;
  final int failedArticles;
  final int parseFailureCount;
  final int timeoutFailureCount;
  final List<AnnouncementListItem> newMatches;
  final double fraction;
  final bool isComplete;
  final bool isFinished;
  final int requestCount;
  final int retryCount;
  final String? lastError;
  int get unfinishedCount => failedPages + failedArticles;
}

/// Uses the public website-group index, with an explicit site/column scope.
/// Each run owns one transport and fetches pages sequentially. There is no
/// per-site HTML crawling, article fetching, worker pool or search-strength
/// scheduler. Results are emitted after every page for the existing list UI.
class AnnouncementSearchService {
  AnnouncementSearchService({
    http.Client Function()? clientFactory,
    this.sources = AnnouncementSource.all,
    Duration retryBaseDelay = const Duration(milliseconds: 400),
    Duration requestTimeout = HttpTimeout.normal,
    DateTime Function()? now,
  })  : _clientFactory = clientFactory ?? _createClient,
        _retryBaseDelay = retryBaseDelay,
        _requestTimeout = requestTimeout,
        _now = now ?? DateTime.now;

  static final _endpoint = Uri.parse(
    'https://www.shu.edu.cn/aop_component/webber/search/search/search/queryPage',
  );
  static const _headers = {
    'Authorization': 'preview',
    'owner': '1864855249',
    'allsite': '1',
    'Content-Type': 'application/json;charset=UTF-8',
  };
  static const _pageSize = 50;

  static http.Client _createClient() => IOClient(HttpClient()
    ..connectionTimeout = HttpTimeout.connect
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 1);

  final http.Client Function() _clientFactory;
  final List<AnnouncementSource> sources;
  final Duration _retryBaseDelay;
  final Duration _requestTimeout;
  final DateTime Function() _now;
  AnnouncementSearchRun? _active;
  bool _disposed = false;

  AnnouncementSearchRun startSearch({
    required String query,
    bool includeTitle = true,
    bool includeBody = false,
    bool retryFailures = true,
    List<AnnouncementSource>? sources,
    AnnouncementSearchDateRange? dateRange,
  }) {
    if (_disposed) throw StateError('AnnouncementSearchService is disposed');
    if (query.trim().isEmpty) throw ArgumentError.value(query, 'query');
    if (!includeTitle && !includeBody) {
      throw ArgumentError('请选择标题或正文搜索');
    }
    final selected = List<AnnouncementSource>.of(sources ?? this.sources);
    if (selected.isEmpty || selected.any((source) => !source.supportsSearch)) {
      // An empty owner means the server's default scope, not an empty search.
      // Reject unsupported selections rather than silently widening the range.
      throw ArgumentError('请选择支持搜索的部门');
    }
    final dateParameters =
        (dateRange ?? const AnnouncementSearchDateRange())._parameters(_now());
    _active?.cancel();
    late final AnnouncementSearchRun run;
    run = AnnouncementSearchRun._(
      client: _clientFactory(),
      query: query.trim(),
      scope: includeTitle ? (includeBody ? 3 : 1) : 2,
      sources: selected,
      dateParameters: dateParameters,
      retryFailures: retryFailures,
      retryBaseDelay: _retryBaseDelay,
      requestTimeout: _requestTimeout,
      onFinished: () {
        if (identical(_active, run)) _active = null;
      },
    );
    _active = run;
    return run;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active?.cancel();
    _active = null;
  }
}

class AnnouncementSearchRun {
  AnnouncementSearchRun._({
    required http.Client client,
    required String query,
    required int scope,
    required List<AnnouncementSource> sources,
    required Map<String, Object> dateParameters,
    required bool retryFailures,
    required Duration retryBaseDelay,
    required Duration requestTimeout,
    required void Function() onFinished,
  })  : _client = client,
        _query = query,
        _scope = scope,
        _dateParameters = dateParameters,
        _sourcesByOwner = {
          for (final source in sources) source.searchOwner!: source,
        },
        _retryFailures = retryFailures,
        _retryBaseDelay = retryBaseDelay,
        _requestTimeout = requestTimeout,
        _onFinished = onFinished {
    // Let the caller subscribe before even an immediately completed mock reply.
    scheduleMicrotask(_load);
  }

  final http.Client _client;
  final String _query;
  final int _scope;
  final Map<String, Object> _dateParameters;
  final Map<String, AnnouncementSource> _sourcesByOwner;
  final bool _retryFailures;
  final Duration _retryBaseDelay;
  final Duration _requestTimeout;
  final void Function() _onFinished;
  final _updates = StreamController<AnnouncementSearchProgress>.broadcast();
  final _finished = Completer<AnnouncementSearchProgress>();
  final _cancelled = Completer<void>();
  final _seen = <String>{};
  int _total = 0;
  int _totalPages = 0;
  int _completedPages = 0;
  int _scanned = 0;
  int _matched = 0;
  int _requests = 0;
  int _retries = 0;
  bool _closed = false;
  Timer? _retryTimer;
  Completer<void>? _retryWait;

  Stream<AnnouncementSearchProgress> get updates => _updates.stream;
  Future<AnnouncementSearchProgress> get finished => _finished.future;

  Future<void> _load() async {
    try {
      for (var current = 0; !_closed; current++) {
        final page = await _fetchPage(current);
        if (_closed) return;
        final records = page['records'];
        if (records != null && records is! List) {
          throw const FormatException('搜索结果格式异常');
        }
        final total = page['total'];
        final size = page['size'];
        if (total is! num ||
            total < 0 ||
            size is! num ||
            size <= 0 ||
            page['current'] != current) {
          throw const FormatException('搜索分页格式异常');
        }
        _total = total.toInt();
        _totalPages = (_total / size).ceil();
        final rows = (records as List?) ?? const [];
        if (rows.isEmpty && current * size < _total) {
          throw const FormatException('搜索分页提前结束，请重试');
        }
        final matches = <AnnouncementListItem>[];
        for (final raw in rows) {
          if (raw is! Map) throw const FormatException('搜索结果格式异常');
          final item = _parseItem(raw);
          if (item != null &&
              _seen.add('${item.sourceId}\u0000${item.url}\u0000'
                  '${item.title.trim().toLowerCase()}')) {
            matches.add(item);
          }
        }
        _scanned += rows.length;
        _matched += matches.length;
        _completedPages++;
        final done = (current + 1) * size >= _total;
        final progress = _progress(
          newMatches: matches,
          complete: done,
          finished: done,
        );
        if (done) {
          _finish(progress);
          return;
        }
        _updates.add(progress);
        await Future<void>.delayed(Duration.zero);
      }
    } on Object catch (error) {
      if (_closed) return;
      _finish(_progress(
        finished: true,
        failedPages: 1,
        parseFailures: error is FormatException ? 1 : 0,
        timeoutFailures: error is TimeoutException ? 1 : 0,
        lastError: error.toString(),
      ));
    }
  }

  Future<Map> _fetchPage(int current) async {
    final body = jsonEncode({
      'aliasName': 'article_data',
      'keyWord': _query,
      'searchKeyWord': true,
      'searchAggregation': false,
      'searchType': 'text',
      'searchScope': _scope,
      'searchOperator': 1,
      'orderType': 'date',
      'allsite': true,
      'owner': _sourcesByOwner.keys.join(','),
      'columnId': _sourcesByOwner.values
          .expand((source) => source.searchColumnIds)
          .toSet()
          .join(','),
      'auditing': ['1'],
      ..._dateParameters,
      'page': {'current': current, 'size': AnnouncementSearchService._pageSize},
    });
    for (var attempt = 0;; attempt++) {
      if (_closed) throw const _SearchCancelled();
      final abort = Completer<void>();
      try {
        _requests++;
        final request = http.AbortableRequest(
          'POST',
          AnnouncementSearchService._endpoint,
          abortTrigger: Future.any([_cancelled.future, abort.future]),
        )
          ..headers.addAll(AnnouncementSearchService._headers)
          ..bodyBytes = utf8.encode(body);
        final response = await Future.any([
          _client.send(request).then(http.Response.fromStream),
          _cancelled.future
              .then<http.Response>((_) => throw const _SearchCancelled()),
        ]).timeout(_requestTimeout, onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw TimeoutException('搜索请求超时', _requestTimeout);
        });
        if (_closed) throw const _SearchCancelled();
        if (response.statusCode != HttpStatus.ok) {
          throw _SearchApiException(
            '搜索请求失败（${response.statusCode}）',
            retryable: response.statusCode == 408 ||
                response.statusCode == 429 ||
                response.statusCode >= 500,
          );
        }
        final result = jsonDecode(utf8.decode(response.bodyBytes));
        if (result is! Map || result['code'] != '0000') {
          throw const _SearchApiException('搜索接口返回失败');
        }
        final data = result['data'];
        if (data is! Map || data['page'] is! Map) {
          throw const FormatException('搜索接口返回格式异常');
        }
        return data['page'] as Map;
      } on Object catch (error) {
        if (_closed || error is _SearchCancelled) rethrow;
        final retryable = error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException ||
            (error is _SearchApiException && error.retryable);
        if (!_retryFailures || attempt >= 2 || !retryable) rethrow;
        _retries++;
        _retryWait = Completer<void>();
        _retryTimer = Timer(_retryBaseDelay * (1 << attempt), () {
          _retryWait?.complete();
          _retryWait = null;
        });
        await _retryWait!.future;
        _retryTimer = null;
      }
    }
  }

  AnnouncementListItem? _parseItem(Map record) {
    if (record['index'] != 'article_data') return null;
    final source = _sourcesByOwner[record['owner']?.toString()];
    if (source == null ||
        !source.searchColumnIds.contains(record['column']?.toString())) {
      return null;
    }
    final title = _plainText(record['title']);
    final rawUrl = record['url'];
    if (title.isEmpty || rawUrl is! String || rawUrl.trim().isEmpty) {
      throw const FormatException('搜索文章缺少标题或地址');
    }
    final uri = Uri.parse(source.listUrl).resolve(rawUrl.trim());
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('搜索文章地址无效');
    }
    final created = record['createDate'];
    final publishedAt = created is String ? DateTime.tryParse(created) : null;
    final dateText = publishedAt == null
        ? ''
        : '${publishedAt.year}-${publishedAt.month.toString().padLeft(2, '0')}-'
            '${publishedAt.day.toString().padLeft(2, '0')}';
    return AnnouncementListItem(
      title: title,
      url: uri.removeFragment().toString(),
      summary:
          _plainText(record['intro'] ?? record['content'] ?? record['summary']),
      dateText: dateText,
      publishedAt: publishedAt,
      sourceId: source.id,
      column:
          source.adapter.hideListColumn ? '' : _plainText(record['columnName']),
    );
  }

  static String _plainText(Object? value) {
    if (value is! String || value.isEmpty) return '';
    if (!value.contains('<') && !value.contains('&')) {
      return value.replaceAll(_whitespace, ' ').trim();
    }
    final fragment = html_parser.parseFragment(value);
    for (final element in fragment.querySelectorAll('script,style')) {
      element.remove();
    }
    return (fragment.text ?? '').replaceAll(_whitespace, ' ').trim();
  }

  static final _whitespace = RegExp(r'\s+');

  AnnouncementSearchProgress _progress({
    List<AnnouncementListItem> newMatches = const [],
    bool complete = false,
    bool finished = false,
    int failedPages = 0,
    int parseFailures = 0,
    int timeoutFailures = 0,
    String? lastError,
  }) =>
      AnnouncementSearchProgress(
        totalPages: _totalPages,
        completedPages: _completedPages,
        discoveredArticles: _total,
        scannedArticles: _scanned,
        matchedArticles: _matched,
        failedPages: failedPages,
        parseFailureCount: parseFailures,
        timeoutFailureCount: timeoutFailures,
        newMatches: List.unmodifiable(newMatches),
        fraction: complete
            ? 1
            : (_totalPages == 0
                ? 0
                : (_completedPages / _totalPages).clamp(0, 1)),
        isComplete: complete,
        isFinished: finished,
        requestCount: _requests,
        retryCount: _retries,
        lastError: lastError,
      );

  void _finish(AnnouncementSearchProgress progress) {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    _retryWait?.complete();
    _retryWait = null;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _client.close();
    _updates.add(progress);
    _finished.complete(progress);
    unawaited(_updates.close());
    _onFinished();
  }

  /// Retained for page disposal and replacing an in-flight query.
  void cancel() => _finish(_progress(finished: true));
}

class _SearchApiException implements Exception {
  const _SearchApiException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class _SearchCancelled implements Exception {
  const _SearchCancelled();
}
