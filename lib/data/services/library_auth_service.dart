import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/client_user_agent.dart';
import '../../core/library_constants.dart';
import 'academic_account_store.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'library_auth_exception.dart';
import 'library_auth_parser.dart';
import 'library_session_store.dart';
import 'session_cookie_jar.dart';
import 'shu_sso_session_store.dart';

export 'library_auth_exception.dart';

class LibraryAuthSession {
  const LibraryAuthSession({
    required this.studentId,
    required this.userName,
    required this.jwt,
    required this.jwtHeader,
    this.unit = '',
    this.userGroupName = '',
    this.cookies = const [],
  });

  final String studentId;
  final String userName;

  /// 图书馆接口要求的登录凭据，以 [jwtHeader] 为名放进请求头。
  final String jwt;
  final String jwtHeader;
  final String unit;
  final String userGroupName;
  final List<SessionCookie> cookies;
}

/// 用 ShuYo 已有的 newsso 会话换取图书馆业务凭据。
///
/// 链路与浏览器一致，且并非纯 302：
/// 1. 超星认证站 `init` 下发 `firstReferer` Cookie，并用脚本跳到 newsso；
/// 2. newsso 带着 `SHU_OAUTH2` 把授权码送回超星 `index`；
/// 3. `index` 是脚本页：先请求 `login` 兑换授权码，成功后带 `data/time/enc`
///    跳回图书馆的 `/find/sso/login/shu/0`；
/// 4. 图书馆在跳转地址里给出 `jwt` 与 `jwtHeader`，此后所有接口靠这个请求头鉴权。
class LibraryAuthService {
  LibraryAuthService({
    http.Client? client,
    ShuSsoSessionStore? ssoSessionStore,
    LibrarySessionStore? sessionStore,
    AcademicAccountStore? accountStore,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _ssoSessionStore = ssoSessionStore ?? ShuSsoSessionStore(),
        _sessionStore = sessionStore ?? LibrarySessionStore(),
        _accountStore = accountStore ?? AcademicAccountStore();

  static const _maxRedirects = 24;

  final http.Client _client;
  final bool _ownsClient;
  final ShuSsoSessionStore _ssoSessionStore;
  final LibrarySessionStore _sessionStore;
  final AcademicAccountStore _accountStore;
  Future<LibraryAuthSession>? _inFlightAuth;

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> clearSession() => _sessionStore.clearSession();

  Future<String?> _loadStudentId() async {
    final id = (await _accountStore.loadStudentId())?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  /// 验证已保存的图书馆会话是否仍有效；无效时返回 null。
  Future<LibraryAuthSession?> validateCurrentSession() async {
    final studentId = await _loadStudentId();
    if (studentId == null) return null;
    final stored = await _sessionStore.loadSession(studentId: studentId);
    if (stored == null) return null;

    final expiry = LibraryAuthParser.jwtExpiry(stored.jwt);
    if (expiry != null && !expiry.isAfter(DateTime.now())) {
      await _sessionStore.clearSession();
      return null;
    }

    final cookies = AcademicSessionCookieStore();
    for (final item in stored.cookies) {
      cookies.save(
        Uri.parse(
            'https://${item.domain.isEmpty ? LibraryConstants.host : item.domain}/'),
        [
          Cookie(item.name, item.value)
            ..domain = item.domain
            ..path = item.path,
        ],
      );
    }
    final info = await _fetchUserInfo(cookies, stored.jwtHeader, stored.jwt);
    if (info == null) return null;
    return _sessionFrom(
        studentId, info, stored.jwt, stored.jwtHeader, stored.cookies);
  }

  /// 保证存在可用的图书馆会话；并发调用共享同一次授权。
  Future<LibraryAuthSession> authorize({bool force = false}) {
    if (!force) {
      final pending = _inFlightAuth;
      if (pending != null) return pending;
    }
    final operation = _authorize(force: force);
    _inFlightAuth = operation;
    return operation.whenComplete(() {
      if (identical(_inFlightAuth, operation)) _inFlightAuth = null;
    });
  }

  Future<LibraryAuthSession> _authorize({required bool force}) async {
    final studentId = await _loadStudentId();
    if (studentId == null) {
      throw const LibraryCampusAuthRequiredException();
    }

    if (!force) {
      final existing = await validateCurrentSession();
      if (existing != null) return existing;
    }

    final identity = await _ssoSessionStore.sessionCookies();
    final cookies = AcademicSessionCookieStore();
    for (final entry in identity) {
      if (entry.domain != LibraryConstants.newssoHost ||
          entry.cookie.name != 'SHU_OAUTH2') {
        continue;
      }
      cookies.save(Uri.parse('https://${LibraryConstants.newssoHost}/'), [
        Cookie(entry.cookie.name, entry.cookie.value)
          ..domain = LibraryConstants.newssoHost
          ..path = entry.path,
      ]);
    }
    if (cookies
        .headerFor(Uri.parse('https://${LibraryConstants.newssoHost}/'))
        .isEmpty) {
      throw const LibraryCampusAuthRequiredException(ssoExpired: true);
    }

    final credentials = await _followAuthorization(cookies);
    final info =
        await _fetchUserInfo(cookies, credentials.header, credentials.jwt);
    final libraryCookies = _libraryCookies(cookies);
    await _sessionStore.saveSession(
      studentId: studentId,
      session: LibraryStoredSession(
        jwt: credentials.jwt,
        jwtHeader: credentials.header,
        cookies: libraryCookies,
      ),
    );
    return _sessionFrom(
        studentId, info, credentials.jwt, credentials.header, libraryCookies);
  }

  LibraryAuthSession _sessionFrom(
    String studentId,
    Map<String, Object?>? info,
    String jwt,
    String jwtHeader,
    List<SessionCookie> cookies,
  ) {
    final payloadSub = LibraryAuthParser.jwtSubject(jwt);
    final effectiveStudentId =
        (info?['studentId'] as String?) ?? payloadSub ?? studentId;
    final userName = (info?['name'] as String?) ??
        (info?['userName'] as String?) ??
        (info?['displayName'] as String?) ??
        payloadSub ??
        studentId;
    return LibraryAuthSession(
      studentId: effectiveStudentId,
      userName: userName,
      unit: (info?['unit'] as String?) ??
          (info?['deptName'] as String?) ??
          (info?['department'] as String?) ??
          '',
      userGroupName: (info?['userGroupName'] as String?) ??
          (info?['groupName'] as String?) ??
          '',
      jwt: jwt,
      jwtHeader: jwtHeader,
      cookies: cookies,
    );
  }

  List<SessionCookie> _libraryCookies(AcademicSessionCookieStore cookies) => [
        for (final entry in cookies.entries)
          if (entry.domain == LibraryConstants.host)
            SessionCookie(
              name: entry.cookie.name,
              value: entry.cookie.value,
              domain: entry.domain,
              path: entry.path,
            ),
      ];

  Future<({String jwt, String header})> _followAuthorization(
      AcademicSessionCookieStore cookies) async {
    var current = LibraryConstants.initUri;
    for (var count = 0; count < _maxRedirects; count++) {
      current = _trusted(current);
      final response = await _get(current, cookies);
      _trace(current, response);

      final found = _credentialsIn(current, response, cookies);
      if (found != null) return (jwt: found.jwt, header: found.header);

      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw const LibraryAuthException('图书馆认证跳转不完整，请稍后重试');
        }
        current = current.resolve(location);
        continue;
      }
      if (status >= 500) {
        throw LibraryAuthException('校方认证服务暂时异常（HTTP $status），请稍后重试');
      }
      if (current.host == LibraryConstants.newssoHost && status == 401) {
        throw const LibraryCampusAuthRequiredException(ssoExpired: true);
      }
      if (status != 200) {
        throw LibraryAuthException('图书馆认证失败（HTTP $status）');
      }

      if (current.host == LibraryConstants.newssoHost) {
        // 带着有效会话时 newsso 只会跳转；停在 200 页面意味着要求重新登录。
        throw const LibraryCampusAuthRequiredException(ssoExpired: true);
      }
      if (current.host == LibraryConstants.chaoxingAuthHost) {
        if (current.path == LibraryConstants.chaoxingInitPath) {
          current = _newssoTarget(current, response.body);
          continue;
        }
        if (current.path == LibraryConstants.chaoxingCallbackPath) {
          current = await _redeemCallback(current, response.body, cookies);
          continue;
        }
      }
      throw const LibraryAuthException('图书馆没有返回登录凭据，请稍后重试');
    }
    throw const LibraryAuthException('图书馆认证跳转次数过多，请稍后重试');
  }

  /// 只允许跳往认证链路上的已知主机，且授权码始终走 TLS：超星有时会返回
  /// `http://` 形式的同主机地址，这里升级为 https 而不是明文发送。
  Uri _trusted(Uri uri) {
    if (uri.userInfo.isNotEmpty ||
        !LibraryConstants.allowedRedirectHosts.contains(uri.host)) {
      throw const LibraryAuthException('认证跳转到了未受信任的地址，已中止');
    }
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' && (!uri.hasPort || uri.port == 80)) {
      return uri.replace(scheme: 'https', port: 443);
    }
    throw const LibraryAuthException('认证跳转到了未受信任的地址，已中止');
  }

