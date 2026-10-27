import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        RenderEditable,
        RenderSliver,
        RenderSliverList,
        ScrollCacheExtent,
        SliverMultiBoxAdaptorParentData;
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/announcement.dart';
import '../../data/models/announcement_source.dart';
import '../../data/models/announcement_target.dart';
import '../../data/repositories/announcement_repository.dart';
import '../../data/services/announcement_api_client.dart';
import '../../data/services/announcement_order.dart';
import '../../data/services/announcement_search_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/fullscreen_image_page.dart';
import '../../shared/widgets/date_range_picker.dart';
import 'announcement_search_matches.dart';

/// Horizontal padding of the detail body, also used hui derive the image decode
/// width.
const double _announcementDetailPadding = 20;

/// Height reserved until an image is decoded, so the body does not jump from
/// zero height when the image arrives.
const double _announcementImagePlaceholderHeight = 180;

/// Frame budget for waiting on the push animation, roughly 1.5 seconds, kept
/// only as a safety net.
const int _maximumAnimationFrames = 90;

const _announcementMatchScrollDuration = Duration(milliseconds: 450);

String _breakableInlineLinkText(String text, String url) {
  final lowerText = text.toLowerCase();
  final lowerUrl = url.toLowerCase();
  final isAddress = lowerUrl.startsWith('mailto:') && text.contains('@');
  final isUrl =
      (lowerUrl.startsWith('http://') || lowerUrl.startsWith('https://')) &&
          (lowerText.startsWith('http://') ||
              lowerText.startsWith('https://') ||
              lowerText.startsWith('www.'));
  if (!isAddress && !isUrl) return text;

  final runes = text.runes.toList();
  final schemeEnd = lowerText.startsWith('http://')
      ? 7
      : lowerText.startsWith('https://')
          ? 8
          : 0;
  final result = StringBuffer();
  var runLength = 0;
  for (var index = 0; index < runes.length; index++) {
    final character = String.fromCharCode(runes[index]);
    result.write(character);
    if (index + 1 == runes.length) continue;
    runLength++;
    if (index + 1 < schemeEnd) continue;
    if ('./@_-?&=#'.contains(character) || runLength >= 4) {
      result.write('\u200B');
      runLength = 0;
    }
  }
  return result.toString();
}

@visibleForTesting
const announcementImagePlaceholderKey =
    ValueKey<String>('announcement-image-placeholder');

@visibleForTesting
const announcementSourceMenuKey = ValueKey<String>('announcement-source-menu');

class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({
    super.key,
    required this.repository,
    this.isDemo = false,
  });

  final AnnouncementRepository repository;
  final bool isDemo;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  final ScrollController _scrollController = ScrollController();
  AnnouncementSource? _source;
  _LoadedAnnouncementList? _loaded;
  Object? _loadError;
  bool _isBusy = true;
  bool _isPullRefreshing = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _loadMoreCheckScheduled = false;
  int _requestGeneration = 0;
  final ValueNotifier<bool> _updatesPaused = ValueNotifier(false);
  Completer<void>? _listVisibilityGate;
  final Set<_AnnouncementItemRow> _preparingCards = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  @override
  void dispose() {
    _requestGeneration++;
    _cancelCardPreparation();
    _listVisibilityGate?.complete();
    _listVisibilityGate = null;
    _updatesPaused.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    AnnouncementSource source;
    try {
      source = await widget.repository.defaultSource();
    } on Object {
      source = AnnouncementSource.official;
    }
    if (!mounted) return;
    setState(() => _source = source);
    await _fetchPage(source, forceRefresh: true);
  }

  Future<_LoadedAnnouncementList> _loadList(
    AnnouncementSource source, {
    bool forceRefresh = false,
    bool loadNextPage = false,
  }) async {
    final items = await widget.repository.fetchAnnouncements(
      source: source,
      forceRefresh: forceRefresh,
      loadNextPage: loadNextPage,
    );
    final sorted = orderAnnouncements(items);
    // Refreshes own new card states; pagination preserves entered presentations.
    final previous = loadNextPage ? _loaded?.cardsByUrl : null;
    // Enrichment must not move an article that is already on screen.
    final ordered = previous == null
        ? sorted
        : [
            for (final row in _loaded!.cards) row.item,
            for (final item in sorted)
              if (!previous.containsKey(item.url)) item,
          ];
    final loaded = _LoadedAnnouncementList(ordered, [
      for (var index = 0; index < ordered.length; index++)
        _AnnouncementItemRow(
          index,
          ordered[index],
          presentation: previous?[ordered[index].url]?.presentation,
        ),
    ]);
    // Prepare ahead in parallel, but publish as soon as the first card settles.
    await _prepareCards(loaded);
    return loaded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_source == null || _source == AnnouncementSource.official
            ? '通知公告'
            : _source!.name),
        actions: [
          IconButton(
            tooltip: '搜索公告',
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
          ),
          if (!widget.isDemo)
            IconButton(
              tooltip: '选择公告来源',
              onPressed: _source == null ? null : _chooseSource,
              icon: const Icon(Icons.format_list_bulleted),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child:
              (_isBusy || (_loaded?.preparing ?? false)) && !_isPullRefreshing
                  ? const LinearProgressIndicator(minHeight: 3)
                  : const SizedBox(height: 3),
        ),
      ),
      body: _buildList(),
    );
  }

  Widget _buildSourceInfo() {
    final source = _source;
    if (source == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        '通知来源：${source.name} ${Uri.parse(source.listUrl).host}',
        textAlign: TextAlign.center,
        style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
      ),
    );
  }

  Widget _buildList() {
    final loaded = _loaded;
    if (loaded == null) {
      final error = _loadError;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSourceInfo(),
          Expanded(
            child: error == null
                ? const _AnnouncementLoadingState()
                : _AnnouncementErrorState(
                    message: _friendlyError(error),
                    onRetry: _refresh,
                  ),
          ),
        ],
      );
    }
    final items = loaded.items;
    if (items.isEmpty) {
      return _withAnnouncementScrollbar(
        RefreshIndicator(
          onRefresh: () => _refresh(isPullRefresh: true),
          child: ListView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _buildSourceInfo(),
              const SizedBox(height: 96),
              const EmptyState(
                icon: Icons.campaign_outlined,
                title: '暂无公告',
                message: '该来源暂时没有可展示的通知公告。',
              ),
            ],
          ),
        ),
      );
    }
    final rows = loaded.rows;
    return _withAnnouncementScrollbar(
      RefreshIndicator(
        onRefresh: () => _refresh(isPullRefresh: true),
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          scrollCacheExtent: const ScrollCacheExtent.pixels(0),
          slivers: _homeSlivers(rows),
        ),
      ),
    );
  }

  List<Widget> _homeSlivers(List<Object> rows) {
    final slivers = <Widget>[
      SliverToBoxAdapter(child: _buildSourceInfo()),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
    var position = 0;
    while (position < rows.length) {
      _AnnouncementMonthHeader? header;
      if (rows[position] is _AnnouncementMonthHeader) {
        header = rows[position] as _AnnouncementMonthHeader;
        position++;
      }
      final start = position;
      while (position < rows.length && rows[position] is _AnnouncementItemRow) {
        position++;
      }
      final end = position;
      if (start == end) continue;
      final group = rows.sublist(start, end).cast<_AnnouncementItemRow>();
      final indices = {
        for (var index = 0; index < group.length; index++)
          group[index].presentation.key: index,
      };
      final itemList = SliverList.builder(
        // Refresh the extent estimate even when the old tail is off screen.
        key: ValueKey(group.length),
        itemCount: group.length,
        findChildIndexCallback: (key) => indices[key],
        itemBuilder: (context, index) {
          final itemRow = group[index];
          final item = itemRow.item;
          return Column(
            key: itemRow.presentation.key,
            mainAxisSize: MainAxisSize.min,
            children: [
              _AnnouncementTile(
                key: ValueKey(item.url),
                index: itemRow.index,
                item: item,
                external: itemRow.external,
                updatesPaused: _updatesPaused,
                presentation: itemRow.presentation,
                onTap: () => unawaited(_openAnnouncement(item)),
              ),
              if (index + 1 < end - start &&
                  CustomBackgroundScope.maybeOf(context) == null)
                Divider(height: 1, color: context.shuyoColors.border),
            ],
          );
        },
      );
      if (header == null) {
        slivers.add(itemList);
      } else {
        // Appending prepared cards must not fade an already entered month.
        var visibleCard = group.first.presentation;
        for (final row in group) {
          final candidate = row.presentation;
          if (candidate.entrance.value > visibleCard.entrance.value) {
            visibleCard = candidate;
          }
        }
        slivers.add(SliverMainAxisGroup(slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _AnnouncementStickyHeaderDelegate(
              month: header.label,
              opacity: visibleCard.entrance,
            ),
          ),
          itemList,
        ]));
      }
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return slivers;
  }

  Widget _withAnnouncementScrollbar(Widget child) {
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          context.shuyoColors.textMuted.withValues(alpha: 0.55),
        ),
        thickness: const WidgetStatePropertyAll(2.5),
        radius: const Radius.circular(4),
      ),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        interactive: true,
        child: child,
      ),
    );
  }

  void _cancelCardPreparation() {
    for (final row in _preparingCards.toList()) {
      widget.repository.cancelCard(row.item);
    }
  }

  Future<void> _prepareCards(_LoadedAnnouncementList loaded) {
    if (loaded.preparing) return Future.value();
    final pending = loaded.cards
        .where((row) => row.presentation.card == null)
        .take(6)
        .toList();
    if (pending.isEmpty) return Future.value();
    final generation = _requestGeneration;
    loaded.preparing = true;
    if (identical(_loaded, loaded)) setState(() {});
    final work = [
      for (final row in pending)
        () async {
          AnnouncementCardData card;
          _preparingCards.add(row);
          try {
            card = await widget.repository.loadCard(row.item);
          } on Object {
            card = AnnouncementCardData.fromItem(row.item);
          } finally {
            _preparingCards.remove(row);
          }
          if (!await _waitForListVisibility(generation)) return;
          final previousCount = loaded.visibleCount;
          row.presentation.card = card;
          // Only append a ready prefix. A later result can never insert content
          // above entered cards or change their height, even while transparent.
          if (identical(_loaded, loaded) &&
              loaded.visibleCount != previousCount) {
            setState(() {});
          }
        }(),
    ];
    unawaited(Future.wait(work).whenComplete(() {
      loaded.preparing = false;
      if (mounted && identical(_loaded, loaded)) {
        setState(() {});
        _scheduleLoadMoreCheck();
      }
    }));
    return work.first;
  }

  void _onScroll() {
    if (_updatesPaused.value || !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.extentAfter > 280 || _isBusy) {
      return;
    }
    final loaded = _loaded;
    if (loaded == null || loaded.preparing) return;
    if (loaded.visibleCount < loaded.cards.length) {
      unawaited(_prepareCards(loaded));
    } else if (_hasMore && !_loadingMore) {
      unawaited(_loadNextPage());
    }
  }

  Future<void> _chooseSource() async {
    Set<String> favorites;
    AnnouncementMenuExpansion expansion;
    try {
      final settings = await Future.wait<Object>([
        widget.repository.favoriteSourceIds(),
        widget.repository.menuExpansion(),
      ]);
      favorites = settings[0] as Set<String>;
      expansion = settings[1] as AnnouncementMenuExpansion;
    } on Object {
      favorites = <String>{};
      expansion = (
        favorites: true,
        schoolPortal: true,
        administrativeDepartment: true,
        affiliatedInstitution: true,
        college: false,
        researchInstitute: false,
      );
    }
    if (!mounted || _source == null) return;
    final choice = await showGeneralDialog<AnnouncementSource>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭公告来源菜单',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.18, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      pageBuilder: (menuContext, animation, secondaryAnimation) => SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
            child: _AnnouncementSourceMenu(
              selected: _source!,
              initialFavorites: favorites,
              initialExpansion: expansion,
              onToggleFavorite: widget.repository.toggleFavoriteSource,
              onExpansionChanged: widget.repository.saveMenuExpansion,
              onSelect: (source) => Navigator.of(menuContext).pop(source),
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    _cancelCardPreparation();
    setState(() {
      _source = choice;
      _loaded = null;
      _loadError = null;
      _hasMore = false;
      _isBusy = true;
      _isPullRefreshing = false;
    });
    await _fetchPage(choice, forceRefresh: true);
  }

  Future<void> _refresh({bool isPullRefresh = false}) async {
    final source = _source;
    if (source == null || _isBusy || _updatesPaused.value) return;
    await _fetchPage(source, forceRefresh: true, isPullRefresh: isPullRefresh);
  }

  Future<void> _loadNextPage() async {
    final source = _source;
    if (source == null ||
        !_hasMore ||
        _isBusy ||
        _loadingMore ||
        _updatesPaused.value) {
      return;
    }
    final generation = _requestGeneration;
    setState(() {
      _loadingMore = true;
      _isBusy = true;
    });
    _LoadedAnnouncementList? result;
    Object? failure;
    var hasMore = false;
    try {
      final loaded = await _loadList(source, loadNextPage: true);
      hasMore = widget.repository.hasMoreAnnouncements(source: source);
      result = loaded;
    } on Object catch (error) {
      failure = error;
    }
    if (!await _waitForListVisibility(generation) || !mounted) return;
    setState(() {
      _loadingMore = false;
      _isBusy = false;
      if (result != null) {
        _loaded = result;
        _hasMore = hasMore;
      }
    });
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(failure))),
      );
    }
    _scheduleLoadMoreCheck();
  }

  void _scheduleLoadMoreCheck() {
    if (_loadMoreCheckScheduled) return;
    _loadMoreCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreCheckScheduled = false;
      if (mounted) _onScroll();
    });
  }

  Future<void> _fetchPage(
    AnnouncementSource source, {
    bool forceRefresh = false,
    bool isPullRefresh = false,
  }) async {
    final generation = ++_requestGeneration;
    _cancelCardPreparation();
    setState(() {
      _isBusy = true;
      _isPullRefreshing = isPullRefresh;
      _loadError = null;
      _loadingMore = false;
    });
    _LoadedAnnouncementList? result;
    Object? failure;
    var hasMore = false;
    try {
      final loaded = await _loadList(source, forceRefresh: forceRefresh);
      hasMore = widget.repository.hasMoreAnnouncements(source: source);
      result = loaded;
    } on Object catch (error) {
      failure = error;
    }
    if (!await _waitForListVisibility(generation) || !mounted) return;
    final showError = failure != null && _loaded != null;
    setState(() {
      _isBusy = false;
      _isPullRefreshing = false;
      if (result != null) {
        _loaded = result;
        _hasMore = hasMore;
      } else if (_loaded == null) {
        _loadError = failure;
      }
    });
    if (showError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(failure))),
      );
    }
    if (_loaded != null) _scheduleLoadMoreCheck();
  }

  Future<void> _openSearch() async {
    if (_updatesPaused.value) return;
    final gate = Completer<void>();
    _listVisibilityGate = gate;
    _updatesPaused.value = true;
    final route = shuyoRoute<void>(
      builder: (context) => AnnouncementSearchPage(
        repository: widget.repository,
        isDemo: widget.isDemo,
      ),
    );
    try {
      await Navigator.of(context).push<void>(route);
      if (route is TransitionRoute<void>) await route.completed;
    } finally {
      if (mounted) {
        _listVisibilityGate = null;
        _updatesPaused.value = false;
        if (!gate.isCompleted) gate.complete();
        _scheduleLoadMoreCheck();
      }
    }
  }

  Future<bool> _waitForListVisibility(int generation) async {
    final gate = _listVisibilityGate;
    if (gate != null) await gate.future;
    return mounted && generation == _requestGeneration;
  }

  Future<void> _openAnnouncement(AnnouncementListItem item) async {
    final target =
        AnnouncementTarget.resolve(item.url, sourceId: item.sourceId);
    if (!target.canOpenInApp) {
      await _openExternalAnnouncementUrl(context, item.url);
      return;
    }
    if (_updatesPaused.value) return;
    final gate = Completer<void>();
    _listVisibilityGate = gate;
    _updatesPaused.value = true;
    final route = shuyoRoute<void>(
      builder: (context) => AnnouncementDetailPage(
        repository: widget.repository,
        item: item,
      ),
    );
    try {
      await Navigator.of(context).push<void>(route);
      // A pop completes the push Future before its reverse animation finishes.
      // Keep preview/layout work out of both route transitions.
      if (route is TransitionRoute<void>) await route.completed;
    } finally {
      if (mounted) {
        _listVisibilityGate = null;
        _updatesPaused.value = false;
        if (!gate.isCompleted) gate.complete();
        _scheduleLoadMoreCheck();
      }
    }
  }

  String _friendlyError(Object error) {
    if (error is AnnouncementApiException) {
      return error.message;
    }
    return '通知公告加载失败，请稍后重试';
  }
}

