import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_webrtc_session.dart';

void main() {
  test('initial signaling omits session ID until the server provides one', () {
    final start = buildVodWebRtcSignalingMessage(
      command: 'live',
      request: 'start',
      accountToken: 'synthetic-token',
      sessionId: '',
      requestId: 'start-request',
      fields: {'device_id': 'device'},
    );
    expect(start, {
      'cmd_type': 'live',
      'request_type': 'start',
      'account_token': 'synthetic-token',
      'request_id': 'start-request',
      'device_id': 'device',
    });
    expect(start.containsKey('session_id'), isFalse);

    final answer = buildVodWebRtcSignalingMessage(
      command: 'ice',
      request: 'answer',
      accountToken: 'synthetic-token',
      sessionId: 'server-session',
      requestId: 'answer-request',
      fields: {'sdp': 'synthetic-sdp'},
    );
    expect(answer['session_id'], 'server-session');
    expect(answer['sdp'], 'synthetic-sdp');
  });

  for (final useWebVpn in [false, true]) {
    test('${useWebVpn ? 'WebVPN' : 'direct'} signaling waits for first frame',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cookie = Completer<String?>();
      final start = Completer<Map<String, dynamic>>();
      final answer = Completer<Map<String, dynamic>>();
      WebSocket? serverSocket;
      server.listen((request) async {
        cookie.complete(request.headers.value(HttpHeaders.cookieHeader));
        final socket = await WebSocketTransformer.upgrade(request);
        serverSocket = socket;
        socket.listen((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          if (decoded['cmd_type'] == 'live' &&
              decoded['request_type'] == 'start') {
            start.complete(decoded);
            socket.add(jsonEncode({
              'cmd_type': 'ice',
              'request_type': 'offer',
              'session_id': 'server-session',
              'sdp': 'synthetic-offer',
            }));
          } else if (decoded['cmd_type'] == 'ice' &&
              decoded['request_type'] == 'answer') {
            answer.complete(decoded);
          }
        });
      });
      final renderer = _FakeRenderer();
      final peer = _FakePeer();
      final session = VodWebRtcSession(
        VodWebRtcSource(
          signalingUri: Uri.parse('ws://127.0.0.1:${server.port}/signal'),
          deviceId: 'device',
          accountToken: 'synthetic-token',
          stunServer: 'example.invalid:3478',
          useWebVpn: useWebVpn,
          headers: const {'Cookie': 'synthetic-cookie'},
        ),
        renderer: renderer,
        peerFactory: (_) async => peer,
      );
      addTearDown(() async {
        await session.dispose();
        await serverSocket?.close();
        await server.close(force: true);
      });

      await session.start();
      expect(await cookie.future.timeout(const Duration(seconds: 5)),
          'synthetic-cookie');
      final startMessage =
          await start.future.timeout(const Duration(seconds: 5));
      expect(startMessage.containsKey('session_id'), isFalse);
      expect(startMessage['device_id'], 'device');
      expect(startMessage['account_token'], 'synthetic-token');
      final answerMessage =
          await answer.future.timeout(const Duration(seconds: 5));
      expect(answerMessage['session_id'], 'server-session');
      expect(answerMessage['sdp'], 'synthetic-answer');
      expect(peer.remoteDescription?.sdp, 'synthetic-offer');
      expect(peer.localDescription?.sdp, 'synthetic-answer');

      final stream = _FakeStream();
      peer.onTrack!(RTCTrackEvent(streams: [stream], track: _FakeTrack()));
      expect(renderer.srcObject, same(stream));
      expect(session.state.value, VodWebRtcState.connecting);
      await session.pause();
      await session.play();
      expect(session.state.value, VodWebRtcState.connecting);
      renderer.onFirstFrameRendered!();
      expect(session.state.value, VodWebRtcState.playing);
    });
  }
}

class _FakeRenderer extends RTCVideoRenderer {
  MediaStream? _stream;

  @override
  MediaStream? get srcObject => _stream;

  @override
  set srcObject(MediaStream? stream) => _stream = stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setVolume(double volume) async {}
}

class _FakePeer extends RTCPeerConnection {
  RTCSessionDescription? remoteDescription;
  RTCSessionDescription? localDescription;

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescription = description;
  }

  @override
  Future<RTCSessionDescription> createAnswer(
          [Map<String, dynamic> constraints = const {}]) async =>
      RTCSessionDescription('synthetic-answer', 'answer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    localDescription = description;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStream extends MediaStream {
  _FakeStream() : super('stream', 'owner');

  @override
  List<MediaStreamTrack> getAudioTracks() => [];

  @override
  List<MediaStreamTrack> getVideoTracks() => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack implements MediaStreamTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
