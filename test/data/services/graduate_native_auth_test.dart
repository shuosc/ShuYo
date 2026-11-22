import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/graduate_session_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';

void main() {
  late SessionCookieJar jar;
  late _GraduatePortalFixture portal;
  late AcademicNativeAuthService auth;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    jar = SessionCookieJar.shared..resetForTesting();
    portal = await _GraduatePortalFixture.start();
    auth = AcademicNativeAuthService.forGraduate(httpClient: portal.client);
  });

  tearDown(() async {
    auth.dispose();
    await portal.server.close(force: true);
    jar.resetForTesting();
  });

  test('sign-in completes YJS authorization in isolation before publishing',
      () async {
    final result =
        await auth.login(username: 'test-user', password: 'test-pass');
    expect(result.challenge?.methods.keys, [AcademicVerificationMethod.sms]);
    await auth.sendCode(AcademicVerificationMethod.sms);
    final callback = await auth.verifyCode(
      method: AcademicVerificationMethod.sms,
      code: '000000',
    );
    expect(callback, portal.authorize);
    await auth.completeLogin(callback, publish: false);
    expect(portal.visited.first, GraduateSessionStore.entryUri);
    expect(portal.visited.where((uri) => uri == portal.callback), hasLength(1));
    expect(portal.atCallbackCookie, isEmpty);
    expect(portal.atAuthorizeCookie, 'SHU_OAUTH2=fixture-sso');
    expect(await GraduateSessionStore().loadCookies(), isEmpty);

    await auth.publishSessionCookies();
    final session = (await GraduateSessionStore().loadCookies())
        .singleWhere((cookie) => cookie.name == 'GS_SESSIONID');
    expect(session.domain, GraduateSessionStore.host);
    expect(session.path, '/gsapp/');
    expect(
        await jar.getCookies(domain: GraduateSessionStore.entryUri), isEmpty);
    expect(
      (await jar.getCookies(domain: Uri.https('jwxt.shu.edu.cn', '/jwglxt/'))),
      isEmpty,
    );
    expect(
      (await jar.getCookies(domain: Uri.https('newsso.shu.edu.cn', '/')))
          .map((cookie) => cookie.name),
      ['SHU_OAUTH2'],
    );
    final renewalCookie = await GraduateSessionStore().loadRenewalCookie();
    expect(renewalCookie?.value, 'fixture-sso');
    expect(renewalCookie?.expires, isNotNull);
    await GraduateSessionStore().clearSession();
    expect(await GraduateSessionStore().loadCookies(), isEmpty);
    expect(await GraduateSessionStore().loadRenewalCookie(), isNull);
    expect(await jar.getCookies(domain: Uri.https('newsso.shu.edu.cn', '/')),
        hasLength(1));
  });

  test('a logged-in-looking portal without GS_SESSIONID is not success',
      () async {
    portal.issueBusinessSession = false;
    await expectLater(
      auth.completeLogin(portal.callback),
      throwsA(isA<AcademicNativeAuthException>().having(
        (error) => error.code,
        'code',
        'graduateSessionUnavailable',
      )),
    );
    expect(await GraduateSessionStore().loadCookies(), isEmpty);
  });

  test('successful OTP without redirectUri reuses the same portal flow',
      () async {
    portal.includeSsoRedirect = false;
    await auth.login(username: 'test-user', password: 'test-pass');
    final next = await auth.verifyCode(
      method: AcademicVerificationMethod.sms,
      code: '000000',
    );
    expect(next, portal.authorize);
    await auth.completeLogin(next);
    expect(portal.visited.where((uri) => uri == portal.callback), hasLength(1));
  });

  for (final viaSso in [false, true]) {
    test(
        'WeCom validates YJS account ${viaSso ? 'via authorize' : 'via callback'}',
        () async {
      final challenge = await auth.prepareGraduateWeComLogin();
      expect(challenge.state, portal.loginContext);
      final afterStart = portal.visited.length;
      final account = await auth.completeGraduateWeComLogin(
        challenge,
        redirectUri: viaSso ? portal.authorize : portal.callback,
        ssoCookies: [_ssoCookie()],
      );
      expect(account, 'fixture-account');
      expect(portal.visited.skip(afterStart), [
        if (viaSso) portal.authorize,
        portal.callback,
        GraduateSessionStore.portalUri,
        GraduateSessionStore.userInfoUri,
      ]);
      if (viaSso) expect(portal.atAuthorizeCookie, 'SHU_OAUTH2=fixture-sso');
      expect(portal.atCallbackCookie, isEmpty);
      expect(portal.atUserInfo, ('POST', 'GS_SESSIONID=fixture-yjs'));
      expect(await GraduateSessionStore().loadCookies(), isEmpty);
      expect(await GraduateSessionStore().loadRenewalCookie(), isNull);

      await auth.publishSessionCookies();
      expect((await GraduateSessionStore().loadCookies()).single.name,
          'GS_SESSIONID');
      expect((await GraduateSessionStore().loadRenewalCookie())?.value,
          'fixture-sso');
    });
  }

  for (final (name, redirect)
      in <(String, Uri Function(_GraduatePortalFixture))>[
    (
      'wrong host',
      (portal) => portal.callback.replace(host: 'example.invalid')
    ),
    (
      'different YJS flow',
      (portal) => portal.callback.replace(
            path:
                portal.callback.path.replaceFirst('fixture-flow', 'other-flow'),
          )
    ),
    (
      'wrong state',
      (portal) => portal.callback.replace(queryParameters: {
            ...portal.callback.queryParameters,
            'state': 'other-state',
          })
    ),
    (
      'duplicate state',
      (portal) => portal.callback.replace(
            query: '${portal.callback.query}&state=${portal.flow}',
          )
    ),
    (
      'missing code',
      (portal) => portal.callback.replace(queryParameters: {
            'state': portal.flow,
          })
    ),
    (
      'wrong authorization',
      (portal) => portal.authorize.replace(
            queryParameters: {
              ...portal.authorize.queryParameters,
              'client_id': 'another-client',
            },
          )
    ),
  ]) {
    test('WeCom rejects $name before sending the callback', () async {
      final challenge = await auth.prepareGraduateWeComLogin();
      final requests = portal.visited.length;
      await expectLater(
        auth.completeGraduateWeComLogin(
          challenge,
          redirectUri: redirect(portal),
          ssoCookies: [_ssoCookie()],
        ),
        throwsA(isA<AcademicNativeAuthException>()),
      );
      expect(portal.visited, hasLength(requests));
      expect(await GraduateSessionStore().loadCookies(), isEmpty);
    });
  }

  test('WeCom rejects a callback from an earlier QR attempt', () async {
    final first = await auth.prepareGraduateWeComLogin();
    final previousCallback = portal.callback;
    portal.flow = 'new-fixture-flow';
    final next = await auth.prepareGraduateWeComLogin();
    expect(next.state, isNot(first.state));
    final requests = portal.visited.length;
    await expectLater(
      auth.completeGraduateWeComLogin(
        first,
        redirectUri: previousCallback,
        ssoCookies: [_ssoCookie()],
      ),
      throwsA(isA<AcademicNativeAuthException>()),
    );
    expect(portal.visited, hasLength(requests));
    expect(
        await auth.completeGraduateWeComLogin(
          next,
          redirectUri: portal.callback,
          ssoCookies: [_ssoCookie()],
        ),
        'fixture-account');
  });

  test('WeCom does not accept a YJS portal session with no user ID', () async {
    final challenge = await auth.prepareGraduateWeComLogin();
    portal.userId = null;
    await expectLater(
      auth.completeGraduateWeComLogin(
        challenge,
        redirectUri: portal.callback,
        ssoCookies: [_ssoCookie()],
      ),
      throwsA(isA<AcademicNativeAuthException>().having(
        (error) => error.code,
        'code',
        'graduateAccountMissing',
      )),
    );
    expect(await GraduateSessionStore().loadCookies(), isEmpty);
  });

  test('a durable YJS session can be restored without visiting SSO', () async {
    await jar.setCookie(const SessionCookie(
      name: 'GS_SESSIONID',
      value: 'fixture-yjs',
      domain: GraduateSessionStore.host,
      path: '/gsapp/',
    ));
    await auth.restoreGraduateSession();
    expect(portal.visited, [GraduateSessionStore.portalUri]);
  });

  test('YJS renews using its own SSO even if a campus service changes it',
      () async {
    await GraduateSessionStore().saveRenewalCookie(
      Cookie('SHU_OAUTH2', 'fixture-sso'),
    );
    await jar.setCookie(const SessionCookie(
      name: 'SHU_OAUTH2',
      value: 'another-account',
      domain: 'newsso.shu.edu.cn',
    ));
    await jar.setCookie(const SessionCookie(
      name: 'GS_LTYPE',
      value: 'stale-login-type',
      domain: GraduateSessionStore.host,
      path: '/gsapp/',
    ));
    await auth.restoreGraduateSession();
    expect(portal.visited, [
      GraduateSessionStore.portalUri,
      portal.authorize,
      portal.callback,
      GraduateSessionStore.portalUri,
    ]);
    expect(portal.atCallbackCookie, 'GS_LTYPE=stale-login-type');
    expect(portal.atAuthorizeCookie, 'SHU_OAUTH2=fixture-sso');
    expect((await GraduateSessionStore().loadCookies()).single.name,
        'GS_SESSIONID');
    expect(
      (await jar.getCookies(domain: Uri.https('newsso.shu.edu.cn', '/')))
          .single
          .value,
      'another-account',
    );
  });

  test('a shared SSO session alone cannot renew YJS', () async {
    await jar.setCookie(const SessionCookie(
      name: 'SHU_OAUTH2',
      value: 'fixture-sso',
      domain: 'newsso.shu.edu.cn',
    ));
    await expectLater(
      auth.restoreGraduateSession(),
      throwsA(isA<AcademicNativeAuthException>().having(
        (error) => error.code,
        'code',
        AcademicNativeAuthService.graduateLoginRequired,
      )),
    );
    expect(portal.visited, isEmpty);
    expect(await GraduateSessionStore().loadCookies(), isEmpty);
  });

  test('expired SSO returns login required without publishing a session',
      () async {
    await GraduateSessionStore().saveRenewalCookie(
      Cookie('SHU_OAUTH2', 'fixture-expired'),
    );
    await expectLater(
      auth.restoreGraduateSession(),
      throwsA(isA<AcademicNativeAuthException>().having(
        (error) => error.code,
        'code',
        AcademicNativeAuthService.graduateLoginRequired,
      )),
    );
    expect(await GraduateSessionStore().loadCookies(), isEmpty);
  });
}

