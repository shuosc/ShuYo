import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'announcement_search_service.dart';

/// Keeps network, scheduling, caching and HTML parsing off the UI isolate.
///
/// The worker is started lazily and retained for the lifetime of this service,
/// so short-lived search caches remain useful across different queries.
class AnnouncementSearchWorkerService {
  AnnouncementSearchWorkerService({AnnouncementSearchService? fallback})
      : _fallback = fallback ?? (kIsWeb ? AnnouncementSearchService() : null),
        _ownsFallback = fallback == null && kIsWeb;

  /// An injected service can be kept on the current isolate for widget tests.
  /// The fallback belongs to its caller and is never disposed here.
  final AnnouncementSearchService? _fallback;
  final bool _ownsFallback;
  ReceivePort? _events;
  StreamSubscription<dynamic>? _eventSubscription;
  Future<SendPort>? _starting;
  Completer<SendPort>? _handshake;
  Isolate? _isolate;
  SendPort? _commands;
  AnnouncementSearchWorkerRun? _active;
  int _nextRunId = 0;
  bool _disposed = false;

  AnnouncementSearchWorkerRun startSearch({
    required String query,
    bool includeTitle = true,
    bool includeBody = false,
    int strength = 2,
    bool fast = false,
    bool retryFailures = true,
    Duration? batchPause,
    List<AnnouncementSource>? sources,
  }) {
    if (_disposed) {
      throw StateError('AnnouncementSearchWorkerService is disposed');
    }
    _active?.cancel();
    final fallback = _fallback;
    if (fallback != null) {
      final run = AnnouncementSearchWorkerRun._legacy(fallback.startSearch(
        query: query,
        includeTitle: includeTitle,
        includeBody: includeBody,
        strength: strength,
        fast: fast,
        retryFailures: retryFailures,
        batchPause: batchPause,
        sources: sources,
      ));
      _active = run;
      return run;
    }

    final run = AnnouncementSearchWorkerRun._(this, ++_nextRunId);
    _active = run;
    final command = <String, Object?>{
      'type': 'start',
      'runId': run._id,
      'query': query,
      'includeTitle': includeTitle,
      'includeBody': includeBody,
      'strength': strength,
      'fast': fast,
      'retryFailures': retryFailures,
      'batchPauseMs': batchPause?.inMilliseconds,
      'sources': (sources ?? AnnouncementSource.all)
          .map(_encodeSource)
          .toList(growable: false),
    };
    unawaited(_startRun(run, command));
    return run;
  }

  Future<void> _startRun(
      AnnouncementSearchWorkerRun run, Map<String, Object?> command) async {
    try {
      final port = await _ensureStarted();
      if (!_disposed && identical(_active, run) && !run._closed) {
        port.send(command);
      }
    } on Object catch (error, stackTrace) {
      // A failed spawn must not leave a cached failed Future for later searches.
      _starting = null;
      run._fail(error, stackTrace);
    }
  }

  Future<SendPort> _ensureStarted() => _starting ??= _spawn();

  Future<SendPort> _spawn() async {
    final events = ReceivePort();
    final handshake = Completer<SendPort>();
    _events = events;
    _handshake = handshake;
    _eventSubscription = events.listen(_handleEvent);
    try {
      final isolate = await Isolate.spawn<SendPort>(
        _announcementSearchWorkerMain,
        events.sendPort,
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'announcement-search',
      );
      _isolate = isolate;
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('AnnouncementSearchWorkerService is disposed');
      }
      return await handshake.future.timeout(const Duration(seconds: 10));
    } on Object {
      _eventSubscription?.cancel();
      events.close();
      _isolate?.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  void _handleEvent(dynamic event) {
    if (_disposed) return;
    if (event is Map && event['type'] == 'ready') {
      final port = event['port'];
      if (port is SendPort) {
        _commands = port;
        if (_handshake?.isCompleted == false) _handshake!.complete(port);
      }
      return;
    }
    if (event == null || event is List) {
      final description = event is List && event.isNotEmpty
          ? event.first.toString()
          : 'Search worker exited unexpectedly';
      _failWorker(StateError(description));
      return;
    }
    if (event is! Map) return;
    final run = _active;
    if (run == null || run._id != event['runId'] || run._closed) return;
    switch (event['type']) {
      case 'progress':
        final payload = event['progress'];
        if (payload is Map) run._receive(_decodeProgress(payload));
      case 'error':
        run._fail(StateError(event['message']?.toString() ?? 'Search failed'));
    }
  }

  void _failWorker(Object error) {
    final wasReady = _commands != null;
    if (_handshake?.isCompleted == false) _handshake!.completeError(error);
    _active?._fail(error);
    _commands = null;
    if (wasReady) {
      _starting = null;
      _isolate = null;
      unawaited(_eventSubscription?.cancel() ?? Future<void>.value());
      _eventSubscription = null;
      _events?.close();
      _events = null;
      _handshake = null;
    }
  }

  void _post(Map<String, Object?> message) {
    if (_disposed) return;
    _commands?.send(message);
  }

  void dispose() {
    if (_disposed) return;
    _active?.cancel();
    _disposed = true;
    _commands?.send(const {'type': 'dispose'});
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _eventSubscription?.cancel();
    _events?.close();
    if (_ownsFallback) _fallback?.dispose();
  }
}

/// UI-facing handle. Every finished search is terminal, including one with
/// failed pages or articles.
class AnnouncementSearchWorkerRun {
  AnnouncementSearchWorkerRun._(this._service, this._id)
      : _legacy = null,
        _updates = StreamController<AnnouncementSearchProgress>.broadcast();