class AnnouncementSearchPage extends StatefulWidget {
  const AnnouncementSearchPage({
    super.key,
    required this.repository,
    this.isDemo = false,
    this.searchService,
  });

  final AnnouncementRepository repository;
  final bool isDemo;
  final AnnouncementSearchService? searchService;

  @override
  State<AnnouncementSearchPage> createState() => _AnnouncementSearchPageState();
}

enum _SearchTimePreset { all, week, month, year, custom }

Future<T?> _showAnnouncementFilterMenu<T>({
  required BuildContext context,
  required String barrierLabel,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.18, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        )),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
          child: builder(context),
        ),
      ),
    ),
  );
}

class _AnnouncementFilterPanel extends StatelessWidget {
  const _AnnouncementFilterPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: math.min(264.0, MediaQuery.sizeOf(context).width * 0.68),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context).colorScheme.surface,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: child,
          ),
        ),
      );
}

class _AnnouncementSearchPageState extends State<AnnouncementSearchPage> {
  static final Map<String, int> _sourceOrder = {
    for (final entry in [
      ...AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolPortal),
      ...AnnouncementSource.inGroup(
          AnnouncementSourceGroup.administrativeDepartment),
      ...AnnouncementSource.inGroup(
          AnnouncementSourceGroup.affiliatedInstitution),
      for (final category in AnnouncementCollegeCategory.values)
        ...AnnouncementSource.inCollegeCategory(category),
      ...AnnouncementSource.inGroup(AnnouncementSourceGroup.researchInstitute),
    ].asMap().entries)
      entry.value.id: entry.key,
  };
  static const _includeBodyKey = 'announcements.search.includeBody';
  static const _includeTitleKey = 'announcements.search.includeTitle';
  static const _selectedSourcesKey = 'announcements.search.selectedSources';
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocusNode = FocusNode();
  final ScrollController _resultsScrollController = ScrollController();
  String _activeQuery = '';
  bool _activeIncludeTitle = true;
  bool _activeIncludeBody = false;
  Set<String> _activeSelectedSourceIds = {};
  DateTimeRange? _dateRange;
  DateTimeRange? _activeDateRange;
  _SearchTimePreset _timePreset = _SearchTimePreset.all;
  final Map<String, int> _resultIndexByKey = {};
  final Map<String, _AnnouncementCardPresentation> _cardPresentations = {};
  final Map<String, AnnouncementListItem> _preparingSearchCards = {};
  final Map<String, AnnouncementCardData> _settledSearchCards = {};
  bool _searchCardCheckScheduled = false;
  final List<AnnouncementListItem> _results = [];
  final Map<String, List<AnnouncementListItem>> _resultsBySource = {};
  List<Widget> _resultSlivers = const [];
  final Map<String, Widget> _sourceSlivers = {};
  final Map<String, int> _visibleSearchCounts = {};
  final Set<String> _publishedSearchKeys = {};
  final Map<String, AnnouncementListItem> _pendingMatches = {};
  AnnouncementSearchService? _searchService;
  bool _ownsSearchService = false;
  AnnouncementSearchRun? _session;
  StreamSubscription<AnnouncementSearchProgress>? _subscription;
  AnnouncementSearchProgress? _pendingProgress;
  Timer? _progressTimer;
  bool _progressFrameScheduled = false;
  bool _resultsScrolling = false;
  bool _includeBody = false;
  bool _includeTitle = true;
  bool _started = false;
  bool _searching = false;
  bool _failureNoticeShown = false;
  final ValueNotifier<bool> _updatesPaused = ValueNotifier(false);
  bool get _detailRouteOpen => _updatesPaused.value;
  bool _searchStreamDone = false;
  String? _pendingSearchError;
  int _generation = 0;
  int _discoveredArticles = 0;
  bool _settingsTouched = false;
  bool _selectionTouched = false;
  Set<String> _selectedSourceIds = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _resultsScrollController.addListener(_scheduleSearchCardCheck);
    if (!widget.isDemo) {
      _ownsSearchService = widget.searchService == null;
      _searchService = widget.searchService ?? AnnouncementSearchService();
    }
    unawaited(_loadSearchSettings());
    unawaited(_loadSelectedSources());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resultSlivers = const [];
    _sourceSlivers.clear();
  }

  @override
  void didUpdateWidget(covariant AnnouncementSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      for (final item in _preparingSearchCards.values.toList()) {
        oldWidget.repository.cancelCard(item);
      }
      _preparingSearchCards.clear();
      _settledSearchCards.clear();
      _generation++;
      _session?.cancel();
      final subscription = _subscription;
      if (subscription != null) unawaited(subscription.cancel());
      _session = null;
      _subscription = null;
      _progressTimer?.cancel();
      _progressTimer = null;
      _pendingProgress = null;
      _pendingMatches.clear();
      _searchStreamDone = true;
      _searching = false;
      _cardPresentations.clear();
      _publishedSearchKeys.clear();
      _resultSlivers = const [];
      _sourceSlivers.clear();
      _visibleSearchCounts.clear();
      _scheduleSearchCardCheck();
    }
  }

  Future<void> _loadSelectedSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_selectedSourcesKey);
      if (!mounted || _selectionTouched || saved == null) return;
      final validIds = AnnouncementSource.all
          .where((source) => source.supportsSearch)
          .map((source) => source.id)
          .toSet();
      final selected = saved.toSet().intersection(validIds);
      setState(() => _selectedSourceIds = selected);
      if (selected.length != saved.toSet().length) {
        await _saveSelectedSources();
      }
    } on Object {
      // Keep no sources selected when local settings are unavailable.
    }
  }

  Future<void> _loadSearchSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _settingsTouched) return;
      setState(() {
        _includeTitle = prefs.getBool(_includeTitleKey) ?? true;
        _includeBody = prefs.getBool(_includeBodyKey) ?? false;
      });
    } on Object {
      // Keep the defaults if local settings are unavailable.
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancelSearchCardPreparation();
    _progressTimer?.cancel();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _session?.cancel();
    if (_ownsSearchService) _searchService?.dispose();
    _pendingMatches.clear();
    _updatesPaused.dispose();
    _queryFocusNode.dispose();
    _queryController.dispose();
    _resultsScrollController
      ..removeListener(_scheduleSearchCardCheck)
      ..dispose();
    super.dispose();
  }

  void _startSearch() {
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入搜索关键词')),
      );
      return;
    }
    if (!_includeTitle && !_includeBody) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个搜索范围')),
      );
      return;
    }
    if (_selectedSourceIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个部门')),
      );
      return;
    }
    _queryFocusNode.unfocus();
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
    _activeQuery = query;
    _activeIncludeTitle = _includeTitle;
    _activeIncludeBody = _includeBody;
    _activeSelectedSourceIds = {..._selectedSourceIds};
    _activeDateRange = _dateRange;
    final generation = ++_generation;
    _cancelSearchCardPreparation();
    _resultsScrolling = false;
    final oldSubscription = _subscription;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _subscription = null;
    _session?.cancel();
    _session = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    _pendingProgress = null;
    _pendingMatches.clear();
    setState(() {
      _resultIndexByKey.clear();
      _cardPresentations.clear();
      _publishedSearchKeys.clear();
      _results.clear();
      _resultsBySource.clear();
      _resultSlivers = const [];
      _sourceSlivers.clear();
      _started = true;
      _searching = true;
      _failureNoticeShown = false;
      _discoveredArticles = 0;
      _error = null;
      _searchStreamDone = false;
      _pendingSearchError = null;
    });
    if (widget.isDemo) {
      unawaited(_searchDemo(query, generation));
      return;
    }
    try {
      final session = _searchService!.startSearch(
        query: query,
        includeTitle: _activeIncludeTitle,
        includeBody: _activeIncludeBody,
        dateRange: _activeDateRange == null
            ? null
            : AnnouncementSearchDateRange(
                begin: _activeDateRange!.start,
                end: _activeDateRange!.end,
              ),
        sources: AnnouncementSource.all
            .where((source) =>
                source.supportsSearch &&
                _activeSelectedSourceIds.contains(source.id))
            .toList(),
      );
      _session = session;
      _subscription = session.updates.listen(
        (progress) => _queueProgress(progress, generation),
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted || generation != _generation) return;
          _progressTimer?.cancel();
          _pendingSearchError = '搜索失败，请重试';
          _searchStreamDone = true;
          _flushProgress(generation);
        },
        onDone: () {
          if (!mounted || generation != _generation) return;
          _progressTimer?.cancel();
          _searchStreamDone = true;
          _flushProgress(generation);
        },
      );
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '搜索失败，请重试';
        _searching = false;
      });
    }
  }

  void _queueProgress(AnnouncementSearchProgress progress, int generation) {
    if (!mounted || generation != _generation) return;
    _pendingProgress = progress;
    for (final item in progress.newMatches) {
      _pendingMatches[_searchResultKey(item)] = item;
    }
    if (_detailRouteOpen) return;
    if (progress.isFinished) {
      _progressTimer?.cancel();
      _flushProgress(generation);
      return;
    }
    _progressTimer ??= Timer(
      const Duration(milliseconds: 250),
      () => _flushProgress(generation),
    );
  }

  String _searchResultKey(AnnouncementListItem item) =>
      '${item.sourceId}\u0000${item.url}\u0000${item.title.trim().toLowerCase()}';

  int _compareSearchDate(AnnouncementListItem a, AnnouncementListItem b) {
    final left = _cardPresentations[_searchResultKey(a)]?.card?.publishedAt ??
        a.publishedAt;
    final right = _cardPresentations[_searchResultKey(b)]?.card?.publishedAt ??
        b.publishedAt;
    if (left == null) return right == null ? 0 : 1;
    if (right == null) return -1;
    return right.compareTo(left);
  }

  void _insertSortedResult(AnnouncementListItem item) {
    final items = _resultsBySource.putIfAbsent(item.sourceId, () => []);
    var low = 0;
    var high = items.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_compareSearchDate(items[middle], item) <= 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    items.insert(low, item);
  }

  bool _upsertSearchResult(AnnouncementListItem item) {
    final key = _searchResultKey(item);
    final index = _resultIndexByKey[key];
    if (index == null) {
      _resultIndexByKey[key] = _results.length;
      _results.add(item);
    } else {
      final old = _results[index];
      if (identical(old, item)) return false;
      _resultsBySource[old.sourceId]?.remove(old);
      _results[index] = item;
    }
    _insertSortedResult(item);
    return true;
  }

  Set<String> _mergePendingMatches() {
    if (_pendingMatches.isEmpty) return const <String>{};
    final changedSources = <String>{};
    final additionsBySource = <String, List<AnnouncementListItem>>{};
    final replacedKeysBySource = <String, Set<String>>{};
    // A fast connection can finish many pages before the UI gets a frame.
    // Bound each application batch instead of draining the entire backlog in
    // the final progress callback.
    final entries = _pendingMatches.entries.take(100).toList();
    for (final entry in entries) {
      final item = entry.value;
      final index = _resultIndexByKey[entry.key];
      if (index == null) {
        _resultIndexByKey[entry.key] = _results.length;
        _results.add(item);
      } else {
        final previous = _results[index];
        if (identical(previous, item)) continue;
        _results[index] = item;
        replacedKeysBySource
            .putIfAbsent(previous.sourceId, () => <String>{})
            .add(entry.key);
      }
      changedSources.add(item.sourceId);
      additionsBySource.putIfAbsent(item.sourceId, () => []).add(item);
    }
    for (final entry in entries) {
      _pendingMatches.remove(entry.key);
    }
    if (changedSources.isEmpty) return changedSources;

    int compare(AnnouncementListItem a, AnnouncementListItem b) {
      final byDate = _compareSearchDate(a, b);
      return byDate != 0
          ? byDate
          : _resultIndexByKey[_searchResultKey(a)]!
              .compareTo(_resultIndexByKey[_searchResultKey(b)]!);
    }

    for (final entry in additionsBySource.entries) {
      final additions = entry.value..sort(compare);
      final replacedKeys = replacedKeysBySource[entry.key];
      final existing = _resultsBySource[entry.key] ?? const [];
      final retained = replacedKeys == null
          ? existing
          : existing
              .where((item) => !replacedKeys.contains(_searchResultKey(item)))
              .toList();
      final merged = <AnnouncementListItem>[];
      var previous = 0;
      var next = 0;
      while (previous < retained.length && next < additions.length) {
        if (compare(retained[previous], additions[next]) <= 0) {
          merged.add(retained[previous++]);
        } else {
          merged.add(additions[next++]);
        }
      }
      merged.addAll(retained.skip(previous));
      merged.addAll(additions.skip(next));
      _resultsBySource[entry.key] = merged;
    }
    return changedSources;
  }

  void _rebuildResultRows({Set<String>? changedSources}) {
    if (changedSources == null) {
      _sourceSlivers.clear();
      _visibleSearchCounts.clear();
    }
    final sourceIds = _resultsBySource.keys.toList()
      ..sort((a, b) {
        final byOrder = (_sourceOrder[a] ?? _sourceOrder.length)
            .compareTo(_sourceOrder[b] ?? _sourceOrder.length);
        return byOrder != 0 ? byOrder : a.compareTo(b);
      });
    var blocked = false;
    for (final sourceId in sourceIds) {
      final rows = <Object>[];
      var index = 0;
      String? previousMonth;
      for (final item in _resultsBySource[sourceId]!) {
        final key = _searchResultKey(item);
        final presentation = _cardPresentations.putIfAbsent(
            key, _AnnouncementCardPresentation.new);
        final card = presentation.card;
        if (card == null) {
          blocked = true;
          continue;
        }
        if (blocked && !_publishedSearchKeys.contains(key)) continue;
        _publishedSearchKeys.add(key);
        final date = card.publishedAt ?? item.publishedAt;
        final month = date == null ? null : '${date.year}年${date.month}月';
        if (month != null && month != previousMonth) {
          rows.add(_AnnouncementMonthHeader(month));
        }
        previousMonth = month;
        rows.add(_AnnouncementItemRow(index, item, presentation: presentation));
        index++;
      }
      if (rows.isEmpty) {
        _sourceSlivers.remove(sourceId);
        _visibleSearchCounts.remove(sourceId);
        continue;
      }
      if (_sourceSlivers.containsKey(sourceId) &&
          changedSources != null &&
          !changedSources.contains(sourceId) &&
          _visibleSearchCounts[sourceId] == index) {
        continue;
      }
      _visibleSearchCounts[sourceId] = index;
      _sourceSlivers[sourceId] = _SearchSourceSection(
        key: ValueKey('announcement-search-source-$sourceId'),
        department: AnnouncementSource.byId(sourceId).name,
        rows: rows,
        itemBuilder: _searchItem,
      );
    }
    _resultSlivers = [
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      for (final sourceId in sourceIds)
        if (_sourceSlivers[sourceId] case final Widget sliver) sliver,
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
    _scheduleSearchCardCheck();
  }

  void _cancelSearchCardPreparation() {
    for (final item in _preparingSearchCards.values.toList()) {
      widget.repository.cancelCard(item);
    }
    _preparingSearchCards.clear();
    _settledSearchCards.clear();
  }

  void _scheduleSearchCardCheck() {
    if (_searchCardCheckScheduled) return;
    _searchCardCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchCardCheckScheduled = false;
      if (mounted) _prepareSearchCards();
    });
  }

  void _prepareSearchCards() {
    if (_detailRouteOpen || _resultsScrolling) return;
    final sourceIds = _resultsBySource.keys.toList()
      ..sort((a, b) {
        final order = (_sourceOrder[a] ?? _sourceOrder.length)
            .compareTo(_sourceOrder[b] ?? _sourceOrder.length);
        return order != 0 ? order : a.compareTo(b);
      });
    var foundMissing = false;
    var missingBeforePublished = false;
    for (final sourceId in sourceIds) {
      for (final item in _resultsBySource[sourceId]!) {
        final key = _searchResultKey(item);
        if (_cardPresentations[key]?.card == null) foundMissing = true;
        if (foundMissing && _publishedSearchKeys.contains(key)) {
          missingBeforePublished = true;
          break;
        }
      }
      if (missingBeforePublished) break;
    }
    if (!missingBeforePublished &&
        _resultsScrollController.hasClients &&
        _resultsScrollController.position.extentAfter > 280) {
      return;
    }
    final generation = _generation;
    final pending = <AnnouncementListItem>[];
    var blocked = false;
    var windowSize = 0;
    for (final sourceId in sourceIds) {
      for (final item in _resultsBySource[sourceId]!) {
        final key = _searchResultKey(item);
        final ready = _cardPresentations[key]?.card != null;
        if (!blocked && ready) continue;
        blocked = true;
        if (windowSize++ == 6) break;
        if (!ready &&
            !_preparingSearchCards.containsKey(key) &&
            !_settledSearchCards.containsKey(key)) {
          pending.add(item);
        }
      }
      if (windowSize > 6) break;
    }
    for (final item in pending) {
      final key = _searchResultKey(item);
      _preparingSearchCards[key] = item;
      () async {
        AnnouncementCardData card;
        try {
          card = await widget.repository.loadCard(item);
        } on Object {
          card = AnnouncementCardData.fromItem(item);
        }
        if (!mounted || generation != _generation) return;
        _preparingSearchCards.remove(key);
        _settledSearchCards[key] = card;
        _publishSearchCards();
      }();
    }
  }

  void _publishSearchCards() {
    if (!mounted ||
        _detailRouteOpen ||
        _resultsScrolling ||
        _settledSearchCards.isEmpty) {
      return;
    }
    final changedSources = <String>{};
    for (final entry in _settledSearchCards.entries) {
      final index = _resultIndexByKey[entry.key];
      if (index == null) continue;
      final item = _results[index];
      _cardPresentations
          .putIfAbsent(entry.key, _AnnouncementCardPresentation.new)
          .card = entry.value;
      changedSources.add(item.sourceId);
    }
    _settledSearchCards.clear();
    if (changedSources.isNotEmpty) {
      setState(() {
        for (final sourceId in changedSources) {
          final items = _resultsBySource[sourceId];
          if (items == null) continue;
          // Leave unprepared entries in their slots so an earlier pending card
          // cannot expose later results. Sort settled cards by their final date.
          final ready = items
              .where((item) =>
                  _cardPresentations[_searchResultKey(item)]?.card != null)
              .toList()
            ..sort((a, b) {
              final byDate = _compareSearchDate(a, b);
              return byDate != 0
                  ? byDate
                  : _resultIndexByKey[_searchResultKey(a)]!
                      .compareTo(_resultIndexByKey[_searchResultKey(b)]!);
            });
          var next = 0;
          for (var index = 0; index < items.length; index++) {
            if (_cardPresentations[_searchResultKey(items[index])]?.card !=
                null) {
              items[index] = ready[next++];
            }
          }
        }
        _rebuildResultRows(changedSources: changedSources);
      });
    }
  }

  void _flushProgress(int generation) {
    _progressTimer = null;
    if (!mounted ||
        generation != _generation ||
        _detailRouteOpen ||
        _resultsScrolling ||
        _progressFrameScheduled) {
      return;
    }
    final progress = _pendingProgress;
    if (progress == null && !_searchStreamDone) return;
    _pendingProgress = null;
    final streamSearching =
        !_searchStreamDone && !(progress?.isFinished ?? false);
    final searching = streamSearching || _pendingMatches.length > 100;
    if (progress?.isFinished == true && !_failureNoticeShown) {
      _failureNoticeShown = true;
      final otherFailureCount = progress!.unfinishedCount -
          progress.parseFailureCount -
          progress.timeoutFailureCount;
      final notices = <String>[
        if (progress.parseFailureCount > 0)
          '${progress.parseFailureCount} 项解析失败',
        if (progress.timeoutFailureCount > 0)
          '${progress.timeoutFailureCount} 项请求超时',
        if (otherFailureCount > 0) '$otherFailureCount 项请求失败',
      ];
      if (notices.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(notices.join('；'))));
      }
    }
    if (_pendingMatches.isEmpty &&
        _discoveredArticles ==
            (progress?.discoveredArticles ?? _discoveredArticles) &&
        _searching == searching &&
        (_pendingSearchError == null || _error == _pendingSearchError)) {
      return;
    }
    final changedSources = _mergePendingMatches();
    if (changedSources.isNotEmpty) {
      _rebuildResultRows(changedSources: changedSources);
    }
    setState(() {
      _discoveredArticles = progress?.discoveredArticles ?? _discoveredArticles;
      _searching = searching;
      _error = _pendingSearchError ?? _error;
    });
    if (_pendingMatches.isNotEmpty) {
      _pendingProgress ??= progress;
      _scheduleProgressFrame();
    }
  }

  void _scheduleProgressFrame() {
    if (_progressFrameScheduled) return;
    _progressFrameScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _progressFrameScheduled = false;
      // A ScrollEnd from resetting an old list can queue this frame just
      // before a new run starts. The pending queue always belongs to the
      // current run, so an old generation must not strand its fast response.
      _flushProgress(_generation);
    });
  }

  Future<void> _searchDemo(String query, int generation) async {
    final normalized = query.toLowerCase();
    try {
      final items = (await widget.repository.fetchAnnouncements())
          .where((item) =>
              _activeSelectedSourceIds.contains(item.sourceId) &&
              _matchesActiveDateRange(item))
          .toList();
      if (!mounted || generation != _generation) return;
      setState(() {
        _discoveredArticles = items.length;
      });
      for (final item in items) {
        if (!mounted || generation != _generation) return;
        var matched = _activeIncludeTitle &&
            item.title.toLowerCase().contains(normalized);
        if (!matched && _activeIncludeBody) {
          try {
            final detail = await widget.repository.fetchDetail(item);
            matched = detail.blocks.any((block) =>
                (block.isText &&
                    (block.value.toLowerCase().contains(normalized) ||
                        block.parts.any((part) =>
                            part.text.toLowerCase().contains(normalized)))) ||
                (block.isTable &&
                    (block.cells.any((cell) =>
                            cell.text.toLowerCase().contains(normalized)) ||
                        block.rows.any((row) => row.any((cell) =>
                            cell.toLowerCase().contains(normalized))))) ||
                (block.isLink && block.label.toLowerCase().contains(normalized)) ||
                (block.isImage && block.alt.toLowerCase().contains(normalized)));
          } on Object {
            // A demo detail can fail independently of the other results.
          }
        }
        if (!mounted || generation != _generation) return;
        setState(() {
          if (matched && _upsertSearchResult(item)) {
            _rebuildResultRows();
          }
        });
        await Future<void>.delayed(Duration.zero);
      }
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '搜索失败，请重试';
          _searching = false;
        });
      }
    }
  }

  bool _matchesActiveDateRange(AnnouncementListItem item) {
    final range = _activeDateRange;
    if (range == null) return true;
    final date = item.publishedAt;
    if (date == null) return false;
    final day = DateUtils.dateOnly(date);
    return !day.isBefore(range.start) && !day.isAfter(range.end);
  }

  Future<void> _chooseSearchSources() async {
    AnnouncementMenuExpansion expansion;
    try {
      expansion = await widget.repository.menuExpansion();
    } on Object {
      expansion = (
        favorites: true,
        schoolPortal: true,
        college: false,
        researchInstitute: false,
        administrativeDepartment: true,
        affiliatedInstitution: true,
      );
    }
    if (!mounted) return;
    await _showAnnouncementFilterMenu<void>(
      context: context,
      barrierLabel: '关闭搜索部门筛选',
      builder: (context) => _AnnouncementSourceMenu(
        selected: AnnouncementSource.official,
        initialFavorites: const {},
        initialExpansion: expansion,
        onToggleFavorite: (_) async => <String>{},
        onExpansionChanged: widget.repository.saveMenuExpansion,
        onSelect: (_) {},
        selectedIds: _selectedSourceIds,
        onSelectedIdsChanged: _changeSelectedSources,
      ),
    );
  }

  void _changeSelectedSources(Set<String> selectedIds) {
    _selectionTouched = true;
    setState(() => _selectedSourceIds = {
          for (final source in AnnouncementSource.all)
            if (source.supportsSearch && selectedIds.contains(source.id))
              source.id,
        });
    unawaited(_saveSelectedSources());
  }

  Future<void> _saveSelectedSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _selectedSourcesKey,
        AnnouncementSource.all
            .where((source) =>
                source.supportsSearch && _selectedSourceIds.contains(source.id))
            .map((source) => source.id)
            .toList(),
      );
    } on Object {
      // Keep the current choice in memory if local storage is unavailable.
    }
  }

  Future<void> _saveSearchSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_includeTitleKey, _includeTitle);
      await prefs.setBool(_includeBodyKey, _includeBody);
    } on Object {
      // Keep the current choice in memory if local storage is unavailable.
    }
  }

  String get _dateRangeLabel {
    switch (_timePreset) {
      case _SearchTimePreset.all:
        return '时间不限';
      case _SearchTimePreset.week:
        return '近一周';
      case _SearchTimePreset.month:
        return '近一月';
      case _SearchTimePreset.year:
        return '近一年';
      case _SearchTimePreset.custom:
        String format(DateTime day) =>
            '${day.year}/${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}';
        return '${format(_dateRange!.start)}—${format(_dateRange!.end)}';
    }
  }

  Future<void> _openSearchTimeMenu() async {
    final preset = await _showAnnouncementFilterMenu<_SearchTimePreset>(
      context: context,
      barrierLabel: '关闭搜索时间筛选',
      builder: (menuContext) => _AnnouncementFilterPanel(
        key: const ValueKey('announcement-search-time-menu'),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final entry in const {
              _SearchTimePreset.all: '时间不限',
              _SearchTimePreset.week: '近一周',
              _SearchTimePreset.month: '近一月',
              _SearchTimePreset.year: '近一年',
              _SearchTimePreset.custom: '自定义日期',
            }.entries)
              ListTile(
                key: ValueKey('announcement-search-time-${entry.key.name}'),
                selected: _timePreset == entry.key,
                title: Text(entry.value),
                onTap: () => Navigator.of(menuContext).pop(entry.key),
              ),
          ],
        ),
      ),
    );
    if (mounted && preset != null) await _chooseSearchTime(preset);
  }

  Future<void> _chooseSearchTime(_SearchTimePreset preset) async {
    final today = DateUtils.dateOnly(DateTime.now());
    DateTimeRange? range;
    switch (preset) {
      case _SearchTimePreset.all:
        break;
      case _SearchTimePreset.week:
        range = DateTimeRange(
          start: DateTime(today.year, today.month, today.day - 6),
          end: today,
        );
      case _SearchTimePreset.month:
      case _SearchTimePreset.year:
        final months = preset == _SearchTimePreset.month ? 1 : 12;
        final first = DateTime(today.year, today.month - months);
        final lastDay = DateTime(first.year, first.month + 1, 0).day;
        range = DateTimeRange(
          start:
              DateTime(first.year, first.month, math.min(today.day, lastDay)),
          end: today,
        );
      case _SearchTimePreset.custom:
        range = await showShuYoDateRangePicker(
          context: context,
          title: '自定义搜索日期',
          firstDate: DateTime(1900),
          lastDate: today,
          initialRange: _dateRange,
        );
        if (!mounted || range == null) return;
    }
    setState(() {
      _timePreset = preset;
      _dateRange = range;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索公告'),
        actions: [
          IconButton(
            tooltip: '筛选部门',
            onPressed: _chooseSearchSources,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.filter_list),
                Positioned(
                  right: -6,
                  bottom: -4,
                  child: Text(
                    _selectedSourceIds.length ==
                            AnnouncementSource.all
                                .where((source) => source.supportsSearch)
                                .length
                        ? 'ALL'
                        : '${_selectedSourceIds.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      height: 1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('announcement-search-time-filter'),
            tooltip: '搜索时间：$_dateRangeLabel',
            onPressed: _openSearchTimeMenu,
            icon: Icon(
              _dateRange == null ? Icons.date_range_outlined : Icons.date_range,
              color: _dateRange == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 2),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _searching
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(
        children: [
          _buildSearchHeader(colors),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildSearchHeader(ShuYoColors colors) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  focusNode: _queryFocusNode,
                  readOnly: _searching,
                  onTapOutside: (_) => _queryFocusNode.unfocus(),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) {
                    if (!_searching) _startSearch();
                  },
                  decoration: const InputDecoration(
                    labelText: '搜索公告关键词',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '开始搜索',
                onPressed: _searching ? null : _startSearch,
                icon: Icon(
                  Icons.search,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        _searchStatus(colors),
      ],
    );
  }

  Widget _searchStatus(ShuYoColors colors) {
    Widget scopeChip(String label, String key, bool selected,
            ValueChanged<bool> onSelected) =>
        FilterChip(
          key: ValueKey(key),
          label: Text(label),
          selected: selected,
          showCheckmark: true,
          onSelected: _searching
              ? null
              : (value) {
                  _settingsTouched = true;
                  onSelected(value);
                  unawaited(_saveSearchSettings());
                },
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('公告数', style: TextStyle(color: colors.textMuted, fontSize: 12)),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      _statusNumber(
                          'announcement-search-found-count',
                          _results.length,
                          Theme.of(context).colorScheme.primary,
                          fontSize: 26,
                          fontWeight: FontWeight.w600),
                      Text('/',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          )),
                      _statusNumber('announcement-search-total-count',
                          _discoveredArticles, colors.textPrimary,
                          fontSize: 18, fontWeight: FontWeight.w600),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              scopeChip(
                  '标题',
                  'announcement-search-title-scope',
                  _searching ? _activeIncludeTitle : _includeTitle,
                  (value) => setState(() => _includeTitle = value)),
              const SizedBox(width: 8),
              scopeChip(
                  '内容',
                  'announcement-search-body-scope',
                  _searching ? _activeIncludeBody : _includeBody,
                  (value) => setState(() => _includeBody = value)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusNumber(String key, int value, Color color,
      {double fontSize = 12.5, FontWeight? fontWeight}) {
    return Text(
      '$value',
      key: ValueKey<String>(key),
      maxLines: 1,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _buildResults() {
    if (_results.isEmpty) {
      if (_error != null) {
        return EmptyState(
          icon: Icons.error_outline,
          title: '搜索失败',
          message: _error!,
        );
      }
      if (_searching) {
        return const Center(child: Text('正在查询各来源公告…'));
      }
      return EmptyState(
        icon: _started ? Icons.search_off : Icons.search,
        title: _started ? '没有找到公告' : '搜索公告',
        message: _started ? '试试其他关键词。' : '输入关键词后点击搜索。',
      );
    }
    if (_resultSlivers.isEmpty) _rebuildResultRows();
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          context.shuyoColors.textMuted.withValues(alpha: 0.55),
        ),
        thickness: const WidgetStatePropertyAll(2.5),
        radius: const Radius.circular(4),
      ),
      child: Scrollbar(
        controller: _resultsScrollController,
        thumbVisibility: true,
        interactive: true,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth != 0) return false;
            if (notification is ScrollStartNotification) {
              _resultsScrolling = true;
            } else if (notification is ScrollEndNotification) {
              _resultsScrolling = false;
              _publishSearchCards();
              _scheduleSearchCardCheck();
              if (_pendingProgress != null || _searchStreamDone) {
                _scheduleProgressFrame();
              }
            }
            return false;
          },
          child: CustomScrollView(
            controller: _resultsScrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(0),
            slivers: _resultSlivers,
          ),
        ),
      ),
    );
  }

  Widget _searchItem(BuildContext context, _AnnouncementItemRow row,
      {required bool showDivider}) {
    final item = row.item;
    return Column(
      key: ValueKey(_searchResultKey(item)),
      mainAxisSize: MainAxisSize.min,
      children: [
        _AnnouncementTile(
          index: row.index,
          item: item,
          external: row.external,
          presentation: row.presentation,
          updatesPaused: _updatesPaused,
          highlightQuery: _activeQuery,
          onTap: () => unawaited(_openSearchResult(item)),
        ),
        if (showDivider && CustomBackgroundScope.maybeOf(context) == null)
          Divider(height: 1, color: context.shuyoColors.border),
      ],
    );
  }

  Future<void> _openSearchResult(AnnouncementListItem item) async {
    if (!AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
        .canOpenInApp) {
      await _openExternalAnnouncementUrl(context, item.url);
      return;
    }
    if (_detailRouteOpen) return;
    _updatesPaused.value = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    final route = shuyoRoute<void>(
      builder: (context) => AnnouncementDetailPage(
        repository: widget.repository,
        item: item,
        highlightQuery: _activeQuery,
      ),
    );
    try {
      await Navigator.of(context).push<void>(route);
      // The push Future completes at pop time; wait until the reverse animation
      // finishes before applying the accumulated page update.
      if (route is TransitionRoute<void>) await route.completed;
    } finally {
      if (mounted) {
        _updatesPaused.value = false;
        _flushProgress(_generation);
        _publishSearchCards();
        _scheduleSearchCardCheck();
      }
    }
  }
}

class _LoadedAnnouncementList {
  _LoadedAnnouncementList(this.items, this.cards)
      : cardsByUrl = {for (final row in cards) row.item.url: row};

  final List<AnnouncementListItem> items;
  final List<_AnnouncementItemRow> cards;
  final Map<String, _AnnouncementItemRow> cardsByUrl;
  bool preparing = false;

  int get visibleCount =>
      cards.takeWhile((row) => row.presentation.card != null).length;

  List<Object> get rows {
    final rows = <Object>[];
    String? previousMonth;
    for (final row in cards) {
      if (row.presentation.card == null) break;
      final date = row.presentation.card?.publishedAt ?? row.item.publishedAt;
      final month = date == null ? null : '${date.year}年${date.month}月';
      if (month != null && month != previousMonth) {
        rows.add(_AnnouncementMonthHeader(month));
      }
      rows.add(row);
      previousMonth = month;
    }
    return rows;
  }
}

class _AnnouncementMonthHeader {
  const _AnnouncementMonthHeader(this.label);

  final String label;
}

const _stickyHeaderExtent = 34.0;

class _AnnouncementStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _AnnouncementStickyHeaderDelegate({
    required this.month,
    required this.opacity,
  });

  final String month;
  final Animation<double> opacity;

  @override
  double get minExtent => maxExtent;

  @override
  double get maxExtent => _stickyHeaderExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final colors = context.shuyoColors;
    return Material(
      key: ValueKey('announcement-sticky-home-$month'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox.expand(
        child: FadeTransition(
          opacity: opacity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                month,
                style: ShuYoTextStyles.meta(
                  color: colors.textSecondary,
                  size: 12.5,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_AnnouncementStickyHeaderDelegate oldDelegate) =>
      month != oldDelegate.month || opacity != oldDelegate.opacity;
}

class _AnnouncementItemRow {
  _AnnouncementItemRow(
    this.index,
    this.item, {
    _AnnouncementCardPresentation? presentation,
  }) : presentation = presentation ?? _AnnouncementCardPresentation();

  final int index;
  final AnnouncementListItem item;
  final _AnnouncementCardPresentation presentation;
  late final bool external =
      !AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
          .canOpenInApp;
}

/// Survives month regrouping and viewport recycling without retaining a ticker.
class _AnnouncementCardPresentation {
  final key = GlobalKey();
  final entrance = ProxyAnimation(const AlwaysStoppedAnimation<double>(0));
  AnnouncementCardData? card;
  bool entered = false;
}

const _searchStickyHeaderExtent = 38.0;

class _SearchMonthHeader extends SliverPersistentHeaderDelegate {
  const _SearchMonthHeader({this.department, required this.month});
  final String? department;
  final String month;

  @override
  double get minExtent => _searchStickyHeaderExtent;
  @override
  double get maxExtent => _searchStickyHeaderExtent;
  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey(department == null
          ? 'announcement-sticky-home-$month'
          : 'announcement-sticky-month-$department-$month'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(month,
            style: ShuYoTextStyles.meta(
                color: context.shuyoColors.textSecondary,
                size: 12.5,
                weight: FontWeight.w600)),
      ),
    );
  }

  @override
  bool shouldRebuild(_SearchMonthHeader oldDelegate) =>
      department != oldDelegate.department || month != oldDelegate.month;
}

class _AnnouncementDepartmentStickyHeaderDelegate
    extends SliverPersistentHeaderDelegate {
  const _AnnouncementDepartmentStickyHeaderDelegate(this.department);

  final String department;

  @override
  double get minExtent => maxExtent;

  @override
  double get maxExtent => _searchStickyHeaderExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey('announcement-sticky-department-$department'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 5),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            department,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.meta(
              color: Theme.of(context).colorScheme.primary,
              size: 15,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_AnnouncementDepartmentStickyHeaderDelegate oldDelegate) =>
      department != oldDelegate.department;
}

typedef _SearchItemBuilder = Widget Function(
  BuildContext context,
  _AnnouncementItemRow row, {
  required bool showDivider,
});

typedef _SearchMonthViewport = ({String? month, double pushOffset});

/// Each department has one lazy child delegate, regardless of how many years
/// its results cover. A delegate per month would build an offscreen article
/// for every month just to estimate that delegate's scroll extent.
class _SearchSourceSection extends StatefulWidget {
  const _SearchSourceSection({
    super.key,
    required this.department,
    required this.rows,
    required this.itemBuilder,
  });

  final String department;
  final List<Object> rows;
  final _SearchItemBuilder itemBuilder;

  @override
  State<_SearchSourceSection> createState() => _SearchSourceSectionState();
}

class _SearchSourceSectionState extends State<_SearchSourceSection> {
  late List<Object> _rows;
  late List<String?> _months;
  late Map<Key, int> _indices;
  late Set<int> _monthHeaders;
  late final ValueNotifier<_SearchMonthViewport> _viewport;
  _SearchMonthViewport? _pendingViewport;
  bool _viewportScheduled = false;

  @override
  void initState() {
    super.initState();
    _readRows();
    _viewport = ValueNotifier((
      month: _months.isEmpty ? null : _months.first,
      pushOffset: 0,
    ));
  }

  @override
  void didUpdateWidget(covariant _SearchSourceSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rows != widget.rows) _readRows();
  }

  void _readRows() {
    _rows = widget.rows.toList();
    // The first month is represented by the persistent header; later months
    // retain their normal position inside the one lazy list.
    if (_rows.firstOrNull is _AnnouncementMonthHeader) _rows.removeAt(0);
    _indices = {};
    _monthHeaders = {};
    _months = [];
    String? month = widget.rows.firstOrNull is _AnnouncementMonthHeader
        ? (widget.rows.first as _AnnouncementMonthHeader).label
        : null;
    for (var index = 0; index < _rows.length; index++) {
      final row = _rows[index];
      final Key key;
      if (row is _AnnouncementMonthHeader) {
        month = row.label;
        _monthHeaders.add(index);
        key = ValueKey('month-${row.label}');
      } else {
        final item = (row as _AnnouncementItemRow).item;
        key = ValueKey(
            '${item.sourceId}\u0000${item.url}\u0000${item.title.trim().toLowerCase()}');
      }
      _indices[key] = index;
      _months.add(month);
    }
  }

  void _reportViewport(_SearchMonthViewport viewport) {
    if (viewport == _viewport.value) {
      _pendingViewport = null;
      return;
    }
    if (viewport == _pendingViewport) return;
    _pendingViewport = viewport;
    if (_viewportScheduled) return;
    _viewportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportScheduled = false;
      if (!mounted) return;
      final next = _pendingViewport;
      _pendingViewport = null;
      if (next == null) return;
      final monthChanged = next.month != _viewport.value.month;
      _viewport.value = next;
      if (monthChanged) setState(() {});
    });
  }

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(slivers: [
      SliverPersistentHeader(
        pinned: true,
        delegate:
            _AnnouncementDepartmentStickyHeaderDelegate(widget.department),
      ),
      if (_months.any((month) => month != null))
        SliverPersistentHeader(
          pinned: true,
          delegate: _SearchMonthStickyHeaderDelegate(
            department: widget.department,
            viewport: _viewport,
          ),
        ),
      _SearchMonthList(
        months: _months,
        monthHeaders: _monthHeaders,
        onViewport: _reportViewport,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final row = _rows[index];
            if (row is _AnnouncementMonthHeader) {
              return SizedBox(
                key: ValueKey('month-${row.label}'),
                height: _searchStickyHeaderExtent,
                child: row.label == _viewport.value.month
                    ? null
                    : _SearchMonthHeader(month: row.label)
                        .build(context, 0, false),
              );
            }
            return widget.itemBuilder(
              context,
              row as _AnnouncementItemRow,
              showDivider: index + 1 < _rows.length &&
                  _rows[index + 1] is _AnnouncementItemRow,
            );
          },
          childCount: _rows.length,
          findChildIndexCallback: (key) => _indices[key],
        ),
      ),
    ]);
  }
}

