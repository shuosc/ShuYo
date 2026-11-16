import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

/// Opens the media server's WebSocket using its required header casing.
Future<WebSocket> connectVodWebRtcSignaling(
  Uri uri, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (!const {'ws', 'wss'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('Invalid WebRTC signaling URL');
  }
  final client = HttpClient()..connectionTimeout = timeout;
  var abandoned = false;

  Future<WebSocket> open() async {
    final random = Random.secure();
    final nonce =
        Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256)));
    final key = base64Encode(nonce);
    final expectedAccept = base64Encode(SHA1Digest().process(Uint8List.fromList(
        utf8.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))));
    final target = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
    final request = await client.getUrl(target);
    request.followRedirects = false;
    const reserved = {
      'host',
      'connection',
      'upgrade',
      'sec-websocket-key',
      'sec-websocket-version',
      'sec-websocket-extensions',
      'sec-websocket-protocol',
    };
    for (final entry in headers.entries) {
      if (!reserved.contains(entry.key.toLowerCase())) {
        request.headers.set(entry.key, entry.value, preserveHeaderCase: true);
      }
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    request.headers.set('Host', uri.hasPort ? '$host:${uri.port}' : host,
        preserveHeaderCase: true);
    request.headers.set('Connection', 'Upgrade', preserveHeaderCase: true);
    request.headers.set('Upgrade', 'websocket', preserveHeaderCase: true);
    request.headers.set('Sec-WebSocket-Key', key, preserveHeaderCase: true);
    request.headers
        .set('Sec-WebSocket-Version', '13', preserveHeaderCase: true);
    final response = await request.close();
    bool containsToken(String header, String token) =>
        (response.headers[header] ?? const <String>[])
            .expand((value) => value.split(','))
            .any((value) => value.trim().toLowerCase() == token);
    if (response.statusCode != HttpStatus.switchingProtocols ||
        !containsToken(HttpHeaders.connectionHeader, 'upgrade') ||
        !containsToken(HttpHeaders.upgradeHeader, 'websocket') ||
        response.headers.value('sec-websocket-accept') != expectedAccept ||
        response.headers.value('sec-websocket-extensions') != null ||
        response.headers.value('sec-websocket-protocol') != null) {
      final contentType = response.headers.contentType?.mimeType ?? 'unknown';
      final location = response.headers.value(HttpHeaders.locationHeader);
      final redirectHost =
          location == null ? 'none' : Uri.tryParse(location)?.host;
      final cookieSent =
          headers.keys.any((name) => name.toLowerCase() == 'cookie');
      throw WebSocketException(
          'Invalid WebSocket upgrade response (HTTP ${response.statusCode}); type=$contentType, redirectHost=$redirectHost, cookieSent=$cookieSent');
    }
    final socket = await response.detachSocket();
    if (abandoned) {
      socket.destroy();
      throw TimeoutException('WebRTC signaling connection timed out');
    }
    try {
      return WebSocket.fromUpgradedSocket(socket,
          serverSide: false, compression: CompressionOptions.compressionOff);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  try {
    final socket = await open().timeout(timeout);
    client.close();
    return socket;
  } catch (_) {
    abandoned = true;
    client.close(force: true);
    rethrow;
  }
}
