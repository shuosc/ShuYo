import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../../core/academic_url_resolver.dart';
import '../../core/client_user_agent.dart';
import 'academic_auth_service.dart';
import 'academic_account_store.dart';
import 'http_timeout.dart';
import 'session_cookie_jar.dart';
import 'webvpn_device_id.dart';
import 'webvpn_session_store.dart';

enum AcademicVerificationMethod { wecom, sms }

enum _NativeAuthTarget { academic, webVpn, there }

class AcademicLoginChallenge {
  const AcademicLoginChallenge({required this.methods});
  final Map<AcademicVerificationMethod, String> methods;
}

class AcademicLoginResult {
  const AcademicLoginResult({this.challenge, this.callbackUri});

  final AcademicLoginChallenge? challenge;
  final Uri? callbackUri;
}

class AcademicNativeAuthException implements Exception {
  const AcademicNativeAuthException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}

class AcademicPasswordEncryptor {
  const AcademicPasswordEncryptor._();

  static const _rsaModulusHex =
      'e5fda0a0465f5fff838df4c7b0a159d5e7c38b394d802c18b614a739c88b1f4a'
      '98af2b17bb03a162b498c7bdadd6a4cee0bd53a29cc7a1a7a89fd9434891b68d'
      'fa99567f9230a84571b0d6697a2c5ce06b1b63d757124dd6b518f0192c832f24'
      'b3104487fe4a49568c4eee28d162a53eda8491c1304d78f3a4d47f8b450a2481';

  static String encrypt(String password) {
    final publicKey = RSAPublicKey(
      BigInt.parse(_rsaModulusHex, radix: 16),
      BigInt.from(65537),
    );
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    final encrypted = cipher.process(Uint8List.fromList(utf8.encode(password)));
    return base64Encode(encrypted);
  }
}

