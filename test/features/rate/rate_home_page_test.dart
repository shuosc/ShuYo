import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_review.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/course_review_repository.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/rate/rate_home_page.dart';
import 'package:shuyo/features/rate/rate_list_pages.dart';
import 'package:shuyo/features/rate/rate_widgets.dart';

RateUnit _unit(String id, String name, double? average, int count) =>
    RateUnit.fromJson({
      'id': id,
      'role': 'lead',
      'average': average,
      'reviewCount': count,
      'course': {'id': id, 'name': name, 'college': '测试学院', 'credits': '2'},
      'teacher': {'id': 'teacher-$id', 'name': '测试教师'},
    });

RateScheduleMatch _scheduleMatch(RateUnit unit) => RateScheduleMatch(
      course: RateScheduleCourse(
        teachingClassId: 'class-${unit.id}',
        courseCode: unit.course.id,
        courseName: unit.course.name,
        teacherName: unit.teacher.name,
      ),
      result: RateLookupResult(
        status: RateLookupStatus.unit,
        unit: unit,
        courseId: '',
        units: const [],
        query: '',
      ),
    );

final _scheduleUnit = _unit('schedule', '本学期评分课程', 8.7, 9);

final _recent = _unit('recent', '最近评价课程', 8.6, 11);
final _rankings = [
  RateRankingPreview(
    key: 'general',
    title: '通识课',
    total: 1,
    items: [_unit('general', '通识课程', 9.0, 17)],
  ),
  RateRankingPreview(
    key: 'core_general',
    title: '核心通识课',
    total: 1,
    items: [_unit('core_general', '核心通识课程', 9.0, 19)],
  ),
  RateRankingPreview(
    key: 'pe',
    title: '体育',
    total: 1,
    items: [_unit('pe', '体育课程', 8.0, 23)],
  ),
  RateRankingPreview(
    key: 'public',
    title: '公共基础课',
    total: 1,
    items: [_unit('public', '公共基础课程', 7.0, 29)],
  ),
];

class _FakeCourseReviewRepository extends CourseReviewRepository {
  _FakeCourseReviewRepository({
    this.matches = const [],
    this.failPreferenceWrites = false,
    this.matchLoader,
    super.preferencesLoader,
  }) : super(
          studentIdentityService: StudentIdentityService(),
          scheduleRepository: AcademicScheduleRepository(),
        );

  List<RateRankingPreview> rankings = _rankings;
  List<RateScheduleMatch> matches;
  final Future<List<RateScheduleMatch>> Function()? matchLoader;
  int homeCalls = 0;
  int matchCalls = 0;
  final bool failPreferenceWrites;

  @override
  Future<RateHome> home() async {
    homeCalls++;
    return RateHome(
      recent: [_recent],
      rankings: rankings,
      colleges: const [],
    );
  }

  @override
  Future<List<RateScheduleMatch>> matchSchedule() async {
    matchCalls++;
    return matchLoader == null ? matches : await matchLoader!();
  }

  @override
  Future<void> saveScheduleCollapsed(bool collapsed) async {
    if (failPreferenceWrites) throw StateError('preferences unavailable');
    await super.saveScheduleCollapsed(collapsed);
  }

  @override
  Future<RateRankingResult> ranking(String category,
      {String sub = '', int page = 1}) async {
    final ranking = rankings.singleWhere((item) => item.key == category);
    return RateRankingResult(
      key: ranking.key,
      title: ranking.title,
      subcategories: const [],
      total: ranking.total,
      page: page,
      pageSize: 20,
      items: ranking.items,
    );
  }
}

