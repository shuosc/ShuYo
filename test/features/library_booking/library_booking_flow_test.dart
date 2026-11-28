import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPicker;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/there_booking_client.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/features/library_booking/library_booking_names.dart';
import 'package:shuyo/features/library_booking/library_booking_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

import 'support/booking_page_test_support.dart';

class _ManyDaysClient extends FakeThereBookingClient {
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

class _TomorrowBookingClient extends FakeThereBookingClient {
  @override
  Future<Map<String, dynamic>> overview(String day) async => {
        'bookingDays': [
          {'day': day},
          {'day': '2026-10-19'},
        ],
      };
}

class _AreaRulesRetryClient extends FakeThereBookingClient {
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

class _NoMinimumClient extends FakeThereBookingClient {
  @override
  Future<Map<String, dynamic>> area(
      String areaId, String begin, String end) async {
    final data = await super.area(areaId, begin, end);
    (data['bookingTimes'] as Map).remove('minDuration');
    return data;
  }
}

class _IntervalBookingClient extends FakeThereBookingClient {
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
      if (begin == bookingDay()) {
        await todayRules.future;
      } else {
        await nextDayRules.future;
      }
      final data = await super.area(areaId, begin, end);
      if (begin != bookingDay()) {
        (data['bookingTimes'] as Map)['startHour'] = 12;
      }
      return data;
    }
    return super.area(areaId, begin, end);
  }
}

