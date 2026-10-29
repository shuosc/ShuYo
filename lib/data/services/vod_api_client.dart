import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/vod_url_resolver.dart';
import '../models/common.dart';
import '../models/course_recording.dart';
import 'http_timeout.dart';
import 'vod_auth_service.dart';

class VodApiException implements Exception {
  const VodApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class VodSessionExpiredException extends VodApiException {
  const VodSessionExpiredException([super.message = '校园账户登录已失效，请重新登录'])
      : ssoExpired = false;

  const VodSessionExpiredException.campus({this.ssoExpired = false})
      : super('校园账户登录已失效，请重新登录');

  final bool ssoExpired;
}

class _VodBusinessSessionExpired implements Exception {
  const _VodBusinessSessionExpired();
}

class VodPermissionException extends VodApiException {
  const VodPermissionException([super.message = '当前账号没有这节录播的观看权限']);
}

class VodNetworkException extends VodApiException {
  const VodNetworkException([super.message = '录播平台暂时无法连接，请稍后重试']);
}

class VodInvalidResponseException extends VodApiException {
  const VodInvalidResponseException([super.message = '录播平台返回的数据不完整，请刷新重试']);
}

typedef VodHeadersLoader = Future<Map<String, String>> Function(Uri target);

class VodLiveUnavailableException extends VodApiException {
  const VodLiveUnavailableException(super.message);
}

typedef VodUriResolver = Uri Function(
  String path,
  Map<String, String> queryParameters,
);

/// Uses the ordinary account catalog and viewer endpoints exclusively.
class VodApiClient {
  VodApiClient({
    VodAuthService? authService,
    http.Client? httpClient,
    VodHeadersLoader? headersLoader,
    VodHeadersLoader? mediaHeadersLoader,
    VodUriResolver? uriResolver,
    Uri Function(String url)? mediaUrlResolver,
    bool? useWebVpn,
    this.pageSize = 100,
  })  : assert(pageSize > 0 && pageSize <= 1000),
        _authService = authService ?? VodAuthService(),
        _ownsAuthService = authService == null,
        _httpClient = httpClient ?? IOClient(HttpClient()),
        _ownsHttpClient = httpClient == null,
        _providedHeadersLoader = headersLoader,
        _providedMediaHeadersLoader = mediaHeadersLoader,
        _providedUriResolver = uriResolver,
        _providedMediaUrlResolver = mediaUrlResolver,
        useWebVpn = useWebVpn ?? VodUrlResolver.usesWebVpn;

  final VodAuthService _authService;
  final bool _ownsAuthService;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final VodHeadersLoader? _providedHeadersLoader;
  final VodHeadersLoader? _providedMediaHeadersLoader;
  final VodUriResolver? _providedUriResolver;
  final Uri Function(String url)? _providedMediaUrlResolver;
  final int pageSize;

  /// Frozen for this client so a settings switch cannot mix two sessions.
  final bool useWebVpn;
  bool _disposed = false;

  Future<List<VodTerm>> fetchTerms() async {
    final decoded = await _get('/v1/list/termYear');
    // This endpoint returns an array, unlike the other API envelopes.
    if (decoded is! List) throw const VodInvalidResponseException();
    final terms = decoded
        .whereType<JsonMap>()
        .where((json) {
          final startYear = int.tryParse(
              stringValue(json['acyeCode']).trim().split('-').first);
          return startYear != null &&
              startYear >= 2025 &&
              intValue(json['acteTerm']) >= 1;
        })
        .map(VodTerm.fromJson)
        .where((term) => term.id > 0)
        .toList(growable: false)
      ..sort((a, b) {
        if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
        return b.id.compareTo(a.id);
      });
    return List.unmodifiable(terms);
  }

  Future<List<VodCourse>> fetchCourses({
    required int termId,
    void Function(List<VodCourse>)? onProgress,
  }) async {
    if (termId <= 0) throw const VodInvalidResponseException('请选择有效学期');
    final courses = <int, VodCourse>{};
    var parsed = 0;
    await _readAll(
      '/v1/group_subject_vod_list/t-1',
      {'acteId': '$termId'},
      identityField: 'teclId',
      orderBy: 'updateTime',
      ascending: false,
      onProgress: (records) {
        for (final record in records.skip(parsed)) {
          final course = VodCourse.fromJson(record);
          if (course.teachingClassId <= 0 || course.name.isEmpty) {
            throw const VodInvalidResponseException();
          }
          if (course.termId != termId) {
            throw const VodInvalidResponseException('录播平台返回了其他学期的课程，请刷新重试');
          }
          courses[course.teachingClassId] = course;
          parsed++;
          onProgress?.call(List<VodCourse>.unmodifiable(courses.values));
        }
      },
    );
    return List.unmodifiable(courses.values);
  }

