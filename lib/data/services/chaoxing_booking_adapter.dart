import 'dart:async';
import 'dart:io';

import 'academic_account_store.dart';
import 'chaoxing_booking_client.dart';
import 'there_booking_client.dart';

/// Exposes the library seat provider through the booking page's existing model.
/// The injected client owns its HTTP connection and session.
class ChaoxingBookingAdapter extends ThereBookingClient {
  ChaoxingBookingAdapter({
    required ChaoxingBookingClient client,
    DateTime Function()? schoolClock,
    Future<List<Map<String, dynamic>>> Function()? loadRooms,
  })  : _client = client,
        _loadRooms = loadRooms,
        _schoolClock = schoolClock ??
            (() => DateTime.now().toUtc().add(const Duration(hours: 8)));

  final ChaoxingBookingClient _client;
  final Future<List<Map<String, dynamic>>> Function()? _loadRooms;
  final DateTime Function() _schoolClock;
  BookingVenue? _selectedVenue;
  Future<void>? _pendingReset;
  final Map<String, Map<String, dynamic>> _knownRooms = {};
  final Map<String, Map<String, dynamic>> _created = {};
  String? _knownDay;
  String? _sessionUserId;
  static const _sharedSnapshotWindow = Duration(seconds: 5);
  List<Map<String, dynamic>>? _roomSnapshot;
  DateTime? _roomSnapshotAt;
  final Set<BookingVenue> _roomSnapshotServed = {};
  List<Map<String, dynamic>>? _recentSnapshot;
  DateTime? _recentSnapshotAt;
  final Set<BookingVenue> _recentSnapshotServed = {};

  void _clearSnapshots() {
    _roomSnapshot = null;
    _roomSnapshotAt = null;
    _roomSnapshotServed.clear();
    _clearRecentSnapshot();
  }

  void _clearRecentSnapshot() {
    _recentSnapshot = null;
    _recentSnapshotAt = null;
    _recentSnapshotServed.clear();
  }

  bool _canShare(
      DateTime? fetchedAt, BookingVenue venue, Set<BookingVenue> served) {
    if (fetchedAt == null || served.contains(venue)) return false;
    final elapsed = DateTime.now().difference(fetchedAt);
    return elapsed >= Duration.zero && elapsed < _sharedSnapshotWindow;
  }

  void _clearData() {
    _knownRooms.clear();
    _created.clear();
    _knownDay = null;
    _clearSnapshots();
  }

  static const _rules = <String, dynamic>{
    'startHour': 8,
    'endHour': 22,
    'meetingInterval': 30,
    'minDuration': 60,
    'maxDuration': 840,
    'supportAcrossDayBooking': false,
  };

  String get _today {
    final now = _schoolClock();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${pad(now.month)}-${pad(now.day)}';
  }

  @override
  BookingVenue? get venue => _selectedVenue;

  @override
  bool get hasBusinessSession => _selectedVenue != null && _client.user != null;

  @override
  void resetSession() {
    _selectedVenue = null;
    _sessionUserId = null;
    _clearData();
    _pendingReset = _client.clearSession().catchError((Object _) {});
  }

  @override
  Future<void> clearSession() async {
    _selectedVenue = null;
    _sessionUserId = null;
    _clearData();
    await _pendingReset;
    _pendingReset = null;
    await _client.clearSession();
  }

  Future<T> _translate<T>(Future<T> Function() work) async {
    try {
      await _pendingReset;
      _pendingReset = null;
      return await work();
    } on ChaoxingBookingException catch (error) {
      throw ThereBookingException(
        switch (error.kind) {
          ChaoxingFailureKind.loginRequired => ThereFailureKind.loginRequired,
          ChaoxingFailureKind.unreachable => ThereFailureKind.unreachable,
          ChaoxingFailureKind.business => ThereFailureKind.business,
          ChaoxingFailureKind.uncertain => ThereFailureKind.uncertain,
        },
        error.message,
        ssoExpired: error.ssoExpired,
      );
    }
  }

  BookingVenue _requireVenue() {
    final venue = _selectedVenue;
    if (venue == null || !venue.isChaoxing) {
      throw const ThereBookingException(ThereFailureKind.business, '请先选择图书馆场馆');
    }
    return venue;
  }

