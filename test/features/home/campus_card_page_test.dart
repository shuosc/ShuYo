import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/models/campus_card.dart';
import 'package:shuyo/data/models/campus_card_snapshot.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/campus_card_cache.dart';
import 'package:shuyo/data/services/campus_card_service.dart';
import 'package:shuyo/data/services/secure_app_store.dart';
import 'package:shuyo/features/home/campus_card_bill_list.dart';
import 'package:shuyo/features/home/campus_card_history_page.dart';
import 'package:shuyo/features/home/campus_card_page.dart';
import 'package:shuyo/features/home/campus_card_spending_chart.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _card = CampusCardInfo(
  studentId: 'TEST-IDENTITY-999',
  name: '不应展示的姓名',
  status: '不应展示的卡片状态',
  balance: 128.50,
  validUntil: '2099-12-31',
);

const _firstBill = CampusCardBill(
  name: '第一批消费',
  payTime: '2026-10-20 12:00:00',
  amount: 3.50,
);
const _secondBill = CampusCardBill(
  name: '第二批消费',
  payTime: '2026-10-19 12:00:00',
  amount: 4.50,
);
const _currentBill = CampusCardBill(
  name: '当前范围消费',
  payTime: '2026-10-20 13:00:00',
  amount: 2.50,
);
const _staleProgressBill = CampusCardBill(
  name: '迟到的旧范围进度',
  payTime: '2025-10-20 12:00:00',
  amount: 1,
);
const _staleResultBill = CampusCardBill(
  name: '迟到的旧范围结果',
  payTime: '2025-10-19 12:00:00',
  amount: 1,
);

const _chartBill = CampusCardBill(
  name: '独立图表消费',
  payTime: '2026-10-26 12:00:00',
  amount: 6,
);
const _updatedChartBill = CampusCardBill(
  name: '刷新后的图表消费',
  payTime: '2026-10-27 12:00:00',
  amount: 8,
);

