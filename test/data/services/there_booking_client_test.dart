import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/there_booking_client.dart';

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> requests;
  late ThereBookingClient client;
  final seen = <String>[];
  final requestCookies = <String, String?>{};
  final requestQueries = <String, Map<String, String>>{};
  final mobileModes = <String>[];
  final detailAbilities = <String, List<String>>{};
  Map<String, dynamic>? createdBody;
  var rejected = false;
  var requireLogin = false;
  var redirectLocation = '/login?code=SECRET_AUTH_CODE';
  var weChatRedirectForMarked = false;
  var weChatRedirectForAll = false;
  var weChatRedirectHost = 'open.weixin.qq.com';
  var redirectToWebVpnPortal = false;
  String? bootstrapState = 'SERVER_STATE+/_=';

  Uri callbackUri(String? state, {String code = 'ONCE', bool proxy = false}) =>
      Uri.parse(proxy
              ? 'https://there.shu.edu.cn/login-oauth2'
              : 'http://127.0.0.1:${server.port}/login-oauth2')
          .replace(queryParameters: {
        'code': code,
        if (state != null) 'state': state,
      });

  setUp(() async {
    seen.clear();
    requestCookies.clear();
    requestQueries.clear();
    mobileModes.clear();
    detailAbilities.clear();
    createdBody = null;
    rejected = false;
    requireLogin = false;
    redirectLocation = '/login?code=SECRET_AUTH_CODE';
    weChatRedirectForMarked = false;
    weChatRedirectForAll = false;
    weChatRedirectHost = 'open.weixin.qq.com';
    redirectToWebVpnPortal = false;
    bootstrapState = 'SERVER_STATE+/_=';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = server.listen((request) async {
      final path = request.uri.path;
      final method = request.method;
      seen.add('$method $path '
          '${request.headers.value('x-room-type') ?? '-'} '
          '${request.headers.value('x-hys-session') ?? '-'}');
      requestCookies[path] = request.headers.value(HttpHeaders.cookieHeader);
      requestQueries[path] = request.uri.queryParameters;
      Object response;
      if (path == '/login') {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          Uri.parse('https://oauth.shu.edu.cn/oauth/authorize')
              .replace(queryParameters: {
            if (bootstrapState != null) 'state': bootstrapState!,
          }).toString(),
        );
        request.response.headers
            .add(HttpHeaders.setCookieHeader, 'SPHYS_SESSION=prewarm; Path=/');
        response = '';
      } else if (path == '/login-oauth2') {
        if (request.uri.queryParameters['state'] != bootstrapState ||
            request.uri.queryParametersAll['state']?.length != 1 ||
            requestCookies[path]?.contains('SPHYS_SESSION=prewarm') != true) {
          request.response.statusCode = 400;
          request.response.write('登录校验失败，请重新发起授权');
          await request.response.close();
          return;
        }
        request.response.statusCode = 302;
        request.response.headers
            .set(HttpHeaders.locationHeader, '/web?authJump=token');
        request.response.headers.add(
            HttpHeaders.setCookieHeader, 'SPHYS_SESSION=authenticated; Path=/');
        response = '';
      } else if (path == '/web') {
        response = '<html>空间预约</html>';
      } else if (path == '/mobile/libseat' || path == '/mobile/seat2021') {
        if (redirectToWebVpnPortal) {
          request.response.statusCode = 302;
          request.response.headers
              .set(HttpHeaders.locationHeader, 'https://webvpn.shu.edu.cn/');
          await request.response.close();
          return;
        }
        final marked =
            request.headers.value('x-requested-with') == 'com.tencent.wework';
        mobileModes.add(marked ? 'wework-header' : 'plain');
        if (weChatRedirectForAll || (weChatRedirectForMarked && marked)) {
          request.response.statusCode = 302;
          request.response.headers.set(HttpHeaders.locationHeader,
              'https://$weChatRedirectHost/connect/oauth2/authorize?code=SECRET_AUTH_CODE');
          await request.response.close();
          return;
        }
        if (requireLogin) {
          request.response.statusCode = 302;
          request.response.headers
              .set(HttpHeaders.locationHeader, redirectLocation);
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.html;
        response = path == '/mobile/libseat'
            ? 'window.loginUser={"isAnonymous":false};'
                'window.sessionId="SESSION_LIB";'
            : 'window.loginUser={"isAnonymous":false,'
                '"sessionId":"SESSION_24H"};';
      } else if (path == '/api/v3/my/profile') {
        response = {
          'code': 0,
          'data': {
            'id': 'USER_1',
            'name': '测试用户',
            'loginName': 'STUDENT_1',
            'isAnonymous': false,
          },
        };
      } else if (path == '/api/v3/booking-status/areas/AREA_1') {
        response = {
          'code': 0,
          'data': {
            'bookingTimes': {'supportAcrossDayBooking': false},
            'rooms': [
              {
                'id': 'ROOM_1',
                'name': '2E015',
                'officeAreaId': 'AREA_1',
                'disabled': false,
                'isBusy': false,
                'isBooked': false,
                'abilities': ['booking'],
              },
            ],
          },
        };
      } else if (path == '/api/v3/bookings' && method == 'POST') {
        createdBody = jsonDecode(await utf8.decodeStream(request))
            as Map<String, dynamic>;
        response = rejected
            ? {'code': 200, 'warnMessage': '超过预约天数'}
            : {
                'code': 0,
                'data': [
                  {'id': 'BOOKING_1'},
                ],
              };
      } else if (path == '/api/v3/bookings/BOOKING_1') {
        response = {
          'code': 0,
          'data': {
            'id': 'BOOKING_1',
            'abilities':
                detailAbilities[request.headers.value('x-room-type')] ??
                    (request.headers.value('x-room-type') == 'STATION'
                        ? ['close']
                        : ['cancel']),
          },
        };
      } else if (path == '/api/v3/bookings/BOOKING_1/cancel') {
        response = {'code': 0, 'data': {}};
      } else if (path == '/api/v3/bookings/BOOKING_1/finish') {
        response = {'code': 0, 'data': {}};
      } else {
        request.response.statusCode = 404;
        response = {'error': 'unhandled'};
      }
      request.response.write(
        response is String ? response : jsonEncode(response),
      );
      await request.response.close();
    });
    client = ThereBookingClient(
      serviceUri: Uri.parse('http://127.0.0.1:${server.port}'),
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
  });

  tearDown(() async {
    client.dispose();
    await requests.cancel();
    await server.close(force: true);
  });

  test('each venue uses its own mobile session and room type', () async {
    await client.selectVenue(BookingVenue.library);
    await client.profile();
    await client.selectVenue(BookingVenue.studySpace);
    await client.profile();
    expect(seen, contains('GET /api/v3/my/profile LIB_SEAT SESSION_LIB'));
    expect(seen, contains('GET /api/v3/my/profile STATION SESSION_24H'));
  });

  test('an active venue reuses its mobile session within the client', () async {
    await client.selectVenue(BookingVenue.library);
    await client.selectVenue(BookingVenue.library);
    await client.profile();
    expect(
      seen.where((entry) => entry.startsWith('GET /mobile/libseat')),
      hasLength(1),
    );
    expect(seen, contains('GET /api/v3/my/profile LIB_SEAT SESSION_LIB'));
  });

  test('refreshing the venue obtains a new business session', () async {
    await client.selectVenue(BookingVenue.library);
    await client.refreshVenue(BookingVenue.library);
    expect(
      seen.where((entry) => entry.startsWith('GET /mobile/libseat')),
      hasLength(2),
    );
  });

  test('create rechecks the seat and cancel uses the server action', () async {
    await client.selectVenue(BookingVenue.library);
    final id = await client.create(
      areaId: 'AREA_1',
      roomId: 'ROOM_1',
      day: '2026-10-03',
      start: '08:30',
      end: '09:30',
    );
    expect(id, 'BOOKING_1');
    expect(createdBody?['subject'], '测试用户');
    expect(createdBody?['meetingMembers'], ['USER_1']);
    expect((createdBody?['rooms'] as List).single['id'], 'ROOM_1');
    expect(seen, contains('POST /api/v3/bookings LIB_SEAT SESSION_LIB'));
    await client.cancel(id);
    expect(
        seen,
        contains('DELETE /api/v3/bookings/BOOKING_1/cancel '
            'LIB_SEAT SESSION_LIB'));
    expect(
        seen.where(
            (entry) => entry.startsWith('GET /api/v3/bookings/BOOKING_1 ')),
        hasLength(1));
  });

  test('cancel and finish follow fresh detail abilities across room types',
      () async {
    detailAbilities[BookingVenue.library.roomType] = ['close'];
    await client.selectVenue(BookingVenue.library);
    await expectLater(
      client.cancel('BOOKING_1'),
      throwsA(isA<ThereBookingException>()
          .having((error) => error.message, 'message', '当前预约不可取消')),
    );
    expect(seen.where((entry) => entry.contains('/BOOKING_1/cancel')), isEmpty);
    await client.finish('BOOKING_1');
    expect(seen,
        contains('PUT /api/v3/bookings/BOOKING_1/finish LIB_SEAT SESSION_LIB'));

    detailAbilities[BookingVenue.studySpace.roomType] = ['cancel'];
    await client.selectVenue(BookingVenue.studySpace);
    await expectLater(
      client.finish('BOOKING_1'),
      throwsA(isA<ThereBookingException>()
          .having((error) => error.message, 'message', '当前预约不可退座')),
    );
    expect(
        seen.where((entry) =>
            entry.startsWith('PUT /api/v3/bookings/BOOKING_1/finish')),
        hasLength(1));
    await client.cancel('BOOKING_1');
    expect(
        seen,
        contains('DELETE /api/v3/bookings/BOOKING_1/cancel '
            'STATION SESSION_24H'));
  });

  test('next-day library booking sends the selected date and time', () async {
    await client.selectVenue(BookingVenue.library);
    await client.create(
      areaId: 'AREA_1',
      roomId: 'ROOM_1',
      day: '2026-10-19',
      start: '20:30',
      end: '22:00',
    );
    expect(createdBody?['times'], [
      {
        'startDate': '2026-10-19',
        'startTime': '20:30',
        'endDate': '2026-10-19',
        'endTime': '22:00',
      },
    ]);
  });

  test('HTTP 200 with a rejected business code is not success', () async {
    rejected = true;
    await client.selectVenue(BookingVenue.library);
    await expectLater(
      client.create(
        areaId: 'AREA_1',
        roomId: 'ROOM_1',
        day: '2026-10-03',
        start: '08:30',
        end: '09:30',
      ),
      throwsA(isA<ThereBookingException>().having(
        (error) => error.message,
        'message',
        '超过预约天数',
      )),
    );
    expect(seen.where((entry) => entry.startsWith('POST /api/v3/bookings')),
        hasLength(1));
  });

  test('24H early finish is only sent when detail allows close', () async {
    await client.selectVenue(BookingVenue.studySpace);
    await client.finish('BOOKING_1');
    expect(
        seen,
        contains('PUT /api/v3/bookings/BOOKING_1/finish '
            'STATION SESSION_24H'));
  });

  test('there bootstrap cookie is carried through OAuth callback', () async {
    final state = await client.prepareOAuth();
    expect(state, bootstrapState);
    await client.completeOAuth(callbackUri(state));
    expect(requestQueries['/login-oauth2']?['state'], state);
    expect(requestCookies['/login-oauth2'], contains('SPHYS_SESSION=prewarm'));
    expect(requestCookies['/web'], contains('SPHYS_SESSION=authenticated'));
    expect(
      seen.where((entry) => entry.startsWith('GET /api/v3/my/profile')),
      isEmpty,
    );
    expect(await client.profile(), containsPair('id', 'USER_1'));
  });

  for (final entry in <String, String?>{'missing': null, 'empty': ''}.entries) {
    test('OAuth bootstrap rejects a ${entry.key} state and forgets old state',
        () async {
      final previousState = await client.prepareOAuth();
      bootstrapState = entry.value;
      await expectLater(
        client.prepareOAuth(),
        throwsA(isA<ThereBookingException>()),
      );
      await expectLater(
        client.completeOAuth(callbackUri(previousState)),
        throwsA(isA<ThereBookingException>()),
      );
      expect(requestQueries.containsKey('/login-oauth2'), isFalse);
    });
  }

  for (final entry in <String, String?>{
    'missing': null,
    'mismatched': 'OTHER_STATE',
  }.entries) {
    test('OAuth callback rejects a ${entry.key} state before requesting there',
        () async {
      await client.prepareOAuth();
      await expectLater(
        client.completeOAuth(callbackUri(entry.value)),
        throwsA(isA<ThereBookingException>().having(
          (error) => error.message,
          'message',
          contains('授权状态校验失败'),
        )),
      );
      expect(requestQueries.containsKey('/login-oauth2'), isFalse);
    });
  }

  test('OAuth callback rejects duplicate state parameters', () async {
    final state = await client.prepareOAuth();
    final callback = Uri.parse(
        '${callbackUri(state)}&state=${Uri.encodeQueryComponent(state)}');
    await expectLater(
      client.completeOAuth(callback),
      throwsA(isA<ThereBookingException>()),
    );
    expect(requestQueries.containsKey('/login-oauth2'), isFalse);
  });

  test('a new OAuth bootstrap replaces the previous expected state', () async {
    final previousState = await client.prepareOAuth();
    bootstrapState = 'NEXT_SERVER_STATE';
    final state = await client.prepareOAuth();
    await expectLater(
      client.completeOAuth(callbackUri(previousState)),
      throwsA(isA<ThereBookingException>()),
    );
    expect(requestQueries.containsKey('/login-oauth2'), isFalse);
    await client.completeOAuth(callbackUri(state));
    expect(requestQueries['/login-oauth2']?['state'], state);
  });

  test('resetting the session invalidates pending OAuth state', () async {
    final state = await client.prepareOAuth();
    client.resetSession();
    await expectLater(
      client.completeOAuth(callbackUri(state)),
      throwsA(isA<ThereBookingException>()),
    );
    expect(requestQueries.containsKey('/login-oauth2'), isFalse);
  });

  test('a completed OAuth state cannot be reused', () async {
    final state = await client.prepareOAuth();
    await client.completeOAuth(callbackUri(state));
    final callbacks =
        seen.where((entry) => entry.startsWith('GET /login-oauth2')).length;
    await expectLater(
      client.completeOAuth(callbackUri(state)),
      throwsA(isA<ThereBookingException>()),
    );
    expect(seen.where((entry) => entry.startsWith('GET /login-oauth2')).length,
        callbacks);
  });

  test('HTTP there landing is upgraded to HTTPS without changing its token',
      () {
    final secureClient = ThereBookingClient(
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
    addTearDown(secureClient.dispose);
    final landing = secureClient.normalizeServiceRedirect(Uri.parse(
      'http://there.shu.edu.cn/web?authJump=SECRET_TOKEN',
    ));
    expect(landing?.origin, 'https://there.shu.edu.cn');
    expect(landing?.path, '/web');
    expect(landing?.queryParameters['authJump'], 'SECRET_TOKEN');
    expect(
      secureClient.normalizeServiceRedirect(
          Uri.parse('http://other.shu.edu.cn/web?authJump=SECRET_TOKEN')),
      isNull,
    );
    expect(
      secureClient.normalizeServiceRedirect(
          Uri.parse('http://there.shu.edu.cn:8080/web')),
      isNull,
    );
  });

  test('proxied there uses portal token without copying direct cookies',
      () async {
    final proxyClient = ThereBookingClient(
      serviceUri: Uri.parse('http://127.0.0.1:${server.port}'),
      useWebVpn: true,
      cookieLoader: (uri) async => uri.host == 'webvpn.shu.edu.cn'
          ? [
              SessionCookie(
                name: 'webvpn-token',
                value: 'GATEWAY_TOKEN',
                domain: 'webvpn.shu.edu.cn',
              ),
            ]
          : [],
      cookieSetter: (_) async {},
    );
    addTearDown(proxyClient.dispose);
    await proxyClient.selectVenue(BookingVenue.library);
    expect(requestCookies['/mobile/libseat'],
        contains('webvpn-token=GATEWAY_TOKEN'));
    expect(requestCookies['/mobile/libseat'], isNot(contains('SPHYS_SESSION')));
    final state = await proxyClient.prepareOAuth();
    await proxyClient.completeOAuth(callbackUri(state, proxy: true));
    expect(requestQueries['/login-oauth2']?['state'], state);
    expect(requestCookies['/login-oauth2'], contains('SPHYS_SESSION=prewarm'));
    expect(await proxyClient.profile(), containsPair('id', 'USER_1'));
  });

  test('proxy mode keeps there landing on the proxy HTTPS host', () {
    final proxyClient = ThereBookingClient(
      useWebVpn: true,
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
    addTearDown(proxyClient.dispose);
    final landing = proxyClient.normalizeServiceRedirect(Uri.parse(
      'http://there.shu.edu.cn/web?authJump=SECRET_TOKEN',
    ));
    expect(landing?.host, 'https-there-shu-edu-cn-443.webvpn.shu.edu.cn');
    expect(landing?.scheme, 'https');
    expect(landing?.queryParameters['authJump'], 'SECRET_TOKEN');
    expect(
      proxyClient
          .normalizeServiceRedirect(Uri.parse('http://other.shu.edu.cn/web')),
      isNull,
    );
  });

  test('proxy portal redirect is reported as WebVPN login required', () async {
    redirectToWebVpnPortal = true;
    final proxyClient = ThereBookingClient(
      serviceUri: Uri.parse('http://127.0.0.1:${server.port}'),
      useWebVpn: true,
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
    addTearDown(proxyClient.dispose);
    await expectLater(
      proxyClient.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>().having(
        (error) => error.kind,
        'kind',
        ThereFailureKind.webVpnLoginRequired,
      )),
    );
  });

  test('there callback diagnostics redact the code, state and landing token',
      () async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = previous);
    bootstrapState = 'SECRET_STATE';
    final state = await client.prepareOAuth();
    await client.completeOAuth(callbackUri(state, code: 'SECRET_CODE'));
    final log = logs.join('\n');
    expect(log, contains('path=/login-oauth2 status=302'));
    expect(log, isNot(contains('SECRET_CODE')));
    expect(log, isNot(contains('SECRET_STATE')));
    expect(log, isNot(contains('authJump=token')));
  });

  test('account matching accepts either loginName or jobNumber', () {
    expect(
      ThereBookingClient.matchesAccount(
          {'loginName': 'internal', 'jobNumber': 'STUDENT_1'}, 'student_1'),
      isTrue,
    );
    expect(
      ThereBookingClient.matchesAccount(
          {'loginName': 'ANOTHER', 'jobNumber': 'OTHER'}, 'STUDENT_1'),
      isFalse,
    );
  });

  test('API timing route names omit area and booking identifiers', () {
    expect(
      ThereBookingClient.routeForLog(
          '/api/v3/booking-status/areas/SECRET_AREA_ID'),
      '/api/v3/booking-status/areas/{areaId}',
    );
    expect(
      ThereBookingClient.routeForLog(
          '/api/v3/bookings/SECRET_BOOKING_ID/cancel'),
      '/api/v3/bookings/{bookingId}/cancel',
    );
  });

  test('an explicit login redirect is classified separately from an outage',
      () async {
    requireLogin = true;
    await expectLater(
      client.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>().having(
        (error) => error.kind,
        'kind',
        ThereFailureKind.loginRequired,
      )),
    );
  });

  test('WeCom-only mobile redirect retries once as a plain app request',
      () async {
    weChatRedirectForMarked = true;
    await client.selectVenue(BookingVenue.library);
    expect(await client.profile(), containsPair('id', 'USER_1'));
    expect(mobileModes, ['wework-header', 'plain']);
  });

  test('proxied WeChat redirect uses the same plain retry', () async {
    weChatRedirectForMarked = true;
    weChatRedirectHost = 'https-open-weixin-qq-com-443.webvpn.shu.edu.cn';
    final proxyClient = ThereBookingClient(
      serviceUri: Uri.parse('http://127.0.0.1:${server.port}'),
      useWebVpn: true,
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
    addTearDown(proxyClient.dispose);
    await proxyClient.selectVenue(BookingVenue.library);
    expect(await proxyClient.profile(), containsPair('id', 'USER_1'));
    expect(mobileModes, ['wework-header', 'plain']);
  });

  test('persistent proxied WeChat redirect first requests there login',
      () async {
    weChatRedirectForAll = true;
    weChatRedirectHost = 'https-open-weixin-qq-com-443.webvpn.shu.edu.cn';
    final proxyClient = ThereBookingClient(
      serviceUri: Uri.parse('http://127.0.0.1:${server.port}'),
      useWebVpn: true,
      cookieLoader: (_) async => [],
      cookieSetter: (_) async {},
    );
    addTearDown(proxyClient.dispose);
    await expectLater(
      proxyClient.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>().having(
        (error) => error.kind,
        'kind',
        ThereFailureKind.loginRequired,
      )),
    );
    expect(mobileModes, ['wework-header', 'plain']);
  });

  test('a persistent WeChat redirect tries SSO before reporting a gap',
      () async {
    weChatRedirectForAll = true;
    await expectLater(
      client.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>().having(
          (error) => error.kind, 'kind', ThereFailureKind.loginRequired)),
    );
    final state = await client.prepareOAuth();
    await expectLater(
      client.completeOAuth(callbackUri(state)),
      throwsA(isA<ThereBookingException>()
          .having((error) => error.kind, 'kind', ThereFailureKind.uncertain)
          .having((error) => error.message, 'message', contains('微信授权'))),
    );
    expect(mobileModes, ['wework-header', 'plain', 'wework-header', 'plain']);
  });

  test('mobile entry log reports status without redirect secrets', () async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = previous);
    requireLogin = true;
    await expectLater(
      client.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>()),
    );
    final log =
        logs.where((line) => line.contains('[THERE_BOOKING]')).join('\n');
    expect(log, contains('status=302'));
    expect(log, contains('redirect=http://127.0.0.1/login'));
    expect(log, isNot(contains('SECRET_AUTH_CODE')));
    expect(log, isNot(contains('code=')));
    redirectLocation = '/callback/SHORT_SECRET?code=SECRET_AUTH_CODE';
    await expectLater(
      client.selectVenue(BookingVenue.library),
      throwsA(isA<ThereBookingException>()),
    );
    expect(logs.join('\n'), isNot(contains('SHORT_SECRET')));
  });
}
