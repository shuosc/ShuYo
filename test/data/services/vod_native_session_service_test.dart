import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/vod_constants.dart';
import 'package:shuyo/core/vod_url_resolver.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/shu_sso_session_store.dart';
import 'package:shuyo/data/services/vod_auth_exception.dart';
import 'package:shuyo/data/services/vod_native_session_service.dart';

http.Response _redirect(String target, {String? cookie}) =>
    http.Response('', 302, headers: {
      'location': target,
      if (cookie != null) 'set-cookie': cookie,
    });

Future<SessionCookieJar> _identityJar({bool gateway = false}) async {
  final jar = SessionCookieJar();
  await jar.setCookie(const SessionCookie(
    name: 'SHU_OAUTH2',
    value: 'shared-campus-session',
    domain: 'newsso.shu.edu.cn',
  ));
  if (gateway) {
    await jar.setCookie(const SessionCookie(
      name: 'webvpn-token',
      value: 'gateway-connection',
      domain: 'webvpn.shu.edu.cn',
    ));
    await jar.setCookie(const SessionCookie(
      name: 'unrelated',
      value: 'must-not-copy',
      domain: 'webvpn.shu.edu.cn',
    ));
  }
  return jar;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VodUrlResolver.configure(useWebVpn: false);
  });

  for (final vpn in [false, true]) {
    test(
        'native CAS chain preserves state and cookie ownership '
        'with ${vpn ? 'WebVPN' : 'direct'} transport', () async {
      final jar = await _identityJar(gateway: vpn);
      final requests = <http.Request>[];
      final platformHost =
          vpn ? VodUrlResolver.webVpnHost : VodConstants.directHost;
      final casHost = vpn ? VodUrlResolver.casWebVpnHost : VodConstants.casHost;
      const state = 'opaque+state/with=padding';
      final identity = Uri.https('newsso.shu.edu.cn', '/oauth/authorize', {
        'state': state,
        'redirect_uri':
            'https://${VodConstants.casHost}${VodConstants.casCallbackPath}',
      });
      final callback =
          Uri.https(VodConstants.casHost, VodConstants.casCallbackPath, {
        'state': state,
        'code': 'server-code',
      });
      final service = VodNativeSessionService(
        cookieJar: jar,
        ssoSessionStore: ShuSsoSessionStore(cookieJar: jar),
        client: MockClient((request) async {
          requests.add(request);
          expect(request.followRedirects, isFalse);
          expect(request.headers.containsKey('jwt-token'), isFalse);
          final cookie = request.headers['cookie'] ?? '';
          if (request.url.host == 'newsso.shu.edu.cn') {
            expect(cookie, 'SHU_OAUTH2=shared-campus-session');
          } else {
            expect(cookie.contains('SHU_OAUTH2'), isFalse);
            if (vpn) {
              expect(cookie, contains('webvpn-token=gateway-connection'));
              expect(cookie.contains('unrelated'), isFalse);
            }
          }
          switch (requests.length) {
            case 1:
              expect(request.url, VodUrlResolver.authorizeUri(useWebVpn: vpn));
              return _redirect(
                'https://${VodConstants.directHost}/cloud-rbac/authorize?state=rbac-state',
                cookie:
                    'JSESSIONID=vod-root; Path=/; Domain=.shu.edu.cn; Secure',
              );
            case 2:
              expect(request.url.host, platformHost);
              expect(request.url.path, '/cloud-rbac/authorize');
              expect(cookie, contains('JSESSIONID=vod-root'));
              return _redirect(
                  'https://${VodConstants.casHost}${VodConstants.casLoginPath}?service=server-service');
            case 3:
              expect(request.url.host, casHost);
              expect(request.url.path, VodConstants.casLoginPath);
              expect(cookie.contains('JSESSIONID'), isFalse);
              return _redirect(identity.toString(),
                  cookie:
                      'CASSTATE=server-state; Path=/; Domain=.shu.edu.cn; Secure');
            case 4:
              expect(request.url.host, 'newsso.shu.edu.cn');
              expect(request.url.queryParameters['state'], state);
              return _redirect(callback.toString());
            case 5:
              expect(request.url.host, casHost);
              expect(request.url.path, VodConstants.casCallbackPath);
              expect(request.url.queryParameters['state'], state);
              expect(request.url.queryParameters['code'], 'server-code');
              expect(cookie, contains('CASSTATE=server-state'));
              return _redirect(
                  'https://${VodConstants.directHost}/cloud-rbac/authorize?ticket=ST-server-ticket&state=rbac-state');
            case 6:
              expect(request.url.host, platformHost);
              expect(request.url.queryParameters['ticket'], 'ST-server-ticket');
              expect(cookie, contains('JSESSIONID=vod-root'));
              expect(cookie.contains('CASSTATE'), isFalse);
              return _redirect(
                  'https://${VodConstants.directHost}${VodConstants.uiPath}/?type=cas');
            case 7:
              expect(request.url.host, platformHost);
              expect(request.url.path, '${VodConstants.apiPath}/authority/me');
              expect(cookie, contains('JSESSIONID=vod-root'));
              return http.Response(
                  jsonEncode({
                    'status': 200,
                    'result': {'id': 'business-user'}
                  }),
                  200);
            case 8:
              expect(request.url.host, platformHost);
              expect(request.url.path, '${VodConstants.apiPath}/oauth2/token');
              expect(cookie, contains('JSESSIONID=vod-root'));
              return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'result': {'jwt_token': 'business-jwt-from-server'},
                  }),
                  200);
            default:
              fail('unexpected extra authorization request');
          }
        }),
      );
      addTearDown(service.dispose);
      final session = await service.authorize(
          useWebVpn: vpn, expectedStudentId: '25120000');
      expect(session.jwtToken, 'business-jwt-from-server');
      expect(requests.length, 8);
      expect(
          session.cookies.any((cookie) =>
              cookie.name == 'JSESSIONID' &&
              cookie.domain == platformHost &&
              cookie.path == '/'),
          isTrue);
      expect(
          session.cookies.any((cookie) =>
              cookie.name == 'CASSTATE' && cookie.domain == casHost),
          isTrue);
      expect(session.cookies.any((cookie) => cookie.name == 'SHU_OAUTH2'),
          isFalse);
      expect(session.cookies.any((cookie) => cookie.name == 'webvpn-token'),
          isFalse);
    });
  }

  for (final path in ['/login', '/oauth2/login/context']) {
    test('newsso $path is an expired shared SSO, with no login form request',
        () async {
      final jar = await _identityJar();
      var requests = 0;
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((_) async {
          requests++;
          return _redirect('https://newsso.shu.edu.cn$path');
        }),
      );
      addTearDown(service.dispose);
      await expectLater(
          service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
          throwsA(
            isA<VodCampusAuthRequiredException>()
                .having((error) => error.ssoExpired, 'ssoExpired', isTrue),
          ));
      expect(requests, 1);
    });
  }

  for (final status in [401, 500]) {
    test('newsso HTTP $status keeps expiry distinct from service failure',
        () async {
      final jar = await _identityJar();
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((request) async => request.url.host ==
                'newsso.shu.edu.cn'
            ? http.Response('', status)
            : _redirect(
                'https://newsso.shu.edu.cn/oauth/authorize?state=server-state')),
      );
      addTearDown(service.dispose);
      await expectLater(
          service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
          throwsA(
            status == 401
                ? isA<VodCampusAuthRequiredException>()
                    .having((error) => error.ssoExpired, 'ssoExpired', isTrue)
                : allOf(isA<VodAuthException>(),
                    isNot(isA<VodCampusAuthRequiredException>())),
          ));
    });
  }

  test('business token endpoint 401 is not declared to be shared SSO expiry',
      () async {
    final jar = await _identityJar();
    final service = VodNativeSessionService(
      cookieJar: jar,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/oauth2/authorize')) {
          return _redirect(
              'https://${VodConstants.directHost}${VodConstants.uiPath}/?type=cas');
        }
        if (request.url.path.endsWith('/authority/me')) {
          return http.Response('{"status":200,"result":{}}', 200);
        }
        return http.Response('', 401);
      }),
    );
    addTearDown(service.dispose);
    await expectLater(
        service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
        throwsA(
          allOf(isA<VodAuthException>(),
              isNot(isA<VodCampusAuthRequiredException>())),
        ));
  });

  test(
      'foreign redirects are rejected before credentials can leave known hosts',
      () async {
    final jar = await _identityJar();
    final requests = <http.Request>[];
    final service = VodNativeSessionService(
      cookieJar: jar,
      client: MockClient((request) async {
        requests.add(request);
        return _redirect('https://foreign.example/oauth/authorize');
      }),
    );
    addTearDown(service.dispose);
    await expectLater(
        service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
        throwsA(
          allOf(isA<VodAuthException>(),
              isNot(isA<VodCampusAuthRequiredException>())),
        ));
    expect(requests.length, 1);
  });

  test('missing shared SSO fails before making any business request', () async {
    final service = VodNativeSessionService(
      cookieJar: SessionCookieJar(),
      client: MockClient(
          (_) async => fail('missing SSO must not start authorization')),
    );
    addTearDown(service.dispose);
    await expectLater(
        service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
        throwsA(
          isA<VodCampusAuthRequiredException>()
              .having((error) => error.ssoExpired, 'ssoExpired', isTrue),
        ));
  });
}