class _SearchMonthStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _SearchMonthStickyHeaderDelegate({
    required this.department,
    required this.viewport,
  });

  final String department;
  final ValueNotifier<_SearchMonthViewport> viewport;

  @override
  double get minExtent => _searchStickyHeaderExtent;

  @override
  double get maxExtent => _searchStickyHeaderExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ClipRect(
      child: ValueListenableBuilder<_SearchMonthViewport>(
        valueListenable: viewport,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, value.pushOffset),
          child: _SearchMonthHeader(
            department: department,
            month: value.month ?? '',
          ).build(context, shrinkOffset, overlapsContent),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SearchMonthStickyHeaderDelegate oldDelegate) =>
      department != oldDelegate.department || viewport != oldDelegate.viewport;
}

class _SearchMonthList extends SliverList {
  const _SearchMonthList({
    required super.delegate,
    required this.months,
    required this.monthHeaders,
    required this.onViewport,
  });

  final List<String?> months;
  final Set<int> monthHeaders;
  final ValueChanged<_SearchMonthViewport> onViewport;

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderSearchMonthList(
        childManager: context as SliverMultiBoxAdaptorElement,
        months: months,
        monthHeaders: monthHeaders,
        onViewport: onViewport,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderSearchMonthList renderObject) {
    renderObject
      ..months = months
      ..monthHeaders = monthHeaders
      ..onViewport = onViewport
      ..markNeedsLayout();
  }
}

