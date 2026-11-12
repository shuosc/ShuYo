import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/models/academic_schedule_collection.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_schedule_api_client.dart';
import 'package:shuyo/data/services/academic_schedule_notification_service.dart';
import 'package:shuyo/data/services/academic_schedule_widget_service.dart';
import 'package:shuyo/features/home/academic_schedule_collection_page.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/home/schedule_share_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _current = AcademicTermQuery(
    yearCode: '2026',
    termCode: '3',
    academicYearName: '2026-2027',
    termName: '秋');
const _history = AcademicTermQuery(
    yearCode: '2025',
    termCode: '3',
    academicYearName: '2025-2026',
    termName: '秋');

AcademicSchedule _schedule(AcademicTermQuery query, {String? name}) {
  final data = jsonDecode(
      File('test/fixtures/academic_schedule/historical_schedule.json')
          .readAsStringSync()) as Map<String, dynamic>;
  final term = data['xsxx'] as Map;
  term['XNM'] = query.yearCode;
  term['XQM'] = query.termCode;
  term['XNMC'] = query.academicYearName;
  term['XQMMC'] = query.termName;
  if (name != null) {
    for (final course in data['kbList'] as List) {
      (course as Map)['kcmc'] = name;
    }
  }
  return AcademicScheduleParser.parse(data);
}

class _Api extends AcademicScheduleApiClient {
  int requests = 0;
  int catalogRequests = 0;
  final requestedTerms = <String>[];
  bool authExpired = false;
  String? historicalName;
  final emptyTerms = <String>{};
  Completer<void>? refreshGate;
  final terms = <AcademicTermQuery>[_current, _history];

  @override
  Future<AcademicTermCatalog> fetchTermCatalog() async {
    catalogRequests++;
    if (authExpired) throw const AcademicAuthException('expired', 901);
    return AcademicTermCatalog(currentTerm: _current, terms: terms);
  }

  @override
  Future<AcademicSchedule> fetchCurrentSchedule() async {
    requests++;
    if (authExpired) throw const AcademicAuthException('expired', 901);
    return _schedule(_current);
  }

  @override
  Future<AcademicSchedule> fetchScheduleForTerm(AcademicTermQuery query) async {
    requests++;
    requestedTerms.add(query.key);
    await refreshGate?.future;
    if (authExpired) throw const AcademicAuthException('expired', 901);
    final schedule = _schedule(query,
        name: query.key == _history.key ? historicalName : null);
    return emptyTerms.contains(query.key)
        ? schedule.copyWith(sessions: [], untimedCourses: [])
        : schedule;
  }
}

class _Widgets extends AcademicScheduleWidgetService {
  _Widgets(this.repository) : super(repository: repository);
  final AcademicScheduleRepository repository;
  final publishedYears = <String>[];

  @override
  Future<void> syncFromCache({DateTime? now}) async {
    final schedule = await repository.loadCachedSchedule();
    if (schedule != null) publishedYears.add(schedule.term.yearCode);
  }
}

class _Notifications extends AcademicScheduleNotificationService {
  _Notifications(this.repository) : super(repository: repository);
  final AcademicScheduleRepository repository;
  final publishedYears = <String>[];

  @override
  Future<int> syncScheduleReminders(
      {bool requestPermission = false, DateTime? now}) async {
    final schedule = await repository.loadCachedSchedule();
    if (schedule != null) publishedYears.add(schedule.term.yearCode);
    return 0;
  }
}

