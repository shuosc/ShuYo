import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/home/home_dashboard_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';

void main() {
  testWidgets('custom photo keeps stronger home text without tap ripple',
      (tester) async {
    const background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 100,
      background: Color(0xFF777777),
      surface: Color(0xFFBBBBBB),
      text: Colors.black,
      accent: Colors.blue,
    );
    await tester.pumpWidget(MaterialApp(
      theme: background.theme.themeData(),
      builder: (_, child) => CustomBackgroundFrame(
        settings: background,
        child: child!,
      ),
      home: Scaffold(
        body: HomeDashboardPage(
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
    ));

    expect(
      tester.widget<Text>(find.text('查询当前可用教室')).style?.color,
      background.text,
    );
    final todayRow = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('今日课程'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(todayRow.splashFactory, NoSplash.splashFactory);
    expect(todayRow.overlayColor?.resolve({WidgetState.pressed}),
        Colors.transparent);
    final todayContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('今日课程'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(todayContainer.decoration, isNull);
    final firstContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('立即登录'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(firstContainer.decoration, isNull);
  });

  Widget page(
          {required bool loggedIn,
          bool syncing = false,
          bool expired = false,
          String? displayName}) =>
      MaterialApp(
        home: Scaffold(
          body: HomeDashboardPage(
            hasAcademicAccount: loggedIn,
            academicSessionExpired: expired,
            academicDisplayName: loggedIn ? displayName ?? '25120000' : null,
            isAcademicLoginCompleting: syncing,
            onLogin: () {},
            onOpenAcademicSystem: () {},
            onOpenAnnouncements: () {},
            onOpenEmptyClassroom: () {},
            onOpenOtp: () {},
            todayCourseContent: '今日无课',
            announcementContent: '查看公告',
          ),
        ),
      );

  testWidgets('campus login shows student greeting and campus services',
      (tester) async {
    await tester.pumpWidget(page(loggedIn: true));
    expect(find.text('你好，25120000！'), findsOneWidget);
    expect(find.text('今日课程'), findsOneWidget);
    expect(find.text('空教室查询'), findsOneWidget);
    expect(find.text('图书馆预约'), findsOneWidget);
    expect(find.text('动态口令'), findsOneWidget);
    expect(find.text('课程评价'), findsNothing);
    expect(find.textContaining('论坛'), findsNothing);
    final firstContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('你好，25120000！'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((firstContainer.decoration as BoxDecoration).border, isNotNull);
    for (final title in ['今日课程', '通知公告', '空教室查询', '图书馆预约', '动态口令']) {
      final row = tester.widget<Container>(
        find
            .ancestor(
              of: find.text(title),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((row.decoration as BoxDecoration).border, isNotNull);
    }
  });

  testWidgets('logged out home invites campus login', (tester) async {
    await tester.pumpWidget(page(loggedIn: false));
    expect(find.text('立即登录'), findsOneWidget);
    expect(find.text('登录后同步个人数据'), findsOneWidget);
  });

  testWidgets('custom nickname changes only the home greeting', (tester) async {
    await tester.pumpWidget(page(loggedIn: true, displayName: '小明'));
    expect(find.text('你好，小明！'), findsOneWidget);
    expect(find.text('你好，25120000！'), findsNothing);
  });

  testWidgets(
      'expired account invites reauthentication while retaining local data',
      (tester) async {
    await tester.pumpWidget(page(loggedIn: false, expired: true));
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    expect(find.text('今日无课'), findsOneWidget);
  });
}
