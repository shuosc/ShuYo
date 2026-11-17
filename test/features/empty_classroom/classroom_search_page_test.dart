import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/core/classroom_url_resolver.dart';
import 'package:shuyo/data/models/classroom.dart';
import 'package:shuyo/data/repositories/classroom_repository.dart';
import 'package:shuyo/features/empty_classroom/classroom_search_page.dart';

void main() {
  setUp(() => ClassroomUrlResolver.configure(useWebVpn: false));
  tearDown(() => ClassroomUrlResolver.configure(useWebVpn: false));

  Future<void> open(
    WidgetTester tester,
    _SearchRepository repository, {
    String campus = '宝山',
    ClassroomSearchOptions? options,
    DateTime? initialDate,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: ClassroomSearchPage(
        repository: repository,
        options: options ?? _SearchRepository.options,
        // 2026-09-01 为周二（weekday == 2），第 1 周。
        initialDate: initialDate ?? DateTime(2026, 9, 1),
        initialCampus: campus,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('searches via the text field and adjacent search button',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    final submit = find.byKey(const ValueKey('classroom-search-submit'));
    expect(find.byType(TextField), findsOneWidget);
    expect(submit, findsOneWidget);
    expect(tester.widget<IconButton>(submit).onPressed, isNull);
    expect(repository.searchCalls, isEmpty);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump();
    expect(tester.widget<IconButton>(submit).onPressed, isNotNull);
    expect(
        find.byKey(const ValueKey('classroom-search-results')), findsNothing);

    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(repository.searchCalls.single.keyword, '高等数学');
    expect(
        find.byKey(const ValueKey('classroom-search-results')), findsOneWidget);
    expect(find.text('高等数学'), findsWidgets);
    expect(find.textContaining('门课'), findsNothing);
    expect(find.textContaining('找到 '), findsNothing);
  });

  testWidgets('groups hits by building then by section with two sticky levels',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('classroom-search-submit')));
    await tester.pumpAndSettle();

    // 一级吸顶「宝山校区 A楼」，二级吸顶「1-2节」。
    expect(find.text('宝山校区 A楼'), findsOneWidget);
    expect(find.text('1-2节'), findsOneWidget);
  });

  testWidgets('filters ES results locally by selected date and buildings',
      (tester) async {
    final repository = _SearchRepository(
      hitsByPage: {
        0: const ClassroomCourseSearchResult(
          totalHits: 4,
          hits: [
            ClassroomEsCourseHit(
              courseName: '高等数学',
              teacherName: '张老师',
              roomName: 'A101',
              dayInWeek: 2,
              startSection: 1,
              endSection: 2,
              startWeek: 1,
              endWeek: 16,
            ),
            // 周三课程，不应在周二显示。
            ClassroomEsCourseHit(
              courseName: '高等数学(周三)',
              teacherName: '赵老师',
              roomName: 'A102',
              dayInWeek: 3,
              startSection: 1,
              endSection: 2,
              startWeek: 1,
              endWeek: 16,
            ),
            // 第 5-8 周课程，不应在第 1 周显示。
            ClassroomEsCourseHit(
              courseName: '高等数学(后半程)',
              teacherName: '钱老师',
              roomName: 'A103',
              dayInWeek: 2,
              startSection: 3,
              endSection: 3,
              startWeek: 5,
              endWeek: 8,
            ),
            // 延长校区课程，默认仅选宝山时不显示。
            ClassroomEsCourseHit(
              courseName: '高等数学(延长)',
              teacherName: '孙老师',
              roomName: '行健201',
              dayInWeek: 2,
              startSection: 1,
              endSection: 2,
              startWeek: 1,
              endWeek: 16,
            ),
          ],
        ),
      },
    );
    await open(tester, repository);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('classroom-search-submit')));
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsWidgets);
    expect(find.text('高等数学(周三)'), findsNothing);
    expect(find.text('高等数学(后半程)'), findsNothing);
    expect(find.text('高等数学(延长)'), findsNothing);

    // 勾选延长校区后立即出现延长的结果，无需重新请求。
    final callsBefore = repository.searchCalls.length;
    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('classroom-campus-check-延长')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    expect(repository.searchCalls.length, callsBefore);
    expect(find.text('高等数学(延长)'), findsOneWidget);
  });

  testWidgets('loads next page seamlessly when scrolling near bottom',
      (tester) async {
    final page0Hits = [
      for (var i = 1; i <= 16; i++)
        ClassroomEsCourseHit(
          courseName: '课程$i',
          teacherName: '教师$i',
          roomName: 'A${100 + i}',
          dayInWeek: 2,
          startSection: 1,
          endSection: 2,
          startWeek: 1,
          endWeek: 16,
        ),
    ];
    final page1Hits = [
      const ClassroomEsCourseHit(
        courseName: '第二页课程',
        teacherName: '李老师',
        roomName: 'A201',
        dayInWeek: 2,
        startSection: 3,
        endSection: 3,
        startWeek: 1,
        endWeek: 16,
      ),
    ];
    final repository = _SearchRepository(
      hitsByPage: {
        0: ClassroomCourseSearchResult(totalHits: 17, hits: page0Hits),
        16: ClassroomCourseSearchResult(totalHits: 17, hits: page1Hits),
      },
    );
    await open(tester, repository);

    await tester.enterText(find.byType(TextField), '课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('classroom-search-submit')));
    await tester.pumpAndSettle();

    expect(repository.searchCalls.map((c) => c.startPage), [0]);
    expect(find.text('第二页课程'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('classroom-search-results')),
      const Offset(0, -1500),
    );
    await tester.pumpAndSettle();

    expect(repository.searchCalls.map((c) => c.startPage), [0, 16]);
    expect(find.text('第二页课程'), findsOneWidget);
  });

  testWidgets('an empty keyword leaves the result area blank', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    expect(find.textContaining('输入课程名'), findsNothing);
    expect(find.textContaining('范围：'), findsNothing);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('classroom-search-submit')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('classroom-search-results')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-search-clear')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('classroom-search-results')), findsNothing);
  });

  testWidgets('the app bar owns the date and building filters', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    expect(find.byKey(const ValueKey('classroom-search-date')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('classroom-search-filter')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-search-date')));
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
    expect(find.text('自定时间'), findsOneWidget);

    await tester.tap(find.text('明天'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-search-date')), findsOneWidget);
  });

  testWidgets('the filter groups three campuses like the announcement menu',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    expect(find.text('宝山校区'), findsOneWidget);
    expect(find.text('延长校区'), findsOneWidget);
    expect(find.text('嘉定校区'), findsOneWidget);
    expect(find.text('宝山东区校区'), findsNothing);

    for (final campus in const ['宝山', '延长', '嘉定']) {
      final header = tester.widget<Checkbox>(
          find.byKey(ValueKey('classroom-campus-check-$campus')));
      expect(header.tristate, isTrue);
    }

    expect(
        find.byKey(const ValueKey('classroom-building-303')), findsOneWidget);
    expect(find.byKey(const ValueKey('classroom-building-399')), findsNothing);
    expect(find.byKey(const ValueKey('classroom-building-607')), findsNothing);
    expect(find.byKey(const ValueKey('classroom-building-check-303')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-campus-延长')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('classroom-building-399')), findsOneWidget);
  });

  testWidgets('a campus header collapses its buildings', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('classroom-building-303')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-campus-宝山')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classroom-building-303')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('classroom-campus-宝山')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('classroom-building-303')), findsOneWidget);
  });

  testWidgets('clearing every campus asks the user to pick one',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('classroom-campus-check-宝山')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    expect(find.text('没有选择教学楼'), findsOneWidget);
  });

  testWidgets('paired buildings share a row but keep their own checkboxes',
      (tester) async {
    final repository = _PairedRepository();
    await open(tester, repository, options: _PairedRepository.options);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    final a =
        tester.getCenter(find.byKey(const ValueKey('classroom-building-303')));
    final aj =
        tester.getCenter(find.byKey(const ValueKey('classroom-building-325')));
    expect(a.dy, aj.dy);
    expect(a.dx, lessThan(aj.dx));

    bool? checked(int id) => tester
        .widget<Checkbox>(find.byKey(ValueKey('classroom-building-check-$id')))
        .value;

    expect(checked(303), isTrue);
    expect(checked(325), isTrue);
    await tester
        .tap(find.byKey(const ValueKey('classroom-building-check-303')));
    await tester.pumpAndSettle();
    expect(checked(303), isFalse);
    expect(checked(325), isTrue);

    Text titleOf(int id) => tester.widget<Text>(find.descendant(
          of: find.byKey(ValueKey('classroom-building-$id')),
          matching: find.byType(Text),
        ));
    expect(titleOf(303).maxLines, 1);
    expect(titleOf(325).maxLines, 1);
    expect(titleOf(220).maxLines, 2);
  });
}

