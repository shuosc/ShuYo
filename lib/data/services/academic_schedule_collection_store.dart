import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/academic_schedule_collection.dart';

/// Each term is an independently written value. Account IDs are part of every
/// key; changing accounts never exposes the previous account's timetable.
class AcademicScheduleCollectionStore {
  AcademicScheduleCollectionStore({
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferencesLoader;
  final changes = ValueNotifier<int>(0);
  Future<void>? _writes;

  String _prefix(String studentId) =>
      'academic.schedule.collection.${Uri.encodeComponent(studentId)}.';
  String _recordKey(String studentId, String termKey) =>
      '${_prefix(studentId)}term.$termKey';

  Future<AcademicScheduleRecord?> load(String studentId, String termKey) async {
    final raw =
        (await _preferencesLoader()).getString(_recordKey(studentId, termKey));
    if (raw == null) return null;
    try {
      final record = AcademicScheduleRecord.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      if (record.studentId != studentId || record.key != termKey) return null;
      for (final schedule in [
        record.schedule,
        record.remoteSchedule,
      ]) {
        if (schedule != null &&
            (schedule.term.studentId != studentId ||
                academicTermKey(
                        schedule.term.yearCode, schedule.term.termCode) !=
                    termKey)) {
          return null;
        }
      }
      return record;
    } on Object {
      return null;
    }
  }

  Future<List<AcademicScheduleRecord>> list(String studentId) async {
    final prefs = await _preferencesLoader();
    final prefix = '${_prefix(studentId)}term.';
    final keys =
        prefs.getKeys().where((key) => key.startsWith(prefix)).toList();
    final records = <AcademicScheduleRecord>[];
    for (final key in keys) {
      final record = await load(studentId, key.substring(prefix.length));
      if (record != null) records.add(record);
    }
    const order = {'3': 0, '12': 1, '16': 2, '32': 3};
    records.sort((a, b) {
      final year = b.yearCode.compareTo(a.yearCode);
      return year != 0
          ? year
          : (order[a.termCode] ?? 99).compareTo(order[b.termCode] ?? 99);
    });
    return records;
  }

  Future<void> update(
    String studentId,
    String termKey,
    Future<AcademicScheduleRecord?> Function(AcademicScheduleRecord?) mutation,
  ) async {
    final previousWrite = _writes;
    final completion = Completer<void>();
    _writes = completion.future;
    try {
      if (previousWrite != null) await previousWrite;
      final record = await mutation(await load(studentId, termKey));
      if (record == null) return;
      if (record.studentId != studentId || record.key != termKey) {
        throw StateError('课表记录与账号或学期不匹配');
      }
      await (await _preferencesLoader()).setString(
          _recordKey(studentId, termKey), jsonEncode(record.toJson()));
      changes.value++;
    } finally {
      completion.complete();
      if (identical(_writes, completion.future)) _writes = null;
    }
  }

  Future<String?> primaryKey(String studentId) async =>
      (await _preferencesLoader()).getString('${_prefix(studentId)}primary');

  Future<void> setPrimaryKey(String studentId, String key) async {
    await (await _preferencesLoader())
        .setString('${_prefix(studentId)}primary', key);
    changes.value++;
  }

  Future<String?> metadata(String studentId, String name) async =>
      (await _preferencesLoader()).getString('${_prefix(studentId)}$name');

  Future<void> setMetadata(String studentId, String name, String value) async {
    await (await _preferencesLoader())
        .setString('${_prefix(studentId)}$name', value);
  }
}