Future<void> _pumpHome(
  WidgetTester tester, {
  _FakeCourseReviewRepository? repository,
  bool settle = true,
  bool disableAnimations = false,
  bool active = false,
  int scheduleRevision = 0,
}) async {
  tester.view.physicalSize = const Size(420, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = repository ?? _FakeCourseReviewRepository();
  addTearDown(repo.dispose);
  await tester.pumpWidget(MaterialApp(
    builder: disableAnimations
        ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
        : null,
    home: Scaffold(
      body: RateHomePage(
        repository: repo,
        active: active,
        scheduleRevision: scheduleRevision,
      ),
    ),
  ));
  if (settle) await tester.pumpAndSettle();
}

double _scheduleArrowTurns(WidgetTester tester) => tester
    .widget<RotationTransition>(find.descendant(
      of: find.byKey(const ValueKey('rate-schedule-toggle')),
      matching: find.byType(RotationTransition),
    ))
    .turns
    .value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'homepage rankings match recent cards and show stars without counts',
      (tester) async {
    await _pumpHome(tester);
    final recentCard = find.ancestor(
      of: find.text(_recent.course.name),
      matching: find.byType(RateCard),
    );
    final recentSurface = tester.widget<Material>(
      find.descendant(of: recentCard, matching: find.byType(Material)),
    );
    expect(tester.getSize(recentCard), const Size(156, 112));
    for (final ranking in _rankings) {
      expect(find.text(ranking.title), findsOneWidget);
      final unit = ranking.items.single;
      final card = find.ancestor(
        of: find.text('1  ${unit.course.name}'),
        matching: find.byType(RateCard),
      );
      expect(tester.getSize(card), tester.getSize(recentCard));
      final surface = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)),
      );
      expect(surface.shape, recentSurface.shape);
      expect(surface.color, recentSurface.color);
      expect(
        find.descendant(of: card, matching: find.byType(RateStars)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text(rateScoreText(unit.average)),
        ),
        findsOneWidget,
      );
    }
    expect(find.textContaining('份'), findsNothing);
    expect(find.text('新生研讨课'), findsNothing);
    expect(tester.getTopLeft(find.text('通识课')).dy,
        lessThan(tester.getTopLeft(find.text('核心通识课')).dy));
    expect(tester.getTopLeft(find.text('核心通识课')).dy,
        lessThan(tester.getTopLeft(find.text('体育')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('homepage renders server categories without filtering seminar',
      (tester) async {
    final repo = _FakeCourseReviewRepository()
      ..rankings = [
        RateRankingPreview(
          key: 'seminar',
          title: '服务端下发的栏目',
          total: 1,
          items: [_unit('seminar', '服务端课程', 9.0, 31)],
        ),
      ];
    await _pumpHome(tester, repository: repo);
    expect(find.text('服务端下发的栏目'), findsOneWidget);
    expect(find.text('1  服务端课程'), findsOneWidget);
    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('服务端下发的栏目'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester cards show stars only when a score is available',
      (tester) async {
    final unrated = _unit('unrated', '本学期暂无评价课程', null, 0);
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(matches: [
          _scheduleMatch(_scheduleUnit),
          _scheduleMatch(unrated),
        ]));
    final scoredCard = find.ancestor(
      of: find.text(_scheduleUnit.course.name),
      matching: find.byType(RateCard),
    );
    final stars = find.descendant(
      of: scoredCard,
      matching: find.byType(RateStars),
    );
    expect(stars, findsOneWidget);
    expect(tester.widget<RateStars>(stars).average, _scheduleUnit.average);
    expect(
      find.descendant(of: scoredCard, matching: find.text('8.7')),
      findsOneWidget,
    );
    final unratedCard = find.ancestor(
      of: find.text(unrated.course.name),
      matching: find.byType(RateCard),
    );
    expect(
      find.descendant(of: unratedCard, matching: find.byType(RateStars)),
      findsNothing,
    );
    expect(
      find.descendant(of: unratedCard, matching: find.text('暂无评价')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the entire semester header toggles without ink feedback',
      (tester) async {
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository);
    final header = find.byKey(const ValueKey('rate-schedule-toggle'));
    final ink = tester.widget<InkWell>(header);
    expect(ink.splashFactory, same(NoSplash.splashFactory));
    for (final state in [
      WidgetState.pressed,
      WidgetState.hovered,
      WidgetState.focused,
    ]) {
      expect(ink.overlayColor!.resolve({state}), Colors.transparent);
    }
    expect(
      find.descendant(of: header, matching: find.byType(IconButton)),
      findsNothing,
    );

    final bounds = tester.getRect(header);
    final points = [
      bounds.centerLeft + const Offset(2, 0),
      tester.getCenter(find.text('课表课程')),
      bounds.center,
      tester.getCenter(find.byIcon(Icons.expand_more)),
      bounds.centerRight - const Offset(2, 0),
    ];
    for (var index = 0; index < points.length; index++) {
      await tester.tapAt(points[index]);
      await tester.pumpAndSettle();
      final collapsed = index.isEven;
      expect(await repository.loadScheduleCollapsed(), collapsed);
      expect(find.text(_scheduleUnit.course.name),
          collapsed ? findsNothing : findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester content and arrow animate in both directions',
      (tester) async {
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(
          matches: [_scheduleMatch(_scheduleUnit)],
        ));
    final content = find.byKey(const ValueKey('rate-schedule-content'));
    final fullHeight = tester.getSize(content).height;
    expect(fullHeight, greaterThan(0));
    expect(_scheduleArrowTurns(tester), 0.5);

    await tester.tap(find.text('课表课程'));
    await tester.pump();
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSize(content).height, inExclusiveRange(0, fullHeight));
    expect(_scheduleArrowTurns(tester), inExclusiveRange(0, 0.5));
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    final pointerGuard = tester.widget<IgnorePointer>(find.descendant(
      of: content,
      matching: find.byType(IgnorePointer),
    ));
    expect(pointerGuard.ignoring, isTrue);
    await tester.pumpAndSettle();
    expect(tester.getSize(content).height, 0);
    expect(_scheduleArrowTurns(tester), 0);
    expect(find.text(_scheduleUnit.course.name), findsNothing);

    await tester.tap(find.text('课表课程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSize(content).height, inExclusiveRange(0, fullHeight));
    expect(_scheduleArrowTurns(tester), inExclusiveRange(0, 0.5));
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.getSize(content).height, fullHeight);
    expect(_scheduleArrowTurns(tester), 0.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester animation reverses smoothly when toggled again',
      (tester) async {
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository);
    final content = find.byKey(const ValueKey('rate-schedule-content'));
    final fullHeight = tester.getSize(content).height;
    await tester.tap(find.text('课表课程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final partialHeight = tester.getSize(content).height;
    final partialTurns = _scheduleArrowTurns(tester);
    expect(partialHeight, inExclusiveRange(0, fullHeight));

    await tester.tap(find.text('课表课程'));
    await tester.pump();
    expect(tester.getSize(content).height, closeTo(partialHeight, 0.01));
    expect(_scheduleArrowTurns(tester), closeTo(partialTurns, 0.001));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getSize(content).height,
        inExclusiveRange(partialHeight, fullHeight));
    expect(_scheduleArrowTurns(tester), inExclusiveRange(partialTurns, 0.5));
    await tester.pumpAndSettle();
    expect(tester.getSize(content).height, fullHeight);
    expect(await repository.loadScheduleCollapsed(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester toggle respects the reduced motion setting',
      (tester) async {
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(
          matches: [_scheduleMatch(_scheduleUnit)],
        ),
        disableAnimations: true);
    final content = find.byKey(const ValueKey('rate-schedule-content'));
    final fullHeight = tester.getSize(content).height;
    await tester.tap(find.text('课表课程'));
    await tester.pump();
    expect(tester.getSize(content).height, 0);
    expect(_scheduleArrowTurns(tester), 0);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    await tester.tap(find.text('课表课程'));
    await tester.pump();
    expect(tester.getSize(content).height, fullHeight);
    expect(_scheduleArrowTurns(tester), 0.5);
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester collapse state survives refresh and page recreation',
      (tester) async {
    final matches = [_scheduleMatch(_scheduleUnit)];
    final repository = _FakeCourseReviewRepository(matches: matches);
    await _pumpHome(tester, repository: repository);
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    await tester.tap(find.byTooltip('折叠课表课程'));
    await tester.pumpAndSettle();
    expect(find.text('课表课程'), findsOneWidget);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(find.byTooltip('展开课表课程'), findsOneWidget);
    expect(await repository.loadScheduleCollapsed(), isTrue);

    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text(_scheduleUnit.course.name), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(matches: matches));
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    await tester.tap(find.byTooltip('展开课表课程'));
    await tester.pumpAndSettle();
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(await repository.loadScheduleCollapsed(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(matches: matches));
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(find.byTooltip('折叠课表课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved collapse is restored before semester cards are displayed',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final repository = _FakeCourseReviewRepository();
    addTearDown(repository.dispose);
    await repository.saveScheduleCollapsed(true);
    final ready = Completer<SharedPreferences>();
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(
          matches: [_scheduleMatch(_scheduleUnit)],
          preferencesLoader: () => ready.future,
        ),
        settle: false);
    await tester.pump();
    expect(find.text('课表课程'), findsNothing);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    ready.complete(preferences);
    await tester.pumpAndSettle();
    expect(find.text('课表课程'), findsOneWidget);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(find.byTooltip('展开课表课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semester cards default to expanded when preferences cannot load',
      (tester) async {
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(
          matches: [_scheduleMatch(_scheduleUnit)],
          preferencesLoader: () async => throw StateError('unavailable'),
        ));
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(find.byTooltip('折叠课表课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed collapse persistence shows an error and keeps the toggle usable',
      (tester) async {
    await _pumpHome(tester,
        repository: _FakeCourseReviewRepository(
          matches: [_scheduleMatch(_scheduleUnit)],
          failPreferenceWrites: true,
        ));
    await tester.tap(find.byTooltip('折叠课表课程'));
    await tester.pumpAndSettle();
    expect(find.text('折叠状态保存失败，下次进入可能不会保留'), findsOneWidget);
    expect(find.byTooltip('展开课表课程'), findsOneWidget);
    await tester.tap(find.byTooltip('展开课表课程'));
    await tester.pumpAndSettle();
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule changes refresh on entry within the freshness window',
      (tester) async {
    final updated = _unit('history', '正在查看的历史课程', 8.0, 2);
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository, active: true);
    await _pumpHome(tester, repository: repository);
    repository.matches = [_scheduleMatch(updated)];
    await _pumpHome(tester, repository: repository, scheduleRevision: 1);
    expect(repository.matchCalls, 1);
    expect(find.text(_scheduleUnit.course.name), findsNothing);

    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.text(updated.course.name), findsOneWidget);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(repository.matchCalls, 2);
    expect(repository.homeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged schedules do not reload on a quick tab round trip',
      (tester) async {
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository, active: true);
    await _pumpHome(tester, repository: repository);
    await _pumpHome(tester, repository: repository, active: true);
    expect(repository.matchCalls, 1);
    expect(repository.homeCalls, 1);
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-term course edits refresh without resetting collapse state',
      (tester) async {
    final updated = _unit('edited', '本地编辑后的课程', 8.0, 2);
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository, active: true);
    await tester.tap(find.byTooltip('折叠课表课程'));
    await tester.pumpAndSettle();
    repository.matches = [_scheduleMatch(updated)];
    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.byTooltip('展开课表课程'), findsOneWidget);
    expect(find.text(updated.course.name), findsNothing);
    expect(repository.homeCalls, 1);
    await tester.tap(find.byTooltip('展开课表课程'));
    await tester.pumpAndSettle();
    expect(find.text(updated.course.name), findsOneWidget);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty selected schedule clears the previous course section',
      (tester) async {
    final repository = _FakeCourseReviewRepository(
      matches: [_scheduleMatch(_scheduleUnit)],
    );
    await _pumpHome(tester, repository: repository, active: true);
    repository.matches = const [];
    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.text('课表课程'), findsNothing);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(repository.homeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late old matches cannot block or overwrite the new schedule',
      (tester) async {
    final oldMatches = Completer<List<RateScheduleMatch>>();
    final updated = _unit('latest', '最新选择的课程', 8.0, 2);
    var first = true;
    final repository = _FakeCourseReviewRepository(matchLoader: () {
      if (first) {
        first = false;
        return oldMatches.future;
      }
      return Future.value([_scheduleMatch(updated)]);
    });
    await _pumpHome(tester,
        repository: repository, active: true, settle: false);
    await tester.pumpAndSettle();
    expect(find.text('最近评价'), findsOneWidget);
    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.text(updated.course.name), findsOneWidget);

    oldMatches.complete([_scheduleMatch(_scheduleUnit)]);
    await tester.pumpAndSettle();
    expect(find.text(updated.course.name), findsOneWidget);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(repository.homeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed matches after switching clear old courses and retry on entry',
      (tester) async {
    var fail = false;
    final repository = _FakeCourseReviewRepository(matchLoader: () async {
      if (fail) throw StateError('lookup unavailable');
      return [_scheduleMatch(_scheduleUnit)];
    });
    await _pumpHome(tester, repository: repository, active: true);
    fail = true;
    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.text(_scheduleUnit.course.name), findsNothing);
    expect(find.text('课表课程'), findsNothing);
    fail = false;
    await _pumpHome(tester, repository: repository, scheduleRevision: 1);
    await _pumpHome(tester,
        repository: repository, active: true, scheduleRevision: 1);
    expect(find.text(_scheduleUnit.course.name), findsOneWidget);
    expect(repository.matchCalls, 3);
    expect(repository.homeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  for (var index = 0; index < _rankings.length; index++) {
    final ranking = _rankings[index];
    testWidgets('${ranking.title} list retains review counts', (tester) async {
      await _pumpHome(tester);
      final more = find.byType(RateMoreButton).at(index);
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.byType(RateRankingPage), findsOneWidget);
      expect(
        find.text('${ranking.items.single.reviewCount} 份评价'),
        findsOneWidget,
      );
      expect(find.byType(RateScoreTrailing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
