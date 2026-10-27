import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_service.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/course_recordings/recording_lessons_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _terms = [
  VodTerm(id: 5, name: '2025-2026学年第1学期'),
  VodTerm(id: 6, name: '2025-2026学年第2学期'),
  VodTerm(id: 7, name: '2026-2027学年第1学期', isCurrent: true),
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

    final filter = tester.widget<DropdownButton<int>>(
      find.byKey(const ValueKey('vod-term-filter')),
    );
    expect(filter.value, 7);
    expect(repository.courseRequests, [7]);
    expect(find.text('当前账号 · 3 门课程'), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
  });

  testWidgets(
      'keyword and teacher filtering stay inside the loaded account list',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('vod-course-search'));

    await tester.enterText(search, '程序');
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-course:101')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:102')), findsNothing);
    expect(find.byKey(const ValueKey('vod-course:103')), findsNothing);

    final teacher = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('vod-teacher-filter')),
    );
    teacher.onChanged!('教师乙');
    await tester.pump();
    expect(find.text('没有匹配的课程'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-course:103')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-course:101')), findsNothing);

    await tester.enterText(search, '课表外不存在的课程');
    await tester.pump();
    expect(find.text('没有匹配的课程'), findsOneWidget);
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
    final filter = tester.widget<DropdownButton<int>>(
      find.byKey(const ValueKey('vod-term-filter')),
    );
    filter.onChanged!(6);
    await tester.pump();
    expect(repository.courseRequests, [7, 6]);
    expect(find.byKey(const ValueKey('vod-course:101')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    pending.complete(const [
      VodCourse(teachingClassId: 601, termId: 6, name: '历史学期课程'),
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vod-course:601')), findsOneWidget);
    expect(
      tester
          .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('vod-term-filter')))
          .value,
      6,
    );
  });

  testWidgets('a late response cannot overwrite a newer queued term selection',
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
    // Keep the callback to model filter events already queued before a frame
    // disables the dropdown. Both requests may then finish out of order.
    final changeTerm = tester
        .widget<DropdownButton<int>>(
            find.byKey(const ValueKey('vod-term-filter')))
        .onChanged!;
    changeTerm(6);
    await tester.pump();
    changeTerm(5);
    await tester.pump();
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

  testWidgets('course rows open the dated recording lesson list',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-course:101')));
    await tester.pumpAndSettle();

    expect(find.byType(RecordingLessonsPage), findsOneWidget);
    final lessonsPage = tester.widget<RecordingLessonsPage>(
      find.byType(RecordingLessonsPage),
    );
    expect(lessonsPage.course.teachingClassId, 101);
    expect(identical(lessonsPage.repository, repository), isTrue);
    expect(repository.lessonRequests, 1);
    expect(find.text('暂无可观看回放'), findsOneWidget);
  });

  testWidgets('320 pixel layout supports double sized text and empty filtering',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository();
    await _mount(tester, repository, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('vod-course-search')),
      '没有任何匹配',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('没有匹配的课程'), findsOneWidget);
  });
}
