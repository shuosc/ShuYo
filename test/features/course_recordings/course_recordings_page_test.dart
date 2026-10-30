import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_timetable_view.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/course_color_label.dart';
import 'package:shuyo/shared/widgets/schedule_week_switcher.dart';

const _terms = [
  VodTerm(
      id: 5, name: '2025-2026学年第1学期', academicYear: '2025-2026', termNumber: 1),
  VodTerm(
      id: 6, name: '2025-2026学年第2学期', academicYear: '2025-2026', termNumber: 2),
  VodTerm(
      id: 7,
      name: '2026-2027学年第1学期',
      academicYear: '2026-2027',
      termNumber: 1,
      isCurrent: true),
];

const _programming = VodCourse(
  teachingClassId: 101,
  termId: 7,
  name: '程序设计',
  teacherNames: ['教师甲'],
  code: 'CS101',
);
const _electronics = VodCourse(
  teachingClassId: 102,
  termId: 7,
  name: '电路与模拟电子技术',
  teacherNames: ['教师甲'],
  code: 'EE102',
);
const _art = VodCourse(
  teachingClassId: 103,
  termId: 7,
  name: '艺术导论',
  teacherNames: ['教师乙'],
  code: 'ART103',
);
const _currentCourses = [_programming, _electronics, _art];

class _Repository extends VodRepository {
  Future<List<VodTerm>> Function(bool force)? termsLoader;
  Future<List<VodCourse>> Function(int term, bool force)? coursesLoader;
  Future<List<VodLesson>> Function(VodCourse course, bool force)? lessonsLoader;
  Future<VodPlayback> Function(VodCourse course, VodLesson lesson)?
      playbackLoader;
  final playbackRequests = <VodLesson>[];
  final progressCallbacks = <int, void Function(List<VodCourse>)>{};
  int termRequests = 0;
  int lessonRequests = 0;
  int clears = 0;
  final courseRequests = <int>[];
  final forcedCourseRequests = <bool>[];

  @override
  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) async {
    termRequests++;
    final loader = termsLoader;
    return loader == null ? _terms : await loader(forceRefresh);
  }

  @override
  Future<List<VodCourse>> loadCourses({
    required int termId,
    bool forceRefresh = false,
    void Function(List<VodCourse>)? onProgress,
  }) async {
    courseRequests.add(termId);
    forcedCourseRequests.add(forceRefresh);
    if (onProgress != null) progressCallbacks[termId] = onProgress;
    final loader = coursesLoader;
    return loader == null
        ? _currentCourses
        : await loader(termId, forceRefresh);
  }

  @override
  Future<List<VodCourse>> loadCatalog({
    required int termId,
    bool forceRefresh = false,
    void Function(List<VodCourse>)? onProgress,
  }) =>
      loadCourses(
          termId: termId, forceRefresh: forceRefresh, onProgress: onProgress);

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
          {bool forceRefresh = false}) =>
      loadLessons(course, forceRefresh: forceRefresh);

  @override
  Future<List<VodLesson>> loadLessons(
    VodCourse course, {
    bool forceRefresh = false,
  }) async {
    lessonRequests++;
    return await lessonsLoader?.call(course, forceRefresh) ?? [];
  }

  @override
  Future<VodPlayback> preparePlayback(
      {required VodCourse course, required VodLesson lesson}) {
    playbackRequests.add(lesson);
    return playbackLoader?.call(course, lesson) ??
        Future.error(const VodPermissionException());
  }

  @override
  void clear() => clears++;
}

class _Auth extends VodAuthService {
  int sessionClears = 0;

  @override
  Future<void> clearSession({bool? useWebVpn}) async => sessionClears++;
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  bool signedIn = true,
  _Auth? auth,
  Future<bool> Function()? login,
  Future<bool> Function()? sessionLoader,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  final authService = auth ?? _Auth();
  addTearDown(authService.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.all.first.themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: child!,
    ),
    home: CourseRecordingsPage(
      repository: repository,
      authService: authService,
      sessionLoader: sessionLoader ?? () async => signedIn,
      onLoginRequested: login ?? () async => false,
    ),
  ));
}

