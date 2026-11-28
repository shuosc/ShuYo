import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/library_booking_cache.dart';
import 'package:shuyo/data/services/there_booking_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/library_booking/library_booking_list_tile.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

import 'support/booking_page_test_support.dart';

class _GatedHomeBookingsClient extends FakeThereBookingClient {
  final records = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> recent() => records.future;
}

class _CloseOnlyClient extends HistoryClient {
  @override
  Future<List<Map<String, dynamic>>> recent() async {
    final upcoming = (await super.recent()).first;
    return [
      {...upcoming, 'id': 'CLOSE_ONLY', 'roomName': 'C-007'},
    ];
  }

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async {
    final item = await super.detail(bookingId);
    return {
      ...item,
      'abilities': ['close']
    };
  }
}

class _GatedDetailHistoryClient extends HistoryClient {
  final detailGate = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> recent() async =>
      (await super.recent()).reversed.toList();

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async {
    await detailGate.future;
    return super.detail(bookingId);
  }
}

class _RecentCancelableDetailFailureClient extends HistoryClient {
  @override
  Future<List<Map<String, dynamic>>> recent() async => [
        for (final item in await super.recent())
          if (item['id'] == 'UPCOMING')
            {
              ...item,
              'abilities': ['cancel']
            }
          else
            item,
      ];

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async =>
      throw const ThereBookingException(
        ThereFailureKind.unreachable,
        '预约详情暂时不可用',
      );
}

class _BookedChaoxingBookingClient extends EmptyChaoxingBookingClient {
  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    return {
      'curReserves': [
        for (final (index, hall) in [
          '钱伟长图书馆',
          '嘉定联合馆',
          '延长文荟馆',
        ].indexed)
          {
            'id': '${index + 1}',
            'secondLevelName': hall,
            'thirdLevelName': '阅览室',
            'seatNum': 'CX-${index + 1}',
            'status': '0',
          },
      ],
      'nearReserves': <Map<String, dynamic>>[],
    };
  }
}

class _InUseChaoxingBookingClient extends EmptyChaoxingBookingClient {
  String? signedBackId;

  @override
  Future<void> signback(String reserveId) async => signedBackId = reserveId;

  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    int schoolTime(int hour) => DateTime.utc(day.year, day.month, day.day, hour)
        .subtract(const Duration(hours: 8))
        .millisecondsSinceEpoch;
    Map<String, dynamic> reserve(int id, int status) => {
          'id': id,
          'secondLevelName': '钱伟长图书馆',
          'thirdLevelName': '阅览室',
          'seatNum': '00$id',
          'startTime': schoolTime(6),
          'endTime': schoolTime(7),
          'status': status,
        };
    return {
      'curReserves': [
        reserve(1, 0),
        if (signedBackId != '2') reserve(2, 1),
        reserve(3, 3),
      ],
      'nearReserves': [
        if (signedBackId == '2') reserve(2, 2),
        reserve(4, 7),
      ],
    };
  }
}

class _SignableChaoxingBookingClient extends EmptyChaoxingBookingClient {
  String? signedId;

  @override
  Future<void> sign(String reserveId) async => signedId = reserveId;

  @override
  Future<void> signWithSeatPage({
    required String reserveId,
    required String roomId,
    required String seatNum,
    String? deptId,
  }) async =>
      sign(reserveId);

  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    final start = DateTime.utc(day.year, day.month, day.day, 10)
        .subtract(const Duration(hours: 8))
        .millisecondsSinceEpoch;
    return {
      'seatConfig': {'preSignDuration': 20, 'signDuration': 20},
      'curReserves': [
        {
          'id': 123,
          'secondLevelName': '钱伟长图书馆',
          'thirdLevelName': '阅览室',
          'seatNum': '001',
          'roomId': 6508,
          'startTime': start,
          'endTime': start + const Duration(hours: 1).inMilliseconds,
          'status': signedId == null ? 0 : 1,
        },
      ],
      'nearReserves': <Map<String, dynamic>>[],
    };
  }
}

class _CachedActionClient extends FakeThereBookingClient {
  _CachedActionClient(this.ability, this.day);

  final String ability;
  final String day;
  final recentGate = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> recent() async {
    await recentGate.future;
    return [];
  }

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async {
    bookingDetailCalls++;
    return {
      'id': bookingId,
      'roomName': 'C-007',
      'beginTime': '$day 08:30:00',
      'endTime': '$day 10:30:00',
      'status': 'OPEN',
      'abilities': [ability],
    };
  }
}

