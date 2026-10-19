import 'dart:convert';
import 'dart:async';
import 'dart:collection';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/common.dart';
import '../services/announcement_api_client.dart';
import '../services/client_settings_service.dart';

class AnnouncementHomeSummary {
  const AnnouncementHomeSummary(this.text);

  final String text;
}

enum AnnouncementMenuSection { favorites, campus, college }

typedef AnnouncementMenuExpansion = ({
  bool favorites,
  bool campus,
  bool college,
});

class AnnouncementRepository {
  AnnouncementRepository({
    AnnouncementApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    this.autoRefreshInterval = defaultAutoRefreshInterval,
  })  : _apiClient = apiClient ?? AnnouncementApiClient(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const defaultAutoRefreshInterval = Duration(hours: 12);
  static const _listCacheKey = 'announcements.list.cache';
  static const _lastRefreshKey = 'announcements.lastRefreshAt';
  static const _cacheVersionKey = 'announcements.cacheVersion';
  static const _defaultSourceKey =
      ClientSettingsService.defaultAnnouncementSourceKey;
  static const _favoritesKey = 'announcements.favoriteSources';
  static const _menuExpansionKey = 'announcements.menu.expanded';
  static const _cacheVersion = 4;

  final AnnouncementApiClient _apiClient;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Duration autoRefreshInterval;

  final Map<String, List<AnnouncementListItem>> _memoryLists = {};
  final Map<String, List<String?>> _nextPageUrls = {};
  final Map<String, Set<String>> _visitedPageUrls = {};
  final Map<String, String?> _previews = {};
  final Map<String, Future<String?>> _pendingPreviews = {};
  final Map<String, AnnouncementDetail> _recentDetails = {};
  final Map<String, Future<AnnouncementDetail>> _pendingDetails = {};
  final Queue<({AnnouncementListItem item, Completer<String?> completer})>
      _previewQueue = Queue();
  int _activePreviewRequests = 0;

  /// Detail requests for list previews are limited so scrolling a long list
  /// does not open a connection for every announcement at once.
  Future<String?> loadPreview(AnnouncementListItem item) {
    if (item.summary.isNotEmpty) return Future.value(item.summary);
    final key = '${item.sourceId}|${item.url}';
    if (_previews.containsKey(key)) return Future.value(_previews[key]);
    final pending = _pendingPreviews[key];
    if (pending != null) return pending;
    final completer = Completer<String?>();
    _pendingPreviews[key] = completer.future;
    _previewQueue.add((item: item, completer: completer));
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
    ({AnnouncementListItem item, Completer<String?> completer}) request,
  ) async {
    final item = request.item;
    final key = '${item.sourceId}|${item.url}';
    try {
      final detail = await fetchDetail(item);
      final text = detail.blocks
          .where((block) => block.isText)
          .map((block) => block.value.trim())
          .where((value) => value.isNotEmpty && value != detail.title)
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
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
      _previews[key] = preview;
      request.completer.complete(preview);
    } on Object {
      // A failed detail request is retried if the item is built again later.
      request.completer.complete(null);
    } finally {
      _pendingPreviews.remove(key);
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
    return (
      favorites: prefs.getBool('$_menuExpansionKey.favorites') ?? true,
      campus: prefs.getBool('$_menuExpansionKey.campus') ?? true,
      college: prefs.getBool('$_menuExpansionKey.college') ?? false,
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
      return _memoryLists[selected.id]!;
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
    final recent = _mergeAnnouncements(const [], items);
    _memoryLists[selected.id] = recent;
    return recent;
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
        final merged = _mergeAnnouncements(cached, page.items);
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
      final items = _mergeAnnouncements(cached, page.items);
      await _saveList(selected, items);
      return items;
    } on Object {
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    final key = '${item.sourceId}|${item.url}';
    final cached = _recentDetails[key];
    if (cached != null) return Future.value(cached);
    final pending = _pendingDetails[key];
    if (pending != null) return pending;
    Future<AnnouncementDetail> load() async {
      try {
        final detail = await _apiClient.fetchDetail(item);
        _recentDetails.remove(key);
        _recentDetails[key] = detail;
        if (_recentDetails.length > 12) {
          _recentDetails.remove(_recentDetails.keys.first);
        }
        return detail;
      } finally {
        _pendingDetails.remove(key);
      }
    }

    final task = load();
    _pendingDetails[key] = task;
    return task;
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
    if (prefs.getInt('$_cacheVersionKey.${source.id}') != _cacheVersion) {
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
    final prefs = await _preferencesLoader();
    await prefs.setString(
      '$_listCacheKey.${source.id}',
      jsonEncode(uniqueItems.map((item) => item.toJson()).toList()),
    );
    await prefs.setString(
      '$_lastRefreshKey.${source.id}',
      DateTime.now().toIso8601String(),
    );
    await prefs.setInt('$_cacheVersionKey.${source.id}', _cacheVersion);
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
