import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/graduate_schedule_api_client.dart';
import 'package:shuyo/data/services/graduate_session_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';

const _studentId = 'fixture-student';
const _module = '/gsapp/sys/wdkbapp';
const _entry = '$_module/*default/index.do';
const _catalog = '$_module/modules/xskcb/kfdxnxqcx.do';
const _schedule = '$_module/modules/xskcb/xspkjgcx.do';
const _host = GraduateSessionStore.host;
const _session = 'GS_SESSIONID=fixture-session';

void main() {
  late GraduateSessionStore store;
  late SessionCookieJar jar;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    jar = SessionCookieJar();
    store = GraduateSessionStore(cookieJar: jar);
    await store.replacePortalCookies(const [
      SessionCookie(
        name: 'GS_SESSIONID',
        value: 'fixture-session',
        domain: _host,
        path: '/gsapp/',
      ),
      SessionCookie(
        name: '_WEU',
        value: 'portal-context',
        domain: _host,
        path: '/gsapp/',
      ),
    ]);
  });

  GraduateScheduleApiClient client(
      http.Response Function(http.Request) respond) {
    final transport = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.authority, _host);
      expect(request.followRedirects, isFalse);
      return respond(request);
    });
    addTearDown(transport.close);
    return GraduateScheduleApiClient(
        sessionStore: store, httpClient: transport);
  }

  test('opens the module, uses fresh scoped cookies, and accepts an empty term',
      () async {
    await jar.setCookie(const SessionCookie(
      name: '_WEU',
      value: 'other-host-context',
      domain: 'newsso.shu.edu.cn',
    ));
    final calls = <String>[];
    final api = client((request) {
      final path = request.url.path;
      calls.add('${request.method} $path');
      final cookie = request.headers['cookie'];
      if (request.url == GraduateSessionStore.userInfoUri) {
        expect(cookie, _session);
        return _identity();
      }
      switch (path) {
        case _entry:
          expect(cookie, '$_session; _WEU=portal-context');
          expect(request.headers['referer'],
              GraduateSessionStore.portalUri.toString());
          return http.Response('<html></html>', 200, headers: {
            'set-cookie': [
              '_WEU=module-context; Path=/gsapp/; Secure; HttpOnly',
              '_WEU=foreign-context; Domain=shu.edu.cn; Path=$_module',
              '_WEU=other-path; Path=${_catalog}extra',
              '_WEU=expired; Path=$_module; Max-Age=0',
              'GS_SESSIONID=unverified-session; Path=/gsapp/',
            ].join(', '),
          });
        case _catalog:
          expect(request.headers['referer'], 'https://$_host$_entry');
          expect(cookie, '$_session; _WEU=module-context');
          expect(request.body, isEmpty);
          return _table('kfdxnxqcx', [
            {'XNXQDM': '20261'},
            {'XNXQDM': '20243'},
          ], headers: {
            'set-cookie': '_WEU=catalog-context; Path=/gsapp/',
          });
        case _schedule:
          expect(cookie, '$_session; _WEU=catalog-context');
          expect(request.bodyFields, {'XNXQDM': '20261', '*order': '-ZCBH'});
          return _table('xspkjgcx', []);
        default:
          throw StateError('Unexpected path: $path');
      }
    });

    final schedule = await api.fetchCurrentSchedule(studentId: _studentId);
    expect(schedule.term.displayName, '2026-2027 秋');
    expect(schedule.sessions, isEmpty);
    expect(calls, [
      'POST ${GraduateSessionStore.userInfoUri.path}',
      'GET $_entry',
      'POST $_catalog',
      'POST $_schedule',
    ]);
    // Read-only imports may not overwrite the app's account or portal cookies.
    expect((await store.loadCookies()).map((cookie) => cookie.value),
        ['fixture-session', 'portal-context']);
  });

  test('historical term merges consecutive sections without merging week masks',
      () async {
    final api = client((request) {
      if (request.url == GraduateSessionStore.userInfoUri) return _identity();
      if (request.url.path == _entry) return _modulePage();
      expect(request.url.path, _schedule);
      expect(request.headers['cookie'], '$_session; _WEU=module-context');
      expect(request.bodyFields['XNXQDM'], '20243');
      return _table('xspkjgcx', [
        _row(3, weeks: '0101'),
        _row(4, weeks: '0101'),
        _row(3, weeks: '1010'),
        _row(4, weeks: '1010'),
      ]);
    });
    final schedule = await api.fetchScheduleForTerm(
      const AcademicTermQuery(yearCode: '2024', termCode: '16'),
      studentId: _studentId,
    );
    expect(schedule.sessions, hasLength(2));
    expect(schedule.sessions.map((session) => session.sections), [
      [3, 4],
      [3, 4],
    ]);
    expect(
        schedule.sessions.map((session) => session.weeks),
        unorderedEquals([
          [1, 3],
          [2, 4]
        ]));
  });

  test('only the verified account may open the schedule module', () async {
    final api = client((request) {
      expect(request.url, GraduateSessionStore.userInfoUri);
      return _identity(studentId: 'other-student');
    });
    await expectLater(api.fetchTermCatalog(studentId: _studentId),
        throwsA(isA<AcademicAuthException>()));
  });

  for (final (description, response, isAuth) in [
    ('HTTP 403', http.Response('<html>403</html>', 403), false),
    ('JSON 403', http.Response('{"code":"403"}', 200), false),
    ('HTTP 401', http.Response('', 401), true),
    (
      'SSO redirect',
      http.Response('', 302, headers: {
        'location': 'https://newsso.shu.edu.cn/oauth/authorize',
      }),
      true,
    ),
  ]) {
    test('$description is classified without following redirects', () async {
      final api = client((request) {
        if (request.url == GraduateSessionStore.userInfoUri) return _identity();
        if (request.url.path == _entry) return _modulePage();
        expect(request.url.path, _catalog);
        return response;
      });
      await expectLater(
        api.fetchTermCatalog(studentId: _studentId),
        throwsA(isAuth
            ? isA<AcademicAuthException>()
            : allOf(
                isNot(isA<AcademicAuthException>()),
                isA<AcademicApiException>()
                    .having((error) => error.statusCode, 'statusCode', 403),
              )),
      );
    });
  }
}

http.Response _identity({String studentId = _studentId}) => http.Response(
      jsonEncode({
        'code': '0',
        'data': {'userId': studentId},
      }),
      200,
    );

http.Response _modulePage() => http.Response('<html></html>', 200,
    headers: {'set-cookie': '_WEU=module-context; Path=/gsapp/'});

http.Response _table(String action, List<Map<String, Object>> rows,
        {Map<String, String> headers = const {}}) =>
    http.Response(
      jsonEncode({
        'code': '0',
        'datas': {
          action: {'totalSize': rows.length, 'rows': rows},
        },
      }),
      200,
      headers: headers,
    );

Map<String, Object> _row(int section, {required String weeks}) => {
      'XNXQDM': '20243',
      'KCDM': 'demo',
      'BJDM': 'demo-class',
      'KCMC': 'Fixture course',
      'JSXM': 'Fixture teacher',
      'JASMC': 'Fixture room',
      'XQ': 2,
      'KSJCDM': section,
      'JSJCDM': section,
      'ZCBH': weeks,
    };
