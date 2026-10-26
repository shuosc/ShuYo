import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

const _source = AnnouncementSource.official;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('explicit-source list work never opens preferences or writes list data',
      () async {
    SharedPreferences.setMockInitialValues({'unrelated.setting': 'retained'});
    final preferences = await SharedPreferences.getInstance();
    var preferenceReads = 0;
    final api = _MemoryListApi();
    final repository = AnnouncementRepository(
      apiClient: api,
      preferencesLoader: () {
        preferenceReads++;
        throw StateError('List data must remain independent from preferences');
      },
    );
    addTearDown(repository.dispose);

    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    final first = await repository.fetchAnnouncements(source: _source);
    expect(await repository.fetchAnnouncements(source: _source), first);
    expect(await repository.loadCachedAnnouncements(source: _source), first);
    await repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await repository.fetchAnnouncements(source: _source, forceRefresh: true);

    expect(api.requests, hasLength(3));
    expect(preferenceReads, 0);
    expect(preferences.getKeys(), {'unrelated.setting'});
    expect(preferences.getString('unrelated.setting'), 'retained');
  });

  test('five-minute expiry removes the list and cursor before paging restarts',
      () async {
    final start = DateTime(2026, 10, 27);
    var now = start;
    final api = _MemoryListApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    addTearDown(repository.dispose);
    final first = await repository.fetchAnnouncements(source: _source);

    now = start.add(const Duration(minutes: 4, seconds: 59));
    expect(await repository.fetchAnnouncements(source: _source), first);
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);
    expect(api.requests, hasLength(1));

    now = start.add(const Duration(minutes: 5));
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);

    final restarted = await repository.fetchAnnouncements(
        source: _source, loadNextPage: true);
    expect(api.requests, hasLength(2));
    expect(api.requests.last.pageUrls, isNull);
    expect(restarted, hasLength(1));
    expect(restarted.single.url, isNot(first.single.url));
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);

    await repository.fetchAnnouncements(source: _source, loadNextPage: true);
    expect(api.requests.last.pageUrls, [api.nextUrl(_source, 2)]);
  });

  test('the twelve-source LRU evicts a list together with its pagination',
      () async {
    final sources = AnnouncementSource.all.take(13).toList();
    final api = _MemoryListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    for (final source in sources.take(12)) {
      await repository.fetchAnnouncements(source: source);
    }
    expect(api.requests, hasLength(12));

    // Reading an old source promotes that complete list session in the LRU.
    expect(await repository.loadCachedAnnouncements(source: sources.first),
        hasLength(1));
    await repository.fetchAnnouncements(source: sources.last);

    expect(await repository.loadCachedAnnouncements(source: sources.first),
        hasLength(1));
    expect(
        await repository.loadCachedAnnouncements(source: sources[1]), isEmpty);
    expect(repository.hasMoreAnnouncements(source: sources[1]), isFalse);
    expect(repository.hasMoreAnnouncements(source: sources.last), isTrue);
    await repository.fetchAnnouncements(source: sources[1], loadNextPage: true);
    expect(api.requests.last.pageUrls, isNull);
    expect(api.requests.last.sourceId, sources[1].id);
    expect(await repository.loadCachedAnnouncements(source: sources[1]),
        hasLength(1));
  });

  test('the eight-megabyte payload budget bounds lists below the source limit',
      () async {
    final sources = AnnouncementSource.all.take(3).toList();
    // Each cached UTF-16 payload is roughly 3 MB; two fit, three exceed 8 MB.
    final api =
        _MemoryListApi(summary: List<String>.filled(1500000, 'x').join());
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    await repository.fetchAnnouncements(source: sources[0]);
    await repository.fetchAnnouncements(source: sources[1]);
    expect(repository.hasMoreAnnouncements(source: sources[0]), isTrue);
    expect(repository.hasMoreAnnouncements(source: sources[1]), isTrue);

    await repository.fetchAnnouncements(source: sources[2]);
    expect(api.requests, hasLength(3));
    expect(
        await repository.loadCachedAnnouncements(source: sources[0]), isEmpty);
    expect(repository.hasMoreAnnouncements(source: sources[0]), isFalse);
    expect(await repository.loadCachedAnnouncements(source: sources[1]),
        hasLength(1));
    expect(await repository.loadCachedAnnouncements(source: sources[2]),
        hasLength(1));
  });

  test('a newly created repository cannot restore another repository list',
      () async {
    final firstApi = _MemoryListApi();
    final first = AnnouncementRepository(apiClient: firstApi);
    addTearDown(first.dispose);
    await first.fetchAnnouncements(source: _source);
    expect(first.hasMoreAnnouncements(source: _source), isTrue);

    final freshApi = _MemoryListApi();
    final fresh = AnnouncementRepository(apiClient: freshApi);
    addTearDown(fresh.dispose);
    expect(await fresh.loadCachedAnnouncements(source: _source), isEmpty);
    expect(fresh.hasMoreAnnouncements(source: _source), isFalse);
    expect(freshApi.requests, isEmpty);
    expect(await first.loadCachedAnnouncements(source: _source), hasLength(1));
  });

  test('settings access removes only retired cache keys and their subkeys',
      () async {
    const retiredBases = [
      'announcements.list.cache',
      'announcements.lastRefreshAt',
      'announcements.cacheVersion',
    ];
    final retained = <String, Object>{
      'announcements.defaultSource': 'sfa',
      'announcements.favoriteSources': ['utseus'],
      'announcements.menu.expanded.favorites': false,
      'announcements.menu.expanded.college': true,
      'announcements.list.cacheBackup': 'keep adjacent prefix',
      'announcements.lastRefreshAtBackup': 'keep adjacent clock prefix',
      'announcements.cacheVersioned': 20,
      'other.announcements.list.cache': 'keep another namespace',
    };
    SharedPreferences.setMockInitialValues({
      ...retained,
      for (final key in retiredBases) key: 'obsolete',
      for (final key in retiredBases) '$key.shu': 'obsolete',
      for (final key in retiredBases) '$key.utseus.child': 'obsolete',
    });
    final preferences = await SharedPreferences.getInstance();
    final repository = AnnouncementRepository(
        apiClient: _MemoryListApi(),
        preferencesLoader: () async => preferences);
    addTearDown(repository.dispose);

    expect((await repository.defaultSource()).id, 'sfa');
    expect(preferences.getKeys(), retained.keys.toSet());
    for (final entry in retained.entries) {
      expect(preferences.get(entry.key), entry.value, reason: entry.key);
    }
    expect(await repository.favoriteSourceIds(), {'utseus'});
    final expansion = await repository.menuExpansion();
    expect(expansion.favorites, isFalse);
    expect(expansion.college, isTrue);
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
  });

  test('date completion updates fields without extending list freshness',
      () async {
    final start = DateTime(2026, 10, 27);
    var now = start;
    final api = _MemoryListApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    addTearDown(repository.dispose);
    final item = (await repository.fetchAnnouncements(source: _source)).single;
    now = start.add(const Duration(minutes: 4));
    final completion = repository.loadPublicationDate(item);
    api.dates[item.url]!.complete(AnnouncementListItem(
      title: item.title,
      url: item.url,
      sourceId: item.sourceId,
      dateText: '2026-10-26',
      publishedAt: DateTime(2026, 10, 26),
    ));
    expect((await completion)!.dateText, '2026-10-26');
    expect(
        (await repository.loadCachedAnnouncements(source: _source))
            .single
            .dateText,
        '2026-10-26');
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);

    now = start.add(const Duration(minutes: 5));
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
    expect(api.requests, hasLength(1));
  });
}

class _MemoryListApi extends AnnouncementApiClient {
  _MemoryListApi({this.summary = '已有概览'});

  final String summary;
  final requests = <({String sourceId, List<String?>? pageUrls})>[];
  final _headCounts = <String, int>{};
  final dates = <String, Completer<AnnouncementListItem?>>{};

  String nextUrl(AnnouncementSource source, int head) =>
      '${source.listUrls.first}?memorySession=$head&page=2';

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    requests.add((sourceId: source.id, pageUrls: pageUrls));
    final head = pageUrls == null
        ? _headCounts.update(source.id, (value) => value + 1, ifAbsent: () => 1)
        : _headCounts[source.id]!;
    final page = pageUrls == null ? 'head' : 'next';
    return AnnouncementPageBatch(
      items: [
        AnnouncementListItem(
          title: '${source.id} $page $head',
          url: 'https://www.shu.edu.cn/info/1050/${source.id}-$page-$head.htm',
          sourceId: source.id,
          summary: summary,
        ),
      ],
      nextPageUrls: [pageUrls == null ? nextUrl(source, head) : null],
    );
  }

  @override
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) {
    final pending = Completer<AnnouncementListItem?>();
    dates[item.url] = pending;
    return pending.future;
  }
}
