import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:shuyo/data/services/vod_webrtc_signaling.dart';

void main() {
  test('uses compatible header casing and receives WebSocket frames', () async {
    final server = await _RawServer.start();
    addTearDown(server.dispose);
    final socket = await connectVodWebRtcSignaling(server.uri,
        headers: const {'Cookie': 'synthetic-cookie'});
    final headers = await server.headers.future;
    expect(headers, contains('Host: 127.0.0.1:${server.port}'));
    expect(headers, contains('Connection: Upgrade'));
    expect(headers, contains('Upgrade: websocket'));
    expect(headers, contains('Sec-WebSocket-Version: 13'));
    expect(headers, contains('Cookie: synthetic-cookie'));
    expect(
        headers.any((line) => line.startsWith('Sec-WebSocket-Key: ')), isTrue);
    expect(
        headers.any((line) =>
            line.toLowerCase().startsWith('sec-websocket-extensions:')),
        isFalse);
    expect(await socket.first.timeout(const Duration(seconds: 3)), 'ok');
    await socket.close();
  });

  for (final response in [
    'bad-accept',
    'bad-upgrade',
    'bad-connection',
    'extension',
    'status'
  ]) {
    test('rejects invalid upgrade response: $response', () async {
      final server = await _RawServer.start(response: response);
      addTearDown(server.dispose);
      await expectLater(
          connectVodWebRtcSignaling(server.uri),
          throwsA(isA<WebSocketException>().having(
              (error) => error.message,
              'HTTP status',
              contains(response == 'status' ? 'HTTP 426' : 'HTTP 101'))));
    });
  }

  test('times out if the server does not finish its response', () async {
    final server = await _RawServer.start(response: 'hang');
    addTearDown(server.dispose);
    await expectLater(
        connectVodWebRtcSignaling(server.uri,
            timeout: const Duration(milliseconds: 150)),
        throwsA(isA<TimeoutException>()));
  });
}

class _RawServer {
  _RawServer(this.server, this.response);

  final ServerSocket server;
  final String response;
  final headers = Completer<List<String>>();
  Socket? peer;

  int get port => server.port;
  Uri get uri => Uri.parse('ws://127.0.0.1:$port/signal');

  static Future<_RawServer> start({String response = 'ok'}) async {
    final raw = _RawServer(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), response);
    raw.server.listen(raw._accept);
    return raw;
  }

  void _accept(Socket socket) {
    peer = socket;
    final bytes = <int>[];
    var replied = false;
    socket.listen((chunk) {
      if (replied) {
        // A close frame is sufficient for the client to complete teardown.
        if (chunk.isNotEmpty && (chunk.first & 0x0f) == 8) {
          socket.add([0x88, 0]);
        }
        return;
      }
      bytes.addAll(chunk);
      final text = latin1.decode(bytes);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      final lines = text.substring(0, end).split('\r\n');
      headers.complete(lines);
      replied = true;
      if (response == 'hang') return;
      final keyLine = lines.firstWhere(
          (line) => line.toLowerCase().startsWith('sec-websocket-key:'));
      final key = keyLine.substring(keyLine.indexOf(':') + 1).trim();
      final accept = base64Encode(SHA1Digest().process(Uint8List.fromList(
          utf8.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))));
      socket.write(
          'HTTP/1.1 ${response == 'status' ? '426 Upgrade Required' : '101 Switching Protocols'}\r\n');
      socket.write(
          'Connection: ${response == 'bad-connection' ? 'close' : 'keep-alive, Upgrade'}\r\n');
      socket.write(
          'Upgrade: ${response == 'bad-upgrade' ? 'other' : 'websocket'}\r\n');
      socket.write(
          'Sec-WebSocket-Accept: ${response == 'bad-accept' ? 'invalid' : accept}\r\n');
      if (response == 'extension') {
        socket.write('Sec-WebSocket-Extensions: permessage-deflate\r\n');
      }
      socket.write('\r\n');
      if (response == 'ok') socket.add([0x81, 2, 0x6f, 0x6b]);
    });
  }

  Future<void> dispose() async {
    peer?.destroy();
    await server.close();
  }
}
