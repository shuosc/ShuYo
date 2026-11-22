import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/graduate_session_store.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/student_identity_service.dart';

class _MemorySecureStore extends SecureAppStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _SchoolAuth extends AcademicAuthService {
  _SchoolAuth()
      : super(cookieLoader: (_) async => const [], cookieSetter: (_) async {});

  int reads = 0;

  @override
  Future<String?> cookieHeaderForIdentityVerification(
      {required Uri targetUri}) async {
    expect(targetUri, AcademicUrlResolver.studentIdentityUri);
    reads++;
    return 'JSESSIONID=school-session; SHU_OAUTH2=must-not-leave-app';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'YJS verifies with its own scoped cookie and reuses the same student identity',
      () async {
    final accounts = AcademicAccountStore();
    const studentId = '23abc456';
    await accounts.saveStudentId(studentId, system: CampusSystem.graduate);
    await accounts.saveSystem(CampusSystem.graduate);
    final secure = _MemorySecureStore();
    final jar = SessionCookieJar(secureStore: secure);
    final graduate = GraduateSessionStore(cookieJar: jar, secureStore: secure);
    for (final cookie in const [
      SessionCookie(
          name: 'GS_SESSIONID',
          value: 'yjs-fixture',
          domain: GraduateSessionStore.host,
          path: '/gsapp/'),
      SessionCookie(
          name: 'GS_SESSIONID',
          value: 'wrong-path',
          domain: GraduateSessionStore.host,
          path: '/separate/'),
      SessionCookie(
          name: 'GS_SESSIONID',
          value: 'parent-domain',
          domain: 'shu.edu.cn',
          path: '/gsapp/'),
      SessionCookie(
          name: 'SHU_OAUTH2',
          value: 'sso-fixture',
          domain: 'newsso.shu.edu.cn'),
      SessionCookie(
          name: 'JSESSIONID', value: 'jwxt-fixture', domain: 'jwxt.shu.edu.cn'),
    ]) {
      await jar.setCookie(cookie);
    }
    final school = _SchoolAuth();
    var enrollments = 0;
    final service = StudentIdentityService(
      accountStore: accounts,
      secureStore: secure,
      academicAuthService: school,
      graduateSessionStore: graduate,
      httpClient: MockClient((request) async {
        if (request.method == 'GET') return http.Response('{}', 200);
        expect(request.url.path, '/api/v1/student/sessions');
        expect(request.followRedirects, isFalse);
        expect(
            jsonDecode(request.body),
            containsPair('schoolSession', {
              'source': 'yjs',
              'cookie': 'GS_SESSIONID=yjs-fixture',
            }));
        expect(jsonDecode(request.body)['expectedStudentId'], studentId);
        expect(jsonDecode(request.body)['userInitiated'], isTrue);
        enrollments++;
        return _issuedSession();
      }),
    );
    addTearDown(service.dispose);
    await expectLater(service.bindCurrentStudent(manual: true),
        throwsA(isA<StudentIdentityException>()));
    expect(enrollments, 0);
    await service.grantConsent();
    await service.ensureAfterCampusLogin();
    expect(enrollments, 1);
    expect((await service.checkCurrentSession())?.studentId, studentId);

    await accounts.saveStudentId(studentId.toUpperCase());
    await accounts.saveSystem(CampusSystem.undergraduate);
    expect(
        (await service.bindCurrentStudent(manual: true)).studentId, studentId);
    expect(enrollments, 1);
    expect(school.reads, 0);

    await accounts.saveStudentId('another-campus-account');
    expect(await service.checkCurrentSession(), isNull);
    expect(service.isVerified, isFalse);
  });

