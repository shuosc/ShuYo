import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/data/services/library_session_store.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/shu_sso_session_store.dart';

typedef _SsoCookieEntry = ({Cookie cookie, String domain, String path});

// exp 为 2099 年，保证缓存会话在测试里不会过期。
const _jwt =
    'eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI0NDEyMjIiLCJleHAiOjQwNzAwOTA0MDB9.c2ln';
const _expiredJwt =
    'eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI0NDEyMjIiLCJleHAiOjF9.c2ln';

const _initPage = r'''
<script>
    window.location = "https:\/\/newsso.shu.edu.cn\/oauth\/authorize?response_type=code\u0026redirect_uri=https:\/\/tyrzfw.chaoxing.com\/OAuth2\/shu\/index\u0026client_id=sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37";
</script>
''';

const _callbackPage = r'''
<script>
    var url = "\/OAuth2\/shu\/login";
    var firstReferer = "https:\/\/findshu.libsp.cn\/find\/sso\/login\/shu\/0";
    jQuery.ajax({ data: {
        data: "",
        time: 1794298118289,
        enc: "B4FE9821886D77021390505D887FD0AC",
        displayName: null,
        userRole: 3
    }});
</script>
''';

class _FakeMemorySecureStore extends SecureAppStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

class _FakeSsoSessionStore extends ShuSsoSessionStore {
  _FakeSsoSessionStore([this._cookies = const []]);
  final List<_SsoCookieEntry> _cookies;

  @override
  Future<List<_SsoCookieEntry>> sessionCookies() async => _cookies;
}

class _FakeAccountStore extends AcademicAccountStore {
  _FakeAccountStore([this._studentId]);
  final String? _studentId;

  @override
  Future<String?> loadStudentId() async => _studentId;
}

_SsoCookieEntry _ssoCookie() => (
      cookie: Cookie('SHU_OAUTH2', 'valid-sso-token')
        ..domain = 'newsso.shu.edu.cn'
        ..path = '/',
      domain: 'newsso.shu.edu.cn',
      path: '/',
    );

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _html(String body) => http.Response(
      body,
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );

/// 复现真实站点的响应形态。[onUserInfo] 收到请求时可做断言。
http.Response _libraryResponse(
  http.Request request, {
  List<String>? trace,
  void Function(http.Request request)? onUserInfo,
  String? libraryLocation,
  String loginReply = '{"status":true}',
}) {
  final uri = request.url;
  trace?.add('${uri.host}${uri.path}');
  if (uri.host == 'tyrzfw.chaoxing.com' && uri.path == '/OAuth2/shu/init') {
    return http.Response(_initPage, 200, headers: {
      'content-type': 'text/html;charset=UTF-8',
      'set-cookie':
          'firstReferer=https://findshu.libsp.cn/find/sso/login/shu/0; '
              'Max-Age=86400; Expires=Wed, 11-Nov-2099 08:08:11 GMT; Path=/, '
              'route=abc; Path=/',
    });
  }
  if (uri.host == 'newsso.shu.edu.cn' && uri.path == '/oauth/authorize') {
    expect(request.headers['Cookie'], contains('SHU_OAUTH2=valid-sso-token'));
    return http.Response('', 302, headers: {
      'location':
          'https://tyrzfw.chaoxing.com/OAuth2/shu/index?code=mock_code_123',
    });
  }
  if (uri.host == 'tyrzfw.chaoxing.com' && uri.path == '/OAuth2/shu/index') {
    expect(request.headers['Cookie'], contains('firstReferer='));
    return _html(_callbackPage);
  }
  if (uri.host == 'tyrzfw.chaoxing.com' && uri.path == '/OAuth2/shu/login') {
    expect(uri.queryParameters['time'], '1794298118289');
    expect(uri.queryParameters['enc'], 'B4FE9821886D77021390505D887FD0AC');
    expect(uri.queryParameters['userRole'], '3');
    expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
    return http.Response(loginReply, 200,
        headers: {'content-type': 'text/plain;charset=UTF-8'});
  }
  if (uri.host == 'findshu.libsp.cn' && uri.path == '/find/sso/login/shu/0') {
    expect(uri.queryParameters['enc'], 'B4FE9821886D77021390505D887FD0AC');
    return http.Response('', 302, headers: {
      'location': libraryLocation ??
          'https://findshu.libsp.cn/find/#/Home?jwt=$_jwt&jwtHeader=jwtOpacAuth',
    });
  }
  if (uri.host == 'findshu.libsp.cn' &&
      (uri.path == '/oga/userinfo' ||
          uri.path == '/find/userInfo/getUserInfo')) {
    onUserInfo?.call(request);
    if (request.headers['jwtOpacAuth'] != _jwt) {
      return http.Response('{"status":401}', 401);
    }
    return _json({
      'success': true,
      'data': {
        'user': {
          'userId': 10001,
          'name': '测试用户',
          'unit': '计算机学院',
          'userGroupName': '本科生',
        },
      },
    });
  }
  return http.Response('Not Found', 404);
}

