import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

void main() {
  setUpAll(timezone_data.initializeTimeZones);

  test('calendar weeks advance on Monday across the year boundary', () {
    final state = ScheduleWeekState(
      currentWeek: 3,
      anchorMonday: DateTime(2025, 12, 29),
    );

    expect(state.weekForDate(DateTime(2025, 12, 28, 23, 59)), 2);
    expect(state.weekForDate(DateTime(2026, 1, 4, 23, 59)), 3);
    expect(state.weekForDate(DateTime(2026, 1, 5)), 4);
    expect(state.weekForDate(DateTime(2025, 12, 1)), -1);
  });

  test('calendar weeks ignore UTC offsets and DST elapsed hours', () {
    final newYork = timezone.getLocation('America/New_York');
    final tokyo = timezone.getLocation('Asia/Tokyo');
    final state = ScheduleWeekState(
      currentWeek: 4,
      anchorMonday: timezone.TZDateTime(newYork, 2026, 3, 2),
    );
    final afterSpringForward = timezone.TZDateTime(newYork, 2026, 3, 9);

    // The two calendar Mondays are only 167 elapsed hours apart.
    expect(afterSpringForward.difference(state.anchorMonday).inHours, 167);
    expect(state.weekForDate(afterSpringForward), 5);
    expect(state.weekForDate(DateTime.utc(2026, 3, 9)), 5);
    expect(state.weekForDate(timezone.TZDateTime(tokyo, 2026, 3, 9)), 5);
    expect(
        state.weekForDate(timezone.TZDateTime(tokyo, 2026, 3, 8, 23, 59)), 4);

    final autumnState = ScheduleWeekState(
      currentWeek: 8,
      anchorMonday: timezone.TZDateTime(newYork, 2026, 11, 2),
    );
    final beforeFallBack = timezone.TZDateTime(newYork, 2026, 10, 26);
    expect(beforeFallBack.difference(autumnState.anchorMonday).inHours, -169);
    expect(autumnState.weekForDate(beforeFallBack), 7);
  });

  test('repository and widget clamp the shared calendar week consistently', () {
    final repository = AcademicScheduleRepository();
    final state = ScheduleWeekState(
      currentWeek: 1,
      anchorMonday: timezone.TZDateTime(
        timezone.getLocation('America/New_York'),
        2026,
        3,
        2,
      ),
    );
    for (final (date, expected) in [
      (DateTime.utc(2026, 2, 16), 0),
      (DateTime.utc(2026, 3, 8, 23, 59), 1),
      (DateTime.utc(2026, 3, 9), 2),
      (DateTime.utc(2027, 1, 1), _schedule.vacationWeek),
    ]) {
      expect(repository.activeWeekFromState(_schedule, state, now: date),
          expected);
      final snapshot = AcademicScheduleWidgetService.buildSnapshot(
        schedule: _schedule,
        weekState: state,
        now: date,
      );
      expect(snapshot['activeWeek'], expected);
    }
  });

  test(
      'cached schedule remains after expiration and is hidden for another account',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = AcademicScheduleRepository();
    final ownedSchedule = _schedule.copyWith(
        term: const AcademicTerm(
      yearCode: '2025',
      termCode: '16',
      academicYearName: '2025-2026',
      termName: '春',
      studentName: '',
      studentId: 'A',
      className: '',
    ));
    await repository.saveCachedSchedule(ownedSchedule);
    final account = AcademicAccountStore();
    await account.saveStudentId('A');
    await account.clear(sessionExpired: true);
    expect((await repository.loadCachedSchedule())?.term.studentId, 'A');
    await account.saveStudentId('OTHER');
    expect(await repository.loadCachedSchedule(), isNull);
    await account.clear(sessionExpired: true);
    expect(await repository.loadCachedSchedule(), isNull);
    // With no known data owner, legacy anonymous fixtures remain readable.
    SharedPreferences.setMockInitialValues({});
    await repository.saveCachedSchedule(_schedule);
    expect(await repository.loadCachedSchedule(), isNotNull);
  });
  test('first schedule import starts at week one', () async {
    SharedPreferences.setMockInitialValues({
      'academic.schedule.anchorWeek': 7,
    });
    final repository = AcademicScheduleRepository(
      apiClient: _FakeAcademicScheduleApiClient(_schedule),
    );

    await repository.refreshSchedule();

    final state = await repository.loadWeekState();
    expect(state.currentWeek, 1);
  });

  test('repeated schedule import preserves the configured week', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = AcademicScheduleRepository(
      apiClient: _FakeAcademicScheduleApiClient(_schedule),
    );

    await repository.refreshSchedule();
    await repository.setCurrentWeek(7, now: DateTime(2026, 8, 31));
    await repository.refreshSchedule();

    final state = await repository.loadWeekState();
    expect(state.currentWeek, 7);
  });

  test('cached state loads the schedule and week anchor together', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = AcademicScheduleRepository(
      apiClient: _FakeAcademicScheduleApiClient(_schedule),
    );
    await repository.saveCachedSchedule(_schedule);
    await repository.setCurrentWeek(3, now: DateTime(2026, 8, 31));

    final cached = await repository.loadCachedState();

    expect(cached.schedule?.term.displayName, _schedule.term.displayName);
    expect(cached.weekState.currentWeek, 3);
    expect(cached.weekState.anchorMonday, DateTime(2026, 8, 31));
  });

  test('legacy week anchors derive the first teaching week start', () {
    final state = ScheduleWeekState(
      currentWeek: 7,
      anchorMonday: DateTime(2026, 8, 31),
    );

    expect(state.firstWeekStart, DateTime(2026, 7, 20));
  });

  test('setting the first week start stores a canonical Monday anchor',
      () async {
    SharedPreferences.setMockInitialValues({
      'academic.schedule.anchorWeek': 7,
      'academic.schedule.anchorMonday': '2026-08-31T00:00:00.000',
    });
    final repository = AcademicScheduleRepository(
      apiClient: _FakeAcademicScheduleApiClient(_schedule),
    );

    await repository.setFirstWeekStart(DateTime(2026, 8, 26));
    final state = await repository.loadWeekState();

    expect(state.currentWeek, 1);
    expect(state.anchorMonday, DateTime(2026, 8, 24));
    expect(state.firstWeekStart, DateTime(2026, 8, 24));
    expect(
      repository.activeWeekFromState(
        _schedule,
        state,
        now: DateTime(2026, 9, 7),
      ),
      3,
    );
    expect(
      repository.dateForWeekday(
        state: state,
        displayedWeek: 3,
        weekday: DateTime.wednesday,
      ),
      DateTime(2026, 9, 9),
    );
  });

  test('active week can be the vacation before week one', () {
    final repository = AcademicScheduleRepository(
      apiClient: _FakeAcademicScheduleApiClient(_schedule),
    );
    final state = ScheduleWeekState(
      currentWeek: 1,
      anchorMonday: DateTime(2026, 7, 13),
    );

    expect(
      repository.activeWeekFromState(
        _schedule,
        state,
        now: DateTime(2026, 7, 6),
      ),
      0,
    );
  });
}