class _RenderSearchMonthList extends RenderSliverList {
  _RenderSearchMonthList({
    required super.childManager,
    required this.months,
    required this.monthHeaders,
    required this.onViewport,
  });

  List<String?> months;
  Set<int> monthHeaders;
  ValueChanged<_SearchMonthViewport> onViewport;

  @override
  void performLayout() {
    super.performLayout();
    if (firstChild == null || geometry!.paintExtent == 0 || months.isEmpty) {
      return;
    }
    // The month changes when the next in-flow header reaches the *top* of
    // the pinned month, rather than its bottom. During that last header-height
    // of travel, slide the old month upward just like a normal sticky group.
    final threshold = constraints.scrollOffset +
        math.max(0, constraints.overlap - _searchStickyHeaderExtent);
    var child = firstChild;
    String? month = months[indexOf(child!)];
    var pushOffset = 0.0;
    while (child != null) {
      final index = indexOf(child);
      final offset =
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset!;
      if (offset <= threshold) {
        month = months[index];
      } else if (monthHeaders.contains(index)) {
        pushOffset =
            math.min(0, offset - threshold - _searchStickyHeaderExtent);
        break;
      }
      child = childAfter(child);
    }
    onViewport((month: month, pushOffset: pushOffset));
  }
}

Future<void> _openExternalAnnouncementUrl(
  BuildContext context,
  String url,
) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on Object {
    // Keep the list available when the system cannot open the URL.
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开公告链接')),
    );
  }
}

class _AnnouncementSourceMenu extends StatefulWidget {
  const _AnnouncementSourceMenu({
    required this.selected,
    required this.initialFavorites,
    required this.initialExpansion,
    required this.onToggleFavorite,
    required this.onExpansionChanged,
    required this.onSelect,
    this.selectedIds,
    this.onSelectedIdsChanged,
  });

  final AnnouncementSource selected;
  final Set<String> initialFavorites;
  final AnnouncementMenuExpansion initialExpansion;
  final Future<Set<String>> Function(AnnouncementSource) onToggleFavorite;
  final Future<void> Function(AnnouncementMenuSection, bool) onExpansionChanged;
  final ValueChanged<AnnouncementSource> onSelect;
  final Set<String>? selectedIds;
  final ValueChanged<Set<String>>? onSelectedIdsChanged;

  @override
  State<_AnnouncementSourceMenu> createState() =>
      _AnnouncementSourceMenuState();
}

