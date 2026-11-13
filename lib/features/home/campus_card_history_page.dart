import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../data/models/campus_card.dart';
import '../../data/services/campus_card_service.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/date_range_picker.dart';
import 'campus_card_bill_list.dart';

class CampusCardHistoryPage extends StatefulWidget {
  const CampusCardHistoryPage({
    super.key,
    required this.onLogin,
    this.serviceFactory,
    this.onAuthRequired,
    this.initialCard,
    this.initialQueriedAt,
    this.fetchCardInfo,
  });

  final Future<bool> Function() onLogin;
  final CampusCardService Function()? serviceFactory;
  final Future<void> Function(CampusCardAuthRequiredException)? onAuthRequired;
  final CampusCardInfo? initialCard;
  final DateTime? initialQueriedAt;
  final Future<CampusCardInfo> Function()? fetchCardInfo;

  @override
  State<CampusCardHistoryPage> createState() => _CampusCardHistoryPageState();
}

class _CampusCardHistoryPageState extends State<CampusCardHistoryPage>
    with SingleTickerProviderStateMixin {
  CampusCardService? _ownedService;
  CampusCardService get _service =>
      widget.serviceFactory?.call() ?? (_ownedService ??= CampusCardService());
  final _scrollController = ScrollController();
  late final TabController _tabController;
  late DateTimeRange _dateRange;
  String _timePreset = 'week';
  int _tabIndex = 0;
  List<CampusCardBill>? _bills;
  late CampusCardInfo? _balanceCard = widget.initialCard;
  late DateTime? _balanceTime = widget.initialQueriedAt;
  bool _anchorLoading = false;
  bool _balanceSnapshotValid = false;
  ({
    List<CampusCardBill>? bills,
    DateTimeRange range,
    DateTime end
  })? _pendingBalanceSnapshot;
  DateTimeRange? _billsRange;
  DateTime? _billsQueryEnd;
  Object? _error;
  String? _loginError;
  bool _loading = true;
  bool _pullRefreshing = false;
  bool _loggingIn = false;
  int _refreshRevision = 0;
  int _billsRevision = 0;
  int _balanceRevision = 0;
  Completer<void>? _refreshSuperseded;
  final _authNotifications = <bool, Future<void>>{};

  @override
  void initState() {
    super.initState();
    _dateRange = _presetRange(_timePreset);
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_onTabChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    ++_refreshRevision;
    ++_billsRevision;
    ++_balanceRevision;
    _supersedeRefresh();
    _tabController.dispose();
    _scrollController.dispose();
    _ownedService?.dispose();
    super.dispose();
  }

  DateTimeRange _presetRange(String preset) {
    final today = DateUtils.dateOnly(DateTime.now());
    if (preset == 'week') {
      return DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 6),
        end: today,
      );
    }
    final months = preset == 'month' ? 1 : 12;
    final first = DateTime(today.year, today.month - months);
    final lastDay = DateUtils.getDaysInMonth(first.year, first.month);
    return DateTimeRange(
      start: DateTime(first.year, first.month, math.min(today.day, lastDay)),
      end: today,
    );
  }

  String get _timeLabel => switch (_timePreset) {
        'week' => '近一周',
        'month' => '近一月',
        'year' => '近一年',
        _ => '${_date(_dateRange.start)}—${_date(_dateRange.end)}',
      };

  void _onTabChanged() {
    if (_tabIndex == _tabController.index) return;
    setState(() => _tabIndex = _tabController.index);
    _scrollToTop();
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
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
        // Host account bookkeeping must not replace the query's retry state.
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
    setState(() => _pullRefreshing = pullToRefresh);
    try {
      await Future.any([_loadBills(), superseded.future]);
      if (!isCurrent()) return;
      final error = _error;
      if (interactive &&
          allowLogin &&
          error is CampusCardAuthRequiredException &&
          error.ssoExpired) {
        final loggedIn = await _login(refreshAfterLogin: false);
        if (!isCurrent()) return;
        if (!loggedIn) return;
        await Future.any([_loadBills(), superseded.future]);
      }
    } finally {
      if (isCurrent()) {
        setState(() => _pullRefreshing = false);
        _refreshSuperseded = null;
      }
    }
  }

  Future<void> _loadBills() async {
    final revision = ++_billsRevision;
    final range = _dateRange;
    // Include newer transactions even when the selected end date is in the
    // past; they are needed to work backwards from today's balance.
    final queryRange = DateTimeRange(
      start: range.start,
      end: DateUtils.dateOnly(DateTime.now()),
    );
    bool isCurrent() => mounted && revision == _billsRevision;
    var receivedProgress = false;
    var acceptingProgress = true;
    setState(() {
      _loading = true;
      _error = null;
      _loginError = null;
      _balanceSnapshotValid = false;
      _pendingBalanceSnapshot = null;
      if (_billsRange != range) _bills = null;
    });
    final balanceTask = _loadBalance();
    try {
      final bills = await _service.fetchBills(
        startDate: queryRange.start,
        endDate: queryRange.end,
        shouldCancel: () => !isCurrent(),
        onProgress: (bills) {
          if (!isCurrent() || !acceptingProgress) return;
          if (bills.isEmpty && !receivedProgress) return;
          receivedProgress = true;
          setState(() {
            _publishOrStageBills(
                bills.isEmpty ? null : sortCampusCardBills(bills),
                range,
                queryRange.end);
          });
        },
      );
      acceptingProgress = false;
      if (!isCurrent()) return;
      setState(() {
        _publishOrStageBills(sortCampusCardBills(bills), range, queryRange.end);
      });
      await balanceTask;
    } on Object catch (error) {
      acceptingProgress = false;
      if (!isCurrent()) return;
      setState(() {
        _error = error;
        if (error is CampusCardException && error.code == 'accountMismatch') {
          ++_refreshRevision;
          ++_billsRevision;
          ++_balanceRevision;
          _supersedeRefresh();
          _bills = null;
          _billsRange = null;
          _balanceCard = null;
          _balanceTime = null;
          _anchorLoading = false;
          _balanceSnapshotValid = false;
          _pendingBalanceSnapshot = null;
          _loading = false;
          _pullRefreshing = false;
        }
      });
      await _notifyAuthRequired(error);
    } finally {
      acceptingProgress = false;
      if (isCurrent()) setState(() => _loading = false);
    }
  }

  void _publishOrStageBills(
      List<CampusCardBill>? bills, DateTimeRange range, DateTime end) {
    final snapshot = (bills: bills, range: range, end: end);
    if (_anchorLoading) {
      _pendingBalanceSnapshot = snapshot;
      return;
    }
    _bills = bills;
    _billsRange = range;
    _billsQueryEnd = end;
    _balanceSnapshotValid = bills != null;
  }

  Future<void> _loadBalance() async {
    final fetch = widget.fetchCardInfo;
    if (fetch == null) return;
    final revision = ++_balanceRevision;
    bool isCurrent() => mounted && revision == _balanceRevision;
    setState(() => _anchorLoading = true);
    try {
      final card = await fetch();
      if (!isCurrent()) return;
      setState(() {
        _balanceCard = card;
        _balanceTime = DateTime.now();
      });
    } on Object {
      if (!isCurrent()) return;
      setState(() {
        _balanceCard = null;
        _balanceTime = null;
      });
    } finally {
      if (isCurrent()) {
        setState(() {
          _anchorLoading = false;
          final pending = _pendingBalanceSnapshot;
          _pendingBalanceSnapshot = null;
          if (pending != null) {
            _publishOrStageBills(pending.bills, pending.range, pending.end);
          }
        });
      }
    }
  }

  Future<bool> _login({bool refreshAfterLogin = true}) async {
    if (_loggingIn) return false;
    if (refreshAfterLogin) {
      ++_refreshRevision;
      _supersedeRefresh();
    }
    setState(() {
      ++_billsRevision;
      ++_balanceRevision;
      _loggingIn = true;
      _loading = false;
      if (refreshAfterLogin) _pullRefreshing = false;
      // Login can select another account; retire the previous session's rows.
      _bills = null;
      _billsRange = null;
      _balanceCard = null;
      _balanceTime = null;
      _anchorLoading = false;
      _balanceSnapshotValid = false;
      _pendingBalanceSnapshot = null;
      _loginError = null;
      _error ??= const CampusCardAuthRequiredException();
    });
    var loggedIn = false;
    try {
      await Future.wait(_authNotifications.values.toList());
      if (!mounted) return false;
      loggedIn = await widget.onLogin();
    } on Object {
      if (mounted) {
        setState(() => _loginError = '暂时无法完成登录，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
    if (loggedIn && mounted && refreshAfterLogin) {
      await _refresh(interactive: true, allowLogin: false);
    }
    return loggedIn;
  }

  Future<void> _chooseTime() async {
    final preset = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭消费时间筛选',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        final colors = context.shuyoColors;
        final size = MediaQuery.sizeOf(context);
        return SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding:
                  const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
              child: SizedBox(
                width: math.min(264, size.width * .68),
                child: Material(
                  key: const ValueKey('campus-card-time-menu'),
                  elevation: 12,
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: size.height * .72),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (final option in const [
                          ('week', '近一周'),
                          ('month', '近一月'),
                          ('year', '近一年'),
                          ('custom', '自定义日期'),
                        ])
                          ListTile(
                            key: ValueKey('campus-card-time-${option.$1}'),
                            selected: _timePreset == option.$1,
                            title: Text(option.$2),
                            onTap: () => Navigator.of(context).pop(option.$1),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position:
              Tween(begin: const Offset(.18, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
    if (preset == null || !mounted) return;
    final DateTimeRange? range;
    if (preset == 'custom') {
      range = await showShuYoDateRangePicker(
        context: context,
        title: '自定义消费日期',
        firstDate: DateTime(1900),
        lastDate: DateUtils.dateOnly(DateTime.now()),
        initialRange: _dateRange,
      );
    } else {
      range = _presetRange(preset);
    }
    final selectedRange = range;
    if (selectedRange == null || !mounted) return;
    final changed = selectedRange != _dateRange || preset != _timePreset;
    setState(() {
      _timePreset = preset;
      _dateRange = selectedRange;
    });
    if (!changed) return;
    _scrollToTop();
    unawaited(_refresh(interactive: true));
  }

  String _date(DateTime day) =>
      '${day.year}/${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}';

  String _errorMessage(Object error) =>
      error is CampusCardAuthRequiredException && error.ssoExpired
          ? '登录已失效，请重新登录'
          : error is CampusCardException
              ? error.message
              : '查询失败，请检查网络后重试。';

  Widget _errorSection(Object error) {
    final authRequired = error is CampusCardAuthRequiredException ||
        error is CampusCardException && error.code == 'accountMismatch';
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_loginError ?? _errorMessage(error),
              style: TextStyle(color: context.shuyoColors.textSecondary)),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('campus-card-history-retry'),
            onPressed: _loggingIn
                ? null
                : authRequired
                    ? () => _login()
                    : () => _refresh(interactive: true),
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

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final allBills = _bills ?? const <CampusCardBill>[];
    final allBalances = campusCardBalances(
      allBills,
      currentBalance: _anchorLoading ||
              !_balanceSnapshotValid ||
              _balanceTime == null ||
              _billsQueryEnd == null ||
              DateUtils.dateOnly(_balanceTime!).isAfter(_billsQueryEnd!)
          ? null
          : _balanceCard?.balance,
      balanceTime: _balanceTime,
    );
    final selected = allBills.indexed.where((entry) {
      final bill = entry.$2;
      final time = DateTime.tryParse(
          bill.payTime.trim().replaceAll(RegExp(r'\s+'), 'T'));
      if (time != null && DateUtils.dateOnly(time).isAfter(_dateRange.end)) {
        return false;
      }
      return switch (_tabIndex) {
        1 => bill.amount < 0,
        2 => bill.amount > 0,
        _ => true,
      };
    }).toList(growable: false);
    final bills = [for (final entry in selected) entry.$2];
    final balances = [for (final entry in selected) allBalances[entry.$1]];
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史消费'),
        actions: [
          IconButton(
            key: const ValueKey('campus-card-time-filter'),
            tooltip: '消费时间：$_timeLabel',
            onPressed: _loggingIn ? null : _chooseTime,
            icon: const Icon(Icons.date_range_outlined),
          ),
          const SizedBox(width: 2),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight + 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_pullRefreshing && (_loading || _loggingIn))
                const LinearProgressIndicator(minHeight: 3)
              else
                const SizedBox(height: 3),
              TabBar(
                controller: _tabController,
                labelColor: colors.accent,
                unselectedLabelColor: colors.textSecondary,
                indicatorColor: colors.accent,
                dividerColor: colors.border,
                tabs: const [
                  Tab(key: ValueKey('campus-card-history-tab-all'), text: '全部'),
                  Tab(
                      key: ValueKey('campus-card-history-tab-credit'),
                      text: '充值'),
                  Tab(
                      key: ValueKey('campus-card-history-tab-debit'),
                      text: '消费'),
                ],
              ),
            ],
          ),
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
            key: const ValueKey('campus-card-history-scroll-view'),
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (_error != null || (!_loading && bills.isEmpty))
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  sliver: SliverList.list(children: [
                    if (_error != null)
                      _errorSection(_error!)
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Text('所选日期内暂无记录，可切换日期查询。',
                            style: TextStyle(color: colors.textSecondary)),
                      ),
                  ]),
                ),
              ...campusCardBillSlivers(bills,
                  context: context,
                  balances: balances,
                  retainPreviousBalances: _anchorLoading ||
                      !_balanceSnapshotValid ||
                      _balanceCard == null),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      ),
    );
  }
}
