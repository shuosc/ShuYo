import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/client_user_agent.dart';
import '../../core/otp_url_resolver.dart';
import '../../core/webvpn_urls.dart';
import '../../core/wecom_constants.dart';
import '../models/otp_token.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'otp_token_parser.dart';
import 'session_cookie_jar.dart';

/// Raised when the token page cannot be read. [code] is a stable identifier
/// the UI can branch on, [message] is shown to the user.
class OtpTokenException implements Exception {
  const OtpTokenException(this.code, this.message, {this.statusCode});

  /// The campus single sign-on session is gone, so the token system cannot be
  /// authorized and the user has to log in again.
  static const sessionNotReused = 'sessionNotReused';

  /// The WebVPN gateway rejected its token. Recovering the session through the
  /// account manager usually needs no new credentials.
  static const webVpnLoginRequired = 'webVpnLoginRequired';

  static const networkError = 'networkError';
  static const timeout = 'timeout';

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() {
    final status = statusCode;
    return status == null ? message : '$message ($status)';
  }
}

/// Reads the dynamic password from the school token page
/// (`https://otp.shu.edu.cn/`).
///
/// The page is an ASP.NET WebForms single page whose code is rendered by the
/// server, so the app only has to hold a token session and re-read the page.
/// The session is established from the campus single sign-on cookie the app
/// already stores:
///
/// 1. `GET /` bootstraps a `state` and an `ASP.NET_SessionId` (the callback
///    compares the two, so the warm-up request is mandatory);
/// 2. `GET newsso/oauth/authorize?...&state=` returns the callback location
///    carrying an authorization `code`;
/// 3. the callback exchanges the code for the token session; it redirects via a
///    `Refresh` header rather than a 302, so it is followed manually.
///
/// Every request shares one cookie container, the way a browser session would.
///
/// The transport follows the WebVPN setting the same way the classroom module
/// does: when it is on, the token site is reached through the gateway host and
/// the portal `webvpn-token` is attached, so an off-campus user sees the same
/// code as on campus. The OAuth exchange itself still runs against the direct
/// identity host, where the app keeps `SHU_OAUTH2`, and the returned code is
/// then redeemed through the gateway.
class OtpTokenApiClient {
  OtpTokenApiClient({
    HttpClient? httpClient,
    SessionCookieJar? cookieJar,
  })  : _client = httpClient ?? HttpClient(),
        _cookieJarInstance = cookieJar {
    _client.connectionTimeout = HttpTimeout.connect;
  }

  static const _landingMarker = 'Default.aspx';
  static const _accountMarker = '账户名';
  static const _maxRedirects = 8;
  static final _ssoHost = Uri.parse(WeComConstants.ssoBase).host;

  /// Identity host the gateway rewrites SSO traffic to. A WebVPN login can
  /// leave `SHU_OAUTH2` here instead of on the direct identity host.
  static final _webVpnSsoHost =
      Uri.parse('https://${WeComConstants.webVpnNewssoProxyHost}');
  static final _portalHost = Uri.parse(WebVpnUrls.portal).host;

  final HttpClient _client;
  final AcademicSessionCookieStore _cookies = AcademicSessionCookieStore();
  SessionCookieJar? _cookieJarInstance;
  SessionCookieJar get _cookieJar =>
      _cookieJarInstance ??= SessionCookieJar.shared;

  bool _ssoAdopted = false;
  String? _portalWebVpnToken;

  void dispose() => _client.close(force: true);

  /// Reads the code the token page shows right now.
  ///
  /// The first call also establishes the token session; later calls reuse it,
  /// and re-establish it transparently once it expires.
  Future<OtpToken> fetchToken() async {
    try {
      // Establishing the session is several requests long, so the whole
      // operation gets one budget instead of only per-request timeouts.
      return await HttpTimeout.request(
        _fetchToken(),
        timeout: HttpTimeout.composed,
        message: '动态口令加载超时，请稍后重试',
      );
    } on OtpTokenException {
      rethrow;
    } on TimeoutException {
      throw const OtpTokenException(
        OtpTokenException.timeout,
        '动态口令加载超时，请稍后重试',
      );
    }
  }