class _ChangingSeatsClient extends FakeThereBookingClient {
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

class _DelayedCreateClient extends FakeThereBookingClient {
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

Future<void> _pickTime(
    WidgetTester tester, String box, String hour, String minute) async {
  await tester.tap(find.byKey(ValueKey(box)));
  await pumpBookingPage(tester);
  int indexFor(String title, String value) {
    final picker = tester
        .widget<CupertinoPicker>(find.byKey(ValueKey('time-wheel-$title')));
    final children =
        (picker.childDelegate as ListWheelChildListDelegate).children;
    return children
        .indexWhere((child) => ((child as Center).child as Text).data == value);
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

String _boxValue(WidgetTester tester, String key) => tester
    .widget<Text>(
      find.descendant(
          of: find.byKey(ValueKey(key)), matching: find.byType(Text)),
    )
    .data!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'campus venues, create confirmation, and cancellation are reachable',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: 'STUDENT_1',
    });
    final client = FakeThereBookingClient();
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
    expect(find.textContaining(bookingDay()), findsNothing);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.textContaining(bookingDay()), findsNothing);
    expect(find.textContaining('最长 8 小时'), findsOneWidget);
    expect(client.detailAreaCalls, 1);
    expect(_boxValue(tester, 'start-hour'), '08');
    expect(_boxValue(tester, 'start-minute'), '00');
    expect(_boxValue(tester, 'end-hour'), '08');
    expect(_boxValue(tester, 'end-minute'), '30');
    await _pickTime(tester, 'start-hour', '10', '00');
    await _pickTime(tester, 'end-minute', '11', '00');
    expect(_boxValue(tester, 'start-hour'), '10');
    expect(_boxValue(tester, 'end-hour'), '11');
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
    expect(find.textContaining(bookingDay()), findsNothing);
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
      schoolClock: bookingSchoolTime,
    )));
    await pumpBookingPage(tester);
    expect(find.textContaining('2E015'), findsNothing);
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
      schoolClock: bookingSchoolTime,
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
    await _pickTime(tester, 'start-hour', '10', '00');
    expect(_boxValue(tester, 'start-hour'), '10');
    expect(_boxValue(tester, 'end-hour'), '10');
    expect(_boxValue(tester, 'end-minute'), '30');
    await _pickTime(tester, 'end-hour', '10', '00');
    expect(_boxValue(tester, 'start-hour'), '09');
    expect(_boxValue(tester, 'start-minute'), '30');
    await _pickTime(tester, 'end-hour', '18', '00');
    expect(_boxValue(tester, 'start-hour'), '10');
    expect(_boxValue(tester, 'end-hour'), '18');
    await _pickTime(tester, 'start-hour', '21', '30');
    expect(_boxValue(tester, 'start-hour'), '21');
    expect(_boxValue(tester, 'start-minute'), '30');
    expect(_boxValue(tester, 'end-hour'), '22');
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey(bookingDayKey(1))));
    await pumpBookingPage(tester);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(_boxValue(tester, 'start-hour'), '08');
    expect(_boxValue(tester, 'start-minute'), '00');
    expect(_boxValue(tester, 'end-hour'), '08');
    expect(_boxValue(tester, 'end-minute'), '30');
    await tester.tap(find.byKey(const ValueKey('manual-seat-button')));
    await pumpBookingPage(tester);
    await tester.tap(find.byTooltip('返回上一步'));
    await pumpBookingPage(tester);
    expect(find.text('创建预约'), findsOneWidget);
    expect(find.byKey(ValueKey(bookingDayKey(1))), findsOneWidget);
  });

  testWidgets('half-hour range slider and time boxes stay synchronized',
      (tester) async {
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: bookingSchoolTime,
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
    expect(_boxValue(tester, 'start-hour'), '10');
    expect(_boxValue(tester, 'start-minute'), '00');
    expect(_boxValue(tester, 'end-hour'), '10');
    expect(_boxValue(tester, 'end-minute'), '30');
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
    expect(_boxValue(tester, 'end-hour'), '11');
    expect(_boxValue(tester, 'end-minute'), '00');
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
          schoolClock: bookingSchoolTime,
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
      schoolClock: bookingSchoolTime,
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
    final library = EmptyChaoxingBookingClient();
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
    await _pickTime(tester, 'start-hour', '20', '30');
    await _pickTime(tester, 'end-hour', '22', '00');
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
      schoolClock: bookingSchoolTime,
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(find.textContaining('最短'), findsNothing);
    await _pickTime(tester, 'start-hour', '10', '00');
    expect(_boxValue(tester, 'start-hour'), '10');
    expect(_boxValue(tester, 'end-hour'), '10');
    expect(_boxValue(tester, 'end-minute'), '30');
  });

  testWidgets('today has no default after the final valid start',
      (tester) async {
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => bookingSchoolTime(21, 46),
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
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => bookingSchoolTime(8, 7),
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    await tester.tap(find.byKey(ValueKey(bookingDayKey())));
    await pumpBookingPage(tester);
    expect(_boxValue(tester, 'start-hour'), '08');
    expect(_boxValue(tester, 'start-minute'), '30');
    expect(_boxValue(tester, 'end-hour'), '09');
    expect(_boxValue(tester, 'end-minute'), '00');
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
      schoolClock: bookingSchoolTime,
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
    expect(_boxValue(tester, 'start-hour'), '12');
    expect(_boxValue(tester, 'end-hour'), '12');
    expect(find.text('可选座位数：1/2'), findsOneWidget);
    expect(client.ruleDays.length, ruleCalls);
    expect(client.detailAreaCalls, previewCalls);
  });

  testWidgets('early morning uses 08:00 and seat count follows the time',
      (tester) async {
    final client = _ChangingSeatsClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryBookingPage(
      accountService: UnifiedAccountService(),
      thereClientFactory: (_) => client,
      schoolClock: () => bookingSchoolTime(2, 7),
    )));
    await tester
        .tap(find.text(LibraryBookingNames.venue(BookingVenue.library)));
    await pumpBookingPage(tester);
    await tester.tap(find.text('2楼东侧'));
    await pumpBookingPage(tester);
    expect(_boxValue(tester, 'start-hour'), '08');
    expect(_boxValue(tester, 'start-minute'), '00');
    expect(_boxValue(tester, 'end-hour'), '08');
    expect(_boxValue(tester, 'end-minute'), '30');
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
    await _pickTime(tester, 'start-hour', '10', '00');
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
    final client = FakeThereBookingClient();
    addTearDown(client.dispose);
    final spec = ShuYoThemes.byId(ShuYoThemes.systemDarkId);
    await tester.pumpWidget(MaterialApp(
      theme: spec.themeData(),
      home: LibraryBookingPage(
        accountService: UnifiedAccountService(),
        thereClientFactory: (_) => client,
        schoolClock: bookingSchoolTime,
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
        schoolClock: bookingSchoolTime,
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
}
