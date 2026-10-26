import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/client_user_agent.dart';
import '../models/announcement_target.dart';
import 'announcement_memory_cache.dart';
import 'http_timeout.dart';

enum AnnouncementRequestPriority { list, detail }

/// Shared transport for list pages, previews, article details and metadata.
///
/// Network requests release their slots before HTML parsing. Completed responses
/// waiting for parsing have a separate budget, so a slow parser cannot produce
/// an unlimited backlog of downloaded documents.
class AnnouncementRequestClient {
  AnnouncementRequestClient({
    http.Client? httpClient,
    bool ownsHttpClient = true,
    this.requestTimeout = HttpTimeout.normal,
    this.operationTimeout = HttpTimeout.composed,
    this.retryBaseDelay = const Duration(milliseconds: 250),
    this.maxAttempts = 3,
    this.maxConcurrentRequests = 6,
    this.maxConcurrentRequestsPerHost = 4,
    this.maxPendingResponses = 32,
    this.maxPendingResponseBytes = 8 * 1024 * 1024,
    DateTime Function()? now,
  })  : assert(maxAttempts > 0),
        assert(maxConcurrentRequests > 0),
        assert(maxConcurrentRequestsPerHost > 0),
        assert(maxPendingResponses > 0),
        assert(maxPendingResponseBytes > 0),
        _httpClient =
            httpClient ?? _createHttpClient(maxConcurrentRequestsPerHost),
        _ownsHttpClient = httpClient == null || ownsHttpClient,
        _responses = AnnouncementMemoryCache<http.Response>(
          maxEntries: 300,
          maxBytes: 16 * 1024 * 1024,
          sizeOf: (response) => response.bodyBytes.length,
          now: now,
        );

  static http.Client _createHttpClient(int maxConnectionsPerHost) =>
      IOClient(HttpClient()
        ..connectionTimeout = HttpTimeout.connect
        ..idleTimeout = const Duration(seconds: 30)
        ..maxConnectionsPerHost = maxConnectionsPerHost);

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration requestTimeout;
  final Duration operationTimeout;
  final Duration retryBaseDelay;
  final int maxAttempts;
  final int maxConcurrentRequests;
  final int maxConcurrentRequestsPerHost;
  final int maxPendingResponses;
  final int maxPendingResponseBytes;
  final AnnouncementMemoryCache<http.Response> _responses;
  final Map<String, _Request> _inflight = {};
  final Set<_Request> _requests = {};
  final List<_Request> _queued = [];
  final Map<String, _Host> _hosts = {};
  Timer? _wakeTimer;
  int _active = 0;
  int _activeDetails = 0;
  int _pendingResponses = 0;
  int _pendingResponseBytes = 0;
  int _cacheEpoch = 0;
  bool _closed = false;
  bool _pumping = false;

  /// Only article/metadata requests use the short-lived response cache. A list
  /// refresh always reaches the network, even if that URL was cached as detail.
  Future<http.Response> get(
    String url, {
    AnnouncementRequestPriority priority = AnnouncementRequestPriority.list,
  }) =>
      _get(url, priority: priority);

  /// Reads only the bounded beginning of a VSB document export, then stops the
  /// response as soon as its metadata is complete. Prefixes never share the
  /// response cache or in-flight entries used by complete HTML downloads.
  Future<http.Response> getMetadataPrefix(
    String url, {
    required bool Function(List<int>) isComplete,
    int maxBytes = 16 * 1024,
  }) {
    if (maxBytes <= 0) {
      return Future.error(ArgumentError.value(maxBytes, 'maxBytes'));
    }
    return _get(
      url,
      priority: AnnouncementRequestPriority.detail,
      isComplete: isComplete,
      maxBytes: maxBytes,
    );
  }

  Future<http.Response> _get(
    String url, {
    required AnnouncementRequestPriority priority,
    bool Function(List<int>)? isComplete,
    int maxBytes = 0,
  }) {
    if (_closed) {
      return Future.error(StateError('Announcement client is closed'));
    }
    final normalizedUrl = _urlKey(url);
    final key = isComplete == null
        ? normalizedUrl
        : 'metadata:$maxBytes:$normalizedUrl';
    final cacheable = priority == AnnouncementRequestPriority.detail;
    if (cacheable) {
      final cached = _responses.lookup(key);
      if (cached != null) return Future.value(cached.value);
    }
    final existing = _inflight[key];
    if (existing != null) {
      existing.cacheable |= cacheable;
      if (priority == AnnouncementRequestPriority.list &&
          existing.priority != priority) {
        existing.priority = priority;
        _pump();
      }
      return existing.completer.future;
    }
    final request = _Request(
      normalizedUrl,
      key,
      priority,
      cacheable,
      _cacheEpoch,
      isComplete: isComplete,
      maxBytes: maxBytes,
    );
    _inflight[key] = request;
    _requests.add(request);
    _queued.add(request);
    request.deadline = DateTime.now().add(operationTimeout);
    request.timer = Timer(operationTimeout, () {
      _finishError(
        request,
        TimeoutException('通知公告请求超时，请稍后再试', operationTimeout),
      );
      _pump();
    });
    _pump();
    return request.completer.future;
  }

