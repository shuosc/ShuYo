import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
import 'package:shuyo/features/empty_classroom/classroom_presentation.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';

void main() {
  test('groups B楼 with 宝山 despite the malformed source fullName', () {
    final options = ClassroomApiClient.parseSearchOptions(
      {
        'data': {
          'buildList': [
            {
              'id': 303,
              'name': 'A楼',
              'parentNodeId': 3,
              'fullName': '上海大学/宝山校区/A楼',
            },
            {
              'id': 122,
              'name': 'B楼',
              'parentNodeId': 3,
              'fullName': '上海大学/宝山校区B楼',
            },
          ],
        },
      },
      {
        'data': {'section': []},
      },
    );

    expect(options.campusNames, ['宝山']);
    expect(options.buildings.last.campusName, '宝山');
  });

  test('corrects the previously cached B楼 campus name', () {
    final options = ClassroomSearchOptions.fromJson({
      'buildings': [
        {
          'id': 122,
          'name': 'B楼',
          'campusId': 3,
          'campusName': '宝山B楼',
          'fullName': '上海大学/宝山校区B楼',
        },
      ],
      'sections': [],
    });

    expect(options.campusNames, ['宝山']);
  });

  test('merges the east district into 宝山 and keeps three campuses', () {
    final options = ClassroomApiClient.parseSearchOptions(
      {
        'data': {
          'buildList': [
            {
              'id': 303,
              'name': 'A楼',
              'parentNodeId': 3,
              'fullName': '上海大学/宝山校区/A楼',
            },
            {
              'id': 476,
              'name': '商管大楼',
              'parentNodeId': 475,
              'fullName': '上海大学/宝山东区/商管大楼',
            },
            {
              'id': 399,
              'name': '行健楼',
              'parentNodeId': 398,
              'fullName': '上海大学/延长校区/行健楼',
            },
            {
              'id': 607,
              'name': '第一教学楼',
              'parentNodeId': 574,
              'fullName': '上海大学/嘉定校区/第一教学楼',
            },
          ],
        },
      },
      {
        'data': {'section': []},
      },
    );

    expect(options.campusNames, ['宝山', '延长', '嘉定']);
    expect(options.campusNames, isNot(contains('宝山东区')));
  });

  test('renames the three renamed buildings and hides 计算机大楼', () {
    final options = ClassroomApiClient.parseSearchOptions(
      {
        'data': {
          'buildList': [
            {
              'id': 476,
              'name': '商管大楼',
              'parentNodeId': 475,
              'fullName': '上海大学/宝山东区/商管大楼',
            },
            {
              'id': 478,
              'name': '信息大楼',
              'parentNodeId': 475,
              'fullName': '上海大学/宝山东区/信息大楼',
            },
            {
              'id': 477,
              'name': '材料大楼',
              'parentNodeId': 475,
              'fullName': '上海大学/宝山东区/材料大楼',
            },
            {
              'id': 884,
              'name': '计算机大楼',
              'parentNodeId': 475,
              'fullName': '上海大学/宝山东区/计算机大楼',
            },
            {
              'id': 700,
              'name': 'J楼',
              'parentNodeId': 3,
              'fullName': '上海大学/宝山校区/J楼',
            },
            {
              'id': 930,
              'name': 'GA楼',
              'parentNodeId': 3,
              'fullName': '上海大学/宝山校区/GA楼',
            },
          ],
        },
      },
      {
        'data': {'section': []},
      },
    );

    final names = [for (final building in options.buildings) building.name];
    expect(names, containsAll(['经管楼', '计算机/通信楼', '材料楼']));
    expect(names, isNot(contains('计算机大楼')));
    // J楼与 GA楼照常参与。
    expect(names, containsAll(['J楼', 'GA楼']));
    // 楼名改了，全名末段也跟着改。
    final renamed =
        options.buildings.firstWhere((building) => building.id == 476);
    expect(renamed.fullName, '上海大学/宝山东区/经管楼');
  });

  test('sorts 宝山 buildings so 主楼 sits next to its 阶梯楼', () {
    final options = ClassroomSearchOptions(
      buildings: const [
        ClassroomBuilding(id: 325, name: 'AJ楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(id: 303, name: 'A楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(id: 328, name: 'BJ楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(id: 122, name: 'B楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(
            id: 399, name: '行健楼', campusId: 398, campusName: '延长'),
      ],
      sections: const [],
    );

    final sorted = selectableBuildings(options);
    expect([for (final building in sorted) building.name],
        ['A楼', 'AJ楼', 'B楼', 'BJ楼', '行健楼']);
  });

  test('preferred campus selects every building in that campus', () {
    final options = ClassroomSearchOptions(
      buildings: const [
        ClassroomBuilding(id: 303, name: 'A楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(id: 122, name: 'B楼', campusId: 3, campusName: '宝山'),
        ClassroomBuilding(
            id: 399, name: '行健楼', campusId: 398, campusName: '延长'),
      ],
      sections: const [],
    );

    expect(
        defaultBuildingSelection(options, preferredCampus: '宝山'), {303, 122});
    expect(
        defaultBuildingSelection(options, preferredCampus: '嘉定'), {303, 122});
    expect(defaultBuildingSelection(options, preferredCampus: '延长'), {399});
  });

  testWidgets('preferred campus is applied on open with an available fallback',
      (tester) async {
    final repository = _CampusRepository();
    Future<void> open(String campus, String key) async {
      await tester.pumpWidget(MaterialApp(
        home: EmptyClassroomPage(
          key: ValueKey(key),
          repository: repository,
          initialDate: DateTime(2026, 9, 1),
          initialCampus: campus,
        ),
      ));
      await tester.pumpAndSettle();
    }

    await open('嘉定', 'first');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>).first,
          )
          .initialValue,
      '嘉定',
    );

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('宝山').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>).first,
          )
          .initialValue,
      '宝山',
    );

    await open('嘉定', 'reopen');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>).first,
          )
          .initialValue,
      '嘉定',
    );

    await open('延长', 'second');
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>).first,
          )
          .initialValue,
      '宝山',
    );
  });
}

class _CampusRepository extends ClassroomRepository {
  static const options = ClassroomSearchOptions(
    buildings: [
      ClassroomBuilding(
        id: 1,
        name: 'A楼',
        campusId: 3,
        campusName: '宝山',
      ),
      ClassroomBuilding(
        id: 2,
        name: 'D楼',
        campusId: 574,
        campusName: '嘉定',
      ),
    ],
    sections: [
      ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
    ],
  );

  @override
  Future<ClassroomSearchOptions> loadOptions(
          {bool forceRefresh = false}) async =>
      options;

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
  }) async =>
      ClassroomAvailabilityResult(
        building: query.building,
        date: query.date,
        startSection: query.startSection,
        endSection: query.endSection,
        floors: const [],
      );
}
