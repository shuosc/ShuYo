import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_search_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _terms = [
  VodTerm(
      id: 7,
      name: '2026-2027学年第1学期',
      academicYear: '2026-2027',
      termNumber: 1,
      isCurrent: true),
  VodTerm(
      id: 6, name: '2025-2026学年第2学期', academicYear: '2025-2026', termNumber: 2),
];
const _course = VodCourse(
  teachingClassId: 101,
  termId: 7,
  name: '程序设计',
  code: 'CS101',
  teacherNames: ['教师甲'],
);

VodSearchResult _result(int id,
        {String name = '程序设计', bool playable = true, DateTime? begin}) =>
    VodSearchResult(
      course: VodCourse(
          teachingClassId: 101,
          termId: 7,
          name: name,
          code: 'CS101',
          teacherNames: ['教师甲']),
      lesson: VodLesson(
        id: id,
        teachingClassId: 101,
        name: name,
        isPlayable: playable,
        isGenerating: !playable,
        beginTime: begin ?? DateTime(2026, 10, id, 8),
        endTime: begin == null ? DateTime(2026, 10, id, 9, 40) : null,
        sectionLabel: '第1节',
        classroom: 'A101',
      ),
    );

class _Repository extends VodRepository {
  Future<List<VodSearchResult>> Function(int term, String keyword)?
      searchLoader;
  final searches = <({int termId, String keyword})>[];
  final playbackRequests = <VodLesson>[];
  int lessonRequests = 0;
  int previewRequests = 0;

  @override
  Future<List<VodTerm>> loadTerms({bool forceRefresh = false}) async => _terms;

  @override
  Future<List<VodCourse>> loadCatalog({
    required int termId,
    bool forceRefresh = false,
    void Function(List<VodCourse>)? onProgress,
  }) async =>
      [_course];