Cookie _ssoCookie() => Cookie('SHU_OAUTH2', 'fixture-sso')..path = '/';

/// Synthetic server for password, OTP and dynamic OAuth with no real accounts.
class _GraduatePortalFixture {
  _GraduatePortalFixture(this.server) : client = _LoopbackClient(server);

  final HttpServer server;
  final _LoopbackClient client;
  String flow = 'fixture-flow';
  String get loginContext => 'portal-context-$flow';
  String get _callbackPath =>
      '/gsapp/sys/yjsrzfwapp/oauth_shu/callback/$flow.do';
  Uri get callback => Uri.https(GraduateSessionStore.host, _callbackPath, {
        'code': 'fixture-code',
        'state': flow,
      });
  Uri get authorize => Uri.https('newsso.shu.edu.cn', '/oauth/authorize', {
        'client_id': 'fixture-client',
        'response_type': 'code',
        'redirect_uri':
            Uri.https(GraduateSessionStore.host, _callbackPath).toString(),
        'state': flow,
      });
  List<Uri> get visited => client.visited;
  bool issueBusinessSession = true;
  bool includeSsoRedirect = true;
  bool returnedFromCallback = false;
  String? atAuthorizeCookie;
  String? atCallbackCookie;
  (String, String)? atUserInfo;
  String? userId = 'fixture-account';

