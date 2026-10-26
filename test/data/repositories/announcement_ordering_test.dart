import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

AnnouncementListItem _article(
  String sourceId,
  String name, {
  DateTime? date,
  String summary = '',
}) =>
    AnnouncementListItem(
      title: name,
      url: 'https://$sourceId.shu.edu.cn/info/1010/$name.htm',
      sourceId: sourceId,
      summary: summary,
      publishedAt: date,
      dateText: date == null ? '' : date.toIso8601String().substring(0, 10),
    );

AnnouncementListItem _external(String sourceId, String name) =>
    AnnouncementListItem(
      title: name,
      url: 'https://mp.weixin.qq.com/s/$name',
      sourceId: sourceId,
    );

class _OrderingApi extends AnnouncementApiClient {
  _OrderingApi(this.pages, this.dates);

  final List<AnnouncementPageBatch> pages;
  final Map<String, AnnouncementListItem> dates;
  final pageRequests = <List<String?>?>[];
  final metadataRequests = <String>[];

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    pageRequests.add(pageUrls);
    return pages.removeAt(0);
  }

  @override
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) async {
    metadataRequests.add(item.url);
    return dates[item.url];
  }
}

void main() {
  for (final sourceId in ['sfa', 'utseus']) {
    test(
        '$sourceId refresh restores external links among dated history and '
        'keeps them through metadata, pagination and cache reload', () async {
      final source = AnnouncementSource.byId(sourceId);
      final newest = _article(sourceId, 'newest',
          date: DateTime(2026, 10, 20), summary: 'Saved list summary');
      final middle = _article(sourceId, 'middle');
      final oldest = _article(sourceId, 'oldest', date: DateTime(2026, 10, 18));
      final firstExternal = _external(sourceId, 'external-a');
      final secondExternal = _external(sourceId, 'external-b');
      final history = [
        for (var day = 20; day > 0; day--)
          _article(sourceId, 'history-$day', date: DateTime(2026, 1, day)),
      ];
      // This mirrors an old cache where all unknown-date links sank below a
      // long dated history. The fresh source page must restore their slots.
      SharedPreferences.setMockInitialValues({
        'announcements.list.cache.$sourceId': jsonEncode([
          newest.toJson(),
          oldest.toJson(),
          ...history.map((item) => item.toJson()),
          firstExternal.toJson(),
          secondExternal.toJson(),
        ]),
      });
      final firstPage = [
        _article(sourceId, 'newest'),
        firstExternal,
        middle,
        secondExternal,
        _article(sourceId, 'oldest'),
      ];
      final firstPageUrls = firstPage.map((item) => item.url).toList();
      final nextUrl = 'https://$sourceId.shu.edu.cn/list/2.htm';
      final pagedArticle =
          _article(sourceId, 'page-two', date: DateTime(2025, 12, 31));
      final pagedExternal = _external(sourceId, 'external-page-two');
      final datedMiddle = _article(sourceId, 'middle',
          date: DateTime(2026, 10, 19), summary: 'Resolved summary');
      final api = _OrderingApi([
        AnnouncementPageBatch(items: firstPage, nextPageUrls: [nextUrl]),
        AnnouncementPageBatch(items: firstPage, nextPageUrls: [nextUrl]),
        AnnouncementPageBatch(
            items: [pagedArticle, pagedExternal], nextPageUrls: [null]),
      ], {
        middle.url: datedMiddle,
      });
      final repository = AnnouncementRepository(apiClient: api);
      addTearDown(repository.dispose);

      void expectSourceLinks(List<AnnouncementListItem> items) {
        expect(items[1].url, firstExternal.url);
        expect(items[3].url, secondExternal.url);
        expect(
            items.where((item) => item.url == firstExternal.url), hasLength(1));
        expect(items.where((item) => item.url == secondExternal.url),
            hasLength(1));
        expect(items[1].dateText, isEmpty);
        expect(items[1].publishedAt, isNull);
        expect(items[3].dateText, isEmpty);
        expect(items[3].publishedAt, isNull);
      }

      final initial = await repository.fetchAnnouncements(
          source: source, forceRefresh: sourceId == 'sfa');
      expect(initial, hasLength(history.length + firstPage.length));
      expect(initial.take(firstPage.length).map((item) => item.url),
          firstPageUrls);
      expectSourceLinks(initial);
      final retained = initial.singleWhere((item) => item.url == newest.url);
      expect(retained.dateText, newest.dateText);
      expect(retained.publishedAt, newest.publishedAt);
      expect(retained.summary, newest.summary);
      expect(retained.sourceId, sourceId);

      expect(await repository.loadPublicationDate(firstExternal), isNull);
      expect(await repository.loadPublicationDate(firstExternal), isNull);
      expect(api.metadataRequests, isEmpty);
      expectSourceLinks(
          await repository.loadCachedAnnouncements(source: source));

      final resolved = await repository.loadPublicationDate(middle);
      expect(resolved!.dateText, '2026-10-19');
      final patched = await repository.loadCachedAnnouncements(source: source);
      expect(patched.take(firstPage.length).map((item) => item.url),
          firstPageUrls);
      expectSourceLinks(patched);
      expect(patched[2].summary, middle.summary);

      final refreshed = await repository.fetchAnnouncements(
          source: source, forceRefresh: true);
      expect(refreshed.take(firstPage.length).map((item) => item.url),
          firstPageUrls);
      expectSourceLinks(refreshed);
      expect(refreshed[2].dateText, datedMiddle.dateText);
      expect(refreshed[2].summary, middle.summary);
      expect(refreshed[2].sourceId, sourceId);
      expect(repository.hasMoreAnnouncements(source: source), isTrue);

      final paginated = await repository.fetchAnnouncements(
          source: source, loadNextPage: true);
      expect(paginated, hasLength(initial.length + 2));
      expect(paginated.take(firstPage.length).map((item) => item.url),
          firstPageUrls);
      expectSourceLinks(paginated);
      expect(paginated[paginated.length - 2].url, pagedArticle.url);
      expect(paginated.last.url, pagedExternal.url);
      expect(repository.hasMoreAnnouncements(source: source), isFalse);
      expect(api.pageRequests, [
        null,
        null,
        [nextUrl]
      ]);

      final restored = AnnouncementRepository();
      addTearDown(restored.dispose);
      final persisted = await restored.loadCachedAnnouncements(source: source);
      expect(
          persisted.map((item) => item.url), paginated.map((item) => item.url));
      expectSourceLinks(persisted);
      expect(persisted[0].summary, newest.summary);
      expect(persisted[2].dateText, datedMiddle.dateText);
      expect(persisted[2].summary, middle.summary);
      expect(persisted.every((item) => item.sourceId == sourceId), isTrue);
    });
  }
}