class _SearchRepository extends ClassroomRepository {
  _SearchRepository({Map<int, ClassroomCourseSearchResult>? hitsByPage})
      : _hitsByPage = hitsByPage ??
            const {
              0: ClassroomCourseSearchResult(
                totalHits: 2,
                hits: [
                  ClassroomEsCourseHit(
                    courseName: '高等数学',
                    teacherName: '张老师',
                    roomName: 'A101',
                    dayInWeek: 2,
                    startSection: 1,
                    endSection: 2,
                    startWeek: 1,
                    endWeek: 16,
                  ),
                  ClassroomEsCourseHit(
                    courseName: '线性代数',
                    teacherName: '王老师',
                    roomName: 'A103',
                    dayInWeek: 2,
                    startSection: 3,
                    endSection: 3,
                    startWeek: 1,
                    endWeek: 16,
                  ),
                ],
              ),
            };

  static const options = ClassroomSearchOptions(
    buildings: [
      ClassroomBuilding(id: 303, name: 'A楼', campusId: 3, campusName: '宝山'),
      ClassroomBuilding(id: 399, name: '行健楼', campusId: 398, campusName: '延长'),
      ClassroomBuilding(
          id: 607, name: '第一教学楼', campusId: 574, campusName: '嘉定'),
    ],
    sections: [
      ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
      ClassroomSection(index: 2, startTime: '08:55', endTime: '09:40'),
      ClassroomSection(index: 3, startTime: '10:00', endTime: '10:45'),
    ],
  );

