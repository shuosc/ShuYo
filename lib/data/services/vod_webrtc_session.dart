import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/course_recording.dart';
import 'vod_webrtc_media_audio.dart';
import 'vod_webrtc_signaling.dart';

enum VodWebRtcState { idle, connecting, playing, paused, failed, disposed }

@visibleForTesting
Map<String, dynamic> buildVodWebRtcSignalingMessage({
  required String command,
  required String request,
  required String accountToken,
  required String sessionId,
  required String requestId,
  Map<String, dynamic>? fields,
}) =>
    {
      'cmd_type': command,
      'request_type': request,
      'account_token': accountToken,
      if (sessionId.isNotEmpty) 'session_id': sessionId,
      'request_id': requestId,
      ...?fields,
    };

class VodWebRtcSession {
  VodWebRtcSession(
    this.source, {
    RTCVideoRenderer? renderer,
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory,
    Future<void> Function()? prepareAudio,
    Future<void> Function(double, MediaStreamTrack)? setTrackVolume,
  })  : renderer = renderer ?? RTCVideoRenderer(),
        _peerFactory = peerFactory ?? createPeerConnection,
        _prepareAudio = prepareAudio ?? VodWebRtcMediaAudio.shared.prepare,
        _setTrackVolume = setTrackVolume ?? Helper.setVolume;

  final VodWebRtcSource source;
  final RTCVideoRenderer renderer;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _peerFactory;
  final Future<void> Function() _prepareAudio;
  final Future<void> Function(double, MediaStreamTrack) _setTrackVolume;
  final ValueNotifier<VodWebRtcState> state =
      ValueNotifier(VodWebRtcState.idle);

  String? error;
  WebSocket? _socket;
  RTCPeerConnection? _peer;
  MediaStream? _stream;
  final _audioTracks = <String, MediaStreamTrack>{};
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
  bool _hasFirstFrame = false;
  int _generation = 0;
  Future<void>? _rendererInitialization;
  Future<void> _peerQueue = Future.value();
  Future<void> _playbackQueue = Future.value();
  Future<void>? _startWork;
  Future<void>? _closeWork;
  Future<void>? _disposeWork;
  Object? _cleanupError;
  StackTrace? _cleanupStack;