void main() {
  late _Api api;
  late AcademicScheduleRepository repository;
  late _Widgets widgets;
  late _Notifications notifications;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AcademicAccountStore().saveStudentId('TEST_STUDENT');
    api = _Api();
    repository = AcademicScheduleRepository(apiClient: api);
    await repository.refreshSchedule();
    await repository.setFirstWeekStart(
        AcademicScheduleRepository.startOfWeek(DateTime.now()));
    await repository.discoverSchedules(force: true);
    widgets = _Widgets(repository);
    notifications = _Notifications(repository);
  });

  Future<void> showPage(
    WidgetTester tester, {
    String? themeId,
    Future<void> Function()? onLoginRequired,
    Future<bool> Function()? onRecoverSession,
    ValueChanged<AcademicSchedule?>? onViewedScheduleChanged,
    AcademicScheduleCacheState? initialState,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ShuYoThemes.byId(themeId ?? ShuYoThemes.defaultId).themeData(),
      home: AcademicSchedulePage(
        repository: repository,
        notificationService: notifications,
        widgetService: widgets,
        onLoginRequired: onLoginRequired ?? () async {},
        onRecoverSession: onRecoverSession,
        onViewedScheduleChanged: onViewedScheduleChanged,
        initialState: initialState,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openManager(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理课表'));
    await tester.pumpAndSettle();
    expect(find.byType(AcademicScheduleCollectionPage), findsOneWidget);
  }

  Future<void> refreshViewedTerm(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  Future<void> viewHistory(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('schedule-term-${_history.key}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'switching historical term is local and never publishes it as primary',
      (tester) async {
    await showPage(tester);
    final requests = api.requests;
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    expect(find.text('2026-2027 学年'), findsOneWidget);
    expect(find.text('2025-2026 学年'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('schedule-term-${_history.key}')));
    await tester.pumpAndSettle();
    expect(find.text('2025-2026 秋'), findsOneWidget);
    expect(find.text('正在浏览其他学期，首页、组件和提醒仍使用常用课表'), findsOneWidget);
    expect(api.requests, requests);
    expect((await repository.loadCachedSchedule())!.term.yearCode, '2026');
    expect(widgets.publishedYears.toSet(), {'2026'});
    expect(notifications.publishedYears, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final query in [_current, _history]) {
    testWidgets('share entry uses the viewed working copy for ${query.key}',
        (tester) async {
      final edited = _schedule(query, name: '分享本地修改');
      await repository.saveWorkingSchedule(edited);
      await showPage(tester);
      if (query.key == _history.key) await viewHistory(tester);
      await tester.tap(find.byTooltip('分享与导入'));
      await tester.pumpAndSettle();
      final sharePage =
          tester.widget<ScheduleSharePage>(find.byType(ScheduleSharePage));
      expect(sharePage.ownSchedule!.toJson(), edited.toJson());
      final weekState = await repository.loadTermWeekState(query.key);
      expect(sharePage.ownWeekState!.firstWeekStart, weekState.firstWeekStart);
      expect(await repository.loadPrimaryTermKey(), _current.key);
      expect((await repository.loadCachedSchedule())!.term.yearCode,
          _current.yearCode);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('publishes the displayed working copy when switching terms',
      (tester) async {
    final snapshots = <AcademicSchedule?>[];
    await repository.saveWorkingSchedule(_schedule(_history, name: '历史课表本地修改'));
    await showPage(tester, onViewedScheduleChanged: snapshots.add);
    expect(snapshots.last!.term.yearCode, _current.yearCode);
    await viewHistory(tester);
    expect(snapshots.last!.term.yearCode, _history.yearCode);
    expect(snapshots.last!.sessions.first.courseName, '历史课表本地修改');
    expect(await repository.loadPrimaryTermKey(), _current.key);
    expect((await repository.loadCachedSchedule())!.term.yearCode,
        _current.yearCode);
    expect(notifications.publishedYears, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an initial view is published safely after the first frame',
      (tester) async {
    final snapshots = <AcademicSchedule?>[];
    final initial = _schedule(_history, name: '启动时已加载的课程');
    await showPage(tester,
        onViewedScheduleChanged: snapshots.add,
        initialState: AcademicScheduleCacheState(
          schedule: initial,
          weekState: await repository.loadTermWeekState(_history.key),
        ));
    expect(snapshots.last, same(initial));
    expect(find.text('2025-2026 秋'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshing the viewed term publishes its new course content',
      (tester) async {
    final snapshots = <AcademicSchedule?>[];
    await showPage(tester, onViewedScheduleChanged: snapshots.add);
    await viewHistory(tester);
    api.historicalName = '刷新后的历史课程';
    await refreshViewedTerm(tester);
    expect(snapshots.last!.term.yearCode, _history.yearCode);
    expect(snapshots.last!.sessions.first.courseName, '刷新后的历史课程');
    expect(await repository.loadPrimaryTermKey(), _current.key);
    expect(notifications.publishedYears, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('accepting an empty viewed term publishes an empty snapshot',
      (tester) async {
    final snapshots = <AcademicSchedule?>[];
    await showPage(tester, onViewedScheduleChanged: snapshots.add);
    await viewHistory(tester);
    api.emptyTerms.add(_history.key);
    await refreshViewedTerm(tester);
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    expect(snapshots.last!.term.yearCode, _history.yearCode);
    expect(snapshots.last!.sessions, isEmpty);
    expect(snapshots.last!.untimedCourses, isEmpty);
    expect((await repository.loadCachedSchedule())!.sessions, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management only offers view, update and primary actions',
      (tester) async {
    await showPage(tester);
    await openManager(tester);
    expect(find.text('已保存 2 份课表'), findsOneWidget);
    await tester.tap(find.byTooltip('管理 2025-2026 秋'));
    await tester.pumpAndSettle();
    expect(find.text('查看课表'), findsOneWidget);
    expect(find.text('更新这一学期'), findsOneWidget);
    expect(find.text('设为常用'), findsOneWidget);
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(3));
    expect(find.text('隐藏课表'), findsNothing);
    expect(find.text('恢复显示'), findsNothing);
    expect(find.text('恢复上一版'), findsNothing);
    final menu = tester.widget<Material>(find
        .ancestor(
          of: find.byType(PopupMenuItem<String>).first,
          matching: find.byType(Material),
        )
        .first);
    expect(menu.color, Colors.white);
    expect(menu.surfaceTintColor, Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management omits discovery range and empty-term counts',
      (tester) async {
    const empty = AcademicTermQuery(
        yearCode: '2024',
        termCode: '16',
        academicYearName: '2024-2025',
        termName: '春');
    api.terms.add(empty);
    api.emptyTerms.add(empty.key);
    await repository.discoverSchedules(force: true);
    await showPage(tester);
    await openManager(tester);
    expect(find.text('已保存 2 份课表'), findsOneWidget);
    expect(find.textContaining('默认从'), findsNothing);
    expect(find.textContaining('已记录'), findsNothing);
    expect(find.textContaining('暂无课表的学期'), findsNothing);
    await tester.tap(find.byTooltip('更多检查选项'));
    await tester.pumpAndSettle();
    final menu = tester.widget<Material>(find
        .ancestor(
          of: find.text('完整检查所有学年'),
          matching: find.byType(Material),
        )
        .first);
    expect(menu.color, Colors.white);
    expect(menu.surfaceTintColor, Colors.transparent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker lists semesters without folding or resizing on year taps',
      (tester) async {
    await showPage(tester);
    final trigger = tester
        .widget<InkWell>(find.byKey(const ValueKey('schedule-term-picker')));
    expect(trigger.splashFactory, NoSplash.splashFactory);
    expect(trigger.highlightColor, Colors.transparent);
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    final sheetFinder =
        find.byKey(const ValueKey('schedule-term-picker-sheet'));
    final sheet = tester.widget<Container>(sheetFinder);
    final decoration = sheet.decoration! as BoxDecoration;
    expect(decoration.color, Colors.white);
    expect(decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(8)));
    expect(find.text('切换课表'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byKey(const ValueKey('schedule-term-2026:3')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-term-2025:3')), findsOneWidget);
    final originalRect = tester.getRect(sheetFinder);
    await tester.tap(find.text('2025-2026 学年'));
    await tester.pumpAndSettle();
    expect(tester.getRect(sheetFinder), originalRect);
    expect(find.byKey(const ValueKey('schedule-term-2025:3')), findsOneWidget);
    expect(find.text('管理课表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final themeId in [ShuYoThemes.defaultId, ShuYoThemes.systemDarkId]) {
    testWidgets('picker matches the more menu text size and weight in $themeId',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await showPage(tester, themeId: themeId);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      final moreMenuText = find.text('更新课表');
      final moreMenuStyle =
          DefaultTextStyle.of(tester.element(moreMenuText)).style;
      expect(moreMenuStyle.fontWeight, FontWeight.w400);
      expect(moreMenuStyle.fontSize, 15.5);
      Navigator.of(tester.element(moreMenuText)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
      await tester.pumpAndSettle();
      final picker = find.byType(AcademicScheduleTermPicker);
      final year = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('schedule-year-2026')),
        matching: find.byType(Text),
      ));
      expect(year.style!.fontSize, moreMenuStyle.fontSize);
      expect(year.style!.fontWeight, FontWeight.w400);
      final tile = tester
          .widget<ListTile>(find.byKey(const ValueKey('schedule-term-2026:3')));
      expect(tile.dense, isNot(true));
      expect(tile.minTileHeight, 52);
      expect((tile.title! as Text).style!.fontSize, moreMenuStyle.fontSize);
      final primary = tester
          .widget<Text>(find.descendant(of: picker, matching: find.text('常用')));
      expect(primary.style!.fontSize, moreMenuStyle.fontSize);
      final manager = tester.widget<Text>(
          find.descendant(of: picker, matching: find.text('管理课表')));
      expect(manager.style!.fontSize, moreMenuStyle.fontSize);
      for (final text in tester.widgetList<Text>(
          find.descendant(of: picker, matching: find.byType(Text)))) {
        expect(text.style!.fontWeight, moreMenuStyle.fontWeight);
        expect(text.style!.fontSize, moreMenuStyle.fontSize);
      }
      expect(find.text('管理课表').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('management hides expired-login messages until the user searches',
      (tester) async {
    api.authExpired = true;
    await repository.discoverSchedules(force: true);
    expect(repository.discoveryState.value.requiresLogin, isTrue);
    var recoveries = 0;
    final requests = api.catalogRequests;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      return false;
    });
    await openManager(tester);
    expect(find.text('教务登录已失效，登录后可继续查找'), findsNothing);
    expect(find.text('请先登录校园账户再查找课表'), findsNothing);
    expect(find.text('查找其他课表'), findsOneWidget);
    expect(recoveries, 0);
    expect(api.catalogRequests, requests);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual refresh restores SSO and retries without logging out',
      (tester) async {
    final requests = api.requests;
    var recoveries = 0;
    var legacyLogins = 0;
    api.authExpired = true;
    await showPage(tester, onLoginRequired: () async {
      legacyLogins++;
    }, onRecoverSession: () async {
      recoveries++;
      api.authExpired = false;
      return true;
    });
    await refreshViewedTerm(tester);
    expect(recoveries, 1);
    expect(legacyLogins, 0);
    expect(api.requests, requests + 2);
    expect(await AcademicAccountStore().loadStudentId(), 'TEST_STUDENT');
    expect(find.textContaining('课表已同步'), findsOneWidget);
    expect(find.text('课表刷新失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('historical refresh retries the selected term after SSO recovery',
      (tester) async {
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      api.authExpired = false;
      api.historicalName = '恢复后的历史课程';
      return true;
    });
    await viewHistory(tester);
    api.authExpired = true;
    final requests = api.requests;
    await refreshViewedTerm(tester);
    expect(recoveries, 1);
    expect(api.requests, requests + 2);
    expect(await repository.loadPrimaryTermKey(), _current.key);
    expect(
        (await repository.loadTermRecord(_history.key))!
            .schedule!
            .sessions
            .every((course) => course.courseName == '恢复后的历史课程'),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery cannot redirect a refresh to a newly selected primary',
      (tester) async {
    await showPage(tester, onRecoverSession: () async {
      api.authExpired = false;
      await repository.setPrimaryTerm(_history.key);
      return true;
    });
    api.authExpired = true;
    await refreshViewedTerm(tester);
    expect(api.requestedTerms.sublist(api.requestedTerms.length - 2),
        [_current.key, _current.key]);
    expect(await repository.loadPrimaryTermKey(), _history.key);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management update restores SSO and retries the same term',
      (tester) async {
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      api.authExpired = false;
      api.historicalName = '管理页恢复后的课程';
      return true;
    });
    await openManager(tester);
    api.authExpired = true;
    final requests = api.requests;
    await tester.tap(find.descendant(
      of: find.byKey(ValueKey('managed-schedule-${_history.key}')),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新这一学期'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(api.requests, requests + 2);
    expect(find.text('这一学期的课表已更新'), findsOneWidget);
    expect(
        (await repository.loadTermRecord(_history.key))!
            .schedule!
            .sessions
            .every((course) => course.courseName == '管理页恢复后的课程'),
        isTrue);
    expect(await repository.loadPrimaryTermKey(), _current.key);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed manual recovery keeps saved schedules without retrying',
      (tester) async {
    final requests = api.requests;
    final cached = (await repository.loadCachedSchedule())!.toJson();
    var recoveries = 0;
    api.authExpired = true;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      return false;
    });
    await refreshViewedTerm(tester);
    expect(recoveries, 1);
    expect(api.requests, requests + 1);
    expect((await repository.loadCachedSchedule())!.toJson(), cached);
    expect((await repository.loadSavedSchedules()).length, 2);
    expect(find.text('课表刷新失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent manual expiry does not recover in a loop',
      (tester) async {
    final requests = api.requests;
    var recoveries = 0;
    var legacyLogins = 0;
    api.authExpired = true;
    await showPage(tester, onLoginRequired: () async {
      legacyLogins++;
    }, onRecoverSession: () async {
      recoveries++;
      return true;
    });
    await refreshViewedTerm(tester);
    expect(recoveries, 1);
    expect(legacyLogins, 0);
    expect(api.requests, requests + 2);
    expect(find.text('教务登录恢复后仍无法同步，请稍后重试'), findsOneWidget);
    expect((await repository.loadSavedSchedules()).length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('known expiry recovers first and continues discovery in one tap',
      (tester) async {
    api.authExpired = true;
    await repository.discoverSchedules(force: true);
    final requests = api.catalogRequests;
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      expect(api.catalogRequests, requests);
      api.authExpired = false;
      return true;
    });
    await openManager(tester);
    await tester.tap(find.text('查找其他课表'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(api.catalogRequests, requests + 1);
    expect(repository.discoveryState.value.requiresLogin, isFalse);
    expect(find.textContaining('登录'), findsNothing);
    expect((await repository.loadSavedSchedules()).length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('newly detected expiry recovers and retries discovery once',
      (tester) async {
    api.authExpired = true;
    final requests = api.catalogRequests;
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      expect(api.catalogRequests, requests + 1);
      api.authExpired = false;
      return true;
    });
    await openManager(tester);
    await tester.tap(find.text('查找其他课表'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(api.catalogRequests, requests + 2);
    expect(repository.discoveryState.value.requiresLogin, isFalse);
    expect(find.textContaining('登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed recovery stops discovery without an expiry warning',
      (tester) async {
    api.authExpired = true;
    await repository.discoverSchedules(force: true);
    final requests = api.catalogRequests;
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      return false;
    });
    await openManager(tester);
    await tester.tap(find.text('查找其他课表'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(api.catalogRequests, requests);
    expect(find.textContaining('登录'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '查找其他课表'))
            .onPressed,
        isNotNull);
    expect((await repository.loadSavedSchedules()).length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search remains disabled while session recovery is pending',
      (tester) async {
    api.authExpired = true;
    await repository.discoverSchedules(force: true);
    final requests = api.catalogRequests;
    final recovery = Completer<bool>();
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () {
      recoveries++;
      return recovery.future;
    });
    await openManager(tester);
    final search = find.widgetWithText(FilledButton, '查找其他课表');
    await tester.tap(search);
    await tester.pump();
    expect(tester.widget<FilledButton>(search).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('登录'), findsNothing);
    await tester.tap(search);
    await tester.pump();
    expect(recoveries, 1);
    expect(api.catalogRequests, requests);
    api.authExpired = false;
    recovery.complete(true);
    await tester.pumpAndSettle();
    expect(api.catalogRequests, requests + 1);
    expect(tester.widget<FilledButton>(search).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent expiry does not cause a recovery loop',
      (tester) async {
    api.authExpired = true;
    final requests = api.catalogRequests;
    var recoveries = 0;
    await showPage(tester, onRecoverSession: () async {
      recoveries++;
      return true;
    });
    await openManager(tester);
    await tester.tap(find.text('查找其他课表'));
    await tester.pumpAndSettle();
    expect(recoveries, 1);
    expect(api.catalogRequests, requests + 2);
    expect(repository.discoveryState.value.requiresLogin, isTrue);
    expect(find.textContaining('登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy login callback also resumes the requested discovery',
      (tester) async {
    api.authExpired = true;
    await repository.discoverSchedules(force: true);
    final requests = api.catalogRequests;
    var logins = 0;
    await showPage(tester, onLoginRequired: () async {
      logins++;
      api.authExpired = false;
    });
    await openManager(tester);
    await tester.tap(find.text('查找其他课表'));
    await tester.pumpAndSettle();
    expect(logins, 1);
    expect(api.catalogRequests, requests + 1);
    expect(repository.discoveryState.value.requiresLogin, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management still shows non-authentication discovery errors',
      (tester) async {
    repository.discoveryState.value =
        const ScheduleDiscoveryState(message: '网络连接失败，请稍后重试');
    await showPage(tester);
    await openManager(tester);
    expect(find.text('网络连接失败，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'long picker scrolls within its maximum height in both directions',
      (tester) async {
    final original = _schedule(_history);
    for (var year = 2024; year >= 2020; year--) {
      for (final term in const {'3': '秋', '16': '春', '32': '夏'}.entries) {
        await repository.saveWorkingSchedule(original.copyWith(
            term: AcademicTerm(
          yearCode: '$year',
          termCode: term.key,
          academicYearName: '$year-${year + 1}',
          termName: term.value,
          studentName: '',
          studentId: 'TEST_STUDENT',
          className: '',
        )));
      }
    }
    await showPage(tester);
    final requests = api.requests;
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    final sheetFinder =
        find.byKey(const ValueKey('schedule-term-picker-sheet'));
    final originalRect = tester.getRect(sheetFinder);
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(originalRect.height, lessThanOrEqualTo(screenHeight * .75));
    final scrollable = find.descendant(
        of: find.byType(AcademicScheduleTermPicker),
        matching: find.byType(Scrollable));
    final lastTerm = find.byKey(const ValueKey('schedule-term-2020:32'));
    final firstTerm = find.byKey(const ValueKey('schedule-term-2026:3'));
    await tester.scrollUntilVisible(lastTerm, 240, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(lastTerm.hitTestable(), findsOneWidget);
    expect(find.text('管理课表').hitTestable(), findsOneWidget);
    expect(tester.getRect(sheetFinder), originalRect);
    await tester.scrollUntilVisible(firstTerm, -240, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(firstTerm.hitTestable(), findsOneWidget);
    expect(tester.getRect(sheetFinder), originalRect);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(api.requests, requests);
    expect(tester.takeException(), isNull);
  });

  for (final themeId in [ShuYoThemes.defaultId, ShuYoThemes.systemDarkId]) {
    testWidgets('management uses regular weight throughout in $themeId',
        (tester) async {
      await showPage(tester, themeId: themeId);
      await openManager(tester);
      final page = find.byType(AcademicScheduleCollectionPage);
      TextStyle effectiveStyle(Finder finder) {
        final text = tester.widget<Text>(finder);
        return DefaultTextStyle.of(tester.element(finder))
            .style
            .merge(text.style);
      }

      for (final text in tester.widgetList<Text>(
          find.descendant(of: page, matching: find.byType(Text)))) {
        expect(effectiveStyle(find.byWidget(text)).fontWeight, FontWeight.w400);
      }
      expect(effectiveStyle(find.text('管理课表')).fontSize, 17.5);
      expect(effectiveStyle(find.text('已保存 2 份课表')).fontSize, 15.5);
      expect(effectiveStyle(find.text('2026-2027 学年')).fontSize, 14.5);
      expect(effectiveStyle(find.text('查找其他课表')).fontSize, 14);
      final tile = tester.widget<ListTile>(
          find.byKey(const ValueKey('managed-schedule-2026:3')));
      final title = tile.title! as Text;
      final term = (title.textSpan! as TextSpan).children!.first as TextSpan;
      expect(term.style!.fontWeight, FontWeight.w400);
      expect(title.style!.fontSize, 15.5);
      final badgeText = find.descendant(
          of: find.byKey(const ValueKey('managed-schedule-primary-2026:3')),
          matching: find.byType(Text));
      expect(effectiveStyle(badgeText).fontSize, 11);
      await tester.tap(find.byTooltip('管理 2025-2026 秋'));
      await tester.pumpAndSettle();
      for (final text in ['查看课表', '更新这一学期', '设为常用']) {
        expect(effectiveStyle(find.text(text)).fontWeight, FontWeight.w400);
      }
      Navigator.of(tester.element(find.text('查看课表'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多检查选项'));
      await tester.pumpAndSettle();
      expect(effectiveStyle(find.text('完整检查所有学年')).fontWeight, FontWeight.w400);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'management vertically centers the primary pill in the full schedule row',
      (tester) async {
    await showPage(tester);
    await openManager(tester);
    final colors = ShuYoThemes.byId(ShuYoThemes.defaultId).colors;
    final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('managed-schedule-2026:3')));
    final badgeFinder =
        find.byKey(const ValueKey('managed-schedule-primary-2026:3'));
    final badge = tester.widget<Container>(badgeFinder);
    final decoration = badge.decoration! as BoxDecoration;
    expect(decoration.color, colors.accent);
    expect(decoration.borderRadius, BorderRadius.circular(999));
    final badgeText = badge.child! as Text;
    expect(badgeText.data, '常用');
    expect(badgeText.style!.color, Colors.white);
    expect(
        badge.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 2));
    final badgeContext = tester.element(badgeFinder);
    final originalStyle = Theme.of(badgeContext).textTheme.bodyLarge!.copyWith(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w400,
        );
    final originalText = TextPainter(
      text: TextSpan(text: '常用', style: originalStyle),
      textDirection: Directionality.of(badgeContext),
      textScaler: MediaQuery.textScalerOf(badgeContext),
      locale: Localizations.maybeLocaleOf(badgeContext),
    )..layout();
    addTearDown(originalText.dispose);
    expect(tester.getSize(find.byWidget(badgeText)), originalText.size);
    expect(tester.getSize(badgeFinder),
        Size(originalText.width + 24, originalText.height + 4));
    expect(tile.title, isA<Text>());
    expect(tile.titleAlignment, ListTileTitleAlignment.center);
    expect(
        find.descendant(
            of: find.byWidget(tile.trailing!), matching: badgeFinder),
        findsOneWidget);
    expect(tester.getRect(badgeFinder).center.dy,
        closeTo(tester.getRect(find.byWidget(tile)).center.dy, 0.01));
    expect(
        tester.getRect(badgeFinder).center.dy,
        closeTo(
            tester.getRect(find.byTooltip('管理 2026-2027 秋')).center.dy, 0.01));
    expect(tile.isThreeLine, isFalse);
    final metadata = tester.widget<Text>(
        find.byKey(const ValueKey('managed-schedule-meta-2026:3')));
    expect(metadata.textSpan!.toPlainText(), startsWith('同步于 '));
    expect(metadata.style!.color, colors.textMuted);
    expect(metadata.maxLines, 1);
    expect(metadata.textSpan!.toPlainText(), isNot(contains('常用')));
    expect(find.text('开学日期未设置'), findsNothing);
    expect(find.byKey(const ValueKey('managed-schedule-primary-2025:3')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final age in [
    Duration.zero,
    const Duration(minutes: 10),
    const Duration(hours: 3),
    const Duration(days: 3),
    const Duration(days: 21),
    const Duration(days: 120),
    const Duration(days: 400),
  ]) {
    testWidgets('management formats a sync time $age ago', (tester) async {
      final syncedAt = DateTime.now().subtract(age);
      final prefs = await SharedPreferences.getInstance();
      final key =
          'academic.schedule.collection.TEST_STUDENT.term.${_current.key}';
      final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      record['syncedAt'] = syncedAt.toUtc().toIso8601String();
      await prefs.setString(key, jsonEncode(record));
      await showPage(tester);
      await openManager(tester);
      final expected = age.inMinutes < 1
          ? '刚刚'
          : age.inHours < 1
              ? '${age.inMinutes}分钟前'
              : age.inDays < 1
                  ? '${age.inHours}小时前'
                  : age.inDays < 7
                      ? '${age.inDays}天前'
                      : age.inDays < 365
                          ? '${syncedAt.month}月${syncedAt.day}日'
                          : '${syncedAt.year}年${syncedAt.month}月${syncedAt.day}日';
      final metadata = tester.widget<Text>(
          find.byKey(const ValueKey('managed-schedule-meta-2026:3')));
      expect(metadata.textSpan!.toPlainText(), '同步于 $expected');
      expect(metadata.style!.color,
          ShuYoThemes.byId(ShuYoThemes.defaultId).colors.textMuted);
      expect(metadata.maxLines, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('management omits sync metadata when no sync time is saved',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'academic.schedule.collection.TEST_STUDENT.term.${_current.key}';
    final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    record.remove('syncedAt');
    await prefs.setString(key, jsonEncode(record));
    await showPage(tester);
    await openManager(tester);
    final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('managed-schedule-2026:3')));
    expect(tile.subtitle, isNull);
    expect(find.byKey(const ValueKey('managed-schedule-meta-2026:3')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local edit status stays on the same compact metadata line',
      (tester) async {
    await repository.saveWorkingSchedule(_schedule(_history, name: '本地修改'));
    await showPage(tester);
    await openManager(tester);
    final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('managed-schedule-2025:3')));
    final metadata = tester.widget<Text>(
        find.byKey(const ValueKey('managed-schedule-meta-2025:3')));
    expect(tile.isThreeLine, isFalse);
    expect(metadata.maxLines, 1);
    expect(metadata.textSpan!.toPlainText(), startsWith('有本地修改 · 同步于 '));
    expect(metadata.textSpan!.toPlainText(), isNot(contains('\n')));
    expect(metadata.textSpan!.toPlainText(), isNot(contains('开学日期未设置')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'formerly hidden schedules remain selectable after feature removal',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'academic.schedule.collection.TEST_STUDENT.term.${_history.key}';
    final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    record['hidden'] = true;
    record['backup'] = _schedule(_history, name: '旧备份').toJson();
    await prefs.setString(key, jsonEncode(record));
    await showPage(tester);
    await viewHistory(tester);
    expect(find.text('2025-2026 秋'), findsOneWidget);
    expect((await repository.loadTermRecord(_history.key))!.schedule!.sessions,
        isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing calendar banner only says its date is unset',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'academic.schedule.collection.TEST_STUDENT.term.${_current.key}';
    final record = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    record.remove('firstWeekStart');
    await prefs.setString(key, jsonEncode(record));
    await showPage(tester);
    expect(find.text('开学日期未设置'), findsOneWidget);
    expect(find.textContaining('设置后才能'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark picker and management menus keep dark surfaces',
      (tester) async {
    await showPage(tester, themeId: ShuYoThemes.systemDarkId);
    final surface = ShuYoThemes.byId(ShuYoThemes.systemDarkId).colors.surface;
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    final sheet = tester.widget<Container>(
        find.byKey(const ValueKey('schedule-term-picker-sheet')));
    expect((sheet.decoration! as BoxDecoration).color, surface);
    await tester.tap(find.text('管理课表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('管理 2025-2026 秋'));
    await tester.pumpAndSettle();
    final menu = tester.widget<Material>(find
        .ancestor(
          of: find.byType(PopupMenuItem<String>).first,
          matching: find.byType(Material),
        )
        .first);
    expect(menu.color, surface);
    expect(menu.surfaceTintColor, Colors.transparent);
    final badge = tester.widget<Container>(
        find.byKey(const ValueKey('managed-schedule-primary-2026:3')));
    expect((badge.decoration! as BoxDecoration).color,
        ShuYoThemes.byId(ShuYoThemes.systemDarkId).colors.accent);
    expect((badge.child! as Text).style!.color, Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setting primary is explicit and warns about an unset calendar',
      (tester) async {
    await showPage(tester);
    await openManager(tester);
    await tester.tap(find.byTooltip('管理 2025-2026 秋'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为常用'));
    await tester.pumpAndSettle();
    expect(await repository.loadPrimaryTermKey(), _history.key);
    expect(await repository.primaryCalendarConfigured(), isFalse);
    expect(find.text('已设为常用课表，请设置开学日期后启用课程提醒'), findsOneWidget);
    expect(notifications.publishedYears, ['2025']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Setting primary does not silently navigate away from the term being read.
    expect(find.text('2026-2027 秋'), findsOneWidget);
    expect(find.text('正在浏览其他学期，首页、组件和提醒仍使用常用课表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'updating an edited historical term confirms scope without restore copy',
      (tester) async {
    await repository.saveWorkingSchedule(_schedule(_history, name: '本地修改'));
    api.historicalName = '教务更新';
    await showPage(tester);
    await openManager(tester);
    await tester.tap(find.byTooltip('管理 2025-2026 秋'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新这一学期'));
    await tester.pumpAndSettle();
    expect(find.text('更新将覆盖 2025-2026 秋 的本地修改。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final record = (await repository.loadTermRecord(_history.key))!;
    expect(record.schedule!.sessions.first.courseName, '教务更新');
    expect(record.toJson().containsKey('backup'), isFalse);
    expect(find.textContaining('备份'), findsNothing);
    expect(find.textContaining('恢复上一版'), findsNothing);
    expect((await repository.loadCachedSchedule())!.term.yearCode, '2026');
    expect(notifications.publishedYears, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an in-flight primary update keeps the newly selected view',
      (tester) async {
    final snapshots = <AcademicSchedule?>[];
    await showPage(tester, onViewedScheduleChanged: snapshots.add);
    api.refreshGate = Completer<void>();
    final requests = api.requests;
    await refreshViewedTerm(tester);
    await viewHistory(tester);
    snapshots.clear();
    api.refreshGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('2025-2026 秋'), findsOneWidget);
    expect(snapshots, isNotEmpty);
    expect(
        snapshots
            .every((snapshot) => snapshot!.term.yearCode == _history.yearCode),
        isTrue);
    expect(api.requests, requests + 1);
    expect(notifications.publishedYears, ['2026']);
    expect((await repository.loadCachedSchedule())!.term.yearCode, '2026');
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty confirmation stays scoped when switching during refresh',
      (tester) async {
    await showPage(tester);
    api.emptyTerms.add(_current.key);
    api.refreshGate = Completer<void>();
    final requests = api.requests;
    await refreshViewedTerm(tester);
    await viewHistory(tester);
    api.refreshGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('教务返回空课表'), findsOneWidget);
    expect(find.text('是否将 2026-2027 秋 替换为空课表？'), findsOneWidget);
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    final primary = (await repository.loadTermRecord(_current.key))!;
    final history = (await repository.loadTermRecord(_history.key))!;
    expect(primary.schedule!.sessions, isEmpty);
    expect(primary.toJson().containsKey('backup'), isFalse);
    expect(history.schedule!.sessions, isNotEmpty);
    expect(find.text('2025-2026 秋'), findsOneWidget);
    expect(api.requests, requests + 1);
    expect(notifications.publishedYears, ['2026']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stale empty confirmation reports an error without losing data',
      (tester) async {
    await showPage(tester);
    await viewHistory(tester);
    api.emptyTerms.add(_history.key);
    await refreshViewedTerm(tester);
    expect(find.text('教务返回空课表'), findsOneWidget);
    // Another completed sync makes the pending confirmation stale.
    api.emptyTerms.remove(_history.key);
    await repository.refreshTerm(_history.key, replaceEdited: true);
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    expect(find.text('课表刷新失败'), findsOneWidget);
    expect(find.text('没有待确认的空课表'), findsOneWidget);
    expect((await repository.loadTermRecord(_history.key))!.schedule!.sessions,
        isNotEmpty);
    expect(notifications.publishedYears, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all semesters of the same year share one picker heading',
      (tester) async {
    final original = _schedule(_history);
    await repository.saveWorkingSchedule(original.copyWith(
        term: AcademicTerm(
      yearCode: '2025',
      termCode: '16',
      academicYearName: '2025-2026',
      termName: '春',
      studentName: '',
      studentId: 'TEST_STUDENT',
      className: '',
    )));
    await showPage(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    expect(find.text('2025-2026 学年'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-term-2025:3')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-term-2025:16')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