  Future<OtpToken> _fetchToken() async {
    try {
      await _prepareContext();
      final probe = await _probe();
      if (probe.token != null) return probe.token!;
      // Establishing ends on the token page itself, so its body is usually the
      // first code read and no extra request is needed.
      final established = await _establishSession(probe.state);
      final token = _tokenFrom(established) ?? (await _probe()).token;
      if (token == null) {
        throw const OtpTokenException(
          'tokenUnavailable',
          '未能读取动态口令，请稍后重试',
        );
      }
      return token;
    } on OtpTokenException {
      rethrow;
    } on TimeoutException {
      throw const OtpTokenException(
        OtpTokenException.timeout,
        '网络请求超时，请稍后重试',
      );
    } on SocketException {
      throw const OtpTokenException(
        OtpTokenException.networkError,
        '网络连接失败，请检查网络后重试',
      );
    } on HandshakeException {
      throw const OtpTokenException(
        OtpTokenException.networkError,
        '安全连接建立失败，请稍后重试',
      );
    }
  }

  /// Loads the cookies shared with the rest of the app.
  ///
  /// Both steps are idempotent and retried while they have nothing: the user
  /// can log in, or restore WebVPN, while this page is open.
  Future<void> _prepareContext() async {
    if (!_ssoAdopted) {
      _ssoAdopted = await _adoptSsoCookies();
    }
    if (OtpUrlResolver.usesWebVpn && _portalWebVpnToken == null) {
      final portal = Uri.parse(WebVpnUrls.portal);
      final portalCookies = await _cookieJar.getCookies(domain: portal);
      for (final cookie in portalCookies) {
        if (cookie.name == 'webvpn-token' && cookie.value.isNotEmpty) {
          _portalWebVpnToken = cookie.value;
        }
      }
    }
  }

  /// Seeds the request cookies with the campus single sign-on session.
  ///
  /// The stored scope is preserved, so a cookie the identity host issued for
  /// `shu.edu.cn` also reaches the token host, exactly like a browser.
  /// Returns true when a session was actually adopted.
  Future<bool> _adoptSsoCookies() async {
    final ssoUri = Uri.parse(WeComConstants.ssoBase);
    final direct = await _cookieJar.getCookies(domain: ssoUri);
    var adopted = 0;
    for (final cookie in direct) {
      if (cookie.name != WeComConstants.sessionCookieName ||
          cookie.value.isEmpty) {
        continue;
      }
      _cookies.save(ssoUri, [
        Cookie(cookie.name, cookie.value)
          ..domain = cookie.domain.isEmpty ? ssoUri.host : cookie.domain
          ..path = cookie.path.isEmpty ? '/' : cookie.path,
      ]);
      adopted++;
    }
    if (adopted > 0) return true;

    // `WebVpnSessionStore` also clears `SHU_OAUTH2` from the gateway's identity
    // host, because a WebVPN login can leave the session there. Its value is a
    // newsso session all the same, so it is reused against the direct host.
    final proxied = await _cookieJar.getCookies(domain: _webVpnSsoHost);
    for (final cookie in proxied) {
      if (cookie.name != WeComConstants.sessionCookieName ||
          cookie.value.isEmpty) {
        continue;
      }
      _cookies.save(ssoUri, [
        Cookie(cookie.name, cookie.value)..domain = ssoUri.host,
      ]);
      adopted++;
    }
    return adopted > 0;
  }

