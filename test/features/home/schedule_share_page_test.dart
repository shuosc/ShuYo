import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/schedule_share_service.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/home/schedule_share_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets(
      'share card stays fixed while the pill switches on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: ScheduleSharePage(
        ownSchedule: null,
        ownWeekState: null,
        scheduleRepository: AcademicScheduleRepository(),
        identityService: null,
        importStore: _MemoryImports(),
        calendarStore: _MemoryCalendar(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('说明'));
    await tester.pumpAndSettle();
    expect(find.text('导入他人课表后可计算出两者共同空闲时间，支持多人比较'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byKey(const ValueKey('share-controls')));
    final capsule =
        tester.getRect(find.byKey(const ValueKey('share-code-capsule')));
    final generate =
        tester.getSize(find.byKey(const ValueKey('share-mode-generate')));
    final import =
        tester.getSize(find.byKey(const ValueKey('share-mode-import')));
    final selectedStart =
        tester.getRect(find.byKey(const ValueKey('share-mode-selection')));
    final generateLabel =
        tester.widget<AnimatedDefaultTextStyle>(find.descendant(
      of: find.byKey(const ValueKey('share-mode-generate')),
      matching: find.byType(AnimatedDefaultTextStyle),
    ));
    final importLabel = tester.widget<AnimatedDefaultTextStyle>(find.descendant(
      of: find.byKey(const ValueKey('share-mode-import')),
      matching: find.byType(AnimatedDefaultTextStyle),
    ));
    expect(generateLabel.style.fontWeight, importLabel.style.fontWeight);
    expect(import.width, lessThan(generate.width));
    expect(find.byType(Card), findsNothing);
    expect(find.text('暂无分享码'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('导入').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final selectedMiddle =
        tester.getRect(find.byKey(const ValueKey('share-mode-selection')));
    await tester.pumpAndSettle();
    final selectedEnd =
        tester.getRect(find.byKey(const ValueKey('share-mode-selection')));
    expect(selectedMiddle.left, greaterThan(selectedStart.left));
    expect(selectedMiddle.left, lessThan(selectedEnd.left));
    expect(selectedEnd.width, lessThan(selectedStart.width));
    expect(tester.getRect(find.byKey(const ValueKey('share-controls'))), card);
    expect(tester.getRect(find.byKey(const ValueKey('share-code-capsule'))),
        capsule);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.decoration?.border, InputBorder.none);
    expect(field.decoration?.enabledBorder, InputBorder.none);
    expect(field.decoration?.focusedBorder, InputBorder.none);
    await tester.enterText(find.byType(TextField).first, 'ABC123');
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.tapAt(const Offset(16, 600));
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(field.controller!.text, 'ABC123');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成分享码'));
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generation shares the viewed term instead of the primary term',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final identity = _FakeIdentity();
    addTearDown(identity.dispose);
    await AcademicAccountStore().saveStudentId(identity.session.studentId);
    AcademicSchedule scheduleFor(String year) => AcademicSchedule(
          term: AcademicTerm(
            yearCode: year,
            termCode: '3',
            academicYearName: '$year-${int.parse(year) + 1}',
            termName: '秋',
            studentName: '本人',
            studentId: identity.session.studentId,
            className: '一班',
          ),
          sessions: const [],
          untimedCourses: [
            UntimedCourse(
              id: 'manual-$year',
              courseName: '$year 本地课程',
              teacherName: '老师',
              campus: '校区',
              weeks: const [1, 2],
              weekText: '1-2周',
              summary: '自主安排',
              credit: '1',
            ),
          ],
          fetchedAt: DateTime.utc(2026, 10, 8),
        );
    final repository = AcademicScheduleRepository();
    final primary = scheduleFor('2026');
    final viewed = scheduleFor('2025');
    await repository.saveWorkingSchedule(primary);
    await repository.saveWorkingSchedule(viewed);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'success': true,
          'data': request.method == 'GET'
              ? null
              : {
                  'id': 'share-history',
                  'code': 'Ab3D4e',
                  'expiresAt': DateTime.now()
                      .add(const Duration(days: 14))
                      .toUtc()
                      .toIso8601String(),
                  'termLabel': viewed.term.displayName,
                  'includeNote': false,
                },
        })),
        request.method == 'GET' ? 200 : 201,
      );
    });
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: ScheduleSharePage(
        ownSchedule: (await repository.loadTermRecord('2025:3'))!.schedule,
        ownWeekState: await repository.loadTermWeekState('2025:3'),
        scheduleRepository: repository,
        identityService: identity,
        shareApi: ScheduleShareApi(client: client),
        importStore: _MemoryImports(),
        calendarStore: _MemoryCalendar(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '生成'));
    await tester.pumpAndSettle();
    expect(find.text('Ab3D4e'), findsOneWidget);
    final request = requests.singleWhere((item) => item.method == 'POST');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['snapshot'], scheduleShareSnapshot(viewed, includeNote: false));
    expect(await repository.loadPrimaryTermKey(), '2026:3');
    expect((await repository.loadCachedSchedule())!.toJson(), primary.toJson());
    expect(tester.takeException(), isNull);
  });

  testWidgets('destroying a code clears the read only capsule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final identity = _FakeIdentity();
    addTearDown(identity.dispose);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response('{"success":true,"data":null}', 200);
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'success': true,
            'data': {
              'id': 'share-one',
              'code': 'Ab3D4e',
              'expiresAt': DateTime.now()
                  .add(const Duration(days: 14))
                  .toUtc()
                  .toIso8601String(),
              'termLabel': '2026 秋',
              'includeNote': false
            }
          })),
          201);
    });
    const term = AcademicTerm(
      yearCode: '2026',
      termCode: '3',
      academicYearName: '2026-2027',
      termName: '秋',
      studentName: '本人',
      studentId: '12345678',
      className: '一班',
    );
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: ScheduleSharePage(
        ownSchedule: AcademicSchedule(
            term: term,
            sessions: const [],
            untimedCourses: const [],
            fetchedAt: DateTime.utc(2026, 10, 8)),
        ownWeekState: ScheduleWeekState(
            currentWeek: 1, anchorMonday: DateTime(2026, 8, 31)),
        scheduleRepository: AcademicScheduleRepository(),
        identityService: identity,
        shareApi: ScheduleShareApi(client: client),
        importStore: _MemoryImports(),
        calendarStore: _MemoryCalendar(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '生成'));
    await tester.pumpAndSettle();
    expect(find.text('Ab3D4e'), findsOneWidget);
    final card = tester.getRect(find.byKey(const ValueKey('share-controls')));
    final capsule =
        tester.getRect(find.byKey(const ValueKey('share-code-capsule')));
    await tester.tap(find.text('导入').first);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('share-controls'))), card);
    expect(tester.getRect(find.byKey(const ValueKey('share-code-capsule'))),
        capsule);
    await tester.tap(find.text('生成分享码'));
    await tester.pumpAndSettle();
    expect(requests.where((item) => item.method == 'POST').length, 1);
    expect(
        requests
            .firstWhere((item) => item.method == 'POST')
            .body
            .contains('12345678'),
        isFalse);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('销毁分享码'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '销毁'));
    await tester.pumpAndSettle();
    expect(find.text('Ab3D4e'), findsNothing);
    expect(find.text('暂无分享码'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '复制',
            ))
            .onPressed,
        isNull);
  });

  testWidgets(
      'imports a code, opens a read only schedule and compares with mine',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final importStore = _MemoryImports();
    const term = AcademicTerm(
      yearCode: '2026',
      termCode: '3',
      academicYearName: '2026-2027',
      termName: '秋',
      studentName: '本人',
      studentId: '12345678',
      className: '一班',
    );
    final own = AcademicSchedule(
      term: term,
      sessions: const [],
      untimedCourses: const [],
      fetchedAt: DateTime.utc(2026, 10, 8),
      teachingWeekCount: 16,
    );
    final snapshot = {
      'version': 1,
      'term': {
        'yearCode': '2026',
        'termCode': '3',
        'academicYearName': '2026-2027',
        'termName': '秋'
      },
      'sessions': [
        {
          'courseName': '线性代数',
          'teacherName': '张老师',
          'campus': '宝山',
          'location': '一教',
          'credit': '3',
          'weekday': 1,
          'sections': [1, 2],
          'weeks': [for (var week = 1; week <= 16; week++) week]
        }
      ],
      'untimedCourses': []
    };
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/shares/resolve') {
        expect(jsonDecode(request.body)['code'], 'ABC123');
        return http.Response.bytes(
            utf8.encode(jsonEncode({
              'success': true,
              'data': {'snapshot': snapshot, 'digest': 'digest-one'}
            })),
            200);
      }
      return http.Response('{}', 404);
    });
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
      home: ScheduleSharePage(
        ownSchedule: own,
        ownWeekState: ScheduleWeekState(
            currentWeek: 1, anchorMonday: DateTime(2026, 8, 31)),
        scheduleRepository: AcademicScheduleRepository(),
        identityService: null,
        shareApi: ScheduleShareApi(client: client),
        importStore: importStore,
        calendarStore: _MemoryCalendar(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('分享与导入'), findsOneWidget);
    await tester.tap(find.text('导入').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'ABC123');
    await tester.tap(find.text('导入').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .focusNode!
            .hasFocus,
        isFalse);
    expect(find.text('课表 1'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    final menu = tester
        .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>));
    expect(menu.color, ShuYoThemes.byId(ShuYoThemes.defaultId).colors.surface);
    expect(menu.surfaceTintColor, Colors.transparent);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '同学课表');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('同学课表'), findsOneWidget);
    final importField = tester.widget<TextField>(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'ABC123');
    expect(importField.focusNode!.hasFocus, isTrue);
    await tester.tap(find.text('同学课表'));
    await tester.pumpAndSettle();
    expect(importField.focusNode!.hasFocus, isFalse);
    expect(find.text('线性代数'), findsWidgets);
    expect(find.byTooltip('设置开学日期'), findsNothing);
    expect(find.byTooltip('比较'), findsOneWidget);
    expect(find.byIcon(Icons.join_inner), findsOneWidget);
    await tester.tap(find.text('线性代数').first);
    await tester.pumpAndSettle();
    expect(find.text('周一 第1-2节 1-16周'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
    expect(find.text('删除'), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(importField.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.text('同学课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('比较'));
    await tester.pumpAndSettle();
    expect(find.text('我的课表'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '比较'))
            .onPressed,
        isNull);
    await tester.tap(find.text('我的课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '比较'));
    await tester.pumpAndSettle();
    expect(find.text('空余时段'), findsOneWidget);
    expect(find.text('线性代数'), findsNothing);
    final blue = ShuYoThemes.byId(ShuYoThemes.defaultId)
        .colors
        .accent
        .withValues(alpha: 0.58);
    expect(
        tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)).any(
              (widget) =>
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color == blue,
            ),
        isTrue);
  });
}

class _MemoryImports extends ImportedScheduleStore {
  final values = <ImportedSchedule>[];

  @override
  Future<List<ImportedSchedule>> list() async => [...values];

  @override
  Future<ImportedSchedule> save(SharedScheduleResult result) async {
    final item = ImportedSchedule(
      id: 'import-one',
      name: '课表 1',
      digest: result.digest,
      snapshot: result.snapshot,
      importedAt: DateTime.utc(2026, 10, 8),
    );
    values.add(item);
    return item;
  }

  @override
  Future<void> rename(ImportedSchedule item, String name) async {
    final index = values.indexWhere((value) => value.id == item.id);
    values[index] = item.copyWith(name: name);
  }
}

class _MemoryCalendar extends TermCalendarStore {
  @override
  Future<void> save(String termKey, DateTime date) async {}
}

class _FakeIdentity extends StudentIdentityService {
  _FakeIdentity()
      : super(httpClient: MockClient((_) async => http.Response('{}', 200)));
  final session = StudentIdentitySession(
    token: 'test-student-token',
    studentId: '12345678',
    maskedStudentId: '12****78',
    expiresAt: DateTime.utc(2030),
  );

  @override
  Future<StudentIdentitySession?> checkCurrentSession() async => session;

  @override
  Future<StudentIdentitySession?> loadLocalSession() async => session;

  @override
  Future<bool> ensureForProtectedAction() async => true;
}