  /// 超星入口页用脚本跳转到 newsso，目标必须仍是 newsso 的授权端点。
  Uri _newssoTarget(Uri page, String body) {
    final target = LibraryAuthParser.parseJsRedirect(body, page);
    if (target == null ||
        target.scheme != 'https' ||
        target.host != LibraryConstants.newssoHost ||
        target.path != '/oauth/authorize' ||
        target.queryParameters['client_id'] != LibraryConstants.oauthClientId) {
      throw const LibraryAuthException('图书馆认证入口已变化，请更新应用后重试');
    }
    return target;
  }

  /// 回调页要求先兑换授权码，成功后才会放行到图书馆。
  Future<Uri> _redeemCallback(
    Uri page,
    String body,
    AcademicSessionCookieStore cookies,
  ) async {
    final params = LibraryAuthParser.parseCallbackPage(body);
    if (params == null) {
      throw const LibraryAuthException('图书馆认证页面已变化，请更新应用后重试');
    }
    final loginUri = page.resolve(params.loginPath);
    if (loginUri.scheme != 'https' ||
        loginUri.host != LibraryConstants.chaoxingAuthHost ||
        loginUri.path != LibraryConstants.chaoxingLoginPath) {
      throw const LibraryAuthException('图书馆认证入口已变化，请更新应用后重试');
    }
    final request = loginUri.replace(queryParameters: {
      'data': params.data,
      'time': params.time,
      'enc': params.enc,
      'displayName': params.displayName,
      'userRole': params.userRole,
    });
    final response = await _get(
      request,
      cookies,
      accept: 'application/json, text/javascript, */*; q=0.01',
      referer: page,
      ajax: true,
    );
    _trace(request, response);
    if (response.statusCode != 200) {
      throw LibraryAuthException('图书馆授权码兑换失败（HTTP ${response.statusCode}）');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const LibraryAuthException('图书馆授权码兑换返回了无法识别的内容');
    }
    if (decoded is! Map || decoded['status'] != true) {
      final message = decoded is Map ? decoded['msg'] : null;
      throw LibraryAuthException(message is String && message.isNotEmpty
          ? '图书馆拒绝了本次授权：$message'
          : '图书馆拒绝了本次授权');
    }

    final referer = Uri.tryParse(params.firstReferer ??
        '${LibraryConstants.baseUrl}${LibraryConstants.ssoLoginReturnPath}');
    if (referer == null ||
        referer.scheme != 'https' ||
        referer.host != LibraryConstants.host ||
        !referer.path.startsWith(LibraryConstants.ssoLoginReturnPrefix)) {
      throw const LibraryAuthException('图书馆返回地址异常，已中止授权');
    }
    // 与回调页脚本一致：把兑换用的参数原样追加到返回地址。
    return referer.replace(queryParameters: {
      ...referer.queryParameters,
      'data': params.data,
      'time': params.time,
      'enc': params.enc,
    });
  }