  /// Warms up `state`, authorizes, and completes the token session.
  ///
  /// [knownState] comes from the probe request that already received the
  /// warm-up redirect, so the entry page is not fetched twice. Returns the page
  /// the session landed on, which already contains the code.
  Future<_OtpResponse> _establishSession(String? knownState) async {
    _debug('establish begin');
    var state = knownState;
    if (state == null) {
      final bootstrap = await _send(OtpUrlResolver.baseUri);
      state = _stateFrom(bootstrap);
      if (state == null) {
        throw OtpTokenException(
          'bootstrapFailed',
          '未能从动态口令站点取得登录状态',
          statusCode: bootstrap.statusCode,
        );
      }
    }

    final authorizeUri = Uri.parse(WeComConstants.ssoBase).replace(
      path: WeComConstants.authorizePath,
      queryParameters: {
        'response_type': 'code',
        'client_id': OtpUrlResolver.clientId,
        'redirect_uri': OtpUrlResolver.redirectUri,
        'scope': OtpUrlResolver.scope,
        'state': state,
      },
    );
    final authorize = await _send(authorizeUri);
    final location = authorize.headers.value(HttpHeaders.locationHeader);
    if (authorize.statusCode < 300 ||
        authorize.statusCode >= 400 ||
        location == null) {
      throw OtpTokenException(
        'authorizeFailed',
        '统一认证未返回动态口令授权地址（HTTP ${authorize.statusCode}）',
        statusCode: authorize.statusCode,
      );
    }
    if (location.contains(WeComConstants.loginPathMarker)) {
      throw const OtpTokenException(
        OtpTokenException.sessionNotReused,
        '校园登录状态已失效，请重新登录后重试',
      );
    }

    // The identity service answers with the registered direct callback even
    // when WebVPN is on; the code is then redeemed through the transport the
    // rest of the app uses.
    final callbackUri = authorizeUri.resolve(location);
    _validateCallback(callbackUri);

    var result = await _follow(_serviceUri(callbackUri));
    if (!_isSessionEstablished(result)) {
      result = await _follow(OtpUrlResolver.landingUri);
    }
    if (!_isSessionEstablished(result)) {
      throw const OtpTokenException(
        'callbackFailed',
        '动态口令登录未完成，请稍后重试',
      );
    }
    _debug('establish ok');
    return result;
  }

  /// Reads the token page once.
  ///
  /// A page without the code node means the token session has to be
  /// established; the redirect that carries the `state` for that exchange is
  /// returned alongside so it can be reused.
  Future<({OtpToken? token, String? state})> _probe() async {
    final response = await _send(OtpUrlResolver.baseUri);
    final token = _tokenFrom(response);
    if (token != null) return (token: token, state: null);
    _debug('probe status=${response.statusCode} (session not established)');
    return (token: null, state: _stateFrom(response));
  }

  /// Reads a code out of [response], or null when the page is not the token
  /// page (its login guide has no code node).
  OtpToken? _tokenFrom(_OtpResponse response) {
    if (response.statusCode != HttpStatus.ok) return null;
    return OtpTokenParser.parse(
      response.body,
      refreshHeader: response.headers.value('refresh'),
    );
  }

  Uri _serviceUri(Uri direct) => OtpUrlResolver.mapServiceUri(direct);

  bool _isSessionEstablished(_OtpResponse response) =>
      response.finalUri.toString().contains(_landingMarker) ||
      response.body.contains(_accountMarker);

  String? _stateFrom(_OtpResponse response) {
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    final state = Uri.tryParse(location)?.queryParameters['state'];
    return state == null || state.isEmpty ? null : state;
  }

  void _validateCallback(Uri uri) {
    // The registered redirect ends in `//Callback.aspx`, but the school side
    // may normalize the doubled slash, so match on the trailing path instead
    // of on exact equality. The host and code checks still block any other
    // target the identity service could return.
    if (uri.scheme != 'https' ||
        uri.host != Uri.parse(OtpUrlResolver.redirectUri).host ||
        !uri.path.endsWith('/Callback.aspx') ||
        uri.queryParameters['code']?.isNotEmpty != true) {
      throw const OtpTokenException(
        'unexpectedCallback',
        '统一认证返回了未预期的动态口令回调地址',
      );
    }
  }

