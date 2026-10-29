import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/models/academic_progress.dart';
import 'package:shuyo/data/models/academic_ranking.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/models/academic_student_profile.dart';
import 'package:shuyo/data/repositories/academic_progress_repository.dart';
import 'package:shuyo/data/repositories/academic_ranking_repository.dart';
import 'package:shuyo/data/repositories/academic_student_profile_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_progress_api_client.dart';
import 'package:shuyo/data/services/academic_progress_display_settings_service.dart';
import 'package:shuyo/data/services/academic_progress_parser.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/features/home/academic_progress_page.dart';
import 'package:shuyo/features/home/home_dashboard_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

class _AuthWithCookie extends AcademicAuthService {
  _AuthWithCookie()
      : super(
          cookieLoader: (_) async => [],
          cookieSetter: (_) async {},
        );

  @override
  Future<String?> cookieHeader({Uri? targetUri}) async => 'JSESSIONID=test';
}

class _LongStudentProfileRepository
    extends DemoAcademicStudentProfileRepository {
  static const longProfile = AcademicStudentProfile(
    studentId: 'DEMO0001',
    studentName: '示例姓名',
    grade: '2025',
    academicLevel: '本科',
    majorName: '很长的专业名称用于验证窄屏上的文本布局',
    collegeName: '很长的学院名称用于验证窄屏上的文本布局',
  );

  @override
  Future<AcademicStudentProfile?> loadCachedProfile() async => longProfile;

  @override
  Future<AcademicStudentProfile> refreshProfile() async => longProfile;
}

class _StudentProfileRepository extends AcademicStudentProfileRepository {
  _StudentProfileRepository({this.cached, this.refreshed, this.error});

  final AcademicStudentProfile? cached;
  final AcademicStudentProfile? refreshed;
  final Object? error;
  int requests = 0;

  @override
  Future<AcademicStudentProfile?> loadCachedProfile() async => cached;

  @override
  Future<AcademicStudentProfile> refreshProfile() async {
    requests++;
    if (error case final error?) throw error;
    final result = refreshed;
    if (result == null) throw const AcademicApiException('profile offline');
    return result;
  }
}

DemoAcademicScheduleRepository _scheduleWithName(String id, String name) =>
    DemoAcademicScheduleRepository(AcademicSchedule(
      term: AcademicTerm(
        yearCode: '',
        termCode: '',
        academicYearName: '',
        termName: '',
        studentName: name,
        studentId: id,
        className: '',
      ),
      sessions: const [],
      untimedCourses: const [],
      fetchedAt: DateTime(2026),
    ));

class _DeepProgressRepository extends AcademicProgressRepository {
  _DeepProgressRepository() {
    final sample = DemoAcademicProgressRepository().progress;
    progress = AcademicProgress(
      studentId: sample.studentId,
      gpa: sample.gpa,
      plannedCourses: sample.plannedCourses,
      passedCourses: sample.passedCourses,
      ongoingCourses: sample.ongoingCourses,
      notTakenCourses: sample.notTakenCourses,
      fetchedAt: sample.fetchedAt,
      nodes: [
        sample.nodes.first,
        const AcademicProgressNode(
          id: 'level-1',
          parentId: 'demo-main',
          name: '专业课程',
          requiredCredits: 90,
          earnedCredits: 30,
          passed: true,
          courseKind: '',
          isLeaf: false,
        ),
        const AcademicProgressNode(
          id: 'level-2',
          parentId: 'level-1',
          name: '专业选修',
          requiredCredits: 30,
          earnedCredits: 8,
          passed: false,
          courseKind: '',
          isLeaf: false,
        ),
        AcademicProgressNode(
          id: 'level-3',
          parentId: 'level-2',
          name: '软件工程方向',
          requiredCredits: 15,
          earnedCredits: 3,
          passed: false,
          courseKind: '1',
          isLeaf: true,
          courses: [sample.nodes[1].courses.first],
        ),
      ],
    );
  }

  late final AcademicProgress progress;

  @override
  Future<AcademicProgress?> loadCachedProgress() async => progress;

  @override
  Future<AcademicProgress> refreshProgress() async => progress;
}

class _FailingRankingRepository extends AcademicRankingRepository {
  _FailingRankingRepository({this.cached});

  final AcademicRanking? cached;

  @override
  Future<AcademicRanking?> loadCachedRanking() async => cached;

  @override
  Future<AcademicRanking> refreshRanking() async =>
      throw const AcademicApiException('ranking unavailable');
}

class _RefreshingProgressRepository extends AcademicProgressRepository {
  _RefreshingProgressRepository({required this.fetch, this.cached});

  final Future<AcademicProgress> Function() fetch;
  final AcademicProgress? cached;
  int requests = 0;

  @override
  Future<AcademicProgress?> loadCachedProgress() async => cached;

  @override
  Future<AcademicProgress> refreshProgress() {
    requests++;
    return fetch();
  }
}

class _RefreshingRankingRepository extends AcademicRankingRepository {
  _RefreshingRankingRepository({required this.fetch, this.cached});

  final Future<AcademicRanking> Function() fetch;
  final AcademicRanking? cached;
  int requests = 0;

  @override
  Future<AcademicRanking?> loadCachedRanking() async => cached;

  @override
  Future<AcademicRanking> refreshRanking() {
    requests++;
    return fetch();
  }
}

Future<void> _restoreSession() async {}

Future<void> _tapRefresh(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('刷新学业信息'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectInlineEdgeMetric(
  WidgetTester tester, {
  required String label,
  required String valueKey,
  required double edgeX,
  bool rightAligned = false,
}) {
  final labelBounds = tester.getRect(find.text(label));
  final valueBounds = tester.getRect(find.byKey(ValueKey(valueKey)));
  final valueBoxBounds = tester.getRect(find.byKey(ValueKey('$valueKey-box')));
  expect(labelBounds.right, lessThan(valueBounds.left));
  expect(labelBounds.top, lessThan(valueBounds.bottom));
  expect(labelBounds.bottom, greaterThan(valueBounds.top));
  expect(rightAligned ? valueBoxBounds.right : labelBounds.left,
      closeTo(edgeX, 1));
  if (rightAligned) {
    final iconBounds = tester.getRect(find.byIcon(Icons.swap_horiz));
    expect(iconBounds.right, lessThan(labelBounds.left));
    expect(iconBounds.top, lessThan(labelBounds.bottom));
    expect(iconBounds.bottom, greaterThan(labelBounds.top));
  }
}

double _metricTextGap(WidgetTester tester, String label, String valueKey) {
  final labelFinder = find.text(label);
  final valueFinder = find.byKey(ValueKey(valueKey));
  final labelParagraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: labelFinder, matching: find.byType(RichText)).first,
  );
  final valueParagraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: valueFinder, matching: find.byType(RichText)).first,
  );
  final labelText = labelParagraph.text.toPlainText();
  final labelBox = labelParagraph
      .getBoxesForSelection(TextSelection(
          baseOffset: labelText.length - 1, extentOffset: labelText.length))
      .single;
  final valueBox = valueParagraph
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .single;
  final labelEnd = labelParagraph.localToGlobal(Offset(labelBox.right, 0)).dx;
  final valueStart = valueParagraph.localToGlobal(Offset(valueBox.left, 0)).dx;
  return valueStart - labelEnd;
}

