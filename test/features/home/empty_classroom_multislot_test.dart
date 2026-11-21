import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';

const _building = ClassroomBuilding(
  id: 1,
  name: 'GA楼',
  campusId: 3,
  campusName: '宝山',
);

const _floor = ClassroomFloor(
  id: 1,
  name: '一层',
  rooms: [
    ClassroomRoom(
      id: 101,
      name: 'GA101',
      floorName: '一层',
      fullName: '宝山/GA楼/一层/GA101',
      courses: [
        ClassroomCourse(
          courseName: '线性代数',
          teacherName: '林老师',
          startSection: 5,
          endSection: 6,
        ),
      ],
    ),
    ClassroomRoom(
      id: 102,
      name: 'GA102',
      floorName: '一层',
      fullName: '',
      courses: [
        ClassroomCourse(
          courseName: '大学英语',
          teacherName: '周老师',
          startSection: 3,
          endSection: 4,
        ),
      ],
    ),
    ClassroomRoom(
      id: 103,
      name: 'GA103',
      floorName: '一层',
      fullName: '',
      courses: [
        ClassroomCourse(
          courseName: '程序设计',
          teacherName: '余老师',
          startSection: 7,
          endSection: 8,
        ),
      ],
    ),
    ClassroomRoom(
      id: 104,
      name: 'GA104',
      floorName: '一层',
      fullName: '',
      courses: [],
    ),
    ClassroomRoom(
      id: 105,
      name: 'GA105',
      floorName: '一层',
      fullName: '',
      courses: [
        ClassroomCourse(
          courseName: '教学活动',
          teacherName: '',
          startSection: 4,
          endSection: 7,
          source: '借',
        ),
      ],
    ),
  ],
);

class _ScheduleRepository extends ClassroomRepository {
  int loads = 0;

  @override
  ClassroomSearchOptions get optionsSnapshot => const ClassroomSearchOptions(
        buildings: [_building],
        sections: [
          ClassroomSection(index: 3, startTime: '10:00', endTime: '10:45'),
          ClassroomSection(index: 4, startTime: '10:55', endTime: '11:40'),
          ClassroomSection(index: 5, startTime: '13:00', endTime: '13:45'),
          ClassroomSection(index: 6, startTime: '13:55', endTime: '14:40'),
          ClassroomSection(index: 7, startTime: '15:00', endTime: '15:45'),
          ClassroomSection(index: 8, startTime: '15:55', endTime: '16:40'),
        ],
      );

  @override
  Future<ClassroomBuildingSchedule> loadSchedule({
    required ClassroomBuilding building,
    required DateTime date,
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async {
    loads++;
    return const ClassroomBuildingSchedule(
        building: _building, floors: [_floor]);
  }
}

final _sectionButton = find.byKey(const ValueKey('classroom-sections'));
final _apply = find.widgetWithText(FilledButton, '应用');
Finder _slot(int start, int end) =>
    find.byKey(ValueKey('classroom-slot-$start-$end'));

Future<void> _open(WidgetTester tester, _ScheduleRepository repository,
    {double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: EmptyClassroomPage(
      repository: repository,
      fixedDate: true,
      initialDate: DateTime(2026, 9, 1, 10, 5),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pickSections(WidgetTester tester) async {
  await tester.tap(_sectionButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'disjoint blocks intersect availability using the loaded schedule',
      (tester) async {
    final repository = _ScheduleRepository();
    await _open(tester, repository);
    expect(find.text('GA103'), findsOneWidget);

    await _pickSections(tester);
    expect(tester.widget<FilterChip>(_slot(3, 4)).selected, isTrue);
    await tester.tap(_slot(7, 8));
    await tester.pump();
    expect(tester.widget<FilterChip>(_slot(7, 8)).selected, isTrue);
    await tester.tap(_apply);
    await tester.pumpAndSettle();

    expect(find.text('3–4、7–8节'), findsOneWidget);
    expect(find.text('GA101'), findsOneWidget);
    expect(find.text('GA104'), findsOneWidget);
    expect(find.text('GA102'), findsNothing);
    expect(find.text('GA103'), findsNothing);
    expect(find.text('GA105'), findsNothing);
    expect(repository.loads, 1);
  });

  testWidgets('empty draft cannot apply and dismissing keeps the active filter',
      (tester) async {
    final repository = _ScheduleRepository();
    await _open(tester, repository);
    await _pickSections(tester);
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(tester.widget<FilledButton>(_apply).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('3–4节'), findsOneWidget);
    expect(find.text('GA103'), findsOneWidget);
    expect(repository.loads, 1);
  });

  testWidgets('exact sections work with large text on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ScheduleRepository();
    await _open(tester, repository, textScale: 1.8);
    await _pickSections(tester);
    await tester.tap(find.text('单节'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(_slot(3, 3)).selected, isTrue);
    await tester.tap(_slot(4, 4));
    await tester.pump();
    await tester.tap(_apply);
    await tester.pumpAndSettle();
    expect(find.text('3节'), findsOneWidget);
    expect(find.text('GA105'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
