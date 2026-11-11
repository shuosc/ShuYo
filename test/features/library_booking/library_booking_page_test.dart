import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/chaoxing_booking_client.dart';
import 'package:shuyo/data/services/library_booking_cache.dart';
import 'package:shuyo/data/services/there_booking_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/library_booking/library_booking_list_tile.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/features/library_booking/library_booking_names.dart';
import 'package:shuyo/features/library_booking/library_booking_resources.dart';
import 'package:shuyo/shared/navigation/shuyo_route.dart';
import 'package:shuyo/shared/theme/custom_background.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

Future<void> pumpBookingPage(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

class _BookingClient extends ThereBookingClient {
  _BookingClient()
      : super(cookieLoader: (_) async => [], cookieSetter: (_) async {});

  final selectedVenues = <BookingVenue>[];
  final refreshedVenues = <BookingVenue>[];
  int areaListCalls = 0;
  int detailAreaCalls = 0;
  int bookingDetailCalls = 0;
  bool created = false;
  bool cancelled = false;
  BookingVenue? cancellationVenue;
  String? submittedDay;
  String? submittedStart;
  String? submittedEnd;

  @override
  Future<void> selectVenue(BookingVenue venue) async {
    selectedVenues.add(venue);
  }

  @override
  Future<void> refreshVenue(BookingVenue venue) async {
    refreshedVenues.add(venue);
    await super.refreshVenue(venue);
  }

  @override
  Future<Map<String, dynamic>> profile() async => {
        'id': 'USER_1',
        'name': '测试用户',
        'loginName': 'STUDENT_1',
        'isAnonymous': false,
      };

  @override
  Future<List<Map<String, dynamic>>> recent() async => created
      ? [
          {
            'id': 'BOOKING_1',
            'roomType': BookingVenue.library.roomType,
            'roomName': '2E015',
            'officeAreaName': '二楼东侧',
            'beginTime':
                '${submittedDay ?? '2026-10-03'} ${submittedStart ?? '08:30'}:00',
            'endTime':
                '${submittedDay ?? '2026-10-03'} ${submittedEnd ?? '09:30'}:00',
            'statusLabel': cancelled ? '已取消' : '已预约',
          },
        ]
      : [];

  @override
  Future<Map<String, dynamic>> overview(String day) async => {
        'bookingDays': [
          {'day': day},
        ],
      };

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    areaListCalls++;
    return [
      {
        'id': 'ROOT',
        'name': '校本部图书馆自修区',
        'supportRoomTypes': [BookingVenue.library.roomType],
      },
      {
        'id': 'AREA_1',
        'name': '二楼东侧',
        'parentId': 'ROOT',
        'totalResourceCount': 10,
        'disabledResourceCount': 1,
        'busyResourceCount': 3,
        'freeResourceCount': 6,
        'bookingTimes': {'startHour': 8, 'endHour': 22},
        'supportRoomTypes': [
          for (final venue in BookingVenue.values) venue.roomType,
        ],
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    if (begin.contains(' ')) detailAreaCalls++;
    return {
      'bookingTimes': {
        'suggestStartTime': '08:30',
        'suggestEndTime': '09:30',
        'minDuration': 30,
        'maxDuration': 480,
        'startHour': 8,
        'endHour': 22,
        'meetingInterval': 30,
      },
      'rooms': [
        {
          'id': 'ROOM_1',
          'name': '2E015',
          'officeAreaId': 'AREA_1',
          'abilities': ['booking'],
        },
        {
          'id': 'ROOM_2',
          'name': '2E016',
          'officeAreaId': 'AREA_1',
          'isBusy': true,
          'abilities': <String>[],
        },
      ],
    };
  }

  @override
  Future<String> create({
    required String areaId,
    required String roomId,
    required String day,
    required String start,
    required String end,
  }) async {
    submittedDay = day;
    submittedStart = start;
    submittedEnd = end;
    created = true;
    return 'BOOKING_1';
  }

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async {
    bookingDetailCalls++;
    return {
      'id': bookingId,
      'roomName': '2E015',
      'allOfficeAreaName': '校本部图书馆-二楼东侧',
      'beginTime':
          '${submittedDay ?? '2026-10-03'} ${submittedStart ?? '08:30'}:00',
      'endTime':
          '${submittedDay ?? '2026-10-03'} ${submittedEnd ?? '09:30'}:00',
      'statusLabel': cancelled ? '已取消' : '已预约',
      'abilities': cancelled ? <String>[] : ['cancel'],
    };
  }

  @override
  Future<void> cancel(String bookingId) async {
    cancellationVenue = selectedVenues.last;
    cancelled = true;
  }
}

class _UnreachableBookingClient extends _BookingClient {
  @override
  Future<void> selectVenue(BookingVenue venue) async =>
      throw const ThereBookingException(
        ThereFailureKind.unreachable,
        '暂时无法访问预约系统。请连接校园网、学校VPN，或开启WebVPN后重试。',
      );
}

class _GatedAreaListClient extends _BookingClient {
  final gate = Completer<void>();
  int started = 0;

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    started++;
    await gate.future;
    return super.areas(day);
  }
}

class _GatedVenueSelectionClient extends _BookingClient {
  final gate = Completer<void>();
  final selectionCalls = <BookingVenue, int>{};

  @override
  Future<void> selectVenue(BookingVenue venue) async {
    selectionCalls.update(venue, (count) => count + 1, ifAbsent: () => 1);
    await gate.future;
    await super.selectVenue(venue);
  }
}

class _VenueScopedBookingClient extends _BookingClient {
  _VenueScopedBookingClient(this.expectedVenue);

  final BookingVenue expectedVenue;

  @override
  Future<void> selectVenue(BookingVenue venue) async {
    if (venue != expectedVenue) {
      throw StateError('Another venue took over this client');
    }
    await super.selectVenue(venue);
  }

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    areaListCalls++;
    return [
      {
        'id': expectedVenue.roomType,
        'name': '${expectedVenue.label}分区',
        'supportRoomTypes': [expectedVenue.roomType],
        'totalResourceCount': 12,
        'disabledResourceCount': 2,
        'bookingTimes': {'startHour': 8, 'endHour': 22},
      },
    ];
  }
}

