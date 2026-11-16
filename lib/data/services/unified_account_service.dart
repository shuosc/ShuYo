import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'academic_auth_service.dart';
import 'academic_account_store.dart';
import 'academic_native_auth_service.dart';
import '../../core/wecom_constants.dart';
import 'shu_sso_session_store.dart';
import 'wecom_auth_service.dart';

enum WebVpnRecoveryOutcome {
  alreadyValid,
  recovered,
  needsAuthentication,
  unavailable,
  businessFailure,
}

/// Reuses a newsso session to establish only the WebVPN business session.
/// A failed attempt never clears an existing SSO or business credential.
class UnifiedAccountService {
  UnifiedAccountService({
    ShuSsoSessionStore? ssoSessionStore,
    AcademicAuthService? academicAuthService,
    Future<SharedPreferences> Function()? preferencesLoader,
    WeComAuthService Function()? weComAuthServiceFactory,
    AcademicNativeAuthService Function()? webVpnInstallerFactory,
  })  : _ssoSessionStoreInstance = ssoSessionStore,
        _academicAuthServiceInstance = academicAuthService,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _weComAuthServiceFactory =
            weComAuthServiceFactory ?? (() => WeComAuthService()),
        _webVpnInstallerFactory = webVpnInstallerFactory ??
            (() => AcademicNativeAuthService.forWebVpn());

  static const pendingWebVpnRecoveryKey = 'account.webvpn.pending_recovery';
  static const pendingThereRecoveryKey = 'account.there.pending_recovery';

  ShuSsoSessionStore? _ssoSessionStoreInstance;
  ShuSsoSessionStore get _ssoSessionStore =>
      _ssoSessionStoreInstance ??= ShuSsoSessionStore();
  AcademicAuthService? _academicAuthServiceInstance;
  AcademicAuthService get _academicAuthService =>
      _academicAuthServiceInstance ??= AcademicAuthService();
  final Future<SharedPreferences> Function() _preferencesLoader;
  final WeComAuthService Function() _weComAuthServiceFactory;
  final AcademicNativeAuthService Function() _webVpnInstallerFactory;
  String? _lastWebVpnFailureMessage;

  String? get lastWebVpnFailureMessage => _lastWebVpnFailureMessage;

  Future<bool> isWebVpnPendingRecovery() async =>
      (await _preferencesLoader()).getBool(pendingWebVpnRecoveryKey) ?? false;

  Future<void> setWebVpnPendingRecovery(bool pending) async {
    final prefs = await _preferencesLoader();
    if (pending) {
      await prefs.setBool(pendingWebVpnRecoveryKey, true);
    } else {
      await prefs.remove(pendingWebVpnRecoveryKey);
    }
  }

  Future<bool> isTherePendingRecovery() async =>
      (await _preferencesLoader()).getBool(pendingThereRecoveryKey) ?? false;

  Future<void> setTherePendingRecovery(bool pending) async {
    final prefs = await _preferencesLoader();
    if (pending) {
      await prefs.setBool(pendingThereRecoveryKey, true);
    } else {
      await prefs.remove(pendingThereRecoveryKey);
    }
  }

