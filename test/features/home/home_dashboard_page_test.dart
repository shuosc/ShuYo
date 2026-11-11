import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/home_layout.dart';
import 'package:shuyo/features/home/home_dashboard_page.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  TextStyle renderedTextStyle(WidgetTester tester, String text) {
    final finder = find.text(text);
    return DefaultTextStyle.of(tester.element(finder))
        .style
        .merge(tester.widget<Text>(finder).style);
  }

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
      renderedTextStyle(tester, '查看可用教室').color,
      background.text,
    );
    final todayTheme = Theme.of(tester.element(find.text('今日课程')));
    expect(todayTheme.splashFactory, NoSplash.splashFactory);
    expect(todayTheme.splashColor, Colors.transparent);
    expect(todayTheme.highlightColor, Colors.transparent);
    expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('home-background')))
            .color,
        Colors.transparent);
    expect(find.byType(Divider), findsOneWidget);
  });

  Widget page(
          {required bool loggedIn,
          bool syncing = false,
          bool expired = false,
          String? displayName,
          ShuYoThemeSpec? theme,
          HomeLayout? layout,
          TextScaler textScaler = TextScaler.noScaling,
          String todayCourseContent = '今日无课',
          String announcementContent = '查看公告'}) =>
      MaterialApp(
        theme: theme?.themeData(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: HomeDashboardPage(
            layout: layout,
            hasAcademicAccount: loggedIn,
            academicSessionExpired: expired,
            academicDisplayName: loggedIn ? displayName ?? '25120000' : null,
            isAcademicLoginCompleting: syncing,
            onLogin: () {},
            onOpenAcademicSystem: () {},
            onOpenAnnouncements: () {},
            onOpenEmptyClassroom: () {},
            onOpenOtp: () {},
            todayCourseContent: todayCourseContent,
            announcementContent: announcementContent,
          ),
        ),
      );

  testWidgets('campus login shows student greeting and campus services',
      (tester) async {
    await tester.pumpWidget(page(loggedIn: true));
    expect(find.text('你好，25120000！'), findsOneWidget);
    expect(find.text('今日课程'), findsOneWidget);
    expect(find.text('空教室'), findsOneWidget);
    expect(find.text('查看可用教室'), findsOneWidget);
    expect(find.text('图书馆预约'), findsOneWidget);
    expect(find.text('课程录播'), findsOneWidget);
    expect(find.text('动态口令'), findsOneWidget);
    expect(find.text('课程评价'), findsNothing);
    expect(find.textContaining('论坛'), findsNothing);
    final overview = find.byKey(const ValueKey('home-card:overview'));
    final services = find.byKey(const ValueKey('home-card:services'));
    expect(find.descendant(of: overview, matching: find.text('今日课程')),
        findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('通知公告')),
        findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('空教室')),
        findsOneWidget);
    expect(find.descendant(of: services, matching: find.text('动态口令')),
        findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('你好，25120000！'), matching: find.byType(Card)),
        findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('今日概览'), findsNothing);
    expect(find.text('校园服务'), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byType(Card), findsNWidgets(2));
    final greetingStyle = renderedTextStyle(tester, '你好，25120000！');
    final moduleStyle = renderedTextStyle(tester, '今日课程');
    expect(greetingStyle.fontSize, moduleStyle.fontSize);
    expect(greetingStyle.fontWeight, moduleStyle.fontWeight);
    expect(greetingStyle.height, moduleStyle.height);
    final greeting = tester.widget<ListTile>(find.ancestor(
      of: find.text('你好，25120000！'),
      matching: find.byType(ListTile),
    ));
    final greetingSubtitle = (greeting.subtitle! as Text).data!;
    final greetingSubtitleStyle = renderedTextStyle(tester, greetingSubtitle);
    final moduleSubtitleStyle = renderedTextStyle(tester, '今日无课');
    expect(greetingSubtitleStyle.fontSize, moduleSubtitleStyle.fontSize);
    expect(greetingSubtitleStyle.fontWeight, moduleSubtitleStyle.fontWeight);
  });

  testWidgets('logged out home invites campus login', (tester) async {
    await tester.pumpWidget(page(loggedIn: false));
    expect(find.text('立即登录'), findsOneWidget);
    expect(find.text('登录后同步个人数据'), findsOneWidget);
  });

  for (final themeId in [
    ShuYoThemes.defaultId,
    'paper_light',
    'morning_coral',
    ShuYoThemes.systemDarkId
  ]) {
    testWidgets('grouped list uses the existing $themeId theme',
        (tester) async {
      final theme = ShuYoThemes.byId(themeId);
      await tester.pumpWidget(page(loggedIn: true, theme: theme));
      final card = tester.widget<Card>(find.descendant(
        of: find.byKey(const ValueKey('home-card:overview')),
        matching: find.byType(Card),
      ));
      final background = tester
          .widget<ColoredBox>(find.byKey(const ValueKey('home-background')))
          .color;
      expect(background, theme.colors.background);
      expect(background,
          Theme.of(tester.element(find.text('今日课程'))).scaffoldBackgroundColor);
      if (theme.colors.brightness == Brightness.light) {
        expect(card.color, const Color(0xFFFFFEFC));
        final material = tester.widget<Material>(find
            .descendant(
              of: find.byKey(const ValueKey('home-card:overview')),
              matching: find.byType(Material),
            )
            .first);
        expect(material.elevation, 0.5);
        expect(material.shadowColor,
            Theme.of(tester.element(find.text('今日课程'))).colorScheme.shadow);
      } else {
        expect(card.color, theme.colors.surface);
        expect(card.elevation, 0);
      }
      expect(
          (card.shape! as RoundedRectangleBorder).side.style, BorderStyle.none);
      final titleStyle = renderedTextStyle(tester, '今日课程');
      final subtitleStyle = renderedTextStyle(tester, '今日无课');
      expect(titleStyle.color, theme.colors.textPrimary);
      expect(
          subtitleStyle.color,
          Color.lerp(
              theme.colors.textSecondary, theme.colors.textTertiary, 0.7));
      expect(titleStyle.fontSize, greaterThan(subtitleStyle.fontSize!));
      expect(titleStyle.fontWeight!.value,
          greaterThan(subtitleStyle.fontWeight!.value));
      expect(find.byType(Divider), findsOneWidget);
      expect(find.text('今日概览'), findsNothing);
      expect(find.text('校园服务'), findsNothing);
    });
  }

  testWidgets('all hidden modules retain the account without a footer entry',
      (tester) async {
    var layout = HomeLayout.defaults();
    for (final module in HomeModule.values) {
      layout = layout.setEnabled(module, false);
    }
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeDashboardPage(
          layout: layout,
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
    expect(find.text('立即登录'), findsOneWidget);
    expect(find.text('今日课程'), findsNothing);
    expect(find.text('今日概览'), findsNothing);
    expect(find.byType(Card), findsOneWidget);
    expect(find.text('自定义首页'), findsNothing);
  });

  testWidgets('only explicitly inserted dividers appear inside their card',
      (tester) async {
    var layout = HomeLayout.defaults()
        .removeDivider('overview-divider')
        .addDivider('line');
    layout = layout.move(layout.entries.length - 1, 2);
    await tester.pumpWidget(page(loggedIn: true, layout: layout));
    final divider = find.byKey(const ValueKey('divider:line'));
    expect(find.byType(Divider), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-card:overview')),
            matching: divider),
        findsOneWidget);
    expect(tester.getCenter(find.text('今日课程')).dy,
        lessThan(tester.getCenter(divider).dy));
    expect(tester.getCenter(divider).dy,
        lessThan(tester.getCenter(find.text('校园卡')).dy));
    final cardSurface = find
        .descendant(
          of: find.byKey(const ValueKey('home-card:overview')),
          matching: find.byType(Material),
        )
        .first;
    final line =
        find.descendant(of: divider, matching: find.byType(DecoratedBox));
    expect(tester.getRect(line).left, tester.getRect(cardSurface).left);
    expect(tester.getRect(line).right, tester.getRect(cardSurface).right);
    await tester
        .pumpWidget(page(loggedIn: true, layout: layout.removeDivider('line')));
    expect(find.byType(Divider), findsNothing);
    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets('larger text and long summaries fit a narrow home page',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(page(
      loggedIn: true,
      theme: ShuYoThemes.byId(ShuYoThemes.defaultId),
      textScaler: const TextScaler.linear(1.6),
      displayName: '一个较长的校园昵称',
      todayCourseContent: '下一节课程为大学物理实验，教学楼一号楼，今日还有三节课。',
      announcementContent: '关于本学期课程安排及教学楼使用时间调整的通知公告。',
    ));
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('动态口令'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
