import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

class _MetadataDateApiClient extends AnnouncementApiClient {
  _MetadataDateApiClient(this.result, {this.items = const []});

  final Future<AnnouncementListItem?> result;
  final List<AnnouncementListItem> items;
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
    return AnnouncementPageBatch(
        items: items, nextPageUrls: List.filled(source.listUrls.length, null));
  }
}

void main() {
  for (final sourceId in ['sfa', 'utseus', 'bksy']) {
    test('$sourceId memory reuse preserves verified dates and missing fields',
        () async {
      final source = AnnouncementSource.byId(sourceId);
      final history = AnnouncementListItem(
        title: '有准确日期的历史公告',
        url: 'https://$sourceId.shu.edu.cn/info/1010/1.htm',
        sourceId: sourceId,
        dateText: '2020-01-02',
        publishedAt: DateTime(2020, 1, 2),
      );
      final undated = AnnouncementListItem(
        title: '待查询日期的公告',
        url: 'https://$sourceId.shu.edu.cn/info/1010/2.htm',
        sourceId: sourceId,
        summary: '保留已有摘要',
      );
      final api =
          _MetadataDateApiClient(Future.value(null), items: [undated, history]);
      final repository = AnnouncementRepository(apiClient: api);
      addTearDown(repository.dispose);

      final first = await repository.fetchAnnouncements(source: source);
      final reused = await repository.fetchAnnouncements(source: source);
      expect(reused.map((item) => item.url), first.map((item) => item.url));
      final savedHistory =
          reused.singleWhere((item) => item.url == history.url);
      expect(savedHistory.dateText, history.dateText);
      expect(savedHistory.publishedAt, history.publishedAt);
      final waiting = reused.singleWhere((item) => item.url == undated.url);
      expect(waiting.dateText, isEmpty);
      expect(waiting.publishedAt, isNull);
      expect(waiting.summary, undated.summary);
      expect(waiting.sourceId, sourceId);
      expect(api.pageRequests, 1);
      expect(api.dateRequests, isEmpty);
    });
  }

  test('a cross-site metadata date patches only its original list source',
      () async {
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
    final source = AnnouncementSource.byId('xiangying');
    final api = _MetadataDateApiClient(Future.value(dated), items: [item]);
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    await repository.fetchAnnouncements(source: source);

    final resolved = await repository.loadPublicationDate(item);
    expect(resolved!.sourceId, 'xiangying');
    expect(resolved.dateText, '2026-03-27');
    expect(api.dateRequests, [same(item)]);
    expect(await repository.loadPublicationDate(item), same(resolved));
    // Full metadata reuse belongs to the API; the repository patches the
    // source's current list without adding a second date-result cache.
    expect(api.dateRequests, hasLength(2));

    final saved = await repository.loadCachedAnnouncements(source: source);
    expect(saved.single.sourceId, 'xiangying');
    expect(saved.single.url, item.url);
    expect(saved.single.summary, item.summary);
    expect(saved.single.dateText, dated.dateText);
    expect(saved.single.publishedAt, dated.publishedAt);
    expect(
        await repository.loadCachedAnnouncements(
            source: AnnouncementSource.byId('scie')),
        isEmpty);
    final otherRepository = AnnouncementRepository(
        apiClient: _MetadataDateApiClient(Future.value(null)));
    addTearDown(otherRepository.dispose);
    expect(
        await otherRepository.loadCachedAnnouncements(source: source), isEmpty);
  });

  test('unavailable optional metadata leaves its memory list readable',
      () async {
    const item = AnnouncementListItem(
      title: '没有可用元数据的中欧公告',
      url: 'https://utseus.shu.edu.cn/info/1010/6186.htm',
      sourceId: 'utseus',
      summary: '摘要仍然可读',
    );
    final pending = Completer<AnnouncementListItem?>();
    final api = _MetadataDateApiClient(pending.future, items: [item]);
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final source = AnnouncementSource.byId('utseus');
    await repository.fetchAnnouncements(source: source);

    final first = repository.loadPublicationDate(item);
    expect(api.dateRequests, hasLength(1));
    pending.completeError(StateError('Optional export is unavailable'));
    expect(await first, isNull);
    expect(await repository.loadPublicationDate(item), isNull);
    expect(api.dateRequests, hasLength(2));
    final saved = await repository.loadCachedAnnouncements(source: source);
    expect(saved.single.summary, item.summary);
    expect(saved.single.dateText, isEmpty);
    expect(saved.single.publishedAt, isNull);
  });
}