class _AnnouncementSourceMenuState extends State<_AnnouncementSourceMenu> {
  late Set<String> _favorites = {...widget.initialFavorites};
  late final Set<String> _selectedIds = {...?widget.selectedIds};
  final ScrollController _scrollController = ScrollController();
  late bool _favoritesExpanded = widget.initialExpansion.favorites;
  late bool _schoolPortalExpanded = widget.initialExpansion.schoolPortal;
  late bool _collegeExpanded = widget.initialExpansion.college;
  late bool _researchInstituteExpanded =
      widget.initialExpansion.researchInstitute;
  late bool _administrativeDepartmentExpanded =
      widget.initialExpansion.administrativeDepartment;
  late bool _affiliatedInstitutionExpanded =
      widget.initialExpansion.affiliatedInstitution;
  bool _saving = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final favoriteSources = AnnouncementSource.all
        .where((source) => _favorites.contains(source.id))
        .toList();
    final researchInstituteSources =
        AnnouncementSource.inGroup(AnnouncementSourceGroup.researchInstitute);
    final schoolPortalSources =
        AnnouncementSource.inGroup(AnnouncementSourceGroup.schoolPortal);
    final administrativeDepartmentSources = AnnouncementSource.inGroup(
        AnnouncementSourceGroup.administrativeDepartment);
    final affiliatedInstitutionSources = AnnouncementSource.inGroup(
        AnnouncementSourceGroup.affiliatedInstitution);
    final collegeSources =
        AnnouncementSource.inGroup(AnnouncementSourceGroup.college);
    final menuWidth = math.min(264.0, MediaQuery.sizeOf(context).width * 0.68);
    final menuChildren = <Widget>[
      if (widget.selectedIds == null) ...[
        _sectionHeader('收藏', _favoritesExpanded,
            () => _toggleSection(AnnouncementMenuSection.favorites)),
        if (_favoritesExpanded)
          if (favoriteSources.isEmpty)
            const ListTile(
              contentPadding: EdgeInsets.only(left: 16, right: 12),
              title: Text('暂无收藏'),
            )
          else
            for (final source in favoriteSources) _sourceRow(source),
      ],
      _sectionHeader(
        AnnouncementSourceGroup.schoolPortal.label,
        _schoolPortalExpanded,
        () => _toggleSection(AnnouncementMenuSection.schoolPortal),
        sources: schoolPortalSources,
        group: AnnouncementSourceGroup.schoolPortal,
      ),
      if (_schoolPortalExpanded)
        for (final source in schoolPortalSources) _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.administrativeDepartment.label,
        _administrativeDepartmentExpanded,
        () => _toggleSection(AnnouncementMenuSection.administrativeDepartment),
        sources: administrativeDepartmentSources,
        group: AnnouncementSourceGroup.administrativeDepartment,
      ),
      if (_administrativeDepartmentExpanded)
        for (final source in administrativeDepartmentSources)
          _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.affiliatedInstitution.label,
        _affiliatedInstitutionExpanded,
        () => _toggleSection(AnnouncementMenuSection.affiliatedInstitution),
        sources: affiliatedInstitutionSources,
        group: AnnouncementSourceGroup.affiliatedInstitution,
      ),
      if (_affiliatedInstitutionExpanded)
        for (final source in affiliatedInstitutionSources) _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.college.label,
        _collegeExpanded,
        () => _toggleSection(AnnouncementMenuSection.college),
        sources: collegeSources,
        group: AnnouncementSourceGroup.college,
      ),
      if (_collegeExpanded)
        for (final category in AnnouncementCollegeCategory.values) ...[
          _collegeCategoryHeader(category.label),
          for (final source in AnnouncementSource.inCollegeCategory(category))
            _sourceRow(source),
        ],
      _sectionHeader(
        AnnouncementSourceGroup.researchInstitute.label,
        _researchInstituteExpanded,
        () => _toggleSection(AnnouncementMenuSection.researchInstitute),
        sources: researchInstituteSources,
        group: AnnouncementSourceGroup.researchInstitute,
      ),
      if (_researchInstituteExpanded)
        for (final source in researchInstituteSources) _sourceRow(source),
    ];
    return _AnnouncementFilterPanel(
      key: announcementSourceMenuKey,
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: CustomScrollView(
          controller: _scrollController,
          shrinkWrap: true,
          slivers: _menuSlivers(context, menuChildren, menuWidth),
        ),
      ),
    );
  }

  List<Widget> _menuSlivers(
    BuildContext context,
    List<Widget> children,
    double menuWidth,
  ) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
    final regularChildren = <Widget>[];

    void flushRegularChildren() {
      if (regularChildren.isEmpty) return;
      slivers.add(SliverList(
        delegate: SliverChildListDelegate([...regularChildren]),
      ));
      regularChildren.clear();
    }

    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child is! _AnnouncementMenuSectionHeader) {
        regularChildren.add(child);
        continue;
      }

      flushRegularChildren();
      final sectionChildren = <Widget>[];
      while (index + 1 < children.length &&
          children[index + 1] is! _AnnouncementMenuSectionHeader) {
        sectionChildren.add(children[++index]);
      }
      final sectionSlivers =
          _menuSectionSlivers(context, sectionChildren, menuWidth);
      slivers.add(SliverMainAxisGroup(slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _AnnouncementMenuSectionStickyHeaderDelegate(
            header: child,
            extent: _announcementMenuSectionHeaderExtent,
          ),
        ),
        ...sectionSlivers,
      ]));
    }
    flushRegularChildren();
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 8)));
    return slivers;
  }

  List<Widget> _menuSectionSlivers(
    BuildContext context,
    List<Widget> children,
    double menuWidth,
  ) {
    final slivers = <Widget>[];
    final regularChildren = <Widget>[];

    void flushRegularChildren() {
      if (regularChildren.isEmpty) return;
      slivers.add(SliverList(
        delegate: SliverChildListDelegate([...regularChildren]),
      ));
      regularChildren.clear();
    }

    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      if (child is! _AnnouncementCollegeCategoryHeader) {
        regularChildren.add(child);
        continue;
      }

      flushRegularChildren();
      final categoryChildren = <Widget>[];
      while (index + 1 < children.length &&
          children[index + 1] is! _AnnouncementCollegeCategoryHeader) {
        categoryChildren.add(children[++index]);
      }
      final maxWidth = menuWidth > 28 ? menuWidth - 28 : 0.0;
      final extent = child.extent(context, maxWidth);
      slivers.add(SliverMainAxisGroup(slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _AnnouncementCollegeCategoryStickyHeaderDelegate(
            header: child,
            extent: extent,
          ),
        ),
        SliverList(
          delegate: SliverChildListDelegate(categoryChildren),
        ),
      ]));
    }
    flushRegularChildren();
    return slivers;
  }

  Widget _sectionHeader(String title, bool expanded, VoidCallback onTap,
      {List<AnnouncementSource>? sources, AnnouncementSourceGroup? group}) {
    final tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: widget.selectedIds == null || sources == null || group == null
          ? Icon(expanded ? Icons.expand_less : Icons.expand_more)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: ValueKey<String>(
                      'announcement-search-group-${group.name}'),
                  tristate: true,
                  value: _groupSelection(sources),
                  onChanged: (_) => _toggleGroupSelection(sources),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
      onTap: onTap,
    );
    return _AnnouncementMenuSectionHeader(title: title, tile: tile);
  }

  bool? _groupSelection(List<AnnouncementSource> sources) {
    sources = sources.where((source) => source.supportsSearch).toList();
    final selected =
        sources.where((source) => _selectedIds.contains(source.id)).length;
    if (selected == 0) return false;
    if (selected == sources.length) return true;
    return null;
  }

  void _toggleGroupSelection(List<AnnouncementSource> sources) {
    sources = sources.where((source) => source.supportsSearch).toList();
    final allSelected =
        sources.every((source) => _selectedIds.contains(source.id));
    setState(() {
      for (final source in sources) {
        if (allSelected) {
          _selectedIds.remove(source.id);
        } else {
          _selectedIds.add(source.id);
        }
      }
    });
    widget.onSelectedIdsChanged?.call({..._selectedIds});
  }

  Widget _collegeCategoryHeader(String title) {
    return _AnnouncementCollegeCategoryHeader(title);
  }

  void _toggleSection(AnnouncementMenuSection section) {
    late final bool expanded;
    setState(() {
      switch (section) {
        case AnnouncementMenuSection.favorites:
          expanded = _favoritesExpanded = !_favoritesExpanded;
        case AnnouncementMenuSection.schoolPortal:
          expanded = _schoolPortalExpanded = !_schoolPortalExpanded;
        case AnnouncementMenuSection.college:
          expanded = _collegeExpanded = !_collegeExpanded;
        case AnnouncementMenuSection.researchInstitute:
          expanded = _researchInstituteExpanded = !_researchInstituteExpanded;
        case AnnouncementMenuSection.administrativeDepartment:
          expanded = _administrativeDepartmentExpanded =
              !_administrativeDepartmentExpanded;
        case AnnouncementMenuSection.affiliatedInstitution:
          expanded =
              _affiliatedInstitutionExpanded = !_affiliatedInstitutionExpanded;
      }
    });
    unawaited(widget.onExpansionChanged(section, expanded).catchError(
      (Object error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('分组状态保存失败，请重试')),
        );
      },
    ));
  }

  Widget _sourceRow(AnnouncementSource source) {
    final favorite = _favorites.contains(source.id);
    final selecting = widget.selectedIds != null;
    final enabled = !selecting || source.supportsSearch;
    void toggleSelection() {
      setState(() {
        if (!_selectedIds.add(source.id)) _selectedIds.remove(source.id);
      });
      widget.onSelectedIdsChanged?.call({..._selectedIds});
    }

    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      title: Text(
        source.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      selected: !selecting && widget.selected == source,
      onTap: !enabled
          ? null
          : selecting
              ? toggleSelection
              : () => widget.onSelect(source),
      trailing: selecting
          ? Checkbox(
              value: _selectedIds.contains(source.id),
              onChanged: enabled ? (_) => toggleSelection() : null,
            )
          : IconButton(
              iconSize: 22,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              splashRadius: 20,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(40),
                shape: const CircleBorder(),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: favorite ? '取消收藏${source.name}' : '收藏${source.name}',
              icon: Icon(
                favorite ? Icons.star : Icons.star_border,
                color: favorite ? Theme.of(context).colorScheme.primary : null,
              ),
              onPressed: _saving ? null : () => _toggleFavorite(source),
            ),
    );
  }

  Future<void> _toggleFavorite(AnnouncementSource source) async {
    setState(() => _saving = true);
    try {
      final favorites = await widget.onToggleFavorite(source);
      if (mounted) setState(() => _favorites = favorites);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('收藏保存失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

const _announcementMenuSectionHeaderExtent = 56.0;

class _AnnouncementMenuSectionHeader extends StatelessWidget {
  const _AnnouncementMenuSectionHeader({
    required this.title,
    required this.tile,
  });

  final String title;
  final ListTile tile;

  @override
  Widget build(BuildContext context) => tile;
}

class _AnnouncementMenuSectionStickyHeaderDelegate
    extends SliverPersistentHeaderDelegate {
  const _AnnouncementMenuSectionStickyHeaderDelegate({
    required this.header,
    required this.extent,
  });

  final _AnnouncementMenuSectionHeader header;
  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey('announcement-sticky-menu-section-${header.title}'),
      color: Theme.of(context).colorScheme.surface,
      child: header,
    );
  }

  @override
  bool shouldRebuild(
          _AnnouncementMenuSectionStickyHeaderDelegate oldDelegate) =>
      header != oldDelegate.header || extent != oldDelegate.extent;
}

class _AnnouncementCollegeCategoryHeader extends StatelessWidget {
  const _AnnouncementCollegeCategoryHeader(this.title);

  final String title;

  double extent(BuildContext context, double maxWidth) {
    final style = DefaultTextStyle.of(context).style.merge(TextStyle(
          color: context.shuyoColors.textMuted,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ));
    final painter = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );
    try {
      painter.layout(maxWidth: maxWidth);
      return painter.height + 14;
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 12, top: 10, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          textAlign: TextAlign.left,
          style: TextStyle(
            color: context.shuyoColors.textMuted,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _AnnouncementCollegeCategoryStickyHeaderDelegate
    extends SliverPersistentHeaderDelegate {
  const _AnnouncementCollegeCategoryStickyHeaderDelegate({
    required this.header,
    required this.extent,
  });

  final _AnnouncementCollegeCategoryHeader header;
  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      key: ValueKey('announcement-sticky-college-category-${header.title}'),
      color: Theme.of(context).colorScheme.surface,
      child: header,
    );
  }

  @override
  bool shouldRebuild(
          _AnnouncementCollegeCategoryStickyHeaderDelegate oldDelegate) =>
      header.title != oldDelegate.header.title || extent != oldDelegate.extent;
}

class AnnouncementDetailPage extends StatefulWidget {
  const AnnouncementDetailPage({
    super.key,
    required this.repository,
    required this.item,
    this.highlightQuery = '',
  });

  final AnnouncementRepository repository;
  final AnnouncementListItem item;
  final String highlightQuery;

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  final Map<String, TapGestureRecognizer> _linkRecognizers = {};
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _matchSliverKey = GlobalKey();
  final GlobalKey _matchTextKey = GlobalKey();
  GlobalKey? _tableMatchKey;
  Rect? _tableMatchRect;
  double? _matchBlockLocalY;
  AnnouncementDetail? _matchedDetail;
  int? _matchedBlockIndex;
  ({int row, int column, int start, int end})? _matchedTableCell;
  int _matchStart = 0;
  int _matchEnd = 0;
  int _displayMatchStart = 0;
  int _displayMatchEnd = 0;
  bool _matchScrollScheduled = false;
  bool _matchPositioned = false;
  Timer? _matchPauseTimer;
  bool _matchPauseElapsed = false;
  bool _matchNavigationCancelled = false;
  bool _initialMatchScrollFinished = false;
  bool _matchCorrectionScheduled = false;
  bool _matchCorrectionUsed = false;
  bool _prefixMetricsReady = false;
  int _prefixMetricsGeneration = 0;
  Object? _prefixMetricsConfiguration;
  final Map<int, double> _prefixTextExtents = {};

  /// Locate the text before creating widgets, while leaving the article at its
  /// heading until both its first layout and the short reading pause finish.
  void _findSearchMatch(AnnouncementDetail detail) {
    if (identical(_matchedDetail, detail)) return;
    _matchedDetail = detail;
    _matchedBlockIndex = null;
    _matchedTableCell = null;
    _tableMatchKey = null;
    _tableMatchRect = null;
    _matchBlockLocalY = null;
    _matchPositioned = false;
    _matchPauseTimer?.cancel();
    _matchPauseTimer = null;
    _matchPauseElapsed = false;
    _matchNavigationCancelled = false;
    _initialMatchScrollFinished = false;
    _matchCorrectionScheduled = false;
    _matchCorrectionUsed = false;
    _prefixMetricsConfiguration = null;
    _prefixMetricsReady = false;
    _prefixMetricsGeneration++;
    _prefixTextExtents.clear();
    final pattern = announcementSearchPattern(widget.highlightQuery);
    if (pattern == null) return;
    for (var index = 0; index < detail.blocks.length; index++) {
      final block = detail.blocks[index];
      if (block.isTable) {
        final cells = block.cells.isNotEmpty
            ? [...block.cells]
            : [
                for (var row = 0; row < block.rows.length; row++)
                  for (var column = 0;
                      column < block.rows[row].length;
                      column++)
                    AnnouncementTableCell(
                        row: row,
                        column: column,
                        text: block.rows[row][column]),
              ];
        cells.sort((a, b) {
          final rowOrder = a.row.compareTo(b.row);
          return rowOrder != 0 ? rowOrder : a.column.compareTo(b.column);
        });
        for (final cell in cells) {
          final match = pattern.firstMatch(cell.text);
          if (match == null) continue;
          _matchedBlockIndex = index;
          _matchStart = match.start;
          _matchEnd = match.end;
          _displayMatchStart = match.start;
          _displayMatchEnd = match.end;
          _matchedTableCell = (
            row: cell.row,
            column: cell.column,
            start: match.start,
            end: match.end
          );
          return;
        }
        continue;
      }
      final text = block.isText
          ? block.parts.isEmpty
              ? block.value
              : block.parts.map((part) => part.text).join()
          : block.isLink
              ? block.label
              : '';
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      _matchedBlockIndex = index;
      _matchStart = match.start;
      _matchEnd = match.end;
      return;
    }
  }

  List<InlineSpan> _highlightedSpans(
    String text, {
    required int start,
    required int end,
  }) {
    return [
      if (start > 0) TextSpan(text: text.substring(0, start)),
      TextSpan(
        text: text.substring(start, end),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (end < text.length) TextSpan(text: text.substring(end)),
    ];
  }

  void _positionFirstMatch() {
    if (_matchedBlockIndex == null ||
        _matchPositioned ||
        !_matchPauseElapsed ||
        !_prefixMetricsReady ||
        _matchNavigationCancelled ||
        _matchScrollScheduled) {
      return;
    }
    _matchScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _matchScrollScheduled = false;
      if (!mounted ||
          _matchNavigationCancelled ||
          _route?.isCurrent == false ||
          !_scrollController.hasClients) {
        return;
      }
      final tableTarget = _tableMatchKey?.currentContext?.findRenderObject();
      final tableRect = _tableMatchRect;
      final target = _matchTextKey.currentContext?.findRenderObject();
      if (tableTarget is RenderBox &&
          tableTarget.attached &&
          tableRect != null) {
        _matchPositioned = true;
        _scrollToMatchY(tableTarget.localToGlobal(tableRect.topLeft).dy);
        return;
      }
      if (target == null || !target.attached) return;
      if (_matchedTableCell != null) {
        unawaited(Scrollable.maybeOf(_matchTextKey.currentContext!,
                axis: Axis.horizontal)
            ?.position
            .ensureVisible(
              target,
              alignment: 0.15,
              duration: _announcementMatchScrollDuration,
              curve: Curves.easeOutCubic,
            ));
      }
      RenderEditable? editable;
      void visit(RenderObject object) {
        if (object is RenderEditable) {
          editable ??= object;
        } else {
          object.visitChildren(visit);
        }
      }

      visit(target);
      final renderEditable = editable;
      if (renderEditable == null) {
        if (target is RenderBox) {
          _matchPositioned = true;
          _scrollToMatchY(target.localToGlobal(Offset.zero).dy);
        }
        return;
      }
      final boxes = renderEditable.getBoxesForSelection(TextSelection(
        baseOffset: _displayMatchStart,
        extentOffset: _displayMatchEnd,
      ));
      if (boxes.isEmpty) return;
      _matchPositioned = true;
      final matchY =
          renderEditable.localToGlobal(Offset(0, boxes.first.top)).dy;
      _scrollToMatchY(matchY);
    });
  }

  void _scrollToMatchY(double matchY) {
    if (_matchNavigationCancelled) return;
    final blockTop = _matchBlockGlobalY();
    if (blockTop != null) _matchBlockLocalY = matchY - blockTop;
    unawaited(_animateToMatch(matchY));
  }

  Future<void> _animateToMatch(double matchY) async {
    final generation = _prefixMetricsGeneration;
    await _scrollController.animateTo(
      _offsetForMatchY(matchY),
      duration: _announcementMatchScrollDuration,
      curve: Curves.easeOutCubic,
    );
    if (!mounted ||
        _matchNavigationCancelled ||
        generation != _prefixMetricsGeneration ||
        _route?.isCurrent == false ||
        !_scrollController.hasClients) {
      return;
    }
    _initialMatchScrollFinished = true;
    _scheduleMatchCorrection();
  }

  /// A late image or table may replace a placeholder even after the animation.
  /// Allow one final correction when the scroll metrics change, then leave the
  /// article alone. Any user interaction cancels this opportunity as well.
  void _scheduleMatchCorrection() {
    if (!_initialMatchScrollFinished ||
        _matchCorrectionUsed ||
        _matchCorrectionScheduled ||
        _matchNavigationCancelled) {
      return;
    }
    _matchCorrectionScheduled = true;
    final generation = _prefixMetricsGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _prefixMetricsGeneration) return;
      _matchCorrectionScheduled = false;
      if (_matchNavigationCancelled ||
          _route?.isCurrent == false ||
          !_scrollController.hasClients) {
        return;
      }
      final finalMatchY = _currentMatchY();
      if (finalMatchY == null) return;
      final correction = _offsetForMatchY(finalMatchY);
      if ((correction - _scrollController.offset).abs() <= 1) return;
      _matchCorrectionUsed = true;
      unawaited(_scrollController.animateTo(
        correction,
        duration: _announcementMatchScrollDuration,
        curve: Curves.easeOutCubic,
      ));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  double _offsetForMatchY(double matchY) {
    final position = _scrollController.position;
    final viewport = position.context.notificationContext?.findRenderObject();
    if (viewport is! RenderBox) return position.pixels;
    final viewportY = viewport.localToGlobal(Offset.zero).dy;
    final offset = position.pixels +
        matchY -
        viewportY -
        position.viewportDimension * 0.18;
    return offset.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  double? _currentMatchY() {
    final tableTarget = _tableMatchKey?.currentContext?.findRenderObject();
    final tableRect = _tableMatchRect;
    if (tableTarget is RenderBox && tableTarget.attached && tableRect != null) {
      return tableTarget.localToGlobal(tableRect.topLeft).dy;
    }
    final target = _matchTextKey.currentContext?.findRenderObject();
    if (target == null || !target.attached) {
      final blockTop = _matchBlockGlobalY();
      final localY = _matchBlockLocalY;
      return blockTop != null && localY != null ? blockTop + localY : null;
    }
    RenderEditable? editable;
    void visit(RenderObject object) {
      if (object is RenderEditable) {
        editable ??= object;
      } else {
        object.visitChildren(visit);
      }
    }

    visit(target);
    if (editable == null) {
      return target is RenderBox ? target.localToGlobal(Offset.zero).dy : null;
    }
    final boxes = editable!.getBoxesForSelection(TextSelection(
      baseOffset: _displayMatchStart,
      extentOffset: _displayMatchEnd,
    ));
    if (boxes.isEmpty) return null;
    return editable!.localToGlobal(Offset(0, boxes.first.top)).dy;
  }

  double? _matchBlockGlobalY() {
    final sliver = _matchSliverKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliver || !sliver.attached) return null;
    final position = _scrollController.position;
    final viewport = position.context.notificationContext?.findRenderObject();
    if (viewport is! RenderBox) return null;
    return viewport.localToGlobal(Offset.zero).dy +
        sliver.constraints.precedingScrollExtent -
        position.pixels;
  }

  TapGestureRecognizer _recognizerFor(String url) =>
      _linkRecognizers.putIfAbsent(
          url,
          () => TapGestureRecognizer()
            ..onTap = () => unawaited(_openExternal(url)));

  @override
  void dispose() {
    _matchPauseTimer?.cancel();
    _prefixMetricsGeneration++;
    _scrollController.dispose();
    for (final recognizer in _linkRecognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  /// Route hosting this page, used to wait for the push animation to settle.
  ModalRoute<dynamic>? _route;

  Future<AnnouncementDetail>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of<dynamic>(context);
    // The request is fired on the first frame, but _load holds its result back
    // until the push animation has settled.
    _future ??= _load();
  }

  Future<AnnouncementDetail> _load() {
    // Future.wait subscribes to the request right away, which avoids an
    // unhandled async error while the animation is still running. Its
    // eagerError defaults to false, so a failure also waits for the animation.
    return Future.wait<AnnouncementDetail?>([
      widget.repository.fetchDetail(widget.item),
      _waitForRoutePushAnimation().then((_) => null),
    ]).then((results) {
      final detail = results.first!;
      if (!detail.hasContent) {
        throw const AnnouncementApiException('公告正文无法解析');
      }
      return detail;
    });
  }

  /// DOM parsing, first layout and image decoding of the body keep the raster
  /// thread busy; overlapping them with the 240ms push animation drops frames.
  /// This defers the body until the animation has settled so the two do not
  /// compete for the same frames.
  Future<void> _waitForRoutePushAnimation() {
    final route = _route;
    if (route == null) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    var frames = 0;
    void poll(Duration _) {
      final animation = route.animation;
      // On the first frame of a push, HeroController marks the incoming route
      // offstage and swaps its animation for kAlwaysCompleteAnimation (value
      // 1.0), so offstage must not be read as "already settled". A zero-duration
      // transition emits no status change either, hence polling every frame
      // instead of listening to the animation status.
      final settled = !route.offstage &&
          (animation == null ||
              animation.isCompleted ||
              !animation.isAnimating);
      // Safety net: release the body even if the animation misbehaves rather
      // than leaving it stuck in the loading state.
      if (settled || frames > _maximumAnimationFrames) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      frames++;
      WidgetsBinding.instance.addPostFrameCallback(poll);
    }

    WidgetsBinding.instance.addPostFrameCallback(poll);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('公告详情'),
        actions: [
          IconButton(
            tooltip: '复制公告链接',
            icon: const Icon(Icons.share_outlined),
            onPressed: _copyLink,
          ),
          IconButton(
            tooltip: '查看原文',
            icon: const Icon(Icons.open_in_new),
            onPressed: _confirmOpenOriginal,
          ),
        ],
      ),
      body: FutureBuilder<AnnouncementDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _AnnouncementLoadingState();
          }
          if (snapshot.hasError) {
            if (snapshot.error is AnnouncementUnavailableException) {
              return const EmptyState(
                icon: Icons.link_off_outlined,
                title: '公告失效',
                message: '系统提示：您访问的页面未找到，可能已被删除。',
              );
            }
            return _AnnouncementErrorState(
              message: '公告详情加载失败，请稍后重试',
              onRetry: () async {
                setState(() {
                  _future = _load();
                });
              },
            );
          }
          final detail = snapshot.data!;
          _findSearchMatch(detail);
          _positionFirstMatch();
          final colors = context.shuyoColors;
          final imageUrls = detail.blocks
              .where((block) => block.isImage)
              .map((block) => block.value)
              .toList(growable: false);
          // Precompute every image's index into imageUrls to avoid an O(n²)
          // scan while building the list.
          final imageIndexByBlock = <int, int>{};
          for (var index = 0; index < detail.blocks.length; index++) {
            if (detail.blocks[index].isImage) {
              imageIndexByBlock[index] = imageIndexByBlock.length;
            }
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
              child: _matchedBlockIndex != null
                  ? _matchedArticleList(detail, imageUrls, imageIndexByBlock)
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        _announcementDetailPadding,
                        10,
                        _announcementDetailPadding,
                        28,
                      ),
                      children: [
                        _detailTitle(detail),
                        const SizedBox(height: 12),
                        _AnnouncementMetadata(
                          detail: detail,
                          showDepartment: AnnouncementTarget.resolve(detail.url,
                                  sourceId: widget.item.sourceId)
                              .showDepartment,
                        ),
                        const SizedBox(height: 22),
                        if (!detail.hasContent)
                          Text(
                            '这条公告暂时没有解析到正文。',
                            style: TextStyle(color: colors.textTertiary),
                          )
                        else
                          ...List.generate(detail.blocks.length, (index) {
                            return _blockWidget(
                              detail.blocks[index],
                              imageUrls: imageUrls,
                              imageIndex: imageIndexByBlock[index] ?? 0,
                            );
                          }),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _detailTitle(AnnouncementDetail detail) {
    final style = ShuYoTextStyles.title(
      color: context.shuyoColors.textPrimary,
      size: 20,
      height: 1.22,
      weight: FontWeight.w600,
    );
    final matches = announcementSearchPattern(widget.highlightQuery)
        ?.allMatches(detail.title)
        .toList(growable: false);
    if (matches == null || matches.isEmpty) {
      return Text(detail.title, style: style);
    }
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in matches) {
      if (match.start > offset) {
        spans.add(TextSpan(text: detail.title.substring(offset, match.start)));
      }
      spans.add(TextSpan(
        text: detail.title.substring(match.start, match.end),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ));
      offset = match.end;
    }
    if (offset < detail.title.length) {
      spans.add(TextSpan(text: detail.title.substring(offset)));
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
    );
  }

  Widget _matchedArticleList(
    AnnouncementDetail detail,
    List<String> imageUrls,
    Map<int, int> imageIndexByBlock,
  ) {
    final matchIndex = _matchedBlockIndex!;
    Widget blockAt(int index) => _blockWidget(
          detail.blocks[index],
          imageUrls: imageUrls,
          imageIndex: imageIndexByBlock[index] ?? 0,
          highlight: index == matchIndex,
        );
    return LayoutBuilder(builder: (context, constraints) {
      _preparePrefixMetrics(context, detail,
          constraints.maxWidth - _announcementDetailPadding * 2);
      final prefixSlivers = <Widget>[];
      var index = 0;
      while (index < matchIndex) {
        final start = index;
        final plainText = _isMeasuredPrefixText(detail.blocks[index]);
        if (plainText) {
          while (index < matchIndex &&
              _isMeasuredPrefixText(detail.blocks[index])) {
            index++;
          }
        } else {
          while (index < matchIndex &&
              !_isMeasuredPrefixText(detail.blocks[index])) {
            index++;
          }
        }
        final count = index - start;
        prefixSlivers.add(SliverPadding(
          padding: const EdgeInsets.symmetric(
              horizontal: _announcementDetailPadding),
          sliver: plainText && _prefixMetricsReady
              ? SliverVariedExtentList.builder(
                  itemCount: count,
                  itemExtentBuilder: (index, dimensions) =>
                      index < count ? _prefixTextExtents[start + index] : null,
                  itemBuilder: (context, index) => blockAt(start + index),
                )
              : SliverList.builder(
                  itemCount: count,
                  itemBuilder: (context, index) => blockAt(start + index),
                ),
        ));
      }
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical) {
            _scheduleMatchCorrection();
          }
          return false;
        },
        child: Listener(
          onPointerDown: (_) => _cancelMatchNavigation(),
          onPointerSignal: (_) => _cancelMatchNavigation(),
          child: CustomScrollView(
            key: const ValueKey('announcement-search-matched-article'),
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(_announcementDetailPadding,
                    10, _announcementDetailPadding, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detailTitle(detail),
                      const SizedBox(height: 12),
                      _AnnouncementMetadata(
                        detail: detail,
                        showDepartment: AnnouncementTarget.resolve(detail.url,
                                sourceId: widget.item.sourceId)
                            .showDepartment,
                      ),
                      const SizedBox(height: 22),
                    ],
                  ),
                ),
              ),
              ...prefixSlivers,
              SliverPadding(
                key: _matchSliverKey,
                padding: const EdgeInsets.fromLTRB(_announcementDetailPadding,
                    0, _announcementDetailPadding, 28),
                sliver: SliverList.builder(
                  itemCount: detail.blocks.length - matchIndex,
                  itemBuilder: (context, index) => blockAt(matchIndex + index),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  bool _isMeasuredPrefixText(AnnouncementContentBlock block) =>
      block.isText && block.parts.every((part) => part.url.isEmpty);

  /// Known text extents let the lazy list pass distant paragraphs without
  /// creating every SelectableText on the way. The initial body is already
  /// visible while these cheap measurements run in short frame slices.
  void _preparePrefixMetrics(
      BuildContext context, AnnouncementDetail detail, double width) {
    final defaults = DefaultTextStyle.of(context);
    var style = defaults.style.merge(TextStyle(
      fontSize: 16,
      height: 1.7,
      color: context.shuyoColors.textPrimary,
    ));
    style = style.copyWith(
      height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context) ??
          style.height,
      letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context) ??
          style.letterSpacing,
      wordSpacing:
          MediaQuery.maybeWordSpacingOverrideOf(context) ?? style.wordSpacing,
    );
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior = defaults.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    final configuration = (
      width,
      style,
      scaler,
      direction,
      locale,
      defaults.textAlign,
      defaults.textWidthBasis,
      defaults.maxLines,
      heightBehavior,
    );
    if (_prefixMetricsConfiguration == configuration) return;
    _prefixMetricsConfiguration = configuration;
    _prefixMetricsReady = false;
    _prefixTextExtents.clear();
    final generation = ++_prefixMetricsGeneration;
    final matchIndex = _matchedBlockIndex!;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _prefixMetricsGeneration) return;
      _matchPauseTimer ??= Timer(const Duration(milliseconds: 250), () {
        if (!mounted || _matchNavigationCancelled) return;
        setState(() => _matchPauseElapsed = true);
        _positionFirstMatch();
        WidgetsBinding.instance.scheduleFrame();
      });
      final stopwatch = Stopwatch()..start();
      for (var index = 0; index < matchIndex; index++) {
        if (!mounted || generation != _prefixMetricsGeneration) return;
        final block = detail.blocks[index];
        if (!_isMeasuredPrefixText(block)) continue;
        final text = block.parts.isEmpty
            ? block.value
            : block.parts.map((part) => part.text).join();
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: direction,
          textAlign: defaults.textAlign ?? TextAlign.start,
          textScaler: scaler,
          textWidthBasis: defaults.textWidthBasis,
          textHeightBehavior: heightBehavior,
          maxLines: defaults.maxLines,
          locale: locale,
          strutStyle: const StrutStyle().inheritFromTextStyle(style),
        )..layout(maxWidth: math.max(0, width - 3));
        // SelectableText's RenderEditable reserves a 2px caret plus 1px gap.
        _prefixTextExtents[index] = painter.height + 13;
        painter.dispose();
        if (stopwatch.elapsedMicroseconds >= 2200) {
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
          stopwatch.reset();
        }
      }
      if (!mounted || generation != _prefixMetricsGeneration) return;
      setState(() => _prefixMetricsReady = true);
      _positionFirstMatch();
    });
  }

  void _cancelMatchNavigation() {
    if (_matchNavigationCancelled) return;
    _matchPauseTimer?.cancel();
    _matchNavigationCancelled = true;
    if (_scrollController.hasClients &&
        _scrollController.position.isScrollingNotifier.value) {
      _scrollController.jumpTo(_scrollController.offset);
    }
    setState(() {});
  }

  Widget _blockWidget(
    AnnouncementContentBlock block, {
    required List<String> imageUrls,
    required int imageIndex,
    bool highlight = false,
  }) {
    if (block.isLink) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _openExternal(block.value),
          icon: Icon(
            block.value.startsWith('mailto:')
                ? Icons.mail_outline
                : Icons.open_in_new,
            size: 18,
          ),
          label: highlight
              ? Text.rich(
                  key: _matchTextKey,
                  TextSpan(
                      children: _highlightedSpans(block.label,
                          start: _matchStart, end: _matchEnd)),
                )
              : Text(block.label.isEmpty ? '查看链接' : block.label),
        ),
      );
    }
    if (block.isTable) {
      return _AnnouncementTableWidget(
        block: block,
        color: context.shuyoColors,
        match: highlight ? _matchedTableCell : null,
        matchKey: highlight ? _matchTextKey : null,
        positionMatch: _matchPauseElapsed &&
            _prefixMetricsReady &&
            !_matchNavigationCancelled,
        onMatchReady: highlight
            ? (key, rect) {
                _tableMatchKey = key;
                _tableMatchRect = rect;
                _positionFirstMatch();
              }
            : null,
      );
    }
    if (block.isImage) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: GestureDetector(
          onTap: () {
            Navigator.of(context).push<void>(
              shuyoRoute(
                builder: (context) => FullscreenImagePage(
                  urls: imageUrls,
                  initialIndex: imageIndex,
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              block.value,
              fit: BoxFit.cover,
              // Decode at the width the body actually displays: source images
              // are often wider than 1000px, and decoding them at full size
              // makes the raster thread drop frames during the transition and
              // the scrolling that follows.
              cacheWidth: _decodeWidth(context),
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || frame != null) {
                  return child;
                }
                return const _AnnouncementImagePlaceholder();
              },
              errorBuilder: (context, error, stackTrace) {
                final colors = context.shuyoColors;
                return Container(
                  height: 120,
                  alignment: Alignment.center,
                  color: colors.surfaceAlt,
                  child: Text(
                    '图片加载失败',
                    style: TextStyle(color: colors.textTertiary),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: SelectableText.rich(
        key: highlight ? _matchTextKey : null,
        TextSpan(children: _bodyTextSpans(block, highlight: highlight)),
        style: TextStyle(
          fontSize: 16,
          height: 1.7,
          color: context.shuyoColors.textPrimary,
        ),
      ),
    );
  }

  List<InlineSpan> _bodyTextSpans(
    AnnouncementContentBlock block, {
    required bool highlight,
  }) {
    if (!highlight) {
      if (block.parts.isEmpty) return [TextSpan(text: block.value)];
      return block.parts.map((part) {
        if (part.url.isEmpty) return TextSpan(text: part.text);
        final primary = Theme.of(context).colorScheme.primary;
        return TextSpan(children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Icon(
                part.url.startsWith('mailto:')
                    ? Icons.mail_outline
                    : Icons.open_in_new,
                size: 17,
                color: primary,
              ),
            ),
          ),
          TextSpan(
            text: _breakableInlineLinkText(part.text, part.url),
            style: TextStyle(
              color: primary,
              decoration: TextDecoration.underline,
              decorationColor: primary,
            ),
            recognizer: _recognizerFor(part.url),
          ),
        ]);
      }).toList();
    }
    final parts = block.parts.isEmpty
        ? [AnnouncementInlinePart(block.value)]
        : block.parts;
    final spans = <InlineSpan>[];
    var rawOffset = 0;
    var displayOffset = 0;
    int displayIndex(String text, int rawIndex) {
      var characters = 0;
      for (var index = 0; index < text.length; index++) {
        if (characters == rawIndex) return index;
        if (text[index] != '\u200B') characters++;
      }
      return text.length;
    }

    for (final part in parts) {
      final isLink = part.url.isNotEmpty;
      final primary = Theme.of(context).colorScheme.primary;
      final text =
          isLink ? _breakableInlineLinkText(part.text, part.url) : part.text;
      final style = isLink
          ? TextStyle(
              color: primary,
              decoration: TextDecoration.underline,
              decorationColor: primary,
            )
          : null;
      final recognizer = isLink ? _recognizerFor(part.url) : null;
      if (isLink) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Icon(
              part.url.startsWith('mailto:')
                  ? Icons.mail_outline
                  : Icons.open_in_new,
              size: 17,
              color: primary,
            ),
          ),
        ));
        displayOffset++;
      }
      if (highlight &&
          _matchStart >= rawOffset &&
          _matchStart < rawOffset + part.text.length) {
        _displayMatchStart =
            displayOffset + displayIndex(text, _matchStart - rawOffset);
      }
      if (highlight &&
          _matchEnd > rawOffset &&
          _matchEnd <= rawOffset + part.text.length) {
        _displayMatchEnd =
            displayOffset + displayIndex(text, _matchEnd - rawOffset);
      }
      if (highlight &&
          _matchStart < rawOffset + part.text.length &&
          _matchEnd > rawOffset) {
        final start = displayIndex(
            text, (_matchStart - rawOffset).clamp(0, part.text.length));
        final end = displayIndex(
            text, (_matchEnd - rawOffset).clamp(0, part.text.length));
        if (start > 0) {
          spans.add(TextSpan(
              text: text.substring(0, start),
              style: style,
              recognizer: recognizer));
        }
        spans.add(TextSpan(
          text: text.substring(start, end),
          style: (style ?? const TextStyle()).copyWith(
            color: primary,
            fontWeight: FontWeight.w600,
          ),
          recognizer: recognizer,
        ));
        if (end < text.length) {
          spans.add(TextSpan(
              text: text.substring(end), style: style, recognizer: recognizer));
        }
      } else {
        spans.add(TextSpan(text: text, style: style, recognizer: recognizer));
      }
      rawOffset += part.text.length;
      displayOffset += text.length;
    }
    return spans;
  }

  /// Pixel width the body actually occupies, used as the image decode width.
  int _decodeWidth(BuildContext context) {
    final logicalWidth =
        MediaQuery.sizeOf(context).width - _announcementDetailPadding * 2;
    final pixels =
        (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
    return pixels < 1 ? 1 : pixels;
  }

  Future<bool> _openExternal(String url) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // Keep the readable page available when the system cannot open the link.
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开原网站链接')),
      );
    }
    return opened;
  }

  Future<void> _confirmOpenOriginal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳转浏览器'),
        content: const Text('将在浏览器中打开公告'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _openExternal(widget.item.url);
    }
  }

  Future<void> _copyLink() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.item.url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('公告链接已复制')),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('复制失败，请重试')),
      );
    }
  }
}

