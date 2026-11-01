import 'dart:convert';

import '../models/course_recording.dart';
import 'secure_app_store.dart';

/// Persistent recording links and the metadata needed to reach them during an
/// API outage. Credentials and live streams are deliberately excluded.
class VodRecordingCache {
  VodRecordingCache({SecureAppStore? store})
      : _store = store ?? SecureAppStore();

  static const storageKey = 'vod.recording.cache.v1';
  static Future<void> _writes = Future<void>.value();
  final SecureAppStore _store;

  String _scope(String account, bool vpn) =>
      '${Uri.encodeComponent(account)}:${vpn ? 'webvpn' : 'direct'}';

  Future<Map<String, dynamic>> _read() async {
    final raw = await _store.read(storageKey);
    if (raw == null) return {};
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return {};
    }
    return value is Map<String, dynamic> ? value : {};
  }

  Future<List<Map<String, dynamic>>> savedLessons(
      String account, bool vpn, int? termId) async {
    try {
      await _writes;
      final scope = (await _read())[_scope(account, vpn)];
      if (scope is! Map) return const [];
      return [
        for (final entry in scope.entries)
          if (entry.key.toString().startsWith('playback:') &&
              entry.value is Map<String, dynamic> &&
              (termId == null ||
                  (entry.value['course'] as Map?)?['acteId'] == termId))
            entry.value as Map<String, dynamic>,
      ];
    } on Object {
      return const [];
    }
  }

  Future<Object?> load(String account, bool vpn, String key) async {
    try {
      await _writes;
      final scope = (await _read())[_scope(account, vpn)];
      return scope is Map ? scope[key] : null;
    } on Object {
      return null;
    }
  }

  Future<void> save(String account, bool vpn, String key, Object value) {
    final operation = _writes.then((_) async {
      final all = await _read();
      final name = _scope(account, vpn);
      final previous = all[name];
      final scope = previous is Map
          ? Map<String, dynamic>.from(previous)
          : <String, dynamic>{};
      if (jsonEncode(scope[key]) == jsonEncode(value)) return;
      scope[key] = value;
      all[name] = scope;
      await _store.write(storageKey, jsonEncode(all));
    });
    // A storage failure must neither fail playback nor poison later writes.
    _writes =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return _writes;
  }

  static Map<String, dynamic> termJson(VodTerm term) => {
        'id': term.id,
        'acyeCode': term.academicYear,
        'acteTerm': term.termNumber,
        'currentTerm': term.isCurrent,
        'acteBeginDate': term.startDate?.toIso8601String(),
        'acteEndDate': term.endDate?.toIso8601String(),
      };

  static Map<String, dynamic> courseJson(VodCourse course) => {
        'teclId': course.teachingClassId,
        'acteId': course.termId,
        'subjName': course.name,
        'teclName': course.teachingClassName,
        'subjCode': course.code,
        'teacNames': course.teacherNames,
        'courTimes': course.lessonCount,
      };

  static Map<String, dynamic> lessonJson(VodLesson lesson) => {
        'id': lesson.id,
        'teclId': lesson.teachingClassId,
        'subjName': lesson.name,
        'courBeginTime': lesson.beginTime?.toIso8601String(),
        'courEndTime': lesson.endTime?.toIso8601String(),
        'weekNumber': lesson.weekNumber,
        'sectionLabel': lesson.sectionLabel,
        'clroName': lesson.classroom,
        'playable': lesson.isPlayable,
        'generating': lesson.isGenerating,
        'listed': lesson.isListed,
      };

  static VodLesson lessonFromJson(Map<String, dynamic> json) => VodLesson(
        id: json['id'] as int,
        teachingClassId: json['teclId'] as int,
        name: json['subjName'] as String,
        isPlayable: json['playable'] == true,
        isGenerating: json['generating'] == true,
        isListed: json['listed'] == true,
        beginTime: vodDateValue(json['courBeginTime']),
        endTime: vodDateValue(json['courEndTime']),
        weekNumber: json['weekNumber'] as int,
        sectionLabel: json['sectionLabel'] as String,
        classroom: json['clroName'] as String,
      );

  static Map<String, dynamic> playbackJson(VodPlayback playback) => {
        'lessonId': playback.lessonId,
        'teachingClassId': playback.teachingClassId,
        'title': playback.title,
        'description': playback.description,
        'voiceChannel': playback.voiceChannel,
        'views': [
          for (final view in playback.views)
            {
              'viewNumber': view.viewNumber,
              'url': view.url.toString(),
              'label': view.displayLabel,
            },
        ],
      };
}
