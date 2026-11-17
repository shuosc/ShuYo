import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/client_user_agent.dart';
import '../../core/webvpn_urls.dart';
import 'academic_native_auth_service.dart';
import 'http_timeout.dart';
import 'session_cookie_jar.dart';

enum BookingVenue {
  library('校本部图书馆', 'LIB_SEAT', '/mobile/libseat', true),
  studySpace('24H学习空间', 'STATION', '/mobile/seat2021', true),
  yanchang('延长智能中心', 'SEAT', '/mobile/seat-mgr', false),
  scienceArt('科学与艺术中心', 'CS_SEAT', '/mobile/csseat', false),
  qianweichang('钱伟长图书馆', 'CX_QWC', '', false, isChaoxing: true),
  jiading('嘉定联合馆', 'CX_JD', '', false, isChaoxing: true),
  wenhui('延长文荟馆', 'CX_WH', '', false, isChaoxing: true);

  const BookingVenue(
      this.label, this.roomType, this.mobilePath, this.showChecks,
      {this.isChaoxing = false});

  final String label;
  final String roomType;
  final String mobilePath;
  final bool showChecks;
  final bool isChaoxing;
}

enum ThereFailureKind {
  loginRequired,
  webVpnLoginRequired,
  unreachable,
  business,
  uncertain,
}

class ThereBookingException implements Exception {
  const ThereBookingException(this.kind, this.message,
      {this.ssoExpired = false});

  final ThereFailureKind kind;
  final String message;
  final bool ssoExpired;

  @override
  String toString() => message;
}

class ThereBookingClient {
  ThereBookingClient({
    HttpClient? httpClient,
    SessionCookieJar? cookieJar,
    Uri? serviceUri,
    this.useWebVpn = false,
    Future<List<SessionCookie>> Function(Uri)? cookieLoader,
    Future<void> Function(SessionCookie)? cookieSetter,
  })  : _http = httpClient ?? HttpClient(),
        _cookieJarInstance = cookieJar,
        baseUri = serviceUri ??
            Uri.parse(useWebVpn
                ? 'https://https-there-shu-edu-cn-443.webvpn.shu.edu.cn'
                : 'https://there.shu.edu.cn'),
        _cookieLoader = cookieLoader,
        _cookieSetter = cookieSetter {
    _http.connectionTimeout = HttpTimeout.connect;
  }

  static const _submitInterval = Duration(seconds: 10);
  static final directUri = Uri.parse('https://there.shu.edu.cn');

  final HttpClient _http;
  final Uri baseUri;
  final bool useWebVpn;
  final Future<List<SessionCookie>> Function(Uri)? _cookieLoader;
  final Future<void> Function(SessionCookie)? _cookieSetter;
  SessionCookieJar? _cookieJarInstance;
  SessionCookieJar get _cookieJar =>
      _cookieJarInstance ??= SessionCookieJar.shared;
  AcademicSessionCookieStore _cookies = AcademicSessionCookieStore();
  bool _browserCookiesLoaded = false;
  String? _portalWebVpnToken;
  String? _oauthState;
  bool _oauthCompleted = false;
  BookingVenue? _venue;
  String? _sessionId;
  DateTime? _lastSubmit;
  bool _submitting = false;

  BookingVenue? get venue => _venue;
  // A parsed empty sessionId selects cookie authentication on newer pages.
  // null means that no mobile entry has been initialized.
  bool get hasBusinessSession => _sessionId != null;

  void dispose() => _http.close(force: true);

  void resetSession() {
    _cookies = AcademicSessionCookieStore();
    _browserCookiesLoaded = false;
    _portalWebVpnToken = null;
    _oauthState = null;
    _oauthCompleted = false;
    _sessionId = null;
    _venue = null;
  }

