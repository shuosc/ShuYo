import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/vod_ppt.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const slide = VodPptSlide(
  id: 'first',
  imageUrl: null,
  position: Duration(seconds: 12),
  text: '公式和笔记',
);

class PptClient extends VodApiClient {
  PptClient() : super(headersLoader: (_) async => {});

  final requested = <int>[];
  Future<List<VodPptSlide>> Function(int)? onLoad;

  @override
  Future<List<VodPptSlide>> fetchPptSlides(int courseId) {
    requested.add(courseId);
    return onLoad?.call(courseId) ?? Future.value([slide]);
  }
}

void main() {
  test('deduplicates requests and caches only the requested lesson', () async {
    final client = PptClient();
    final pending = Completer<List<VodPptSlide>>();
    client.onLoad = (_) => pending.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final first = repository.loadPptSlides(42);
    final second = repository.loadPptSlides(42);
    expect(client.requested, [42]);
    pending.complete([slide]);
    expect(await first, [slide]);
    expect(await second, [slide]);
    expect(await repository.loadPptSlides(42), [slide]);
    expect(client.requested, [42]);

    await repository.loadPptSlides(43);
    expect(client.requested, [42, 43]);
  });

  test('caches empty notes and force refresh can replace that result',
      () async {
    final client = PptClient()..onLoad = (_) async => [];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    expect(await repository.loadPptSlides(42), isEmpty);
    expect(await repository.loadPptSlides(42), isEmpty);
    expect(client.requested, [42]);
    client.onLoad = (_) async => [slide];
    expect(await repository.loadPptSlides(42, forceRefresh: true), [slide]);
    expect(client.requested, [42, 42]);
  });

  test('expired in-memory results are refreshed', () async {
    final client = PptClient();
    final repository =
        VodRepository(apiClient: client, cacheDuration: Duration.zero);
    addTearDown(repository.dispose);
    await repository.loadPptSlides(42);
    await repository.loadPptSlides(42);
    expect(client.requested, [42, 42]);
  });

  test('cached results cannot be mutated by the caller or the API client',
      () async {
    final source = [slide];
    final client = PptClient()..onLoad = (_) async => source;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final notes = await repository.loadPptSlides(42);
    source.clear();
    expect(notes, [slide]);
    expect(() => notes.clear(), throwsUnsupportedError);
    expect(await repository.loadPptSlides(42), [slide]);
  });

  test('invalid lesson IDs do not invoke the API', () async {
    final client = PptClient();
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(repository.loadPptSlides(0),
        throwsA(isA<VodInvalidResponseException>()));
    expect(client.requested, isEmpty);
  });

  test('a failed request is not cached and the next attempt can succeed',
      () async {
    final client = PptClient()
      ..onLoad = (_) => Future.error(const VodNetworkException());
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(
        repository.loadPptSlides(42), throwsA(isA<VodNetworkException>()));
    client.onLoad = (_) async => [slide];
    expect(await repository.loadPptSlides(42), [slide]);
    expect(client.requested, [42, 42]);
  });

  test('clear rejects old results and cannot overwrite the new session',
      () async {
    final oldClient = PptClient();
    final nextClient = PptClient()..onLoad = (_) async => [];
    final pending = Completer<List<VodPptSlide>>();
    oldClient.onLoad = (_) => pending.future;
    final repository =
        VodRepository(apiClient: oldClient, clientFactory: () => nextClient);
    addTearDown(repository.dispose);
    final old = repository.loadPptSlides(42);
    final rejected =
        expectLater(old, throwsA(isA<VodSessionExpiredException>()));
    repository.clear();
    expect(await repository.loadPptSlides(42), isEmpty);
    pending.complete([slide]);
    await rejected;
    expect(await repository.loadPptSlides(42), isEmpty);
    expect(nextClient.requested, [42]);
  });

  test('force refresh waits for an older request then fetches fresh notes',
      () async {
    final client = PptClient();
    final pending = Completer<List<VodPptSlide>>();
    client.onLoad = (_) => pending.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final old = repository.loadPptSlides(42);
    final refreshed = repository.loadPptSlides(42, forceRefresh: true);
    expect(client.requested, [42]);
    client.onLoad = (_) async => [];
    pending.complete([slide]);
    expect(await old, [slide]);
    expect(await refreshed, isEmpty);
    expect(client.requested, [42, 42]);
  });

  test('dispose rejects in-flight requests and further loads', () async {
    final client = PptClient();
    final pending = Completer<List<VodPptSlide>>();
    client.onLoad = (_) => pending.future;
    final repository = VodRepository(apiClient: client);
    final loading = repository.loadPptSlides(42);
    final rejected =
        expectLater(loading, throwsA(isA<VodSessionExpiredException>()));
    repository.dispose();
    pending.complete([slide]);
    await rejected;
    expect(() => repository.loadPptSlides(42),
        throwsA(isA<VodSessionExpiredException>()));
  });
}
