import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'announcement_api_client.dart';
import 'announcement_film_date_order.dart';
import 'announcement_search_service.dart';

class AnnouncementSearchProfile {
  const AnnouncementSearchProfile(this.clientCount, this.pagePause,
      this.hostLimit, this.networkLimit, this.firstPageLimit);

  final int clientCount;
  final Duration pagePause;
  final int hostLimit;
  final int networkLimit;
  final int firstPageLimit;

  static const profiles = [
    AnnouncementSearchProfile(24, Duration(seconds: 25), 2, 4, 2),
    AnnouncementSearchProfile(40, Duration(seconds: 16), 2, 6, 3),
    AnnouncementSearchProfile(64, Duration(seconds: 11), 2, 8, 4),
    AnnouncementSearchProfile(96, Duration(seconds: 7), 2, 12, 5),
    AnnouncementSearchProfile(144, Duration(seconds: 4), 3, 16, 6),
    AnnouncementSearchProfile(200, Duration.zero, 3, 24, 6),
  ];

  static const _desiredBodyParses = [1, 2, 3, 4, 5, 6];
  static const _desiredTotalParses = [3, 4, 5, 6, 8, 10];

  int get _strengthIndex {
    final index =
        profiles.indexWhere((entry) => entry.clientCount == clientCount);
    return index < 0 ? 0 : index;
  }

  int get desiredBodyParses => _desiredBodyParses[_strengthIndex];
  int get desiredTotalParses => _desiredTotalParses[_strengthIndex];

  static AnnouncementSearchProfile forStrength(int strength) =>
      profiles[strength.clamp(0, profiles.length - 1)];
}

/// A bounded, short-lived cache shared by searches started from one page.
class AnnouncementSearchCache {
  final LinkedHashMap<String, _CachedDocument> _documents = LinkedHashMap();
  final LinkedHashMap<String, _CachedBodyText> _bodyTexts = LinkedHashMap();
  int _bytes = 0;
  int _bodyTextBytes = 0;

  static const _maxEntries = 300;
  static const _maxBytes = 16 * 1024 * 1024;
  static const _maxBodyTextBytes = 8 * 1024 * 1024;
  static const _ttl = Duration(minutes: 5);

  _CachedDocument? _lookup(String url) {
    final key = searchUrlKey(url);
    final entry = _documents.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.createdAt) >= _ttl) {
      _bytes -= entry.size;
      return null;
    }
    _documents[key] = entry;
    return entry;
  }

  void put(String url, http.Response response) {
    final size = response.bodyBytes.length;
    if (size > _maxBytes) return;
    final key = searchUrlKey(url);
    final previous = _documents.remove(key);
    if (previous != null) _bytes -= previous.size;
    _documents[key] = _CachedDocument(response, size);
    _bytes += size;
    while (_documents.length > _maxEntries || _bytes > _maxBytes) {
      final oldest = _documents.remove(_documents.keys.first)!;
      _bytes -= oldest.size;
    }
  }

  void evict(String url) {
    final entry = _documents.remove(searchUrlKey(url));
    if (entry != null) _bytes -= entry.size;
  }

  String? bodyText(String sourceId, String url) {
    final key = '$sourceId\u0000${searchUrlKey(url)}';
    final entry = _bodyTexts.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.createdAt) >= _ttl) {
      _bodyTextBytes -= entry.size;
      return null;
    }
    _bodyTexts[key] = entry;
    return entry.text;
  }

  void putBodyText(String sourceId, String url, String text) {
    final size = text.length * 2;
    if (size > _maxBodyTextBytes) return;
    final key = '$sourceId\u0000${searchUrlKey(url)}';
    final previous = _bodyTexts.remove(key);
    if (previous != null) _bodyTextBytes -= previous.size;
    _bodyTexts[key] = _CachedBodyText(text, size);
    _bodyTextBytes += size;
    while (_bodyTextBytes > _maxBodyTextBytes) {
      final oldest = _bodyTexts.remove(_bodyTexts.keys.first)!;
      _bodyTextBytes -= oldest.size;
    }
  }

  void clear() {
    _documents.clear();
    _bodyTexts.clear();
    _bytes = 0;
    _bodyTextBytes = 0;
  }
}

class _CachedBodyText {
  _CachedBodyText(this.text, this.size) : createdAt = DateTime.now();

  final String text;
  final int size;
  final DateTime createdAt;
}

class _CachedDocument {
  _CachedDocument(this.response, this.size) : createdAt = DateTime.now();

  final http.Response response;
  final int size;
  final DateTime createdAt;
  final Map<String, AnnouncementSearchColumnPage> pages = {};
  DateTime? filmDate;
  bool filmDateParsed = false;
}

String searchUrlKey(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri == null ? url.trim() : uri.replace(fragment: '').toString();
}

enum _TaskKind { list, body, film }

enum _TaskState { pending, running, waiting, success, unfinished }

enum _SearchFailureKind { parse, timeout, request }

bool _isTimeoutFailure(Object error) {
  if (error is TimeoutException) return true;
  if (error is AnnouncementApiException &&
      (error.statusCode == 408 || error.statusCode == 504)) {
    return true;
  }
  final message = error.toString().toLowerCase();
  return message.contains('timed out') ||
      message.contains('timeout') ||
      message.contains('超时');
}

class _Column {
  _Column(this.source, this.name, this.nextUrl);

