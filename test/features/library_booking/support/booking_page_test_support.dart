import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/chaoxing_booking_client.dart';
import 'package:shuyo/data/services/there_booking_client.dart';

Future<void> pumpBookingPage(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

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

class FakeThereBookingClient extends ThereBookingClient {
  FakeThereBookingClient()
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

class VenueScopedBookingClient extends FakeThereBookingClient {
  VenueScopedBookingClient(this.expectedVenue);

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

class CampusLoadingClient extends VenueScopedBookingClient {
  CampusLoadingClient(super.expectedVenue, {this.areaGate});

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

class HistoryClient extends FakeThereBookingClient {
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

class FakeLibraryRoomsClient extends ChaoxingBookingClient {
  FakeLibraryRoomsClient()
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

class EmptyChaoxingBookingClient extends FakeLibraryRoomsClient {
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
