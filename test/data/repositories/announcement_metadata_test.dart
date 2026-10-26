import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

class _MetadataDateApiClient extends AnnouncementApiClient {
  _MetadataDateApiClient(this.result);

  final Future<AnnouncementListItem?> result;
  final dateRequests = <AnnouncementListItem>[];
  int pageRequests = 0;

  @override
  Future<AnnouncementListItem?> fetchPublicationDate(
      AnnouncementListItem item) {
    dateRequests.add(item);
    return result;
  }

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    pageRequests++;
    throw StateError('A fresh list cache must not request another page');
  }
}

void main() {
  for (final entry in [
    (sourceId: 'sfa', cacheVersion: 9),
    (sourceId: 'utseus', cacheVersion: 5),
    (sourceId: 'bksy', cacheVersion: 5),
  ]) {
    test('${entry.sourceId} cache keeps history and drops unverified estimates',
        () async {
      final source = AnnouncementSource.byId(entry.sourceId);
      final refreshTime = DateTime.now().toIso8601String();
      final history = AnnouncementListItem(
        title: '有准确日期的历史公告',
        url: 'https://${entry.sourceId}.shu.edu.cn/info/1010/1.htm',
        sourceId: entry.sourceId,
        dateText: '2020-01-02',
        publishedAt: DateTime(2020, 1, 2),
      );
      final undated = AnnouncementListItem(
        title: '待查询日期的历史公告',
        url: 'https://${entry.sourceId}.shu.edu.cn/info/1010/2.htm',
        sourceId: entry.sourceId,
        summary: '保留已有摘要',
        publishedAt: DateTime(2099, 1, 1),
      );
      SharedPreferences.setMockInitialValues({
        'announcements.cacheVersion.${entry.sourceId}': entry.cacheVersion,
        'announcements.lastRefreshAt.${entry.sourceId}': refreshTime,
        'announcements.list.cache.${entry.sourceId}':
            jsonEncode([undated.toJson(), history.toJson()]),
      });
      final api = _MetadataDateApiClient(Future.value(null));
      final repository = AnnouncementRepository(apiClient: api);
      addTearDown(repository.dispose);

      final cached = await repository.fetchAnnouncements(source: source);
      expect(cached, hasLength(2));
      final savedHistory =
          cached.singleWhere((item) => item.url == history.url);
      expect(savedHistory.dateText, history.dateText);
      expect(savedHistory.publishedAt, history.publishedAt);
      final waiting = cached.singleWhere((item) => item.url == undated.url);
      expect(waiting.dateText, isEmpty);
      expect(waiting.publishedAt, isNull);
      expect(waiting.summary, undated.summary);
      expect(waiting.sourceId, undated.sourceId);
      expect(api.pageRequests, 0);
      expect(api.dateRequests, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('announcements.lastRefreshAt.${entry.sourceId}'),
          refreshTime);
      expect(prefs.getInt('announcements.cacheVersion.${entry.sourceId}'),
          entry.cacheVersion);
    });
  }

  test('a cross-site metadata date persists under its original list source',
      () async {
    const refreshTime = '2026-10-24T09:30:00.000';
    const item = AnnouncementListItem(
      title: '翔英学院转载的通知',
      url: 'https://scie.shu.edu.cn/info/1070/46185.htm',
      sourceId: 'xiangying',
      summary: '保留列表摘要',
    );
    final dated = AnnouncementListItem(
      title: item.title,
      url: item.url,
      sourceId: item.sourceId,
      summary: item.summary,
      dateText: '2026-03-27',
      publishedAt: DateTime(2026, 3, 27, 14, 15, 2),
    );
    SharedPreferences.setMockInitialValues({
      'announcements.lastRefreshAt.xiangying': refreshTime,
      'announcements.list.cache.xiangying': jsonEncode([item.toJson()]),
    });
    final api = _MetadataDateApiClient(Future.value(dated));
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);

    final resolved = await repository.loadPublicationDate(item);
    expect(resolved!.sourceId, 'xiangying');
    expect(resolved.dateText, '2026-03-27');
    expect(api.dateRequests, [same(item)]);
    expect(await repository.loadPublicationDate(item), same(resolved));
    // Full metadata caching belongs to the API; the repository only patches
    // list ownership and persistence, without a second independent date cache.
    expect(api.dateRequests, hasLength(2));
    await Future<void>.delayed(Duration.zero);

    final restored = AnnouncementRepository();
    addTearDown(restored.dispose);
    final saved = await restored.loadCachedAnnouncements(
        source: AnnouncementSource.byId('xiangying'));
    expect(saved.single.sourceId, 'xiangying');
    expect(saved.single.url, item.url);
    expect(saved.single.summary, item.summary);
    expect(saved.single.dateText, dated.dateText);
    expect(saved.single.publishedAt, dated.publishedAt);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getString('announcements.lastRefreshAt.xiangying'), refreshTime);
    expect(prefs.getString('announcements.list.cache.scie'), isNull);
  });

  test(
      'unavailable optional metadata stays nonfatal without a second date cache',
      () async {
    SharedPreferences.setMockInitialValues({});
    const item = AnnouncementListItem(
      title: '没有可用元数据的中欧公告',
      url: 'https://utseus.shu.edu.cn/info/1010/6186.htm',
      sourceId: 'utseus',
      summary: '摘要仍然可读',
    );
    final pending = Completer<AnnouncementListItem?>();
    final api = _MetadataDateApiClient(pending.future);
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);

    final first = repository.loadPublicationDate(item);
    expect(api.dateRequests, hasLength(1));
    pending.completeError(StateError('Optional export is unavailable'));
    expect(await first, isNull);
    expect(await repository.loadPublicationDate(item), isNull);
    expect(api.dateRequests, hasLength(2));
  });
}
