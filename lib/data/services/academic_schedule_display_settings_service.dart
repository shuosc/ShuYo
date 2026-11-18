import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/academic_schedule.dart';
import '../models/academic_schedule_collection.dart';

class AcademicScheduleDisplaySettings {
  const AcademicScheduleDisplaySettings({
    required this.colorful,
    required this.showTeacher,
    this.showCredit = false,
    this.showNote = false,
    this.showNonCurrentWeekCourses = true,
  });

  final bool colorful;
  final bool showTeacher;
  final bool showCredit;
  final bool showNote;
  final bool showNonCurrentWeekCourses;

  AcademicScheduleDisplaySettings copyWith({
    bool? colorful,
    bool? showTeacher,
    bool? showCredit,
    bool? showNote,
    bool? showNonCurrentWeekCourses,
  }) {
    return AcademicScheduleDisplaySettings(
      colorful: colorful ?? this.colorful,
      showTeacher: showTeacher ?? this.showTeacher,
      showCredit: showCredit ?? this.showCredit,
      showNote: showNote ?? this.showNote,
      showNonCurrentWeekCourses:
          showNonCurrentWeekCourses ?? this.showNonCurrentWeekCourses,
    );
  }
}

class AcademicScheduleDisplayState {
  const AcademicScheduleDisplayState({
    required this.settings,
    required this.courseColorValues,
  });

  final AcademicScheduleDisplaySettings settings;
  final Map<String, int> courseColorValues;
}

class AcademicScheduleDisplaySettingsService {
  AcademicScheduleDisplaySettingsService({
    Future<SharedPreferences> Function()? preferencesLoader,
    this.scope,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final String? scope;
  String _key(String key) => scope == null ? key : '$key.$scope';

  static const _colorfulKey = 'academic.schedule.display.colorful';
  static const _showTeacherKey = 'academic.schedule.display.showTeacher';
  static const _showCreditKey = 'academic.schedule.display.showCredit';
  static const _showNoteKey = 'academic.schedule.display.showNote';
  static const _showNonCurrentWeekCoursesKey =
      'academic.schedule.display.showNonCurrentWeekCourses';
  static const _courseColorsKey = 'academic.schedule.display.courseColors';

  final Future<SharedPreferences> Function() _preferencesLoader;

  String _termCourseColorsKey(AcademicTerm term) => _key(
        '$_courseColorsKey.term.${Uri.encodeComponent(term.studentId)}.'
        '${academicTermKey(term.yearCode, term.termCode)}',
      );

  Future<AcademicScheduleDisplayState> loadState({AcademicTerm? term}) async {
    final prefs = await _preferencesLoader();
    return AcademicScheduleDisplayState(
      settings: _settingsFromPreferences(prefs),
      courseColorValues: _courseColorsFromPreferences(prefs, term),
    );
  }

  Future<AcademicScheduleDisplaySettings> loadSettings() async {
    final prefs = await _preferencesLoader();
    return _settingsFromPreferences(prefs);
  }

  AcademicScheduleDisplaySettings _settingsFromPreferences(
    SharedPreferences prefs,
  ) {
    return AcademicScheduleDisplaySettings(
      colorful: prefs.getBool(_key(_colorfulKey)) ?? true,
      showTeacher: prefs.getBool(_key(_showTeacherKey)) ?? true,
      showCredit: prefs.getBool(_key(_showCreditKey)) ?? false,
      showNote: prefs.getBool(_key(_showNoteKey)) ?? false,
      showNonCurrentWeekCourses:
          prefs.getBool(_key(_showNonCurrentWeekCoursesKey)) ?? true,
    );
  }

  Future<AcademicScheduleDisplaySettings> saveSettings(
    AcademicScheduleDisplaySettings settings,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.setBool(_key(_colorfulKey), settings.colorful);
    await prefs.setBool(_key(_showTeacherKey), settings.showTeacher);
    await prefs.setBool(_key(_showCreditKey), settings.showCredit);
    await prefs.setBool(_key(_showNoteKey), settings.showNote);
    await prefs.setBool(
      _key(_showNonCurrentWeekCoursesKey),
      settings.showNonCurrentWeekCourses,
    );
    return settings;
  }

  Future<Map<String, int>> loadCourseColors(AcademicTerm term) async {
    final prefs = await _preferencesLoader();
    return _courseColorsFromPreferences(prefs, term);
  }

  Map<String, int> _courseColorsFromPreferences(
    SharedPreferences prefs,
    AcademicTerm? term,
  ) {
    // Legacy colors are a read-only starting point for untouched terms.
    final raw =
        (term == null ? null : prefs.getString(_termCourseColorsKey(term))) ??
            prefs.getString(_key(_courseColorsKey));
    if (raw == null || raw.isEmpty) {
      return <String, int>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, int>{};
      }
      return <String, int>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is int)
            entry.key as String: entry.value as int,
      };
    } on Object {
      return <String, int>{};
    }
  }

  Future<void> saveCourseColor(
    AcademicTerm term,
    String key,
    int colorValue,
  ) async {
    final prefs = await _preferencesLoader();
    final colors = _courseColorsFromPreferences(prefs, term)
      ..[key] = colorValue;
    await prefs.setString(_termCourseColorsKey(term), jsonEncode(colors));
  }

  Future<void> saveCourseColors(
    AcademicTerm term,
    Map<String, int> colors,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.setString(_termCourseColorsKey(term), jsonEncode(colors));
  }
}
