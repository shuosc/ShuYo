import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/announcement.dart';
import '../../data/models/announcement_source.dart';
import '../../data/repositories/announcement_repository.dart';
import '../../data/services/announcement_api_client.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/fullscreen_image_page.dart';

/// Horizontal padding of the detail body, also used to derive the image decode
/// width.
const double _announcementDetailPadding = 20;

/// Height reserved until an image is decoded, so the body does not jump from
/// zero height when the image arrives.
const double _announcementImagePlaceholderHeight = 180;

/// Frame budget for waiting on the push animation, roughly 1.5 seconds, kept
/// only as a safety net.
const int _maximumAnimationFrames = 90;

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
  bool _loadingMore = false;
  bool _hasMore = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialize();
  }

  @override
  void dispose() {
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
    final media = MediaQuery.maybeOf(context);
    final firstScreenHeight = media == null
        ? 740.0
        : media.size.height -
            media.padding.top -
            media.padding.bottom -
            kToolbarHeight -
            8;
    final items = await widget.repository.fetchAnnouncements(
      source: source,
      forceRefresh: forceRefresh,
      loadNextPage: loadNextPage,
    );
    final firstScreenCount =
        (firstScreenHeight / 120).ceil().clamp(0, items.length);
    final firstItems = items.take(firstScreenCount).toList();
    final previewItems =
        firstItems.where((item) => !_isExternalAnnouncement(item)).toList();
    final previews = await Future.wait(
      previewItems.map(widget.repository.loadPreview),
    );
    final previewsByUrl = {
      for (var index = 0; index < previewItems.length; index++)
        previewItems[index].url: previews[index],
    };
    return _LoadedAnnouncementList(items, {
      for (final item in firstItems) item.url: previewsByUrl[item.url],
    });
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
          child: _isBusy
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: _buildList(),
    );
  }

  Widget _buildList() {
    final loaded = _loaded;
    if (loaded == null) {
      final error = _loadError;
      return error == null
          ? const _AnnouncementLoadingState()
          : _AnnouncementErrorState(
              message: _friendlyError(error),
              onRetry: _refresh,
            );
    }
    final items = loaded.items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 96),
            EmptyState(
              icon: Icons.campaign_outlined,
              title: '暂无公告',
              message: '该来源暂时没有可展示的通知公告。',
            ),
          ],
        ),
      );
    }
    final rows = _announcementRows(items);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        separatorBuilder: (context, index) {
          if (index + 1 >= rows.length ||
              rows[index] is _AnnouncementMonthHeader ||
              rows[index + 1] is _AnnouncementMonthHeader ||
              CustomBackgroundScope.maybeOf(context) != null) {
            return const SizedBox.shrink();
          }
          return Divider(height: 1, color: context.shuyoColors.border);
        },
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          if (row is _AnnouncementMonthHeader) {
            return _AnimatedAnnouncementMonthHeader(
              label: row.label,
              index: row.index,
            );
          }
          final itemRow = row as _AnnouncementItemRow;
          final item = itemRow.item;
          return _AnnouncementTile(
            key: ValueKey(item.url),
            index: itemRow.index,
            item: item,
            repository: widget.repository,
            external: _isExternalAnnouncement(item),
            initialPreviewReady: loaded.initialPreviews.containsKey(item.url),
            initialPreview: loaded.initialPreviews[item.url],
            onTap: () => _openAnnouncement(item),
          );
        },
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
    if (!_scrollController.hasClients) {
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
        campus: true,
        college: false,
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
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
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
    });
    await _fetchPage(choice, forceRefresh: true);
  }

  Future<void> _refresh() async {
    final source = _source;
    if (source == null || _isBusy) return;
    await _fetchPage(source, forceRefresh: true);
  }

  Future<void> _loadNextPage() async {
    final source = _source;
    if (source == null || !_hasMore || _isBusy || _loadingMore) return;
    final generation = _requestGeneration;
    setState(() {
      _loadingMore = true;
      _isBusy = true;
    });
    try {
      final loaded = await _loadList(source, loadNextPage: true);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loaded = loaded;
        _hasMore = widget.repository.hasMoreAnnouncements(source: source);
      });
    } on Object catch (error) {
      if (mounted && generation == _requestGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() {
          _loadingMore = false;
          _isBusy = false;
        });
        _scheduleLoadMoreCheck();
      }
    }
  }

  void _scheduleLoadMoreCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  Future<void> _fetchPage(
    AnnouncementSource source, {
    bool forceRefresh = false,
  }) async {
    final generation = ++_requestGeneration;
    setState(() {
      _isBusy = true;
      _loadError = null;
      _loadingMore = false;
    });
    try {
      final loaded = await _loadList(source, forceRefresh: forceRefresh);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loaded = loaded;
        _hasMore = widget.repository.hasMoreAnnouncements(source: source);
      });
    } on Object catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      if (_loaded == null) {
        setState(() => _loadError = error);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _openDetail(AnnouncementListItem item) {
    Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => AnnouncementDetailPage(
          repository: widget.repository,
          item: item,
        ),
      ),
    );
  }

  void _openAnnouncement(AnnouncementListItem item) {
    if (_isExternalAnnouncement(item)) {
      unawaited(_openExternalAnnouncement(item.url));
      return;
    }
    _openDetail(item);
  }

  Future<void> _openExternalAnnouncement(String url) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // Keep the list available when the system cannot open the URL.
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开公告链接')),
      );
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
  const _LoadedAnnouncementList(this.items, this.initialPreviews);

  final List<AnnouncementListItem> items;
  final Map<String, String?> initialPreviews;
}

