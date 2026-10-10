import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/academic_url_resolver.dart';
import '../../core/client_backend_constants.dart';
import 'academic_account_store.dart';
import 'academic_auth_service.dart';
import 'academic_progress_api_client.dart';
import 'http_timeout.dart';
import 'secure_app_store.dart';

class StudentIdentityException implements Exception {
  const StudentIdentityException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class StudentIdentitySession {
  const StudentIdentitySession({
    required this.token,
    required this.studentId,
    required this.maskedStudentId,
    required this.expiresAt,
  });

  final String token;
  final String studentId;
  final String maskedStudentId;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Map<String, String> toJson() => {
        'token': token,
        'studentId': studentId,
        'maskedStudentId': maskedStudentId,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static StudentIdentitySession? fromJson(Object? value) {
    if (value is! Map) return null;
    final token = value['token']?.toString() ?? '';
    final studentId = value['studentId']?.toString() ?? '';
    final masked = value['maskedStudentId']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(value['expiresAt']?.toString() ?? '');
    if (token.isEmpty || studentId.isEmpty || expiresAt == null) return null;
    return StudentIdentitySession(
      token: token,
      studentId: studentId,
      maskedStudentId: masked,
      expiresAt: expiresAt,
    );
  }
}

class StudentDataDeletionGrant {
  const StudentDataDeletionGrant({
    required this.token,
    required this.studentId,
    required this.maskedStudentId,
    required this.expiresAt,
  });

  final String token;
  final String studentId;
  final String maskedStudentId;
  final DateTime expiresAt;

  static StudentDataDeletionGrant? fromJson(
    Object? value, {
    required String studentId,
  }) {
    if (value is! Map) return null;
    final token = value['token']?.toString() ?? '';
    final masked = value['maskedStudentId']?.toString() ?? '';
    final expiresAt = DateTime.tryParse(value['expiresAt']?.toString() ?? '');
    if (token.isEmpty || masked.isEmpty || expiresAt == null) return null;
    return StudentDataDeletionGrant(
      token: token,
      studentId: studentId,
      maskedStudentId: masked,
      expiresAt: expiresAt,
    );
  }
}

class StudentIdentityService extends ChangeNotifier {
  StudentIdentityService({
    SecureAppStore? secureStore,
    AcademicAccountStore? accountStore,
    AcademicAuthService? academicAuthService,
    Future<SharedPreferences> Function()? preferencesLoader,
    http.Client? httpClient,
  })  : _secureStore = secureStore ?? SecureAppStore(),
        _accountStore = accountStore ?? AcademicAccountStore(),
        _academicAuthService = academicAuthService,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
        _httpClient = httpClient ??
            IOClient(HttpClient()..connectionTimeout = HttpTimeout.connect);

  static const _sessionKey = 'shuyo.student.session.v1';
  static const _pendingRevocationsKey = 'shuyo.student.pending_revocations.v1';
  static const _consentKey = 'shuyo.student.identity.consent.v1';
  static const _consentChoiceKey = 'shuyo.student.identity.choice.v1';
  static const _manualReverificationKey =
      'shuyo.student.identity.manual_reverification.v1';
  static const _pendingEnrollmentKey =
      'shuyo.student.identity.pending_enrollment.v1';

  final SecureAppStore _secureStore;
  final AcademicAccountStore _accountStore;
  AcademicAuthService? _academicAuthService;
  AcademicAuthService get _schoolAuth =>
      _academicAuthService ??= AcademicAuthService();
  final Future<SharedPreferences> Function() _preferencesLoader;
  final http.Client _httpClient;
  int _epoch = 0;
  bool _isVerified = false;
  bool _disposed = false;

  bool get isVerified => _isVerified;

  void _setVerified(bool value) {
    if (_disposed) return;
    if (_isVerified == value) return;
    _isVerified = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _httpClient.close();
    super.dispose();
  }

  Future<bool> hasConsent() async =>
      (await _preferencesLoader()).getBool(_consentKey) ?? false;

  Future<bool> hasAnsweredConsent() async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(_consentChoiceKey) == true ||
        prefs.getBool(_consentKey) == true;
  }

  Future<void> grantConsent() async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(_consentKey, true);
    await prefs.setBool(_consentChoiceKey, true);
    await prefs.setBool(_pendingEnrollmentKey, true);
  }

