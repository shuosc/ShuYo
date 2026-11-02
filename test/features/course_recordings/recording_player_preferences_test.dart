import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/features/course_recordings/recording_player_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('existing installs keep HLS as the default live stream', () async {
    SharedPreferences.setMockInitialValues({
      'vod.player.showClock': false,
      'vod.player.secondaryView': true,
    });

    final preferences = await RecordingPlayerPreferences.load();

    expect(preferences.defaultLiveProtocol, VodLiveProtocol.hls);
    expect(preferences.showClock, isFalse);
    expect(preferences.secondaryView, isTrue);
  });

  for (final protocol in VodLiveProtocol.values) {
    test('${protocol.name} default survives saving and unrelated changes',
        () async {
      final preferences = const RecordingPlayerPreferences()
          .copyWith(defaultLiveProtocol: protocol)
          .copyWith(showClock: false, secondaryView: true);
      await preferences.save();

      final loaded = await RecordingPlayerPreferences.load();
      final stored = await SharedPreferences.getInstance();

      expect(loaded.defaultLiveProtocol, protocol);
      expect(loaded.showClock, isFalse);
      expect(loaded.secondaryView, isTrue);
      expect(stored.getString('vod.player.defaultLiveProtocol'), protocol.name);
    });
  }

  test('unknown saved protocols fall back without resetting display settings',
      () async {
    SharedPreferences.setMockInitialValues({
      'vod.player.defaultLiveProtocol': 'unsupported',
      'vod.player.showClock': false,
      'vod.player.secondaryView': true,
    });

    final preferences = await RecordingPlayerPreferences.load();

    expect(preferences.defaultLiveProtocol, VodLiveProtocol.hls);
    expect(preferences.showClock, isFalse);
    expect(preferences.secondaryView, isTrue);
  });
}