Future<void> _chooseTerm(WidgetTester tester, int termId) async {
  await tester.tap(find.byKey(const ValueKey('vod-term-filter')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(ValueKey('vod-term-option:$termId')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _selectTimetableDate(
    WidgetTester tester, int week, String date) async {
  tester
      .widget<ScheduleWeekSwitcher>(find.byType(ScheduleWeekSwitcher))
      .onQuickWeekSelected(week);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('timetable-day-$date')));
  await tester.pumpAndSettle();
}

void main() {
  final morningLesson = VodLesson(
      id: 201,
      teachingClassId: 101,
      name: '程序设计',
      isPlayable: true,
      beginTime: DateTime(2026, 10, 28, 8),
      weekNumber: 7,
      sectionLabel: '第1节');
  final afternoonLesson = VodLesson(
      id: 202,
      teachingClassId: 101,
      name: '程序设计',
      isPlayable: true,
      beginTime: DateTime(2026, 10, 28, 14),
      weekNumber: 7,
      sectionLabel: '第7节');

  testWidgets('timetable mode reuses catalog and preserves the chosen date',
      (tester) async {
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader =
        (_, __) async => [morningLesson, afternoonLesson];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('vod-view-toggle'));
    expect(find.descendant(of: find.byType(AppBar), matching: toggle),
        findsOneWidget);
    expect(find.byType(RecordingTimetableView), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await _selectTimetableDate(tester, 7, '2026-10-28');
    final summary = find.byKey(const ValueKey('vod-course-summary'));
    final weeks = find.byType(ScheduleWeekSwitcher);
    final dates = find.byKey(const ValueKey('timetable-weekdays'));
    expect(tester.getBottomLeft(summary).dy,
        lessThanOrEqualTo(tester.getTopLeft(weeks).dy));
    expect(tester.getBottomLeft(weeks).dy,
        lessThanOrEqualTo(tester.getTopLeft(dates).dy));
    expect(
        find.byKey(const ValueKey('timetable-day-2026-10-31')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('timetable-day-2026-11-01')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('timetable-entry-101-201')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('timetable-entry-101-202')), findsOneWidget);
    expect(find.text('录播回放'), findsNothing);
    for (final lessonId in [201, 202]) {
      final row = tester.widget<ListTile>(
          find.byKey(ValueKey('timetable-entry-101-$lessonId')));
      expect(row.enabled, isTrue);
      expect(row.onTap, isNotNull);
      expect((row.trailing! as Icon).icon, Icons.chevron_right);
    }
    expect(repository.courseRequests, [7]);
    expect(repository.lessonRequests, 1);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('timetable-entry-101-201')), findsOneWidget);
    expect(repository.lessonRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timetable entry opens its exact lesson instead of the latest',
      (tester) async {
    final pendingPlayback = Completer<VodPlayback>();
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader =
        (_, __) async => [afternoonLesson, morningLesson];
    repository.playbackLoader = (_, __) => pendingPlayback.future;
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pumpAndSettle();
    await _selectTimetableDate(tester, 7, '2026-10-28');
    await tester.tap(find.byKey(const ValueKey('timetable-entry-101-201')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.course.teachingClassId, 101);
    expect(player.initialLesson?.id, 201);
    expect(player.lessons.map((lesson) => lesson.id), [202, 201]);
    expect(repository.playbackRequests.map((lesson) => lesson.id), [201]);
    await tester.pumpWidget(const SizedBox.shrink());
    pendingPlayback.completeError(const VodPermissionException());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('timetable preserves pull and automatic loading feedback rules',
      (tester) async {
    final initialLessons = Completer<List<VodLesson>>();
    final catalog = Completer<List<VodCourse>>();
    final refreshedLessons = Completer<List<VodLesson>>();
    final repository = _Repository();
    repository.coursesLoader =
        (_, force) => force ? catalog.future : Future.value([_programming]);
    repository.lessonsLoader =
        (_, force) => force ? refreshedLessons.future : initialLessons.future;
    await _mount(tester, repository);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pump();
    final progress = find.byKey(const ValueKey('vod-loading-progress'));
    expect(progress, findsOneWidget);
    await tester.drag(
        find.byKey(const ValueKey('timetable-pageview')), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(repository.forcedCourseRequests, [false]);
    initialLessons.complete([morningLesson]);
    await tester.pumpAndSettle();
    await _selectTimetableDate(tester, 7, '2026-10-28');
    expect(progress, findsNothing);
    await tester.drag(
        find.byKey(const PageStorageKey('timetable-list-2026-10-28')),
        const Offset(0, 400));
    for (var frame = 0;
        frame < 20 && !repository.forcedCourseRequests.contains(true);
        frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(repository.forcedCourseRequests, [false, true]);
    expect(progress, findsNothing);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    catalog.complete([_programming]);
    await tester.pump();
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    refreshedLessons.complete([morningLesson, afternoonLesson]);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(progress, findsNothing);
    expect(
        find.byKey(const ValueKey('timetable-entry-101-202')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timetable clears failures for courses removed by a refresh',
      (tester) async {
    final repository = _Repository();
    repository.coursesLoader = (_, force) async =>
        force ? [_electronics] : [_programming, _electronics];
    repository.lessonsLoader = (course, _) async {
      if (course.teachingClassId == 101) {
        throw const VodNetworkException();
      }
      return [
        VodLesson(
            id: 301,
            teachingClassId: 102,
            name: _electronics.name,
            isPlayable: true,
            beginTime: DateTime(2026, 10, 28, 8),
            weekNumber: 7)
      ];
    };
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('timetable-load-warning')), findsOneWidget);
    await tester
        .widget<RecordingTimetableView>(find.byType(RecordingTimetableView))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timetable-load-warning')), findsNothing);
    expect(repository.forcedCourseRequests, [false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timetable term changes do not retain another term lessons',
      (tester) async {
    const previousCourse = VodCourse(
        teachingClassId: 101, termId: 6, name: '上学期程序设计', code: 'OLD101');
    final previousLesson = VodLesson(
        id: 301,
        teachingClassId: 101,
        name: previousCourse.name,
        isPlayable: true,
        beginTime: DateTime(2026, 3, 4, 8),
        weekNumber: 2);
    final repository = _Repository();
    repository.coursesLoader =
        (term, _) async => [term == 7 ? _programming : previousCourse];
    repository.lessonsLoader = (course, _) async =>
        [course.termId == 7 ? morningLesson : previousLesson];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pumpAndSettle();
    await _selectTimetableDate(tester, 7, '2026-10-28');
    await _chooseTerm(tester, 6);
    await tester.pumpAndSettle();
    final timetable = tester
        .widget<RecordingTimetableView>(find.byType(RecordingTimetableView));
    expect(timetable.data.entriesFor(DateTime(2026, 10, 28)), isEmpty);
    expect(
        timetable.data.entriesFor(DateTime(2026, 3, 4)).single.lesson.id, 301);
    expect(find.byKey(const ValueKey('timetable-entry-101-201')), findsNothing);
    expect(repository.courseRequests, [7, 6]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session and catalog loading use only AppBar progress',
      (tester) async {
    final session = Completer<bool>();
    final courses = Completer<List<VodCourse>>();
    final repository = _Repository()..coursesLoader = (_, __) => courses.future;
    await _mount(tester, repository, sessionLoader: () => session.future);
    final progress = find.byKey(const ValueKey('vod-loading-progress'));
    expect(find.descendant(of: find.byType(AppBar), matching: progress),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    session.complete(true);
    await tester.pump();
    await tester.pump();
    expect(repository.courseRequests, [7]);
    expect(find.descendant(of: find.byType(AppBar), matching: progress),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('本学期暂无可观看课程'), findsNothing);
    expect(find.textContaining('当前账号'), findsNothing);
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(repository.courseRequests, [7]);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(progress, findsOneWidget);
    courses.complete(_currentCourses);
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
  });

  testWidgets('partial courses open before the rest of the catalog completes',
      (tester) async {
    final courses = Completer<List<VodCourse>>();
    final repository = _Repository()..coursesLoader = (_, __) => courses.future;
    await _mount(tester, repository);
    await tester.pump();
    repository.progressCallbacks[7]!([_programming]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final course = find.byKey(const ValueKey('vod-course:101'));
    expect(course, findsOneWidget);
    expect(tester.widget<ListTile>(course).enabled, isTrue);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-course-count')))
            .textSpan!
            .toPlainText(),
        '1个课程');
    final requestsBeforeOpening = repository.lessonRequests;
    await tester.tap(course);
    await tester.pump();
    courses.complete(_currentCourses);
    await tester.pumpAndSettle();
    expect(find.byType(RecordingPlayerPage), findsOneWidget);
    expect(repository.lessonRequests, greaterThan(requestsBeforeOpening));
  });

  testWidgets('stale partial snapshots cannot cross a term selection',
      (tester) async {
    final previous = Completer<List<VodCourse>>();
    final current = Completer<List<VodCourse>>();
    final repository = _Repository()
      ..coursesLoader = (term, _) => switch (term) {
            6 => previous.future,
            5 => current.future,
            _ => Future.value(_currentCourses),
          };
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await _chooseTerm(tester, 6);
    final staleProgress = repository.progressCallbacks[6]!;
    await _chooseTerm(tester, 5);
    const selectedCourse =
        VodCourse(teachingClassId: 501, termId: 5, name: '所选学期');
    const staleCourse = VodCourse(teachingClassId: 601, termId: 6, name: '旧学期');
    repository.progressCallbacks[5]!([selectedCourse]);
    staleProgress([staleCourse]);
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-course:501')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:601')), findsNothing);
    current.complete([selectedCourse]);
    previous.complete([staleCourse]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:501')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:601')), findsNothing);
  });

  testWidgets(
      'a partial catalog remains visible when the remaining source fails',
      (tester) async {
    final courses = Completer<List<VodCourse>>();
    final repository = _Repository()..coursesLoader = (_, __) => courses.future;
    await _mount(tester, repository);
    await tester.pump();
    repository.progressCallbacks[7]!([_programming]);
    await tester.pump();
    courses.completeError(const VodNetworkException());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('课程加载失败'), findsNothing);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsNothing);
  });

  testWidgets('failed refresh keeps successful catalog content usable',
      (tester) async {
    final refresh = Completer<List<VodCourse>>();
    final repository = _Repository()
      ..coursesLoader =
          (_, force) => force ? refresh.future : Future.value(_currentCourses);
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final refreshing = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsNothing);
    repository.progressCallbacks[7]!(const []);
    await tester.pump();
    expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('vod-course:101')))
            .enabled,
        isTrue);
    refresh.completeError(const VodNetworkException());
    await refreshing;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('课程加载失败'), findsNothing);
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('vod-course-lesson-count:101')))
            .textSpan!
            .toPlainText(),
        '0/0节');
  });

  testWidgets(
      'course entrance matches notices and does not replay on live reorder',
      (tester) async {
    final courses = Completer<List<VodCourse>>();
    final repository = _Repository()..coursesLoader = (_, __) => courses.future;
    await _mount(tester, repository);
    await tester.pump();
    repository.progressCallbacks[7]!([_programming, _electronics]);
    await tester.pump();
    final row = find.byKey(const ValueKey('vod-course:101'));
    final fade =
        find.ancestor(of: row, matching: find.byType(FadeTransition)).first;
    final slide =
        find.ancestor(of: row, matching: find.byType(SlideTransition)).first;
    final opacity = tester.widget<FadeTransition>(fade).opacity;
    expect(opacity.value, 0);
    expect(tester.widget<SlideTransition>(slide).position.value,
        const Offset(0.12, 0));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 140));
    expect(opacity.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity.value, 1);
    repository.progressCallbacks[7]!([
      _electronics.withLiveLesson(const VodLesson(
        id: 900,
        teachingClassId: 102,
        name: '正在直播',
        isPlayable: true,
        isLive: true,
      )),
      _programming,
    ]);
    await tester.pump();
    expect(tester.widget<FadeTransition>(fade).opacity, same(opacity));
    expect(opacity.value, 1);
    courses.complete(_currentCourses);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion renders partial courses without entrance motion',
      (tester) async {
    final courses = Completer<List<VodCourse>>();
    final repository = _Repository()..coursesLoader = (_, __) => courses.future;
    await _mount(tester, repository, disableAnimations: true);
    await tester.pump();
    repository.progressCallbacks[7]!([_programming]);
    await tester.pump();
    final row = find.byKey(const ValueKey('vod-course:101'));
    final fade =
        find.ancestor(of: row, matching: find.byType(FadeTransition)).first;
    final slide =
        find.ancestor(of: row, matching: find.byType(SlideTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
    courses.complete(_currentCourses);
    await tester.pumpAndSettle();
  });

  testWidgets('signed-out accounts do not request any catalog data',
      (tester) async {
    final repository = _Repository();
    var logins = 0;
    await _mount(
      tester,
      repository,
      signedIn: false,
      login: () async {
        logins++;
        return false;
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('登录校园账户'), findsOneWidget);
    expect(repository.termRequests, 0);
    expect(repository.courseRequests, isEmpty);
    expect(logins, 0);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(repository.termRequests, 0);
  });

  testWidgets('selects the current term instead of the first returned term',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();

    expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const ValueKey('vod-term-filter')),
        ),
        findsOneWidget);
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('vod-term-option:7')),
            )
            .selected,
        isTrue);
    await tester.tapAt(const Offset(10, 200));
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7]);
    expect(find.textContaining('当前账号'), findsNothing);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
  });

  testWidgets(
      'course catalog shows all loaded courses without search or teacher filters',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('vod-teacher-filter')), findsNothing);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:102')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:103')), findsOneWidget);
    expect(find.textContaining('当前账号'), findsNothing);
    expect(repository.termRequests, 1);
    expect(repository.courseRequests, [7]);
  });

  testWidgets(
      'term changes remove old courses while the new request is pending',
      (tester) async {
    final pending = Completer<List<VodCourse>>();
    final repository = _Repository()
      ..coursesLoader = (term, _) =>
          term == 7 ? Future.value(_currentCourses) : pending.future;
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await _chooseTerm(tester, 6);
    expect(repository.courseRequests, [7, 6]);
    expect(find.byKey(const ValueKey('vod-course:101')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete(const [
      VodCourse(teachingClassId: 601, termId: 6, name: '历史学期课程'),
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:601')), findsOneWidget);
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('vod-term-option:6')),
            )
            .selected,
        isTrue);
  });

  testWidgets('a late response cannot overwrite a newer term selection',
      (tester) async {
    final secondTerm = Completer<List<VodCourse>>();
    final firstTerm = Completer<List<VodCourse>>();
    final repository = _Repository()
      ..coursesLoader = (term, _) => switch (term) {
            6 => secondTerm.future,
            5 => firstTerm.future,
            _ => Future.value(_currentCourses),
          };
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await _chooseTerm(tester, 6);
    await _chooseTerm(tester, 5);
    expect(repository.courseRequests, [7, 6, 5]);
    firstTerm.complete(const [
      VodCourse(teachingClassId: 501, termId: 5, name: '先前学年课程'),
    ]);
    await tester.pumpAndSettle();
    secondTerm.complete(const [
      VodCourse(teachingClassId: 601, termId: 6, name: '迟到的学期课程'),
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:501')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:601')), findsNothing);
  });

  testWidgets(
      'term menu groups years newest first and orders summer spring autumn',
      (tester) async {
    final repository = _Repository()
      ..termsLoader = (_) async => [
            const VodTerm(
                id: 8, name: '夏季', academicYear: '2025-2026', termNumber: 3),
            _terms[1],
            _terms[2],
            _terms[0],
          ];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    expect(find.text('26-27学年'), findsOneWidget);
    expect(find.text('25-26学年'), findsOneWidget);
    expect(tester.getTopLeft(find.text('26-27学年')).dy,
        lessThan(tester.getTopLeft(find.text('25-26学年')).dy));
    final autumn = find.byKey(const ValueKey('vod-term-option:5'));
    final spring = find.byKey(const ValueKey('vod-term-option:6'));
    final summer = find.byKey(const ValueKey('vod-term-option:8'));
    expect(find.descendant(of: autumn, matching: find.text('秋季学期')),
        findsOneWidget);
    expect(find.descendant(of: spring, matching: find.text('春季学期')),
        findsOneWidget);
    expect(find.descendant(of: summer, matching: find.text('夏季学期')),
        findsOneWidget);
    expect(
        tester.getTopLeft(summer).dy, lessThan(tester.getTopLeft(spring).dy));
    expect(
        tester.getTopLeft(spring).dy, lessThan(tester.getTopLeft(autumn).dy));
    await tester.tap(summer);
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7, 8]);
    expect(find.byKey(const ValueKey('vod-term-menu')), findsNothing);
  });

  testWidgets('historical four-term menu keeps descending order and selection',
      (tester) async {
    final repository = _Repository();
    repository.termsLoader = (_) async => [
          for (final number in [1, 3, 2, 4])
            VodTerm(
              id: 40 + number,
              name: '2024-2025学年第$number学期',
              academicYear: '2024-2025',
              termNumber: number,
            ),
          _terms[2],
        ];
    repository.coursesLoader = (termId, _) async => termId == 42
        ? const [
            VodCourse(teachingClassId: 4201, termId: 42, name: '历史冬季课程'),
          ]
        : [_programming];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('26-27学年')).dy,
        lessThan(tester.getTopLeft(find.text('24-25学年')).dy));
    await tester.tap(find.byKey(const ValueKey('vod-term-year:2026-2027')));
    await tester.pumpAndSettle();
    final autumn = find.byKey(const ValueKey('vod-term-option:41'));
    final winter = find.byKey(const ValueKey('vod-term-option:42'));
    final spring = find.byKey(const ValueKey('vod-term-option:43'));
    final summer = find.byKey(const ValueKey('vod-term-option:44'));
    for (final option in [
      (summer, '夏季学期'),
      (spring, '春季学期'),
      (winter, '冬季学期'),
      (autumn, '秋季学期'),
    ]) {
      expect(find.descendant(of: option.$1, matching: find.text(option.$2)),
          findsOneWidget);
    }
    expect(
        tester.getTopLeft(summer).dy, lessThan(tester.getTopLeft(spring).dy));
    expect(
        tester.getTopLeft(spring).dy, lessThan(tester.getTopLeft(winter).dy));
    expect(
        tester.getTopLeft(winter).dy, lessThan(tester.getTopLeft(autumn).dy));
    await tester.tap(winter);
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7, 42]);
    expect(find.byKey(const ValueKey('vod-course:4201')), findsOneWidget);
    expect(find.text('2024-2025 学年 冬季学期'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('term year groups fold independently and restore when reopened',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    final currentYear = find.byKey(const ValueKey('vod-term-year:2026-2027'));
    final previousYear = find.byKey(const ValueKey('vod-term-year:2025-2026'));
    final currentTerm = find.byKey(const ValueKey('vod-term-option:7'));
    final previousTerm = find.byKey(const ValueKey('vod-term-option:5'));
    expect(
        find.descendant(
            of: previousYear, matching: find.byIcon(Icons.expand_less)),
        findsOneWidget);
    await tester.tap(previousYear);
    await tester.pumpAndSettle();
    expect(previousTerm, findsNothing);
    expect(currentTerm, findsOneWidget);
    expect(
        find.descendant(
            of: previousYear, matching: find.byIcon(Icons.expand_more)),
        findsOneWidget);
    expect(repository.courseRequests, [7]);
    await tester.tap(currentYear);
    await tester.pumpAndSettle();
    expect(currentTerm, findsNothing);
    await tester.tapAt(const Offset(10, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    expect(currentTerm, findsNothing);
    expect(previousTerm, findsNothing);
    await tester.tap(currentYear);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(currentTerm).selected, isTrue);
    expect(previousTerm, findsNothing);
    await tester.tap(previousYear);
    await tester.pumpAndSettle();
    await tester.tap(previousTerm);
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7, 5]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('year headers pin within their group and yield to the next year',
      (tester) async {
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository()
      ..termsLoader = (_) async => [
            for (var year = 2032; year >= 2025; year--)
              for (var number = 1; number <= 3; number++)
                VodTerm(
                  id: year * 10 + number,
                  name: '$year学年第$number学期',
                  academicYear: '$year-${year + 1}',
                  termNumber: number,
                ),
          ];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('vod-term-menu'));
    final scroll = tester
        .widget<CustomScrollView>(
          find.byKey(const ValueKey('vod-term-menu-scroll')),
        )
        .controller!;
    final first = find.byKey(const ValueKey('vod-term-year:2032-2033'));
    final second = find.byKey(const ValueKey('vod-term-year:2031-2032'));
    final menuTop = tester.getTopLeft(menu).dy;
    final nextYearOffset = tester.getTopLeft(second).dy - menuTop;
    scroll.jumpTo(80);
    await tester.pump();
    expect(tester.getTopLeft(first).dy, closeTo(menuTop, 1));
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-term-option:20321')), findsNothing);
    expect(tester.takeException(), isNull);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(first);
    await tester.pumpAndSettle();
    scroll.jumpTo(nextYearOffset + 16);
    await tester.pump();
    expect(tester.getTopLeft(second).dy, closeTo(menuTop, 1));
    expect(tester.getBottomLeft(first).dy, lessThanOrEqualTo(menuTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'term menu matches notice menu sizing and dismisses without loading',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository();
    await _mount(tester, repository, textScale: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择学期'));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('vod-term-menu'));
    expect(tester.getSize(menu).width, 264);
    expect(tester.getTopLeft(menu).dx, closeTo(390 - 264 - 12, 1));
    expect(find.descendant(of: menu, matching: find.byType(Scrollbar)),
        findsOneWidget);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    expect(tester.getSize(menu).width, closeTo(320 * 0.68, 0.1));
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(10, 250));
    await tester.pumpAndSettle();
    expect(menu, findsNothing);
    expect(repository.courseRequests, [7]);
    await _chooseTerm(tester, 7);
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7]);
  });

  testWidgets('network errors retry the catalog without requiring login',
      (tester) async {
    final repository = _Repository();
    var logins = 0;
    var requests = 0;
    repository.coursesLoader = (_, __) async {
      if (++requests == 1) throw const VodNetworkException();
      return _currentCourses;
    };
    await _mount(tester, repository, login: () async {
      logins++;
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.text('课程加载失败'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    expect(logins, 0);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(repository.forcedCourseRequests, [false, true]);
    expect(logins, 0);
  });

  testWidgets('session expiry clears old data and waits for explicit login',
      (tester) async {
    final repository = _Repository();
    final auth = _Auth();
    var requests = 0;
    var logins = 0;
    repository.coursesLoader = (_, __) async {
      if (++requests == 1) {
        throw const VodSessionExpiredException.campus(ssoExpired: true);
      }
      return _currentCourses;
    };
    await _mount(tester, repository, auth: auth, login: () async {
      logins++;
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.text('校园账户登录已失效'), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:101')), findsNothing);
    expect(auth.sessionClears, 0);
    expect(repository.clears, 1);
    expect(logins, 0);

    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(repository.clears, 2);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(repository.forcedCourseRequests, [false, true]);
  });

  testWidgets('plain course list keeps pull-to-refresh including empty results',
      (tester) async {
    final repository = _Repository()
      ..coursesLoader = (_, force) async => force ? [] : _currentCourses;
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    expect(find.byTooltip('刷新课程'), findsNothing);
    expect(find.byType(Card), findsNothing);
    final separator = tester.widget<Divider>(find
        .descendant(
          of: find.byKey(const ValueKey('vod-courses:7')),
          matching: find.byType(Divider),
        )
        .first);
    expect(separator.indent, 16);
    expect(separator.endIndent, 16);
    expect(find.text('2026-2027 学年 秋季学期'), findsOneWidget);
    final term = tester.widget<Text>(find.text('2026-2027 学年 秋季学期'));
    final termSpan = term.textSpan! as TextSpan;
    expect(term.style!.fontWeight, FontWeight.w600);
    expect(
        termSpan.children!.last.style!.color,
        Theme.of(tester.element(find.text('2026-2027 学年 秋季学期')))
            .colorScheme
            .primary);
    final count =
        tester.widget<Text>(find.byKey(const ValueKey('vod-course-count')));
    final countSpan = count.textSpan! as TextSpan;
    expect(count.style!.fontWeight, FontWeight.w600);
    expect(countSpan.toPlainText(), '3个课程');
    expect(
        countSpan.children!.first.style!.color,
        Theme.of(tester.element(find.byKey(const ValueKey('vod-course-count'))))
            .colorScheme
            .primary);
    final course = find.byKey(const ValueKey('vod-course:101'));
    final colors = tester.element(course).shuyoColors;
    final title = tester.widget<Text>(find.descendant(
      of: course,
      matching: find.text('程序设计'),
    ));
    final label =
        find.descendant(of: course, matching: find.byType(CourseColorLabel));
    final metadata = tester.widget<Text>(
        find.descendant(of: label, matching: find.text('CS101 · 教师甲')));
    expect(title.style?.color, colors.textPrimary);
    expect(metadata.style?.color, colors.textSecondary);
    expect(metadata.style!.fontSize!, lessThan(title.style!.fontSize!));
    expect(tester.getTopLeft(find.text('CS101 · 教师甲')).dy,
        greaterThan(tester.getTopLeft(find.text('程序设计')).dy));
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(repository.forcedCourseRequests, [false, true]);
    expect(find.text('本学期暂无可观看课程'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-course-count')))
            .textSpan!
            .toPlainText(),
        '0个课程');
    await tester.drag(find.byType(ListView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(repository.forcedCourseRequests, [false, true, true]);
  });

  testWidgets('course counts distinguish playable recordings from all lessons',
      (tester) async {
    const lessons = [
      VodLesson(id: 1, teachingClassId: 101, name: '回放一', isPlayable: true),
      VodLesson(id: 2, teachingClassId: 101, name: '回放二', isPlayable: true),
      VodLesson(
          id: 3,
          teachingClassId: 101,
          name: '生成中',
          isPlayable: false,
          isGenerating: true),
      VodLesson(
          id: 4,
          teachingClassId: 101,
          name: '直播',
          isPlayable: true,
          isLive: true),
      VodLesson(
          id: 5,
          teachingClassId: 101,
          name: '不可播放',
          isPlayable: false,
          isListed: true),
      VodLesson(id: 6, teachingClassId: 101, name: '未列出', isPlayable: false),
      VodLesson(id: 7, teachingClassId: 999, name: '其他班', isPlayable: true),
      VodLesson(id: 1, teachingClassId: 101, name: '重复课次', isPlayable: true),
    ];
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader = (_, __) async => lessons;
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('vod-course-lesson-count:101'));
    final span = tester.widget<Text>(finder).textSpan! as TextSpan;
    expect(span.toPlainText(), '2/5节');
    expect(tester.widget<Text>(finder).style!.fontWeight, FontWeight.w600);
    expect(span.children!.first.style!.color,
        Theme.of(tester.element(finder)).colorScheme.primary);
    expect(tester.getTopLeft(finder).dx,
        lessThan(tester.getTopLeft(find.byIcon(Icons.chevron_right)).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('course and its count enter together after the count loads',
      (tester) async {
    final pending = Completer<List<VodLesson>>();
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader = (_, __) => pending.future;
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final row = find.byKey(const ValueKey('vod-course:101'));
    final finder = find.byKey(const ValueKey('vod-course-lesson-count:101'));
    expect(row, findsNothing);
    expect(finder, findsNothing);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsOneWidget);
    pending.complete(const [
      VodLesson(id: 1, teachingClassId: 101, name: '回放', isPlayable: true),
    ]);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(finder).textSpan!.toPlainText(), '1/1节');
    final entrance = find.byKey(const ValueKey(101));
    final slide =
        find.descendant(of: entrance, matching: find.byType(SlideTransition));
    expect(tester.widget<SlideTransition>(slide).position.value.dx,
        greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull refresh shows only its spinner until all counts finish',
      (tester) async {
    final catalog = Completer<List<VodCourse>>();
    final counts = {
      for (final course in _currentCourses)
        course.teachingClassId: Completer<List<VodLesson>>()
    };
    final repository = _Repository();
    repository.coursesLoader =
        (_, force) => force ? catalog.future : Future.value(_currentCourses);
    repository.lessonsLoader = (course, force) =>
        force ? counts[course.teachingClassId]!.future : Future.value([]);
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final progress = find.byKey(const ValueKey('vod-loading-progress'));
    final spinner = find.byType(RefreshProgressIndicator);
    expect(progress, findsNothing);
    expect(spinner, findsNothing);

    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 400));
    for (var frame = 0;
        frame < 20 && !repository.forcedCourseRequests.contains(true);
        frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(repository.forcedCourseRequests, [false, true]);
    expect(progress, findsNothing);
    expect(spinner, findsOneWidget);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(repository.forcedCourseRequests, [false, true]);

    catalog.complete(_currentCourses);
    await tester.pump();
    await tester.pump();
    expect(repository.lessonRequests, 6);
    counts[101]!.complete([]);
    counts[102]!.completeError(const VodNetworkException());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(progress, findsNothing);
    expect(spinner, findsOneWidget);
    expect(tester.widget<RefreshProgressIndicator>(spinner).value, isNull);
    expect(find.byTooltip('课次统计暂不可用，下拉刷新重试'), findsOneWidget);

    counts[103]!.complete([]);
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(spinner, findsNothing);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:102')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:103')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows appear on success or failure while progress waits for all',
      (tester) async {
    final first = Completer<List<VodLesson>>();
    final second = Completer<List<VodLesson>>();
    final third = Completer<List<VodLesson>>();
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => _currentCourses;
    repository.lessonsLoader = (course, _) => switch (course.teachingClassId) {
          101 => first.future,
          102 => second.future,
          _ => third.future,
        };
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump();
    final progress = find.byKey(const ValueKey('vod-loading-progress'));
    expect(progress, findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:101')), findsNothing);
    expect(find.byKey(const ValueKey('vod-course:102')), findsNothing);
    expect(find.byKey(const ValueKey('vod-course:103')), findsNothing);
    second.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-course:102')), findsOneWidget);
    expect(find.byTooltip('课次统计暂不可用，下拉刷新重试'), findsOneWidget);
    expect(progress, findsOneWidget);
    first.complete(const [
      VodLesson(id: 1, teachingClassId: 101, name: '回放', isPlayable: true)
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:103')), findsNothing);
    expect(progress, findsOneWidget);
    third.complete([]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:103')), findsOneWidget);
    expect(progress, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lesson count requests are bounded and run in the background',
      (tester) async {
    final courses = [
      for (var index = 0; index < 5; index++)
        VodCourse(teachingClassId: 301 + index, termId: 7, name: '课程$index'),
    ];
    final completions = {
      for (final course in courses)
        course.teachingClassId: Completer<List<VodLesson>>()
    };
    final started = <int>[];
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => courses;
    repository.lessonsLoader = (course, _) {
      started.add(course.teachingClassId);
      return completions[course.teachingClassId]!.future;
    };
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started, [301, 302, 303]);
    expect(find.byKey(const ValueKey('vod-course:301')), findsNothing);
    completions[301]!.complete([]);
    await tester.pump();
    await tester.pump();
    expect(started, [301, 302, 303, 304]);
    expect(find.byKey(const ValueKey('vod-course:301')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsOneWidget);
    for (final completion in completions.values) {
      if (!completion.isCompleted) completion.complete([]);
    }
    await tester.pumpAndSettle();
    expect(started, [301, 302, 303, 304, 305]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull refresh stays disabled until pending counts finish',
      (tester) async {
    final pending = Completer<List<VodLesson>>();
    final forceFlags = <bool>[];
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader = (_, force) {
      forceFlags.add(force);
      return force
          ? Future.value(const [
              VodLesson(
                  id: 2, teachingClassId: 101, name: '回放', isPlayable: true),
              VodLesson(
                  id: 3, teachingClassId: 101, name: '回放', isPlayable: true),
            ])
          : pending.future;
    };
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(forceFlags, [false]);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsOneWidget);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(repository.forcedCourseRequests, [false]);
    pending.complete(const [
      VodLesson(id: 1, teachingClassId: 101, name: '旧回放', isPlayable: true),
    ]);
    await tester.pumpAndSettle();
    expect(forceFlags, [false]);
    expect(find.byKey(const ValueKey('vod-loading-progress')), findsNothing);
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(forceFlags, [false, true]);
    final finder = find.byKey(const ValueKey('vod-course-lesson-count:101'));
    expect(tester.widget<Text>(finder).textSpan!.toPlainText(), '2/2节');
    expect(tester.takeException(), isNull);
  });

  testWidgets('late lesson counts cannot cross a term change', (tester) async {
    const olderCourse = VodCourse(
        teachingClassId: 101, termId: 6, name: '上一学期的课程', code: 'OLD101');
    final pending = Completer<List<VodLesson>>();
    final repository = _Repository();
    repository.coursesLoader =
        (term, _) async => term == 7 ? [_programming] : [olderCourse];
    repository.lessonsLoader = (course, _) => course.termId == 7
        ? pending.future
        : Future.value(const [
            VodLesson(
                id: 11, teachingClassId: 101, name: '回放', isPlayable: true),
          ]);
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _chooseTerm(tester, 6);
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('vod-course-lesson-count:101'));
    expect(tester.widget<Text>(finder).textSpan!.toPlainText(), '1/1节');
    expect(find.text('2025-2026 学年 春季学期'), findsOneWidget);
    pending.complete(const [
      VodLesson(
          id: 21,
          teachingClassId: 101,
          name: '生成',
          isPlayable: false,
          isGenerating: true),
    ]);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(finder).textSpan!.toPlainText(), '1/1节');
    expect(tester.takeException(), isNull);
  });

  testWidgets('lesson count errors show an unknown value instead of zero',
      (tester) async {
    final repository = _Repository();
    repository.coursesLoader = (_, __) async => [_programming];
    repository.lessonsLoader = (_, __) async => throw StateError('offline');
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('vod-course-lesson-count:101'));
    expect(tester.widget<Text>(finder).textSpan!.toPlainText(), '—/—节');
    expect(find.byTooltip('课次统计暂不可用，下拉刷新重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
  });

  testWidgets('course metadata handles missing codes and teachers',
      (tester) async {
    const withoutCode = VodCourse(
      teachingClassId: 201,
      termId: 7,
      name: '无课程号',
      teacherNames: ['教师甲', '教师乙'],
    );
    const withoutTeacher = VodCourse(
      teachingClassId: 202,
      termId: 7,
      name: '无教师姓名',
      code: 'CS202',
    );
    final repository = _Repository()
      ..coursesLoader = (_, __) async => [withoutCode, withoutTeacher];
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('教师甲、教师乙'), findsOneWidget);
    expect(find.text('CS202 · 教师信息暂未提供'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('course list does not display classroom names', (tester) async {
    const live = VodLesson(
      id: 201,
      teachingClassId: 101,
      name: '程序设计',
      classroom: '东区 A101',
      isLive: true,
      isPlayable: true,
    );
    final repository = _Repository()
      ..coursesLoader = (_, __) async => [_programming.withLiveLesson(live)];
    await _mount(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final course = find.byKey(const ValueKey('vod-course:101'));
    expect(find.descendant(of: course, matching: find.text('CS101 · 教师甲')),
        findsOneWidget);
    expect(find.textContaining('东区 A101'), findsNothing);
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('vod-course-lesson-count:101')))
            .textSpan!
            .toPlainText(),
        '0/1节');
    expect(repository.lessonRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'course rows open the player directly with introduction and episodes',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final requestsBeforeOpening = repository.lessonRequests;
    await tester.tap(find.byKey(const ValueKey('vod-course:101')));
    await tester.pumpAndSettle();

    expect(find.byType(RecordingPlayerPage), findsOneWidget);
    final lessonsPage = tester.widget<RecordingPlayerPage>(
      find.byType(RecordingPlayerPage),
    );
    expect(lessonsPage.course.teachingClassId, 101);
    expect(identical(lessonsPage.repository, repository), isTrue);
    expect(repository.lessonRequests, greaterThan(requestsBeforeOpening));
    expect(find.text('课程介绍'), findsNothing);
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('剧集'), findsNothing);
    expect(find.text('暂无可观看回放'), findsOneWidget);
  });

  testWidgets(
      '320 pixel layout supports double sized text and an empty catalog',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository()
      ..coursesLoader = (_, force) async => force ? [] : _currentCourses;
    await _mount(tester, repository, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timetable-weekdays')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('vod-view-toggle')));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('本学期暂无可观看课程'), findsOneWidget);
  });
}
