import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

http.Response _response(Object data) => http.Response(
      jsonEncode({'status': 200, 'ok': true, 'dataOk': true, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

VodApiClient _client(Future<http.Response> Function(http.Request) handler) =>
    VodApiClient(
      selectorPageSize: 2,
      httpClient: MockClient(handler),
      headersLoader: (_) async => {},
      uriResolver: (path, parameters) =>
          Uri.https('vod.example', path, parameters),
    );

Map<String, Object?> _class({
  required int id,
  int term = 7,
  String? code = '01045069',
  String? courseNo,
  bool authorized = false,
}) =>
    {
      'id': id,
      'acteId': term,
      'subjCode': code,
      'courseNo': courseNo,
      'subjName': '程序设计',
      'teclName': '程序设计班',
      'authorized': authorized,
      'teacherList': [
        {'userName': '教师甲'},
        {'userName': '教师甲'},
        {'userName': '教师乙'}
      ],
    };

void main() {
  test('paginates cross-term results and keeps matching unauthorized classes',
      () async {
    final pages = <int>[];
    final client = _client((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/teachingclass/list');
      expect(request.url.queryParameters['allType'], '1');
      expect(request.url.queryParameters['type'], '1');
      expect(request.url.queryParameters['condition'], '01045069');
      expect(request.url.queryParameters['pageSize'], '2');
      final page = int.parse(request.url.queryParameters['pageIndex']!);
      pages.add(page);
      return _response({
        'currPage': page,
        'totalCount': 4,
        'totalPage': 2,
        'list': page == 1
            ? [_class(id: 1, term: 4), _class(id: 2)]
            : [
                _class(id: 3, code: 'unrelated'),
                _class(id: 4, code: null, courseNo: '01045069'),
              ],
      });
    });
    addTearDown(client.dispose);

    final results = await client.searchCoursesByCode(
      termId: 7,
      keyword: ' 01045069 ',
    );
    expect(pages, [1, 2]);
    expect(results.map((r) => r.course.teachingClassId), [2, 4]);
    expect(results.first.course.code, '01045069');
    expect(results.first.course.teacherNames, ['教师甲', '教师乙']);
    expect(results.last.courseNumber, '01045069');
    expect(results.last.course.code, '');
    expect(
        results.every((r) => r.lesson.id == 0 && !r.lesson.isPlayable), isTrue);
  });

  test('matching identifiers are case insensitive and allow partial codes',
      () async {
    final client = _client((request) async => _response({
          'currPage': 1,
          'totalCount': 1,
          'totalPage': 1,
          'list': [_class(id: 1, code: 'AB12345')],
        }));
    addTearDown(client.dispose);
    final results = await client.searchCoursesByCode(termId: 7, keyword: 'b12');
    expect(results.single.course.code, 'AB12345');
  });

  test('empty result and invalid inputs are handled', () async {
    var calls = 0;
    final client = _client((request) async {
      calls++;
      return _response({
        'currPage': 1,
        'totalCount': 0,
        'totalPage': 0,
        'list': [],
      });
    });
    addTearDown(client.dispose);
    await expectLater(client.searchCoursesByCode(termId: 0, keyword: '123'),
        throwsA(isA<VodInvalidResponseException>()));
    await expectLater(client.searchCoursesByCode(termId: 7, keyword: '1'),
        throwsA(isA<VodApiException>()));
    expect(calls, 0);
    expect(
        await client.searchCoursesByCode(termId: 7, keyword: '123'), isEmpty);
  });

  test('incomplete and repeated pages fail rather than return partial data',
      () async {
    for (final repeated in [false, true]) {
      final client = _client((request) async {
        final page = int.parse(request.url.queryParameters['pageIndex']!);
        return _response({
          'currPage': page,
          'totalCount': 2,
          'totalPage': 2,
          'list': page == 1
              ? [_class(id: 1)]
              : repeated
                  ? [_class(id: 1)]
                  : [],
        });
      });
      await expectLater(client.searchCoursesByCode(termId: 7, keyword: '01'),
          throwsA(isA<VodInvalidResponseException>()));
      client.dispose();
    }
  });

  test('network failure on a later page is not hidden', () async {
    final client = _client((request) async {
      if (request.url.queryParameters['pageIndex'] == '2') {
        return http.Response('unavailable', 503);
      }
      return _response({
        'currPage': 1,
        'totalCount': 2,
        'totalPage': 2,
        'list': [_class(id: 1)],
      });
    });
    addTearDown(client.dispose);
    await expectLater(client.searchCoursesByCode(termId: 7, keyword: '01'),
        throwsA(isA<VodApiException>()));
  });
}