void _expectSimilarMetricTextGaps(WidgetTester tester, String rankingLabel) {
  final gpaGap = _metricTextGap(tester, '平均绩点', 'academic-gpa-value');
  final rankingGap =
      _metricTextGap(tester, rankingLabel, 'academic-ranking-value');
  expect(gpaGap, inInclusiveRange(0, 10));
  expect(rankingGap, inInclusiveRange(0, 10));
  expect(rankingGap, closeTo(gpaGap, 3));

  final gpa = find.byKey(const ValueKey('academic-gpa-value'));
  final ranking = find.byKey(const ValueKey('academic-ranking-value'));
  expect(tester.widget<Text>(gpa).style!.fontSize,
      tester.widget<Text>(ranking).style!.fontSize);
  final gpaTransform = tester.renderObject(gpa).getTransformTo(null).storage;
  final rankingTransform =
      tester.renderObject(ranking).getTransformTo(null).storage;
  expect(rankingTransform[0], closeTo(gpaTransform[0], 0.001));
  expect(rankingTransform[5], closeTo(gpaTransform[5], 0.001));
}

const _index = '''
<html><body>
<form id="form">
  <input name="xh_id" value="DEMO0001">
  <input name="cjlrxn" value="2026">
  <input name="cjlrxq" value="3">
</form>
<div id="alertBox">（GPA）：3.4 计划总课程 20 门 通过 8 门；未修 10 门；在读 2 门</div>
<ul class="treeview"></ul>
<script>
\$("<li id='limain' fxfyqjd_id='' ><div class='title' xfyqjd_id='main' jdkcsx='' leaf='' sfmjd='0'><p class='title1' id='pmain' yxxf='20' yqzdxf='100' sftg='0'>" +
  "主修&nbsp;" + "</p></div></li>");
\$("<li id='liplan' fxfyqjd_id='main' ><div class='title' xfyqjd_id='plan' jdkcsx='1' leaf='' sfmjd='1'><p class='title1' id='pplan' yxxf='3' yqzdxf='6' sftg='0'>" +
  "计划课程&nbsp;" + "</p></div></li>");
\$("<li id='liother' fxfyqjd_id='main' ><div class='title' xfyqjd_id='other' jdkcsx='4' leaf='' sfmjd='1'><p class='title1' id='pother' yxxf='1' yqzdxf='2' sftg='0'>" +
  "通识课程&nbsp;" + "</p></div></li>");
\$("<li id='liqtkcxfyq' fxfyqjd_id='' ><div class='title' xfyqjd_id='qtkcxfyq' jdkcsx='1' leaf='' sfmjd='1'><p class='title1' id='pqtkcxfyq' yxxf='' yqzdxf='' sftg=''>" +
  "其他课程" + "</p></div></li>");
// zgzsxx 资格证书信息由单独分支生成。
</script></body></html>
''';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('GPA display setting defaults off and is stored', () async {
    final service = AcademicProgressDisplaySettingsService();
    expect(await service.loadShowGpa(), isFalse);
    expect(await service.loadShowRanking(), isFalse);
    await service.saveShowGpa(true);
    await service.saveShowRanking(true);
    expect(await service.loadShowGpa(), isTrue);
    expect(await service.loadShowRanking(), isTrue);
  });

  test('parses tree, summary and course response', () {
    final index = AcademicProgressParser.parseIndex(_index);
    expect(index.nodes.map((node) => node.name), [
      '主修',
      '计划课程',
      '通识课程',
      '资格证书信息',
      '其他课程',
    ]);
    expect(index.nodes.where((node) => node.isLeaf).length, 4);
    expect(index.gpa, '3.4');
    expect(index.plannedCourses, 20);
    expect(index.passedCourses, 8);
    expect(index.ongoingCourses, 2);
    expect(index.notTakenCourses, 10);

    final courses = AcademicProgressParser.parseCourses(
      '[{"KCH_ID":"C1","KCH":"C1","KCMC":"示例课程",'
      '"XF":"2.0","XDZT":"4","CJ":"90","JD":4}]',
    );
    expect(courses.single.name, '示例课程');
    expect(courses.single.statusLabel, '已修');
    expect(courses.single.gradePoint, '4');
    expect(AcademicProgressParser.parseCertificates('[]'), isEmpty);
    final certificates = AcademicProgressParser.parseCertificates(
      '[{"XMMC":"英语等级考试","SFHD":"已获得"}]',
    );
    expect(certificates.single.name, '英语等级考试');
    expect(certificates.single.acquisitionStatus, '已获得');
  });

  test('fetches each leaf with the matching endpoint and form fields',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response.bytes(utf8.encode(_index), 200,
            headers: {'content-type': 'text/html;charset=UTF-8'});
      }
      expect(request.headers['cookie'], 'JSESSIONID=test');
      if (request.url.path.endsWith('cxZgzsInfo.html')) {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response.bytes(
        utf8.encode('[{"KCH_ID":"C1","KCH":"C1","KCMC":"示例课程",'
            '"XF":"2.0","XDZT":"1"}]'),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = AcademicProgressApiClient(
      authService: _AuthWithCookie(),
      httpClient: client,
    );

    final progress = await api.fetchProgress();
    expect(progress.nodes.length, 5);
    expect(progress.nodes.where((node) => node.courses.isNotEmpty).length, 3);
    expect(progress.certificates, isEmpty);
    expect(requests.length, 5);
    expect(
        requests
            .where(
                (request) => request.url.path.endsWith('cxJxzxjhxfyqKcxx.html'))
            .length,
        2);
    expect(
        requests
            .where((request) =>
                request.url.path.endsWith('cxJxzxjhxfyqFKcxx.html'))
            .length,
        1);
    final otherCoursesRequest =
        requests.where((request) => request.method == 'POST').singleWhere(
              (request) => request.bodyFields['xfyqjd_id'] == 'qtkcxfyq',
            );
    expect(otherCoursesRequest.bodyFields['cjlrxn'], '2026');
    expect(otherCoursesRequest.bodyFields['cjlrxq'], '3');
    expect(otherCoursesRequest.bodyFields['xh_id'], 'DEMO0001');
    expect(
        requests
            .where((request) => request.url.path.endsWith('cxZgzsInfo.html')),
        hasLength(1));
  });

  test(
      'QR identity lookup reads only the index without fetching or caching data',
      () async {
    final requests = <http.Request>[];
    final api = AcademicProgressApiClient(
      authService: _AuthWithCookie(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          '<form id="form"><input name="xh_id" value=" QR_ACCOUNT "></form>',
          200,
        );
      }),
    );
    expect(await api.fetchAuthenticatedStudentId(), 'QR_ACCOUNT');
    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(requests.single.headers['cookie'], 'JSESSIONID=test');
    final preferences = await SharedPreferences.getInstance();
    expect(
        preferences.containsKey(AcademicProgressRepository.cacheKey), isFalse);
    expect(
        preferences.containsKey(AcademicRankingRepository.cacheKey), isFalse);
  });

  test('QR identity lookup rejects missing identity and expired login',
      () async {
    var response = '<form id="form"></form>';
    final api = AcademicProgressApiClient(
      authService: _AuthWithCookie(),
      httpClient: MockClient((_) async => http.Response(response, 200)),
    );
    await expectLater(api.fetchAuthenticatedStudentId(),
        throwsA(isA<AcademicApiException>()));
    response = '<html>newsso.shu.edu.cn/oauth2/login</html>';
    await expectLater(api.fetchAuthenticatedStudentId(),
        throwsA(isA<AcademicAuthException>()));
  });

  testWidgets('restores the session before automatic and manual refresh',
      (tester) async {
    final firstRestore = Completer<void>();
    final secondRestore = Completer<void>();
    var restores = 0;
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    final ranking = _RefreshingRankingRepository(
      fetch: () async => DemoAcademicRankingRepository().ranking,
    );
    final profile = _StudentProfileRepository(
      refreshed: _LongStudentProfileRepository.longProfile,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: progress,
        rankingRepository: ranking,
        studentProfileRepository: profile,
        restoreSession: () =>
            ++restores == 1 ? firstRestore.future : secondRestore.future,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pump();

    final indicator = find.byKey(const ValueKey('academic-refresh-indicator'));
    expect(restores, 1);
    expect(progress.requests, 0);
    expect(ranking.requests, 0);
    expect(profile.requests, 0);
    expect(indicator, findsOneWidget);
    expect(find.ancestor(of: indicator, matching: find.byType(AppBar)),
        findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(indicator).value, isNull);
    await tester.tap(find.byTooltip('更多'));
    await tester.pump(const Duration(milliseconds: 400));
    final refreshTile = find.ancestor(
      of: find.text('刷新学业信息'),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(refreshTile).enabled, isFalse);
    expect(restores, 1);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(milliseconds: 400));

    firstRestore.complete();
    await tester.pumpAndSettle();
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    expect(profile.requests, 1);
    expect(indicator, findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await _tapRefresh(tester);
    expect(restores, 2);
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    expect(profile.requests, 1);
    expect(indicator, findsOneWidget);
    secondRestore.complete();
    await tester.pumpAndSettle();
    expect(progress.requests, 2);
    expect(ranking.requests, 2);
    expect(profile.requests, 2);
    expect(indicator, findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('refresh indicator never moves the page content', (tester) async {
    final restores = [Completer<void>(), Completer<void>()];
    final rankings = [
      Completer<AcademicRanking>(),
      Completer<AcademicRanking>(),
    ];
    var restoreCount = 0;
    var rankingCount = 0;
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    final ranking = _RefreshingRankingRepository(
      fetch: () => rankings[rankingCount++].future,
    );
    final profile = DemoAcademicStudentProfileRepository();
    Widget page(bool active) => MaterialApp(
          home: AcademicProgressPage(
            active: active,
            repository: progress,
            rankingRepository: ranking,
            studentProfileRepository: profile,
            restoreSession: () => restores[restoreCount++].future,
            onLoginRequired: () async {},
          ),
        );
    final indicator = find.byKey(const ValueKey('academic-refresh-indicator'));
    final overview = find.text('学业总览');

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    final contentPosition = tester.getTopLeft(overview);
    expect(indicator, findsNothing);

    await tester.pumpWidget(page(true));
    await tester.pump();
    for (var cycle = 0; cycle < restores.length; cycle++) {
      if (cycle > 0) await _tapRefresh(tester);

      // Keep session restoration and the final request pending separately so
      // both loading phases must preserve the idle page's position.
      expect(restoreCount, cycle + 1);
      expect(rankingCount, cycle);
      expect(indicator, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(indicator).value, isNull);
      expect(tester.getTopLeft(overview), contentPosition);

      restores[cycle].complete();
      await tester.pump();
      await tester.pump();
      expect(rankingCount, cycle + 1);
      expect(indicator, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(indicator).value, isNull);
      expect(tester.getTopLeft(overview), contentPosition);

      rankings[cycle].complete(DemoAcademicRankingRepository().ranking);
      await tester.pumpAndSettle();
      expect(indicator, findsNothing);
      expect(tester.getTopLeft(overview), contentPosition);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic refresh reports session restoration failure',
      (tester) async {
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: progress,
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        restoreSession: () async => throw StateError('cookie unavailable'),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(progress.requests, 0);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
        find.byKey(const ValueKey('academic-refresh-indicator')), findsNothing);
    expect(find.text('学业总览'), findsOneWidget);
  });

  testWidgets('automatic refresh reports request failures and preserves cache',
      (tester) async {
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => throw const AcademicApiException('offline'),
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: progress,
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        restoreSession: _restoreSession,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(progress.requests, 1);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('学业总览'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('academic-refresh-indicator')), findsNothing);
  });

  testWidgets('indicator stays visible until all refresh requests finish',
      (tester) async {
    final rankingResult = Completer<AcademicRanking>();
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: progress,
        rankingRepository:
            _RefreshingRankingRepository(fetch: () => rankingResult.future),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        restoreSession: _restoreSession,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(progress.requests, 1);
    expect(find.byKey(const ValueKey('academic-refresh-indicator')),
        findsOneWidget);
    rankingResult.complete(DemoAcademicRankingRepository().ranking);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('academic-refresh-indicator')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('automatic authentication failure reports without opening login',
      (tester) async {
    var logins = 0;
    final delayedRanking = Completer<AcademicRanking>();
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: _RefreshingProgressRepository(
          cached: DemoAcademicProgressRepository().progress,
          fetch: () async => throw const AcademicAuthException(),
        ),
        rankingRepository:
            _RefreshingRankingRepository(fetch: () => delayedRanking.future),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        restoreSession: _restoreSession,
        onLoginRequired: () async => logins++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(logins, 0);
    expect(find.text('学业信息同步失败，请重新登录校园账户'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('academic-refresh-indicator')), findsNothing);
    delayedRanking.complete(DemoAcademicRankingRepository().ranking);
    await tester.pump();
  });

  testWidgets('an inactive page refreshes once on first activation',
      (tester) async {
    var restores = 0;
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    Widget page(bool active) => MaterialApp(
          home: AcademicProgressPage(
            active: active,
            repository: progress,
            rankingRepository: DemoAcademicRankingRepository(),
            studentProfileRepository: DemoAcademicStudentProfileRepository(),
            restoreSession: () async {
              restores++;
            },
            onLoginRequired: () async {},
          ),
        );
    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(restores, 0);
    expect(progress.requests, 0);
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(restores, 1);
    expect(progress.requests, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('changing ranking visibility does not fetch missing ranking',
      (tester) async {
    final ranking = _RefreshingRankingRepository(
      fetch: () async => DemoAcademicRankingRepository().ranking,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: ranking,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示排名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(ranking.requests, 0);
    expect(find.text('学院排名'), findsOneWidget);
    expect(find.text('暂无排名'), findsOneWidget);
  });

  for (final (theme, background) in [
    (ShuYoThemes.byId(ShuYoThemes.defaultId), null),
    (ShuYoThemes.byId(ShuYoThemes.systemDarkId), null),
    (
      const CustomBackground(
        imagePath: '',
        opacity: 50,
        background: Color(0xFF777777),
        surface: Color(0xFFBBBBBB),
        text: Colors.black,
        accent: Colors.blue,
      ).theme,
      const CustomBackground(
        imagePath: '',
        opacity: 50,
        background: Color(0xFF777777),
        surface: Color(0xFFBBBBBB),
        text: Colors.black,
        accent: Colors.blue,
      ),
    ),
  ]) {
    testWidgets('student card matches home card for ${theme.id}',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: theme.themeData(),
        builder: (_, child) => CustomBackgroundScope(
          settings: background,
          child: child!,
        ),
        home: Scaffold(
          body: Row(children: [
            Expanded(
              child: HomeDashboardPage(
                hasAcademicAccount: false,
                isAcademicLoginCompleting: false,
                onLogin: () {},
                onOpenAcademicSystem: () {},
                onOpenAnnouncements: () {},
                onOpenEmptyClassroom: () {},
                onOpenOtp: () {},
                todayCourseContent: '今日无课',
                announcementContent: '查看公告',
              ),
            ),
            Expanded(
              child: AcademicProgressPage(
                autoRefreshEnabled: false,
                restoreSession: _restoreSession,
                repository: DemoAcademicProgressRepository(),
                studentProfileRepository:
                    DemoAcademicStudentProfileRepository(),
                onLoginRequired: () async {},
              ),
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      final homeCard = tester.widget<Card>(find.descendant(
        of: find.byKey(const ValueKey('home-card:overview')),
        matching: find.byType(Card),
      ));
      final studentCard =
          tester.widget<Card>(find.byKey(const ValueKey('student-info-card')));
      expect(studentCard.color, homeCard.color);
      expect(studentCard.elevation, homeCard.elevation);
      expect(studentCard.shadowColor, homeCard.shadowColor);
      expect(studentCard.surfaceTintColor, homeCard.surfaceTintColor);
      expect(studentCard.shape, homeCard.shape);
      expect(studentCard.clipBehavior, homeCard.clipBehavior);
    });
  }

  testWidgets('shows an elevated student card before inline credit progress',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    final heading = find.text('学业总览');
    final name = find.text('示例同学');
    final category = find.text('本科生');
    final studentId = find.text('DEMO0001');
    final details = find.text('示例专业 · 示例学院');
    final credits = find.text('学分');
    final studentCard = find.byKey(const ValueKey('student-info-card'));
    expect(heading, findsOneWidget);
    expect(name, findsOneWidget);
    expect(category, findsOneWidget);
    expect(
        find.byKey(const ValueKey('student-category-badge')), findsOneWidget);
    final badge = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('student-category-badge')));
    final badgeColor = (badge.decoration as BoxDecoration).color!;
    final categoryStyle = tester.widget<Text>(category).style!;
    expect(badgeColor.a, 1);
    expect(categoryStyle.foreground, isNull);
    expect(categoryStyle.color!.a, 1);
    expect(categoryStyle.color, isNot(badgeColor));
    expect(studentId, findsOneWidget);
    expect(details, findsOneWidget);
    final nameStyle = tester.widget<Text>(name).style!;
    final studentIdStyle = tester.widget<Text>(studentId).style!;
    final detailsStyle = tester.widget<Text>(details).style!;
    expect(nameStyle.fontSize, greaterThan(22));
    expect(nameStyle.fontWeight, FontWeight.w600);
    expect(studentIdStyle.fontSize, lessThan(detailsStyle.fontSize!));
    expect(categoryStyle.fontSize, 10);
    expect(categoryStyle.fontSize, lessThan(studentIdStyle.fontSize!));
    expect(credits, findsOneWidget);
    expect(find.text('已获学分'), findsNothing);
    expect(find.text('要求学分'), findsNothing);
    expect(find.textContaining('2025级'), findsNothing);
    expect(studentCard, findsOneWidget);
    expect(tester.widget<Card>(studentCard).elevation, greaterThan(0));
    expect(find.descendant(of: studentCard, matching: name), findsOneWidget);
    expect(
        find.descendant(of: studentCard, matching: studentId), findsOneWidget);
    expect(find.descendant(of: studentCard, matching: details), findsOneWidget);
    final creditValue = tester
        .widget<Text>(find.byKey(const ValueKey('academic-credit-value')));
    final creditProgress =
        find.byKey(const ValueKey('academic-credit-progress'));
    expect(creditValue.textSpan!.toPlainText(), '62/160');
    final creditSpans =
        (creditValue.textSpan! as TextSpan).children!.cast<TextSpan>();
    final accent = tester.element(credits).shuyoColors.accent;
    expect(creditSpans.first.text, '62');
    expect(creditSpans.first.style?.color, accent);
    expect(
        creditSpans.skip(1).map((span) => span.toPlainText()).join(), '/160');
    for (final span in creditSpans.skip(1)) {
      expect(span.style?.color ?? creditValue.style?.color, isNot(accent));
    }
    expect(creditProgress, findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('academic-credit-value'))).dy,
      closeTo(tester.getCenter(creditProgress).dy, 1),
    );
    expect(
      tester.getTopLeft(credits).dx -
          tester
              .getTopRight(
                  find.byKey(const ValueKey('academic-credit-value-box')))
              .dx,
      closeTo(4, 0.01),
    );
    expect(
      tester.getTopLeft(creditProgress).dx - tester.getTopRight(credits).dx,
      closeTo(10, 0.01),
    );
    expect(tester.getBottomLeft(studentCard).dy,
        lessThan(tester.getTopLeft(heading).dy));
    expect(tester.getBottomLeft(heading).dy,
        lessThan(tester.getTopLeft(credits).dy));
    expect(
        tester.getCenter(name).dy, closeTo(tester.getCenter(category).dy, 2));
    expect(
        tester.getTopRight(name).dx, lessThan(tester.getTopLeft(category).dx));
    expect(tester.getBottomLeft(name).dy,
        lessThan(tester.getTopLeft(studentId).dy));
    expect(tester.getBottomLeft(studentId).dy,
        lessThan(tester.getTopLeft(details).dy));
    expect(tester.getBottomLeft(details).dy,
        lessThan(tester.getTopLeft(credits).dy));
    expect(find.byIcon(Icons.school_outlined), findsOneWidget);
    final banner = find.ancestor(of: name, matching: find.byType(Row)).first;
    expect(
      find.descendant(of: banner, matching: find.byIcon(Icons.chevron_right)),
      findsNothing,
    );
    expect(find.textContaining('同步于'), findsNothing);
    expect(find.textContaining('数据仅供学业修读参考'), findsNothing);
    final readingHeading = find.text('修读情况');
    final counts = find.text('计划 40 门 · 已修 16 门 · 在修 5 门 · 未修 19 门');
    final firstNode = find.byKey(const ValueKey('progress-node-demo-main'));
    expect(counts, findsOneWidget);
    expect(tester.getBottomLeft(readingHeading).dy,
        lessThan(tester.getTopLeft(counts).dy));
    expect(tester.getBottomLeft(counts).dy,
        lessThan(tester.getTopLeft(firstNode).dy));
  });

  testWidgets('student banner accommodates long details on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: _LongStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('示例姓名'), findsOneWidget);
    expect(find.text('本科生'), findsOneWidget);
    expect(find.text('DEMO0001'), findsOneWidget);
    expect(
      find.text('很长的专业名称用于验证窄屏上的文本布局 · 很长的学院名称用于验证窄屏上的文本布局'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a graduate badge from the student profile',
      (tester) async {
    const graduate = AcademicStudentProfile(
      studentId: 'DEMO0001',
      studentName: '示例姓名',
      grade: '2025',
      academicLevel: '硕士',
      majorName: '示例专业',
      collegeName: '示例学院',
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: _StudentProfileRepository(cached: graduate),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('研究生'), findsOneWidget);
    expect(find.text('本科生'), findsNothing);
    expect(find.text('示例专业 · 示例学院'), findsOneWidget);
    expect(find.textContaining('2025级'), findsNothing);
  });

  testWidgets('does not invent a category when the profile level is missing',
      (tester) async {
    const missingLevel = AcademicStudentProfile(
      studentId: 'DEMO0001',
      studentName: '示例姓名',
      grade: '2025',
      majorName: '示例专业',
      collegeName: '示例学院',
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository:
            _StudentProfileRepository(cached: missingLevel),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('示例姓名'), findsOneWidget);
    expect(find.text('本科生'), findsNothing);
    expect(find.text('研究生'), findsNothing);
    expect(find.byKey(const ValueKey('student-category-badge')), findsNothing);
  });

  testWidgets('uses the matching schedule name when the profile is unavailable',
      (tester) async {
    final profile = _StudentProfileRepository();
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: profile,
        scheduleRepository: _scheduleWithName('DEMO0001', '课表姓名'),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(profile.requests, 0);
    expect(find.text('课表姓名'), findsOneWidget);
    expect(find.text('学生'), findsNothing);
  });

  testWidgets('prefers a nonempty profile name over the schedule name',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        scheduleRepository: _scheduleWithName('DEMO0001', '课表姓名'),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('示例同学'), findsOneWidget);
    expect(find.text('课表姓名'), findsNothing);
  });

  testWidgets('does not display a schedule name from another account',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        studentProfileRepository: _StudentProfileRepository(),
        scheduleRepository: _scheduleWithName('OTHER', '其他人姓名'),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('其他人姓名'), findsNothing);
    expect(find.text('DEMO0001'), findsOneWidget);
  });

  testWidgets('refreshes a cached profile whose name is empty', (tester) async {
    const emptyName = AcademicStudentProfile(
      studentId: 'DEMO0001',
      studentName: ' ',
      grade: '2025',
      majorName: '示例专业',
      collegeName: '示例学院',
    );
    final profile = _StudentProfileRepository(
      cached: emptyName,
      refreshed: _LongStudentProfileRepository.longProfile,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: profile,
        scheduleRepository: _scheduleWithName('DEMO0001', '课表姓名'),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(profile.requests, 1);
    expect(find.text('示例姓名'), findsOneWidget);
    expect(find.text('课表姓名'), findsNothing);
  });

  testWidgets('refreshes a cached profile whose grade is empty',
      (tester) async {
    const missingGrade = AcademicStudentProfile(
      studentId: 'DEMO0001',
      studentName: '示例姓名',
      grade: '',
      academicLevel: '本科',
      majorName: '示例专业',
      collegeName: '示例学院',
    );
    final profile = _StudentProfileRepository(
      cached: missingGrade,
      refreshed: _LongStudentProfileRepository.longProfile,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: profile,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(profile.requests, 1);
    expect(
      find.text('很长的专业名称用于验证窄屏上的文本布局 · 很长的学院名称用于验证窄屏上的文本布局'),
      findsOneWidget,
    );
  });

  testWidgets('profile refresh failure reports partial success and keeps cache',
      (tester) async {
    final profile = _StudentProfileRepository(
      cached: _LongStudentProfileRepository.longProfile,
      error: const AcademicApiException('profile offline'),
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: profile,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(profile.requests, 0);
    await _tapRefresh(tester);
    await tester.pumpAndSettle();

    expect(profile.requests, 1);
    expect(find.text('学籍信息获取失败，请稍后重试'), findsOneWidget);
    expect(find.text('学业信息已同步'), findsNothing);
    expect(find.text('示例姓名'), findsOneWidget);
    expect(find.text('本科生'), findsOneWidget);
    expect(
      find.text('很长的专业名称用于验证窄屏上的文本布局 · 很长的学院名称用于验证窄屏上的文本布局'),
      findsOneWidget,
    );
  });

  testWidgets('profile authentication failure requests login once on refresh',
      (tester) async {
    var logins = 0;
    final profile = _StudentProfileRepository(
      cached: _LongStudentProfileRepository.longProfile,
      error: const AcademicAuthException(),
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        studentProfileRepository: profile,
        onLoginRequired: () async => logins++,
      ),
    ));
    await tester.pumpAndSettle();
    expect(profile.requests, 0);
    await _tapRefresh(tester);
    await tester.pumpAndSettle();

    expect(profile.requests, 1);
    expect(logins, 1);
    expect(find.text('示例姓名'), findsOneWidget);
    expect(find.text('学业信息已同步'), findsNothing);
  });

  testWidgets('browses categories and refreshes from the More menu',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('平均绩点'), findsNothing);
    expect(find.text('公共基础课程'), findsOneWidget);
    await tester.tap(find.text('公共基础课程'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('progress-node-demo-basic')),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(find.text('大学英语'), findsOneWidget);
    expect(find.text('已修'), findsOneWidget);
    expect(find.text('在修'), findsOneWidget);
    expect(find.text('待修'), findsOneWidget);
    expect(find.text('公共基础课 · 2.0 学分'), findsOneWidget);
    final statusRect = tester.getRect(find.text('已修'));
    final dotRect = tester
        .getRect(find.byKey(const ValueKey('progress-course-dot-DEMO101')));
    final courseNameRect = tester.getRect(find.text('大学英语'));
    expect((dotRect.center.dy - courseNameRect.center.dy).abs(), lessThan(3));
    final courseTapRect =
        tester.getRect(find.byKey(const ValueKey('progress-course-DEMO101')));
    final nextCourseTapRect =
        tester.getRect(find.byKey(const ValueKey('progress-course-DEMO102')));
    expect(courseTapRect.bottom, closeTo(nextCourseTapRect.top, 0.01));
    expect(courseNameRect.left - dotRect.center.dx, closeTo(29, 0.01));
    expect(courseTapRect.left,
        closeTo((dotRect.center.dx + courseNameRect.left) / 2, 1));
    expect(courseTapRect.left, greaterThan(dotRect.right));
    expect(courseTapRect.left - dotRect.right, lessThan(20));
    expect(courseTapRect.left, greaterThan(statusRect.right));
    expect(
      find.ancestor(of: find.text('已修'), matching: find.byType(InkWell)),
      findsNothing,
    );
    await tester.tap(find.text('已修'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('progress-course-sheet')), findsOneWidget);
    Navigator.of(
            tester.element(find.byKey(const ValueKey('progress-course-sheet'))))
        .pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('大学英语'));
    await tester.pumpAndSettle();
    expect(find.text('成绩'), findsOneWidget);
    expect(find.text('88'), findsOneWidget);
    final sheet = find.byKey(const ValueKey('progress-course-sheet'));
    expect(tester.getSize(sheet).width,
        tester.view.physicalSize.width / tester.view.devicePixelRatio);
    Navigator.of(tester.element(find.text('88'))).pop();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('资格证书信息'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('资格证书信息'));
    await tester.pumpAndSettle();
    expect(find.text('暂无资格证书信息'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('显示设置'), findsOneWidget);
    expect(find.text('刷新学业信息'), findsOneWidget);
    expect(tester.getTopLeft(find.text('显示设置')).dy,
        lessThan(tester.getTopLeft(find.text('刷新学业信息')).dy));
    await tester.tap(find.text('刷新学业信息'));
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('暂无资格证书信息'), findsOneWidget);
  });

  testWidgets('course details cover the gesture navigation area',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共基础课程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大学英语'));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey('progress-course-sheet'));
    expect(tester.getBottomLeft(sheet).dy, 844);
    final scrollView = tester.widget<SingleChildScrollView>(
      find.descendant(of: sheet, matching: find.byType(SingleChildScrollView)),
    );
    final contentPadding = scrollView.child! as Padding;
    expect(contentPadding.padding.resolve(TextDirection.ltr).bottom, 62);
  });

  testWidgets('display settings control GPA only in the overview',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('平均绩点'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    final creditPosition = tester.getTopLeft(find.text('学分'));
    await tester.tap(find.text('公共基础课程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大学英语'));
    await tester.pumpAndSettle();
    expect(find.text('绩点'), findsOneWidget);
    Navigator.of(
            tester.element(find.byKey(const ValueKey('progress-course-sheet'))))
        .pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '显示设置')).onTap,
      isNull,
    );
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    final toggle = tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '显示绩点'));
    expect(toggle.value, isFalse);
    expect(toggle.overlayColor?.resolve({WidgetState.pressed}),
        Colors.transparent);
    await tester.tap(find.text('显示绩点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('平均绩点'), findsOneWidget);
    expect(tester.getTopLeft(find.text('学分')), creditPosition);
    expect(find.byType(Divider), findsOneWidget);
    expect(tester.getBottomLeft(find.byType(LinearProgressIndicator)).dy,
        lessThan(tester.getCenter(find.byType(Divider)).dy));
    expect(tester.getCenter(find.byType(Divider)).dy,
        lessThan(tester.getTopLeft(find.text('平均绩点')).dy));
    _expectInlineEdgeMetric(
      tester,
      label: '平均绩点',
      valueKey: 'academic-gpa-value',
      edgeX: tester.getRect(find.byType(Divider)).left,
    );
    expect(
        await AcademicProgressDisplaySettingsService().loadShowGpa(), isTrue);
    await tester.tap(find.text('大学英语'));
    await tester.pumpAndSettle();
    expect(find.text('绩点'), findsOneWidget);
  });

  testWidgets('ranking and GPA share a separate row below credit progress',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('学院排名'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    final creditPosition = tester.getTopLeft(find.text('学分'));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    final rankingToggle = tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '显示排名'));
    expect(rankingToggle.value, isFalse);
    await tester.tap(find.text('显示排名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('学院排名'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    void expectMutedDenominator(String value, String numerator, String suffix) {
      final finder = find.text(value);
      final text = tester.widget<Text>(finder);
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      final colors = tester.element(finder).shuyoColors;
      expect(spans.first.text, numerator);
      expect(spans.first.style?.color ?? text.style?.color,
          isNot(colors.textSecondary));
      expect(spans.skip(1).map((span) => span.toPlainText()).join(), suffix);
      for (final span in spans.skip(1)) {
        expect(span.style?.color, colors.textSecondary);
      }
    }

    expectMutedDenominator('42/260', '42', '/260');
    expect(find.text('共260人'), findsNothing);
    expect(tester.getTopLeft(find.text('学分')), creditPosition);
    expect(find.byType(Divider), findsOneWidget);
    expect(tester.getBottomLeft(find.byType(LinearProgressIndicator)).dy,
        lessThan(tester.getCenter(find.byType(Divider)).dy));
    expect(tester.getCenter(find.byType(Divider)).dy,
        lessThan(tester.getTopLeft(find.text('学院排名')).dy));
    _expectInlineEdgeMetric(
      tester,
      label: '学院排名',
      valueKey: 'academic-ranking-value',
      edgeX: tester.getRect(find.byType(Divider)).right,
      rightAligned: true,
    );
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('专业排名'), findsOneWidget);
    expect(find.text('12/80'), findsOneWidget);
    expectMutedDenominator('12/80', '12', '/80');
    expect(find.text('共80人'), findsNothing);
    _expectInlineEdgeMetric(
      tester,
      label: '专业排名',
      valueKey: 'academic-ranking-value',
      edgeX: tester.getRect(find.byType(Divider)).right,
      rightAligned: true,
    );

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示绩点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final gpaPosition = tester.getTopLeft(find.text('平均绩点'));
    final rankingPosition = tester.getTopLeft(find.text('专业排名'));
    expect(find.text('3.65/4.0'), findsOneWidget);
    expectMutedDenominator('3.65/4.0', '3.65', '/4.0');
    expect(gpaPosition.dy, closeTo(rankingPosition.dy, 1));
    expect(gpaPosition.dx, lessThan(rankingPosition.dx));
    _expectSimilarMetricTextGaps(tester, '专业排名');
    expect(tester.getCenter(find.byType(Divider)).dy, lessThan(gpaPosition.dy));
    final metricBounds = tester.getRect(find.byType(Divider));
    _expectInlineEdgeMetric(
      tester,
      label: '平均绩点',
      valueKey: 'academic-gpa-value',
      edgeX: metricBounds.left,
    );
    _expectInlineEdgeMetric(
      tester,
      label: '专业排名',
      valueKey: 'academic-ranking-value',
      edgeX: metricBounds.right,
      rightAligned: true,
    );
    await tester.tap(find.byKey(const ValueKey('academic-ranking-value')));
    await tester.pumpAndSettle();
    expect(find.text('学院排名'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expectMutedDenominator('42/260', '42', '/260');
    _expectSimilarMetricTextGaps(tester, '学院排名');
    final rankingHotArea =
        find.byKey(const ValueKey('academic-ranking-toggle'));
    final rankingToggleBounds = tester.getRect(rankingHotArea);
    expect(rankingToggleBounds.height, lessThan(44));
    expect(
        rankingToggleBounds.height,
        closeTo(
            tester
                .getSize(find.byKey(const ValueKey('academic-gpa-value-box')))
                .height,
            0.01));
    expect(tester.widget<GestureDetector>(rankingHotArea).behavior,
        HitTestBehavior.opaque);
    await tester.tap(find.text('学院排名'));
    await tester.pumpAndSettle();
    expect(find.text('专业排名'), findsOneWidget);
    expect(find.text('12/80'), findsOneWidget);
    await tester.tapAt(rankingToggleBounds.topLeft + const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('学院排名'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(tester.getTopLeft(find.text('学分')), creditPosition);
    expect(await AcademicProgressDisplaySettingsService().loadShowRanking(),
        isTrue);
  });

  testWidgets('metric geometry and font size stay fixed across values and taps',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showGpaKey: true,
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    AcademicProgress progressWithGpa(String gpa) => AcademicProgress.fromJson(
        DemoAcademicProgressRepository().progress.toJson()..['gpa'] = gpa);
    AcademicRanking rankingWithValues(
            int collegeRank, int collegeCount, int majorRank, int majorCount) =>
        AcademicRanking.fromJson(
            DemoAcademicRankingRepository().ranking.toJson()
              ..['collegeRank'] = collegeRank
              ..['collegeCount'] = collegeCount
              ..['majorRank'] = majorRank
              ..['majorCount'] = majorCount);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: _RefreshingProgressRepository(
          cached: progressWithGpa('1.11'),
          fetch: () async => progressWithGpa('3.88'),
        ),
        rankingRepository: _RefreshingRankingRepository(
          cached: rankingWithValues(88888, 99999, 1, 9),
          fetch: () async => rankingWithValues(2, 99, 3333, 5555),
        ),
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    final gpaValue = find.byKey(const ValueKey('academic-gpa-value'));
    final rankingValue = find.byKey(const ValueKey('academic-ranking-value'));
    final rankingHotArea =
        find.byKey(const ValueKey('academic-ranking-toggle'));
    Map<String, Rect> bounds() => {
          'gpaLabel': tester.getRect(find.text('平均绩点')),
          'rankingLabel': tester.getRect(find.text('学院排名').evaluate().isNotEmpty
              ? find.text('学院排名')
              : find.text('专业排名')),
          'gpaBox': tester
              .getRect(find.byKey(const ValueKey('academic-gpa-value-box'))),
          'rankingBox': tester.getRect(
              find.byKey(const ValueKey('academic-ranking-value-box'))),
          'rankingIcon': tester.getRect(find.byIcon(Icons.swap_horiz)),
          'rankingHotArea': tester.getRect(rankingHotArea),
          'divider': tester.getRect(find.byType(Divider)),
          'nextSection': tester.getRect(find.text('修读情况')),
        };
    final initialBounds = bounds();
    final initialGpaFont = tester.widget<Text>(gpaValue).style!;
    final initialRankingFont = tester.widget<Text>(rankingValue).style!;
    final initialGpaHeight = tester.getSize(gpaValue).height;
    final initialRankingHeight = tester.getSize(rankingValue).height;
    List<double> scale(Finder finder) {
      final matrix = tester.renderObject(finder).getTransformTo(null).storage;
      return [matrix[0], matrix[5]];
    }

    final initialGpaScale = scale(gpaValue);
    final initialRankingScale = scale(rankingValue);
    expect(initialBounds['rankingHotArea']!.height, lessThan(44));
    expect(initialBounds['rankingHotArea']!.height,
        closeTo(initialGpaHeight, 0.01));
    expect(initialGpaFont.fontFeatures?.map((feature) => feature.feature),
        contains('tnum'));
    expect(initialRankingFont.fontFeatures?.map((feature) => feature.feature),
        contains('tnum'));
    void expectStableMetrics() {
      expect(bounds(), initialBounds);
      expect(tester.widget<Text>(gpaValue).style!.fontSize,
          initialGpaFont.fontSize);
      expect(tester.widget<Text>(rankingValue).style!.fontSize,
          initialRankingFont.fontSize);
      expect(tester.getSize(gpaValue).height, initialGpaHeight);
      expect(tester.getSize(rankingValue).height, initialRankingHeight);
      expect(scale(gpaValue), initialGpaScale);
      expect(scale(rankingValue), initialRankingScale);
      expect(tester.takeException(), isNull);
    }

    expect(find.text('1.11/4.0'), findsOneWidget);
    expect(find.text('88888/99999'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('1/9'), findsOneWidget);
    _expectSimilarMetricTextGaps(tester, '专业排名');
    expectStableMetrics();
    await tester.tap(find.text('专业排名'));
    await tester.pumpAndSettle();
    expect(find.text('88888/99999'), findsOneWidget);
    expectStableMetrics();
    await tester.tap(rankingValue);
    await tester.pumpAndSettle();
    expect(find.text('1/9'), findsOneWidget);
    expectStableMetrics();
    await tester
        .tapAt(initialBounds['rankingHotArea']!.topLeft + const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('88888/99999'), findsOneWidget);
    expectStableMetrics();

    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('3.88/4.0'), findsOneWidget);
    expect(find.text('2/99'), findsOneWidget);
    expectStableMetrics();
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('3333/5555'), findsOneWidget);
    expectStableMetrics();
  });

  testWidgets('ranking failures keep academic progress and old ranking',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    final ranking = DemoAcademicRankingRepository().ranking;
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: _FailingRankingRepository(cached: ranking),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('42/260'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新学业信息'));
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(find.text('旧数据'), findsOneWidget);
  });

  testWidgets('ranking failure without cache shows a retry state',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        rankingRepository: _FailingRankingRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('学院排名'), findsOneWidget);
    expect(find.text('暂无排名'), findsOneWidget);
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('获取失败'), findsOneWidget);
    await tester.tap(find.text('学院排名'));
    await tester.pumpAndSettle();
    expect(find.text('获取失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refresh starts both requests with ranking hidden and shows progress early',
      (tester) async {
    final progressResult = Completer<AcademicProgress>();
    final rankingResult = Completer<AcademicRanking>();
    final progress =
        _RefreshingProgressRepository(fetch: () => progressResult.future);
    final ranking =
        _RefreshingRankingRepository(fetch: () => rankingResult.future);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: progress,
        rankingRepository: ranking,
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(progress.requests, 0);
    expect(ranking.requests, 0);
    await _tapRefresh(tester);
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    progressResult.complete(DemoAcademicProgressRepository().progress);
    await tester.pump();
    await tester.pump();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('学院排名'), findsNothing);
    rankingResult.completeError(const AcademicApiException('ranking offline'));
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('排名获取失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('progress failure keeps its cache while new ranking is displayed',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => throw const AcademicApiException('progress offline'),
    );
    final ranking = _RefreshingRankingRepository(
      fetch: () async => DemoAcademicRankingRepository().ranking,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: progress,
        rankingRepository: ranking,
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(ranking.requests, 0);
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(find.text('学业信息获取失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('both failed requests preserve cached progress and ranking',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    final progress = _RefreshingProgressRepository(
      cached: DemoAcademicProgressRepository().progress,
      fetch: () async => throw const AcademicApiException('progress offline'),
    );
    final ranking = _RefreshingRankingRepository(
      cached: DemoAcademicRankingRepository().ranking,
      fetch: () async => throw const AcademicApiException('ranking offline'),
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: progress,
        rankingRepository: ranking,
        studentProfileRepository: DemoAcademicStudentProfileRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(find.text('旧数据'), findsOneWidget);
    expect(find.text('学业信息、排名获取失败，请稍后重试'), findsOneWidget);
  });

  for (final restoreSession in [false, true]) {
    testWidgets(
        'both expired requests open login once without retry, restored=$restoreSession',
        (tester) async {
      var authenticated = false;
      var logins = 0;
      final progress = _RefreshingProgressRepository(
        cached: DemoAcademicProgressRepository().progress,
        fetch: () async {
          if (!authenticated) throw const AcademicAuthException();
          return DemoAcademicProgressRepository().progress;
        },
      );
      final ranking = _RefreshingRankingRepository(fetch: () async {
        if (!authenticated) throw const AcademicAuthException();
        return DemoAcademicRankingRepository().ranking;
      });
      await tester.pumpWidget(MaterialApp(
        home: AcademicProgressPage(
          autoRefreshEnabled: false,
          restoreSession: _restoreSession,
          repository: progress,
          rankingRepository: ranking,
          studentProfileRepository: DemoAcademicStudentProfileRepository(),
          onLoginRequired: () async {
            logins++;
            authenticated = restoreSession;
          },
        ),
      ));
      await tester.pumpAndSettle();
      await _tapRefresh(tester);
      await tester.pumpAndSettle();
      expect(logins, 1);
      expect(progress.requests, 1);
      expect(ranking.requests, 1);
      expect(find.text('学业总览'), findsOneWidget);
      if (restoreSession) {
        await _tapRefresh(tester);
        await tester.pumpAndSettle();
        expect(progress.requests, 2);
        expect(ranking.requests, 2);
        expect(logins, 1);
        expect(find.byType(SnackBar), findsNothing);
      }
    });
  }

  testWidgets('ranking expiration opens login and retains successful progress',
      (tester) async {
    var logins = 0;
    final progress = _RefreshingProgressRepository(
      fetch: () async => DemoAcademicProgressRepository().progress,
    );
    final ranking = _RefreshingRankingRepository(
      fetch: () async => throw const AcademicAuthException(),
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: progress,
        rankingRepository: ranking,
        onLoginRequired: () async => logins++,
      ),
    ));
    await tester.pumpAndSettle();
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(progress.requests, 1);
    expect(ranking.requests, 1);
    expect(find.text('学业总览'), findsOneWidget);
  });

  for (final outcome in ['success', 'partial failure', 'failure']) {
    testWidgets('credit progress animates only after full refresh: $outcome',
        (tester) async {
      final sample = DemoAcademicProgressRepository().progress;
      final result = Completer<AcademicProgress>();
      await tester.pumpWidget(MaterialApp(
        home: AcademicProgressPage(
          autoRefreshEnabled: false,
          restoreSession: _restoreSession,
          repository: _RefreshingProgressRepository(
            cached: sample,
            fetch: () => result.future,
          ),
          rankingRepository: DemoAcademicRankingRepository(),
          studentProfileRepository: outcome == 'partial failure'
              ? _StudentProfileRepository(
                  error: const AcademicApiException('profile offline'))
              : DemoAcademicStudentProfileRepository(),
          onLoginRequired: () async {},
        ),
      ));
      await tester.pumpAndSettle();
      final indicator = find.byKey(const ValueKey('academic-credit-progress'));
      double value() =>
          tester.widget<LinearProgressIndicator>(indicator).value!;
      final target =
          sample.mainNode!.earnedCredits! / sample.mainNode!.requiredCredits!;
      expect(value(), closeTo(target, 0.001));

      await _tapRefresh(tester);
      expect(value(), closeTo(target, 0.001));
      if (outcome == 'failure') {
        result.completeError(const AcademicApiException('progress offline'));
      } else {
        result.complete(sample);
      }
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('academic-refresh-indicator')),
          findsNothing);

      if (outcome == 'success') {
        expect(value(), closeTo(0, 0.001));
        expect(find.byType(SnackBar), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        expect(value(), greaterThan(target * 0.5));
        expect(value(), lessThan(target));
        await tester.pump(const Duration(milliseconds: 400));
        expect(value(), closeTo(target, 0.001));
      } else {
        expect(value(), closeTo(target, 0.001));
        expect(find.byType(SnackBar), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(value(), closeTo(target, 0.001));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'inline three-digit credits and optional metrics fit a narrow phone',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showGpaKey: true,
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Rect? compactValueBounds;
    Rect? compactBarBounds;
    // Ahem's wide glyphs reach the cap for both three- and two-digit credits.
    for (final credits in [(1, 10), (62, 160), (999, 999)]) {
      final json = DemoAcademicProgressRepository().progress.toJson();
      final root = (json['nodes'] as List).first as Map<String, dynamic>;
      root['earnedCredits'] = credits.$1;
      root['requiredCredits'] = credits.$2;
      final progress = AcademicProgress.fromJson(json);
      await tester.pumpWidget(MaterialApp(
        home: AcademicProgressPage(
          key: ValueKey(credits),
          autoRefreshEnabled: false,
          restoreSession: _restoreSession,
          repository: _RefreshingProgressRepository(
              cached: progress, fetch: () async => progress),
          rankingRepository: DemoAcademicRankingRepository(),
          onLoginRequired: () async {},
        ),
      ));
      await tester.pumpAndSettle();
      for (final label in ['学分', '平均绩点', '学院排名']) {
        expect(find.text(label), findsOneWidget);
      }
      final value = find.byKey(const ValueKey('academic-credit-value'));
      final valueBox = find.byKey(const ValueKey('academic-credit-value-box'));
      final bar = find.byKey(const ValueKey('academic-credit-progress'));
      expect(tester.widget<Text>(value).textSpan!.toPlainText(),
          '${credits.$1}/${credits.$2}');
      final valueBounds = tester.getRect(valueBox);
      final barBounds = tester.getRect(bar);
      final labelBounds = tester.getRect(find.text('学分'));
      final textBounds = tester.getRect(value);
      expect(valueBounds.width, closeTo(textBounds.width, 0.01));
      expect(valueBounds.width, lessThanOrEqualTo(120));
      expect(tester.getCenter(valueBox).dy, closeTo(barBounds.center.dy, 3));
      expect(labelBounds.top, lessThan(valueBounds.bottom));
      expect(labelBounds.bottom, greaterThan(valueBounds.top));
      expect(labelBounds.left - valueBounds.right, closeTo(4, 0.01));
      expect(barBounds.left - labelBounds.right, closeTo(10, 0.01));
      expect(barBounds.width, greaterThan(0));
      expect(barBounds.right, lessThanOrEqualTo(320));
      if (compactValueBounds != null && compactBarBounds != null) {
        expect(valueBounds.width, greaterThan(compactValueBounds.width));
        expect(barBounds.left, greaterThan(compactBarBounds.left));
        expect(barBounds.width, lessThan(compactBarBounds.width));
        expect(barBounds.right, closeTo(compactBarBounds.right, 0.01));
      }
      compactValueBounds ??= valueBounds;
      compactBarBounds ??= barBounds;
      expect(barBounds.bottom,
          lessThan(tester.getCenter(find.byType(Divider)).dy));
      expect(tester.getCenter(find.byType(Divider)).dy,
          lessThan(tester.getTopLeft(find.text('平均绩点')).dy));
      final metricBounds = tester.getRect(find.byType(Divider));
      _expectInlineEdgeMetric(
        tester,
        label: '平均绩点',
        valueKey: 'academic-gpa-value',
        edgeX: metricBounds.left,
      );
      _expectInlineEdgeMetric(
        tester,
        label: '学院排名',
        valueKey: 'academic-ranking-value',
        edgeX: metricBounds.right,
        rightAligned: true,
      );
      final rankingIconBounds = tester.getRect(find.byIcon(Icons.swap_horiz));
      final gpaValueBounds =
          tester.getRect(find.byKey(const ValueKey('academic-gpa-value')));
      expect(gpaValueBounds.right, lessThanOrEqualTo(rankingIconBounds.left));
      expect(
          tester
              .getSize(find.byKey(const ValueKey('academic-ranking-toggle')))
              .height,
          lessThan(44));
      expect(tester.takeException(), isNull);
    }
  });

  test('does not show another account’s cached progress', () async {
    final sample = DemoAcademicProgressRepository().progress;
    SharedPreferences.setMockInitialValues({
      AcademicProgressRepository.cacheKey: jsonEncode(sample.toJson()),
    });
    final account = AcademicAccountStore();
    await account.saveStudentId('ANOTHER');
    final repository = AcademicProgressRepository();
    expect(await repository.loadCachedProgress(), isNull);
    await account.saveStudentId('DEMO0001');
    expect((await repository.loadCachedProgress())?.studentId, 'DEMO0001');
  });

  test('older cached progress gains the certificate branch', () {
    final oldCache = DemoAcademicProgressRepository().progress.toJson()
      ..remove('certificates');
    (oldCache['nodes'] as List)
        .removeWhere((node) => (node as Map)['id'] == 'zgzsxx');
    final restored = AcademicProgress.fromJson(oldCache);
    expect(restored.node('zgzsxx')?.name, '资格证书信息');
    expect(restored.certificates, isEmpty);
  });

  testWidgets('tree rows fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共基础课程'));
    await tester.pumpAndSettle();
    expect(find.text('大学英语'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested branches expand on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: _DeepProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    final completedDot =
        find.byKey(const ValueKey('progress-node-dot-level-1'));
    final expectedGreen =
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.success;
    expect(
        (tester.widget<AnimatedContainer>(completedDot).decoration
                as BoxDecoration)
            .color,
        expectedGreen);
    for (final title in ['专业课程', '专业选修', '软件工程方向']) {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }
    expect(
        (tester.widget<AnimatedContainer>(completedDot).decoration
                as BoxDecoration)
            .color,
        expectedGreen);
    expect(find.text('大学英语'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsing a branch retracts its connected children',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        autoRefreshEnabled: false,
        restoreSession: _restoreSession,
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共基础课程'));
    await tester.pumpAndSettle();
    expect(find.text('大学英语'), findsOneWidget);
    await tester.tap(find.text('公共基础课程'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('大学英语'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('大学英语'), findsNothing);
  });
}