  Future<T> withResponse<T>(
    String url,
    Future<T> Function(http.Response response) action, {
    AnnouncementRequestPriority priority = AnnouncementRequestPriority.list,
  }) async {
    final epoch = _cacheEpoch;
    final response = await get(url, priority: priority);
    if (_closed) throw StateError('Announcement client is closed');
    _pendingResponses++;
    _pendingResponseBytes += response.bodyBytes.length;
    try {
      return await action(response);
    } on Object {
      // A successful download may still contain a broken article template.
      // Do not keep serving that document to later preview/detail retries.
      // A parse from before refresh must not evict the refreshed response.
      if (epoch == _cacheEpoch) {
        final key = _urlKey(url);
        _responses.removeWhere(
          (cachedKey, value) => cachedKey == key && identical(value, response),
        );
      }
      rethrow;
    } finally {
      _pendingResponses--;
      _pendingResponseBytes -= response.bodyBytes.length;
      _pump();
    }
  }

  /// An older request can still finish for its original caller, but cannot
  /// populate this cache or be reused by requests after a forced refresh.
  void clearResponseCache() {
    _cacheEpoch++;
    _responses.clear();
    _inflight.clear();
  }

  /// Refresh one article without invalidating unrelated sites or consumers.
  void invalidateUrls(Iterable<String> urls) {
    final keys = urls.map(announcementUrlKey).toSet();
    _responses.removeWhere((key, _) =>
        keys.contains(key) || keys.any((url) => key.endsWith(':$url')));
    for (final request in _requests) {
      if (!keys.contains(request.url)) continue;
      request.cacheable = false;
      if (identical(_inflight[request.key], request)) {
        _inflight.remove(request.key);
      }
    }
  }

  /// Release expired optional work, including requests still in the queue.
  void cancelUrls(Iterable<String> urls) {
    final keys = urls.map(announcementUrlKey).toSet();
    for (final request in _requests.toList()) {
      if (keys.contains(request.url)) {
        _finishError(request, StateError('Announcement preparation cancelled'));
      }
    }
    _pump();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _wakeTimer?.cancel();
    for (final request in _requests.toList()) {
      _finishError(request, StateError('Announcement client is closed'));
    }
    _queued.clear();
    _responses.clear();
    if (_ownsHttpClient) _httpClient.close();
  }

  static String _urlKey(String url) => announcementUrlKey(url);

  _Host _host(_Request request) => _hosts.putIfAbsent(
        Uri.parse(request.url).host.toLowerCase(),
        () => _Host(maxConcurrentRequestsPerHost),
      );

  void _pump() {
    if (_closed || _pumping) return;
    _pumping = true;
    try {
      while (_active < maxConcurrentRequests &&
          _pendingResponses < maxPendingResponses &&
          _pendingResponseBytes < maxPendingResponseBytes) {
        final request = _takeReady();
        if (request == null) break;
        final host = _host(request);
        final detail = request.priority == AnnouncementRequestPriority.detail;
        _active++;
        host.active++;
        if (detail) {
          _activeDetails++;
          host.activeDetails++;
        }
        unawaited(_execute(request, host, detail));
      }
      _scheduleWake();
    } finally {
      _pumping = false;
    }
  }

  _Request? _takeReady() {
    final now = DateTime.now();
    for (final priority in AnnouncementRequestPriority.values) {
      for (var index = 0; index < _queued.length; index++) {
        final request = _queued[index];
        if (request.done || request.priority != priority) continue;
        if (request.readyAt != null && request.readyAt!.isAfter(now)) continue;
        final host = _host(request);
        if (host.cooldownUntil != null && host.cooldownUntil!.isAfter(now)) {
          continue;
        }
        if (host.active >= host.effectiveLimit) continue;
        if (priority == AnnouncementRequestPriority.detail &&
            (_activeDetails >= max(1, maxConcurrentRequests - 1) ||
                host.activeDetails >= max(1, host.effectiveLimit - 1))) {
          continue;
        }
        return _queued.removeAt(index);
      }
    }
    return null;
  }

