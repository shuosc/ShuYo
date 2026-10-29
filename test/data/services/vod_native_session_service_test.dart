import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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

  test('WebVPN empty headers survive real IOClient transport without aborting',
      () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    var requests = 0;
    upstream.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      String? body;
      switch (requests) {
        case 1:
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader,
              'https://${VodUrlResolver.webVpnHost}/cloud-rbac/authorize');
          request.response.headers.add(HttpHeaders.setCookieHeader,
              'SESSION=server-session; Path=/; SameSite=Laxcloud-rbac; SameSite=Lax');
        case 2:
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader,
              'https://${VodUrlResolver.webVpnHost}${VodConstants.uiPath}/');
        default:
          body = jsonEncode({
            'status': 200,
            'result': requests == 3
                ? <String, String>{}
                : {'jwt_token': 'business-jwt-from-server'},
          });
      }
      request.response.headers.add(HttpHeaders.setCookieHeader, '');
      request.response.headers.add(HttpHeaders.setCookieHeader, '');
      if (body != null) request.response.write(body);
      await request.response.close();
    });
    final transport = IOClient();
    addTearDown(transport.close);
    final jar = await _identityJar(gateway: true);
    final service = VodNativeSessionService(
      cookieJar: jar,
      client: MockClient((request) async {
        if (requests > 0) {
          expect(request.headers['cookie'], contains('SESSION=server-session'));
        }
        final response = await http.Response.fromStream(await transport.send(
          http.Request(
            request.method,
            Uri.http('127.0.0.1:${upstream.port}', request.url.path),
          )..followRedirects = false,
        ));
        expect(response.headers['set-cookie'],
            requests == 1 ? endsWith(',,') : ',');
        if (requests > 1) {
          expect(
            () => Cookie.fromSetCookieValue(response.headers['set-cookie']!),
            throwsA(isA<HttpException>()),
          );
        }
        return response;
      }),
    );
    addTearDown(service.dispose);
    final session =
        await service.authorize(useWebVpn: true, expectedStudentId: '25120000');
    expect(requests, 4);
    expect(session.jwtToken, 'business-jwt-from-server');
    expect(session.cookies.single.path, '/');
    expect(session.cookies.single.domain, VodUrlResolver.webVpnHost);
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
      const callbackPath =
          '${VodConstants.casCallbackPathPrefix}387a16aceb9941e993b07aa1d918d22a';
      final identityHost = vpn
          ? 'https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn'
          : 'newsso.shu.edu.cn';
      final redirectUri =
          Uri.encodeQueryComponent('https://$casHost$callbackPath');
      final registeredRedirectUri = Uri.encodeQueryComponent(
          'https://${VodConstants.casHost}$callbackPath');
      const originalParameters =
          'state=opaque%2Bstate%2Fwith%3Dpadding&scope=first%2Bvalue&scope=second%2Fvalue';
      final identity = Uri.parse('https://$identityHost/oauth/authorize?'
          '$originalParameters&redirect_uri=$redirectUri');
      final callback = Uri.https(VodConstants.casHost, callbackPath, {
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
                    'JSESSIONID=vod-root; Path=/; Domain=.shu.edu.cn; Secure, '
                    'ROUTE=server-route; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/, '
                    'BUSINESS=server-session; Path=/; HttpOnly; Secure; '
                    'SameSite=Laxjy-application-resourcemanage/; HttpOnly; '
                    'SameSite=Lax, '
                    'SINGLE=standalone-invalid; Path=/; HttpOnly; Secure; '
                    'SameSite=Laxjy-application-resourcemanage/, '
                    'httponly, secure${vpn ? ',,' : ''}',
              );
            case 2:
              expect(request.url.host, platformHost);
              expect(request.url.path, '/cloud-rbac/authorize');
              expect(cookie, contains('JSESSIONID=vod-root'));
              expect(cookie, contains('ROUTE=server-route'));
              expect(cookie, contains('BUSINESS=server-session'));
              expect(cookie, contains('SINGLE=standalone-invalid'));
              expect(cookie, isNot(contains('httponly')));
              expect(cookie, isNot(contains('secure')));
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
              expect(request.url.query,
                  '$originalParameters&redirect_uri=$registeredRedirectUri');
              expect(request.url.queryParameters['state'], state);
              expect(request.url.queryParametersAll['scope'],
                  ['first+value', 'second/value']);
              expect(request.url.queryParameters['redirect_uri'],
                  'https://${VodConstants.casHost}$callbackPath');
              return _redirect(callback.toString());
            case 5:
              expect(request.url.host, casHost);
              expect(request.url.path, callbackPath);
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
                'https://${VodConstants.directHost}${VodConstants.uiPath}/?type=cas',
                cookie: vpn ? ',,' : null,
              );
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
      expect(
          session.cookies.any((cookie) =>
              cookie.name == 'SINGLE' &&
              cookie.value == 'standalone-invalid' &&
              cookie.domain == platformHost),
          isTrue);
      expect(session.cookies.any((cookie) => cookie.name == 'SHU_OAUTH2'),
          isFalse);
      expect(session.cookies.any((cookie) => cookie.name == 'webvpn-token'),
          isFalse);
    });
  }

  for (final header in [
    '',
    ' ',
    ',',
    ', ',
    ', , ',
    ',,,',
    'SESSION=server-session; Path=/; Secure; SameSite=Lax,,',
    ' , SESSION=server-session; Path=/; Secure; SameSite=Lax, ,',
    ',,SESSION=server-session; Path=/; SameSite=Laxcloud-rbac; '
        'SameSite=Lax, ,HttpOnly, ,Secure, ,',
  ]) {
    test('WebVPN ignores empty Set-Cookie fields: ${jsonEncode(header)}',
        () async {
      final jar = await _identityJar(gateway: true);
      var requests = 0;
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, VodUrlResolver.webVpnHost);
          final cookie = request.headers['cookie'] ?? '';
          expect(cookie, contains('webvpn-token=gateway-connection'));
          expect(cookie, isNot(contains('SHU_OAUTH2')));
          if (requests == 1) {
            return _redirect(
              'https://${VodUrlResolver.webVpnHost}/cloud-rbac/authorize',
              cookie: header,
            );
          }
          if (header.contains('SESSION=')) {
            expect(cookie, contains('SESSION=server-session'));
          }
          if (requests == 2) {
            return _redirect(
              'https://${VodUrlResolver.webVpnHost}${VodConstants.uiPath}/',
              cookie: ', ,',
            );
          }
          return http.Response(
            jsonEncode({
              'status': 200,
              'result': requests == 3
                  ? <String, String>{}
                  : {'jwt_token': 'business-jwt-from-server'},
            }),
            200,
            headers: {'set-cookie': ',,'},
          );
        }),
      );
      addTearDown(service.dispose);
      final session = await service.authorize(
          useWebVpn: true, expectedStudentId: '25120000');
      expect(requests, 4);
      expect(session.jwtToken, 'business-jwt-from-server');
      expect(session.cookies.any((cookie) => cookie.name == 'SESSION'),
          header.contains('SESSION='));
      expect(
          session.cookies.any((cookie) =>
              cookie.name == 'webvpn-token' || cookie.name == 'SHU_OAUTH2'),
          isFalse);
    });
  }

  const callbackPath =
      '${VodConstants.casCallbackPathPrefix}387a16aceb9941e993b07aa1d918d22a';
  final callbackCases = <String, String>{
    'https://${VodUrlResolver.casWebVpnHost}$callbackPath'
            '?opaque=first%2Bvalue&opaque=second%2Fvalue':
        'https://${VodConstants.casHost}$callbackPath'
            '?opaque=first%2Bvalue&opaque=second%2Fvalue',
    'https://foreign.example$callbackPath':
        'https://foreign.example$callbackPath',
    'https://${VodUrlResolver.casWebVpnHost}/unregistered/callback':
        'https://${VodUrlResolver.casWebVpnHost}/unregistered/callback',
    'https://${VodUrlResolver.casWebVpnHost}'
            '${VodConstants.casCallbackPathPrefix}not-a-callback':
        'https://${VodUrlResolver.casWebVpnHost}'
            '${VodConstants.casCallbackPathPrefix}not-a-callback',
    'https://${VodUrlResolver.casWebVpnHost}:8443$callbackPath':
        'https://${VodUrlResolver.casWebVpnHost}:8443$callbackPath',
    'http://${VodUrlResolver.casWebVpnHost}$callbackPath':
        'http://${VodUrlResolver.casWebVpnHost}$callbackPath',
    'https://unexpected-user@${VodUrlResolver.casWebVpnHost}$callbackPath':
        'https://unexpected-user@${VodUrlResolver.casWebVpnHost}$callbackPath',
    'https://${VodConstants.casHost}$callbackPath':
        'https://${VodConstants.casHost}$callbackPath',
  };
  for (final callbackCase in callbackCases.entries) {
    test(
        'WebVPN rewrites only registered CAS redirect URI: '
        '${callbackCase.key}', () async {
      final jar = await _identityJar(gateway: true);
      var requests = 0;
      final redirectUri = Uri.encodeQueryComponent(callbackCase.key);
      final expectedRedirectUri = Uri.encodeQueryComponent(callbackCase.value);
      const originalParameters =
          'state=opaque%2Bstate%2Fwith%3Dpadding&scope=first%2Bvalue&scope=second%2Fvalue';
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((request) async {
          requests++;
          switch (requests) {
            case 1:
              return _redirect(
                  'https://https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn'
                  '/oauth/authorize?$originalParameters&redirect_uri=$redirectUri');
            case 2:
              expect(request.url.host, 'newsso.shu.edu.cn');
              expect(request.url.query,
                  '$originalParameters&redirect_uri=$expectedRedirectUri');
              expect(request.headers['cookie'],
                  'SHU_OAUTH2=shared-campus-session');
              return _redirect(
                  'https://${VodUrlResolver.webVpnHost}${VodConstants.uiPath}/?type=cas');
            case 3:
              expect(request.url.path, '${VodConstants.apiPath}/authority/me');
              return http.Response('{"status":200,"result":{}}', 200);
            case 4:
              expect(request.url.path, '${VodConstants.apiPath}/oauth2/token');
              return http.Response(
                  '{"status":200,"result":{"jwt_token":"business-jwt"}}', 200);
            default:
              fail('unexpected extra authorization request');
          }
        }),
      );
      addTearDown(service.dispose);
      final session = await service.authorize(
          useWebVpn: true, expectedStudentId: '25120000');
      expect(session.jwtToken, 'business-jwt');
      expect(requests, 4);
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

  for (final malformed in [
    'broken-cookie-without-equals',
    'BAD NAME=value; Path=/',
    'SESSION=value,,',
  ]) {
    test('malformed cookie is reported as an authentication failure', () async {
      final jar = await _identityJar();
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((_) async => _redirect(
              'https://${VodConstants.directHost}/cloud-rbac/authorize',
              cookie: malformed,
            )),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
        throwsA(isA<VodAuthException>().having(
          (error) => error.message,
          'message',
          '录播认证会话信息不完整，请稍后重试',
        )),
      );
    });
  }

  for (final path in ['/scope,', '/,']) {
    test('literal Cookie Path comma is not trimmed or broadened: $path',
        () async {
      final jar = await _identityJar(gateway: true);
      var requests = 0;
      final service = VodNativeSessionService(
        cookieJar: jar,
        client: MockClient((request) async {
          requests++;
          expect(request.headers['cookie'],
              isNot(contains('SCOPED=server-session')));
          if (requests == 1) {
            return _redirect(
              'https://${VodUrlResolver.webVpnHost}${VodConstants.uiPath}/',
              cookie: 'SCOPED=server-session; Path=$path',
            );
          }
          return http.Response(
            jsonEncode({
              'status': 200,
              'result': requests == 2
                  ? <String, String>{}
                  : {'jwt_token': 'business-jwt-from-server'},
            }),
            200,
          );
        }),
      );
      addTearDown(service.dispose);
      final session = await service.authorize(
          useWebVpn: true, expectedStudentId: '25120000');
      expect(session.cookies.single.path, path);
      expect(requests, 3);
    });
  }

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

  test('CAS callback accepts only the server-generated 32-hex route', () async {
    final jar = await _identityJar();
    var requests = 0;
    final service = VodNativeSessionService(
      cookieJar: jar,
      client: MockClient((request) async {
        requests++;
        return _redirect(
          'https://${VodConstants.casHost}'
          '${VodConstants.casCallbackPathPrefix}not-a-callback',
        );
      }),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.authorize(useWebVpn: false, expectedStudentId: '25120000'),
      throwsA(allOf(
        isA<VodAuthException>(),
        isNot(isA<VodCampusAuthRequiredException>()),
      )),
    );
    expect(requests, 1);
    expect(
      VodConstants.isCasCallbackPath(
          '${VodConstants.casCallbackPathPrefix}387a16aceb9941e993b07aa1d918d22a'),
      isTrue,
    );
    expect(
      VodConstants.isCasCallbackPath(
          '${VodConstants.casCallbackPathPrefix}387a16aceb9941e993b07aa1d918d22'),
      isFalse,
    );
    expect(
      VodConstants.isCasCallbackPath(
          '${VodConstants.casCallbackPathPrefix}387a16aceb9941e993b07aa1d918d22z'),
      isFalse,
    );
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
