import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'secure_app_store.dart';

class AcademicAccountStore {
  AcademicAccountStore({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const studentIdKey = 'academic.account.student_id';
  static const lastStudentIdKey = 'academic.account.last_student_id';
  static const loginHistoryKey = 'academic.account.login_history';
  static const sessionExpiredKey = 'academic.account.session_expired.current';
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
    if (preferences.getString(studentIdKey)?.trim() != normalized) {
      final secure = SecureAppStore(preferencesLoader: _preferencesLoader);
      await secure.delete(SecureAppStore.campusCardSessionKey);
      if (await loadDataStudentId() != normalized) {
        await secure.delete(SecureAppStore.campusCardBalanceKey);
      }
    }
    await Future.wait([
      preferences.setString(studentIdKey, normalized),
      preferences.setString(lastStudentIdKey, normalized),
      preferences.remove(sessionExpiredKey),
      preferences.remove(legacySessionExpiredKey),
    ]);
  }

  Future<String?> loadDataStudentId() async {
    final preferences = await _preferencesLoader();
    final value = (preferences.getString(studentIdKey) ??
            preferences.getString(lastStudentIdKey))
        ?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<bool> isSessionExpired() async =>
      (await _preferencesLoader()).getBool(sessionExpiredKey) ?? false;

  /// Upgrade existing accounts without treating their next login as first use.
  Future<void> rememberExistingAccounts() async {
    final preferences = await _preferencesLoader();
    final history = {...?preferences.getStringList(loginHistoryKey)};
    for (final key in [studentIdKey, lastStudentIdKey]) {
      final id = preferences.getString(key)?.trim();
      if (id != null && id.isNotEmpty) history.add(id);
    }
    for (final key in [
      'academic.schedule.cache',
      'academic.progress.cache',
      'academic.ranking.cache',
      'academic.student_profile.cache',
    ]) {
      try {
        final raw = preferences.getString(key);
        if (raw == null) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final id = key == 'academic.schedule.cache'
            ? (decoded['term'] is Map
                ? (decoded['term'] as Map)['studentId']
                : null)
            : decoded['studentId'];
        if (id is String && id.trim().isNotEmpty) history.add(id.trim());
      } on Object {
        // A damaged cache must not prevent account recovery.
      }
    }
    await preferences.setStringList(loginHistoryKey, history.toList());
  }

  /// Record authentication before fetching data, even if initial sync fails.
  Future<bool> takeInitialSync(String studentId) async {
    final id = studentId.trim();
    if (id.isEmpty) return false;
    final preferences = await _preferencesLoader();
    final history = {...?preferences.getStringList(loginHistoryKey)};
    final firstLogin = history.add(id);
    await preferences.setStringList(loginHistoryKey, history.toList());
    return firstLogin;
  }

  Future<bool> hasLegacyExpiredAccount() async =>
      (await _preferencesLoader()).getBool(legacySessionExpiredKey) == true;

  Future<void> clear({bool sessionExpired = false}) async {
    final preferences = await _preferencesLoader();
    await rememberExistingAccounts();
    final studentId = await loadStudentId();
    if (studentId != null) {
      await preferences.setString(lastStudentIdKey, studentId);
    }
    await Future.wait([
      preferences.remove(studentIdKey),
      preferences.remove(legacySessionExpiredKey),
      if (sessionExpired)
        preferences.setBool(sessionExpiredKey, true)
      else
        preferences.remove(sessionExpiredKey),
    ]);
    await SecureAppStore(preferencesLoader: _preferencesLoader)
        .delete(SecureAppStore.campusCardSessionKey);
    if (!sessionExpired) {
      await SecureAppStore(preferencesLoader: _preferencesLoader)
          .delete(SecureAppStore.campusCardBalanceKey);
    }
  }
}
