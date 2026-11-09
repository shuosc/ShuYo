import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: ClassroomSearchPage(
        repository: repository,
        options: options ?? _SearchRepository.options,
        initialDate: DateTime(2026, 9, 1),
        initialCampus: campus,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('searches as the user types without a submit button',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    // 没有“开始搜索”按钮，输入即触发。
    expect(find.byTooltip('开始搜索'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsWidgets);
    expect(find.text('找到 2 条 · 1 门课'), findsOneWidget);
  });

  testWidgets('groups hits by building then by section with two sticky levels',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    // 一级吸顶「宝山校区 A楼」，二级吸顶「1-2节」。
    expect(find.text('宝山校区 A楼'), findsOneWidget);
    expect(find.text('1-2节'), findsOneWidget);
  });

  testWidgets('matches course name, teacher and room number', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    // 关键词本身也会出现在输入框里，因此只在结果区里查文本。
    Finder inResults(String text) => find.descendant(
          of: find.byKey(const ValueKey('classroom-search-results')),
          matching: find.text(text),
        );

    Future<void> search(String keyword) async {
      await tester.enterText(find.byType(TextField), keyword);
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pumpAndSettle();
    }

    await search('张老师');
    expect(inResults('高等数学'), findsOneWidget);
    expect(inResults('线性代数'), findsNothing);

    await search('A103');
    expect(inResults('线性代数'), findsOneWidget);
    expect(inResults('高等数学'), findsNothing);

    await search('线性代数');
    expect(inResults('线性代数'), findsOneWidget);
  });

  testWidgets('an empty keyword leaves the result area blank', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    // 搜索框下方不再有说明小字。
    expect(find.textContaining('输入课程名'), findsNothing);
    expect(find.textContaining('范围：'), findsNothing);

    await tester.enterText(find.byType(TextField), '高等数学');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(find.text('找到 2 条 · 1 门课'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('classroom-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('找到 2 条 · 1 门课'), findsNothing);
  });

  testWidgets('the app bar owns the date and building filters', (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    expect(find.byKey(const ValueKey('classroom-search-date')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('classroom-search-filter')), findsOneWidget);

    // 时间筛选是校园卡同款的三项。
    await tester.tap(find.byKey(const ValueKey('classroom-search-date')));
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
    expect(find.text('自定时间'), findsOneWidget);

    await tester.tap(find.text('明天'));
    await tester.pumpAndSettle();
    // 换日期会重新取当天的课表。
    expect(repository.loadedBuildings, contains(303));
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
    // 东区并入宝山，所以不会单独出现。
    expect(find.text('宝山东区校区'), findsNothing);

    // 每个校区一个三态勾选框（公告搜索的分组头同款）。
    for (final campus in const ['宝山', '延长', '嘉定']) {
      final header = tester.widget<Checkbox>(
          find.byKey(ValueKey('classroom-campus-check-$campus')));
      expect(header.tristate, isTrue);
    }

    // 默认只展开当前校区（宝山），另外两个校区收起。
    expect(
        find.byKey(const ValueKey('classroom-building-303')), findsOneWidget);
    expect(find.byKey(const ValueKey('classroom-building-399')), findsNothing);
    expect(find.byKey(const ValueKey('classroom-building-607')), findsNothing);
    expect(find.byKey(const ValueKey('classroom-building-check-303')),
        findsOneWidget);

    // 展开另一个校区后才出现它的楼。
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

  testWidgets('toggling a campus selects and clears all its buildings',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    // 分组头的勾选框单独管全组，点整行只会折叠。
    await tester.tap(find.byKey(const ValueKey('classroom-campus-check-延长')));
    await tester.pumpAndSettle();
    // 关闭浮层时把勾选结果交回页面。
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    // 宝山 + 延长 都参与，嘉定没有。
    expect(repository.loadedBuildings, containsAll(<int>[303, 399]));
    expect(repository.loadedBuildings, isNot(contains(607)));
  });

  testWidgets('clearing every campus asks the user to pick one',
      (tester) async {
    final repository = _SearchRepository();
    await open(tester, repository);
    // 打开页面时已经按默认校区取过一次课表。
    final loadsBefore = repository.loadedBuildings.length;

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('classroom-campus-check-宝山')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 400));
    await tester.pumpAndSettle();

    // 一栋都没选时不再发请求，而是提示去筛选里勾选。
    expect(repository.loadedBuildings, hasLength(loadsBefore));
    expect(find.text('没有选择教学楼'), findsOneWidget);
  });

  testWidgets('paired buildings share a row but keep their own checkboxes',
      (tester) async {
    final repository = _PairedRepository();
    await open(tester, repository, options: _PairedRepository.options);

    await tester.tap(find.byKey(const ValueKey('classroom-search-filter')));
    await tester.pumpAndSettle();

    // A楼 与 AJ楼 并排：同一行、上下位置一致。
    final a =
        tester.getCenter(find.byKey(const ValueKey('classroom-building-303')));
    final aj =
        tester.getCenter(find.byKey(const ValueKey('classroom-building-325')));
    expect(a.dy, aj.dy);
    expect(a.dx, lessThan(aj.dx));

    bool? checked(int id) => tester
        .widget<Checkbox>(find.byKey(ValueKey('classroom-building-check-$id')))
        .value;

    // 各自一个勾选框，互相不影响。
    expect(checked(303), isTrue);
    expect(checked(325), isTrue);
    await tester
        .tap(find.byKey(const ValueKey('classroom-building-check-303')));
    await tester.pumpAndSettle();
    expect(checked(303), isFalse);
    expect(checked(325), isTrue);

    // 并排的楼名只占一行：半宽单元格不足时截断而不是折行。
    Text titleOf(int id) => tester.widget<Text>(find.descendant(
          of: find.byKey(ValueKey('classroom-building-$id')),
          matching: find.byType(Text),
        ));
    expect(titleOf(303).maxLines, 1);
    expect(titleOf(325).maxLines, 1);
    // 独占一行的楼仍然允许两行。
    expect(titleOf(220).maxLines, 2);
  });
}

