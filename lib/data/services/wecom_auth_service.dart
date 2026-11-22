import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/client_user_agent.dart';
import '../../core/wecom_constants.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'webvpn_device_id.dart';

/// 企业微信扫码登录过程中的会话信息。
class WeComQrSession {
  const WeComQrSession({
    required this.key,
    required this.confirmUrl,
    required this.wxWorkSchemeUrl,
    required this.state,
  });

  /// 企微扫码会话标识，用于长轮询与确认页地址。
  final String key;

  /// 与二维码绑定的授权上下文，换取 SSO 会话时须原样使用。
  final String state;

  /// 扫码后企微内置浏览器打开的确认页地址。
  final String confirmUrl;

  /// 包装后的 scheme 跳转地址（`wxwork://sso/jump?url=...`），
  /// 在外部浏览器/短信中打开可拉起企业微信。
  final String wxWorkSchemeUrl;
}

/// 长轮询扫码状态。
enum WeComScanStatus {
  /// 尚未扫码。
  waiting,

  /// 已扫码，等待手机确认。
  confirmedPending,

  /// 已确认，取得 auth_code。
  succeeded,

  /// 二维码已过期或已取消。
  expired,
}

/// 扫码长轮询结果。
class WeComScanResult {
  const WeComScanResult._({required this.status, this.authCode});

  const WeComScanResult.waiting() : this._(status: WeComScanStatus.waiting);

  const WeComScanResult.confirmedPending()
      : this._(status: WeComScanStatus.confirmedPending);

  const WeComScanResult.succeeded(String authCode)
      : this._(status: WeComScanStatus.succeeded, authCode: authCode);

  const WeComScanResult.expired() : this._(status: WeComScanStatus.expired);

  final WeComScanStatus status;
  final String? authCode;

  bool get isSuccess => status == WeComScanStatus.succeeded;
}

/// 阶段一的产物：已建立的 SSO 会话。
class WeComSessionResult {
  const WeComSessionResult({
    required this.sessionCookies,
    required this.cookieSourceUri,
    this.redirectUri,
  });

  final List<Cookie> sessionCookies;
  final Uri cookieSourceUri;
  final Uri? redirectUri;
}

/// 一条带作用域的 Cookie，供写入会话 Cookie 罐时使用。
class WeComStoredCookie {
  const WeComStoredCookie({
    required this.cookie,
    required this.domain,
    required this.path,
  });

  final Cookie cookie;
  final String domain;
  final String path;
}

/// 企微扫码登录的最终结果。
///
/// [callbackUri] 是**目标业务系统**的完成地址：普通目标为
/// `authorize` 的 302 callback，WebVPN 则为私有握手完成后的落地页；
/// [sessionCookies] 是本次流程收集到的全部 Cookie，必须写入会话 Cookie 罐，
/// 否则加载 [callbackUri] 时 SSO 会认为未登录并重定向回登录页。
class WeComRedeemResult {
  const WeComRedeemResult({
    required this.callbackUri,
    required this.sessionCookies,
    this.accountName,
  });

  final Uri callbackUri;
  final List<WeComStoredCookie> sessionCookies;
  final String? accountName;
}

/// 企业微信扫码登录错误。
class WeComAuthException implements Exception {
  const WeComAuthException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 企业微信扫码登录服务。
///
/// 采用两阶段设计：
///
/// **阶段一：用企微换 SSO 会话**
/// 1. `GET /wwopen/sso/qrConnect` → HTML 内嵌 `qrImg?key=<key>`，key 为扫码会话标识；
/// 2. 长轮询 `GET /wwopen/sso/l/qrConnect` → JSONP `jsonpCallback({...})`，
///    状态机 `QRCODE_SCAN_NEVER → QRCODE_SCAN_ING → QRCODE_SCAN_SUCC`；
/// 3. `GET /oauth/wecom/qrcode?code=<auth_code>&state=<params>&appid=...`
///    → 302 + `SHU_OAUTH2` 会话 Cookie。
///
/// **阶段二：用 SSO 会话换目标业务系统的授权码**
/// 4. 按目标系统准备 `state`；
/// 5. `GET /oauth/authorize?response_type=code&client_id&redirect_uri&scope&state`
///    → 302 到业务系统的 callback 地址（带 `code`）。
/// 6. WebVPN 作为例外，还会用 code 调用 `auth/finish` 并通过
///    `user/info` 验证会话。
///
/// YJS 从门户发起动态授权，不使用第 4、5 步的静态目标逻辑，而是将
/// 第 3 步的重定向和 Cookie 交回同一次 YJS 登录流程。
class WeComAuthService {
  static const scanTimeout = Duration(seconds: 90);