/// Holds the image's place until it is decoded, so the body does not jump from
/// zero height when the image arrives.
class _AnnouncementImagePlaceholder extends StatelessWidget {
  const _AnnouncementImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      key: announcementImagePlaceholderKey,
      height: _announcementImagePlaceholderHeight,
      alignment: Alignment.center,
      color: colors.surfaceAlt,
      child: Icon(Icons.image_outlined, size: 22, color: colors.textMuted),
    );
  }
}

/// The loading state carries its own repaint boundary, so during a transition
/// only this small area is re-recorded and the page layer can be reused.
class _AnnouncementTableWidget extends StatelessWidget {
  const _AnnouncementTableWidget({
    required this.block,
    required this.color,
    this.match,
    this.matchKey,
    this.onMatchReady,
    this.positionMatch = true,
  });

  final AnnouncementContentBlock block;
  final ShuYoColors color;
  final ({int row, int column, int start, int end})? match;
  final GlobalKey? matchKey;
  final void Function(GlobalKey key, Rect rect)? onMatchReady;
  final bool positionMatch;

  @override
  Widget build(BuildContext context) {
    final rowCount = block.rows.length;
    final columnCount = block.rows.fold<int>(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    if (rowCount == 0 || columnCount == 0) return const SizedBox.shrink();

    final cells = block.cells.isNotEmpty
        ? block.cells
        : [
            for (var row = 0; row < block.rows.length; row++)
              for (var column = 0; column < block.rows[row].length; column++)
                AnnouncementTableCell(
                  row: row,
                  column: column,
                  text: block.rows[row][column],
                ),
          ];
    if (cells.length > 24) {
      return _FastAnnouncementTable(
        block: block,
        cells: cells,
        rowCount: rowCount,
        columnCount: columnCount,
        color: color,
        match: match,
        matchColor: Theme.of(context).colorScheme.primary,
        onMatchReady: onMatchReady,
        positionMatch: positionMatch,
      );
    }
    final textStyle = TextStyle(color: color.textPrimary, fontSize: 13.5);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = math.max(
          112.0,
          constraints.maxWidth / columnCount,
        );
        final rowHeights = List<double>.filled(rowCount, 40);
        final measuredHeights = <AnnouncementTableCell, double>{};
        for (final cell in cells) {
          if (cell.row >= rowCount || cell.column >= columnCount) continue;
          final span = cell.columnSpan.clamp(1, columnCount - cell.column);
          final width = columnWidth * span;
          final painter = TextPainter(
            text: _tableCellTextSpan(cell,
                style: textStyle,
                match: match,
                matchColor: Theme.of(context).colorScheme.primary),
            textDirection: textDirection,
            textScaler: textScaler,
            textAlign: _textAlign(cell.textAlignment),
          )..layout(maxWidth: math.max(1, width - 16));
          final height = math.max(40.0, painter.height + 16);
          painter.dispose();
          measuredHeights[cell] = height;
          if (cell.rowSpan <= 1) {
            rowHeights[cell.row] = math.max(rowHeights[cell.row], height);
          }
        }
        for (final cell in cells) {
          if (cell.rowSpan <= 1 || cell.row >= rowCount) continue;
          final endRow = math.min(rowCount, cell.row + cell.rowSpan);
          final availableHeight = rowHeights
              .getRange(cell.row, endRow)
              .fold<double>(0, (total, height) => total + height);
          final requiredHeight = measuredHeights[cell] ?? 40;
          if (requiredHeight <= availableHeight) continue;
          final extra =
              (requiredHeight - availableHeight) / (endRow - cell.row);
          for (var row = cell.row; row < endRow; row++) {
            rowHeights[row] += extra;
          }
        }

        final rowOffsets = List<double>.filled(rowCount + 1, 0);
        for (var row = 0; row < rowCount; row++) {
          rowOffsets[row + 1] = rowOffsets[row] + rowHeights[row];
        }
        final columnOffsets = List<double>.generate(
          columnCount + 1,
          (index) => index * columnWidth,
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: columnOffsets.last,
              height: rowOffsets.last,
              child: Stack(
                children: [
                  for (final cell in cells)
                    if (cell.row < rowCount && cell.column < columnCount)
                      Positioned(
                        left: columnOffsets[cell.column],
                        top: rowOffsets[cell.row],
                        width: columnOffsets[math.min(
                                columnCount, cell.column + cell.columnSpan)] -
                            columnOffsets[cell.column],
                        height: rowOffsets[
                                math.min(rowCount, cell.row + cell.rowSpan)] -
                            rowOffsets[cell.row],
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: color.border, width: 0.5),
                          ),
                          padding: const EdgeInsets.all(8),
                          alignment: _cellAlignment(cell),
                          child: match?.row == cell.row &&
                                  match?.column == cell.column
                              ? SelectableText.rich(
                                  key: matchKey,
                                  _tableCellTextSpan(cell,
                                      style: textStyle,
                                      match: match,
                                      matchColor: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                  style: textStyle,
                                  textAlign: _textAlign(cell.textAlignment),
                                )
                              : SelectableText(
                                  cell.text,
                                  style: textStyle,
                                  textAlign: _textAlign(cell.textAlignment),
                                ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TextAlign _textAlign(String value) => switch (value) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      };

  Alignment _cellAlignment(AnnouncementTableCell cell) {
    final horizontal = switch (cell.textAlignment) {
      'center' => 0.0,
      'right' => 1.0,
      _ => -1.0,
    };
    final vertical = switch (cell.verticalAlignment) {
      'top' => -1.0,
      'bottom' => 1.0,
      _ => 0.0,
    };
    return Alignment(horizontal, vertical);
  }
}

TextSpan _tableCellTextSpan(
  AnnouncementTableCell cell, {
  required TextStyle style,
  ({int row, int column, int start, int end})? match,
  Color? matchColor,
}) {
  if (match == null || match.row != cell.row || match.column != cell.column) {
    return TextSpan(text: cell.text, style: style);
  }
  return TextSpan(style: style, children: [
    if (match.start > 0) TextSpan(text: cell.text.substring(0, match.start)),
    TextSpan(
      text: cell.text.substring(match.start, match.end),
      style: TextStyle(color: matchColor, fontWeight: FontWeight.w600),
    ),
    if (match.end < cell.text.length)
      TextSpan(text: cell.text.substring(match.end)),
  ]);
}

/// Large tables cache visible text layouts and paint only visible cells.
class _FastAnnouncementTable extends StatefulWidget {
  const _FastAnnouncementTable({
    required this.block,
    required this.cells,
    required this.rowCount,
    required this.columnCount,
    required this.color,
    this.match,
    this.matchColor,
    this.onMatchReady,
    this.positionMatch = true,
  });

  final AnnouncementContentBlock block;
  final List<AnnouncementTableCell> cells;
  final int rowCount;
  final int columnCount;
  final ShuYoColors color;
  final ({int row, int column, int start, int end})? match;
  final Color? matchColor;
  final void Function(GlobalKey key, Rect rect)? onMatchReady;
  final bool positionMatch;

  @override
  State<_FastAnnouncementTable> createState() => _FastAnnouncementTableState();
}

class _FastAnnouncementTableState extends State<_FastAnnouncementTable> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _paintKey = GlobalKey();
  _AnnouncementTablePaintLayout? _layout;
  double? _viewportWidth;
  TextScaler? _textScaler;
  TextDirection? _textDirection;
  Color? _textColor;
  int _layoutGeneration = 0;
  bool _matchPositioned = false;

  @override
  void didUpdateWidget(covariant _FastAnnouncementTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionMatch &&
        !widget.positionMatch &&
        _scrollController.hasClients &&
        _scrollController.position.isScrollingNotifier.value) {
      _scrollController.jumpTo(_scrollController.offset);
    }
    if (!identical(oldWidget.block, widget.block) ||
        oldWidget.match != widget.match ||
        oldWidget.matchColor != widget.matchColor) {
      _clearLayout();
    }
  }

  @override
  void dispose() {
    _clearLayout();
    _scrollController.dispose();
    super.dispose();
  }

  void _clearLayout() {
    _layoutGeneration++;
    _layout?.dispose();
    _layout = null;
    _viewportWidth = null;
    _textScaler = null;
    _textDirection = null;
    _textColor = null;
    _matchPositioned = false;
  }

  _AnnouncementTablePaintLayout? _layoutFor(
      double viewportWidth, TextScaler textScaler, TextDirection direction) {
    if (_viewportWidth == viewportWidth &&
        _textScaler == textScaler &&
        _textDirection == direction &&
        _textColor == widget.color.textPrimary) {
      return _layout;
    }
    _clearLayout();
    _viewportWidth = viewportWidth;
    _textScaler = textScaler;
    _textDirection = direction;
    _textColor = widget.color.textPrimary;
    final work = _AnnouncementTableLayoutWork(
      cells: widget.cells,
      rowCount: widget.rowCount,
      columnCount: widget.columnCount,
      textColor: widget.color.textPrimary,
      viewportWidth: viewportWidth,
      textScaler: textScaler,
      textDirection: direction,
      match: widget.match,
      matchColor: widget.matchColor,
    );
    if (widget.cells.length <= 256) {
      while (!work.isComplete) {
        work.advance();
      }
      return _layout = work.finish();
    }
    final generation = _layoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _layoutGeneration) {
        unawaited(_finishLargeLayout(work, generation));
      }
    });
    return null;
  }

