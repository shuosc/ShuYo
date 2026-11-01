import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');
const anotherTerm = VodCourse(teachingClassId: 42, termId: 8, name: '课程');
const lesson =
    VodLesson(id: 12, teachingClassId: 42, name: '课程', isPlayable: false);

class PreviewClient extends VodApiClient {
  PreviewClient({super.useWebVpn}) : super(headersLoader: (_) async => {});

  int requests = 0;
  Future<List<VodLesson>> Function()? onPreview;

  @override
  Future<List<VodLesson>> fetchPreviewLessons(VodCourse course) {
    requests++;
    return onPreview?.call() ?? Future.value([lesson]);
  }

  @override
  Future<List<VodCourse>> fetchCourses(
          {required int termId, void Function(List<VodCourse>)? onProgress}) =>
      throw StateError('preview must not require the account catalog');

  @override
  Future<List<VodLesson>> fetchLiveLessons(
          {required int termId,
          int? teachingClassId,
          void Function(List<VodLesson>)? onProgress}) =>
      throw StateError('preview must not fetch live lessons');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('deduplicates concurrent requests and avoids catalog and live requests',
      () async {
    final client = PreviewClient();
    final pending = Completer<List<VodLesson>>();
    client.onPreview = () => pending.future;
    final repository = VodRepository(
        apiClient: client, studentIdLoader: () async => 'account');
    addTearDown(repository.dispose);
    final first = repository.loadPreviewLessons(course);
    final second = repository.loadPreviewLessons(course);
    await Future<void>.delayed(Duration.zero);
    expect(client.requests, 1);
    pending.complete([lesson]);
    expect((await first).single.id, 12);
    expect((await second).single.id, 12);
  });

  test(
      'restores preview after recreation only for the same account, transport and term',
      () async {
    final online = VodRepository(
        apiClient: PreviewClient(), studentIdLoader: () async => 'a');
    await online.loadPreviewLessons(course);
    online.dispose();

    Future<List<VodLesson>> fail() => Future.error(const VodNetworkException());
    final offlineClient = PreviewClient()..onPreview = fail;
    final offline = VodRepository(
        apiClient: offlineClient, studentIdLoader: () async => 'a');
    addTearDown(offline.dispose);
    expect((await offline.loadPreviewLessons(course)).single.id, 12);
    await expectLater(offline.loadPreviewLessons(anotherTerm),
        throwsA(isA<VodNetworkException>()));

    for (final account in ['b', 'a']) {
      final otherClient = PreviewClient(useWebVpn: account == 'a')
        ..onPreview = fail;
      final other = VodRepository(
          apiClient: otherClient, studentIdLoader: () async => account);
      await expectLater(other.loadPreviewLessons(course),
          throwsA(isA<VodNetworkException>()));
      other.dispose();
    }
  });

  test(
      'empty successful preview is cached but an uncached error remains an error',
      () async {
    final client = PreviewClient()..onPreview = () async => [];
    final repository =
        VodRepository(apiClient: client, studentIdLoader: () async => 'a');
    expect(await repository.loadPreviewLessons(course), isEmpty);
    repository.dispose();
    final offlineClient = PreviewClient()
      ..onPreview = () => Future.error(const VodNetworkException());
    final offline = VodRepository(
        apiClient: offlineClient, studentIdLoader: () async => 'a');
    addTearDown(offline.dispose);
    expect(await offline.loadPreviewLessons(course), isEmpty);
    await expectLater(offline.loadPreviewLessons(anotherTerm),
        throwsA(isA<VodNetworkException>()));
  });

  test(
      'account change during request rejects result and cannot populate next account',
      () async {
    var account = 'a';
    final client = PreviewClient();
    final pending = Completer<List<VodLesson>>();
    client.onPreview = () => pending.future;
    final repository =
        VodRepository(apiClient: client, studentIdLoader: () async => account);
    addTearDown(repository.dispose);
    final old = repository.loadPreviewLessons(course);
    await Future<void>.delayed(Duration.zero);
    account = 'b';
    pending.complete([lesson]);
    await expectLater(old, throwsA(isA<VodSessionExpiredException>()));
    client.onPreview = () => Future.error(const VodNetworkException());
    await expectLater(repository.loadPreviewLessons(course),
        throwsA(isA<VodNetworkException>()));
  });

  test('clear rejects in-flight response and starts a fresh request', () async {
    final pending = Completer<List<VodLesson>>();
    final oldClient = PreviewClient()..onPreview = () => pending.future;
    final newClient = PreviewClient();
    final repository = VodRepository(
        apiClient: oldClient,
        clientFactory: () => newClient,
        studentIdLoader: () async => 'a');
    addTearDown(repository.dispose);
    final old = repository.loadPreviewLessons(course);
    await Future<void>.delayed(Duration.zero);
    repository.clear();
    pending.complete([lesson]);
    await expectLater(old, throwsA(isA<VodSessionExpiredException>()));
    expect((await repository.loadPreviewLessons(course)).single.id, 12);
    expect(newClient.requests, 1);
  });
}
