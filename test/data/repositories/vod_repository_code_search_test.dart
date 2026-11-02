import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

VodSearchResult _result(int id, {String code = 'AB123', String name = '课程'}) =>
    VodSearchResult(
      course: VodCourse(teachingClassId: id, termId: 7, name: name, code: code),
      lesson:
          VodLesson(id: id, teachingClassId: id, name: '课程', isPlayable: true),
    );

class _Client extends VodApiClient {
  _Client() : super(headersLoader: (_) async => {});
  int sourceCalls = 0;
  int codeCalls = 0;
  int keywordCalls = 0;
  Future<List<VodSearchResult>> Function()? source;
  Future<List<VodSearchResult>> Function()? code;
  Future<List<VodSearchResult>> Function()? keyword;

  @override
  Future<List<VodSearchResult>> searchLessons(
      {required int termId, required String keyword}) {
    sourceCalls++;
    return source?.call() ?? Future.value([]);
  }

  @override
  Future<List<VodSearchResult>> searchCoursesByCode(
      {required int termId, required String keyword}) {
    codeCalls++;
    return code?.call() ?? Future.value([]);
  }

  @override
  Future<List<VodSearchResult>> searchCoursesByKeyword(
      {required int termId, required String keyword}) {
    keywordCalls++;
    return this.keyword?.call() ?? Future.value([]);
  }
}

void main() {
  test('starts both searches concurrently and deduplicates classes', () async {
    final source = Completer<List<VodSearchResult>>();
    final code = Completer<List<VodSearchResult>>();
    final client = _Client();
    client.source = () => source.future;
    client.code = () => code.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final result = repository.searchLessons(termId: 7, keyword: 'AB123');
    await Future<void>.delayed(Duration.zero);
    expect(client.sourceCalls, 1);
    expect(client.codeCalls, 1);
    source.complete([_result(1), _result(1)]);
    code.complete([_result(1), _result(2)]);
    expect((await result).map((r) => r.course.teachingClassId), [1, 1, 2]);
  });

  test('Chinese keyword supplements source with teaching class directory',
      () async {
    final client = _Client();
    final first = _result(1, name: '大学英语D(3)');
    final extra = _result(2, name: '大学英语C(3)');
    client.source = () async => [first];
    client.keyword = () async => [first, extra, _result(3, name: '线性代数')];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final results = await repository.searchLessons(termId: 7, keyword: '大学英语');
    expect(results, [first, extra]);
    expect(client.sourceCalls, 1);
    expect(client.codeCalls, 0);
    expect(client.keywordCalls, 1);
  });

  test('directory cache does not cache current lesson source', () async {
    final client = _Client();
    client.source = () async => [_result(client.sourceCalls, name: '大学英语')];
    client.keyword = () async => [_result(100, name: '大学英语')];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final first = await repository.searchLessons(termId: 7, keyword: '大学英语');
    final second = await repository.searchLessons(termId: 7, keyword: '大学英语');
    expect(first.first.lesson.id, 1);
    expect(second.first.lesson.id, 2);
    expect(client.sourceCalls, 2);
    expect(client.keywordCalls, 1);
  });

  test('expired directory cache requests new teaching class metadata',
      () async {
    final client = _Client();
    final repository =
        VodRepository(apiClient: client, cacheDuration: Duration.zero);
    addTearDown(repository.dispose);
    await repository.searchLessons(termId: 7, keyword: '大学英语');
    await repository.searchLessons(termId: 7, keyword: '大学英语');
    expect(client.sourceCalls, 2);
    expect(client.keywordCalls, 2);
  });

  test('a directory failure never discards matching source lessons', () async {
    for (final failure in [
      const VodSessionExpiredException(),
      const VodNetworkException(),
      const VodPermissionException(),
    ]) {
      final client = _Client();
      final hit = _result(1, name: '大学英语');
      client.source = () async => [hit];
      client.keyword = () => Future.error(failure);
      final repository = VodRepository(apiClient: client);
      expect(await repository.searchLessons(termId: 7, keyword: '大学英语'), [hit]);
      repository.dispose();
    }
  });

  test('slow optional directory does not hold usable source lessons', () async {
    final client = _Client();
    final hit = _result(1, name: '大学英语');
    final blocked = Completer<List<VodSearchResult>>();
    client.source = () async => [hit];
    client.keyword = () => blocked.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    expect(await repository.searchLessons(termId: 7, keyword: '大学英语'), [hit]);
    blocked.complete([_result(2, name: '大学英语')]);
    await Future<void>.delayed(Duration.zero);
    expect(
        (await repository.searchLessons(termId: 7, keyword: '大学英语'))
            .map((item) => item.course.teachingClassId),
        [1, 2]);
    expect(client.keywordCalls, 1);
  });

  test('one search timeout does not cancel a later directory consumer',
      () async {
    final client = _Client();
    final hit = _result(1, code: 'AB123', name: '大学英语');
    final blocked = Completer<List<VodSearchResult>>();
    client.source = () async => [hit];
    client.code = () => blocked.future;
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);

    final first = repository.searchLessons(termId: 7, keyword: 'AB123');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // A distinct spelling shares the normalized directory request while
    // retaining an independent search deadline.
    final second = repository.searchLessons(termId: 7, keyword: 'ab123');
    expect(await first, [hit]);
    blocked.complete([_result(2, code: 'AB123', name: '大学英语')]);
    expect((await second).map((item) => item.course.teachingClassId), [1, 2]);
    expect(client.codeCalls, 1);
  });

  test('partial failure returns matched results from either search', () async {
    for (final sourceFails in [false, true]) {
      final client = _Client();
      client.source = sourceFails
          ? () => Future.error(const VodNetworkException())
          : () async => [_result(1)];
      client.code = sourceFails
          ? () async => [_result(2)]
          : () => Future.error(const VodNetworkException());
      final repository = VodRepository(apiClient: client);
      expect(
          (await repository.searchLessons(termId: 7, keyword: 'AB123'))
              .single
              .course
              .teachingClassId,
          sourceFails ? 2 : 1);
      repository.dispose();
    }
  });

  test('unmatched rows do not hide a failure from the other search', () async {
    final client = _Client();
    client.source = () async => [_result(1, code: 'OTHER')];
    client.code = () => Future.error(const VodNetworkException());
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(repository.searchLessons(termId: 7, keyword: 'AB123'),
        throwsA(isA<VodNetworkException>()));
  });

  test('source session expiry is never hidden by directory metadata', () async {
    final client = _Client();
    client.source = () => Future.error(const VodSessionExpiredException());
    client.code = () async => [_result(2)];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await expectLater(repository.searchLessons(termId: 7, keyword: 'AB123'),
        throwsA(isA<VodSessionExpiredException>()));
  });

  test('optional code directory expiry preserves successful source', () async {
    final client = _Client();
    final hit = _result(1);
    client.source = () async => [hit];
    client.code = () => Future.error(const VodSessionExpiredException());
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    expect(await repository.searchLessons(termId: 7, keyword: 'AB123'), [hit]);
  });

  test('matching directory metadata is retained when source does not match',
      () async {
    final client = _Client();
    client.source = () async => [_result(1, code: '')];
    client.code = () async => [_result(1)];
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    final results = await repository.searchLessons(termId: 7, keyword: 'AB123');
    expect(results.length, 2);
    expect(results.last.course.code, 'AB123');
  });
}
