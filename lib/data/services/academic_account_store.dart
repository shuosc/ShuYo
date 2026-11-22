import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/campus_system.dart';
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
  static const _systemKey = 'academic.account.system';

  final Future<SharedPreferences> Function() _preferencesLoader;

  CampusSystem _system(SharedPreferences prefs) =>
      prefs.getString(_systemKey) == CampusSystem.graduate.name
          ? CampusSystem.graduate
          : CampusSystem.undergraduate;

  String _key(String legacyKey, CampusSystem system) =>
      system == CampusSystem.undergraduate ? legacyKey : '$legacyKey.graduate';

  Future<CampusSystem> loadSystem() async =>
      _system(await _preferencesLoader());

  Future<void> saveSystem(CampusSystem system) async {
    final preferences = await _preferencesLoader();
    await preferences.setString(_systemKey, system.name);
  }

  Future<String?> loadStudentId({CampusSystem? system}) async {
    final preferences = await _preferencesLoader();
    final value = preferences
        .getString(_key(studentIdKey, system ?? _system(preferences)))
        ?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> saveStudentId(
    String studentId, {
    CampusSystem system = CampusSystem.undergraduate,
  }) async {
    final normalized = studentId.trim();
    if (normalized.isEmpty) return;
    final preferences = await _preferencesLoader();
    final key = _key(studentIdKey, system);
    if (preferences.getString(key)?.trim() != normalized) {
      final secure = SecureAppStore(preferencesLoader: _preferencesLoader);
      await secure.delete(SecureAppStore.campusCardSessionKey);
      if (await loadDataStudentId(system: system) != normalized) {
        await secure.delete(SecureAppStore.campusCardBalanceKey);
        await secure.delete(SecureAppStore.campusCardSnapshotKey);
      }
    }
    await Future.wait([
      preferences.setString(key, normalized),
      preferences.setString(_key(lastStudentIdKey, system), normalized),
      preferences.remove(_key(sessionExpiredKey, system)),
      if (system == CampusSystem.undergraduate)
        preferences.remove(legacySessionExpiredKey),
    ]);
  }

  Future<String?> loadDataStudentId({CampusSystem? system}) async {
    final preferences = await _preferencesLoader();
    final selected = system ?? _system(preferences);
    final value = (preferences.getString(_key(studentIdKey, selected)) ??
            preferences.getString(_key(lastStudentIdKey, selected)))
        ?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<bool> isSessionExpired({CampusSystem? system}) async {
    final preferences = await _preferencesLoader();
    return preferences
            .getBool(_key(sessionExpiredKey, system ?? _system(preferences))) ??
        false;
  }

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

  Future<void> clear({
    bool sessionExpired = false,
    CampusSystem system = CampusSystem.undergraduate,
  }) async {
    final preferences = await _preferencesLoader();
    if (system == CampusSystem.undergraduate) await rememberExistingAccounts();
    final studentId = await loadStudentId(system: system);
    if (studentId != null) {
      await preferences.setString(_key(lastStudentIdKey, system), studentId);
    }
    await Future.wait([
      preferences.remove(_key(studentIdKey, system)),
      if (system == CampusSystem.undergraduate)
        preferences.remove(legacySessionExpiredKey),
      if (sessionExpired)
        preferences.setBool(_key(sessionExpiredKey, system), true)
      else
        preferences.remove(_key(sessionExpiredKey, system)),
    ]);
    await SecureAppStore(preferencesLoader: _preferencesLoader)
        .delete(SecureAppStore.campusCardSessionKey);
    if (!sessionExpired) {
      await SecureAppStore(preferencesLoader: _preferencesLoader)
          .delete(SecureAppStore.campusCardBalanceKey);
      await SecureAppStore(preferencesLoader: _preferencesLoader)
          .delete(SecureAppStore.campusCardSnapshotKey);
    }
  }
}
