import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

import '../models/academic_schedule_collection.dart';
import 'package:http/io_client.dart';

import '../../core/academic_constants.dart';
import '../../core/academic_url_resolver.dart';
import '../../core/client_user_agent.dart';
import '../models/academic_schedule.dart';
import '../models/common.dart';
import 'academic_auth_service.dart';
import 'http_timeout.dart';

class AcademicApiException implements Exception {
  const AcademicApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    final code = statusCode;
    if (code == null) {
      return message;
    }
    return '$message ($code)';
  }
}

class AcademicAuthException extends AcademicApiException {
  const AcademicAuthException([
    super.message = '需要先登录教务系统',
    int? statusCode,
  ]) : super(statusCode: statusCode);
}

class AcademicTermQuery {
  const AcademicTermQuery({
    required this.yearCode,
    required this.termCode,
    this.academicYearName = '',
    this.termName = '',
    this.lastYearInclusive,
  });

  final String yearCode;
  final String termCode;
  final String academicYearName;
  final String termName;
  final int? lastYearInclusive;

  String get key => academicTermKey(yearCode, termCode);

  bool get isValid => yearCode.isNotEmpty && termCode.isNotEmpty;
}

class AcademicTermCatalog {
  const AcademicTermCatalog({required this.currentTerm, required this.terms});

  final AcademicTermQuery currentTerm;
  final List<AcademicTermQuery> terms;
}

class AcademicNoScheduleException extends AcademicApiException {
  const AcademicNoScheduleException() : super('该学年学期暂无您的课表');
}

class AcademicScheduleApiClient {
  AcademicScheduleApiClient({
    AcademicAuthService? authService,
    http.Client? httpClient,
  })  : _authService = authService ?? AcademicAuthService(),
        _httpClient = httpClient ?? _defaultHttpClient();

  final AcademicAuthService _authService;
  final http.Client _httpClient;

  static http.Client _defaultHttpClient() {
    return IOClient(HttpClient());
  }

  Future<AcademicSchedule> fetchCurrentSchedule() {
    return HttpTimeout.request(
      _fetchCurrentSchedule(),
      timeout: HttpTimeout.composed,
      message: '课表同步超时，请稍后再试',
    );
  }

