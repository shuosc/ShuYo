import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/data/services/classroom_api_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/home/empty_classroom_page.dart';

void main() {
  setUp(() => ClassroomUrlResolver.configure(useWebVpn: false));
  tearDown(() => ClassroomUrlResolver.configure(useWebVpn: false));

  for (final reenable in [false, true]) {
    testWidgets('late auth failure ignores a changed mode: reenable=$reenable',
        (tester) async {
      ClassroomUrlResolver.configure(useWebVpn: true);
      final repository = _PendingRepository();
      var recoveries = 0;
      var expiryNotifications = 0;
      await tester.pumpWidget(MaterialApp(
        home: EmptyClassroomPage(
          repository: repository,
          onWebVpnRecoveryRequired: (_) async {
            recoveries++;
            return WebVpnRecoveryOutcome.recovered;
          },
          onWebVpnExpired: () async => expiryNotifications++,
        ),
      ));

      ClassroomUrlResolver.configure(useWebVpn: false);
      if (reenable) ClassroomUrlResolver.configure(useWebVpn: true);
      repository.pending.completeError(const ClassroomWebVpnAuthException());
      await tester.pumpAndSettle();

      expect(recoveries, 0);
      expect(expiryNotifications, 0);
      expect(repository.searches, 1);
      expect(ClassroomUrlResolver.usesWebVpn, reenable);
    });
  }

  testWidgets('an unchanged WebVPN mode recovers and retries once',
      (tester) async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final repository = _PendingRepository();
    var recoveries = 0;
    await tester.pumpWidget(MaterialApp(
      home: EmptyClassroomPage(
        repository: repository,
        onWebVpnRecoveryRequired: (_) async {
          recoveries++;
          return WebVpnRecoveryOutcome.recovered;
        },
      ),
    ));

    repository.pending.completeError(const ClassroomWebVpnAuthException());
    await tester.pumpAndSettle();

    expect(recoveries, 1);
    expect(repository.searches, 2);
    expect(find.text('没有空教室'), findsOneWidget);
  });

  testWidgets('closing WebVPN during recovery prevents retry', (tester) async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final repository = _PendingRepository();
    final recovery = Completer<WebVpnRecoveryOutcome>();
    var recoveries = 0;
    await tester.pumpWidget(MaterialApp(
      home: EmptyClassroomPage(
        repository: repository,
        onWebVpnRecoveryRequired: (_) {
          recoveries++;
          return recovery.future;
        },
      ),
    ));

    repository.pending.completeError(const ClassroomWebVpnAuthException());
    await tester.pump();
    expect(recoveries, 1);
    ClassroomUrlResolver.configure(useWebVpn: false);
    recovery.complete(WebVpnRecoveryOutcome.recovered);
    await tester.pumpAndSettle();

    expect(repository.searches, 1);
    expect(ClassroomUrlResolver.usesWebVpn, isFalse);
  });

  testWidgets('late options failure does not invoke the legacy expiry callback',
      (tester) async {
    ClassroomUrlResolver.configure(useWebVpn: true);
    final load = Completer<ClassroomSearchOptions>();
    var expiryNotifications = 0;
    await tester.pumpWidget(MaterialApp(
      home: EmptyClassroomPage(
        repository: _SnapshotRepository(pendingLoad: load.future),
        onWebVpnExpired: () async => expiryNotifications++,
      ),
    ));

    ClassroomUrlResolver.configure(useWebVpn: false);
    load.completeError(const ClassroomWebVpnAuthException());
    await tester.pumpAndSettle();

    expect(expiryNotifications, 0);
    expect(ClassroomUrlResolver.usesWebVpn, isFalse);
  });

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
    expect(find.text('没有空教室'), findsOneWidget);
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

class _PendingRepository extends _SnapshotRepository {
  _PendingRepository() : super(snapshot: _SnapshotRepository.options);

  final pending = Completer<ClassroomAvailabilityResult>();

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) {
    if (searches == 0) {
      searches++;
      return pending.future;
    }
    return super
        .search(query, forceRefresh: forceRefresh, accessMode: accessMode);
  }
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
  Future<ClassroomSearchOptions> loadOptions({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) =>
      pendingLoad ?? Future.value(options);

  @override
  Future<ClassroomAvailabilityResult> search(
    ClassroomAvailabilityQuery query, {
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
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
