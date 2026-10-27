import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps credentials in Keychain/Android secure storage on phones. Existing
/// SharedPreferences values are moved only after a secure write succeeds.
class SecureAppStore {
  SecureAppStore({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const _installMarker = 'shuyo.secure_storage.initialized.v1';
  static const campusCardSessionKey = 'campus_card.portal_session.v1';
  static const campusCardBalanceKey = 'campus_card.balance.v1';
  static const _sensitiveKeys = [
    campusCardSessionKey,
    campusCardBalanceKey,
    'academic.auth.cached_cookies.direct',
    'academic.auth.cached_cookies.webvpn',
    // Owned by SessionCookieJar.storageKey; repeated here so a fresh install
    // cannot inherit the previous one's campus sessions.
    'shuyo.session.cookies.v1',
    'shuyo.student.session.v1',
    'shuyo.student.pending_revocations.v1',
    'vod.auth.session.direct.v1',
    'vod.auth.session.webvpn.v1',
  ];
  static Future<void>? _mobileInitialization;

  final FlutterSecureStorage _secureStorage;
  final Future<SharedPreferences> Function() _preferencesLoader;

  bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  Future<void> _initialize() async {
    if (!_isMobile) return;
    _mobileInitialization ??= _initializeMobile();
    try {
      await _mobileInitialization;
    } on Object {
      _mobileInitialization = null;
      rethrow;
    }
  }

  Future<void> _initializeMobile() async {
    final prefs = await _preferencesLoader();
    if (prefs.getBool(_installMarker) == true) return;
    // iOS Keychain can survive app removal. A fresh install must not inherit
    // the previous installation's school or ShuYo login credentials.
    for (final key in _sensitiveKeys) {
      await _secureStorage.delete(key: key);
    }
    await prefs.setBool(_installMarker, true);
  }

  Future<String?> read(String key) async {
    final prefs = await _preferencesLoader();
    if (!_isMobile) return prefs.getString(key);
    await _initialize();
    final secure = await _secureStorage.read(key: key);
    final legacy = prefs.getString(key);
    if (secure != null) {
      if (legacy != null) await prefs.remove(key);
      return secure;
    }
    if (legacy == null) return null;
    await _secureStorage.write(key: key, value: legacy);
    await prefs.remove(key);
    return legacy;
  }

  Future<void> write(String key, String value) async {
    final prefs = await _preferencesLoader();
    if (_isMobile) {
      await _initialize();
      await _secureStorage.write(key: key, value: value);
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  Future<void> delete(String key) async {
    final prefs = await _preferencesLoader();
    if (_isMobile) {
      await _initialize();
      await _secureStorage.delete(key: key);
    }
    await prefs.remove(key);
  }
}
