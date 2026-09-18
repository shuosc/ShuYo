import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/certificate_policy.dart';
import '../../core/client_user_agent.dart';
import '../../core/forum_url_resolver.dart';
import '../models/common.dart';
import 'forum_auth_service.dart';
import 'http_timeout.dart';

const forumRefreshTooFastMessage = '刷新过快，请稍后再试';
const forumWebVpnParseFailedMessage = 'WebVPN 解析失败，请尝试使用校园网访问';

class ForumApiException implements Exception {
  const ForumApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    final code = statusCode;
    if (code == null ||
        message == forumRefreshTooFastMessage ||
        message == forumWebVpnParseFailedMessage) {
      return message;
    }
    return '$message ($code)';
  }
}

class ForumAuthException extends ForumApiException {
  const ForumAuthException([
    super.message = '请先登录乐乎',
    int? statusCode,
  ]) : super(statusCode: statusCode);
}

class ForumOfflineCacheMissException extends ForumApiException {
  const ForumOfflineCacheMissException() : super('无法连接论坛，请尝试重新登录。');
}

class ForumConnectionUnavailableException extends ForumApiException {
  const ForumConnectionUnavailableException(super.message);
}

class DiscourseApiClient {
  DiscourseApiClient({
    required ForumAuthService authService,
    http.Client? httpClient,
  })  : _authService = authService,
        _httpClient = httpClient ?? _defaultHttpClient();

  final ForumAuthService _authService;
  final http.Client _httpClient;
  String? _csrfToken;
  Future<void> _requestStartQueue = Future<void>.value();
  DateTime? _lastRequestStartedAt;

  static const _requestSpacing = Duration(milliseconds: 220);

  static http.Client _defaultHttpClient() {
    final client = HttpClient();
    if (CertificatePolicy.supportsForumException) {
      client.badCertificateCallback = (certificate, host, port) {
        return CertificatePolicy.allowsHost(host);
      };
    }
    return IOClient(client);
  }

