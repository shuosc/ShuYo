import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_exception.dart';
import 'package:shuyo/features/course_recordings/course_recordings_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_search_page.dart';
import 'package:shuyo/features/course_recordings/recording_status_icon.dart';
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
        {String name = '程序设计',
        bool playable = true,
        DateTime? begin,
        int termId = 7,
        int classId = 101,
        String teachingClassName = '',
        String code = 'CS101',
        String courseNumber = '',
        List<String> teachers = const ['教师甲']}) =>
    VodSearchResult(
      courseNumber: courseNumber,
      course: VodCourse(
          teachingClassId: classId,
          termId: termId,
          name: name,
          teachingClassName: teachingClassName,
          code: code,
          teacherNames: teachers),
      lesson: VodLesson(
        id: id,
        teachingClassId: classId,
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
  final warmedCourses = <({VodCourse course, List<VodLesson> lessons})>[];
  Future<List<VodLesson>> Function(VodCourse course, bool force)? previewLoader;
  Future<VodRecordingAvailability> Function(VodCourse course, VodLesson lesson)?
      availabilityLoader;
  final verificationRequests =
      <({int termId, int classId, int lessonId, bool fresh})>[];
  final previewCalls = <({int termId, int classId, bool force})>[];
  int lessonRequests = 0;
  int previewRequests = 0;
  int activePreviews = 0;
  int maxActivePreviews = 0;
  List<VodSearchResult> _lastResults = [];

  @override
  Future<void> warmCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {bool forceRefresh = false}) async {
    warmedCourses.add((course: course, lessons: lessons));
  }

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
  Future<List<VodLesson>> loadSearchLessons(VodCourse course,
      {bool forceRefresh = false}) async {
    previewRequests++;
    activePreviews++;
    if (activePreviews > maxActivePreviews) {
      maxActivePreviews = activePreviews;
    }
    previewCalls.add((
      termId: course.termId,
      classId: course.teachingClassId,
      force: forceRefresh
    ));
    try {
      return await previewLoader?.call(course, forceRefresh) ??
          _lastResults
              .where((result) =>
                  result.course.teachingClassId == course.teachingClassId &&
                  result.lesson.id > 0)
              .map((result) => result.lesson)
              .toList();
    } finally {
      activePreviews--;
    }
  }

  @override
  Future<List<VodLesson>> loadAndWarmSearchLessons(
    VodCourse course,
    List<VodLesson> seeds, {
    bool forceRefresh = false,
  }) async {
    final lessons = await loadSearchLessons(course, forceRefresh: forceRefresh);
    final merged = <(int, bool), VodLesson>{
      for (final lesson in seeds) (lesson.id, lesson.isLive): lesson,
      for (final lesson in lessons) (lesson.id, lesson.isLive): lesson,
    }.values.toList();
    await warmCourseRecordings(course, merged, forceRefresh: forceRefresh);
    return lessons;
  }

  @override
  Future<bool> verifyLiveSearchLesson(
          VodCourse course, VodLesson lesson) async =>
      true;

  @override
  Future<List<VodLesson>> loadGeneratingLessons(VodCourse course,
          {bool forceRefresh = false}) async =>
      const [];

  @override
  Future<void> verifyCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {required void Function(int, VodRecordingAvailability) onResult,
      required bool Function() isCurrent,
      bool fresh = false,
      bool forceRefresh = false}) async {
    final seen = <int>{};
    for (final lesson in lessons) {
      if (lesson.isLive || !seen.add(lesson.id)) continue;
      verificationRequests.add((
        termId: course.termId,
        classId: course.teachingClassId,
        lessonId: lesson.id,
        fresh: fresh
      ));
      final result = await (availabilityLoader?.call(course, lesson) ??
          Future.value(lesson.isPlayable
              ? VodRecordingAvailability.available
              : VodRecordingAvailability.unavailable));
      if (!isCurrent()) return;
      onResult(lesson.id, result);
    }
  }

  @override
  Future<List<VodSearchResult>> searchLessons({
    required int termId,
    required String keyword,
  }) async {
    searches.add((termId: termId, keyword: keyword));
    return _lastResults = await searchLoader?.call(termId, keyword) ?? [];
  }

  @override
  Future<VodPlayback> preparePlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) async {
    playbackRequests.add(lesson);
    throw const VodPermissionException();
  }

  @override
  Future<VodPlayback> prepareLivePlaybackWithProtocol({
    required VodCourse course,
    required VodLesson lesson,
    required VodLiveProtocol protocol,
  }) =>
      preparePlayback(course: course, lesson: lesson);
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  Future<void> Function(bool)? invalidated,
  Future<bool> Function()? login,
  Future<bool> Function()? webVpnRecovery,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  addTearDown(repository.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: ShuYoThemes.all.first.themeData(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations),
      child: child!,
    ),
    home: RecordingSearchPage(
      repository: repository,
      terms: _terms,
      selectedTermId: 7,
      onSessionInvalidated: invalidated,
      onLoginRequested: login,
      onWebVpnSessionExpired: webVpnRecovery,
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

void _expectNoCourseLessonCount(Finder row) {
  final lessonCount = RegExp(r'(?:[0-9]+|—)\s*/\s*(?:[0-9]+|—)\s*节');
  expect(
    find.descendant(
      of: row,
      matching: find.byWidgetPredicate((widget) {
        if (widget is! Text) return false;
        final value = widget.data ?? widget.textSpan?.toPlainText() ?? '';
        return lessonCount.hasMatch(value);
      }),
    ),
    findsNothing,
  );
}

void _expectSingleLessonCount(WidgetTester tester, Finder row, String count) {
  final tile = tester.widget<ListTile>(row);
  final trailing = tile.trailing! as Row;
  final labels = trailing.children.whereType<Text>().toList();
  expect(labels, hasLength(1));
  expect(labels.single.data, '$count节');
  expect(labels.single.data, isNot(contains('/')));
  _expectNoCourseLessonCount(row);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final previewFailure in [false, true]) {
    for (final error in [
      const VodWebVpnSessionExpiredException(),
      const VodWebVpnAuthRequiredException(),
    ]) {
      testWidgets(
          'search ${previewFailure ? 'preview' : 'query'} ${error.runtimeType} restores without campus login',
          (tester) async {
        var restored = false;
        var allowRecovery = false;
        var recoveries = 0;
        var invalidations = 0;
        var logins = 0;
        final repository = _Repository()
          ..searchLoader = ((_, __) async {
            if (!previewFailure && !restored) throw error;
            return [_result(1)];
          })
          ..previewLoader = ((_, __) async {
            if (previewFailure && !restored) throw error;
            return [_result(1).lesson];
          });
        await _mount(tester, repository,
            invalidated: (_) async => invalidations++,
            login: () async {
              logins++;
              return true;
            },
            webVpnRecovery: () async {
              recoveries++;
              restored = allowRecovery;
              return allowRecovery;
            });
        await _submit(tester, '程序');
        await tester.pumpAndSettle();
        expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsOneWidget);
        expect(find.text('重新登录'), findsNothing);
        expect(invalidations, 0);
        expect(logins, 0);
        expect(recoveries, 0);
        expect(repository.searches, hasLength(1));
        await tester.tap(find.text('恢复连接'));
        await tester.pumpAndSettle();
        expect(recoveries, 1);
        expect(repository.searches, hasLength(1));
        expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsOneWidget);
        allowRecovery = true;
        await tester.tap(find.text('恢复连接'));
        await tester.pumpAndSettle();
        expect(recoveries, 2);
        expect(repository.searches, hasLength(2));
        expect(
            repository.previewCalls.every((request) => !request.force), isTrue);
        expect(find.byKey(const ValueKey('vod-search-course:7:101')),
            findsOneWidget);
        expect(find.text('WebVPN 连接已失效，请恢复连接后重试'), findsNothing);
        expect(invalidations, 0);
        expect(logins, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'search forwards WebVPN recovery without invalidating campus auth',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [_result(1)]);
    var recoveries = 0;
    var invalidations = 0;
    await _mount(tester, repository,
        invalidated: (_) async => invalidations++,
        webVpnRecovery: () async {
          recoveries++;
          return true;
        });
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vod-search-course:7:101')));
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(await player.onWebVpnSessionExpired!(), isTrue);
    expect(recoveries, 1);
    expect(invalidations, 0);
    Navigator.of(tester.element(find.byType(RecordingPlayerPage))).pop();
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('vod-search-course:7:101')), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing only rebuilds the search controls after results load',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = (_, __) async => [_result(1)];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    final summary = find.byKey(const ValueKey('vod-search-summary'));
    final originalSummary = tester.widget<Padding>(summary);
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    final originalRow = tester.widget<ListTile>(row);
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '程序设计');
    await tester.pump();
    expect(tester.widget<Padding>(summary), same(originalSummary));
    expect(tester.widget<ListTile>(row), same(originalRow));
    expect(repository.searches, hasLength(1));
    expect(repository.previewCalls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('IME selection and keyboard insets preserve search result rows',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final repository = _Repository()
      ..searchLoader = (_, __) async => [_result(1)];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    final originalRow = tester.widget<ListTile>(row);
    final summary = find.byKey(const ValueKey('vod-search-summary'));
    final originalSummary = tester.widget<Padding>(summary);
    final query = find.byKey(const ValueKey('vod-search-query'));
    await tester.showKeyboard(query);
    await tester.pump();
    final originalInput = tester.widget<TextField>(query);

    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '程序',
      selection: TextSelection.collapsed(offset: 1),
      composing: TextRange(start: 0, end: 1),
    ));
    await tester.pump();
    expect(tester.widget<TextField>(query), same(originalInput));

    final initialHeight =
        tester.getSize(find.byKey(const ValueKey('vod-search-results'))).height;
    for (final inset in [60.0, 140.0, 220.0, 300.0, 220.0, 100.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<ListTile>(row), same(originalRow));
      expect(tester.widget<Padding>(summary), same(originalSummary));
      final height = tester
          .getSize(find.byKey(const ValueKey('vod-search-results')))
          .height;
      expect(height, closeTo(initialHeight - inset, .1));
    }
    expect(repository.searches, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows first reached while dragging do not start entrance fades',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final repository = _Repository()
      ..searchLoader = (_, __) async => [
            for (var index = 0; index < 40; index++)
              _result(index % 20 + 1,
                  classId: 101 + index, name: '程序设计 $index'),
          ];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    Finder row(int index) =>
        find.byKey(ValueKey('vod-search-course:7:${101 + index}'),
            skipOffstage: false);
    final initiallyBuilt = {
      for (var index = 0; index < 40; index++)
        if (tester.any(row(index))) index,
    };
    final list = find.byKey(const ValueKey('vod-search-results'));
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 16));
    final newRows = [
      for (var index = 0; index < 40; index++)
        if (!initiallyBuilt.contains(index) && tester.any(row(index))) index,
    ];
    expect(newRows, isNotEmpty);
    for (final index in newRows) {
      var foundEntrance = false;
      var foundFade = false;
      tester.element(row(index)).visitAncestorElements((element) {
        if (element.widget.runtimeType.toString() == '_SearchCourseEntrance') {
          foundEntrance = true;
          return false;
        }
        if (element.widget is FadeTransition) foundFade = true;
        return true;
      });
      expect(foundEntrance, isTrue);
      expect(foundFade, isFalse);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial results still animate when the list is idle',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = (_, __) async => [_result(1)];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pump(const Duration(milliseconds: 16));
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    final fade =
        find.ancestor(of: row, matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('summary uses course count and separate year and season lines',
      (tester) async {
    await _mount(tester, _Repository());
    final year = find.byKey(const ValueKey('vod-search-year-label'));
    final season = find.byKey(const ValueKey('vod-search-season-label'));
    expect(tester.widget<Text>(year).data, '2026-2027 学年');
    expect(tester.widget<Text>(season).data, '秋季学期');
    expect(tester.getBottomLeft(year).dy,
        lessThanOrEqualTo(tester.getTopLeft(season).dy));
    expect(find.text('课程数'), findsOneWidget);
    expect(find.text('已加载 / 总课程'), findsNothing);
    for (final key in ['vod-search-loaded-count', 'vod-search-total-count']) {
      expect(tester.widget<Text>(find.byKey(ValueKey(key))).data, '0');
    }
  });

  testWidgets(
      'three previews run concurrently without waiting for display frames',
      (tester) async {
    final responses = {
      for (var id = 101; id <= 105; id++) id: Completer<List<VodLesson>>()
    };
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            for (var id = 101; id <= 105; id++) _result(id - 100, classId: id),
          ])
      ..previewLoader =
          (course, _) => responses[course.teachingClassId]!.future;
    await _mount(tester, repository);
    await _submit(tester, '程序');
    expect(
        repository.previewCalls.map((call) => call.classId), [101, 102, 103]);
    expect(repository.activePreviews, 3);
    expect(find.byType(ListTile), findsNothing);

    responses[102]!.complete([_result(2, classId: 102).lesson]);
    await tester.idle();
    expect(repository.previewCalls.map((call) => call.classId),
        [101, 102, 103, 104]);
    expect(repository.activePreviews, 3);
    expect(find.byType(ListTile), findsNothing);

    responses[103]!.complete([_result(3, classId: 103).lesson]);
    await tester.idle();
    expect(repository.previewCalls.map((call) => call.classId),
        [101, 102, 103, 104, 105]);
    expect(repository.maxActivePreviews, 3);
    await tester.pump();
    // Completed rows appear immediately in their source order, without
    // waiting for an unrelated earlier preview.
    expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((row) => row.key),
        [
          const ValueKey('vod-search-course:7:102'),
          const ValueKey('vod-search-course:7:103'),
        ]);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-loaded-count')))
            .data,
        '2');

    responses[101]!.complete([_result(1).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final firstRow = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(firstRow, findsOneWidget);
    final rows = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(rows.map((row) => row.key), [
      const ValueKey('vod-search-course:7:101'),
      const ValueKey('vod-search-course:7:102'),
      const ValueKey('vod-search-course:7:103'),
    ]);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-loaded-count')))
            .data,
        '3');
    final transition = find
        .ancestor(of: firstRow, matching: find.byType(SlideTransition))
        .first;
    expect(tester.widget<SlideTransition>(transition).position.value.dx,
        greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        tester.widget<SlideTransition>(transition).position.value, Offset.zero);

    responses[104]!.complete([_result(4, classId: 104).lesson]);
    responses[105]!.complete([_result(5, classId: 105).lesson]);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-loaded-count')))
            .data,
        '5');
    expect(repository.activePreviews, 0);
    expect(repository.maxActivePreviews, 3);
    expect(repository.verificationRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);
    expect(repository.playbackRequests, isEmpty);
  });

  testWidgets('completing later previews reuses already built course tiles',
      (tester) async {
    final responses = {
      for (var id = 101; id <= 103; id++) id: Completer<List<VodLesson>>()
    };
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            for (var id = 101; id <= 103; id++) _result(id - 100, classId: id),
          ])
      ..previewLoader =
          (course, _) => responses[course.teachingClassId]!.future;
    await _mount(tester, repository);
    await _submit(tester, '程序');
    responses[101]!.complete([_result(1).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final firstRow = find.byKey(const ValueKey('vod-search-course:7:101'));
    final originalTile = tester.widget<ListTile>(firstRow);

    responses[102]!.complete([_result(2, classId: 102).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(identical(tester.widget<ListTile>(firstRow), originalTile), isTrue);

    responses[103]!.complete([_result(3, classId: 103).lesson]);
    await tester.pumpAndSettle();
    expect(identical(tester.widget<ListTile>(firstRow), originalTile), isTrue);
    expect(find.byKey(const ValueKey('vod-search-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'preview completions update one frozen result view without rebuilding search chrome',
      (tester) async {
    final responses = {
      for (var id = 101; id <= 104; id++) id: Completer<List<VodLesson>>()
    };
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            for (var id = 101; id <= 104; id++) _result(id - 100, classId: id),
          ])
      ..previewLoader =
          (course, _) => responses[course.teachingClassId]!.future;
    await _mount(tester, repository);
    await _submit(tester, '程序');

    final originalScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final originalAppBar = tester.widget<AppBar>(find.byType(AppBar));
    final query = find.byKey(const ValueKey('vod-search-query'));
    final originalInput = tester.widget<TextField>(query);
    final summary = find.byKey(const ValueKey('vod-search-summary'));
    final originalSummary = tester.widget<Padding>(summary);
    final count = find.byKey(const ValueKey('vod-search-loaded-count'));
    final firstRow = find.byKey(const ValueKey('vod-search-course:7:101'));

    void expectStableChrome() {
      expect(tester.widget<Scaffold>(find.byType(Scaffold)),
          same(originalScaffold));
      expect(tester.widget<AppBar>(find.byType(AppBar)), same(originalAppBar));
      expect(tester.widget<TextField>(query), same(originalInput));
    }

    responses[101]!.complete([_result(1).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expectStableChrome();
    expect(tester.widget<Padding>(summary), isNot(same(originalSummary)));
    expect(tester.widget<Text>(count).data, '1');
    _expectSingleLessonCount(tester, firstRow, '1');

    responses[102]!.complete([_result(2, classId: 102).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expectStableChrome();
    expect(tester.widget<Text>(count).data, '2');
    expect(
        find.byKey(const ValueKey('vod-search-course:7:102')), findsOneWidget);

    final frozenSummary = tester.widget<Padding>(summary);
    final originalFirstRow = tester.widget<ListTile>(firstRow);
    final results = find.byKey(const ValueKey('vod-search-results'));
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: results, matching: find.byType(Scrollable)).first);
    ScrollStartNotification(
      metrics: scrollable.position,
      context: scrollable.context,
    ).dispatch(scrollable.context);
    responses[103]!.complete([_result(3, classId: 103).lesson]);
    responses[104]!.complete([_result(4, classId: 104).lesson]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expectStableChrome();
    expect(tester.widget<Padding>(summary), same(frozenSummary));
    expect(tester.widget<Text>(count).data, '2');
    expect(tester.widget<ListTile>(firstRow), same(originalFirstRow));
    expect(find.byKey(const ValueKey('vod-search-course:7:103')), findsNothing);
    expect(find.byKey(const ValueKey('vod-search-course:7:104')), findsNothing);
    expect(repository.activePreviews, 0);

    ScrollEndNotification(
      metrics: scrollable.position,
      context: scrollable.context,
    ).dispatch(scrollable.context);
    await tester.pumpAndSettle();

    expectStableChrome();
    expect(tester.widget<Text>(count).data, '4');
    expect(tester.widget<Padding>(summary), isNot(same(frozenSummary)));
    expect(tester.widget<ListTile>(firstRow), same(originalFirstRow));
    expect(
        find.byKey(const ValueKey('vod-search-course:7:103')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('vod-search-course:7:104')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-search-progress')), findsNothing);
    expect(repository.previewRequests, 4);
    expect(repository.verificationRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling back to a course does not replay its entrance',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            for (var id = 101; id <= 140; id++) _result(id - 100, classId: id),
          ]);
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    final firstRow = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(firstRow, findsOneWidget);
    final scrollView = find.byKey(const ValueKey('vod-search-results'));
    await tester.drag(scrollView, const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(firstRow, findsNothing);
    await tester.drag(scrollView, const Offset(0, 5000));
    await tester.pump();
    expect(firstRow, findsOneWidget);
    final transition = find
        .ancestor(of: firstRow, matching: find.byType(SlideTransition))
        .first;
    expect(
        tester.widget<SlideTransition>(transition).position.value, Offset.zero);
    await tester.pumpAndSettle();
    expect(repository.previewRequests, 40);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and failed previews retain searchable lesson candidates',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            _result(1),
            _result(2, classId: 102),
            _result(3, classId: 103),
          ])
      ..previewLoader = (course, _) async {
        if (course.teachingClassId == 101) return [];
        if (course.teachingClassId == 102) {
          throw const VodNetworkException();
        }
        return [_result(3, classId: 103).lesson];
      };
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(
        repository.previewCalls.map((call) => call.classId), [101, 102, 103]);
    for (final id in [101, 102]) {
      final row = find.byKey(ValueKey('vod-search-course:7:$id'));
      expect(tester.widget<ListTile>(row).enabled, isTrue);
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
    }
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('vod-search-course:7:103')))
            .onTap,
        isNotNull);
    expect(find.byType(RecordingPlayerPage), findsNothing);
    expect(repository.playbackRequests, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-loaded-count')))
            .data,
        '3');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-total-count')))
            .data,
        '3');
    await tester.tap(find.byKey(const ValueKey('vod-search-course:7:101')));
    await tester.pumpAndSettle();
    expect(repository.playbackRequests.single.id, 1);
  });

  testWidgets('clearing a pending preview discards it and stops the queue',
      (tester) async {
    final pending = Completer<List<VodLesson>>();
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            _result(1),
            _result(2, classId: 102),
            _result(3, classId: 103),
            _result(4, classId: 104),
          ])
      ..previewLoader = (_, __) => pending.future;
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-clear')));
    await tester.pumpAndSettle();
    pending.complete([_result(1).lesson]);
    await tester.pumpAndSettle();
    expect(repository.previewCalls, hasLength(3));
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('搜索课程、教师或课程号'), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-loaded-count')))
            .data,
        '0');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('vod-search-total-count')))
            .data,
        '0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('submitting again retries a disabled course with a fresh preview',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            const VodSearchResult(
              course: _course,
              lesson: VodLesson(
                  id: 0, teachingClassId: 101, name: '程序设计', isPlayable: false),
            ),
          ])
      ..previewLoader = (_, force) async => force ? [_result(1).lesson] : [];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(row, findsNothing);
    expect(find.text('没有可播放的课程'), findsOneWidget);
    // Results no longer refresh by pulling; the search button is the only
    // manual refresh entry point.
    expect(find.byType(RefreshIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pumpAndSettle();
    expect(repository.previewCalls.map((call) => call.force), [false, true]);
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search waits for preview before revealing a course',
      (tester) async {
    final pendingPreview = Completer<List<VodLesson>>();
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [_result(1, playable: false)])
      ..previewLoader = (_, __) => pendingPreview.future;
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pump();

    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(row, findsNothing);
    expect(find.text('正在加载课程…'), findsOneWidget);
    expect(repository.previewCalls, hasLength(1));
    expect(repository.verificationRequests, isEmpty);
    expect(repository.playbackRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);
    pendingPreview.complete([_result(1).lesson, _result(2).lesson]);
    await tester.pumpAndSettle();
    _expectSingleLessonCount(tester, row, '2');
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    expect(repository.previewCalls, hasLength(1));
    expect(repository.verificationRequests, isEmpty);
    expect(repository.playbackRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);

    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.initialLesson?.id, 2);
    expect(player.loadPreviewCatalog, isTrue);
    expect(player.skipInitialCatalogLoad, isTrue);
    expect(repository.playbackRequests.single.id, 2);
    expect(repository.previewCalls, hasLength(2));
    expect(repository.verificationRequests, isEmpty);
    await tester.pumpAndSettle();
    expect(repository.warmedCourses, isNotEmpty);
    expect(repository.warmedCourses.first.lessons.map((e) => e.id),
        containsAll([1, 2]));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('search groups lessons and shows one plain preview count per row',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            _result(1, begin: DateTime.utc(2026, 10, 3, 2)),
            _result(3, begin: DateTime.utc(2026, 10, 3, 0)),
            _result(2, playable: false),
          ]);
    await _mount(tester, repository);
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), ' 教师甲 ');
    await tester.pumpAndSettle();
    expect(repository.searches, isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.searches, [(termId: 7, keyword: '教师甲')]);
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(row, findsOneWidget);
    expect(find.text('CS101 · 教师甲'), findsOneWidget);
    expect(find.text('2026年10月3日 周六'), findsNothing);
    _expectSingleLessonCount(tester, row, '3');
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    expect(repository.previewCalls, hasLength(1));
    expect(repository.verificationRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);
    expect(repository.playbackRequests, isEmpty);
    expect(repository.lessonRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'search uses the existing live row and opens live before playback',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final recording = _result(1, begin: now.subtract(const Duration(days: 1)));
    final live = VodLesson(
      id: 2,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: true,
      isLive: true,
      beginTime: now.subtract(const Duration(minutes: 20)),
      liveEndTime: now.add(const Duration(minutes: 20)),
    );
    final pending = VodLesson(
      id: 3,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: false,
      isGenerating: true,
      beginTime: now,
    );
    final shadow = VodLesson(
      id: live.id,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: false,
      isGenerating: true,
    );
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            recording,
            VodSearchResult(course: _course, lesson: live),
          ])
      ..previewLoader = (_, __) async => [pending, shadow, recording.lesson];
    await _mount(tester, repository, disableAnimations: true);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    _expectSingleLessonCount(tester, row, '3');
    final status = tester.widget<RecordingStatusIcon>(
        find.descendant(of: row, matching: find.byType(RecordingStatusIcon)));
    expect(status.isLive, isTrue);
    expect(repository.searches, hasLength(1));
    expect(repository.previewCalls, hasLength(1));
    expect(repository.playbackRequests, isEmpty);
    expect(repository.verificationRequests, isEmpty);

    await tester.tap(row);
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.initialLesson, live);
    expect(player.lessons.map((lesson) => lesson.id), [3, 2, 1]);
    expect(repository.playbackRequests, [live]);
    expect(repository.previewCalls, hasLength(2));
    expect(repository.warmedCourses.first.lessons, [recording.lesson]);
    final pendingRow = tester
        .widget<ListTile>(find.byKey(const ValueKey('recording-lesson-3')));
    expect(pendingRow.enabled, isFalse);
    expect(pendingRow.onTap, isNull);
    expect(find.text('回放生成中'), findsNothing);
    expect(tester.takeException(), isNull);

    // The player no longer exposes a pull gesture; no refresh is needed here.
    expect(
        find.descendant(
            of: find.byType(RecordingPlayerPage),
            matching: find.byType(RefreshIndicator)),
        findsNothing);
    expect(repository.playbackRequests, [live]);
    expect(repository.previewCalls, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final openBeforePreview in [false, true]) {
    testWidgets(
        'live search ${openBeforePreview ? 'shares a pending preview' : 'updates its cached row'}',
        (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final live = VodLesson(
        id: 2,
        teachingClassId: 101,
        name: _course.name,
        isPlayable: true,
        isLive: true,
        beginTime: now,
        classroom: 'A101',
        liveEndTime: now.add(const Duration(hours: 1)),
      );
      final recording =
          _result(1, begin: now.subtract(const Duration(days: 1)));
      final preview = Completer<List<VodLesson>>();
      final repository = _Repository()
        ..searchLoader = ((_, __) async => [
              VodSearchResult(course: _course, lesson: live),
            ])
        ..previewLoader = (_, __) => preview.future;
      await _mount(tester, repository, disableAnimations: true);
      await _submit(tester, '程序');
      await tester.pump(const Duration(milliseconds: 300));

      final row = find.byKey(const ValueKey('vod-search-course:7:101'));
      expect(row, findsOneWidget);
      _expectSingleLessonCount(tester, row, '1');
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
      expect(repository.previewRequests, 1);

      if (openBeforePreview) {
        await tester.tap(row);
        await tester.pump(const Duration(milliseconds: 300));
        expect(repository.playbackRequests, [live]);
        expect(repository.previewRequests, 1);
      }
      preview.complete([recording.lesson]);
      await tester.pumpAndSettle();
      if (!openBeforePreview) {
        _expectSingleLessonCount(tester, row, '2');
        await tester.tap(row);
        await tester.pumpAndSettle();
        final player = tester
            .widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
        expect(player.lessons.map((lesson) => lesson.id), containsAll([1, 2]));
        expect(player.skipInitialCatalogLoad, isTrue);
      } else {
        expect(
            find.byKey(const ValueKey('recording-lesson-1')), findsOneWidget);
      }
      // A pending preview is shared, so opening first still costs one request.
      expect(repository.previewRequests, openBeforePreview ? 1 : 2);
      expect(repository.playbackRequests, [live]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tapping a stale live row uses the just-completed preview',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final live = VodLesson(
      id: 2,
      teachingClassId: 101,
      name: _course.name,
      isPlayable: true,
      isLive: true,
      beginTime: now,
      classroom: 'A101',
      liveEndTime: now.add(const Duration(hours: 1)),
    );
    final recording = _result(1, begin: now.subtract(const Duration(days: 1)));
    final preview = Completer<List<VodLesson>>();
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [
            VodSearchResult(course: _course, lesson: live),
          ])
      ..previewLoader = (_, __) => preview.future;
    await _mount(tester, repository, disableAnimations: true);
    await _submit(tester, '程序');
    await tester.pump(const Duration(milliseconds: 300));
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    _expectSingleLessonCount(tester, row, '1');
    final staleTap = tester.widget<ListTile>(row).onTap!;

    // Complete the preview and run its microtasks, without rendering a new row.
    preview.complete([recording.lesson]);
    await tester.idle();
    _expectSingleLessonCount(tester, row, '1');
    staleTap();
    await tester.pumpAndSettle();

    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.lessons.map((lesson) => lesson.id), containsAll([1, 2]));
    expect(player.skipInitialCatalogLoad, isTrue);
    expect(repository.previewRequests, 2);
    expect(repository.playbackRequests, [live]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generating-only search course stays hidden without toggle',
      (tester) async {
    final pending = _result(2, playable: false);
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [pending])
      ..previewLoader = (_, __) async => [];
    await _mount(tester, repository, disableAnimations: true);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    expect(row, findsNothing);
    expect(find.text('没有可播放的课程'), findsOneWidget);
    expect(find.text('显示无法播放的课程'), findsNothing);
    expect(find.byKey(const ValueKey('vod-search-show-unavailable')),
        findsNothing);
    expect(find.byType(RecordingPlayerPage), findsNothing);
    expect(repository.playbackRequests, isEmpty);
    expect(repository.verificationRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);
    expect(repository.previewCalls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable courses remain filtered out from search results',
      (tester) async {
    final playable = _result(1);
    final disabled = _result(2, classId: 102, playable: false);
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [playable, disabled])
      ..previewLoader = (course, _) async =>
          course.teachingClassId == 102 ? [] : [playable.lesson];
    await _mount(tester, repository, disableAnimations: true);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('vod-search-show-unavailable')),
        findsNothing);
    final playableRow = find.byKey(const ValueKey('vod-search-course:7:101'));
    final disabledRow = find.byKey(const ValueKey('vod-search-course:7:102'));
    expect(playableRow, findsOneWidget);
    expect(disabledRow, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final availability in [
    VodRecordingAvailability.unavailable,
    VodRecordingAvailability.unknown,
  ]) {
    testWidgets('one source candidate with $availability URLs stays hidden',
        (tester) async {
      final repository = _Repository()
        ..searchLoader = ((_, __) async => [_result(1)])
        ..previewLoader = ((_, __) async => [])
        ..availabilityLoader = (_, __) async => availability;
      await _mount(tester, repository, disableAnimations: true);
      await _submit(tester, '程序');
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('vod-search-course:7:101'));
      expect(row, findsNothing);
      expect(find.text('没有可播放的课程'), findsOneWidget);
      expect(
          tester
              .widget<Text>(
                  find.byKey(const ValueKey('vod-search-loaded-count')))
              .data,
          '0');
      expect(repository.verificationRequests, hasLength(1));
      expect(repository.verificationRequests.single.fresh, isTrue);
      expect(repository.playbackRequests, isEmpty);
      expect(find.byType(RecordingPlayerPage), findsNothing);
    });
  }

  testWidgets(
      'filters classes before preview and keeps all matching class seeds',
      (tester) async {
    final first = _result(1, teachers: ['教师乙']);
    final match = _result(2, teachers: ['教师甲']);
    final unrelated = _result(3, classId: 102, name: '无关课程', teachers: ['别人']);
    final repository = _Repository()
      ..searchLoader = (_, __) async => [first, unrelated, match];
    await _mount(tester, repository);
    await _submit(tester, '教师甲');
    await tester.pumpAndSettle();
    expect(find.text('CS101 · 教师甲'), findsOneWidget);
    expect(find.text('无关课程'), findsNothing);
    expect(repository.previewCalls, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('vod-search-course:7:101')));
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.lessons.map((lesson) => lesson.id), containsAll([1, 2]));
  });

  testWidgets('matches teaching class and separate course number visibly',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = (_, __) async => [
            _result(1, teachingClassName: '程序设计实验班', courseNumber: 'ABC-987'),
            _result(2, classId: 102, name: '无关课程'),
          ];
    await _mount(tester, repository);
    await _submit(tester, '实验班');
    await tester.pumpAndSettle();
    expect(find.text('程序设计实验班'), findsOneWidget);
    expect(repository.previewCalls, hasLength(1));
    await _submit(tester, 'abc-987');
    await tester.pumpAndSettle();
    expect(find.text('ABC-987'), findsOneWidget);
    expect(find.text('无关课程'), findsNothing);
    expect(repository.previewCalls, hasLength(2));
  });

  testWidgets('unrelated search results show empty without loading previews',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = (_, __) async => [_result(1)];
    await _mount(tester, repository);
    await _submit(tester, '完全不相关');
    await tester.pumpAndSettle();
    expect(find.text('没有找到录播'), findsOneWidget);
    expect(repository.previewCalls, isEmpty);
  });

  testWidgets('short keywords explain the minimum without sending a request',
      (tester) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await _submit(tester, '课', keyboard: true);
    await tester.pumpAndSettle();
    expect(repository.searches, isEmpty);
    expect(find.text('请输入至少 2 个字的课程、教师或课程号关键词'), findsOneWidget);
    expect(find.text('搜索课程、教师或课程号'), findsOneWidget);
  });

  testWidgets('opening a course loads preview and warms all its lessons',
      (tester) async {
    final result = _result(12);
    final other = _result(11);
    final extra = _result(10);
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [result, other])
      ..previewLoader =
          (_, __) async => [result.lesson, other.lesson, extra.lesson];
    await _mount(tester, repository);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(repository.previewCalls, hasLength(1));
    expect(repository.verificationRequests, isEmpty);
    expect(repository.warmedCourses, isEmpty);
    await tester.tap(find.byKey(const ValueKey('vod-search-course:7:101')));
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(identical(player.repository, repository), isTrue);
    expect(player.initialLesson, isNotNull);
    expect(player.lessons, containsAll([result.lesson, other.lesson]));
    expect(player.loadCourseCatalog, isFalse);
    expect(player.loadPreviewCatalog, isTrue);
    expect(player.skipInitialCatalogLoad, isTrue);
    expect(repository.playbackRequests, [player.initialLesson]);
    expect(repository.lessonRequests, 0);
    expect(repository.previewRequests, 2);
    expect(repository.warmedCourses, isNotEmpty);
    expect(repository.warmedCourses.first.course.teachingClassId, 101);
    expect(repository.warmedCourses.first.lessons.map((lesson) => lesson.id),
        containsAll([10, 11, 12]));
    expect(tester.takeException(), isNull);
  });

  testWidgets('course without seed opens and plays the fetched preview',
      (tester) async {
    final repository = _Repository()
      ..searchLoader = ((_, __) async => [_result(0)])
      ..previewLoader =
          (_, __) async => [_result(12).lesson, _result(11).lesson];
    await _mount(tester, repository);
    await _submit(tester, 'CS101');
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('vod-search-course:7:101'));
    _expectSingleLessonCount(tester, row, '2');
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    expect(find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
    expect(repository.previewCalls, hasLength(1));
    expect(repository.verificationRequests, isEmpty);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.initialLesson?.id, 12);
    expect(player.lessons.map((lesson) => lesson.id), [12, 11]);
    expect(player.loadPreviewCatalog, isTrue);
    expect(player.skipInitialCatalogLoad, isTrue);
    expect(repository.previewRequests, 2);
    expect(repository.playbackRequests.single.id, 12);
    expect(repository.warmedCourses.first.lessons.map((e) => e.id),
        containsAll([11, 12]));
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
    latest.complete([_result(2, name: '新关键词结果')]);
    await tester.pumpAndSettle();
    old.complete([_result(1, name: '旧结果')]);
    await tester.pumpAndSettle();
    expect(find.text('新关键词结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
    await _submit(tester, '清空');
    await tester.tap(find.byKey(const ValueKey('vod-search-clear')));
    await tester.pumpAndSettle();
    cleared.complete([_result(3, name: '过期结果')]);
    await tester.pumpAndSettle();
    expect(find.text('搜索课程、教师或课程号'), findsOneWidget);
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
        find.byKey(const ValueKey('vod-search-course:7:101')), findsOneWidget);
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
    expect(find.text('搜索课程、教师或课程号'), findsOneWidget);
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
    for (final key in ['vod-search-year-label', 'vod-search-season-label']) {
      final label = find.byKey(ValueKey(key));
      final rect = tester.getRect(label);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(720));
      expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse);
    }
    expect(
        tester
            .getBottomLeft(find.byKey(const ValueKey('vod-search-year-label')))
            .dy,
        lessThanOrEqualTo(tester
            .getTopLeft(find.byKey(const ValueKey('vod-search-season-label')))
            .dy));
    expect(tester.takeException(), isNull);
    await _submit(tester, '程序');
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('vod-search-course:7:101')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