void main() {
  testWidgets(
      'reopening shows the completed snapshot before new requests finish',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: _card.studentId,
    });
    final cache = CampusCardCache()..selectAccount(_card.studentId);
    final first = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, first,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    first.requests.single.complete(const [_firstBill]);
    first.chartRequests.single.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    expect(cache.snapshot!.recent!.balances, [128.5]);
    final originalEndDate = cache.snapshot!.chart!.endDate;

    await tester.pumpWidget(const SizedBox.shrink());
    final pendingCard = Completer<CampusCardInfo>();
    final second = _ControlledCampusCardService(
        pendingCard: pendingCard, pendingChart: true);
    await _pumpPage(tester, second,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(_spendingChart(tester).bills, [_chartBill]);
    expect(_spendingChart(tester).endDate, originalEndDate);
    expect(_appBarProgress(), findsOneWidget);

    // Even a final ledger waits for its own balance before replacing old rows.
    second.requests.single.report(const [_currentBill, _firstBill]);
    second.requests.single.complete(const [_currentBill, _firstBill]);
    second.chartRequests.single.complete(const [_updatedChartBill]);
    await tester.pump();
    expect(find.text(_currentBill.name), findsNothing);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(cache.snapshot!.recent!.bills, [_firstBill]);
    expect(_spendingChart(tester).bills, [_updatedChartBill]);

    pendingCard.complete(const CampusCardInfo(
        studentId: 'TEST-IDENTITY-999',
        name: '',
        status: '',
        balance: 200,
        validUntil: ''));
    await tester.pumpAndSettle();
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.text('余额 ¥200.00'), findsOneWidget);
    expect(find.text('余额 ¥202.50'), findsOneWidget);
    expect(cache.snapshot!.recent!.balances, [200, 202.5]);
    expect(cache.snapshot!.recent!.balance!.balance, 200);
    expect(_appBarProgress(), findsNothing);
  });

  testWidgets('a new cache instance restores disk data and its original dates',
      (tester) async {
    final original = await _seedCampusCardCache();
    final cache = CampusCardCache()..selectAccount(_card.studentId);
    expect(cache.snapshot, isNull);
    final service = _ControlledCampusCardService(
        pendingCard: Completer<CampusCardInfo>(), pendingChart: true);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(_spendingChart(tester).bills!.single.name, _chartBill.name);
    expect(_spendingChart(tester).endDate, original.snapshot!.chart!.endDate);
    expect(DateUtils.isSameDay(_spendingChart(tester).endDate, DateTime.now()),
        isFalse);
    expect(find.byKey(const ValueKey('campus-card-chart-updated-at')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('campus-card-bills-updated-at')),
        findsOneWidget);
  });

  testWidgets(
      'reopening after disk hydration never replays the old disk result',
      (tester) async {
    await _seedCampusCardCache();
    final cache = CampusCardCache()..selectAccount(_card.studentId);
    await cache.load();
    final first = _ControlledCampusCardService();
    await _pumpPage(tester, first,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    first.requests.single.complete(const [_currentBill]);
    await tester.pumpAndSettle();
    expect(find.text(_currentBill.name), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final second = _ControlledCampusCardService(
        pendingCard: Completer<CampusCardInfo>(), pendingChart: true);
    await _pumpPage(tester, second,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    await tester.pump();
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.text(_firstBill.name), findsNothing);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
  });

  testWidgets('late disk hydration cannot replace any fresh on-screen section',
      (tester) async {
    final saved = await _seedCampusCardCache();
    final raw = jsonEncode(saved.snapshot!.toJson());
    final store = _DelayedCampusCardStore();
    final cache = CampusCardCache(
        store: store, accountIdLoader: () async => _card.studentId)
      ..selectAccount(_card.studentId);
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    service.requests.single.complete(const [_currentBill]);
    await tester.pumpAndSettle();
    expect(find.text(_currentBill.name), findsOneWidget);
    store.readResult.complete(raw);
    await tester.pumpAndSettle();
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.text(_firstBill.name), findsNothing);
    expect(_spendingChart(tester).bills, isEmpty);
    expect(cache.snapshot!.recent!.bills.single.name, _currentBill.name);
    expect(cache.snapshot!.chart!.bills, isEmpty);
  });

  testWidgets(
      'failed refreshes retain all cached sections with concise feedback',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final snapshot = cache.snapshot;
    final pendingCard = Completer<CampusCardInfo>();
    final service = _ControlledCampusCardService(
        pendingCard: pendingCard, pendingChart: true);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    pendingCard.completeError(StateError('private balance diagnostic'));
    service.requests.single.result
        .completeError(StateError('private ledger diagnostic'));
    service.chartRequests.single.result
        .completeError(StateError('private chart diagnostic'));
    await tester.pumpAndSettle();
    expect(find.text('刷新失败'), findsNWidgets(3));
    expect(find.textContaining('当前显示上次数据'), findsNothing);
    expect(find.textContaining('private'), findsNothing);
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('campus-card-chart-plot')), findsOneWidget);
    expect(cache.snapshot, same(snapshot));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('partial and empty progress cannot replace a completed snapshot',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final original = cache.snapshot!.recent;
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    final request = service.requests.single;
    request.report(const [_currentBill]);
    await tester.pump();
    request.report(const []);
    await tester.pump();
    expect(find.text(_currentBill.name), findsNothing);
    expect(find.text(_firstBill.name), findsOneWidget);
    request.result.completeError(StateError('failed last batch'));
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(cache.snapshot!.recent, same(original));
  });

  testWidgets('successful empty responses replace nonempty cached sections',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    service.requests.single.complete(const []);
    service.chartRequests.single.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsNothing);
    expect(find.text('近一年暂无记录，可前往历史记录选择其他日期。'), findsOneWidget);
    expect(cache.snapshot!.recent!.bills, isEmpty);
    expect(cache.snapshot!.recent!.balances, isEmpty);
    expect(cache.snapshot!.chart!.bills, isEmpty);
  });

  testWidgets(
      'new ledger never inherits cached row balances after card failure',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final pendingCard = Completer<CampusCardInfo>();
    final service = _ControlledCampusCardService(pendingCard: pendingCard);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    pendingCard.completeError(StateError('balance unavailable'));
    service.requests.single.complete(const [_firstBill]);
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text('余额 ¥128.50'), findsNothing);
    expect(find.text('余额 —'), findsOneWidget);
    expect(cache.snapshot!.recent!.balances, [null]);
    expect(cache.snapshot!.recent!.balance, isNull);
  });

  testWidgets('account mismatch clears cached data and ignores late results',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final pendingCard = Completer<CampusCardInfo>();
    final service = _ControlledCampusCardService(
        pendingCard: pendingCard, pendingChart: true);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    pendingCard.completeError(
        const CampusCardException('accountMismatch', 'private identity'));
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsNothing);
    expect(find.text('¥ 128.50'), findsNothing);
    expect(cache.snapshot, isNull);
    expect(service.requests.single.isCancelled, isTrue);
    expect(service.chartRequests.single.isCancelled, isTrue);
    service.requests.single.complete(const [_staleResultBill]);
    service.chartRequests.single.complete(const [_updatedChartBill]);
    await tester.pumpAndSettle();
    expect(cache.snapshot, isNull);
    expect(
        (await SharedPreferences.getInstance())
            .getString(SecureAppStore.campusCardSnapshotKey),
        isNull);
  });

  testWidgets(
      'disposing does not save progress or results from retired requests',
      (tester) async {
    final cache = await _seedCampusCardCache();
    final snapshot = cache.snapshot;
    final pendingCard = Completer<CampusCardInfo>();
    final service = _ControlledCampusCardService(
        pendingCard: pendingCard, pendingChart: true);
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    service.requests.single.report(const [_currentBill]);
    await tester.pumpWidget(const SizedBox.shrink());
    pendingCard.complete(_card);
    service.requests.single.complete(const [_staleResultBill]);
    service.chartRequests.single.complete(const [_updatedChartBill]);
    await tester.pumpAndSettle();
    expect(cache.snapshot, same(snapshot));
    expect(tester.takeException(), isNull);
  });

  testWidgets('first-visit partial rows are visible but are not cached',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AcademicAccountStore.studentIdKey: _card.studentId,
    });
    final cache = CampusCardCache()..selectAccount(_card.studentId);
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service,
        cache: cache, initialCard: null, viewport: const Size(402, 1500));
    service.requests.single.report(const [_firstBill]);
    await tester.pump();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(cache.snapshot!.recent, isNull);
    service.requests.single.result
        .completeError(StateError('failed last batch'));
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(cache.snapshot!.recent, isNull);
  });

  test('running balances reverse debits and credits without losing cents', () {
    const bills = [
      CampusCardBill(name: '充值', payTime: '2026-10-22 12:00:00', amount: -10),
      CampusCardBill(name: '消费', payTime: '2026-10-21 12:00:00', amount: 3.5),
      CampusCardBill(name: '消费2', payTime: '2026-10-20 12:00:00', amount: 0.1),
    ];
    expect(
        campusCardBalances(bills,
            currentBalance: 100, balanceTime: DateTime(2026, 10, 23)),
        [100, 90, 93.5]);
    expect(
        campusCardBalances(bills,
            currentBalance: 100, balanceTime: DateTime(2026, 10, 22)),
        [null, 100, 103.5]);
    const tied = [
      CampusCardBill(name: '甲', payTime: '2026-10-22 12:00:00', amount: 2),
      CampusCardBill(name: '乙', payTime: '2026-10-22 12:00:00', amount: -5),
      CampusCardBill(name: '丙', payTime: '2026-10-21 12:00:00', amount: 1),
    ];
    expect(
        campusCardBalances(tied,
            currentBalance: 100, balanceTime: DateTime(2026, 10, 23)),
        [null, null, 97]);
    expect(
        campusCardBalances(
            const [CampusCardBill(name: '未知', payTime: 'invalid', amount: 2)],
            currentBalance: 100, balanceTime: DateTime(2026, 10, 23)),
        [null]);
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
        'bill amount is centered alongside name and time at $textScale×',
        (tester) async {
      const bill = CampusCardBill(
        name: '一条很长的校园卡消费记录名称',
        payTime: '2026-10-20 12:00:00',
        amount: 1234.50,
      );
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
              child:
                  SizedBox(width: 280, child: CampusCardBillRow(bill: bill))),
        ),
      ));
      final row = find.byType(CampusCardBillRow);
      final amount = find.text('- ¥1234.50');
      final balance = find.text('余额 —');
      final rightColumnCenter =
          (tester.getTopLeft(amount).dy + tester.getBottomLeft(balance).dy) / 2;
      expect(rightColumnCenter, closeTo(tester.getCenter(row).dy, 0.01));
      expect(tester.getTopRight(amount).dx,
          closeTo(tester.getTopRight(row).dx, 0.01));
      expect(find.text(bill.name), findsOneWidget);
      expect(find.text(bill.payTime), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'home preview shows post-transaction balances under larger amounts',
      (tester) async {
    const credit =
        CampusCardBill(name: '充值', payTime: '2026-10-21 12:00:00', amount: -10);
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service, viewport: const Size(402, 1500));
    service.requests.single.complete(const [_firstBill, credit]);
    await tester.pumpAndSettle();
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(find.text('余额 ¥118.50'), findsOneWidget);
    expect(find.text('+ ¥10.00'), findsOneWidget);
    final amount = tester.widget<Text>(find.text('- ¥3.50'));
    final balance = tester.widget<Text>(find.text('余额 ¥118.50'));
    final colors = ShuYoThemes.byId(ShuYoThemes.defaultId).colors;
    expect(amount.style!.fontSize, 17);
    expect(balance.style!.fontSize, 12);
    expect(balance.style!.color, colors.textTertiary);
  });

  testWidgets('home refresh keeps its snapshot until the whole ledger loads',
      (tester) async {
    const updated = CampusCardInfo(
      studentId: 'TEST-IDENTITY-999',
      name: '',
      status: '',
      balance: 200,
      validUntil: '',
    );
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service, viewport: const Size(402, 1500));
    service.requests.single.complete(const [_firstBill]);
    await tester.pumpAndSettle();
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    final pendingCard = Completer<CampusCardInfo>();
    service.nextCard = pendingCard;
    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    expect(find.text('余额 —'), findsNothing);
    final request = service.requests.last;
    request.report(const [_currentBill, _firstBill]);
    await tester.pump();
    expect(find.text(_currentBill.name), findsNothing);
    expect(find.text('余额 ¥128.50'), findsOneWidget);

    pendingCard.complete(updated);
    await tester.pump();
    await tester.pump();
    expect(find.text(_currentBill.name), findsNothing);
    expect(find.text('余额 ¥128.50'), findsOneWidget);
    request.complete(const [_currentBill, _firstBill]);
    await tester.pumpAndSettle();
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.text('余额 ¥200.00'), findsOneWidget);
    expect(find.text('余额 ¥202.50'), findsOneWidget);
    expect(find.text('余额 —'), findsNothing);
  });

  testWidgets('year preview streams cumulative rows under the app bar',
      (tester) async {
    final pendingCard = Completer<CampusCardInfo>();
    final service = _ControlledCampusCardService(pendingCard: pendingCard);
    await _pumpPage(tester, service, initialCard: null);

    expect(service.requests, hasLength(1));
    final request = service.requests.single;
    expect(request.range.start, _calendarMonthsAgo(request.range.end, 12));
    expect(DateUtils.isSameDay(request.range.end, DateTime.now()), isTrue);
    expect(find.byKey(const ValueKey('campus-card-time-filter')), findsNothing);
    expect(_appBarProgress(), findsOneWidget);
    expect(tester.getSize(_appBarProgress()).height, 3);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    pendingCard.complete(_card);
    await tester.pump();
    request.report(const [_firstBill]);
    await tester.pump();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(_appBarProgress(), findsOneWidget);

    request.report(const [_firstBill, _secondBill]);
    await tester.pump();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text(_secondBill.name), findsOneWidget);
    expect(_appBarProgress(), findsOneWidget);

    request.complete(const [_firstBill, _secondBill]);
    await tester.pumpAndSettle();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(find.text(_secondBill.name), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the balance header omits account details and refresh action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final service = _ControlledCampusCardService();
      await _pumpPage(tester, service);
      service.requests.single.complete(const []);
      await tester.pumpAndSettle();

      final headers = find.byWidgetPredicate((widget) =>
          widget is Semantics &&
          widget.properties.header == true &&
          widget.child is Text);
      final titles = tester
          .widgetList<Semantics>(headers)
          .map((widget) => (widget.child! as Text).data)
          .toList();
      expect(titles, hasLength(3));
      expect(titles.first, '余额');
      expect(titles.last, '消费记录');
      final balance = find.text('¥ 128.50');
      expect(balance, findsOneWidget);
      expect(tester.widget<Text>(balance).style?.fontSize,
          greaterThanOrEqualTo(32));
      for (final detail in [
        _card.name,
        _card.studentId,
        _card.status,
        _card.validUntil,
        '有效期',
        '查询时间',
      ]) {
        expect(find.textContaining(detail), findsNothing);
      }
      expect(find.bySemanticsLabel(RegExp('卡片状态')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.refresh),
        ),
        findsNothing,
      );
      expect(find.byTooltip('刷新余额和消费记录'), findsNothing);
      expect(
          find.byKey(const ValueKey('campus-card-time-filter')), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('pull refresh interrupts a long query using only its own spinner',
      (tester) async {
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service);
    final oldRequest = service.requests.single;
    oldRequest.report(const [_firstBill]);
    await tester.pump();
    expect(_appBarProgress(), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.requests, hasLength(2));
    expect(service.cardRequestCount, 2);
    expect(oldRequest.isCancelled, isTrue);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    oldRequest.complete(const [_firstBill]);
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    service.requests.last.report(const [_currentBill]);
    await tester.pump();
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    service.requests.last.complete(const [_currentBill]);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('balance time belongs to the last successful balance query',
      (tester) async {
    final pendingCard = Completer<CampusCardInfo>();
    DateTime? actualQueryTime;
    final service = _ControlledCampusCardService(pendingCard: pendingCard);
    await _pumpPage(tester, service,
        onCardUpdated: (_, queriedAt) => actualQueryTime = queriedAt);
    final updateLabel =
        find.byKey(const ValueKey('campus-card-balance-updated-at'));
    expect(tester.widget<Text>(updateLabel).data, '更新时间：2034-05-06 13:47:09');

    pendingCard.complete(_card);
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    String two(int value) => value.toString().padLeft(2, '0');
    final time = actualQueryTime!.toLocal();
    final expected = '更新时间：${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    expect(tester.widget<Text>(updateLabel).data, expected);

    final failedCard = Completer<CampusCardInfo>();
    service.nextCard = failedCard;
    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Text>(updateLabel).data, expected);
    failedCard.completeError(const CampusCardException('network', '余额加载失败'));
    service.requests.last.complete(const []);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(updateLabel).data, expected);
    expect(find.text('刷新失败'), findsOneWidget);
  });

  testWidgets(
      'disposing the page cancels a pending query and ignores late data',
      (tester) async {
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service);
    final request = service.requests.single;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(request.isCancelled, isTrue);
    request.report(const [_staleProgressBill]);
    request.complete(const [_staleResultBill]);
    await tester.pumpAndSettle();

    expect(find.text(_staleProgressBill.name), findsNothing);
    expect(find.text(_staleResultBill.name), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an account mismatch clears balance, ledger and pending chart',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service);
    service.requests.single.complete(const [_firstBill]);
    service.chartRequests.single.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(_spendingChart(tester).bills, [_chartBill]);

    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.requests, hasLength(2));
    expect(service.chartRequests, hasLength(2));
    final request = service.requests.last;
    final oldChart = service.chartRequests.last;
    request.result.completeError(
        const CampusCardException('accountMismatch', '校园账户已切换，请重新登录'));
    await tester.pump();
    expect(request.isCancelled, isTrue);
    expect(oldChart.isCancelled, isTrue);
    expect(find.text('¥ 128.50'), findsNothing);
    expect(find.text(_firstBill.name), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-balance-updated-at')),
        findsNothing);
    expect(_spendingChart(tester).bills, isNull);

    request.report(const [_staleProgressBill]);
    oldChart.report(const [_updatedChartBill]);
    oldChart.complete(const [_updatedChartBill]);
    await tester.pumpAndSettle();
    expect(find.text(_staleProgressBill.name), findsNothing);
    expect(find.text('¥ 128.50'), findsNothing);
    expect(_spendingChart(tester).bills, isNull);
    expect(find.text('登录校园账户'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull refresh reloads the fixed chart window and waits for it',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service);
    final originalRange = service.chartRequests.single.range;
    service.requests.single.complete(const []);
    service.chartRequests.single.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final originalPlotRect = tester.getRect(plot);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.requests, hasLength(2));
    expect(service.chartRequests, hasLength(2));
    expect(service.chartRequests.last.range, originalRange);
    expect(_spendingChart(tester).loading, isTrue);
    expect(_spendingChart(tester).bills, [_chartBill]);
    expect(
        find.byKey(const ValueKey('campus-card-chart-loading')), findsNothing);
    expect(tester.getRect(plot), originalPlotRect);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    service.requests.last.complete(const []);
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget,
        reason: 'chart history is still part of this pull refresh');

    service.chartRequests.last.complete(const [_updatedChartBill]);
    await tester.pumpAndSettle();
    expect(_spendingChart(tester).bills, [_updatedChartBill]);
    expect(_spendingChart(tester).endDate, originalRange.end);
    expect(_spendingChart(tester).loading, isFalse);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('unchanged chart records do not repaint after refresh',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service);
    service.requests.single.complete(const []);
    service.chartRequests.single.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    final plot = find.byKey(const ValueKey('campus-card-chart-plot'));
    final originalPainter = tester.widget<CustomPaint>(plot).painter!;

    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.requests.last.complete(const []);
    service.chartRequests.last.complete([
      CampusCardBill(
          name: _chartBill.name,
          payTime: _chartBill.payTime,
          amount: _chartBill.amount),
    ]);
    await tester.pumpAndSettle();
    final refreshedPainter = tester.widget<CustomPaint>(plot).painter!;
    expect(refreshedPainter.shouldRepaint(originalPainter), isFalse);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('balance refresh failures are shown inline without a snackbar',
      (tester) async {
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service);
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    final pendingCard = Completer<CampusCardInfo>();
    service.nextCard = pendingCard;
    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('¥ 128.50'), findsOneWidget);
    pendingCard.completeError(const CampusCardException('network', '余额加载失败'));
    service.requests.last.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text('¥ 128.50'), findsOneWidget);
    expect(find.text('刷新失败'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled login during refresh does not show a snackbar',
      (tester) async {
    var loginCalls = 0;
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service, onLogin: () async {
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
    service.requests.last.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pumpAndSettle();
    expect(loginCalls, 1);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('throwing auth notifications preserve errors and retry actions',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    var notifications = 0;
    await _pumpPage(
      tester,
      service,
      onAuthRequired: (_) async {
        notifications++;
        throw StateError('host notification failed');
      },
    );
    service.chartRequests.single.result
        .completeError(const CampusCardAuthRequiredException());
    service.requests.single.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pumpAndSettle();

    expect(notifications, 2);
    expect(
      _spendingChart(tester).error,
      isA<CampusCardAuthRequiredException>()
          .having((error) => error.ssoExpired, 'ssoExpired', isFalse),
    );
    expect(_spendingChart(tester).loading, isFalse);
    final chartLogin = find.byKey(const ValueKey('campus-card-chart-retry'));
    expect(chartLogin, findsOneWidget);
    expect(tester.widget<TextButton>(chartLogin).onPressed, isNotNull);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    expect(find.text('登录校园账户'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'external login waits for every auth notification and retires pull',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    final businessAuth = Completer<void>();
    final sharedAuth = Completer<void>();
    final notifications = <bool>[];
    var loginCalls = 0;
    await _pumpPage(
      tester,
      service,
      onAuthRequired: (error) {
        notifications.add(error.ssoExpired);
        return error.ssoExpired ? sharedAuth.future : businessAuth.future;
      },
      onLogin: () async {
        loginCalls++;
        return false;
      },
    );
    service.requests.single.complete(const []);
    service.chartRequests.single.complete(const []);
    await tester.pumpAndSettle();

    final lateCard = Completer<CampusCardInfo>();
    service.nextCard = lateCard;
    unawaited(tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.requests, hasLength(2));
    expect(service.chartRequests, hasLength(2));
    final oldBills = service.requests.last;
    final oldChart = service.chartRequests.last;
    oldChart.result.completeError(const CampusCardAuthRequiredException());
    oldBills.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pump();
    expect(notifications, unorderedEquals([false, true]));

    businessAuth.complete();
    await tester.pump();
    final chartLogin = find.byKey(const ValueKey('campus-card-chart-retry'));
    expect(tester.widget<TextButton>(chartLogin).onPressed, isNotNull);
    await tester.tap(chartLogin);
    await tester.pump();
    expect(loginCalls, 0,
        reason: 'the shared SSO notification is still pending');
    expect(oldBills.isCancelled, isTrue);
    expect(oldChart.isCancelled, isTrue);

    // This third loader belonged to the superseded pull. It must not notify
    // the host again after the user's explicit login action has begun.
    lateCard.completeError(const CampusCardAuthRequiredException());
    await tester.pump();
    expect(notifications, unorderedEquals([false, true]));
    expect(loginCalls, 0);

    sharedAuth.complete();
    await tester.pumpAndSettle();
    expect(loginCalls, 1);
    expect(notifications, unorderedEquals([false, true]));
    expect(find.byType(SnackBar), findsNothing,
        reason: 'the old pull must not report its stale login failure');
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'home shows only the newest five rows with stable duplicate ordering',
      (tester) async {
    const latest =
        CampusCardBill(name: '最新消费', payTime: '2026-09-01 12:00:00', amount: 1);
    const august =
        CampusCardBill(name: '八月消费', payTime: '2026-08-01 12:00:00', amount: 1);
    const firstTwin = CampusCardBill(
        name: '同刻第一笔', payTime: '2026-07-25 12:00:00', amount: 2);
    const secondTwin = CampusCardBill(
        name: '同刻第二笔', payTime: '2026-07-25 12:00:00', amount: 3);
    const older = CampusCardBill(
        name: '超出预览的消费', payTime: '2026-06-12 12:00:00', amount: 4);
    const unknown =
        CampusCardBill(name: '超出预览的未知日期', payTime: 'not-a-date', amount: 1);
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service, viewport: const Size(402, 1500));
    service.requests.single.complete(const [
      older,
      firstTwin,
      august,
      secondTwin,
      latest,
      firstTwin,
      unknown
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(CampusCardBillRow), findsNWidgets(5));
    expect(find.text(firstTwin.name), findsNWidgets(2));
    expect(find.text(older.name), findsNothing);
    expect(find.text(unknown.name), findsNothing);
    expect(find.byType(SliverPersistentHeader), findsNothing);
    expect(find.text('最近 5 条'), findsNothing);
    final rows = tester
        .widgetList<CampusCardBillRow>(find.byType(CampusCardBillRow))
        .toList();
    expect(rows.map((row) => row.bill),
        [latest, august, firstTwin, secondTwin, firstTwin]);
    final history = find.byKey(const ValueKey('campus-card-history'));
    expect(history, findsOneWidget);
    expect(
        tester.getTopLeft(history).dy,
        greaterThanOrEqualTo(
            tester.getBottomLeft(find.byType(CampusCardBillRow).last).dy));
    expect(tester.getCenter(history).dx, greaterThan(201));
    expect(
        find.descendant(
            of: history, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget);
  });

  testWidgets(
      'history opens on a year and its tabs filter locally before return refreshes home',
      (tester) async {
    const recharge = CampusCardBill(
        name: '充值测试', payTime: '2026-10-21 12:00:00', amount: -20);
    const spend =
        CampusCardBill(name: '消费测试', payTime: '2026-10-20 12:00:00', amount: 3);
    final service = _ControlledCampusCardService();
    await _pumpPage(tester, service);
    service.requests.single.complete(const [_firstBill]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('campus-card-time-filter')), findsNothing);

    await _openHistory(tester);
    expect(find.byType(CampusCardHistoryPage), findsOneWidget);
    expect(service.requests, hasLength(2));
    expect(service.cardRequestCount, 2);
    expect(service.chartRequests, hasLength(1));
    final historyRequest = service.requests.last;
    final historyEnd = historyRequest.range.end;
    expect(historyRequest.range.start,
        DateTime(historyEnd.year, historyEnd.month, historyEnd.day - 6));
    expect(find.byTooltip('消费时间：近一周'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('campus-card-time-filter')), findsOneWidget);
    historyRequest.complete(const [recharge, spend]);
    await tester.pumpAndSettle();

    for (final label in ['充值', '消费', '全部']) {
      await tester.tap(find.widgetWithText(Tab, label));
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(2));
      expect(service.chartRequests, hasLength(1));
      if (label == '充值') {
        expect(find.text(recharge.name), findsOneWidget);
        expect(find.text(spend.name), findsNothing);
      } else if (label == '消费') {
        expect(find.text(recharge.name), findsNothing);
        expect(find.text(spend.name), findsOneWidget);
      }
    }
    expect(find.text(recharge.name), findsOneWidget);
    expect(find.text(spend.name), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.cardRequestCount, 3);
    expect(service.requests, hasLength(3));
    expect(service.chartRequests, hasLength(2));
    service.requests.last.complete(const [_currentBill]);
    await tester.pumpAndSettle();
    expect(find.byType(CampusCardHistoryPage), findsNothing);
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.text(_firstBill.name), findsNothing);
    expect(find.byKey(const ValueKey('campus-card-time-filter')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening history retires home card chart and preview requests',
      (tester) async {
    final pendingCard = Completer<CampusCardInfo>();
    final updates = <CampusCardInfo>[];
    final service = _ControlledCampusCardService(
        pendingCard: pendingCard, pendingChart: true);
    await _pumpPage(tester, service,
        onCardUpdated: (card, _) => updates.add(card));
    final oldBills = service.requests.single;
    final oldChart = service.chartRequests.single;
    oldBills.report(const [_firstBill]);
    await tester.pump();

    await _openHistory(tester);
    expect(oldBills.isCancelled, isTrue);
    expect(oldChart.isCancelled, isTrue);
    expect(service.requests, hasLength(2));
    service.requests.last.complete(const [_currentBill]);
    oldBills.report(const [_staleProgressBill]);
    oldBills.complete(const [_staleResultBill]);
    oldChart.complete(const [_updatedChartBill]);
    pendingCard.complete(const CampusCardInfo(
        studentId: 'OLD-IDENTITY',
        name: '',
        status: '',
        balance: 999,
        validUntil: ''));
    await tester.pumpAndSettle();

    expect(updates, isEmpty);
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(
        find.text(_staleProgressBill.name, skipOffstage: false), findsNothing);
    expect(find.text(_staleResultBill.name, skipOffstage: false), findsNothing);
    expect(find.text('¥ 999.00', skipOffstage: false), findsNothing);
    final hiddenChart = tester.widget<CampusCardSpendingChart>(
        find.byType(CampusCardSpendingChart, skipOffstage: false));
    expect(hiddenChart.bills, isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a stale home auth notification cannot log in over the history route',
      (tester) async {
    final service = _ControlledCampusCardService();
    final pendingAuth = Completer<void>();
    var authCalls = 0;
    var loginCalls = 0;
    await _pumpPage(tester, service, onAuthRequired: (_) {
      authCalls++;
      return pendingAuth.future;
    }, onLogin: () async {
      loginCalls++;
      return false;
    });
    final stale = service.requests.single;
    stale.result
        .completeError(const CampusCardAuthRequiredException(ssoExpired: true));
    await tester.pump();
    expect(authCalls, 1);

    await _openHistory(tester);
    expect(stale.isCancelled, isTrue);
    service.requests.last.complete(const [_currentBill]);
    await tester.pumpAndSettle();
    pendingAuth.complete();
    await tester.pumpAndSettle();
    expect(authCalls, 1);
    expect(loginCalls, 0);
    expect(find.text(_currentBill.name), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'chart range changes use local chart data without querying the preview',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service);
    final chartRequest = service.chartRequests.single;
    final end = chartRequest.range.end;
    expect(
        chartRequest.range.start, DateTime(end.year, end.month, end.day - 29));
    service.requests.single.complete(const [_firstBill]);
    chartRequest.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    for (final days in [30, 7]) {
      await tester.tap(find.byKey(ValueKey('campus-card-chart-range-$days')));
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      expect(service.chartRequests, hasLength(1));
      expect(_spendingChart(tester).bills, [_chartBill]);
      expect(_spendingChart(tester).endDate, end);
      expect(find.text(_firstBill.name), findsOneWidget);
      expect(
          find.byKey(const ValueKey('campus-card-time-filter')), findsNothing);
    }
  });

  testWidgets(
      'a pending chart does not block the preview and is cancelled on disposal',
      (tester) async {
    final service = _ControlledCampusCardService(pendingChart: true);
    await _pumpPage(tester, service);
    final chartRequest = service.chartRequests.single;
    service.requests.single.complete(const [_firstBill]);
    await tester.pump();
    expect(find.text(_firstBill.name), findsOneWidget);
    expect(_appBarProgress(), findsOneWidget);
    expect(_spendingChart(tester).loading, isTrue);
    expect(chartRequest.isCancelled, isFalse);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(chartRequest.isCancelled, isTrue);
    chartRequest.report(const [_chartBill]);
    chartRequest.complete(const [_chartBill]);
    await tester.pumpAndSettle();
    expect(find.byType(CampusCardSpendingChart), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final themeId in [ShuYoThemes.defaultId, 'ink_teal']) {
    testWidgets(
        'recharge uses theme colors and the external campus card URI in $themeId',
        (tester) async {
      final launches = <MethodCall>[];
      _mockUrlLauncher(tester, (call) async {
        launches.add(call);
        return true;
      });
      final service = _ControlledCampusCardService();
      await _pumpPage(tester, service, themeId: themeId);
      service.requests.single.complete(const []);
      await tester.pumpAndSettle();
      final finder = find.byKey(const ValueKey('campus-card-recharge'));
      final button = tester.widget<FilledButton>(finder);
      final colors = tester.element(finder).shuyoColors;
      expect(button.style?.backgroundColor?.resolve(const <WidgetState>{}),
          colors.accent);
      expect(button.style?.foregroundColor?.resolve(const <WidgetState>{}),
          colors.onAccent);
      expect(
          find.descendant(of: finder, matching: find.byIcon(Icons.open_in_new)),
          findsOneWidget);
      expect(find.descendant(of: finder, matching: find.text('充值')),
          findsOneWidget);
      expect(tester.getCenter(finder).dx,
          greaterThan(tester.getCenter(find.text('¥ 128.50')).dx));
      // The balance can wrap at large text scales (or with the test font).
      // Keep the button aligned with its first line, above the update time.
      expect(tester.getCenter(finder).dy,
          closeTo(tester.getTopLeft(find.text('¥ 128.50')).dy + 25, 1));

      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(launches, hasLength(1));
      expect(launches.single.method, 'launch');
      final arguments = launches.single.arguments as Map<dynamic, dynamic>;
      final uri = Uri.parse(arguments['url'] as String);
      expect(uri.scheme, 'wxwork');
      expect(uri.host, 'jump');
      expect(uri.queryParameters, {
        'target': 'jump_to_third_app',
        'businessid': '5629500339709576',
      });
      expect(arguments['useSafariVC'], isFalse);
      expect(arguments['useWebView'], isFalse);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<FilledButton>(finder).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platformThrows in [false, true]) {
    testWidgets(
        'recharge launch failure reports a manual path (throws=$platformThrows)',
        (tester) async {
      var launchCalls = 0;
      _mockUrlLauncher(tester, (call) async {
        expect(call.method, 'launch');
        launchCalls++;
        if (platformThrows) throw PlatformException(code: 'launch_failed');
        return false;
      });
      final service = _ControlledCampusCardService();
      await _pumpPage(tester, service);
      service.requests.single.complete(const []);
      await tester.pumpAndSettle();
      final recharge = find.byKey(const ValueKey('campus-card-recharge'));
      await tester.tap(recharge);
      await tester.pumpAndSettle();

      expect(launchCalls, 1);
      expect(find.text('无法打开企业微信，请安装企业微信后在工作台打开“校园卡”'), findsOneWidget);
      expect(tester.widget<FilledButton>(recharge).onPressed, isNotNull);
      expect(service.cardRequestCount, 1);
      expect(service.requests, hasLength(1));
      expect(service.chartRequests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'recharge deduplicates pending launches independently of card queries and login',
      (tester) async {
    final pendingLaunch = Completer<bool>();
    final pendingCard = Completer<CampusCardInfo>();
    var launchCalls = 0;
    var loginCalls = 0;
    _mockUrlLauncher(tester, (call) async {
      expect(call.method, 'launch');
      launchCalls++;
      return pendingLaunch.future;
    });
    final service = _ControlledCampusCardService(pendingCard: pendingCard);
    await _pumpPage(tester, service, initialCard: null, onLogin: () async {
      loginCalls++;
      return false;
    });
    final recharge = find.byKey(const ValueKey('campus-card-recharge'));
    await tester.tap(recharge);
    await tester.tap(recharge);
    await tester.pump();
    expect(launchCalls, 1);
    expect(tester.widget<FilledButton>(recharge).onPressed, isNull);
    expect(loginCalls, 0);
    expect(service.cardRequestCount, 1);
    expect(service.requests, hasLength(1));
    expect(service.chartRequests, hasLength(1));

    pendingLaunch.complete(true);
    pendingCard.complete(_card);
    service.requests.single.complete(const []);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(recharge).onPressed, isNotNull);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final loggedIn in [true, false]) {
    testWidgets(
        'returning home during history login resumes refresh after result=$loggedIn',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        AcademicAccountStore.studentIdKey: _card.studentId,
      });
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final pendingLogin = Completer<bool>();
      var loginCalls = 0;
      final service = _ControlledCampusCardService(pendingChart: true);
      await _pumpPage(tester, service, onLogin: () {
        loginCalls++;
        return pendingLogin.future;
      });
      service.requests.single.complete(const [_firstBill]);
      service.chartRequests.single.complete(const [_chartBill]);
      await tester.pumpAndSettle();

      await _openHistory(tester);
      expect(service.requests, hasLength(2));
      final historyRequest = service.requests.last;
      historyRequest.result
          .completeError(const CampusCardAuthRequiredException());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('campus-card-history-retry')));
      await tester.pump();
      expect(loginCalls, 1);
      expect(historyRequest.isCancelled, isTrue);

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CampusCardHistoryPage), findsNothing);
      expect(service.cardRequestCount, 2);
      expect(service.requests, hasLength(2));
      expect(service.chartRequests, hasLength(1));
      expect(find.text('¥ 128.50'), findsOneWidget);

      service.nextCard = Completer<CampusCardInfo>()
        ..complete(const CampusCardInfo(
          studentId: 'TEST-IDENTITY-999',
          name: '',
          status: '',
          balance: 256.75,
          validUntil: '',
        ));
      pendingLogin.complete(loggedIn);
      await tester.pump();
      await tester.pump();
      expect(service.cardRequestCount, 3);
      expect(service.requests, hasLength(3));
      expect(service.chartRequests, hasLength(2));
      service.requests.last.complete(const [_currentBill]);
      service.chartRequests.last.complete(const [_updatedChartBill]);
      await tester.pumpAndSettle();

      expect(loginCalls, 1);
      expect(find.text('¥ 256.75'), findsOneWidget);
      expect(find.text('¥ 128.50'), findsNothing);
      expect(find.text(_currentBill.name), findsOneWidget);
      expect(find.text(_firstBill.name), findsNothing);
      expect(_spendingChart(tester).bills, [_updatedChartBill]);
      expect(_spendingChart(tester).loading, isFalse);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<CampusCardCache> _seedCampusCardCache() async {
  SharedPreferences.setMockInitialValues({
    AcademicAccountStore.studentIdKey: _card.studentId,
  });
  final cache = CampusCardCache()..selectAccount(_card.studentId);
  final time = DateTime.now().subtract(const Duration(days: 1));
  await cache.rememberBalance(_card, time, revision: cache.revision);
  await cache.rememberRecent(
    CampusCardRecentSnapshot(
      bills: const [_firstBill],
      balances: const [128.5],
      startDate: DateTime(time.year - 1, time.month, time.day),
      endDate: DateUtils.dateOnly(time),
      queriedAt: time,
      balance: CampusCardBalanceSnapshot(balance: 128.5, queriedAt: time),
    ),
    revision: cache.revision,
  );
  await cache.rememberChart(
    CampusCardChartSnapshot(
        bills: const [_chartBill],
        endDate: DateUtils.dateOnly(time),
        queriedAt: time),
    revision: cache.revision,
  );
  return cache;
}

Future<void> _pumpPage(
  WidgetTester tester,
  _ControlledCampusCardService service, {
  CampusCardInfo? initialCard = _card,
  CampusCardCache? cache,
  String themeId = ShuYoThemes.defaultId,
  void Function(CampusCardInfo, DateTime)? onCardUpdated,
  Future<bool> Function()? onLogin,
  Future<void> Function(CampusCardAuthRequiredException)? onAuthRequired,
  Size? viewport = const Size(402, 1000),
}) async {
  addTearDown(service.dispose);
  if (viewport != null) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ShuYoThemes.byId(themeId).themeData(),
    home: CampusCardPage(
      cache: cache,
      serviceFactory: () => service,
      onLogin: onLogin ?? () async => false,
      onAuthRequired: onAuthRequired,
      onCardUpdated: onCardUpdated,
      initialCard: initialCard,
      initialQueriedAt: DateTime(2034, 5, 6, 13, 47, 9),
    ),
  ));
  await tester.pump();
}

CampusCardSpendingChart _spendingChart(WidgetTester tester) => tester
    .widget<CampusCardSpendingChart>(find.byType(CampusCardSpendingChart));

Finder _appBarProgress() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(LinearProgressIndicator),
    );

Future<void> _openHistory(WidgetTester tester) async {
  final history = find.byKey(const ValueKey('campus-card-history'));
  await tester.ensureVisible(history);
  await tester.pump();
  await tester.tap(history);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _mockUrlLauncher(
  WidgetTester tester,
  Future<Object?> Function(MethodCall) handler,
) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handler);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
}

DateTime _calendarMonthsAgo(DateTime day, int months) {
  final target = DateTime(day.year, day.month - months);
  final lastDay = DateUtils.getDaysInMonth(target.year, target.month);
  return DateTime(
    target.year,
    target.month,
    day.day > lastDay ? lastDay : day.day,
  );
}

class _ControlledCampusCardService extends CampusCardService {
  _ControlledCampusCardService({this.pendingCard, this.pendingChart = false});

  final Completer<CampusCardInfo>? pendingCard;
  Completer<CampusCardInfo>? nextCard;
  final bool pendingChart;
  final requests = <_BillRequest>[];
  final chartRequests = <_BillRequest>[];
  int cardRequestCount = 0;
  int _remainingRefreshQueries = 0;

  @override
  Future<CampusCardInfo> fetchCardInfo() {
    cardRequestCount++;
    _remainingRefreshQueries = 2;
    final next = nextCard;
    nextCard = null;
    return next?.future ?? pendingCard?.future ?? Future.value(_card);
  }

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
    // A full refresh calls card, then transaction history, then chart history.
    // Keep chart identification independent of potentially equal date ranges.
    final isChart = _remainingRefreshQueries == 1;
    if (_remainingRefreshQueries > 0) _remainingRefreshQueries--;
    if (isChart) {
      chartRequests.add(request);
      if (!pendingChart) request.complete(const []);
    } else {
      requests.add(request);
    }
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

  void report(List<CampusCardBill> snapshot) => onProgress?.call(snapshot);

  void complete(List<CampusCardBill> bills) => result.complete(bills);
}

class _DelayedCampusCardStore extends SecureAppStore {
  final readResult = Completer<String?>();

  @override
  Future<String?> read(String key) => readResult.future;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