  final Map<int, ClassroomCourseSearchResult> _hitsByPage;
  final searchCalls = <({String keyword, int startPage, int pageSize})>[];

  @override
  ClassroomSearchOptions? get optionsSnapshot => options;

  @override
  Future<ClassroomSearchOptions> loadOptions({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async =>
      options;

  @override
  Future<ClassroomSemesterInfo?> loadCurrentSemester({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async =>
      ClassroomSemesterInfo(week: 1, realDate: DateTime(2026, 9, 1));

  @override
  Future<ClassroomCourseSearchResult> searchCourses({
    required String keyword,
    int startPage = 0,
    int pageSize = 50,
    ClassroomAccessMode? accessMode,
  }) async {
    searchCalls.add((
      keyword: keyword,
      startPage: startPage,
      pageSize: pageSize,
    ));
    return _hitsByPage[startPage] ??
        const ClassroomCourseSearchResult(totalHits: 0, hits: []);
  }
}

/// 宝山里同时有主楼和阶梯楼，用来验证筛选器把它们并到同一行。
class _PairedRepository extends _SearchRepository {
  static const options = ClassroomSearchOptions(
    buildings: [
      ClassroomBuilding(id: 303, name: 'A楼', campusId: 3, campusName: '宝山'),
      ClassroomBuilding(id: 325, name: 'AJ楼', campusId: 3, campusName: '宝山'),
      ClassroomBuilding(id: 122, name: 'B楼', campusId: 3, campusName: '宝山'),
      ClassroomBuilding(id: 328, name: 'BJ楼', campusId: 3, campusName: '宝山'),
      ClassroomBuilding(id: 220, name: 'EJ楼', campusId: 3, campusName: '宝山'),
    ],
    sections: [
      ClassroomSection(index: 1, startTime: '08:00', endTime: '08:45'),
      ClassroomSection(index: 2, startTime: '08:55', endTime: '09:40'),
      ClassroomSection(index: 3, startTime: '10:00', endTime: '10:45'),
    ],
  );

  @override
  ClassroomSearchOptions? get optionsSnapshot => options;
}
