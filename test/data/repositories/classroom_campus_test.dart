import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
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
  Future<ClassroomSearchOptions> loadOptions({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async =>
      options;

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async =>
      ClassroomAvailabilityResult(
        building: query.building,
        date: query.date,
        startSection: query.startSection,
        endSection: query.endSection,
        floors: const [],
      );
}
