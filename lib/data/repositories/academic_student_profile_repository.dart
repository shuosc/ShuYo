import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/academic_student_profile.dart';
import '../services/academic_account_store.dart';
import '../services/academic_schedule_api_client.dart';
import '../services/academic_student_profile_api_client.dart';

class AcademicStudentProfileRepository {
  AcademicStudentProfileRepository({
    AcademicStudentProfileApiClient? apiClient,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _apiClient = apiClient,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  static const cacheKey = 'academic.student_profile.cache';

  AcademicStudentProfileApiClient? _apiClient;
  AcademicStudentProfileApiClient get _client =>
      _apiClient ??= AcademicStudentProfileApiClient();
  final Future<SharedPreferences> Function() _preferencesLoader;

  Future<AcademicStudentProfile?> loadCachedProfile() async {
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final profile = AcademicStudentProfile.fromJson(decoded);
    final account = await AcademicAccountStore(
      preferencesLoader: _preferencesLoader,
    ).loadDataStudentId();
    return account != null && profile.studentId == account ? profile : null;
  }

  Future<AcademicStudentProfile> refreshProfile() async {
    final accounts =
        AcademicAccountStore(preferencesLoader: _preferencesLoader);
    final studentId = await accounts.loadStudentId();
    if (studentId == null) {
      throw const AcademicAuthException('请先登录上大校园账户');
    }
    final profile = await _client.fetchProfile(expectedStudentId: studentId);
    if (await accounts.loadStudentId() != studentId) {
      throw const AcademicAuthException('校园账户已更换，请重新同步');
    }
    final prefs = await _preferencesLoader();
    await prefs.setString(cacheKey, jsonEncode(profile.toJson()));
    return profile;
  }
}