class _CampusLoadingClient extends _VenueScopedBookingClient {
  _CampusLoadingClient(super.expectedVenue, {this.areaGate});

  final Completer<void>? areaGate;
  Completer<void>? recentGate;
  List<Map<String, dynamic>>? records;
  bool failRecent = false;
  int areaLoadsStarted = 0;
  int recentCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async {
    areaLoadsStarted++;
    await areaGate?.future;
    return super.areas(day);
  }

  @override
  Future<List<Map<String, dynamic>>> recent() async {
    recentCalls++;
    await recentGate?.future;
    if (failRecent) {
      throw const ThereBookingException(
          ThereFailureKind.unreachable, '预约暂时无法加载');
    }
    return records ?? await super.recent();
  }
}

class _GatedHomeBookingsClient extends _BookingClient {
  final records = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> recent() => records.future;
}

class _ThreeAreaBookingClient extends _VenueScopedBookingClient {
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

class _EmptyThereAreaClient extends _BookingClient {
  @override
  Future<List<Map<String, dynamic>>> areas(String day) async => [];
}

class _EmptyOnceThereAreaClient extends _VenueScopedBookingClient {
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

class _GatewayRecoveryClient extends _BookingClient {
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

class _HistoryClient extends _BookingClient {
  @override
  Future<List<Map<String, dynamic>>> recent() async {
    final tomorrow = DateTime.parse(ThereBookingClient.schoolDay())
        .add(const Duration(days: 1));
    final day =
        '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    return [
      {
        'id': 'UPCOMING',
        'roomType': BookingVenue.studySpace.roomType,
        'roomName': 'B-034',
        'officeAreaName': 'B',
        'beginTime': '$day 08:30:00',
        'endTime': '$day 09:30:00',
        'createdAt': '2026-10-18 20:15:42',
        'status': cancelled ? 'CANCEL' : 'OPEN',
        'statusLabel': cancelled ? '已取消' : '正常',
      },
      {
        'id': 'FINISHED_EARLY',
        'roomType': BookingVenue.studySpace.roomType,
        'roomName': 'A-001',
        'officeAreaName': 'A',
        'beginTime': '2026-01-01 08:30:00',
        'endTime': '2026-01-01 08:30:00',
        'createdAt': '2025-12-31 21:05:00',
        'origEndAt': '2026-01-01 09:30:00',
        'duration': 0,
        'status': 'CANCEL',
        'statusLabel': '已取消',
      },
    ];
  }
}

class _CloseOnlyClient extends _HistoryClient {
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

class _GatedDetailHistoryClient extends _HistoryClient {
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

class _RecentCancelableDetailFailureClient extends _HistoryClient {
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

class _ManyDaysClient extends _BookingClient {
  @override
  Future<Map<String, dynamic>> overview(String day) async {
    final today = DateTime.parse(day);
    String format(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
    return {
      'bookingDays': [
        for (var offset = 0; offset < 4; offset++)
          {
            'day': format(
                DateTime.utc(today.year, today.month, today.day + offset))
          },
      ],
    };
  }
}

class _TomorrowBookingClient extends _BookingClient {
  @override
  Future<Map<String, dynamic>> overview(String day) async => {
        'bookingDays': [
          {'day': day},
          {'day': '2026-10-19'},
        ],
      };
}

class _AreaRulesRetryClient extends _BookingClient {
  bool failRulesOnce = true;

  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    if (begin == end && failRulesOnce) {
      failRulesOnce = false;
      throw const ThereBookingException(
          ThereFailureKind.unreachable, '分区时段暂时不可用');
    }
    return super.area(areaId, begin, end);
  }
}

class _NoMinimumClient extends _BookingClient {
  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    final data = await super.area(areaId, begin, end);
    (data['bookingTimes'] as Map).remove('minDuration');
    return data;
  }
}

class _IntervalBookingClient extends _BookingClient {
  _IntervalBookingClient(this.interval);

  final int interval;

  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    final data = await super.area(areaId, begin, end);
    (data['bookingTimes'] as Map)['meetingInterval'] = interval;
    return data;
  }
}

class _DeferredDayRulesClient extends _ManyDaysClient {
  final todayRules = Completer<void>();
  final nextDayRules = Completer<void>();
  final ruleDays = <String>[];

  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    if (begin == end) {
      ruleDays.add(begin);
      if (begin == ThereBookingClient.schoolDay()) {
        await todayRules.future;
      } else {
        await nextDayRules.future;
      }
      final data = await super.area(areaId, begin, end);
      if (begin != ThereBookingClient.schoolDay()) {
        (data['bookingTimes'] as Map)['startHour'] = 12;
      }
      return data;
    }
    return super.area(areaId, begin, end);
  }
}

class _ChangingSeatsClient extends _BookingClient {
  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    final data = await super.area(areaId, begin, end);
    if (begin.contains(' 10:00')) {
      (data['rooms'] as List).first['isBusy'] = true;
    }
    return data;
  }
}

class _DelayedCreateClient extends _BookingClient {
  final gate = Completer<void>();

