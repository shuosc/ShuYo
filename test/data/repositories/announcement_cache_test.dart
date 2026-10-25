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

  test('expired preview and article caches fetch an updated body', () async {
    var now = DateTime(2026, 10, 25);
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api, now: () => now);
    final item = _item(1);
    expect(await repository.loadPreview(item), '正文 1');
    expect((await repository.fetchDetail(item)).blocks.single.value, '正文 1');
    now = now.add(const Duration(minutes: 5));
    expect(await repository.loadPreview(item), '正文 2');
    expect(api.detailCalls, 2);
  });

  test('anchors in one article share the same preview and detail work',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    await Future.wait([
      repository.fetchDetail(_item(1, fragment: '#first')),
      repository.fetchDetail(_item(1, fragment: '#second')),
    ]);
    await repository.loadPreview(_item(1, fragment: '#third'));
    expect(api.detailCalls, 1);
  });

  test('force refresh invalidates previews and details without caching lists',
      () async {
    final api = _CacheApi();
    final repository = AnnouncementRepository(apiClient: api);
    final item = _item(1);
    expect(await repository.loadPreview(item), '正文 1');
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    expect(await repository.loadPreview(item), '正文 2');
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    expect(api.listCalls, 2);
    expect(api.clearCalls, 2);
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

  test('a stale preview cannot replace the preview loaded after refresh',
      () async {
    final api = _CacheApi(defer: true);
    final repository = AnnouncementRepository(apiClient: api);
    final item = _item(1);
    final old = repository.loadPreview(item);
    await repository.fetchAnnouncements(
        source: AnnouncementSource.official, forceRefresh: true);
    final fresh = repository.loadPreview(item);
    expect(api.pending, hasLength(2));
    api.pending[0].complete(_detail(item, '旧正文'));
    await old;
    expect(identical(repository.loadPreview(item), fresh), isTrue);
    api.pending[1].complete(_detail(item, '新正文'));
    expect(await fresh, '新正文');
    expect(await repository.loadPreview(item), '新正文');
    expect(api.detailCalls, 2);
  });
}

class _CacheApi extends AnnouncementApiClient {
  _CacheApi({this.defer = false});

  final bool defer;
  int detailCalls = 0;
  int listCalls = 0;
  int clearCalls = 0;
  final List<Completer<AnnouncementDetail>> pending = [];

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
  void clearResponseCache() => clearCalls++;
}