  void _requireToday(String day) {
    if (day != _today) {
      throw const ThereBookingException(
          ThereFailureKind.business, '只能预约今天，请重新选择当天时段');
    }
  }

  Future<void> _checkAccount() async {
    final expected = await AcademicAccountStore().loadStudentId();
    final actual = _id(_client.user?['sno']);
    if (expected == null || actual == null) return;
    if (expected.toLowerCase() == actual.toLowerCase()) return;
    await _client.clearSession();
    _selectedVenue = null;
    _sessionUserId = null;
    _clearData();
    throw const ThereBookingException(
        ThereFailureKind.business, '图书馆预约账号与当前校园账号不一致，请重新登录');
  }

  static BookingVenue? _venueForRoom(Map<String, dynamic> room) {
    final name = '${room['secondLevelName'] ?? ''} '
        '${room['thirdLevelName'] ?? ''}';
    if (name.contains('钱伟长')) return BookingVenue.qianweichang;
    if (name.contains('嘉定')) return BookingVenue.jiading;
    if (name.contains('延长') || name.contains('文荟')) {
      return BookingVenue.wenhui;
    }
    return null;
  }

  static String? _id(Object? value) => ThereBookingClient.string(value);

  static int? _count(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  @override
  Future<void> selectVenue(BookingVenue venue) => _translate(() async {
        if (!venue.isChaoxing) {
          throw const ThereBookingException(
              ThereFailureKind.business, '所选场馆不属于图书馆座位系统');
        }
        if (_client.user == null) {
          _clearData();
          await _client.bootstrap();
        }
        await _checkAccount();
        final userId = _id(_client.user?['uid']);
        if (_sessionUserId != userId) {
          _clearData();
        }
        _sessionUserId = userId;
        _selectedVenue = venue;
      });

  @override
  Future<Map<String, dynamic>> profile() => _translate(() async {
        _requireVenue();
        final user = _client.user ?? await _client.bootstrap();
        await _checkAccount();
        final uid = _id(user['uid']);
        final sno = _id(user['sno']);
        if (uid == null || sno == null) {
          throw const ThereBookingException(
              ThereFailureKind.loginRequired, '图书馆预约账号需要重新登录');
        }
        return {
          'id': uid,
          'name': _id(user['uname']) ?? '校园用户',
          'loginName': sno,
          'jobNumber': sno,
          'isAnonymous': false,
        };
      });

  @override
  Future<Map<String, dynamic>> overview(String day) async {
    _requireVenue();
    _requireToday(day);
    return {
      'bookingDays': [
        {'day': _today},
      ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> areas(String day) => _translate(() async {
        final venue = _requireVenue();
        _requireToday(day);
        if (_knownDay != day) {
          _knownDay = day;
          _knownRooms.clear();
          _roomSnapshot = null;
          _roomSnapshotAt = null;
          _roomSnapshotServed.clear();
        }
        if (_roomSnapshot == null ||
            !_canShare(_roomSnapshotAt, venue, _roomSnapshotServed)) {
          _roomSnapshot = await (_loadRooms?.call() ?? _client.rooms());
          _roomSnapshotAt = DateTime.now();
          _roomSnapshotServed.clear();
        }
        _roomSnapshotServed.add(venue);
        final rooms = _roomSnapshot!;
        _requireToday(day);
        final result = <Map<String, dynamic>>[];
        for (final room in rooms) {
          if (_venueForRoom(room) != venue) continue;
          final id = _id(room['id']);
          if (id == null) continue;
          _knownRooms[id] = room;
          final capacity = _count(room['capacity']);
          result.add({
            'id': id,
            'name': _id(room['thirdLevelName']) ?? '阅览室',
            'supportRoomTypes': [venue.roomType],
            if (capacity != null) 'totalResourceCount': capacity,
            'disabledResourceCount': 0,
            'bookingTimes': _rules,
          });
        }
        return result;
      });

  Future<Map<String, dynamic>> _room(String roomId) async {
    final venue = _requireVenue();
    if (_knownDay != _today) {
      _knownRooms.clear();
      _knownDay = null;
    }
    var room = _knownRooms[roomId];
    if (room == null || _venueForRoom(room) != venue) {
      await areas(_today);
      room = _knownRooms[roomId];
    }
    if (room == null || _venueForRoom(room) != venue) {
      throw const ThereBookingException(
          ThereFailureKind.business, '所选阅览室不属于当前场馆');
    }
    return room;
  }

  static ({String day, String? time}) _splitDateTime(String value) {
    final match =
        RegExp(r'^(\d{4}-\d{2}-\d{2})(?: (\d{2}:\d{2}))?$').firstMatch(value);
    if (match == null) {
      throw const ThereBookingException(
          ThereFailureKind.business, '请选择有效的预约日期与时段');
    }
    return (day: match.group(1)!, time: match.group(2));
  }

  @override
  Future<Map<String, dynamic>> area(String areaId, String begin, String end) =>
      _translate(() async {
        final start = _splitDateTime(begin);
        final finish = _splitDateTime(end);
        _requireToday(start.day);
        _requireToday(finish.day);
        final room = await _room(areaId);
        if (start.time == null && finish.time == null) {
          return {'bookingTimes': _rules, 'rooms': <Map<String, dynamic>>[]};
        }
        if (start.time == null || finish.time == null) {
          throw const ThereBookingException(
              ThereFailureKind.business, '请选择完整的预约时段');
        }
        final available = await _client.availability(
          roomId: areaId,
          start: start.time!,
          end: finish.time!,
        );
        _requireToday(start.day);
        final free = ThereBookingClient.strings(available['available']).toSet();
        final occupied = ThereBookingClient.strings(available['used']).toSet();
        final details = ThereBookingClient.object(available['room']) ?? room;
        final capacity =
            _count(details['capacity']) ?? _count(room['capacity']);
        final first = _count(details['startSeatNum']) ??
            _count(room['startSeatNum']) ??
            1;
        final numbers = capacity == null
            ? {...free, ...occupied}.toList()
            : [
                for (var value = first; value < first + capacity; value++)
                  value.toString().padLeft(3, '0'),
              ];
        numbers.sort();
        return {
          'bookingTimes': _rules,
          'rooms': [
            for (final number in numbers)
              {
                'id': number,
                'name': number,
                'officeAreaId': areaId,
                'disabled': false,
                'isBusy': !free.contains(number),
                'isBooked': occupied.contains(number),
                'abilities': free.contains(number) ? ['booking'] : <String>[],
              },
          ],
        };
      });

  @override
  Future<String> create({
    required String areaId,
    required String roomId,
    required String day,
    required String start,
    required String end,
  }) =>
      _translate(() async {
        final venue = _requireVenue();
        _requireToday(day);
        final schoolNow = _schoolClock();
        if (schoolNow.hour < 7) {
          throw const ThereBookingException(
              ThereFailureKind.business, '当天预约 07:00 开放');
        }
        final room = await _room(areaId);
        final current =
            await _client.availability(roomId: areaId, start: start, end: end);
        _requireToday(day);
        final seat = _id(roomId);
        if (seat == null ||
            !ThereBookingClient.strings(current['available']).contains(seat)) {
          throw const ThereBookingException(
              ThereFailureKind.business, '所选座位已不可预约，请刷新后重选');
        }
        _clearRecentSnapshot();
        final rawId = await _client.submit(
          roomId: areaId,
          start: start,
          end: end,
          seatNum: seat,
        );
        final id = _wrapId(venue, rawId);
        _created[id] = {
          'id': id,
          'roomType': venue.roomType,
          'roomName': seat,
          'officeAreaName': _id(room['thirdLevelName']) ?? '',
          'allOfficeAreaName':
              '${_id(room['secondLevelName']) ?? venue.label} · '
                  '${_id(room['thirdLevelName']) ?? ''}',
          'beginTime': '$day $start:00',
          'endTime': '$day $end:00',
          'statusLabel': '待确认',
          'abilities': <String>[],
        };
        return id;
      });

  static String _wrapId(BookingVenue venue, String raw) =>
      'cx:${venue.roomType}:$raw';

  static String _unwrapId(String value, BookingVenue venue) {
    final prefix = 'cx:${venue.roomType}:';
    if (!value.startsWith(prefix)) {
      throw const ThereBookingException(
          ThereFailureKind.business, '预约编号不属于当前场馆');
    }
    final raw = value.substring(prefix.length);
    if (!RegExp(r'^\d+$').hasMatch(raw)) {
      throw const ThereBookingException(ThereFailureKind.business, '预约编号无效');
    }
    return raw;
  }

  static String? _schoolTime(Object? value) {
    final epoch = _count(value);
    if (epoch == null) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true)
        .add(const Duration(hours: 8));
    String pad(int part) => part.toString().padLeft(2, '0');
    return '${date.year.toString().padLeft(4, '0')}-'
        '${pad(date.month)}-${pad(date.day)} '
        '${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
  }

  static bool _explicitCancel(Map<String, dynamic> item) =>
      item['canCancel'] == true ||
      ThereBookingClient.strings(item['abilities']).contains('cancel');

  bool _canSign(Map<String, dynamic> item, Map<String, dynamic> seatConfig) {
    final startTime = _count(item['startTime']);
    final beforeMinutes = _count(item['preSignDuration']) ??
        _count(seatConfig['preSignDuration']) ??
        _count(seatConfig['signDuration']);
    final afterMinutes =
        _count(item['signDuration']) ?? _count(seatConfig['signDuration']);
    if (startTime == null) return false;
    final schoolStart =
        DateTime.fromMillisecondsSinceEpoch(startTime, isUtc: true)
            .add(const Duration(hours: 8));
    final now = _schoolClock();
    if (now.isBefore(schoolStart)) {
      return beforeMinutes != null &&
          beforeMinutes >= 0 &&
          !now.isBefore(schoolStart.subtract(Duration(minutes: beforeMinutes)));
    }
    return afterMinutes != null &&
        afterMinutes >= 0 &&
        !now.isAfter(schoolStart.add(Duration(minutes: afterMinutes)));
  }

  Map<String, dynamic>? _booking(Map<String, dynamic> item,
      {required bool current, required Map<String, dynamic> seatConfig}) {
    final rawId = _id(item['id']);
    if (rawId == null || !RegExp(r'^\d+$').hasMatch(rawId)) return null;
    final venue = _venueForRoom(item);
    if (venue == null) return null;
    final status = _id(item['status']);
    final canCancel = status != '2' &&
        status != '7' &&
        (_explicitCancel(item) || current && status == '0');
    final canFinish = current && (status == '1' || status == '3');
    final canSign = current &&
        status == '0' &&
        _id(item['roomId']) != null &&
        _id(item['seatNum']) != null &&
        _canSign(item, seatConfig);
    final area = _id(item['thirdLevelName']) ?? '';
    final hall = _id(item['secondLevelName']) ?? venue.label;
    return {
      'id': _wrapId(venue, rawId),
      'roomType': venue.roomType,
      'roomName': _id(item['seatNum']) ?? '',
      if (_id(item['roomId']) case final String roomId) 'cxRoomId': roomId,
      if (_id(item['seatNum']) case final String seatNum) 'cxSeatNum': seatNum,
      if (_id(seatConfig['deptId']) case final String deptId)
        'cxDeptId': deptId,
      'officeAreaName': area,
      'allOfficeAreaName': '$hall · $area',
      if (_schoolTime(item['startTime']) case final String value)
        'beginTime': value,
      if (_schoolTime(item['endTime']) case final String value)
        'endTime': value,
      'status': status == null ? 'CX_UNKNOWN' : 'CX_$status',
      'cxCurrent': current,
      'statusLabel': switch (status) {
        '0' => '待签到',
        '1' => '在座',
        '2' => '已退座',
        '3' => '暂离',
        '7' => '已结束',
        null => '状态待确认',
        _ => '状态 $status',
      },
      'abilities': [
        if (canCancel) 'cancel',
        if (canSign) 'sign',
        if (canFinish) 'close',
      ],
    };
  }

  Future<List<Map<String, dynamic>>> _allBookings() async {
    final home = await _client.home();
    final seatConfig = ThereBookingClient.object(home['seatConfig']) ?? {};
    final byId = <String, Map<String, dynamic>>{};
    for (final item in ThereBookingClient.objects(home['curReserves'])) {
      final mapped = _booking(item, current: true, seatConfig: seatConfig);
      if (mapped != null) byId[mapped['id'] as String] = mapped;
    }
    for (final item in ThereBookingClient.objects(home['nearReserves'])) {
      final mapped = _booking(item, current: false, seatConfig: seatConfig);
      if (mapped != null) {
        byId.putIfAbsent(mapped['id'] as String, () => mapped);
      }
    }
    return byId.values.toList();
  }

  @override
  Future<List<Map<String, dynamic>>> recent() => _translate(() async {
        final venue = _requireVenue();
        if (_recentSnapshot == null ||
            !_canShare(_recentSnapshotAt, venue, _recentSnapshotServed)) {
          _recentSnapshot = await _allBookings();
          _recentSnapshotAt = DateTime.now();
          _recentSnapshotServed.clear();
        }
        _recentSnapshotServed.add(venue);
        final all = _recentSnapshot!;
        return all.where((item) => item['roomType'] == venue.roomType).toList();
      });

  @override
  Future<Map<String, dynamic>> detail(String bookingId) => _translate(() async {
        final venue = _requireVenue();
        final rawId = _unwrapId(bookingId, venue);
        _clearRecentSnapshot();
        final all = await _allBookings();
        final item = all
            .where((entry) =>
                entry['id'] == _wrapId(venue, rawId) &&
                entry['roomType'] == venue.roomType)
            .firstOrNull;
        if (item != null) return item;
        final pending = _created[_wrapId(venue, rawId)];
        if (pending != null && pending['roomType'] == venue.roomType) {
          return pending;
        }
        throw const ThereBookingException(
            ThereFailureKind.uncertain, '预约详情暂未同步，请稍后刷新我的预约');
      });

  @override
  Future<void> cancel(String bookingId) => _translate(() async {
        final current = await detail(bookingId);
        if (!ThereBookingClient.strings(current['abilities'])
            .contains('cancel')) {
          throw const ThereBookingException(
              ThereFailureKind.business, '当前预约不可取消');
        }
        await _client.cancel(_unwrapId(bookingId, _requireVenue()));
        _created.remove(bookingId);
        _clearRecentSnapshot();
      });

  @override
  Future<void> finish(String bookingId) => _translate(() async {
        final venue = _requireVenue();
        final rawId = _unwrapId(bookingId, venue);
        final current = await detail(bookingId);
        if (!ThereBookingClient.strings(current['abilities'])
            .contains('close')) {
          throw const ThereBookingException(
              ThereFailureKind.business, '当前预约不可退座');
        }
        await _client.signback(rawId);
        _created.remove(bookingId);
        _clearRecentSnapshot();
      });

  Future<void> sign(String bookingId) => _translate(() async {
        final venue = _requireVenue();
        final rawId = _unwrapId(bookingId, venue);
        final current = await detail(bookingId);
        if (!ThereBookingClient.strings(current['abilities'])
            .contains('sign')) {
          throw const ThereBookingException(
              ThereFailureKind.business, '当前不在可签到时间或预约状态不可签到');
        }
        final roomId = _id(current['cxRoomId']);
        final seatNum = _id(current['cxSeatNum']);
        if (roomId == null || seatNum == null) {
          throw const ThereBookingException(
              ThereFailureKind.business, '当前预约缺少房间或座位信息，请刷新后重试');
        }
        await _client.signWithSeatPage(
          reserveId: rawId,
          roomId: roomId,
          seatNum: seatNum,
          deptId: _id(current['cxDeptId']),
        );
        _clearRecentSnapshot();
      });

  @override
  Future<String> prepareOAuth() async {
    throw const ThereBookingException(
        ThereFailureKind.loginRequired, '请先登录校园账户，再返回图书馆预约');
  }

  @override
  Future<void> completeOAuth(
    Uri callback, {
    Iterable<({Cookie cookie, String domain, String path})> cookies = const [],
  }) async {
    throw const ThereBookingException(
        ThereFailureKind.business, '当前场馆使用校园账户登录，请返回后重试');
  }
}