  @override
  Future<List<VodLesson>> loadCourseLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    lessonRequests++;
    return [];
  }

  @override
  Future<List<VodLesson>> loadPreviewLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    previewRequests++;
    return [];
  }

  @override
  Future<List<VodSearchResult>> searchLessons({
    required int termId,
    required String keyword,
  }) async {
    searches.add((termId: termId, keyword: keyword));
    return await searchLoader?.call(termId, keyword) ?? [];
  }

  @override
  Future<VodPlayback> preparePlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    playbackRequests.add(lesson);
    throw const VodPermissionException();
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  Future<void> Function(bool)? invalidated,
  Future<bool> Function()? login,
  double textScale = 1,
}) async {
  addTearDown(repository.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.all.first.themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: RecordingSearchPage(
      repository: repository,
      terms: _terms,
      selectedTermId: 7,
      onSessionInvalidated: invalidated,
      onLoginRequested: login,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String keyword,
    {bool keyboard = false}) async {
  await tester.enterText(
      find.byKey(const ValueKey('vod-search-query')), keyword);
  await tester.pump();
  if (keyboard) {
    await tester.testTextInput.receiveAction(TextInputAction.search);
  } else {
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
  }
  await tester.pump();
}

void main() {
  testWidgets('catalog search icon opens the search page without searching',
      (tester) async {
    final repository = _Repository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: CourseRecordingsPage(
        repository: repository,
        sessionLoader: () async => true,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-search')));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingSearchPage), findsOneWidget);
    expect(find.text('搜索录播'), findsOneWidget);
    expect(repository.searches, isEmpty);
    expect(repository.playbackRequests, isEmpty);
    final page =
        tester.widget<RecordingSearchPage>(find.byType(RecordingSearchPage));
    expect(identical(page.repository, repository), isTrue);
    expect(page.selectedTermId, 7);
  });

  testWidgets('search is explicit and keyboard submission shows dated lessons',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = (_, __) async => [
            _result(1, begin: DateTime.utc(2026, 10, 3, 2)),
            _result(3, begin: DateTime.utc(2026, 10, 3, 0)),
            _result(2, playable: false),
          ];
    await _mount(tester, repository);
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), ' 教师甲 ');
    await tester.pumpAndSettle();
    expect(repository.searches, isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.searches, [(termId: 7, keyword: '教师甲')]);
    expect(find.text('2026年10月3日 周六'), findsOneWidget);
    expect(find.text('CS101 · 教师甲'), findsNWidgets(3));
    final newest = find.byKey(const ValueKey('vod-search-result:101:3'));
    final older = find.byKey(const ValueKey('vod-search-result:101:1'));
    expect(tester.getTopLeft(newest).dy, lessThan(tester.getTopLeft(older).dy));
    expect(
        tester.getTopLeft(older).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('vod-search-result:101:2')))
            .dy));
    final generating = tester.widget<ListTile>(
        find.byKey(const ValueKey('vod-search-result:101:2')));
    expect(generating.enabled, isTrue);
    expect(generating.onTap, isNotNull);
    expect(repository.playbackRequests, isEmpty);
    expect(repository.lessonRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short keywords explain the minimum without sending a request',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await _submit(tester, '课', keyboard: true);
    await tester.pumpAndSettle();
    expect(repository.searches, isEmpty);
    expect(find.text('请输入至少 2 个字的课程或教师关键词'), findsOneWidget);
    expect(find.text('搜索课程或教师'), findsOneWidget);
  });

  testWidgets('opening a result prepares playback and previews its class',
      (tester) async {
    final result = _result(12);
    final other = _result(11);
    final repository = _Repository()
      ..searchLoader = (_, __) async => [result, other];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(repository.playbackRequests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('vod-search-result:101:12')));
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(identical(player.repository, repository), isTrue);
    expect(player.initialLesson, same(result.lesson));
    expect(player.lessons, [result.lesson, other.lesson]);
    expect(player.loadCourseCatalog, isFalse);
    expect(player.loadPreviewCatalog, isTrue);
    expect(repository.playbackRequests, [result.lesson]);
    expect(repository.lessonRequests, 0);
    expect(repository.previewRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new submission and clear both invalidate older responses',
      (tester) async {
    final old = Completer<List<VodSearchResult>>();
    final latest = Completer<List<VodSearchResult>>();
    final cleared = Completer<List<VodSearchResult>>();
    final repository = _Repository()
      ..searchLoader = (_, keyword) => switch (keyword) {
            '旧关键词' => old.future,
            '新关键词' => latest.future,
            _ => cleared.future,
          };
    await _mount(tester, repository);
    await _submit(tester, '旧关键词');
    await _submit(tester, '新关键词', keyboard: true);
    latest.complete([_result(2, name: '新结果')]);
    await tester.pumpAndSettle();
    old.complete([_result(1, name: '旧结果')]);
    await tester.pumpAndSettle();
    expect(find.text('新结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
    await _submit(tester, '清空');
    await tester.tap(find.byKey(const ValueKey('vod-search-clear')));
    await tester.pumpAndSettle();
    cleared.complete([_result(3, name: '过期结果')]);
    await tester.pumpAndSettle();
    expect(find.text('搜索课程或教师'), findsOneWidget);
    expect(find.text('过期结果'), findsNothing);
    expect(find.byKey(const ValueKey('vod-search-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late session failure after clear cannot expire current search',
      (tester) async {
    final pending = Completer<List<VodSearchResult>>();
    var invalidations = 0;
    final repository = _Repository()..searchLoader = (_, __) => pending.future;
    await _mount(tester, repository, invalidated: (_) async => invalidations++);
    await _submit(tester, '程序');
    await tester.enterText(find.byKey(const ValueKey('vod-search-query')), '');
    await tester.pumpAndSettle();
    pending.completeError(const VodSessionExpiredException());
    await tester.pumpAndSettle();
    expect(invalidations, 0);
    expect(find.text('校园账户登录已失效'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired session clears results and login reruns the query',
      (tester) async {
    var requests = 0;
    var logins = 0;
    final invalidated = <bool>[];
    final repository = _Repository()
      ..searchLoader = (_, __) async {
        if (++requests == 1) {
          throw const VodSessionExpiredException.campus(ssoExpired: true);
        }
        return [_result(4)];
      };
    await _mount(tester, repository,
        invalidated: (expired) async => invalidated.add(expired),
        login: () async {
          logins++;
          return true;
        });
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(invalidated, [true]);
    expect(find.text('校园账户登录已失效'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(repository.searches.length, 2);
    expect(
        find.byKey(const ValueKey('vod-search-result:101:4')), findsOneWidget);
    expect(find.text('校园账户登录已失效'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network error retries and an empty search has its own state',
      (tester) async {
    var requests = 0;
    final repository = _Repository()
      ..searchLoader = (_, __) async {
        if (++requests == 1) throw const VodNetworkException();
        return [];
      };
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(find.text('录播搜索失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repository.searches.length, 2);
    expect(find.text('没有找到录播'), findsOneWidget);
    expect(find.text('录播搜索失败'), findsNothing);
  });

  testWidgets(
      'term change waits for an explicit search and cancels old results',
      (tester) async {
    final pending = Completer<List<VodSearchResult>>();
    final repository = _Repository()
      ..searchLoader =
          (term, _) => term == 7 ? pending.future : Future.value([]);
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.tap(find.byKey(const ValueKey('vod-search-term-filter')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('vod-term-option:6')));
    await tester.pumpAndSettle();
    pending.complete([_result(5)]);
    await tester.pumpAndSettle();
    expect(repository.searches.length, 1);
    expect(find.text('搜索课程或教师'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pumpAndSettle();
    expect(repository.searches.last, (termId: 6, keyword: '程序'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 pixel search supports double text scale and long results',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository()
      ..searchLoader = (_, __) async => [
            _result(1, name: '程序设计与算法分析以及计算机科学基础课程'),
          ];
    await _mount(tester, repository, textScale: 2);
    expect(tester.takeException(), isNull);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('vod-search-result:101:1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