  Future<WebVpnRecoveryOutcome> recoverWebVpn(
      {bool forceRefresh = false}) async {
    _lastWebVpnFailureMessage = null;
    final WebVpnSessionStatus existing;
    try {
      existing = await _academicAuthService.validateWebVpnSession();
    } on Object {
      return _finish(WebVpnRecoveryOutcome.unavailable);
    }
    if (existing == WebVpnSessionStatus.valid && !forceRefresh) {
      return _finish(WebVpnRecoveryOutcome.alreadyValid);
    }
    if (existing == WebVpnSessionStatus.unavailable) {
      return _finish(WebVpnRecoveryOutcome.unavailable);
    }

    final List<({Cookie cookie, String domain, String path})> cookies;
    try {
      cookies = await _ssoSessionStore.sessionCookies();
    } on Object {
      return _finish(WebVpnRecoveryOutcome.unavailable);
    }
    if (cookies.isEmpty) {
      return _finish(WebVpnRecoveryOutcome.needsAuthentication);
    }

    final auth = _weComAuthServiceFactory();
    try {
      auth.adoptSessionCookies(cookies);
      final result = await auth.completeWebVpnLogin();
      final expectedAccount = await AcademicAccountStore().loadStudentId();
      final actualAccount = result.accountName?.trim();
      if (expectedAccount != null &&
          actualAccount != null &&
          actualAccount.isNotEmpty &&
          actualAccount.toLowerCase() != expectedAccount.toLowerCase()) {
        _lastWebVpnFailureMessage = 'WebVPN账号与当前校园账户不一致';
        return await _finish(WebVpnRecoveryOutcome.businessFailure);
      }
      final installer = _webVpnInstallerFactory();
      try {
        installer.adoptSessionCookies(result.sessionCookies.map(
          (entry) => (
            cookie: entry.cookie,
            domain: entry.domain,
            path: entry.path,
          ),
        ));
        // Clear the rejected session before publishing the new one, so a stale
        // webvpn-token cannot shadow the token this handshake just created.
        await installer.resetPreviousSession();
        await installer.publishSessionCookies();
      } finally {
        installer.dispose();
      }
      final verified = await _academicAuthService.validateWebVpnSession();
      return await _finish(switch (verified) {
        WebVpnSessionStatus.valid => WebVpnRecoveryOutcome.recovered,
        WebVpnSessionStatus.loginRequired =>
          WebVpnRecoveryOutcome.businessFailure,
        WebVpnSessionStatus.unavailable => WebVpnRecoveryOutcome.unavailable,
      });
    } on WeComAuthException catch (error) {
      _lastWebVpnFailureMessage = error.message;
      return _finish(switch (error.code) {
        'sessionNotReused' => WebVpnRecoveryOutcome.needsAuthentication,
        'webVpnHttpError' ||
        'invalidWebVpnResponse' ||
        'webVpnAuthorizeFailed' =>
          WebVpnRecoveryOutcome.unavailable,
        _ => WebVpnRecoveryOutcome.businessFailure,
      });
    } on TimeoutException {
      return _finish(WebVpnRecoveryOutcome.unavailable);
    } on Object {
      return _finish(WebVpnRecoveryOutcome.unavailable);
    } finally {
      auth.dispose();
    }
  }

  /// Returns null only when SSO cannot authorize without new user input.
  /// Other failures remain errors of this authorization attempt.
  Future<Uri?> authorizeAcademic() async {
    final cookies = await _ssoSessionStore.sessionCookies();
    if (cookies.isEmpty) return null;
    final auth = _weComAuthServiceFactory();
    try {
      auth.adoptSessionCookies(cookies);
      return await auth.authorizeTarget(WeComOAuthTarget.academic);
    } on WeComAuthException catch (error) {
      if (error.code == 'sessionNotReused') return null;
      rethrow;
    } finally {
      auth.dispose();
    }
  }

  Future<Uri?> authorizeThere() async {
    final cookies = await _ssoSessionStore.sessionCookies();
    if (cookies.isEmpty) return null;
    final auth = _weComAuthServiceFactory();
    try {
      auth.adoptSessionCookies(cookies);
      return await auth.authorizeTarget(WeComOAuthTarget.there);
    } on WeComAuthException catch (error) {
      if (error.code == 'sessionNotReused') return null;
      rethrow;
    } finally {
      auth.dispose();
    }
  }

  Future<Uri?> authorizeCampusCard() async {
    final cookies = await _ssoSessionStore.sessionCookies();
    if (cookies.isEmpty) return null;
    final auth = _weComAuthServiceFactory();
    try {
      auth.adoptSessionCookies(cookies);
      return await auth.authorizeTarget(WeComOAuthTarget.campusCard);
    } on WeComAuthException catch (error) {
      if (error.code == 'sessionNotReused') return null;
      rethrow;
    } finally {
      auth.dispose();
    }
  }

  Future<WebVpnRecoveryOutcome> _finish(WebVpnRecoveryOutcome outcome) async {
    await setWebVpnPendingRecovery(
      outcome != WebVpnRecoveryOutcome.alreadyValid &&
          outcome != WebVpnRecoveryOutcome.recovered,
    );
    return outcome;
  }

  Future<void> clearSsoSession() => _ssoSessionStore.clearSession();
}