  WeComAuthService({
    HttpClient? httpClient,
    Future<SharedPreferences> Function()? preferencesLoader,
    Random? random,
  })  : _client = httpClient ?? HttpClient(),
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _random = random ?? Random.secure() {
    _client.connectionTimeout = HttpTimeout.connect;
  }

  final HttpClient _client;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Random _random;
  final AcademicSessionCookieStore _cookies = AcademicSessionCookieStore();
  static final _qrImgKeyPattern = RegExp(r'qrImg\?key=([0-9a-fA-F]+)');
  static final _jsonpPattern = RegExp(r'jsonpCallback\((\{.*?\})\)');

  void dispose() => _client.close(force: true);

  /// Cookies collected for the campus or WebVPN login callback.
  List<WeComStoredCookie> get cookieJar => [
        for (final entry in _cookies.entries)
          WeComStoredCookie(
            cookie: entry.cookie,
            domain: entry.domain,
            path: entry.path,
          ),
      ];

  /// Imports a host-scoped SSO session established by the campus login flow.
  /// Domain matching remains in AcademicSessionCookieStore, so it is only sent
  /// to the original identity host.
  void adoptSessionCookies(
    Iterable<({Cookie cookie, String domain, String path})> cookies,
  ) {
    for (final entry in cookies) {
      final uri = Uri(scheme: 'https', host: entry.domain);
      final cookie = Cookie(entry.cookie.name, entry.cookie.value)
        ..domain = entry.domain
        ..path = entry.path;
      _cookies.save(uri, [cookie]);
    }
  }

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[SHU_WECOM] $message');
  }

  @visibleForTesting
  static String describeUrlForLog(Uri uri) {
    final path = switch (uri.path) {
      '/oauth/authorize' => '/oauth/authorize',
      '/oauth/wecom/qrcode' => '/oauth/wecom/qrcode',
      '/login-oauth2' => '/login-oauth2',
      '/callback/oauth2' => '/callback/oauth2',
      '/sso/shulogin' => '/sso/shulogin',
      '/wwopen/sso/qrConnect' => '/wwopen/sso/qrConnect',
      '/wwopen/sso/l/qrConnect' => '/wwopen/sso/l/qrConnect',
      _ when uri.path.startsWith('/oauth2/login/') => '/oauth2/login/{context}',
      _ when uri.path.startsWith('/gsapp/sys/yjsrzfwapp/oauth_shu/callback/') =>
        '/gsapp/sys/yjsrzfwapp/oauth_shu/callback/{flow}',
      _ => '/{other:${uri.pathSegments.length}}',
    };
    final keys = uri.queryParameters.keys.toList()..sort();
    return '${uri.host}$path queryKeys=$keys';
  }