  @override
  Future<String> create({
    required String areaId,
    required String roomId,
    required String day,
    required String start,
    required String end,
  }) async {
    await gate.future;
    return super.create(
        areaId: areaId, roomId: roomId, day: day, start: start, end: end);
  }
}

class _LibraryBranchClient extends ChaoxingBookingClient {
  _LibraryBranchClient()
      : super(cookieLoader: (_) async => [], cookieSetter: (_) async {});

  int roomsCalls = 0;

  @override
  Map<String, dynamic>? get user => const {
        'uid': 'USER_1',
        'uname': '测试用户',
        'sno': 'STUDENT_1',
      };

  @override
  Future<List<Map<String, dynamic>>> rooms() async {
    roomsCalls++;
    return [
      {
        'id': 6508,
        'secondLevelName': '钱伟长馆',
        'thirdLevelName': '四楼阅览室',
        'capacity': 2,
        'startSeatNum': 1,
      },
    ];
  }
}

class _EmptyChaoxingBookingClient extends _LibraryBranchClient {
  int homeCalls = 0;

  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    return {
      'curReserves': <Map<String, dynamic>>[],
      'nearReserves': <Map<String, dynamic>>[],
    };
  }
}

class _BookedChaoxingBookingClient extends _EmptyChaoxingBookingClient {
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

class _InUseChaoxingBookingClient extends _EmptyChaoxingBookingClient {
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

class _SignableChaoxingBookingClient extends _EmptyChaoxingBookingClient {
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

class _UnavailableChaoxingBookingClient extends _EmptyChaoxingBookingClient {
  @override
  Future<Map<String, dynamic>> home() async {
    homeCalls++;
    throw const ChaoxingBookingException(
        ChaoxingFailureKind.unreachable, '图书馆座位系统暂时无法访问');
  }
}

class _GatedBookingClient extends _BookingClient {
  final gate = Completer<void>();
  bool recentStarted = false;

