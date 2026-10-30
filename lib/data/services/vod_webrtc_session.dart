import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/course_recording.dart';

enum VodWebRtcState { idle, connecting, playing, paused, failed, disposed }

class VodWebRtcSession {
  VodWebRtcSession(this.source);

  final VodWebRtcSource source;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  final ValueNotifier<VodWebRtcState> state =
      ValueNotifier(VodWebRtcState.idle);

  String? error;
  WebSocket? _socket;
  RTCPeerConnection? _peer;
  MediaStream? _stream;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _connectionTimeout;
  String _sessionId = '';
  int _requestNumber = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _playing = true;
  bool _audioEnabled = true;
  double _volume = 100;
  bool _resetting = false;
  int _generation = 0;
  Future<void>? _rendererInitialization;
  Future<void> _offerQueue = Future.value();

  Future<void> start() async {
    if (_disposed) throw StateError('直播连接已关闭');
    if (state.value == VodWebRtcState.connecting ||
        state.value == VodWebRtcState.playing ||
        state.value == VodWebRtcState.paused) {
      return;
    }
    error = null;
    final generation = ++_generation;
    state.value = VodWebRtcState.connecting;
    try {
      if (source.useWebVpn) {
        throw StateError('WebVPN 尚未提供可验证的 WebRTC 媒体中继，请使用 HLS 或 FLV');
      }
      if (!_initialized) {
        _rendererInitialization ??= renderer.initialize();
        await _rendererInitialization;
        _initialized = true;
      }
      if (_disposed || generation != _generation) return;
      await _closeConnection();
      if (_disposed || generation != _generation) return;
      await _createPeer(generation);
      if (_disposed || generation != _generation) return;
      final socket = await WebSocket.connect(
        source.signalingUri.toString(),
        headers: source.headers,
      ).timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.listen(
        _onMessage,
        onError: (Object _) => _fail('WebRTC 信令连接失败'),
        onDone: () => _fail('WebRTC 信令连接已断开'),
      );
      _send('live', 'start', {
        'device_id': source.deviceId,
        'nmedia_id': 0,
        'protocol': 'webrtc',
        'stun_server': source.stunServer,
        'preferred_path': '',
        'video_codec': 'H264',
        'play_prev_second': 0,
      });
      _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        _send('detect', 'heartbeat', {'request_id': 'heartbeat'});
      });
      _connectionTimeout = Timer(const Duration(seconds: 30), () {
        if (state.value == VodWebRtcState.connecting) {
          _fail('WebRTC 连接超时，请重试或切换线路');
        }
      });
    } catch (_) {
      if (!_disposed && generation == _generation) {
        error = source.useWebVpn
            ? 'WebVPN 尚未提供可验证的 WebRTC 媒体中继，请使用 HLS 或 FLV'
            : 'WebRTC 连接失败，请重试或切换线路';
        state.value = VodWebRtcState.failed;
        await _closeConnection();
      }
      throw StateError(error ?? 'WebRTC 连接已关闭');
    }
  }

  Future<void> _createPeer(int generation) async {
    final stun = source.stunServer.trim();
    final peer = await createPeerConnection({
      'iceServers': stun.isEmpty
          ? <Map<String, String>>[]
          : [
              {'urls': stun.startsWith('stun:') ? stun : 'stun:$stun'},
            ],
      'sdpSemantics': 'unified-plan',
    });
    if (_disposed || generation != _generation) {
      await peer.close();
      await peer.dispose();
      return;
    }
    _peer = peer;
    peer.onIceCandidate = (candidate) {
      if (_disposed || generation != _generation || _peer != peer) return;
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        _send(_resetting ? 'reset' : 'ice', 'candidate', {
          'candidate': candidate.candidate,
        });
      }
    };
    peer.onTrack = (event) {
      if (_disposed || generation != _generation || event.streams.isEmpty) {
        return;
      }
      _stream = event.streams.first;
      renderer.srcObject = _stream;
      unawaited(_applyPlaybackState());
      _connectionTimeout?.cancel();
      state.value = _playing ? VodWebRtcState.playing : VodWebRtcState.paused;
    };
    peer.onConnectionState = (connectionState) {
      if (_disposed || generation != _generation || _peer != peer) return;
      if (connectionState ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail('WebRTC 媒体连接失败，请重试或切换线路');
      }
    };
  }

  void _send(String command, String request, [Map<String, dynamic>? fields]) {
    final socket = _socket;
    if (_disposed || socket == null || socket.readyState != WebSocket.open) {
      return;
    }
    socket.add(jsonEncode({
      'cmd_type': command,
      'request_type': request,
      'account_token': source.accountToken,
      'session_id': _sessionId,
      'request_id':
          '${DateTime.now().microsecondsSinceEpoch}-${_requestNumber++}',
      ...?fields,
    }));
  }

  void _onMessage(dynamic message) {
    if (_disposed || message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      final sessionId = decoded['session_id'];
      if (sessionId != null) _sessionId = sessionId.toString();
      final serverError = decoded['error'];
      if (serverError != null && serverError.toString() != '0') {
        _fail('WebRTC 服务器拒绝连接，请重试或切换线路');
        return;
      }
      final command = decoded['cmd_type'];
      if (decoded['request_type'] == 'notify' && command == 'reset') {
        _send('reset', 'ack', {'stun_server': source.stunServer});
      } else if ((command == 'ice' || command == 'reset') &&
          decoded['request_type'] == 'offer' &&
          decoded['sdp'] is String) {
        final offer = decoded['sdp'] as String;
        final generation = _generation;
        _offerQueue = _offerQueue.then((_) async {
          if (!_disposed && generation == _generation) {
            await _answerOffer(offer, reset: command == 'reset');
          }
        });
      }
    } catch (_) {
      _fail('WebRTC 信令数据无效');
    }
  }

  Future<void> _answerOffer(String offer, {required bool reset}) async {
    final generation = _generation;
    try {
      if (reset) {
        final previousPeer = _peer;
        _peer = null;
        await previousPeer?.close();
        await previousPeer?.dispose();
        if (_disposed || generation != _generation) return;
        await _createPeer(generation);
      }
      final peer = _peer;
      if (peer == null || _disposed || generation != _generation) return;
      _resetting = reset;
      await peer.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      if (answer.sdp != null) {
        _send(reset ? 'reset' : 'ice', 'answer', {'sdp': answer.sdp});
      }
    } catch (_) {
      if (generation == _generation) {
        _fail('WebRTC 媒体协商失败，请重试或切换线路');
      }
    }
  }

  Future<void> play() async {
    _playing = true;
    await _applyPlaybackState();
    if (!_disposed && _stream != null && state.value != VodWebRtcState.failed) {
      state.value = VodWebRtcState.playing;
    }
  }

  Future<void> pause() async {
    _playing = false;
    await _applyPlaybackState();
    if (!_disposed && _stream != null && state.value != VodWebRtcState.failed) {
      state.value = VodWebRtcState.paused;
    }
  }

  Future<void> setAudioEnabled(bool enabled) async {
    _audioEnabled = enabled;
    await _applyPlaybackState();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100).toDouble();
    await _applyPlaybackState();
  }

  Future<Map<String, String>> playbackInformation() async {
    final peer = _peer;
    if (_disposed || peer == null) return const {};
    try {
      final reports = await peer.getStats().timeout(const Duration(seconds: 2));
      if (_disposed || _peer != peer) return const {};
      final codecs = {
        for (final report in reports.where((report) => report.type == 'codec'))
          report.id: report.values
      };
      final result = <String, String>{};
      for (final report in reports) {
        if (report.type != 'inbound-rtp' || report.values['isRemote'] == true) {
          continue;
        }
        final kind = report.values['kind'] ?? report.values['mediaType'];
        final codec = codecs[report.values['codecId']];
        if (codec?['mimeType'] == 'video/rtx') continue;
        if (kind == 'video') {
          result['VideoParams'] = [
            codec?['mimeType'],
            if (report.values['frameWidth'] != null &&
                report.values['frameHeight'] != null)
              '${report.values['frameWidth']}x${report.values['frameHeight']}',
            if (report.values['framesPerSecond'] != null)
              '${report.values['framesPerSecond']} fps',
          ].whereType<String>().join(' · ');
          result['VideoTrack'] =
              (report.values['trackIdentifier'] ?? report.id).toString();
        } else if (kind == 'audio') {
          result['AudioParams'] = [
            codec?['mimeType'],
            if (codec?['clockRate'] != null) '${codec!['clockRate']} Hz',
            if (codec?['channels'] != null) '${codec!['channels']} channels',
          ].whereType<String>().join(' · ');
          result['AudioTrack'] =
              (report.values['trackIdentifier'] ?? report.id).toString();
        }
      }
      return result;
    } on Object {
      return const {};
    }
  }

  Future<void> _applyPlaybackState() async {
    final stream = _stream;
    if (stream == null || _disposed) return;
    for (final track in stream.getVideoTracks()) {
      track.enabled = _playing;
    }
    for (final track in stream.getAudioTracks()) {
      track.enabled = _playing && _audioEnabled;
    }
    await renderer.setVolume(_playing && _audioEnabled ? _volume / 100 : 0);
  }

  void _fail(String message) {
    if (_disposed || state.value == VodWebRtcState.failed) return;
    _generation++;
    error = message;
    state.value = VodWebRtcState.failed;
    unawaited(_closeConnection());
  }

  Future<void> _closeConnection() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    _send('live', 'stop');
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    final peer = _peer;
    _peer = null;
    if (_initialized) renderer.srcObject = null;
    _stream = null;
    _sessionId = '';
    await subscription?.cancel();
    await socket?.close();
    await peer?.close();
    await peer?.dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _generation++;
    _send('live', 'stop');
    _disposed = true;
    await _closeConnection();
    try {
      await _rendererInitialization;
      if (_rendererInitialization != null) _initialized = true;
    } catch (_) {}
    if (_initialized) await renderer.dispose();
    state.value = VodWebRtcState.disposed;
    state.dispose();
  }
}
