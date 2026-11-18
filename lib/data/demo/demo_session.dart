import 'package:shared_preferences/shared_preferences.dart';

class DemoSession {
  const DemoSession._();

  // Public review credentials select bundled data; they grant no server access.
  static const username = 'shuyo.demo';
  static const password = 'CampusPreview26';
  static const _enabledKey = 'demo.session.enabled.v1';

  static bool isDemoUsername(String input) =>
      input.trim().toLowerCase() == username;

  static bool matchesCredentials(String inputUsername, String inputPassword) =>
      isDemoUsername(inputUsername) && inputPassword == password;

  static Future<bool> isEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? false;
  }

  static Future<void> enable() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, true);
  }

  static Future<void> disable() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_enabledKey);
  }
}
