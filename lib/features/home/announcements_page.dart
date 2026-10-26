import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/announcement.dart';
import '../../data/models/announcement_source.dart';
import '../../data/models/announcement_target.dart';
import '../../data/repositories/announcement_repository.dart';
import '../../data/services/announcement_api_client.dart';
import '../../data/services/announcement_order.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/fullscreen_image_page.dart';

/// Horizontal padding of the detail body, also used hui derive the image decode
/// width.
const double _announcementDetailPadding = 20;

/// Height reserved until an image is decoded, so the body does not jump from
/// zero height when the image arrives.
const double _announcementImagePlaceholderHeight = 180;

/// Frame budget for waiting on the push animation, roughly 1.5 seconds, kept
/// only as a safety net.
const int _maximumAnimationFrames = 90;

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
  int _cardPreparationVersion = 0;
  final ValueNotifier<bool> _updatesPaused = ValueNotifier(false);
  Completer<void>? _listVisibilityGate;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  @override
  void dispose() {
    _requestGeneration++;
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
    return _LoadedAnnouncementList(sorted, _announcementRows(sorted));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_source == null || _source == AnnouncementSource.official
            ? '通知公告'
            : _source!.name),
        actions: [
          if (!widget.isDemo)
            IconButton(
              tooltip: '选择公告来源',
              onPressed: _source == null ? null : _chooseSource,
              icon: const Icon(Icons.format_list_bulleted),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _isBusy && !_isPullRefreshing
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
      final itemList = SliverList.builder(
        itemCount: end - start,
        itemBuilder: (context, index) {
          final itemRow = rows[start + index] as _AnnouncementItemRow;
          final item = itemRow.item;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AnnouncementTile(
                key: ValueKey(item.url),
                index: itemRow.index,
                item: item,
                repository: widget.repository,
                external: itemRow.external,
                updatesPaused: _updatesPaused,
                preparationVersion: _cardPreparationVersion,
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
        slivers.add(SliverMainAxisGroup(slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _AnnouncementStickyHeaderDelegate(month: header.label),
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

  List<Object> _announcementRows(List<AnnouncementListItem> items) {
    final rows = <Object>[];
    String? previousMonth;
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final date = item.publishedAt;
      if (date == null) {
        rows.add(_AnnouncementItemRow(index, item));
        previousMonth = null;
        continue;
      }
      final month = '${date.year}年${date.month}月';
      if (month != previousMonth) {
        rows.add(_AnnouncementMonthHeader(month, index));
        previousMonth = month;
      }
      rows.add(_AnnouncementItemRow(index, item));
    }
    return rows;
  }

  void _onScroll() {
    if (_updatesPaused.value || !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.extentAfter > 280 ||
        !_hasMore ||
        _loadingMore ||
        _isBusy) {
      return;
    }
    unawaited(_loadNextPage());
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
        // Request cancellation and visible-card preparation have different
        // lifetimes. Keep the entered cards intact until a new list succeeds.
        _cardPreparationVersion++;
      } else if (_loaded == null) {
        _loadError = failure;
      }
    });
    if (showError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(failure))),
      );
    }
    if (_loaded != null && _hasMore) _scheduleLoadMoreCheck();
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

class _LoadedAnnouncementList {
  const _LoadedAnnouncementList(this.items, this.rows);

  final List<AnnouncementListItem> items;
  final List<Object> rows;
}

class _AnnouncementMonthHeader {
  const _AnnouncementMonthHeader(this.label, this.index);

  final String label;
  final int index;
}

const _stickyHeaderExtent = 38.0;

class _AnnouncementStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _AnnouncementStickyHeaderDelegate({required this.month});

  final String month;

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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(
          month,
          style: ShuYoTextStyles.meta(
            color: colors.textSecondary,
            size: 12.5,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_AnnouncementStickyHeaderDelegate oldDelegate) =>
      month != oldDelegate.month;
}

class _AnnouncementItemRow {
  _AnnouncementItemRow(this.index, this.item);

  final int index;
  final AnnouncementListItem item;
  late final bool external =
      !AnnouncementTarget.resolve(item.url, sourceId: item.sourceId)
          .canOpenInApp;
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
  });

  final AnnouncementSource selected;
  final Set<String> initialFavorites;
  final AnnouncementMenuExpansion initialExpansion;
  final Future<Set<String>> Function(AnnouncementSource) onToggleFavorite;
  final Future<void> Function(AnnouncementMenuSection, bool) onExpansionChanged;
  final ValueChanged<AnnouncementSource> onSelect;

  @override
  State<_AnnouncementSourceMenu> createState() =>
      _AnnouncementSourceMenuState();
}

