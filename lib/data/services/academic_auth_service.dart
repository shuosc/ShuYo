import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/academic_constants.dart';
import '../../core/academic_url_resolver.dart';
import '../../core/client_user_agent.dart';
import '../../core/forum_url_resolver.dart';
import 'academic_account_store.dart';
import 'http_timeout.dart';

enum WebVpnSessionStatus { valid, loginRequired, unavailable }

class AcademicAuthService {
  AcademicAuthService({
    WebViewCookieManager? cookieManager,
    Future<SharedPreferences> Function()? preferencesLoader,
    AcademicAccountStore? accountStore,
    Future<List<WebViewCookie>> Function(Uri domain)? cookieLoader,
    Future<void> Function(WebViewCookie cookie)? cookieSetter,
    Future<WebVpnSessionStatus> Function(String cookieHeader)?
        webVpnSessionValidator,
    Future<WebVpnSessionStatus> Function(String cookieHeader)?
        directSessionValidator,
  })  : _cookieManager = cookieManager ??
            (cookieLoader == null || cookieSetter == null
                ? WebViewCookieManager()
                : null),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _accountStore = accountStore ??
            AcademicAccountStore(preferencesLoader: preferencesLoader) {
    _cookieLoader =
        cookieLoader ?? (domain) => _cookieManager!.getCookies(domain: domain);
    _cookieSetter = cookieSetter ?? _cookieManager!.setCookie;
    _webVpnSessionValidator =
        webVpnSessionValidator ?? _validateWebVpnSessionOverNetwork;
    _directSessionValidator =
        directSessionValidator ?? _validateDirectAcademicSessionOverNetwork;
  }

  static const _cachedDirectCookiesKey = 'academic.auth.cached_cookies.direct';
  static const _cachedWebVpnCookiesKey = 'academic.auth.cached_cookies.webvpn';
  // Explicit logout must win over a temporarily unavailable WebVPN endpoint
  // and any cookies that a WebView has not removed yet.
  static const _explicitlySignedOutKey = 'academic.auth.explicitly_signed_out';
  static const _portalGroup = 'portal';
  static const _academicGroup = 'academic';

  final WebViewCookieManager? _cookieManager;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final AcademicAccountStore _accountStore;
  late final Future<List<WebViewCookie>> Function(Uri domain) _cookieLoader;
  late final Future<void> Function(WebViewCookie cookie) _cookieSetter;
  late final Future<WebVpnSessionStatus> Function(String cookieHeader)
      _webVpnSessionValidator;
  late final Future<WebVpnSessionStatus> Function(String cookieHeader)
      _directSessionValidator;

  /// Clears every piece of state that makes the campus account appear signed
  /// in. Schedule data, forum cookies, and WebVPN cookies are intentionally
  /// outside this account boundary.
  Future<void> clearAccount() async {
    try {
      await clearCookies();
    } finally {
      // Account identity must never survive a confirmed invalid session, even
      // if an individual platform-cookie operation fails.
      await _accountStore.clear();
    }
  }

  Future<Set<String>> clearCookies() async {
    // Academic logout only owns the direct jwxt session. WebVPN and forum
    // sessions are independent and must survive this operation.
    final clearedSharedNames = <String>{};
    final domains = <(Uri, bool)>[
      (Uri.parse(AcademicConstants.baseUrl), false),
      (Uri.parse('${AcademicConstants.baseUrl}/jwglxt/'), false),
    ];
    final prefs = await _preferencesLoader();
    // Record the user's intent before touching the WebView. Cookie deletion
    // can fail on a transient WebVPN/WebView error, but must not resurrect the
    // account on the next app launch.
    await prefs.setBool(_explicitlySignedOutKey, true);
    for (final (domain, sharedWithForum) in domains) {
      List<WebViewCookie> cookies;
      try {
        cookies = await _cookieLoader(domain);
      } on Object {
        continue;
      }
      for (final cookie in cookies) {
        if (sharedWithForum) clearedSharedNames.add(cookie.name);
        try {
          await _cookieSetter(
            WebViewCookie(
              name: cookie.name,
              value: '',
              domain: cookie.domain,
              path: cookie.path,
            ),
          );
        } on Object {
          // Continue clearing other domains; the persistent logout marker
          // above protects against a partial WebView cleanup.
        }
      }
    }
    await Future.wait([
      prefs.remove(_cachedDirectCookiesKey),
      prefs.setBool(_explicitlySignedOutKey, true),
    ]);
    return clearedSharedNames;
  }

