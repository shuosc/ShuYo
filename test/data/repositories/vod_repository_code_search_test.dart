import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

VodSearchResult _result(int id, {String code = 'AB123'}) => VodSearchResult(
      course: VodCourse(teachingClassId: id, termId: 7, name: '课程', code: code),
      lesson:
          VodLesson(id: id, teachingClassId: id, name: '课程', isPlayable: true),
    );

class _Client extends VodApiClient {
  _Client() : super(headersLoader: (_) async => {});
  int sourceCalls = 0;
  int codeCalls = 0;
  Future<List<VodSearchResult>> Function()? source;
  Future<List<VodSearchResult>> Function()? code;

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

  test('Chinese keyword only queries the lesson source', () async {
    final client = _Client();
    final repository = VodRepository(apiClient: client);
    addTearDown(repository.dispose);
    await repository.searchLessons(termId: 7, keyword: '程序设计');
    expect(client.sourceCalls, 1);
    expect(client.codeCalls, 0);
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

  test('session expiry is never hidden by the other search', () async {
    for (final sourceFails in [false, true]) {
      final client = _Client();
      client.source = sourceFails
          ? () => Future.error(const VodSessionExpiredException())
          : () async => [_result(1)];
      client.code = sourceFails
          ? () async => [_result(2)]
          : () => Future.error(const VodSessionExpiredException());
      final repository = VodRepository(apiClient: client);
      await expectLater(repository.searchLessons(termId: 7, keyword: 'AB123'),
          throwsA(isA<VodSessionExpiredException>()));
      repository.dispose();
    }
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