class AcademicNativeAuthService {
  AcademicNativeAuthService({HttpClient? httpClient})
      : _target = _NativeAuthTarget.academic,
        _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = HttpTimeout.connect;
  }

  AcademicNativeAuthService.forWebVpn({
    HttpClient? httpClient,
  })  : _target = _NativeAuthTarget.webVpn,
        _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = HttpTimeout.connect;
  }

  AcademicNativeAuthService.forThere({HttpClient? httpClient})
      : _target = _NativeAuthTarget.there,
        _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = HttpTimeout.connect;
  }

  static const _newssoPathMarker = '/oauth2/login/';
  static const _tenantId = '上海大学';
  static const _maxRedirects = 16;
  static Uri get _academicEntry => AcademicUrlResolver.entryUri;
  static const _webVpnPortal = 'https://webvpn.shu.edu.cn';
  static const _webVpnHost = 'webvpn.shu.edu.cn';
  static const _thereEntry = 'https://there.shu.edu.cn/login?from=web';
  final _NativeAuthTarget _target;
  final HttpClient _client;
  final AcademicSessionCookieStore _cookieStore = AcademicSessionCookieStore();

  Uri? _loginUri;
  String? _params;
  String? _username;
  String? _encryptedPassword;
  // The WebVPN challenge identifier the authorization code belongs to, kept
  // between `auth/start` and the callback that has to finish the handshake.
  String? _webVpnExternalId;

  void dispose() => _client.close(force: true);

  List<({Cookie cookie, String domain, String path})> get sessionCookies =>
      _cookieStore.entries;

  /// Reads only cookies collected by this login attempt, without publishing
  /// them to the app's campus session.
  String cookieHeaderFor(Uri uri) => _cookieStore.headerFor(uri);

  /// 把外部登录流程（如企业微信扫码）取得的会话 Cookie 并入本次认证会话。
  ///
  /// 企业微信扫码走的是独立的 `WeComAuthService`，不会经过本类的
  /// [login] 流程，因此 [_cookieStore] 是空的。必须在
  /// [completeLogin] 之前把外部流程收集到的 Cookie 交给本类，
  /// 否则加载 callbackUri 时会因缺少会话而被重定向回登录页。
  void adoptSessionCookies(
    Iterable<({Cookie cookie, String domain, String path})> cookies,
  ) {
    for (final entry in cookies) {
      if (entry.cookie.name.isEmpty || entry.cookie.value.isEmpty) continue;
      final scoped = Cookie(entry.cookie.name, entry.cookie.value)
        ..domain = entry.domain
        ..path = entry.path;
      _cookieStore.save(Uri.parse('https://${entry.domain}'), [scoped]);
    }
    if (kDebugMode) {
      debugPrint(
        '[SHU_AUTH] adopted session cookies '
        'names=${cookies.map((entry) => entry.cookie.name).toList()..sort()}',
      );
    }
  }

  /// Clears the business session that a new login replaces.
  ///
  /// Every campus login starts from the same clean state as an explicit logout:
  /// an expired root-path `JSESSIONID` must not survive into the new session,
  /// and a stale WebVPN token must not masquerade as the one the gateway is
  /// about to issue.
  Future<void> resetPreviousSession() async {
    if (_target == _NativeAuthTarget.academic) {
      await AcademicAuthService().clearAccount(
        sessionExpired: await AcademicAccountStore().isSessionExpired(),
      );
      return;
    }
    if (_target == _NativeAuthTarget.webVpn) {
      await WebVpnSessionStore().clearCachedCookiesForReauthentication();
      await _clearWebVpnAuthCookies();
    }
  }

  /// Publishes the cookies this login collected to the shared jar.
  ///
  /// The API clients read that jar rather than this instance, so a completed
  /// login has to hand its session over before anything else uses it.
  Future<void> publishSessionCookies() async {
    final published = <String>[];
    for (final stored in _cookieStore.entries) {
      final cookie = stored.cookie;
      if (cookie.value.isEmpty) continue;
      published.add('${cookie.name}@${stored.domain}${stored.path}');
      await SessionCookieJar.shared.setCookie(
        SessionCookie(
          name: cookie.name,
          value: cookie.value,
          domain: stored.domain,
          path: stored.path,
        ),
      );
    }
    if (kDebugMode) {
      published.sort();
      debugPrint('[SHU_AUTH] published session cookies $published');
    }
  }

  /// Removes the WebVPN and identity cookies left on the gateway hosts, so a
  /// rejected login cannot be mistaken for a live session.
  Future<void> _clearWebVpnAuthCookies() async {
    final domains = <Uri>[
      Uri.parse(_webVpnPortal),
      Uri.parse('https://oauth.shu.edu.cn'),
      Uri.parse('https://https-oauth-shu-edu-cn-443.webvpn.shu.edu.cn'),
      Uri.parse('https://https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn'),
    ];
    for (final domain in domains) {
      try {
        final cookies = await SessionCookieJar.shared.getCookies(
          domain: domain,
        );
        for (final cookie in cookies) {
          if (cookie.name != 'webvpn-token' && cookie.name != 'SHU_OAUTH2') {
            continue;
          }
          await SessionCookieJar.shared.setCookie(
            SessionCookie(
              name: cookie.name,
              value: '',
              domain: cookie.domain.isEmpty ? domain.host : cookie.domain,
              path: cookie.path.isEmpty ? '/' : cookie.path,
            ),
          );
        }
      } on Object {
        // Fresh cookies collected by the native flow replace these afterwards.
      }
    }
  }

  Future<AcademicLoginResult> login({
    required String username,
    required String password,
  }) {
    return _runAuthenticationStage(
      'credentials',
      HttpTimeout.authentication,
      () => _login(username: username, password: password),
    );
  }

  Future<AcademicLoginResult> _login({
    required String username,
    required String password,
  }) async {
    _clearChallenge();
    final loginUri = await _discoverLoginUri();
    if (isAuthorizedCallback(loginUri)) {
      // 复用仍然有效的 SSO 会话，授权码已就绪，无需再提交凭据。
      _validateUri(loginUri);
      return AcademicLoginResult(callbackUri: loginUri);
    }
    final params = _extractParams(loginUri);
    final encryptedPassword = AcademicPasswordEncryptor.encrypt(password);
    final response = await _jsonRequest(
      'POST',
      loginUri.resolve('/oauth/userLogin'),
      body: {
        'username': username,
        'password': encryptedPassword,
        'tenantId': _tenantId,
        'params': params,
      },
      referer: loginUri,
    );
    _requireSuccess(response);

    if (response['twoStepRequired'] == true) {
      _loginUri = loginUri;
      _params = params;
      _username = username;
      _encryptedPassword = encryptedPassword;
      final rawMethods = response['twoStepMethods'];
      final methods = <AcademicVerificationMethod, String>{};
      if (rawMethods is Map) {
        for (final entry in rawMethods.entries) {
          final method = _methodFromWire(entry.key.toString());
          if (method != null) methods[method] = entry.value?.toString() ?? '';
        }
      }
      if (methods.isEmpty) {
        throw const AcademicNativeAuthException(
          'noTwoStepMethod',
          '学校未返回可用的验证方式',
        );
      }
      return AcademicLoginResult(
        challenge: AcademicLoginChallenge(methods: methods),
      );
    }

    final redirect = response['redirectUri']?.toString();
    if (redirect == null || redirect.isEmpty) {
      throw const AcademicNativeAuthException(
        'missingRedirect',
        '登录成功，但学校未返回授权地址',
      );
    }
    final callbackUri = canonicalSsoUri(loginUri.resolve(redirect));
    _validateUri(callbackUri);
    _clearChallenge();
    return AcademicLoginResult(callbackUri: callbackUri);
  }

  Future<void> sendCode(AcademicVerificationMethod method) {
    return _runAuthenticationStage(
      'send-code',
      HttpTimeout.normal,
      () => _sendCode(method),
    );
  }

  Future<void> _sendCode(AcademicVerificationMethod method) async {
    final loginUri = _requireChallenge();
    final response = await _jsonRequest(
      'POST',
      loginUri.resolve('/oauth/twoStep/send'),
      body: {'method': method.name},
      referer: loginUri,
    );
    _requireSuccess(response);
  }

  Future<Uri> verifyCode({
    required AcademicVerificationMethod method,
    required String code,
  }) {
    return _runAuthenticationStage(
      'verify-code',
      HttpTimeout.normal,
      () => _verifyCode(method: method, code: code),
    );
  }

  Future<Uri> _verifyCode({
    required AcademicVerificationMethod method,
    required String code,
  }) async {
    final loginUri = _requireChallenge();
    final response = await _jsonRequest(
      'POST',
      loginUri.resolve('/oauth/twoStep/verify'),
      body: {
        'username': _username,
        'password': _encryptedPassword,
        'tenantId': _tenantId,
        'params': _params,
        'code': code,
        'method': method.name,
      },
      referer: loginUri,
    );
    _requireSuccess(response);
    final redirect = response['redirectUri']?.toString();
    if (redirect == null || redirect.isEmpty) {
      throw const AcademicNativeAuthException(
        'missingRedirect',
        '验证成功，但学校未返回授权地址',
      );
    }
    final callbackUri = canonicalSsoUri(loginUri.resolve(redirect));
    _validateUri(callbackUri);
    _clearChallenge();
    return callbackUri;
  }

  /// Completes a login by following its OAuth callback over HTTP.
  ///
  /// A hidden WebView used to load [callbackUri] only so the platform cookie
  /// store received its `Set-Cookie` headers. Following the redirect chain
  /// reaches the same session, because no step of the exchange depends on page
  /// script. The collected cookies are published to the shared jar unless this
  /// is a one-time data deletion verification.
  Future<void> completeLogin(Uri callbackUri, {bool publish = true}) {
    return _runAuthenticationStage(
      'complete-login',
      HttpTimeout.oauthCompletion,
      () => _completeLogin(callbackUri, publish: publish),
    );
  }

  Future<void> _completeLogin(Uri callbackUri, {required bool publish}) async {
    switch (_target) {
      case _NativeAuthTarget.academic:
        await _completeAcademicLogin(callbackUri);
      case _NativeAuthTarget.there:
        // The booking service exchanges its own code, so its callback never
        // reaches the shared jar: see ThereBookingClient.completeOAuth.
        throw const AcademicNativeAuthException(
          'unsupportedTarget',
          '图书馆预约需要使用专属登录流程',
        );
      case _NativeAuthTarget.webVpn:
        await _completeWebVpnLogin(callbackUri);
    }
    if (publish) await publishSessionCookies();
  }

  /// Follows the jwxt callback until it reaches a page only a live session can
  /// serve.
  Future<void> _completeAcademicLogin(Uri callbackUri) async {
    var current = callbackUri;
    var ticketReloaded = false;
    for (var redirects = 0; redirects < _maxRedirects; redirects++) {
      final response = await _request('GET', current);
      final next = _redirectTarget(response, current);
      await response.drain<void>().timeout(HttpTimeout.normal);
      if (next != null) {
        current = next;
        continue;
      }
      if (!ticketReloaded &&
          AcademicUrlResolver.isTicketLoginUrl(current.toString())) {
        // The ticket page hands the session over through a page-level
        // redirect, so no `Location` header follows it. Requesting the home
        // page performs the same exchange.
        ticketReloaded = true;
        current = AcademicUrlResolver.homeUri;
        continue;
      }
      if (!AcademicUrlResolver.isAcademicSessionUrl(current.toString())) {
        throw const AcademicNativeAuthException(
          'academicSessionNotEstablished',
          '教务系统登录未完成，请重试',
        );
      }
      return;
    }
    throw const AcademicNativeAuthException(
      'tooManyRedirects',
      '教务系统登录跳转次数过多',
    );
  }

  /// Finishes the WebVPN handshake the callback page used to run.
  ///
  /// `auth/start` issued a challenge whose `code` reaches the callback, but the
  /// gateway only creates the session once `auth/finish` presents that code
  /// together with the device identity the challenge was issued to.
  Future<void> _completeWebVpnLogin(Uri callbackUri) async {
    final externalId = _webVpnExternalId;
    final code = callbackUri.queryParameters['code'];
    final state = callbackUri.queryParameters['state'];
    if (externalId == null ||
        code == null ||
        code.isEmpty ||
        state == null ||
        state.isEmpty) {
      throw const AcademicNativeAuthException(
        'webVpnCallbackMismatch',
        'WebVPN 授权回调校验失败，请重新尝试',
      );
    }
    final portal = Uri.parse(_webVpnPortal);
    final finish = await _jsonRequest(
      'POST',
      portal.resolve('/api/access/auth/finish'),
      body: {
        'externalId': externalId,
        'data': jsonEncode({
          'callbackUrl': portal.resolve('/callback/oauth2').toString(),
          'code': code,
          'deviceId': await WebVpnDeviceId.load(),
          'state': state,
        }),
      },
      referer: portal.resolve('/callback/oauth2'),
    );
    if (finish['code'] != 0) {
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] webvpn auth/finish rejected '
          'code=${finish['code']} message=${finish['message']}',
        );
      }
      throw const AcademicNativeAuthException(
        'webVpnFinishFailed',
        'WebVPN 登录未完成，请重试',
      );
    }
    final info = await _jsonRequest(
      'GET',
      portal.resolve('/api/access/user/info'),
      referer: portal.resolve('/site-nav/'),
    );
    final data = info['data'];
    final userId = data is Map ? data['userId']?.toString() : null;
    if (info['code'] != 0 ||
        userId == null ||
        userId.isEmpty ||
        userId == '0') {
      throw const AcademicNativeAuthException(
        'webVpnUserInfoMissing',
        'WebVPN 未能确认登录身份，请重新尝试',
      );
    }
  }

  Future<Uri> _discoverLoginUri() async {
    if (_target == _NativeAuthTarget.webVpn) {
      return _startWebVpnOAuth();
    }
    var uri = _target == _NativeAuthTarget.there
        ? Uri.parse(_thereEntry)
        : _academicEntry;
    for (var redirects = 0; redirects < _maxRedirects; redirects++) {
      final response = await _request('GET', uri);
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] discover target=${_target.name} '
          'status=${response.statusCode} uri=${uri.host}${uri.path} '
          'location=${location == null ? '-' : _safeLocation(location)}',
        );
      }
      final next = _redirectTarget(response, uri);
      await response.drain<void>().timeout(HttpTimeout.normal);
      if (next == null) {
        if (uri.path.contains(_newssoPathMarker)) {
          return canonicalSsoUri(uri);
        }
        throw const AcademicNativeAuthException(
          'loginPageNotFound',
          '无法取得该服务的统一认证入口',
        );
      }
      if (next.path.contains(_newssoPathMarker)) {
        final directLogin = canonicalSsoUri(next);
        final loginPage = await _request('GET', directLogin);
        final loginRedirect = _redirectTarget(loginPage, directLogin);
        await loginPage.drain<void>().timeout(HttpTimeout.normal);
        return canonicalSsoUri(loginRedirect ?? directLogin);
      }
      uri = next;
    }
    throw const AcademicNativeAuthException(
      'tooManyRedirects',
      '认证入口跳转次数过多',
    );
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    Uri? referer,
  }) async {
    final response = await _request(
      method,
      uri,
      body: body == null ? null : jsonEncode(body),
      referer: referer,
    );
    final text = await utf8.decodeStream(response).timeout(HttpTimeout.normal);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } on Object {
      throw AcademicNativeAuthException(
        'invalidResponse',
        '学校认证服务返回了无法识别的内容（HTTP ${response.statusCode}）',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = json['message']?.toString() ?? 'http${response.statusCode}';
      throw AcademicNativeAuthException(code, messageForCode(code));
    }
    return json;
  }

  Future<Uri> _startWebVpnOAuth() async {
    final portal = Uri.parse(_webVpnPortal);
    final methodsResponse = await _jsonRequest(
      'GET',
      portal.resolve('/api/access/authentication/list?type=Login'),
      referer: portal.resolve('/auth/login'),
    );
    if (methodsResponse['code'] != 0) {
      throw const AcademicNativeAuthException(
        'webVpnAuthMethodsFailed',
        '无法取得 WebVPN 认证方式',
      );
    }
    final data = methodsResponse['data'];
    final list = data is Map ? data['list'] : null;
    Map<dynamic, dynamic>? oauthMethod;
    if (list is List) {
      for (final item in list) {
        if (item is Map && item['authType'] == 5) {
          oauthMethod = item;
          break;
        }
      }
    }
    final externalId = oauthMethod?['externalId']?.toString();
    if (externalId == null || externalId.isEmpty) {
      throw const AcademicNativeAuthException(
        'webVpnOAuthUnavailable',
        'WebVPN 当前未提供上海大学统一认证',
      );
    }
    _webVpnExternalId = externalId;
    final state =
        base64Encode(utf8.encode(jsonEncode({'externalId': externalId})));
    final callbackUrl = portal.resolve('/callback/oauth2').toString();
    final startResponse = await _jsonRequest(
      'POST',
      portal.resolve('/api/access/auth/start'),
      body: {
        'externalId': externalId,
        'data': jsonEncode({
          'callbackUrl': callbackUrl,
          'state': state,
        }),
      },
      referer: portal.resolve('/auth/login'),
    );
    if (startResponse['code'] != 0) {
      throw const AcademicNativeAuthException(
        'webVpnOAuthStartFailed',
        'WebVPN 统一认证启动失败',
      );
    }
    final startData = startResponse['data'];
    final action = startData is Map ? startData['action'] : null;
    final loginUrl = action is Map ? action['login_url']?.toString() : null;
    final rawLoginUri = loginUrl == null ? null : Uri.tryParse(loginUrl);
    final loginUri = rawLoginUri == null ? null : canonicalSsoUri(rawLoginUri);
    if (loginUri == null) {
      throw const AcademicNativeAuthException(
        'webVpnLoginUrlMissing',
        'WebVPN 未返回统一认证地址',
      );
    }
    _validateUri(loginUri);
    // auth/start now returns /oauth/authorize directly. Resolve that request
    // here so the credential flow can still consume the legacy login page
    // when no SSO session exists, while an existing session may finish at the
    // WebVPN callback immediately.
    var current = loginUri;
    for (var redirects = 0; redirects < _maxRedirects; redirects++) {
      final response = await _request('GET', current, referer: portal);
      final next = _redirectTarget(response, current);
      await response.drain<void>().timeout(HttpTimeout.normal);
      if (next == null) return current;
      if (_isWebVpnCallbackUri(next)) return next;
      if (next.path.contains(_newssoPathMarker)) return next;
      current = next;
    }
    throw const AcademicNativeAuthException(
      'tooManyRedirects',
      'WebVPN认证入口跳转次数过多',
    );
  }

  bool _isWebVpnCallbackUri(Uri uri) {
    return uri.host == _webVpnHost &&
        uri.path == '/callback/oauth2' &&
        uri.queryParameters.containsKey('code');
  }

  /// Whether discovery already landed on a business callback carrying an
  /// authorization code.
  ///
  /// A still-valid SSO session makes `authorize` answer with the business
  /// callback instead of the login page. That callback already holds the `code`
  /// the remaining handshake needs and has no login parameters to submit, so
  /// the credential exchange has to be skipped.
  @visibleForTesting
  static bool isAuthorizedCallback(Uri uri) {
    final code = uri.queryParameters['code'];
    return code != null && code.isNotEmpty;
  }

  /// The gateway and some business entries point at a different SSO host.
  /// A host-scoped SHU_OAUTH2 cookie can be reused only on newsso itself.
  @visibleForTesting
  static Uri canonicalSsoUri(Uri uri) {
    const newsso = 'newsso.shu.edu.cn';
    const proxy = 'https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn';
    if ((uri.host == 'oauth.shu.edu.cn' || uri.host == proxy) &&
        (uri.path.startsWith('/oauth/') || uri.path.startsWith('/oauth2/'))) {
      return uri.replace(scheme: 'https', host: newsso);
    }
    return uri;
  }

  Future<HttpClientResponse> _request(
    String method,
    Uri uri, {
    String? body,
    Uri? referer,
  }) async {
    _validateUri(uri);
    if (kDebugMode) {
      debugPrint(
        '[SHU_AUTH] native request-start method=$method '
        'uri=${uri.host}${uri.path}',
      );
    }
    final request = await _client.openUrl(method, uri).timeout(
          HttpTimeout.connect,
        );
    request.followRedirects = false;
    request.headers
        .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
    request.headers
        .set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
    final cookieHeader = _cookieHeader(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    if (referer != null) {
      request.headers.set(HttpHeaders.refererHeader, referer.toString());
      request.headers.set('Origin', '${referer.scheme}://${referer.authority}');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(HttpTimeout.normal);
    } on TimeoutException {
      request.abort(
        TimeoutException('学校认证服务请求超时', HttpTimeout.normal),
      );
      rethrow;
    }
    if (kDebugMode) {
      final setCookieNames = response.cookies
          .map((cookie) => cookie.name)
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      debugPrint(
        '[SHU_AUTH] native response method=$method '
        'status=${response.statusCode} uri=${uri.host}${uri.path} '
        'setCookieNames=$setCookieNames',
      );
    }
    _saveCookies(uri, response.cookies);
    return response;
  }

  Future<T> _runAuthenticationStage<T>(
    String stage,
    Duration timeout,
    Future<T> Function() operation,
  ) async {
    if (kDebugMode) {
      debugPrint(
        '[SHU_AUTH] stage-start target=${_target.name} stage=$stage '
        'timeoutMs=${timeout.inMilliseconds}',
      );
    }
    try {
      final result = await operation().timeout(timeout);
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] stage-complete target=${_target.name} stage=$stage',
        );
      }
      return result;
    } on TimeoutException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] stage-timeout target=${_target.name} stage=$stage '
          'error=$error',
        );
        debugPrintStack(label: '[SHU_AUTH] stack', stackTrace: stackTrace);
      }
      throw const AcademicNativeAuthException(
        'timeout',
        '连接学校认证服务超时，请使用校园网访问',
      );
    } on AcademicNativeAuthException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] stage-rejected target=${_target.name} stage=$stage '
          'code=${error.code}',
        );
        debugPrintStack(label: '[SHU_AUTH] stack', stackTrace: stackTrace);
      }
      rethrow;
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          '[SHU_AUTH] stage-failed target=${_target.name} stage=$stage '
          'type=${error.runtimeType} error=$error',
        );
        debugPrintStack(label: '[SHU_AUTH] stack', stackTrace: stackTrace);
      }
      rethrow;
    }
  }

  Uri? _redirectTarget(HttpClientResponse response, Uri current) {
    if (response.statusCode < 300 || response.statusCode >= 400) return null;
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) return null;
    var next = current.resolve(location);
    // Some direct campus gateways answer the HTTPS entry with a temporary
    // HTTP canonical URL. Browsers immediately upgrade it back to HTTPS;
    // mirror that behavior before the next request while keeping all
    // authentication traffic encrypted.
    if (next.scheme == 'http' && _isShuHost(next.host)) {
      next = next.replace(scheme: 'https');
    }
    _validateUri(next);
    return next;
  }

  String _safeLocation(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return '<invalid>';
    return '${uri.host}${uri.path} '
        'queryKeys=${uri.queryParameters.keys.toList()..sort()}';
  }

  void _saveCookies(Uri source, List<Cookie> cookies) {
    _cookieStore.save(source, cookies);
  }

  String _cookieHeader(Uri uri) => _cookieStore.headerFor(uri);

  String _extractParams(Uri loginUri) {
    final index = loginUri.path.indexOf(_newssoPathMarker);
    if (index < 0) {
      throw const AcademicNativeAuthException('missingParams', '认证地址缺少登录参数');
    }
    final params = loginUri.path.substring(index + _newssoPathMarker.length);
    if (params.isEmpty) {
      throw const AcademicNativeAuthException('missingParams', '认证地址缺少登录参数');
    }
    return params;
  }

  void _requireSuccess(Map<String, dynamic> response) {
    final code = response['message']?.toString();
    if (code != 'success') {
      throw AcademicNativeAuthException(
        code ?? 'unknown',
        messageForCode(code ?? 'unknown'),
      );
    }
  }

  Uri _requireChallenge() {
    final uri = _loginUri;
    if (uri == null ||
        _params == null ||
        _username == null ||
        _encryptedPassword == null) {
      throw const AcademicNativeAuthException(
          'challengeExpired', '登录状态已失效，请重新输入账号密码');
    }
    return uri;
  }

  void _clearChallenge() {
    _loginUri = null;
    _params = null;
    _username = null;
    _encryptedPassword = null;
  }

  AcademicVerificationMethod? _methodFromWire(String value) => switch (value) {
        'wecom' => AcademicVerificationMethod.wecom,
        'sms' => AcademicVerificationMethod.sms,
        _ => null,
      };

  void _validateUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (uri.scheme != 'https' || !_isShuHost(host)) {
      throw const AcademicNativeAuthException(
          'unsafeRedirect', '认证服务返回了非上海大学的跳转地址');
    }
  }

  bool _isShuHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'shu.edu.cn' || normalized.endsWith('.shu.edu.cn');
  }

  @visibleForTesting
  static String messageForCode(String code) => switch (code) {
        'badPassword' => '学号或密码错误',
        'userNotFound' => '未找到该校园账户',
        'invalidCode' => '验证码错误或已失效',
        'userLocked' => '账户已被锁定，请稍后重试',
        'ipLimitExceeded' => '登录请求过于频繁，请稍后重试',
        'sendError' || 'senderror' => '验证码发送过于频繁，请切换验证方式或稍后再试',
        'userNotAllowed' => '该账户暂时无法登录此服务',
        'internalServerError' => '学校认证服务暂时不可用',
        _ => '登录失败，请稍后重试（$code）',
      };
}