  Future<List<VodLesson>> fetchLessons(VodCourse course) async {
    await checkTeachingClassPermission(course.teachingClassId);
    final records = await _readAll(
      '/v1/subject_vod_list_new',
      {
        'teclIds': '${course.teachingClassId}',
        'schoolOpenStatusFlag': 'false',
      },
      identityField: 'id',
      orderBy: 'courBeginTime',
      ascending: true,
    );
    final lessons = <int, VodLesson>{};
    for (final record in records) {
      final lesson = VodLesson.fromJson(record);
      if (lesson.id <= 0 || lesson.teachingClassId != course.teachingClassId) {
        throw const VodInvalidResponseException('录播课次与所选教学班不一致，请刷新重试');
      }
      if (lesson.isPlayable || lesson.isGenerating || lesson.isListed) {
        lessons[lesson.id] = lesson;
      }
    }
    final sorted = lessons.values.toList(growable: false)
      ..sort((a, b) {
        final time = (a.beginTime?.millisecondsSinceEpoch ?? 0)
            .compareTo(b.beginTime?.millisecondsSinceEpoch ?? 0);
        return time == 0 ? a.id.compareTo(b.id) : time;
      });
    return List.unmodifiable(sorted);
  }

  Future<void> checkTeachingClassPermission(int teachingClassId,
      {bool isLive = false}) async {
    final result = _dataMap(await _get(
      '/v1/course-role-permission/teaching-class/resources',
      {'teclId': '$teachingClassId'},
    ));
    final resources = result['resourceList'];
    if (resources is! List) throw const VodInvalidResponseException();
    final signs = resources
        .whereType<JsonMap>()
        .map((resource) => resource['sign'])
        .toSet();
    if (isLive
        ? !signs.contains('p2-live-page')
        : !signs.contains('p2-video-page') ||
            !signs.contains('p2-video-playback-view')) {
      throw const VodPermissionException();
    }
  }

  Future<List<VodLesson>> fetchLiveLessons({
    required int termId,
    int? teachingClassId,
    void Function(List<VodLesson>)? onProgress,
  }) async {
    if (termId <= 0) throw const VodInvalidResponseException('请选择有效学期');
    final lessons = <VodLesson>[];
    var parsed = 0;
    await _readAll(
      '/v1/vod_live/t-1',
      {
        'acteId': '$termId',
        'liveType': '0',
        if (teachingClassId != null) 'teclId': '$teachingClassId'
      },
      identityField: 'id',
      orderBy: 'courBeginTime',
      ascending: false,
      onProgress: (records) {
        for (final record in records.skip(parsed)) {
          final lesson = VodLesson.fromLiveJson(record);
          if (intValue(record['acteId']) != termId ||
              lesson.id <= 0 ||
              lesson.teachingClassId <= 0 ||
              (teachingClassId != null &&
                  lesson.teachingClassId != teachingClassId)) {
            throw const VodInvalidResponseException('直播课次与所选学期或教学班不一致，请刷新重试');
          }
          parsed++;
          if (lesson.isLiveAvailable) {
            lessons.add(lesson);
            onProgress?.call(List<VodLesson>.unmodifiable(lessons));
          }
        }
      },
    );
    return List.unmodifiable(lessons);
  }

