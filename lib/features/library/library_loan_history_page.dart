import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/library_loan_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'library_loan_detail_sheet.dart';
import 'library_loan_list_tile.dart';
import 'library_loan_rules_sheet.dart';
import 'library_loan_time_menu.dart';

/// 借阅记录子页面（参考图书馆预约记录 + 校园卡历史消费：
/// Tab 区分「全部 / 借阅中 / 已归还」、AppBar 时间筛选、年月时间吸顶、全部实时走 API 不写本地缓存）。
class LibraryLoanHistoryPage extends StatefulWidget {
  const LibraryLoanHistoryPage({
    super.key,
    required this.apiClient,
    this.authService,
    this.initialSession,
    this.initialTabIndex = 0,
    this.onCampusSessionExpired,
    this.onActiveLoansChanged,
    this.now,
  });

  final LibraryApiClient apiClient;
  final LibraryAuthService? authService;
  final LibraryAuthSession? initialSession;
  final int initialTabIndex;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;
  final ValueChanged<List<LibraryLoanItem>>? onActiveLoansChanged;
  final DateTime? now;

  @override
  State<LibraryLoanHistoryPage> createState() => _LibraryLoanHistoryPageState();
}

class _LibraryLoanHistoryPageState extends State<LibraryLoanHistoryPage>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['全部', '借阅中', '已归还'];
  static const _historyPageSize = 20;

  late final TabController _tabController = TabController(
    length: _tabs.length,
    initialIndex: widget.initialTabIndex.clamp(0, _tabs.length - 1),
    vsync: this,
  )..addListener(_onTabChanged);

  final _scrollController = ScrollController();

  late LibraryAuthSession? _session = widget.initialSession;
  late int _tabIndex = widget.initialTabIndex.clamp(0, _tabs.length - 1);
  LibraryLoanTimeFilter _timeFilter = const LibraryLoanTimeFilter.all();

  List<LibraryLoanItem> _activeLoans = const [];
  final List<LibraryLoanItem> _historyLoans = [];
  final Set<String> _historyKeys = {};
  int _activeNumFound = 0;
  int _historyNumFound = 0;
  int _historyPage = 0;
  bool _hasMoreHistory = true;
  bool _hasLoaded = false;

  LibraryTodoCounts? _todoCounts;

  bool _loading = true;
  bool _pullRefreshing = false;
  bool _loadingMore = false;
  Object? _error;
  Object? _loadMoreError;

  int _requestRevision = 0;
  int _animationEpoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAll());
  }

  @override
  void dispose() {
    ++_requestRevision;
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _tabIndex) return;
    setState(() {
      _tabIndex = _tabController.index;
      _animationEpoch++;
    });
    _scrollToTop();
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  Future<LibraryAuthSession?> _ensureSession(
      {bool forceRefresh = false}) async {
    if (!forceRefresh && _session != null) return _session;
    final authService = widget.authService;
    if (authService == null) return _session;
    final session = await authService.authorize(force: forceRefresh);
    if (mounted) {
      _session = session;
    }
    return session;
  }

  Future<T> _runWithAuthRetry<T>(
    Future<T> Function(LibraryAuthSession? session) action,
  ) async {
    var session = await _ensureSession();
    try {
      return await action(session);
    } on LibraryApiAuthRequiredException {
      if (widget.authService == null) rethrow;
      try {
        session = await _ensureSession(forceRefresh: true);
      } on LibraryCampusAuthRequiredException catch (authErr) {
        if (authErr.ssoExpired) {
          final recovered =
              await widget.onCampusSessionExpired?.call(true) ?? false;
          if (recovered) {
            session = await _ensureSession(forceRefresh: true);
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }
      return action(session);
    }
  }

  Future<void> _loadAll({bool pullToRefresh = false}) async {
    final revision = ++_requestRevision;
    bool isCurrent() => mounted && revision == _requestRevision;

    setState(() {
      _loading = !pullToRefresh;
      _pullRefreshing = pullToRefresh;
      _loadingMore = false;
      _error = null;
      _loadMoreError = null;
    });

    try {
      final result = await _runWithAuthRetry((session) async {
        final activeFuture =
            widget.apiClient.fetchAllActiveLoans(session: session);
        final historyFuture = widget.apiClient.fetchLoanHistoryList(
          page: 1,
          rows: _historyPageSize,
          session: session,
        );
        final limitFuture = widget.apiClient
            .fetchUserLimit(session: session)
            .catchError((Object _) => const LibraryTodoCounts());
        final results =
            await Future.wait([activeFuture, historyFuture, limitFuture]);
        return (
          active: results[0] as List<LibraryLoanItem>,
          historyPage1: results[1] as LibraryLoanPageResult,
          limit: results[2] as LibraryTodoCounts,
        );
      });

      if (!isCurrent()) return;
      final activeSorted = sortLibraryActiveLoans(
        result.active,
        now: widget.now,
      );
      setState(() {
        _activeLoans = activeSorted;
        _activeNumFound = activeSorted.length;
        _historyLoans.clear();
        _historyKeys.clear();
        for (final item in result.historyPage1.items) {
          if (_historyKeys.add(item.stableKey)) {
            _historyLoans.add(item);
          }
        }
        _historyNumFound = result.historyPage1.numFound;
        _historyPage = 1;
        _hasMoreHistory = result.historyPage1.items.isNotEmpty &&
            _historyLoans.length < _historyNumFound;
        _todoCounts = result.limit;
        _hasLoaded = true;
        _loading = false;
        _pullRefreshing = false;
        _animationEpoch++;
      });
      widget.onActiveLoansChanged?.call(activeSorted);

      if (_timeFilter.isActive && _hasMoreHistory) {
        unawaited(_drainHistoryPagesForFilter(revision));
      }
    } on LibraryCampusAuthRequiredException catch (e) {
      if (e.ssoExpired) {
        final recovered =
            await widget.onCampusSessionExpired?.call(true) ?? false;
        if (recovered && isCurrent()) {
          unawaited(_loadAll(pullToRefresh: pullToRefresh));
          return;
        }
      }
      _handleLoadError(e, isCurrent: isCurrent, pullToRefresh: pullToRefresh);
    } on Object catch (e) {
      _handleLoadError(e, isCurrent: isCurrent, pullToRefresh: pullToRefresh);
    }
  }

  void _handleLoadError(
    Object error, {
    required bool Function() isCurrent,
    required bool pullToRefresh,
  }) {
    if (!isCurrent()) return;
    setState(() {
      _loading = false;
      _pullRefreshing = false;
      if (!_hasLoaded) {
        _error = error;
      }
    });
    if (_hasLoaded) {
      final msg = error is LibraryApiException
          ? error.message
          : (error is LibraryAuthException ? error.message : '刷新借阅记录失败，请稍后重试');
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    } else if (pullToRefresh) {
      setState(() => _error = error);
    }
  }

  Future<void> _loadMoreHistory({bool userRetry = false}) async {
    if (_loading || _loadingMore || !_hasMoreHistory || !_hasLoaded) return;
    if (_loadMoreError != null && !userRetry) return;

    final revision = _requestRevision;
    bool isCurrent() => mounted && revision == _requestRevision;

    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final nextPage = _historyPage + 1;
      final pageResult = await _runWithAuthRetry(
        (session) => widget.apiClient.fetchLoanHistoryList(
          page: nextPage,
          rows: _historyPageSize,
          session: session,
        ),
      );
      if (!isCurrent()) return;
      setState(() {
        _historyPage = nextPage;
        var added = 0;
        for (final item in pageResult.items) {
          if (_historyKeys.add(item.stableKey)) {
            _historyLoans.add(item);
            added++;
          }
        }
        if (pageResult.numFound > _historyNumFound) {
          _historyNumFound = pageResult.numFound;
        }
        _hasMoreHistory = pageResult.items.isNotEmpty &&
            added > 0 &&
            _historyLoans.length < _historyNumFound;
        _loadingMore = false;
      });
    } on Object catch (e) {
      if (!isCurrent()) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = e;
      });
    }
  }

  /// 开启日期范围筛选时，顺序补齐未加载的历史页（遵循服务端流控策略与 numFound 终止条件）。
  Future<void> _drainHistoryPagesForFilter(int revision) async {
    while (mounted &&
        revision == _requestRevision &&
        _timeFilter.isActive &&
        _hasMoreHistory &&
        !_loadingMore) {
      await _loadMoreHistory();
      if (_loadMoreError != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_tabIndex == 1) return false; // 「借阅中」一次性拉全，不分页
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      if (metrics.maxScrollExtent > 0 &&
          (metrics.pixels >= metrics.maxScrollExtent * 0.55 ||
              metrics.extentAfter < 360)) {
        unawaited(_loadMoreHistory());
      }
    }
    return false;
  }

  Future<void> _chooseTime() async {
    final nextFilter = await showLibraryLoanTimeMenu(
      context,
      selectedFilter: _timeFilter,
      now: widget.now,
    );
    if (nextFilter == null || !mounted || nextFilter == _timeFilter) return;
    setState(() {
      _timeFilter = nextFilter;
      _animationEpoch++;
    });
    _scrollToTop();
    if (_timeFilter.isActive && _hasMoreHistory) {
      unawaited(_drainHistoryPagesForFilter(_requestRevision));
    }
  }

  Future<void> _openRulesSheet() async {
    final session = _session;
    await showLibraryLoanRulesSheet(
      context,
      apiClient: widget.apiClient,
      authService: widget.authService,
      session: session,
      onSessionRefreshed: (refreshed) {
        if (mounted) _session = refreshed;
      },
      initialLimit: _todoCounts,
    );
  }

  Future<LibraryLoanRenewResult> _handleRenew(LibraryLoanItem target) async {
    final serverMessage = await _runWithAuthRetry(
      (session) => widget.apiClient.renewLoan(
        barcode: target.barcode ?? '',
        loanId: target.loanId,
        session: session,
      ),
    );
    final optimistic = target.copyWith(
      renewTimes: target.renewTimes + 1,
      surplusRenewTimes: (target.surplusRenewTimes - 1).clamp(0, 99),
    );
    if (mounted) {
      final updatedList = [
        for (final item in _activeLoans)
          item.stableKey == target.stableKey ? optimistic : item,
      ];
      setState(() {
        _activeLoans = sortLibraryActiveLoans(updatedList, now: widget.now);
      });
      widget.onActiveLoansChanged?.call(_activeLoans);
    }

    // 后台静默重新拉取一次在借列表，确保新 normReturnDate 与服务端最终一致。
    try {
      final latest = await _runWithAuthRetry(
        (session) => widget.apiClient.fetchAllActiveLoans(session: session),
      );
      if (mounted) {
        final sorted = sortLibraryActiveLoans(latest, now: widget.now);
        setState(() {
          _activeLoans = sorted;
          _activeNumFound = sorted.length;
        });
        widget.onActiveLoansChanged?.call(sorted);
        for (final item in sorted) {
          if (item.stableKey == target.stableKey ||
              (target.loanId != null && item.loanId == target.loanId) ||
              (target.barcode != null && item.barcode == target.barcode)) {
            return (loan: item, message: serverMessage ?? '续借成功');
          }
        }
      }
    } on Object {
      // 静默同步失败保留已乐观更新的本地对象
    }
    return (loan: optimistic, message: serverMessage ?? '续借成功');
  }

  void _openDetail(LibraryLoanItem loan) {
    unawaited(
      showLibraryLoanDetailSheet(
        context,
        loan: loan,
        apiClient: widget.apiClient,
        session: _session,
        onRenew: loan.isHistory ? null : _handleRenew,
        now: widget.now,
      ),
    );
  }

  List<LibraryLoanItem> _visibleLoans() {
    final Iterable<LibraryLoanItem> source = switch (_tabIndex) {
      1 => _activeLoans,
      2 => _historyLoans,
      _ => [..._activeLoans, ..._historyLoans],
    };
    final filtered = source
        .where((item) => _timeFilter.matches(item, now: widget.now))
        .toList(growable: false);
    return sortLibraryLoansNewestFirst(filtered);
  }

  String _emptyTitle() {
    if (_timeFilter.isActive) return '所选时间内暂无借阅记录';
    return switch (_tabIndex) {
      1 => '当前没有在借图书',
      2 => '暂无历史借阅记录',
      _ => '暂无借阅记录',
    };
  }

  String _emptyMessage() {
    if (_timeFilter.isActive) return '可以切换顶部时间筛选查看其他日期范围的记录。';
    return switch (_tabIndex) {
      1 => '去图书馆首页看看今日推荐或热门榜单吧。',
      2 => '归还后的图书会记录在这里。',
      _ => '借阅图书后，当前在借与历史借阅会展示在这里。',
    };
  }

  String _friendlyErrorMessage(Object error) {
    if (error is LibraryAuthException) return error.message;
    if (error is LibraryApiException) return error.message;
    return '获取借阅记录失败，请检查网络后重试。';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final visible = _visibleLoans();
    final showsHistoryTab = _tabIndex == 0 || _tabIndex == 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('借阅记录'),
        actions: [
          IconButton(
            key: const ValueKey('library-loan-rules'),
            tooltip: '借阅规则与读者证',
            onPressed: _openRulesSheet,
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            key: const ValueKey('library-loan-time-filter'),
            tooltip: '借阅时间：${_timeFilter.displayLabel()}',
            onPressed: _chooseTime,
            icon: const Icon(Icons.date_range_outlined),
          ),
          const SizedBox(width: 2),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight + 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_pullRefreshing && _loading)
                const LinearProgressIndicator(
                  key: ValueKey('library-loan-history-progress'),
                  minHeight: 3,
                )
              else
                const SizedBox(height: 3),
              TabBar(
                controller: _tabController,
                labelColor: colors.accent,
                unselectedLabelColor: colors.textSecondary,
                indicatorColor: colors.accent,
                dividerColor: colors.border,
                tabs: const [
                  Tab(key: ValueKey('library-loan-tab-all'), text: '全部'),
                  Tab(key: ValueKey('library-loan-tab-active'), text: '借阅中'),
                  Tab(key: ValueKey('library-loan-tab-returned'), text: '已归还'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          key: const ValueKey('library-loan-history-refresh'),
          onRefresh: () async {
            if (!_pullRefreshing) {
              await _loadAll(pullToRefresh: true);
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: CustomScrollView(
              key: const ValueKey('library-loan-history-scroll-view'),
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (_hasLoaded && _error == null)
                  SliverToBoxAdapter(
                    child: _buildSummaryBar(context, visible.length),
                  ),
                if (_loading && visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 12),
                            Text(
                              '正在加载借阅记录…',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (_error != null && visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: _error is LibraryApiAuthRequiredException ||
                              _error is LibraryCampusAuthRequiredException
                          ? Icons.lock_outline
                          : Icons.cloud_off_outlined,
                      title: '未能加载借阅记录',
                      message: _friendlyErrorMessage(_error!),
                      action: FilledButton.icon(
                        onPressed: () => unawaited(_loadAll()),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ),
                  )
                else if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: _timeFilter.isActive
                          ? Icons.filter_alt_off_outlined
                          : Icons.menu_book_outlined,
                      title: _emptyTitle(),
                      message: _emptyMessage(),
                      action: _timeFilter.isActive
                          ? TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _timeFilter =
                                      const LibraryLoanTimeFilter.all();
                                  _animationEpoch++;
                                });
                              },
                              icon: const Icon(Icons.clear),
                              label: const Text('查看全部时间'),
                            )
                          : null,
                    ),
                  )
                else ...[
                  ...libraryLoanSlivers(
                    visible,
                    context: context,
                    onTapItem: _openDetail,
                    animationEpoch: _animationEpoch,
                    now: widget.now,
                  ),
                  if (showsHistoryTab)
                    SliverToBoxAdapter(
                      child: _buildFooter(colors, visible.length),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryBar(BuildContext context, int visibleCount) {
    final colors = context.shuyoColors;
    final countSummary = switch (_tabIndex) {
      1 => '当前在借 $_activeNumFound 本',
      2 => '已归还 $_historyNumFound 本',
      _ => '在借 $_activeNumFound · 已归还 $_historyNumFound 本',
    };
    return Padding(
      key: const ValueKey('library-loan-history-summary'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    _timeFilter.displayLabel(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _timeFilter.isActive
                              ? colors.accent
                              : colors.textTertiary,
                          fontWeight:
                              _timeFilter.isActive ? FontWeight.w600 : null,
                        ),
                  ),
                ),
                if (_timeFilter.isActive) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      setState(() {
                        _timeFilter = const LibraryLoanTimeFilter.all();
                        _animationEpoch++;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        '重置',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.textSecondary,
                            ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _timeFilter.isActive ? '匹配 $visibleCount 条' : countSummary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ShuYoColors colors, int visibleCount) {
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Center(
          child: TextButton.icon(
            key: const ValueKey('library-loan-history-load-more-retry'),
            onPressed: () => unawaited(_loadMoreHistory(userRetry: true)),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('加载更多失败，点击重试'),
          ),
        ),
      );
    }
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Center(
          child: Text(
            '正在加载更多历史记录…',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
      );
    }
    if (!_hasMoreHistory && visibleCount > 0 && _historyNumFound > 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Center(
          child: Text(
            _timeFilter.isActive
                ? '已筛选全部历史记录'
                : '已显示全部 $_historyNumFound 条历史借阅',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