class _AnnouncementMonthHeader {
  const _AnnouncementMonthHeader(this.label, this.index);

  final String label;
  final int index;
}

class _AnimatedAnnouncementMonthHeader extends StatefulWidget {
  const _AnimatedAnnouncementMonthHeader({
    required this.label,
    required this.index,
  });

  final String label;
  final int index;

  @override
  State<_AnimatedAnnouncementMonthHeader> createState() =>
      _AnimatedAnnouncementMonthHeaderState();
}

class _AnimatedAnnouncementMonthHeaderState
    extends State<_AnimatedAnnouncementMonthHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _startEntrance();
  }

  @override
  void didUpdateWidget(covariant _AnimatedAnnouncementMonthHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label || oldWidget.index != widget.index) {
      _startEntrance();
    }
  }

  void _startEntrance() {
    _entranceTimer?.cancel();
    _entrance.reset();
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
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
      ).animate(CurvedAnimation(
        parent: _entrance,
        curve: Curves.easeOutCubic,
      )),
      child: FadeTransition(
        opacity: _entrance,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(
            widget.label,
            style: ShuYoTextStyles.meta(
              color: context.shuyoColors.textSecondary,
              size: 12.5,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnnouncementItemRow {
  const _AnnouncementItemRow(this.index, this.item);

  final int index;
  final AnnouncementListItem item;
}

bool _isExternalAnnouncement(AnnouncementListItem item) {
  final uri = Uri.tryParse(item.url);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return true;
  }
  final host = uri.host.toLowerCase();
  if (host == 'mp.weixin.qq.com') return false;
  final sourceUri =
      Uri.tryParse(AnnouncementSource.byId(item.sourceId).listUrl);
  return sourceUri == null || host != sourceUri.host.toLowerCase();
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
  late bool _campusExpanded = widget.initialExpansion.campus;
  late bool _collegeExpanded = widget.initialExpansion.college;
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
    final campusSources =
        AnnouncementSource.inGroup(AnnouncementSourceGroup.campus);
    final collegeSources =
        AnnouncementSource.inGroup(AnnouncementSourceGroup.college);
    final menuWidth = math.min(264.0, MediaQuery.sizeOf(context).width * 0.68);
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
            child: ListView(
              controller: _scrollController,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
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
                _sectionHeader('校级与公共服务', _campusExpanded,
                    () => _toggleSection(AnnouncementMenuSection.campus)),
                if (_campusExpanded)
                  for (final source in campusSources) _sourceRow(source),
                _sectionHeader('学院与培养单位', _collegeExpanded,
                    () => _toggleSection(AnnouncementMenuSection.college)),
                if (_collegeExpanded)
                  for (final source in collegeSources) _sourceRow(source),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, bool expanded, VoidCallback onTap) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
      onTap: onTap,
    );
  }

  void _toggleSection(AnnouncementMenuSection section) {
    late final bool expanded;
    setState(() {
      switch (section) {
        case AnnouncementMenuSection.favorites:
          expanded = _favoritesExpanded = !_favoritesExpanded;
        case AnnouncementMenuSection.campus:
          expanded = _campusExpanded = !_campusExpanded;
        case AnnouncementMenuSection.college:
          expanded = _collegeExpanded = !_collegeExpanded;
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
    ]).then((results) => results.first!);
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
          return ListView(
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
              _AnnouncementMetadata(detail: detail),
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
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(block.label.isEmpty ? '查看链接' : block.label),
        ),
      );
    }
    if (block.isTable) {
      final colors = context.shuyoColors;
      final columnCount = block.rows.fold<int>(
        0,
        (count, row) => row.length > count ? row.length : count,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: colors.border),
            children: [
              for (final row in block.rows)
                TableRow(
                  children: [
                    for (var index = 0; index < columnCount; index++)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: SelectableText(
                          index < row.length ? row[index] : '',
                          style: TextStyle(color: colors.textPrimary),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
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
      child: SelectableText(
        block.value,
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

  Future<void> _openExternal(String url) async {
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
    required this.initialPreviewReady,
    required this.initialPreview,
    required this.onTap,
  });

  final int index;
  final AnnouncementListItem item;
  final AnnouncementRepository repository;
  final bool external;
  final bool initialPreviewReady;
  final String? initialPreview;
  final VoidCallback onTap;

  @override
  State<_AnnouncementTile> createState() => _AnnouncementTileState();
}

class _AnnouncementTileState extends State<_AnnouncementTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  Timer? _entranceTimer;
  int _previewGeneration = 0;
  late bool _previewReady;
  String? _resolvedPreview;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _loadPreview();
  }

  @override
  void didUpdateWidget(covariant _AnnouncementTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url ||
        oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.summary != widget.item.summary ||
        oldWidget.initialPreviewReady != widget.initialPreviewReady ||
        oldWidget.initialPreview != widget.initialPreview ||
        oldWidget.external != widget.external ||
        oldWidget.repository != widget.repository) {
      _loadPreview();
    }
  }

  void _loadPreview() {
    final generation = ++_previewGeneration;
    _entranceTimer?.cancel();
    _entrance.reset();
    _previewReady =
        widget.initialPreviewReady || widget.item.summary.isNotEmpty;
    _resolvedPreview = widget.item.summary.isNotEmpty
        ? widget.item.summary
        : widget.initialPreview;
    if (widget.external) {
      _previewReady = true;
      _resolvedPreview = null;
      _startEntrance();
      return;
    }
    if (_previewReady) {
      _startEntrance();
      return;
    }
    widget.repository.loadPreview(widget.item).then(
      (preview) {
        if (!mounted || generation != _previewGeneration) return;
        setState(() {
          _previewReady = true;
          _resolvedPreview = preview;
        });
        _startEntrance();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || generation != _previewGeneration) return;
        setState(() => _previewReady = true);
        _startEntrance();
      },
    );
  }

  void _startEntrance() {
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_previewReady) {
      return const SizedBox(
        height: 104,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _entrance,
        curve: Curves.easeOutCubic,
      )),
      child: FadeTransition(
        opacity: _entrance,
        child: _tile(_resolvedPreview),
      ),
    );
  }

  Widget _tile(String? preview) {
    final item = widget.item;
    final colors = context.shuyoColors;
    final metadata = [
      if (item.column.isNotEmpty) item.column,
      if (item.dateText.isNotEmpty) item.dateText,
    ].join(' · ');
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
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 16,
                      height: 1.26,
                      weight: FontWeight.w500,
                    ),
                  ),
                  if (preview != null && preview.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 14.5,
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
}

class _AnnouncementMetadata extends StatelessWidget {
  const _AnnouncementMetadata({required this.detail});

  final AnnouncementDetail detail;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (detail.dateText.isNotEmpty) detail.dateText,
      if (detail.department.isNotEmpty) detail.department,
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
