import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/vod_webrtc_media_audio.dart';

void main() {
  test('both views initialize media audio once before routing is configured',
      () async {
    final initialized = Completer<void>();
    final events = <String>[];
    final audio = VodWebRtcMediaAudio(
      isAndroid: () => true,
      initialize: (options) async {
        events.add('initialize');
        final config = options['androidAudioConfiguration'] as Map;
        expect(config['androidAudioMode'], 'normal');
        expect(config['androidAudioStreamType'], 'music');
        expect(config['androidAudioAttributesUsageType'], 'media');
        expect(config['forceHandleAudioRouting'], isNot(true));
        await initialized.future;
      },
      configure: (config) async {
        events.add('configure');
        expect(config.toMap()['androidAudioMode'], 'normal');
      },
    );

    final first = audio.prepare();
    final second = audio.prepare();
    expect(second, same(first));
    expect(events, ['initialize']);
    initialized.complete();
    await Future.wait([first, second]);
    await audio.prepare();
    expect(events, ['initialize', 'configure']);
  });

  test('failed audio preparation can retry and other platforms do no work',
      () async {
    var attempts = 0;
    var configurations = 0;
    final audio = VodWebRtcMediaAudio(
      isAndroid: () => true,
      initialize: (_) async {
        if (attempts++ == 0) throw StateError('initialization');
      },
      configure: (_) async => configurations++,
    );
    await expectLater(audio.prepare(), throwsStateError);
    await audio.prepare();
    expect(attempts, 2);
    expect(configurations, 1);

    final desktop = VodWebRtcMediaAudio(
      isAndroid: () => false,
      initialize: (_) async => fail('must not initialize Android audio'),
      configure: (_) async => fail('must not configure Android audio'),
    );
    await desktop.prepare();
  });
}
