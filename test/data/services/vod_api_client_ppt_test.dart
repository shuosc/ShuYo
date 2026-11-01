import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/core/vod_url_resolver.dart';
import 'package:shuyo/data/services/vod_api_client.dart';

http.Response response(Object? data) => http.Response(
      jsonEncode({'status': 200, 'ok': true, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

VodApiClient client(Future<http.Response> Function(http.Request) handler,
        {bool useWebVpn = false}) =>
    VodApiClient(
      httpClient: MockClient(handler),
      headersLoader: (_) async => {},
      uriResolver: (path, params) => Uri.https('vod.example', path, params),
      useWebVpn: useWebVpn,
    );

void main() {
  test('reads visible OCR notes in stable playback order with optional images',
      () async {
    final api = client((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/course/ai/ppt');
      expect(request.url.queryParameters, {'courseId': '42'});
      return response({
        'docList': [
          {
            'pptDocId': 'second',
            'imageId': 2,
            'imageSeekTime': 20,
            'ocrText': ' 第二页\n公式 ',
            'imageUrl': 'https://vod.cc.shu.edu.cn/images/2.jpg?token=a%2Fb',
            'showFlag': true,
          },
          {
            'imageId': 1,
            'imageSeekTime': '1.5',
            'ocrText': '第一页',
            'imageUrl': '/images/1.jpg',
          },
          {'pptDocId': 'same-time', 'imageSeekTime': 20, 'ocrText': '第三页'},
          {'pptDocId': 'hidden', 'showFlag': false, 'ocrText': '隐藏内容'},
          {'pptDocId': 'blank', 'ocrText': ' \n '},
          {'pptDocId': 'image-only', 'imageUrl': '/images/empty.jpg'},
          {
            'pptDocId': 'bad-image',
            'imageSeekTime': -1,
            'ocrText': '图片失败仍有文字',
            'imageUrl': 'javascript:alert(1)',
          },
        ],
      });
    });
    addTearDown(api.dispose);
    final slides = await api.fetchPptSlides(42);
    expect(slides.map((slide) => slide.id),
        ['bad-image', 'image:1', 'second', 'same-time']);
    expect(slides.map((slide) => slide.position.inMilliseconds),
        [0, 1500, 20000, 20000]);
    expect(slides[0].imageUrl, isNull);
    expect(slides[1].imageUrl.toString(),
        'https://vod.cc.shu.edu.cn/images/1.jpg');
    expect(slides[2].text, '第二页\n公式');
    expect(slides[2].imageUrl!.query, 'token=a%2Fb');
    expect(slides[3].imageUrl, isNull);
    expect(() => slides.clear(), throwsUnsupportedError);
  });

  test('maps relative and absolute PPT images through the selected WebVPN',
      () async {
    final api = client(
        (_) async => response({
              'docList': [
                {
                  'imageId': 1,
                  'imageUrl': '/images/1.jpg',
                  'ocrText': '站内图片',
                },
                {
                  'imageId': 2,
                  'imageUrl':
                      'https://vrmvod.cc.shu.edu.cn:40443/ppt/2.jpg?q=a%2Fb',
                  'ocrText': '媒体图片',
                },
              ],
            }),
        useWebVpn: true);
    addTearDown(api.dispose);
    final slides = await api.fetchPptSlides(42);
    expect(slides[0].imageUrl!.host, VodUrlResolver.webVpnHost);
    expect(slides[1].imageUrl!.host, VodUrlResolver.mediaWebVpnHost);
    expect(slides[1].imageUrl!.query, 'q=a%2Fb');
  });

  test('null data and an empty doc list are valid empty notes', () async {
    for (final data in [
      null,
      {'docList': []}
    ]) {
      final api = client((_) async => response(data));
      addTearDown(api.dispose);
      expect(await api.fetchPptSlides(42), isEmpty);
    }
  });

  for (final data in [
    'invalid',
    <String, Object?>{},
    {'docList': null},
    {'docList': {}},
    {
      'docList': [42]
    },
    {
      'docList': [
        {'imageId': 1, 'ocrText': 123}
      ]
    },
    {
      'docList': [
        {'ocrText': 'missing identity'}
      ]
    },
  ]) {
    test('rejects malformed PPT data $data', () async {
      final api = client((_) async => response(data));
      addTearDown(api.dispose);
      await expectLater(
          api.fetchPptSlides(42), throwsA(isA<VodInvalidResponseException>()));
    });
  }

  test('rejects invalid lesson IDs without making a request', () async {
    final api = client((_) async => throw StateError('unexpected request'));
    addTearDown(api.dispose);
    await expectLater(
        api.fetchPptSlides(0), throwsA(isA<VodInvalidResponseException>()));
  });

  test('missing response data is malformed rather than an empty lesson',
      () async {
    final api = client((_) async => http.Response('{"status":200}', 200));
    addTearDown(api.dispose);
    await expectLater(
        api.fetchPptSlides(42), throwsA(isA<VodInvalidResponseException>()));
  });
}