  Future<void> _cleanup(FutureOr<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stack) {
      _cleanupError ??= error;
      _cleanupStack ??= stack;
    }
  }

  void _throwCleanupError() {
    final error = _cleanupError;
    if (error != null) Error.throwWithStackTrace(error, _cleanupStack!);
  }

  Future<void> _releasePeer(RTCPeerConnection? peer) async {
    if (peer == null) return;
    await _cleanup(peer.close);
    await _cleanup(peer.dispose);
    _throwCleanupError();
  }

  Future<void> start() {
    if (_disposed) return Future.error(StateError('直播连接已关闭'));
    final pending = _startWork;
    if (pending != null) return pending;
    final work = _start();
    _startWork = work;
    work.then<void>((_) {
      if (identical(_startWork, work)) _startWork = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_startWork, work)) _startWork = null;
    });
    return work;
  }

  Future<void> _start() async {
    if (_disposed) throw StateError('直播连接已关闭');
    if (state.value == VodWebRtcState.connecting ||
        state.value == VodWebRtcState.playing ||
        state.value == VodWebRtcState.paused) {
      return;
    }
    error = null;
    final generation = ++_generation;
    state.value = VodWebRtcState.connecting;
    var stage = 'audio configuration';
    try {
      await _prepareAudio();
      if (_disposed || generation != _generation) return;
      stage = 'renderer';
      if (!_initialized) {
        _rendererInitialization ??= renderer.initialize();
        await _rendererInitialization;
        _initialized = true;
      }
      if (_disposed || generation != _generation) return;
      await _peerQueue;
      if (_disposed || generation != _generation) return;
      await _closeConnection();
      if (_disposed || generation != _generation) return;
      stage = 'peer';
      await _createPeer(generation);
      if (_disposed || generation != _generation) return;
      stage = 'signaling';
      final socket = await connectVodWebRtcSignaling(source.signalingUri,
          headers: source.headers);
      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      debugPrint('ShuYoVOD WebRTC signaling connected');
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
      _waitForFirstFrame(generation);
    } catch (cause) {
      _logFailure(stage, cause);
      if (!_disposed && generation == _generation) {
        error = source.useWebVpn
            ? 'WebVPN 下的 WebRTC 连接失败，请重试或切换线路'
            : 'WebRTC 连接失败，请重试或切换线路';
        state.value = VodWebRtcState.failed;
        await _closeConnection();
      }
      throw StateError(error ?? 'WebRTC 连接已关闭');
    }
  }

  void _waitForFirstFrame(int generation) {
    _connectionTimeout?.cancel();
    _connectionTimeout = Timer(const Duration(seconds: 30), () {
      if (!_disposed && generation == _generation && !_hasFirstFrame) {
        _fail(source.useWebVpn
            ? 'WebVPN 下的 WebRTC 未收到画面，请重试或切换 HLS / FLV'
            : 'WebRTC 连接超时，请重试或切换线路');
      }
    });
  }

  void _logFailure(String stage, Object cause) {
    var detail = '';
    if (cause is WebSocketException) {
      detail = cause.message
          .replaceAll(RegExp(r'(?:wss?|https?)://[^\s]+'), '<signaling>');
    } else if (cause is HandshakeException) {
      detail = cause.message
          .replaceAll(RegExp(r'(?:wss?|https?)://[^\s]+'), '<signaling>');
    } else if (cause is SocketException) {
      detail = 'osError=${cause.osError?.errorCode}';
    }
    debugPrint(
        'ShuYoVOD WebRTC failure: stage=$stage, type=${cause.runtimeType}, $detail');
  }

  Future<void> _createPeer(int generation) async {
    final stun = source.stunServer.trim();
    final peer = await _peerFactory({
      'iceServers': stun.isEmpty
          ? <Map<String, String>>[]
          : [
              {'urls': stun.startsWith('stun:') ? stun : 'stun:$stun'},
            ],
      'sdpSemantics': 'unified-plan',
    });
    if (_disposed || generation != _generation) {
      await _releasePeer(peer);
      return;
    }
    _peer = peer;
    _hasFirstFrame = false;
    renderer.onFirstFrameRendered = () {
      if (_disposed || generation != _generation || _peer != peer) return;
      _hasFirstFrame = true;
      _connectionTimeout?.cancel();
      debugPrint('ShuYoVOD WebRTC first frame rendered');
      state.value = _playing ? VodWebRtcState.playing : VodWebRtcState.paused;
    };
    peer.onIceCandidate = (candidate) {
      if (_disposed || generation != _generation || _peer != peer) return;
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        _send(_resetting ? 'reset' : 'ice', 'candidate', {
          'candidate': candidate.candidate,
        });
      }
    };
    peer.onTrack = (event) {
      if (_disposed || generation != _generation || _peer != peer) {
        return;
      }
      unawaited(_enqueuePlayback(() async {
        if (_disposed || generation != _generation || _peer != peer) return;
        // onTrack streams are snapshots and audio may use a separate stream,
        // or no stream at all. Keep those tracks even when a later video
        // snapshot omits them, and never replace visible video with audio-only.
        if (event.track.kind == 'audio') {
          _rememberAudioTrack(event.track);
        }
        for (final stream in event.streams) {
          for (final track in stream.getAudioTracks()) {
            _rememberAudioTrack(track);
          }
        }
        final videoStream = event.streams
            .where((stream) => stream.getVideoTracks().isNotEmpty)
            .firstOrNull;
        final stream = videoStream ??
            (event.track.kind == 'video' || _stream == null
                ? event.streams.firstOrNull
                : null);
        if (stream != null) {
          _stream = stream;
          await renderer.setSrcObject(stream: stream);
        }
        if (!_disposed && generation == _generation && _peer == peer) {
          await _updatePlaybackState();
        }
      }).catchError((Object cause) {
        _logFailure('playback state', cause);
        _fail('WebRTC 播放状态更新失败，请重试或切换线路');
      }));
    };
    peer.onConnectionState = (connectionState) {
      if (_disposed || generation != _generation || _peer != peer) return;
      debugPrint('ShuYoVOD WebRTC media state: ${connectionState.name}');
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
    socket.add(jsonEncode(buildVodWebRtcSignalingMessage(
      command: command,
      request: request,
      accountToken: source.accountToken,
      sessionId: _sessionId,
      requestId: '${DateTime.now().microsecondsSinceEpoch}-${_requestNumber++}',
      fields: fields,
    )));
  }

  void _sendStop() {
    try {
      _send('live', 'stop');
    } on Object catch (cause) {
      // A failed advisory message must not prevent local native teardown.
      _logFailure('stop signaling', cause);
    }
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
        debugPrint(
            'ShuYoVOD WebRTC server error: code=${int.tryParse(serverError.toString())}');
        _fail('WebRTC 服务器拒绝连接，请重试或切换线路');
        return;
      }
      final command = decoded['cmd_type'];
      if (decoded['request_type'] == 'notify' && command == 'reset') {
        _send('reset', 'ack', {'stun_server': source.stunServer});
      } else if ((command == 'ice' || command == 'reset') &&
          decoded['request_type'] == 'offer' &&
          decoded['sdp'] is String) {
        debugPrint('ShuYoVOD WebRTC offer received');
        final offer = decoded['sdp'] as String;
        final generation = _generation;
        unawaited(_enqueuePeer(() async {
          if (!_disposed && generation == _generation) {
            await _answerOffer(offer, reset: command == 'reset');
          }
        }));
      }
    } catch (cause) {
      _logFailure('message', cause);
      _fail('WebRTC 信令数据无效');
    }
  }

  Future<void> _answerOffer(String offer, {required bool reset}) async {
    final generation = _generation;
    try {
      if (reset) {
        final previousPeer = _peer;
        _peer = null;
        await _cleanup(_detachMedia);
        await _releasePeer(previousPeer);
        if (_disposed || generation != _generation) return;
        await _createPeer(generation);
        if (!_disposed && generation == _generation) {
          state.value = VodWebRtcState.connecting;
          _waitForFirstFrame(generation);
        }
      }
      final peer = _peer;
      if (peer == null || _disposed || generation != _generation) return;
      _resetting = reset;
      await peer.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      if (_disposed || generation != _generation || _peer != peer) return;
      final answer = await peer.createAnswer();
      if (_disposed || generation != _generation || _peer != peer) return;
      await peer.setLocalDescription(answer);
      if (_disposed || generation != _generation || _peer != peer) return;
      if (answer.sdp != null) {
        _send(reset ? 'reset' : 'ice', 'answer', {'sdp': answer.sdp});
      }
    } catch (cause) {
      _logFailure('negotiation', cause);
      if (generation == _generation) {
        _fail('WebRTC 媒体协商失败，请重试或切换线路');
      }
    }
  }

  Future<void> play() async {
    _playing = true;
    await _applyPlaybackState();
    if (!_disposed && _hasFirstFrame && state.value != VodWebRtcState.failed) {
      state.value = VodWebRtcState.playing;
    }
  }

  Future<void> pause() async {
    _playing = false;
    await _applyPlaybackState();
    if (!_disposed && _hasFirstFrame && state.value != VodWebRtcState.failed) {
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

  Future<Map<String, String>> playbackInformation() {
    final peer = _peer;
    if (_disposed || peer == null) return Future.value(const {});
    final generation = _generation;
    // The UI timeout must not remove the underlying native stats work from
    // the queue observed by reset/dispose.
    return _enqueuePeer(() => _readPlaybackInformation(peer, generation))
        .timeout(const Duration(seconds: 2), onTimeout: () => const {});
  }

  Future<Map<String, String>> _readPlaybackInformation(
      RTCPeerConnection peer, int generation) async {
    if (_disposed || peer != _peer || generation != _generation) {
      return const {};
    }
    try {
      final reports = await peer.getStats();
      if (_disposed || _peer != peer || generation != _generation) {
        return const {};
      }
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

  Future<void> _applyPlaybackState() {
    return _enqueuePlayback(_updatePlaybackState);
  }

  void _rememberAudioTrack(MediaStreamTrack track) {
    final id = track.id;
    if (id != null && id.isNotEmpty) _audioTracks[id] = track;
  }

  Future<T> _enqueuePeer<T>(Future<T> Function() operation) {
    final work = _peerQueue.then((_) => operation());
    _peerQueue = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<void> _enqueuePlayback(Future<void> Function() update) {
    final work = _playbackQueue.then((_) => update());
    // Later updates and teardown must still run after a failed update.
    _playbackQueue =
        work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  Future<void> _updatePlaybackState() async {
    final stream = _stream;
    if (_disposed) return;
    for (final track in stream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _playing;
    }
    final audio = _audioTracks.values.toList(growable: false);
    for (final track in audio) {
      track.enabled = _playing && _audioEnabled;
    }
    final volume = _playing && _audioEnabled ? _volume / 100 : 0.0;
    if (audio.isEmpty) {
      if (stream != null) await renderer.setVolume(volume);
    } else {
      for (final track in audio) {
        await _setTrackVolume(volume, track);
      }
    }
  }

  Future<void> _detachMedia() async {
    _stream = null;
    _audioTracks.clear();
    renderer.onFirstFrameRendered = null;
    _hasFirstFrame = false;
    await _playbackQueue;
    if (_initialized) await renderer.setSrcObject();
  }

  void _fail(String message) {
    if (_disposed || state.value == VodWebRtcState.failed) return;
    _generation++;
    error = message;
    state.value = VodWebRtcState.failed;
    unawaited(_closeAfterPendingWork(_generation).catchError((Object cause) {
      _logFailure('close', cause);
    }));
  }

  Future<void> _closeAfterPendingWork(int generation) async {
    try {
      await _startWork;
    } catch (_) {}
    try {
      await _peerQueue;
    } catch (_) {}
    if (!_disposed && generation == _generation) await _closeConnection();
  }

  Future<void> _closeConnection() {
    final pending = _closeWork;
    if (pending != null) return pending;
    final work = _performClose();
    _closeWork = work;
    work.then<void>((_) {
      if (identical(_closeWork, work)) _closeWork = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_closeWork, work)) _closeWork = null;
    });
    return work;
  }

  Future<void> _performClose() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    _sendStop();
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    final peer = _peer;
    _peer = null;
    await _cleanup(_detachMedia);
    _sessionId = '';
    await _cleanup(() async => subscription?.cancel());
    await _cleanup(() async => socket?.close());
    await _cleanup(() => _releasePeer(peer));
    _throwCleanupError();
  }

  Future<void> dispose() {
    final pending = _disposeWork;
    if (pending != null) return pending;
    _generation++;
    _sendStop();
    _disposed = true;
    return _disposeWork = _performDispose();
  }

  Future<void> _performDispose() async {
    try {
      await _startWork;
    } catch (_) {}
    try {
      await _peerQueue;
    } catch (_) {}
    await _cleanup(_closeConnection);
    try {
      await _rendererInitialization;
      if (_rendererInitialization != null) _initialized = true;
    } catch (_) {}
    if (_initialized) await _cleanup(renderer.dispose);
    state.value = VodWebRtcState.disposed;
    state.dispose();
    _throwCleanupError();
  }
}
