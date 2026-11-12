import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/data/models/campus_card.dart';
import 'package:shuyo/data/services/campus_card_service.dart';
import 'package:shuyo/features/home/campus_card_history_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';
import 'package:shuyo/shared/widgets/date_picker_dialog.dart';
import 'package:table_calendar/table_calendar.dart';

const _debit = CampusCardBill(
  name: '餐费扣款',
  payTime: '2026-10-20 12:00:00',
  amount: 3.5,
);
const _credit = CampusCardBill(
  name: '其他入账原文',
  payTime: '2026-10-20 13:00:00',
  amount: -10,
);
const _zero = CampusCardBill(
  name: '零金额记录',
  payTime: '2026-10-19 12:00:00',
  amount: 0,
);
const _current = CampusCardBill(
  name: '新范围记录',
  payTime: '2026-10-22 12:00:00',
  amount: 2,
);
const _stale = CampusCardBill(
  name: '旧范围迟到记录',
  payTime: '2025-10-19 12:00:00',
  amount: 1,
);

void main() {
  testWidgets('new history rows enter only after their balance is ready',
      (tester) async {
    const card = CampusCardInfo(
      studentId: 'test',
      name: '',
      status: '',
      balance: 100,
      validUntil: '',
    );
    final pendingCard = Completer<CampusCardInfo>();
    final service = _HistoryService();
    await _pumpPage(tester, service, fetchCardInfo: () => pendingCard.future);
    final request = service.requests.single;
    request.report(const [_debit]);
    await tester.pump();
    expect(find.text(_debit.name), findsNothing);
    request.complete(const [_debit]);
    await tester.pump();
    expect(find.text(_debit.name), findsNothing);
    expect(_appBarProgress(), findsOneWidget);

    pendingCard.complete(card);
    await tester.pump();
    await tester.pump();
    expect(find.text(_debit.name), findsOneWidget);
    expect(find.text('余额 ¥100.00'), findsOneWidget);
    final row = find.ancestor(
        of: find.text(_debit.name), matching: find.byType(SlideTransition));
    expect(row, findsWidgets);
    expect(
        tester.widgetList<SlideTransition>(row).any((transition) =>
            (transition.position.value.dx - 0.12).abs() < 0.001),
        isTrue);
    await tester.pumpAndSettle();
    expect(_appBarProgress(), findsNothing);
  });

  testWidgets('history shows records if the balance request fails',
      (tester) async {
    final pendingCard = Completer<CampusCardInfo>();
    final service = _HistoryService();
    await _pumpPage(tester, service, fetchCardInfo: () => pendingCard.future);
    service.requests.single.complete(const [_debit]);
    await tester.pump();
    expect(find.text(_debit.name), findsNothing);
    pendingCard.completeError(const CampusCardException('network', '网络错误'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(_debit.name), findsOneWidget);
    expect(find.text('余额 —'), findsOneWidget);
    expect(_appBarProgress(), findsNothing);
  });

  testWidgets('history refresh keeps old balances until new rows are ready',
      (tester) async {
    const card = CampusCardInfo(
        studentId: 'test', name: '', status: '', balance: 100, validUntil: '');
    const updated = CampusCardInfo(
        studentId: 'test', name: '', status: '', balance: 120, validUntil: '');
    final pendingCard = Completer<CampusCardInfo>();
    var calls = 0;
    final service = _HistoryService();
    await _pumpPage(tester, service,
        fetchCardInfo: () =>
            calls++ == 0 ? Future.value(card) : pendingCard.future);
    service.requests.single.complete(const [_debit]);
    await tester.pumpAndSettle();
    expect(find.text('余额 ¥100.00'), findsOneWidget);

    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('余额 ¥100.00'), findsOneWidget);
    expect(find.text('余额 —'), findsNothing);
    final request = service.requests.last;
    request.report(const [_credit, _debit]);
    await tester.pump();
    expect(find.text(_credit.name), findsNothing);
    expect(find.text('余额 ¥100.00'), findsOneWidget);

    pendingCard.complete(updated);
    await tester.pump();
    await tester.pump();
    expect(find.text(_credit.name), findsOneWidget);
    expect(find.text('余额 ¥120.00'), findsOneWidget);
    expect(find.text('余额 ¥110.00'), findsOneWidget);
    request.complete(const [_credit, _debit]);
    await tester.pumpAndSettle();
    expect(find.text('余额 —'), findsNothing);
  });

  testWidgets('past date range includes newer transactions for balances',
      (tester) async {
    const card = CampusCardInfo(
        studentId: 'test', name: '', status: '', balance: 100, validUntil: '');
    final service = _HistoryService();
    final now = DateTime.now();
    final today = DateUtils.dateOnly(now);
    final past = DateTime(today.year, today.month, today.day - 2);
    await _pumpPage(tester, service, initialCard: card, initialQueriedAt: now);
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    await _chooseTime(tester, 'custom');
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final calendar = tester.widget<TableCalendar<void>>(
          find.byKey(const ValueKey('shuyo-calendar-day-view')));
      calendar.onDaySelected!(past, past);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final request = service.requests.last;
    expect(request.range.start, past);
    expect(request.range.end, today);
    request.complete([
      CampusCardBill(
          name: '较新充值', payTime: today.toIso8601String(), amount: -10),
      CampusCardBill(
          name: '过去消费', payTime: past.toIso8601String(), amount: 3.5),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('较新充值'), findsNothing);
    expect(find.text('过去消费'), findsOneWidget);
    expect(find.text('余额 ¥90.00'), findsOneWidget);
  });

  testWidgets('balances use all transactions before filtering tabs',
      (tester) async {
    const card = CampusCardInfo(
      studentId: 'test',
      name: '',
      status: '',
      balance: 100,
      validUntil: '',
    );
    final service = _HistoryService();
    await _pumpPage(tester, service,
        initialCard: card, initialQueriedAt: DateTime.now());
    service.requests.single.complete(const [_debit, _credit, _zero]);
    await tester.pumpAndSettle();
    expect(find.text('余额 ¥100.00'), findsOneWidget);
    expect(find.text('余额 ¥90.00'), findsOneWidget);
    expect(find.text('余额 ¥93.50'), findsOneWidget);
    expect(find.text('¥0.00'), findsOneWidget);
    final text = tester.widget<Text>(find.text('余额 ¥90.00'));
    expect(text.style!.fontSize, 12);
    expect(text.style!.color,
        ShuYoThemes.byId(ShuYoThemes.defaultId).colors.textTertiary);

    await _chooseTab(tester, 'debit');
    expect(find.text(_debit.name), findsOneWidget);
    expect(find.text('余额 ¥90.00'), findsOneWidget);
    expect(find.text('余额 ¥100.00'), findsNothing);
    expect(service.requests, hasLength(1));
    await _chooseTab(tester, 'credit');
    expect(find.text('余额 ¥100.00'), findsOneWidget);
  });

  testWidgets('history defaults to one week and only offers bounded ranges',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final request = service.requests.single;
    final today = request.range.end;
    expect(DateUtils.isSameDay(today, DateTime.now()), isTrue);
    expect(
        request.range.start, DateTime(today.year, today.month, today.day - 6));
    expect(find.textContaining(' 至 '), findsNothing);
    expect(find.byTooltip('消费时间：近一周'), findsOneWidget);
    expect(_appBarProgress(), findsOneWidget);
    _expectProgressAboveTabs(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byKey(const ValueKey('campus-card-time-filter')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('campus-card-time-all')), findsNothing);
    expect(find.text('时间不限'), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(4));
    for (final preset in ['week', 'month', 'year', 'custom']) {
      final option = find.byKey(ValueKey('campus-card-time-$preset'));
      expect(option, findsOneWidget);
      expect(tester.widget<ListTile>(option).selected, preset == 'week');
    }
    await tester.tap(find.byKey(const ValueKey('campus-card-time-week')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(service.requests, hasLength(1));

    request.report(const [_debit]);
    await tester.pump();
    expect(find.text(_debit.name), findsOneWidget);
    expect(find.text('已加载 1 条'), findsNothing);
    expect(find.text('共 1 条'), findsNothing);
    expect(_appBarProgress(), findsOneWidget);
    request.complete(const [_credit, _debit]);
    await tester.pumpAndSettle();
    expect(find.text('共 2 条'), findsNothing);
    expect(_appBarProgress(), findsNothing);
  });

  testWidgets('scrolling to the end does not query older history',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service, viewport: const Size(402, 600));
    final request = service.requests.single;
    final today = request.range.end;
    request.complete([
      for (var index = 0; index < 30; index++)
        CampusCardBill(
          name: '本周记录 $index',
          payTime: DateTime(today.year, today.month, today.day, 12)
              .subtract(Duration(minutes: index))
              .toString(),
          amount: 1,
        ),
    ]);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('本周记录 29'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(1));
    expect(_appBarProgress(), findsNothing);
    expect(find.text('继续查看更早记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty history offers date selection without loading older years',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();

    expect(find.text('所选日期内暂无记录，可切换日期查询。'), findsOneWidget);
    expect(find.text('继续查看更早记录'), findsNothing);
    expect(service.requests, hasLength(1));
    expect(_appBarProgress(), findsNothing);
  });

  testWidgets(
      'new rows enter from the right while existing duplicate rows stay visible',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service, viewport: const Size(402, 1000));
    final request = service.requests.single;
    request.report(const [_debit, _debit]);
    await tester.pump();

    SlideTransition slide(Finder row) => tester.widget<SlideTransition>(
          find.ancestor(of: row, matching: find.byType(SlideTransition)).first,
        );
    FadeTransition fade(Finder row) => tester.widget<FadeTransition>(
          find.ancestor(of: row, matching: find.byType(FadeTransition)).first,
        );
    final existing = find.text(_debit.name);
    expect(existing, findsNWidgets(2));
    expect(slide(existing.first).position.value.dx, closeTo(0.12, 0.001));
    expect(fade(existing.first).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(slide(existing.first).position.value.dx, 0);
    expect(fade(existing.first).opacity.value, 1);
    expect(fade(existing.last).opacity.value, 1);

    request.report(const [_debit, _debit, _credit]);
    await tester.pump();
    final added = find.text(_credit.name);
    expect(added, findsOneWidget);
    expect(existing, findsNWidgets(2));
    expect(fade(existing.first).opacity.value, 1);
    expect(fade(existing.last).opacity.value, 1);
    expect(slide(added).position.value.dx, closeTo(0.12, 0.001));
    expect(fade(added).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(slide(added).position.value.dx, 0);
    expect(fade(added).opacity.value, 1);
    request.complete(const [_debit, _debit, _credit]);
    await tester.pumpAndSettle();
    expect(existing, findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabs filter signed amounts locally and keep duplicate rows',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    service.requests.single.complete(const [_debit, _credit, _zero, _debit]);
    await tester.pumpAndSettle();
    expect(find.text(_debit.name), findsNWidgets(2));
    expect(find.text(_credit.name), findsOneWidget);
    expect(find.text(_zero.name), findsOneWidget);

    await _chooseTab(tester, 'credit');
    expect(find.text('充值含其他入账'), findsNothing);
    expect(find.text(_credit.name), findsOneWidget);
    expect(find.text(_debit.name), findsNothing);
    expect(find.text(_zero.name), findsNothing);
    expect(find.text('共 1 条'), findsNothing);

    await _chooseTab(tester, 'debit');
    expect(find.text(_debit.name), findsNWidgets(2));
    expect(find.text(_credit.name), findsNothing);
    expect(find.text(_zero.name), findsNothing);
    expect(find.text('充值含其他入账'), findsNothing);
    expect(find.text('共 2 条'), findsNothing);

    await _chooseTab(tester, 'all');
    expect(find.text(_zero.name), findsOneWidget);
    expect(service.requests, hasLength(1));
  });

  testWidgets('calendar presets remain available and custom cancel is inert',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final today = service.requests.single.range.end;
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();

    await _chooseTime(tester, 'custom');
    await tester.pumpAndSettle();
    expect(find.byType(ShuYoDatePickerDialog), findsOneWidget);
    expect(find.text('自定义消费日期'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(1));
    expect(find.byTooltip('消费时间：近一周'), findsOneWidget);

    await _chooseTime(tester, 'month');
    _expectProgressAboveTabs(tester);
    expect(service.requests.last.range,
        DateTimeRange(start: _monthsAgo(today, 1), end: today));
    service.requests.last.complete(const []);
    await tester.pumpAndSettle();
    await _chooseTime(tester, 'month');
    expect(service.requests, hasLength(2));

    await _chooseTime(tester, 'year');
    expect(service.requests.last.range,
        DateTimeRange(start: _monthsAgo(today, 12), end: today));
    service.requests.last.complete(const []);
    await tester.pumpAndSettle();

    await _chooseTime(tester, 'week');
    expect(
      service.requests.last.range,
      DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 6),
        end: today,
      ),
    );
    service.requests.last.complete(const []);
    await tester.pumpAndSettle();
    await _chooseTime(tester, 'week');
    expect(service.requests, hasLength(4));
  });

  testWidgets('new dates clear old rows and reject old progress and results',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final old = service.requests.single;
    old.report(const [_debit]);
    await tester.pump();
    expect(find.text(_debit.name), findsOneWidget);

    await _chooseTime(tester, 'month');
    final current = service.requests.last;
    expect(old.isCancelled, isTrue);
    expect(find.text(_debit.name), findsNothing);
    current.report(const [_current]);
    await tester.pump();
    old.report(const [_stale]);
    old.complete(const [_stale]);
    await tester.pump();
    expect(find.text(_stale.name), findsNothing);
    expect(find.text(_current.name), findsOneWidget);
    expect(find.text('已加载 1 条'), findsNothing);
    expect(_appBarProgress(), findsOneWidget);

    current.complete(const [_current]);
    await tester.pumpAndSettle();
    expect(find.text(_current.name), findsOneWidget);
    expect(find.text('共 1 条'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull refresh replaces a long query using only the pull spinner',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final old = service.requests.single;
    old.report(const [_debit]);
    await tester.pump();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.requests, hasLength(2));
    expect(service.requests.last.range, old.range);
    expect(old.isCancelled, isTrue);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(_appBarProgress(), findsNothing);

    old.complete(const [_stale]);
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    service.requests.last.report(const [_credit]);
    await tester.pump();
    expect(find.text(_credit.name), findsOneWidget);
    expect(find.text('共 1 条'), findsNothing);
    service.requests.last.complete(const [_credit]);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(_appBarProgress(), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed final batch keeps partial records visibly incomplete',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final request = service.requests.single;
    request.report(const [_debit]);
    await tester.pump();
    request.result
        .completeError(const CampusCardException('network', '测试网络错误'));
    await tester.pumpAndSettle();
    expect(find.text(_debit.name), findsOneWidget);
    expect(find.text('已加载 1 条'), findsNothing);
    expect(find.text('共 1 条'), findsNothing);
    expect(find.text('测试网络错误'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('所选日期内暂无记录，可切换日期查询。'), findsNothing);
    expect(_appBarProgress(), findsNothing);

    await tester.tap(find.byKey(const ValueKey('campus-card-history-retry')));
    await tester.pump();
    expect(service.requests, hasLength(2));
    service.requests.last.complete(const [_debit, _credit]);
    await tester.pumpAndSettle();
    expect(find.text('共 2 条'), findsNothing);
    expect(find.text('测试网络错误'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('login failure stays inline and offers another login attempt',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service, onLogin: () async {
      throw StateError('login failed');
    });
    service.requests.single.result
        .completeError(const CampusCardAuthRequiredException());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('campus-card-history-retry')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法完成登录，请稍后重试'), findsOneWidget);
    expect(find.text('登录校园账户'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull failure and cancelled login do not show a snackbar',
      (tester) async {
    final service = _HistoryService();
    var loginCalls = 0;
    await _pumpPage(tester, service, onLogin: () async {
      loginCalls++;
      return false;
    });
    service.requests.single.complete(const [_debit]);
    await tester.pumpAndSettle();

    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.requests.last.result
        .completeError(const CampusCardException('network', '测试网络错误'));
    await tester.pumpAndSettle();
    expect(find.text('测试网络错误'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.requests.last.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pumpAndSettle();
    expect(loginCalls, 1);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    expect(find.text('登录校园账户'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('months pin in order and the next month replaces the old header',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service, viewport: const Size(402, 844));
    service.requests.single.complete([
      for (var index = 0; index < 30; index++)
        CampusCardBill(
          name: '七月记录 $index',
          payTime: DateTime(2026, 7, 30 - index, 12).toString(),
          amount: 1,
        ),
      for (var index = 0; index < 30; index++)
        CampusCardBill(
          name: '六月记录 $index',
          payTime: DateTime(2026, 6, 30 - index, 12).toString(),
          amount: 1,
        ),
    ]);
    await tester.pumpAndSettle();
    final scroll = find.byType(CustomScrollView);
    final july = find.byKey(const ValueKey('campus-card-month-2026-07'));
    final june = find.byKey(const ValueKey('campus-card-month-2026-06'));

    await tester.drag(scroll, const Offset(0, -180));
    await tester.pumpAndSettle();
    final pinnedTop = tester.getTopLeft(july).dy;
    expect(pinnedTop, closeTo(tester.getTopLeft(scroll).dy, 1));
    await tester.drag(scroll, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(july).dy, closeTo(pinnedTop, 1));

    await tester.scrollUntilVisible(
      find.text('六月记录 0'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(scroll, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(june).dy, closeTo(pinnedTop, 1));
    await tester.drag(scroll, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(june).dy, closeTo(pinnedTop, 1));

    await _chooseTab(tester, 'credit');
    expect(
      tester.widget<CustomScrollView>(scroll).controller!.offset,
      0,
    );
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sorting keeps identical records and groups unknown dates safely',
      (tester) async {
    const july = CampusCardBill(
      name: '七月重复记录',
      payTime: '2026-07-25 12:00:00',
      amount: 1,
    );
    const june = CampusCardBill(
      name: '六月较早记录',
      payTime: '2026-06-25 12:00:00',
      amount: 1,
    );
    const unknown = CampusCardBill(
      name: '异常日期原文',
      payTime: 'not-a-date',
      amount: 1,
    );
    final service = _HistoryService();
    await _pumpPage(tester, service, viewport: const Size(402, 1200));
    service.requests.single.complete(const [unknown, june, july, july]);
    await tester.pumpAndSettle();
    expect(find.text(july.name), findsNWidgets(2));
    expect(find.text('日期未知'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(june.name)).dy,
      greaterThan(tester.getTopLeft(find.text(july.name).last).dy),
    );
    expect(
      tester.getTopLeft(find.text(unknown.name)).dy,
      greaterThan(tester.getTopLeft(find.text(june.name)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account mismatch clears partial rows and stops the old query',
      (tester) async {
    final service = _HistoryService();
    await _pumpPage(tester, service);
    final request = service.requests.single;
    request.report(const [_debit]);
    await tester.pump();
    request.result.completeError(
        const CampusCardException('accountMismatch', '校园账户已切换，请重新登录'));
    await tester.pumpAndSettle();
    expect(request.isCancelled, isTrue);
    expect(find.text(_debit.name), findsNothing);
    expect(find.text('已加载 1 条'), findsNothing);
    expect(find.text('登录校园账户'), findsOneWidget);
    request.report(const [_stale]);
    await tester.pump();
    expect(find.text(_stale.name), findsNothing);
    expect(_appBarProgress(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('throwing auth notifications retain a usable login action',
      (tester) async {
    final service = _HistoryService();
    var notifications = 0;
    await _pumpPage(tester, service, onAuthRequired: (_) async {
      notifications++;
      throw StateError('host notification failed');
    });
    service.requests.single.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pumpAndSettle();
    expect(notifications, 1);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    final retry = find.byKey(const ValueKey('campus-card-history-retry'));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    expect(_appBarProgress(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale auth cannot trigger login after a new range succeeds',
      (tester) async {
    final service = _HistoryService();
    final pendingAuth = Completer<void>();
    var loginCalls = 0;
    await _pumpPage(tester, service,
        onAuthRequired: (_) => pendingAuth.future,
        onLogin: () async {
          loginCalls++;
          return false;
        });
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    await _chooseTime(tester, 'year');
    final stale = service.requests.last;
    stale.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pump();

    await _chooseTime(tester, 'month');
    service.requests.last.complete(const [_current]);
    await tester.pumpAndSettle();
    pendingAuth.complete();
    await tester.pumpAndSettle();
    expect(stale.isCancelled, isTrue);
    expect(loginCalls, 0);
    expect(find.text(_current.name), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('登录已失效，请重新登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit login waits for pending notifications and retires pull',
      (tester) async {
    final service = _HistoryService();
    final pendingAuth = Completer<void>();
    var loginCalls = 0;
    await _pumpPage(tester, service,
        onAuthRequired: (_) => pendingAuth.future,
        onLogin: () async {
          loginCalls++;
          return false;
        });
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final request = service.requests.last;
    request.result.completeError(const CampusCardAuthRequiredException());
    await tester.pump();
    final retry = find.byKey(const ValueKey('campus-card-history-retry'));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.tap(retry);
    await tester.pump();
    expect(loginCalls, 0);
    expect(request.isCancelled, isTrue);

    pendingAuth.complete();
    await tester.pumpAndSettle();
    expect(loginCalls, 1);
    expect(service.requests, hasLength(2));
    expect(find.byType(SnackBar), findsNothing,
        reason: 'the old pull must not surface its stale error after login');
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large month labels fit inside their pinned header',
      (tester) async {
    final service = _HistoryService();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
        child: child!,
      ),
      home: CampusCardHistoryPage(
        serviceFactory: () => service,
        onLogin: () async => false,
      ),
    ));
    await tester.pump();
    service.requests.single.complete(const [_debit]);
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('campus-card-month-2026-10'));
    final label = find.descendant(of: header, matching: find.text('2026年10月'));
    final bounds = tester.getRect(header);
    final textBounds = tester.getRect(label);
    expect(bounds.height, greaterThan(38));
    expect(textBounds.top, greaterThanOrEqualTo(bounds.top));
    expect(textBounds.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached month headers follow theme changes without scrolling',
      (tester) async {
    final service = _HistoryService();
    addTearDown(service.dispose);
    final dark = ShuYoThemes.byId(ShuYoThemes.systemDarkId).themeData();
    final light = ShuYoThemes.byId(ShuYoThemes.defaultId).themeData();
    final theme = ValueNotifier(dark);
    addTearDown(theme.dispose);
    await tester.pumpWidget(ValueListenableBuilder<ThemeData>(
      valueListenable: theme,
      builder: (context, current, child) => MaterialApp(
        theme: current,
        home: CampusCardHistoryPage(
          serviceFactory: () => service,
          onLogin: () async => false,
        ),
      ),
    ));
    await tester.pump();
    service.requests.single.complete(const [_debit]);
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('campus-card-month-2026-10'));
    expect(tester.widget<Material>(header).color, dark.scaffoldBackgroundColor);

    theme.value = light;
    await tester.pumpAndSettle();
    expect(
        tester.widget<Material>(header).color, light.scaffoldBackgroundColor);
    final label = find.descendant(of: header, matching: find.text('2026年10月'));
    expect(tester.widget<Text>(label).style?.color,
        light.extension<ShuYoColors>()!.textSecondary);
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing history cancels requests and ignores late callbacks',
      (tester) async {
    final service = _HistoryService();
    var notifications = 0;
    await _pumpPage(tester, service, onAuthRequired: (_) async {
      notifications++;
    });
    final request = service.requests.single;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(request.isCancelled, isTrue);
    request.report(const [_stale]);
    request.result.completeError(const CampusCardAuthRequiredException());
    await tester.pumpAndSettle();
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _HistoryService service, {
  Future<bool> Function()? onLogin,
  Future<void> Function(CampusCardAuthRequiredException)? onAuthRequired,
  Size viewport = const Size(402, 1000),
  CampusCardInfo? initialCard,
  DateTime? initialQueriedAt,
  Future<CampusCardInfo> Function()? fetchCardInfo,
}) async {
  addTearDown(service.dispose);
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
    home: CampusCardHistoryPage(
      serviceFactory: () => service,
      onLogin: onLogin ?? () async => false,
      onAuthRequired: onAuthRequired,
      initialCard: initialCard,
      initialQueriedAt: initialQueriedAt,
      fetchCardInfo: fetchCardInfo,
    ),
  ));
  await tester.pump();
}

Finder _appBarProgress() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(LinearProgressIndicator),
    );

void _expectProgressAboveTabs(WidgetTester tester) {
  final progress = tester.getRect(_appBarProgress());
  final tabs = tester.getRect(find.byType(TabBar));
  final appBar = tester.getRect(find.byType(AppBar));
  expect(progress.height, 3);
  expect(progress.bottom, tabs.top);
  expect(tabs.bottom, appBar.bottom);
}

Future<void> _chooseTime(WidgetTester tester, String preset) async {
  await tester.tap(find.byKey(const ValueKey('campus-card-time-filter')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  expect(find.byKey(const ValueKey('campus-card-time-menu')), findsOneWidget);
  await tester.tap(find.byKey(ValueKey('campus-card-time-$preset')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _chooseTab(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(ValueKey('campus-card-history-tab-$tab')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

DateTime _monthsAgo(DateTime day, int months) {
  final target = DateTime(day.year, day.month - months);
  final lastDay = DateUtils.getDaysInMonth(target.year, target.month);
  return DateTime(
    target.year,
    target.month,
    day.day > lastDay ? lastDay : day.day,
  );
}

class _HistoryService extends CampusCardService {
  final requests = <_BillRequest>[];

  @override
  Future<List<CampusCardBill>> fetchBills({
    required DateTime startDate,
    required DateTime endDate,
    void Function(List<CampusCardBill>)? onProgress,
    bool Function()? shouldCancel,
  }) {
    final request = _BillRequest(
      range: DateTimeRange(start: startDate, end: endDate),
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    requests.add(request);
    return request.result.future;
  }
}

class _BillRequest {
  _BillRequest({
    required this.range,
    required this.onProgress,
    required this.shouldCancel,
  });

  final DateTimeRange range;
  final void Function(List<CampusCardBill>)? onProgress;
  final bool Function()? shouldCancel;
  final result = Completer<List<CampusCardBill>>();

  bool get isCancelled => shouldCancel?.call() ?? false;
  void report(List<CampusCardBill> bills) => onProgress?.call(bills);
  void complete(List<CampusCardBill> bills) => result.complete(bills);
}
