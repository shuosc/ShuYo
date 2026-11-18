import 'package:shared_preferences/shared_preferences.dart';

class AcademicProgressDisplaySettingsService {
  AcademicProgressDisplaySettingsService({
    Future<SharedPreferences> Function()? preferencesLoader,
    this.isDemo = false,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const showGpaKey = 'academic.progress.display.showGpa';
  static const showRankingKey = 'academic.progress.display.showRanking';

  final Future<SharedPreferences> Function() _preferencesLoader;
  final bool isDemo;

  String _key(String key) => isDemo ? 'demo.$key' : key;

  Future<bool> loadShowGpa() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(_key(showGpaKey)) ?? isDemo;
  }

  Future<void> saveShowGpa(bool showGpa) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(_key(showGpaKey), showGpa);
  }

  Future<bool> loadShowRanking() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(_key(showRankingKey)) ?? isDemo;
  }

  Future<void> saveShowRanking(bool showRanking) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(_key(showRankingKey), showRanking);
  }
}
