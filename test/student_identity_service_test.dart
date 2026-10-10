import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
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
    reads++;
    return 'JSESSIONID=school-session';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
        expect(body['schoolCookie'], 'JSESSIONID=school-session');
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
        expect(body['schoolCookie'], 'JSESSIONID=fresh-login');
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
      schoolCookie: 'JSESSIONID=fresh-login',
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
    final service = StudentIdentityService(
      secureStore: secure,
      accountStore: accounts,
      academicAuthService: _SchoolAuth(),
      preferencesLoader: () async =>
          throw StateError('preferences unavailable'),
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
