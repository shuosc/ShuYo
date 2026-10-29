import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/client_user_agent.dart';
import '../../core/vod_constants.dart';
import '../../core/vod_url_resolver.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'session_cookie_jar.dart';
import 'shu_sso_session_store.dart';
import 'vod_auth_exception.dart';

class VodNativeSession {
  const VodNativeSession({required this.jwtToken, this.cookies = const []});

  final String jwtToken;
  final List<SessionCookie> cookies;
}

/// Exchanges ShuYo's existing newsso session for the VOD business session.
/// The server creates all state and tickets; no login form or WebView is used.
class VodNativeSessionService {
  VodNativeSessionService({
    http.Client? client,
    ShuSsoSessionStore? ssoSessionStore,
    SessionCookieJar? cookieJar,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _cookieJar = cookieJar ?? SessionCookieJar.shared,
        _ssoSessionStore = ssoSessionStore ??
            ShuSsoSessionStore(cookieJar: cookieJar ?? SessionCookieJar.shared);

  final http.Client _client;
  final bool _ownsClient;
  final SessionCookieJar _cookieJar;
  final ShuSsoSessionStore _ssoSessionStore;

  Future<VodNativeSession> authorize({
    required bool useWebVpn,
    required String expectedStudentId,
  }) async {
    if (expectedStudentId.trim().isEmpty) {
      throw const VodCampusAuthRequiredException();
    }
    final identity = await _ssoSessionStore.sessionCookies();
    if (identity.isEmpty) {
      throw const VodCampusAuthRequiredException(ssoExpired: true);
    }
    final cookies = AcademicSessionCookieStore();
    for (final entry in identity) {
      if (entry.domain != 'newsso.shu.edu.cn' ||
          entry.cookie.name != 'SHU_OAUTH2') {
        continue;
      }
      cookies.save(Uri.parse('https://newsso.shu.edu.cn/'), [
        Cookie(entry.cookie.name, entry.cookie.value)
          ..domain = 'newsso.shu.edu.cn'
          ..path = entry.path,
      ]);
    }
    if (cookies.headerFor(Uri.parse('https://newsso.shu.edu.cn/')).isEmpty) {
      throw const VodCampusAuthRequiredException(ssoExpired: true);
    }
    if (useWebVpn) {
      final gateway = Uri.parse('https://webvpn.shu.edu.cn/');
      final stored = await _cookieJar.getCookies(domain: gateway);
      for (final item in stored) {
        if (item.name != 'webvpn-token' || item.value.isEmpty) continue;
        cookies.save(gateway, [
          Cookie(item.name, item.value)
            ..domain = 'webvpn.shu.edu.cn'
            ..path = '/',
        ]);
      }
      if (cookies.headerFor(gateway).isEmpty) {
        throw const VodAuthException('WebVPN 连接已失效，请恢复连接后重试');
      }
    }
    try {
      await _followAuthorization(cookies, useWebVpn);
      await _jsonGet(
          VodUrlResolver.apiUri('/authority/me', useWebVpn: useWebVpn),
          cookies);
      final token = await _jsonGet(
          VodUrlResolver.apiUri('/oauth2/token', useWebVpn: useWebVpn),
          cookies);
      final jwt = token['jwt_token'];
      if (jwt is! String || jwt.isEmpty || jwt.contains(RegExp(r'[\r\n]'))) {
        throw const VodAuthException('录播平台未返回有效的登录凭据，请稍后重试');
      }
      final platformHosts = {
        VodUrlResolver.baseUriFor(useWebVpn: useWebVpn).host,
        useWebVpn ? VodUrlResolver.casWebVpnHost : VodConstants.casHost,
      };
      return VodNativeSession(jwtToken: jwt, cookies: [
        for (final entry in cookies.entries)
          if (platformHosts.contains(entry.domain))
            SessionCookie(
              name: entry.cookie.name,
              value: entry.cookie.value,
              domain: entry.domain,
              path: entry.path,
            ),
      ]);
    } on VodAuthException {
      rethrow;
    } on TimeoutException {
      throw const VodAuthException('连接录播认证服务超时，请稍后重试');
    } on SocketException {
      throw const VodAuthException('暂时无法连接录播认证服务，请检查网络后重试');
    } on http.ClientException {
      throw const VodAuthException('暂时无法连接录播认证服务，请检查网络后重试');
    }
  }

  Future<void> _followAuthorization(
      AcademicSessionCookieStore cookies, bool vpn) async {
    var current = VodUrlResolver.authorizeUri(useWebVpn: vpn);
    for (var count = 0; count < 16; count++) {
      current = _normalize(current, vpn);
      _validate(current, vpn);
      if (_isSsoLogin(current)) {
        throw const VodCampusAuthRequiredException(ssoExpired: true);
      }
      if (VodUrlResolver.isPlatformPage(current, useWebVpn: vpn)) return;
      final response = await _get(current, cookies);
      if (_isIdentity(current) && response.statusCode == 401) {
        throw const VodCampusAuthRequiredException(ssoExpired: true);
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw const VodAuthException('录播认证跳转不完整，请稍后重试');
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode >= 500) {
        throw VodAuthException(
            '校方录播认证服务暂时异常（HTTP ${response.statusCode}），请稍后重试');
      }
      if (_isIdentity(current) &&
          response.statusCode == 200 &&
          RegExp(r'/oauth2/login/|action=["\x27][^"\x27]*/login',
                  caseSensitive: false)
              .hasMatch(response.body)) {
        throw const VodCampusAuthRequiredException(ssoExpired: true);
      }
      throw const VodAuthException('录播平台授权尚未完成，请稍后重试');
    }
    throw const VodAuthException('录播认证跳转次数过多，请稍后重试');
  }

  Uri _normalize(Uri uri, bool vpn) {
    if (const {
          'newsso.shu.edu.cn',
          'oauth.shu.edu.cn',
          'https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn',
          'https-oauth-shu-edu-cn-443.webvpn.shu.edu.cn',
        }.contains(uri.host) &&
        (uri.path.startsWith('/oauth/') || uri.path.startsWith('/oauth2/'))) {
      uri = uri.replace(scheme: 'https', host: 'newsso.shu.edu.cn');
      if (vpn) {
        uri = uri.replace(
          query: uri.query.split('&').map((part) {
            final parameter = Uri.splitQueryString(part);
            final value = parameter['redirect_uri'];
            if (value == null) return part;
            final callback = Uri.tryParse(value);
            if (callback == null ||
                callback.scheme != 'https' ||
                callback.userInfo.isNotEmpty ||
                callback.host != VodUrlResolver.casWebVpnHost ||
                callback.port != 443 ||
                !VodConstants.isCasCallbackPath(callback.path)) {
              return part;
            }
            return 'redirect_uri=${Uri.encodeQueryComponent(callback.replace(host: VodConstants.casHost).toString())}';
          }).join('&'),
        );
      }
    }
    return VodUrlResolver.mapServiceUri(uri, useWebVpn: vpn);
  }

  bool _isIdentity(Uri uri) =>
      uri.host == 'newsso.shu.edu.cn' || uri.host == 'oauth.shu.edu.cn';

  bool _isSsoLogin(Uri uri) =>
      _isIdentity(uri) &&
      (uri.path == '/login' ||
          uri.path == '/login/' ||
          uri.path.startsWith('/oauth2/login/'));

  void _validate(Uri uri, bool vpn) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      throw const VodAuthException('录播认证返回了不支持的跳转地址');
    }
    if (_isIdentity(uri) &&
        (uri.path.startsWith('/oauth/') ||
            uri.path.startsWith('/oauth2/') ||
            uri.path == '/login' ||
            uri.path == '/login/')) {
      return;
    }
    final host = VodUrlResolver.baseUriFor(useWebVpn: vpn).host;
    if (uri.host == host &&
        (uri.path == VodConstants.apiPath ||
            uri.path.startsWith('${VodConstants.apiPath}/') ||
            uri.path == '/cloud-rbac' ||
            uri.path.startsWith('/cloud-rbac/') ||
            VodUrlResolver.isPlatformPage(uri, useWebVpn: vpn))) {
      return;
    }
    final cas = vpn ? VodUrlResolver.casWebVpnHost : VodConstants.casHost;
    if (uri.host == cas &&
        (uri.path == VodConstants.casLoginPath ||
            VodConstants.isCasCallbackPath(uri.path))) {
      return;
    }
    if (uri.host == 'webvpn.shu.edu.cn') {
      throw const VodAuthException('WebVPN 连接已失效，请恢复连接后重试');
    }
    throw const VodAuthException('录播认证返回了不支持的跳转地址');
  }

