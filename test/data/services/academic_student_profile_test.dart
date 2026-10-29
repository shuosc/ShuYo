import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_student_profile.dart';
import 'package:shuyo/data/repositories/academic_student_profile_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_student_profile_api_client.dart';

class _AuthWithCookie extends AcademicAuthService {
  _AuthWithCookie()
      : super(cookieLoader: (_) async => [], cookieSetter: (_) async {});

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => 'JSESSIONID=test';
}

const _response = '''
{"items":[{"xh":"DEMO0001","xm":"示例学生","njmc":"2025",
"jgmc":"示例学院","zymc":"示例专业","ccmc":" 本科 ","sfzh":"sensitive"}],"totalCount":1}
''';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('queries and caches only the current student profile', () async {
    final requests = <http.Request>[];
    var fail = false;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') return http.Response('<html></html>', 200);
      if (fail) return http.Response('unavailable', 503);
      return http.Response.bytes(utf8.encode(_response), 200,
          headers: {'content-type': 'application/json;charset=UTF-8'});
    });
    final repository = AcademicStudentProfileRepository(
      apiClient: AcademicStudentProfileApiClient(
        authService: _AuthWithCookie(),
        httpClient: client,
      ),
    );
    await AcademicAccountStore().saveStudentId('DEMO0001');
    final profile = await repository.refreshProfile();
    expect(profile.studentName, '示例学生');
    expect(profile.grade, '2025');
    expect(profile.collegeName, '示例学院');
    expect(profile.majorName, '示例专业');
    expect(profile.academicLevel, '本科');
    expect(profile.studentCategory, '本科生');
    expect(requests.length, 2);
    final post = requests.last;
    expect(post.method, 'POST');
    expect(post.url.path, '/jwglxt/xszsdy/xszsdy_cxXszsdyIndex.html');
    expect(post.url.queryParameters, {'doType': 'query', 'gnmkdm': 'N109835'});
    expect(post.headers['cookie'], 'JSESSIONID=test');
    expect(post.bodyFields['queryModel.sortName'], 'njmc desc,bj,xh ');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AcademicStudentProfileRepository.cacheKey),
        isNot(contains('sensitive')));

    fail = true;
    await expectLater(
        repository.refreshProfile(), throwsA(isA<AcademicApiException>()));
    expect((await repository.loadCachedProfile())?.grade, '2025');
    expect((await repository.loadCachedProfile())?.studentCategory, '本科生');
    await AcademicAccountStore().saveStudentId('OTHER');
    expect(await repository.loadCachedProfile(), isNull);
  });

  test('old cache remains readable and unknown levels are not guessed', () {
    final old = AcademicStudentProfile.fromJson({
      'studentId': 'DEMO0001',
      'studentName': '示例学生',
      'grade': '2025',
      'collegeName': '示例学院',
      'majorName': '示例专业',
    });
    expect(old.academicLevel, isEmpty);
    expect(old.studentCategory, isEmpty);
    final values = {
      '本科': '本科生',
      '本科生': '本科生',
      '研究生': '研究生',
      '硕士': '研究生',
      '博士': '研究生',
      '硕士研究生': '研究生',
      '博士研究生': '研究生',
      '专科': '',
      '未知': '',
    };
    for (final entry in values.entries) {
      final profile = AcademicStudentProfile.fromJson({
        ...old.toJson(),
        'academicLevel': entry.key,
      });
      expect(profile.studentCategory, entry.value, reason: entry.key);
    }
  });

  test('rejects another student and does not overwrite cached profile',
      () async {
    var response = _response;
    final repository = AcademicStudentProfileRepository(
      apiClient: AcademicStudentProfileApiClient(
        authService: _AuthWithCookie(),
        httpClient: MockClient((request) async => request.method == 'GET'
            ? http.Response('<html></html>', 200)
            : http.Response.bytes(utf8.encode(response), 200,
                headers: {'content-type': 'application/json;charset=UTF-8'})),
      ),
    );
    await AcademicAccountStore().saveStudentId('DEMO0001');
    await repository.refreshProfile();
    response = _response.replaceAll('DEMO0001', 'OTHER');
    await expectLater(repository.refreshProfile(), throwsFormatException);
    expect((await repository.loadCachedProfile())?.studentId, 'DEMO0001');
  });

  test('does not cache a response after the account changes', () async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final repository = AcademicStudentProfileRepository(
      apiClient: AcademicStudentProfileApiClient(
        authService: _AuthWithCookie(),
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response('<html></html>', 200);
          }
          requested.complete();
          return response.future;
        }),
      ),
    );
    await AcademicAccountStore().saveStudentId('DEMO0001');
    final pending = repository.refreshProfile();
    await requested.future;
    await AcademicAccountStore().saveStudentId('OTHER');
    response.complete(http.Response.bytes(utf8.encode(_response), 200,
        headers: {'content-type': 'application/json;charset=UTF-8'}));
    await expectLater(pending, throwsA(isA<AcademicAuthException>()));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AcademicStudentProfileRepository.cacheKey), isNull);
  });
}