  @override
  Future<List<Map<String, dynamic>>> recent() async {
    recentStarted = true;
    await gate.future;
    final day = ThereBookingClient.schoolDay();
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

class _CachedActionClient extends _BookingClient {
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

class _HomeWriteClient extends _BookingClient {
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

class _GatedChaoxingBookingClient extends _EmptyChaoxingBookingClient {
  final gate = Completer<void>();
  bool homeStarted = false;

  @override
  Future<Map<String, dynamic>> home() async {
    homeStarted = true;
    await gate.future;
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    return {
      'curReserves': [
        {
          'id': '1',
          'secondLevelName': '钱伟长图书馆',
          'thirdLevelName': '阅览室',
          'seatNum': 'CX-EARLY',
          'status': '0',
          'startTime': DateTime.utc(day.year, day.month, day.day, 1)
              .millisecondsSinceEpoch,
          'endTime': DateTime.utc(day.year, day.month, day.day, 2)
              .millisecondsSinceEpoch,
        },
      ],
      'nearReserves': <Map<String, dynamic>>[],
    };
  }
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
    final client = _BookingClient();
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
        schoolClock: () {
          final day = DateTime.parse(ThereBookingClient.schoolDay());
          return DateTime.utc(day.year, day.month, day.day, 8);
        },
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

  testWidgets('new library venue bypasses WebVPN when it is enabled',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    final there = _GatewayRecoveryClient();
    final library = _LibraryBranchClient();
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    var webVpnRecoveries = 0;
    addTearDown(there.dispose);
    addTearDown(library.dispose);

    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => there,
        chaoxingClient: library,
        useWebVpn: true,
        schoolClock: () => DateTime.utc(day.year, day.month, day.day, 8),
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

  DateTime schoolMorning() {
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    return DateTime.utc(day.year, day.month, day.day, 8);
  }

  String bookingDay([int offset = 0]) {
    final today = DateTime.parse(ThereBookingClient.schoolDay());
    final date = today.add(Duration(days: offset));
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String bookingDayKey([int offset = 0]) => 'booking-day-${bookingDay(offset)}';

  Future<void> pickTime(
      WidgetTester tester, String box, String hour, String minute) async {
    await tester.tap(find.byKey(ValueKey(box)));
    await pumpBookingPage(tester);
    int indexFor(String title, String value) {
      final picker = tester
          .widget<CupertinoPicker>(find.byKey(ValueKey('time-wheel-$title')));
      final children =
          (picker.childDelegate as ListWheelChildListDelegate).children;
      return children.indexWhere(
          (child) => ((child as Center).child as Text).data == value);
    }

    final hourPicker = tester
        .widget<CupertinoPicker>(find.byKey(const ValueKey('time-wheel-小时')));
    final hourIndex = indexFor('小时', hour);
    expect(hourIndex, greaterThanOrEqualTo(0));
    hourPicker.scrollController!.jumpToItem(hourIndex);
    await pumpBookingPage(tester);
    final minutePicker = tester
        .widget<CupertinoPicker>(find.byKey(const ValueKey('time-wheel-分钟')));
    final minuteIndex = indexFor('分钟', minute);
    expect(minuteIndex, greaterThanOrEqualTo(0));
    minutePicker.scrollController!.jumpToItem(minuteIndex);
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认时间'));
    await pumpBookingPage(tester);
  }

  String boxValue(WidgetTester tester, String key) => tester
      .widget<Text>(
        find.descendant(
            of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
      )
      .data!;

  group('shared booking snapshots', () {
    late Map<BookingVenue, _CampusLoadingClient> clients;
    late _EmptyChaoxingBookingClient library;
    late DateTime now;

    setUp(() {
      now = schoolMorning();
      clients = {
        for (final venue
            in BookingVenue.values.where((venue) => !venue.isChaoxing))
          venue: _CampusLoadingClient(venue),
      };
      library = _EmptyChaoxingBookingClient();
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
      final clients = <BookingVenue, _CampusLoadingClient>{};
      final library = _EmptyChaoxingBookingClient();
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
              clients.putIfAbsent(venue, () => _CampusLoadingClient(venue)),
          chaoxingClient: library,
          schoolClock: schoolMorning,
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
      'campus switches reuse pending areas and refresh only the active campus',
      (tester) async {
    final gate = Completer<void>();
    final clients = <BookingVenue, _CampusLoadingClient>{};
    final library = _EmptyChaoxingBookingClient();
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
            () => _CampusLoadingClient(venue,
                areaGate: venue == BookingVenue.yanchang ||
                        venue == BookingVenue.scienceArt
                    ? gate
                    : null)),
        chaoxingClient: library,
        schoolClock: schoolMorning,
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
      final library = _EmptyChaoxingBookingClient();
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

  testWidgets(
      'campus venues, create confirmation, and cancellation are reachable',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    final client = _BookingClient();
    final library = _EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        chaoxingClient: library,
        schoolClock: schoolMorning,
      ),
    ));
    await pumpBookingPage(tester);
    expect(find.text('图书馆预约'), findsOneWidget);
    expect(find.text('仅查看座位情况'), findsNothing);
    await tester.scrollUntilVisible(
        find.text(LibraryBookingNames.venue(BookingVenue.qianweichang)), 180,
        scrollable: find.byType(Scrollable).first);
    for (final venue in [
      BookingVenue.library,
      BookingVenue.studySpace,
      BookingVenue.qianweichang,
    ]) {
      expect(find.text(LibraryBookingNames.venue(venue)), findsWidgets);
    }
    await tester.tap(find.text('延长校区'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(
        find.text(LibraryBookingNames.venue(BookingVenue.wenhui)), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(LibraryBookingNames.venue(BookingVenue.library)),
        findsNothing);
    for (final venue in [
      BookingVenue.scienceArt,
      BookingVenue.yanchang,
      BookingVenue.wenhui,
    ]) {
      expect(find.text(LibraryBookingNames.venue(venue)), findsOneWidget);
    }
    await tester.tap(find.text('嘉定校区'));
    await pumpBookingPage(tester);
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text(LibraryBookingNames.venue(BookingVenue.jiading)),
        findsOneWidget);
    await tester.tap(find.text('宝山校区'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(find.text('我的预约'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(tester.getTopLeft(find.text('我的预约')).dy,
        lessThan(tester.getTopLeft(find.text('选择场馆')).dy));
    expect(find.text('暂无待履约或进行中的预约'), findsOneWidget);
    await tester.tap(find.text('我的预约'));
    await pumpBookingPage(tester);
    expect(find.text('选择场馆'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('查看历史预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('查看历史预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.byTooltip('返回上一步'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(
        find.text(LibraryBookingNames.venue(BookingVenue.library)), -180,
        scrollable: find.byType(Scrollable).first);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    expect(find.byTooltip('我的预约'), findsNothing);
    expect(find.text('以下为当前座位情况'), findsNothing);
    expect(find.text('2楼东侧'), findsOneWidget);
    expect(find.textContaining('开放座位数：6/9'), findsOneWidget);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    expect(find.text('宝山校区 - 本部图书馆 - 2楼东侧'), findsOneWidget);
    expect(find.textContaining(ThereBookingClient.schoolDay()), findsNothing);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.textContaining(ThereBookingClient.schoolDay()), findsNothing);
    expect(find.textContaining('最长 8 小时'), findsOneWidget);
    expect(client.detailAreaCalls, 1);
    expect(boxValue(tester, 'start-hour'), '08');
    expect(boxValue(tester, 'start-minute'), '00');
    expect(boxValue(tester, 'end-hour'), '08');
    expect(boxValue(tester, 'end-minute'), '30');
    await pickTime(tester, 'start-hour', '10', '00');
    await pickTime(tester, 'end-minute', '11', '00');
    expect(boxValue(tester, 'start-hour'), '10');
    expect(boxValue(tester, 'end-hour'), '11');
    expect(client.detailAreaCalls, greaterThan(1));
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    final previews = client.detailAreaCalls;
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    expect(client.detailAreaCalls, previews + 1);
    expect(find.text('宝山校区 - 本部图书馆 - 2楼东侧'), findsOneWidget);
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).bottomNavigationBar,
        isA<Container>());
    expect(find.textContaining(ThereBookingClient.schoolDay()), findsNothing);
    await tester.tap(find.text('2E015'));
    await pumpBookingPage(tester);
    final seatTile = find.byTooltip('2E015，可选');
    final seatLabel = find.descendant(
      of: seatTile,
      matching: find.text('2E015'),
    );
    final selectedWeight = tester.widget<Text>(seatLabel).style!.fontWeight;
    await tester.tap(seatTile);
    await pumpBookingPage(tester);
    expect(tester.widget<Text>(seatLabel).style!.fontWeight, selectedWeight);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认座位'))
            .onPressed,
        isNull);
    await tester.tap(seatTile);
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认座位'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('selected-seat-label')), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('2E015'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '创建预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, '创建预约'));
    await pumpBookingPage(tester);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('宝山校区 - 本部图书馆 - 2楼东侧'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('提交'));
    await pumpBookingPage(tester);
    expect(client.created, isTrue);
    expect(client.selectedVenues.last, BookingVenue.library);
    expect(find.text('图书馆预约'), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('home:BOOKING_1')), findsOneWidget);
    expect(find.text('取消预约'), findsOneWidget);
    expect(find.text('预约编号'), findsNothing);
    expect(find.text('宝山校区 本部图书馆'), findsWidgets);
    expect(find.text('there:BOOKING_1'), findsNothing);
    expect(find.text('座位'), findsNothing);
    final createdDetailSheet =
        tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(createdDetailSheet.backgroundColor,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.surface);
    expect(createdDetailSheet.clipBehavior, Clip.antiAlias);
    expect((createdDetailSheet.shape as RoundedRectangleBorder).borderRadius,
        const BorderRadius.vertical(top: Radius.circular(20)));
    await tester.tap(find.text('取消预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认'));
    await pumpBookingPage(tester);
    expect(client.cancelled, isTrue);
    for (var step = 0; step < 2; step++) {
      if (find.byTooltip('返回上一步').evaluate().isEmpty) break;
      await tester.tap(find.byTooltip('返回上一步'));
      await pumpBookingPage(tester);
    }
    expect(find.text('暂无本地记录'), findsNothing);
    expect(find.textContaining('2E015'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
    )));
    await pumpBookingPage(tester);
    expect(find.textContaining('2E015'), findsNothing);
  });

  testWidgets(
      'selected campus venues load areas concurrently and expand in place',
      (tester) async {
    final client = _GatedAreaListClient();
    final library = _EmptyChaoxingBookingClient();
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
      schoolClock: schoolMorning,
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
    final clients = <BookingVenue, _VenueScopedBookingClient>{};
    final library = _EmptyChaoxingBookingClient();
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
              : _VenueScopedBookingClient(venue),
        ),
        chaoxingClient: library,
        schoolClock: schoolMorning,
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

  testWidgets('area and booking preloads share each venue entry request',
      (tester) async {
    final client = _GatedVenueSelectionClient();
    final library = _EmptyChaoxingBookingClient();
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
        schoolClock: schoolMorning,
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
    final clients = <BookingVenue, _VenueScopedBookingClient>{};
    final library = _EmptyChaoxingBookingClient();
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
            clients.putIfAbsent(venue, () => _VenueScopedBookingClient(venue)),
        chaoxingClient: library,
        schoolClock: schoolMorning,
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
    final library = _EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        chaoxingClient: library,
        schoolClock: schoolMorning,
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
    final clients = <BookingVenue, _VenueScopedBookingClient>{};
    final library = _EmptyChaoxingBookingClient();
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
              : _VenueScopedBookingClient(venue),
        ),
        chaoxingClient: library,
        schoolClock: schoolMorning,
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
        schoolClock: schoolMorning,
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
        schoolClock: schoolMorning,
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

  testWidgets('seat preview entry is hidden while venue selection remains',
      (tester) async {
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
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
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
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
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
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
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
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
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
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

  testWidgets(
      'only today and tomorrow appear, and time boxes keep a valid interval',
      (tester) async {
    final client = _ManyDaysClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    expect(find.byType(ChoiceChip), findsNothing);
    for (var offset = 0; offset < 5; offset++) {
      expect(find.byKey(ValueKey(bookingDayKey(offset))), findsOneWidget);
      expect(
          tester
              .widget<InkWell>(find.byKey(ValueKey(bookingDayKey(offset))))
              .onTap,
          offset < 2 ? isNotNull : isNull);
    }
    expect(find.byKey(ValueKey(bookingDayKey(5))), findsNothing);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.text('已选场馆'), findsOneWidget);
    final selectedVenue = find.text('宝山校区 - 本部图书馆 - 2楼东侧');
    expect(selectedVenue, findsOneWidget);
    expect(tester.widget<Text>(selectedVenue).style,
        Theme.of(tester.element(selectedVenue)).textTheme.bodyMedium);
    expect(find.byKey(const ValueKey('start-hour')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.byKey(const ValueKey('booking-time-range')), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byKey(const ValueKey('start-hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('start-minute')), findsOneWidget);
    expect(find.byKey(const ValueKey('end-hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('end-minute')), findsOneWidget);
    expect(find.textContaining('最短'), findsNothing);
    await pickTime(tester, 'start-hour', '10', '00');
    expect(boxValue(tester, 'start-hour'), '10');
    expect(boxValue(tester, 'end-hour'), '10');
    expect(boxValue(tester, 'end-minute'), '30');
    await pickTime(tester, 'end-hour', '10', '00');
    expect(boxValue(tester, 'start-hour'), '09');
    expect(boxValue(tester, 'start-minute'), '30');
    await pickTime(tester, 'end-hour', '18', '00');
    expect(boxValue(tester, 'start-hour'), '10');
    expect(boxValue(tester, 'end-hour'), '18');
    await pickTime(tester, 'start-hour', '21', '30');
    expect(boxValue(tester, 'start-hour'), '21');
    expect(boxValue(tester, 'start-minute'), '30');
    expect(boxValue(tester, 'end-hour'), '22');
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey(bookingDayKey(1))));
    await pumpBookingPage(tester);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(boxValue(tester, 'start-hour'), '08');
    expect(boxValue(tester, 'start-minute'), '00');
    expect(boxValue(tester, 'end-hour'), '08');
    expect(boxValue(tester, 'end-minute'), '30');
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    await tester.tap(find.byTooltip('返回上一步'));
    await pumpBookingPage(tester);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.byKey(ValueKey(bookingDayKey(1))), findsOneWidget);
  });

  testWidgets('half-hour range slider and time boxes stay synchronized',
      (tester) async {
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: schoolMorning,
      ),
    ));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);

    const rangeKey = ValueKey('booking-time-range');
    RangeSlider range() => tester.widget<RangeSlider>(find.byKey(rangeKey));
    expect(range().min, 8 * 60);
    expect(range().max, 22 * 60);
    expect(range().divisions, 28);
    expect(range().values, const RangeValues(480, 510));
    expect(range().labels, isNull);
    expect(
        SliderTheme.of(tester.element(find.byKey(rangeKey))).showValueIndicator,
        ShowValueIndicator.never);
    final durationLeft = tester.getTopLeft(find.text('已选 0.5 小时')).dx;

    final previewCalls = client.detailAreaCalls;
    range().onChanged!(const RangeValues(600, 630));
    await tester.pump();
    expect(boxValue(tester, 'start-hour'), '10');
    expect(boxValue(tester, 'start-minute'), '00');
    expect(boxValue(tester, 'end-hour'), '10');
    expect(boxValue(tester, 'end-minute'), '30');
    expect(range().values, const RangeValues(600, 630));
    expect(client.detailAreaCalls, previewCalls);
    expect(find.textContaining('正在查询'), findsNothing);
    expect(find.textContaining('可选座位数：'), findsNothing);
    range().onChangeEnd!(range().values);
    await pumpBookingPage(tester);
    expect(client.detailAreaCalls, previewCalls + 1);

    range().onChanged!(const RangeValues(600, 660));
    await tester.pump();
    expect(tester.getTopLeft(find.text('已选 1 小时')).dx, durationLeft);
    expect(boxValue(tester, 'end-hour'), '11');
    expect(boxValue(tester, 'end-minute'), '00');
    range().onChangeEnd!(range().values);
    await pumpBookingPage(tester);
    final beforeWheel = client.detailAreaCalls;
    await tester.tap(find.byKey(const ValueKey('start-hour')));
    await pumpBookingPage(tester);
    final hourPicker = tester
        .widget<CupertinoPicker>(find.byKey(const ValueKey('time-wheel-小时')));
    final hours =
        (hourPicker.childDelegate as ListWheelChildListDelegate).children;
    final noonIndex = hours
        .indexWhere((child) => ((child as Center).child as Text).data == '12');
    expect(noonIndex, greaterThanOrEqualTo(0));
    hourPicker.scrollController!.jumpToItem(noonIndex);
    await pumpBookingPage(tester);
    expect(client.detailAreaCalls, beforeWheel);
    await tester.tap(find.text('确认时间'));
    await pumpBookingPage(tester);
    expect(client.detailAreaCalls, beforeWheel + 1);
    expect(range().values, const RangeValues(720, 750));
  });

  for (final interval in [15, 60]) {
    testWidgets(
        'range slider stays on valid half-hours for $interval-minute rules',
        (tester) async {
      final client = _IntervalBookingClient(interval);
      addTearDown(client.dispose);
      await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
          accountService: UnifiedAccountService(),
          thereClientFactory: (_) => client,
          schoolClock: schoolMorning,
        ),
      ));
      await tester
          .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
      await pumpBookingPage(tester);
      await tester.tap(find.text('2楼东侧'));
      await pumpBookingPage(tester);

      const key = ValueKey('booking-time-range');
      RangeSlider range() => tester.widget<RangeSlider>(find.byKey(key));
      expect(range().divisions, 28);
      expect(find.text('08:00'), findsNothing);
      range().onChanged!(const RangeValues(495, 570));
      await tester.pump();
      expect(range().values.start % 30, 0);
      expect(range().values.end % 30, 0);
      if (interval == 60) {
        expect(range().values.start % 60, 0);
        expect(range().values.end % 60, 0);
      }
      range().onChangeEnd!(range().values);
      await pumpBookingPage(tester);
      expect(find.textContaining('正在查询'), findsNothing);
    });
  }

  testWidgets('date remains selectable when its time rules need a retry',
      (tester) async {
    final client = _AreaRulesRetryClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.byKey(ValueKey(bookingDayKey())), findsOneWidget);
    expect(find.text('分区时段暂时不可用'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-hour')), findsNothing);
    await tester.tap(find.text('重试加载时段'));
    await pumpBookingPage(tester);
    expect(find.text('分区时段暂时不可用'), findsNothing);
    expect(find.byKey(const ValueKey('start-hour')), findsOneWidget);
  });

  testWidgets('October 18 selection submits October 19 library booking',
      (tester) async {
    final client = _TomorrowBookingClient();
    final library = _EmptyChaoxingBookingClient();
    addTearDown(client.dispose);
    addTearDown(library.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        chaoxingClient: library,
        schoolClock: () => DateTime.utc(2026, 10, 18, 21, 18),
      ),
    ));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(const ValueKey('booking-day-2026-10-19')));
    await pumpBookingPage(tester);
    await pickTime(tester, 'start-hour', '20', '30');
    await pickTime(tester, 'end-hour', '22', '00');
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2E015'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('确认座位'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '创建预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, '创建预约'));
    await pumpBookingPage(tester);
    final confirmation = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.textContaining('宝山校区 - 本部图书馆 - 2楼东侧'),
    );
    expect(confirmation, findsOneWidget);
    await tester.tap(find.text('提交'));
    await pumpBookingPage(tester);
    expect(client.submittedDay, '2026-10-19');
    expect(client.submittedStart, '20:30');
    expect(client.submittedEnd, '22:00');
    expect(client.refreshedVenues, contains(BookingVenue.library));
  });

  testWidgets('missing minimum uses the smallest selectable step',
      (tester) async {
    final client = _NoMinimumClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.textContaining('最短'), findsNothing);
    await pickTime(tester, 'start-hour', '10', '00');
    expect(boxValue(tester, 'start-hour'), '10');
    expect(boxValue(tester, 'end-hour'), '10');
    expect(boxValue(tester, 'end-minute'), '30');
  });

  testWidgets('today has no default after the final valid start',
      (tester) async {
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => DateTime.utc(day.year, day.month, day.day, 21, 46),
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.text('今天已无可预约时段'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('manual-seat-button')))
            .onPressed,
        isNull);
  });

