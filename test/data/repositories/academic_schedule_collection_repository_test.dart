import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/models/academic_schedule_collection.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';

const current = AcademicTermQuery(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋');
const history = AcademicTermQuery(
    yearCode: '2025',
    termCode: '3',
    academicYearName: '2025-2026',
    termName: '秋');
const older = AcademicTermQuery(
    yearCode: '2024',
    termCode: '16',
    academicYearName: '2024-2025',
    termName: '春');

AcademicSchedule scheduleFor(
  AcademicTermQuery query, {
  String owner = 'A',
  String admission = '2025',
  bool empty = false,
  bool untimedOnly = false,
  String courseName = '测试课程',
}) =>
    AcademicSchedule(
      term: AcademicTerm(
          yearCode: query.yearCode,
          termCode: query.termCode,
          academicYearName: query.academicYearName,
          termName: query.termName,
          studentName: '测试同学',
          studentId: owner,
          className: '测试班',
          admissionYearCode: admission),
      sessions: empty || untimedOnly
          ? []
          : [
              CourseSession(
                id: 'course',
                courseName: courseName,
                courseCode: 'TEST001',
                teacherName: '',
                campus: '',
                location: '',
                weekday: 1,
                startSection: 1,
                endSection: 2,
                sections: [1, 2],
                weeks: [1, 2],
                weekText: '1-2周',
                credit: '1',
                note: '',
              )
            ],
      untimedCourses: untimedOnly
          ? [
              const UntimedCourse(
                id: 'untimed',
                courseName: '实践课程',
                teacherName: '',
                campus: '',
                weeks: [1],
                weekText: '1周',
                summary: '',
                credit: '1',
              )
            ]
          : [],
      fetchedAt: DateTime(2026, 11, 8, 12),
    );

class _Api extends AcademicScheduleApiClient {
  _Api({List<AcademicTermQuery>? terms})
      : catalog = AcademicTermCatalog(
            currentTerm: current, terms: terms ?? [current, history, older]);

  AcademicTermCatalog catalog;
  int catalogs = 0;
  int active = 0;
  int maxActive = 0;
  final calls = <String>[];
  final responses = <String, AcademicSchedule>{};
  final errors = <String, Object>{};
  final gates = <String, Completer<void>>{};
  String owner = 'A';

  @override
  Future<AcademicTermCatalog> fetchTermCatalog() async {
    catalogs++;
    return catalog;
  }

  @override
  Future<AcademicSchedule> fetchCurrentSchedule() =>
      fetchScheduleForTerm(current);

  @override
  Future<AcademicSchedule> fetchScheduleForTerm(AcademicTermQuery query) async {
    calls.add(query.key);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await gates[query.key]?.future;
      await Future<void>.value();
      final error = errors[query.key];
      if (error != null) throw error;
      return responses[query.key] ??
          scheduleFor(query, owner: owner, empty: query.key != current.key);
    } finally {
      active--;
    }
  }
}

