import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/client_user_agent.dart';
import '../models/academic_schedule.dart';
import '../models/common.dart';
import 'academic_schedule_api_client.dart';
import 'graduate_session_store.dart';
import 'http_timeout.dart';
import 'session_cookie_jar.dart';

/// Reads the YJS 我的课表 / 学生课程表 grid, not the public course catalog.
class GraduateScheduleApiClient {
  GraduateScheduleApiClient({
    GraduateSessionStore? sessionStore,
    http.Client? httpClient,
  })  : _sessionStore = sessionStore ?? GraduateSessionStore(),
        _httpClient = httpClient ?? http.Client();

  static const _module = '/gsapp/sys/wdkbapp';
  static const _catalogAction = 'kfdxnxqcx';
  static const _scheduleAction = 'xspkjgcx';
  static final _moduleEntry = Uri.https(
    GraduateSessionStore.host,
    '$_module/*default/index.do',
  );
  static const _termCodes = {
    '1': ('3', '秋'),
    '2': ('12', '冬'),
    '3': ('16', '春'),
    '4': ('32', '夏'),
  };

  final GraduateSessionStore _sessionStore;
  final http.Client _httpClient;

  Future<AcademicTermCatalog> fetchTermCatalog(
      {required String studentId}) async {
    final session = await _openVerifiedModule(studentId);
    return _fetchTermCatalog(session);
  }

  Future<AcademicSchedule> fetchCurrentSchedule(
      {required String studentId}) async {
    final session = await _openVerifiedModule(studentId);
    final catalog = await _fetchTermCatalog(session);
    return _fetchSchedule(catalog.currentTerm, studentId, session);
  }

  Future<AcademicSchedule> fetchScheduleForTerm(
    AcademicTermQuery term, {
    required String studentId,
  }) async {
    final session = await _openVerifiedModule(studentId);
    return _fetchSchedule(term, studentId, session);
  }

  static Uri _actionUri(String action) => Uri.https(
        GraduateSessionStore.host,
        '$_module/modules/xskcb/$action.do',
      );

  Future<_GraduateScheduleSession> _openVerifiedModule(String studentId) async {
    final session = _GraduateScheduleSession(await _sessionStore.loadCookies());
    // Timetable rows do not identify the student. Bind all requests in this
    // operation to the same session that passes the portal identity check.
    final account = await _post(
      GraduateSessionStore.userInfoUri,
      session,
      referer: GraduateSessionStore.portalUri,
    );
    final data = account['data'];
    if (data is! JsonMap || stringValue(data['userId']).trim() != studentId) {
      throw const AcademicAuthException('研究生系统登录账号不匹配，请重新登录');
    }
    // The portal's _WEU is not enough for the schedule API. Loading the
    // module issues the context cookie that the follow-up XHRs need.
    await _send('GET', _moduleEntry, session,
        referer: GraduateSessionStore.portalUri);
    return session;
  }

  Future<AcademicTermCatalog> _fetchTermCatalog(
    _GraduateScheduleSession session,
  ) async {
    final rows = await _fetchRows(_catalogAction, session);
    final terms = <String, AcademicTermQuery>{};
    for (final row in rows) {
      final raw = stringValue(row['XNXQDM']);
      if (!_rawTermPattern.hasMatch(raw)) {
        throw const AcademicApiException('未能识别研究生系统学期');
      }
      final year = raw.substring(0, 4);
      final (termCode, termName) = _termCodes[raw.substring(4)]!;
      final term = AcademicTermQuery(
        yearCode: year,
        termCode: termCode,
        academicYearName: '$year-${int.parse(year) + 1}',
        termName: termName,
      );
      terms[term.key] = term;
    }
    if (terms.isEmpty) {
      throw const AcademicApiException('研究生系统未提供可查询的学期');
    }
    // The course page uses the first returned entry as its initial selection.
    return AcademicTermCatalog(
      currentTerm: terms.values.first,
      terms: terms.values.toList(growable: false),
    );
  }

  static final _rawTermPattern = RegExp(r'^\d{4}[1-4]$');
  static final _weekMaskPattern = RegExp(r'^[01]{1,32}$');