  Future<AcademicSchedule> _fetchCurrentSchedule() async {
    _debug(
        'sync start mode=${AcademicUrlResolver.usesWebVpn ? 'webvpn' : 'direct'}');
    try {
      final term = await fetchCurrentTermQuery();
      if (!term.isValid) {
        throw const AcademicApiException('未能识别当前学期');
      }
      _debug('term resolved year=${term.yearCode} term=${term.termCode}');
      final schedule = await fetchScheduleForTerm(term);
      _debug('sync success');
      return schedule;
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[SHU_SCHEDULE_API] sync failed: $error');
        debugPrintStack(
          label: '[SHU_SCHEDULE_API] stack',
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<AcademicTermQuery> fetchCurrentTermQuery() async =>
      (await fetchTermCatalog()).currentTerm;

  Future<AcademicTermCatalog> fetchTermCatalog() async {
    final response = await HttpTimeout.request(
      _httpClient.get(
        _uri(AcademicConstants.scheduleIndexPath),
        headers: await _headers(accept: 'text/html,application/xhtml+xml'),
      ),
      message: '教务系统请求超时，请稍后再试',
    );
    _debugResponse('schedule-index', response);
    _ensureSuccess(response);
    _ensureNotLoginPage(response.body);
    return parseTermCatalog(response.body);
  }

  @visibleForTesting
  static AcademicTermCatalog parseTermCatalog(String html) {
    final document = html_parser.parse(html);
    List<(String, String, bool)> options(String id) => [
          for (final option in document.querySelectorAll('select#$id option'))
            if ((option.attributes['value'] ?? '').trim().isNotEmpty)
              (
                option.attributes['value']!.trim(),
                option.text.trim(),
                option.attributes.containsKey('selected'),
              ),
        ];
    final years = options('xnm');
    final semesters = options('xqm');
    String selected(String id, List<(String, String, bool)> items) {
      for (final item in items) {
        if (item.$3) return item.$1;
      }
      return document
              .querySelector('input[name="$id"]')
              ?.attributes['value']
              ?.trim() ??
          '';
    }

    final year = selected('xnm', years);
    final semester = selected('xqm', semesters);
    String name(
        List<(String, String, bool)> items, String code, String fallback) {
      for (final item in items) {
        if (item.$1 == code) return item.$2;
      }
      return fallback;
    }

    final current = AcademicTermQuery(
      yearCode: year,
      termCode: semester,
      academicYearName: name(
          years,
          year,
          document.querySelector('input[name="xnmc"]')?.attributes['value'] ??
              ''),
      termName: name(
          semesters,
          semester,
          document.querySelector('input[name="xqmmc"]')?.attributes['value'] ??
              ''),
    );
    if (!current.isValid) {
      throw const AcademicApiException('未能识别教务默认学期');
    }
    final candidates = <String, AcademicTermQuery>{current.key: current};
    for (final y in years) {
      for (final term in semesters) {
        final maxYear = int.tryParse(
            RegExp(r'(\d{4})及之前').firstMatch(term.$2)?.group(1) ?? '');
        final yearNumber = int.tryParse(y.$1);
        if (maxYear != null && yearNumber != null && yearNumber > maxYear) {
          continue;
        }
        final query = AcademicTermQuery(
          yearCode: y.$1,
          termCode: term.$1,
          academicYearName: y.$2,
          termName: term.$2.replaceFirst(RegExp(r'[（(].*$'), '').trim(),
          lastYearInclusive: maxYear,
        );
        candidates[query.key] = query;
      }
    }
    final currentYear = int.tryParse(year) ?? 0;
    const termOrder = {'3': 0, '12': 1, '16': 2, '32': 3};
    final terms = candidates.values.toList()
      ..sort((a, b) {
        if (a.key == current.key) return b.key == current.key ? 0 : -1;
        if (b.key == current.key) return 1;
        final distanceA = ((int.tryParse(a.yearCode) ?? 0) - currentYear).abs();
        final distanceB = ((int.tryParse(b.yearCode) ?? 0) - currentYear).abs();
        final distance = distanceA.compareTo(distanceB);
        if (distance != 0) return distance;
        final yearOrder = b.yearCode.compareTo(a.yearCode);
        if (yearOrder != 0) return yearOrder;
        final semesterOrder = (termOrder[a.termCode] ?? 99)
            .compareTo(termOrder[b.termCode] ?? 99);
        return semesterOrder != 0
            ? semesterOrder
            : a.termCode.compareTo(b.termCode);
      });
    return AcademicTermCatalog(currentTerm: current, terms: terms);
  }

  Future<AcademicSchedule> fetchScheduleForTerm(AcademicTermQuery term) async {
    if (!term.isValid) throw const AcademicApiException('无效的学年或学期');
    final json = await fetchScheduleJson(term);
    final schedule = AcademicScheduleParser.parse(json);
    if (schedule.term.yearCode != term.yearCode ||
        schedule.term.termCode != term.termCode ||
        schedule.term.studentId.isEmpty) {
      throw const AcademicApiException('教务返回的课表与所查询的学期不匹配');
    }
    return schedule;
  }

  Future<JsonMap> fetchScheduleJson(AcademicTermQuery term) async {
    final body = Uri(
      queryParameters: {
        'xnm': term.yearCode,
        'xqm': term.termCode,
        'kzlx': 'ck',
        'xsdm': '',
        'kclbdm': '',
        'kclxdm': '',
      },
    ).query;
    final response = await HttpTimeout.request(
      _httpClient.post(
        _uri(AcademicConstants.scheduleDataPath),
        headers: await _headers(
          accept: '*/*',
          formRequest: true,
        ),
        body: body,
      ),
      message: '教务系统请求超时，请稍后再试',
    );
    _debugResponse('schedule-data', response);
    _ensureSuccess(response);
    _ensureNotLoginPage(response.body);
    final decoded = jsonDecode(response.body);
    if (decoded is! JsonMap) {
      throw const AcademicApiException('教务系统返回了无法识别的课表数据');
    }
    if (decoded['kbList'] is! List ||
        decoded['xsxx'] is! JsonMap ||
        (decoded.containsKey('sjkList') && decoded['sjkList'] is! List)) {
      throw const AcademicApiException('教务系统返回的数据不包含课表');
    }
    return decoded;
  }

  Future<Map<String, String>> _headers({
    required String accept,
    bool formRequest = false,
  }) async {
    final cookie = await _authService.cookieHeader(
      targetUri: _uri(AcademicConstants.scheduleIndexPath),
    );
    if (cookie == null || cookie.isEmpty) {
      _debug('cookie header unavailable');
      throw const AcademicAuthException('未读取到教务系统 Cookie，请先打开教务系统并确认已登录');
    }
    final cookieNames = cookie
        .split(';')
        .map((part) => part.trim().split('=').first)
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    _debug('request cookies=$cookieNames');
    return {
      'accept': accept,
      'cookie': cookie,
      'referer': AcademicUrlResolver.usesWebVpn
          ? AcademicUrlResolver.scheduleIndexUri.toString()
          : '${AcademicUrlResolver.baseUrl}${AcademicConstants.scheduleIndexPath}',
      'user-agent': ClientUserAgent.mobileBrowser,
      'x-requested-with': formRequest ? 'XMLHttpRequest' : '',
      if (formRequest)
        'content-type': 'application/x-www-form-urlencoded;charset=UTF-8',
    }..removeWhere((_, value) => value.isEmpty);
  }

  Uri _uri(String path) => AcademicUrlResolver.uri(path);

  void _ensureSuccess(http.Response response) {
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        response.statusCode == 901) {
      throw AcademicAuthException('教务登录已失效', response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AcademicApiException(
        '教务系统请求失败',
        statusCode: response.statusCode,
      );
    }
  }

  void _ensureNotLoginPage(String body) {
    if (_loginPageSignals(body).isNotEmpty) {
      throw const AcademicAuthException('教务登录已失效，请重新登录');
    }
  }

  void _debugResponse(String requestName, http.Response response) {
    if (!kDebugMode) return;
    final requestUri = response.request?.url;
    final title = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    )
        .firstMatch(response.body)
        ?.group(1)
        ?.replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final safeTitle =
        title == null ? '-' : title.substring(0, title.length.clamp(0, 80));
    final contentType = response.headers['content-type'] ?? '-';
    final signals = _loginPageSignals(response.body);
    _debug(
      'response request=$requestName '
      'uri=${requestUri == null ? '-' : _describeUri(requestUri)} '
      'status=${response.statusCode} contentType=$contentType '
      'bytes=${response.bodyBytes.length} title="$safeTitle" '
      'loginSignals=$signals',
    );
  }

  List<String> _loginPageSignals(String body) {
    final lower = body.toLowerCase();
    return <(String, String)>[
      ('oauth2-login', '/oauth2/login'),
      ('newsso-host', 'newsso.shu.edu.cn'),
      ('legacy-login', 'jwglxt/xtgl/login_slogin'),
      ('username-double-quote', 'name="yhm"'),
      ('username-single-quote', "name='yhm'"),
    ]
        .where((entry) => lower.contains(entry.$2))
        .map((entry) => entry.$1)
        .toList();
  }

  String _describeUri(Uri uri) {
    final keys = uri.queryParameters.keys.toList()..sort();
    return '${uri.host}${uri.path}${keys.isEmpty ? '' : ' queryKeys=$keys'}';
  }

  void _debug(String message) {
    if (kDebugMode) debugPrint('[SHU_SCHEDULE_API] $message');
  }
}
