import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/vod_live_stream_proxy.dart';

void main() {
  test(
      'HLS relay rewrites nested playlists, encryption keys and signed segments',
      () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = <Uri>[];
    final cookies = <String?>[];
    upstream.listen((request) async {
      requested.add(request.uri);
      cookies.add(request.headers.value('Cookie'));
      expect(request.headers.value('jwt-token'), isNull);
      expect(request.headers.value('authorization'), isNull);
      if (request.uri.path.endsWith('master.m3u8')) {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo/child.m3u8?grant=one%2Btwo\n');
      } else if (request.uri.path.endsWith('child.m3u8')) {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?grant=three%2Bfour"\n#EXTINF:5,\nsegment.ts?grant=five%2Bsix\n');
      } else {
        request.response.add([1, 2, 3]);
      }
      await request.response.close();
    });
    addTearDown(() => upstream.close(force: true));
    final relay = VodLiveStreamProxy(
      useWebVpn: true,
      headersLoader: (_) async => {
        'Cookie': 'scoped-media',
        'jwt-token': 'private',
        'Authorization': 'private'
      },
      mediaUrlResolver: (target) {
        if (target.host != '127.0.0.1' || target.port != upstream.port) {
          throw const FormatException('unsupported target');
        }
        return target;
      },
    );
    addTearDown(relay.dispose);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<String> read(Uri uri) async =>
        utf8.decoder.bind(await (await client.getUrl(uri)).close()).join();
    final original = Uri.parse(
        'http://127.0.0.1:${upstream.port}/master.m3u8?signature=keep%2Bbytes');
    final entry = await relay.open(original);
    final master = await read(entry);
    final child = Uri.parse(
        master.split('\n').firstWhere((line) => line.startsWith('http')));
    expect(child.port, entry.port);
    final playlist = await read(child);
    final key = Uri.parse(RegExp('URI="([^"]+)"').firstMatch(playlist)![1]!);
    final segment = Uri.parse(
        playlist.split('\n').firstWhere((line) => line.startsWith('http')));
    await read(key);
    await read(segment);
    expect(requested.map((uri) => uri.toString()), [
      '/master.m3u8?signature=keep%2Bbytes',
      '/video/child.m3u8?grant=one%2Btwo',
      '/key.bin?grant=three%2Bfour',
      '/video/segment.ts?grant=five%2Bsix',
    ]);
    expect(cookies, everyElement('scoped-media'));
    expect(await relay.open(original), entry);
  });

  test(
      'production relay rejects arbitrary media hosts before starting a listener',
      () async {
    final relay =
        VodLiveStreamProxy(useWebVpn: true, headersLoader: (_) async => {});
    addTearDown(relay.dispose);
    await expectLater(
        relay.open(Uri.parse('https://unrelated.example/live.m3u8')),
        throwsFormatException);
  });

  test('RTC TS segments mislabeled as HLS remain binary for both views',
      () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final segmentRequests = <String>[];
    final payload = [0x47, 0xff, 0xfe, 0x00, 0x47, 0x80];
    upstream.listen((request) async {
      request.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\nsegment.ts?account_token=media%2Bgrant\n');
      } else {
        segmentRequests.add(request.uri.path);
        expect(request.uri.query, 'account_token=media%2Bgrant');
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-5');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes 0-5/6');
        request.response.add(payload);
      }
      await request.response.close();
    });
    addTearDown(() => upstream.close(force: true));
    final relay = VodLiveStreamProxy(
      useWebVpn: false,
      headersLoader: (_) async => {},
      mediaUrlResolver: (target) => target,
    );
    addTearDown(relay.dispose);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await Future.wait(['classroom', 'ppt'].map((view) async {
      final entry = await relay
          .open(Uri.parse('http://127.0.0.1:${upstream.port}/$view/live.m3u8'));
      final playlist = await utf8.decoder
          .bind(await (await client.getUrl(entry)).close())
          .join();
      final segment = Uri.parse(
          playlist.split('\n').firstWhere((line) => line.startsWith('http')));
      final request = await client.getUrl(segment);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.contentType?.mimeType, 'video/mp2t');
      expect(response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-5/6');
      expect(
          await response
              .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)),
          payload);
    }));
    expect(
        segmentRequests,
        unorderedEquals([
          '/classroom/segment.ts',
          '/ppt/segment.ts',
        ]));
  });
}