  AnnouncementSearchWorkerRun._legacy(AnnouncementSearchRun legacy)
      : _legacy = legacy,
        _service = null,
        _id = 0,
        _updates = null;

  final AnnouncementSearchWorkerService? _service;
  final AnnouncementSearchRun? _legacy;
  final int _id;
  final StreamController<AnnouncementSearchProgress>? _updates;
  Completer<AnnouncementSearchProgress> _finished = Completer();
  AnnouncementSearchProgress? _lastProgress;
  bool _closed = false;
  bool _settled = false;
  bool _canResume = false;

  Stream<AnnouncementSearchProgress> get updates =>
      _legacy?.updates ?? _updates!.stream;
  Future<AnnouncementSearchProgress> get finished =>
      _legacy?.finished ?? _finished.future;
  bool get canResume => _legacy?.canResume ?? _canResume;

  void _receive(AnnouncementSearchProgress progress) {
    if (_closed) return;
    _lastProgress = progress;
    _updates!.add(progress);
    if (progress.isFinished) {
      _settled = true;
      _canResume = false;
      if (!_finished.isCompleted) _finished.complete(progress);
      _closed = true;
      unawaited(_updates.close());
    }
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _canResume = false;
    _settled = true;
    _closed = true;
    _updates!.addError(error, stackTrace);
    if (!_finished.isCompleted) {
      _finished.complete(
          _cancelledProgress(_lastProgress, lastError: error.toString()));
    }
    unawaited(_updates.close());
  }

  void resumeFailed() {
    final legacy = _legacy;
    if (legacy != null) {
      legacy.resumeFailed();
      return;
    }
    if (_closed || !_settled || !_canResume) return;
    _settled = false;
    _canResume = false;
    _finished = Completer();
    _service!._post({'type': 'resume', 'runId': _id});
  }