  static String schoolDay([DateTime? now]) {
    final value = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 8));
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  static String? string(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static Map<String, dynamic>? object(Object? value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : null;

  static List<Map<String, dynamic>> objects(Object? value) => value is List
      ? [
          for (final item in value)
            if (object(item) case final Map<String, dynamic> entry) entry,
        ]
      : [];

  static List<String> strings(Object? value) => value is List
      ? [
          for (final item in value)
            if (string(item) != null) string(item)!
        ]
      : [];

  static bool matchesAccount(Map<String, dynamic> profile, String studentId) {
    final candidates = [
      string(profile['loginName']),
      string(profile['jobNumber']),
    ].whereType<String>().toList();
    return candidates.isNotEmpty &&
        candidates.any(
          (value) => value.toLowerCase() == studentId.toLowerCase(),
        );
  }

  /// Re-reads each mobile entry because x-hys-session belongs to that entry.
  Future<void> selectVenue(BookingVenue venue) async {
    if (venue.isChaoxing) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '该场馆需要通过对应的预约服务访问',
      );
    }
    if (_venue == venue && hasBusinessSession) return;
    _venue = venue;
    _sessionId = null;
    var response = await _request('GET', venue.mobilePath,
        headers: {'X-Requested-With': 'com.tencent.wework'});
    if (_isWeChatRedirect(response)) {
      // The HAR was captured inside WeCom. A normal app request must not keep
      // its WebView-only marker if the server routes that branch to WeChat.
      response = await _request('GET', venue.mobilePath);
    }
    if (_isWeChatRedirect(response)) {
      if (_oauthCompleted) {
        throw const ThereBookingException(
          ThereFailureKind.uncertain,
          '预约入口仍跳转至微信授权，当前客户端暂时无法完成该认证',
        );
      }
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    _requirePage(response);
    if (RegExp(r'''["']isAnonymous["']\s*:\s*true''').hasMatch(response.body)) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    final match = RegExp(
          r'''\bsessionId\s*[=:]\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''',
        ).firstMatch(response.body) ??
        RegExp(
          r'''["']sessionId["']\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''',
        ).firstMatch(response.body);
    if (match == null || match.group(1) == null) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约页面没有返回可识别的会话，请稍后重试',
      );
    }
    final literal = match.group(1)!;
    String? session;
    try {
      session = literal.startsWith('"')
          ? jsonDecode(literal).toString()
          : literal.substring(1, literal.length - 1);
    } on Object {
      session = null;
    }
    if (session == null ||
        session.contains('\n') ||
        session.contains('\r') ||
        (session.isNotEmpty && session.trim().isEmpty)) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约页面会话无效，请稍后重试',
      );
    }
    // Current pages leave sessionId empty and authenticate API requests with
    // SPHYS_SESSION. Keep legacy header authentication when a token is present;
    // profile() still verifies the authenticated account in either mode.
    _sessionId = session;
    if (kDebugMode) {
      debugPrint(
        '[THERE_BOOKING] mobile-session '
        'venue=${venue.roomType} '
        'transport=${useWebVpn ? 'webvpn' : 'direct'} '
        'mode=${session.isEmpty ? 'cookie' : 'header'}',
      );
    }
  }

  Future<void> refreshVenue(BookingVenue venue) async {
    _sessionId = null;
    await selectVenue(venue);
  }

  Future<Map<String, dynamic>> profile() async {
    final data = object((await _api('GET', '/api/v3/my/profile'))['data']);
    if (data == null ||
        data['isAnonymous'] != false ||
        string(data['id']) == null ||
        string(data['name']) == null) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> recent() async =>
      objects((await _api('GET', '/api/v3/my/bookings/recent'))['data']);

  Future<Map<String, dynamic>> overview(String day) async =>
      object((await _api('GET', '/api/v3/booking-status/overview',
          query: {'day': day}))['data']) ??
      const {};

  Future<List<Map<String, dynamic>>> areas(String day) async =>
      objects((await _api('GET', '/api/v3/booking-status/areas',
          query: {'begin': day, 'end': day}))['data']);

  Future<Map<String, dynamic>> area(
          String areaId, String begin, String end) async =>
      object((await _api(
        'GET',
        '/api/v3/booking-status/areas/${Uri.encodeComponent(areaId)}',
        query: {'begin': begin, 'end': end},
      ))['data']) ??
      const {};

  Future<Map<String, dynamic>> detail(String bookingId) async {
    final data = object((await _api(
      'GET',
      '/api/v3/bookings/${Uri.encodeComponent(bookingId)}',
      query: _venue?.showChecks == true ? {'showChecks': 'true'} : null,
    ))['data']);
    if (data == null || string(data['id']) == null) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '预约详情暂时无法确认，请稍后重试',
      );
    }
    return data;
  }

  /// Refreshes the selected interval immediately before creating a booking.
  Future<String> create({
    required String areaId,
    required String roomId,
    required String day,
    required String start,
    required String end,
  }) async {
    if (_submitting) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '预约正在提交，请等待结果',
      );
    }
    final last = _lastSubmit;
    if (last != null && DateTime.now().difference(last) < _submitInterval) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '同一用户提交过于频繁，请稍后重试',
      );
    }
    if (end.compareTo(start) <= 0) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '结束时间需要晚于开始时间',
      );
    }
    _submitting = true;
    try {
      final user = await profile();
      if (user['disableBooking'] == true) {
        throw const ThereBookingException(
          ThereFailureKind.business,
          '当前账户不可预约',
        );
      }
      final currentArea = await area(
        areaId,
        '$day $start',
        '$day $end',
      );
      final room = objects(currentArea['rooms'])
          .where(
            (item) => string(item['id']) == roomId,
          )
          .firstOrNull;
      if (room == null ||
          string(room['officeAreaId']) != areaId ||
          room['disabled'] == true ||
          room['isBusy'] == true ||
          room['isBooked'] == true ||
          !strings(room['abilities']).contains('booking')) {
        throw const ThereBookingException(
          ThereFailureKind.business,
          '所选座位已不可预约，请刷新后重选',
        );
      }
      _lastSubmit = DateTime.now();
      final result = await _api('POST', '/api/v3/bookings',
          body: {
            'rooms': [room],
            'times': [
              {
                'startDate': day,
                'startTime': start,
                'endDate': day,
                'endTime': end,
              },
            ],
            'subject': user['name'],
            'meetingMembers': [user['id']],
          },
          createRequest: true);
      final id = string(objects(result['data']).firstOrNull?['id']);
      if (id == null) {
        throw const ThereBookingException(
          ThereFailureKind.uncertain,
          '预约结果尚未确认，请先查看我的预约',
        );
      }
      return id;
    } finally {
      _submitting = false;
    }
  }

  Future<void> cancel(String bookingId) async {
    final current = await detail(bookingId);
    if (!strings(current['abilities']).contains('cancel')) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '当前预约不可取消',
      );
    }
    await _api(
        'DELETE', '/api/v3/bookings/${Uri.encodeComponent(bookingId)}/cancel');
  }

  Future<void> finish(String bookingId) async {
    final current = await detail(bookingId);
    if (!strings(current['abilities']).contains('close')) {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '当前预约不可退座',
      );
    }
    await _api(
        'PUT', '/api/v3/bookings/${Uri.encodeComponent(bookingId)}/finish');
  }

  /// Returns the server's state paired with the initialized booking cookie.
  Future<String> prepareOAuth() async {
    _oauthState = null;
    final response = await _request('GET', '/login', query: {'from': 'web'});
    final states = response.location?.queryParametersAll['state'];
    if (response.status < 300 ||
        response.status >= 400 ||
        states == null ||
        states.length != 1 ||
        states.single.isEmpty) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约暂时无法启动登录，请稍后重试',
      );
    }
    return _oauthState = states.single;
  }

  Future<void> completeOAuth(
    Uri callback, {
    Iterable<({Cookie cookie, String domain, String path})> cookies = const [],
  }) async {
    final expectedCallback = useWebVpn ? directUri : baseUri;
    if (callback.origin != expectedCallback.origin ||
        callback.path != '/login-oauth2' ||
        string(callback.queryParameters['code']) == null) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约授权回调无效',
      );
    }
    final states = callback.queryParametersAll['state'];
    if (_oauthState == null ||
        states == null ||
        states.length != 1 ||
        states.single != _oauthState) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约授权状态校验失败，请重新登录',
      );
    }
    await _loadBrowserCookies();
    for (final entry in cookies) {
      if (entry.domain != baseUri.host) continue;
      final cookie = Cookie(entry.cookie.name, entry.cookie.value)
        ..domain = entry.domain
        ..path = entry.path;
      _cookies.save(baseUri, [cookie]);
    }
    final response =
        await _request('GET', callback.path, query: callback.queryParameters);
    final location = normalizeServiceRedirect(response.location);
    if (response.status < 300 ||
        response.status >= 400 ||
        location == null ||
        location.path != '/web') {
      throw const ThereBookingException(
        ThereFailureKind.business,
        '图书馆预约未能建立业务会话，请重试',
      );
    }
    var landing = location;
    var landed = false;
    for (var hop = 0; hop < 4; hop++) {
      final page =
          await _request('GET', landing.path, query: landing.queryParameters);
      if (page.status == 200) {
        landed = true;
        break;
      }
      final next = normalizeServiceRedirect(page.location);
      if (page.status < 300 ||
          page.status >= 400 ||
          next == null ||
          next.path.startsWith('/login')) {
        throw const ThereBookingException(
          ThereFailureKind.business,
          '图书馆预约会话兑换失败，请重试',
        );
      }
      landing = next;
    }
    if (!landed) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约登录跳转次数过多，请稍后重试',
      );
    }
    _oauthState = null;
    _oauthCompleted = true;
    await selectVenue(BookingVenue.library);
  }

  /// there currently issues an HTTP Location for /web after an HTTPS OAuth
  /// callback. Resolve only its exact host and normal HTTP port through HTTPS.
  /// The client's cookies are never sent to the HTTP URL.
  @visibleForTesting
  Uri? normalizeServiceRedirect(Uri? location) {
    if (location == null || location.userInfo.isNotEmpty) {
      return null;
    }
    if (location.origin == baseUri.origin) return location;
    final directHost = directUri.host;
    final allowedOriginalHost = location.host == directHost &&
        ((location.scheme == 'https' && location.port == 443) ||
            (location.scheme == 'http' && location.port == 80));
    if (useWebVpn && allowedOriginalHost) {
      return baseUri.replace(
        path: location.path,
        queryParameters: location.queryParameters,
        fragment: '',
      );
    }
    if (useWebVpn &&
        location.scheme == 'https' &&
        location.port == 443 &&
        location.host == 'http-there-shu-edu-cn-80.webvpn.shu.edu.cn') {
      return baseUri.replace(
        path: location.path,
        queryParameters: location.queryParameters,
        fragment: '',
      );
    }
    if (location.host != baseUri.host) return null;
    if (baseUri.scheme == 'https' &&
        baseUri.port == 443 &&
        location.scheme == 'http' &&
        location.port == 80) {
      return baseUri.replace(
        path: location.path,
        queryParameters: location.queryParameters,
        fragment: '',
      );
    }
    return null;
  }

  Future<void> clearSession() async {
    resetSession();
    final cookies = await (_cookieLoader?.call(baseUri) ??
        _cookieJar.getCookies(domain: baseUri));
    for (final cookie in cookies) {
      if (cookie.name != 'SPHYS_SESSION' &&
          cookie.name != 'authenticityToken' &&
          cookie.name != 'HYS_LANG') {
        continue;
      }
      final expired = SessionCookie(
        name: cookie.name,
        value: '',
        domain: cookie.domain.isEmpty ? baseUri.host : cookie.domain,
        path: cookie.path.isEmpty ? '/' : cookie.path,
      );
      await (_cookieSetter?.call(expired) ?? _cookieJar.setCookie(expired));
    }
  }

  Future<Map<String, dynamic>> _api(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool createRequest = false,
  }) async {
    final venue = _venue;
    if (venue == null || !hasBusinessSession) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    final headers = <String, String>{
      if (_sessionId!.isNotEmpty) 'x-hys-session': _sessionId!,
      'x-room-type': venue.roomType,
      'x-hys-platform': 'UNDEFINE',
      'x-lang': 'zh',
      'X-Requested-With': 'com.tencent.wework',
      'Referer': baseUri.resolve(venue.mobilePath).toString(),
      'Content-Type': 'application/json',
      if (method != 'GET') 'Origin': baseUri.toString(),
    };
    final response = await _request(method, path,
        query: query,
        headers: headers,
        body: body,
        createRequest: createRequest);
    _requireBusinessResponse(response);
    final Map<String, dynamic> json;
    try {
      json = object(jsonDecode(response.body))!;
    } on Object {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约服务返回了无法识别的内容，请稍后重试',
      );
    }
    final code = json['code'];
    if (code is! int || code is bool) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约服务返回了无法识别的结果，请稍后重试',
      );
    }
    if (code != 0) {
      final message = string(json['warnMessage']) ??
          string(json['message']) ??
          string(json['noticeMessage']) ??
          '图书馆预约服务拒绝了本次操作';
      throw ThereBookingException(ThereFailureKind.business, message);
    }
    if (kDebugMode && path.startsWith('/api/v3/booking-status/areas/')) {
      final rooms = object(json['data'])?['rooms'];
      if (rooms is List) {
        debugPrint(
          '[THERE_BOOKING] seats '
          'venue=${venue.roomType} '
          'transport=${useWebVpn ? 'webvpn' : 'direct'} '
          'query=${_queryShape(query)} count=${rooms.length}',
        );
      }
    }
    return json;
  }

  Future<_ThereResponse> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    Map<String, dynamic>? body,
    bool createRequest = false,
  }) async {
    final timer = Stopwatch()..start();
    await _loadBrowserCookies();
    final uri =
        Uri.parse('${baseUri.origin}$path').replace(queryParameters: query);
    try {
      final request =
          await _http.openUrl(method, uri).timeout(HttpTimeout.connect);
      request.followRedirects = false;
      request.headers
          .set(HttpHeaders.userAgentHeader, ClientUserAgent.mobileBrowser);
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/json,text/html,*/*');
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final cookieHeader = _cookies.headerFor(uri);
      final hasTargetWebVpnToken = cookieHeader.split(';').any(
            (part) => part.trimLeft().startsWith('webvpn-token='),
          );
      final gatewayCookie = useWebVpn &&
              !hasTargetWebVpnToken &&
              _portalWebVpnToken?.isNotEmpty == true
          ? 'webvpn-token=$_portalWebVpnToken'
          : '';
      final combinedCookies = [
        if (gatewayCookie.isNotEmpty) gatewayCookie,
        if (cookieHeader.isNotEmpty) cookieHeader,
      ].join('; ');
      if (combinedCookies.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, combinedCookies);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(HttpTimeout.normal);
      final responseCookies = <Cookie>[];
      for (final value in response.headers[HttpHeaders.setCookieHeader] ??
          const <String>[]) {
        try {
          responseCookies.add(Cookie.fromSetCookieValue(value));
        } on FormatException {
          // An unrelated malformed cookie must not hide a usable session.
        }
      }
      final scopedCookies = responseCookies.map((cookie) {
        if (!useWebVpn ||
            cookie.domain?.replaceFirst(RegExp(r'^\.'), '') != directUri.host) {
          return cookie;
        }
        return cookie..domain = baseUri.host;
      }).toList();
      _cookies.save(uri, scopedCookies);
      for (final cookie in scopedCookies) {
        if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
        final jarCookie = SessionCookie(
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain ?? uri.host,
          path: cookie.path ?? '/',
        );
        await (_cookieSetter?.call(jarCookie) ??
            _cookieJar.setCookie(jarCookie));
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      final text =
          await utf8.decodeStream(response).timeout(HttpTimeout.normal);
      if (kDebugMode && path.startsWith('/mobile/')) {
        final redirect = location == null ? null : uri.resolve(location);
        final mode =
            headers.containsKey('X-Requested-With') ? 'wework-header' : 'plain';
        debugPrint(
          '[THERE_BOOKING] mobile-entry '
          'venue=${_venue?.roomType ?? '-'} '
          'transport=${useWebVpn ? 'webvpn' : 'direct'} '
          'mode=$mode '
          'status=${response.statusCode} '
          'contentType=${response.headers.contentType?.mimeType ?? '-'} '
          'redirect=${_safeRedirect(redirect)} '
          'bodyChars=${text.length} '
          'durationMs=${timer.elapsedMilliseconds}',
        );
      }
      if (kDebugMode &&
          (path == '/login' || path == '/login-oauth2' || path == '/web')) {
        final redirect = location == null ? null : uri.resolve(location);
        final cookieNames =
            responseCookies.map((cookie) => cookie.name).toList()..sort();
        debugPrint(
          '[THERE_BOOKING] oauth-stage '
          'transport=${useWebVpn ? 'webvpn' : 'direct'} '
          'path=$path '
          'status=${response.statusCode} '
          'redirect=${_safeRedirect(redirect)} '
          'cookieNames=$cookieNames '
          'durationMs=${timer.elapsedMilliseconds}',
        );
      }
      if (kDebugMode && path.startsWith('/api/v3/')) {
        debugPrint(
          '[THERE_BOOKING] api '
          'transport=${useWebVpn ? 'webvpn' : 'direct'} '
          'method=$method route=${routeForLog(path)} '
          'query=${_queryShape(query)} '
          'status=${response.statusCode} '
          'bodyChars=${text.length} '
          'durationMs=${timer.elapsedMilliseconds}',
        );
      }
      final redirect = location == null ? null : uri.resolve(location);
      if (useWebVpn &&
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          redirect?.host == Uri.parse(WebVpnUrls.portal).host) {
        throw const ThereBookingException(
          ThereFailureKind.webVpnLoginRequired,
          'WebVPN登录已失效，请在账号管理恢复后重试',
        );
      }
      return _ThereResponse(
        response.statusCode,
        text,
        location == null ? null : uri.resolve(location),
      );
    } on TimeoutException {
      _logTransportFailure(path, 'timeout', timer.elapsedMilliseconds);
      throw _connectionFailure(createRequest);
    } on SocketException {
      _logTransportFailure(path, 'socket', timer.elapsedMilliseconds);
      throw _connectionFailure(createRequest);
    } on HandshakeException {
      _logTransportFailure(path, 'tls', timer.elapsedMilliseconds);
      throw const ThereBookingException(
        ThereFailureKind.unreachable,
        '暂时无法连接预约系统，请检查网络后重试',
      );
    }
  }

  ThereBookingException _connectionFailure(bool createRequest) => createRequest
      ? const ThereBookingException(
          ThereFailureKind.uncertain,
          '预约提交结果未确认，请先查看我的预约',
        )
      : const ThereBookingException(
          ThereFailureKind.unreachable,
          '暂时无法访问预约系统。请连接校园网、学校VPN，或开启WebVPN后重试。',
        );

  void _logTransportFailure(String path, String kind, int durationMs) {
    if (!kDebugMode) return;
    if (path.startsWith('/mobile/')) {
      debugPrint(
        '[THERE_BOOKING] mobile-entry '
        'venue=${_venue?.roomType ?? '-'} transport=$kind '
        'durationMs=$durationMs',
      );
    } else if (path == '/login' || path == '/login-oauth2' || path == '/web') {
      debugPrint('[THERE_BOOKING] oauth-stage path=$path transport=$kind '
          'durationMs=$durationMs');
    } else if (path.startsWith('/api/v3/')) {
      debugPrint('[THERE_BOOKING] api route=${routeForLog(path)} '
          'transport=$kind durationMs=$durationMs');
    }
  }

  @visibleForTesting
  static String routeForLog(String path) {
    if (path == '/api/v3/my/profile' ||
        path == '/api/v3/my/bookings/recent' ||
        path == '/api/v3/booking-status/overview' ||
        path == '/api/v3/booking-status/areas' ||
        path == '/api/v3/bookings') {
      return path;
    }
    if (path.startsWith('/api/v3/booking-status/areas/')) {
      return '/api/v3/booking-status/areas/{areaId}';
    }
    if (path.startsWith('/api/v3/bookings/')) {
      final suffix = path.endsWith('/cancel')
          ? '/cancel'
          : path.endsWith('/finish')
              ? '/finish'
              : '';
      return '/api/v3/bookings/{bookingId}$suffix';
    }
    return '/api/v3/{other}';
  }

  String _queryShape(Map<String, String>? query) {
    if (query == null || query.isEmpty) return '-';
    if (query.containsKey('begin') && query.containsKey('end')) {
      return query['begin']?.length == 10 && query['end']?.length == 10
          ? 'day'
          : 'interval';
    }
    if (query.containsKey('day')) return 'day';
    if (query.containsKey('showChecks')) return 'detail';
    return 'other';
  }

  String _safeRedirect(Uri? uri) {
    if (uri == null) return '-';
    final path = switch (uri.path) {
      '/' => '/',
      '/login' => '/login',
      '/login-oauth2' => '/login-oauth2',
      '/web' => '/web',
      '/web/home' => '/web/home',
      '/auth/login' => '/auth/login',
      '/oauth/authorize' => '/oauth/authorize',
      '/connect/oauth2/authorize' => '/connect/oauth2/authorize',
      '/mobile/libseat' => '/mobile/libseat',
      '/mobile/seat2021' => '/mobile/seat2021',
      '/mobile/seat-mgr' => '/mobile/seat-mgr',
      '/mobile/csseat' => '/mobile/csseat',
      _ when uri.path.startsWith('/oauth2/login/') => '/oauth2/login/{context}',
      _ => '/{other:${uri.pathSegments.length}}',
    };
    return '${uri.scheme}://${uri.host}$path';
  }

  bool _isWeChatRedirect(_ThereResponse response) {
    if (response.status < 300 || response.status >= 400) return false;
    final host = response.location?.host;
    return host == 'open.weixin.qq.com' ||
        (useWebVpn && host == 'https-open-weixin-qq-com-443.webvpn.shu.edu.cn');
  }

  Future<void> _loadBrowserCookies() async {
    if (_browserCookiesLoaded) return;
    if (useWebVpn) {
      final portal = Uri.parse(WebVpnUrls.portal);
      final portalCookies = await (_cookieLoader?.call(portal) ??
          _cookieJar.getCookies(domain: portal));
      _portalWebVpnToken = [
        for (final cookie in portalCookies)
          if (cookie.name == 'webvpn-token' && cookie.value.isNotEmpty)
            cookie.value,
      ].lastOrNull;
    }
    final values = await (_cookieLoader?.call(baseUri) ??
        _cookieJar.getCookies(domain: baseUri));
    for (final value in values) {
      final cookie = Cookie(value.name, value.value)
        ..domain = value.domain.isEmpty ? baseUri.host : value.domain
        ..path = value.path.isEmpty ? '/' : value.path;
      _cookies.save(baseUri, [cookie]);
    }
    _browserCookiesLoaded = true;
  }

  void _requirePage(_ThereResponse response) {
    if (_requiresLogin(response)) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    if (response.status != 200) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '暂时无法打开图书馆预约，请稍后重试',
      );
    }
  }

  void _requireBusinessResponse(_ThereResponse response) {
    if (_requiresLogin(response)) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '图书馆预约需要登录',
      );
    }
    if (response.status != 200) {
      throw const ThereBookingException(
        ThereFailureKind.uncertain,
        '图书馆预约服务暂时不可用，请稍后重试',
      );
    }
  }

  bool _requiresLogin(_ThereResponse response) =>
      response.status == 401 ||
      (response.status >= 300 &&
          response.status < 400 &&
          _isLoginRedirect(response.location));

  bool _isLoginRedirect(Uri? location) =>
      location != null &&
      ((location.host == baseUri.host &&
              (location.path == '/login' ||
                  location.path == '/login-oauth2')) ||
          (location.host.endsWith('.shu.edu.cn') &&
              (location.path.startsWith('/oauth/') ||
                  location.path.startsWith('/oauth2/'))));
}

class _ThereResponse {
  const _ThereResponse(this.status, this.body, this.location);

  final int status;
  final String body;
  final Uri? location;
}
