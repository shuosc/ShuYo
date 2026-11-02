import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';

http.Response _response(Object data) => http.Response(
      jsonEncode({'status': 200, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _page(int page, int total, int pages, List<Object?> records) =>
    _response({
      'currPage': page,
      'totalCount': total,
      'totalPage': pages,
      'list': records,
    });

Map<String, Object?> _class(int id,
        {int term = 7,
        String name = '大学英语',
        String className = '教学班',
        String teacher = '吴雪颖'}) =>
    {
      'id': id,
      'acteId': term,
      'subjName': name,
      'teclName': className,
      'subjCode': 'AB123',
      'courseNo': 'B456',
      'authorized': false,
      'vodEnable': 0,
      'teacherList': [
        {'userName': teacher},
      ],
    };

VodApiClient _client(
  Future<http.Response> Function(http.Request) handler, {
  int selectorPageSize = 1000,
}) =>
    VodApiClient(
      selectorPageSize: selectorPageSize,
      httpClient: MockClient(handler),
      headersLoader: (_) async => {},
      uriResolver: (path, parameters) =>
          Uri.https('vod.example', path, parameters),
    );

class _SessionAuth extends VodAuthService {
  final forcedRefreshes = <bool>[];

  @override
  Future<void> ensureSession(
      {required bool useWebVpn, bool forceRefresh = false}) async {
    forcedRefreshes.add(forceRefresh);
  }

  @override
  Future<Map<String, String>> headersFor(Uri uri, {bool? useWebVpn}) async =>
      {'jwt-token': 'existing'};
}

void main() {
  test('keyword selector defaults to 1000 rows and retains unverified classes',
      () async {
    var requests = 0;
    final api = _client((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/teachingclass/list');
      expect(request.url.queryParameters, {
        'allType': '1',
        'type': '1',
        'condition': '大学英语',
        'pageIndex': '1',
        'pageSize': '1000',
      });
      return _page(1, 2, 1, [_class(26120), _class(26121, term: 4)]);
    });
    addTearDown(api.dispose);

    final results =
        await api.searchCoursesByKeyword(termId: 7, keyword: ' 大学英语 ');
    expect(requests, 1);
    expect(results.single.course.teachingClassId, 26120);
    expect(results.single.course.teacherNames, ['吴雪颖']);
    expect(results.single.lesson.id, 0);
    expect(results.single.lesson.isPlayable, isFalse);
  });

  test('keyword selector paginates and locally rejects unrelated classes',
      () async {
    final pages = <int>[];
    final api = _client((request) async {
      final page = int.parse(request.url.queryParameters['pageIndex']!);
      pages.add(page);
      return _page(
          page,
          4,
          2,
          page == 1
              ? [_class(1), _class(2, term: 4)]
              : [_class(3, name: '大学物理'), _class(4)]);
    }, selectorPageSize: 2);
    addTearDown(api.dispose);

    final results =
        await api.searchCoursesByKeyword(termId: 7, keyword: '大学英语');
    expect(pages, [1, 2]);
    expect(results.map((result) => result.course.teachingClassId), [1, 4]);
  });

  test('large selector pages preserve matches and reject duplicates', () async {
    final records = List<Object?>.generate(
      1000,
      (index) => _class(index + 1, term: index.isEven ? 7 : 4),
    );
    final api = _client((_) async => _page(1, 1000, 1, records));
    addTearDown(api.dispose);
    final results =
        await api.searchCoursesByKeyword(termId: 7, keyword: '大学英语');
    expect(results.length, 500);
    expect(results.first.course.teachingClassId, 1);
    expect(results.last.course.teachingClassId, 999);
    expect(results.every((result) => result.lesson.id == 0), isTrue);

    records[999] = records[0];
    await expectLater(
      api.searchCoursesByKeyword(termId: 7, keyword: '大学英语'),
      throwsA(isA<VodInvalidResponseException>()),
    );
  });

  test('disposed client rejects a late directory page', () async {
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final api = _client((_) {
      requested.complete();
      return response.future;
    });
    final results = api.searchCoursesByKeyword(termId: 7, keyword: '大学英语');
    await requested.future;
    api.dispose();
    response.complete(_page(1, 1, 1, [_class(1)]));
    await expectLater(results, throwsA(isA<VodSessionExpiredException>()));
  });

  test('keyword selector matches teacher, teaching class and identifiers',
      () async {
    for (final keyword in ['吴雪颖', '专题数学', 'b12', 'b456']) {
      final api = _client((_) async => _page(1, 1, 1, [
            _class(1, className: '专题数学班'),
          ]));
      expect(
          (await api.searchCoursesByKeyword(termId: 7, keyword: keyword))
              .single
              .course
              .teachingClassId,
          1);
      api.dispose();
    }
  });

  test('keyword selector rejects invalid input without a request', () async {
    var calls = 0;
    final api = _client((_) async {
      calls++;
      return _page(1, 0, 0, []);
    });
    addTearDown(api.dispose);
    await expectLater(api.searchCoursesByKeyword(termId: 0, keyword: '大学'),
        throwsA(isA<VodInvalidResponseException>()));
    await expectLater(api.searchCoursesByKeyword(termId: 7, keyword: '大'),
        throwsA(isA<VodApiException>()));
    expect(calls, 0);
  });

  test('keyword selector rejects duplicate pages instead of partial results',
      () async {
    final api = _client(
        (request) async => _page(
            int.parse(request.url.queryParameters['pageIndex']!),
            2,
            2,
            [_class(1)]),
        selectorPageSize: 1);
    addTearDown(api.dispose);
    await expectLater(api.searchCoursesByKeyword(termId: 7, keyword: '大学英语'),
        throwsA(isA<VodInvalidResponseException>()));
  });

  test('optional selector rejection never forces a shared session refresh',
      () async {
    for (final codeOnly in [false, true]) {
      final auth = _SessionAuth();
      var calls = 0;
      final api = VodApiClient(
        authService: auth,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('expired', 401);
        }),
        uriResolver: (path, parameters) =>
            Uri.https('vod.example', path, parameters),
      );
      await expectLater(
          codeOnly
              ? api.searchCoursesByCode(termId: 7, keyword: 'AB12')
              : api.searchCoursesByKeyword(termId: 7, keyword: '大学英语'),
          throwsA(isA<VodSessionExpiredException>()));
      expect(calls, 1);
      expect(auth.forcedRefreshes, everyElement(isFalse));
      api.dispose();
      auth.dispose();
    }
  });
}
