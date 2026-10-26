import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

const _source = AnnouncementSource.official;

AnnouncementListItem _article(int id,
    {bool dated = false, String sourceId = AnnouncementSource.officialId}) {
  final date = dated ? DateTime(2026, 10, id) : null;
  return AnnouncementListItem(
    title: '公告 $id',
    url: 'https://www.shu.edu.cn/info/1050/$id.htm',
    sourceId: sourceId,
    summary: '已有概览 $id',
    dateText: date?.toIso8601String().substring(0, 10) ?? '',
    publishedAt: date,
  );
}

AnnouncementPageBatch _page(List<AnnouncementListItem> items, {String? next}) =>
    AnnouncementPageBatch(items: items, nextPageUrls: [next]);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<List<AnnouncementListItem>> _seed(
  AnnouncementRepository repository,
  _ControlledListApi api,
  List<AnnouncementListItem> items, {
  AnnouncementSource source = _source,
  String? next,
}) async {
  final pending =
      repository.fetchAnnouncements(source: source, forceRefresh: true);
  await _settle();
  api.pages.last.complete(_page(items, next: next));
  return pending;
}

void main() {
  test('an older homepage cannot replace a newer refresh or its next page',
      () async {
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);

    final old =
        repository.fetchAnnouncements(source: _source, forceRefresh: true);
    await _settle();
    final fresh =
        repository.fetchAnnouncements(source: _source, forceRefresh: true);
    await _settle();
    expect(api.pages, hasLength(2));
    const freshNext = 'https://www.shu.edu.cn/list/fresh.htm';
    api.pages[1].complete(_page([_article(2)], next: freshNext));
    expect((await fresh).single.url, _article(2).url);

    api.pages[0].complete(_page([_article(1)]));
    expect((await old).single.url, _article(2).url);
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);
    final next =
        repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await _settle();
    expect(api.pageUrls.last, [freshNext]);
    api.pages.last.complete(_page([_article(3)]));
    expect((await next).map((item) => item.url),
        [_article(2).url, _article(3).url]);
  });

  test('an older pagination cannot consume the refreshed pagination cursor',
      () async {
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    const oldNext = 'https://www.shu.edu.cn/list/old.htm';
    await _seed(repository, api, [_article(1)], next: oldNext);

    final oldPagination =
        repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await _settle();
    final refresh =
        repository.fetchAnnouncements(source: _source, forceRefresh: true);
    await _settle();
    const freshNext = 'https://www.shu.edu.cn/list/fresh.htm';
    api.pages[2].complete(_page([_article(2)], next: freshNext));
    final fresh = await refresh;
    api.pages[1].complete(_page([_article(99)]));
    expect(await oldPagination, fresh);
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);

    final next =
        repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await _settle();
    expect(api.pageUrls.last, [freshNext]);
    api.pages.last.complete(_page([_article(3)]));
    final loaded = await next;
    expect(loaded.map((item) => item.url),
        [_article(2).url, _article(1).url, _article(3).url]);
    final cached = await repository.loadCachedAnnouncements(source: _source);
    expect(cached.any((item) => item.url == _article(99).url), isFalse);
  });

  test(
      'stale pagination failure returns the fresh memory list without changing it',
      () async {
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    await _seed(repository, api, [_article(1)],
        next: 'https://www.shu.edu.cn/2');
    final oldPagination =
        repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await _settle();
    final refresh =
        repository.fetchAnnouncements(source: _source, forceRefresh: true);
    await _settle();
    api.pages[2].complete(_page([_article(2)]));
    final fresh = await refresh;
    api.pages[1].completeError(StateError('old request failed'));
    expect(await oldPagination, fresh);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
  });

  test(
      'concurrent date completions retain every field and the current card order',
      () async {
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final items = [for (var id = 1; id <= 6; id++) _article(id)];
    await _seed(repository, api, items);

    final pending = items.map(repository.loadPublicationDate).toList();
    for (var index = 0; index < items.length; index++) {
      api.dates[items[index].url]!.complete(_article(index + 1, dated: true));
    }
    await Future.wait(pending);
    final cached = await repository.loadCachedAnnouncements(source: _source);
    expect(cached.map((item) => item.url), items.map((item) => item.url));
    expect(cached.map((item) => item.dateText), [
      for (var id = 1; id <= 6; id++) _article(id, dated: true).dateText,
    ]);
    expect(
        cached.map((item) => item.summary), items.map((item) => item.summary));
    expect(api.pages, hasLength(1));
  });

  test('refresh rejects its older date while another source can still complete',
      () async {
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final otherSource = AnnouncementSource.byId('utseus');
    final item = _article(1);
    final otherItem = _article(2, sourceId: otherSource.id);
    await _seed(repository, api, [item]);
    await _seed(repository, api, [otherItem], source: otherSource);

    final oldDate = repository.loadPublicationDate(item);
    final oldDateResult = api.dates[item.url]!;
    final otherDate = repository.loadPublicationDate(otherItem);
    final otherDateResult = api.dates[otherItem.url]!;
    await _seed(repository, api, [item]);
    oldDateResult.complete(_article(1, dated: true));
    otherDateResult
        .complete(_article(2, dated: true, sourceId: otherSource.id));
    expect(await oldDate, isNull);
    expect((await otherDate)!.sourceId, otherSource.id);
    expect(
        (await repository.loadCachedAnnouncements(source: _source))
            .single
            .dateText,
        isEmpty);
    expect(
        (await repository.loadCachedAnnouncements(source: otherSource))
            .single
            .dateText,
        _article(2, dated: true).dateText);

    final freshDate = repository.loadPublicationDate(item);
    api.dates[item.url]!.complete(_article(1, dated: true));
    expect((await freshDate)!.dateText, _article(1, dated: true).dateText);
    expect(
        (await repository.loadCachedAnnouncements(source: _source))
            .single
            .dateText,
        _article(1, dated: true).dateText);
  });

  test('a late date cannot resurrect an expired list or its pagination cursor',
      () async {
    var now = DateTime(2026, 10, 27);
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    addTearDown(repository.dispose);
    final item = _article(1);
    await _seed(repository, api, [item], next: 'https://www.shu.edu.cn/2');
    final date = repository.loadPublicationDate(item);
    now = now.add(const Duration(minutes: 5));
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
    api.dates[item.url]!.complete(_article(1, dated: true));
    await date;
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
  });

  test('an active pagination retains its captured list across TTL expiry',
      () async {
    var now = DateTime(2026, 10, 27);
    final api = _ControlledListApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    addTearDown(repository.dispose);
    const secondPage = 'https://www.shu.edu.cn/list/2.htm';
    const thirdPage = 'https://www.shu.edu.cn/list/3.htm';
    await _seed(repository, api, [_article(1)], next: secondPage);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    final pending =
        repository.fetchAnnouncements(source: _source, loadNextPage: true);
    await _settle();
    expect(api.pageUrls.last, [secondPage]);

    now = now.add(const Duration(seconds: 2));
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
    api.pages.last.complete(_page([_article(2)], next: thirdPage));
    final loaded = await pending;
    expect(loaded.map((item) => item.url), [_article(1).url, _article(2).url]);
    expect(repository.hasMoreAnnouncements(source: _source), isTrue);
    expect(
        (await repository.loadCachedAnnouncements(source: _source))
            .map((item) => item.url),
        loaded.map((item) => item.url));

    // A successful next-page response starts a new five-minute lifetime.
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(await repository.loadCachedAnnouncements(source: _source),
        hasLength(2));
    now = now.add(const Duration(seconds: 1));
    expect(await repository.loadCachedAnnouncements(source: _source), isEmpty);
    expect(repository.hasMoreAnnouncements(source: _source), isFalse);
  });
}

class _ControlledListApi extends AnnouncementApiClient {
  final pages = <Completer<AnnouncementPageBatch>>[];
  final pageUrls = <List<String?>?>[];
  final dates = <String, Completer<AnnouncementListItem?>>{};

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) {
    this.pageUrls.add(pageUrls);
    final pending = Completer<AnnouncementPageBatch>();
    pages.add(pending);
    return pending.future;
  }

  @override
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) {
    final pending = Completer<AnnouncementListItem?>();
    dates[item.url] = pending;
    return pending.future;
  }
}