  static Future<_GraduatePortalFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _GraduatePortalFixture(server);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
    void redirect(Uri target) {
      response.statusCode = HttpStatus.found;
      response.headers.set(HttpHeaders.locationHeader, target.toString());
    }

    void json(Map<String, Object> data) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'message': 'success', ...data}));
    }

    switch (request.uri.path) {
      case '/':
        redirect(GraduateSessionStore.portalUri);
      case '/oauth/authorize':
        atAuthorizeCookie = cookie;
        if (cookie.contains('SHU_OAUTH2=fixture-sso')) {
          redirect(callback);
        } else {
          redirect(
              Uri.https('newsso.shu.edu.cn', '/oauth2/login/$loginContext'));
        }
      case final path when path == '/oauth2/login/$loginContext':
        response.write('login');
      case '/oauth/userLogin':
        await request.drain<void>();
        json({
          'twoStepRequired': true,
          'twoStepMethods': {'sms': 'test'}
        });
      case '/oauth/twoStep/send':
        await request.drain<void>();
        json({});
      case '/oauth/twoStep/verify':
        await request.drain<void>();
        response.cookies.add(Cookie('SHU_OAUTH2', 'fixture-sso')
          ..path = '/'
          ..maxAge = const Duration(days: 3).inSeconds);
        json({if (includeSsoRedirect) 'redirectUri': authorize.toString()});
      case final path when path == _callbackPath:
        atCallbackCookie = cookie;
        returnedFromCallback = true;
        response.cookies.add(Cookie('GS_LTYPE', 'deleted')
          ..path = '/gsapp/'
          ..maxAge = 0);
        if (issueBusinessSession) {
          response.cookies.add(Cookie('GS_SESSIONID', 'fixture-yjs')
            ..path = '/gsapp/'
            ..httpOnly = true);
        }
        redirect(GraduateSessionStore.portalUri);
      case '/gsapp/sys/yjsemaphome/portal/index.do':
        if (returnedFromCallback ||
            cookie.contains('GS_SESSIONID=fixture-yjs')) {
          response.write('portal');
        } else {
          redirect(authorize);
        }
      case final path when path == GraduateSessionStore.userInfoUri.path:
        atUserInfo = (request.method, cookie);
        await request.drain<void>();
        if (cookie.contains('GS_SESSIONID=fixture-yjs')) {
          json({
            'code': '0',
            'data': {if (userId != null) 'userId': userId}
          });
        } else {
          redirect(authorize);
        }
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}

class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.server);

  final HttpServer server;
  final _client = HttpClient();
  final visited = <Uri>[];

  @override
  set connectionTimeout(Duration? timeout) =>
      _client.connectionTimeout = timeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    visited.add(url);
    return _client.openUrl(
        method,
        url.replace(
          scheme: 'http',
          host: server.address.address,
          port: server.port,
        ));
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
