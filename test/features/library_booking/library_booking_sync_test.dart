import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/chaoxing_booking_client.dart';
import 'package:shuyo/data/services/library_booking_cache.dart';
import 'package:shuyo/data/services/there_booking_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/library_booking/library_booking_list_tile.dart';
import 'package:shuyo/features/library_booking/library_booking_names.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';

import 'support/booking_page_test_support.dart';

class _UnreachableBookingClient extends FakeThereBookingClient {
  @override
  Future<void> selectVenue(BookingVenue venue) async =>
      throw const ThereBookingException(
        ThereFailureKind.unreachable,
        '暂时无法访问预约系统。请连接校园网、学校VPN，或开启WebVPN后重试。',
      );
}

class _GatedVenueSelectionClient extends FakeThereBookingClient {
  final gate = Completer<void>();
  final selectionCalls = <BookingVenue, int>{};

  @override
  Future<void> selectVenue(BookingVenue venue) async {
    selectionCalls.update(venue, (count) => count + 1, ifAbsent: () => 1);
    await gate.future;
    await super.selectVenue(venue);
  }
}

class _EmptyThereAreaClient extends FakeThereBookingClient {
  @override
  Future<List<Map<String, dynamic>>> areas(String day) async => [];
}

class _EmptyOnceThereAreaClient extends VenueScopedBookingClient {
  _EmptyOnceThereAreaClient(super.expectedVenue);

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    if (areaListCalls == 0) {
      areaListCalls++;
      return [];
    }
    return super.areas(day);
  }
}

class _GatewayRecoveryClient extends FakeThereBookingClient {
  bool gatewayLoginRequired = true;
  int selectionAttempts = 0;

  @override
  Future<void> selectVenue(BookingVenue venue) async {
    selectionAttempts++;
    if (gatewayLoginRequired) {
      throw const ThereBookingException(
        ThereFailureKind.webVpnLoginRequired,
        'WebVPN登录已失效',
      );
    }
    await super.selectVenue(venue);
  }
}

class _UnavailableChaoxingBookingClient extends EmptyChaoxingBookingClient {
  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    throw const ChaoxingBookingException(
        ChaoxingFailureKind.unreachable, '图书馆座位系统暂时无法访问');
  }
}

class _GatedBookingClient extends FakeThereBookingClient {
  final gate = Completer<void>();
  bool recentStarted = false;

  @override
  Future<List<Map<String, dynamic>>> recent() async {
    recentStarted = true;
    await gate.future;
    final day = bookingDay();
    return [
      {
        'id': 'LIB-LATE',
        'roomType': BookingVenue.library.roomType,
        'roomName': 'LIB-LATE',
        'beginTime': '$day 16:00:00',
        'endTime': '$day 17:00:00',
      },
    ];
  }
}

class _GatedChaoxingBookingClient extends EmptyChaoxingBookingClient {
  final gate = Completer<void>();
  bool homeStarted = false;

  @override
  Future<Map<String, dynamic>> home() async {
    homeStarted = true;
    await gate.future;
    return {
      'curReserves': [
        {
          'id': '1',
          'secondLevelName': '钱伟长图书馆',
          'thirdLevelName': '阅览室',
          'seatNum': 'CX-EARLY',
          'status': '0',
          'startTime': bookingTimestamp(9),
          'endTime': bookingTimestamp(10),
        },
      ],
      'nearReserves': <Map<String, dynamic>>[],
    };
  }
}

class _RecordingBookingCache extends LibraryBookingCache {
  final writtenRoomTypes = <String>[];