  Future<VodPlayback> fetchLivePlayback(
      {required VodCourse course,
      required VodLesson lesson,
      VodLiveProtocol protocol = VodLiveProtocol.hls}) async {
    if (!lesson.isLiveAvailable ||
        lesson.teachingClassId != course.teachingClassId) {
      throw const VodPermissionException('这节课当前没有可观看的直播');
    }
    await checkTeachingClassPermission(course.teachingClassId, isLive: true);
    final verified =
        _dataMap(await _get('/v1/course/verify', {'courId': '${lesson.id}'}));
    if (verified['verify'] != true) throw const VodPermissionException();
    final response = await _get('/v1/course_vod_videoinfos', {
      'courseId': '${lesson.id}',
      'playType': switch (protocol) {
        VodLiveProtocol.hls => '3',
        VodLiveProtocol.flv => '2',
        VodLiveProtocol.webRtc => '1',
      },
    });
    final data = _dataMap(response);
    debugPrint(
        'ShuYoVOD live detail: permission=${data['lvcrLiveStatus']}, views=${data['courseDeviceViewDtoList'] is List ? (data['courseDeviceViewDtoList'] as List).length : -1}, start=${data['liveStartTime'] != null}, end=${data['liveEndTime'] != null}');
    if (intValue(data['lvcrLiveStatus'], -1) != 1) {
      throw const VodPermissionException();
    }
    if (intValue(data['id']) != lesson.id ||
        intValue(data['teclId']) != course.teachingClassId) {
      throw const VodInvalidResponseException('直播详情与所选课次不一致，请刷新重试');
    }
    final now = response is JsonMap
        ? vodDateValue(response['timestamp']) ?? DateTime.now()
        : DateTime.now();
    final start = vodDateValue(data['liveStartTime']);
    final end = vodDateValue(data['liveEndTime']);
    if (start == null ||
        end == null ||
        now.isBefore(start) ||
        !now.isBefore(end)) {
      throw const VodLiveUnavailableException('当前不在这节课的直播时间内');
    }
    final rawViews = data['courseDeviceViewDtoList'];
    if (rawViews is! List) throw const VodInvalidResponseException();
    final stunServer =
        protocol == VodLiveProtocol.webRtc ? await _fetchStunServer() : '';
    debugPrint(
        'ShuYoVOD live device states: ${rawViews.whereType<JsonMap>().map((device) => intValue(device['deviceStatus'], -1)).join(',')}');
    final views = <VodView>[];
    for (final value in rawViews.whereType<JsonMap>()) {
      if (!const {0, 1}.contains(intValue(value['deviceStatus'], -1))) {
        continue;
      }
      if (protocol == VodLiveProtocol.webRtc) {
        final source = stringValue(value['chanNameMainPlayUrl']).trim();
        final deviceId = stringValue(value['chanGbidMain']).trim();
        final token = stringValue(value['mainTokenStr']);
        if (source.isEmpty || deviceId.isEmpty || token.isEmpty) continue;
        final signalingUri = _resolveWebRtcSignalingUri(source);
        final target = signalingUri.replace(
          scheme: signalingUri.scheme == 'wss' ? 'https' : 'http',
        );
        final headers = await mediaHeadersFor(target);
        final webRtcSource = VodWebRtcSource(
          signalingUri: signalingUri,
          deviceId: deviceId,
          accountToken: token,
          stunServer: stunServer,
          useWebVpn: useWebVpn,
          headers: headers,
        );
        views.add(VodView(
          viewNumber: intValue(value['deviViewNum'], -1),
          url: signalingUri,
          httpHeaders: headers,
          displayLabel: '直播视角 ${views.length + 1}',
          webRtcSource: webRtcSource,
        ));
        continue;
      }
      final hls = stringValue(value['chanNameMainHlsPlayUrl']).trim();
      final source = protocol == VodLiveProtocol.hls && hls.isNotEmpty
          ? hls
          : stringValue(value['chanNameMainPlayUrl']).trim();
      if (source.isEmpty) continue;
      final token = stringValue(value['mainTokenStr']);
      final original = Uri.tryParse(source);
      debugPrint(
          'ShuYoVOD live source: device=${value['deviceStatus']}, scheme=${original?.scheme}, host=${original?.host}, port=${original?.port}');
      if (original == null || original.hasFragment) {
        throw const VodInvalidResponseException();
      }
      final rawUrl = token.isEmpty ||
              original.queryParameters.containsKey('account_token')
          ? source
          : '$source${original.hasQuery ? '&' : '?'}account_token=${Uri.encodeQueryComponent(token)}';
      final Uri url;
      try {
        url = _providedMediaUrlResolver?.call(rawUrl) ??
            VodUrlResolver.resolveMediaUrl(rawUrl, useWebVpn: useWebVpn);
      } on Object {
        throw const VodInvalidResponseException('暂不支持此直播资源地址');
      }
      if (!['https', 'http'].contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const VodInvalidResponseException();
      }
      final number = intValue(value['deviViewNum'], -1);
      views.add(VodView(
        viewNumber: number,
        url: url,
        httpHeaders: await mediaHeadersFor(url),
        displayLabel: '直播视角 ${views.length + 1}',
      ));
    }
    if (views.isEmpty) {
      final devices = rawViews.whereType<JsonMap>().toList();
      if (devices.isNotEmpty &&
          devices.every((device) => intValue(device['deviceStatus'], -1) > 1)) {
        throw const VodLiveUnavailableException('直播设备当前离线，请稍后重试');
      }
      throw const VodLiveUnavailableException('直播设备暂未提供可播放的画面');
    }
    return VodPlayback(
      lessonId: lesson.id,
      teachingClassId: course.teachingClassId,
      title: stringValue(data['courName'], course.name),
      views: List.unmodifiable(views),
      isLive: true,
      description: stringValue(
          data['description'], stringValue(data['teclDescription'])),
    );
  }

