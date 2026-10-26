import 'dart:async';
import 'dart:collection';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/announcement_target.dart';
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
  administrativeDepartment,
  affiliatedInstitution,
  college,
  researchInstitute,
}

typedef AnnouncementMenuExpansion = ({
  bool favorites,
  bool schoolPortal,
  bool administrativeDepartment,
  bool affiliatedInstitution,
  bool college,
  bool researchInstitute,
});

class AnnouncementRepository {
  AnnouncementRepository({
    AnnouncementApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? now,
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
    _lists.clear();
    _recentDetails.clear();
    _apiClient.close();
  }

  static const cardPreparationTimeout = Duration(seconds: 5);
  static const _defaultSourceKey =
      ClientSettingsService.defaultAnnouncementSourceKey;
  static const _favoritesKey = 'announcements.favoriteSources';
  static const _menuExpansionKey = 'announcements.menu.expanded';

  final AnnouncementApiClient _apiClient;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;
  final Duration cardLoadTimeout;

  late final _lists = AnnouncementMemoryCache<_AnnouncementListState>(
    maxEntries: 12,
    maxBytes: 8 * 1024 * 1024,
    sizeOf: (state) => state.bytes,
    now: _now,
  );
  late final _recentDetails = AnnouncementMemoryCache<AnnouncementDetail>(
    maxEntries: 12,
    maxBytes: 8 * 1024 * 1024,
    sizeOf: _detailCacheBytes,
    now: _now,
  );
  final Map<String, Future<AnnouncementDetail>> _pendingDetails = {};
  Future<void>? _legacyCacheCleanup;
  final Map<String, int> _listGenerations = {};
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
    final prefs = await _preferences();
    return AnnouncementSource.byId(prefs.getString(_defaultSourceKey));
  }

  Future<void> setDefaultSource(AnnouncementSource source) async {
    final prefs = await _preferences();
    await prefs.setString(_defaultSourceKey, source.id);
  }

  Future<Set<String>> favoriteSourceIds() async {
    final prefs = await _preferences();
    final known = AnnouncementSource.all.map((source) => source.id).toSet();
    return (prefs.getStringList(_favoritesKey) ?? const <String>[])
        .where(known.contains)
        .toSet();
  }

  Future<Set<String>> toggleFavoriteSource(AnnouncementSource source) async {
    final prefs = await _preferences();
    final ids = await favoriteSourceIds();
    if (!ids.add(source.id)) ids.remove(source.id);
    await prefs.setStringList(_favoritesKey, ids.toList());
    return ids;
  }