const _firstCourseTitle = '高等数学';

class _SearchRepository extends ClassroomRepository {
  _SearchRepository();

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

  final loadedBuildings = <int>[];

  @override
  ClassroomSearchOptions? get optionsSnapshot => options;

  @override
  Future<ClassroomSearchOptions> loadOptions(
          {bool forceRefresh = false}) async =>
      options;

  @override
  Future<ClassroomBuildingSchedule> loadBuildingDay({
    required ClassroomBuilding building,
    required DateTime date,
    bool forceRefresh = false,
  }) async {
    loadedBuildings.add(building.id);
    if (building.id != 303) {
      return ClassroomBuildingSchedule(building: building, floors: const []);
    }
    return ClassroomBuildingSchedule(
      building: building,
      floors: [
        ClassroomFloor(
          id: 1,
          name: '一层',
          rooms: [
            ClassroomRoom(
              id: 11,
              name: 'A101',
              floorName: '一层',
              fullName: 'A楼A101',
              courses: const [
                ClassroomCourse(
                  courseName: _firstCourseTitle,
                  teacherName: '张老师',
                  startSection: 1,
                  endSection: 2,
                ),
              ],
            ),
            ClassroomRoom(
              id: 12,
              name: 'A102',
              floorName: '一层',
              fullName: 'A楼A102',
              courses: const [
                ClassroomCourse(
                  courseName: _firstCourseTitle,
                  teacherName: '李老师',
                  startSection: 3,
                  endSection: 3,
                ),
              ],
            ),
            ClassroomRoom(
              id: 13,
              name: 'A103',
              floorName: '一层',
              fullName: 'A楼A103',
              courses: const [
                ClassroomCourse(
                  courseName: '线性代数',
                  teacherName: '王老师',
                  startSection: 1,
                  endSection: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );
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
