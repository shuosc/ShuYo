import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/app/app_shell.dart';
import 'package:shuyo/core/app_tab.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/features/home/academic_schedule_page.dart';
import 'package:shuyo/features/onboarding/startup_onboarding.dart';
import 'package:shuyo/features/rate/rate_home_page.dart';

AcademicSchedule _schedule(String year, String name) {
  final data = jsonDecode(
    File('test/fixtures/academic_schedule/historical_schedule.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final term = data['xsxx'] as Map<String, dynamic>;
  term['XNM'] = year;
  term['XNMC'] = '$year-${int.parse(year) + 1}';
  data['kbList'] = [
    {...(data['kbList'] as List).first as Map<String, dynamic>, 'kcmc': name},
  ];
  data['sjkList'] = [];
  return AcademicScheduleParser.parse(data);
}

void main() {
  late AcademicScheduleRepository repository;
  late AcademicSchedule primary;
  late AcademicSchedule history;
  late StartupOnboardingController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AcademicAccountStore().saveStudentId('TEST_STUDENT');
    repository = AcademicScheduleRepository();
    primary = _schedule('2026', '常用课表课程');
    history = _schedule('2025', '历史课表本地课程');
    await repository.saveWorkingSchedule(primary);
    await repository.saveWorkingSchedule(history);
    controller = StartupOnboardingController();
    addTearDown(controller.dispose);
  });

  Future<void> showApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppShell(
        initialWebVpnEnabled: false,
        selectedThemeId: 'default',
        followSystemTheme: false,
        onThemeChanged: (_) async {},
        onFollowSystemThemeChanged: (_) async {},
        academicLoginSignal: 0,
        initialHasAcademicSession: true,
        initialAcademicStudentId: 'TEST_STUDENT',
        onboardingController: controller,
        initialStartupTab: AppTab.rate,
        scheduleRepository: repository,
        isDemo: true,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> selectTab(WidgetTester tester, AppTab tab) async {
    tester
        .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
        .onTap!(tab.index);
    await tester.pumpAndSettle();
  }

  Future<void> viewHistory(WidgetTester tester) async {
    await selectTab(tester, AppTab.schedule);
    await tester.tap(find.byKey(const ValueKey('schedule-term-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-term-2025:3')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'course reviews follow the viewed working copy without rekeying pages',
      (tester) async {
    await showApp(tester);
    final initialRatePage =
        tester.widget<RateHomePage>(find.byType(RateHomePage));
    final rateState = tester.state(find.byType(RateHomePage));
    expect(
        (await initialRatePage.repository.scheduleCourses()).single.courseName,
        '常用课表课程');
    await viewHistory(tester);
    final scheduleState = tester.state(find.byType(AcademicSchedulePage));
    expect(find.text('2025-2026 秋'), findsOneWidget);
    await selectTab(tester, AppTab.rate);

    final ratePage = tester.widget<RateHomePage>(find.byType(RateHomePage));
    expect((await ratePage.repository.scheduleCourses()).single.courseName,
        '历史课表本地课程');
    expect(ratePage.scheduleRevision,
        greaterThan(initialRatePage.scheduleRevision));
    expect(tester.state(find.byType(RateHomePage)), same(rateState));
    expect(tester.state(find.byType(AcademicSchedulePage, skipOffstage: false)),
        same(scheduleState));
    expect((await repository.loadCachedSchedule())!.toJson(), primary.toJson());
    expect(await repository.loadPrimaryTermKey(), '2026:3');

    // Republishing equivalent data must not trigger another lookup revision.
    final schedulePage = tester.widget<AcademicSchedulePage>(
        find.byType(AcademicSchedulePage, skipOffstage: false));
    schedulePage
        .onViewedScheduleChanged!(AcademicSchedule.fromJson(history.toJson()));
    await tester.pumpAndSettle();
    expect(
        tester.widget<RateHomePage>(find.byType(RateHomePage)).scheduleRevision,
        ratePage.scheduleRevision);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('an empty viewed schedule never falls back to primary courses',
      (tester) async {
    await repository.saveWorkingSchedule(history.copyWith(sessions: []));
    await showApp(tester);
    await viewHistory(tester);
    await selectTab(tester, AppTab.rate);
    final ratePage = tester.widget<RateHomePage>(find.byType(RateHomePage));
    expect(await ratePage.repository.scheduleCourses(), isEmpty);
    expect((await repository.loadCachedSchedule())!.sessions, isNotEmpty);
    expect(await repository.loadPrimaryTermKey(), '2026:3');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
