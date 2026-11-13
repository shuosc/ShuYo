import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/models/academic_progress.dart';
import 'package:shuyo/data/models/academic_ranking.dart';
import 'package:shuyo/data/repositories/academic_progress_repository.dart';
import 'package:shuyo/data/repositories/academic_ranking_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_progress_api_client.dart';
import 'package:shuyo/data/services/academic_progress_display_settings_service.dart';
import 'package:shuyo/data/services/academic_progress_parser.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/features/home/academic_progress_page.dart';
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

Future<void> _tapRefresh(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('刷新学业信息'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
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

  testWidgets('changing ranking visibility does not fetch missing ranking',
      (tester) async {
    final ranking = _RefreshingRankingRepository(
      fetch: () async => DemoAcademicRankingRepository().ranking,
    );
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
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

  testWidgets('browses categories and refreshes from the More menu',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
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
        repository: DemoAcademicProgressRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('平均绩点'), findsNothing);
    final earnedX = tester.getTopLeft(find.text('已获学分')).dx;
    final requiredX = tester.getTopLeft(find.text('要求学分')).dx;
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
    expect(tester.getTopLeft(find.text('已获学分')).dx, earnedX);
    expect(tester.getTopLeft(find.text('要求学分')).dx, requiredX);
    expect(
        await AcademicProgressDisplaySettingsService().loadShowGpa(), isTrue);
    await tester.tap(find.text('大学英语'));
    await tester.pumpAndSettle();
    expect(find.text('绩点'), findsOneWidget);
  });

  testWidgets(
      'ranking starts with college, switches to major, and uses four slots',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('学院排名'), findsNothing);
    final earnedX = tester.getTopLeft(find.text('已获学分')).dx;
    final requiredX = tester.getTopLeft(find.text('要求学分')).dx;

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
    expect(find.text('共260人'), findsNothing);
    expect(tester.getTopLeft(find.text('已获学分')).dx, earnedX);
    expect(tester.getTopLeft(find.text('要求学分')).dx, requiredX);
    await tester.tap(find.text('学院排名'));
    await tester.pumpAndSettle();
    expect(find.text('专业排名'), findsOneWidget);
    expect(find.text('12/80'), findsOneWidget);
    expect(find.text('共80人'), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示绩点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final positions = [
      for (final label in ['已获学分', '要求学分', '平均绩点', '专业排名'])
        tester.getTopLeft(find.text(label)).dx,
    ];
    expect(
        positions[1] - positions[0], closeTo(positions[2] - positions[1], 1));
    expect(
        positions[2] - positions[1], closeTo(positions[3] - positions[2], 1));
    expect(await AcademicProgressDisplaySettingsService().loadShowRanking(),
        isTrue);
  });

  testWidgets('ranking failures keep academic progress and old ranking',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    final ranking = DemoAcademicRankingRepository().ranking;
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
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
        repository: progress,
        rankingRepository: ranking,
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
    expect(find.text('学业信息已同步，排名获取失败'), findsOneWidget);
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
        repository: progress,
        rankingRepository: ranking,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(ranking.requests, 0);
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(find.text('排名已同步，学业信息获取失败'), findsOneWidget);
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
        repository: progress,
        rankingRepository: ranking,
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    await _tapRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('学业总览'), findsOneWidget);
    expect(find.text('42/260'), findsOneWidget);
    expect(find.text('旧数据'), findsOneWidget);
    expect(find.text('学业信息同步失败'), findsOneWidget);
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
          repository: progress,
          rankingRepository: ranking,
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
        expect(find.text('学业信息已同步'), findsOneWidget);
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

  testWidgets('four overview metrics fit a narrow phone', (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicProgressDisplaySettingsService.showGpaKey: true,
      AcademicProgressDisplaySettingsService.showRankingKey: true,
    });
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: AcademicProgressPage(
        repository: DemoAcademicProgressRepository(),
        rankingRepository: DemoAcademicRankingRepository(),
        onLoginRequired: () async {},
      ),
    ));
    await tester.pumpAndSettle();
    for (final label in ['已获学分', '要求学分', '平均绩点', '学院排名']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
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