  testWidgets('today starts at the next selectable time', (tester) async {
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    final client = _BookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => DateTime.utc(day.year, day.month, day.day, 8, 7),
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(boxValue(tester, 'start-hour'), '08');
    expect(boxValue(tester, 'start-minute'), '30');
    expect(boxValue(tester, 'end-hour'), '09');
    expect(boxValue(tester, 'end-minute'), '00');
    const rangeKey = ValueKey('booking-time-range');
    RangeSlider range() => tester.widget<RangeSlider>(find.byKey(rangeKey));
    expect(range().values, const RangeValues(510, 540));
    final sliderTheme = SliderTheme.of(tester.element(find.byKey(rangeKey)));
    expect(sliderTheme.activeTrackColor,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.accent);
    expect(
        sliderTheme.rangeTickMarkShape, isA<RoundRangeSliderTickMarkShape>());
    expect(find.text('08:00'), findsNothing);
    range().onChanged!(const RangeValues(480, 540));
    await tester.pump();
    expect(range().values, const RangeValues(510, 540),
        reason: 'Elapsed time must remain unavailable');
  });

  testWidgets('open days prefetch concurrently and switching uses cached data',
      (tester) async {
    final client = _DeferredDayRulesClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: schoolMorning,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    for (var i = 0; i < 10 && client.ruleDays.length < 2; i++) {
      await tester.pump();
    }
    expect(client.ruleDays, containsAll([bookingDay(), bookingDay(1)]));
    client.todayRules.complete();
    client.nextDayRules.complete();
    await pumpBookingPage(tester);

    final startFinder = find.byKey(const ValueKey('start-hour'));
    final startElement = tester.element(startFinder);
    final startPosition = tester.getTopLeft(startFinder);
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    final ruleCalls = client.ruleDays.length;
    final previewCalls = client.detailAreaCalls;
    expect(ruleCalls, 2);
    expect(previewCalls, 2);

    await tester.tap(find.byKey(ValueKey(bookingDayKey(1))));
    await tester.pump();
    expect(tester.element(startFinder), same(startElement));
    expect(tester.getTopLeft(startFinder), startPosition);
    expect(find.textContaining('正在查询'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<InkWell>(startFinder).onTap, isNotNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('manual-seat-button')))
            .onPressed,
        isNotNull);
    expect(tester.element(startFinder), same(startElement));
    expect(boxValue(tester, 'start-hour'), '12');
    expect(boxValue(tester, 'end-hour'), '12');
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(client.ruleDays.length, ruleCalls);
    expect(client.detailAreaCalls, previewCalls);
  });