  test('an enrollment finishing after a school switch cannot install its token',
      () async {
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    final secure = _MemorySecureStore();
    final started = Completer<void>();
    final reply = Completer<http.Response>();
    final service = StudentIdentityService(
      accountStore: accounts,
      secureStore: secure,
      academicAuthService: _SchoolAuth(),
      httpClient: MockClient((request) {
        if (request.method == 'POST') {
          started.complete();
          return reply.future;
        }
        expect(request.method, 'DELETE');
        expect(request.headers['authorization'], 'Bearer ${'a' * 43}');
        return Future.value(http.Response('', 204));
      }),
    );
    addTearDown(service.dispose);
    await service.grantConsent();
    final rejected = expectLater(service.bindCurrentStudent(manual: true),
        throwsA(isA<StudentIdentityException>()));
    await started.future;
    await accounts.saveStudentId('23123456', system: CampusSystem.graduate);
    await accounts.saveSystem(CampusSystem.graduate);
    reply.complete(_issuedSession());
    await rejected;
    expect(secure.values['shuyo.student.session.v1'], isNull);
    expect(service.isVerified, isFalse);
  });

  test('binds only after consent, then reuses the ShuYo session', () async {
    final secure = _MemorySecureStore();
    final school = _SchoolAuth();
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    var enrollmentCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/student/session') {
        return http.Response('{"success":true,"data":{}}', 200);
      }
      if (request.url.path == '/api/v1/student/sessions') {
        enrollmentCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['schoolSession'], {
          'source': 'jwxt',
          'cookie': 'JSESSIONID=school-session',
        });
        expect(body['expectedStudentId'], '23123456');
        expect(body['userInitiated'], isTrue);
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'token': 'a' * 43,
              'maskedStudentId': '23****56',
              'expiresAt': '2099-01-01T00:00:00Z',
            }
          }),
          201,
        );
      }
      return http.Response('{}', 500);
    });
    final service = StudentIdentityService(
      secureStore: secure,
      accountStore: accounts,
      academicAuthService: school,
      httpClient: client,
    );
    await service.ensureAfterCampusLogin();
    expect(school.reads, 0);
    expect(await service.ensureForProtectedAction(), isFalse);
    await service.grantConsent();
    await service.ensureAfterCampusLogin();
    expect(school.reads, 1);
    expect(enrollmentCount, 1);
    expect((await service.loadLocalSession())?.studentId, '23123456');
    await service.ensureAfterCampusLogin();
    expect(enrollmentCount, 1);
    expect(await service.ensureForProtectedAction(), isTrue);
    expect(school.reads, 1);
    service.dispose();
  });

  test('manual revocation stops silent reauthentication until user verifies',
      () async {
    final secure = _MemorySecureStore();
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    var enrollmentCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/student/sessions') {
        enrollmentCount++;
        return http.Response(
          jsonEncode({
            'data': {
              'token': 'a' * 43,
              'maskedStudentId': '23****56',
              'expiresAt': '2099-01-01T00:00:00Z',
            }
          }),
          201,
        );
      }
      if (request.url.path == '/api/v1/student/session' &&
          request.method == 'DELETE') {
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/student/session') {
        return http.Response('{}', 200);
      }
      return http.Response('{}', 500);
    });
    final service = StudentIdentityService(
      secureStore: secure,
      accountStore: accounts,
      academicAuthService: _SchoolAuth(),
      httpClient: client,
    );
    await service.grantConsent();
    await service.bindCurrentStudent(manual: true);
    await service.signOut();
    await service.ensureAfterCampusLogin();
    expect(await service.ensureForProtectedAction(), isFalse);
    expect(enrollmentCount, 1);
    await service.bindCurrentStudent(manual: true);
    expect(enrollmentCount, 2);
    expect(await service.ensureForProtectedAction(), isTrue);
    service.dispose();
  });

  test('server-side revocation on another device requires manual renewal',
      () async {
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    var enrollmentCount = 0;
    var sessionChecks = 0;
    final service = StudentIdentityService(
      secureStore: _MemorySecureStore(),
      accountStore: accounts,
      academicAuthService: _SchoolAuth(),
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/student/sessions') {
          enrollmentCount++;
          return http.Response(
            jsonEncode({
              'data': {
                'token': 'a' * 43,
                'maskedStudentId': '23****56',
                'expiresAt': '2099-01-01T00:00:00Z',
              }
            }),
            201,
          );
        }
        if (request.url.path == '/api/v1/student/session') {
          sessionChecks++;
          return http.Response('{"error":"revoked"}', 401);
        }
        return http.Response('{}', 500);
      }),
    );
    await service.grantConsent();
    await service.bindCurrentStudent(manual: true);
    expect(await service.hasConsent(), isTrue);
    expect(await service.ensureForProtectedAction(), isFalse);
    expect(sessionChecks, 1);
    expect(await service.loadLocalSession(), isNull);
    await service.ensureAfterCampusLogin();
    expect(enrollmentCount, 1);
    await service.bindCurrentStudent(manual: true);
    expect(enrollmentCount, 2);
    service.dispose();
  });

  test('deletion verification works without a device session', () async {
    final secure = _MemorySecureStore();
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/student/data-deletion/verify') {
        expect(request.method, 'POST');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['schoolSession'], {
          'source': 'yjs',
          'cookie': 'GS_SESSIONID=fresh-login',
        });
        expect(body['expectedStudentId'], '23123456');
        return http.Response(
          jsonEncode({
            'data': {
              'token': 'b' * 43,
              'maskedStudentId': '23****56',
              'expiresAt': '2099-01-01T00:00:00Z',
            }
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/student/data') {
        expect(request.method, 'DELETE');
        expect(jsonDecode(request.body)['token'], 'b' * 43);
        return http.Response('', 204);
      }
      return http.Response('{}', 500);
    });
    final service = StudentIdentityService(
      secureStore: secure,
      httpClient: client,
    );
    await service.grantConsent();
    final grant = await service.beginDataDeletion(
      system: CampusSystem.graduate,
      schoolCookie: 'GS_SESSIONID=fresh-login; SHU_OAUTH2=must-not-leave-app',
      expectedStudentId: '23123456',
    );
    expect(grant.maskedStudentId, '23****56');
    await service.completeDataDeletion(grant);
    expect(await service.hasConsent(), isFalse);
    expect(service.isVerified, isFalse);
    service.dispose();
  });

  test('deleting another verified student does not clear this device',
      () async {
    final secure = _MemorySecureStore();
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    final service = StudentIdentityService(
      secureStore: secure,
      accountStore: accounts,
      academicAuthService: _SchoolAuth(),
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/v1/student/sessions') {
          return http.Response(
            jsonEncode({
              'data': {
                'token': 'a' * 43,
                'maskedStudentId': '23****56',
                'expiresAt': '2099-01-01T00:00:00Z',
              }
            }),
            201,
          );
        }
        if (request.url.path == '/api/v1/student/data') {
          return http.Response('', 204);
        }
        return http.Response('{}', 500);
      }),
    );
    await service.grantConsent();
    await service.bindCurrentStudent(manual: true);
    await service.completeDataDeletion(
      StudentDataDeletionGrant(
        token: 'b' * 43,
        studentId: '87654321',
        maskedStudentId: '87****21',
        expiresAt: DateTime.utc(2099),
      ),
    );
    expect((await service.loadLocalSession())?.studentId, '23123456');
    expect(await service.hasConsent(), isTrue);
    service.dispose();
  });

  test('preference cleanup failure does not turn a saved session into failure',
      () async {
    final secure = _MemorySecureStore();
    final accounts = AcademicAccountStore();
    await accounts.saveStudentId('23123456');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('shuyo.student.identity.consent.v1', true);
    var preferenceReads = 0;
    final service = StudentIdentityService(
      secureStore: secure,
      accountStore: accounts,
      academicAuthService: _SchoolAuth(),
      preferencesLoader: () async {
        if (++preferenceReads == 1) return prefs;
        throw StateError('preferences unavailable');
      },
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'data': {
                'token': 'a' * 43,
                'maskedStudentId': '23****56',
                'expiresAt': '2099-01-01T00:00:00Z',
              }
            }),
            201,
          )),
    );
    final session = await service.bindCurrentStudent(manual: true);
    expect(session.maskedStudentId, '23****56');
    expect((await service.loadLocalSession())?.token, session.token);
    expect(service.isVerified, isTrue);
    service.dispose();
  });
}

http.Response _issuedSession() => http.Response(
      jsonEncode({
        'data': {
          'token': 'a' * 43,
          'maskedStudentId': '23****56',
          'expiresAt': '2099-01-01T00:00:00Z',
        },
      }),
      201,
    );
