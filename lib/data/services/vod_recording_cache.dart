import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/course_recording.dart';
import 'secure_app_store.dart';

/// Persistent recording links and the metadata needed to reach them during an
/// API outage. Credentials and live streams are deliberately excluded.
class VodRecordingCache {
  VodRecordingCache({
    SecureAppStore? store,
    this.backgroundWriteDelay = const Duration(seconds: 2),
  }) : _store = store ?? SecureAppStore();

  static const storageKey = 'vod.recording.cache.v1';
  static Future<void> _writes = Future<void>.value();
  static final _pendingBatches = <_CacheWriteBatch>{};
  final SecureAppStore _store;
  @visibleForTesting
  final Duration backgroundWriteDelay;
  _CacheWriteBatch? _batch;

  // Flush waiting batches before foreground reads or writes. The batches are
  // registered in the global write chain as soon as they are created, so a
  // second cache instance cannot bypass or race the first one's pending data.
  static void _flushPendingBatches() {
    for (final batch in _pendingBatches.toList(growable: false)) {
      batch.start();
    }
  }

  String _scope(String account, bool vpn) =>
      '${Uri.encodeComponent(account)}:${vpn ? 'webvpn' : 'direct'}';

  Future<List<Map<String, dynamic>>> savedLessons(
      String account, bool vpn, int? termId) async {
    try {
      _flushPendingBatches();
      await _writes;
      final raw = await _store.read(storageKey);
      if (raw == null) return const [];
      final request = (raw: raw, scope: _scope(account, vpn), termId: termId);
      return raw.length >= 16384
          ? await compute(_readSavedLessons, request,
              debugLabel: 'vodCacheLessonsRead')
          : _readSavedLessons(request);
    } on Object {
      return const [];
    }
  }

  /// Checks for an offline fallback without transferring every saved lesson
  /// and signed media URL from the worker back into the UI isolate.
  Future<bool> hasSavedLessons(String account, bool vpn) async {
    try {
      _flushPendingBatches();
      await _writes;
      final raw = await _store.read(storageKey);
      if (raw == null) return false;
      final request = (raw: raw, scope: _scope(account, vpn));
      return raw.length >= 16384
          ? await compute(_hasSavedLessons, request,
              debugLabel: 'vodCacheAvailabilityRead')
          : _hasSavedLessons(request);
    } on Object {
      return false;
    }
  }

  Future<Object?> load(String account, bool vpn, String key) async {
    try {
      _flushPendingBatches();
      await _writes;
      final raw = await _store.read(storageKey);
      if (raw == null) return null;
      final request = (raw: raw, scope: _scope(account, vpn), key: key);
      return raw.length >= 16384
          ? await compute(_readCacheValue, request,
              debugLabel: 'vodCacheValueRead')
          : _readCacheValue(request);
    } on Object {
      return null;
    }
  }

  Future<void> save(String account, bool vpn, String key, Object value,
      {FutureOr<bool> Function()? canWrite,
      bool Function()? canCommit,
      int? version,
      void Function()? onCommitted,
      bool background = false}) {
    if (!background) _flushPendingBatches();
    var batch = _batch;
    if (batch == null) {
      batch = _CacheWriteBatch();
      _batch = batch;
      final scheduled = batch;
      _pendingBatches.add(scheduled);
      scheduled.timer = Timer(
          background ? backgroundWriteDelay : const Duration(milliseconds: 40),
          scheduled.start);
      final operation = _writes.then((_) async {
        // The first request bounds the wait; further writes do not postpone it.
        await scheduled.ready.future;
        _pendingBatches.remove(scheduled);
        if (identical(_batch, scheduled)) _batch = null;
        await _flush(scheduled.entries);
      });
      // A storage failure must neither fail playback nor poison later writes.
      _writes =
          operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      scheduled.done = _writes;
    }
    batch.entries.add(_CacheWrite(_scope(account, vpn), key, value, canWrite,
        canCommit, version, onCommitted));
    return batch.done;
  }

