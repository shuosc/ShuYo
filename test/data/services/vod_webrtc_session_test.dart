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
      await renderer.volumeStarted.future.timeout(const Duration(seconds: 5));
      expect(renderer.srcObject, same(stream));
      expect(session.state.value, VodWebRtcState.connecting);
      await session.pause();
      await session.play();
      expect(session.state.value, VodWebRtcState.connecting);
      renderer.onFirstFrameRendered!();
      expect(session.state.value, VodWebRtcState.playing);
    });
  }

  test('dispose waits for an in-flight offer before closing the peer',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? serverSocket;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      serverSocket = socket;
      socket.listen((message) {
        final decoded = jsonDecode(message as String) as Map<String, dynamic>;
        if (decoded['cmd_type'] == 'live' &&
            decoded['request_type'] == 'start') {
          socket.add(jsonEncode({
            'cmd_type': 'ice',
            'request_type': 'offer',
            'sdp': 'synthetic-offer',
          }));
        }
      });
    });
    final peer = _FakePeer()..remoteGate = Completer<void>();
    final session = VodWebRtcSession(
      VodWebRtcSource(
        signalingUri: Uri.parse('ws://127.0.0.1:${server.port}/signal'),
        deviceId: 'device',
        accountToken: 'test',
        stunServer: '',
        useWebVpn: false,
      ),
      renderer: _FakeRenderer(),
      peerFactory: (_) async => peer,
    );
    await session.start();
    await peer.remoteStarted.future.timeout(const Duration(seconds: 5));
    final disposal = session.dispose();
    expect(session.dispose(), same(disposal));
    await Future<void>.delayed(Duration.zero);
    expect(peer.closed, isFalse);
    peer.remoteGate!.complete();
    await disposal.timeout(const Duration(seconds: 5));
    expect(peer.closed, isTrue);
    expect(peer.answerCount, 0);
    await serverSocket?.close();
    await server.close(force: true);
  });

  test('dispose waits for a peer being created and closes it once', () async {
    final peer = _FakePeer();
    final peerGate = Completer<RTCPeerConnection>();
    final session = VodWebRtcSession(
      VodWebRtcSource(
        signalingUri: Uri.parse('ws://127.0.0.1:1/signal'),
        deviceId: 'device',
        accountToken: 'test',
        stunServer: '',
        useWebVpn: false,
      ),
      renderer: _FakeRenderer(),
      peerFactory: (_) => peerGate.future,
    );
    final starting = session.start();
    await Future<void>.delayed(Duration.zero);
    final disposal = session.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(peer.closed, isFalse);
    peerGate.complete(peer);
    await starting;
    await disposal;
    expect(peer.closed, isTrue);
    expect(peer.closeCount, 1);
    expect(peer.answerCount, 0);
  });

  test('dispose waits for an in-flight renderer volume update', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
    });
    final renderer = _FakeRenderer()..volumeGate = Completer<void>();
    final peer = _FakePeer();
    final session = VodWebRtcSession(
      VodWebRtcSource(
        signalingUri: Uri.parse('ws://127.0.0.1:${server.port}/signal'),
        deviceId: 'device',
        accountToken: 'test',
        stunServer: '',
        useWebVpn: false,
      ),
      renderer: renderer,
      peerFactory: (_) async => peer,
    );
    await session.start();
    peer.onTrack!(RTCTrackEvent(streams: [_FakeStream()], track: _FakeTrack()));
    await renderer.volumeStarted.future.timeout(const Duration(seconds: 5));
    final disposal = session.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(peer.closed, isFalse);
    expect(renderer.disposed, isFalse);
    renderer.volumeGate!.complete();
    await disposal.timeout(const Duration(seconds: 5));
    expect(peer.closed, isTrue);
    expect(renderer.disposed, isTrue);
    await server.close(force: true);
  });

  test('volume failure is handled and cleanup attempts all resources',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
    });
    final renderer = _FakeRenderer()..volumeError = StateError('volume');
    final peer = _FakePeer()..closeError = StateError('peer close');
    final session = VodWebRtcSession(
      VodWebRtcSource(
        signalingUri: Uri.parse('ws://127.0.0.1:${server.port}/signal'),
        deviceId: 'device',
        accountToken: 'test',
        stunServer: '',
        useWebVpn: false,
      ),
      renderer: renderer,
      peerFactory: (_) async => peer,
    );
    await session.start();
    peer.onTrack!(RTCTrackEvent(streams: [_FakeStream()], track: _FakeTrack()));
    await renderer.volumeStarted.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(session.state.value, VodWebRtcState.failed);
    await expectLater(session.dispose(), throwsStateError);
    expect(peer.disposeCount, 1);
    expect(renderer.disposed, isTrue);
    await server.close(force: true);
  });

  test('audio configuration completes before renderer and peer initialization',
      () async {
    final server = await _signalingServer();
    final configured = Completer<void>();
    final renderer = _FakeRenderer();
    var createdPeer = false;
    final session = VodWebRtcSession(
      _sourceFor(server),
      renderer: renderer,
      prepareAudio: () => configured.future,
      peerFactory: (_) async {
        createdPeer = true;
        return _FakePeer();
      },
    );
    addTearDown(() async {
      await session.dispose();
      await server.close(force: true);
    });

    final start = session.start();
    await Future<void>.delayed(Duration.zero);
    expect(renderer.initialized, isFalse);
    expect(createdPeer, isFalse);
    configured.complete();
    await start;
    expect(renderer.initialized, isTrue);
    expect(createdPeer, isTrue);
  });

  test('stats remain a native teardown barrier after the UI timeout', () async {
    final server = await _signalingServer();
    final peer = _FakePeer()..statsGate = Completer<List<StatsReport>>();
    final session = VodWebRtcSession(
      _sourceFor(server),
      renderer: _FakeRenderer(),
      peerFactory: (_) async => peer,
    );
    addTearDown(() async {
      await session.dispose();
      await server.close(force: true);
    });
    await session.start();

    final information = session.playbackInformation();
    await peer.statsStarted.future.timeout(const Duration(seconds: 5));
    expect(await information, isEmpty);
    final disposing = session.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(peer.closed, isFalse);

    peer.statsGate!.complete([]);
    await disposing.timeout(const Duration(seconds: 5));
    expect(peer.closed, isTrue);
    expect(peer.disposeCount, 1);
  });

  test('reset detaches the old renderer and forgets its audio before release',
      () async {
    final socket = Completer<WebSocket>();
    final server = await _signalingServer(onConnection: socket.complete);
    final renderer = _FakeRenderer();
    final previous = _FakePeer()..statsGate = Completer<List<StatsReport>>();
    final replacement = _FakePeer();
    final volumeUpdates = <double>[];
    var updatesAtClose = 0;
    previous.onClose = () async {
      expect(renderer.srcObject, isNull);
      updatesAtClose = volumeUpdates.length;
    };
    var created = 0;
    final session = VodWebRtcSession(
      _sourceFor(server),
      renderer: renderer,
      peerFactory: (_) async => created++ == 0 ? previous : replacement,
      setTrackVolume: (volume, _) async => volumeUpdates.add(volume),
    );
    addTearDown(() async {
      await session.dispose();
      await server.close(force: true);
    });
    await session.start();
    final audio = _FakeTrack(id: 'old-audio', kind: 'audio');
    final video = _FakeTrack(id: 'old-video');
    previous.onTrack!(RTCTrackEvent(streams: [
      _FakeStream(audio: [audio], video: [video])
    ], track: video));
    await session.setVolume(70);
    expect(renderer.srcObject, isNotNull);
    expect(volumeUpdates, isNotEmpty);
    final information = session.playbackInformation();
    await previous.statsStarted.future.timeout(const Duration(seconds: 5));

    (await socket.future).add(jsonEncode({
      'cmd_type': 'reset',
      'request_type': 'offer',
      'sdp': 'replacement-offer',
    }));
    await Future<void>.delayed(Duration.zero);
    expect(previous.closeCount, 0);
    previous.statsGate!.complete([]);
    expect(await information, isEmpty);
    await replacement.remoteStarted.future.timeout(const Duration(seconds: 5));
    expect(previous.closeCount, 1);
    expect(previous.disposeCount, 1);
    await session.setVolume(55);
    expect(volumeUpdates, hasLength(updatesAtClose));
    expect(renderer.srcObject, isNull);
  });

  test(
      'first streamless audio survives video snapshots and mutes the other view',
      () async {
    final server = await _signalingServer();
    final mainPeer = _FakePeer();
    final otherPeer = _FakePeer();
    final mainVolumes = <double>[];
    final otherVolumes = <double>[];
    final main = VodWebRtcSession(
      _sourceFor(server),
      renderer: _FakeRenderer(),
      peerFactory: (_) async => mainPeer,
      setTrackVolume: (volume, _) async => mainVolumes.add(volume),
    );
    final other = VodWebRtcSession(
      _sourceFor(server),
      renderer: _FakeRenderer(),
      peerFactory: (_) async => otherPeer,
      setTrackVolume: (volume, _) async => otherVolumes.add(volume),
    );
    addTearDown(() async {
      await main.dispose();
      await other.dispose();
      await server.close(force: true);
    });
    await other.setAudioEnabled(false);
    await main.start();
    await other.start();
    final mainAudio = _FakeTrack(id: 'audio', kind: 'audio');
    final otherAudio = _FakeTrack(id: 'audio', kind: 'audio');
    mainPeer.onTrack!(RTCTrackEvent(streams: [], track: mainAudio));
    otherPeer.onTrack!(RTCTrackEvent(streams: [], track: otherAudio));
    await main.setAudioEnabled(true);
    await other.setAudioEnabled(false);
    expect(mainVolumes.first, 1);
    await main.setVolume(65);
    await other.setVolume(65);
    expect(otherVolumes, everyElement(0));
    expect(mainAudio.enabled, isTrue);
    expect(otherAudio.enabled, isFalse);

    final video = _FakeTrack();
    mainPeer.onTrack!(RTCTrackEvent(streams: [
      _FakeStream(video: [video])
    ], track: video));
    await main.setAudioEnabled(true);
    expect(mainVolumes.last, .65);
    expect(main.renderer.srcObject?.getVideoTracks(), [video]);
    await main.pause();
    expect(mainVolumes.last, 0);
    expect(mainAudio.enabled, isFalse);
    await main.play();
    expect(mainVolumes.last, .65);
    expect(mainAudio.enabled, isTrue);
  });
}

