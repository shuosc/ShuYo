import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/services/vod_webrtc_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WebVPN refuses WebRTC before opening an unverified media route',
      () async {
    final session = VodWebRtcSession(
      VodWebRtcSource(
        signalingUri: Uri.parse('wss://example.invalid/signal'),
        deviceId: 'device',
        accountToken: 'synthetic-token',
        stunServer: 'example.invalid:3478',
        useWebVpn: true,
      ),
    );

    await expectLater(session.start(), throwsStateError);
    expect(session.state.value, VodWebRtcState.failed);
    expect(session.error, contains('WebVPN'));
    expect(session.renderer.srcObject, isNull);
    await session.dispose();
  });
}
