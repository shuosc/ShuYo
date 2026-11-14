import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/course_recording.dart';

class RecordingPlayerPreferences {
  const RecordingPlayerPreferences({
    this.showClock = true,
    this.keepScreenOn = true,
    this.secondaryView = false,
    this.defaultLiveProtocol = VodLiveProtocol.hls,
  });

  final bool showClock;
  final bool keepScreenOn;
  final bool secondaryView;
  final VodLiveProtocol defaultLiveProtocol;

  RecordingPlayerPreferences copyWith({
    bool? showClock,
    bool? keepScreenOn,
    bool? secondaryView,
    VodLiveProtocol? defaultLiveProtocol,
  }) =>
      RecordingPlayerPreferences(
        showClock: showClock ?? this.showClock,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        secondaryView: secondaryView ?? this.secondaryView,
        defaultLiveProtocol: defaultLiveProtocol ?? this.defaultLiveProtocol,
      );

  static Future<RecordingPlayerPreferences> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final protocolName =
          preferences.getString('vod.player.defaultLiveProtocol');
      return RecordingPlayerPreferences(
        showClock: preferences.getBool('vod.player.showClock') ?? true,
        keepScreenOn: preferences.getBool('vod.player.keepScreenOn') ?? true,
        secondaryView: preferences.getBool('vod.player.secondaryView') ?? false,
        defaultLiveProtocol: VodLiveProtocol.values.firstWhere(
          (protocol) => protocol.name == protocolName,
          orElse: () => VodLiveProtocol.hls,
        ),
      );
    } on Object {
      return const RecordingPlayerPreferences();
    }
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('vod.player.showClock', showClock);
    await preferences.setBool('vod.player.keepScreenOn', keepScreenOn);
    await preferences.setBool('vod.player.secondaryView', secondaryView);
    await preferences.setString(
        'vod.player.defaultLiveProtocol', defaultLiveProtocol.name);
  }
}