VodWebRtcSource _sourceFor(HttpServer server) => VodWebRtcSource(
      signalingUri: Uri.parse('ws://127.0.0.1:${server.port}/signal'),
      deviceId: 'device',
      accountToken: 'test',
      stunServer: '',
      useWebVpn: false,
    );

Future<HttpServer> _signalingServer(
    {void Function(WebSocket)? onConnection}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    onConnection?.call(socket);
    socket.listen((_) {});
  });
  return server;
}

class _FakeRenderer extends RTCVideoRenderer {
  MediaStream? _stream;
  Completer<void>? volumeGate;
  final volumeStarted = Completer<void>();
  Object? volumeError;
  bool disposed = false;
  bool initialized = false;

  @override
  MediaStream? get srcObject => _stream;

  @override
  set srcObject(MediaStream? stream) => _stream = stream;

  @override
  Future<void> setSrcObject({MediaStream? stream, String? trackId}) async {
    _stream = stream;
  }

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<void> setVolume(double volume) async {
    if (!volumeStarted.isCompleted) volumeStarted.complete();
    await volumeGate?.future;
    if (volumeError != null) throw volumeError!;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _FakePeer extends RTCPeerConnection {
  RTCSessionDescription? remoteDescription;
  RTCSessionDescription? localDescription;
  final remoteStarted = Completer<void>();
  Completer<void>? remoteGate;
  int answerCount = 0;
  bool closed = false;
  int closeCount = 0;
  int disposeCount = 0;
  Object? closeError;
  Future<void> Function()? onClose;
  Completer<List<StatsReport>>? statsGate;
  final statsStarted = Completer<void>();

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    if (!statsStarted.isCompleted) statsStarted.complete();
    return statsGate == null ? [] : await statsGate!.future;
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remoteDescription = description;
    if (!remoteStarted.isCompleted) remoteStarted.complete();
    await remoteGate?.future;
  }

  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic> constraints = const {}]) async {
    answerCount++;
    return RTCSessionDescription('synthetic-answer', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    localDescription = description;
  }

  @override
  Future<void> close() async {
    await onClose?.call();
    closed = true;
    closeCount++;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<void> dispose() async => disposeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStream extends MediaStream {
  _FakeStream({this.audio = const [], this.video = const []})
      : super('stream', 'owner');

  final List<MediaStreamTrack> audio;
  final List<MediaStreamTrack> video;

  @override
  List<MediaStreamTrack> getAudioTracks() => audio;

  @override
  List<MediaStreamTrack> getVideoTracks() => video;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack implements MediaStreamTrack {
  _FakeTrack({this.id = 'track', this.kind = 'video'});

  @override
  final String id;
  @override
  final String kind;
  @override
  bool enabled = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
