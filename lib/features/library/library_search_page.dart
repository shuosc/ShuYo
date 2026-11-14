import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../course_recordings/recording_list_presentation.dart';
import 'library_book_list_tile.dart';
import 'library_search_controller.dart';

class LibrarySearchPage extends StatefulWidget {
  const LibrarySearchPage({
    super.key,
    required this.apiClient,
    this.session,
    this.controller,
  });

  final LibraryApiClient apiClient;
  final LibraryAuthSession? session;
  final LibrarySearchController? controller;

  @override
  State<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends State<LibrarySearchPage> {
  final _queryController = TextEditingController();
  final _queryState = ValueNotifier((hasText: false, hasKeyword: false));
  final _queryFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _searchBusy = ValueNotifier(false);
  late final bool _ownsController = widget.controller == null;
  late final LibrarySearchController _searchController = widget.controller ??
      LibrarySearchController(widget.apiClient, session: widget.session);
  late LibrarySearchViewData _view = LibrarySearchViewData(_searchController);
  final _bookRows = <int, (LibraryBookItem, Widget)>{};
  final _animatedBookIds = <int>{};
  ThemeData? _rowTheme;
  int _renderedRevision = -1;

  int get _revision => _searchController.revision;
  String? get _activeKeyword => _view.activeKeyword;
  Object? get _error => _view.error;
  bool get _searching => _view.searching;
  bool get _hasMore => _view.hasMore;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_updateQueryState);
    _searchController.addListener(_updateSearchChrome);
    _updateSearchChrome();
  }

  @override
  void didUpdateWidget(covariant LibrarySearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _searchController.updateSession(widget.session);
    }
  }

  void _updateQueryState() {
    final text = _queryController.text;
    _queryState.value =
        (hasText: text.isNotEmpty, hasKeyword: text.trim().isNotEmpty);
  }

  void _updateSearchChrome() {
    _searchBusy.value =
        _searchController.searching || _searchController.loadingMore;
  }

  @override
  void dispose() {
    _searchController.removeListener(_updateSearchChrome);
    if (_ownsController) {
      _searchController.dispose();
    }
    _searchBusy.dispose();
    _queryController.removeListener(_updateQueryState);
    _queryState.dispose();
    _queryController.dispose();
    _queryFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    if (_rowTheme != theme) {
      _rowTheme = theme;
      _bookRows.clear();
    }
  }

  void _clearSearch({bool clearField = true}) {
    if (clearField) _queryController.clear();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _searchController.clear();
  }

  Future<void> _search() async {
    final keyword = _queryController.text.trim();
    if (keyword.isEmpty) {
      _clearSearch();
      return;
    }
    _queryFocusNode.unfocus();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _searchController.search(keyword);
  }

  void _submitSearch() {
    unawaited(_search());
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      if (metrics.maxScrollExtent > 0 &&
          (metrics.pixels >= metrics.maxScrollExtent * 0.55 ||
              metrics.extentAfter < 500)) {
        unawaited(_searchController.loadMore());
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索图书'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: ValueListenableBuilder<bool>(
            valueListenable: _searchBusy,
            builder: (context, busy, _) => busy
                ? const LinearProgressIndicator(
                    key: ValueKey('library-search-progress'),
                    minHeight: 3,
                  )
                : const SizedBox(height: 3),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: ListenableBuilder(
              listenable: _queryState,
              builder: (context, child) => Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('library-search-query'),
                      controller: _queryController,
                      focusNode: _queryFocusNode,
                      onTapOutside: (_) => _queryFocusNode.unfocus(),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submitSearch(),
                      onChanged: (value) {
                        if (value.isEmpty) {
                          _clearSearch(clearField: false);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: '书名 / 作者 / ISBN / 索书号',
                        suffixIcon: !_queryState.value.hasText
                            ? null
                            : IconButton(
                                key: const ValueKey('library-search-clear'),
                                tooltip: '清空关键词',
                                onPressed: _clearSearch,
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    key: const ValueKey('library-search-submit'),
                    tooltip: '开始搜索',
                    onPressed: !_queryState.value.hasKeyword
                        ? null
                        : _submitSearch,
                    icon: Icon(
                      Icons.search,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: RecordingListPresentation(
              changes: _searchController,
              shouldUpdateImmediately: () =>
                  _renderedRevision != _revision ||
                  _searchController.books.isNotEmpty,
              builder: (context) {
                _view = LibrarySearchViewData(_searchController);
                if (_renderedRevision != _revision) {
                  _renderedRevision = _revision;
                  _bookRows.clear();
                  _animatedBookIds.clear();
                }
                return Column(
                  children: [
                    _buildSummary(),
                    Expanded(child: _buildResults()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    Widget number(String key, int value, Color color, double size) => Text(
          '$value',
          key: ValueKey(key),
          maxLines: 1,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );

    return Padding(
      key: const ValueKey('library-search-summary'),
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              key: const ValueKey('library-search-scope-label'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '馆藏范围',
                  maxLines: 1,
                  style: ShuYoTextStyles.bodyCompact(color: colors.textPrimary)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  _activeKeyword == null ? '仅检索图书' : '图书 · $_activeKeyword',
                  key: const ValueKey('library-search-keyword-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShuYoTextStyles.bodyCompact(color: primary)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '图书数',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        number(
                          'library-search-loaded-count',
                          _view.books.length,
                          primary,
                          26,
                        ),
                        Text(
                          '/',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        number(
                          'library-search-total-count',
                          _view.numFound,
                          colors.textPrimary,
                          18,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final view = _view;
    final books = view.books;
    final colors = context.shuyoColors;

    Widget? state;
    if (_error != null) {
      state = EmptyState(
        icon: Icons.cloud_off_outlined,
        title: '图书搜索失败',
        message: _errorMessage(),
        action: TextButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    } else if (_searching) {
      state = const Center(child: Text('正在搜索图书…'));
    } else if (!view.hasResults) {
      state = EmptyState(
        icon: _activeKeyword == null ? Icons.search : Icons.search_off,
        title: _activeKeyword == null ? '搜索馆藏图书' : '没有找到相关图书',
        message: _activeKeyword == null
            ? '输入书名、作者、ISBN 或索书号关键词后点击搜索。'
            : '试试其他关键词后重新搜索。',
      );
    }

    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          colors.textMuted.withValues(alpha: 0.55),
        ),
        thickness: const WidgetStatePropertyAll(2.5),
        radius: const Radius.circular(4),
      ),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        interactive: true,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            key: const ValueKey('library-search-results'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (state != null)
                SliverFillRemaining(hasScrollBody: false, child: state)
              else ...[
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList.builder(
                  itemCount: books.isEmpty ? 0 : books.length * 2 - 1,
                  itemBuilder: (context, index) {
                    if (index.isOdd) {
                      return Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: colors.border.withValues(alpha: 0.5),
                      );
                    }
                    final bookIndex = index ~/ 2;
                    final book = books[bookIndex];
                    final cached = _bookRows[book.recordId];
                    final row = cached != null && identical(cached.$1, book)
                        ? cached.$2
                        : LibraryBookListTile(
                            key: ValueKey(
                              'library-search-book:${book.recordId}',
                            ),
                            book: book,
                            apiClient: widget.apiClient,
                            session: widget.session,
                          );
                    _bookRows[book.recordId] = (book, row);
                    final firstAppearance = _animatedBookIds.add(book.recordId);
                    final scrolling = _scrollController.hasClients &&
                        _scrollController.position.isScrollingNotifier.value;
                    return _SearchBookEntrance(
                      key: ValueKey((view.revision, book.recordId)),
                      animate: firstAppearance && !scrolling,
                      child: row,
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: _buildFooter(colors, view),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ShuYoColors colors, LibrarySearchViewData view) {
    if (view.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Center(
          child: TextButton.icon(
            key: const ValueKey('library-search-load-more-retry'),
            onPressed: () =>
                unawaited(_searchController.loadMore(userRetry: true)),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('加载更多失败，点击重试'),
          ),
        ),
      );
    }

    if (!_hasMore && view.books.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Center(
          child: Text(
            '已显示全部 ${view.books.length} 本图书',
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ),
      );
    }

    return const SizedBox(height: 24);
  }

  String _errorMessage() {
    final error = _error;
    if (error is LibraryApiException) {
      return error.message;
    }
    return '暂时无法连接图书馆检索服务，请稍后重试。';
  }
}

class _SearchBookEntrance extends StatefulWidget {
  const _SearchBookEntrance({
    super.key,
    required this.animate,
    required this.child,
  });

  final bool animate;
  final Widget child;

  @override
  State<_SearchBookEntrance> createState() => _SearchBookEntranceState();
}

class _SearchBookEntranceState extends State<_SearchBookEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController? _controller = widget.animate
      ? AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )
      : null;
  late final Animation<double> _opacity =
      _controller!.drive(CurveTween(curve: Curves.easeOutCubic));
  late final Animation<Offset> _position =
      _opacity.drive(Tween(begin: const Offset(.12, 0), end: Offset.zero));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = _controller;
    if (controller == null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = 1;
    } else if (!controller.isAnimating && controller.value < 1) {
      controller.forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : SlideTransition(
          position: _position,
          child: FadeTransition(opacity: _opacity, child: widget.child),
        );
}