MockClient _libraryServer({
  List<String>? trace,
  void Function(http.Request request)? onUserInfo,
  String? libraryLocation,
  String loginReply = '{"status":true}',
}) {
  return MockClient((request) async => _libraryResponse(
        request,
        trace: trace,
        onUserInfo: onUserInfo,
        libraryLocation: libraryLocation,
        loginReply: loginReply,
      ));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  LibraryAuthService service(
    http.Client client, {
    String? studentId = '25120000',
    List<_SsoCookieEntry> sso = const [],
    LibrarySessionStore? sessionStore,
  }) =>
      LibraryAuthService(
        client: client,
        accountStore: _FakeAccountStore(studentId),
        ssoSessionStore: _FakeSsoSessionStore(sso),
        sessionStore: sessionStore ??
            LibrarySessionStore(secureStore: _FakeMemorySecureStore()),
      );

  test('asks for a campus login when no account is signed in', () async {
    await expectLater(
      service(_libraryServer(), studentId: null).authorize(),
      throwsA(isA<LibraryCampusAuthRequiredException>()
          .having((e) => e.ssoExpired, 'ssoExpired', isFalse)),
    );
  });

  test('asks for a campus login when the SSO cookie is missing', () async {
    await expectLater(
      service(_libraryServer()).authorize(),
      throwsA(isA<LibraryCampusAuthRequiredException>()
          .having((e) => e.ssoExpired, 'ssoExpired', isTrue)),
    );
  });

  test('walks the full chain and keeps the issued jwt', () async {
    final trace = <String>[];
    final sessionStore =
        LibrarySessionStore(secureStore: _FakeMemorySecureStore());
    final session = await service(
      _libraryServer(trace: trace),
      sso: [_ssoCookie()],
      sessionStore: sessionStore,
    ).authorize();

    expect(trace, [
      'tyrzfw.chaoxing.com/OAuth2/shu/init',
      'newsso.shu.edu.cn/oauth/authorize',
      'tyrzfw.chaoxing.com/OAuth2/shu/index',
      'tyrzfw.chaoxing.com/OAuth2/shu/login',
      'findshu.libsp.cn/find/sso/login/shu/0',
      'findshu.libsp.cn/oga/userinfo',
    ]);
    expect(session.userName, '测试用户');
    expect(session.unit, '计算机学院');
    expect(session.jwt, _jwt);
    expect(session.jwtHeader, 'jwtOpacAuth');

    final stored = await sessionStore.loadSession(studentId: '25120000');
    expect(stored!.jwt, _jwt);
    expect(stored.jwtHeader, 'jwtOpacAuth');
  });

  test('sends the jwt header and groupCode when confirming the login',
      () async {
    late http.Request seen;
    await service(
      _libraryServer(onUserInfo: (request) => seen = request),
      sso: [_ssoCookie()],
    ).authorize();

    expect(seen.headers['jwtOpacAuth'], _jwt);
    expect(seen.headers['groupCode'], '201578');
    expect(seen.headers['mappingPath'], 'find');
  });

  test('falls back to jwt subject when user info request fails', () async {
    final session = await service(
      _libraryServer(onUserInfo: (_) => throw http.ClientException('fail')),
      sso: [_ssoCookie()],
    ).authorize();

    expect(session.jwt, _jwt);
    expect(session.userName, '441222');
  });

  test('reports the platform message when the code exchange is refused',
      () async {
    await expectLater(
      service(
        _libraryServer(loginReply: '{"msg":"参数错误","status":false}'),
        sso: [_ssoCookie()],
      ).authorize(),
      throwsA(isA<LibraryAuthException>()
          .having((e) => e.message, 'message', contains('参数错误'))),
    );
  });

  test('refuses a return address outside the library host', () async {
    final client = MockClient((request) async {
      final uri = request.url;
      if (uri.path == '/OAuth2/shu/init') return _html(_initPage);
      if (uri.host == 'newsso.shu.edu.cn') {
        return http.Response('', 302, headers: {
          'location': 'https://tyrzfw.chaoxing.com/OAuth2/shu/index?code=1',
        });
      }
      if (uri.path == '/OAuth2/shu/index') {
        return _html(_callbackPage.replaceFirst(
            r'https:\/\/findshu.libsp.cn\/find\/sso\/login\/shu\/0',
            r'https:\/\/evil.example\/find\/sso\/login\/shu\/0'));
      }
      if (uri.path == '/OAuth2/shu/login') return _json({'status': true});
      return http.Response('Not Found', 404);
    });

    await expectLater(
      service(client, sso: [_ssoCookie()]).authorize(),
      throwsA(isA<LibraryAuthException>()),
    );
  });

  test('upgrades a cleartext redirect on a trusted host to https', () async {
    final schemes = <String>[];
    final client = MockClient((request) async {
      schemes.add(request.url.scheme);
      if (request.url.path == '/oauth/authorize') {
        return http.Response('', 302, headers: {
          'location':
              'http://tyrzfw.chaoxing.com/OAuth2/shu/index?code=mock_code_123',
        });
      }
      return _libraryResponse(request);
    });

    final session = await service(client, sso: [_ssoCookie()]).authorize();

    expect(session.jwt, _jwt);
    expect(schemes.toSet(), {'https'});
  });

  test('refuses to follow a redirect to an untrusted host', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/OAuth2/shu/init') {
        return http.Response('', 302,
            headers: {'location': 'https://evil.example/steal'});
      }
      throw StateError('Unexpected request: ${request.url}');
    });

    await expectLater(
      service(client, sso: [_ssoCookie()]).authorize(),
      throwsA(isA<LibraryAuthException>()),
    );
  });

  test('reuses a valid cached session without repeating the chain', () async {
    final trace = <String>[];
    final sessionStore =
        LibrarySessionStore(secureStore: _FakeMemorySecureStore());
    await sessionStore.saveSession(
      studentId: '25120000',
      session: const LibraryStoredSession(
        jwt: _jwt,
        jwtHeader: 'jwtOpacAuth',
        cookies: [
          SessionCookie(name: 'route', value: 'r1', domain: 'findshu.libsp.cn'),
        ],
      ),
    );

    final session = await service(
      _libraryServer(trace: trace),
      sessionStore: sessionStore,
    ).authorize();

    expect(trace, ['findshu.libsp.cn/oga/userinfo']);
    expect(session.userName, '测试用户');
  });

  test('discards an expired cached session and signs in again', () async {
    final trace = <String>[];
    final sessionStore =
        LibrarySessionStore(secureStore: _FakeMemorySecureStore());
    await sessionStore.saveSession(
      studentId: '25120000',
      session: const LibraryStoredSession(
        jwt: _expiredJwt,
        jwtHeader: 'jwtOpacAuth',
      ),
    );

    final session = await service(
      _libraryServer(trace: trace),
      sso: [_ssoCookie()],
      sessionStore: sessionStore,
    ).authorize();

    expect(trace.first, 'tyrzfw.chaoxing.com/OAuth2/shu/init');
    expect(session.jwt, _jwt);
  });

  test('deduplicates simultaneous authorize requests', () async {
    final trace = <String>[];
    final svc = service(_libraryServer(trace: trace), sso: [_ssoCookie()]);

    final results = await Future.wait([
      svc.authorize(),
      svc.authorize(),
      svc.authorize(),
    ]);

    expect(
        trace.where((item) => item.endsWith('/OAuth2/shu/init')), hasLength(1));
    expect(results.map((item) => item.userName).toSet(), {'测试用户'});
  });
}