  /// 编码 OAuth 参数为 base64url 无填充字符串（与 `_extractParams` 格式一致）。
  ///
  /// 注意：必须使用 base64url 无 `=` 填充，否则企微/SSO 返回 `badRequestParams`。
  static String encodeOAuthParams(Map<String, String> params) {
    final json = jsonEncode(params);
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  /// 旧的通用 SSO 换取流程使用本科教务系统的登录上下文。
  ///
  /// 研究生扫码则使用 YJS 当次发起的、由学校生成的登录上下文。
  static String get weComRedeemState =>
      encodeOAuthParams(WeComOAuthTarget.academic.toParams());

  /// 发起企微扫码会话，返回二维码与唤起链接。
  Future<WeComQrSession> startQrSession({String? state}) async {
    _debug('startQrSession begin');
    final redeemState = state ?? weComRedeemState;
    final uri = Uri.parse(WeComConstants.qrConnectBase).replace(
      queryParameters: {
        'appid': WeComConstants.appId,
        'agentid': WeComConstants.agentId,
        'redirect_uri': WeComConstants.redirectUri,
        'state': redeemState,
        'lang': 'zh',
        'version': '1.2.7',
        'login_type': 'jssdk',
      },
    );
    final response = await _get(uri, host: _RequestHost.weCom);
    final body = await utf8.decodeStream(response).timeout(HttpTimeout.normal);
    final match = _qrImgKeyPattern.firstMatch(body);
    if (match == null) {
      _debug('startQrSession no-key bodyLength=${body.length}');
      throw const WeComAuthException(
        'qrcodeKeyNotFound',
        '未能获取企业微信登录二维码，请稍后重试',
      );
    }
    final key = match.group(1)!;
    _debug('startQrSession keyReceived=true');
    final confirmUrl = '${WeComConstants.confirmBase}?k=$key&notretry=yes';
    return WeComQrSession(
      key: key,
      state: redeemState,
      confirmUrl: confirmUrl,
      wxWorkSchemeUrl:
          '${WeComConstants.schemeJumpBase}${Uri.encodeComponent(confirmUrl)}',
    );
  }

  /// 长轮询等待用户扫码确认，直到成功、过期或达到超时时间。
  ///
  /// [onStatusChanged] 会在状态变化时回调（用于界面展示）。
  /// [isCancelled] 返回 true 时提前终止轮询（例如页面被 dispose），
  /// 避免在后台持续发起网络请求。
  Future<WeComScanResult> waitForScan(
    String key, {
    Duration timeout = scanTimeout,
    void Function(WeComScanStatus status)? onStatusChanged,
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    WeComScanStatus lastStatus = WeComScanStatus.waiting;
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) {
        return WeComScanResult.expired();
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return WeComScanResult.expired();
      final result = await _pollOnce(key).timeout(
        remaining,
        onTimeout: () => const WeComScanResult.expired(),
      );
      lastStatus = result.status;
      onStatusChanged?.call(lastStatus);
      if (result.status == WeComScanStatus.succeeded) {
        return result;
      }
      if (result.status == WeComScanStatus.expired) {
        return result;
      }
      final delay = result.status == WeComScanStatus.confirmedPending
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 1);
      final timeLeft = deadline.difference(DateTime.now());
      if (timeLeft <= Duration.zero) return WeComScanResult.expired();
      await Future<void>.delayed(timeLeft < delay ? timeLeft : delay);
    }
    return WeComScanResult.expired();
  }

  /// 阶段一：把企微 `auth_code` 换成 SSO 会话。
  ///
  /// [state] 与生成本次二维码时的值一致。这里只读取重定向，不访问它。
  Future<WeComSessionResult> redeem(String authCode, String state) async {
    _debug('redeem begin');
    final uri =
        Uri.parse('${WeComConstants.ssoBase}/oauth/wecom/qrcode').replace(
      queryParameters: {
        'code': authCode,
        'state': state,
        'appid': WeComConstants.appId,
      },
    );
    final response = await _get(uri, host: _RequestHost.sso);
    final statusCode = response.statusCode;
    final cookies = _parseCookies(response);
    final location = response.headers.value(HttpHeaders.locationHeader);
    // 失败判定：Location 含 message=wecomAuthFailed，或响应体含
    // badRequestParams（缺 appid / state 非 base64url 时都会命中）。
    if (statusCode < 300 ||
        statusCode >= 400 ||
        location?.contains('wecomAuthFailed') == true) {
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(HttpTimeout.normal);
      throw WeComAuthException(
        'redeemFailed',
        text.contains('badRequestParams')
            ? '企业微信授权失败，请重新尝试'
            : '企业微信授权失败（HTTP $statusCode）',
      );
    }
    final parsed = location == null ? null : Uri.tryParse(location);
    final redirect = parsed == null ? null : uri.resolveUri(parsed);
    _debug('redeem ok status=$statusCode '
        'cookies=${cookies.map((c) => c.name).toList()} '
        'location=${redirect == null ? '-' : describeUrlForLog(redirect)}');
    _cookies.save(uri, cookies);
    await response.drain<void>().timeout(HttpTimeout.normal);
    return WeComSessionResult(
      sessionCookies: cookies,
      cookieSourceUri: uri,
      redirectUri: redirect,
    );
  }

