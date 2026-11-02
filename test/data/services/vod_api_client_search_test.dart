import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/common.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

JsonMap _record({
  int id = 123,
  int teachingClassId = 42,
  int termId = 7,
  int courseStatus = 2,
}) =>
    {
      'id': id,
      'teclId': teachingClassId,
      'acteId': termId,
      'subjName': '<em>程序</em>设计',
      'teacNames': ['教师甲'],
      'courseStatus': courseStatus,
      'hasPrivilege': false,
    };

http.Response _response(Object? data) => http.Response(
      jsonEncode({'status': 200, 'ok': true, 'dataOk': true, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

VodApiClient _client(
  Future<http.Response> Function(http.Request) handler,
) =>
    VodApiClient(
      httpClient: MockClient(handler),
      headersLoader: (_) async => {'jwt-token': 'test-business-token'},
      mediaHeadersLoader: (_) async => {},
      uriResolver: (path, parameters) =>
          Uri.https('vod.example', path, parameters),
      mediaUrlResolver: Uri.parse,
    );

void main() {
  test('course and teacher search share trimmed keyword and fixed POST body',
      () async {
    final keywords = <String>[];
    final client = _client((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/course/source/search');
      expect(request.url.queryParameters, isEmpty);
      expect(request.headers['jwt-token'], 'test-business-token');
      expect(request.headers['content-type'], contains('application/json'));
      final body = jsonDecode(request.body) as JsonMap;
      expect(body, {
        'acteId': 7,
        'keyword': body['keyword'],
        'queryType': 0,
        'maxSearchCount': 50,
      });
      keywords.add(body['keyword'] as String);
      return _response({
        'courseSourceList': [_record()]
      });
    });
    addTearDown(client.dispose);

    for (final keyword in ['  程序设计  ', '\t教师甲\n']) {
      final result = await client.searchLessons(termId: 7, keyword: keyword);
      expect(result.single.course.name, '程序设计');
      expect(result.single.lesson.id, 123);
    }
    expect(keywords, ['程序设计', '教师甲']);
  });

  test('invalid term or fewer than two characters fail before networking',
      () async {
    var requests = 0;
    final client = _client((request) async {
      requests++;
      return _response({'courseSourceList': []});
    });
    addTearDown(client.dispose);

    for (final keyword in ['', '  ', '课', ' 课 ', '😀']) {
      await expectLater(client.searchLessons(termId: 7, keyword: keyword),
          throwsA(isA<VodApiException>()));
    }
    for (final termId in [0, -7]) {
      await expectLater(client.searchLessons(termId: termId, keyword: '课程'),
          throwsA(isA<VodInvalidResponseException>()));
    }
    expect(requests, 0);
  });

  test('search retains server order and the first occurrence of each lesson',
      () async {
    final client = _client((request) async => _response({
          'courseSourceList': [
            _record(id: 126),
            _record(id: 123),
            {..._record(id: 126), 'subjName': '重复结果'},
            _record(id: 124, teachingClassId: 43),
          ],
        }));
    addTearDown(client.dispose);

    final results = await client.searchLessons(termId: 7, keyword: '程序');
    expect(results.map((result) => result.lesson.id), [126, 123, 124]);
    expect(results.first.course.name, '程序设计');
    expect(() => results.add(results.first), throwsUnsupportedError);
  });

  test('search returns current live and recordings in one request', () async {
    var requests = 0;
    final client = _client((request) async {
      requests++;
      return _response({
        'courseSourceList': [
          _record(id: 120, courseStatus: 0),
          _record(id: 121, courseStatus: 1),
          {..._record(id: 122), 'courseStatus': null},
          _record(),
          _record(id: 124, courseStatus: 99),
          {..._record(id: 125), 'courseStatus': '0'},
          {..._record(id: 126), 'courseStatus': '2'},
          {..._record(id: 127), 'courseStatus': 0.5},
          {..._record(id: 128), 'courseStatus': false},
        ],
      });
    });
    addTearDown(client.dispose);

    final results = await client.searchLessons(termId: 7, keyword: '程序');
    expect(results.map((result) => result.lesson.id), [120, 123, 125, 126]);
    expect(results.map((result) => result.lesson.isLive),
        [true, false, true, false]);
    expect(results.every((result) => result.lesson.isPlayable), isTrue);
    expect(requests, 1);
  });

  test('duplicate lesson keeps current live regardless of response order',
      () async {
    var requests = 0;
    final client = _client((request) async {
      requests++;
      return _response({
        'courseSourceList': [
          _record(id: 123),
          _record(id: 124, courseStatus: 0),
          _record(id: 123, courseStatus: 0),
          _record(id: 124),
        ],
      });
    });
    addTearDown(client.dispose);

    final results = await client.searchLessons(termId: 7, keyword: '程序');
    expect(results.map((result) => result.lesson.id), [123, 124]);
    expect(results.every((result) => result.lesson.isLiveAvailable), isTrue);
    expect(requests, 1);
  });

  test('live search uses already loaded term metadata without extra requests',
      () async {
    final requests = <String>[];
    final client = _client((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/v1/list/termYear') {
        return http.Response(
            jsonEncode([
              {
                'id': 7,
                'acyeCode': '2026-2027',
                'acteTerm': 1,
                'acteBeginDate': '2026-09-14',
              },
            ]),
            200);
      }
      return _response({
        'courseSourceList': [
          {
            ..._record(courseStatus: 0),
            'courBeginTime': '2026-11-02 13:00:00',
          },
        ],
      });
    });
    addTearDown(client.dispose);
    await client.fetchTerms();
    final result =
        (await client.searchLessons(termId: 7, keyword: '程序')).single;
    expect(result.lesson.weekNumber, 8);
    expect(requests, ['/v1/list/termYear', '/v1/course/source/search']);
  });

  final invalidRecords = <String, JsonMap>{
    'missing lesson ID': {..._record(), 'id': null},
    'invalid lesson ID': _record(id: 0),
    'fractional lesson ID': {..._record(), 'id': 123.5},
    'missing class ID': {..._record(), 'teclId': null},
    'invalid class ID': _record(teachingClassId: -1),
    'other term': _record(termId: 8),
    'missing term': {..._record(), 'acteId': null},
    'fractional term': {..._record(), 'acteId': 7.2},
    'empty names': {..._record(), 'subjName': '<em></em>'},
  };
  for (final entry in invalidRecords.entries) {
    test('search rejects ${entry.key}', () async {
      final client = _client((request) async => _response({
            'courseSourceList': [entry.value],
          }));
      addTearDown(client.dispose);

      await expectLater(client.searchLessons(termId: 7, keyword: '程序'),
          throwsA(isA<VodInvalidResponseException>()));
    });
  }

  test('repeated lesson identity cannot silently change teaching class',
      () async {
    final client = _client((request) async => _response({
          'courseSourceList': [_record(), _record(teachingClassId: 43)],
        }));
    addTearDown(client.dispose);
    await expectLater(client.searchLessons(termId: 7, keyword: '程序'),
        throwsA(isA<VodInvalidResponseException>()));
  });

  for (final data in [
    null,
    <String, Object?>{},
    {'courseSourceList': null},
    {'courseSourceList': {}},
    {
      'courseSourceList': [null]
    },
  ]) {
    test('search rejects malformed results $data', () async {
      final client = _client((request) async => _response(data));
      addTearDown(client.dispose);
      await expectLater(client.searchLessons(termId: 7, keyword: '程序'),
          throwsA(isA<VodInvalidResponseException>()));
    });
  }

  test('empty search succeeds without manufacturing results', () async {
    final client = _client((request) async => _response({
          'courseSourceList': [],
          'hitCount': 0,
        }));
    addTearDown(client.dispose);
    expect(await client.searchLessons(termId: 7, keyword: '课程'), isEmpty);
  });

  test('candidate can fetch playback and the viewer still validates identity',
      () async {
    var invalidDetail = false;
    final client = _client((request) async {
      if (request.url.path == '/v1/course/source/search') {
        return _response({
          'courseSourceList': [_record()]
        });
      }
      expect(request.url.path, '/v1/course_vod_urls_new');
      expect(request.url.queryParameters['courseId'], '123');
      return _response({
        'id': invalidDetail ? 999 : 123,
        'teclId': 42,
        'courseVodViewList': [
          {
            'courId': 123,
            'viewNum': 7,
            'url': 'https://media.example/recording.mp4',
          },
        ],
      });
    });
    addTearDown(client.dispose);
    final result =
        (await client.searchLessons(termId: 7, keyword: '程序')).single;
    final playback = await client.fetchPlayback(
        course: result.course, lesson: result.lesson);
    expect(playback.lessonId, 123);
    expect(playback.views.single.url.path, '/recording.mp4');

    invalidDetail = true;
    await expectLater(
        client.fetchPlayback(course: result.course, lesson: result.lesson),
        throwsA(isA<VodInvalidResponseException>()));
  });
}