  ({String jwt, String header})? _credentialsIn(
    Uri uri,
    http.Response response,
    AcademicSessionCookieStore cookies,
  ) {
    final location = response.headers['location'];
    if (location != null && uri.host != LibraryConstants.newssoHost) {
      final found = LibraryAuthParser.extractJwt(location);
      if (found != null) return (jwt: found.jwt, header: found.header);
    }
    if (uri.host != LibraryConstants.host) return null;

    final named = <String, String>{};
    for (final entry in cookies.entries) {
      if (entry.domain != LibraryConstants.host) continue;
      if (entry.cookie.name == 'jwt' || entry.cookie.name == 'jwtHeader') {
        named[entry.cookie.name] = Uri.decodeComponent(entry.cookie.value);
      }
    }
    final cookieJwt = named['jwt'];
    if (cookieJwt != null && LibraryAuthParser.looksLikeJwt(cookieJwt)) {
      final header = named['jwtHeader'];
      return (
        jwt: cookieJwt,
        header: header != null && LibraryAuthParser.isValidJwtHeader(header)
            ? header
            : LibraryConstants.defaultJwtHeader,
      );
    }
    final fromBody = LibraryAuthParser.extractJwt(response.body);
    return fromBody == null
        ? null
        : (jwt: fromBody.jwt, header: fromBody.header);
  }

