import 'dart:convert';
import 'dart:async';
import 'dart:collection';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/common.dart';
import '../services/announcement_api_client.dart';
import '../services/announcement_memory_cache.dart';
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
  })  : _apiClient = apiClient ?? AnnouncementApiClient(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  void dispose() => _apiClient.close();

  static const defaultAutoRefreshInterval = Duration(hours: 12);
  static const _listCacheKey = 'announcements.list.cache';
  static const _lastRefreshKey = 'announcements.lastRefreshAt';
  static const _cacheVersionKey = 'announcements.cacheVersion';
  static const _defaultSourceKey =
      ClientSettingsService.defaultAnnouncementSourceKey;
  static const _favoritesKey = 'announcements.favoriteSources';
  static const _menuExpansionKey = 'announcements.menu.expanded';
  static const _cacheVersion = 5;
  static int _cacheVersionFor(AnnouncementSource source) => switch (source.id) {
        'sfa' => 9,
        'cs' => 6,
        _ => _cacheVersion,
      };

  final AnnouncementApiClient _apiClient;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;
  final Duration autoRefreshInterval;

  final Map<String, List<AnnouncementListItem>> _memoryLists = {};
  final Map<String, List<String?>> _nextPageUrls = {};
  final Map<String, Set<String>> _visitedPageUrls = {};
  late final _previews = AnnouncementMemoryCache<String?>(
    maxEntries: 160,
    maxBytes: 256 * 1024,
    ttl: const Duration(minutes: 5),
    sizeOf: (value) => (value?.length ?? 0) * 2,
    now: _now,
  );
  final Map<String, Future<String?>> _pendingPreviews = {};
  late final _recentDetails = AnnouncementMemoryCache<AnnouncementDetail>(
    maxEntries: 12,
    maxBytes: 8 * 1024 * 1024,
    ttl: const Duration(minutes: 5),
    sizeOf: _detailCacheBytes,
    now: _now,
  );
  final Map<String, Future<AnnouncementDetail>> _pendingDetails = {};
  late final _publicationDates = AnnouncementMemoryCache<AnnouncementListItem?>(
    maxEntries: 160,
    maxBytes: 256 * 1024,
    ttl: const Duration(minutes: 5),
    sizeOf: (item) => item == null ? 0 : 128 + item.dateText.length * 2,
    now: _now,
  );
  final Map<String, Future<AnnouncementListItem?>> _pendingPublicationDates =
      {};
  final Map<String, Future<void>> _pendingListWrites = {};
  final Map<String, int> _cacheGenerations = {};
  final Queue<
      ({
        AnnouncementListItem item,
        Completer<String?> completer,
        int cacheGeneration,
      })> _previewQueue = Queue();
  int _activePreviewRequests = 0;
  static const _maximumQueuedPreviews = 24;

  /// Detail requests for list previews are limited so scrolling a long list
  /// does not open a connection for every announcement at once.
  Future<String?> loadPreview(AnnouncementListItem item) {
    // The Vancouver Film School list has excerpts, but its previews should
    // use the article body like the other parsed announcements. Keep the list
    // excerpt available to the tile if the article has no readable body.
    if (item.summary.isNotEmpty && item.sourceId != 'shvfs') {
      return Future.value(item.summary);
    }
    final key = _detailKey(item);
    final cached = _previews.lookup(key);
    if (cached != null) return Future.value(cached.value);
    final pending = _pendingPreviews[key];
    if (pending != null) return pending;
    // A fast fling should not leave hundreds of offscreen detail requests in
    // memory. The tile can retry if it comes back on screen.
    if (_previewQueue.length >= _maximumQueuedPreviews) {
      return Future.value(null);
    }
    final completer = Completer<String?>();
    _pendingPreviews[key] = completer.future;
    _previewQueue.add((
      item: item,
      completer: completer,
      cacheGeneration: _cacheGenerations[item.sourceId] ?? 0,
    ));
    _pumpPreviewQueue();
    return completer.future;
  }

  void _pumpPreviewQueue() {
    while (_activePreviewRequests < 3 && _previewQueue.isNotEmpty) {
      final request = _previewQueue.removeFirst();
      _activePreviewRequests++;
      unawaited(_loadQueuedPreview(request));
    }
  }

  Future<void> _loadQueuedPreview(
    ({
      AnnouncementListItem item,
      Completer<String?> completer,
      int cacheGeneration,
    }) request,
  ) async {
    final item = request.item;
    final key = _detailKey(item);
    try {
      final detail = await fetchDetail(item);
      // Only the first readable paragraph is needed for a two-line preview.
      // Joining an entire long article here needlessly allocates a large string.
      final previewBuffer = StringBuffer();
      for (final block in detail.blocks) {
        if (!block.isText) continue;
        final value = block.value.trim();
        if (value.isEmpty || value == detail.title) continue;
        if (previewBuffer.isNotEmpty) previewBuffer.write(' ');
        previewBuffer
            .write(value.length > 180 ? value.substring(0, 180) : value);
        if (previewBuffer.length >= 180) break;
      }
      final text =
          previewBuffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      final preview = text.isEmpty
          ? detail.blocks.any((block) =>
                  block.isLink &&
                  Uri.tryParse(block.value)
                          ?.path
                          .toLowerCase()
                          .endsWith('.pdf') ==
                      true)
              ? '[PDF文件]'
              : detail.blocks.any((block) => block.isImage)
                  ? '[图片]'
                  : detail.blocks.any((block) => block.isTable)
                      ? '[表格]'
                      : null
          : text.length > 110
              ? '${text.substring(0, 110)}…'
              : text;
      if (request.cacheGeneration == (_cacheGenerations[item.sourceId] ?? 0)) {
        _previews.put(key, preview);
      }
      request.completer.complete(preview);
    } on Object {
      // A failed detail request is retried if the item is built again later.
      request.completer.complete(null);
    } finally {
      if (identical(_pendingPreviews[key], request.completer.future)) {
        _pendingPreviews.remove(key);
      }
      _activePreviewRequests--;
      _pumpPreviewQueue();
    }
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
        .toList();
    final recent = _keepActiveColumns(
      selected,
      _mergeAnnouncements(const [], items),
    );
    _memoryLists[selected.id] = recent;
    return recent;
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
    if (forceRefresh && !loadNextPage) _invalidateSourceDetails(selected);
    final cached = await loadCachedAnnouncements(source: selected);
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
      final items =
          _mergeAnnouncements(_memoryLists[selected.id] ?? cached, page.items);
      await _saveList(selected, items);
      return items;
    } on Object {
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  /// Fills a visible historical card's missing date, including items that were
  /// not returned by the latest list page. Preserve its original list source.
  Future<AnnouncementListItem?> loadPublicationDate(AnnouncementListItem item) {
    if (item.dateText.isNotEmpty) return Future.value(item);
    final key = _detailKey(item);
    final cached = _publicationDates.lookup(key);
    if (cached != null) return Future.value(cached.value);
    final pending = _pendingPublicationDates[key];
    if (pending != null) return pending;
    final generation = _cacheGenerations[item.sourceId] ?? 0;
    late final Future<AnnouncementListItem?> task;
    task = _loadPublicationDate(item, key, generation).whenComplete(() {
      if (identical(_pendingPublicationDates[key], task)) {
        _pendingPublicationDates.remove(key);
      }
    });
    _pendingPublicationDates[key] = task;
    return task;
  }

  Future<AnnouncementListItem?> _loadPublicationDate(
    AnnouncementListItem item,
    String key,
    int generation,
  ) async {
    AnnouncementListItem? dated;
    try {
      dated = await _apiClient.fetchPublicationDate(item);
    } on Object {
      // Optional metadata must not prevent reading the list or its articles.
    }
    if (generation != (_cacheGenerations[item.sourceId] ?? 0)) return null;
    if (dated != null) {
      final source = AnnouncementSource.byId(item.sourceId);
      final current = await loadCachedAnnouncements(source: source);
      if (generation != (_cacheGenerations[item.sourceId] ?? 0)) return null;
      if (source.id == item.sourceId &&
          current.any((entry) =>
              _announcementUrlKey(entry.url) ==
              _announcementUrlKey(item.url))) {
        _memoryLists[source.id] =
            _mergeAnnouncements(_memoryLists[source.id] ?? current, [dated]);
        try {
          await _persistList(source, markRefreshed: false);
        } on Object {
          // The card can still show the verified date if saving fails.
        }
      }
    }
    if (generation != (_cacheGenerations[item.sourceId] ?? 0)) return null;
    _publicationDates.put(key, dated);
    return dated;
  }

  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    final key = _detailKey(item);
    final cached = _recentDetails.lookup(key);
    if (cached != null) return Future.value(cached.value);
    final pending = _pendingDetails[key];
    if (pending != null) return pending;
    final generation = _cacheGenerations[item.sourceId] ?? 0;
    late final Future<AnnouncementDetail> task;
    task = Future<AnnouncementDetail>.sync(() => _apiClient.fetchDetail(item))
        .then((detail) {
      if (generation == (_cacheGenerations[item.sourceId] ?? 0)) {
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

  String _detailKey(AnnouncementListItem item) =>
      '${item.sourceId}|${_announcementUrlKey(item.url)}';

  void _invalidateSourceDetails(AnnouncementSource source) {
    _cacheGenerations.update(source.id, (value) => value + 1,
        ifAbsent: () => 1);
    final prefix = '${source.id}|';
    _recentDetails.removeWhere((key, _) => key.startsWith(prefix));
    _previews.removeWhere((key, _) => key.startsWith(prefix));
    _pendingDetails.removeWhere((key, _) => key.startsWith(prefix));
    _pendingPreviews.removeWhere((key, _) => key.startsWith(prefix));
    _publicationDates.removeWhere((key, _) => key.startsWith(prefix));
    _pendingPublicationDates.removeWhere((key, _) => key.startsWith(prefix));
    _previewQueue.removeWhere((request) {
      if (request.item.sourceId != source.id) return false;
      request.completer.complete(null);
      return true;
    });
    _apiClient.clearResponseCache();
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
    return DateTime.now().difference(lastRefresh) >= autoRefreshInterval;
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
          DateTime.now().toIso8601String(),
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
    Iterable<AnnouncementListItem> incoming,
  ) {
    final byUrl = <String, AnnouncementListItem>{};
    void merge(AnnouncementListItem item) {
      final key = _announcementUrlKey(item.url);
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
    for (final item in incoming) {
      merge(item);
    }
    final items = byUrl.values.toList();
    final order = {
      for (var index = 0; index < items.length; index++)
        _announcementUrlKey(items[index].url): index,
    };
    items.sort((a, b) {
      final left = a.publishedAt;
      final right = b.publishedAt;
      if (left == null) {
        return right == null
            ? order[_announcementUrlKey(a.url)]!
                .compareTo(order[_announcementUrlKey(b.url)]!)
            : 1;
      }
      if (right == null) return -1;
      final byDate = right.compareTo(left);
      return byDate != 0
          ? byDate
          : order[_announcementUrlKey(a.url)]!
              .compareTo(order[_announcementUrlKey(b.url)]!);
    });
    return items;
  }
}

String _announcementUrlKey(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return url.trim();
  return uri.replace(fragment: '').toString();
}