  Future<void> _flush(List<_CacheWrite> entries) async {
    // Send the persisted string straight to the worker. Returning its decoded
    // tree here and sending it back for encoding would copy the entire cache
    // twice, even when this batch only adds one course's lesson metadata.
    final original = await _store.read(storageKey);
    var pending = entries;
    while (pending.isNotEmpty) {
      final accepted = <_CacheWrite>[];
      for (final entry in pending) {
        if (entry.canWrite != null && !await entry.canWrite!()) continue;
        // Keep equal-value writes as candidates: an earlier write of the same
        // key may become invalid while this batch is being encoded.
        accepted.add(entry);
      }
      if (accepted.isEmpty) return;
      // One course entry can contain hundreds of lessons, so entry count is
      // not a useful size threshold. Decode, merge, compare and encode the
      // bounded batch together outside the UI isolate for every cache size.
      final encoded = await compute(
        _mergeCacheJson,
        (
          raw: original,
          entries: [
            for (final entry in accepted)
              (
                scope: entry.scope,
                key: entry.key,
                value: entry.value,
                version: entry.version,
              ),
          ],
        ),
        debugLabel: 'vodCacheWrite',
      );
      // Encoding may yield to an isolate; an account can change while it is
      // running. Rebuild without invalid entries before touching the store.
      final stillValid = <_CacheWrite>[];
      for (final entry in accepted) {
        if (entry.canWrite == null || await entry.canWrite!()) {
          stillValid.add(entry);
        }
      }
      // No asynchronous gap is allowed between the final validity check and
      // starting the write. Another entry's account lookup may have yielded
      // after an earlier entry was checked.
      final ready = stillValid
          .where((entry) => entry.canCommit == null || entry.canCommit!())
          .toList();
      if (ready.length != accepted.length) {
        pending = ready;
        continue;
      }
      if (encoded != null) await _store.write(storageKey, encoded);
      for (final entry in ready) {
        entry.onCommitted?.call();
      }
      return;
    }
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

Map? _readCacheScope(String raw, String scope) {
  final all = jsonDecode(raw);
  if (all is! Map) return null;
  final selected = all[scope];
  return selected is Map ? selected : null;
}

Object? _readCacheValue(({String raw, String scope, String key}) request) =>
    _readCacheScope(request.raw, request.scope)?[request.key];

bool _hasSavedLessons(({String raw, String scope}) request) =>
    _readCacheScope(request.raw, request.scope)?.entries.any((entry) =>
        entry.key.toString().startsWith('playback:') &&
        entry.value is Map<String, dynamic>) ??
    false;

List<Map<String, dynamic>> _readSavedLessons(
    ({String raw, String scope, int? termId}) request) {
  final scope = _readCacheScope(request.raw, request.scope);
  if (scope == null) return const [];
  return [
    for (final entry in scope.entries)
      if (entry.key.toString().startsWith('playback:') &&
          entry.value is Map<String, dynamic> &&
          (request.termId == null ||
              (entry.value['course'] as Map?)?['acteId'] == request.termId))
        entry.value as Map<String, dynamic>,
  ];
}

typedef _CacheJsonEntry = ({
  String scope,
  String key,
  Object value,
  int? version,
});

String? _mergeCacheJson(
    ({
      String? raw,
      List<_CacheJsonEntry> entries,
    }) batch) {
  Object? decoded;
  try {
    decoded = batch.raw == null ? null : jsonDecode(batch.raw!);
  } on FormatException {
    // A malformed previous cache should not prevent a fresh API response from
    // repairing it, matching the foreground read's empty-cache fallback.
  }
  final all = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  final versions = <String, int>{};
  var changed = false;
  for (final entry in batch.entries) {
    final identity = '${entry.scope}\u0000${entry.key}';
    final previousVersion = versions[identity];
    if (entry.version != null &&
        previousVersion != null &&
        previousVersion > entry.version!) {
      continue;
    }
    if (entry.version != null) versions[identity] = entry.version!;
    final previous = all[entry.scope];
    final scope =
        previous is Map<String, dynamic> ? previous : <String, dynamic>{};
    all[entry.scope] = scope;
    if (jsonEncode(scope[entry.key]) == jsonEncode(entry.value)) continue;
    scope[entry.key] = entry.value;
    changed = true;
  }
  return changed ? jsonEncode(all) : null;
}

class _CacheWriteBatch {
  final entries = <_CacheWrite>[];
  final ready = Completer<void>();
  Timer? timer;
  late Future<void> done;

  void start() {
    timer?.cancel();
    if (!ready.isCompleted) ready.complete();
  }
}

class _CacheWrite {
  _CacheWrite(this.scope, this.key, this.value, this.canWrite, this.canCommit,
      this.version, this.onCommitted);

  final String scope;
  final String key;
  final Object value;
  final FutureOr<bool> Function()? canWrite;
  final bool Function()? canCommit;
  final int? version;
  final void Function()? onCommitted;
}
