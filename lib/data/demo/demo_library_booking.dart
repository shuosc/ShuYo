import '../services/there_booking_client.dart';

/// In-memory seat reservations shared by the library pages in one demo session.
class DemoLibraryBookingSession {
  DemoLibraryBookingSession({DateTime Function()? schoolClock})
      : schoolClock = schoolClock ??
            (() => DateTime.now().toUtc().add(const Duration(hours: 8)));

  final DateTime Function() schoolClock;
  final _venues = <BookingVenue, LibraryBookingVenueData>{};

  LibraryBookingVenueData forVenue(BookingVenue venue) => _venues.putIfAbsent(
      venue, () => _DemoLibraryBookingVenue(venue, schoolClock));
}

class _DemoLibraryBookingVenue implements LibraryBookingVenueData {
  _DemoLibraryBookingVenue(this._venue, this._schoolClock);

  static const _seatCount = 15;
  static const _rules = {
    'startHour': 8,
    'endHour': 22,
    'meetingInterval': 30,
    'minDuration': 30,
    'maxDuration': 180,
  };
  static const _areaNames = {
    BookingVenue.library: ['二楼东侧', '二楼西侧'],
    BookingVenue.studySpace: ['A区', 'B区'],
    BookingVenue.qianweichang: ['四楼外圈', '四楼内圈'],
    BookingVenue.scienceArt: ['学生共享创作中心A', '学生共享创作中心B'],
    BookingVenue.yanchang: ['B区', 'C区'],
    BookingVenue.wenhui: ['一楼自修区', '二楼自修区'],
    BookingVenue.jiading: ['一楼自修室', '二楼自修区'],
  };

  final BookingVenue _venue;
  final DateTime Function() _schoolClock;
  final _bookings = <String, Map<String, dynamic>>{};
  int _nextBooking = 0;

  String get _now => _schoolClock().toIso8601String().replaceFirst('T', ' ');

  String _areaId(int index) => '${_venue.roomType}-$index';
  String _roomId(String areaId, int seat) => '$areaId-$seat';

  List<String> _days(String day) {
    final date = DateTime.parse('${day}T00:00:00Z');
    final tomorrow = date.add(const Duration(days: 1));
    return [day, tomorrow.toIso8601String().substring(0, 10)];
  }

  @override
  Future<Map<String, dynamic>> profile() async => const {
        'id': 'demo-library',
        'name': '演示用户',
        'isAnonymous': false,
      };

  @override
  Future<Map<String, dynamic>> overview(String day) async => {
        'bookingDays': _days(day),
      };

  @override
  Future<List<Map<String, dynamic>>> areas(String day) async => [
        for (final index in _areaNames[_venue]!.asMap().keys)
          _area(index, '$day 08:00', '$day 22:00'),
      ];

  @override
  Future<Map<String, dynamic>> area(
          String areaId, String begin, String end) async =>
      _area(_areaIndex(areaId), begin, end);

  int _areaIndex(String areaId) {
    final index = _areaNames[_venue]!
        .asMap()
        .keys
        .where((index) => _areaId(index) == areaId)
        .firstOrNull;
    if (index == null) {
      throw const ThereBookingException(ThereFailureKind.business, '分区不可用');
    }
    return index;
  }

  Map<String, dynamic> _area(int index, String begin, String end) {
    final areaId = _areaId(index);
    final bookedRoomIds = {
      for (final record in _bookings.values)
        if (record['officeAreaId'] == areaId &&
            record['status'] != 'CANCEL' &&
            (record['beginTime'] as String).compareTo(end) < 0 &&
            (record['endTime'] as String).compareTo(begin) > 0)
          record['roomId'],
    };
    final rooms = [
      for (var seat = 1; seat <= _seatCount; seat++)
        {
          'id': _roomId(areaId, seat),
          'name': seat.toString().padLeft(2, '0'),
          'officeAreaId': areaId,
          'isBusy': seat == 3 || seat == 8,
          'disabled': seat == 5,
          'isBooked': bookedRoomIds.contains(_roomId(areaId, seat)),
          'abilities': const ['booking'],
        },
    ];
    final free = rooms.where(_isAvailable).length;
    return {
      'id': areaId,
      'name': _areaNames[_venue]![index],
      'supportRoomTypes': [_venue.roomType],
      'bookingTimes': _rules,
      'totalResourceCount': rooms.length,
      'disabledResourceCount': 1,
      'freeResourceCount': free,
      'rooms': rooms,
    };
  }

  bool _isAvailable(Map<String, dynamic> room) =>
      room['disabled'] == false &&
      room['isBusy'] == false &&
      room['isBooked'] == false;

  Map<String, dynamic> _record(String id) {
    final record = _bookings[id];
    if (record == null) {
      throw const ThereBookingException(ThereFailureKind.business, '预约不存在');
    }
    return record;
  }

  Map<String, dynamic> _withAbilities(Map<String, dynamic> record) => {
        ...record,
        'abilities': [
          if (_canCancel(record)) 'cancel',
        ],
      };

  bool _canCancel(Map<String, dynamic> record) =>
      record['status'] != 'CANCEL' &&
      (record['endTime'] as String).compareTo(_now) > 0;

  @override
  Future<List<Map<String, dynamic>>> recent() async =>
      _bookings.values.map(_withAbilities).toList();

  @override
  Future<Map<String, dynamic>> detail(String bookingId) async =>
      _withAbilities(_record(bookingId));

  @override
  Future<String> create({
    required String areaId,
    required String roomId,
    required String day,
    required String start,
    required String end,
  }) async {
    final begin = '$day $start';
    final finish = '$day $end';
    final beginAt = DateTime.tryParse('${begin.replaceFirst(' ', 'T')}Z');
    final finishAt = DateTime.tryParse('${finish.replaceFirst(' ', 'T')}Z');
    final now = _now;
    if (beginAt == null ||
        finishAt == null ||
        !_days(now.substring(0, 10)).contains(day) ||
        begin.compareTo(now.substring(0, 16)) < 0 ||
        start.compareTo('08:00') < 0 ||
        end.compareTo('22:00') > 0 ||
        beginAt.minute % _rules['meetingInterval']! != 0 ||
        finishAt.minute % _rules['meetingInterval']! != 0 ||
        finishAt.difference(beginAt).inMinutes < _rules['minDuration']! ||
        finishAt.difference(beginAt).inMinutes > _rules['maxDuration']!) {
      throw const ThereBookingException(
          ThereFailureKind.business, '请选择有效的预约时段');
    }

    final currentArea = _area(_areaIndex(areaId), begin, finish);
    final room = ThereBookingClient.objects(currentArea['rooms'])
        .where((room) => room['id'] == roomId && _isAvailable(room))
        .firstOrNull;
    if (room == null) {
      throw const ThereBookingException(
          ThereFailureKind.business, '所选座位已不可预约，请重选');
    }
    final id = 'demo-${_venue.roomType}-${++_nextBooking}';
    _bookings[id] = {
      'id': id,
      'roomId': roomId,
      'roomType': _venue.roomType,
      'roomName': room['name'],
      'officeAreaId': areaId,
      'officeAreaName': currentArea['name'],
      'beginTime': begin,
      'endTime': finish,
      'createdAt': now,
      'status': 'BOOKING',
    };
    return id;
  }

  @override
  Future<void> cancel(String bookingId) async {
    final record = _record(bookingId);
    if (!_canCancel(record)) {
      throw const ThereBookingException(ThereFailureKind.business, '当前预约不可取消');
    }
    record['status'] = 'CANCEL';
  }
}