  Future<void> declineConsent() async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(_consentKey, false);
    await prefs.setBool(_consentChoiceKey, true);
    await prefs.remove(_pendingEnrollmentKey);
  }

  Future<bool> _requiresManualReverification() async =>
      (await _preferencesLoader()).getBool(_manualReverificationKey) ?? false;

  Future<void> _requireManualReverification() async =>
      (await _preferencesLoader()).setBool(_manualReverificationKey, true);

  Future<void> refreshLocalStatus() async {
    try {
      _setVerified(await loadLocalSession() != null);
    } on Object {
      _setVerified(false);
    }
  }

  Future<StudentIdentitySession?> loadLocalSession() async {
    final raw = await _secureStore.read(_sessionKey);
    if (raw == null) {
      _setVerified(false);
      return null;
    }
    try {
      final session = StudentIdentitySession.fromJson(jsonDecode(raw));
      if (session != null && !session.isExpired) {
        _setVerified(true);
        return session;
      }
    } on Object {
      // Damaged secure storage should not block the rest of the app.
    }
    await _secureStore.delete(_sessionKey);
    _setVerified(false);
    return null;
  }

  Future<void> ensureAfterCampusLogin() async {
    try {
      await retryPendingRevocations();
      final studentId = await _accountStore.loadStudentId();
      if (studentId == null) return;
      final existing = await loadLocalSession();
      if (existing != null && existing.studentId != studentId) {
        await _clearCurrentSession();
      } else if (existing != null) {
        return;
      }
      if (!await hasConsent()) return;
      if (await _requiresManualReverification()) return;
      if ((await _preferencesLoader()).getBool(_pendingEnrollmentKey) != true) {
        return;
      }
      await bindCurrentStudent(manual: true);
    } on Object {
      // ShuYo identity is independent of the campus login and local schedule.
    }
  }

  Future<StudentIdentitySession> bindCurrentStudent(
      {bool force = false, bool manual = false}) async {
    if (!manual && await _requiresManualReverification()) {
      throw const StudentIdentityException('请手动重新认证。');
    }
    final epoch = _epoch;
    final studentId = await _accountStore.loadStudentId();
    if (studentId == null) {
      throw const StudentIdentityException('请先登录校园账户。');
    }
    var previous = await loadLocalSession();
    if (previous != null && previous.studentId != studentId) {
      await _clearCurrentSession();
      previous = null;
    }
    if (!force && previous != null) return previous;
    final schoolUri = AcademicUrlResolver.uri(
      AcademicProgressApiClient.studentIdentityPath,
    );
    final schoolCookie = await _schoolAuth.cookieHeaderForIdentityVerification(
        targetUri: schoolUri);
    if (schoolCookie == null || schoolCookie.isEmpty) {
      throw const StudentIdentityException('当前教务会话不可用，请重新登录校园账户。',
          code: 'no_school_session');
    }
    final response = await _request(
      'POST',
      '/api/v1/student/sessions',
      token: previous?.token,
      body: {
        'schoolCookie': schoolCookie,
        'expectedStudentId': studentId,
        'deviceLabel': Platform.isIOS ? 'iPhone' : 'Android',
        'userInitiated': manual,
      },
    );
    final data = response['data'];
    if (data is! Map) {
      throw const StudentIdentityException('服务器未返回身份凭证。');
    }
    final session = StudentIdentitySession.fromJson({
      'token': data['token'],
      'studentId': studentId,
      'maskedStudentId': data['maskedStudentId'],
      'expiresAt': data['expiresAt'],
    });
    if (session == null) {
      throw const StudentIdentityException('服务器返回的身份凭证无效。');
    }
    if (epoch != _epoch || (await _accountStore.loadStudentId()) != studentId) {
      await _revokeOrQueue(session.token);
      throw const StudentIdentityException('校园账户已切换，请重新核验。');
    }
    await _secureStore.write(_sessionKey, jsonEncode(session.toJson()));
    if (epoch != _epoch) {
      await _secureStore.delete(_sessionKey);
      await _revokeOrQueue(session.token);
      throw const StudentIdentityException('校园账户已退出，请重新核验。');
    }
    _setVerified(true);
    if (manual) {
      try {
        final preferences = await _preferencesLoader();
        await preferences.remove(_manualReverificationKey);
        await preferences.remove(_pendingEnrollmentKey);
      } on Object {
        // The session is already saved. A preference cleanup error must not
        // turn a successful verification into a reported failure.
      }
    }
    return session;
  }

  Future<StudentIdentitySession?> checkCurrentSession() async {
    final session = await loadLocalSession();
    if (session == null) return null;
    final currentStudentId = await _accountStore.loadStudentId();
    if (currentStudentId != null && currentStudentId != session.studentId) {
      await _clearCurrentSession();
      return null;
    }
    try {
      await _request('GET', '/api/v1/student/session', token: session.token);
      return session;
    } on StudentIdentityException catch (error) {
      if (error.code == 'unauthorized') {
        await _secureStore.delete(_sessionKey);
        await _requireManualReverification();
        _setVerified(false);
        return null;
      }
      rethrow;
    }
  }

  /// Call before a feature that requires a verified student. A valid session
  /// is reused; an absent or revoked session needs a user-initiated renewal.
  Future<bool> ensureForProtectedAction() async {
    if (!await hasConsent()) return false;
    try {
      return await checkCurrentSession() != null;
    } on Object {
      return false;
    }
  }

  Future<void> signOut() async {
    _epoch++;
    await _requireManualReverification();
    await (await _preferencesLoader()).remove(_pendingEnrollmentKey);
    await _clearCurrentSession();
  }

  Future<void> revokeAllDevices() async {
    final session = await loadLocalSession();
    if (session == null) return;
    await _request(
      'POST',
      '/api/v1/student/sessions/revoke-all',
      token: session.token,
    );
    _epoch++;
    await _requireManualReverification();
    await (await _preferencesLoader()).remove(_pendingEnrollmentKey);
    await _secureStore.delete(_sessionKey);
    _setVerified(false);
  }

  Future<StudentDataDeletionGrant> beginDataDeletion({
    required String schoolCookie,
    required String expectedStudentId,
  }) async {
    final response = await _request(
      'POST',
      '/api/v1/student/data-deletion/verify',
      body: {
        'schoolCookie': schoolCookie,
        'expectedStudentId': expectedStudentId,
      },
    );
    final grant = StudentDataDeletionGrant.fromJson(
      response['data'],
      studentId: expectedStudentId.trim().toUpperCase(),
    );
    if (grant == null) {
      throw const StudentIdentityException('服务器未返回删除验证结果。');
    }
    return grant;
  }

  Future<void> completeDataDeletion(StudentDataDeletionGrant grant) async {
    await _request('DELETE', '/api/v1/student/data',
        body: {'token': grant.token});
    _epoch++;
    try {
      final localSession = await loadLocalSession();
      final currentStudentId = await _accountStore.loadStudentId();
      final localStudentId = localSession?.studentId ?? currentStudentId;
      if (localStudentId != null &&
          localStudentId.toUpperCase() != grant.studentId) {
        return;
      }
      await _secureStore.delete(_sessionKey);
      final preferences = await _preferencesLoader();
      await preferences.remove(_consentKey);
      await preferences.remove(_consentChoiceKey);
      await preferences.remove(_pendingEnrollmentKey);
      await preferences.setBool(_manualReverificationKey, true);
      _setVerified(false);
    } on Object {
      // The server has already deleted the data; a local storage failure must
      // not report the deletion as unsuccessful.
      _setVerified(false);
    }
  }

  Future<void> _clearCurrentSession() async {
    final session = await loadLocalSession();
    await _secureStore.delete(_sessionKey);
    _setVerified(false);
    if (session != null) await _revokeOrQueue(session.token);
  }

  Future<void> _revokeOrQueue(String token) async {
    try {
      await _request('DELETE', '/api/v1/student/session', token: token);
    } on StudentIdentityException catch (error) {
      if (error.code != 'unauthorized') await _queueRevocation(token);
    } on Object {
      await _queueRevocation(token);
    }
  }

  Future<void> _queueRevocation(String token) async {
    final pending = await _pendingRevocations();
    if (!pending.contains(token)) pending.add(token);
    await _secureStore.write(
      _pendingRevocationsKey,
      jsonEncode(
          pending.length > 20 ? pending.sublist(pending.length - 20) : pending),
    );
  }

  Future<List<String>> _pendingRevocations() async {
    try {
      final raw = await _secureStore.read(_pendingRevocationsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).whereType<String>().toList();
    } on Object {
      return [];
    }
  }

  Future<void> retryPendingRevocations() async {
    final pending = await _pendingRevocations();
    if (pending.isEmpty) return;
    final remaining = <String>[];
    for (final token in pending) {
      try {
        await _request('DELETE', '/api/v1/student/session', token: token);
      } on StudentIdentityException catch (error) {
        if (error.code != 'unauthorized') remaining.add(token);
      } on Object {
        remaining.add(token);
      }
    }
    await _secureStore.write(_pendingRevocationsKey, jsonEncode(remaining));
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('${ClientBackendConstants.baseUrl}$path');
    final request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final response = await HttpTimeout.request(
      _httpClient.send(request).then(http.Response.fromStream),
      timeout: const Duration(seconds: 15),
      message: '认证超时，请稍后再试',
    );
    if (response.statusCode == 204) return {};
    Map<String, dynamic> decoded;
    try {
      decoded =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on Object {
      throw const StudentIdentityException('ShuYo 服务器返回了无法识别的内容。');
    }
    if (response.statusCode == 401) {
      throw StudentIdentityException(
        decoded['error']?.toString() ?? '身份已失效。',
        code: 'unauthorized',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudentIdentityException(
        decoded['error']?.toString() ?? '身份核验失败。',
        code: decoded['code']?.toString(),
      );
    }
    return decoded;
  }
}
