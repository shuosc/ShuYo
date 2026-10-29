import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_app_store.dart';

/// A cookie together with the scope that decides which requests receive it.
@immutable
class SessionCookie {
  const SessionCookie({
    required this.name,
    required this.value,
    this.domain = '',
    this.path = '/',
  });

  final String name;
  final String value;

  /// Host that owns the cookie; an empty value scopes it to no host at all.
  final String domain;

  /// Path prefix the cookie applies to.
  final String path;
}

/// The app-owned replacement for the platform WebView cookie jar.
///
/// Campus sessions used to live in the WebView cookie store: the login flow
/// wrote them there and every HTTP client read them back through
/// `WebViewCookieManager`. The jar now belongs to the app, so a session
/// survives without a WebView ever being created, and all services share one
/// instance the way they shared one platform store.
///
/// Cookies persist through [SecureAppStore]: a school session must never land
/// in plain `SharedPreferences`.
class SessionCookieJar {
  SessionCookieJar({
    Future<SharedPreferences> Function()? preferencesLoader,
    SecureAppStore? secureStore,
  }) : _secureStore =
            secureStore ?? SecureAppStore(preferencesLoader: preferencesLoader);

  /// The jar every campus service reads and writes.
  static final SessionCookieJar shared = SessionCookieJar();

  static const storageKey = 'shuyo.session.cookies.v1';

  final SecureAppStore _secureStore;
  final List<_StoredCookie> _cookies = [];
  bool _restored = false;
  Future<void>? _restoring;

  /// Returns the cookies that would be sent to [domain], using the host and
  /// path matching a browser applies.
  Future<List<SessionCookie>> getCookies({required Uri domain}) async {
    await _ensureRestored();
    return [
      for (final cookie in _cookies)
        if (cookie.matches(domain))
          SessionCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
          ),
    ];
  }

  /// Lists every path scope owned by [domain] or one of its subdomains.
  ///
  /// Use this when clearing a service's sessions: [getCookies] filters by the
  /// request path and would miss cookies scoped to other paths on that host.
  Future<List<SessionCookie>> getCookiesForDomainTree(
      {required String domain}) async {
    await _ensureRestored();
    final scope = _normalizeDomain(domain).toLowerCase();
    if (scope.isEmpty) return [];
    return [
      for (final cookie in _cookies)
        if (cookie.domain.toLowerCase() == scope ||
            cookie.domain.toLowerCase().endsWith('.$scope'))
          SessionCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
          ),
    ];
  }

  /// Writes [cookie] to its own scope. An empty value removes that scope
  /// without touching the other paths and hosts holding the same name.
  Future<void> setCookie(SessionCookie cookie) async {
    await _ensureRestored();
    final domain = _normalizeDomain(cookie.domain);
    final path = cookie.path.isEmpty ? '/' : cookie.path;
    _cookies.removeWhere(
      (stored) =>
          stored.name == cookie.name &&
          stored.domain == domain &&
          stored.path == path,
    );
    if (cookie.value.isNotEmpty) {
      _cookies.add(
        _StoredCookie(
          name: cookie.name,
          value: cookie.value,
          domain: domain,
          path: path,
        ),
      );
    }
    await _persist();
  }

  Future<void> _ensureRestored() {
    if (_restored) return Future<void>.value();
    final existing = _restoring;
    if (existing != null) return existing;
    late final Future<void> pending;
    pending = _restore().then((_) {
      _restored = true;
    }).whenComplete(() {
      // Retain only an in-flight restore. Keeping the completed Future also
      // retains its originating async zone across independent widget tests.
      if (identical(_restoring, pending)) _restoring = null;
    });
    _restoring = pending;
    return pending;
  }

  /// Forgets the in-memory cookies and the cached restore so the next read
  /// loads from storage again. Widget tests each run in their own fake-async
  /// zone; a restore future cached by an earlier test never completes there.
  @visibleForTesting
  void resetForTesting() {
    _cookies.clear();
    _restored = false;
    _restoring = null;
  }

  Future<void> _restore() async {
    String? raw;
    try {
      raw = await _secureStore.read(storageKey);
    } on Object {
      // An unavailable Keychain/Keystore leaves the jar empty for this run;
      // the next login repopulates it.
      return;
    }
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        final name = item['name']?.toString() ?? '';
        final value = item['value']?.toString() ?? '';
        final domain = _normalizeDomain(item['domain']?.toString() ?? '');
        final path = item['path']?.toString() ?? '';
        if (name.isEmpty || value.isEmpty || domain.isEmpty) continue;
        _cookies.add(
          _StoredCookie(
            name: name,
            value: value,
            domain: domain,
            path: path.isEmpty ? '/' : path,
          ),
        );
      }
    } on Object {
      // A malformed cache must not block a fresh login.
    }
  }

  Future<void> _persist() async {
    final encoded = jsonEncode([
      for (final cookie in _cookies)
        {
          'name': cookie.name,
          'value': cookie.value,
          'domain': cookie.domain,
          'path': cookie.path,
        },
    ]);
    try {
      await _secureStore.write(storageKey, encoded);
    } on Object {
      // The in-memory jar still serves this run; the next write retries.
    }
  }

  /// Normalizes the forms the platform store accepted as the same host: a
  /// scheme-qualified value and a dot-prefixed domain both describe [value]'s
  /// host without its punctuation.
  String _normalizeDomain(String value) {
    if (value.isEmpty) return '';
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
    final withoutScheme = value.replaceFirst(RegExp(r'^https?://'), '');
    final host = withoutScheme.split('/').first.split(':').first;
    return host.replaceFirst(RegExp(r'^\.'), '');
  }
}

class _StoredCookie {
  const _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
  });

  final String name;
  final String value;
  final String domain;
  final String path;

  bool matches(Uri uri) {
    if (domain.isEmpty) return false;
    final host = uri.host.toLowerCase();
    final normalized = domain.toLowerCase();
    if (host != normalized && !host.endsWith('.$normalized')) return false;
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath == path ||
        requestPath.startsWith(path.endsWith('/') ? path : '$path/');
  }
}
