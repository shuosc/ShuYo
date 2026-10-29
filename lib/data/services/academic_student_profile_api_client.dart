import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/academic_url_resolver.dart';
import '../../core/client_user_agent.dart';
import '../models/academic_student_profile.dart';
import '../models/common.dart';
import 'academic_auth_service.dart';
import 'academic_schedule_api_client.dart';
import 'http_timeout.dart';

class AcademicStudentProfileApiClient {
  AcademicStudentProfileApiClient({
    AcademicAuthService? authService,
    http.Client? httpClient,
  })  : _authService = authService ?? AcademicAuthService(),
        _httpClient = httpClient ?? IOClient(HttpClient());

  static const _indexPath =
      '/jwglxt/xszsdy/xszsdy_cxXszsdyIndex.html?gnmkdm=N109835&layout=default';
  static const _queryPath =
      '/jwglxt/xszsdy/xszsdy_cxXszsdyIndex.html?doType=query&gnmkdm=N109835';

  final AcademicAuthService _authService;
  final http.Client _httpClient;

  Future<AcademicStudentProfile> fetchProfile({
    required String expectedStudentId,
  }) async {
    final studentId = expectedStudentId.trim();
    if (studentId.isEmpty) {
      throw const AcademicAuthException('请先登录上大校园账户');
    }
    final indexUri = AcademicUrlResolver.uri(_indexPath);
    final cookie = await _authService.cookieHeader(targetUri: indexUri);
    if (cookie == null || cookie.isEmpty) {
      throw const AcademicAuthException('请先登录上大校园账户');
    }
    final headers = {
      'cookie': cookie,
      'referer': indexUri.toString(),
      'user-agent': ClientUserAgent.mobileBrowser,
    };
    final index = await HttpTimeout.request(
      _httpClient.get(indexUri, headers: {
        ...headers,
        'accept': 'text/html,application/xhtml+xml',
      }),
      message: '学籍页面请求超时，请稍后重试',
    );
    _ensureResponse(index);
    final response = await HttpTimeout.request(
      _httpClient.post(
        AcademicUrlResolver.uri(_queryPath),
        headers: {
          ...headers,
          'accept': 'application/json, text/javascript, */*; q=0.01',
          'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'x-requested-with': 'XMLHttpRequest',
        },
        body: {
          '_search': 'false',
          'nd': DateTime.now().millisecondsSinceEpoch.toString(),
          'queryModel.showCount': '15',
          'queryModel.currentPage': '1',
          'queryModel.sortName': 'njmc desc,bj,xh ',
          'queryModel.sortOrder': 'asc',
          'time': '0',
        },
      ),
      message: '学籍信息请求超时，请稍后重试',
    );
    _ensureResponse(response);
    final decoded = jsonDecode(response.body);
    if (decoded is! JsonMap || decoded['items'] is! List) {
      throw const FormatException('教务系统返回了无法识别的学籍信息');
    }
    final matches = (decoded['items'] as List)
        .whereType<JsonMap>()
        .where((item) => stringValue(item['xh']).trim() == studentId)
        .toList();
    if (matches.length != 1) {
      throw const FormatException('教务系统未返回当前学号的学籍信息');
    }
    final item = matches.single;
    return AcademicStudentProfile(
      studentId: studentId,
      studentName: stringValue(item['xm']).trim(),
      grade: stringValue(item['njmc']).trim(),
      collegeName: stringValue(item['jgmc']).trim(),
      majorName: stringValue(item['zymc']).trim(),
      academicLevel: stringValue(item['ccmc']).trim(),
    );
  }

  void _ensureResponse(http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AcademicAuthException('教务登录已失效', response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AcademicApiException('教务系统学籍请求失败', statusCode: response.statusCode);
    }
    final lower = response.body.toLowerCase();
    if (lower.contains('/oauth2/login') ||
        lower.contains('newsso.shu.edu.cn') ||
        lower.contains('jwglxt/xtgl/login_slogin') ||
        lower.contains('name="yhm"')) {
      throw const AcademicAuthException('教务登录已失效，请重新登录');
    }
  }
}