  Future<String> _fetchStunServer() async {
    final data = _dataMap(await _get('/v1/setting/stun'));
    final nested = data['data'];
    final config =
        data['stunConfig'] ?? (nested is JsonMap ? nested['stunConfig'] : null);
    if (config is! JsonMap) return '';
    final ip = stringValue(config['ip']).trim();
    final port = intValue(config['port']);
    if (ip.isEmpty || port <= 0 || port > 65535) return '';
    return '$ip:$port';
  }

  Uri _resolveWebRtcSignalingUri(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        !const {'ws', 'wss'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const VodInvalidResponseException('暂不支持此直播信令地址');
    }
    final target = uri.replace(scheme: 'https', port: uri.port);
    if (!VodUrlResolver.isKnownMediaUri(target)) {
      throw const VodInvalidResponseException('暂不支持此直播信令地址');
    }
    final mapped = VodUrlResolver.mapServiceUri(target, useWebVpn: useWebVpn);
    if (useWebVpn && !VodUrlResolver.isProxiedMediaUri(mapped) ||
        !useWebVpn && VodUrlResolver.isProxiedMediaUri(mapped)) {
      throw const VodInvalidResponseException('直播信令地址与当前连接方式不一致');
    }
    return mapped.replace(scheme: useWebVpn ? 'wss' : uri.scheme);
  }

  Future<Map<String, String>> mediaHeadersFor(Uri target) async {
    final headers = Map<String, String>.of(
        await (_providedMediaHeadersLoader?.call(target) ??
            _authService.mediaHeadersFor(target, useWebVpn: useWebVpn)));
    headers.removeWhere((name, _) =>
        ['jwt-token', 'authorization'].contains(name.toLowerCase()));
    return Map.unmodifiable(headers);
  }

  Future<void> keepLiveAlive(VodCourse course, VodLesson lesson) async {
    await _get('/v1/live/keepAlive', const {},
        {'courId': lesson.id, 'subjCode': course.code});
  }