class _HomeWriteClient extends FakeThereBookingClient {
  _HomeWriteClient(this.venue, this.day, this.action);

  @override
  final BookingVenue venue;
  final String day;
  final String action;
  int recentCalls = 0;
  bool written = false;

  Map<String, dynamic> get record => {
        'id': venue == BookingVenue.studySpace ? 'HOME_ACTION' : 'HOME_STABLE',
        'roomType': venue.roomType,
        'roomName': venue == BookingVenue.studySpace ? 'C-007' : '2E015',
        'beginTime':
            '$day ${venue == BookingVenue.studySpace ? '09:00' : '08:30'}:00',
        'endTime':
            written && action == 'close' ? '$day 09:00:00' : '$day 10:30:00',
        'status': written ? 'CANCEL' : 'OPEN',
        'statusLabel': written ? '已取消' : '正常',
        if (written && action == 'close') ...{
          'origEndAt': '$day 10:30:00',
          'duration': 0,
        },
      };

  @override
  Future<List<Map<String, dynamic>>> recent() async {
    recentCalls++;
    return venue == BookingVenue.studySpace || venue == BookingVenue.library
        ? [record]
        : [];
  }

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async => {
        ...record,
        'abilities': written ? <String>[] : [action],
      };

  @override
  Future<void> cancel(String bookingId) async => written = true;

