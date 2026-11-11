import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_author_text.dart';
import 'library_book_detail_page.dart';
import 'library_campus_menu.dart';

class LibraryRankListPage extends StatefulWidget {
  const LibraryRankListPage({
    super.key,
    required this.apiClient,
    this.session,
    this.initialType = LibraryRankType.hotLoan,
  });

  final LibraryApiClient apiClient;
  final LibraryAuthSession? session;
  final LibraryRankType initialType;

  @override
  State<LibraryRankListPage> createState() => _LibraryRankListPageState();
}

class _LibraryRankListPageState extends State<LibraryRankListPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<LibraryRankType, List<LibraryBookItem>> _cachedLists = {};
  final Map<LibraryRankType, int> _pageMap = {};
  final Map<LibraryRankType, bool> _hasMoreMap = {};
  final Map<LibraryRankType, bool> _loadingStates = {};
  final Map<LibraryRankType, bool> _loadingMoreStates = {};
  bool _isNavLoading = false;

  HotLoanSortType _hotLoanSort = HotLoanSortType.loanCount;
  NewBookCampus _newBookCampus = NewBookCampus.all;

  static const double _coverWidth = 76.0;
  static const double _coverHeight = 106.0;
  static const int _pageSize = 30;

  @override
  void initState() {
    super.initState();
    final initialIndex = LibraryRankType.values.indexOf(widget.initialType);
    _tabController = TabController(
      length: LibraryRankType.values.length,
      initialIndex: initialIndex.clamp(0, LibraryRankType.values.length - 1),
      vsync: this,
    );

    _tabController.addListener(_handleTabChanged);
    unawaited(_loadRank(widget.initialType, showBarLoading: true));
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    setState(() {}); // 更新 AppBar 标题和 actions 状态
    if (_tabController.indexIsChanging) {
      final currentType = LibraryRankType.values[_tabController.index];
      if (!_cachedLists.containsKey(currentType)) {
        unawaited(_loadRank(currentType, showBarLoading: true));
      }
    }
  }

  void _toggleHotLoanSort() {
    final nextSort = _hotLoanSort == HotLoanSortType.loanCount
        ? HotLoanSortType.loanRate
        : HotLoanSortType.loanCount;
    setState(() {
      _hotLoanSort = nextSort;
      _cachedLists.remove(LibraryRankType.hotLoan);
    });
    unawaited(_loadRank(LibraryRankType.hotLoan, showBarLoading: true));
  }

  Future<void> _chooseNewBookCampus() async {
    final campus = await showLibraryCampusMenu(
      context,
      selectedCampus: _newBookCampus,
    );
    if (!mounted || campus == null || campus == _newBookCampus) return;
    _selectNewBookCampus(campus);
  }

  void _selectNewBookCampus(NewBookCampus campus) {
    if (_newBookCampus == campus) return;
    setState(() {
      _newBookCampus = campus;
      _cachedLists.remove(LibraryRankType.newBook);
    });
    unawaited(_loadRank(LibraryRankType.newBook, showBarLoading: true));
  }

  Future<void> _loadRank(
    LibraryRankType type, {
    bool force = false,
    bool showBarLoading = false,
  }) async {
    if (_loadingStates[type] == true) return;

    if (showBarLoading && mounted) {
      setState(() => _isNavLoading = true);
    }
    _loadingStates[type] = true;

    try {
      final books = await widget.apiClient.fetchRankList(
        type: type,
        page: 1,
        rows: _pageSize,
        session: widget.session,
        hotLoanSort: _hotLoanSort,
        newBookCampus: _newBookCampus,
      );
      if (!mounted) return;
      setState(() {
        _cachedLists[type] = books;
        _pageMap[type] = 1;
        _hasMoreMap[type] = books.length >= _pageSize;
      });
    } on Object {
      // 容错处理，展示已缓存或空状态
    } finally {
      _loadingStates[type] = false;
      if (mounted) {
        setState(() => _isNavLoading = false);
      }
    }
  }

  Future<void> _loadMore(LibraryRankType type) async {
    if (_loadingMoreStates[type] == true || _loadingStates[type] == true) {
      return;
    }
    if (_hasMoreMap[type] == false) {
      return;
    }

    final currentPage = _pageMap[type] ?? 1;
    final nextPage = currentPage + 1;
    setState(() {
      _loadingMoreStates[type] = true;
      _isNavLoading = true;
    });

    try {
      final newBooks = await widget.apiClient.fetchRankList(
        type: type,
        page: nextPage,
        rows: _pageSize,
        session: widget.session,
        hotLoanSort: _hotLoanSort,
        newBookCampus: _newBookCampus,
      );
      if (!mounted) return;
      setState(() {
        final existing = _cachedLists[type] ?? [];
        _cachedLists[type] = [...existing, ...newBooks];
        _pageMap[type] = nextPage;
        _hasMoreMap[type] = newBooks.length >= _pageSize;
      });
    } on Object {
      // 加载更多失败保持原状
    } finally {
      if (mounted) {
        setState(() {
          _loadingMoreStates[type] = false;
          _isNavLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final currentType = LibraryRankType.values[_tabController.index];

    return Scaffold(
      appBar: AppBar(
        title: const Text('图书榜单'),
        actions: [
          if (currentType == LibraryRankType.hotLoan)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: _hotLoanSort == HotLoanSortType.loanCount
                    ? '切换为按借阅比排序'
                    : '切换为按借阅次数排序',
                child: TextButton.icon(
                  key: const ValueKey('library-hotloan-sort-toggle'),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: _toggleHotLoanSort,
                  icon: Icon(
                    _hotLoanSort == HotLoanSortType.loanCount
                        ? Icons.numbers_rounded
                        : Icons.percent_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _hotLoanSort.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (currentType == LibraryRankType.newBook)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                key: const ValueKey('library-newbook-campus-filter'),
                tooltip: '选择校区',
                icon: Icon(
                  _newBookCampus == NewBookCampus.all
                      ? Icons.format_list_bulleted
                      : Icons.filter_alt_rounded,
                  color: _newBookCampus == NewBookCampus.all
                      ? colors.textPrimary
                      : colors.accent,
                ),
                onPressed: _chooseNewBookCampus,
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kTextTabBarHeight + 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isNavLoading)
                const LinearProgressIndicator(
                  key: ValueKey('rank-appbar-loading'),
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
                tabs: LibraryRankType.values
                    .map((type) => Tab(text: type.label))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: LibraryRankType.values.map((type) {
          return _buildTabView(context, colors, type);
        }).toList(),
      ),
    );
  }

  Widget _buildTabView(
    BuildContext context,
    ShuYoColors colors,
    LibraryRankType type,
  ) {
    final books = _cachedLists[type];
    final isLoading = _loadingStates[type] == true && books == null;

    if (isLoading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (books == null || books.isEmpty) {
      return Center(
        child: Text(
          '暂无${type.label}数据',
          style: TextStyle(
            fontSize: 14,
            color: colors.textMuted,
          ),
        ),
      );
    }

    if (type == LibraryRankType.newBook) {
      return RefreshIndicator(
        onRefresh: () => _loadRank(type, force: true, showBarLoading: false),
        child: NotificationListener<ScrollNotification>(
          onNotification: (scrollInfo) {
            final max = scrollInfo.metrics.maxScrollExtent;
            final current = scrollInfo.metrics.pixels;
            if (max > 0 && current >= max * 0.5) {
              unawaited(_loadMore(type));
            }
            return false;
          },
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: books.length,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: colors.border.withValues(alpha: 0.5),
            ),
            itemBuilder: (context, index) {
              final book = books[index];
              return _AnimatedRankBookRow(
                key: ValueKey(book.recordId),
                index: index,
                colors: colors,
                book: book,
                rankNumber: index + 1,
                showTopBadge: false,
                coverHeight: _coverHeight,
                coverWidth: _coverWidth,
                apiClient: widget.apiClient,
                session: widget.session,
              );
            },
          ),
        ),
      );
    }

    // 其它 3 个榜单（热门借阅、热门收藏、高分图书）：按 10 本一组加入吸顶分段 ("TOP 1-10", "TOP 11-20" 等)
    final slivers = <Widget>[];
    const groupSize = 10;
    for (var i = 0; i < books.length; i += groupSize) {
      final end = (i + groupSize).clamp(0, books.length);
      final subList = books.sublist(i, end);
      final startIndex = i;
      final label = 'TOP ${i + 1}-$end';

      slivers.add(
        SliverMainAxisGroup(
          key: ValueKey('${type.name}-group-$i'),
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _RankStickyHeaderDelegate(label: label),
            ),
            SliverList.separated(
              itemCount: subList.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: colors.border.withValues(alpha: 0.5),
              ),
              itemBuilder: (context, idx) {
                final globalIndex = startIndex + idx;
                final book = subList[idx];
                return _AnimatedRankBookRow(
                  key: ValueKey(book.recordId),
                  index: globalIndex,
                  colors: colors,
                  book: book,
                  rankNumber: globalIndex + 1,
                  coverHeight: _coverHeight,
                  coverWidth: _coverWidth,
                  hotLoanSort: type == LibraryRankType.hotLoan
                      ? _hotLoanSort
                      : HotLoanSortType.loanCount,
                  apiClient: widget.apiClient,
                  session: widget.session,
                );
              },
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadRank(type, force: true, showBarLoading: false),
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          final max = scrollInfo.metrics.maxScrollExtent;
          final current = scrollInfo.metrics.pixels;
          if (max > 0 && current >= max * 0.5) {
            unawaited(_loadMore(type));
          }
          return false;
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ...slivers,
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
        ),
      ),
    );
  }
}

class _RankStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _RankStickyHeaderDelegate({
    required this.label,
  });

  final String label;
  static const double _extent = 34.0;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = context.shuyoColors;
    final theme = Theme.of(context);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        height: _extent,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color:
                  colors.border.withValues(alpha: overlapsContent ? 0.6 : 0.25),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 12,
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_RankStickyHeaderDelegate oldDelegate) =>
      label != oldDelegate.label;
}

class _AnimatedRankBookRow extends StatefulWidget {
  const _AnimatedRankBookRow({
    super.key,
    required this.index,
    required this.colors,
    required this.book,
    required this.rankNumber,
    this.showTopBadge = true,
    required this.coverHeight,
    required this.coverWidth,
    this.hotLoanSort = HotLoanSortType.loanCount,
    this.apiClient,
    this.session,
  });

  final int index;
  final ShuYoColors colors;
  final LibraryBookItem book;
  final int rankNumber;
  final bool showTopBadge;
  final double coverHeight;
  final double coverWidth;
  final HotLoanSortType hotLoanSort;
  final LibraryApiClient? apiClient;
  final LibraryAuthSession? session;

  @override
  State<_AnimatedRankBookRow> createState() => _AnimatedRankBookRowState();
}

class _AnimatedRankBookRowState extends State<_AnimatedRankBookRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    final delayMs = (widget.index % 6) * 55;
    _entranceTimer = Timer(Duration(milliseconds: delayMs), () {
      if (mounted) _entrance.forward();
    });
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic),
      ),
      child: FadeTransition(
        opacity: _entrance,
        child: _buildContent(context),
      ),
    );
  }

  String? _buildBadgeText(LibraryBookItem book) {
    if (widget.hotLoanSort == HotLoanSortType.loanRate &&
        book.loanRate != null) {
      return '借阅比 ${(book.loanRate! * 100).toStringAsFixed(1)}%';
    }
    return book.badgeText;
  }

  Widget _buildContent(BuildContext context) {
    final colors = widget.colors;
    final book = widget.book;
    final rankNumber = widget.rankNumber;

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          shuyoRoute(
            builder: (context) => LibraryBookDetailPage(
              recordId: book.recordId,
              title: book.title,
              author: book.author,
              publisher: book.publisher,
              publishYear: book.publishYear,
              apiClient: widget.apiClient,
              session: widget.session,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCover(colors, book, rankNumber),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: widget.coverHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title.isNotEmpty ? book.title : '未知书名',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    LibraryAuthorText(
                      parsed: book.parsedAuthors,
                      fallbackText:
                          book.author?.isNotEmpty == true ? book.author! : '',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    if (_buildPublishRow(colors, book) != null) ...[
                      _buildPublishRow(colors, book)!,
                      const SizedBox(height: 3),
                    ],
                    if (book.rating != null && book.rating! > 0) ...[
                      const SizedBox(height: 3),
                      _buildStarRating(colors, book.rating!),
                    ] else if (_buildBadgeText(book) != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        _buildBadgeText(book)!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.accent,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const Spacer(),
                    Row(
                      children: [
                        if (book.totalHolding != null) ...[
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${book.onShelfHolding ?? 0}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colors.accent,
                                  ),
                                ),
                                TextSpan(
                                  text: '/${book.totalHolding}本',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (book.callNo != null && book.callNo!.isNotEmpty)
                          Expanded(
                            child: _buildCallNoRow(colors, book.callNo!),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: EdgeInsets.only(top: widget.coverHeight * 0.38),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallNoRow(ShuYoColors colors, String callNo) {
    final slashIndex = callNo.indexOf('/');
    if (slashIndex > 0) {
      final classNo = callNo.substring(0, slashIndex);
      final remaining = callNo.substring(slashIndex); // 如 "/TP181"
      return Text.rich(
        TextSpan(
          text: '索书号 ',
          style: TextStyle(
            fontSize: 13,
            color: colors.textSecondary,
          ),
          children: [
            TextSpan(
              text: classNo,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            const TextSpan(text: ' '),
            TextSpan(
              text: remaining,
              style: TextStyle(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text(
      '索书号 $callNo',
      style: TextStyle(
        fontSize: 13,
        color: colors.textSecondary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildStarRating(ShuYoColors colors, double rating) {
    final filledCount = rating.round().clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              i < filledCount ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 15,
              color: i < filledCount
                  ? colors.accent
                  : colors.textMuted.withValues(alpha: 0.6),
            ),
          ),
        const SizedBox(width: 4),
        Text(
          '${rating.toStringAsFixed(rating.truncateToDouble() == rating ? 0 : 1)}分',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.accent,
          ),
        ),
      ],
    );
  }

  Widget? _buildPublishRow(ShuYoColors colors, LibraryBookItem book) {
    final publisher = book.publisher?.trim() ?? '';
    final year = book.publishYear?.trim() ?? '';

    if (publisher.isEmpty && year.isEmpty) {
      return null;
    }

    return Text.rich(
      TextSpan(
        text: publisher,
        style: TextStyle(
          fontSize: 12,
          color: colors.textSecondary,
        ),
        children: [
          if (year.isNotEmpty) ...[
            if (publisher.isNotEmpty) const TextSpan(text: ' '),
            TextSpan(
              text: '($year)',
              style: TextStyle(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildCover(ShuYoColors colors, LibraryBookItem book, int rankNumber) {
    final coverUrl = book.coverUrl;
    final placeholder = Container(
      width: widget.coverWidth,
      height: widget.coverHeight,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: colors.textMuted,
          size: 26,
        ),
      ),
    );

    final coverWidget = (coverUrl == null || coverUrl.isEmpty)
        ? placeholder
        : ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              coverUrl,
              width: widget.coverWidth,
              height: widget.coverHeight,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return placeholder;
              },
            ),
          );

    if (!widget.showTopBadge || rankNumber > 3) {
      return coverWidget;
    }

    return Stack(
      children: [
        coverWidget,
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(
              'TOP $rankNumber',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