  /// 阶段二：用已建立的 SSO 会话向 [target] 换取业务系统授权码回调地址。
  ///
  /// 业务系统提供的 [state] 原样传递并校验；未提供时按目标策略准备。
  /// 请求 `/oauth/authorize` 并返回其 302 的 Location。
  Future<Uri> authorizeTarget(
    WeComOAuthTarget target, {
    String? state,
  }) async {
    if (target.kind == WeComOAuthTargetKind.webVpn) {
      throw const WeComAuthException(
        'webVpnRequiresFinish',
        'WebVPN 需要完成专用授权握手',
      );
    }
    _debug('authorizeTarget begin client=${target.clientName}');
    final expectedState = state ?? await _prepareState(target);
    _debug('authorizeTarget stateLength=${expectedState.length}');
    final uri = Uri.parse(WeComConstants.ssoBase).replace(
      path: WeComConstants.authorizePath,
      queryParameters: {
        'response_type': 'code',
        'client_id': target.clientId,
        'redirect_uri': target.redirectUri,
        if (target.scope.isNotEmpty) 'scope': target.scope,
        if (expectedState.isNotEmpty) 'state': expectedState,
      },
    );
    final response = await _get(uri, host: _RequestHost.sso);
    final statusCode = response.statusCode;
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>();
    if (statusCode < 300 || statusCode >= 400 || location == null) {
      throw WeComAuthException(
        'authorizeFailed',
        'SSO 未返回 ${target.clientName} 的授权地址（HTTP $statusCode）',
      );
    }
    // 会话未被复用时会跳回登录页，说明 SHU_OAUTH2 没有生效。
    if (location.contains(WeComConstants.loginPathMarker)) {
      throw const WeComAuthException(
        'sessionNotReused',
        '企业微信会话未能复用，请重新登录',
      );
    }
    final callbackUri = uri.resolve(location);
    _validateRedirect(callbackUri, target.redirectUri);
    final returnedState = callbackUri.queryParameters['state'];
    if ((state != null || returnedState != null) &&
        (returnedState != expectedState ||
            callbackUri.queryParametersAll['state']?.length != 1)) {
      throw const WeComAuthException(
        'authorizationStateMismatch',
        '统一认证授权状态校验失败',
      );
    }
    if (callbackUri.queryParameters['code']?.isNotEmpty != true) {
      throw const WeComAuthException(
        'authorizationCodeMissing',
        '统一认证未返回可用的授权码',
      );
    }
    _debug('authorizeTarget ok location=${describeUrlForLog(callbackUri)}');
    return callbackUri;
  }