  @override
  Future<void> finish(String bookingId) async => written = true;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scenario in [
    (name: 'empty', count: 0, fail: false, scale: 1.0, longTitle: false),
    (name: 'one', count: 1, fail: false, scale: 1.0, longTitle: false),
    (name: 'many', count: 4, fail: false, scale: 1.0, longTitle: false),
    (name: 'failed', count: 0, fail: true, scale: 1.0, longTitle: false),
    (name: 'large text', count: 4, fail: false, scale: 1.5, longTitle: false),
    (name: 'long title', count: 1, fail: false, scale: 1.0, longTitle: true),
    (
      name: 'large text with long title',
      count: 1,
      fail: false,
      scale: 2.0,
      longTitle: true
    ),
  ]) {
    testWidgets('${scenario.name} bookings show a non-scrolling home summary',
        (tester) async {
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _GatedHomeBookingsClient();
      final library = EmptyChaoxingBookingClient();
      addTearDown(() {
        if (!client.records.isCompleted) client.records.complete([]);
        client.dispose();
        library.dispose();
      });
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scenario.scale)),
          child: child!,
        ),
        home: LibraryBookingPage(
          accountService: UnifiedAccountService(),
          thereClientFactory: (_) => client,
          chaoxingClient: library,
          schoolClock: schoolMorning,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 20));
      final viewport = find.byKey(const ValueKey('home-bookings-viewport'));
      final beforeViewport = tester.getRect(viewport);
      final beforeVenue = tester.getTopLeft(find.text('选择场馆'));
      expect(find.text('加载中'), findsOneWidget);
      if (scenario.fail) {
        client.records.completeError(const ThereBookingException(
            ThereFailureKind.unreachable, '预约暂时无法加载'));
      } else {
        final day = ThereBookingClient.schoolDay();
        client.records.complete([
          for (var index = 0; index < scenario.count; index++)
            {
              'id': 'LAYOUT_$index',
              'roomType': BookingVenue.library.roomType,
              'roomName': scenario.longTitle
                  ? '这是用于验证预约卡片自动增高的较长座位名称$index'
                  : '2E00$index',
              'officeAreaName': '二楼东侧',
              'beginTime':
                  '$day ${(9 + index).toString().padLeft(2, '0')}:00:00',
              'endTime': '$day 13:00:00',
              'status': 'OPEN',
            },
        ]);
      }
      await pumpBookingPage(tester);
      final afterViewport = tester.getRect(viewport);
      expect(afterViewport.topLeft, beforeViewport.topLeft);
      expect(afterViewport.height, greaterThanOrEqualTo(beforeViewport.height));
      expect(
          tester.getTopLeft(find.text('选择场馆')).dy,
          closeTo(beforeVenue.dy + afterViewport.height - beforeViewport.height,
              0.01));
      if (scenario.longTitle) {
        expect(afterViewport.height, greaterThan(beforeViewport.height));
      } else if (scenario.count == 0) {
        expect(afterViewport, beforeViewport);
      }
      expect(find.descendant(of: viewport, matching: find.byType(Scrollable)),
          findsNothing);
      final tiles = find.descendant(
          of: viewport, matching: find.byType(LibraryBookingListTile));
      expect(tiles, scenario.count == 0 ? findsNothing : findsOneWidget);
      if (scenario.count > 0) {
        final latest =
            find.byKey(ValueKey<String>('home:LAYOUT_${scenario.count - 1}'));
        expect(latest.hitTestable(), findsOneWidget);
        expect(tester.getRect(latest).bottom,
            lessThanOrEqualTo(afterViewport.bottom));
        for (var index = 0; index < scenario.count - 1; index++) {
          expect(
              find.byKey(ValueKey<String>('home:LAYOUT_$index')), findsNothing);
        }
        if (scenario.count > 1) {
          await tester.tap(latest);
          await pumpBookingPage(tester);
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.text('there:LAYOUT_${scenario.count - 1}'), findsNothing);
          await tester.tapAt(const Offset(20, 20));
          await pumpBookingPage(tester);
          await tester.ensureVisible(find.text('查看历史预约'));
          await tester.tap(find.text('查看历史预约'));
          await pumpBookingPage(tester);
          for (var index = scenario.count - 1; index >= 0; index--) {
            final record = find.byKey(ValueKey<String>('0:LAYOUT_$index'));
            await tester.scrollUntilVisible(record, 120,
                scrollable: find.byType(Scrollable).first);
            expect(record.hitTestable(), findsOneWidget);
          }
        }
      } else {
        expect(
            find.text(
                scenario.fail ? '预约列表暂时无法完整加载，请检查是否连接校园网' : '暂无待履约或进行中的预约'),
            findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('my bookings directly loads every venue and returns in one step',
      (tester) async {
    final client = FakeThereBookingClient();
    final library = _BookedChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    SharedPreferences.setMockInitialValues({
      'library_booking_selected_venues': [BookingVenue.studySpace.roomType],
    });
    Widget page() => MaterialApp(
            home: LibraryBookingPage(
          accountService: UnifiedAccountService(),
          thereClientFactory: (_) => client,
          chaoxingClient: library,
          schoolClock: schoolMorning,
        ));
    await tester.pumpWidget(page());
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.text('选择要查看预约的场馆'), findsNothing);
    for (final (index, venue) in [
      BookingVenue.qianweichang,
      BookingVenue.jiading,
      BookingVenue.wenhui,
    ].indexed) {
      expect(
          find.byKey(ValueKey<String>('0:cx:${venue.roomType}:${index + 1}')),
          findsOneWidget);
    }
    for (final name in [
      '宝山校区 钱伟长图书馆',
      '嘉定校区 联合图书馆',
      '延长校区 文荟图书馆',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.textContaining('CX-1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('0:cx:CX_QWC:1')));
    await pumpBookingPage(tester);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('宝山校区 钱伟长图书馆'),
      ),
      findsOneWidget,
    );
    expect(find.text('预约编号'), findsNothing);
    expect(find.text('cx:1'), findsNothing);
    expect(find.textContaining('cx:CX_QWC:'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await pumpBookingPage(tester);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(3));
    expect(find.byType(TabBar), findsOneWidget);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);
    expect(
        find.ancestor(of: find.byType(TabBar), matching: find.byType(ListView)),
        findsNothing);
    expect(client.selectedVenues.toSet(),
        BookingVenue.values.where((venue) => !venue.isChaoxing).toSet());
    expect(library.homeCalls, greaterThan(0));
    await tester.tap(find.byTooltip('返回上一步'));
    await pumpBookingPage(tester);
    expect(find.text('图书馆预约'), findsOneWidget);
  });

  testWidgets(
      'Chaoxing sign appears beside cancel in its configured window and refreshes status',
      (tester) async {
    final there = FakeThereBookingClient();
    final library = _SignableChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    var now = DateTime.utc(day.year, day.month, day.day, 9, 39);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        schoolClock: () => now,
      ),
    ));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    const bookingKey = ValueKey<String>('0:cx:CX_QWC:123');
    await tester.tap(find.byKey(bookingKey));
    await pumpBookingPage(tester);
    expect(find.text('取消预约'), findsOneWidget);
    expect(find.text('签到'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await pumpBookingPage(tester);

    now = DateTime.utc(day.year, day.month, day.day, 9, 40);
    await tester.tap(find.byKey(bookingKey));
    await pumpBookingPage(tester);
    expect(find.text('取消预约'), findsOneWidget);
    expect(find.text('签到'), findsOneWidget);
    expect(tester.getTopLeft(find.text('取消预约')).dy,
        tester.getTopLeft(find.text('签到')).dy);
    await tester.tap(find.text('签到'));
    await pumpBookingPage(tester);
    expect(library.signedId, '123');
    expect(find.byKey(bookingKey), findsOneWidget);
    await tester.tap(find.byKey(bookingKey));
    await pumpBookingPage(tester);
    expect(find.text('退座'), findsOneWidget);
    expect(find.text('签到'), findsNothing);
  });

  testWidgets('current Chaoxing bookings stay active after their end time',
      (tester) async {
    final there = FakeThereBookingClient();
    final library = _InUseChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        schoolClock: schoolMorning,
      ),
    ));
    await pumpBookingPage(tester);
    final homeTile = find.descendant(
        of: find.byKey(const ValueKey('home-bookings-viewport')),
        matching: find.byType(LibraryBookingListTile));
    expect(homeTile, findsOneWidget);
    expect(tester.widget<LibraryBookingListTile>(homeTile).status, '进行中');
    expect(
        find.byKey(const ValueKey<String>('home:cx:CX_QWC:4')), findsNothing);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('进行中').first);
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:3')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:4')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('1:cx:CX_QWC:2')));
    await pumpBookingPage(tester);
    expect(find.text('退座'), findsOneWidget);
    await tester.tap(find.text('退座'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认'));
    await pumpBookingPage(tester);
    expect(library.signedBackId, '2');
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:2')), findsNothing);
  });

  testWidgets('Chaoxing early check-in appears in the active filter',
      (tester) async {
    final there = FakeThereBookingClient();
    final library = _InUseChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        schoolClock: () => DateTime.utc(day.year, day.month, day.day, 5),
      ),
    ));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('进行中').first);
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:1')), findsNothing);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('1:cx:CX_QWC:3')), findsOneWidget);
  });

  testWidgets('booking tabs fit a narrow screen without scrolling',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final there = FakeThereBookingClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(there.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => there,
      chaoxingClient: library,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(tester.takeException(), isNull);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);
    expect(find.text('已取消'), findsOneWidget);
  });

  testWidgets('bookings filter future and early-finished records',
      (tester) async {
    final client = HistoryClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey<String>('home:UPCOMING')),
            matching: find.textContaining('B-034')),
        findsOneWidget);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey<String>('0:UPCOMING')), findsOneWidget);
    expect(find.textContaining('B-034'), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('0:FINISHED_EARLY')), findsOneWidget);
    expect(find.textContaining('A-001'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('0:UPCOMING')),
        matching: find.text('待履约'),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    expect(find.byType(FadeTransition), findsWidgets);
    final nextDay = DateTime.parse(ThereBookingClient.schoolDay())
        .add(const Duration(days: 1));
    final day = '${nextDay.year}-${nextDay.month.toString().padLeft(2, '0')}-'
        '${nextDay.day.toString().padLeft(2, '0')}';
    expect(find.textContaining('$day 08:30'), findsNothing);
    expect(find.textContaining('${day.substring(5)} 08:30'), findsOneWidget);
    await tester.tap(find.text('待履约').first);
    await pumpBookingPage(tester);
    const upcomingKey = ValueKey<String>('1:UPCOMING');
    expect(find.byKey(upcomingKey), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('1:FINISHED_EARLY')), findsNothing);
    final detailsBeforeTap = client.bookingDetailCalls;
    await tester.tap(find.byKey(upcomingKey));
    await pumpBookingPage(tester);
    expect(client.bookingDetailCalls, detailsBeforeTap + 1);
    final listedDetailSheet =
        tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(listedDetailSheet.backgroundColor,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.surface);
    expect(listedDetailSheet.clipBehavior, Clip.antiAlias);
    expect(find.text('开始时间'), findsOneWidget);
    expect(find.text('结束时间'), findsOneWidget);
    expect(find.text('预约时间'), findsOneWidget);
    expect(find.text('2026-10-18 20:15'), findsOneWidget);
    expect(find.text('2E015'), findsOneWidget);
    expect(find.text('预约编号'), findsNothing);
    expect(find.text('there:UPCOMING'), findsNothing);
    expect(find.text('座位'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await pumpBookingPage(tester);
    await tester.tap(find.text('已结束'));
    await pumpBookingPage(tester);
    expect(
        find.byKey(const ValueKey<String>('2:FINISHED_EARLY')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('2:UPCOMING')), findsNothing);
    expect(find.text('已结束'), findsNWidgets(2));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('2:FINISHED_EARLY')));
    await pumpBookingPage(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('2025-12-31 21:05'), findsOneWidget);
    expect(find.text('取消预约'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await pumpBookingPage(tester);
    await tester.tap(find.text('全部'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(const ValueKey<String>('3:UPCOMING')));
    await pumpBookingPage(tester);
    await tester.tap(find.text('取消预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认'));
    await pumpBookingPage(tester);
    expect(client.cancelled, isTrue);
    expect(client.cancellationVenue, BookingVenue.studySpace);
  });

  testWidgets('bookings without cancellation can open a detail sheet',
      (tester) async {
    final client = _CloseOnlyClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    final homeTile = find.byKey(const ValueKey<String>('home:CLOSE_ONLY'));
    await tester.scrollUntilVisible(homeTile, 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: homeTile, matching: find.text('待履约')),
        findsOneWidget);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey<String>('0:CLOSE_ONLY')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey<String>('0:CLOSE_ONLY')),
            matching: find.text('待履约')),
        findsOneWidget);
    expect(find.textContaining('C-007'), findsOneWidget);
    expect(client.bookingDetailCalls, 0);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('0:CLOSE_ONLY')));
    await pumpBookingPage(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('取消预约'), findsNothing);
    expect(find.text('退座'), findsOneWidget);
    expect(client.bookingDetailCalls, 1);
  });

  for (final ability in ['close', 'cancel']) {
    testWidgets(
        'shows cached bookings and actions while refreshing $ability data',
        (tester) async {
      final day = ThereBookingClient.schoolDay();
      SharedPreferences.setMockInitialValues({
        AcademicAccountStore.studentIdKey: 'STUDENT_1',
      });
      await LibraryBookingCache()
          .replaceVenue('STUDENT_1', BookingVenue.studySpace.roomType, [
        {
          'id': 'CACHED_ACTION',
          'roomType': BookingVenue.studySpace.roomType,
          'roomName': 'C-007',
          'beginTime': '$day 08:30:00',
          'endTime': '$day 10:30:00',
          'status': 'OPEN',
        },
      ]);
      final client = _CachedActionClient(ability, day);
      final library = EmptyChaoxingBookingClient();
      addTearDown(client.dispose);
      addTearDown(library.dispose);
      await tester.pumpWidget(MaterialApp(
          home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        chaoxingClient: library,
        schoolClock: () => DateTime.parse('${day}T09:00:00'),
      )));
      final tile = find.byKey(const ValueKey<String>('home:CACHED_ACTION'));
      for (var attempt = 0; attempt < 5 && tile.evaluate().isEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tile, findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('正在更新预约状态…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(tile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(client.bookingDetailCalls, 1);
      expect(find.byType(BottomSheet), findsOneWidget);
      final action = ability == 'close' ? '退座' : '取消预约';
      expect(find.text(action), findsOneWidget);
      await tester.drag(
          find
              .descendant(
                  of: find.byType(BottomSheet),
                  matching: find.byType(Scrollable))
              .first,
          const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(action));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(ability == 'close' ? '确认退座' : '取消这条预约'), findsOneWidget);
      await tester.tap(find.text(ability == 'close' ? '返回' : '保留'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 300));

      client.recentGate.complete();
      await pumpBookingPage(tester);
      expect(tile, findsNothing);
      expect(find.text('暂无待履约或进行中的预约'), findsOneWidget);
      expect(client.bookingDetailCalls, 1);
    });
  }

  for (final fromHistory in [false, true]) {
    for (final action in ['close', 'cancel']) {
      testWidgets(
          '${fromHistory ? 'history' : 'home'} $action refreshes only its venue after the write',
          (tester) async {
        final day = ThereBookingClient.schoolDay();
        final clients = {
          for (final venue
              in BookingVenue.values.where((venue) => !venue.isChaoxing))
            venue: _HomeWriteClient(venue, day, action),
        };
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
          thereClientFactory: (venue) => clients[venue]!,
          chaoxingClient: library,
          schoolClock: () => DateTime.parse('${day}T09:00:00'),
        )));
        await pumpBookingPage(tester);
        expect(find.byKey(const ValueKey<String>('home:HOME_ACTION')),
            findsOneWidget);
        expect(find.byKey(const ValueKey<String>('home:HOME_STABLE')),
            findsNothing);
        if (fromHistory) {
          await tester.ensureVisible(find.text('查看历史预约'));
          await tester.pump();
          await tester.tap(find.text('查看历史预约'));
          await pumpBookingPage(tester);
        }
        final actionClient = clients[BookingVenue.studySpace]!;
        final stableClient = clients[BookingVenue.library]!;
        final previousActionCalls = actionClient.recentCalls;
        final previousStableCalls = stableClient.recentCalls;
        final previousRoomCalls = library.roomsCalls;
        final previousAreaCalls = {
          for (final entry in clients.entries)
            entry.key: entry.value.areaListCalls,
        };
        final actionTile = find.byKey(
            ValueKey<String>('${fromHistory ? '0' : 'home'}:HOME_ACTION'));
        await tester.scrollUntilVisible(actionTile, 120,
            scrollable: find.byType(Scrollable).first);
        await pumpBookingPage(tester);
        await tester.tap(actionTile);
        await pumpBookingPage(tester);
        await tester.tap(find.text(action == 'close' ? '退座' : '取消预约'));
        await pumpBookingPage(tester);
        await tester.tap(find.text('确认'));
        await pumpBookingPage(tester);
        expect(actionClient.written, isTrue);
        expect(actionClient.recentCalls, greaterThan(previousActionCalls));
        expect(stableClient.recentCalls, previousStableCalls);
        expect(library.roomsCalls, previousRoomCalls);
        for (final entry in clients.entries) {
          expect(
              entry.value.areaListCalls,
              previousAreaCalls[entry.key]! +
                  (entry.key == BookingVenue.studySpace ? 1 : 0));
        }
        if (!fromHistory) {
          expect(find.byKey(const ValueKey<String>('home:HOME_ACTION')),
              findsNothing);
          expect(find.byKey(const ValueKey<String>('home:HOME_STABLE')),
              findsOneWidget);
          await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('查看历史预约'));
          await pumpBookingPage(tester);
        }
        final updated = find.byKey(const ValueKey<String>('0:HOME_ACTION'));
        expect(updated, findsOneWidget);
        expect(
          find.descendant(
              of: updated,
              matching: find.text(action == 'close' ? '已结束' : '已取消')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('返回上一步'));
        await pumpBookingPage(tester);
        expect(find.byKey(const ValueKey<String>('home:HOME_ACTION')),
            findsNothing);
        expect(find.byKey(const ValueKey<String>('home:HOME_STABLE')),
            findsOneWidget);
        expect(stableClient.recentCalls, previousStableCalls);
        expect(actionClient.recentCalls, previousActionCalls + 1);
      });
    }
  }

  testWidgets('recent cancel ability survives a failed detail prefetch',
      (tester) async {
    final client = _RecentCancelableDetailFailureClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey<String>('0:UPCOMING')));
    await pumpBookingPage(tester);
    expect(find.text('取消预约'), findsOneWidget);
    await tester.tap(find.text('取消预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认'));
    await pumpBookingPage(tester);
    expect(client.cancelled, isTrue);
  });

  testWidgets('booking row and centered arrow appear together after detail',
      (tester) async {
    final client = _GatedDetailHistoryClient();
    final library = EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      chaoxingClient: library,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        find.byKey(const ValueKey<String>('0:FINISHED_EARLY')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('0:UPCOMING')), findsOneWidget);

    client.detailGate.complete();
    await pumpBookingPage(tester);
    const tileKey = ValueKey<String>('0:UPCOMING');
    final tile = find.byKey(tileKey);
    final arrow = find.descendant(
      of: tile,
      matching: find.byIcon(Icons.chevron_right),
    );
    final status = find.descendant(of: tile, matching: find.text('待履约'));
    expect(find.byKey(tileKey), findsOneWidget);
    expect(arrow, findsOneWidget);
    expect((tester.getCenter(arrow).dy - tester.getCenter(tile).dy).abs(),
        lessThan(3));
    expect(tester.getBottomRight(status).dy,
        greaterThan(tester.getCenter(arrow).dy));
  });
}
