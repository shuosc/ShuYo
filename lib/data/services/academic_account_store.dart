import 'package:shared_preferences/shared_preferences.dart';

class AcademicAccountStore {
  AcademicAccountStore({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const studentIdKey = 'academic.account.student_id';
  // Kept only so upgrades can collapse the former "expired account" state
  // into the canonical signed-out state.
  static const legacySessionExpiredKey = 'academic.account.session_expired';

  final Future<SharedPreferences> Function() _preferencesLoader;

  Future<String?> loadStudentId() async {
    final value = (await _preferencesLoader()).getString(studentIdKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> saveStudentId(String studentId) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return;
    final preferences = await _preferencesLoader();
    await Future.wait([
      preferences.setString(studentIdKey, normalized),
      preferences.remove(legacySessionExpiredKey),
    ]);
  }

  Future<bool> hasLegacyExpiredAccount() async =>
      (await _preferencesLoader()).getBool(legacySessionExpiredKey) == true;

  Future<void> clear() async {
    final preferences = await _preferencesLoader();
    await Future.wait([
      preferences.remove(studentIdKey),
      preferences.remove(legacySessionExpiredKey),
    ]);
  }
}
