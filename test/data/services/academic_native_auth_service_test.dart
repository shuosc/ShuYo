import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';

void main() {
  test('native JWXT login resolves the account only from the homepage',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = _IdentityHttpClient(server.port);
    final service = AcademicNativeAuthService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      await server.close(force: true);
    });
    service.adoptSessionCookies([
      (
        cookie: Cookie('JSESSIONID', 'jwxt-fixture'),
        domain: 'jwxt.shu.edu.cn',
        path: '/jwglxt/',
      ),
      (
        cookie: Cookie('SHU_OAUTH2', 'sso-fixture'),
        domain: 'newsso.shu.edu.cn',
        path: '/',
      ),
    ]);
    var status = HttpStatus.ok;
    const input = '<input type="hidden" id="sessionUserKey" value="23123456">';
    var body = input;
    final captured = <(String, Uri, String?)>[];
    server.listen((request) async {
      captured.add((
        request.method,
        request.uri,
        request.headers.value(HttpHeaders.cookieHeader)
      ));
      request.response.statusCode = status;
      if (status == HttpStatus.found) {
        request.response.headers.set(HttpHeaders.locationHeader,
            'https://newsso.shu.edu.cn/oauth2/login/');
      }
      request.response.write(body);
      await request.response.close();
    });

    expect(await service.readCampusAccount(), '23123456');
    expect(captured.single, (
      'GET',
      Uri.parse('/jwglxt/xtgl/index_initMenu.html?jsdm=xs&echarts=1'),
      'JSESSIONID=jwxt-fixture',
    ));
    body = '$input$input';
    await expectLater(service.readCampusAccount(),
        throwsA(isA<AcademicNativeAuthException>()));
    body = '';
    status = HttpStatus.found;
    await expectLater(service.readCampusAccount(),
        throwsA(isA<AcademicNativeAuthException>()));
    expect(
        client.visited, List.filled(3, AcademicUrlResolver.studentIdentityUri));
  });

  test('academic password encryption produces randomized 1024-bit RSA data',
      () {
    final first = AcademicPasswordEncryptor.encrypt('test-password');
    final second = AcademicPasswordEncryptor.encrypt('test-password');

    expect(base64Decode(first), hasLength(128));
    expect(base64Decode(second), hasLength(128));
    expect(second, isNot(first));
  });

  test('sendError explains the rate limit and alternate method', () {
    expect(
      AcademicNativeAuthService.messageForCode('sendError'),
      '验证码发送过于频繁，请切换验证方式或稍后再试',
    );
  });

  test('identity redirects use newsso without changing business callbacks', () {
    final login = AcademicNativeAuthService.canonicalSsoUri(Uri.parse(
      'https://oauth.shu.edu.cn/oauth2/login/context',
    ));
    final proxy = AcademicNativeAuthService.canonicalSsoUri(Uri.parse(
      'https://https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn/oauth/authorize?client_id=x',
    ));
    final callback = AcademicNativeAuthService.canonicalSsoUri(Uri.parse(
      'https://jwxt.shu.edu.cn/sso/shulogin?code=x',
    ));
    expect(login.host, 'newsso.shu.edu.cn');
    expect(proxy.host, 'newsso.shu.edu.cn');
    expect(proxy.queryParameters['client_id'], 'x');
    expect(callback.host, 'jwxt.shu.edu.cn');
  });

  test('an authorization code alone marks the entry as a finished handshake',
      () {
    // SSO 会话仍有效时，authorize 直接回业务系统回调；此时没有登录参数可提交。
    expect(
      AcademicNativeAuthService.isAuthorizedCallback(Uri.parse(
        'https://webvpn.shu.edu.cn/callback/oauth2?code=x&state=y',
      )),
      isTrue,
    );
    expect(
      AcademicNativeAuthService.isAuthorizedCallback(Uri.parse(
        'https://jwxt.shu.edu.cn/sso/shulogin?code=x&state=y',
      )),
      isTrue,
    );
    // 登录页没有 code，仍须走凭据交换。
    expect(
      AcademicNativeAuthService.isAuthorizedCallback(Uri.parse(
        'https://newsso.shu.edu.cn/oauth2/login/context',
      )),
      isFalse,
    );
    // 空 code 不能当作已完成，否则会跳过整个凭据流程。
    expect(
      AcademicNativeAuthService.isAuthorizedCallback(
        Uri.parse('https://webvpn.shu.edu.cn/callback/oauth2?code='),
      ),
      isFalse,
    );
  });

  group('AcademicSessionCookieStore', () {
    const newsso = 'https://newsso.shu.edu.cn';

    test('removes a replaced SSO cookie without dropping business cookies', () {
      final store = AcademicSessionCookieStore();
      final uri = Uri.parse(newsso);
      store.save(uri, [
        Cookie('SHU_OAUTH2', 'old'),
        Cookie('ASP.NET_SessionId', 'business'),
      ]);

      store.removeByName('SHU_OAUTH2');
      expect(store.headerFor(uri), 'ASP.NET_SessionId=business');
    });

    test('keeps WeCom SSO cookies for the newsso callback request', () {
      final store = AcademicSessionCookieStore();

      // 企微扫码流程不经过 login()，SSO 会话 Cookie 需要外部注入。
      store.save(
        Uri.parse('$newsso/oauth/wecom/qrcode'),
        [
          Cookie('SHU_OAUTH2', 'sso-session-value')..path = '/',
          Cookie('empty', '')..path = '/',
        ],
      );

      final header = store.headerFor(Uri.parse(newsso));
      expect(header, 'SHU_OAUTH2=sso-session-value');
      expect(header, isNot(contains('empty=')));
    });

    test('exposes entries for publishing into the session cookie jar', () {
      final store = AcademicSessionCookieStore();
      store.save(
        Uri.parse('$newsso/oauth/wecom/qrcode'),
        [Cookie('SHU_OAUTH2', 'sso-session-value')..path = '/'],
      );

      final entry = store.entries.single;
      expect(entry.cookie.name, 'SHU_OAUTH2');
      expect(entry.domain, 'newsso.shu.edu.cn');
      expect(entry.path, '/');
    });

    test('ignores empty cookie values', () {
      final store = AcademicSessionCookieStore();
      store.save(
        Uri.parse('$newsso/oauth/wecom/qrcode'),
        [Cookie('SHU_OAUTH2', '')..path = '/'],
      );
      expect(store.headerFor(Uri.parse(newsso)), isEmpty);
      expect(store.entries, isEmpty);
    });

    test('overwrites a cookie with the same name, domain and path', () {
      final store = AcademicSessionCookieStore();
      final source = Uri.parse('$newsso/oauth/wecom/qrcode');
      store.save(source, [Cookie('SHU_OAUTH2', 'old')..path = '/']);
      store.save(source, [Cookie('SHU_OAUTH2', 'new')..path = '/']);
      expect(store.headerFor(Uri.parse(newsso)), 'SHU_OAUTH2=new');
    });
  });
}

class _IdentityHttpClient extends Fake implements HttpClient {
  _IdentityHttpClient(this.port);

  final int port;
  final _client = HttpClient();
  final visited = <Uri>[];

  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    visited.add(url);
    return _client.openUrl(
        method, url.replace(scheme: 'http', host: '127.0.0.1', port: port));
  }

  @override
  void close({bool force = false}) => _client.close(force: force);
}
