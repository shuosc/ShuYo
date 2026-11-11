import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/wecom_constants.dart';
import '../../data/models/campus_card.dart';
import '../../data/models/campus_card_snapshot.dart';
import '../../data/services/academic_account_store.dart';
import '../../data/services/campus_card_service.dart';
import '../../data/services/campus_card_cache.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/navigation/shuyo_route.dart';
import 'campus_card_bill_list.dart';
import 'campus_card_history_page.dart';
import 'campus_card_spending_chart.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({
    super.key,
    required this.onLogin,
    this.serviceFactory,
    this.fetchCardInfo,
    this.initialCard,
    this.initialQueriedAt,
    this.onCardUpdated,
    this.onAuthRequired,
    this.cache,
  });

  final CampusCardCache? cache;
  final Future<bool> Function() onLogin;
  final CampusCardService Function()? serviceFactory;
  final Future<CampusCardInfo> Function()? fetchCardInfo;
  final CampusCardInfo? initialCard;
  final DateTime? initialQueriedAt;
  final void Function(CampusCardInfo, DateTime)? onCardUpdated;
  final Future<void> Function(CampusCardAuthRequiredException)? onAuthRequired;

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  CampusCardService? _ownedService;
  CampusCardService get _service =>
      widget.serviceFactory?.call() ?? (_ownedService ??= CampusCardService());
  static const _recentBillLimit = CampusCardRecentSnapshot.limit;
  bool _historyOpen = false;
  bool _openingRecharge = false;
  final _scrollController = ScrollController();
  late CampusCardInfo? _card = widget.initialCard;
  late DateTime? _cardQueriedAt =
      widget.initialCard == null ? null : widget.initialQueriedAt;
  List<CampusCardBill>? _bills;
  List<CampusCardBill>? _chartBills;
  List<double?>? _billBalances;
  DateTime? _billsQueriedAt;
  DateTime? _chartQueriedAt;
  bool _receivedCardData = false;
  bool _receivedBillsData = false;
  bool _receivedChartData = false;
  DateTime _chartEndDate = DateUtils.dateOnly(DateTime.now());
  Object? _cardError;
  Object? _billsError;
  Object? _chartError;
  bool _loadingCard = true;
  bool _loadingBills = true;
  bool _loadingChart = true;
  bool _loggingIn = false;
  bool _pullRefreshing = false;
  int _refreshRevision = 0;
  int _cardRevision = 0;
  int _billsRevision = 0;
  int _chartRevision = 0;
  Completer<void>? _refreshSuperseded;
  final _authNotifications = <bool, Future<void>>{};
  ({
    List<CampusCardBill>? bills,
    DateTimeRange range,
    DateTime? queriedAt,
    int? cacheRevision,
  })? _pendingBalanceSnapshot;

  @override
  void initState() {
    super.initState();
    _restoreSnapshot(widget.cache?.snapshot);
    unawaited(_restoreCachedSnapshot());
    unawaited(_refresh());
  }

  void _restoreSnapshot(CampusCardSnapshot? snapshot) {
    if (snapshot == null) return;
    final balance = snapshot.balance;
    if (!_receivedCardData &&
        balance != null &&
        (_cardQueriedAt == null ||
            balance.queriedAt.isAfter(_cardQueriedAt!))) {
      _card = balance.toCard(snapshot.studentId);
      _cardQueriedAt = balance.queriedAt;
    }
    final recent = snapshot.recent;
    if (!_receivedBillsData && recent != null) {
      _bills = recent.bills;
      _billBalances = recent.balances;
      _billsQueriedAt = recent.queriedAt;
    }
    final chart = snapshot.chart;
    if (!_receivedChartData && chart != null) {
      _chartBills = chart.bills;
      _chartEndDate = chart.endDate;
      _chartQueriedAt = chart.queriedAt;
    }
  }

  Future<void> _restoreCachedSnapshot() async {
    final cache = widget.cache;
    if (cache == null) return;
    final revision = cache.revision;
    final snapshot = await cache.load();
    if (!mounted || revision != cache.revision) return;
    setState(() => _restoreSnapshot(snapshot));
  }

  @override
  void dispose() {
    _supersedeRefresh();
    _scrollController.dispose();
    _ownedService?.dispose();
    super.dispose();
  }

  // The home preview always queries the past year.
  DateTimeRange get _queryRange {
    final today = DateUtils.dateOnly(DateTime.now());
    final first = DateTime(today.year - 1, today.month);
    final lastDay = DateUtils.getDaysInMonth(first.year, first.month);
    return DateTimeRange(
      start: DateTime(
          first.year, first.month, today.day > lastDay ? lastDay : today.day),
      end: today,
    );
  }

  Object? get _refreshError {
    for (final error in [_cardError, _billsError, _chartError]) {
      if (error is CampusCardAuthRequiredException && error.ssoExpired) {
        return error;
      }
    }
    return _cardError ?? _billsError ?? _chartError;
  }

  void _supersedeRefresh() {
    final pending = _refreshSuperseded;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _notifyAuthRequired(Object error) async {
    if (error is! CampusCardAuthRequiredException) return;
    final pending = _authNotifications[error.ssoExpired];
    if (pending != null) return pending;
    Future<void> notify() async {
      try {
        await widget.onAuthRequired?.call(error);
      } on Object {
        // Preserve the query's error and retry action if the host's account
        // status notification fails. It must not escape an unawaited refresh.
      }
    }

    final notification = notify();
    _authNotifications[error.ssoExpired] = notification;
    try {
      await notification;
    } finally {
      if (identical(_authNotifications[error.ssoExpired], notification)) {
        _authNotifications.remove(error.ssoExpired);
      }
    }
  }

  Future<void> _refresh({
    bool interactive = false,
    bool allowLogin = true,
    bool pullToRefresh = false,
  }) async {
    if (_loggingIn) return;
    _supersedeRefresh();
    final superseded = Completer<void>();
    _refreshSuperseded = superseded;
    final revision = ++_refreshRevision;
    bool isCurrent() => mounted && revision == _refreshRevision;
    setState(() {
      _pullRefreshing = pullToRefresh;
    });
    try {
      await Future.any([
        Future.wait([_loadCard(), _loadBills(), _loadChart()]),
        superseded.future,
      ]);
      if (!isCurrent()) return;
      final error = _refreshError;
      if (error is CampusCardAuthRequiredException) {
        if (interactive && allowLogin && error.ssoExpired) {
          final loggedIn = await _login(refreshAfterLogin: false);
          if (!isCurrent()) return;
          if (!loggedIn) return;
          await Future.any([
            Future.wait([_loadCard(), _loadBills(), _loadChart()]),
            superseded.future,
          ]);
          if (!isCurrent()) return;
        }
      }
    } finally {
      if (isCurrent()) {
        setState(() {
          _pullRefreshing = false;
        });
        _refreshSuperseded = null;
      }
    }
  }

  Future<void> _loadCard() async {
    final revision = ++_cardRevision;
    final cacheRevision = widget.cache?.revision;
    bool isCurrent() =>
        mounted &&
        revision == _cardRevision &&
        (widget.cache == null || cacheRevision == widget.cache!.revision);
    setState(() {
      _loadingCard = true;
      _cardError = null;
    });
    try {
      final card =
          await (widget.fetchCardInfo?.call() ?? _service.fetchCardInfo());
      if (!isCurrent()) return;
      final queriedAt = DateTime.now();
      setState(() {
        _card = card;
        _cardQueriedAt = queriedAt;
        _receivedCardData = true;
      });
      final cache = widget.cache;
      if (cache != null) {
        unawaited(
            cache.rememberBalance(card, queriedAt, revision: cacheRevision!));
      }
      widget.onCardUpdated?.call(card, queriedAt);
    } on Object catch (error) {
      if (isCurrent()) {
        setState(() {
          _cardError = error;
          _clearMismatchedAccount(error);
        });
        await _notifyAuthRequired(error);
      }
    } finally {
      if (isCurrent()) {
        setState(() {
          _loadingCard = false;
          final pending = _pendingBalanceSnapshot;
          _pendingBalanceSnapshot = null;
          if (pending != null) {
            _publishOrStageBills(pending.bills, pending.range,
                queriedAt: pending.queriedAt,
                cacheRevision: pending.cacheRevision);
          }
        });
      }
    }
  }

  Future<void> _loadBills() async {
    final revision = ++_billsRevision;
    final cacheRevision = widget.cache?.revision;
    bool isCurrent() =>
        mounted &&
        revision == _billsRevision &&
        (widget.cache == null || cacheRevision == widget.cache!.revision);
    final range = _queryRange;
    var receivedProgress = false;
    setState(() {
      _loadingBills = true;
      _pendingBalanceSnapshot = null;
      _billsError = null;
    });
    try {
      final bills = await _service.fetchBills(
        startDate: range.start,
        endDate: range.end,
        shouldCancel: () => !isCurrent(),
        onProgress: (bills) {
          if (!isCurrent()) return;
          // Completed snapshots stay on screen until the whole query succeeds.
          // A first visit still streams cumulative progress from recent ranges.
          if (_billsQueriedAt != null) return;
          if (bills.isEmpty && !receivedProgress) return;
          receivedProgress = true;
          _receivedBillsData = true;
          setState(() {
            _publishOrStageBills(
                bills.isEmpty ? null : sortCampusCardBills(bills), range);
          });
        },
      );
      if (!isCurrent()) return;
      setState(() {
        _receivedBillsData = true;
        _publishOrStageBills(sortCampusCardBills(bills), range,
            queriedAt: DateTime.now(), cacheRevision: cacheRevision);
      });
    } on Object catch (error) {
      if (isCurrent()) {
        setState(() {
          _billsError = error;
          _clearMismatchedAccount(error);
        });
        await _notifyAuthRequired(error);
      }
    } finally {
      if (isCurrent()) {
        setState(() => _loadingBills = false);
      }
    }
  }

  void _publishOrStageBills(List<CampusCardBill>? bills, DateTimeRange range,
      {DateTime? queriedAt, int? cacheRevision}) {
    if (_loadingCard) {
      _pendingBalanceSnapshot = (
        bills: bills,
        range: range,
        queriedAt: queriedAt,
        cacheRevision: cacheRevision,
      );
      return;
    }
    final canInferBalance = _card != null &&
        _cardError == null &&
        _cardQueriedAt != null &&
        !DateUtils.dateOnly(_cardQueriedAt!).isAfter(range.end);
    _bills = bills;
    _billBalances = bills == null
        ? null
        : campusCardBalances(bills,
            currentBalance: canInferBalance ? _card!.balance : null,
            balanceTime: _cardQueriedAt);
    if (queriedAt == null || bills == null) return;
    _billsQueriedAt = queriedAt;
    final cache = widget.cache;
    if (cache != null && cacheRevision != null) {
      unawaited(cache.rememberRecent(
        CampusCardRecentSnapshot(
          bills: bills,
          balances: _billBalances!,
          startDate: range.start,
          endDate: range.end,
          queriedAt: queriedAt,
          balance: canInferBalance
              ? CampusCardBalanceSnapshot(
                  balance: _card!.balance, queriedAt: _cardQueriedAt!)
              : null,
        ),
        revision: cacheRevision,
      ));
    }
  }

  Future<void> _loadChart() async {
    final revision = ++_chartRevision;
    final cacheRevision = widget.cache?.revision;
    bool isCurrent() =>
        mounted &&
        revision == _chartRevision &&
        (widget.cache == null || cacheRevision == widget.cache!.revision);
    final today = DateUtils.dateOnly(DateTime.now());
    setState(() {
      _loadingChart = true;
      _chartError = null;
    });
    try {
      // Fetch a fixed window independently of the transaction-list filter.
      // The chart switches between 7 and 30 days using this same snapshot.
      final bills = await _service.fetchBills(
        startDate: DateTime(today.year, today.month, today.day - 29),
        endDate: today,
        shouldCancel: () => !isCurrent(),
      );
      if (!isCurrent()) return;
      setState(() {
        if (!_sameChartBills(_chartBills, bills)) {
          _chartBills = List.unmodifiable(bills);
        }
        _chartEndDate = today;
        _chartQueriedAt = DateTime.now();
        _receivedChartData = true;
      });
      final cache = widget.cache;
      if (cache != null) {
        unawaited(cache.rememberChart(
          CampusCardChartSnapshot(
              bills: _chartBills!, endDate: today, queriedAt: _chartQueriedAt!),
          revision: cacheRevision!,
        ));
      }
    } on Object catch (error) {
      if (isCurrent()) {
        setState(() {
          _chartError = error;
          _clearMismatchedAccount(error);
        });
        await _notifyAuthRequired(error);
      }
    } finally {
      if (isCurrent()) {
        setState(() => _loadingChart = false);
      }
    }
  }

  bool _sameChartBills(
      List<CampusCardBill>? previous, List<CampusCardBill> next) {
    if (previous == null || previous.length != next.length) return false;
    for (var index = 0; index < next.length; index++) {
      final a = previous[index];
      final b = next[index];
      if (a.name != b.name || a.payTime != b.payTime || a.amount != b.amount) {
        return false;
      }
    }
    return true;
  }

  void _clearMismatchedAccount(Object error) {
    if (error is! CampusCardException || error.code != 'accountMismatch') {
      return;
    }
    ++_cardRevision;
    ++_billsRevision;
    ++_chartRevision;
    ++_refreshRevision;
    _supersedeRefresh();
    _pullRefreshing = false;
    _card = null;
    _cardQueriedAt = null;
    _bills = null;
    _chartBills = null;
    _billBalances = null;
    _billsQueriedAt = null;
    _chartQueriedAt = null;
    _pendingBalanceSnapshot = null;
    _loadingCard = false;
    _loadingBills = false;
    _loadingChart = false;
    _cardError = error;
    _billsError = error;
    _chartError = error;
    unawaited(widget.cache?.clear());
  }

  Future<bool> _login({bool refreshAfterLogin = true}) async {
    if (_loggingIn) return false;
    if (refreshAfterLogin) {
      ++_refreshRevision;
      _supersedeRefresh();
    }
    setState(() {
      _loggingIn = true;
      if (refreshAfterLogin) _pullRefreshing = false;
      // Prevent an old request from reporting expiry after login has begun.
      ++_cardRevision;
      ++_billsRevision;
      ++_chartRevision;
      _pendingBalanceSnapshot = null;
      const authRequired = CampusCardAuthRequiredException();
      if (_loadingCard) _cardError ??= authRequired;
      if (_loadingBills) _billsError ??= authRequired;
      if (_loadingChart) _chartError ??= authRequired;
      _loadingCard = false;
      _loadingBills = false;
      _loadingChart = false;
    });
    var loggedIn = false;
    try {
      // Finish any expiry bookkeeping before the host starts a fresh login.
      await Future.wait(_authNotifications.values.toList());
      if (!mounted) return false;
      loggedIn = await widget.onLogin();
      if (loggedIn && mounted) {
        final studentId = await AcademicAccountStore().loadStudentId();
        if (!mounted) return false;
        widget.cache?.selectAccount(studentId);
        if (_card?.studentId != studentId) {
          setState(() {
            ++_cardRevision;
            ++_billsRevision;
            ++_chartRevision;
            _card = null;
            _cardQueriedAt = null;
            _bills = null;
            _chartBills = null;
            _loadingChart = false;
            _billBalances = null;
            _billsQueriedAt = null;
            _chartQueriedAt = null;
            _receivedCardData = false;
            _receivedBillsData = false;
            _receivedChartData = false;
            _pendingBalanceSnapshot = null;
          });
        }
        unawaited(_restoreCachedSnapshot());
      }
    } on Object {
      loggedIn = false;
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
    if (loggedIn && mounted && refreshAfterLogin) {
      await _refresh(interactive: true, allowLogin: false);
    }
    return loggedIn;
  }

  Future<void> _openHistory() async {
    if (_historyOpen || _loggingIn) return;
    // Retire home requests before the history route can start a new login.
    // Otherwise an old home expiry could invalidate that new session.
    _historyOpen = true;
    ++_refreshRevision;
    ++_cardRevision;
    ++_billsRevision;
    ++_chartRevision;
    _pendingBalanceSnapshot = null;
    _supersedeRefresh();
    setState(() {
      _pullRefreshing = false;
      _loadingCard = false;
      _loadingBills = false;
      _loadingChart = false;
    });
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => CampusCardHistoryPage(
          serviceFactory: () => _service,
          onLogin: _loginFromHistory,
          onAuthRequired: widget.onAuthRequired,
          initialCard: _card,
          initialQueriedAt: _cardQueriedAt,
          fetchCardInfo: widget.fetchCardInfo ?? _service.fetchCardInfo,
        ),
      ));
    } finally {
      _historyOpen = false;
      if (mounted) unawaited(_refresh(allowLogin: false));
    }
  }

  Future<bool> _loginFromHistory() async {
    final loggedIn = await _login(refreshAfterLogin: false);
    // The history route may be popped while the host is finishing login. Its
    // return refresh was skipped during login, so resume home loading here.
    if (mounted && !_historyOpen) {
      unawaited(_refresh(allowLogin: false));
    }
    return loggedIn;
  }

  String _errorMessage(Object error) =>
      error is CampusCardAuthRequiredException && error.ssoExpired
          ? '登录已失效，请重新登录'
          : error is CampusCardAuthRequiredException ||
                  error is CampusCardException &&
                      error.code == 'accountMismatch'
              ? '请登录校园账户'
              : '刷新失败';

  Future<void> _openRecharge() async {
    if (_openingRecharge) return;
    setState(() => _openingRecharge = true);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(WeComConstants.campusCardAppScheme),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // The school app remains reachable manually if the OS rejects the URI.
    } finally {
      if (mounted) setState(() => _openingRecharge = false);
    }
    if (!opened && mounted) {
      _showSnack('无法打开企业微信，请安装企业微信后在工作台打开“校园卡”');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showDataInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('校园卡信息说明'),
        content: const Text('数据由学校信息门户提供，可能存在同步延迟。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final bills = _bills;
    final occurrences = <(String, String, double), int>{};
    final billKeys = [
      for (final bill
          in (bills ?? const <CampusCardBill>[]).take(_recentBillLimit))
        ValueKey((
          bill.name,
          bill.payTime,
          bill.amount,
          occurrences.update(
              (bill.name, bill.payTime, bill.amount), (count) => count + 1,
              ifAbsent: () => 0),
        )),
    ];
    final billIndexes = {
      for (var index = 0; index < billKeys.length; index++)
        billKeys[index]: index,
    };
    final balances =
        _billBalances ?? List<double?>.filled(bills?.length ?? 0, null);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('校园卡'),
            Transform.translate(
              offset: const Offset(-3, -0.5),
              child: Opacity(
                opacity: 0.65,
                child: IconButton(
                  tooltip: '校园卡信息说明',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: _showDataInfo,
                ),
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: !_pullRefreshing &&
                  (_loadingCard || _loadingBills || _loadingChart || _loggingIn)
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            if (!_pullRefreshing && !_loggingIn) {
              await _refresh(interactive: true, pullToRefresh: true);
            }
          },
          child: CustomScrollView(
            key: const ValueKey('campus-card-scroll-view'),
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                sliver: SliverList.list(children: [
                  Semantics(
                    header: true,
                    child: Text('余额',
                        style: ShuYoTextStyles.sectionTitle(
                            color: colors.textPrimary)),
                  ),
                  _cardSection(),
                  const SizedBox(height: 24),
                  CampusCardSpendingChart(
                    bills: _chartBills,
                    endDate: _chartEndDate,
                    loading: _loadingChart,
                    error: _chartError,
                    onRetry: _loggingIn
                        ? null
                        : _chartError is CampusCardAuthRequiredException ||
                                _chartError is CampusCardException &&
                                    (_chartError as CampusCardException).code ==
                                        'accountMismatch'
                            ? () => _login()
                            : _loadChart,
                  ),
                  if (_chartQueriedAt != null) ...[
                    const SizedBox(height: 4),
                    _updatedAt(
                        _chartQueriedAt!, 'campus-card-chart-updated-at'),
                  ],
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      '消费记录',
                      style: ShuYoTextStyles.sectionTitle(
                          color: colors.textPrimary),
                    ),
                  ),
                  if (_billsQueriedAt != null) ...[
                    const SizedBox(height: 4),
                    _updatedAt(
                        _billsQueriedAt!, 'campus-card-bills-updated-at'),
                  ],
                  if (!_loadingBills && _billsError != null) ...[
                    const SizedBox(height: 16),
                    _errorSection(_billsError!,
                        onRetry: () => _refresh(interactive: true)),
                  ] else if (!_loadingBills && _bills?.isEmpty == true)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        '近一年暂无记录，可前往历史记录选择其他日期。',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                ]),
              ),
              if (_bills != null)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.separated(
                    itemCount: _bills!.length.clamp(0, _recentBillLimit),
                    findItemIndexCallback: (key) => billIndexes[key],
                    itemBuilder: (context, index) => CampusCardBillRow(
                      key: billKeys[index],
                      bill: _bills![index],
                      balanceAfter: balances[index],
                    ),
                    separatorBuilder: (context, index) =>
                        const CampusCardBillSeparator(),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const ValueKey('campus-card-history'),
                      onPressed: _loggingIn ? null : _openHistory,
                      style: TextButton.styleFrom(
                          foregroundColor: colors.textSecondary),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('查看历史记录'),
                          SizedBox(width: 2),
                          Icon(Icons.chevron_right, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardSection() {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _balanceContent()),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: FilledButton.icon(
              key: const ValueKey('campus-card-recharge'),
              onPressed: _openingRecharge ? null : _openRecharge,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                minimumSize: const Size(0, 40),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                textStyle: ShuYoTextStyles.label(),
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('充值'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _balanceContent() {
    final card = _card;
    if (card == null && !_loadingCard && _cardError != null) {
      return _errorSection(_cardError!,
          onRetry: () => _refresh(interactive: true));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: card == null
              ? '正在查询校园卡余额'
              : '校园卡余额：${card.balance.toStringAsFixed(2)} 元',
          excludeSemantics: true,
          child: Text(
            card == null ? '¥ —' : '¥ ${card.balance.toStringAsFixed(2)}',
            style: ShuYoTextStyles.title(
              color: context.shuyoColors.textPrimary,
              size: 40,
              weight: FontWeight.w500,
            ),
          ),
        ),
        if (card != null) ...[
          const SizedBox(height: 4),
          Text(
            '更新时间：${_formatUpdateTime(_cardQueriedAt)}',
            key: const ValueKey('campus-card-balance-updated-at'),
            style:
                ShuYoTextStyles.meta(color: context.shuyoColors.textTertiary),
          ),
        ],
        if (!_loadingCard && _cardError != null) ...[
          const SizedBox(height: 8),
          _errorSection(_cardError!,
              onRetry: () => _refresh(interactive: true)),
        ],
      ],
    );
  }

  Widget _updatedAt(DateTime time, String key) => Text(
        '更新时间：${_formatUpdateTime(time)}',
        key: ValueKey(key),
        style: ShuYoTextStyles.meta(color: context.shuyoColors.textTertiary),
      );

  String _formatUpdateTime(DateTime? time) {
    if (time == null) return '—';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Widget _errorSection(Object error,
      {required Future<void> Function() onRetry}) {
    final authRequired = error is CampusCardAuthRequiredException ||
        error is CampusCardException && error.code == 'accountMismatch';
    final message = _errorMessage(error);
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: TextStyle(color: context.shuyoColors.textSecondary)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loggingIn
                ? null
                : authRequired
                    ? () => _login()
                    : onRetry,
            icon: Icon(authRequired ? Icons.login : Icons.refresh),
            label: Text(_loggingIn
                ? '正在登录…'
                : authRequired
                    ? '登录校园账户'
                    : '重试'),
          ),
        ],
      ),
    );
  }
}
