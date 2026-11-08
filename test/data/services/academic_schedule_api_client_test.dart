import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';

String fixture(String name) =>
    File('test/fixtures/academic_schedule/$name').readAsStringSync();

class _Auth extends AcademicAuthService {
  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => 'JSESSIONID=test';
}

void main() {
  test('captured selectors enumerate terms and respect legacy winter range',
      () {
    final catalog =
        AcademicScheduleApiClient.parseTermCatalog(fixture('term_index.html'));
    expect(catalog.currentTerm.key, '2026:3');
    expect(catalog.currentTerm.academicYearName, '2026-2027');
    expect(catalog.terms, hasLength(80));
    expect(catalog.terms.first.key, '2026:3');
    expect(catalog.terms.where((q) => q.yearCode == '2024').map((q) => q.key),
        ['2024:3', '2024:12', '2024:16', '2024:32']);
    expect(catalog.terms.any((q) => q.key == '2024:12'), isTrue);
    expect(catalog.terms.any((q) => q.key == '2025:12'), isFalse);
    expect(catalog.terms.map((q) => q.key).toSet(), hasLength(80));
    expect(catalog.terms.any((q) => q.yearCode.isEmpty), isFalse);
  });

  test('hidden inputs still identify a default term without dropdowns', () {
    final catalog = AcademicScheduleApiClient.parseTermCatalog('''
      <input name="xnm" value="2026"><input name="xqm" value="3">
      <input name="xnmc" value="2026-2027"><input name="xqmmc" value="秋">
    ''');
    expect(catalog.currentTerm.key, '2026:3');
    expect(catalog.terms, hasLength(1));
  });

  test('explicit query posts requested codes and parses historical response',
      () async {
    final api = AcademicScheduleApiClient(
      authService: _Auth(),
      httpClient: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, endsWith('xskbcx_cxXsgrkb.html'));
        final form = Uri.splitQueryString(request.body);
        expect(form['xnm'], '2025');
        expect(form['xqm'], '3');
        expect(form['kzlx'], 'ck');
        expect(request.headers['cookie'], 'JSESSIONID=test');
        return http.Response(fixture('historical_schedule.json'), 200,
            headers: {'content-type': 'application/json;charset=UTF-8'});
      }),
    );
    final schedule = await api.fetchScheduleForTerm(
        const AcademicTermQuery(yearCode: '2025', termCode: '3'));
    expect(schedule.term.studentId, 'TEST_STUDENT');
    expect(schedule.term.admissionYearCode, '2025');
    expect(schedule.sessions, hasLength(20));
    expect(schedule.untimedCourses, hasLength(1));
    expect(schedule.toJson()['term']['admissionYearCode'], '2025');
  });

  test('verified empty JSON remains a valid response, not an auth error',
      () async {
    final api = AcademicScheduleApiClient(
      authService: _Auth(),
      httpClient: MockClient((_) async => http.Response(
          fixture('empty_schedule.json'), 200,
          headers: {'content-type': 'application/json;charset=UTF-8'})),
    );
    final schedule = await api.fetchScheduleForTerm(
        const AcademicTermQuery(yearCode: '2022', termCode: '16'));
    expect(schedule.sessions, isEmpty);
    expect(schedule.untimedCourses, isEmpty);
    expect(schedule.term.admissionYearCode, '2025');
  });

  test('default-term fallback response cannot be saved under requested term',
      () async {
    final api = AcademicScheduleApiClient(
      authService: _Auth(),
      httpClient: MockClient((_) async => http.Response(
          fixture('historical_schedule.json'), 200,
          headers: {'content-type': 'application/json;charset=UTF-8'})),
    );
    await expectLater(
      api.fetchScheduleForTerm(
          const AcademicTermQuery(yearCode: '2024', termCode: '3')),
      throwsA(isA<AcademicApiException>()),
    );
  });

  test('malformed course data is not interpreted as an empty timetable',
      () async {
    final body = jsonDecode(fixture('empty_schedule.json')) as Map;
    body['sjkList'] = 'invalid';
    final api = AcademicScheduleApiClient(
      authService: _Auth(),
      httpClient: MockClient((_) async => http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json;charset=UTF-8'})),
    );
    await expectLater(
      api.fetchScheduleForTerm(
          const AcademicTermQuery(yearCode: '2022', termCode: '16')),
      throwsA(isA<AcademicApiException>()),
    );
  });

  for (final status in [401, 403]) {
    test('HTTP $status pauses discovery as authentication failure', () async {
      final api = AcademicScheduleApiClient(
        authService: _Auth(),
        httpClient: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(
        api.fetchScheduleForTerm(
            const AcademicTermQuery(yearCode: '2025', termCode: '3')),
        throwsA(isA<AcademicAuthException>()),
      );
    });
  }
}