class _FakeAcademicScheduleApiClient extends AcademicScheduleApiClient {
  _FakeAcademicScheduleApiClient(this.schedule)
      : super(authService: _FakeAcademicAuthService());

  final AcademicSchedule schedule;

  @override
  Future<AcademicSchedule> fetchCurrentSchedule() async => schedule;
}

class _FakeAcademicAuthService implements AcademicAuthService {
  @override
  Future<void> clearAccount({bool sessionExpired = false}) async {}

  @override
  Future<Set<String>> clearCookies() async => {};

  @override
  Future<void> markLoggedIn() async {}

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => null;

  @override
  Future<bool> hasWebVpnSession() async => false;

  @override
  Future<bool> hasAcademicSession() async => false;

  @override
  Future<WebVpnSessionStatus> validateDirectAcademicSession() async =>
      WebVpnSessionStatus.loginRequired;

  @override
  Future<WebVpnSessionStatus> validateWebVpnSession() async =>
      WebVpnSessionStatus.loginRequired;
}

final _schedule = AcademicSchedule(
  term: const AcademicTerm(
    yearCode: '2025',
    termCode: '16',
    academicYearName: '2025-2026',
    termName: '春',
    studentName: '',
    studentId: '',
    className: '',
  ),
  sessions: const [],
  untimedCourses: const [],
  fetchedAt: DateTime(2026, 8, 31),
);
