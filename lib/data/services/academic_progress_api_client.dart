import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/academic_url_resolver.dart';
import '../../core/client_user_agent.dart';
import '../models/academic_progress.dart';
import 'academic_auth_service.dart';
import 'academic_progress_parser.dart';
import 'academic_schedule_api_client.dart';
import 'http_timeout.dart';

class AcademicProgressApiClient {
  AcademicProgressApiClient({
    AcademicAuthService? authService,
    http.Client? httpClient,
  })  : _authService = authService ?? AcademicAuthService(),
        _httpClient = httpClient ?? IOClient(HttpClient());

  static const studentIdentityPath =
      '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?echarts=1&gnmkdm=N105515&layout=default';
  static const _coursePath =
      '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html?gnmkdm=N105515';
  static const _otherCoursePath =
      '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqFKcxx.html?gnmkdm=N105515';
  static const _certificatePath =
      '/jwglxt/xsxy/xsxyqk_cxZgzsInfo.html?gnmkdm=N105515';

  final AcademicAuthService _authService;
  final http.Client _httpClient;

  /// QR authentication has no typed username. Resolve only the authenticated
  /// identity; do not fetch course details or update any academic data cache.
  Future<String> fetchAuthenticatedStudentId({String? sessionCookie}) async {
    final indexUri = AcademicUrlResolver.uri(studentIdentityPath);
    final cookie =
        sessionCookie ?? await _authService.cookieHeader(targetUri: indexUri);
    if (cookie == null || cookie.isEmpty) {
      throw const AcademicAuthException('请先登录上大校园账户');
    }
    final response = await HttpTimeout.request(
      _httpClient.get(indexUri, headers: _headers(cookie, indexUri)),
      message: '账户信息请求超时，请重新尝试登录',
    );
    _ensureResponse(response);
    final studentId = AcademicProgressParser.parseStudentId(response.body);
    if (studentId.isEmpty) {
      throw const AcademicApiException('未能确认登录学号，请重新尝试登录');
    }
    return studentId;
  }

  Future<AcademicProgress> fetchProgress() async {
    final indexUri = AcademicUrlResolver.uri(studentIdentityPath);
    final cookie = await _authService.cookieHeader(targetUri: indexUri);
    if (cookie == null || cookie.isEmpty) {
      throw const AcademicAuthException('请先登录上大校园账户');
    }
    final indexResponse = await HttpTimeout.request(
      _httpClient.get(indexUri, headers: _headers(cookie, indexUri)),
      message: '学业信息请求超时，请稍后重试',
    );
    _ensureResponse(indexResponse);
    final index = await compute(
      AcademicProgressParser.parseIndex,
      indexResponse.body,
    );
    if (index.studentId.isEmpty) {
      throw const AcademicApiException('教务系统未返回学号，无法同步学业信息');
    }

    final nodes = [...index.nodes];
    final leaves = <int>[
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i].isLeaf && nodes[i].id != 'zgzsxx') i,
    ];
    // The page itself requests one endpoint per leaf. Use bounded parallelism
    // and save only after every request succeeds, so cache is never partial.
    for (var start = 0; start < leaves.length; start += 4) {
      final batch = leaves.skip(start).take(4);
      final fetched = await Future.wait(batch.map((indexInNodes) async {
        final node = nodes[indexInNodes];
        final courses = await _fetchNode(
          node: node,
          index: index,
          cookie: cookie,
          referer: indexUri,
        );
        return (indexInNodes, courses);
      }));
      for (final (indexInNodes, courses) in fetched) {
        nodes[indexInNodes] = nodes[indexInNodes].withCourses(courses);
      }
    }
    final certificates = nodes.any((node) => node.id == 'zgzsxx')
        ? await _fetchCertificates(cookie: cookie, referer: indexUri)
        : const <AcademicCertificate>[];
    return AcademicProgress(
      studentId: index.studentId,
      gpa: index.gpa,
      plannedCourses: index.plannedCourses,
      passedCourses: index.passedCourses,
      ongoingCourses: index.ongoingCourses,
      notTakenCourses: index.notTakenCourses,
      nodes: nodes,
      certificates: certificates,
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<AcademicCertificate>> _fetchCertificates({
    required String cookie,
    required Uri referer,
  }) async {
    final response = await HttpTimeout.request(
      _httpClient.post(
        AcademicUrlResolver.uri(_certificatePath),
        headers: _headers(cookie, referer, formRequest: true),
      ),
      message: '资格证书请求超时，请稍后重试',
    );
    _ensureResponse(response);
    return AcademicProgressParser.parseCertificates(response.body);
  }

  Future<List<AcademicProgressCourse>> _fetchNode({
    required AcademicProgressNode node,
    required AcademicProgressIndex index,
    required String cookie,
    required Uri referer,
  }) async {
    final uri = AcademicUrlResolver.uri(
      node.courseKind == '1' ? _coursePath : _otherCoursePath,
    );
    final body = <String, String>{
      'fromXh_id': '',
      'xfyqjd_id': node.id,
      'xh_id': index.studentId,
    };
    if (node.id == 'qtkcxfyq') {
      for (final key in [
        'cjlrxn',
        'cjlrxq',
        'bkcjlrxn',
        'bkcjlrxq',
        'xscjcxkz',
        'cjcxkzzt',
        'cjztkz',
        'cjzt',
      ]) {
        body[key] = index.formValues[key] ?? '';
      }
    }
    final response = await HttpTimeout.request(
      _httpClient.post(
        uri,
        headers: _headers(cookie, referer, formRequest: true),
        body: body,
      ),
      message: '学业课程请求超时，请稍后重试',
    );
    _ensureResponse(response);
    return AcademicProgressParser.parseCourses(response.body);
  }

  Map<String, String> _headers(
    String cookie,
    Uri referer, {
    bool formRequest = false,
  }) =>
      {
        'accept': formRequest
            ? 'application/json, text/javascript, */*; q=0.01'
            : 'text/html,application/xhtml+xml',
        'cookie': cookie,
        'referer': referer.toString(),
        'user-agent': ClientUserAgent.mobileBrowser,
        if (formRequest) ...{
          'x-requested-with': 'XMLHttpRequest',
          'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
        },
      };

  void _ensureResponse(http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AcademicAuthException('教务登录已失效', response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AcademicApiException(
        '教务系统请求失败',
        statusCode: response.statusCode,
      );
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
