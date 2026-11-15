import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../data/models/library_daily_recommend.dart';
import '../../data/models/library_loan_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'library_daily_recommend_card.dart';
import 'library_daily_recommend_skeleton.dart';
import 'library_loan_detail_sheet.dart';
import 'library_loan_history_page.dart';
import 'library_loan_list_tile.dart';
import 'library_rank_gallery.dart';
import 'library_rank_list_page.dart';
import 'library_search_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.authService,
    this.apiClient,
    this.onCampusSessionExpired,
    this.now,
  });

  final LibraryAuthService? authService;
  final LibraryApiClient? apiClient;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;
  final DateTime? now;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const _homeLoanLimit = 3;

  late final LibraryAuthService _authService =
      widget.authService ?? LibraryAuthService();
  late final LibraryApiClient _apiClient =
      widget.apiClient ?? LibraryApiClient();
  bool _isInitialAuthorizing = false;
  LibraryAuthSession? _session;
  LibraryDailyRecommend? _dailyRecommend;
  LibraryRankType _selectedRankType = LibraryRankType.hotLoan;
  final Map<LibraryRankType, List<LibraryBookItem>> _rankLists = {};
  final Map<LibraryRankType, bool> _rankLoading = {};
  List<LibraryLoanItem>? _activeLoans;
  LibraryTodoCounts? _todoCounts;
  bool _loansLoading = false;
  Object? _loansError;
  int _loansRevision = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_performAuthorization(isInitial: true));
  }

  @override
  void dispose() {
    ++_loansRevision;
    if (widget.apiClient == null) {
      _apiClient.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDailyRecommend([LibraryAuthSession? session]) async {
    final currentSession = session ?? _session;
    try {
      final book =
          await _apiClient.fetchDailyRecommend(session: currentSession);
      if (!mounted) return;
      setState(() => _dailyRecommend = book);
    } on Object {
      // 今日推荐加载失败不阻断借阅主流程
    }
  }

  Future<void> _loadRankList(
    LibraryRankType type, {
    LibraryAuthSession? session,
    bool force = false,
  }) async {
    if (!force && _rankLists.containsKey(type)) return;
    if (_rankLoading[type] == true) return;

    final currentSession = session ?? _session;
    setState(() => _rankLoading[type] = true);

    try {
      final books = await _apiClient.fetchRankList(
        type: type,
        page: 1,
        rows: 10,
        session: currentSession,
      );
      if (!mounted) return;
      setState(() {
        _rankLists[type] = books;
      });
    } on Object {
      // 榜单加载失败不阻断主流程
    } finally {
      if (mounted) {
        setState(() => _rankLoading[type] = false);
      }
    }
  }

  Future<void> _loadCurrentLoans([LibraryAuthSession? session]) async {
    final currentSession = session ?? _session;
    final revision = ++_loansRevision;
    bool isCurrent() => mounted && revision == _loansRevision;

    setState(() {
      _loansLoading = true;
      _loansError = null;
    });

    try {
      List<LibraryLoanItem> items;
      try {
        items = await _apiClient.fetchAllActiveLoans(session: currentSession);
      } on LibraryApiAuthRequiredException {
        final refreshedSession = await _authService.authorize(force: true);
        if (!isCurrent()) return;
        _session = refreshedSession;
        items = await _apiClient.fetchAllActiveLoans(session: refreshedSession);
      }
      if (!isCurrent()) return;
      final sorted = sortLibraryActiveLoans(items, now: widget.now);
      setState(() {
        _activeLoans = sorted;
        _loansLoading = false;
        _loansError = null;
      });
    } on LibraryCampusAuthRequiredException catch (e) {
      if (e.ssoExpired) {
        final recovered =
            await widget.onCampusSessionExpired?.call(true) ?? false;
        if (recovered && isCurrent()) {
          await _loadCurrentLoans(await _authService.authorize(force: true));
          return;
        }
      }
      if (!isCurrent()) return;
      setState(() {
        _loansLoading = false;
        _loansError = e;
      });
    } on Object catch (e) {
      if (!isCurrent()) return;
      setState(() {
        _loansLoading = false;
        _loansError = e;
      });
    }
  }

  Future<void> _loadUserLimit([LibraryAuthSession? session]) async {
    final currentSession = session ?? _session;
    try {
      final counts = await _apiClient.fetchUserLimit(session: currentSession);
      if (!mounted) return;
      setState(() => _todoCounts = counts);
    } on Object {
      // 待办计数失败不阻断首页渲染
    }
  }

  Future<LibraryLoanRenewResult> _handleRenewFromHome(
      LibraryLoanItem target) async {
    String? serverMessage;
    try {
      serverMessage = await _apiClient.renewLoan(
        barcode: target.barcode ?? '',
        loanId: target.loanId,
        session: _session,
      );
    } on LibraryApiAuthRequiredException {
      final refreshed = await _authService.authorize(force: true);
      if (!mounted) return (loan: null, message: null);
      _session = refreshed;
      serverMessage = await _apiClient.renewLoan(
        barcode: target.barcode ?? '',
        loanId: target.loanId,
        session: refreshed,
      );
    }

    final optimistic = target.copyWith(
      renewTimes: target.renewTimes + 1,
      surplusRenewTimes: (target.surplusRenewTimes - 1).clamp(0, 99),
    );
    if (mounted) {
      final current = _activeLoans ?? const <LibraryLoanItem>[];
      final updated = [
        for (final item in current)
          item.stableKey == target.stableKey ? optimistic : item,
      ];
      setState(() {
        _activeLoans = sortLibraryActiveLoans(updated, now: widget.now);
      });
      unawaited(_loadCurrentLoans(_session));
    }
    return (loan: optimistic, message: serverMessage ?? '续借成功');
  }

  void _openLoanDetail(LibraryLoanItem loan) {
    unawaited(
      showLibraryLoanDetailSheet(
        context,
        loan: loan,
        apiClient: _apiClient,
        session: _session,
        onRenew: _handleRenewFromHome,
        now: widget.now,
      ),
    );
  }

  void _openLoanHistoryPage({int initialTabIndex = 0}) {
    Navigator.of(context).push(
      shuyoRoute(
        builder: (context) => LibraryLoanHistoryPage(
          apiClient: _apiClient,
          authService: _authService,
          initialSession: _session,
          initialTabIndex: initialTabIndex,
          onCampusSessionExpired: widget.onCampusSessionExpired,
          onActiveLoansChanged: (updated) {
            if (!mounted) return;
            setState(() {
              _activeLoans = sortLibraryActiveLoans(updated, now: widget.now);
            });
          },
          now: widget.now,
        ),
      ),
    );
  }

  void _openRankListPage(LibraryRankType initialType) {
    Navigator.of(context).push(
      shuyoRoute(
        builder: (context) => LibraryRankListPage(
          apiClient: _apiClient,
          session: _session,
          initialType: initialType,
        ),
      ),
    );
  }

  void _openSearchPage() {
    Navigator.of(context).push(
      shuyoRoute(
        builder: (context) => LibrarySearchPage(
          apiClient: _apiClient,
          session: _session,
        ),
      ),
    );
  }

  Future<void> _performAuthorization({
    bool force = false,
    bool isInitial = false,
  }) async {
    if (_isInitialAuthorizing) return;
    setState(() {
      if (isInitial) {
        _isInitialAuthorizing = true;
      }
      _error = null;
    });

    try {
      final session = await _authService.authorize(force: force);
      if (!mounted) return;
      setState(() {
        _session = session;
        _error = null;
      });
      final tasks = <Future<void>>[
        _loadCurrentLoans(session),
        _loadUserLimit(session),
        _loadDailyRecommend(session),
        _loadRankList(_selectedRankType, session: session, force: force),
      ];
      if (!isInitial) {
        await Future.wait(tasks);
      } else {
        for (final task in tasks) {
          unawaited(task);
        }
      }
    } on LibraryCampusAuthRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      if (e.ssoExpired) {
        final recovered =
            await widget.onCampusSessionExpired?.call(true) ?? false;
        if (recovered && mounted) {
          unawaited(_performAuthorization(force: true, isInitial: isInitial));
        }
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted && isInitial) {
        setState(() => _isInitialAuthorizing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图书馆借阅'),
        actions: [
          IconButton(
            key: const ValueKey('library-search'),
            tooltip: '搜索图书',
            onPressed: _openSearchPage,
            icon: const Icon(Icons.search),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _isInitialAuthorizing
                ? const LinearProgressIndicator(
                    key: ValueKey('library-auth-progress'),
                    minHeight: 2,
                  )
                : null,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _performAuthorization(force: true, isInitial: false);
        },
        child: _error != null
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 24),
                children: [
                  _buildBody(),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _buildMyLoansSection(context),
                  const SizedBox(height: 8),
                  if (_dailyRecommend != null)
                    LibraryDailyRecommendCard(book: _dailyRecommend!)
                  else
                    const LibraryDailyRecommendSkeleton(),
                  const SizedBox(height: 14),
                  LibraryRankGallery(
                    selectedType: _selectedRankType,
                    books: _rankLists[_selectedRankType] ?? const [],
                    isLoading: _rankLoading[_selectedRankType] == true,
                    onTypeChanged: (type) {
                      setState(() => _selectedRankType = type);
                      unawaited(_loadRankList(type));
                    },
                    onViewAll: () => _openRankListPage(_selectedRankType),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildMyLoansSection(BuildContext context) {
    final colors = context.shuyoColors;
    final loans = _activeLoans;
    final hasCustomBg = CustomBackgroundScope.maybeOf(context) != null;
    final clientOverdueCount = loans == null
        ? 0
        : loans
            .where((item) =>
                item.statusAt(now: widget.now) == LibraryLoanStatus.overdue)
            .length;
    final expiredCount = clientOverdueCount > 0
        ? clientOverdueCount
        : (_todoCounts?.expiredNum ?? 0);

    final visibleLoans = loans == null
        ? const <LibraryLoanItem>[]
        : loans.take(_homeLoanLimit).toList(growable: false);
    final overflowCount = loans == null
        ? 0
        : (loans.length - _homeLoanLimit).clamp(0, loans.length);

    return Column(
      key: const ValueKey('library-home-loans-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    '我的借阅',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              if (loans != null && loans.isNotEmpty)
                Text(
                  '在借 ${loans.length} 本',
                  key: const ValueKey('library-home-loans-count'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
        if (expiredCount > 0)
          Container(
            key: const ValueKey('library-home-overdue-banner'),
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: colors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: colors.danger.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 17, color: colors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前有 $expiredCount 本图书已逾期，请尽快归还',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.danger,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                ),
              ],
            ),
          ),
        if (_loansLoading && loans == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: Text(
              '加载中',
              style: TextStyle(color: colors.textTertiary),
            ),
          )
        else if (_loansError != null && loans == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _loansError is LibraryApiException
                        ? (_loansError as LibraryApiException).message
                        : '在借图书加载失败',
                    style: TextStyle(color: colors.textTertiary),
                  ),
                ),
                TextButton(
                  key: const ValueKey('library-home-loans-retry'),
                  onPressed: () => unawaited(_loadCurrentLoans(_session)),
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        else if (visibleLoans.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '暂无在借图书',
              style: TextStyle(color: colors.textTertiary),
            ),
          )
        else ...[
          if (_loansError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Text(
                '在借状态更新失败，当前显示上次结果',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textTertiary,
                    ),
              ),
            ),
          Container(
            margin: hasCustomBg
                ? const EdgeInsets.symmetric(horizontal: 12)
                : EdgeInsets.zero,
            decoration: hasCustomBg
                ? BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(14),
                  )
                : null,
            clipBehavior: hasCustomBg ? Clip.antiAlias : Clip.none,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, item) in visibleLoans.indexed) ...[
                  if (index > 0) const LibraryLoanSeparator(),
                  LibraryLoanListTile(
                    key: ValueKey('library-home-loan:${item.stableKey}'),
                    index: index,
                    loan: item,
                    now: widget.now,
                    onTap: () => _openLoanDetail(item),
                  ),
                ],
              ],
            ),
          ),
          if (overflowCount > 0)
            InkWell(
              key: const ValueKey('library-home-loans-more'),
              onTap: () => _openLoanHistoryPage(initialTabIndex: 1),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '还有 $overflowCount 本在借图书',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.accent,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: colors.accent),
                  ],
                ),
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('library-loan-history'),
              onPressed: () => _openLoanHistoryPage(initialTabIndex: 0),
              style:
                  TextButton.styleFrom(foregroundColor: colors.textSecondary),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('查看历史借阅'),
                  SizedBox(width: 2),
                  Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      final message =
          error is LibraryAuthException ? error.message : '获取图书馆授权失败，请稍后重试';
      return EmptyState(
        icon: Icons.error_outline,
        title: '未能获取借阅授权',
        message: message,
        action: FilledButton(
          onPressed: () => unawaited(_performAuthorization(force: true)),
          child: const Text('重新授权'),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
