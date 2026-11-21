import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _building = ClassroomBuilding(
  id: 1,
  name: 'GA楼',
  campusId: 3,
  campusName: '宝山',
);

const _otherBuilding = ClassroomBuilding(
  id: 2,
  name: 'B楼',
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
  _ScheduleRepository({this.otherSchedule});

  final Future<ClassroomBuildingSchedule>? otherSchedule;
  int loads = 0;

  @override
  ClassroomSearchOptions get optionsSnapshot => ClassroomSearchOptions(
        buildings: [_building, if (otherSchedule != null) _otherBuilding],
        sections: const [
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
    if (building.id == _otherBuilding.id) return otherSchedule!;
    return const ClassroomBuildingSchedule(
        building: _building, floors: [_floor]);
  }
}

final _sectionButton = find.byKey(const ValueKey('classroom-sections'));
final _apply = find.widgetWithText(FilledButton, '应用');
Finder _slot(int start, int end) =>
    find.byKey(ValueKey('classroom-slot-$start-$end'));

Future<void> _open(WidgetTester tester, _ScheduleRepository repository,
    {double textScale = 1, bool dark = false}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.byId(
            dark ? ShuYoThemes.systemDarkId : ShuYoThemes.defaultId)
        .themeData(),
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
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
    expect(tester.widget<Semantics>(_slot(3, 4)).properties.selected, isTrue);
    await tester.tap(_slot(7, 8));
    await tester.pump();
    expect(tester.widget<Semantics>(_slot(7, 8)).properties.selected, isTrue);
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
    expect(tester.widget<Semantics>(_slot(3, 3)).properties.selected, isTrue);
    await tester.tap(_slot(4, 4));
    await tester.pump();
    await tester.tap(_apply);
    await tester.pumpAndSettle();
    expect(find.text('3节'), findsOneWidget);
    expect(find.text('GA105'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrangements show matching classes once and share the selection',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(410, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ScheduleRepository();
    await _open(tester, repository);
    await _pickSections(tester);
    await _tap(tester, _slot(7, 8));
    await _tap(tester, _apply);
    await _tap(tester, find.text('教室安排'));

    final fullDay = find.widgetWithText(ChoiceChip, '全天');
    final selectedSections = find.widgetWithText(ChoiceChip, '所选节次');
    expect(tester.widget<ChoiceChip>(fullDay).selected, isTrue);
    expect(tester.getTopLeft(fullDay).dx,
        lessThan(tester.getTopLeft(selectedSections).dx));
    expect(find.text('线性代数'), findsOneWidget);

    await _tap(tester, selectedSections);
    expect(find.text('周老师'), findsOneWidget);
    expect(find.text('程序设计'), findsOneWidget);
    expect(find.text('教学活动'), findsOneWidget);
    expect(find.text('借用'), findsOneWidget);
    expect(find.text('无安排'), findsNWidgets(2));
    expect(find.text('线性代数'), findsNothing);

    await tester.enterText(find.byType(TextField), '林老师');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配结果'), findsOneWidget);
    await _tap(tester, fullDay);
    expect(find.text('线性代数'), findsOneWidget);

    await _tap(tester, find.byTooltip('清除搜索'));
    await _tap(tester, selectedSections);
    await _tap(tester, find.widgetWithText(FilterChip, '仅看有安排'));
    expect(find.text('GA101'), findsNothing);
    expect(find.text('GA104'), findsNothing);
    await _tap(tester, find.text('找空教室'));
    expect(find.text('3–4、7–8节'), findsOneWidget);
    await _tap(tester, find.text('GA101'));
    expect(find.text('线性代数'), findsOneWidget);
    expect(find.text('5–6节'), findsOneWidget);
    expect(repository.loads, 1);
  });

  testWidgets('all buildings keep loaded rooms visible if another fails',
      (tester) async {
    final other = Completer<ClassroomBuildingSchedule>();
    final repository = _ScheduleRepository(otherSchedule: other.future);
    await _open(tester, repository);
    await _tap(tester, find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.text('全部教学楼').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GA104'), findsOneWidget);
    expect(find.text('B楼'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    other.completeError(TimeoutException('test failure'));
    await tester.pumpAndSettle();

    expect(find.text('GA104'), findsOneWidget);
    expect(find.text('未加载'), findsOneWidget);
    expect(find.text('查询失败'), findsNothing);
    await _tap(tester, find.text('教室安排'));
    expect(find.text('大学英语'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('未加载'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('未加载'), findsOneWidget);
  });

  testWidgets('arrangements scroll at large text sizes with keyboard insets',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final repository = _ScheduleRepository();
    await _open(tester, repository, textScale: 2, dark: true);
    await _tap(tester, find.text('教室安排'));
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '大学英语');
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(repository.loads, 1);
  });
}