  final AnnouncementSource source;
  final String name;
  final Set<String> visited = {};
  final List<_Page> pages = [];
  final Map<int, _Page> unemittedPages = {};
  String? nextUrl;
  DateTime? lastListStart;
  int nextPageIndex = 0;
  int nextEmitPageIndex = 0;
  bool pageQueued = false;
}

class _Page {
  _Page(this.column, this.index, this.items)
      : sourceOrder = {
          for (var index = 0; index < items.length; index++)
            searchUrlKey(items[index].url): index,
        };

  final _Column column;
  final int index;
  final List<AnnouncementListItem> items;
  final Map<String, int> sourceOrder;
  final List<_ResultSlot> slots = [];
  int pendingFilm = 0;
  int pendingBody = 0;
  int nextEmit = 0;
  bool finalized = false;
  bool done = false;
}

class _ResultSlot {
  _ResultSlot(this.item);
  AnnouncementListItem item;
  bool resolved = false;
  bool matched = false;
  bool scanned = false;
  bool emitted = false;
}

class _SearchTask {
  _SearchTask.list(this.column, this.url, this.pageIndex)
      : kind = _TaskKind.list,
        page = null,
        slot = null,
        itemIndex = null;

  _SearchTask.body(this.column, _Page bodyPage, _ResultSlot bodySlot)
      : kind = _TaskKind.body,
        url = bodySlot.item.url,
        pageIndex = bodyPage.index,
        page = bodyPage,
        slot = bodySlot,
        itemIndex = null;

  _SearchTask.film(this.column, _Page filmPage, int index)
      : kind = _TaskKind.film,
        url = filmPage.items[index].url,
        pageIndex = filmPage.index,
        page = filmPage,
        slot = null,
        itemIndex = index;

  final _TaskKind kind;
  final _Column column;
  final String url;
  final int pageIndex;
  final _Page? page;
  final _ResultSlot? slot;
  final int? itemIndex;
  _TaskState state = _TaskState.pending;
  DateTime? readyAt;
  int attempts = 0;
  bool recovery = false;
  bool retryable = true;
  bool failureApplied = false;
  bool firstPageAccounted = false;
  _SearchFailureKind? failureKind;
}

class _HostState {
  _HostState(this.limit) : effectiveLimit = limit;
  final int limit;
  int effectiveLimit;
  bool warmed = false;
  int active = 0;
  int consecutiveFailures = 0;
  int recoverySuccesses = 0;
  DateTime? cooldownUntil;

  void succeeded() {
    warmed = true;
    consecutiveFailures = 0;
    if (effectiveLimit < limit && ++recoverySuccesses >= 3) {
      effectiveLimit++;
      recoverySuccesses = 0;
    }
  }

  void failed(Object error) {
    if (error is! TimeoutException &&
        error is! HandshakeException &&
        error is! SocketException &&
        error is! http.ClientException &&
        (error is! AnnouncementApiException ||
            error.statusCode != 429 && error.statusCode != 503)) {
      return;
    }
    consecutiveFailures++;
    recoverySuccesses = 0;
    effectiveLimit = max(1, effectiveLimit ~/ 2);
    final suggested =
        error is AnnouncementApiException ? error.retryAfter : null;
    final backoff =
        Duration(milliseconds: 250 * (1 << min(consecutiveFailures - 1, 5)));
    cooldownUntil = DateTime.now()
        .add(suggested != null && suggested > backoff ? suggested : backoff);
  }
}

class _ParseQueue {
  _ParseQueue._(this.maxActive, this.maxActiveBody);

  factory _ParseQueue.forProfile(AnnouncementSearchProfile profile) {
    // Search parsing uses compute isolates. Reserve a logical processor for
    // the UI, and one parse slot for list pages when bodies are saturated.
    final total = min(
        profile.desiredTotalParses, max(2, Platform.numberOfProcessors - 1));
    final body = min(profile.desiredBodyParses, total - 1);
    return _ParseQueue._(total, body);
  }

  final Queue<Completer<void>> _listWaiting = Queue();
  final Queue<Completer<void>> _otherWaiting = Queue();
  int _active = 0;
  int _activeBody = 0;
  final int maxActive;
  final int maxActiveBody;

  Future<T> run<T>(Future<T> Function() action,
      {bool prioritizeList = false}) async {
    if (_active >= maxActive ||
        (!prioritizeList && _activeBody >= maxActiveBody)) {
      final waiter = Completer<void>();
      (prioritizeList ? _listWaiting : _otherWaiting).add(waiter);
      await waiter.future;
    } else {
      _active++;
      if (!prioritizeList) _activeBody++;
    }
    try {
      return await action();
    } finally {
      _active--;
      if (!prioritizeList) _activeBody--;
      while (_active < maxActive) {
        if (_listWaiting.isNotEmpty) {
          _active++;
          _listWaiting.removeFirst().complete();
        } else if (_otherWaiting.isNotEmpty && _activeBody < maxActiveBody) {
          _active++;
          _activeBody++;
          _otherWaiting.removeFirst().complete();
        } else {
          break;
        }
      }
    }
  }
}

/// One resumable search. Network slots, parsing slots and per-host slots are
/// independent; a waiting retry or column pause owns none of them.
class AnnouncementSearchRun {
  static const _maxPendingParseBytes = 8 * 1024 * 1024;
  static const _maxPendingParses = 32;
  static const _admissionProbePause = Duration(milliseconds: 350);