  Future<VodPlayback> fetchPlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    if (!lesson.isPlayable ||
        lesson.id <= 0 ||
        lesson.teachingClassId != course.teachingClassId) {
      throw const VodPermissionException('这节课尚无可观看的录播');
    }
    await checkTeachingClassPermission(course.teachingClassId);
    final verified = _dataMap(await _get(
      '/v1/course/verify',
      {'courId': '${lesson.id}'},
    ));
    if (verified['verify'] != true) throw const VodPermissionException();
    final data = _dataMap(await _get(
      '/v1/course_vod_urls_new',
      {'courseId': '${lesson.id}'},
    ));
    if (intValue(data['lvcrVodStatus'], -1) != 1) {
      throw const VodPermissionException();
    }
    if (intValue(data['id']) != lesson.id ||
        intValue(data['teclId']) != course.teachingClassId) {
      throw const VodInvalidResponseException('录播详情与所选课次不一致，请刷新重试');
    }
    final rawViews = data['courseVodViewList'];
    if (rawViews is! List) throw const VodInvalidResponseException();
    final views = <VodView>[];
    for (final value in rawViews) {
      if (value is! JsonMap || intValue(value['courId']) != lesson.id) {
        throw const VodInvalidResponseException('录播视角与所选课次不一致，请刷新重试');
      }
      final rawUrl = stringValue(value['url']);
      if (rawUrl.isEmpty) continue;
      final Uri url;
      try {
        url = _providedMediaUrlResolver?.call(rawUrl) ??
            VodUrlResolver.resolveMediaUrl(rawUrl, useWebVpn: useWebVpn);
      } on Object {
        throw const VodInvalidResponseException('暂不支持此录播资源地址');
      }
      if ((url.scheme != 'https' && url.scheme != 'http') ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const VodInvalidResponseException('录播平台返回了无效资源地址');
      }
      // JWT must not be copied to a media CDN. Auth resolves cookies per target.
      final mediaHeaders = Map<String, String>.of(
        await (_providedMediaHeadersLoader?.call(url) ??
            _authService.mediaHeadersFor(url, useWebVpn: useWebVpn)),
      );
      mediaHeaders.removeWhere((name, _) =>
          name.toLowerCase() == 'jwt-token' ||
          name.toLowerCase() == 'authorization');
      views.add(VodView(
        viewNumber: intValue(value['viewNum']),
        url: url,
        httpHeaders: Map.unmodifiable(mediaHeaders),
      ));
    }
    if (views.isEmpty) throw const VodApiException('这节课暂无可用的录播资源');
    final seconds = intValue(data['lastPlayTime']);
    return VodPlayback(
      lessonId: lesson.id,
      teachingClassId: course.teachingClassId,
      title: stringValue(data['courName'], lesson.name),
      views: List.unmodifiable(views),
      lastPosition: Duration(seconds: seconds < 0 ? 0 : seconds),
      voiceChannel:
          data['voiceChannel'] == null ? null : intValue(data['voiceChannel']),
      description: stringValue(
          data['description'], stringValue(data['teclDescription'])),
    );
  }

  Future<List<JsonMap>> _readAll(
    String path,
    Map<String, String> filters, {
    required String identityField,
    required String orderBy,
    required bool ascending,
    void Function(List<JsonMap>)? onProgress,
  }) async {
    final records = <JsonMap>[];
    final seenIds = <int>{};
    int? expectedTotal;
    for (var page = 1; page <= 1000; page++) {
      final data = _dataMap(await _get(path, {
        ...filters,
        'page.pageIndex': '$page',
        'page.pageSize': '$pageSize',
        'page.orders[0].field': orderBy,
        'page.orders[0].asc': '$ascending',
      }));
      final values = data['records'];
      if (values is! List || values.any((value) => value is! JsonMap)) {
        throw const VodInvalidResponseException();
      }
      if (data['pageIndex'] != null && intValue(data['pageIndex']) != page) {
        throw const VodInvalidResponseException('录播平台分页异常，请刷新重试');
      }
      final total = intValue(data['rowCount'], -1);
      final pages = intValue(data['pageCount']);
      if (total < 0) throw const VodInvalidResponseException();
      if (expectedTotal != null && total != expectedTotal) {
        throw const VodInvalidResponseException('课程列表已更新，请刷新重试');
      }
      expectedTotal = total;
      for (final record in values.cast<JsonMap>()) {
        final id = intValue(record[identityField]);
        if (id <= 0) throw const VodInvalidResponseException();
        // A moving sort order may repeat rows on a later page while omitting
        // others. Raw row counts must not turn that into a complete catalog.
        if (!seenIds.add(id)) {
          throw const VodInvalidResponseException('课程列表分页重复，请刷新重试');
        }
        records.add(record);
      }
      final complete = pages > 0 ? page >= pages : records.length >= total;
      if (complete) {
        if (records.length != total) {
          throw const VodInvalidResponseException('课程列表未完整加载，请刷新重试');
        }
      } else if (values.isEmpty) {
        throw const VodInvalidResponseException('课程列表未完整加载，请刷新重试');
      }
      onProgress?.call(List<JsonMap>.unmodifiable(records));
      if (complete) return records;
    }
    throw const VodInvalidResponseException('课程列表分页异常，请稍后重试');
  }

