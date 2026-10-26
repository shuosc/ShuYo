import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

AnnouncementListItem _item(int id, {String summary = '', String date = ''}) =>
    AnnouncementListItem(
      title: '通知 $id',
      url: 'https://www.shu.edu.cn/info/1/$id.htm',
      summary: summary,
      dateText: date,
      publishedAt: DateTime.tryParse(date),
    );

AnnouncementListItem _dated(AnnouncementListItem item) => AnnouncementListItem(
      title: item.title,
      url: item.url,
      summary: item.summary,
      dateText: '2026-10-26',
      publishedAt: DateTime(2026, 10, 26),
      sourceId: item.sourceId,
      column: item.column,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final hasSummary in [false, true]) {
    for (final hasDate in [false, true]) {
      test(
          'card requests only missing fields: summary=$hasSummary date=$hasDate',
          () async {
        final api = _CardApi();
        final repository = AnnouncementRepository(apiClient: api);
        addTearDown(repository.dispose);
        final item = _item(1,
            summary: hasSummary ? '已有概览' : '',
            date: hasDate ? '2026-10-25' : '');
        var ready = false;
        final pending = repository.loadCard(item)..then((_) => ready = true);
        expect(api.previews.keys, hasSummary ? isEmpty : [item.url]);
        expect(api.dates.keys, hasDate ? isEmpty : [item.url]);
        if (!hasSummary && !hasDate) {
          api.previews[item.url]!.complete('原文概览');
          await Future<void>.delayed(Duration.zero);
          expect(ready, isFalse);
        } else if (!hasSummary) {
          api.previews[item.url]!.complete('原文概览');
        }
        if (!hasDate) api.dates[item.url]!.complete(_dated(item));
        final card = await pending;
        expect(card.summary, hasSummary ? '已有概览' : '原文概览');
        expect(card.dateText, hasDate ? '2026-10-25' : '2026-10-26');
        expect(api.detailCalls, 0);
        expect(api.cancelled, isEmpty);
      });
    }
  }

  test('Vancouver list excerpt is immediately used without fetching its body',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    const item = AnnouncementListItem(
      title: '温哥华公告',
      url: 'https://www.shvfs.cn/site/newsDetail/1624',
      sourceId: 'shvfs',
      summary: '列表已经提供概览',
      dateText: '2026-10-26',
    );
    final card = await repository.loadCard(item);
    expect(card.summary, item.summary);
    expect(api.previews, isEmpty);
    expect(api.dates, isEmpty);
  });

  test('unsupported external links settle without entering network queue',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    const item = AnnouncementListItem(
      title: '外链文件公告始终保留',
      url: 'https://example.com/notice.pdf',
      sourceId: 'sfa',
    );
    final card = await repository.loadCard(item);
    expect(card.summary, isEmpty);
    expect(card.dateText, isEmpty);
    expect(api.previews, isEmpty);
    expect(api.dates, isEmpty);
  });

  test('external website preview failure still settles its visible card',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    const item = AnnouncementListItem(
      title: '电影学院转载微信公告',
      url: 'https://mp.weixin.qq.com/s/external',
      sourceId: 'sfa',
    );
    final pending = repository.loadCard(item);
    expect(api.dates, isEmpty);
    api.previews[item.url]!.complete(null);
    final card = await pending;
    expect(card.summary, isEmpty);
    expect(card.dateText, isEmpty);
  });

  test('queued card work is bounded and expired tasks never start afterwards',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(
      apiClient: api,
      cardLoadTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(repository.dispose);
    final cards = [
      for (var id = 0; id < 35; id++) repository.loadCard(_item(id)),
    ];
    expect(api.previews, hasLength(6));
    expect(api.dates, hasLength(6));
    final all = await Future.wait(cards);
    expect(all, hasLength(35));
    expect(all.every((card) => card.summary.isEmpty), isTrue);
    // Every task has the same absolute deadline. Finishing the first active
    // timeout must not give already-expired queued jobs a fresh five seconds.
    expect(api.previews.length, lessThanOrEqualTo(30));
    final startedAfterDeadline = api.previews.length;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.previews.length, startedAfterDeadline);
  });

  test('card deadline retains settled fields and ignores late optional data',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(
      apiClient: api,
      cardLoadTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(repository.dispose);
    final item = _item(1);
    final pending = repository.loadCard(item);
    expect(repository.loadCard(item), same(pending));
    api.previews[item.url]!.complete('已取得概览');
    final card = await pending;
    expect(card.summary, '已取得概览');
    expect(card.dateText, isEmpty);
    api.dates[item.url]!.complete(_dated(item));
    await Future<void>.delayed(Duration.zero);
    expect(card.dateText, isEmpty);
  });

  test('optional failures settle a card without throwing or losing list fields',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final item = _item(1, summary: '已有概览');
    final pending = repository.loadCard(item);
    api.dates[item.url]!.completeError(StateError('网站暂不可用'));
    final card = await pending;
    expect(card.summary, '已有概览');
    expect(card.dateText, isEmpty);
  });

  test('cancelling one cross-post keeps work required by another visible card',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final original = _item(1);
    final repost = AnnouncementListItem(
      title: original.title,
      url: original.url,
      sourceId: 'sfa',
    );
    final first = repository.loadCard(original);
    final second = repository.loadCard(repost);
    repository.cancelCard(original);
    expect((await first).summary, isEmpty);
    expect(api.cancelled, isEmpty);
    repository.cancelCard(repost);
    expect((await second).summary, isEmpty);
    expect(api.cancelled, [original.url]);
  });

  test('cancelling a queued card settles it without starting a request',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final cards = [
      for (var id = 0; id < 8; id++) repository.loadCard(_item(id)),
    ];
    expect(api.previews, hasLength(6));
    repository.cancelCard(_item(7));
    expect((await cards[7]).summary, isEmpty);
    expect(api.previews.containsKey(_item(7).url), isFalse);
    repository.dispose();
    await Future.wait(cards);
    expect(api.previews.containsKey(_item(7).url), isFalse);
  });

  test(
      'refresh settles stale cards and prevents their queued requests starting',
      () async {
    final api = _CardApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final cards = [
      for (var id = 0; id < 10; id++) repository.loadCard(_item(id)),
    ];
    expect(api.previews, hasLength(6));
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    await Future.wait(cards);
    expect(api.previews, hasLength(6));
    expect(api.dates, hasLength(6));
    for (final pending in api.previews.values) {
      pending.complete('刷新前旧概览');
    }
    for (final pending in api.dates.values) {
      pending.complete(null);
    }
    await Future<void>.delayed(Duration.zero);
    final fresh = repository.loadCard(_item(0));
    api.previews[_item(0).url]!.complete('刷新后概览');
    api.dates[_item(0).url]!.complete(_dated(_item(0)));
    expect((await fresh).summary, '刷新后概览');
  });
}

class _CardApi extends AnnouncementApiClient {
  final previews = <String, Completer<String?>>{};
  final dates = <String, Completer<AnnouncementListItem?>>{};
  final cancelled = <String>[];
  int detailCalls = 0;

  @override
  Future<String?> fetchPreview(AnnouncementListItem item) {
    final result = Completer<String?>();
    previews[item.url] = result;
    return result.future;
  }

  @override
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) {
    final result = Completer<AnnouncementListItem?>();
    dates[item.url] = result;
    return result.future;
  }

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    detailCalls++;
    throw StateError('Preparing a card must not parse full article details');
  }

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async =>
      const AnnouncementPageBatch(items: [], nextPageUrls: []);

  @override
  void invalidateArticles(Iterable<String> urls) {}

  @override
  void cancelOptionalArticle(String url) => cancelled.add(url);
}
