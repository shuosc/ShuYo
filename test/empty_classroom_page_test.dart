import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';

void main() {
  test('keeps loaded options as the memory snapshot', () async {
    SharedPreferences.setMockInitialValues({
      'classroom.options.cache': jsonEncode({
        'buildings': [
          {
            'id': 1,
            'name': 'A楼',
            'campusId': 3,
            'campusName': '宝山',
          },
        ],
        'sections': [
          {'index': 1, 'startTime': '08:00', 'endTime': '08:45'},
        ],
      }),
      'classroom.options.lastRefreshAt': DateTime.now().toIso8601String(),
    });
    final repository = ClassroomRepository();

    expect(repository.optionsSnapshot, isNull);

    final options = await repository.loadOptions();

    expect(identical(repository.optionsSnapshot, options), isTrue);
  });

  testWidgets('reopening paints the remembered options on the first frame',
      (tester) async {
    final repository =
        _SnapshotRepository(snapshot: _SnapshotRepository.options);

    await tester.pumpWidget(MaterialApp(
      home: EmptyClassroomPage(repository: repository),
    ));

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(repository.searches, 1);

    await tester.pumpAndSettle();
    // A result without any room is reported as missing data rather than as
    // "no free rooms", so the two cases stay distinguishable.
    expect(find.text('暂无教室数据'), findsOneWidget);
  });

  testWidgets('a cold open waits for the options before showing the controls',
      (tester) async {
    final load = Completer<ClassroomSearchOptions>();
    final repository = _SnapshotRepository(pendingLoad: load.future);

    await tester.pumpWidget(MaterialApp(
      home: EmptyClassroomPage(repository: repository),
    ));

    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    load.complete(_SnapshotRepository.options);
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(repository.searches, 1);
  });
}

class _SnapshotRepository extends ClassroomRepository {
  _SnapshotRepository({
    ClassroomSearchOptions? snapshot,
    this.pendingLoad,
  }) : _snapshot = snapshot;

  static const options = ClassroomSearchOptions(
    buildings: [
      ClassroomBuilding(id: 1, name: 'A楼', campusId: 3, campusName: '宝山'),
    ],
    sections: [
      ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
    ],
  );

  final ClassroomSearchOptions? _snapshot;
  final Future<ClassroomSearchOptions>? pendingLoad;
  int searches = 0;

  @override
  ClassroomSearchOptions? get optionsSnapshot => _snapshot;

  @override
  Future<ClassroomSearchOptions> loadOptions({bool forceRefresh = false}) =>
      pendingLoad ?? Future.value(options);

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
  }) async {
    searches += 1;
    return ClassroomAvailabilityResult(
      building: query.building,
      date: query.date,
      startSection: query.startSection,
      endSection: query.endSection,
      floors: const [],
    );
  }
}
