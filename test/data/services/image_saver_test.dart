import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/image_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('work.shuyo.app/image_saver');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  Future<void> save(String url, {Map<String, String>? headers}) =>
      HttpOverrides.runZoned(
        () => ImageSaver.saveNetworkImage(url, headers: headers),
        createHttpClient: _RealHttpOverrides().createHttpClient,
      );

  test('saved authenticated images retain scoped headers and image metadata',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? cookie;
    server.listen((request) async {
      cookie = request.headers.value('Cookie');
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    await save('http://127.0.0.1:${server.port}/ppt.png',
        headers: {'Cookie': 'webvpn-token=scoped-example'});
    expect(cookie, 'webvpn-token=scoped-example');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveImage');
    final args = calls.single.arguments as Map;
    expect(args['bytes'], Uint8List.fromList([1, 2, 3]));
    expect(args['filename'], 'ppt.png');
    expect(args['mimeType'], 'image/png');
  });

  test('announcement image saving still works without credentials', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? cookie;
    server.listen((request) async {
      cookie = request.headers.value('Cookie');
      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.add([4, 5]);
      await request.response.close();
    });
    await save('http://127.0.0.1:${server.port}/announcement.jpg');
    expect(cookie, isNull);
    expect(calls.single.method, 'saveImage');
    expect((calls.single.arguments as Map)['mimeType'], 'image/jpeg');
  });

  test('failed authenticated downloads are not forwarded to native saving',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });
    await expectLater(
      save('http://127.0.0.1:${server.port}/ppt.png',
          headers: {'Cookie': 'expired-example'}),
      throwsA(isA<Exception>()),
    );
    expect(calls, isEmpty);
  });
}

class _RealHttpOverrides extends HttpOverrides {}