  void cancel() {
    final legacy = _legacy;
    if (legacy != null) {
      legacy.cancel();
      return;
    }
    if (_closed) return;
    _closed = true;
    _canResume = false;
    _service!._post({'type': 'cancel', 'runId': _id});
    if (!_finished.isCompleted) {
      _finished.complete(_cancelledProgress(_lastProgress));
    }
    unawaited(_updates!.close());
  }
}

AnnouncementSearchProgress _cancelledProgress(AnnouncementSearchProgress? old,
        {String? lastError}) =>
    AnnouncementSearchProgress(
      totalPages: old?.totalPages ?? 0,
      completedPages: old?.completedPages ?? 0,
      discoveredArticles: old?.discoveredArticles ?? 0,
      scannedArticles: old?.scannedArticles ?? 0,
      matchedArticles: old?.matchedArticles ?? 0,
      failedPages: old?.failedPages ?? 0,
      failedArticles: old?.failedArticles ?? 0,
      parseFailureCount: old?.parseFailureCount ?? 0,
      timeoutFailureCount: old?.timeoutFailureCount ?? 0,
      newMatches: const [],
      fraction: old?.fraction ?? 0,
      isComplete: false,
      isFinished: true,
      requestCount: old?.requestCount ?? 0,
      retryCount: old?.retryCount ?? 0,
      cacheHits: old?.cacheHits ?? 0,
      lastError: lastError ?? old?.lastError,
    );

Map<String, Object?> _encodeSource(AnnouncementSource source) => {
      'id': source.id,
      'name': source.name,
      'listUrl': source.listUrl,
      'additionalListUrls': source.additionalListUrls,
      'columnNames': source.columnNames,
      'group': source.group.name,
      'adapter': {
        'listFormat': source.adapter.listFormat.name,
        'authorLabelSelectors': source.adapter.authorLabelSelectors,
        'authorValueSelectors': source.adapter.authorValueSelectors,
        'hideListColumn': source.adapter.hideListColumn,
        'hideDetailDepartment': source.adapter.hideDetailDepartment,
      },
    };

AnnouncementSource _decodeSource(Map source) {
  final adapter = source['adapter'] as Map;
  return AnnouncementSource(
    id: source['id'] as String,
    name: source['name'] as String,
    listUrl: source['listUrl'] as String,
    additionalListUrls: (source['additionalListUrls'] as List).cast<String>(),
    columnNames: (source['columnNames'] as List).cast<String>(),
    group: AnnouncementSourceGroup.values.byName(source['group'] as String),
    adapter: AnnouncementSourceAdapter(
      listFormat:
          AnnouncementListFormat.values.byName(adapter['listFormat'] as String),
      authorLabelSelectors:
          (adapter['authorLabelSelectors'] as List).cast<String>(),
      authorValueSelectors:
          (adapter['authorValueSelectors'] as List).cast<String>(),
      hideListColumn: adapter['hideListColumn'] as bool,
      hideDetailDepartment: adapter['hideDetailDepartment'] as bool,
    ),
  );
}

Map<String, Object?> _encodeProgress(AnnouncementSearchProgress progress) => {
      'totalPages': progress.totalPages,
      'completedPages': progress.completedPages,
      'discoveredArticles': progress.discoveredArticles,
      'scannedArticles': progress.scannedArticles,
      'matchedArticles': progress.matchedArticles,
      'failedPages': progress.failedPages,
      'failedArticles': progress.failedArticles,
      'parseFailureCount': progress.parseFailureCount,
      'timeoutFailureCount': progress.timeoutFailureCount,
      'newMatches': progress.newMatches.map((item) => item.toJson()).toList(),
      'fraction': progress.fraction,
      'isComplete': progress.isComplete,
      'isFinished': progress.isFinished,
      'requestCount': progress.requestCount,
      'retryCount': progress.retryCount,
      'cacheHits': progress.cacheHits,
      'lastError': progress.lastError,
    };

AnnouncementSearchProgress _decodeProgress(Map payload) =>
    AnnouncementSearchProgress(
      totalPages: payload['totalPages'] as int,
      completedPages: payload['completedPages'] as int,
      discoveredArticles: payload['discoveredArticles'] as int,
      scannedArticles: payload['scannedArticles'] as int,
      matchedArticles: payload['matchedArticles'] as int,
      failedPages: payload['failedPages'] as int,
      failedArticles: payload['failedArticles'] as int,
      parseFailureCount: payload['parseFailureCount'] as int,
      timeoutFailureCount: payload['timeoutFailureCount'] as int,
      newMatches: [
        for (final raw in payload['newMatches'] as List)
          AnnouncementListItem.fromJson((raw as Map).cast<String, dynamic>()),
      ],
      fraction: (payload['fraction'] as num).toDouble(),
      isComplete: payload['isComplete'] as bool,
      isFinished: payload['isFinished'] as bool,
      requestCount: payload['requestCount'] as int,
      retryCount: payload['retryCount'] as int,
      cacheHits: payload['cacheHits'] as int,
      lastError: payload['lastError'] as String?,
    );

void _announcementSearchWorkerMain(SendPort events) {
  final commands = ReceivePort();
  final service = AnnouncementSearchService();
  AnnouncementSearchRun? active;
  StreamSubscription<AnnouncementSearchProgress>? subscription;
  int? activeId;

  void fail(int id, Object error) => events.send({
        'type': 'error',
        'runId': id,
        'message': error.toString(),
      });

  commands.listen((dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    final id = raw['runId'] as int?;
    try {
      switch (type) {
        case 'start':
          if (id == null) return;
          activeId = id;
          unawaited(subscription?.cancel());
          active?.cancel();
          final run = service.startSearch(
            query: raw['query'] as String,
            includeTitle: raw['includeTitle'] as bool? ?? true,
            includeBody: raw['includeBody'] as bool,
            strength: raw['strength'] as int,
            fast: raw['fast'] as bool,
            retryFailures: raw['retryFailures'] as bool,
            batchPause: switch (raw['batchPauseMs']) {
              final int milliseconds => Duration(milliseconds: milliseconds),
              _ => null,
            },
            sources: [
              for (final item in raw['sources'] as List)
                _decodeSource(item as Map),
            ],
          );
          active = run;
          subscription = run.updates.listen(
            (progress) {
              if (activeId == id) {
                events.send({
                  'type': 'progress',
                  'runId': id,
                  'progress': _encodeProgress(progress),
                });
              }
            },
            onError: (Object error) {
              if (activeId == id) fail(id, error);
            },
          );
        case 'resume':
          if (activeId == id && active?.canResume == true) {
            active!.resumeFailed();
          }
        case 'cancel':
          if (activeId == id) {
            activeId = null;
            unawaited(subscription?.cancel());
            active?.cancel();
            active = null;
            subscription = null;
          }
        case 'dispose':
          activeId = null;
          unawaited(subscription?.cancel());
          service.dispose();
          commands.close();
      }
    } on Object catch (error) {
      if (id != null) fail(id, error);
    }
  });
  events.send({'type': 'ready', 'port': commands.sendPort});
}
