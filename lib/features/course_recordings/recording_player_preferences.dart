import 'package:shared_preferences/shared_preferences.dart';

class RecordingPlayerPreferences {
  const RecordingPlayerPreferences({
    this.showClock = true,
    this.secondaryView = false,
  });

  final bool showClock;
  final bool secondaryView;

  RecordingPlayerPreferences copyWith({
    bool? showClock,
    bool? secondaryView,
  }) =>
      RecordingPlayerPreferences(
        showClock: showClock ?? this.showClock,
        secondaryView: secondaryView ?? this.secondaryView,
      );

  static Future<RecordingPlayerPreferences> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return RecordingPlayerPreferences(
        showClock: preferences.getBool('vod.player.showClock') ?? true,
        secondaryView: preferences.getBool('vod.player.secondaryView') ?? false,
      );
    } on Object {
      return const RecordingPlayerPreferences();
    }
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('vod.player.showClock', showClock);
    await preferences.setBool('vod.player.secondaryView', secondaryView);
  }
}