  Future<http.Response> _get(
    Uri uri,
    AcademicSessionCookieStore cookies, {
    String? accept,
    Uri? referer,
    bool ajax = false,
    Map<String, String> extraHeaders = const {},
  }) async {
    final header = cookies.headerFor(uri);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': accept ??
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': ClientUserAgent.mobileBrowser,
        'groupCode': LibraryConstants.groupCode,
        'mappingPath': LibraryConstants.mappingPath,
        'X-Lang': 'CHI',
        'Content-Language': 'zh_CN',
        if (referer != null) 'Referer': referer.toString(),
        if (ajax) 'X-Requested-With': 'XMLHttpRequest',
        if (header.isNotEmpty) 'Cookie': header,
        ...extraHeaders,
      });
    final http.Response response;
    try {
      response = await HttpTimeout.request(
        http.Response.fromStream(
          await HttpTimeout.request(_client.send(request)),
        ),
      );
    } on TimeoutException {
      throw LibraryAuthUnavailableException('${_stage(uri)}连接超时，请稍后重试');
    } on SocketException {
      throw LibraryAuthUnavailableException('${_stage(uri)}暂时无法访问，请检查网络后重试');
    } on http.ClientException {
      throw LibraryAuthUnavailableException('${_stage(uri)}暂时无法访问，请检查网络后重试');
    } on TlsException {
      throw LibraryAuthUnavailableException('${_stage(uri)}安全连接失败，请稍后重试');
    }
    _storeCookies(uri, response, cookies);
    return response;
  }

  String _stage(Uri uri) => switch (uri.host) {
        LibraryConstants.newssoHost || 'oauth.shu.edu.cn' => '学校统一认证',
        LibraryConstants.chaoxingAuthHost => '图书馆授权',
        LibraryConstants.host => '图书馆服务',
        _ => '图书馆登录',
      };

  void _storeCookies(
    Uri uri,
    http.Response response,
    AcademicSessionCookieStore cookies,
  ) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;
    // package:http 用逗号合并多个 Set-Cookie；保留 Expires 日期里的逗号。
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
        // 图书馆认证只依赖各主机自己下发的 Cookie，不跨主机共享。
        cookie.domain = uri.host;
        cookies.save(uri, [cookie]);
      } on FormatException {
        // 畸形 Cookie 直接忽略。
      } on HttpException {
        // 畸形 Cookie 直接忽略。
      }
    }
  }

  String _repairSameSite(String value) {
    final valid =
        RegExp(r'^samesite\s*=\s*(lax|strict|none)\s*$', caseSensitive: false);
    final attribute = RegExp(r'^samesite(?:\s*=|\s*$)', caseSensitive: false);
    return [
      for (final part in value.split(';'))
        if (!attribute.hasMatch(part.trim()) || valid.hasMatch(part.trim()))
          part,
    ].join(';');
  }

  Future<Map<String, Object?>?> _fetchUserInfo(
    AcademicSessionCookieStore cookies,
    String jwtHeader,
    String jwt,
  ) async {
    final uri =
        Uri.https(LibraryConstants.host, LibraryConstants.ogaUserInfoPath);
    final http.Response response;
    try {
      response = await _get(
        uri,
        cookies,
        accept: 'application/json, text/plain, */*',
        extraHeaders: {jwtHeader: jwt},
      );
    } on Object {
      return _fallbackUserInfoFromJwt(jwt);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }
    if (response.statusCode != 200) {
      return _fallbackUserInfoFromJwt(jwt);
    }
    try {
      final json = jsonDecode(response.body);
      if (json is Map) {
        final data = json['data'];
        if (data is Map) {
          final user = data['user'];
          if (user is Map) return user.cast<String, Object?>();
          return data.cast<String, Object?>();
        }
        final user = json['user'];
        if (user is Map) return user.cast<String, Object?>();
      }
    } on FormatException {
      return _fallbackUserInfoFromJwt(jwt);
    }
    return _fallbackUserInfoFromJwt(jwt);
  }

  Map<String, Object?>? _fallbackUserInfoFromJwt(String jwt) {
    final sub = LibraryAuthParser.jwtSubject(jwt);
    if (sub != null && sub.isNotEmpty) {
      return {'name': sub, 'studentId': sub};
    }
    return null;
  }

  /// 只记录主机类别、阶段与状态码；绝不输出 Cookie、授权码或 JWT。
  void _trace(Uri uri, http.Response response) {
    if (!kDebugMode) return;
    final kind = switch (uri.host) {
      LibraryConstants.newssoHost || 'oauth.shu.edu.cn' => 'identity',
      LibraryConstants.chaoxingAuthHost => 'chaoxing',
      LibraryConstants.host => 'library',
      _ => 'other',
    };
    final location = response.headers['location'];
    var redirectKind = 'none';
    if (location != null && location.isNotEmpty) {
      final target = uri.resolve(location);
      redirectKind = LibraryConstants.allowedRedirectHosts.contains(target.host)
          ? target.host
          : 'other';
    }
    debugPrint('ShuYoLibrary auth: host=$kind path=${uri.path} '
        'status=${response.statusCode} redirect=$redirectKind');
  }
}