  /// Clears the persistent logout marker after a user completes login.
  Future<void> markLoggedIn() async {
    final prefs = await _preferencesLoader();
    await prefs.remove(_explicitlySignedOutKey);
  }

  Future<bool> _isExplicitlySignedOut() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(_explicitlySignedOutKey) == true;
  }

  Future<bool> hasWebVpnSession() async {
    final status = await validateWebVpnSession();
    // A transport failure does not prove that the user was logged out. Keep
    // the cached account available and retry validation with the next forum
    // recovery instead of destroying a potentially valid session.
    return status != WebVpnSessionStatus.loginRequired;
  }

  /// Validates the campus account using the currently selected access mode.
  /// The WebView remains the source of the session cookies; this method only
  /// restores and probes those cookies so a restart can recover the account.
  Future<bool> hasAcademicSession() async {
    if (await _isExplicitlySignedOut()) return false;
    final status = AcademicUrlResolver.usesWebVpn
        ? await validateWebVpnSession()
        : await validateDirectAcademicSession();
    return status == WebVpnSessionStatus.valid;
  }

  Future<WebVpnSessionStatus> validateDirectAcademicSession() async {
    if (await _isExplicitlySignedOut()) {
      return WebVpnSessionStatus.loginRequired;
    }
    final cached = await _loadCachedCookies(webVpn: false);
    final live = await _loadLiveCookies(webVpn: false);
    final merged = _mergeCookieGroups(cached, live);
    await _persistCookies(merged, webVpn: false);
    await _restoreCookies(merged);
    final cookies = merged[_academicGroup] ?? const <WebViewCookie>[];
    final header = cookies
        .where((cookie) => cookie.name.isNotEmpty && cookie.value.isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    if (header.isEmpty) return WebVpnSessionStatus.loginRequired;
    return _directSessionValidator(header).timeout(
      HttpTimeout.normal,
      onTimeout: () => WebVpnSessionStatus.unavailable,
    );
  }

  Future<WebVpnSessionStatus> _validateDirectAcademicSessionOverNetwork(
    String cookieHeader,
  ) async {
    final client = HttpClient()..connectionTimeout = HttpTimeout.connect;
    final deadline = Timer(
      HttpTimeout.normal,
      () => client.close(force: true),
    );
    var current = AcademicUrlResolver.homeUri;
    try {
      for (var redirectCount = 0; redirectCount < 10; redirectCount++) {
        final request = await client.getUrl(current).timeout(
              HttpTimeout.connect,
            );
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml')
          ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
        // The academic session cookie is scoped to jwxt; do not forward it
        // to the SSO host while inspecting an expired-session redirect.
        if (current.host == AcademicConstants.host) {
          request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
        }
        final response = await request.close().timeout(HttpTimeout.normal);
        final location = response.headers.value(HttpHeaders.locationHeader);
        final statusCode = response.statusCode;
        await response.drain<void>().timeout(HttpTimeout.normal);
        _debug(
          'direct validation hop=$redirectCount status=$statusCode '
          'uri=${_describeUri(current)} '
          'location=${_describeLocation(current, location)}',
        );
        if (statusCode >= 300 && statusCode < 400 && location != null) {
          final next = current.resolve(location);
          if (!_isAllowedAcademicHost(next.host)) {
            return WebVpnSessionStatus.unavailable;
          }
          current = next;
          continue;
        }
        if (current.host == AcademicConstants.host &&
            current.path.startsWith('/jwglxt/') &&
            !current.path.endsWith('/jwglxt/ticketlogin') &&
            !current.path.endsWith('/jwglxt/xtgl/login_slogin.html')) {
          return WebVpnSessionStatus.valid;
        }
        if (current.host.contains('newsso-shu-edu-cn') ||
            current.host == 'newsso.shu.edu.cn' ||
            statusCode == 401 ||
            statusCode == 403) {
          return WebVpnSessionStatus.loginRequired;
        }
        return WebVpnSessionStatus.unavailable;
      }
      return WebVpnSessionStatus.unavailable;
    } on TimeoutException catch (error) {
      _debug('direct validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on SocketException catch (error) {
      _debug('direct validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on HandshakeException catch (error) {
      _debug('direct validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on HttpException catch (error) {
      _debug('direct validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on Object catch (error) {
      _debug('direct validation failed: ${error.runtimeType}');
      return WebVpnSessionStatus.unavailable;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  bool _isAllowedAcademicHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'shu.edu.cn' || normalized.endsWith('.shu.edu.cn');
  }

  Future<WebVpnSessionStatus> validateWebVpnSession() async {
    final cached = await _loadCachedCookies(webVpn: true);
    final live = await _loadLiveCookies(webVpn: true);
    final merged = _mergeCookieGroups(cached, live);
    await _persistCookies(merged, webVpn: true);
    await _restoreCookies(merged);
    final hasToken = merged[_portalGroup]?.any(
          (cookie) => cookie.name == 'webvpn-token' && cookie.value.isNotEmpty,
        ) ==
        true;
    if (!hasToken) {
      _debug(
        'session validation: missing portal webvpn-token '
        '${_describeCookieSources(cached: cached, live: live)}',
      );
      return WebVpnSessionStatus.loginRequired;
    }
    final header = (merged[_portalGroup] ?? const <WebViewCookie>[])
        .where((cookie) => cookie.name.isNotEmpty && cookie.value.isNotEmpty)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    if (header.isEmpty) {
      _debug('session validation: empty portal cookie header');
      return WebVpnSessionStatus.loginRequired;
    }
    final status = await _webVpnSessionValidator(header).timeout(
      HttpTimeout.normal,
      onTimeout: () => WebVpnSessionStatus.unavailable,
    );
    _debug(
      'session validation=${status.name} '
      '${_describeCookieSources(cached: cached, live: live)}',
    );
    return status;
  }

  Future<WebVpnSessionStatus> _validateWebVpnSessionOverNetwork(
    String cookieHeader,
  ) async {
    final client = HttpClient()..connectionTimeout = HttpTimeout.connect;
    final deadline = Timer(
      HttpTimeout.normal,
      () => client.close(force: true),
    );
    var current = Uri.parse('${ForumUrlResolver.webVpnBaseUrl}/latest');
    try {
      for (var redirectCount = 0; redirectCount < 10; redirectCount++) {
        final request = await client.getUrl(current).timeout(
              HttpTimeout.connect,
            );
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml')
          ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
          ..set(HttpHeaders.cookieHeader, cookieHeader);
        final response = await request.close().timeout(HttpTimeout.normal);
        final location = response.headers.value(HttpHeaders.locationHeader);
        final statusCode = response.statusCode;
        await response.drain<void>().timeout(HttpTimeout.normal);
        _debug(
          'webvpn validation hop=$redirectCount status=$statusCode '
          'uri=${_describeUri(current)} '
          'location=${_describeLocation(current, location)}',
        );
        if (statusCode >= 300 && statusCode < 400 && location != null) {
          current = current.resolve(location);
          continue;
        }
        if (current.host == ForumUrlResolver.webVpnHost) {
          return WebVpnSessionStatus.valid;
        }
        if (_isWebVpnLoginUri(current) ||
            statusCode == 401 ||
            statusCode == 403) {
          return WebVpnSessionStatus.loginRequired;
        }
        return WebVpnSessionStatus.unavailable;
      }
      return WebVpnSessionStatus.unavailable;
    } on TimeoutException catch (error) {
      _debug('webvpn validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on SocketException catch (error) {
      _debug('webvpn validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on HandshakeException catch (error) {
      _debug('webvpn validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on HttpException catch (error) {
      _debug('webvpn validation failed: $error');
      return WebVpnSessionStatus.unavailable;
    } on Object catch (error) {
      _debug('webvpn validation failed: ${error.runtimeType}');
      return WebVpnSessionStatus.unavailable;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  bool _isWebVpnLoginUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == Uri.parse(ForumUrlResolver.webVpnPortalUrl).host) return true;
    return host == 'oauth.shu.edu.cn' ||
        host.endsWith('.oauth.shu.edu.cn') ||
        host.contains('oauth-shu-edu-cn') ||
        host.contains('newsso-shu-edu-cn');
  }

  /// Returns cookies suitable for the current service.
  ///
  /// When [targetUri] is supplied, cookies are filtered using normal browser
  /// host/path matching. This is important on Android WebView: the WebVPN
  /// portal and each proxied academic host can contain different values for
  /// the same `webvpn-token` name. Collapsing all domains by name can select
  /// the portal token for an academic request and produces a valid HTTP 200
  /// login page instead of the authenticated response.
  Future<String?> cookieHeader({Uri? targetUri}) async {
    final webVpn = AcademicUrlResolver.usesWebVpn;
    final cached = await _loadCachedCookies(webVpn: webVpn);
    final live = await _loadLiveCookies(webVpn: webVpn);
    final merged = _mergeCookieGroups(cached, live);
    await _persistCookies(merged, webVpn: webVpn);

    final values = <String, _CookieCandidate>{};
    final groups = targetUri == null
        ? [if (webVpn) _portalGroup, _academicGroup]
        : <String>[_academicGroup];
    for (final group in groups) {
      for (final cookie in merged[group] ?? const <WebViewCookie>[]) {
        if (cookie.name.isNotEmpty && cookie.value.isNotEmpty) {
          if (targetUri != null && !_cookieMatches(cookie, targetUri)) {
            continue;
          }
          final candidate = _CookieCandidate(cookie);
          final previous = values[cookie.name];
          if (previous == null || candidate.score > previous.score) {
            values[cookie.name] = candidate;
          }
        }
      }
    }
    final target = targetUri == null ? '-' : _describeUri(targetUri);
    if (values.isEmpty) {
      _debug(
        'cookie selection target=$target selected=[] '
        '${_describeCookieSources(cached: cached, live: live)}',
      );
      return null;
    }
    final selected = values.values
        .map(
          (candidate) =>
              '${candidate.cookie.name}@${candidate.cookie.domain}${candidate.cookie.path}',
        )
        .toList()
      ..sort();
    _debug(
      'cookie selection target=$target selected=$selected '
      '${_describeCookieSources(cached: cached, live: live)}',
    );
    await markLoggedIn();
    return values.entries
        .map((entry) => '${entry.key}=${entry.value.cookie.value}')
        .join('; ');
  }

  Future<Map<String, List<WebViewCookie>>> _loadLiveCookies({
    required bool webVpn,
  }) async {
    final groups = <String, List<WebViewCookie>>{};
    if (webVpn) {
      groups[_portalGroup] = await _cookiesFor(
        Uri.parse(ForumUrlResolver.webVpnPortalUrl),
      );
    }
    final academicDomains = webVpn
        ? <Uri>[
            // The WebVPN gateway redirects through this legacy HTTP-prefixed
            // host during ticket login. Android keeps its cookies scoped to
            // that host instead of exposing them on the HTTPS-prefixed host.
            Uri.parse(
              'https://http-jwxt-shu-edu-cn-80.webvpn.shu.edu.cn',
            ),
            Uri.parse(AcademicUrlResolver.webVpnBaseUrl),
            // Some Android WebView versions keep the ticket/session cookie
            // scoped to /jwglxt rather than /. Querying the exact path is
            // required for CookieManager.getCookie to return it.
            Uri.parse('${AcademicUrlResolver.webVpnBaseUrl}/jwglxt/'),
            AcademicUrlResolver.scheduleIndexUri,
            // The gateway can redirect through the original host. Keep a
            // direct-host snapshot as a fallback for Android WebView builds
            // that scope the backend session cookie there.
            Uri.parse(AcademicConstants.baseUrl),
            Uri.parse('${AcademicConstants.baseUrl}/jwglxt/'),
          ]
        : <Uri>[
            Uri.parse(AcademicConstants.baseUrl),
            Uri.parse('${AcademicConstants.baseUrl}/jwglxt/'),
            AcademicUrlResolver.homeUri,
            AcademicUrlResolver.scheduleIndexUri,
          ];
    final academicCookies = <WebViewCookie>[];
    for (final domain in academicDomains) {
      academicCookies.addAll(await _cookiesFor(domain));
    }
    groups[_academicGroup] = academicCookies;
    return groups;
  }

  Future<List<WebViewCookie>> _cookiesFor(Uri domain) async {
    try {
      final loaded = (await _cookieLoader(domain))
          .where((cookie) => cookie.name.isNotEmpty && cookie.value.isNotEmpty)
          .map(
            (cookie) => WebViewCookie(
              name: cookie.name,
              value: cookie.value,
              domain: _normalizeCookieDomain(cookie.domain, domain.host),
              path: cookie.path.isEmpty ? '/' : cookie.path,
            ),
          )
          .toList();
      final cookies = loaded
          .map((cookie) => '${cookie.name}@${cookie.domain}${cookie.path}')
          .toList()
        ..sort();
      _debug(
          'webview cookie read domain=${_describeUri(domain)} cookies=$cookies');
      return loaded;
    } on Object catch (error) {
      _debug(
        'webview cookie read failed domain=${_describeUri(domain)} '
        'error=${error.runtimeType}',
      );
      return const [];
    }
  }

  String _normalizeCookieDomain(String value, String fallbackHost) {
    if (value.isEmpty) return fallbackHost;
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
    final withoutScheme = value.replaceFirst(RegExp(r'^https?://'), '');
    final host = withoutScheme.split('/').first.split(':').first;
    return host.isEmpty ? fallbackHost : host;
  }

  bool _cookieMatches(WebViewCookie cookie, Uri target) {
    final domain = _normalizeCookieDomain(cookie.domain, target.host);
    final host = target.host.toLowerCase();
    final normalizedDomain =
        domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final hostMatches =
        host == normalizedDomain || host.endsWith('.$normalizedDomain');
    if (!hostMatches) return false;
    final path = cookie.path.isEmpty ? '/' : cookie.path;
    final targetPath = target.path.isEmpty ? '/' : target.path;
    return targetPath == path ||
        targetPath.startsWith(path.endsWith('/') ? path : '$path/');
  }

  Future<Map<String, List<WebViewCookie>>> _loadCachedCookies({
    required bool webVpn,
  }) async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(_cacheKey(webVpn));
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final groups = <String, List<WebViewCookie>>{};
      for (final entry in decoded.entries) {
        if (entry.value is! List) continue;
        final cookies = <WebViewCookie>[];
        for (final item in entry.value as List) {
          if (item is! Map) continue;
          final name = item['name']?.toString() ?? '';
          final value = item['value']?.toString() ?? '';
          final domain = item['domain']?.toString() ?? '';
          final path = item['path']?.toString() ?? '/';
          if (name.isEmpty || value.isEmpty || domain.isEmpty) continue;
          cookies.add(
            WebViewCookie(
              name: name,
              value: value,
              domain: domain,
              path: path.isEmpty ? '/' : path,
            ),
          );
        }
        if (cookies.isNotEmpty) groups[entry.key.toString()] = cookies;
      }
      return groups;
    } on Object {
      return const {};
    }
  }

  Map<String, List<WebViewCookie>> _mergeCookieGroups(
    Map<String, List<WebViewCookie>> cached,
    Map<String, List<WebViewCookie>> live,
  ) {
    final groups = <String, List<WebViewCookie>>{};
    for (final group in {...cached.keys, ...live.keys}) {
      final values = <String, WebViewCookie>{};
      final liveCookies = live[group] ?? const <WebViewCookie>[];
      final liveNames = liveCookies.map((cookie) => cookie.name).toSet();
      for (final cookie in cached[group] ?? const <WebViewCookie>[]) {
        // Once WebView exposes a cookie name for this service, its live values
        // are authoritative across all scopes. Keeping an older, more-specific
        // cached path can otherwise make it win request selection after login.
        if (liveNames.contains(cookie.name)) continue;
        values[_cookieKey(cookie)] = cookie;
      }
      for (final cookie in liveCookies) {
        values[_cookieKey(cookie)] = cookie;
      }
      if (values.isNotEmpty) groups[group] = values.values.toList();
    }
    return groups;
  }

  String _cookieKey(WebViewCookie cookie) =>
      '${cookie.name}\u0000${cookie.domain}\u0000${cookie.path}';

  Future<void> _persistCookies(
    Map<String, List<WebViewCookie>> groups, {
    required bool webVpn,
  }) async {
    if (groups.values.every((cookies) => cookies.isEmpty)) return;
    final encoded = <String, Object>{};
    for (final entry in groups.entries) {
      if (entry.value.isEmpty) continue;
      encoded[entry.key] = entry.value
          .map(
            (cookie) => {
              'name': cookie.name,
              'value': cookie.value,
              'domain': cookie.domain,
              'path': cookie.path,
            },
          )
          .toList();
    }
    final prefs = await _preferencesLoader();
    await prefs.setString(_cacheKey(webVpn), jsonEncode(encoded));
  }

  Future<void> _restoreCookies(
    Map<String, List<WebViewCookie>> groups,
  ) async {
    for (final cookies in groups.values) {
      for (final cookie in cookies) {
        try {
          await _cookieSetter(cookie);
        } on Object {
          // HTTP 请求仍可使用缓存，WebView 恢复失败不应清除登录态。
        }
      }
    }
  }

  String _cacheKey(bool webVpn) =>
      webVpn ? _cachedWebVpnCookiesKey : _cachedDirectCookiesKey;

  String _describeCookieSources({
    required Map<String, List<WebViewCookie>> cached,
    required Map<String, List<WebViewCookie>> live,
  }) {
    String describe(Map<String, List<WebViewCookie>> groups) {
      final result = <String>[];
      for (final entry in groups.entries) {
        final names = entry.value.map((cookie) => cookie.name).toSet().toList()
          ..sort();
        result.add('${entry.key}:$names');
      }
      result.sort();
      return result.toString();
    }

    return 'cached=${describe(cached)} live=${describe(live)}';
  }

  String _describeUri(Uri uri) {
    final queryKeys = uri.queryParameters.keys.toList()..sort();
    return '${uri.host}${uri.path}'
        '${queryKeys.isEmpty ? '' : ' queryKeys=$queryKeys'}';
  }

  String _describeLocation(Uri current, String? location) {
    if (location == null || location.isEmpty) return '-';
    try {
      return _describeUri(current.resolve(location));
    } on Object {
      return '<invalid>';
    }
  }

  void _debug(String message) {
    if (kDebugMode) debugPrint('[SHU_ACADEMIC_AUTH] $message');
  }
}

class _CookieCandidate {
  _CookieCandidate(this.cookie)
      : score = cookie.domain.length * 1000 + cookie.path.length;

  final WebViewCookie cookie;
  final int score;
}