  AnnouncementSearchRun({
    required String query,
    required this.includeTitle,
    required this.includeBody,
    required this.fast,
    required this.retryFailures,
    required this.profile,
    required this.sources,
    required this.clientFactory,
    required this.cache,
    required this.onFinished,
    Duration? pagePauseOverride,
    Duration retryBaseDelay = const Duration(milliseconds: 400),
  })  : _query = query.trim().toLowerCase(),
        _pagePause = pagePauseOverride ??
            (fast
                ? Duration(
                    milliseconds: profile.pagePause.inMilliseconds * 4 ~/ 5)
                : profile.pagePause),
        _retryBaseDelay = retryBaseDelay,
        _networkLimit = min(profile.clientCount, profile.networkLimit),
        _parses = _ParseQueue.forProfile(profile),
        _controller = StreamController<AnnouncementSearchProgress>.broadcast() {
    _admissionLimit = min(2, _networkLimit);
    for (final source in sources) {
      for (var index = 0; index < source.listUrls.length; index++) {
        final column = _Column(
          source,
          index < source.columnNames.length ? source.columnNames[index] : '',
          source.listUrls[index],
        );
        _columns.add(column);
        final hostKey = _hostKey(column.nextUrl!);
        _remainingFirstPagesByHost.update(
          hostKey,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        _enqueueNext(column);
      }
    }
    _initialFirstPageCount = _columns.length;
    _remainingFirstPages = _initialFirstPageCount;
    _totalPages = _columns.length;
    scheduleMicrotask(_start);
  }

  final String _query;
  final bool includeTitle;
  final bool includeBody;
  final bool fast;
  final bool retryFailures;
  final AnnouncementSearchProfile profile;
  final List<AnnouncementSource> sources;
  final AnnouncementApiClient Function() clientFactory;
  final AnnouncementSearchCache cache;
  final void Function() onFinished;
  final Duration _pagePause;
  final Duration _retryBaseDelay;
  final int _networkLimit;
  // A worker releases its client before queued HTML parsing. More clients
  // than active requests plus pending parses only create an idle allocation
  // and allow a large synchronous burst of cached tasks.
  int get _workerCount =>
      min(profile.clientCount, _networkLimit + _maxPendingParses);
  final StreamController<AnnouncementSearchProgress> _controller;
  final _ParseQueue _parses;
  final List<_Column> _columns = [];
  final LinkedHashSet<_SearchTask> _tasks = LinkedHashSet();
  // Only dispatchable tasks belong in these indexes. Completed and in-flight
  // body requests can otherwise make every later dispatch scan thousands of
  // irrelevant entries on the UI isolate.
  final Map<String, LinkedHashSet<_SearchTask>> _tasksBySource = {};
  final Map<String, LinkedHashSet<_SearchTask>> _firstPagesBySource = {};
  final Set<_SearchTask> _delayedTasks = {};
  final Set<_SearchTask> _unfinishedTasks = {};
  final Queue<AnnouncementApiClient> _idleClients = Queue();
  final List<AnnouncementApiClient> _allClients = [];
  final Map<String, Future<http.Response>> _inflight = {};
  final Map<String, _HostState> _hosts = {};
  final Map<String, int> _remainingFirstPagesByHost = {};
  final Map<String, bool> _preferBodyBySource = {};
  // A shared URL can carry different titles across departments or columns.
  // Only identical listings can be skipped without losing a title match.
  final Set<String> _seenArticles = {};
  final List<AnnouncementListItem> _newMatches = [];
  Timer? _wakeTimer;
  Timer? _progressTimer;
  DateTime? _nextAdmissionProbeAt;
  final Completer<AnnouncementSearchProgress> _finished = Completer();
  int _sourceCursor = 0;
  int _activeTasks = 0;
  int _pendingTasks = 0;
  int _pendingFirstPages = 0;
  int _initialFirstPageCount = 0;
  int _remainingFirstPages = 0;
  int _activeNetwork = 0;
  int _admissionLimit = 0;
  int _activeBackgroundNetwork = 0;
  int _pendingParseBytes = 0;
  int _pendingParseCount = 0;
  int _totalPages = 0;
  int _completedPages = 0;
  int _discoveredArticles = 0;
  int _scannedArticles = 0;
  int _matchedArticles = 0;
  int _requestCount = 0;
  int _retryCount = 0;
  int _cacheHits = 0;
  double _lastFraction = 0;
  String? _lastError;
  bool _closed = false;
  bool _running = false;
  bool _settled = false;
  bool _recoveryDone = false;
  bool _pumping = false;

  Stream<AnnouncementSearchProgress> get updates => _controller.stream;
  Future<AnnouncementSearchProgress> get finished => _finished.future;

  /// A finished search is terminal. Retrying starts a new search session.
  bool get canResume => false;
  int get clientCount => profile.clientCount;
  int get networkLimit => _networkLimit;

  void _start() {
    if (_closed) return;
    _running = true;
    if (_admissionLimit < min(6, _networkLimit)) {
      _nextAdmissionProbeAt = DateTime.now().add(_admissionProbePause);
    }
    for (var index = 0; index < _workerCount; index++) {
      final client = clientFactory();
      _allClients.add(client);
      _idleClients.add(client);
    }
    _emit();
    _pump();
  }

  /// Kept for callers compiled against the former manual retry API.
  void resumeFailed() {}

  void cancel() {
    if (_closed) return;
    _closed = true;
    _running = false;
    _wakeTimer?.cancel();
    _progressTimer?.cancel();
    _closeClients();
    _newMatches.clear();
    if (!_finished.isCompleted) _finished.complete(_snapshot(isFinished: true));
    unawaited(_controller.close());
    onFinished();
  }

  void _closeClients() {
    for (final client in _allClients) {
      client.close();
    }
    _allClients.clear();
    _idleClients.clear();
  }

  void _enqueueNext(_Column column) {
    final url = column.nextUrl;
    if (url == null || column.pageQueued || column.visited.contains(url)) {
      return;
    }
    if (!fast && column.pages.any((page) => !page.done)) return;
    final unfinished = [
      for (final page in column.pages)
        if (!page.done) page
    ];
    if (fast &&
        unfinished.isNotEmpty &&
        column.nextPageIndex - unfinished.first.index > 3) {
      return;
    }
    final task = _SearchTask.list(column, url, column.nextPageIndex++);
    final lastStart = column.lastListStart;
    if (lastStart != null) task.readyAt = lastStart.add(_pagePause);
    column.nextUrl = null;
    column.pageQueued = true;
    _addTask(task);
    _pump();
  }

  void _addTask(_SearchTask task) {
    _tasks.add(task);
    _indexPendingTask(task);
  }

  void _indexPendingTask(_SearchTask task) {
    _pendingTasks++;
    _tasksBySource
        .putIfAbsent(task.column.source.id, LinkedHashSet.new)
        .add(task);
    if (task.kind == _TaskKind.list && task.pageIndex == 0) {
      _pendingFirstPages++;
      _firstPagesBySource
          .putIfAbsent(task.column.source.id, LinkedHashSet.new)
          .add(task);
    }
    if (task.readyAt != null) _delayedTasks.add(task);
  }

  void _pump() {
    if (!_running || _closed || _pumping) return;
    _pumping = true;
    try {
      _advanceAdmissionProbe(DateTime.now());
      // Stop dispatching when completed responses waiting for parsing reach
      // the budget. In-flight requests still belong to their client slots.
      while (_idleClients.isNotEmpty &&
          _pendingParseBytes < _maxPendingParseBytes &&
          _pendingParseCount < _maxPendingParses) {
        final task = _takeTask();
        if (task == null) break;
        _pendingTasks--;
        _tasksBySource[task.column.source.id]?.remove(task);
        if (task.kind == _TaskKind.list && task.pageIndex == 0) {
          _pendingFirstPages--;
          _firstPagesBySource[task.column.source.id]?.remove(task);
        }
        _delayedTasks.remove(task);
        final client = _idleClients.removeFirst();
        final host = _host(task.url);
        final network = cache._lookup(task.url) == null &&
            !_inflight.containsKey(searchUrlKey(task.url));
        final backgroundNetwork = network && !_isFirstPage(task);
        if (network) {
          host.active++;
          _activeNetwork++;
          if (backgroundNetwork) _activeBackgroundNetwork++;
        }
        if (task.kind == _TaskKind.list) {
          task.column.lastListStart = DateTime.now();
        }
        task.state = _TaskState.running;
        _activeTasks++;
        unawaited(
            _execute(task, client, network ? host : null, backgroundNetwork));
      }
      if (_activeTasks == 0) _settleOrWait();
      _scheduleWake();
    } finally {
      _pumping = false;
    }
  }

  _SearchTask? _takeTask() {
    if (sources.isEmpty) return null;
    final now = DateTime.now();
    // Finish the first-page pass across ALL selected departments before body
    // requests from early departments consume the connection pool.
    return (_pendingFirstPages == 0
            ? null
            : _takeTaskPass(now, firstPageOnly: true)) ??
        _takeTaskPass(now, firstPageOnly: false);
  }

  _SearchTask? _takeTaskPass(DateTime now, {required bool firstPageOnly}) {
    for (var offset = 0; offset < sources.length; offset++) {
      final index = (_sourceCursor + offset) % sources.length;
      final source = sources[index];
      _SearchTask? chosen;
      final preferBody = _preferBodyBySource[source.id] ?? false;
      final sourceTasks = firstPageOnly
          ? _firstPagesBySource[source.id]
          : _tasksBySource[source.id];
      for (final task in sourceTasks ?? const <_SearchTask>{}) {
        if ((task.state != _TaskState.pending &&
                task.state != _TaskState.waiting) ||
            (task.readyAt != null && task.readyAt!.isAfter(now)) ||
            !_hostAvailable(task, now)) {
          continue;
        }
        chosen ??= task;
        if (firstPageOnly ||
            (preferBody
                ? task.kind != _TaskKind.list
                : task.kind == _TaskKind.list)) {
          chosen = task;
          break;
        }
      }
      if (chosen == null) continue;
      if (!firstPageOnly) {
        _preferBodyBySource[source.id] = !preferBody;
      }
      _sourceCursor = (index + 1) % sources.length;
      return chosen;
    }
    return null;
  }

  bool _hostAvailable(_SearchTask task, DateTime now) {
    if (cache._lookup(task.url) != null ||
        _inflight.containsKey(searchUrlKey(task.url))) {
      return true;
    }
    final host = _host(task.url);
    if (!_isFirstPage(task) && _remainingFirstPages > 0) {
      final backgroundLimit = _protectingFirstPageCoverage
          ? max(1, profile.firstPageLimit ~/ 4)
          : max(1, _admissionLimit - profile.firstPageLimit);
      if (_activeBackgroundNetwork >= backgroundLimit) {
        return false;
      }
      if ((_remainingFirstPagesByHost[_hostKey(task.url)] ?? 0) > 0 &&
          host.active >= host.effectiveLimit - 1) {
        return false;
      }
    }
    final phaseLimit = _protectingFirstPageCoverage
        ? min(_admissionLimit, profile.firstPageLimit)
        : _admissionLimit;
    return _activeNetwork < phaseLimit &&
        host.active < (host.warmed ? host.effectiveLimit : 1) &&
        (host.cooldownUntil == null || !host.cooldownUntil!.isAfter(now));
  }

  bool get _protectingFirstPageCoverage =>
      _remainingFirstPages > _initialFirstPageCount ~/ 10;

  void _advanceAdmissionProbe(DateTime now) {
    final next = _nextAdmissionProbeAt;
    if (next == null || now.isBefore(next)) return;
    final ceiling = min(6, _networkLimit);
    if (_admissionLimit < ceiling) {
      _admissionLimit++;
      _nextAdmissionProbeAt =
          _admissionLimit < ceiling ? now.add(_admissionProbePause) : null;
    } else {
      _nextAdmissionProbeAt = null;
    }
  }

  void _growAdmissionAfterSuccess() {
    if (_admissionLimit < _networkLimit) _admissionLimit++;
    if (_admissionLimit >= min(6, _networkLimit)) {
      _nextAdmissionProbeAt = null;
    }
  }

  bool _isFirstPage(_SearchTask task) =>
      task.kind == _TaskKind.list && task.pageIndex == 0;

  String _hostKey(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? url;

  _HostState _host(String url) =>
      _hosts.putIfAbsent(_hostKey(url), () => _HostState(profile.hostLimit));

  Future<http.Response> _request(
      String url, AnnouncementApiClient client) async {
    final cached = cache._lookup(url);
    if (cached != null) {
      _cacheHits++;
      return cached.response;
    }
    final key = searchUrlKey(url);
    final pending = _inflight[key];
    if (pending != null) {
      _cacheHits++;
      return pending;
    }
    _requestCount++;
    final future = client.fetchSearchResponse(url);
    _inflight[key] = future;
    try {
      final response = await future;
      if (!_closed) cache.put(url, response);
      return response;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<void> _execute(_SearchTask task, AnnouncementApiClient client,
      _HostState? networkHost, bool backgroundNetwork) async {
    var clientReleased = false;
    var parsing = false;
    try {
      task.attempts++;
      if (task.attempts > 1 || task.recovery) _retryCount++;
      final response = await _request(task.url, client);
      if (_closed) return;
      networkHost?.succeeded();
      if (networkHost != null) {
        _growAdmissionAfterSuccess();
        networkHost.active--;
        _activeNetwork--;
        if (backgroundNetwork) _activeBackgroundNetwork--;
      }
      _pendingParseBytes += response.bodyBytes.length;
      _pendingParseCount++;
      _idleClients.add(client);
      clientReleased = true;
      _pump();
      try {
        parsing = true;
        await _parses.run(() => _process(task, response, client),
            prioritizeList: task.kind == _TaskKind.list);
        parsing = false;
      } finally {
        _pendingParseBytes -= response.bodyBytes.length;
        _pendingParseCount--;
      }
      if (_closed) return;
      task.state = _TaskState.success;
      _scheduleProgress();
    } on Object catch (error) {
      if (_closed) return;
      final failure = parsing && error is! AnnouncementSearchParseException
          ? AnnouncementSearchParseException('公告解析失败: $error')
          : error;
      if (!clientReleased) networkHost?.failed(failure);
      _lastError = failure.toString();
      task.failureKind = failure is AnnouncementSearchParseException
          ? _SearchFailureKind.parse
          : _isTimeoutFailure(failure)
              ? _SearchFailureKind.timeout
              : _SearchFailureKind.request;
      if (task.failureKind == _SearchFailureKind.parse) {
        cache.evict(task.url);
      }
      task.retryable = _isRetryableFailure(failure);
      final firstPageRecovery =
          _isFirstPage(task) && task.attempts >= 4 && !task.recovery;
      if (retryFailures &&
          task.retryable &&
          !task.recovery &&
          (task.attempts < 4 || firstPageRecovery)) {
        if (firstPageRecovery) {
          // Retry a failed first page before thousands of body tasks finish.
          // This is its final attempt; settlement must not enqueue it again.
          task.recovery = true;
          task.readyAt = null;
        } else {
          final exponent = 1 << (task.attempts - 1);
          final jitter = Random().nextInt(100);
          task.readyAt = DateTime.now().add(Duration(
              milliseconds:
                  _retryBaseDelay.inMilliseconds * exponent + jitter));
        }
        task.state = _TaskState.waiting;
        _indexPendingTask(task);
      } else {
        task.state = _TaskState.unfinished;
        _unfinishedTasks.add(task);
        _applyTerminalFailure(task);
      }
      _scheduleProgress();
    } finally {
      if (networkHost != null && !clientReleased) {
        networkHost.active--;
        _activeNetwork--;
        if (backgroundNetwork) _activeBackgroundNetwork--;
      }
      if (!clientReleased && !_closed) _idleClients.add(client);
      _activeTasks--;
      if (task.state == _TaskState.success) {
        _tasks.remove(task);
      }
      _pump();
    }
  }

  bool _isRetryableFailure(Object error) {
    if (error is AnnouncementSearchParseException) return false;
    if (error is AnnouncementApiException && error.statusCode != null) {
      final status = error.statusCode!;
      return status == 408 || status == 425 || status == 429 || status >= 500;
    }
    return true;
  }

  Future<void> _process(_SearchTask task, http.Response response,
      AnnouncementApiClient client) async {
    switch (task.kind) {
      case _TaskKind.list:
        final cacheEntry = cache._lookup(task.url);
        final pageKey = '${task.column.source.id}|${task.column.name}';
        var parsed = cacheEntry?.pages[pageKey];
        if (parsed == null) {
          parsed = await client.parseSearchColumnResponse(
            response: response,
            source: task.column.source,
            url: task.url,
            column: task.column.name,
          );
          cache._lookup(task.url)?.pages[pageKey] = parsed;
        }
        _acceptList(task, parsed);
      case _TaskKind.body:
        final slot = task.slot!;
        var text = cache.bodyText(slot.item.sourceId, task.url);
        if (text == null) {
          text = await client.parseSearchDetailText(
              response: response, item: slot.item);
          cache.putBodyText(slot.item.sourceId, task.url, text);
        }
        _acceptBody(task, text);
      case _TaskKind.film:
        final entry = cache._lookup(task.url);
        var date = entry?.filmDate;
        if (entry == null || !entry.filmDateParsed) {
          date = await client.parseFilmSearchDate(response);
          final current = cache._lookup(task.url);
          if (current != null) {
            current.filmDate = date;
            current.filmDateParsed = true;
          }
        }
        _acceptFilm(task, date);
    }
  }

  void _acceptList(_SearchTask task, AnnouncementSearchColumnPage parsed) {
    final column = task.column;
    column.visited.add(task.url);
    column.pageQueued = false;
    _completedPages++;
    _finishFirstPage(task);
    final next = parsed.nextPageUrl;
    if (next != null &&
        !column.visited.contains(next) &&
        searchUrlKey(next) != searchUrlKey(task.url)) {
      column.nextUrl = next;
      _totalPages++;
    }
    final indexed = parsed.items.asMap().entries.toList();
    final unique = <AnnouncementListItem>[];
    for (final entry in indexed) {
      if (_seenArticles.add('${column.source.id}\u0000'
          '${searchUrlKey(entry.value.url)}\u0000'
          '${entry.value.title.trim().toLowerCase()}')) {
        unique.add(entry.value);
        _discoveredArticles++;
      }
    }
    final page = _Page(column, task.pageIndex, unique);
    column.pages.add(page);
    column.unemittedPages[page.index] = page;
    if (column.source.adapter.listFormat == AnnouncementListFormat.filmNotice) {
      final host = Uri.tryParse(column.source.listUrl)?.host;
      for (var index = 0; index < unique.length; index++) {
        final uri = Uri.tryParse(unique[index].url);
        if (uri?.host == host && uri!.path.endsWith('.htm')) {
          page.pendingFilm++;
          _addTask(_SearchTask.film(column, page, index));
        }
      }
    }
    // Film dates may need article HTML, but a ready title hit must not wait
    // for every date supplement request to finish.
    _finalizePage(page);
    if (fast) _enqueueNext(column);
    _scheduleProgress();
  }

  void _acceptFilm(_SearchTask task, DateTime? date) {
    final page = task.page!;
    final index = page.finalized
        ? page.items.indexWhere(
            (item) => searchUrlKey(item.url) == searchUrlKey(task.url))
        : task.itemIndex!;
    if (index < 0) return;
    if (date != null) {
      final old = page.items[index];
      final updated = AnnouncementListItem(
        title: old.title,
        url: old.url,
        summary: old.summary,
        dateText: '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
        publishedAt: date,
        sourceId: old.sourceId,
        column: old.column,
      );
      page.items[index] = updated;
      if (page.finalized) {
        _updateFilmEstimates(page);
      }
    }
    if (!task.failureApplied) {
      page.pendingFilm--;
      if (page.pendingFilm == 0) _finalizePage(page);
    }
    _scheduleProgress();
  }

  void _updateFilmEstimates(_Page page) {
    final originalOrder = List<AnnouncementListItem>.of(page.items)
      ..sort((a, b) => page.sourceOrder[searchUrlKey(a.url)]!
          .compareTo(page.sourceOrder[searchUrlKey(b.url)]!));
    final estimated = inferFilmNoticeDates(originalOrder);
    final byUrl = {
      for (final item in estimated) searchUrlKey(item.url): item,
    };
    for (var index = 0; index < page.items.length; index++) {
      page.items[index] = byUrl[searchUrlKey(page.items[index].url)]!;
    }
    for (final slot in page.slots) {
      final updated = byUrl[searchUrlKey(slot.item.url)]!;
      if (slot.item.publishedAt == updated.publishedAt &&
          slot.item.dateText == updated.dateText) {
        continue;
      }
      final previous = slot.item;
      slot.item = AnnouncementListItem(
        title: updated.title,
        url: updated.url,
        summary:
            previous.summary.isNotEmpty ? previous.summary : updated.summary,
        dateText: updated.dateText,
        publishedAt: updated.publishedAt,
        sourceId: updated.sourceId,
        column: updated.column,
      );
      if (slot.matched && slot.emitted) _newMatches.add(slot.item);
    }
  }

  void _finalizePage(_Page page) {
    if (page.finalized) return;
    page.finalized = true;
    page.items.sort((a, b) {
      final left = a.publishedAt;
      final right = b.publishedAt;
      if (left == null) {
        return right == null
            ? page.sourceOrder[searchUrlKey(a.url)]!
                .compareTo(page.sourceOrder[searchUrlKey(b.url)]!)
            : 1;
      }
      if (right == null) return -1;
      final byDate = right.compareTo(left);
      return byDate != 0
          ? byDate
          : page.sourceOrder[searchUrlKey(a.url)]!
              .compareTo(page.sourceOrder[searchUrlKey(b.url)]!);
    });
    for (final item in page.items) {
      final slot = _ResultSlot(item);
      page.slots.add(slot);
      if (includeTitle && item.title.toLowerCase().contains(_query)) {
        slot.resolved = true;
        slot.matched = true;
        slot.scanned = true;
        _scannedArticles++;
        _matchedArticles++;
        _publishMatch(slot);
      } else if (includeBody && _searchable(item.url)) {
        final cached = cache.bodyText(item.sourceId, item.url);
        if (cached != null) {
          _cacheHits++;
          slot.resolved = true;
          slot.scanned = true;
          slot.matched = cached.toLowerCase().contains(_query);
          _scannedArticles++;
          if (slot.matched) {
            _attachBodyPreview(slot, cached);
            _matchedArticles++;
            _publishMatch(slot);
          }
        } else {
          page.pendingBody++;
          _addTask(_SearchTask.body(page.column, page, slot));
        }
      } else {
        slot.resolved = true;
        slot.scanned = true;
        _scannedArticles++;
      }
    }
    _flushSlots(page);
    if (page.pendingBody == 0) _pageDone(page);
  }

  bool _searchable(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return !RegExp(
            r'\.(pdf|docx?|xlsx?|pptx?|zip|rar|7z|png|jpe?g|gif|webp|svg|bmp|ico|mp[34]|wav|avi|mov|css|js)$')
        .hasMatch(path);
  }

  void _acceptBody(_SearchTask task, String text) {
    final slot = task.slot!;
    final page = task.page!;
    final found = text.toLowerCase().contains(_query);
    if (found) _attachBodyPreview(slot, text);
    if (!slot.scanned) {
      slot.scanned = true;
      _scannedArticles++;
    }
    if (slot.resolved) {
      if (found && !slot.matched) {
        slot.matched = true;
        _matchedArticles++;
        _publishMatch(slot);
      }
    } else {
      slot.resolved = true;
      slot.matched = found;
      if (found) {
        _matchedArticles++;
        _publishMatch(slot);
      }
      if (!task.failureApplied) page.pendingBody--;
      _flushSlots(page);
      if (page.pendingBody == 0) _pageDone(page);
    }
    _scheduleProgress();
  }

  void _publishMatch(_ResultSlot slot) {
    if (slot.emitted) return;
    slot.emitted = true;
    _newMatches.add(slot.item);
  }

  void _attachBodyPreview(_ResultSlot slot, String text) {
    // Search can read a very long article. A two-line card only needs its
    // beginning, so avoid normalizing and copying the whole body again.
    final head = text.length > 512 ? text.substring(0, 512) : text;
    final normalized = head.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return;
    final preview = normalized.length > 110
        ? '${normalized.substring(0, 110)}…'
        : normalized;
    final old = slot.item;
    if (old.summary == preview) return;
    slot.item = AnnouncementListItem(
      title: old.title,
      url: old.url,
      summary: preview,
      dateText: old.dateText,
      publishedAt: old.publishedAt,
      sourceId: old.sourceId,
      column: old.column,
    );
  }

  void _flushSlots(_Page page) {
    final column = page.column;
    while (true) {
      final current = column.unemittedPages[column.nextEmitPageIndex];
      if (current == null || !current.finalized) break;
      while (current.nextEmit < current.slots.length &&
          current.slots[current.nextEmit].resolved) {
        current.nextEmit++;
      }
      if (current.nextEmit < current.slots.length) break;
      column.unemittedPages.remove(column.nextEmitPageIndex);
      column.nextEmitPageIndex++;
    }
    _scheduleProgress();
  }

  void _pageDone(_Page page) {
    if (page.done) return;
    page.done = true;
    page.column.pages.remove(page);
    _enqueueNext(page.column);
  }

  void _finishFirstPage(_SearchTask task) {
    if (!_isFirstPage(task) || task.firstPageAccounted) return;
    task.firstPageAccounted = true;
    _remainingFirstPages--;
    final hostKey = _hostKey(task.url);
    final remaining = _remainingFirstPagesByHost[hostKey]! - 1;
    if (remaining == 0) {
      _remainingFirstPagesByHost.remove(hostKey);
    } else {
      _remainingFirstPagesByHost[hostKey] = remaining;
    }
  }

  void _applyTerminalFailure(_SearchTask task) {
    if (task.failureApplied) {
      if (task.kind == _TaskKind.body && task.recovery) {
        task.slot!.resolved = true;
        _flushSlots(task.page!);
      }
      return;
    }
    task.failureApplied = true;
    if (task.kind == _TaskKind.list) {
      _finishFirstPage(task);
    } else if (task.kind == _TaskKind.body) {
      final page = task.page!;
      final slot = task.slot!;
      slot.resolved = true;
      page.pendingBody--;
      _flushSlots(page);
      if (page.pendingBody == 0) _pageDone(page);
    } else if (task.kind == _TaskKind.film) {
      final page = task.page!;
      page.pendingFilm--;
      if (page.pendingFilm == 0) _finalizePage(page);
    }
  }

  void _settleOrWait() {
    if (_settled || !_running) return;
    if (_pendingTasks != 0 || _activeTasks != 0) {
      return;
    }
    final failures = _unfinishedTasks.toList();
    if (failures.any((task) => task.retryable && !task.recovery) &&
        retryFailures &&
        !_recoveryDone) {
      _recoveryDone = true;
      for (final task in failures) {
        if (!task.retryable || task.recovery) continue;
        task.state = _TaskState.pending;
        task.readyAt = null;
        task.recovery = true;
        _unfinishedTasks.remove(task);
        _indexPendingTask(task);
      }
      _pumpAgain();
      return;
    }
    _settled = true;
    _running = false;
    _wakeTimer?.cancel();
    _progressTimer?.cancel();
    final progress = _emit(isFinished: true, isComplete: failures.isEmpty);
    _closeClients();
    if (!_finished.isCompleted) _finished.complete(progress);
    _closed = true;
    unawaited(_controller.close());
    onFinished();
  }

  void _pumpAgain() => scheduleMicrotask(_pump);

  void _scheduleWake() {
    _wakeTimer?.cancel();
    if (!_running || _closed) return;
    DateTime? earliest;
    final now = DateTime.now();
    for (final task in _delayedTasks) {
      final ready = task.readyAt;
      if (ready != null &&
          ready.isAfter(now) &&
          (earliest == null || ready.isBefore(earliest))) {
        earliest = ready;
      }
    }
    // A host cooldown may begin after a task was indexed. The number of hosts
    // is bounded by selected departments, unlike the number of articles.
    for (final host in _hosts.values) {
      final cooldown = host.cooldownUntil;
      if (cooldown != null &&
          cooldown.isAfter(now) &&
          (earliest == null || cooldown.isBefore(earliest))) {
        earliest = cooldown;
      }
    }
    final admission = _nextAdmissionProbeAt;
    if (_pendingTasks > 0 &&
        admission != null &&
        (earliest == null || admission.isBefore(earliest))) {
      earliest = admission;
    }
    if (earliest != null) {
      _wakeTimer = Timer(earliest.difference(now), _pump);
    }
  }

  void _scheduleProgress() {
    if (_closed || !_running || _progressTimer != null) return;
    _progressTimer = Timer(const Duration(milliseconds: 100), () {
      _progressTimer = null;
      if (!_closed && _running) _emit();
    });
  }

  AnnouncementSearchProgress _snapshot(
      {bool isFinished = false, bool isComplete = false}) {
    final failedPages = _unfinishedTasks
        .where((task) =>
            task.kind == _TaskKind.list && task.state == _TaskState.unfinished)
        .length;
    final failedArticles = _unfinishedTasks
        .where((task) =>
            task.kind != _TaskKind.list && task.state == _TaskState.unfinished)
        .length;
    final parseFailureCount = _unfinishedTasks
        .where((task) => task.failureKind == _SearchFailureKind.parse)
        .length;
    final timeoutFailureCount = _unfinishedTasks
        .where((task) => task.failureKind == _SearchFailureKind.timeout)
        .length;
    final pageFraction = _totalPages == 0 ? 0.0 : _completedPages / _totalPages;
    final rawFraction = isComplete
        ? 1.0
        : includeBody
            ? pageFraction * 0.5 +
                (_discoveredArticles == 0
                    ? 0.0
                    : _scannedArticles / _discoveredArticles * 0.5)
            : pageFraction;
    final fraction = rawFraction.clamp(0.0, isComplete ? 1.0 : 0.99);
    if (fraction > _lastFraction) _lastFraction = fraction;
    return AnnouncementSearchProgress(
      totalPages: _totalPages,
      completedPages: _completedPages,
      discoveredArticles: _discoveredArticles,
      scannedArticles: _scannedArticles,
      matchedArticles: _matchedArticles,
      failedPages: failedPages,
      failedArticles: failedArticles,
      parseFailureCount: parseFailureCount,
      timeoutFailureCount: timeoutFailureCount,
      newMatches: List.unmodifiable(_newMatches),
      fraction: _lastFraction,
      isComplete: isComplete,
      isFinished: isFinished,
      requestCount: _requestCount,
      retryCount: _retryCount,
      cacheHits: _cacheHits,
      lastError: _lastError,
    );
  }

  AnnouncementSearchProgress _emit(
      {bool isFinished = false, bool isComplete = false}) {
    final progress = _snapshot(isFinished: isFinished, isComplete: isComplete);
    if (!_controller.isClosed && !_closed) _controller.add(progress);
    _newMatches.clear();
    return progress;
  }
}