class _StoredCookie {
  const _StoredCookie(this.cookie, this.domain, this.path);
  final Cookie cookie;
  final String domain;
  final String path;

  bool matches(Uri uri) {
    final hostMatches = uri.host == domain || uri.host.endsWith('.$domain');
    // Uri.path 对 "https://host" 形式返回空串，但 HTTP 语义上等价于 "/"。
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return hostMatches && requestPath.startsWith(path);
  }
}

/// 认证流程在内存中维护的 Cookie 容器。
///
/// 抽成独立类是为了让「外部流程取得的会话 Cookie 是否正确并入后续请求」
/// 这一行为可以脱离具体服务单独测试。
class AcademicSessionCookieStore {
  final List<_StoredCookie> _cookies = [];

  /// 并入一批 Cookie。空值、已过期的 Cookie 会被丢弃；
  /// 同名同域同路径的旧 Cookie 会被覆盖。
  void save(Uri source, Iterable<Cookie> cookies) {
    for (final cookie in cookies) {
      final domain =
          (cookie.domain?.isNotEmpty == true ? cookie.domain! : source.host)
              .replaceFirst(RegExp(r'^\.'), '');
      final path = cookie.path?.isNotEmpty == true ? cookie.path! : '/';
      _cookies.removeWhere(
        (stored) =>
            stored.cookie.name == cookie.name &&
            stored.domain == domain &&
            stored.path == path,
      );
      if (cookie.value.isNotEmpty &&
          (cookie.expires == null || cookie.expires!.isAfter(DateTime.now()))) {
        _cookies.add(_StoredCookie(cookie, domain, path));
      }
    }
  }

  /// 构造适用于 [uri] 的 `Cookie` 请求头，顺带清理已过期的条目。
  String headerFor(Uri uri) {
    final now = DateTime.now();
    _cookies.removeWhere(
      (stored) => stored.cookie.expires?.isBefore(now) == true,
    );
    return _cookies
        .where((stored) => stored.matches(uri))
        .map((stored) => '${stored.cookie.name}=${stored.cookie.value}')
        .join('; ');
  }

  /// 当前持有的 Cookie 快照，供写入会话 Cookie 罐时使用。
  List<({Cookie cookie, String domain, String path})> get entries => [
        for (final stored in _cookies)
          (cookie: stored.cookie, domain: stored.domain, path: stored.path),
      ];
}
