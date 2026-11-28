import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/there_booking_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/library_booking/library_booking_names.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/features/library_booking/library_booking_resources.dart';
import 'package:shuyo/shared/navigation/shuyo_route.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

import 'support/booking_page_test_support.dart';

class _GatedAreaListClient extends FakeThereBookingClient {
  final gate = Completer<void>();
  int started = 0;

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    started++;
    await gate.future;
    return super.areas(day);
  }
}

class _ThreeAreaBookingClient extends VenueScopedBookingClient {
  _ThreeAreaBookingClient(super.expectedVenue);

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async => [
        for (final name in ['A', 'B', 'C'])
          {
            'id': 'ZONE_$name',
            'name': '分区$name',
            'supportRoomTypes': [expectedVenue.roomType],
            'totalResourceCount': 12,
            'disabledResourceCount': 2,
            'bookingTimes': {'startHour': 8, 'endHour': 22},
          },
      ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('custom photo travels with each booking step', (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    const background = CustomBackground(
      imagePath: 'assets/images/icon.png',
      opacity: 50,
      background: Color(0xFFF8F8F8),
      surface: Colors.white,
      text: Color(0xFF171717),
      accent: Color(0xFF3478D4),
    );
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: background.theme.themeData(),
      builder: (_, child) => CustomBackgroundFrame(
        settings: background,
        child: child!,
      ),
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    expect(find.byType(ShuYoRouteSurface), findsOneWidget);
    expect(find.text('图书馆预约'), findsOneWidget);

    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ShuYoRouteSurface), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(ShuYoRouteSurface),
        matching: find.byType(CustomBackgroundLayer),
      ),
      findsNWidgets(2),
    );
  });

  for (final entry in {
    '宝山': (
      label: '宝山校区',
      venues: [BookingVenue.library, BookingVenue.studySpace]
    ),
    '宝山东区': (
      label: '宝山校区',
      venues: [BookingVenue.library, BookingVenue.studySpace]
    ),
    '延长': (
      label: '延长校区',
      venues: [BookingVenue.scienceArt, BookingVenue.yanchang]
    ),
    '嘉定': (label: '嘉定校区', venues: <BookingVenue>[]),
    '未知校区': (
      label: '宝山校区',
      venues: [BookingVenue.library, BookingVenue.studySpace]
    ),
  }.entries) {
    testWidgets('${entry.key} opens its campus before requesting venue areas',
        (tester) async {
      final clients = <BookingVenue, CampusLoadingClient>{};
      final library = EmptyChaoxingBookingClient();
      addTearDown(() {
        for (final client in clients.values) {
          client.dispose();
        }
        library.dispose();
      });
      await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
          accountService: UnifiedAccountService(),
          initialCampus: entry.key,
          thereClientFactory: (venue) =>
              clients.putIfAbsent(venue, () => CampusLoadingClient(venue)),
          chaoxingClient: library,
          schoolClock: bookingSchoolTime,
        ),
      ));
      final campusBar = find.byType(TabBar);
      final controller = DefaultTabController.of(tester.element(campusBar));
      final tabs = tester.widget<TabBar>(campusBar).tabs;
      expect((tabs[controller.index] as Tab).text, entry.value.label);
      await pumpBookingPage(tester);
      for (final venue
          in BookingVenue.values.where((venue) => !venue.isChaoxing)) {
        expect(clients[venue]?.areaListCalls,
            entry.value.venues.contains(venue) ? 1 : 0);
        expect(clients[venue]?.recentCalls, 1,
            reason: 'Bookings remain visible across every campus');
      }
      expect(library.roomsCalls, 1);
    });
  }

  testWidgets(
      'selected campus venues load areas concurrently and expand in place',
      (tester) async {
    final client = _GatedAreaListClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(() {
      if (!client.gate.isCompleted) client.gate.complete();
      client.dispose();
      library.dispose();
    });
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: bookingSchoolTime,
    )));
    for (var attempt = 0; attempt < 5 && client.started < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(client.started, 2);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-venue-library')),
            matching: find.textContaining('分区')),
        findsNothing);
    final venue = find.byKey(const ValueKey('home-venue-library'));
    expect(
        find.ancestor(
          of: venue,
          matching: find.byWidgetPredicate((widget) =>
              widget is Material && widget.shape is RoundedRectangleBorder),
        ),
        findsNothing);
    expect(
        find.descendant(
            of: venue, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    await tester.tap(venue);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在加载场馆分区…'), findsNothing);
    expect(find.text('正在更新场馆分区…'), findsNothing);
    expect(
        find.descendant(
            of: venue, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);

    client.gate.complete();
    await pumpBookingPage(tester);
    expect(
        find.descendant(of: venue, matching: find.text('1分区')), findsOneWidget);
    expect(library.roomsCalls, 1);
    expect(
        find.descendant(
            of: venue, matching: find.byIcon(Icons.keyboard_arrow_up)),
        findsOneWidget);
    expect(find.text('2楼东侧'), findsOneWidget);
    expect(find.text('08:00–22:00'), findsOneWidget);
    expect(find.textContaining('开放时间：'), findsNothing);
    expect(tester.getCenter(find.text('2楼东侧')).dy,
        tester.getCenter(find.text('08:00–22:00')).dy);
    final areaTitleRect = tester.getRect(find.text('2楼东侧'));
    final openingHoursRect = tester.getRect(find.text('08:00–22:00'));
    expect(openingHoursRect.left - areaTitleRect.right, closeTo(12, 0.01));
    expect(tester.widget<Text>(find.text('08:00–22:00')).style?.color,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.textTertiary);
    expect(find.textContaining('开放座位数：6/9'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('home-venue-studySpace')), 180,
        scrollable: find.byType(Scrollable).first);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-venue-studySpace')),
            matching: find.byIcon(Icons.keyboard_arrow_down)),
        findsOneWidget);
    await tester.ensureVisible(venue);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(venue);
    await pumpBookingPage(tester);
    expect(
        find.descendant(
            of: venue, matching: find.byIcon(Icons.keyboard_arrow_down)),
        findsOneWidget);
    expect(find.text('2楼东侧'), findsNothing);
  });

  testWidgets('venue subtitle counts its selectable areas', (tester) async {
    final clients = <BookingVenue, VenueScopedBookingClient>{};
    final library = EmptyChaoxingBookingClient();
    addTearDown(() {
      for (final client in clients.values) {
        client.dispose();
      }
      library.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (venue) => clients.putIfAbsent(
          venue,
          () => venue == BookingVenue.studySpace
              ? _ThreeAreaBookingClient(venue)
              : VenueScopedBookingClient(venue),
        ),
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    final venue = find.byKey(const ValueKey('home-venue-studySpace'));
    expect(
        find.descendant(of: venue, matching: find.text('3分区')), findsOneWidget);
    expect(find.text('3 个场馆'), findsNothing);
    await tester.ensureVisible(venue);
    await tester.tap(venue);
    await pumpBookingPage(tester);
    await tester.ensureVisible(find.text('分区C'));
    for (final name in ['A', 'B', 'C']) {
      expect(find.text('分区$name'), findsOneWidget);
    }
  });

  testWidgets('seat preview entry is hidden while venue selection remains',
      (tester) async {
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    expect(find.text('仅查看座位情况'), findsNothing);
    expect(find.text(LibraryBookingNames.venue(BookingVenue.library)),
        findsWidgets);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.text('2楼东侧'), findsOneWidget);
  });

  testWidgets('forward and back steps slide in opposite directions',
      (tester) async {
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await tester.pump(const Duration(milliseconds: 50));
    final enteringArea = tester.getTopLeft(find.byType(Scaffold).last).dx;
    expect(enteringArea, greaterThan(0));
    await pumpBookingPage(tester);
    await tester.tap(find.byTooltip('返回上一步'));
    await tester.pump(const Duration(milliseconds: 50));
    final enteringVenue = tester.getTopLeft(find.byType(Scaffold).last).dx;
    expect(enteringVenue, lessThan(0));
    await pumpBookingPage(tester);
    expect(find.text('选择场馆'), findsOneWidget);
  });

  testWidgets('rules and 24H help open local content and zoomable map',
      (tester) async {
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    final rulesText = tester.widget<Text>(find.text('使用规则'));
    expect(rulesText.style?.fontSize, 14.5);
    expect(rulesText.style?.fontWeight, FontWeight.w400);
    expect(find.ancestor(of: find.text('使用规则'), matching: find.byType(InkWell)),
        findsNothing);
    await tester.tap(find.text('使用规则'));
    await pumpBookingPage(tester);
    expect(find.byType(LibraryBookingInfoPage), findsOneWidget);
    expect(find.text('注意事项'), findsOneWidget);
    expect(find.textContaining('刷卡或人脸识别'), findsOneWidget);
    final paragraph = tester.widget<SelectableText>(find
        .ancestor(
          of: find.textContaining('刷卡或人脸识别'),
          matching: find.byType(SelectableText),
        )
        .first);
    expect(paragraph.style?.fontSize, 15.5);
    expect(paragraph.textSpan!.toPlainText(), contains('若未按时签到将被记录为违约行为'));
    await tester.pageBack();
    await pumpBookingPage(tester);

    await tester.ensureVisible(
        find.text(LibraryBookingNames.venue(BookingVenue.studySpace)));
    await tester.pump(const Duration(milliseconds: 20));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.studySpace)));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('常见问题'), 180,
        scrollable: find.byType(Scrollable).first);
    await pumpBookingPage(tester);
    expect(find.text('座位分布'), findsOneWidget);
    expect(find.text('常见问题'), findsOneWidget);
    expect(
        tester.getTopLeft(find.text('座位分布')).dy,
        greaterThan(tester
            .getTopLeft(
                find.text(LibraryBookingNames.venue(BookingVenue.studySpace)))
            .dy));
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    expect(tester.widget<Text>(find.text('座位分布')).style?.fontSize,
        rulesText.style?.fontSize);
    expect(tester.widget<Text>(find.text('常见问题')).style?.fontSize,
        rulesText.style?.fontSize);
    expect(
        find.ancestor(
          of: find.text('座位分布'),
          matching: find.byType(InkWell),
        ),
        findsNothing);
    await tester.tap(find.text('座位分布'));
    await pumpBookingPage(tester);
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.maxScale, greaterThan(1));
    final image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as AssetImage).assetName, librarySeatsAsset);
    await tester.tap(find.byTooltip('关闭图片'));
    await pumpBookingPage(tester);
    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.text('常见问题'));
    await pumpBookingPage(tester);
    expect(find.byType(LibraryBookingInfoPage), findsOneWidget);
    expect(find.text('区域分布（包括饮食、仓库、水房等）'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('无法预约/签到失败等'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    final qaParagraph = tester.widget<SelectableText>(find
        .ancestor(
          of: find.textContaining('无法预约/签到失败等'),
          matching: find.byType(SelectableText),
        )
        .first);
    expect(qaParagraph.style?.fontSize, 15.5);
    expect(qaParagraph.textSpan!.toPlainText(), contains('脸部识别/个人信息等：'));
    await tester.pageBack();
    await pumpBookingPage(tester);

    await tester.tap(find.text('二楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    expect(find.text('座位分布'), findsOneWidget);
    await tester.tap(find.text('座位分布'));
    await pumpBookingPage(tester);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('关闭图片'));
    await pumpBookingPage(tester);
  });

  testWidgets('24H help stays on title rows at narrow width', (tester) async {
    tester.view.physicalSize = const Size(260, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.studySpace)));
    await pumpBookingPage(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('座位分布'), findsOneWidget);
    expect(find.text('常见问题'), findsOneWidget);
    await tester.tap(find.text('二楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('座位分布'), findsOneWidget);
  });

  testWidgets('area availability is a colored fraction on narrow screens',
      (tester) async {
    tester.view.physicalSize = const Size(260, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: bookingSchoolTime,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    final stats = find.text('开放座位数：6/9');
    expect(stats, findsOneWidget);
    final spans = tester.widget<Text>(stats).textSpan as TextSpan;
    final available = spans.children![1] as TextSpan;
    expect(available.text, '6');
    expect(available.style?.color, isNotNull);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(tester.takeException(), isNull);
  });
}
