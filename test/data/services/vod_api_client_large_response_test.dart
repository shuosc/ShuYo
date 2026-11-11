import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

const _course = VodCourse(teachingClassId: 42, termId: 7, name: '课程');
const _lesson =
    VodLesson(id: 123, teachingClassId: 42, name: '课次', isPlayable: false);

VodApiClient _client(String body, {VodHeadersLoader? mediaHeadersLoader}) =>
    VodApiClient(
        httpClient: MockClient((_) async => http.Response(body, 200,
            headers: {'content-type': 'application/json; charset=utf-8'})),
        headersLoader: (_) async => {},
        mediaHeadersLoader: mediaHeadersLoader ?? (_) async => {},
        uriResolver: (path, query) => Uri.https('vod.example', path, query),
        mediaUrlResolver: Uri.parse);

void main() {
  test('large detail response decodes and preserves playback URLs', () async {
    final client = _client(jsonEncode({
      'status': 200,
      'data': {
        'id': 123,
        'teclId': 42,
        'description': 'a' * (130 * 1024),
        'courseVodViewList': [
          {'courId': 123, 'viewNum': 1, 'url': 'https://example.com/v.mp4'}
        ],
      }
    }));
    addTearDown(client.dispose);
    final result = await client.fetchPlayback(course: _course, lesson: _lesson);
    expect(result.views.single.url.host, 'example.com');
    expect(result.description.length, 130 * 1024);
  });

  test('large malformed JSON and non-login HTML remain invalid responses',
      () async {
    for (final body in [
      '{${'a' * (130 * 1024)}',
      '<html>${'a' * (130 * 1024)}'
    ]) {
      final client = _client(body);
      await expectLater(client.fetchPlayback(course: _course, lesson: _lesson),
          throwsA(isA<VodInvalidResponseException>()));
      client.dispose();
    }
  });

  test('validated response with no URL has a distinct unavailable error',
      () async {
    final client = _client(jsonEncode({
      'status': 200,
      'data': {'id': 123, 'teclId': 42, 'courseVodViewList': <Object>[]}
    }));
    addTearDown(client.dispose);
    await expectLater(client.fetchPlayback(course: _course, lesson: _lesson),
        throwsA(isA<VodNoPlaybackException>()));
    await expectLater(
        client.checkPlaybackUrls(course: _course, lesson: _lesson),
        throwsA(isA<VodNoPlaybackException>()));
  });

  test('invalid nonempty URL is malformed, not confirmed unavailable',
      () async {
    final client = _client(jsonEncode({
      'status': 200,
      'data': {
        'id': 123,
        'teclId': 42,
        'courseVodViewList': [
          {'courId': 123, 'viewNum': 1, 'url': 'javascript:alert(1)'}
        ],
      }
    }));
    addTearDown(client.dispose);
    await expectLater(
        client.checkPlaybackUrls(course: _course, lesson: _lesson),
        throwsA(isA<VodInvalidResponseException>()));
  });

  test('large SSO HTML remains a session expiration', () async {
    final client = _client('<html>统一身份认证${'a' * (130 * 1024)}');
    addTearDown(client.dispose);
    await expectLater(client.fetchPlayback(course: _course, lesson: _lesson),
        throwsA(isA<VodSessionExpiredException>()));
  });

  test('availability check validates URL without loading media headers',
      () async {
    var mediaHeaderCalls = 0;
    final client = _client(
        jsonEncode({
          'status': 200,
          'data': {
            'id': 123,
            'teclId': 42,
            'vodStatus': 5,
            'vodEnable': 0,
            'lvcrVodStatus': 0,
            'courseVodViewList': [
              {'courId': 123, 'viewNum': 1, 'url': 'https://example.com/v.mp4'}
            ],
          }
        }), mediaHeadersLoader: (_) async {
      mediaHeaderCalls++;
      return {};
    });
    addTearDown(client.dispose);
    await client.checkPlaybackUrls(course: _course, lesson: _lesson);
    expect(mediaHeaderCalls, 0);
    await client.fetchPlayback(course: _course, lesson: _lesson);
    expect(mediaHeaderCalls, 1);
  });
}
