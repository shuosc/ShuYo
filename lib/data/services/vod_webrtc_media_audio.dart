import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Configures receive-only live streams as media before the plugin creates its
/// process-wide audio device module. Both camera sessions share this barrier.
class VodWebRtcMediaAudio {
  VodWebRtcMediaAudio({
    Future<void> Function(Map<String, dynamic>)? initialize,
    Future<void> Function(AndroidAudioConfiguration)? configure,
    bool Function()? isAndroid,
  })  : _initialize =
            initialize ?? ((options) => WebRTC.initialize(options: options)),
        _configure = configure ?? Helper.setAndroidAudioConfiguration,
        _isAndroid = isAndroid ?? (() => WebRTC.platformIsAndroid);

  static final shared = VodWebRtcMediaAudio();

  final Future<void> Function(Map<String, dynamic>) _initialize;
  final Future<void> Function(AndroidAudioConfiguration) _configure;
  final bool Function() _isAndroid;
  Future<void>? _preparation;

  Future<void> prepare() {
    if (!_isAndroid()) return Future<void>.value();
    final pending = _preparation;
    if (pending != null) return pending;
    final work = _prepare();
    _preparation = work;
    work.then<void>((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_preparation, work)) _preparation = null;
    });
    return work;
  }

  Future<void> _prepare() async {
    final media = AndroidAudioConfiguration.media;
    // AudioTrack attributes are fixed when the native module is initialized;
    // configuring the routing manager afterwards alone leaves call audio.
    await _initialize({'androidAudioConfiguration': media.toMap()});
    await _configure(media);
  }
}
