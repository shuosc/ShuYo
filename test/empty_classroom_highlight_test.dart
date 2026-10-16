import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _building = ClassroomBuilding(
  id: 1,
  name: 'A楼',
  campusId: 3,
  campusName: '宝山',
);

const _rooms = [
  ClassroomRoom(
    id: 101,
    name: 'A101',
    floorName: '一层',
    fullName: 'A楼/一层/A101',
    courses: [
      ClassroomCourse(
        courseName: '下午课程',
        teacherName: '',
        startSection: 3,
        endSection: 4,
      ),
    ],
  ),
  ClassroomRoom(
    id: 102,
    name: 'A102',
    floorName: '一层',
    fullName: 'A楼/一层/A102',
    courses: [
      ClassroomCourse(
        courseName: '上午课程',
        teacherName: '',
        startSection: 1,
        endSection: 2,
      ),
    ],
  ),
];

const _occupiedFloorRooms = [
  ClassroomRoom(
    id: 201,
    name: 'A201',
    floorName: '二层',
    fullName: 'A楼/二层/A201',
    courses: [
      ClassroomCourse(
        courseName: '全天课程',
        teacherName: '',
        startSection: 1,
        endSection: 4,
      ),
    ],
  ),
];

class _ClassroomRepository extends ClassroomRepository {
  @override
  Future<ClassroomSearchOptions> loadOptions({
    bool forceRefresh = false,
  }) async {
    return const ClassroomSearchOptions(
      buildings: [_building],
      sections: [
        ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
        ClassroomSection(index: 2, startTime: '08:55', endTime: '09:40'),
        ClassroomSection(index: 3, startTime: '10:00', endTime: '10:45'),
        ClassroomSection(index: 4, startTime: '10:55', endTime: '11:40'),
      ],
      currentSection: 1,
    );
  }

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
  }) async {
    const floor = ClassroomFloor(id: 1, name: '一层', rooms: _rooms);
    const occupiedFloor = ClassroomFloor(
      id: 2,
      name: '二层',
      rooms: _occupiedFloorRooms,
    );
    return ClassroomAvailabilityResult(
      building: query.building,
      date: query.date,
      startSection: query.startSection,
      endSection: query.endSection,
      floors: [
        ClassroomFloorAvailability(
          floor: floor,
          rooms: floor.rooms,
          availableRooms: floor.rooms
              .where(
                (room) => room.isFreeFor(query.startSection, query.endSection),
              )
              .toList(),
        ),
        ClassroomFloorAvailability(
          floor: occupiedFloor,
          rooms: occupiedFloor.rooms,
          availableRooms: const [],
        ),
      ],
    );
  }
}

void main() {
  for (final themeId in [
    ShuYoThemes.defaultId,
    ShuYoThemes.systemDarkId,
  ]) {
    testWidgets(
      'highlight toggle follows the selected range in $themeId',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = ShuYoThemes.byId(themeId);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.themeData(),
            home: EmptyClassroomPage(repository: _ClassroomRepository()),
          ),
        );
        await tester.pumpAndSettle();

        // The initial range depends on the wall clock: step back once so the
        // assertions below start from the first range whatever the time is.
        await tester.tap(find.byTooltip('上一节'));
        await tester.pumpAndSettle();

        expect(find.text('A101'), findsOneWidget);
        expect(find.text('A102'), findsNothing);
        expect(find.text('A201'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(
          tester.widget<FilterChip>(find.byType(FilterChip)).selected,
          isFalse,
        );

        await tester.tap(find.text('高亮空闲'));
        await tester.pumpAndSettle();

        expect(find.text('A101'), findsOneWidget);
        expect(find.text('A102'), findsOneWidget);
        expect(find.text('A201'), findsOneWidget);
        expect(
          tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('A101'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor,
          theme.colors.accentSoft,
        );
        expect(
          tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('A102'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor,
          theme.colors.surfaceAlt,
        );
        expect(
          tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('A201'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor,
          theme.colors.surfaceAlt,
        );

        await tester.tap(find.byTooltip('下一节'));
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('A102'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor,
          theme.colors.accentSoft,
        );
        expect(
          tester
              .widget<ActionChip>(
                find.ancestor(
                  of: find.text('A101'),
                  matching: find.byType(ActionChip),
                ),
              )
              .backgroundColor,
          theme.colors.surfaceAlt,
        );

        await tester.tap(find.text('高亮空闲'));
        await tester.pumpAndSettle();
        expect(find.text('A101'), findsNothing);
        expect(find.text('A102'), findsOneWidget);
        expect(find.text('A201'), findsNothing);

        await tester.tap(find.byTooltip('搜索课程、教师或教室'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        await tester.tap(find.byTooltip('关闭搜索'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
      },
    );
  }
}
