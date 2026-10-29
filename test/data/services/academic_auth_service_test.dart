import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/academic_constants.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/core/webvpn_urls.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('WebVPN user info distinguishes a session from an outage', () {
    expect(
      AcademicAuthService.classifyWebVpnUserInfo(
        200,
        '{"code":0,"data":{"userId":123}}',
      ),
      WebVpnSessionStatus.valid,
    );
    expect(
      AcademicAuthService.classifyWebVpnUserInfo(401, ''),
      WebVpnSessionStatus.loginRequired,
    );
    expect(
      AcademicAuthService.classifyWebVpnUserInfo(
        200,
        '{"code":401,"data":null}',
      ),
      WebVpnSessionStatus.loginRequired,
    );
    expect(
      AcademicAuthService.classifyWebVpnUserInfo(503, ''),
      WebVpnSessionStatus.unavailable,
    );
    expect(
      AcademicAuthService.classifyWebVpnUserInfo(
        200,
        '{"code":500,"message":"服务暂不可用"}',
      ),
      WebVpnSessionStatus.unavailable,
    );
  });

  test('restores a cached direct campus session when live cookies are partial',
      () async {
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final first = AcademicAuthService(
      cookieLoader: (domain) async {
        if (domain.host == academic.host) {
          return [
            SessionCookie(
              name: 'JSESSIONID',
              value: 'academic-session',
              domain: academic.host,
            ),
          ];
        }
        return const [];
      },
      cookieSetter: (_) async {},
    );

    final initialHeader = await first.cookieHeader();
    expect(initialHeader, contains('JSESSIONID=academic-session'));

    final restored = <SessionCookie>[];
    final restarted = AcademicAuthService(
      cookieLoader: (_) async => const [],
      cookieSetter: (cookie) async => restored.add(cookie),
      directSessionValidator: (_) async => WebVpnSessionStatus.valid,
    );

    expect(await restarted.hasAcademicSession(), isTrue);
    expect(
      await restarted.cookieHeader(),
      contains('JSESSIONID=academic-session'),
    );
  });

  test('selects path-scoped cookies for a targeted direct request', () async {
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final service = AcademicAuthService(
      cookieLoader: (domain) async {
        if (domain.host == academic.host) {
          return [
            SessionCookie(
              name: 'JSESSIONID',
              value: 'academic-session',
              domain: academic.host,
              path: '/jwglxt',
            ),
            SessionCookie(
              name: 'route',
              value: 'node-a',
              domain: academic.host,
            ),
          ];
        }
        return const [];
      },
      cookieSetter: (_) async {},
    );

    final header = await service.cookieHeader(
      targetUri: AcademicUrlResolver.scheduleIndexUri,
    );
    expect(header, contains('JSESSIONID=academic-session'));
    expect(header, contains('route=node-a'));
  });

  test(
      'identity verification reads a cookie without changing campus login state',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('academic.auth.explicitly_signed_out', true);
    final service = AcademicAuthService(
      cookieLoader: (_) async => [
        SessionCookie(
          name: 'JSESSIONID',
          value: 'test-session',
          domain: AcademicConstants.host,
        ),
      ],
      cookieSetter: (_) async {},
    );

    final header = await service.cookieHeaderForIdentityVerification(
      targetUri: AcademicUrlResolver.uri(
        '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html',
      ),
    );

    expect(header, contains('JSESSIONID=test-session'));
    expect(prefs.getBool('academic.auth.explicitly_signed_out'), isTrue);
    expect(prefs.getString('academic.auth.cached_cookies.direct'), isNull);
  });

  test('live academic cookies replace stale cached values across paths',
      () async {
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'academic.auth.cached_cookies.direct',
      '{"academic":[{"name":"JSESSIONID","value":"stale-session","domain":"${academic.host}","path":"/jwglxt"}]}',
    );
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == academic.host
          ? [
              SessionCookie(
                name: 'JSESSIONID',
                value: 'fresh-session',
                domain: academic.host,
              ),
            ]
          : const [],
      cookieSetter: (_) async {},
    );

    final header = await service.cookieHeader(
      targetUri: AcademicUrlResolver.scheduleIndexUri,
    );

    expect(header, contains('JSESSIONID=fresh-session'));
    expect(header, isNot(contains('stale-session')));
    expect(
      prefs.getString('academic.auth.cached_cookies.direct'),
      isNot(contains('stale-session')),
    );
  });

  test('academic sign-out preserves WebVPN and schedule caches', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('academic.auth.cached_cookies.direct', 'direct');
    await prefs.setString('academic.auth.cached_cookies.webvpn', 'webvpn');
    await prefs.setBool('academic.auth.explicitly_signed_out', true);
    await prefs.setString('academic.schedule.cache', 'schedule');
    await prefs.setString(AcademicAccountStore.studentIdKey, '25120001');
    final service = AcademicAuthService(
      cookieLoader: (_) async => const [],
      cookieSetter: (_) async {},
    );

    await service.clearAccount();

    expect(prefs.getString('academic.auth.cached_cookies.direct'), isNull);
    expect(prefs.getString('academic.auth.cached_cookies.webvpn'), 'webvpn');
    expect(prefs.getBool('academic.auth.explicitly_signed_out'), isTrue);
    expect(prefs.getString('academic.schedule.cache'), 'schedule');
    expect(prefs.getString(AcademicAccountStore.studentIdKey), isNull);
  });

  test('does not treat a stale portal token as an authenticated session',
      () async {
    final portal = Uri.parse(WebVpnUrls.portal);
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == portal.host
          ? [
              SessionCookie(
                name: 'webvpn-token',
                value: 'stale-session',
                domain: portal.host,
              ),
            ]
          : const [],
      cookieSetter: (_) async {},
      webVpnSessionValidator: (_) async => WebVpnSessionStatus.loginRequired,
    );

    expect(await service.hasWebVpnSession(), isFalse);
  });

  test('keeps a cached account when WebVPN validation is temporarily offline',
      () async {
    final portal = Uri.parse(WebVpnUrls.portal);
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == portal.host
          ? [
              SessionCookie(
                name: 'webvpn-token',
                value: 'possibly-valid-session',
                domain: portal.host,
              ),
            ]
          : const [],
      cookieSetter: (_) async {},
      webVpnSessionValidator: (_) async => WebVpnSessionStatus.unavailable,
    );

    expect(await service.hasWebVpnSession(), isTrue);
  });

  test('restores and validates a cached direct campus session', () async {
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final restored = <SessionCookie>[];
    final service = AcademicAuthService(
      cookieLoader: (_) async => const [],
      cookieSetter: (cookie) async => restored.add(cookie),
      directSessionValidator: (_) async => WebVpnSessionStatus.valid,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'academic.auth.cached_cookies.direct',
      '{"academic":[{"name":"JSESSIONID","value":"direct-session","domain":"${academic.host}","path":"/"}]}',
    );

    expect(await service.hasAcademicSession(), isTrue);
    expect(
      restored.any(
        (cookie) =>
            cookie.name == 'JSESSIONID' && cookie.value == 'direct-session',
      ),
      isTrue,
    );
  });

  test('restores scoped cached and live academic cookies without validation',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'academic.auth.cached_cookies.direct',
      '{"academic":[{"name":"JSESSIONID","value":"cached-session","domain":"${AcademicConstants.host}","path":"/jwglxt"}]}',
    );
    final restored = <SessionCookie>[];
    var validationCalls = 0;
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == AcademicConstants.host
          ? [
              SessionCookie(
                name: 'route',
                value: 'node-a',
                domain: AcademicConstants.host,
                path: '/jwglxt',
              ),
            ]
          : const [],
      cookieSetter: (cookie) async => restored.add(cookie),
      directSessionValidator: (_) async {
        validationCalls++;
        return WebVpnSessionStatus.valid;
      },
    );

    expect(await service.restoreAcademicCookies(), isTrue);
    expect(validationCalls, 0);
    expect(
      restored.any((cookie) =>
          cookie.name == 'JSESSIONID' &&
          cookie.value == 'cached-session' &&
          cookie.domain == AcademicConstants.host &&
          cookie.path == '/jwglxt'),
      isTrue,
    );
    expect(restored.any((cookie) => cookie.name == 'route'), isTrue);
    expect(
      await service.restoreAcademicCookies(
        targetUri: Uri.parse('https://unrelated.example/jwglxt/'),
      ),
      isFalse,
    );
  });

  test('explicit logout prevents restoring even remaining live cookies',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('academic.auth.explicitly_signed_out', true);
    final restored = <SessionCookie>[];
    var reads = 0;
    final service = AcademicAuthService(
      cookieLoader: (_) async {
        reads++;
        return [
          SessionCookie(
            name: 'JSESSIONID',
            value: 'left-behind',
            domain: AcademicConstants.host,
          ),
        ];
      },
      cookieSetter: (cookie) async => restored.add(cookie),
    );

    expect(await service.restoreAcademicCookies(), isFalse);
    expect(reads, 0);
    expect(restored, isEmpty);
    expect(prefs.getBool('academic.auth.explicitly_signed_out'), isTrue);
  });

  test('explicit logout blocks cached session restoration until login',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'academic.auth.cached_cookies.webvpn',
      '{"portal":[{"name":"webvpn-token","value":"old-session","domain":"webvpn.shu.edu.cn","path":"/"}]}',
    );
    final service = AcademicAuthService(
      cookieLoader: (_) async => const [],
      cookieSetter: (_) async {},
      webVpnSessionValidator: (_) async => WebVpnSessionStatus.valid,
    );

    await service.clearCookies();
    expect(await service.hasAcademicSession(), isFalse);

    await service.markLoggedIn();
    expect(await service.hasAcademicSession(), isFalse);
  });
}