  /// 使用当前企微扫码建立的临时 SSO 会话，独立完成 WebVPN
  /// `auth/start → authorize → auth/finish → user/info` 握手。
  ///
  /// 返回 WebVPN 会话及 newsso 会话，供统一账户复用。
  Future<WeComRedeemResult> completeWebVpnLogin() async {
    final portal = Uri.parse(WeComConstants.webVpnBase);
    final callback = Uri.parse(WeComConstants.webVpnCallback);
    _debug('webvpn begin');

    final methods = await _webVpnJsonRequest(
      'GET',
      portal.resolve('/api/access/authentication/list?type=0'),
      refererPath: '/auth/login',
    );
    final externalId =
        _webVpnExternalId(methods) ?? WeComConstants.webVpnExternalIdFallback;
    final state = webVpnState(externalId);
    final start = await _webVpnJsonRequest(
      'POST',
      portal.resolve('/api/access/auth/start'),
      refererPath: '/auth/login',
      body: {
        'externalId': externalId,
        'data': jsonEncode({
          'callbackUrl': callback.toString(),
          'state': state,
        }),
      },
    );
    if (start['code'] != 0) {
      throw WeComAuthException(
        'webVpnStartFailed',
        _webVpnApiMessage(start, 'WebVPN 企业微信授权启动失败'),
      );
    }
    final startData = start['data'];
    final action = startData is Map ? startData['action'] : null;
    final loginUrl = action is Map ? action['login_url']?.toString() : null;
    if (loginUrl == null || loginUrl.isEmpty) {
      throw const WeComAuthException(
        'webVpnLoginUrlMissing',
        'WebVPN 未返回统一认证地址',
      );
    }
    final authorizeUri = directWebVpnAuthorizeUri(loginUrl);
    _validateWebVpnAuthorizeUri(authorizeUri, state);
    final authorizeResponse = await _get(
      authorizeUri,
      host: _RequestHost.sso,
    );
    final authorizeStatus = authorizeResponse.statusCode;
    final location =
        authorizeResponse.headers.value(HttpHeaders.locationHeader);
    await authorizeResponse.drain<void>().timeout(HttpTimeout.normal);
    if (authorizeStatus < 300 || authorizeStatus >= 400 || location == null) {
      throw WeComAuthException(
        'webVpnAuthorizeFailed',
        'SSO 未返回 WebVPN 授权码（HTTP $authorizeStatus）',
      );
    }
    if (location.contains(WeComConstants.loginPathMarker)) {
      throw const WeComAuthException(
        'sessionNotReused',
        '企业微信会话未能完成 WebVPN 授权，请重新登录',
      );
    }
    final callbackUri = authorizeUri.resolve(location);
    _validateRedirect(callbackUri, callback.toString());
    final code = callbackUri.queryParameters['code'];
    final callbackState = callbackUri.queryParameters['state'];
    if (code == null || code.isEmpty || callbackState != state) {
      throw const WeComAuthException(
        'webVpnCallbackMismatch',
        'WebVPN 授权回调校验失败，请重新尝试',
      );
    }

    final finish = await _webVpnJsonRequest(
      'POST',
      portal.resolve('/api/access/auth/finish'),
      refererPath: '/callback/oauth2',
      body: {
        'externalId': externalId,
        'data': jsonEncode({
          'callbackUrl': callback.toString(),
          'code': code,
          'deviceId': await loadWebVpnDeviceId(),
          'state': state,
        }),
      },
    );
    if (finish['code'] != 0) {
      throw WeComAuthException(
        'webVpnFinishFailed',
        _webVpnApiMessage(finish, 'WebVPN 企业微信登录失败'),
      );
    }
    final info = await _webVpnJsonRequest(
      'GET',
      portal.resolve('/api/access/user/info'),
      refererPath: '/site-nav/',
    );
    final user = info['data'];
    final userId = user is Map ? user['userId'] : null;
    if (info['code'] != 0 ||
        userId == null ||
        userId.toString().isEmpty ||
        userId.toString() == '0') {
      throw const WeComAuthException(
        'webVpnUserInfoMissing',
        'WebVPN 未能确认登录身份，请重新尝试',
      );
    }
    if (user is Map &&
        (user['needTriggerTFA'] == true ||
            user['needChangePwd'] == true ||
            user['needToBindLocalAccount'] == true)) {
      throw const WeComAuthException(
        'webVpnActionRequired',
        'WebVPN 要求完成额外验证或账户操作，请暂时使用账密登录',
      );
    }

    final webVpnCookies = _webVpnCookies;
    if (!webVpnCookies.any(
      (entry) =>
          entry.cookie.name == 'webvpn-token' && entry.cookie.value.isNotEmpty,
    )) {
      throw const WeComAuthException(
        'webVpnTokenMissing',
        'WebVPN 已认证但未返回服务会话，请重试',
      );
    }
    _debug('webvpn ok userIdPresent=true '
        'cookies=${webVpnCookies.map((entry) => entry.cookie.name).toSet().toList()}');
    return WeComRedeemResult(
      callbackUri: Uri.parse(WeComConstants.webVpnLanding),
      sessionCookies: [
        ...webVpnCookies,
        for (final entry in _cookies.entries)
          if (entry.domain == Uri.parse(WeComConstants.ssoBase).host &&
              entry.cookie.name == WeComConstants.sessionCookieName)
            WeComStoredCookie(
              cookie: entry.cookie,
              domain: entry.domain,
              path: entry.path,
            ),
      ],
      accountName: user is Map ? user['username']?.toString() : null,
    );
  }