  Future<AcademicSchedule> _fetchSchedule(
    AcademicTermQuery query,
    String studentId,
    _GraduateScheduleSession session,
  ) async {
    final rawTerm = _termCodes.entries
        .map((entry) => (entry.key, entry.value.$1))
        .where((entry) => entry.$2 == query.termCode)
        .map((entry) => '${query.yearCode}${entry.$1}')
        .firstOrNull;
    if (rawTerm == null || !_rawTermPattern.hasMatch(rawTerm)) {
      throw const AcademicApiException('未能识别研究生系统学期');
    }
    final rows = await _fetchRows(_scheduleAction, session, form: {
      'XNXQDM': rawTerm,
      '*order': '-ZCBH',
    });
    final groups = <_GraduateSlot, _GraduatePlacement>{};
    for (final row in rows) {
      if (stringValue(row['XNXQDM']) != rawTerm) {
        throw const AcademicApiException('研究生系统返回的课表学期不匹配');
      }
      final start = intValue(row['KSJCDM']);
      final end = intValue(row['JSJCDM']);
      final weekday = intValue(row['XQ']);
      final name = stringValue(row['KCMC']).trim();
      final mask = stringValue(row['ZCBH']);
      if (name.isEmpty ||
          start < 1 ||
          end < start ||
          end > 12 ||
          weekday < 1 ||
          weekday > 7 ||
          !_weekMaskPattern.hasMatch(mask) ||
          !mask.contains('1')) {
        throw const AcademicApiException('研究生课表含有无法识别的排课记录');
      }
      final weeks = [
        for (var i = 0; i < mask.length; i++)
          if (mask[i] == '1') i + 1,
      ];
      final slot = (
        courseCode: stringValue(row['KCDM']),
        classId: stringValue(row['BJDM']),
        name: name,
        teacher: stringValue(row['JSXM']),
        room: stringValue(row['JASMC']),
        weekday: weekday,
        weeks: weeks.join(','),
      );
      final placement = groups.putIfAbsent(
          slot,
          () => _GraduatePlacement(
                weeks,
                stringValue(row['ZCMC'], '${slot.weeks}周'),
              ));
      placement.sections.addAll([
        for (var section = start; section <= end; section++) section,
      ]);
    }

    // YJS returns individual sections. Join adjacent sections only when the
    // class, teacher, venue, weekday and exact teaching weeks all match.
    final sessions = <CourseSession>[];
    for (final MapEntry(key: slot, value: placement) in groups.entries) {
      final sections = placement.sections.toList()..sort();
      var first = 0;
      for (var last = 0; last < sections.length; last++) {
        if (last + 1 < sections.length &&
            sections[last + 1] == sections[last] + 1) {
          continue;
        }
        final block = sections.sublist(first, last + 1);
        final id = base64Url.encode(utf8.encode(jsonEncode([
          slot.courseCode,
          slot.classId,
          slot.name,
          slot.teacher,
          slot.room,
          slot.weekday,
          slot.weeks,
          block.first,
          block.last,
        ])));
        sessions.add(CourseSession(
          id: 'yjs:$id',
          courseCode: slot.courseCode,
          courseName: slot.name,
          teacherName: slot.teacher,
          teachingClassId: slot.classId,
          campus: '',
          location: slot.room,
          weekday: slot.weekday,
          startSection: block.first,
          endSection: block.last,
          sections: block,
          weeks: placement.weeks,
          weekText: placement.weekText,
          credit: '',
          note: '',
        ));
        first = last + 1;
      }
    }
    sessions.sort((a, b) {
      final day = a.weekday.compareTo(b.weekday);
      if (day != 0) return day;
      final section = a.startSection.compareTo(b.startSection);
      return section != 0 ? section : a.id.compareTo(b.id);
    });
    return AcademicSchedule(
      term: AcademicTerm(
        yearCode: query.yearCode,
        termCode: query.termCode,
        academicYearName: query.academicYearName,
        termName: query.termName,
        studentName: '',
        studentId: studentId,
        className: '',
      ),
      sessions: sessions,
      untimedCourses: const [],
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<JsonMap>> _fetchRows(
    String action,
    _GraduateScheduleSession session, {
    Map<String, String>? form,
  }) async {
    final result = await _post(_actionUri(action), session, form: form);
    final data = result['datas'];
    final table = data is JsonMap ? data[action] : null;
    if (table is! JsonMap) {
      throw const AcademicApiException('研究生系统返回的数据格式无法识别');
    }
    final rows = table['rows'];
    if (rows is! List || rows.any((row) => row is! JsonMap)) {
      throw const AcademicApiException('研究生系统返回的数据格式无法识别');
    }
    if (intValue(table['totalSize']) > rows.length) {
      throw const AcademicApiException('研究生系统返回的数据不完整，请稍后重试');
    }
    return rows.cast<JsonMap>();
  }

  Future<JsonMap> _post(
    Uri uri,
    _GraduateScheduleSession session, {
    Map<String, String>? form,
    Uri? referer,
  }) async {
    final response = await _send('POST', uri, session,
        form: form, referer: referer ?? _moduleEntry);
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (body.trimLeft().startsWith('<') && _indicatesLogin(body)) {
      throw const AcademicAuthException('研究生系统登录已失效');
    }
    try {
      final result = jsonDecode(body);
      if (result is JsonMap) {
        final code = stringValue(result['code']);
        if (code == '0') return result;
        if (code == '401' || code == '901') {
          throw AcademicAuthException('研究生系统登录已失效', int.parse(code));
        }
        if (code == '403') throw _requestForbidden;
        throw const AcademicApiException('研究生系统未能返回数据');
      }
    } on FormatException {
      // Unexpected HTML or an incomplete response is not an empty timetable.
    }
    throw const AcademicApiException('研究生系统返回的数据格式无法识别');
  }

  Future<http.Response> _send(
    String method,
    Uri uri,
    _GraduateScheduleSession session, {
    required Uri referer,
    Map<String, String>? form,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'cookie': session.headerFor(uri),
        'referer': referer.toString(),
        'user-agent': ClientUserAgent.mobileBrowser,
        if (method == 'POST') ...{
          'accept': 'application/json, text/javascript, */*; q=0.01',
          'origin': referer.origin,
          'x-requested-with': 'XMLHttpRequest',
        } else
          'accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      });
    if (form != null) request.bodyFields = form;
    final response = await HttpTimeout.request(
      _httpClient.send(request).then(http.Response.fromStream),
      message: '研究生系统请求超时，请稍后再试',
    );
    final status = response.statusCode;
    final location = response.headers['location'] ?? '';
    if (status == 401 ||
        status == 901 ||
        (status >= 300 && status < 400 && _indicatesLogin(location))) {
      throw AcademicAuthException('研究生系统登录已失效', status);
    }
    // A timetable request can be forbidden while the portal session is valid.
    if (status == 403) throw _requestForbidden;
    if (status < 200 || status >= 300) {
      throw AcademicApiException('研究生系统请求失败', statusCode: status);
    }
    session.readResponseCookies(uri, response);
    return response;
  }

  static const _requestForbidden = AcademicApiException(
    '研究生系统拒绝了课表请求，请稍后再试',
    statusCode: 403,
  );

  static bool _indicatesLogin(String value) {
    final body = value.toLowerCase();
    return body.contains('newsso.shu.edu.cn') ||
        body.contains('/oauth_shu/login') ||
        body.contains('/oauth2/login') ||
        body.contains('统一身份认证');
  }
}

/// A per-operation cookie snapshot. Context cookie rotation never overwrites
/// the signed-in account, or shares module state across concurrent imports.
class _GraduateScheduleSession {
  _GraduateScheduleSession(List<SessionCookie> cookies)
      : _cookies = cookies
            .where((cookie) =>
                cookie.name == GraduateSessionStore.sessionCookieName ||
                cookie.name == _contextName)
            .toList();

  static const _contextName = '_WEU';
  final List<SessionCookie> _cookies;
  late final _identityCookie = _cookieFor(
      GraduateSessionStore.userInfoUri, GraduateSessionStore.sessionCookieName);

  String headerFor(Uri uri) {
    if (uri.scheme != 'https' || uri.authority != GraduateSessionStore.host) {
      throw ArgumentError('Timetable cookies are only for the YJS host');
    }
    final principal = _cookieFor(uri, GraduateSessionStore.sessionCookieName);
    if (principal == null || principal.value != _identityCookie?.value) {
      throw const AcademicAuthException('请先登录研究生系统');
    }
    final context = uri == GraduateSessionStore.userInfoUri
        ? null
        : _cookieFor(uri, _contextName);
    return '${principal.name}=${principal.value}'
        '${context == null ? '' : '; ${context.name}=${context.value}'}';
  }

  void readResponseCookies(Uri uri, http.Response response) {
    for (final raw in response.headersSplitValues['set-cookie'] ?? const []) {
      if (!raw.trimLeft().startsWith('$_contextName=')) continue;
      final Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(raw);
      } on FormatException {
        continue;
      }
      final domain =
          cookie.domain?.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
      if (domain != null && domain != uri.host) continue;
      final directoryEnd = uri.path.lastIndexOf('/');
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : directoryEnd > 0
              ? uri.path.substring(0, directoryEnd)
              : '/';
      _cookies.removeWhere((entry) =>
          entry.name == _contextName &&
          entry.domain == uri.host &&
          entry.path == path);
      final expired = cookie.maxAge != null
          ? cookie.maxAge! <= 0
          : cookie.expires?.isAfter(DateTime.now()) == false;
      if (expired || cookie.value.isEmpty) continue;
      _cookies.add(SessionCookie(
        name: _contextName,
        value: cookie.value,
        domain: uri.host,
        path: path,
      ));
    }
  }

  SessionCookie? _cookieFor(Uri uri, String name) {
    SessionCookie? match;
    for (final cookie in _cookies) {
      if (cookie.name != name ||
          cookie.domain != uri.host ||
          cookie.value.isEmpty) {
        continue;
      }
      final path = cookie.path;
      if ((uri.path == path ||
              uri.path.startsWith(path.endsWith('/') ? path : '$path/')) &&
          (match == null || path.length > match.path.length)) {
        match = cookie;
      }
    }
    return match;
  }
}

typedef _GraduateSlot = ({
  String courseCode,
  String classId,
  String name,
  String teacher,
  String room,
  int weekday,
  String weeks,
});

class _GraduatePlacement {
  _GraduatePlacement(this.weeks, this.weekText);

  final List<int> weeks;
  final String weekText;
  final sections = <int>{};
}
