import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/client_user_agent.dart';
import '../../core/library_constants.dart';
import 'academic_account_store.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'library_auth_exception.dart';
import 'library_session_store.dart';
import 'session_cookie_jar.dart';
import 'shu_sso_session_store.dart';

export 'library_auth_exception.dart';

class LibraryAuthSession {
  const LibraryAuthSession({
    required this.studentId,
    required this.userName,
    this.unit = '',
    this.userGroupName = '',
    this.cookies = const [],
  });

  final String studentId;
  final String userName;
  final String unit;
  final String userGroupName;
  final List<SessionCookie> cookies;
}

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

  final http.Client _client;
  final bool _ownsClient;
  final ShuSsoSessionStore _ssoSessionStore;
  final LibrarySessionStore _sessionStore;
  final AcademicAccountStore _accountStore;

  static const groupCode = LibraryConstants.groupCode;
  static const newssoHost = LibraryConstants.newssoHost;
  static const chaoxingAuthHost = LibraryConstants.chaoxingAuthHost;
  static const libraryHost = LibraryConstants.host;
  static const oauthClientId = LibraryConstants.oauthClientId;
  static const oauthRedirectUri = LibraryConstants.oauthRedirectUri;

  static Uri get authorizeUri => LibraryConstants.authorizeUri;

  static const _allowedHosts = LibraryConstants.allowedRedirectHosts;

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

  /// 验证已存储的图书馆会话是否有效。
  Future<LibraryAuthSession?> validateCurrentSession() async {
    final studentId = await _loadStudentId();
    if (studentId == null) return null;
    final stored = await _sessionStore.loadCookies(studentId: studentId);
    if (stored.isEmpty) return null;

    final cookies = AcademicSessionCookieStore();
    for (final item in stored) {
      cookies.save(
        Uri.parse(
            'https://${item.domain.isNotEmpty ? item.domain : libraryHost}/'),
        [
          Cookie(item.name, item.value)
            ..domain = item.domain
            ..path = item.path,
        ],
      );
    }

    try {
      final info = await _fetchUserInfo(cookies);
      if (info != null) {
        return LibraryAuthSession(
          studentId: studentId,
          userName: info['name'] as String? ?? '',
          unit: info['unit'] as String? ?? '',
          userGroupName: info['userGroupName'] as String? ?? '',
          cookies: stored,
        );
      }
    } on Object {
      // 网络波动或会话失效
    }
    return null;
  }

  Future<LibraryAuthSession>? _inFlightAuth;

  /// 执行 newsso -> tyrzfw.chaoxing.com -> findshu.libsp.cn 授权链路。
  Future<LibraryAuthSession> authorize({bool force = false}) {
    if (!force) {
      final pending = _inFlightAuth;
      if (pending != null) return pending;
    }
    final operation = _authorizeInternal(force: force);
    _inFlightAuth = operation;
    return operation.whenComplete(() {
      if (identical(_inFlightAuth, operation)) {
        _inFlightAuth = null;
      }
    });
  }

  Future<LibraryAuthSession> _authorizeInternal({bool force = false}) async {
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
      if (entry.domain != newssoHost || entry.cookie.name != 'SHU_OAUTH2') {
        continue;
      }
      cookies.save(Uri.parse('https://$newssoHost/'), [
        Cookie(entry.cookie.name, entry.cookie.value)
          ..domain = newssoHost
          ..path = entry.path,
      ]);
    }

    if (cookies.headerFor(Uri.parse('https://$newssoHost/')).isEmpty) {
      throw const LibraryCampusAuthRequiredException(ssoExpired: true);
    }

    try {
      await _followAuthorization(cookies);
      final userInfo = await _fetchUserInfo(cookies);
      if (userInfo == null) {
        throw const LibraryAuthException('未能获取图书馆用户信息，请稍后重试');
      }

      final libraryCookies = <SessionCookie>[];
      for (final entry in cookies.entries) {
        if (entry.domain.contains('libsp.cn') ||
            entry.domain.contains('chaoxing.com')) {
          libraryCookies.add(
            SessionCookie(
              name: entry.cookie.name,
              value: entry.cookie.value,
              domain: entry.domain,
              path: entry.path,
            ),
          );
        }
      }

      await _sessionStore.saveCookies(
        studentId: studentId,
        cookies: libraryCookies,
      );

      return LibraryAuthSession(
        studentId: studentId,
        userName: userInfo['name'] as String? ?? '',
        unit: userInfo['unit'] as String? ?? '',
        userGroupName: userInfo['userGroupName'] as String? ?? '',
        cookies: libraryCookies,
      );
    } on LibraryAuthException {
      rethrow;
    } on TimeoutException {
      throw const LibraryAuthUnavailableException('连接图书馆认证服务超时，请稍后重试');
    } on SocketException {
      throw const LibraryAuthUnavailableException();
    } on http.ClientException {
      throw const LibraryAuthUnavailableException();
    }
  }

  Future<void> _followAuthorization(AcademicSessionCookieStore cookies) async {
    var current = authorizeUri;
    for (var count = 0; count < 16; count++) {
      if (!_allowedHosts.contains(current.host)) {
        throw LibraryAuthException('认证跳转遇到未受信任的地址: ${current.host}');
      }

      final response = await _get(current, cookies);

      if (current.host == newssoHost && response.statusCode == 401) {
        throw const LibraryCampusAuthRequiredException(ssoExpired: true);
      }

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw const LibraryAuthException('图书馆认证跳转不完整，请稍后重试');
        }
        current = current.resolve(location);
        continue;
      }

      if (response.statusCode >= 500) {
        throw LibraryAuthException(
            '校方认证服务暂时异常（HTTP ${response.statusCode}），请稍后重试');
      }

      if (current.host == newssoHost &&
          response.statusCode == 200 &&
          RegExp(r'/oauth2/login/|action=["\x27][^"\x27]*/login',
                  caseSensitive: false)
              .hasMatch(response.body)) {
        throw const LibraryCampusAuthRequiredException(ssoExpired: true);
      }

      // 成功落地到目标图书馆平台
      if (current.host == libraryHost) {
        return;
      }

      throw const LibraryAuthException('图书馆授权尚未完成，请稍后重试');
    }
    throw const LibraryAuthException('图书馆认证跳转次数过多，请稍后重试');
  }

  Future<http.Response> _get(
      Uri uri, AcademicSessionCookieStore cookies) async {
    final header = cookies.headerFor(uri);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'User-Agent': ClientUserAgent.mobileBrowser,
        'groupCode': groupCode,
        'X-Lang': 'CHI',
        'Content-Language': 'zh_CN',
        if (header.isNotEmpty) 'Cookie': header,
      });

    final http.Response response;
    try {
      response = await HttpTimeout.request(
        http.Response.fromStream(
          await HttpTimeout.request(_client.send(request)),
        ),
      );
    } on Object {
      rethrow;
    }

    _storeCookies(uri, response, cookies);
    return response;
  }

  void _storeCookies(
      Uri uri, http.Response response, AcademicSessionCookieStore cookies) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return;

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
        cookie.domain = uri.host;
        cookies.save(uri, [cookie]);
      } on FormatException {
        // 忽略畸形 Cookie
      } on HttpException {
        // 忽略畸形 Cookie
      }
    }
  }

  String _repairSameSite(String value) {
    final parts = value.split(';');
    final valid =
        RegExp(r'^samesite\s*=\s*(lax|strict|none)\s*$', caseSensitive: false);
    final attribute = RegExp(r'^samesite(?:\s*=|\s*$)', caseSensitive: false);
    return [
      for (final part in parts)
        if (!attribute.hasMatch(part.trim()) || valid.hasMatch(part.trim()))
          part,
    ].join(';');
  }

  Future<Map<String, Object?>?> _fetchUserInfo(
      AcademicSessionCookieStore cookies) async {
    final uri = Uri.parse('https://$libraryHost/find/userInfo/getUserInfo');
    final header = cookies.headerFor(uri);
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'application/json, text/plain, */*',
        'User-Agent': ClientUserAgent.mobileBrowser,
        'groupCode': groupCode,
        'X-Lang': 'CHI',
        'Content-Language': 'zh_CN',
        if (header.isNotEmpty) 'Cookie': header,
      });

    final http.Response response;
    try {
      response = await HttpTimeout.request(
        http.Response.fromStream(
          await HttpTimeout.request(_client.send(request)),
        ),
      );
    } on Object {
      return null;
    }

    if (response.statusCode != 200) return null;
    try {
      final json = jsonDecode(response.body);
      if (json is Map) {
        final user = json['data'] is Map ? json['data']['user'] : json['user'];
        if (user is Map) {
          return user.cast<String, Object?>();
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}