  List<WeComStoredCookie> get _webVpnCookies {
    final portalHost = Uri.parse(WeComConstants.webVpnBase).host;
    final result = <WeComStoredCookie>[
      for (final entry in _cookies.entries)
        if (entry.cookie.name == 'webvpn-token' ||
            entry.domain == portalHost ||
            entry.domain.endsWith('.webvpn.shu.edu.cn'))
          WeComStoredCookie(
            cookie: entry.cookie,
            domain: entry.domain,
            path: entry.path,
          ),
    ];
    WeComStoredCookie? token;
    for (final entry in result) {
      if (entry.cookie.name == 'webvpn-token' &&
          entry.cookie.value.isNotEmpty) {
        token = entry;
        break;
      }
    }
    // The session validator reads webvpn-token on the portal host, while the
    // gateway may scope the token it issued to a proxied host. Always add a
    // portal-host copy so the freshly-created session can be observed.
    if (token != null &&
        !result.any(
          (entry) =>
              entry.cookie.name == 'webvpn-token' &&
              entry.domain == portalHost &&
              entry.path == '/',
        )) {
      result.add(
        WeComStoredCookie(
          cookie: token.cookie,
          domain: portalHost,
          path: '/',
        ),
      );
    }
    return result;
  }

  @visibleForTesting
  static String webVpnState(String externalId) => base64Encode(
        utf8.encode(jsonEncode({'externalId': externalId})),
      );