  Future<void> _finishLargeLayout(
      _AnnouncementTableLayoutWork work, int generation) async {
    while (mounted && generation == _layoutGeneration && !work.isComplete) {
      final stopwatch = Stopwatch()..start();
      do {
        work.advance();
      } while (!work.isComplete && stopwatch.elapsedMicroseconds < 2200);
      if (!work.isComplete) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!mounted || generation != _layoutGeneration) return;
    setState(() => _layout = work.finish());
  }

  void _selectCell(LongPressStartDetails details) {
    final renderObject = _paintKey.currentContext?.findRenderObject();
    final layout = _layout;
    if (renderObject is! RenderBox || layout == null) return;
    final position = renderObject.globalToLocal(details.globalPosition);
    final row = layout.firstVisibleRow(position.dy);
    if (row >= layout.cellsByRow.length) return;
    for (final entry in layout.cellsByRow[row]) {
      if (!entry.rect.contains(position) || entry.cell.text.isEmpty) continue;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: SelectableText(entry.cell.text),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final verticalPosition = Scrollable.maybeOf(context)?.position;
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(builder: (context, constraints) {
      final layout = _layoutFor(constraints.maxWidth, textScaler, direction);
      if (layout == null) {
        return const SizedBox(
          height: 72,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      _positionTableMatch(layout, constraints.maxWidth);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: RepaintBoundary(
          key: const ValueKey<String>('announcement-fast-table'),
          child: GestureDetector(
            onLongPressStart: _selectCell,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: CustomPaint(
                key: _paintKey,
                size: Size(layout.width, layout.height),
                painter: _AnnouncementTablePainter(
                  layout: layout,
                  borderColor: widget.color.border,
                  scrollController: _scrollController,
                  verticalPosition: verticalPosition,
                  tableKey: _paintKey,
                  viewportWidth: constraints.maxWidth,
                  viewportHeight: screenHeight,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  void _positionTableMatch(_AnnouncementTablePaintLayout layout, double width) {
    final match = widget.match;
    if (match == null || _matchPositioned) return;
    _AnnouncementTablePaintCell? matchedCell;
    for (final entry in layout.cells) {
      if (entry.cell.row == match.row && entry.cell.column == match.column) {
        matchedCell = entry;
        break;
      }
    }
    if (matchedCell == null) return;
    _matchPositioned = widget.positionMatch;
    final cell = matchedCell;
    final painter = layout.painterFor(cell);
    final boxes = painter.getBoxesForSelection(TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    ));
    final content = cell.rect.deflate(8);
    final verticalFactor = switch (cell.cell.verticalAlignment) {
      'top' => 0.0,
      'bottom' => 1.0,
      _ => 0.5,
    };
    final textTop = content.top +
        math.max(0.0, content.height - painter.height) * verticalFactor;
    final rect = boxes.isEmpty
        ? content
        : boxes.first.toRect().shift(Offset(content.left, textTop));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_layout, layout)) return;
      if (widget.positionMatch && _scrollController.hasClients) {
        final position = _scrollController.position;
        unawaited(_scrollController.animateTo(
          (rect.left - width * 0.15)
              .clamp(position.minScrollExtent, position.maxScrollExtent),
          duration: _announcementMatchScrollDuration,
          curve: Curves.easeOutCubic,
        ));
      }
      widget.onMatchReady?.call(_paintKey, rect);
    });
  }
}

TextAlign _tableTextAlign(String value) => switch (value) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.left,
    };

class _AnnouncementTablePaintCell {
  _AnnouncementTablePaintCell(this.cell, this.textHeight);

  final AnnouncementTableCell cell;
  final double textHeight;
  late final Rect rect;
}

/// Measures large tables in short frame slices, then builds the paint index.
class _AnnouncementTableLayoutWork {
  _AnnouncementTableLayoutWork({
    required this.cells,
    required this.rowCount,
    required this.columnCount,
    required Color textColor,
    required double viewportWidth,
    required this.textScaler,
    required this.textDirection,
    this.match,
    this.matchColor,
  })  : columnWidth = math.max(112.0, viewportWidth / columnCount),
        style = TextStyle(color: textColor, fontSize: 13.5),
        rowHeights = List<double>.filled(rowCount, 40),
        rowOffsets = List<double>.filled(rowCount + 1, 0),
        cellsByRow = List.generate(
          rowCount,
          (_) => <_AnnouncementTablePaintCell>[],
        );

  final List<AnnouncementTableCell> cells;
  final int rowCount;
  final int columnCount;
  final double columnWidth;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final ({int row, int column, int start, int end})? match;
  final Color? matchColor;
  final List<double> rowHeights;
  final List<double> rowOffsets;
  final List<List<_AnnouncementTablePaintCell>> cellsByRow;
  final List<_AnnouncementTablePaintCell> entries = [];
  int _phase = 0;
  int _index = 0;

  bool get isComplete => _phase == 4;

  int _lastRow(AnnouncementTableCell cell) =>
      math.min(rowCount, cell.row + math.max(1, cell.rowSpan));

  void advance() {
    if (_phase == 0) {
      if (_index == cells.length) {
        _phase = 1;
        _index = 0;
        return;
      }
      final cell = cells[_index++];
      if (cell.row < 0 ||
          cell.column < 0 ||
          cell.row >= rowCount ||
          cell.column >= columnCount) {
        return;
      }
      final span = cell.columnSpan.clamp(1, columnCount - cell.column);
      final painter = TextPainter(
        text: _tableCellTextSpan(cell,
            style: style, match: match, matchColor: matchColor),
        textDirection: textDirection,
        textScaler: textScaler,
        textAlign: _tableTextAlign(cell.textAlignment),
      )..layout(maxWidth: math.max(1, columnWidth * span - 16));
      final height = math.max(40.0, painter.height + 16);
      painter.dispose();
      entries.add(_AnnouncementTablePaintCell(cell, height));
      if (cell.rowSpan <= 1) {
        rowHeights[cell.row] = math.max(rowHeights[cell.row], height);
      }
      return;
    }
    if (_phase == 1) {
      if (_index == entries.length) {
        _phase = 2;
        _index = 0;
        return;
      }
      final entry = entries[_index++];
      final cell = entry.cell;
      if (cell.rowSpan <= 1) return;
      final endRow = _lastRow(cell);
      final currentHeight = rowHeights
          .getRange(cell.row, endRow)
          .fold<double>(0, (sum, height) => sum + height);
      if (entry.textHeight <= currentHeight) return;
      final extra = (entry.textHeight - currentHeight) / (endRow - cell.row);
      for (var row = cell.row; row < endRow; row++) {
        rowHeights[row] += extra;
      }
      return;
    }
    if (_phase == 2) {
      if (_index == rowCount) {
        _phase = 3;
        _index = 0;
        return;
      }
      rowOffsets[_index + 1] = rowOffsets[_index] + rowHeights[_index];
      _index++;
      return;
    }
    if (_phase == 3) {
      if (_index == entries.length) {
        _phase = 4;
        return;
      }
      final entry = entries[_index++];
      final cell = entry.cell;
      final endRow = _lastRow(cell);
      entry.rect = Rect.fromLTRB(
        cell.column * columnWidth,
        rowOffsets[cell.row],
        math.min(columnCount, cell.column + math.max(1, cell.columnSpan)) *
            columnWidth,
        rowOffsets[endRow],
      );
      for (var row = cell.row; row < endRow; row++) {
        cellsByRow[row].add(entry);
      }
    }
  }

  _AnnouncementTablePaintLayout finish() {
    assert(isComplete);
    return _AnnouncementTablePaintLayout(
      width: columnCount * columnWidth,
      height: rowOffsets.last,
      cells: entries,
      rowOffsets: rowOffsets,
      cellsByRow: cellsByRow,
      style: style,
      textScaler: textScaler,
      textDirection: textDirection,
      match: match,
      matchColor: matchColor,
    );
  }
}

class _AnnouncementTablePaintLayout {
  _AnnouncementTablePaintLayout({
    required this.width,
    required this.height,
    required this.cells,
    required this.rowOffsets,
    required this.cellsByRow,
    required this.style,
    required this.textScaler,
    required this.textDirection,
    this.match,
    this.matchColor,
  });

  final double width;
  final double height;
  final List<_AnnouncementTablePaintCell> cells;
  final List<double> rowOffsets;
  final List<List<_AnnouncementTablePaintCell>> cellsByRow;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final ({int row, int column, int start, int end})? match;
  final Color? matchColor;
  final Map<_AnnouncementTablePaintCell, TextPainter> _painters = {};

  int firstVisibleRow(double top) {
    var low = 0;
    var high = rowOffsets.length;
    while (low < high) {
      final middle = low + (high - low) ~/ 2;
      if (rowOffsets[middle] <= top) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return (low - 1).clamp(0, cellsByRow.length);
  }

  int firstRowAfter(double bottom) {
    var low = 0;
    var high = rowOffsets.length;
    while (low < high) {
      final middle = low + (high - low) ~/ 2;
      if (rowOffsets[middle] < bottom) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low.clamp(0, cellsByRow.length);
  }

  TextPainter painterFor(_AnnouncementTablePaintCell cell) {
    final cached = _painters.remove(cell);
    if (cached != null) {
      _painters[cell] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: _tableCellTextSpan(cell.cell,
          style: style, match: match, matchColor: matchColor),
      textDirection: textDirection,
      textScaler: textScaler,
      textAlign: _tableTextAlign(cell.cell.textAlignment),
    )..layout(maxWidth: math.max(1, cell.rect.width - 16));
    if (_painters.length >= 256) {
      _painters.remove(_painters.keys.first)?.dispose();
    }
    _painters[cell] = painter;
    return painter;
  }

  void dispose() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }
}

class _AnnouncementTablePainter extends CustomPainter {
  _AnnouncementTablePainter({
    required this.layout,
    required this.borderColor,
    required this.scrollController,
    required this.verticalPosition,
    required this.tableKey,
    required this.viewportWidth,
    required this.viewportHeight,
  }) : super(
            repaint: Listenable.merge([
          scrollController,
          if (verticalPosition != null) verticalPosition,
        ]));

  final _AnnouncementTablePaintLayout layout;
  final Color borderColor;
  final ScrollController scrollController;
  final ScrollPosition? verticalPosition;
  final GlobalKey tableKey;
  final double viewportWidth;
  final double viewportHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final left = scrollController.hasClients ? scrollController.offset : 0.0;
    final right = left + viewportWidth;
    final renderObject = tableKey.currentContext?.findRenderObject();
    final top = renderObject is RenderBox
        ? renderObject.globalToLocal(Offset.zero).dy
        : 0.0;
    final bottom = renderObject is RenderBox
        ? renderObject.globalToLocal(Offset(0, viewportHeight)).dy
        : size.height;
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final paintedSpans = <_AnnouncementTablePaintCell>{};
    final firstRow = layout.firstVisibleRow(top);
    final lastRow = layout.firstRowAfter(bottom);
    for (var row = firstRow; row < lastRow; row++) {
      for (final entry in layout.cellsByRow[row]) {
        if (entry.cell.rowSpan > 1 && !paintedSpans.add(entry)) continue;
        final rect = entry.rect;
        if (rect.right <= left ||
            rect.left >= right ||
            rect.bottom <= top ||
            rect.top >= bottom) {
          continue;
        }
        canvas.drawRect(rect, border);
        final content = rect.deflate(8);
        if (content.isEmpty) continue;
        final painter = layout.painterFor(entry);
        final verticalFactor = switch (entry.cell.verticalAlignment) {
          'top' => 0.0,
          'bottom' => 1.0,
          _ => 0.5,
        };
        final textTop = content.top +
            math.max(0.0, content.height - painter.height) * verticalFactor;
        canvas.save();
        canvas.clipRect(content);
        painter.paint(canvas, Offset(content.left, textTop));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AnnouncementTablePainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.viewportWidth != viewportWidth ||
      oldDelegate.viewportHeight != viewportHeight ||
      oldDelegate.verticalPosition != verticalPosition;
}

class _AnnouncementLoadingState extends StatelessWidget {
  const _AnnouncementLoadingState();

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
    );
  }
}

class _AnnouncementTile extends StatefulWidget {
  const _AnnouncementTile({
    super.key,
    required this.index,
    required this.item,
    required this.external,
    this.updatesPaused,
    required this.presentation,
    this.highlightQuery = '',
    required this.onTap,
  });

  final int index;
  final AnnouncementListItem item;
  final bool external;
  final ValueNotifier<bool>? updatesPaused;
  final _AnnouncementCardPresentation presentation;
  final String highlightQuery;
  final VoidCallback onTap;

  @override
  State<_AnnouncementTile> createState() => _AnnouncementTileState();
}

class _AnnouncementTileState extends State<_AnnouncementTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<Offset> _slide;
  Timer? _entranceTimer;
  AnnouncementCardData get _card => widget.presentation.card!;

  bool get _updatesPaused => widget.updatesPaused?.value ?? false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0.12, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_entrance);
    widget.updatesPaused?.addListener(_onUpdatePauseChanged);
    _entrance.value = widget.presentation.entered ? 1 : 0;
    widget.presentation.entrance.parent = _entrance;
    widget.presentation.entered = true;
    _startEntrance();
  }

  @override
  void didUpdateWidget(covariant _AnnouncementTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updatesPaused != widget.updatesPaused) {
      oldWidget.updatesPaused?.removeListener(_onUpdatePauseChanged);
      widget.updatesPaused?.addListener(_onUpdatePauseChanged);
      _onUpdatePauseChanged();
    }
  }

  void _startEntrance() {
    if (_updatesPaused ||
        _entrance.isCompleted ||
        (_entranceTimer?.isActive ?? false)) {
      return;
    }
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted && !_updatesPaused) _entrance.forward();
      },
    );
  }

  void _onUpdatePauseChanged() {
    if (_updatesPaused) {
      _entranceTimer?.cancel();
      _entrance.stop();
      return;
    }
    _startEntrance();
  }

  @override
  void dispose() {
    widget.updatesPaused?.removeListener(_onUpdatePauseChanged);
    _entranceTimer?.cancel();
    // The month header can remain pinned after this tile leaves the viewport.
    if (identical(widget.presentation.entrance.parent, _entrance)) {
      widget.presentation.entrance.parent =
          const AlwaysStoppedAnimation<double>(1);
    }
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _entrance,
        child: _tile(_card.summary),
      ),
    );
  }

  Widget _tile(String? preview) {
    final item = widget.item;
    final colors = context.shuyoColors;
    final metadata = _card.dateText;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _title(item.title, colors),
                  if (preview != null && preview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _highlightedText(
                        preview,
                        TextStyle(
                          color: colors.textTertiary,
                          fontSize: 14,
                          height: 1.46,
                        ),
                      ),
                    ),
                  if (metadata.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        metadata,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              widget.external ? Icons.open_in_new : Icons.chevron_right,
              size: widget.external ? 18 : 24,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(String title, ShuYoColors colors) {
    final style = ShuYoTextStyles.title(
      color: colors.textPrimary,
      size: 16,
      height: 1.26,
      weight: FontWeight.w500,
    );
    return _highlightedText(title, style);
  }

  Widget _highlightedText(String text, TextStyle style) {
    final pattern = announcementSearchPattern(widget.highlightQuery);
    final matches = pattern?.allMatches(text);
    if (matches == null || matches.isEmpty) {
      return Text(text,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
    }
    final parts = <TextSpan>[];
    var start = 0;
    for (final match in matches) {
      if (match.start > start) {
        parts.add(TextSpan(text: text.substring(start, match.start)));
      }
      parts.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ));
      start = match.end;
    }
    if (start < text.length) {
      parts.add(TextSpan(text: text.substring(start)));
    }
    return Text.rich(TextSpan(children: parts),
        maxLines: 2, overflow: TextOverflow.ellipsis, style: style);
  }
}

class _AnnouncementMetadata extends StatelessWidget {
  const _AnnouncementMetadata({
    required this.detail,
    this.showDepartment = true,
  });

  final AnnouncementDetail detail;
  final bool showDepartment;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (detail.dateText.isNotEmpty) detail.dateText,
      if (showDepartment && detail.department.isNotEmpty) detail.department,
      if (detail.author.isNotEmpty) detail.author,
    ];
    if (parts.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      parts.join(' · '),
      style: TextStyle(color: context.shuyoColors.textTertiary, fontSize: 13),
    );
  }
}

class _AnnouncementErrorState extends StatelessWidget {
  const _AnnouncementErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: '加载失败',
      message: message,
      action: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    );
  }
}