class _AnnouncementSourceMenuState extends State<_AnnouncementSourceMenu> {
  late Set<String> _favorites = {...widget.initialFavorites};
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
    final menuWidth = math.min(264.0, MediaQuery.sizeOf(context).width * 0.68);
    final menuChildren = <Widget>[
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
      _sectionHeader(
        AnnouncementSourceGroup.schoolPortal.label,
        _schoolPortalExpanded,
        () => _toggleSection(AnnouncementMenuSection.schoolPortal),
      ),
      if (_schoolPortalExpanded)
        for (final source in schoolPortalSources) _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.administrativeDepartment.label,
        _administrativeDepartmentExpanded,
        () => _toggleSection(AnnouncementMenuSection.administrativeDepartment),
      ),
      if (_administrativeDepartmentExpanded)
        for (final source in administrativeDepartmentSources)
          _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.affiliatedInstitution.label,
        _affiliatedInstitutionExpanded,
        () => _toggleSection(AnnouncementMenuSection.affiliatedInstitution),
      ),
      if (_affiliatedInstitutionExpanded)
        for (final source in affiliatedInstitutionSources) _sourceRow(source),
      _sectionHeader(
        AnnouncementSourceGroup.college.label,
        _collegeExpanded,
        () => _toggleSection(AnnouncementMenuSection.college),
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
      ),
      if (_researchInstituteExpanded)
        for (final source in researchInstituteSources) _sourceRow(source),
    ];
    return SizedBox(
      key: announcementSourceMenuKey,
      width: menuWidth,
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: Theme.of(context).colorScheme.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: CustomScrollView(
              controller: _scrollController,
              shrinkWrap: true,
              slivers: _menuSlivers(context, menuChildren, menuWidth),
            ),
          ),
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

  Widget _sectionHeader(String title, bool expanded, VoidCallback onTap) {
    final tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
      onTap: onTap,
    );
    return _AnnouncementMenuSectionHeader(title: title, tile: tile);
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
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      title: Text(
        source.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      selected: widget.selected == source,
      onTap: () => widget.onSelect(source),
      trailing: IconButton(
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
  });

  final AnnouncementRepository repository;
  final AnnouncementListItem item;

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  final Map<String, TapGestureRecognizer> _linkRecognizers = {};
  final ScrollController _scrollController = ScrollController();

  TapGestureRecognizer _recognizerFor(String url) =>
      _linkRecognizers.putIfAbsent(
          url,
          () => TapGestureRecognizer()
            ..onTap = () => unawaited(_openExternal(url)));

  @override
  void dispose() {
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
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(
                  _announcementDetailPadding,
                  10,
                  _announcementDetailPadding,
                  28,
                ),
                children: [
                  Text(
                    detail.title,
                    style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 20,
                      height: 1.22,
                      weight: FontWeight.w600,
                    ),
                  ),
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

  Widget _blockWidget(
    AnnouncementContentBlock block, {
    required List<String> imageUrls,
    required int imageIndex,
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
          label: Text(block.label.isEmpty ? '查看链接' : block.label),
        ),
      );
    }
    if (block.isTable) {
      return _AnnouncementTableWidget(
        block: block,
        color: context.shuyoColors,
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
        TextSpan(
            children: block.parts.isEmpty
                ? [TextSpan(text: block.value)]
                : block.parts.map((part) {
                    if (part.url.isEmpty) return TextSpan(text: part.text);
                    final link = TextSpan(
                      text: _breakableInlineLinkText(part.text, part.url),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: Theme.of(context).colorScheme.primary,
                      ),
                      recognizer: _recognizerFor(part.url),
                    );
                    final isEmail = part.url.startsWith('mailto:');
                    return TextSpan(children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Icon(
                            isEmail ? Icons.mail_outline : Icons.open_in_new,
                            size: 17,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      link,
                    ]);
                  }).toList()),
        style: TextStyle(
          fontSize: 16,
          height: 1.7,
          color: context.shuyoColors.textPrimary,
        ),
      ),
    );
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
  const _AnnouncementTableWidget({required this.block, required this.color});

  final AnnouncementContentBlock block;
  final ShuYoColors color;

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
            text: TextSpan(text: cell.text, style: textStyle),
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
                          child: SelectableText(
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

/// Large tables cache visible text layouts and paint only visible cells.
class _FastAnnouncementTable extends StatefulWidget {
  const _FastAnnouncementTable({
    required this.block,
    required this.cells,
    required this.rowCount,
    required this.columnCount,
    required this.color,
  });

  final AnnouncementContentBlock block;
  final List<AnnouncementTableCell> cells;
  final int rowCount;
  final int columnCount;
  final ShuYoColors color;

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

  @override
  void didUpdateWidget(covariant _FastAnnouncementTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.block, widget.block)) _clearLayout();
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
        text: TextSpan(text: cell.text, style: style),
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
  });

  final double width;
  final double height;
  final List<_AnnouncementTablePaintCell> cells;
  final List<double> rowOffsets;
  final List<List<_AnnouncementTablePaintCell>> cellsByRow;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
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
      text: TextSpan(text: cell.cell.text, style: style),
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
    required this.repository,
    required this.external,
    this.updatesPaused,
    this.preparationVersion = 0,
    required this.onTap,
  });

  final int index;
  final AnnouncementListItem item;
  final AnnouncementRepository repository;
  final bool external;
  final ValueNotifier<bool>? updatesPaused;
  final int preparationVersion;
  final VoidCallback onTap;

  @override
  State<_AnnouncementTile> createState() => _AnnouncementTileState();
}

