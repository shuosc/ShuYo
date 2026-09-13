import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/academic_constants.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/core/forum_url_resolver.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ForumUrlResolver.configure(useWebVpn: false);
  });

  test(
      'restores a cached direct campus session when WebView cookies are partial',
      () async {
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final first = AcademicAuthService(
      cookieLoader: (domain) async {
        if (domain.host == academic.host) {
          return [
            WebViewCookie(
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

    final restored = <WebViewCookie>[];
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
            WebViewCookie(
              name: 'JSESSIONID',
              value: 'academic-session',
              domain: academic.host,
              path: '/jwglxt',
            ),
            WebViewCookie(
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
              WebViewCookie(
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
    final portal = Uri.parse(ForumUrlResolver.webVpnPortalUrl);
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == portal.host
          ? [
              WebViewCookie(
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
    final portal = Uri.parse(ForumUrlResolver.webVpnPortalUrl);
    final service = AcademicAuthService(
      cookieLoader: (domain) async => domain.host == portal.host
          ? [
              WebViewCookie(
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
    ForumUrlResolver.configure(useWebVpn: false);
    final academic = Uri.parse(AcademicConstants.baseUrl);
    final restored = <WebViewCookie>[];
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