  /// Follows 302 responses and `Refresh: 0;url=...` headers until a body
  /// arrives. The token callback only uses the latter, which `HttpClient`
  /// would otherwise ignore.
  Future<_OtpResponse> _follow(Uri uri) async {
    var current = uri;
    for (var hop = 0; hop < _maxRedirects; hop++) {
      final response = await _send(current);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) return response;
        current = _followTarget(current.resolve(location));
        continue;
      }
      final target = _refreshTarget(response.headers.value('refresh'), current);
      if (target != null) {
        current = _followTarget(target);
        continue;
      }
      return response;
    }
    throw const OtpTokenException('tooManyRedirects', '动态口令站点跳转次数过多');
  }

  /// Keeps every followed hop on the token host.
  ///
  /// A direct URL that the school returns while WebVPN is on is mapped onto the
  /// gateway, the way the booking client rewrites its redirects; any other host
  /// is rejected instead of being followed with the session cookies attached.
  Uri _followTarget(Uri uri) {
    final tokenHost = OtpUrlResolver.host;
    if (uri.host == tokenHost) return uri;
    final mapped = OtpUrlResolver.mapServiceUri(uri);
    if (mapped.host != tokenHost) {
      throw const OtpTokenException(
        'unexpectedRedirect',
        '动态口令站点跳转到了未预期的地址',
      );
    }
    return mapped;
  }

  /// Extracts the target of a `Refresh: 0;url=<target>` header.
  ///
  /// A bare `Refresh: 30` is the login guide's countdown, not a redirect, so
  /// only values carrying a `url=` are followed.
  Uri? _refreshTarget(String? header, Uri base) {
    if (header == null) return null;
    final match = RegExp(r'url\s*=\s*(.+)$', caseSensitive: false)
        .firstMatch(header.trim());
    final value =
        match?.group(1)?.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    if (value == null || value.isEmpty) return null;
    final resolved = base.resolve(value);
    // The callback lives under the registered `//Callback.aspx` path, so a
    // relative target inherits the doubled slash; collapse it to the single
    // slash the landing page actually answers on.
    if (!resolved.path.startsWith('//')) return resolved;
    return resolved.replace(
      path: resolved.path.replaceFirst(RegExp(r'^/+'), '/'),
    );
  }

  /// Sends one request, sharing the cookie container and never following
  /// redirects implicitly so each hop can be inspected.
  Future<_OtpResponse> _send(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(HttpTimeout.connect);
    request.followRedirects = false;
    request.headers
      ..set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      )
      ..set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9')
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
    // The identity service expects the same same-origin headers the campus
    // login flow uses; other hosts are requested as plain navigations.
    if (uri.host == _ssoHost) {
      request.headers
        ..set(HttpHeaders.refererHeader, WeComConstants.ssoBase)
        ..set('Origin', WeComConstants.ssoBase);
    }
    final cookieHeader = _cookieHeaderFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    final response = await request.close().timeout(HttpTimeout.normal);
    final cookies = _parseCookies(response);
    _cookies.save(uri, cookies);
    final location = response.headers.value(HttpHeaders.locationHeader);
    final body = await utf8.decodeStream(response).timeout(HttpTimeout.normal);
    _debug('response ${uri.host}${uri.path} status=${response.statusCode} '
        'cookies=${cookies.map((cookie) => cookie.name).toList()}');
    // The gateway answers a rejected token with a jump to its own portal; that
    // is a recoverable state, so it gets its own error instead of being read as
    // a missing token page.
    if (OtpUrlResolver.usesWebVpn &&
        location != null &&
        uri.resolve(location).host == _portalHost) {
      // Drop the cached gateway token so the next attempt picks up a session
      // the account manager may have restored in the meantime.
      _portalWebVpnToken = null;
      throw const OtpTokenException(
        OtpTokenException.webVpnLoginRequired,
        'WebVPN登录已失效，请在账号管理中恢复后重试',
      );
    }
    return _OtpResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      finalUri: uri,
      body: body,
    );
  }

  /// Cookies for [uri], with the gateway token of the portal host attached to
  /// proxied hosts, the way the classroom module sends it.
  String _cookieHeaderFor(Uri uri) {
    final scoped = _cookies.headerFor(uri);
    final token = _portalWebVpnToken;
    if (!OtpUrlResolver.usesWebVpn ||
        token == null ||
        token.isEmpty ||
        uri.host != OtpUrlResolver.webVpnHost) {
      return scoped;
    }
    final hasGatewayToken = scoped
        .split(';')
        .any((part) => part.trimLeft().startsWith('webvpn-token='));
    if (hasGatewayToken) return scoped;
    return 'webvpn-token=$token${scoped.isEmpty ? '' : '; $scoped'}';
  }

  /// Leniently parses `Set-Cookie`; entries that violate RFC 6265 are skipped
  /// rather than failing the whole response.
  static List<Cookie> _parseCookies(HttpClientResponse response) {
    final values = response.headers[HttpHeaders.setCookieHeader];
    if (values == null) return const [];
    final cookies = <Cookie>[];
    for (final value in values) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } on FormatException {
        _debug('skip malformed set-cookie');
      }
    }
    return cookies;
  }

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[SHU_OTP] $message');
  }
}

class _OtpResponse {
  const _OtpResponse({
    required this.statusCode,
    required this.headers,
    required this.finalUri,
    required this.body,
  });

  final int statusCode;
  final HttpHeaders headers;
  final Uri finalUri;
  final String body;
}
