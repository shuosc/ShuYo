import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const _course =
    VodCourse(teachingClassId: 42, termId: 7, name: '直播课程', code: 'CS101');
const _lesson = VodLesson(
    id: 123, teachingClassId: 42, name: '直播课程', isPlayable: true, isLive: true);
final _now = DateTime(2026, 10, 28, 10);

http.Response _response(Object data) => http.Response(
    jsonEncode({
      'status': 200,
      'timestamp': _now.millisecondsSinceEpoch,
      'data': data,
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object?> _detail() => {
      'id': 123,
      'teclId': 42,
      'lvcrLiveStatus': 1,
      'liveStartTime':
          _now.subtract(const Duration(hours: 1)).toIso8601String(),
      'liveEndTime': _now.add(const Duration(hours: 1)).toIso8601String(),
      'courseDeviceViewDtoList': [
        {
          'deviceStatus': 0,
          'deviViewNum': 0,
          'chanNameMainHlsPlayUrl':
              'https://media.example/live.m3u8?grant=one%2Btwo',
          'mainTokenStr': 'opaque+token'
        },
        {
          'deviceStatus': 1,
          'deviViewNum': 1,
          'chanNameMainPlayUrl': 'https://media.example/offline.m3u8'
        },
      ],
    };

VodApiClient _client(Future<http.Response> Function(http.Request) handler) =>
    VodApiClient(
      httpClient: MockClient(handler),
      useWebVpn: false,
      headersLoader: (_) async => {'jwt-token': 'business-token'},
      mediaHeadersLoader: (_) async => {
        'Cookie': 'media-cookie',
        'jwt-token': 'must-not-forward',
        'Authorization': 'must-not-forward'
      },
      uriResolver: (path, query) => Uri.https('vod.example', path, query),
      mediaUrlResolver: Uri.parse,
    );

Future<http.Response> _authorized(
    http.Request request, Map<String, Object?> detail) async {
  if (request.url.path.endsWith('/resources')) {
    return _response({
      'resourceList': [
        {'sign': 'p2-live-page'}
      ]
    });
  }
  if (request.url.path.endsWith('/verify')) return _response({'verify': true});
  expect(request.url.path, '/v1/course_vod_videoinfos');
  expect(request.url.queryParameters, {'courseId': '123', 'playType': '3'});
  return _response(detail);
}

void main() {
  test(
      'live HLS checks permissions, preserves signatures and excludes offline views',
      () async {
    final paths = <String>[];
    final client = _client((request) {
      paths.add(request.url.path);
      return _authorized(request, _detail());
    });
    addTearDown(client.dispose);
    final playback =
        await client.fetchLivePlayback(course: _course, lesson: _lesson);
    expect(paths, [
      '/v1/course-role-permission/teaching-class/resources',
      '/v1/course/verify',
      '/v1/course_vod_videoinfos'
    ]);
    expect(playback.isLive, isTrue);
    expect(playback.lastPosition, Duration.zero);
    expect(playback.views, hasLength(1));
    expect(playback.views.single.url.toString(), contains('grant=one%2Btwo'));
    expect(playback.views.single.url.queryParameters['account_token'],
        'opaque+token');
    expect(playback.views.single.httpHeaders, {'Cookie': 'media-cookie'});
    expect(playback.views.single.label, '直播视角 1');
  });

  test('a recording grant does not authorize live playback', () async {
    final paths = <String>[];
    final client = _client((request) async {
      paths.add(request.url.path);
      return _response({
        'resourceList': [
          {'sign': 'p2-video-page'},
          {'sign': 'p2-video-playback-view'}
        ]
      });
    });
    addTearDown(client.dispose);
    await expectLater(
        client.fetchLivePlayback(course: _course, lesson: _lesson),
        throwsA(isA<VodPermissionException>()));
    expect(paths, ['/v1/course-role-permission/teaching-class/resources']);
  });

  for (final scenario in [
    'permission',
    'mismatch',
    'ended',
    'notStarted',
    'noDevices'
  ]) {
    test('live playback rejects $scenario before opening a decoder', () async {
      final detail = _detail();
      switch (scenario) {
        case 'permission':
          detail['lvcrLiveStatus'] = 0;
        case 'mismatch':
          detail['teclId'] = 999;
        case 'ended':
          detail['liveEndTime'] =
              _now.subtract(const Duration(minutes: 1)).toIso8601String();
        case 'notStarted':
          detail['liveStartTime'] =
              _now.add(const Duration(minutes: 1)).toIso8601String();
        case 'noDevices':
          detail['courseDeviceViewDtoList'] = [];
      }
      final client = _client((request) => _authorized(request, detail));
      addTearDown(client.dispose);
      await expectLater(
          client.fetchLivePlayback(course: _course, lesson: _lesson),
          throwsA(isA<VodApiException>()));
    });
  }

  test('live catalog explicitly selects the term, class and active state',
      () async {
    final client = _client((request) async {
      expect(request.url.path, '/v1/vod_live/t-1');
      expect(request.url.queryParameters['acteId'], '7');
      expect(request.url.queryParameters['teclId'], '42');
      expect(request.url.queryParameters['liveType'], '0');
      expect(request.url.queryParameters.containsKey('liveDay'), isFalse);
      return _response({
        'rowCount': 1,
        'pageCount': 1,
        'records': [
          {
            'id': 123,
            'teclId': 42,
            'acteId': 7,
            'liveType': 0,
            'subjName': '直播课程'
          },
        ]
      });
    });
    addTearDown(client.dispose);
    final lessons =
        await client.fetchLiveLessons(termId: 7, teachingClassId: 42);
    expect(lessons.single.isLive, isTrue);
    expect(lessons.single.catalogCourse!.termId, 7);
  });

  test('heartbeat uses the ordinary POST contract', () async {
    final client = _client((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/live/keepAlive');
      expect(jsonDecode(request.body), {'courId': 123, 'subjCode': 'CS101'});
      return _response({});
    });
    addTearDown(client.dispose);
    await client.keepLiveAlive(_course, _lesson);
  });

  test('generating recordings remain listed but cannot be played', () {
    final lesson = VodLesson.fromJson({
      'id': 5,
      'teclId': 42,
      'vodStatus': 4,
      'vodDisplayStatus': 1,
      'vodEnable': 1,
      'vodClickEnable': 0,
      'vodDeleteStatus': 0,
    });
    expect(lesson.isGenerating, isTrue);
    expect(lesson.isListed, isTrue);
    expect(lesson.canPlay, isFalse);
  });
}