  Future<JsonMap> getJson(String path) async {
    final uri = _uri(path);
    final headers = await _headers();
    final response = await HttpTimeout.request(
      _send(() => _httpClient.get(
            uri,
            headers: headers,
          )),
      message: '论坛请求超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<JsonMap> getTrackedTopicJson(
    String path, {
    required int topicId,
  }) {
    return _runComposed(
      () => _getTrackedTopicJson(path, topicId: topicId),
    );
  }

  Future<JsonMap> _getTrackedTopicJson(
    String path, {
    required int topicId,
  }) async {
    final uri = _uri(path);
    final headers = await _headers(
      csrfToken: await _csrf(),
      referer: '${ForumUrlResolver.baseUrl}/',
      trackViewTopicId: topicId,
    );
    final response = await HttpTimeout.request(
      _send(() => _httpClient.get(
            uri,
            headers: headers,
          )),
      message: '论坛请求超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<JsonMap> postForm(String path, String body) {
    return _runComposed(() => _postForm(path, body));
  }

  Future<JsonMap> _postForm(String path, String body) async {
    final uri = _uri(path);
    final headers = await _headers(
      csrfToken: await _csrf(),
      formRequest: true,
    );
    final response = await HttpTimeout.request(
      _send(() => _httpClient.post(
            uri,
            headers: headers,
            body: body,
          )),
      message: '论坛请求超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<JsonMap> putForm(String path, String body) {
    return _runComposed(() => _putForm(path, body));
  }

  Future<JsonMap> _putForm(String path, String body) async {
    final uri = _uri(path);
    final headers = await _headers(
      csrfToken: await _csrf(),
      formRequest: true,
    );
    final response = await HttpTimeout.request(
      _send(() => _httpClient.put(
            uri,
            headers: headers,
            body: body,
          )),
      message: '论坛请求超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<JsonMap> deleteForm(String path, String body) {
    return _runComposed(() => _deleteForm(path, body));
  }

  Future<JsonMap> _deleteForm(String path, String body) async {
    final uri = _uri(path);
    final headers = await _headers(
      csrfToken: await _csrf(),
      formRequest: true,
    );
    final response = await HttpTimeout.request(
      _send(() => _httpClient.delete(
            uri,
            headers: headers,
            body: body,
          )),
      message: '论坛请求超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<JsonMap> postMultipart({
    required String path,
    required Map<String, String> fields,
    required String fileField,
    required Uint8List fileBytes,
    required String filename,
  }) {
    return HttpTimeout.request(
      _postMultipart(
        path: path,
        fields: fields,
        fileField: fileField,
        fileBytes: fileBytes,
        filename: filename,
      ),
      timeout: HttpTimeout.transfer,
      message: '论坛上传超时，请稍后再试',
    );
  }

  Future<JsonMap> _postMultipart({
    required String path,
    required Map<String, String> fields,
    required String fileField,
    required Uint8List fileBytes,
    required String filename,
  }) async {
    final uri = _uri(path);
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(await _headers(csrfToken: await _csrf()));
    request.fields.addAll(fields);
    request.files.add(
      http.MultipartFile.fromBytes(
        fileField,
        fileBytes,
        filename: filename,
      ),
    );
    final streamed = await HttpTimeout.request(
      _send(() => _httpClient.send(request)),
      timeout: HttpTimeout.transfer,
      message: '论坛上传超时，请稍后再试',
    );
    final response = await HttpTimeout.request(
      http.Response.fromStream(streamed),
      timeout: HttpTimeout.transfer,
      message: '论坛上传超时，请稍后再试',
    );
    await _storeResponseCookies(uri, response);
    return _decode(response);
  }

  Future<T> _runComposed<T>(Future<T> Function() operation) {
    return HttpTimeout.request(
      operation(),
      timeout: HttpTimeout.composed,
      message: '论坛操作超时，请稍后再试',
    );
  }

  Future<void> _storeResponseCookies(
    Uri uri,
    http.BaseResponse response,
  ) async {
    await _authService.updateFromSetCookieHeaders(
      uri,
      response.headersSplitValues['set-cookie'] ?? const <String>[],
    );
  }

  Future<Map<String, String>> _headers({
    String? csrfToken,
    bool formRequest = false,
    String? referer,
    int? trackViewTopicId,
  }) async {
    final headers = <String, String>{
      'accept': formRequest
          ? '*/*'
          : 'application/json, text/javascript, */*; q=0.01',
      'user-agent': ClientUserAgent.mobileBrowser,
      'x-requested-with': 'XMLHttpRequest',
    };
    final cookie = await _authService.cookieHeader();
    if (cookie != null && cookie.isNotEmpty) {
      headers['cookie'] = cookie;
      if (trackViewTopicId != null) {
        headers['discourse-logged-in'] = 'true';
      }
    }
    if (csrfToken != null && csrfToken.isNotEmpty) {
      headers['x-csrf-token'] = csrfToken;
    }
    if (referer != null && referer.isNotEmpty) {
      headers['referer'] = referer;
    }
    if (trackViewTopicId != null) {
      headers['discourse-present'] = 'true';
      headers['discourse-track-view'] = 'true';
      headers['discourse-track-view-topic-id'] = '$trackViewTopicId';
    }
    if (formRequest) {
      headers['content-type'] =
          'application/x-www-form-urlencoded; charset=UTF-8';
    }
    return headers;
  }

  Future<T> _send<T>(Future<T> Function() request) async {
    final previous = _requestStartQueue;
    final nextSlot = Completer<void>();
    _requestStartQueue = nextSlot.future;
    await previous;
    try {
      final lastStartedAt = _lastRequestStartedAt;
      if (lastStartedAt != null) {
        final wait = _requestSpacing - DateTime.now().difference(lastStartedAt);
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
      }
      _lastRequestStartedAt = DateTime.now();
    } finally {
      nextSlot.complete();
    }
    return request();
  }

  Future<String> _csrf() async {
    final cached = _csrfToken;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final json = await getJson('/session/csrf.json');
    final token = stringValue(json['csrf']);
    if (token.isEmpty) {
      throw const ForumAuthException('无法获取 CSRF Token，请重新登录');
    }
    _csrfToken = token;
    return token;
  }

  Uri _uri(String path) {
    return ForumUrlResolver.uri(path);
  }

  JsonMap _decode(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    if (body.trim().isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return <String, dynamic>{};
      }
      if (response.statusCode == 429) {
        throw ForumApiException(
          forumRefreshTooFastMessage,
          statusCode: response.statusCode,
        );
      }
      throw ForumApiException(
        '论坛请求失败',
        statusCode: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = _decodeJsonBody(body);
    } on FormatException {
      throw ForumApiException(
        ForumUrlResolver.usesWebVpn
            ? forumWebVpnParseFailedMessage
            : forumRefreshTooFastMessage,
        statusCode: response.statusCode,
      );
    }
    if (decoded is! JsonMap) {
      throw ForumApiException(
        '加载失败，请稍后再试',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == 429) {
      throw ForumApiException(
        _rateLimitMessage(decoded) ?? forumRefreshTooFastMessage,
        statusCode: response.statusCode,
      );
    }
    if (decoded['error_type'] == 'not_logged_in') {
      throw const ForumAuthException();
    }
    if (response.statusCode == 401) {
      throw ForumAuthException(
        '登录状态已失效',
        response.statusCode,
      );
    }
    if (response.statusCode == 429) {
      throw ForumApiException(
        forumRefreshTooFastMessage,
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ForumApiException(
        _errorMessage(decoded),
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  String _errorMessage(JsonMap json) {
    final errors = json['errors'];
    if (errors is List && errors.isNotEmpty) {
      return errors.map((error) => error.toString()).join('\n');
    }
    final error = json['error'];
    if (error != null) {
      return error.toString();
    }
    return '论坛请求失败';
  }

  String? _rateLimitMessage(JsonMap json) {
    final errors = json['errors'];
    if (errors is List) {
      final messages = errors
          .map((error) => error.toString().trim())
          .where((error) => error.isNotEmpty)
          .toList(growable: false);
      if (messages.isNotEmpty) {
        return messages.join('\n');
      }
    }
    final error = json['error'];
    if (error != null) {
      final text = error.toString().trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    final extras = json['extras'];
    if (extras is JsonMap) {
      final timeLeft = stringValue(extras['time_left']).trim();
      if (timeLeft.isNotEmpty) {
        return '您执行此操作的次数过多。请等待 $timeLeft 后再试。';
      }
      final waitSeconds = intValue(extras['wait_seconds']);
      if (waitSeconds > 0) {
        final minutes = (waitSeconds / 60).ceil();
        return '您执行此操作的次数过多。请等待 $minutes 分钟后再试。';
      }
    }
    return null;
  }

  Object? _decodeJsonBody(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      if (!ForumUrlResolver.usesWebVpn) {
        rethrow;
      }
      final repaired = _repairWebVpnJsonEscapes(body);
      if (repaired == body) {
        rethrow;
      }
      return jsonDecode(repaired);
    }
  }

  String _repairWebVpnJsonEscapes(String body) {
    return body.replaceAllMapped(
      RegExp(r'\\https?-u([0-9a-fA-F]{4})'),
      (match) => r'\u' + (match.group(1) ?? ''),
    );
  }
}
