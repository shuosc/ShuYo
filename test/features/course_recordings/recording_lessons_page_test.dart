import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/repositories/vod_repository.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/features/course_recordings/recording_lessons_page.dart';
import 'package:shuyo/features/course_recordings/recording_player_page.dart';

const _course = VodCourse(
  teachingClassId: 42,
  termId: 7,
  name: '电路与模拟电子技术',
  teacherNames: ['教师甲'],
  code: 'EE101',
);

VodLesson _lesson(int id, int day, {bool playable = true}) => VodLesson(
      id: id,
      teachingClassId: 42,
      name: _course.name,
      beginTime: DateTime(2026, 10, day, 8),
      endTime: DateTime(2026, 10, day, 9, 40),
      weekNumber: 6,
      sectionLabel: '第1节',
      classroom: 'A楼101',
      isPlayable: playable,
    );

class _Repository extends VodRepository {
  _Repository(this.loader);

  final Future<List<VodLesson>> Function(int request, bool forceRefresh) loader;
  int requests = 0;
  int clears = 0;
  final forceRefreshes = <bool>[];
  final playback = Completer<VodPlayback>();

  @override
  Future<List<VodLesson>> loadLessons(
    VodCourse course, {
    bool forceRefresh = false,
  }) {
    forceRefreshes.add(forceRefresh);
    return loader(++requests, forceRefresh);
  }

  @override
  Future<VodPlayback> preparePlayback({
    required VodCourse course,
    required VodLesson lesson,
  }) =>
      playback.future;

  @override
  void clear() => clears++;
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  Future<bool> Function()? recover,
  double textScale = 1,
}) =>
    tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RecordingLessonsPage(
        repository: repository,
        course: _course,
        onSessionExpired: recover,
      ),
    ));

void main() {
  testWidgets(
      'groups dates and keeps chronological episode numbers when sorted',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository((_, __) async => [
          _lesson(1, 20),
          _lesson(2, 22),
          _lesson(3, 23, playable: false),
        ]);
    await _mount(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('教师甲'), findsOneWidget);
    expect(find.text('回放列表 · 2 集'), findsOneWidget);
    expect(find.text('2026年10月22日 周四'), findsOneWidget);
    expect(find.text('2026年10月20日 周二'), findsOneWidget);
    expect(find.text('第 1 集 · 08:00–09:40'), findsOneWidget);
    expect(find.text('第 2 集 · 08:00–09:40'), findsOneWidget);
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('recording-lesson-2'))).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('recording-lesson-1')))
            .dy));

    await tester.tap(find.byTooltip('排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is CheckedPopupMenuItem<bool> && widget.value == false));
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(find.byKey(const ValueKey('recording-lesson-1'))).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const ValueKey('recording-lesson-2')))
            .dy));
    expect(find.text('第 1 集 · 08:00–09:40'), findsOneWidget);
    expect(repository.requests, 1);
  });

  testWidgets('refresh leaves old rows visible but disables playback',
      (tester) async {
    final refresh = Completer<List<VodLesson>>();
    final repository = _Repository((request, _) =>
        request == 1 ? Future.value([_lesson(1, 20)]) : refresh.future);
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();

    final row = tester
        .widget<ListTile>(find.byKey(const ValueKey('recording-lesson-1')));
    expect(row.onTap, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(repository.forceRefreshes, [false, true]);
    refresh.complete([_lesson(2, 22)]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-1')), findsNothing);
    expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('recording-lesson-2')))
            .onTap,
        isNotNull);
  });

  testWidgets('network failures offer retry without invoking login recovery',
      (tester) async {
    var recoveries = 0;
    final repository = _Repository((request, _) async {
      if (request == 1) throw const VodNetworkException();
      return [_lesson(1, 20)];
    });
    await _mount(tester, repository, recover: () async {
      recoveries++;
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.text('无法连接录播平台'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repository.requests, 2);
    expect(recoveries, 0);
    expect(repository.clears, 0);
  });

  testWidgets(
      'session recovery is explicit and clears data before a forced reload',
      (tester) async {
    var recoveries = 0;
    final repository = _Repository((request, force) async {
      if (request == 1) throw const VodSessionExpiredException();
      expect(force, isTrue);
      return [_lesson(2, 22)];
    });
    await _mount(tester, repository, recover: () async {
      recoveries++;
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.text('校园账户登录已失效'), findsOneWidget);
    expect(recoveries, 0);
    expect(repository.requests, 1);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(repository.clears, 1);
    expect(repository.requests, 2);
    expect(find.byKey(const ValueKey('recording-lesson-2')), findsOneWidget);
  });

  testWidgets('permission denial and empty recordings have distinct states',
      (tester) async {
    final denied =
        _Repository((_, __) async => throw const VodPermissionException());
    await _mount(tester, denied);
    await tester.pumpAndSettle();
    expect(find.text('暂时无法观看这门课'), findsOneWidget);
    expect(find.text('重新登录'), findsNothing);
    final empty = _Repository((_, __) async => []);
    await _mount(tester, empty);
    await tester.pumpAndSettle();
    expect(find.text('暂无可观看回放'), findsOneWidget);
  });

  testWidgets('an old request cannot overwrite a replacement repository result',
      (tester) async {
    final oldResult = Completer<List<VodLesson>>();
    final oldRepository = _Repository((_, __) => oldResult.future);
    await _mount(tester, oldRepository);
    final currentRepository = _Repository((_, __) async => [_lesson(2, 22)]);
    await _mount(tester, currentRepository);
    await tester.pumpAndSettle();
    oldResult.complete([_lesson(1, 20)]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recording-lesson-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-lesson-1')), findsNothing);
  });

  testWidgets(
      'lesson opens the player with chronological sequence and selected episode',
      (tester) async {
    final repository =
        _Repository((_, __) async => [_lesson(1, 20), _lesson(2, 22)]);
    await _mount(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-lesson-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final player =
        tester.widget<RecordingPlayerPage>(find.byType(RecordingPlayerPage));
    expect(player.course.teachingClassId, 42);
    expect(player.initialLesson.id, 2);
    expect(player.lessons.map((lesson) => lesson.id), [1, 2]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow screens with large text can scroll without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository((_, __) async => [_lesson(1, 20)]);
    await _mount(tester, repository, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('recording-lesson-1')), findsOneWidget);
  });
}