  Future<Object?> _get(
    String path, [
    Map<String, String> params = const {},
    JsonMap? body,
  ]) async {
    if (_disposed) throw const VodSessionExpiredException();
    final ownsAuthentication = _providedHeadersLoader == null;
    if (ownsAuthentication) await _ensureSession();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _getOnce(path, params, body);
      } on _VodBusinessSessionExpired {
        if (!ownsAuthentication) throw const VodSessionExpiredException();
        if (attempt == 1) {
          // An expired business JWT is not proof that the campus SSO expired.
          throw const VodApiException('暂时无法建立录播会话，请稍后重试');
        }
        await _ensureSession(forceRefresh: true);
      }
    }
    throw const VodApiException('暂时无法建立录播会话，请稍后重试');
  }

  Future<void> _ensureSession({bool forceRefresh = false}) async {
    if (_disposed) throw const VodSessionExpiredException();
    try {
      await _authService.ensureSession(
        useWebVpn: useWebVpn,
        forceRefresh: forceRefresh,
      );
    } on VodCampusAuthRequiredException catch (error) {
      throw VodSessionExpiredException.campus(ssoExpired: error.ssoExpired);
    } on VodAuthException catch (error) {
      throw VodApiException(error.message);
    } on TimeoutException {
      throw const VodNetworkException('录播平台请求超时，请稍后重试');
    } on SocketException {
      throw const VodNetworkException();
    } on http.ClientException {
      throw const VodNetworkException();
    } on Object {
      throw const VodApiException('暂时无法建立录播会话，请稍后重试');
    }
  }

  Future<Object?> _getOnce(
    String path,
    Map<String, String> params,
    JsonMap? body,
  ) async {
    if (_disposed) throw const VodSessionExpiredException();
    final uri = _providedUriResolver?.call(path, params) ??
        VodUrlResolver.apiUri(
          path,
          queryParameters: params,
          useWebVpn: useWebVpn,
        );
    final headers = await _headers(uri);
    final http.Response response;
    try {
      final request = http.Request(body == null ? 'GET' : 'POST', uri)
        ..followRedirects = false
        ..headers.addAll({'Accept': 'application/json', ...headers});
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await HttpTimeout.request(
        http.Response.fromStream(await HttpTimeout.request(
          _httpClient.send(request),
        )),
        message: '录播平台请求超时，请稍后重试',
      );
    } on TimeoutException {
      throw const VodNetworkException('录播平台请求超时，请稍后重试');
    } on SocketException {
      throw const VodNetworkException();
    } on http.ClientException {
      throw const VodNetworkException();
    }
    if (response.statusCode == 401) throw const _VodBusinessSessionExpired();
    if (response.statusCode == 403) throw const VodPermissionException();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      // Never forward the platform JWT through an identity-provider redirect.
      throw const _VodBusinessSessionExpired();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VodApiException('录播平台请求失败，请稍后重试', statusCode: response.statusCode);
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (text.startsWith('<')) {
      // Auth redirects commonly return HTML with a successful HTTP status.
      if (RegExp(r'newsso\.shu|oauth2?/|#/login|统一身份认证|webvpn',
              caseSensitive: false)
          .hasMatch(text)) {
        throw const _VodBusinessSessionExpired();
      }
      throw const VodInvalidResponseException();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const VodInvalidResponseException();
    }
    if (decoded is JsonMap) {
      final status = intValue(decoded['status']);
      final code = intValue(decoded['code']);
      if ({401, 10013, 10014}.contains(status) ||
          {401, 10013, 10014}.contains(code)) {
        throw const _VodBusinessSessionExpired();
      }
      if (status == 403 || code == 403) throw const VodPermissionException();
      if ((status != 0 && status != 200) ||
          (code != 0 && code != 200) ||
          decoded['ok'] == false ||
          decoded['dataOk'] == false) {
        // Do not include backend messages: they can contain signed URLs.
        throw VodApiException('录播平台暂时无法完成请求，请稍后重试',
            statusCode: status == 0 ? code : status);
      }
    }
    return decoded;
  }

  Future<Map<String, String>> _headers(Uri target) async => Map.of(
        await (_providedHeadersLoader?.call(target) ??
            _authService.headersFor(target, useWebVpn: useWebVpn)),
      );

  static JsonMap _dataMap(Object? result) {
    if (result is! JsonMap || result['data'] is! JsonMap) {
      throw const VodInvalidResponseException();
    }
    return result['data'] as JsonMap;
  }

  void dispose() {
    _disposed = true;
    if (_ownsHttpClient) _httpClient.close();
    if (_ownsAuthService) _authService.dispose();
  }
}
