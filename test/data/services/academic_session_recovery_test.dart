import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_session_recovery.dart';

void main() {
  test('a successful request does not refresh the session', () async {
    var recoveries = 0;
    expect(
      await requestWithAcademicSessionRecovery(
        request: () async => 'schedule',
        recoverSession: () async {
          recoveries++;
          return true;
        },
      ),
      'schedule',
    );
    expect(recoveries, 0);
  });

  test('expired business session is restored before retrying the request',
      () async {
    final calls = <String>[];
    var expired = true;
    final result = await requestWithAcademicSessionRecovery(
      request: () async {
        calls.add('request');
        if (expired) throw const AcademicAuthException('expired', 901);
        return 'schedule';
      },
      recoverSession: () async {
        calls.add('SSO');
        expired = false;
        return true;
      },
    );
    expect(result, 'schedule');
    expect(calls, ['request', 'SSO', 'request']);
  });

  test('unavailable recovery does not retry or discard the request state',
      () async {
    var requests = 0;
    expect(
      await requestWithAcademicSessionRecovery<String>(
        request: () async {
          requests++;
          throw const AcademicAuthException('expired', 901);
        },
        recoverSession: () async => false,
      ),
      isNull,
    );
    expect(requests, 1);
  });

  test('persistent expiry attempts only one recovery and one retry', () async {
    var requests = 0;
    var recoveries = 0;
    await expectLater(
      requestWithAcademicSessionRecovery<String>(
        request: () async {
          requests++;
          throw const AcademicAuthException('expired', 901);
        },
        recoverSession: () async {
          recoveries++;
          return true;
        },
      ),
      throwsA(isA<AcademicAuthException>()),
    );
    expect(requests, 2);
    expect(recoveries, 1);
  });

  test('transport errors never trigger session recovery', () async {
    var recoveries = 0;
    const error = AcademicApiException('offline', statusCode: 503);
    await expectLater(
      requestWithAcademicSessionRecovery<String>(
        request: () async => throw error,
        recoverSession: () async {
          recoveries++;
          return true;
        },
      ),
      throwsA(same(error)),
    );
    expect(recoveries, 0);
  });

  test('an error during recovery is propagated without another request',
      () async {
    var requests = 0;
    final error = StateError('SSO unavailable');
    await expectLater(
      requestWithAcademicSessionRecovery<String>(
        request: () async {
          requests++;
          throw const AcademicAuthException('expired', 901);
        },
        recoverSession: () async => throw error,
      ),
      throwsA(same(error)),
    );
    expect(requests, 1);
  });
}
