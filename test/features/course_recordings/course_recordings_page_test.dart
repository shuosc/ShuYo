import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

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
  }) async {
    courseRequests.add(termId);
    forcedCourseRequests.add(forceRefresh);
    final loader = coursesLoader;
    return loader == null
        ? _currentCourses
        : await loader(termId, forceRefresh);
  }

  @override
  Future<List<VodCourse>> loadCatalog(
          {required int termId, bool forceRefresh = false}) =>
      loadCourses(termId: termId, forceRefresh: forceRefresh);

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
    return [];
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
  double textScale = 1,
}) async {
  final authService = auth ?? _Auth();
  addTearDown(authService.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.all.first.themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: CourseRecordingsPage(
      repository: repository,
      authService: authService,
      sessionLoader: () async => signedIn,
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

void main() {
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
    expect(find.text('当前账号 · 3 门课程'), findsOneWidget);
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
    expect(find.text('当前账号 · 3 门课程'), findsOneWidget);
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
      'term menu groups years newest first and orders autumn spring summer',
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
        tester.getTopLeft(autumn).dy, lessThan(tester.getTopLeft(spring).dy));
    expect(
        tester.getTopLeft(spring).dy, lessThan(tester.getTopLeft(summer).dy));
    await tester.tap(summer);
    await tester.pumpAndSettle();
    expect(repository.courseRequests, [7, 8]);
    expect(find.byKey(const ValueKey('vod-term-menu')), findsNothing);
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
    final course = find.byKey(const ValueKey('vod-course:101'));
    final colors = tester.element(course).shuyoColors;
    final title = tester.widget<Text>(find.descendant(
      of: course,
      matching: find.text('程序设计'),
    ));
    final subtitle = tester.widget<Text>(find.descendant(
      of: course,
      matching: find.text('教师甲 · CS101'),
    ));
    expect(title.style?.color, colors.textPrimary);
    expect(subtitle.style?.color, colors.textSecondary);
    expect(title.style!.fontSize!, greaterThan(subtitle.style!.fontSize!));
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(repository.forcedCourseRequests, [false, true]);
    expect(find.text('本学期暂无可观看课程'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(repository.forcedCourseRequests, [false, true, true]);
  });

  testWidgets(
      'course rows open the player directly with introduction and episodes',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-course:101')));
    await tester.pumpAndSettle();

    expect(find.byType(RecordingPlayerPage), findsOneWidget);
    final lessonsPage = tester.widget<RecordingPlayerPage>(
      find.byType(RecordingPlayerPage),
    );
    expect(lessonsPage.course.teachingClassId, 101);
    expect(identical(lessonsPage.repository, repository), isTrue);
    expect(repository.lessonRequests, 1);
    expect(find.text('课程介绍'), findsOneWidget);
    expect(find.text('选集（0）'), findsOneWidget);
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
    await tester.drag(
        find.byKey(const ValueKey('vod-courses:7')), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('本学期暂无可观看课程'), findsOneWidget);
  });
}
