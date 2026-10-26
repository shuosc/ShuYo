import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

AnnouncementListItem _item(int index, {String fragment = ''}) =>
    AnnouncementListItem(
      title: '通知 $index',
      url: 'https://www.shu.edu.cn/info/1/$index.htm$fragment',
    );

AnnouncementDetail _detail(AnnouncementListItem item, String body) =>
    AnnouncementDetail(
      title: item.title,
      url: item.url,
      blocks: [AnnouncementContentBlock.text(body)],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('opening a recently viewed article promotes it in the bounded LRU',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    for (var index = 0; index < 12; index++) {
      await repository.fetchDetail(_item(index));
    }
    await repository.fetchDetail(_item(0));
    await repository.fetchDetail(_item(12));
    expect(api.detailCalls, 13);
    await repository.fetchDetail(_item(0));
    expect(api.detailCalls, 13);
    await repository.fetchDetail(_item(1));
    expect(api.detailCalls, 14);
  });

  test(
      'article detail expiry is independent from lightweight preview extraction',
      () async {
    var now = DateTime(2026, 10, 25);
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    final item = _item(1);
    expect(await repository.loadPreview(item), '预览 1');
    expect((await repository.fetchDetail(item)).blocks.single.value, '正文 1');
    now = now.add(const Duration(minutes: 5));
    expect(await repository.loadPreview(item), '预览 2');
    expect((await repository.fetchDetail(item)).blocks.single.value, '正文 2');
    expect(api.previewCalls, 2);
    expect(api.detailCalls, 2);
  });

  test('anchors in one article share detail work while previews use the API',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    await Future.wait([
      repository.fetchDetail(_item(1, fragment: '#first')),
      repository.fetchDetail(_item(1, fragment: '#second')),
    ]);
    await Future.wait([
      repository.loadPreview(_item(1, fragment: '#third')),
      repository.loadPreview(_item(1, fragment: '#fourth')),
    ]);
    expect(api.detailCalls, 1);
    expect(api.previewCalls, 2);
  });

  test('force refresh invalidates previews and details without caching lists',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    final item = _item(1);
    expect(await repository.loadPreview(item), '预览 1');
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    expect(await repository.loadPreview(item), '预览 2');
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    expect(api.listCalls, 2);
    expect(api.invalidations, [
      [item.url],
      [item.url],
    ]);
  });

  test('a stale in-flight detail cannot refill or remove newer refresh work',
      () async {
    final api = _CacheApi(defer: true);
    final repository = AnnouncementRepository(apiClient: api);
    final item = _item(1);
    final old = repository.fetchDetail(item);
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    final fresh = repository.fetchDetail(item);
    expect(api.pending, hasLength(2));
    api.pending[0].complete(_detail(item, '旧正文'));
    await old;
    expect(identical(repository.fetchDetail(item), fresh), isTrue);
    api.pending[1].complete(_detail(item, '新正文'));
    expect((await fresh).blocks.single.value, '新正文');
    expect((await repository.fetchDetail(item)).blocks.single.value, '新正文');
    expect(api.detailCalls, 2);
  });

  test(
      'same article shares caches across list sources and refresh stays scoped',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    addTearDown(repository.dispose);
    final original = _item(1);
    final repost = AnnouncementListItem(
      title: original.title,
      url: original.url,
      sourceId: 'sfa',
    );
    const other = AnnouncementListItem(
      title: '人事处另一篇文章',
      url: 'https://rsc.shu.edu.cn/info/1/2.htm',
      sourceId: 'rsc',
    );
    final first = await repository.fetchDetail(original);
    expect(await repository.fetchDetail(repost), same(first));
    await repository.loadPreview(original);
    await repository.loadPreview(repost);
    await repository.fetchDetail(other);
    await repository.loadPreview(other);
    expect(api.detailCalls, 2);
    expect(api.previewCalls, 3);

    await repository.fetchAnnouncements(
        source: AnnouncementSource.byId('sfa'), forceRefresh: true);
    await repository.fetchDetail(other);
    await repository.loadPreview(other);
    expect(api.detailCalls, 2);
    expect(api.previewCalls, 4);
    await repository.fetchDetail(original);
    await repository.loadPreview(original);
    expect(api.detailCalls, 3);
    expect(api.previewCalls, 5);
    expect(api.invalidations.single, [original.url]);
  });
}

class _CacheApi extends AnnouncementApiClient {
  _CacheApi({this.defer = false});

  final bool defer;
  int detailCalls = 0;
  int previewCalls = 0;
  int listCalls = 0;
  final List<Completer<AnnouncementDetail>> pending = [];
  final List<List<String>> invalidations = [];

  @override
  Future<String?> fetchPreview(AnnouncementListItem item) {
    previewCalls++;
    return Future.value('预览 $previewCalls');
  }

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) {
    detailCalls++;
    if (defer) {
      final completer = Completer<AnnouncementDetail>();
      pending.add(completer);
      return completer.future;
    }
    return Future.value(_detail(item, '正文 $detailCalls'));
  }

  @override
  Future<AnnouncementPageBatch> fetchPage({
    AnnouncementSource source = AnnouncementSource.official,
    List<String?>? pageUrls,
  }) async {
    listCalls++;
    return AnnouncementPageBatch(
      items: [_item(1)],
      nextPageUrls: List.filled(source.listUrls.length, null),
    );
  }

  @override
  void invalidateArticles(Iterable<String> urls) =>
      invalidations.add(urls.toList());
}