class _AnnouncementTileState extends State<_AnnouncementTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<Offset> _slide;
  Timer? _entranceTimer;
  int _cardGeneration = 0;
  late AnnouncementCardData _card;
  AnnouncementCardData? _pendingCard;
  bool _cardReady = false;

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
    _loadCard();
  }

  @override
  void didUpdateWidget(covariant _AnnouncementTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updatesPaused != widget.updatesPaused) {
      oldWidget.updatesPaused?.removeListener(_onUpdatePauseChanged);
      widget.updatesPaused?.addListener(_onUpdatePauseChanged);
      _onUpdatePauseChanged();
    }
    // Pagination can return the repository's enriched copy of an existing
    // notice. Keep the entered snapshot until a real refresh so neither its
    // height nor its entrance changes underneath the reader.
    if (oldWidget.item.url != widget.item.url ||
        oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.preparationVersion != widget.preparationVersion ||
        oldWidget.external != widget.external ||
        oldWidget.repository != widget.repository ||
        (!_cardReady &&
            (oldWidget.item.summary != widget.item.summary ||
                oldWidget.item.dateText != widget.item.dateText ||
                oldWidget.item.publishedAt != widget.item.publishedAt))) {
      oldWidget.repository.cancelCard(oldWidget.item);
      _loadCard();
    }
  }

  void _loadCard() {
    final generation = ++_cardGeneration;
    _entranceTimer?.cancel();
    _entrance.reset();
    _cardReady = false;
    _pendingCard = null;
    _card = AnnouncementCardData.fromItem(widget.item);
    Future<AnnouncementCardData>.sync(
        () => widget.repository.loadCard(widget.item)).then(
      (card) => _completeCard(generation, card),
      onError: (Object error, StackTrace stackTrace) {
        // Failed preparation still exposes the original title and list fields.
        _completeCard(generation, _card);
      },
    );
  }

  void _completeCard(int generation, AnnouncementCardData card) {
    if (!mounted || generation != _cardGeneration) return;
    if (_updatesPaused) {
      _pendingCard = card;
      return;
    }
    setState(() {
      _card = card;
      _cardReady = true;
    });
    _startEntrance();
  }

  void _startEntrance() {
    if (!_cardReady ||
        _updatesPaused ||
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
    final card = _pendingCard;
    _pendingCard = null;
    if (card != null) {
      _completeCard(_cardGeneration, card);
    } else {
      _startEntrance();
    }
  }

  @override
  void dispose() {
    _cardGeneration++;
    widget.repository.cancelCard(widget.item);
    widget.updatesPaused?.removeListener(_onUpdatePauseChanged);
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _entrance,
        child: IgnorePointer(
          ignoring: !_cardReady,
          child: _tile(_card.summary),
        ),
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
                      child: Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
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
    return Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: ShuYoTextStyles.title(
        color: colors.textPrimary,
        size: 16,
        height: 1.26,
        weight: FontWeight.w500,
      ),
    );
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
