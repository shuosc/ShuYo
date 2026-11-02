import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_search_result.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';
import 'package:shuyo/features/course_recordings/recording_search_page.dart';

const _term = VodTerm(id: 7, name: '测试学期');

VodCourse _course(int id, String name) => VodCourse(
      teachingClassId: id,
      termId: 7,
      name: name,
      code: 'CS$id',
      teacherNames: const ['教师'],
    );

VodLesson _lesson(int id, String name) => VodLesson(
      id: id,
      teachingClassId: id,
      name: name,
      isPlayable: true,
      beginTime: DateTime(2026, 10, 1),
    );

class _StressRepository extends VodRepository {
  final previews = <int, Completer<List<VodLesson>>>{};

  @override
  Future<List<VodSearchResult>> searchLessons(
      {required int termId, required String keyword}) async {
    final ids = keyword == '旧课程' ? List.generate(40, (i) => i + 1) : [100];
    return [
      for (final id in ids)
        VodSearchResult(
            course: _course(id, keyword), lesson: _lesson(id, keyword)),
    ];
  }

  @override
  Future<List<VodLesson>> loadSearchLessons(VodCourse course,
          {bool forceRefresh = false}) =>
      (previews[course.teachingClassId] ??= Completer<List<VodLesson>>())
          .future;

  @override
  Future<List<VodLesson>> loadGeneratingLessons(VodCourse course,
          {bool forceRefresh = false}) async =>
      const [];

  @override
  Future<void> warmCourseRecordings(VodCourse course, List<VodLesson> lessons,
      {bool forceRefresh = false}) async {}

  @override
  Future<VodPlayback> preparePlayback(
          {required VodCourse course, required VodLesson lesson}) async =>
      throw const VodPermissionException();
}

void main() {
  testWidgets('late previews after leaving search do not restart its queue',
      (tester) async {
    final repository = _StressRepository();
    addTearDown(repository.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => RecordingSearchPage(
                repository: repository,
                terms: const [_term],
                selectedTermId: 7),
          )),
          child: const Text('打开搜索'),
        ),
      ),
    ));
    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '旧课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    expect(repository.previews, hasLength(3));

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(RecordingSearchPage), findsNothing);
    for (final entry in repository.previews.entries.toList()) {
      entry.value.complete([_lesson(entry.key, '旧课程')]);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(repository.previews, hasLength(3));
    expect(find.text('打开搜索'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached search rows follow theme and text scale changes',
      (tester) async {
    final repository = _StressRepository();
    addTearDown(repository.dispose);
    final settings = ValueNotifier((
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      scale: 1.0,
    ));
    addTearDown(settings.dispose);
    final page = RecordingSearchPage(
        repository: repository, terms: const [_term], selectedTermId: 7);
    await tester.pumpWidget(ValueListenableBuilder(
      valueListenable: settings,
      builder: (context, value, child) => MaterialApp(
        theme: value.theme,
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(value.scale)),
          child: child!,
        ),
        home: page,
      ),
    ));
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '新课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    repository.previews[100]!.complete([_lesson(100, '新课程')]);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('vod-search-course:7:100'));
    final beforeHeight = tester.getSize(row).height;
    final darkTheme = ThemeData(
        brightness: Brightness.dark, colorSchemeSeed: Colors.deepOrange);
    settings.value = (theme: darkTheme, scale: 2.0);
    await tester.pumpAndSettle();
    final count = find.byKey(const ValueKey('vod-search-lesson-count:7:100'));
    expect(
        tester.widget<Text>(count).style!.color, darkTheme.colorScheme.primary);
    expect(tester.getSize(row).height, greaterThan(beforeHeight));
    expect(repository.previews, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long scroll still receives results and clear is immediate',
      (tester) async {
    final repository = _StressRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RecordingSearchPage(
          repository: repository, terms: const [_term], selectedTermId: 7),
    ));
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '旧课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    repository.previews[1]!.complete([_lesson(1, '旧课程')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final list = find.byKey(const ValueKey('vod-search-results'));
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first);
    ScrollStartNotification(
            metrics: scrollable.position, context: scrollable.context)
        .dispatch(scrollable.context);
    repository.previews[2]!.complete([_lesson(2, '旧课程')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('vod-search-course:7:2')), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-search-course:7:2')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('vod-search-query')), '');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-search-course:7:1')), findsNothing);
    expect(find.text('搜索课程、教师或课程号'), findsOneWidget);
    repository.previews[3]!.complete([_lesson(3, '旧课程')]);
    await tester.pump();
    expect(find.byKey(const ValueKey('vod-search-course:7:3')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incremental inserts preserve an existing row entrance state',
      (tester) async {
    final repository = _StressRepository();
    addTearDown(repository.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RecordingSearchPage(
          repository: repository, terms: const [_term], selectedTermId: 7),
    ));
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '旧课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    repository.previews[2]!.complete([_lesson(2, '旧课程')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final row = find.byKey(const ValueKey('vod-search-course:7:2'));
    final entrance =
        find.ancestor(of: row, matching: find.byType(SlideTransition)).first;
    final before = tester.widget<SlideTransition>(entrance).position.value.dx;
    expect(before, greaterThan(0));

    repository.previews[1]!.complete([_lesson(1, '旧课程')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final after = tester.widget<SlideTransition>(entrance).position.value.dx;
    expect(after, lessThan(before));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        tester.widget<SlideTransition>(entrance).position.value, Offset.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates during rapid navigation do not replace the next search',
      (tester) async {
    final repository = _StressRepository();
    addTearDown(repository.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: RecordingSearchPage(
          repository: repository, terms: const [_term], selectedTermId: 7),
    ));
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '旧课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    repository.previews[1]!.complete([_lesson(1, '旧课程')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('vod-search-course:7:1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final route =
        ModalRoute.of(tester.element(find.byType(RecordingPlayerPage)))!;
    final progress = route.animation!.value;
    expect(progress, greaterThan(0));
    repository.previews[2]!.complete([_lesson(2, '旧课程')]);
    repository.previews[3]!.complete([_lesson(3, '旧课程')]);
    await tester.pump(const Duration(milliseconds: 60));
    expect(route.animation!.value, greaterThan(progress));
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.byKey(const ValueKey('vod-search-query')), '新课程');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('vod-search-submit')));
    await tester.pump();
    repository.previews[100]!.complete([_lesson(100, '新课程')]);
    // Old in-flight previews can finish after the new search starts.
    for (final entry in repository.previews.entries.toList()) {
      if (entry.key != 100 && !entry.value.isCompleted) {
        entry.value.complete([_lesson(entry.key, '旧课程')]);
      }
    }
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('vod-search-course:7:100')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-search-course:7:1')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
