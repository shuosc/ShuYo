import 'dart:io';

import 'package:http/io_client.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import 'announcement_api_client.dart';
import 'announcement_search_scheduler.dart';
import 'http_timeout.dart';

export 'announcement_search_scheduler.dart'
    show AnnouncementSearchProfile, AnnouncementSearchRun;

/// One batched update from a search across department columns and their pages.
/// [newMatches] only contains results found since the previous update.
class AnnouncementSearchProgress {
  const AnnouncementSearchProgress({
    required this.totalPages,
    required this.completedPages,
    required this.discoveredArticles,
    required this.scannedArticles,
    required this.matchedArticles,
    required this.failedPages,
    required this.failedArticles,
    this.parseFailureCount = 0,
    this.timeoutFailureCount = 0,
    required this.newMatches,
    required this.fraction,
    required this.isComplete,
    this.isFinished = false,
    this.requestCount = 0,
    this.retryCount = 0,
    this.cacheHits = 0,
    this.lastError,
  });

  final int totalPages;
  final int completedPages;
  final int discoveredArticles;

  /// Articles whose title or body check succeeded.
  final int scannedArticles;
  final int matchedArticles;
  final int failedPages;
  final int failedArticles;

  /// Terminal HTML parsing failures. These are never retried.
  final int parseFailureCount;

  /// Terminal timeouts after the configured automatic retries are exhausted.
  final int timeoutFailureCount;
  final List<AnnouncementListItem> newMatches;
  final double fraction;

  /// True only when the entire selected search range was checked.
  final bool isComplete;

  /// True when no work is currently running, including a partial search.
  final bool isFinished;
  final int requestCount;
  final int retryCount;
  final int cacheHits;
  int get unfinishedCount => failedPages + failedArticles;
  final String? lastError;
}

typedef AnnouncementSearchSession = AnnouncementSearchRun;

/// Owns the reusable short-term cache and the current cancellable search.
class AnnouncementSearchService {
  AnnouncementSearchService({
    AnnouncementApiClient Function()? clientFactory,
    this.sources = AnnouncementSource.all,
    Duration retryBaseDelay = const Duration(milliseconds: 400),
  })  : _clientFactory = clientFactory,
        _retryBaseDelay = retryBaseDelay;

  final AnnouncementApiClient Function()? _clientFactory;
  final List<AnnouncementSource> sources;
  final Duration _retryBaseDelay;
  final AnnouncementSearchCache _cache = AnnouncementSearchCache();

  AnnouncementSearchRun? _active;
  bool _disposed = false;

  AnnouncementSearchRun startSearch({
    required String query,
    bool includeTitle = true,
    bool includeBody = false,
    int strength = 2,
    bool fast = false,
    bool retryFailures = true,
    Duration? batchPause,
    List<AnnouncementSource>? sources,
  }) {
    if (_disposed) throw StateError('AnnouncementSearchService is disposed');
    _active?.cancel();
    // All workers in one run share a persistent transport. A separate
    // HttpClient per worker would repeatedly open DNS/TCP/TLS connections.
    final transport = _clientFactory == null
        ? IOClient(HttpClient()
          ..connectionTimeout = HttpTimeout.connect
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost =
              AnnouncementSearchProfile.forStrength(strength).hostLimit)
        : null;
    late final AnnouncementSearchRun session;
    session = AnnouncementSearchRun(
      query: query,
      includeTitle: includeTitle,
      includeBody: includeBody,
      fast: fast,
      retryFailures: retryFailures,
      profile: AnnouncementSearchProfile.forStrength(strength),
      sources: List.of(sources ?? this.sources),
      pagePauseOverride: batchPause,
      retryBaseDelay: _retryBaseDelay,
      clientFactory: _clientFactory ??
          () => AnnouncementApiClient(
              httpClient: transport, ownsHttpClient: false),
      cache: _cache,
      onFinished: () {
        transport?.close();
        if (identical(_active, session)) _active = null;
      },
    );
    _active = session;
    return session;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active?.cancel();
    _active = null;
    _cache.clear();
  }
}
