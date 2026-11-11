import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/classroom_auth_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/webvpn_session_store.dart';

const _building = ClassroomBuilding(
  id: 1,
  name: 'A',
  campusId: 1,
  campusName: 'campus',
);
const _portalCookies = [
  SessionCookie(
    name: 'webvpn-token',
    value: 'gateway',
    domain: 'webvpn.shu.edu.cn',
  ),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClassroomUrlResolver.configure(useWebVpn: false);
  });

  tearDown(() {
    ClassroomUrlResolver.configure(useWebVpn: false);
  });

  test('a failed superseded request retains its original API error', () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final sent = Completer<void>();
    final response = Completer<http.Response>();
    final client = ClassroomApiClient(
      authService: ClassroomAuthService(
        cookieLoader: (_) async => _portalCookies,
      ),
      httpClient: MockClient((request) {
        sent.complete();
        return response.future;
      }),
    );

    final pending = client.fetchBuildingSchedule(
      building: _building,
      date: DateTime(2026, 10, 26),
    );
    final assertion = expectLater(
      pending,
      throwsA(isA<ClassroomApiException>()
          .having((error) => error.statusCode, 'original HTTP status', 503)
          .having((error) => error.accessMode, 'original route',
              ClassroomAccessMode.webVpn)),
    );
    await sent.future;
    ClassroomUrlResolver.configure(useWebVpn: false);
    response.complete(http.Response('unavailable', 503));
    await assertion;
  });

  test('all classroom endpoints use WebVPN and its gateway cookie', () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final requests = <http.Request>[];
    final client = ClassroomApiClient(
      authService: ClassroomAuthService(
        cookieLoader: (_) async => _portalCookies,
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":200,"data":{}}', 200);
      }),
    );

    await client.fetchSearchOptions();
    await client.fetchBuildingSchedule(
      building: _building,
      date: DateTime(2026, 10, 26),
    );

    expect(requests.map((request) => request.url.path), [
      '/build/findSearchRoomSearchForm',
      '/course/findSection',
      '/build/findBuildRoomType',
    ]);
    for (final request in requests) {
      expect(request.url.host, ClassroomUrlResolver.webVpnHost);
      expect(request.headers['cookie'], 'webvpn-token=gateway');
      expect(request.headers['referer'], ClassroomUrlResolver.webVpnBaseUrl);
    }
  });

  test(
      'a request started directly stays direct if WebVPN is enabled while awaiting headers',
      () async {
    late http.Request sent;
    final client = ClassroomApiClient(
      authService: ClassroomAuthService(
        cookieLoader: (_) async => _portalCookies,
      ),
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response('{"code":200,"data":{}}', 200);
      }),
    );

    final pending = client.fetchBuildingSchedule(
      building: _building,
      date: DateTime(2026, 10, 26),
    );
    ClassroomUrlResolver.configure(useWebVpn: true);
    await pending;

    expect(sent.url.host, ClassroomUrlResolver.directHost);
    expect(sent.headers['referer'], ClassroomUrlResolver.directBaseUrl);
    expect(sent.headers, isNot(contains('cookie')));
  });

  test(
      'a WebVPN request stays on its host if the switch changes while cookies load',
      () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final portal = Completer<List<SessionCookie>>();
    final cookieReads = <Uri>[];
    late http.Request sent;
    final client = ClassroomApiClient(
      authService: ClassroomAuthService(
        cookieLoader: (uri) async {
          cookieReads.add(uri);
          if (uri.host == 'webvpn.shu.edu.cn') return await portal.future;
          return const [];
        },
      ),
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response('{"code":200,"data":{}}', 200);
      }),
    );

    final pending = client.fetchBuildingSchedule(
      building: _building,
      date: DateTime(2026, 10, 26),
    );
    ClassroomUrlResolver.configure(useWebVpn: false);
    portal.complete(_portalCookies);
    await pending;

    expect(sent.url.host, ClassroomUrlResolver.webVpnHost);
    expect(sent.headers['cookie'], 'webvpn-token=gateway');
    expect(sent.headers['referer'], ClassroomUrlResolver.webVpnBaseUrl);
    expect(
      cookieReads.every((uri) => uri.host.endsWith('webvpn.shu.edu.cn')),
      isTrue,
    );
  });

  test(
    'uses the persisted gateway session rather than reporting a false expiry',
    () async {
      ClassroomUrlResolver.configure(useWebVpn: true);
      SharedPreferences.setMockInitialValues({
        WebVpnSessionStore.cachedCookiesKey:
            '{"portal":[{"name":"webvpn-token","value":"saved"}]}',
      });
      final client = ClassroomApiClient(
        authService: ClassroomAuthService(cookieLoader: (_) async => const []),
        httpClient: MockClient((request) async {
          expect(request.url.host, ClassroomUrlResolver.webVpnHost);
          expect(request.headers['cookie'], 'webvpn-token=saved');
          return http.Response('{"code":200,"data":{}}', 200);
        }),
      );

      await client.fetchBuildingSchedule(
        building: _building,
        date: DateTime(2026, 10, 26),
      );
    },
  );

  test(
    'does not send an unauthenticated WebVPN request without a stored token',
    () async {
      ClassroomUrlResolver.configure(useWebVpn: true);
      var sent = false;
      final client = ClassroomApiClient(
        authService: ClassroomAuthService(cookieLoader: (_) async => const []),
        httpClient: MockClient((request) async {
          sent = true;
          return http.Response('{"code":200,"data":{}}', 200);
        }),
      );

      await expectLater(
        client.fetchBuildingSchedule(
          building: _building,
          date: DateTime(2026, 10, 26),
        ),
        throwsA(isA<ClassroomWebVpnAuthException>()),
      );
      expect(sent, isFalse);
    },
  );

  test('direct override bypasses cookies and leaves the global VPN enabled',
      () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final revision = ClassroomUrlResolver.revision;
    final requests = <http.Request>[];
    final client = ClassroomApiClient(
      authService: ClassroomAuthService(cookieLoader: (_) async {
        fail('Direct requests must not read WebVPN cookies');
      }),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{"code":200,"data":{}}', 200);
      }),
    );
    await client.fetchSearchOptions(accessMode: ClassroomAccessMode.direct);
    await client.fetchBuildingSchedule(
      building: _building,
      date: DateTime(2026, 11, 8),
      accessMode: ClassroomAccessMode.direct,
    );
    expect(requests, hasLength(3));
    for (final request in requests) {
      expect(request.url.host, ClassroomUrlResolver.directHost);
      expect(request.headers, isNot(contains('cookie')));
    }
    expect(ClassroomUrlResolver.usesWebVpn, isTrue);
    expect(ClassroomUrlResolver.revision, revision);
  });

  test('both option requests keep the originally selected mode', () async {
    final requests = <http.Request>[];
    final client = ClassroomApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        ClassroomUrlResolver.configure(useWebVpn: true);
        return http.Response('{"code":200,"data":{}}', 200);
      }),
    );
    await client.fetchSearchOptions();
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.url.host == ClassroomUrlResolver.directHost),
        isTrue);
  });

  for (final error in <Object>[
    TimeoutException('timed out'),
    const SocketException('DNS failed'),
    HandshakeException('TLS failed'),
    http.ClientException('gateway disconnected'),
  ]) {
    test('normalizes ${error.runtimeType} with the actual WebVPN route',
        () async {
      ClassroomUrlResolver.configure(useWebVpn: true);
      final client = ClassroomApiClient(
        authService:
            ClassroomAuthService(cookieLoader: (_) async => _portalCookies),
        webVpnSessionValidator: () async => WebVpnSessionStatus.unavailable,
        httpClient: MockClient((_) async => throw error),
      );
      await expectLater(
        client.fetchBuildingSchedule(
            building: _building, date: DateTime(2026, 11, 8)),
        throwsA(isA<ClassroomApiException>()
            .having(
                (e) => e.accessMode, 'actual route', ClassroomAccessMode.webVpn)
            .having((e) => e.cause, 'original cause', same(error))
            .having((e) => e is ClassroomWebVpnAuthException, 'false expiry',
                isFalse)),
      );
    });
  }

  test('a failing session probe preserves the original request failure',
      () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final error = TimeoutException('request timed out');
    final client = ClassroomApiClient(
      authService:
          ClassroomAuthService(cookieLoader: (_) async => _portalCookies),
      webVpnSessionValidator: () async => throw StateError('probe failed'),
      httpClient: MockClient((_) async => throw error),
    );
    await expectLater(
      client.fetchBuildingSchedule(
          building: _building, date: DateTime(2026, 11, 8)),
      throwsA(isA<ClassroomApiException>()
          .having((e) => e.cause, 'request cause', same(error))),
    );
  });

  test('a confirmed rejected session produces an authentication failure',
      () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final client = ClassroomApiClient(
      authService:
          ClassroomAuthService(cookieLoader: (_) async => _portalCookies),
      webVpnSessionValidator: () async => WebVpnSessionStatus.loginRequired,
      httpClient: MockClient((_) async => http.Response('login required', 503)),
    );
    await expectLater(
      client.fetchBuildingSchedule(
          building: _building, date: DateTime(2026, 11, 8)),
      throwsA(isA<ClassroomWebVpnAuthException>()),
    );
  });

  test('HTTP errors retain their status code and original route', () async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final client = ClassroomApiClient(
      authService:
          ClassroomAuthService(cookieLoader: (_) async => _portalCookies),
      webVpnSessionValidator: () async => WebVpnSessionStatus.unavailable,
      httpClient:
          MockClient((_) async => http.Response('gateway unavailable', 502)),
    );
    await expectLater(
      client.fetchBuildingSchedule(
          building: _building, date: DateTime(2026, 11, 8)),
      throwsA(isA<ClassroomApiException>()
          .having((e) => e.statusCode, 'HTTP status', 502)
          .having(
              (e) => e.accessMode, 'actual route', ClassroomAccessMode.webVpn)),
    );
  });
}
