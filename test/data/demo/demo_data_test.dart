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
    expect(data.classroomOptions.buildings.map((building) => building.name),
        unorderedEquals(['A楼', 'GA楼']));
    final rooms = data.classroomSchedules[930]!.rooms;
    final example = rooms.singleWhere((room) => room.name == 'GA101');
    expect(example.coursesFor({5, 6}).single.courseName, '线性代数');
    expect(example.isFreeFor({3, 4, 7, 8}), isTrue);
    expect(
        rooms.expand((room) => room.courses).any((item) => item.source == '借'),
        isTrue);
  });

  test('serves both classroom buildings offline on the preview date', () async {
    final data = await DemoDataBundle.load();
    final repository = DemoClassroomRepository(
      options: data.classroomOptions,
      schedules: data.classroomSchedules,
    );
    final options = await repository.loadOptions();
    for (final (id, roomName, sections) in [
      (303, 'A101', {7, 8}),
      (930, 'GA101', {5, 6}),
    ]) {
      final schedule = await repository.loadSchedule(
        building:
            options.buildings.singleWhere((building) => building.id == id),
        date: DemoDataBundle.previewTime,
      );
      final room = schedule.rooms.singleWhere((room) => room.name == roomName);
      expect(room.coursesFor(sections).single.courseName, '线性代数');
    }
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
    expect(DemoSession.matchesCredentials('shuyo.demo', 'CampusPreview26'),
        isTrue);
    expect(DemoSession.matchesCredentials('ShuYo.Demo ', 'wrong'), isFalse);
    expect(DemoSession.isDemoUsername('ShuYo.Demo '), isTrue);
    expect(DemoSession.isDemoUsername('admin2512'), isFalse);
  });
}