  Future<http.Response> _get(
      Uri uri, AcademicSessionCookieStore cookies) async {
    final header = cookies.headerFor(uri);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'application/json, text/plain, */*',
        'User-Agent': ClientUserAgent.mobileBrowser,
        if (header.isNotEmpty) 'Cookie': header,
      });
    final response = await HttpTimeout.request(http.Response.fromStream(
        await HttpTimeout.request(_client.send(request))));
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      // Some deployments send `httponly` and `secure` as separate malformed
      // Set-Cookie headers. package:http joins all headers with commas, so
      // separate those standalone flags as well as new name=value cookies.
      // The lookahead keeps the comma inside an Expires date intact.
      final separator = RegExp(
        r',(?=\s*(?:[^=;,\s]+\s*=|(?:httponly|secure)\s*(?:,|$)))',
        caseSensitive: false,
      );
      for (final value in setCookie.split(separator)) {
        final item = value.trim();
        if (RegExp(r'^[,\s]*$').hasMatch(item) ||
            RegExp(r'^(?:httponly|secure)(?:\s*,\s*)*$', caseSensitive: false)
                .hasMatch(item)) {
          continue;
        }
        try {
          final cookie = Cookie.fromSetCookieValue(_repairSameSite(item));
          // These services require no cross-host business cookies. Keep each
          // issued value on its actual response host even if Domain is broad.
          cookie.domain = uri.host;
          cookies.save(uri, [cookie]);
        } on FormatException {
          throw const VodAuthException('录播认证会话信息不完整，请稍后重试');
        } on HttpException {
          throw const VodAuthException('录播认证会话信息不完整，请稍后重试');
        }
      }
    }
    return response;
  }

  String _repairSameSite(String value) {
    // The platform sometimes returns malformed SameSite attributes, including
    // without a valid duplicate. Browsers ignore those attributes, whereas
    // dart:io rejects the cookie. Keep valid attributes and all other fields.
    final parts = value.split(';');
    final valid =
        RegExp(r'^samesite\s*=\s*(lax|strict|none)\s*$', caseSensitive: false);
    final attribute = RegExp(r'^samesite(?:\s*=|\s*$)', caseSensitive: false);
    return [
      parts.first,
      for (final part in parts.skip(1))
        if (!attribute.hasMatch(part.trim()) || valid.hasMatch(part.trim()))
          part,
    ].join(';');
  }

  Future<Map<String, dynamic>> _jsonGet(
      Uri uri, AcademicSessionCookieStore cookies) async {
    final response = await _get(uri, cookies);
    if (response.statusCode != 200) {
      throw VodAuthException('录播平台登录兑换失败（HTTP ${response.statusCode}），请稍后重试');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on Object {
      throw const VodAuthException('录播平台登录响应不完整，请稍后重试');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['status']?.toString() != '200' ||
        !const [null, '0', '200'].contains(decoded['code']?.toString())) {
      throw const VodAuthException('录播平台登录兑换未完成，请稍后重试');
    }
    final result = decoded['result'] ?? decoded;
    if (result is! Map<String, dynamic>) {
      throw const VodAuthException('录播平台登录响应不完整，请稍后重试');
    }
    return result;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