  @visibleForTesting
  static Uri directWebVpnAuthorizeUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https') {
      throw const WeComAuthException(
        'unsafeWebVpnAuthorizeUrl',
        'WebVPN 返回了不安全的授权地址',
      );
    }
    if (uri.host == WeComConstants.webVpnNewssoProxyHost) {
      return uri.replace(host: Uri.parse(WeComConstants.ssoBase).host);
    }
    if (uri.host == Uri.parse(WeComConstants.ssoBase).host) return uri;
    throw const WeComAuthException(
      'unexpectedWebVpnAuthorizeHost',
      'WebVPN 返回了未预期的授权地址',
    );
  }

  @visibleForTesting
  Future<String> loadWebVpnDeviceId() => WebVpnDeviceId.load(
        preferencesLoader: _preferencesLoader,
        random: _random,
      );

  /// 按目标系统准备 `state`。
  Future<String> _prepareState(WeComOAuthTarget target) async {
    if (target.generateState) {
      // jwxt 的授权请求不带 state，本地生成随机值防 CSRF。
      return List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    return '';
  }

  Future<Map<String, dynamic>> _webVpnJsonRequest(
    String method,
    Uri uri, {
    required String refererPath,
    Map<String, Object?>? body,
  }) async {
    final portal = Uri.parse(WeComConstants.webVpnBase);
    if (uri.scheme != 'https' || uri.host != portal.host) {
      throw const WeComAuthException(
        'unsafeWebVpnApiUrl',
        'WebVPN 接口地址不安全',
      );
    }
    final request = await _client.openUrl(method, uri).timeout(
          HttpTimeout.connect,
        );
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser)
      ..set(HttpHeaders.refererHeader, portal.resolve(refererPath).toString())
      ..set('Origin', portal.toString());
    final cookieHeader = _cookies.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(HttpTimeout.normal);
    final responseCookies = _parseCookies(response);
    _cookies.save(uri, responseCookies);
    final text = await utf8.decodeStream(response).timeout(HttpTimeout.normal);
    Map<String, dynamic> decoded;
    try {
      final value = jsonDecode(text);
      if (value is! Map) throw const FormatException();
      decoded = value.map((key, value) => MapEntry(key.toString(), value));
    } on Object {
      throw WeComAuthException(
        'invalidWebVpnResponse',
        'WebVPN 返回了无法识别的内容（HTTP ${response.statusCode}）',
      );
    }
    _debug('webvpn response method=$method path=${uri.path} '
        'status=${response.statusCode} code=${decoded['code'] ?? '-'} '
        'cookies=${responseCookies.map((cookie) => cookie.name).toList()}');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WeComAuthException(
        'webVpnHttpError',
        _webVpnApiMessage(
          decoded,
          'WebVPN 服务请求失败（HTTP ${response.statusCode}）',
        ),
      );
    }
    return decoded;
  }

  String? _webVpnExternalId(Map<String, dynamic> response) {
    if (response['code'] != 0) return null;
    final data = response['data'];
    final list = data is Map ? data['list'] : null;
    if (list is! List) return null;
    for (final item in list) {
      if (item is Map && item['authType'].toString() == '5') {
        final value = item['externalId']?.toString();
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  void _validateWebVpnAuthorizeUri(Uri uri, String state) {
    final ssoHost = Uri.parse(WeComConstants.ssoBase).host;
    if (uri.scheme != 'https' ||
        uri.host != ssoHost ||
        uri.path != WeComConstants.authorizePath ||
        uri.queryParameters['client_id'] != WeComOAuthTarget.webVpn.clientId ||
        uri.queryParameters['redirect_uri'] != WeComConstants.webVpnCallback ||
        uri.queryParameters['state'] != state) {
      throw const WeComAuthException(
        'unexpectedWebVpnAuthorizeParams',
        'WebVPN 返回了未预期的授权参数',
      );
    }
  }

  String _webVpnApiMessage(
    Map<String, dynamic> response,
    String fallback,
  ) {
    final message = response['message']?.toString().trim();
    return message == null || message.isEmpty ? fallback : message;
  }

  /// 单次长轮询请求，返回扫码状态。
  ///
  /// 除企微域 Referer/Origin 外还带 `x-requested-with: XMLHttpRequest`
  /// 与 JS 的 Accept，保证企微侧识别为异步请求。
  Future<WeComScanResult> _pollOnce(String key) async {
    final uri = Uri.parse(WeComConstants.longPollBase).replace(
      queryParameters: {
        'callback': 'jsonpCallback',
        'key': key,
        'redirect_uri': WeComConstants.redirectUri,
        'appid': WeComConstants.appId,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    HttpClientResponse response;
    try {
      response = await _get(
        uri,
        host: _RequestHost.weCom,
        accept:
            'text/javascript, application/javascript, application/ecmascript, */*; q=0.01',
        extraHeaders: const {'x-requested-with': 'XMLHttpRequest'},
        timeout: HttpTimeout.longPoll,
      );
    } on TimeoutException {
      // 长轮询单个请求超时（约 40s）不视为失败，继续下一次轮询。
      return WeComScanResult.waiting();
    } on Object {
      return WeComScanResult.waiting();
    }
    final body =
        await utf8.decodeStream(response).timeout(HttpTimeout.longPoll);
    final match = _jsonpPattern.firstMatch(body);
    if (match == null) {
      return WeComScanResult.waiting();
    }
    try {
      final json = jsonDecode(match.group(1)!) as Map<String, dynamic>;
      final status = json['status']?.toString() ?? '';
      final authCode = json['auth_code']?.toString() ?? '';
      return _parseStatus(status, authCode);
    } on Object {
      return WeComScanResult.waiting();
    }
  }

  WeComScanResult _parseStatus(String status, String authCode) {
    switch (status) {
      case 'QRCODE_SCAN_SUCC':
        if (authCode.isNotEmpty) {
          return WeComScanResult.succeeded(authCode);
        }
        return WeComScanResult.confirmedPending();
      case 'QRCODE_SCAN_ING':
        return WeComScanResult.confirmedPending();
      case 'QRCODE_SCAN_ERR':
      case 'QRCODE_SCAN_OVERDUE':
      case 'QRCODE_SCAN_CANCEL':
        return WeComScanResult.expired();
      default:
        return WeComScanResult.waiting();
    }
  }

  /// 发起请求并按 [host] 选择请求头。
  ///
  /// 默认头指向 SSO 站点，只有企微扫码相关请求才覆盖成企微域的头，
  /// 否则企微侧可能拒绝。可通过 [referer]/[origin] 显式覆盖默认来源，
  /// 通过 [timeout] 覆盖请求超时（长轮询用 [HttpTimeout.longPoll]）。
  Future<HttpClientResponse> _get(
    Uri uri, {
    required _RequestHost host,
    String? accept,
    Map<String, String> extraHeaders = const {},
    String? referer,
    String? origin,
    Duration timeout = HttpTimeout.normal,
  }) async {
    final timer = Stopwatch()..start();
    final request = await _client.getUrl(uri).timeout(HttpTimeout.connect);
    request.followRedirects = false;
    request.headers
      ..set(
        HttpHeaders.acceptHeader,
        accept ?? 'text/html,application/xhtml+xml,*/*;q=0.8',
      )
      ..set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
    switch (host) {
      case _RequestHost.weCom:
        request.headers
          ..set(
            HttpHeaders.refererHeader,
            referer ?? WeComConstants.qrConnectBase,
          )
          ..set(
            'Origin',
            origin ?? 'https://${WeComConstants.weComHost}',
          );
      case _RequestHost.sso:
        request.headers
          ..set(HttpHeaders.refererHeader, referer ?? WeComConstants.ssoBase)
          ..set('Origin', origin ?? WeComConstants.ssoBase);
    }
    for (final entry in extraHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final cookieHeader = _cookies.headerFor(uri);
    if (cookieHeader.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(timeout);
    } on Object catch (error) {
      _debug('request-failed ${describeUrlForLog(uri)} '
          'type=${error.runtimeType} '
          'durationMs=${timer.elapsedMilliseconds}');
      rethrow;
    }
    // 在这里统一收下所有响应（包括 redeem）下发的 Set-Cookie，
    // 模拟浏览器 Session 行为，共享同一个 Cookie 容器。
    final cookies = _parseCookies(response);
    final location = response.headers.value(HttpHeaders.locationHeader);
    _debug('response ${describeUrlForLog(uri)} status=${response.statusCode} '
        'location=${location == null ? '-' : describeUrlForLog(uri.resolve(location))} '
        'cookies=${cookies.map((c) => c.name).toList()} '
        'durationMs=${timer.elapsedMilliseconds}');
    _cookies.save(uri, cookies);
    return response;
  }

  /// 宽松解析 `Set-Cookie`。
  ///
  /// `dart:io` 的 [HttpClientResponse.cookies] 会对每条 Set-Cookie 做严格
  /// 校验，遇到企微扫码域下发的非法值（例如含逗号）会**整体**抛出
  /// [FormatException]。这里逐条解析，跳过不符合 RFC 6265 的条目——
  /// 这些 Cookie 只属于企微扫码域，本流程并不需要它们。
  static List<Cookie> _parseCookies(HttpClientResponse response) {
    final cookies = <Cookie>[];
    final values = response.headers[HttpHeaders.setCookieHeader];
    if (values == null) return cookies;
    for (final value in values) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } on FormatException {
        _debug('skip malformed set-cookie');
      }
    }
    return cookies;
  }

  /// 校验授权回调地址。
  ///
  /// 只允许 [scheme] 为 https 且 host/path 与目标系统的 [expectedRedirect] 一致，
  /// 防止 SSO 返回任意 https 地址时导航到恶意站点（开放重定向）。
  void _validateRedirect(Uri uri, String expectedRedirect) {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const WeComAuthException(
        'unsafeRedirect',
        '企业微信授权返回了不安全的跳转地址',
      );
    }
    final expected = Uri.parse(expectedRedirect);
    if (uri.host != expected.host || uri.path != expected.path) {
      _debug('redirect mismatch location=${describeUrlForLog(uri)} '
          'expected=${expected.host}${expected.path}');
      throw const WeComAuthException(
        'unexpectedRedirect',
        '企业微信授权返回了未预期的跳转地址',
      );
    }
  }
}

/// 请求所属站点，决定 Referer/Origin。
enum _RequestHost { weCom, sso }
