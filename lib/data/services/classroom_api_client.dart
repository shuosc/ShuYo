import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/classroom_url_resolver.dart';
import '../../core/client_user_agent.dart';
import '../models/classroom.dart';
import '../models/common.dart';
import 'classroom_auth_service.dart';
import 'academic_auth_service.dart';
import 'http_timeout.dart';

class ClassroomApiException implements Exception {
  const ClassroomApiException(
    this.message, {
    this.statusCode,
    this.accessMode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final ClassroomAccessMode? accessMode;
  final Object? cause;

  static ClassroomApiException forRequest(
    Object error, {
    required ClassroomAccessMode accessMode,
  }) {
    if (error is ClassroomApiException) {
      if (error.accessMode != null) return error;
      return ClassroomApiException(
        error.message,
        statusCode: error.statusCode,
        accessMode: accessMode,
        cause: error,
      );
    }
    final message = switch (error) {
      TimeoutException() => '请求超时，请稍后重试',
      SocketException() ||
      TlsException() ||
      HttpException() ||
      http.ClientException() =>
        '网络连接异常，请稍后重试',
      _ => '空教室加载失败，请稍后重试',
    };
    return ClassroomApiException(
      message,
      accessMode: accessMode,
      cause: error,
    );
  }

  @override
  String toString() {
    final code = statusCode;
    if (code == null) {
      return message;
    }
    return '$message ($code)';
  }
}

class ClassroomWebVpnAuthException extends ClassroomApiException {
  const ClassroomWebVpnAuthException()
      : super('WebVPN登录已失效，需要重新登录', accessMode: ClassroomAccessMode.webVpn);
}

class ClassroomApiClient {
  ClassroomApiClient({
    ClassroomAuthService? authService,
    http.Client? httpClient,
    Future<WebVpnSessionStatus> Function()? webVpnSessionValidator,
  })  : _webVpnSessionValidator = webVpnSessionValidator ??
            (() => AcademicAuthService().validateWebVpnSession()),
        _authService = authService ?? ClassroomAuthService(),
        _httpClient = httpClient ?? IOClient(HttpClient());

  final ClassroomAuthService _authService;
  final http.Client _httpClient;
  final Future<WebVpnSessionStatus> Function() _webVpnSessionValidator;

  Future<ClassroomSearchOptions> fetchSearchOptions({
    ClassroomAccessMode? accessMode,
  }) async {
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
    final form =
        await _postJson('/build/findSearchRoomSearchForm', accessMode: mode);
    final section = await _postJson('/course/findSection', accessMode: mode);
    return parseSearchOptions(form, section);
  }

  Future<ClassroomBuildingSchedule> fetchBuildingSchedule({
    required ClassroomBuilding building,
    required DateTime date,
    ClassroomAccessMode? accessMode,
  }) async {
    final json = await _postJson(
      '/build/findBuildRoomType',
      accessMode: accessMode ?? ClassroomUrlResolver.accessMode,
      body: {
        'buildId': building.id.toString(),
        'courseDate': _dateParam(date),
      },
    );
    return parseBuildingSchedule(json, building: building);
  }

  static ClassroomSearchOptions parseSearchOptions(
    JsonMap formJson,
    JsonMap sectionJson,
  ) {
    final formData = _dataMap(formJson);
    final sectionData = _dataMap(sectionJson);
    final buildings = (formData['buildList'] as List? ?? const [])
        .whereType<JsonMap>()
        .map(ClassroomBuilding.fromJson)
        .where((building) => building.id > 0 && building.name.isNotEmpty)
        .toList(growable: false);
    final sections = (sectionData['section'] as List? ?? const [])
        .whereType<JsonMap>()
        .map(ClassroomSection.fromJson)
        .where((section) => section.index > 0)
        .toList(growable: false)
      ..sort((a, b) => a.index.compareTo(b.index));
    return ClassroomSearchOptions(
      buildings: buildings,
      sections: sections,
      currentSection: intValue(sectionData['curSection']),
    );
  }

  static ClassroomBuildingSchedule parseBuildingSchedule(
    JsonMap json, {
    required ClassroomBuilding building,
  }) {
    final data = _dataMap(json);
    final floors = (data['floorList'] as List? ?? const [])
        .whereType<JsonMap>()
        .map(ClassroomFloor.fromJson)
        .where((floor) => floor.rooms.isNotEmpty)
        .toList(growable: false);
    return ClassroomBuildingSchedule(
      building: building,
      floors: floors,
    );
  }

  Future<JsonMap> _postJson(
    String path, {
    Map<String, String>? body,
    required ClassroomAccessMode accessMode,
  }) async {
    // Keep the destination and authentication in the same access mode even
    // if settings change while session cookies are being read.
    final useWebVpn = accessMode == ClassroomAccessMode.webVpn;
    final accessRevision = ClassroomUrlResolver.revision;
    final uri = ClassroomUrlResolver.uri(path, accessMode: accessMode);
    try {
      final headers = await _headers(uri, useWebVpn: useWebVpn);
      final response = await HttpTimeout.request(
        _httpClient.post(
          uri,
          headers: headers,
          body: body,
        ),
        message: '空教室查询请求超时，请稍后再试',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ClassroomApiException(
          '空教室查询请求失败',
          statusCode: response.statusCode,
        );
      }
      final decoded = _decodeJson(response.bodyBytes);
      final code = intValue(decoded['code']);
      if (code != 200) {
        throw ClassroomApiException(
          stringValue(decoded['msg'], '空教室查询失败'),
          statusCode: code,
        );
      }
      return decoded;
    } on ClassroomWebVpnAuthException {
      rethrow;
    } catch (error, stackTrace) {
      if (useWebVpn && accessRevision == ClassroomUrlResolver.revision) {
        var status = WebVpnSessionStatus.unavailable;
        try {
          status = await _webVpnSessionValidator();
        } on Object {
          // A failed probe does not establish that the login has expired.
        }
        if (accessRevision == ClassroomUrlResolver.revision &&
            status == WebVpnSessionStatus.loginRequired) {
          throw const ClassroomWebVpnAuthException();
        }
      }
      Error.throwWithStackTrace(
        ClassroomApiException.forRequest(error, accessMode: accessMode),
        stackTrace,
      );
    }
  }

  Future<Map<String, String>> _headers(
    Uri uri, {
    required bool useWebVpn,
  }) async {
    final headers = <String, String>{
      'accept': 'application/json, text/javascript, */*; q=0.01',
      'referer': uri.origin,
      'user-agent': ClientUserAgent.mobileBrowser,
      'x-requested-with': 'XMLHttpRequest',
    };
    if (useWebVpn) {
      final cookie = await _authService.cookieHeader(targetUri: uri);
      if (cookie == null || cookie.isEmpty) {
        throw const ClassroomWebVpnAuthException();
      }
      headers['cookie'] = cookie;
    }
    return headers;
  }

  JsonMap _decodeJson(List<int> bodyBytes) {
    final body = utf8.decode(bodyBytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const ClassroomApiException('加载失败，请稍后再试');
    }
    if (decoded is! JsonMap) {
      throw const ClassroomApiException('加载失败，请稍后再试');
    }
    return decoded;
  }

  static JsonMap _dataMap(JsonMap json) {
    final data = json['data'];
    if (data is JsonMap) {
      return data;
    }
    return const <String, dynamic>{};
  }

  static String _dateParam(DateTime date) {
    return '${date.year}-${date.month}-${date.day}';
  }
}