  Future<void> _execute(_Request request, _Host host, bool detail) async {
    try {
      request.attempts++;
      final response = await _send(request);
      if (request.done) return;
      if (_retryableStatus(response.statusCode)) {
        final delay = _failureDelay(request, _retryAfter(response));
        host.failed(delay);
        if (_retry(request, delay)) return;
      } else if (response.statusCode >= 200 && response.statusCode < 300) {
        host.succeeded();
      }
      if (request.cacheable &&
          request.epoch == _cacheEpoch &&
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          (request.isMetadata
              ? request.prefixComplete
              : _readable(response.headers))) {
        _responses.put(request.key, response);
      }
      _finishResponse(request, response);
    } on Object catch (error) {
      if (request.done) return;
      if (_retryableError(error)) {
        final delay = _failureDelay(request, null);
        host.failed(delay);
        if (_retry(request, delay)) return;
      }
      _finishError(request, error);
    } finally {
      _active--;
      host.active--;
      if (detail) {
        _activeDetails--;
        host.activeDetails--;
      }
      // Let consumers account for responses waiting for parsing first.
      scheduleMicrotask(_pump);
    }
  }

  Future<http.Response> _send(_Request request) async {
    request.prefixComplete = false;
    final abort = Completer<void>();
    request.abort = abort;
    final outgoing = http.AbortableRequest(
      'GET',
      Uri.parse(request.url),
      abortTrigger: abort.future,
    )..headers.addAll({
        'accept': request.isMetadata
            ? 'application/msword,application/octet-stream,multipart/related,'
                'text/html;q=0.9'
            : 'text/html,application/xhtml+xml',
        'user-agent': ClientUserAgent.mobileBrowser,
      });
    Future<http.Response> send() async {
      final streamed = await _httpClient.send(outgoing);
      if (streamed.statusCode < 200 ||
          streamed.statusCode >= 300 ||
          !(request.isMetadata
              ? _metadataReadable(streamed.headers)
              : _readable(streamed.headers))) {
        // Error pages and attachments are unnecessary for the HTML parsers.
        // Preserve headers/status for unavailable notices and Retry-After.
        final subscription = streamed.stream.listen((_) {}, onError: (_) {});
        if (!abort.isCompleted) abort.complete();
        await subscription.cancel();
        return http.Response.bytes(
          const [],
          streamed.statusCode,
          request: streamed.request,
          headers: streamed.headers,
          isRedirect: streamed.isRedirect,
          persistentConnection: streamed.persistentConnection,
          reasonPhrase: streamed.reasonPhrase,
        );
      }
      if (request.isMetadata) {
        return _readMetadataPrefix(streamed, request, abort);
      }
      final response = await http.Response.fromStream(streamed);
      return _ResponseWithUrl(
          response,
          streamed is http.BaseResponseWithUrl
              ? (streamed as http.BaseResponseWithUrl).url
              : outgoing.url);
    }

    try {
      return await Future.any([
        send(),
        request.stopped.future.then<http.Response>((_) => throw request.error!),
      ]).timeout(requestTimeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('通知公告请求超时，请稍后再试', requestTimeout);
      });
    } on Object {
      if (!abort.isCompleted) abort.complete();
      rethrow;
    } finally {
      if (identical(request.abort, abort)) request.abort = null;
    }
  }

  Future<http.Response> _readMetadataPrefix(
    http.StreamedResponse streamed,
    _Request request,
    Completer<void> abort,
  ) async {
    final bytes = <int>[];
    final finished = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    var stopped = false;

    void finish({Object? error, StackTrace? stackTrace, bool cancel = false}) {
      if (stopped) return;
      stopped = true;
      if (cancel && !abort.isCompleted) abort.complete();
      final cleanup = cancel ? subscription.cancel() : Future<void>.value();
      cleanup.then((_) {
        if (error != null) {
          finished.completeError(error, stackTrace);
        } else {
          finished.complete();
        }
      }, onError: (Object cleanupError, StackTrace cleanupStack) {
        finished.completeError(
            error ?? cleanupError, stackTrace ?? cleanupStack);
      });
    }

    subscription = streamed.stream.listen(
      (chunk) {
        try {
          final remaining = request.maxBytes - bytes.length;
          bytes.addAll(
              chunk.length <= remaining ? chunk : chunk.take(remaining));
          request.prefixComplete = request.isComplete!(bytes);
          if (request.prefixComplete || bytes.length == request.maxBytes) {
            finish(cancel: true);
          }
        } on Object catch (error, stackTrace) {
          finish(error: error, stackTrace: stackTrace, cancel: true);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        finish(error: error, stackTrace: stackTrace, cancel: true);
      },
      onDone: finish,
      cancelOnError: false,
    );
    unawaited(abort.future.then((_) {
      finish(
        error: http.ClientException(
            'Metadata request aborted', Uri.parse(request.url)),
        cancel: true,
      );
    }));
    await finished.future;
    return http.Response.bytes(
      bytes,
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  static bool _metadataReadable(Map<String, String> headers) {
    final type =
        (headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    return _readable(headers) ||
        type == 'application/msword' ||
        type == 'application/octet-stream' ||
        type == 'multipart/related' ||
        type == 'message/rfc822';
  }

  static bool _readable(Map<String, String> headers) {
    final type =
        (headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    return type.isEmpty ||
        type == 'text/html' ||
        type == 'application/xhtml+xml' ||
        type == 'text/plain';
  }

  static bool _retryableStatus(int status) =>
      status == 408 || status == 425 || status == 429 || status >= 500;

  static bool _retryableError(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException;

  Duration _failureDelay(_Request request, Duration? retryAfter) {
    final backoff = retryBaseDelay * (1 << min(request.attempts - 1, 5));
    return retryAfter != null && retryAfter > backoff ? retryAfter : backoff;
  }

  static Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after']?.trim();
    if (header == null) return null;
    final seconds = int.tryParse(header);
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 3600));
    try {
      final duration = HttpDate.parse(header).difference(DateTime.now());
      return duration.isNegative ? Duration.zero : duration;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  bool _retry(_Request request, Duration delay) {
    if (request.attempts >= maxAttempts ||
        !DateTime.now().add(delay).isBefore(request.deadline)) {
      return false;
    }
    request.readyAt = DateTime.now().add(delay);
    _queued.add(request);
    return true;
  }

  void _finishResponse(_Request request, http.Response response) {
    _remove(request);
    request.completer.complete(response);
  }

  void _finishError(_Request request, Object error) {
    if (request.done) return;
    request.error = error;
    final abort = request.abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    request.stopped.complete();
    _remove(request);
    request.completer.completeError(error);
  }

  void _remove(_Request request) {
    request.done = true;
    request.timer?.cancel();
    _requests.remove(request);
    _queued.remove(request);
    if (identical(_inflight[request.key], request)) {
      _inflight.remove(request.key);
    }
  }

  void _scheduleWake() {
    _wakeTimer?.cancel();
    DateTime? earliest;
    final now = DateTime.now();
    for (final request in _queued) {
      var ready = request.readyAt ?? now;
      final cooldown = _host(request).cooldownUntil;
      if (cooldown != null && cooldown.isAfter(ready)) ready = cooldown;
      if (ready.isAfter(now) &&
          (earliest == null || ready.isBefore(earliest))) {
        earliest = ready;
      }
    }
    if (earliest != null) {
      _wakeTimer = Timer(earliest.difference(now), _pump);
    }
  }
}

class _ResponseWithUrl extends http.Response
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(http.Response response, this.url)
      : super.bytes(response.bodyBytes, response.statusCode,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase);

  @override
  final Uri url;
}

class _Request {
  _Request(this.url, this.key, this.priority, this.cacheable, this.epoch,
      {this.isComplete, this.maxBytes = 0});

  final String url;
  final String key;
  AnnouncementRequestPriority priority;
  bool cacheable;
  final int epoch;
  final bool Function(List<int>)? isComplete;
  final int maxBytes;
  bool prefixComplete = false;
  bool get isMetadata => isComplete != null;
  final Completer<http.Response> completer = Completer();
  final Completer<void> stopped = Completer();
  Completer<void>? abort;
  Timer? timer;
  late DateTime deadline;
  DateTime? readyAt;
  Object? error;
  int attempts = 0;
  bool done = false;
}

class _Host {
  _Host(this.limit) : effectiveLimit = limit;

  final int limit;
  int effectiveLimit;
  int active = 0;
  int activeDetails = 0;
  int recoverySuccesses = 0;
  DateTime? cooldownUntil;

  void failed(Duration delay) {
    effectiveLimit = max(1, effectiveLimit ~/ 2);
    recoverySuccesses = 0;
    final until = DateTime.now().add(delay);
    if (cooldownUntil == null || until.isAfter(cooldownUntil!)) {
      cooldownUntil = until;
    }
  }

  void succeeded() {
    if (effectiveLimit < limit && ++recoverySuccesses >= 3) {
      effectiveLimit++;
      recoverySuccesses = 0;
    }
  }
}