  @override
  Future<void> mergeVenue(String studentId, String roomType,
      List<Map<String, dynamic>> recent) async {
    await super.mergeVenue(studentId, roomType, recent);
    writtenRoomTypes.add(roomType);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('new library venue bypasses WebVPN when it is enabled',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    final there = _GatewayRecoveryClient();
    final library = FakeLibraryRoomsClient();
    var webVpnRecoveries = 0;
    addTearDown(there.dispose);
    addTearDown(library.dispose);

    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        useWebVpn: true,
        schoolClock: bookingSchoolTime,
        onWebVpnSessionRequired: () async {
          webVpnRecoveries++;
          there.gatewayLoginRequired = false;
          return true;
        },
      ),
    ));
    await pumpBookingPage(tester);

    expect(find.text('图书馆预约'), findsOneWidget);
    final previousThereAttempts = there.selectionAttempts;
    final previousLibraryRoomCalls = library.roomsCalls;
    await tester.scrollUntilVisible(
      find.widgetWithText(
          ListTile, LibraryBookingNames.venue(BookingVenue.qianweichang)),
      180,
      scrollable: find
          .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(
        find.text(LibraryBookingNames.venue(BookingVenue.qianweichang)).last);
    await pumpBookingPage(tester);
    await tester.tap(
        find.text(LibraryBookingNames.venue(BookingVenue.qianweichang)).last);
    await pumpBookingPage(tester);

    expect(find.text('四楼阅览室'), findsOneWidget);
    expect(library.roomsCalls, previousLibraryRoomCalls);
    expect(there.selectionAttempts, previousThereAttempts);
    expect(there.areaListCalls, 0);
    expect(webVpnRecoveries, 0);
  });

  group('shared booking snapshots', () {
    late Map<BookingVenue, CampusLoadingClient> clients;
    late EmptyChaoxingBookingClient library;
    late DateTime now;

    setUp(() {
      now = bookingSchoolTime();
      clients = {
        for (final venue
            in BookingVenue.values.where((venue) => !venue.isChaoxing))
          venue: CampusLoadingClient(venue),
      };
      library = EmptyChaoxingBookingClient();
    });

    tearDown(() {
      for (final client in clients.values) {
        final gate = client.recentGate;
        if (gate != null && !gate.isCompleted) gate.complete();
        client.dispose();
      }
      library.dispose();
    });

    Map<String, dynamic> record(String name) => {
          'id': 'SNAPSHOT',
          'roomType': BookingVenue.studySpace.roomType,
          'roomName': name,
          'beginTime': '${bookingDay()} 10:00:00',
          'endTime': '${bookingDay()} 11:00:00',
          'status': 'OPEN',
        };

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
          accountService: UnifiedAccountService(),
          thereClientFactory: (venue) => clients[venue]!,
          chaoxingClient: library,
          schoolClock: () => now,
        ),
      ));
      await pumpBookingPage(tester);
    }

    Future<void> history(WidgetTester tester) async {
      await tester.ensureVisible(find.text('查看历史预约'));
      await tester.pump();
      await tester.tap(find.text('查看历史预约'));
      await pumpBookingPage(tester);
    }

    Future<void> home(WidgetTester tester) async {
      await tester.tap(find.byTooltip('返回上一步'));
      await pumpBookingPage(tester);
    }

    void expectReads(int count) {
      for (final client in clients.values) {
        expect(client.recentCalls, count);
      }
    }

    testWidgets('home shows only the latest active booking across venues',
        (tester) async {
      final day = bookingDay();
      clients[BookingVenue.library]!.records = [
        {
          ...record('CANCELLED_SEAT'),
          'id': 'CANCELLED',
          'roomType': BookingVenue.library.roomType,
          'beginTime': '$day 12:00:00',
          'endTime': '$day 13:00:00',
          'status': 'CANCEL',
        },
        {
          ...record('FINISHED_SEAT'),
          'id': 'FINISHED',
          'roomType': BookingVenue.library.roomType,
          'beginTime': '$day 06:00:00',
          'endTime': '$day 07:00:00',
        },
      ];
      clients[BookingVenue.studySpace]!.records = [
        {
          ...record('ONGOING_SEAT'),
          'id': 'ONGOING',
          'beginTime': '$day 07:00:00',
          'endTime': '$day 10:00:00',
          'checkInAt': '$day 07:00:00',
        },
        {...record('LATEST_SEAT'), 'id': 'LATEST'},
      ];
      await open(tester);
      final summary = find.byKey(const ValueKey('home-bookings-viewport'));
      expect(
          find.descendant(
              of: summary, matching: find.byType(LibraryBookingListTile)),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('home:LATEST')), findsOneWidget);
      for (final id in ['ONGOING', 'CANCELLED', 'FINISHED']) {
        expect(find.byKey(ValueKey<String>('home:$id')), findsNothing);
      }
      await history(tester);
      for (final id in ['CANCELLED', 'LATEST', 'ONGOING', 'FINISHED']) {
        final tile = find.byKey(ValueKey<String>('0:$id'));
        await tester.scrollUntilVisible(tile, 120,
            scrollable: find.byType(Scrollable).first);
        expect(tile.hitTestable(), findsOneWidget);
      }
    });

    testWidgets('partial refresh warnings and the home booking grow together',
        (tester) async {
      clients[BookingVenue.studySpace]!.records = [record('B-034')];
      clients[BookingVenue.yanchang]!.failRecent = true;
      await open(tester);
      final summary = find.byKey(const ValueKey('home-bookings-viewport'));
      final warning = find.text('部分预约状态暂时无法更新');
      final tile = find.byKey(const ValueKey<String>('home:SNAPSHOT'));
      expect(warning, findsOneWidget);
      expect(tile.hitTestable(), findsOneWidget);
      final bounds = tester.getRect(summary);
      final minHeight =
          tester.widget<ConstrainedBox>(summary).constraints.minHeight;
      expect(bounds.height, greaterThan(minHeight));
      expect(tester.getRect(warning).bottom,
          lessThanOrEqualTo(tester.getRect(tile).top));
      expect(tester.getRect(tile).bottom, lessThanOrEqualTo(bounds.bottom));
      expect(find.descendant(of: summary, matching: find.byType(Scrollable)),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'fresh snapshots survive repeated history round trips without reads',
        (tester) async {
      clients[BookingVenue.studySpace]!.records = [record('CACHED_SEAT')];
      await open(tester);
      final homeCalls = library.homeCalls;
      final roomCalls = library.roomsCalls;
      for (var trip = 0; trip < 2; trip++) {
        await history(tester);
        expect(
            find.byKey(const ValueKey<String>('0:SNAPSHOT')), findsOneWidget);
        await home(tester);
        expect(find.byKey(const ValueKey<String>('home:SNAPSHOT')),
            findsOneWidget);
      }
      expectReads(1);
      expect(library.homeCalls, homeCalls);
      expect(library.roomsCalls, roomCalls);
      expect(clients[BookingVenue.library]!.areaListCalls, 1);
      expect(clients[BookingVenue.studySpace]!.areaListCalls, 1);
      expect(clients[BookingVenue.yanchang]!.areaListCalls, 0);
    });

    testWidgets(
        'expiry refreshes bookings and current campus areas independently',
        (tester) async {
      await open(tester);
      now = now.add(const Duration(seconds: 59));
      await history(tester);
      expectReads(1);
      now = now.add(const Duration(seconds: 1));
      await home(tester);
      expectReads(2);
      expect(clients[BookingVenue.library]!.areaListCalls, 2);
      now = now.add(const Duration(seconds: 60));
      await history(tester);
      expectReads(3);
      expect(clients[BookingVenue.library]!.areaListCalls, 2);
      await home(tester);
      expectReads(3);
      expect(clients[BookingVenue.library]!.areaListCalls, 3);
      expect(clients[BookingVenue.yanchang]!.areaListCalls, 0);
      expect(clients[BookingVenue.scienceArt]!.areaListCalls, 0);
    });

    testWidgets(
        'pending reads survive navigation and become fresh on completion',
        (tester) async {
      final gate = Completer<void>();
      for (final client in clients.values) {
        client.recentGate = gate;
      }
      clients[BookingVenue.studySpace]!.records = [record('LATE_SEAT')];
      await open(tester);
      await history(tester);
      await home(tester);
      now = now.add(const Duration(seconds: 90));
      await history(tester);
      expectReads(1);
      gate.complete();
      await pumpBookingPage(tester);
      expect(find.textContaining('LATE_SEAT'), findsOneWidget);
      await home(tester);
      expectReads(1);
      now = now.add(const Duration(seconds: 59));
      await history(tester);
      expectReads(1);
      now = now.add(const Duration(seconds: 1));
      await home(tester);
      expectReads(2);
    });

    testWidgets(
        'pull refresh forces reads and keeps visible records while waiting',
        (tester) async {
      final target = clients[BookingVenue.studySpace]!;
      target.records = [record('OLD_SEAT')];
      await open(tester);
      final gate = Completer<void>();
      target.recentGate = gate;
      target.records = [record('NEW_SEAT')];
      await tester.dragFrom(
          tester.getTopLeft(
                  find.byKey(const ValueKey('booking-home-refresh'))) +
              const Offset(40, 20),
          const Offset(0, 450));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expectReads(2);
      expect(find.textContaining('OLD_SEAT'), findsOneWidget);
      expect(find.textContaining('NEW_SEAT'), findsNothing);
      await history(tester);
      expectReads(2);
      gate.complete();
      await pumpBookingPage(tester);
      expect(find.textContaining('NEW_SEAT'), findsOneWidget);
      await tester.dragFrom(
          tester.getTopLeft(
                  find.byKey(const ValueKey('booking-history-refresh'))) +
              const Offset(40, 20),
          const Offset(0, 450));
      await pumpBookingPage(tester);
      expectReads(3);
      expect(clients[BookingVenue.library]!.areaListCalls, 2);
      expect(library.roomsCalls, 2);
    });

    testWidgets(
        'failed refresh preserves data and only failed venues are retried',
        (tester) async {
      final target = clients[BookingVenue.studySpace]!;
      target.records = [record('SAVED_SEAT')];
      await open(tester);
      target.failRecent = true;
      await tester
          .widget<RefreshIndicator>(
              find.byKey(const ValueKey('booking-home-refresh')))
          .onRefresh();
      await pumpBookingPage(tester);
      expect(find.textContaining('SAVED_SEAT'), findsOneWidget);
      expectReads(2);
      await history(tester);
      expect(target.recentCalls, 3);
      expect(find.textContaining('SAVED_SEAT'), findsOneWidget);
      target.failRecent = false;
      await home(tester);
      expect(target.recentCalls, 4);
      await history(tester);
      expect(target.recentCalls, 4);
      for (final entry in clients.entries) {
        if (entry.key != BookingVenue.studySpace) {
          expect(entry.value.recentCalls, 2);
        }
      }
    });
  });

  testWidgets(
      'campus switches reuse pending areas and refresh only the active campus',
      (tester) async {
    final gate = Completer<void>();
    final clients = <BookingVenue, CampusLoadingClient>{};
    final library = EmptyChaoxingBookingClient();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
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
            () => CampusLoadingClient(venue,
                areaGate: venue == BookingVenue.yanchang ||
                        venue == BookingVenue.scienceArt
                    ? gate
                    : null)),
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    await tester.ensureVisible(find.text('延长校区'));
    await tester.tap(find.text('延长校区'));
    await tester.pump(const Duration(milliseconds: 20));
    for (final venue in [BookingVenue.yanchang, BookingVenue.scienceArt]) {
      expect(clients[venue]?.areaLoadsStarted, 1);
      expect(clients[venue]?.areaListCalls, 0);
    }
    await tester.tap(find.text('宝山校区'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('延长校区'));
    await tester.pump(const Duration(milliseconds: 20));
    for (final venue in [BookingVenue.yanchang, BookingVenue.scienceArt]) {
      expect(clients[venue]?.areaLoadsStarted, 1);
    }
    gate.complete();
    await pumpBookingPage(tester);
    await tester.ensureVisible(find.text('查看历史预约'));
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.byTooltip('返回上一步'));
    await pumpBookingPage(tester);
    for (final venue in [BookingVenue.library, BookingVenue.studySpace]) {
      expect(clients[venue]?.areaListCalls, 1);
    }
    for (final venue in [BookingVenue.yanchang, BookingVenue.scienceArt]) {
      expect(clients[venue]?.areaListCalls, 1);
    }
    final controller =
        DefaultTabController.of(tester.element(find.byType(TabBar)));
    expect(controller.index, 1);
    await tester.ensureVisible(find.text('宝山校区'));
    await tester.tap(find.text('宝山校区'));
    await pumpBookingPage(tester);
    for (final venue in [BookingVenue.library, BookingVenue.studySpace]) {
      expect(clients[venue]?.areaListCalls, 1);
    }
  });

  testWidgets('area and booking preloads share each venue entry request',
      (tester) async {
    final client = _GatedVenueSelectionClient();
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
      ),
    ));
    await tester.pump(const Duration(milliseconds: 20));
    for (final venue in BookingVenue.values.where((item) => !item.isChaoxing)) {
      expect(client.selectionCalls[venue], 1);
    }
    client.gate.complete();
    await pumpBookingPage(tester);
    expect(client.areaListCalls, 2);
  });

  testWidgets('parallel There areas retain their own venue sessions',
      (tester) async {
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
        thereClientFactory: (venue) =>
            clients.putIfAbsent(venue, () => VenueScopedBookingClient(venue)),
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    for (final venue in BookingVenue.values.where((item) => !item.isChaoxing)) {
      expect(
          clients[venue]?.areaListCalls,
          venue == BookingVenue.library || venue == BookingVenue.studySpace
              ? 1
              : 0);
      expect(clients[venue]?.selectedVenues.toSet(), {venue});
    }
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.text('校本部图书馆分区'), findsOneWidget);
    await tester.tap(find.text('延长校区'));
    await pumpBookingPage(tester);
    for (final venue in [BookingVenue.yanchang, BookingVenue.scienceArt]) {
      expect(clients[venue]?.areaListCalls, 1);
    }
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.scienceArt)));
    await pumpBookingPage(tester);
    expect(find.text('科学与艺术中心分区'), findsOneWidget);
  });

  testWidgets('empty There response offers retry instead of claiming no areas',
      (tester) async {
    final client = _EmptyThereAreaClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-venue-library')),
            matching: find.textContaining('分区')),
        findsNothing);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.text('分区暂时无法加载，重试'), findsOneWidget);
    expect(find.text('当前场馆没有可选分区'), findsNothing);
  });

  testWidgets('opening a venue retries after an empty response',
      (tester) async {
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
          () => venue == BookingVenue.library
              ? _EmptyOnceThereAreaClient(venue)
              : VenueScopedBookingClient(venue),
        ),
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-venue-library')),
            matching: find.textContaining('分区')),
        findsNothing);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.text('校本部图书馆分区'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('home-venue-library')),
            matching: find.text('1分区')),
        findsOneWidget);
    expect(clients[BookingVenue.library]?.refreshedVenues,
        contains(BookingVenue.library));
  });

  testWidgets('unreachable campus service offers an inline retry',
      (tester) async {
    final client = _UnreachableBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.text('分区暂时无法加载，重试'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
  });

  testWidgets('proxy page restores gateway before reading bookings',
      (tester) async {
    final client = _GatewayRecoveryClient();
    addTearDown(client.dispose);
    var recoveries = 0;
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: bookingSchoolTime,
        useWebVpn: true,
        onWebVpnSessionRequired: () async {
          recoveries++;
          client.gatewayLoginRequired = false;
          return true;
        },
      ),
    ));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(recoveries, 1);
    expect(find.text('2楼东侧'), findsOneWidget);
    expect(find.text('选择分区'), findsNothing);
  });

  testWidgets('available bookings remain visible when one service fails',
      (tester) async {
    final client = HistoryClient();
    final library = _UnavailableChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey<String>('0:UPCOMING')), findsOneWidget);
    expect(find.textContaining('B-034'), findsOneWidget);
    final notice = tester.widget<SnackBar>(find.byType(SnackBar));
    expect((notice.content as Text).data, '部分预约加载失败，请下拉重试');
    expect(notice.behavior, SnackBarBehavior.fixed);
    expect(find.text('暂无可显示的预约记录'), findsNothing);
    expect(library.homeCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('shows locally saved booking history when services are offline',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    await LibraryBookingCache()
        .mergeVenue('STUDENT_1', BookingVenue.studySpace.roomType, [
      {
        'id': 'LOCAL_HISTORY',
        'roomType': BookingVenue.studySpace.roomType,
        'roomName': 'B-034',
        'beginTime': '2025-01-01 08:30:00',
        'endTime': '2025-01-01 09:30:00',
        'status': 'CANCEL',
        'statusLabel': '已取消',
      },
    ]);
    final there = _UnreachableBookingClient();
    final library = _UnavailableChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);

    final localBooking = find.byKey(const ValueKey<String>('0:LOCAL_HISTORY'));
    expect(localBooking, findsOneWidget);
    expect(find.descendant(of: localBooking, matching: find.text('已取消')),
        findsOneWidget);
    expect(find.textContaining('B-034'), findsOneWidget);
  });

  testWidgets('persists server booking results as local history',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    final there = HistoryClient();
    final library = EmptyChaoxingBookingClient();
    final cache = _RecordingBookingCache();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        bookingCache: cache,
        schoolClock: bookingSchoolTime,
      ),
    ));
    await pumpBookingPage(tester);

    expect(cache.writtenRoomTypes, contains(BookingVenue.studySpace.roomType));
    final saved = await cache.load('STUDENT_1');
    expect(saved.map((item) => item['id']),
        containsAll(['UPCOMING', 'FINISHED_EARLY']));
    expect(
        saved.singleWhere((item) => item['id'] == 'FINISHED_EARLY')['status'],
        'CANCEL');
  });

  testWidgets('all booking failures use the bottom notice', (tester) async {
    final there = _UnreachableBookingClient();
    final library = _UnavailableChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => there,
      chaoxingClient: library,
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('暂无可显示的预约记录'), findsOneWidget);
    final notice = tester.widget<SnackBar>(find.byType(SnackBar));
    expect((notice.content as Text).data, '预约加载失败，请下拉重试');
    expect(notice.behavior, SnackBarBehavior.fixed);
  });

  testWidgets('booking systems load together and results stay time-ordered',
      (tester) async {
    final there = _GatedBookingClient();
    final library = _GatedChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => there,
      chaoxingClient: library,
      schoolClock: bookingSchoolTime,
    )));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(there.recentStarted, isTrue);
    expect(library.homeStarted, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在获取预约记录…'), findsNothing);

    library.gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey<String>('0:cx:CX_QWC:1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('0:LIB-LATE')), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    const earlyKey = ValueKey<String>('0:cx:CX_QWC:1');
    final earlyTileState = tester.state(find.byKey(earlyKey));

    there.gate.complete();
    await pumpBookingPage(tester);
    const lateKey = ValueKey<String>('0:LIB-LATE');
    expect(find.byKey(lateKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(lateKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(earlyKey)).dy));
    expect(tester.state(find.byKey(earlyKey)), same(earlyTileState));

    await tester.tap(find.text('待履约').first);
    await tester.pump();
    const replayKey = ValueKey<String>('1:cx:CX_QWC:1');
    expect(find.byKey(earlyKey), findsNothing);
    expect(tester.state(find.byKey(replayKey)), isNot(same(earlyTileState)));
    final replaySlide = tester.widget<SlideTransition>(find.descendant(
      of: find.byKey(replayKey),
      matching: find.byType(SlideTransition),
    ));
    expect(replaySlide.position.value, isNot(Offset.zero));
    await pumpBookingPage(tester);
  });
}