  testWidgets('early morning uses 08:00 and seat count follows the time',
      (tester) async {
    final day = DateTime.parse(ThereBookingClient.schoolDay());
    final client = _ChangingSeatsClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => DateTime.utc(day.year, day.month, day.day, 2, 7),
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    expect(boxValue(tester, 'start-hour'), '08');
    expect(boxValue(tester, 'start-minute'), '00');
    expect(boxValue(tester, 'end-hour'), '08');
    expect(boxValue(tester, 'end-minute'), '30');
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsNothing);
    final countText = tester.widget<Text>(find.text('可选座位数：1/2'));
    expect((countText.textSpan! as TextSpan).children![1].style?.color,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.accent);
    expect(find.text('自选'), findsOneWidget);
    expect(find.text('随机'), findsOneWidget);
    expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
    expect(find.byIcon(Icons.casino_outlined), findsOneWidget);

    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '创建预约'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '创建预约'))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const ValueKey('random-seat-button')));
    await pumpBookingPage(tester);
    expect(find.text('2E015'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '创建预约'))
            .onPressed,
        isNotNull);

    await tester.ensureVisible(find.byKey(const ValueKey('start-hour')));
    await pumpBookingPage(tester);
    await pickTime(tester, 'start-hour', '10', '00');
    expect(find.text('可选座位数：0/2'), findsOneWidget);
    expect(find.text('可选座位数：1/2'), findsNothing);
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '创建预约'), 180,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('——'), findsOneWidget);
    for (final key in ['manual-seat-button', 'random-seat-button']) {
      expect(tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed,
          isNull);
    }
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '创建预约'))
            .onPressed,
        isNull);
  });

  testWidgets('time fields and wheels use the active dark theme',
      (tester) async {
    final client = _BookingClient();
    addTearDown(client.dispose);
    final spec = ShuYoThemes.byId(ShuYoThemes.systemDarkId);
    await tester.pumpWidget(MaterialApp(
      theme: spec.themeData(),
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: schoolMorning,
      ),
    ));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.text('宝山校区 - 本部图书馆 - 2楼东侧'), findsOneWidget);
    expect(find.text('最长 8 小时'), findsOneWidget);
    expect(find.text('已选 0.5 小时'), findsOneWidget);
    expect(tester.widget<Text>(find.text('已选 0.5 小时')).style?.color,
        spec.colors.textTertiary);
    expect(tester.getCenter(find.text('最长 8 小时')).dy,
        tester.getCenter(find.text('已选 0.5 小时')).dy);
    expect(find.text('开始'), findsNothing);
    expect(find.text('结束'), findsNothing);
    final material = tester.widget<Material>(find
        .ancestor(
          of: find.byKey(const ValueKey('start-hour')),
          matching: find.byType(Material),
        )
        .first);
    expect(material.color, spec.colors.surface);
    final box = tester.widget<Container>(find
        .descendant(
          of: find.byKey(const ValueKey('start-hour')),
          matching: find.byType(Container),
        )
        .first);
    expect((box.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(10));
    final digit = tester.widget<Text>(find.descendant(
      of: find.byKey(const ValueKey('start-hour')),
      matching: find.byType(Text),
    ));
    expect(digit.style?.fontSize, 22);
    await tester.tap(find.byKey(const ValueKey('start-hour')));
    await pumpBookingPage(tester);
    expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        spec.colors.surface);
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
    for (final picker
        in tester.widgetList<CupertinoPicker>(find.byType(CupertinoPicker))) {
      expect(picker.backgroundColor, spec.colors.surface);
      expect(picker.selectionOverlay, isNull);
    }
    final hourWheel = tester
        .widget<CupertinoPicker>(find.byKey(const ValueKey('time-wheel-小时')));
    final children =
        (hourWheel.childDelegate as ListWheelChildListDelegate).children;
    final selected =
        (children[hourWheel.scrollController!.selectedItem] as Center).child
            as Text;
    expect(selected.style?.color, spec.colors.accent);
    expect(selected.style?.fontWeight, FontWeight.w600);
    final adjacent = (children[1] as Center).child as Text;
    expect(adjacent.style?.fontWeight, FontWeight.w400);
    hourWheel.scrollController!.jumpToItem(2);
    await pumpBookingPage(tester);
    final movedWheel = tester
        .widget<CupertinoPicker>(find.byKey(const ValueKey('time-wheel-小时')));
    final movedChildren =
        (movedWheel.childDelegate as ListWheelChildListDelegate).children;
    final movedSelected = (movedChildren[2] as Center).child as Text;
    final previousSelected = (movedChildren[0] as Center).child as Text;
    expect(movedSelected.style?.color, spec.colors.accent);
    expect(movedSelected.style?.fontWeight, FontWeight.w600);
    expect(previousSelected.style?.fontWeight, FontWeight.w400);
  });

  testWidgets('my bookings directly loads every venue and returns in one step',
      (tester) async {
    final client = _BookingClient();
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
    final there = _BookingClient();
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

  testWidgets('create returns home while waiting and opens listed booking',
      (tester) async {
    final client = _DelayedCreateClient();
    addTearDown(() {
      if (!client.gate.isCompleted) client.gate.complete();
      client.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: schoolMorning,
      ),
    ));
    await pumpBookingPage(tester);
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('random-seat-button')), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('random-seat-button')));
    await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, '创建预约'), 180,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(FilledButton, '创建预约'));
    await pumpBookingPage(tester);
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(find.text('图书馆预约'), findsOneWidget);
    expect(find.text('正在创建预约并更新列表…'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);

    client.gate.complete();
    await pumpBookingPage(tester);
    expect(
        find.byKey(const ValueKey<String>('home:BOOKING_1')), findsOneWidget);
    expect(find.text('正在创建预约并更新列表…'), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('there:BOOKING_1'), findsNothing);
  });

  testWidgets('current Chaoxing bookings stay active after their end time',
      (tester) async {
    final there = _BookingClient();
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
    final there = _BookingClient();
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

  testWidgets('available bookings remain visible when one service fails',
      (tester) async {
    final client = _HistoryClient();
    final library = _UnavailableChaoxingBookingClient();
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
        schoolClock: schoolMorning,
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
    final there = _HistoryClient();
    final library = _EmptyChaoxingBookingClient();
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

    var saved = await LibraryBookingCache().load('STUDENT_1');
    for (var attempt = 0; attempt < 10 && saved.length < 2; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      saved = await LibraryBookingCache().load('STUDENT_1');
    }
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
      schoolClock: schoolMorning,
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
      schoolClock: schoolMorning,
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

  testWidgets('booking tabs fit a narrow screen without scrolling',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final there = _BookingClient();
    final library = _EmptyChaoxingBookingClient();
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
    final client = _HistoryClient();
    final library = _EmptyChaoxingBookingClient();
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
    final library = _EmptyChaoxingBookingClient();
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
      final library = _EmptyChaoxingBookingClient();
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
        final library = _EmptyChaoxingBookingClient();
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
    final library = _EmptyChaoxingBookingClient();
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
    final library = _EmptyChaoxingBookingClient();
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