  Future<AnnouncementMenuExpansion> menuExpansion() async {
    final prefs = await _preferences();
    final legacyDepartmentExpanded =
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
          legacyDepartmentExpanded,
      administrativeDepartment:
          prefs.getBool('$_menuExpansionKey.administrativeDepartment') ??
              legacyDepartmentExpanded,
      affiliatedInstitution:
          prefs.getBool('$_menuExpansionKey.affiliatedInstitution') ??
              legacyDepartmentExpanded,
      college: prefs.getBool('$_menuExpansionKey.college') ?? false,
      researchInstitute:
          prefs.getBool('$_menuExpansionKey.researchInstitute') ?? false,
    );
  }

  Future<void> saveMenuExpansion(
    AnnouncementMenuSection section,
    bool expanded,
  ) async {
    final prefs = await _preferences();
    await prefs.setBool('$_menuExpansionKey.${section.name}', expanded);
  }

  Future<List<AnnouncementListItem>> loadCachedAnnouncements({
    AnnouncementSource? source,
  }) async {
    final selected = source ?? await defaultSource();
    return _lists.lookup(selected.id)?.value.items ?? const [];
  }

  bool hasMoreAnnouncements({AnnouncementSource? source}) {
    final id = source?.id;
    if (id == null) return false;
    return _lists.lookup(id)?.value.nextPageUrls.any((url) => url != null) ??
        false;
  }

  Future<List<AnnouncementListItem>> fetchAnnouncements({
    AnnouncementSource? source,
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    final selected = source ?? await defaultSource();
    if (_disposed) return const [];
    final state = _lists.lookup(selected.id)?.value;
    final cached = state?.items ?? const <AnnouncementListItem>[];
    if (forceRefresh && !loadNextPage) _invalidateSourceDetails(selected);
    if (!forceRefresh && !loadNextPage && state != null) return cached;
    final pageUrls = loadNextPage ? state?.nextPageUrls : null;
    if (pageUrls != null && !pageUrls.any((url) => url != null)) return cached;
    final generation = pageUrls == null
        ? _listGenerations.update(selected.id, (value) => value + 1,
            ifAbsent: () => 1)
        : _listGenerations[selected.id] ?? 0;
    final visited = pageUrls == null
        ? selected.listUrls.toSet()
        : {...state!.visitedPageUrls, ...pageUrls.whereType<String>()};
    try {
      final page =
          await _apiClient.fetchPage(source: selected, pageUrls: pageUrls);
      if (!_isCurrentListGeneration(selected, generation)) {
        return _lists.lookup(selected.id)?.value.items ?? const [];
      }
      final next = [
        for (final next in page.nextPageUrls)
          if (next != null && !visited.contains(next)) next else null,
      ];
      final items = _mergeAnnouncements(
        _lists.lookup(selected.id)?.value.items ?? cached,
        page.items,
        preferIncomingOrder: pageUrls == null,
      );
      _lists.put(selected.id, _AnnouncementListState(items, next, visited));
      return items;
    } on Object {
      if (!_isCurrentListGeneration(selected, generation)) {
        return _lists.lookup(selected.id)?.value.items ?? const [];
      }
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  bool _isCurrentListGeneration(AnnouncementSource source, int generation) =>
      !_disposed && generation == (_listGenerations[source.id] ?? 0);

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
      _patchPublicationDate(dated, generation, articleGeneration);
    }
    return dated;
  }

  void _patchPublicationDate(
      AnnouncementListItem dated, int generation, int articleGeneration) {
    final current = _lists.lookup(dated.sourceId)?.value;
    final key = announcementUrlKey(dated.url);
    if (_disposed ||
        current == null ||
        generation != (_cacheGenerations[dated.sourceId] ?? 0) ||
        articleGeneration != (_articleGenerations[key] ?? 0)) {
      return;
    }
    // Replace in place: optional date completion cannot move a card already
    // being read, or change an external link's position among dated items.
    final items = List<AnnouncementListItem>.of(current.items);
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
    _lists.update(
        dated.sourceId,
        _AnnouncementListState(
            items, current.nextPageUrls, current.visitedPageUrls));
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
      for (final item
          in _lists.lookup(source.id)?.value.items ?? <AnnouncementListItem>[])
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

  Future<SharedPreferences> _preferences() async {
    final prefs = await _preferencesLoader();
    try {
      await (_legacyCacheCleanup ??= _removeLegacyListCache(prefs));
    } on Object {
      // Retired data cleanup must not prevent reading or saving user settings.
      _legacyCacheCleanup = null;
    }
    return prefs;
  }

  static Future<void> _removeLegacyListCache(SharedPreferences prefs) async {
    const retiredKeys = [
      'announcements.list.cache',
      'announcements.lastRefreshAt',
      'announcements.cacheVersion'
    ];
    final keys = prefs
        .getKeys()
        .where((key) =>
            retiredKeys.any((base) => key == base || key.startsWith('$base.')))
        .toList();
    await Future.wait(keys.map(prefs.remove));
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

class _AnnouncementListState {
  _AnnouncementListState(
      List<AnnouncementListItem> items, this.nextPageUrls, this.visitedPageUrls)
      : items = List.of(items);

  final List<AnnouncementListItem> items;
  final List<String?> nextPageUrls;
  final Set<String> visitedPageUrls;

  int get bytes =>
      items.fold<int>(
          0,
          (total, item) =>
              total +
              (item.title.length +
                      item.url.length +
                      item.summary.length +
                      item.dateText.length +
                      item.sourceId.length +
                      item.column.length) *
                  2 +
              8) +
      [...nextPageUrls.whereType<String>(), ...visitedPageUrls]
          .fold<int>(0, (total, url) => total + url.length * 2);
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
