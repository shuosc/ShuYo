import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');

http.Response page(int index, List<Map<String, Object?>> records,
        {int total = 3, int pages = 2}) =>
    http.Response(
        jsonEncode({
          'status': 200,
          'ok': true,
          'dataOk': true,
          'data': {
            'pageIndex': index,
            'pageCount': pages,
            'rowCount': total,
            'records': records,
          },
        }),
        200);

VodApiClient client(Future<http.Response> Function(http.Request) handler) =>
    VodApiClient(
      httpClient: MockClient(handler),
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      pageSize: 2,
    );

void main() {
  test('preview reads all pages and retains status 7 and missing flags',
      () async {
    final requests = <Uri>[];
    final api = client((request) async {
      requests.add(request.url);
      final index = int.parse(request.url.queryParameters['page.pageIndex']!);
      return page(index, [
        if (index == 1) ...[
          {
            'id': 1,
            'teclId': 42,
            'acteId': 7,
            'vodStatus': 7,
            'hasPrivilege': false
          },
          {'id': 2, 'teclId': 42},
        ] else
          {'id': 3, 'teclId': 42, 'acteId': 7, 'vodStatus': 5},
      ]);
    });
    addTearDown(api.dispose);
    final lessons = await api.fetchPreviewLessons(course);
    expect(lessons.map((lesson) => lesson.id), [3, 2, 1]);
    expect(lessons.every((lesson) => lesson.canPlay), isTrue);
    expect(requests.map((uri) => uri.path),
        everyElement('/v1/subject_vod_list/preview'));
    expect(requests.map((uri) => uri.queryParameters['teclIds']), ['42', '42']);
    expect(requests.map((uri) => uri.queryParameters['page.pageIndex']),
        ['1', '2']);
    expect(
        requests.every(
            (uri) => uri.queryParameters['schoolOpenStatusFlag'] == 'false'),
        isTrue);
  });

  test('preview retains generating lessons without fetching their details',
      () async {
    var requests = 0;
    final api = client((request) async {
      requests++;
      expect(request.url.path, '/v1/subject_vod_list/preview');
      return page(
          1,
          [
            {
              'id': 1,
              'teclId': 42,
              'acteId': 7,
              'vodEnable': 1,
              'vodDeleteStatus': 0,
              'vodStatus': 3,
              'vodDisplayStatus': 1,
            },
          ],
          total: 1,
          pages: 1);
    });
    addTearDown(api.dispose);
    final lessons = await api.fetchPreviewLessons(course);
    expect(lessons.single.isGenerating, isTrue);
    expect(lessons.single.isPlayable, isFalse);
    expect(lessons.single.isLive, isFalse);
    expect(requests, 1);
  });

  for (final record in [
    {'id': 1, 'teclId': 43, 'acteId': 7},
    {'id': 1, 'teclId': 42, 'acteId': 8},
    {'id': 0, 'teclId': 42, 'acteId': 7},
  ]) {
    test('preview rejects an inconsistent lesson $record', () async {
      final api = client((_) async => page(1, [record], total: 1, pages: 1));
      addTearDown(api.dispose);
      await expectLater(api.fetchPreviewLessons(course),
          throwsA(isA<VodInvalidResponseException>()));
    });
  }

  test('preview does not accept a repeated page or a failed later page',
      () async {
    for (final serverFailure in [false, true]) {
      final api = client((request) async {
        final index = int.parse(request.url.queryParameters['page.pageIndex']!);
        if (serverFailure && index == 2) {
          return http.Response('unavailable', 503);
        }
        return page(
            index,
            [
              {'id': 1, 'teclId': 42}
            ],
            total: 2);
      });
      await expectLater(
          api.fetchPreviewLessons(course), throwsA(isA<VodApiException>()));
      api.dispose();
    }
  });
}
