import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/demo/demo_data_bundle.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/demo/demo_session.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled demo fixtures without personal identifiers', () async {
    final data = await DemoDataBundle.load();
    expect(data.schedule.term.studentName, '演示同学');
    expect(data.schedule.term.studentId, 'DEMO0001');
    expect(data.announcements, hasLength(4));
    expect(data.classroomSchedule.building.name, 'GA楼');
  });

  test('demonstrates the bundled term and keeps schedule edits offline',
      () async {
    final data = await DemoDataBundle.load();
    final repository = DemoAcademicScheduleRepository(data.schedule);
    final termKey = await repository.loadPrimaryTermKey();
    final state = await repository.loadCachedState();

    expect(await repository.loadSavedSchedules(), hasLength(1));
    expect((await repository.loadTermRecord(termKey))?.schedule, data.schedule);
    expect(state.weekState.firstWeekStart, DateTime(2026, 8, 31));
    expect(repository.activeWeekFromState(data.schedule, state.weekState), 1);
    expect((await repository.homeSummary()).text, contains('面向对象程序设计'));

    await repository.setFirstWeekStart(DateTime(2026, 8, 24));
    expect((await repository.loadTermRecord(termKey))?.firstWeekStart,
        DateTime(2026, 8, 24));
    await repository.saveWorkingSchedule(
      data.schedule.copyWith(sessions: const []),
    );
    expect((await repository.homeSummary()).text, '今日暂无课程');
    await repository.refreshSchedule();
    expect(await repository.loadCachedSchedule(), data.schedule);
    expect((await repository.loadWeekState()).firstWeekStart,
        state.weekState.firstWeekStart);
  });

  test('demo session credentials are exact', () {
    expect(DemoSession.matchesCredentials('admin2512', 'abc123456'), isTrue);
    expect(DemoSession.matchesCredentials('admin2512', 'wrong'), isFalse);
  });
}