void main() {
  late _Api api;
  late AcademicScheduleRepository repo;
  late AcademicAccountStore account;
  final now = DateTime(2026, 11, 8, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    account = AcademicAccountStore();
    await account.saveStudentId('A');
    api = _Api();
    repo = AcademicScheduleRepository(apiClient: api);
  });

  test('legacy cache migrates once with its own calendar and edited protection',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'academic.schedule.cache', jsonEncode(scheduleFor(current).toJson()));
    await prefs.setInt('academic.schedule.anchorWeek', 3);
    await prefs.setString('academic.schedule.anchorMonday', '2026-09-14');
    await repo.loadCachedSchedule();
    final records = await repo.loadSavedSchedules();
    expect(records, hasLength(1));
    expect(records.single.locallyEdited, isTrue);
    expect(records.single.firstWeekStart, DateTime(2026, 8, 31));
    expect(await repo.loadPrimaryTermKey(), current.key);
    expect((await repo.loadWeekState()).currentWeek, 3);
    await repo.loadCachedSchedule();
    expect(await repo.loadSavedSchedules(), hasLength(1));
  });

  test('NJDM_ID narrows automatic discovery with a preceding-year buffer',
      () async {
    api.catalog = AcademicScheduleApiClient.parseTermCatalog(
        File('test/fixtures/academic_schedule/term_index.html')
            .readAsStringSync());
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    expect(api.calls.toSet().length, 13);
    expect(
        api.calls.where((k) => int.parse(k.split(':').first) < 2024), isEmpty);
    expect(
        api.calls.where((k) => int.parse(k.split(':').first) > 2027), isEmpty);
    expect(api.calls, contains('2024:12'));
    expect(api.calls, isNot(contains('2025:12')));
    expect(api.calls.where((key) => key == current.key), hasLength(1));
    expect(api.maxActive, 1);
    expect(repo.discoveryState.value.failed, 0);
    expect(repo.discoveryState.value.total, 13);
  });

  test('complete check can discover terms before admission and far in future',
      () async {
    const past = AcademicTermQuery(yearCode: '2020', termCode: '3');
    const future = AcademicTermQuery(yearCode: '2032', termCode: '3');
    api.catalog = const AcademicTermCatalog(
        currentTerm: current, terms: [current, history, past, future]);
    api.responses[past.key] = scheduleFor(past);
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    expect(api.calls, isNot(contains(past.key)));
    await repo.discoverSchedules(force: true, fullScan: true, now: now);
    expect(api.calls, containsAll([past.key, future.key]));
    expect((await repo.loadTermRecord(past.key))!.hasSavedSchedule, isTrue);
    expect(await repo.loadPrimaryTermKey(), current.key);
  });

  test('an untimed-only timetable is saved and does not change primary',
      () async {
    api.responses[history.key] = scheduleFor(history, untimedOnly: true);
    await repo.refreshSchedule();
    await repo.setCurrentWeek(3, now: DateTime(2026, 9, 14));
    await repo.discoverSchedules(now: now);
    final record = (await repo.loadTermRecord(history.key))!;
    expect(record.hasSavedSchedule, isTrue);
    expect(record.courseCount, 1);
    expect(record.firstWeekStart, isNull);
    expect((await repo.loadCachedSchedule())!.term.yearCode, '2026');
    expect((await repo.loadWeekState()).currentWeek, 3);
    expect(await repo.loadPrimaryTermKey(), current.key);
  });

  test(
      'a default empty term records admission year without creating a timetable',
      () async {
    api.responses[current.key] = scheduleFor(current, empty: true);
    api.responses[history.key] = scheduleFor(history);
    await expectLater(
        repo.refreshSchedule(), throwsA(isA<AcademicNoScheduleException>()));
    expect(await repo.loadCachedSchedule(), isNull);
    expect((await repo.loadTermRecord(current.key))!.hasSavedSchedule, isFalse);
    await repo.discoverSchedules(now: now);
    expect((await repo.loadTermRecord(history.key))!.hasSavedSchedule, isTrue);
    expect(await repo.loadPrimaryTermKey(), isNull);
    expect(await repo.loadCachedSchedule(), isNull);
  });

  test('startup does not repeat a completed discovery or download saved terms',
      () async {
    api.responses[history.key] = scheduleFor(history);
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    final calls = List<String>.of(api.calls);
    final catalogs = api.catalogs;
    await repo.discoverSchedules(now: now.add(const Duration(hours: 1)));
    expect(api.calls, calls);
    expect(api.catalogs, catalogs);
    await repo.discoverSchedules(force: true, now: now);
    expect(api.calls.where((key) => key == history.key), hasLength(1));
    expect(api.calls.where((key) => key == current.key), hasLength(1));
  });

  test('recent and old empty terms have different negative-cache lifetimes',
      () async {
    const recent = AcademicTermQuery(yearCode: '2026', termCode: '16');
    api.catalog = const AcademicTermCatalog(
        currentTerm: current, terms: [current, recent, older]);
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    await repo.discoverSchedules(now: now.add(const Duration(days: 2)));
    expect(api.calls.where((key) => key == recent.key), hasLength(2));
    expect(api.calls.where((key) => key == older.key), hasLength(1));
  });

  test('a failed term is not an empty term and retries independently',
      () async {
    api.errors[history.key] = const AcademicApiException('offline');
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    expect((await repo.loadTermRecord(history.key))!.availability,
        ScheduleAvailability.failed);
    expect((await repo.loadTermRecord(older.key))!.availability,
        ScheduleAvailability.empty);
    expect(repo.discoveryState.value.failed, 1);
    final currentCalls = api.calls.where((k) => k == current.key).length;
    api.errors.remove(history.key);
    api.responses[history.key] = scheduleFor(history);
    await repo.discoverSchedules(
        force: true, retryFailuresOnly: true, now: now);
    expect((await repo.loadTermRecord(history.key))!.hasSavedSchedule, isTrue);
    expect(api.calls.where((k) => k == current.key), hasLength(currentCalls));
    expect(api.calls.where((k) => k == older.key), hasLength(1));
  });

  test(
      'authentication failure pauses the queue without recording an empty term',
      () async {
    api.errors[history.key] = const AcademicAuthException('expired', 901);
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    expect(repo.discoveryState.value.requiresLogin, isTrue);
    expect(await repo.loadTermRecord(history.key), isNull);
    expect(api.calls, isNot(contains(older.key)));
    expect(await repo.loadCachedSchedule(), isNotNull);
  });

  test('account switch during a request discards its response', () async {
    await repo.refreshSchedule();
    final gate = Completer<void>();
    api.gates[history.key] = gate;
    final task = repo.discoverSchedules(now: now);
    while (!api.calls.contains(history.key)) {
      await Future<void>.delayed(Duration.zero);
    }
    await account.saveStudentId('B');
    gate.complete();
    await task;
    expect(await repo.loadSavedSchedules(), isEmpty);
    expect(await repo.loadCachedSchedule(), isNull);
    await account.saveStudentId('A');
    expect(await repo.loadTermRecord(history.key), isNull);
  });

  test('explicit pause discards an in-flight response and can resume',
      () async {
    await repo.refreshSchedule();
    final gate = Completer<void>();
    api.gates[history.key] = gate;
    final task = repo.discoverSchedules(now: now);
    while (!api.calls.contains(history.key)) {
      await Future<void>.delayed(Duration.zero);
    }
    repo.pauseDiscovery();
    gate.complete();
    await task;
    expect(await repo.loadTermRecord(history.key), isNull);
    expect(repo.discoveryState.value.running, isFalse);
    api.gates.clear();
    await repo.discoverSchedules(force: true, now: now);
    expect((await repo.loadTermRecord(history.key))!.availability,
        ScheduleAvailability.empty);
  });

  test('duplicate discovery calls share one queue', () async {
    await repo.refreshSchedule();
    final gate = Completer<void>();
    api.gates[history.key] = gate;
    final first = repo.discoverSchedules(force: true, now: now);
    final second = repo.discoverSchedules(force: true, now: now);
    expect(identical(first, second), isTrue);
    gate.complete();
    await Future.wait([first, second]);
    expect(api.calls.where((key) => key == history.key), hasLength(1));
  });

  test('history edits and dates stay separate from primary cache and calendar',
      () async {
    api.responses[history.key] = scheduleFor(history);
    await repo.refreshSchedule();
    await repo.setCurrentWeek(3, now: DateTime(2026, 9, 14));
    await repo.discoverSchedules(now: now);
    final edited = scheduleFor(history, courseName: '本地历史课程');
    await repo.saveWorkingSchedule(edited);
    await repo.setTermFirstWeekStart(history.key, DateTime(2025, 9, 3));
    expect(
        (await repo.loadCachedSchedule())!.sessions.single.courseName, '测试课程');
    expect((await repo.loadWeekState()).currentWeek, 3);
    expect((await repo.loadTermRecord(history.key))!.locallyEdited, isTrue);
    expect((await repo.loadTermWeekState(history.key)).firstWeekStart,
        DateTime(2025, 9, 1));
    expect((await repo.loadWeekState()).firstWeekStart, DateTime(2026, 8, 31));
  });

  test(
      'changing primary moves calendar and only an explicit date enables reminders',
      () async {
    api.responses[history.key] = scheduleFor(history);
    await repo.refreshSchedule();
    expect(await repo.primaryCalendarConfigured(), isFalse);
    await repo.setFirstWeekStart(DateTime(2026, 8, 31));
    expect(await repo.primaryCalendarConfigured(), isTrue);
    await repo.discoverSchedules(now: now);
    await repo.setPrimaryTerm(history.key);
    expect((await repo.loadCachedSchedule())!.term.yearCode, '2025');
    expect(await repo.primaryCalendarConfigured(), isFalse);
    await repo.setTermFirstWeekStart(history.key, DateTime(2025, 9, 1));
    expect(await repo.primaryCalendarConfigured(), isTrue);
    await repo.setPrimaryTerm(current.key);
    expect((await repo.loadWeekState()).firstWeekStart, DateTime(2026, 8, 31));
  });

  test('retired hidden and backup fields do not change saved schedules',
      () async {
    api.responses[history.key] = scheduleFor(history);
    await repo.refreshSchedule();
    await repo.discoverSchedules(now: now);
    await repo.setTermFirstWeekStart(history.key, DateTime(2025, 9, 1));
    final prefs = await SharedPreferences.getInstance();
    final key = 'academic.schedule.collection.A.term.${history.key}';
    final legacy = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    legacy['hidden'] = true;
    legacy['backup'] = scheduleFor(history, courseName: '旧备份').toJson();
    await prefs.setString(key, jsonEncode(legacy));

    final record = (await repo.loadTermRecord(history.key))!;
    expect(record.schedule!.sessions.single.courseName, '测试课程');
    expect(record.firstWeekStart, DateTime(2025, 9, 1));
    expect(record.toJson().containsKey('hidden'), isFalse);
    expect(record.toJson().containsKey('backup'), isFalse);
    await repo.setPrimaryTerm(history.key);
    expect((await repo.loadCachedSchedule())!.term.yearCode, '2025');
    expect((await repo.loadWeekState()).firstWeekStart, DateTime(2025, 9, 1));
  });

  test('explicit update protects edits until replacement is confirmed',
      () async {
    await repo.refreshSchedule();
    await repo.saveWorkingSchedule(scheduleFor(current, courseName: '本地课程'));
    api.responses[current.key] = scheduleFor(current, courseName: '教务新课程');
    await expectLater(
        repo.refreshTerm(current.key), throwsA(isA<AcademicApiException>()));
    expect(
        (await repo.loadTermRecord(current.key))!
            .schedule!
            .sessions
            .single
            .courseName,
        '本地课程');
    await repo.refreshTerm(current.key, replaceEdited: true);
    final record = (await repo.loadTermRecord(current.key))!;
    expect(record.schedule!.sessions.single.courseName, '教务新课程');
    expect(record.toJson().containsKey('backup'), isFalse);
    expect(record.locallyEdited, isFalse);
  });

  test('empty update keeps the saved timetable until explicitly accepted',
      () async {
    await repo.refreshSchedule();
    api.responses[current.key] = scheduleFor(current, empty: true);
    await expectLater(repo.refreshTerm(current.key),
        throwsA(isA<AcademicNoScheduleException>()));
    var record = (await repo.loadTermRecord(current.key))!;
    expect(record.schedule!.sessions, isNotEmpty);
    expect(record.availability, ScheduleAvailability.empty);
    final calls = api.calls.length;
    await repo.acceptEmptyTerm(current.key);
    record = (await repo.loadTermRecord(current.key))!;
    expect(record.schedule!.sessions, isEmpty);
    expect(record.toJson().containsKey('backup'), isFalse);
    expect(api.calls, hasLength(calls));
  });

  test(
      'account-isolated primary and timetable collections survive switching back',
      () async {
    await repo.refreshSchedule();
    await repo.setFirstWeekStart(DateTime(2026, 8, 31));
    await account.saveStudentId('B');
    expect(await repo.loadSavedSchedules(), isEmpty);
    api.owner = 'B';
    await repo.refreshSchedule();
    expect((await repo.loadCachedSchedule())!.term.studentId, 'B');
    await repo.setFirstWeekStart(DateTime(2026, 9, 7));
    await account.saveStudentId('A');
    expect((await repo.loadCachedSchedule())!.term.studentId, 'A');
    expect((await repo.loadWeekState()).firstWeekStart, DateTime(2026, 8, 31));
    await account.saveStudentId('B');
    expect((await repo.loadCachedSchedule())!.term.studentId, 'B');
    expect((await repo.loadWeekState()).firstWeekStart, DateTime(2026, 9, 7));
  });

  test('resuming before a paused request finishes starts one replacement queue',
      () async {
    await repo.refreshSchedule();
    final gate = Completer<void>();
    api.gates[history.key] = gate;
    final first = repo.discoverSchedules(now: now);
    while (!api.calls.contains(history.key)) {
      await Future<void>.delayed(Duration.zero);
    }
    repo.pauseDiscovery();
    final resumed = repo.discoverSchedules(now: now);
    gate.complete();
    await Future.wait([first, resumed]);
    expect((await repo.loadTermRecord(history.key))!.availability,
        ScheduleAvailability.empty);
    expect(api.calls.where((key) => key == history.key), hasLength(2));
    expect(api.maxActive, 1);
  });

  test('a missing default response does not prevent discovering history',
      () async {
    api.errors[current.key] = const AcademicApiException('default unavailable');
    api.responses[history.key] = scheduleFor(history);
    await repo.discoverSchedules(now: now);
    expect((await repo.loadTermRecord(current.key))!.availability,
        ScheduleAvailability.failed);
    expect((await repo.loadTermRecord(history.key))!.hasSavedSchedule, isTrue);
    expect(api.calls.where((key) => key == current.key), hasLength(1));
  });

  test(
      'consecutive transport failures stop the queue rather than hammering terms',
      () async {
    const next = AcademicTermQuery(yearCode: '2025', termCode: '16');
    const last = AcademicTermQuery(yearCode: '2025', termCode: '32');
    api.catalog = const AcademicTermCatalog(
        currentTerm: current, terms: [current, history, older, next, last]);
    await repo.refreshSchedule();
    for (final query in [history, older, next, last]) {
      api.errors[query.key] = const AcademicApiException('offline');
    }
    await repo.discoverSchedules(now: now);
    expect(api.calls, isNot(contains(last.key)));
    expect(repo.discoveryState.value.failed, 3);
    expect(repo.discoveryState.value.running, isFalse);
    expect(await repo.loadTermRecord(last.key), isNull);
  });

  test('edits made while an explicit refresh is in flight are preserved',
      () async {
    await repo.refreshSchedule();
    final gate = Completer<void>();
    api.gates[current.key] = gate;
    final pending = repo.refreshTerm(current.key, replaceEdited: true);
    final expected = expectLater(pending, throwsA(isA<AcademicApiException>()));
    while (api.calls.where((key) => key == current.key).length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    await repo.saveWorkingSchedule(scheduleFor(current, courseName: '同步期间的修改'));
    gate.complete();
    await expected;
    final record = (await repo.loadTermRecord(current.key))!;
    expect(record.schedule!.sessions.single.courseName, '同步期间的修改');
    expect(record.locallyEdited, isTrue);
  });

  test('a response belonging to another student is never persisted', () async {
    await repo.refreshSchedule();
    api.responses[history.key] = scheduleFor(history, owner: 'OTHER');
    await repo.discoverSchedules(now: now);
    final record = (await repo.loadTermRecord(history.key))!;
    expect(record.availability, ScheduleAvailability.failed);
    expect(record.schedule, isNull);
    expect((await repo.loadCachedSchedule())!.term.studentId, 'A');
  });
}
