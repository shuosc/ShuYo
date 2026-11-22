import 'dart:convert';
import 'dart:io';

import '../../core/wecom_constants.dart';
import 'secure_app_store.dart';
import 'session_cookie_jar.dart';

/// The YJS portal session and the SSO credential from its own sign-in.
class GraduateSessionStore {
  GraduateSessionStore(
      {SessionCookieJar? cookieJar, SecureAppStore? secureStore})
      : _cookieJar = cookieJar ?? SessionCookieJar.shared,
        _secureStore = secureStore ?? SecureAppStore();

  static const host = 'yjs.shu.edu.cn';
  static const sessionCookieName = 'GS_SESSIONID';
  static final entryUri = Uri.https(host, '/');
  static final portalUri =
      Uri.https(host, '/gsapp/sys/yjsemaphome/portal/index.do');
  static final userInfoUri = Uri.https(
    host,
    '/gsapp/sys/yjsemaphome/modules/pubWork/getUserInfo.do',
  );

  final SessionCookieJar _cookieJar;
  final SecureAppStore _secureStore;

  Future<List<SessionCookie>> loadCookies() async => [
        for (final cookie
            in await _cookieJar.getCookiesForDomainTree(domain: host))
          if (cookie.domain == host) cookie,
      ];

  Future<String?> cookieHeaderForIdentityVerification() async {
    final matches = (await _cookieJar.getCookies(domain: userInfoUri))
        .where((cookie) =>
            cookie.domain == host &&
            cookie.name == sessionCookieName &&
            cookie.value.isNotEmpty)
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matches.isEmpty ? null : '$sessionCookieName=${matches.first.value}';
  }

  /// Never renew YJS using a shared SSO cookie that may have been replaced by
  /// a different login (e.g. a standalone campus service).
  Future<Cookie?> loadRenewalCookie() async {
    final raw = await _secureStore.read(SecureAppStore.graduateSsoSessionKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['value'] is! String) return null;
      final value = decoded['value'] as String;
      final expiration = decoded['expires'];
      final expires = expiration is int
          ? DateTime.fromMillisecondsSinceEpoch(expiration)
          : null;
      if (value.isEmpty || expires?.isAfter(DateTime.now()) == false) {
        return null;
      }
      return Cookie(WeComConstants.sessionCookieName, value)
        ..path = '/'
        ..expires = expires;
    } on FormatException {
      return null;
    }
  }

  Future<void> saveRenewalCookie(Cookie? cookie) async {
    if (cookie == null) {
      await _secureStore.delete(SecureAppStore.graduateSsoSessionKey);
      return;
    }
    await _secureStore.write(
      SecureAppStore.graduateSsoSessionKey,
      jsonEncode({
        'value': cookie.value,
        'expires': cookie.expires?.millisecondsSinceEpoch,
      }),
    );
  }

  Future<void> replacePortalCookies(List<SessionCookie> cookies) async {
    final portalCookies = cookies.where((cookie) => cookie.domain == host);
    final scopes = {
      for (final cookie in portalCookies) (cookie.name, cookie.path)
    };
    for (final cookie in await loadCookies()) {
      if (scopes.contains((cookie.name, cookie.path))) continue;
      await _cookieJar.setCookie(SessionCookie(
        name: cookie.name,
        value: '',
        domain: host,
        path: cookie.path,
      ));
    }
    for (final cookie in portalCookies) {
      await _cookieJar.setCookie(cookie);
    }
  }

  Future<void> clearSession() async {
    await saveRenewalCookie(null);
    await replacePortalCookies(const []);
  }
}
