import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const _course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');

VodLesson _candidate(int id) => VodSearchResult.fromJson({
      'id': id,
      'teclId': 42,
      'acteId': 7,
      'subjName': '课程',
      'courseStatus': 2,
    }).lesson;

http.Response _response(Object data) => http.Response(
      jsonEncode({'status': 200, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodRepository.warmingRequestSpacing = Duration.zero;
  });

  for (final sample in [(30099, 283850, false), (29576, 282334, true)]) {
    test(
        'live preflight rejects empty devices and reuses confirmed metadata ${sample.$2}',
        () async {
      var requests = 0;
      final now = DateTime.now();
      final course =
          VodCourse(teachingClassId: sample.$1, termId: 7, name: '大学物理');
      final live = VodSearchResult.fromJson({
        'id': sample.$2,
        'teclId': sample.$1,
        'acteId': 7,
        'subjName': '大学物理',
        'courseStatus': 0,
      }).lesson;
      final client = VodApiClient(
        headersLoader: (_) async => {},
        mediaHeadersLoader: (_) async => {},
        mediaUrlResolver: Uri.parse,
        uriResolver: (path, params) => Uri.https('vod.example', path, params),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/course_vod_videoinfos');
          return _response({
            'id': sample.$2,
            'teclId': sample.$1,
            'lvcrLiveStatus': 1,
            'liveStartTime':
                now.subtract(const Duration(hours: 1)).toIso8601String(),
            'liveEndTime': now.add(const Duration(hours: 1)).toIso8601String(),
            'courseDeviceViewDtoList': [
              if (sample.$3)
                for (var view = 1; view <= 3; view++)
                  {
                    'deviceStatus': 1,
                    'deviViewNum': view,
                    'chanNameMainHlsPlayUrl':
                        'https://media.example/live$view.m3u8'
                  },
            ],
          });
        }),
      );
      final repo = VodRepository(
          apiClient: client, studentIdLoader: () async => 'live-${sample.$2}');
      addTearDown(repo.dispose);
      expect(await repo.verifyLiveSearchLesson(course, live), sample.$3);
      expect(requests, 1);
      if (sample.$3) {
        final playback =
            await repo.preparePlayback(course: course, lesson: live);
        expect(playback.views, hasLength(3));
        expect(requests, 1);
      }
    });
  }

  for (final outcome in ['available', 'empty', 'denied', 'offline', '401']) {
    test('source-only recording resolves against real detail: $outcome',
        () async {
      final paths = <String>[];
      var mediaHeaders = 0;
      final client = VodApiClient(
        headersLoader: (_) async => {},
        mediaHeadersLoader: (_) async {
          mediaHeaders++;
          return {};
        },
        uriResolver: (path, params) => Uri.https('vod.example', path, params),
        mediaUrlResolver: Uri.parse,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.method, 'GET');
          if (request.url.path == '/v1/subject_vod_list/preview') {
            return _response({
              'pageIndex': 1,
              'pageCount': 0,
              'rowCount': 0,
              'records': [],
            });
          }
          expect(request.url.path, '/v1/course_vod_urls_new');
          if (outcome == 'denied') return http.Response('denied', 403);
          if (outcome == 'offline') return http.Response('offline', 503);
          if (outcome == '401') return http.Response('expired', 401);
          return _response({
            'id': 10,
            'teclId': 42,
            'courseVodViewList': [
              if (outcome == 'available')
                {
                  'courId': 10,
                  'viewNum': 1,
                  'url': 'https://media.example/10.mp4',
                },
            ],
          });
        }),
      );
      final repo = VodRepository(
          apiClient: client, studentIdLoader: () async => 'candidate-$outcome');
      addTearDown(repo.dispose);
      final result = await repo.resolveSearchLessons(_course, [_candidate(10)],
          isCurrent: () => true);
      expect(result.map((lesson) => lesson.id),
          outcome == 'available' ? [10] : isEmpty);
      expect(
          paths, ['/v1/subject_vod_list/preview', '/v1/course_vod_urls_new']);
      expect(mediaHeaders, 0);
    });
  }

  test(
      'preview entries need no extra address probes and generation stays disabled',
      () async {
    final paths = <String>[];
    final client = VodApiClient(
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        return _response({
          'pageIndex': 1,
          'pageCount': 1,
          'rowCount': 1,
          'records': [
            {
              'id': 10,
              'teclId': 42,
              'acteId': 7,
              'subjName': '课程',
              'vodEnable': 1,
              'vodDeleteStatus': 0,
              'vodStatusShow': 4,
            },
          ],
        });
      }),
    );
    final repo = VodRepository(
        apiClient: client, studentIdLoader: () async => 'candidate-generating');
    addTearDown(repo.dispose);
    final result = await repo.resolveSearchLessons(_course, [_candidate(10)],
        isCurrent: () => true);
    expect(result.single.isGenerating, isTrue);
    expect(paths, ['/v1/subject_vod_list/preview']);
  });

  test('selector-only placeholder with empty preview never probes id zero',
      () async {
    final client = VodApiClient(
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/subject_vod_list/preview');
        return _response({
          'pageIndex': 1,
          'pageCount': 0,
          'rowCount': 0,
          'records': [],
        });
      }),
    );
    final repo = VodRepository(
        apiClient: client, studentIdLoader: () async => 'candidate-selector');
    addTearDown(repo.dispose);
    final result = await repo.resolveSearchLessons(
        _course,
        const [
          VodLesson(id: 0, teachingClassId: 42, name: '课程', isPlayable: false),
        ],
        isCurrent: () => true);
    expect(result, isEmpty);
  });
}
