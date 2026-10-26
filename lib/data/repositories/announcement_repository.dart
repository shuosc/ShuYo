import 'dart:convert';
import 'dart:async';
import 'dart:collection';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/announcement_target.dart';
import '../models/common.dart';
import '../services/announcement_api_client.dart';
import '../services/announcement_memory_cache.dart';
import '../services/announcement_order.dart';
import '../services/client_settings_service.dart';

class AnnouncementHomeSummary {
  const AnnouncementHomeSummary(this.text);

  final String text;
}

enum AnnouncementMenuSection {
  favorites,
  schoolPortal,
  schoolDepartment,
  college,
  researchInstitute,
}

typedef AnnouncementMenuExpansion = ({
  bool favorites,
  bool schoolPortal,
  bool schoolDepartment,
  bool college,
  bool researchInstitute,
});

class AnnouncementRepository {
  AnnouncementRepository({
    AnnouncementApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? now,
    this.autoRefreshInterval = defaultAutoRefreshInterval,
    this.cardLoadTimeout = cardPreparationTimeout,
  })  : _apiClient = apiClient ?? AnnouncementApiClient(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _pendingCards.values.toList()) {
      _finishCard(request, cancelOptional: true);
    }
    _apiClient.close();
  }

  static const defaultAutoRefreshInterval = Duration(hours: 12);
  static const cardPreparationTimeout = Duration(seconds: 5);
  static const _listCacheKey = 'announcements.list.cache';
  static const _lastRefreshKey = 'announcements.lastRefreshAt';
  static const _cacheVersionKey = 'announcements.cacheVersion';
  static const _defaultSourceKey =
      ClientSettingsService.defaultAnnouncementSourceKey;
  static const _favoritesKey = 'announcements.favoriteSources';
  static const _menuExpansionKey = 'announcements.menu.expanded';
  static const _cacheVersion = 5;
  static const _sourceCacheVersions = {'sfa': 9, 'cs': 6};
  static int _cacheVersionFor(AnnouncementSource source) =>
      _sourceCacheVersions[source.id] ?? _cacheVersion;

  final AnnouncementApiClient _apiClient;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;
  final Duration autoRefreshInterval;
  final Duration cardLoadTimeout;

  final Map<String, List<AnnouncementListItem>> _memoryLists = {};
  final Map<String, List<String?>> _nextPageUrls = {};
  final Map<String, Set<String>> _visitedPageUrls = {};
  late final _recentDetails = AnnouncementMemoryCache<AnnouncementDetail>(
    maxEntries: 12,
    maxBytes: 8 * 1024 * 1024,
    ttl: const Duration(minutes: 5),
    sizeOf: _detailCacheBytes,
    now: _now,
  );
  final Map<String, Future<AnnouncementDetail>> _pendingDetails = {};
  final Map<String, Future<void>> _pendingListWrites = {};
  final Map<String, int> _cacheGenerations = {};
  final Map<String, int> _articleGenerations = {};
  final Map<String, Set<String>> _sourceArticleUrls = {};
  final Queue<_QueuedAnnouncementCard> _cardQueue = Queue();
  final Map<String, _QueuedAnnouncementCard> _pendingCards = {};
  int _activeCardRequests = 0;
  bool _disposed = false;
  static const _maximumActiveCards = 6;
  static const _maximumQueuedCards = 24;

  /// Resolves only the fields missing from a visible card. Preview and date
  /// work run together, while a shared deadline also covers time in the queue.
  /// An unsupported link or failed optional request is a settled card too.
  Future<AnnouncementCardData> loadCard(AnnouncementListItem item) {
    final key = _rememberArticle(item);
    final target =
        AnnouncementTarget.resolve(item.url, sourceId: item.sourceId);
    if (_disposed ||
        ((item.summary.isNotEmpty || !target.canPreview) &&
            (item.dateText.isNotEmpty || !target.canLoadMetadata))) {
      return Future.value(AnnouncementCardData.fromItem(item));
    }
    final pendingKey = '${item.sourceId}|$key';
    final pending = _pendingCards[pendingKey];
    if (pending != null) {
      if (item.summary.isNotEmpty) pending.summary = item.summary;
      if (item.dateText.isNotEmpty) {
        pending.dateText = item.dateText;
        pending.publishedAt = item.publishedAt;
      }
      return pending.completer.future;
    }
    if (_cardQueue.length >= _maximumQueuedCards) {
      return Future.value(AnnouncementCardData.fromItem(item));
    }
    final request = _QueuedAnnouncementCard(
      item: item,
      key: pendingKey,
      sourceGeneration: _cacheGenerations[item.sourceId] ?? 0,
      articleGeneration: _articleGenerations[key] ?? 0,
    );
    _pendingCards[pendingKey] = request;
    request.timer = Timer(
        cardLoadTimeout, () => _finishCard(request, cancelOptional: true));
    _cardQueue.add(request);
    _pumpCardQueue();
    return request.completer.future;
  }

  /// Releases optional work when a card leaves the viewport. Another card for
  /// the same article keeps its shared request alive, including cross-posts.
  void cancelCard(AnnouncementListItem item) {
    final key = '${item.sourceId}|${announcementUrlKey(item.url)}';
    final request = _pendingCards[key];
    if (request != null) _finishCard(request, cancelOptional: true);
  }

  void _pumpCardQueue() {
    while (!_disposed &&
        _activeCardRequests < _maximumActiveCards &&
        _cardQueue.isNotEmpty) {
      final request = _cardQueue.removeFirst();
      if (request.completer.isCompleted) continue;
      if (request.elapsed.elapsed >= cardLoadTimeout) {
        _finishCard(request, pumpQueue: false, cancelOptional: true);
        continue;
      }
      request.started = true;
      _activeCardRequests++;
      unawaited(_loadQueuedCard(request));
    }
  }

  Future<void> _loadQueuedCard(_QueuedAnnouncementCard request) async {
    final item = request.item;
    final target =
        AnnouncementTarget.resolve(item.url, sourceId: item.sourceId);
    await Future.wait<void>([
      if (item.summary.isEmpty && target.canPreview)
        loadPreview(item).then((summary) {
          if (!request.completer.isCompleted &&
              request.summary.isEmpty &&
              summary != null) {
            request.summary = summary;
          }
        }).catchError((Object _) {}),
      if (item.dateText.isEmpty && target.canLoadMetadata)
        loadPublicationDate(item).then((dated) {
          if (!request.completer.isCompleted &&
              request.dateText.isEmpty &&
              dated != null) {
            request.dateText = dated.dateText;
            request.publishedAt = dated.publishedAt;
          }
        }).catchError((Object _) {}),
    ]);
    _finishCard(request);
  }

  void _finishCard(_QueuedAnnouncementCard request,
      {bool pumpQueue = true, bool cancelOptional = false}) {
    if (request.completer.isCompleted) return;
    request.timer?.cancel();
    request.elapsed.stop();
    if (identical(_pendingCards[request.key], request)) {
      _pendingCards.remove(request.key);
    }
    _cardQueue.remove(request);
    final current = request.sourceGeneration ==
            (_cacheGenerations[request.item.sourceId] ?? 0) &&
        request.articleGeneration ==
            (_articleGenerations[announcementUrlKey(request.item.url)] ?? 0);
    request.completer.complete(current
        ? AnnouncementCardData(
            summary: request.summary,
            dateText: request.dateText,
            publishedAt: request.publishedAt,
          )
        : AnnouncementCardData.fromItem(request.item));
    if (cancelOptional) {
      final url = announcementUrlKey(request.item.url);
      final hasAnotherCard = _pendingCards.values
          .any((pending) => announcementUrlKey(pending.item.url) == url);
      if (!hasAnotherCard) _apiClient.cancelOptionalArticle(url);
    }
    if (request.started) _activeCardRequests--;
    if (pumpQueue) _pumpCardQueue();
  }

  /// Preview extraction has no dependency on full article metadata or details.
  Future<String?> loadPreview(AnnouncementListItem item) {
    if (item.summary.isNotEmpty) return Future.value(item.summary);
    _rememberArticle(item);
    if (_disposed ||
        !AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
            .canPreview) {
      return Future.value(null);
    }
    // The API owns the single cached article state, including its summary.
    return Future<String?>.sync(() => _apiClient.fetchPreview(item))
        .catchError((Object _) => null);
  }

  Future<AnnouncementSource> defaultSource() async {
    final prefs = await _preferencesLoader();
    return AnnouncementSource.byId(prefs.getString(_defaultSourceKey));
  }

  Future<void> setDefaultSource(AnnouncementSource source) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(_defaultSourceKey, source.id);
  }

  Future<Set<String>> favoriteSourceIds() async {
    final prefs = await _preferencesLoader();
    final known = AnnouncementSource.all.map((source) => source.id).toSet();
    return (prefs.getStringList(_favoritesKey) ?? const <String>[])
        .where(known.contains)
        .toSet();
  }

  Future<Set<String>> toggleFavoriteSource(AnnouncementSource source) async {
    final prefs = await _preferencesLoader();
    final ids = await favoriteSourceIds();
    if (!ids.add(source.id)) ids.remove(source.id);
    await prefs.setStringList(_favoritesKey, ids.toList());
    return ids;
  }

  Future<AnnouncementMenuExpansion> menuExpansion() async {
    final prefs = await _preferencesLoader();
    final schoolDepartmentExpanded =
        prefs.getBool('$_menuExpansionKey.schoolDepartment') ??
            ((prefs.getBool('$_menuExpansionKey.campusAcademic') ??
                    prefs.getBool('$_menuExpansionKey.campus') ??
                    true) ||
                (prefs.getBool('$_menuExpansionKey.campusAdministration') ??
                    prefs.getBool('$_menuExpansionKey.campus') ??
                    true));
    return (
      favorites: prefs.getBool('$_menuExpansionKey.favorites') ?? true,
      schoolPortal: prefs.getBool('$_menuExpansionKey.schoolPortal') ??
          schoolDepartmentExpanded,
      schoolDepartment: schoolDepartmentExpanded,
      college: prefs.getBool('$_menuExpansionKey.college') ?? false,
      researchInstitute:
          prefs.getBool('$_menuExpansionKey.researchInstitute') ?? false,
    );
  }

  Future<void> saveMenuExpansion(
    AnnouncementMenuSection section,
    bool expanded,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool('$_menuExpansionKey.${section.name}', expanded);
  }

  Future<List<AnnouncementListItem>> loadCachedAnnouncements({
    AnnouncementSource? source,
  }) async {
    final selected = source ?? await defaultSource();
    if (_memoryLists.containsKey(selected.id)) {
      final current = _keepActiveColumns(selected, _memoryLists[selected.id]!);
      _memoryLists[selected.id] = current;
      return current;
    }
    final prefs = await _preferencesLoader();
    final raw = prefs.getString('$_listCacheKey.${selected.id}') ??
        (selected == AnnouncementSource.official
            ? prefs.getString(_listCacheKey)
            : null);
    if (raw == null || raw.isEmpty) {
      return const <AnnouncementListItem>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <AnnouncementListItem>[];
    }
    final items = decoded
        .whereType<JsonMap>()
        .map(AnnouncementListItem.fromJson)
        .map(_withoutUnverifiedDate)
        .toList();
    final recent = _keepActiveColumns(
      selected,
      _mergeAnnouncements(const [], items),
    );
    _memoryLists[selected.id] = recent;
    return recent;
  }

  static AnnouncementListItem _withoutUnverifiedDate(
      AnnouncementListItem item) {
    if (item.dateText.isNotEmpty || item.publishedAt == null) return item;
    // Older caches can contain an ordering estimate without a verified date.
    // Keep the article and let the shared metadata request resolve its date.
    return AnnouncementListItem(
      title: item.title,
      url: item.url,
      summary: item.summary,
      sourceId: item.sourceId,
      column: item.column,
    );
  }

  List<AnnouncementListItem> _keepActiveColumns(
    AnnouncementSource source,
    List<AnnouncementListItem> items,
  ) {
    if (source.columnNames.isEmpty) return items;
    final activeColumns = source.columnNames.toSet();
    return items
        .where((item) =>
            item.column.isEmpty || activeColumns.contains(item.column))
        .toList(growable: false);
  }

  bool hasMoreAnnouncements({AnnouncementSource? source}) {
    final id = source?.id;
    if (id == null) return false;
    return _nextPageUrls[id]?.any((url) => url != null) ?? false;
  }

  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    final selected = source ?? await defaultSource();
    final cached = await loadCachedAnnouncements(source: selected);
    if (forceRefresh && !loadNextPage) _invalidateSourceDetails(selected);
    if (loadNextPage) {
      final nextPageUrls = _nextPageUrls[selected.id];
      if (nextPageUrls == null || !nextPageUrls.any((url) => url != null)) {
        return cached;
      }
      try {
        final visited = _visitedPageUrls.putIfAbsent(
          selected.id,
          () => selected.listUrls.toSet(),
        )..addAll(nextPageUrls.whereType<String>());
        final page = await _apiClient.fetchPage(
          source: selected,
          pageUrls: nextPageUrls,
        );
        _nextPageUrls[selected.id] = [
          for (final next in page.nextPageUrls)
            if (next != null && !visited.contains(next)) next else null,
        ];
        final merged = _mergeAnnouncements(
            _memoryLists[selected.id] ?? cached, page.items);
        await _saveList(selected, merged);
        return merged;
      } on Object {
        if (cached.isNotEmpty) return cached;
        rethrow;
      }
    }
    if (!forceRefresh && !await _shouldAutoRefresh(selected)) {
      return loadCachedAnnouncements(source: selected);
    }
    try {
      final page = await _apiClient.fetchPage(source: selected);
      final visited = _visitedPageUrls[selected.id] = selected.listUrls.toSet();
      _nextPageUrls[selected.id] = [
        for (final next in page.nextPageUrls)
          if (next != null && !visited.contains(next)) next else null,
      ];
      final items = _mergeAnnouncements(
        _memoryLists[selected.id] ?? cached,
        page.items,
        preferIncomingOrder: true,
      );
      await _saveList(selected, items);
      return items;
    } on Object {
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  /// Fills a visible card's missing date, including historical items that were
  /// not returned by the latest list page. Preserve its original list source.
  Future<AnnouncementListItem?> loadPublicationDate(
      AnnouncementListItem item) async {
    if (item.dateText.isNotEmpty) return item;
    final key = _rememberArticle(item);
    if (_disposed ||
        !AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
            .canLoadMetadata) {
      return null;
    }
    final generation = _cacheGenerations[item.sourceId] ?? 0;
    final articleGeneration = _articleGenerations[key] ?? 0;
    AnnouncementListItem? dated;
    try {
      dated = await _apiClient.fetchPublicationDate(item);
    } on Object {
      // Optional metadata must not prevent reading the list or its articles.
    }
    if (_disposed ||
        generation != (_cacheGenerations[item.sourceId] ?? 0) ||
        articleGeneration != (_articleGenerations[key] ?? 0)) {
      return null;
    }
    if (dated != null) {
      // Disk writes must not delay a card's entrance. A source generation
      // check in the patch also rejects results from an older refresh.
      unawaited(_patchPublicationDate(dated, generation, articleGeneration));
    }
    return dated;
  }

  Future<void> _patchPublicationDate(
      AnnouncementListItem dated, int generation, int articleGeneration) async {
    try {
      final source = AnnouncementSource.byId(dated.sourceId);
      if (source.id != dated.sourceId) return;
      final current = await loadCachedAnnouncements(source: source);
      final key = announcementUrlKey(dated.url);
      if (_disposed ||
          generation != (_cacheGenerations[source.id] ?? 0) ||
          articleGeneration != (_articleGenerations[key] ?? 0)) {
        return;
      }
      // Replace in place: optional date completion cannot move a card already
      // being read, or change an external link's position among dated items.
      final items =
          List<AnnouncementListItem>.of(_memoryLists[source.id] ?? current);
      final index = items.indexWhere((entry) =>
          announcementUrlKey(entry.url) == key && entry.dateText.isEmpty);
      if (index < 0) return;
      final entry = items[index];
      items[index] = AnnouncementListItem(
        title: entry.title,
        url: entry.url,
        summary: entry.summary,
        dateText: dated.dateText,
        publishedAt: dated.publishedAt,
        sourceId: entry.sourceId,
        column: entry.column,
      );
      _memoryLists[source.id] = items;
      await _persistList(source, markRefreshed: false);
    } on Object {
      // The verified fields remain usable even if optional persistence fails.
    }
  }

  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    final key = _rememberArticle(item);
    final cached = _recentDetails.lookup(key);
    if (cached != null) return Future.value(cached.value);
    final pending = _pendingDetails[key];
    if (pending != null) return pending;
    final generation = _articleGenerations[key] ?? 0;
    late final Future<AnnouncementDetail> task;
    task = Future<AnnouncementDetail>.sync(() => _apiClient.fetchDetail(item))
        .then((detail) {
      if (!_disposed && generation == (_articleGenerations[key] ?? 0)) {
        _recentDetails.put(key, detail);
      }
      return detail;
    }).whenComplete(() {
      if (identical(_pendingDetails[key], task)) {
        _pendingDetails.remove(key);
      }
    });
    _pendingDetails[key] = task;
    return task;
  }

  String _rememberArticle(AnnouncementListItem item) {
    final key = announcementUrlKey(item.url);
    _sourceArticleUrls.putIfAbsent(item.sourceId, () => <String>{}).add(key);
    return key;
  }

  void _invalidateSourceDetails(AnnouncementSource source) {
    _cacheGenerations.update(source.id, (value) => value + 1,
        ifAbsent: () => 1);
    final urls = <String>{
      ...?_sourceArticleUrls[source.id],
      for (final item in _memoryLists[source.id] ?? <AnnouncementListItem>[])
        announcementUrlKey(item.url),
    };
    for (final url in urls) {
      _articleGenerations.update(url, (value) => value + 1, ifAbsent: () => 1);
    }
    _recentDetails.removeWhere((key, _) => urls.contains(key));
    _pendingDetails.removeWhere((key, _) => urls.contains(key));
    for (final request in _pendingCards.values.toList()) {
      if (request.item.sourceId == source.id ||
          urls.contains(announcementUrlKey(request.item.url))) {
        _finishCard(request, pumpQueue: false, cancelOptional: true);
      }
    }
    _apiClient.invalidateArticles(urls);
    _pumpCardQueue();
  }

  static int _detailCacheBytes(AnnouncementDetail detail) {
    var characters = detail.title.length +
        detail.url.length +
        detail.dateText.length +
        detail.author.length +
        detail.department.length;
    for (final block in detail.blocks) {
      characters += block.value.length + block.alt.length + block.label.length;
      for (final part in block.parts) {
        characters += part.text.length + part.url.length;
      }
      for (final row in block.rows) {
        for (final cell in row) {
          characters += cell.length;
        }
      }
      for (final cell in block.cells) {
        characters += cell.text.length +
            cell.textAlignment.length +
            cell.verticalAlignment.length;
      }
    }
    return characters * 2;
  }

  Future<AnnouncementHomeSummary> homeSummary() async {
    final source = await defaultSource();
    final cached = await loadCachedAnnouncements(source: source);
    if (cached.isNotEmpty) {
      return AnnouncementHomeSummary(source == AnnouncementSource.official
          ? cached.first.title
          : '${source.name} · ${cached.first.title}');
    }
    return AnnouncementHomeSummary('点击查看${source.name}公告');
  }

  Future<bool> _shouldAutoRefresh(AnnouncementSource source) async {
    final prefs = await _preferencesLoader();
    if (prefs.getInt('$_cacheVersionKey.${source.id}') !=
        _cacheVersionFor(source)) {
      return true;
    }
    final raw = prefs.getString('$_lastRefreshKey.${source.id}');
    final lastRefresh = raw == null ? null : DateTime.tryParse(raw);
    if (lastRefresh == null) {
      return true;
    }
    return _now().difference(lastRefresh) >= autoRefreshInterval;
  }

  Future<void> _saveList(
    AnnouncementSource source,
    List<AnnouncementListItem> items,
  ) async {
    final uniqueItems = _mergeAnnouncements(const [], items);
    _memoryLists[source.id] = uniqueItems;
    await _persistList(source);
  }

  Future<void> _persistList(AnnouncementSource source,
      {bool markRefreshed = true}) {
    final previous = _pendingListWrites[source.id] ?? Future<void>.value();
    late final Future<void> task;
    task = previous.catchError((Object _) {}).then((_) async {
      final prefs = await _preferencesLoader();
      final items = _memoryLists[source.id] ?? const <AnnouncementListItem>[];
      await prefs.setString(
        '$_listCacheKey.${source.id}',
        jsonEncode(items.map((item) => item.toJson()).toList()),
      );
      if (markRefreshed) {
        await prefs.setString(
          '$_lastRefreshKey.${source.id}',
          _now().toIso8601String(),
        );
        await prefs.setInt(
            '$_cacheVersionKey.${source.id}', _cacheVersionFor(source));
      }
    }).whenComplete(() {
      if (identical(_pendingListWrites[source.id], task)) {
        _pendingListWrites.remove(source.id);
      }
    });
    _pendingListWrites[source.id] = task;
    return task;
  }

  List<AnnouncementListItem> _mergeAnnouncements(
    Iterable<AnnouncementListItem> existing,
    Iterable<AnnouncementListItem> incoming, {
    bool preferIncomingOrder = false,
  }) {
    final incomingItems = incoming.toList(growable: false);
    final byUrl = <String, AnnouncementListItem>{};
    void merge(AnnouncementListItem item) {
      final key = announcementUrlKey(item.url);
      final previous = byUrl[key];
      if (previous == null) {
        byUrl[key] = item;
        return;
      }
      byUrl[key] = AnnouncementListItem(
        title: item.title.isNotEmpty ? item.title : previous.title,
        url: previous.url,
        summary: item.summary.isNotEmpty ? item.summary : previous.summary,
        dateText: item.dateText.isNotEmpty ? item.dateText : previous.dateText,
        publishedAt: item.publishedAt ?? previous.publishedAt,
        sourceId: item.sourceId.isNotEmpty ? item.sourceId : previous.sourceId,
        column: item.column.isNotEmpty ? item.column : previous.column,
      );
    }

    for (final item in existing) {
      merge(item);
    }
    for (final item in incomingItems) {
      merge(item);
    }
    if (!preferIncomingOrder) return orderAnnouncements(byUrl.values);
    // A refreshed source page restores its own unknown-date link positions,
    // including links previously pushed below dated history in older caches.
    // Pagination and metadata patches retain the order already being read.
    final keys = <String>{
      for (final item in incomingItems) announcementUrlKey(item.url),
      ...byUrl.keys,
    };
    return orderAnnouncements([for (final key in keys) byUrl[key]!]);
  }
}

class _QueuedAnnouncementCard {
  _QueuedAnnouncementCard({
    required this.item,
    required this.key,
    required this.sourceGeneration,
    required this.articleGeneration,
  })  : summary = item.summary,
        dateText = item.dateText,
        publishedAt = item.publishedAt;

  final AnnouncementListItem item;
  final String key;
  final int sourceGeneration;
  final int articleGeneration;
  final Completer<AnnouncementCardData> completer = Completer();
  final Stopwatch elapsed = Stopwatch()..start();
  Timer? timer;
  bool started = false;
  String summary;
  String dateText;
  DateTime? publishedAt;
}
