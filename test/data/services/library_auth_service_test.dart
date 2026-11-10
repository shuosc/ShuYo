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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('throws LibraryCampusAuthRequiredException when not signed in to campus',
      () async {
    final service = LibraryAuthService(
      accountStore: _FakeAccountStore(null),
      ssoSessionStore: _FakeSsoSessionStore(),
    );

    expect(
      () => service.authorize(),
      throwsA(isA<LibraryCampusAuthRequiredException>().having(
        (e) => e.ssoExpired,
        'ssoExpired',
        isFalse,
      )),
    );
  });

  test('throws LibraryCampusAuthRequiredException when SSO cookie is missing',
      () async {
    final service = LibraryAuthService(
      accountStore: _FakeAccountStore('25120000'),
      ssoSessionStore: _FakeSsoSessionStore(const []),
    );

    expect(
      () => service.authorize(),
      throwsA(isA<LibraryCampusAuthRequiredException>().having(
        (e) => e.ssoExpired,
        'ssoExpired',
        isTrue,
      )),
    );
  });

  test('follows OAuth redirects and stores session cookies upon success',
      () async {
    final secureStore = _FakeMemorySecureStore();
    final sessionStore = LibrarySessionStore(secureStore: secureStore);
    final ssoStore = _FakeSsoSessionStore([
      (
        cookie: Cookie('SHU_OAUTH2', 'valid-sso-token')
          ..domain = 'newsso.shu.edu.cn'
          ..path = '/',
        domain: 'newsso.shu.edu.cn',
        path: '/',
      ),
    ]);

    final client = MockClient((request) async {
      final uri = request.url;
      if (uri.host == 'newsso.shu.edu.cn' && uri.path == '/oauth/authorize') {
        expect(
            request.headers['Cookie'], contains('SHU_OAUTH2=valid-sso-token'));
        return http.Response('', 302, headers: {
          'location':
              'https://tyrzfw.chaoxing.com/OAuth2/shu/index?code=mock_code_123',
        });
      }
      if (uri.host == 'tyrzfw.chaoxing.com' &&
          uri.path == '/OAuth2/shu/index') {
        return http.Response('', 302, headers: {
          'set-cookie': 'cx_auth=abc; Domain=tyrzfw.chaoxing.com; Path=/',
          'location':
              'https://findshu.libsp.cn/find/sso/login/shu/0?code=mock_code_123',
        });
      }
      if (uri.host == 'findshu.libsp.cn' &&
          uri.path == '/find/sso/login/shu/0') {
        return http.Response('', 302, headers: {
          'set-cookie': 'token=mock_jwt_token; Domain=findshu.libsp.cn; Path=/',
          'location': 'https://findshu.libsp.cn/find/#/Home',
        });
      }
      if (uri.host == 'findshu.libsp.cn' && uri.path == '/find/') {
        return http.Response('<html>OK</html>', 200);
      }
      if (uri.host == 'findshu.libsp.cn' &&
          uri.path == '/find/userInfo/getUserInfo') {
        expect(request.headers['groupCode'], '201578');
        expect(request.headers['Cookie'], contains('token=mock_jwt_token'));
        return http.Response(
          jsonEncode({
            'success': true,
            'user': {
              'userId': 10001,
              'name': '测试用户',
              'unit': '计算机学院',
              'userGroupName': '本科生',
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('Not Found', 404);
    });

    final service = LibraryAuthService(
      client: client,
      accountStore: _FakeAccountStore('25120000'),
      ssoSessionStore: ssoStore,
      sessionStore: sessionStore,
    );

    final session = await service.authorize();
    expect(session.studentId, '25120000');
    expect(session.userName, '测试用户');
    expect(session.unit, '计算机学院');

    final cached = await sessionStore.loadCookies(studentId: '25120000');
    expect(cached, isNotEmpty);
    expect(cached.any((c) => c.name == 'token' && c.value == 'mock_jwt_token'),
        isTrue);
  });

  test('validates existing cached session without repeating OAuth chain',
      () async {
    final secureStore = _FakeMemorySecureStore();
    final sessionStore = LibrarySessionStore(secureStore: secureStore);
    await sessionStore.saveCookies(
      studentId: '25120000',
      cookies: const [
        SessionCookie(
          name: 'token',
          value: 'saved_token',
          domain: 'findshu.libsp.cn',
        ),
      ],
    );

    var getUserInfoCalled = false;
    final client = MockClient((request) async {
      if (request.url.path == '/find/userInfo/getUserInfo') {
        getUserInfoCalled = true;
        return http.Response(
          jsonEncode({
            'success': true,
            'user': {
              'userId': 10001,
              'name': '已缓存用户',
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      throw StateError('Unexpected request: ${request.url}');
    });

    final service = LibraryAuthService(
      client: client,
      accountStore: _FakeAccountStore('25120000'),
      ssoSessionStore: _FakeSsoSessionStore(),
      sessionStore: sessionStore,
    );

    final session = await service.authorize(force: false);
    expect(getUserInfoCalled, isTrue);
    expect(session.userName, '已缓存用户');
  });

  test('deduplicates simultaneous in-flight authorize requests', () async {
    final secureStore = _FakeMemorySecureStore();
    final sessionStore = LibrarySessionStore(secureStore: secureStore);
    var requestCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/find/userInfo/getUserInfo') {
        requestCount++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response(
          jsonEncode({
            'success': true,
            'user': {'userId': 10001, 'name': '并发测试用户'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('Not Found', 404);
    });

    await sessionStore.saveCookies(
      studentId: '25120000',
      cookies: const [
        SessionCookie(
            name: 'token', value: 'token123', domain: 'findshu.libsp.cn'),
      ],
    );

    final service = LibraryAuthService(
      client: client,
      accountStore: _FakeAccountStore('25120000'),
      ssoSessionStore: _FakeSsoSessionStore(),
      sessionStore: sessionStore,
    );

    final results = await Future.wait([
      service.authorize(),
      service.authorize(),
      service.authorize(),
    ]);

    expect(requestCount, 1);
    expect(results[0].userName, '并发测试用户');
    expect(results[1].userName, '并发测试用户');
    expect(results[2].userName, '并发测试用户');
  });
}
