import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/classroom_url_resolver.dart';
import '../../data/models/classroom.dart';
import '../../data/models/client_backend.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/classroom_api_client.dart';
import '../../data/services/unified_account_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/course_color_label.dart';
import '../../shared/widgets/empty_state.dart';
import 'classroom_filter_menu.dart';
import 'classroom_grouped_sliver.dart';
import 'classroom_presentation.dart';
import 'classroom_room_sheet.dart';

/// 一条课程检索结果：ES 课程命中与推断出的教学楼。
class ClassroomSearchHit {
  const ClassroomSearchHit({
    required this.building,
    required this.esHit,
    this.isKnownBuilding = true,
  });

  final ClassroomBuilding building;
  final ClassroomEsCourseHit esHit;
  final bool isKnownBuilding;
}

/// 独立搜索页：通过线上 ES 接口检索课程，并在本地按日期与教学楼二次过滤。
///
/// 保持原有筛选、两级吸顶分组与教室详情弹窗，并支持滚动到底部无缝加载下一页。
class ClassroomSearchPage extends StatefulWidget {
  const ClassroomSearchPage({
    super.key,
    required this.repository,
    required this.options,
    this.initialDate,
    this.initialCampus = ClassroomCampus.defaultName,
    this.onWebVpnRecoveryRequired,
    this.webVpnServiceStatus,
  });

  final ClassroomRepository repository;
  final ClassroomSearchOptions options;
  final DateTime? initialDate;
  final String initialCampus;
  final Future<WebVpnRecoveryOutcome> Function(bool interactive)?
      onWebVpnRecoveryRequired;
  final WebVpnServiceStatus Function()? webVpnServiceStatus;

  @override
  State<ClassroomSearchPage> createState() => _ClassroomSearchPageState();
}

class _ClassroomSearchPageState extends State<ClassroomSearchPage> {
  static const _pageSize = 50;
  static const _minVisibleMatches = 15;
  static const _maxBurstPages = 4;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  late DateTime _date;
  late Set<int> _selectedIds;
  final _rawHits = <ClassroomEsCourseHit>[];
  ClassroomSemesterInfo? _semesterInfo;
  int _revision = 0;
  int _nextStartPage = 0;
  int _totalHits = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  Object? _loadMoreError;
  String _keyword = '';

  ClassroomRepository get _repository => widget.repository;
  ClassroomSearchOptions get _options => widget.options;

  List<ClassroomSectionRange> get _ranges =>
      _repository.defaultRanges(_options.sections);

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate ?? _repository.defaultDateFor(_options);
    _selectedIds = defaultBuildingSelection(
      _options,
      preferredCampus: widget.initialCampus,
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submitSearch([String? raw]) async {
    _focusNode.unfocus();
    final keyword = (raw ?? _controller.text).trim();
    if (keyword.isEmpty) {
      _clearKeyword(clearField: false);
      return;
    }
    final revision = ++_revision;
    setState(() {
      _keyword = keyword;
      _rawHits.clear();
      _nextStartPage = 0;
      _totalHits = 0;
      _hasMore = false;
      _loading = true;
      _loadingMore = false;
      _error = null;
      _loadMoreError = null;
    });
    await _fetchPages(revision: revision, isInitial: true);
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _keyword.isEmpty) return;
    final revision = _revision;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    await _fetchPages(revision: revision, isInitial: false);
  }

  Future<void> _fetchPages({
    required int revision,
    required bool isInitial,
  }) async {
    final mode = ClassroomUrlResolver.accessMode;
    try {
      if (_semesterInfo == null) {
        try {
          final info = await _withWebVpnRecovery(
            () => _repository.loadCurrentSemester(accessMode: mode),
            accessMode: mode,
          );
          if (!mounted || revision != _revision) return;
          _semesterInfo = info;
        } on Object {
          // 学期接口失败时仍按周几过滤，不阻断搜索主流程。
        }
      }

      var fetchedPages = 0;
      while (fetchedPages < _maxBurstPages) {
        final result = await _withWebVpnRecovery(
          () => _repository.searchCourses(
            keyword: _keyword,
            startPage: _nextStartPage,
            pageSize: _pageSize,
            accessMode: mode,
          ),
          accessMode: mode,
        );
        if (!mounted || revision != _revision) return;
        fetchedPages++;
        _rawHits.addAll(result.hits);
        _totalHits = result.totalHits;
        _nextStartPage += result.hits.length;
        _hasMore = result.hits.isNotEmpty && _nextStartPage < _totalHits;

        if (!_hasMore || _matches.length >= _minVisibleMatches) {
          break;
        }
      }
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    } on Object catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        if (isInitial && _rawHits.isEmpty) {
          _error = error;
        } else {
          _loadMoreError = error;
        }
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _clearKeyword({bool clearField = true}) {
    _revision++;
    if (clearField) {
      _controller.clear();
    }
    setState(() {
      _keyword = '';
      _rawHits.clear();
      _nextStartPage = 0;
      _totalHits = 0;
      _hasMore = false;
      _loading = false;
      _loadingMore = false;
      _error = null;
      _loadMoreError = null;
    });
  }

  bool get _webVpnServiceUnavailable =>
      widget.webVpnServiceStatus?.call().effectiveStateAt(DateTime.now()) ==
      WebVpnServiceState.unavailable;

  Future<T> _withWebVpnRecovery<T>(
    Future<T> Function() operation, {
    required ClassroomAccessMode accessMode,
  }) async {
    final accessRevision = ClassroomUrlResolver.revision;
    bool canRecover() =>
        mounted &&
        accessMode == ClassroomAccessMode.webVpn &&
        ClassroomUrlResolver.usesWebVpn &&
        accessRevision == ClassroomUrlResolver.revision;
    try {
      try {
        return await operation();
      } on ClassroomWebVpnAuthException {
        if (!canRecover()) rethrow;
        if (_webVpnServiceUnavailable) {
          throw const ClassroomApiException(
            '暂时无法连接WebVPN，请稍后重试',
            accessMode: ClassroomAccessMode.webVpn,
          );
        }
        final recover = widget.onWebVpnRecoveryRequired;
        if (recover == null) rethrow;
        final interactive =
            mounted && ModalRoute.of(context)?.isCurrent != false;
        final outcome = await recover(interactive);
        if (!canRecover()) rethrow;
        switch (outcome) {
          case WebVpnRecoveryOutcome.alreadyValid:
          case WebVpnRecoveryOutcome.recovered:
            return await operation();
          case WebVpnRecoveryOutcome.needsAuthentication:
            rethrow;
          case WebVpnRecoveryOutcome.unavailable:
            throw const ClassroomApiException(
              '暂时无法连接WebVPN，请稍后重试',
              accessMode: ClassroomAccessMode.webVpn,
            );
          case WebVpnRecoveryOutcome.businessFailure:
            throw const ClassroomApiException(
              'WebVPN会话恢复失败，请稍后重试',
              accessMode: ClassroomAccessMode.webVpn,
            );
        }
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ClassroomApiException.forRequest(error, accessMode: accessMode),
        stackTrace,
      );
    }
  }

  Future<void> _pickDate() async {
    final picked = await showClassroomDateMenu(context, selectedDate: _date);
    if (picked == null || !mounted) return;
    if (DateUtils.isSameDay(picked, _date)) return;
    setState(() => _date = DateUtils.dateOnly(picked));
    _maybeLoadMoreAfterFilterChange();
  }

  Future<void> _pickBuildings() async {
    final picked = await showClassroomBuildingMenu(
      context,
      buildings: selectableBuildings(_options),
      selectedIds: _selectedIds,
      // 默认只展开已选楼宇所在的那个校区，其余两个收起。
      expandedCampus: selectableBuildings(_options)
              .where((building) => _selectedIds.contains(building.id))
              .firstOrNull
              ?.campusName ??
          widget.initialCampus,
    );
    if (picked == null || !mounted) return;
    final unchanged = picked.length == _selectedIds.length &&
        picked.containsAll(_selectedIds);
    if (unchanged) return;
    setState(() => _selectedIds = picked);
    _maybeLoadMoreAfterFilterChange();
  }

  void _maybeLoadMoreAfterFilterChange() {
    if (_keyword.isEmpty ||
        _selectedIds.isEmpty ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    if (_matches.length < _minVisibleMatches) {
      unawaited(_loadMore());
    }
  }

  /// 二次过滤：按选定日期（周几 + 教学周）与已选教学楼筛选，并按「楼 → 节次」排序。
  List<ClassroomSearchHit> get _matches {
    if (_keyword.isEmpty || _selectedIds.isEmpty) return const [];
    final allSelectable = selectableBuildings(_options);
    final allSelected = _selectedIds.length == allSelectable.length;
    final targetWeek = _semesterInfo?.weekForDate(_date);
    final hits = <ClassroomSearchHit>[];

    for (final raw in _rawHits) {
      if (!raw.matchesDate(_date, targetWeek: targetWeek)) continue;
      final matched = raw.matchBuilding(allSelectable);
      if (matched != null) {
        if (!_selectedIds.contains(matched.id)) continue;
        hits.add(ClassroomSearchHit(building: matched, esHit: raw));
      } else if (allSelected) {
        final fallbackName = raw.roomName.contains('/')
            ? raw.roomName.split('/').first.trim()
            : '其他教室';
        hits.add(
          ClassroomSearchHit(
            building: ClassroomBuilding(
              id: 0,
              name: fallbackName.isEmpty ? '其他教室' : fallbackName,
              campusId: 0,
              campusName: '',
            ),
            esHit: raw,
            isKnownBuilding: false,
          ),
        );
      }
    }

    hits.sort((a, b) {
      if (a.isKnownBuilding != b.isKnownBuilding) {
        return a.isKnownBuilding ? -1 : 1;
      }
      final building = compareClassroomBuildings(a.building, b.building);
      if (building != 0) return building;
      final section = a.esHit.startSection.compareTo(b.esHit.startSection);
      if (section != 0) return section;
      return a.esHit.roomName.compareTo(b.esHit.roomName);
    });
    return hits;
  }

  String _dateActionLabel() {
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(_date);
    if (day == today) return '今天';
    if (day == today.add(const Duration(days: 1))) return '明天';
    return '${_date.month}/${_date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = selectableBuildings(_options).length;
    final selectedCount = _selectedIds.length;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索课程'),
        actions: [
          IconButton(
            key: const ValueKey('classroom-search-date'),
            tooltip: '选择日期（${_dateActionLabel()}）',
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          IconButton(
            key: const ValueKey('classroom-search-filter'),
            tooltip: '筛选教室（已选 $selectedCount 栋）',
            onPressed: _pickBuildings,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.filter_list),
                Positioned(
                  right: -6,
                  bottom: -4,
                  child: Text(
                    selectedCount == totalCount ? 'ALL' : '$selectedCount',
                    style: TextStyle(
                      color: primary,
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
          const SizedBox(width: 2),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _loading
              ? const LinearProgressIndicator(
                  key: ValueKey('classroom-search-progress'),
                  minHeight: 3,
                )
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                final hasText = value.text.isNotEmpty;
                final hasKeyword = value.text.trim().isNotEmpty;
                return Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('classroom-search-query'),
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        onTapOutside: (_) => _focusNode.unfocus(),
                        textInputAction: TextInputAction.search,
                        onSubmitted: _submitSearch,
                        onChanged: (text) {
                          if (text.trim().isEmpty && _keyword.isNotEmpty) {
                            _clearKeyword(clearField: false);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: '搜索课程、教师或教室',
                          suffixIcon: !hasText
                              ? null
                              : IconButton(
                                  key: const ValueKey('classroom-search-clear'),
                                  tooltip: '清空关键词',
                                  onPressed: _clearKeyword,
                                  icon: const Icon(Icons.clear),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      key: const ValueKey('classroom-search-submit'),
                      tooltip: '开始搜索',
                      onPressed: !hasKeyword ? null : () => _submitSearch(),
                      icon: Icon(
                        Icons.search,
                        color: hasKeyword
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    final colors = context.shuyoColors;
    if (_error != null) {
      final webVpn = _error is ClassroomWebVpnAuthException;
      return EmptyState(
        icon: webVpn ? Icons.vpn_key_outlined : Icons.cloud_off_outlined,
        title: '课程搜索失败',
        message: _errorMessage(_error!),
        action: TextButton.icon(
          onPressed: () => unawaited(_submitSearch(_keyword)),
          icon: Icon(webVpn ? Icons.vpn_key_outlined : Icons.refresh),
          label: Text(webVpn ? '重试连接' : '重试'),
        ),
      );
    }
    if (_selectedIds.isEmpty) {
      return const EmptyState(
        icon: Icons.filter_list_off,
        title: '没有选择教学楼',
        message: '在右上角的筛选里至少勾选一栋教学楼。',
      );
    }
    if (_keyword.isEmpty) return const SizedBox.shrink();
    final matches = _matches;
    if (matches.isEmpty) {
      if (_loading) {
        return Center(
          child: Text(
            '正在搜索课程…',
            style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
          ),
        );
      }
      if (_hasMore) {
        return Center(
          child: TextButton.icon(
            onPressed: _loadingMore ? null : _loadMore,
            icon: const Icon(Icons.expand_more),
            label: Text(_loadingMore ? '正在加载更多…' : '当前页无匹配，继续加载更多'),
          ),
        );
      }
      return const EmptyState(
        icon: Icons.search_off,
        title: '没有找到课程',
        message: '试试课程名、教师名或教室号，也可以在右上角换一批教学楼或日期。',
      );
    }
    return _results(matches);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 280 &&
        _hasMore &&
        !_loading &&
        !_loadingMore &&
        _loadMoreError == null) {
      unawaited(_loadMore());
    }
    return false;
  }

  Widget _results(List<ClassroomSearchHit> matches) {
    // 分组顺序跟随结果本身，因此始终与楼宇展示顺序一致。
    final buildings = <String, List<ClassroomSearchHit>>{};
    for (final hit in matches) {
      final groupKey = hit.isKnownBuilding
          ? 'id:${hit.building.id}'
          : 'name:${hit.building.name}';
      buildings.putIfAbsent(groupKey, () => []).add(hit);
    }
    final ranges = _ranges;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Scrollbar(
        child: CustomScrollView(
          key: const ValueKey('classroom-search-results'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            for (final entry in buildings.entries)
              ClassroomGroupedSliver(
                key: ValueKey('classroom-search-group-${entry.key}'),
                title: entry.value.first.building.campusName.isNotEmpty
                    ? '${entry.value.first.building.campusName}校区 '
                        '${entry.value.first.building.name}'
                    : entry.value.first.building.name,
                groups: _rangeGroups(entry.value, ranges),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        key: ValueKey('classroom-search-load-more'),
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
              )
            else if (_loadMoreError != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: TextButton(
                      onPressed: _loadMore,
                      child: const Text('加载更多失败，点击重试'),
                    ),
                  ),
                ),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  List<ClassroomRangeGroup> _rangeGroups(
    List<ClassroomSearchHit> hits,
    List<ClassroomSectionRange> ranges,
  ) {
    final byRange = <ClassroomSectionRange, List<ClassroomSearchHit>>{};
    for (final hit in hits) {
      final range = _repository.rangeForSection(
            hit.esHit.startSection,
            ranges,
          ) ??
          ranges.first;
      byRange.putIfAbsent(range, () => []).add(hit);
    }
    final ordered = byRange.keys.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return [
      for (final range in ordered)
        ClassroomRangeGroup(
          label: range.label,
          children: _groupChildren(byRange[range]!),
        ),
    ];
  }

  /// 课程行之间夹一条与录播列表同款的分割线。
  List<Widget> _groupChildren(List<ClassroomSearchHit> hits) {
    final children = <Widget>[];
    for (var index = 0; index < hits.length; index++) {
      if (index > 0) {
        children.add(const Divider(indent: 16, endIndent: 16));
      }
      final hit = hits[index];
      children.add(_CourseHitTile(
        hit: hit,
        onTap: () => showClassroomRoomSheet(
          context,
          room: ClassroomRoom(
            id: 0,
            name: hit.esHit.roomName,
            floorName: '',
            fullName: hit.building.fullName.isNotEmpty
                ? '${hit.building.fullName}/${hit.esHit.roomName}'
                : hit.esHit.roomName,
            courses: [
              ClassroomCourse(
                courseName: hit.esHit.courseName,
                teacherName: hit.esHit.teacherName,
                startSection: hit.esHit.startSection,
                endSection: hit.esHit.endSection,
              ),
            ],
          ),
          startSection: hit.esHit.startSection,
          endSection: hit.esHit.endSection,
        ),
      ));
    }
    return children;
  }

  String _errorMessage(Object error) {
    final failure = error is ClassroomApiException ? error : null;
    final mode = failure?.accessMode ?? ClassroomUrlResolver.accessMode;
    if (mode == ClassroomAccessMode.webVpn) {
      if (error is ClassroomWebVpnAuthException && !_webVpnServiceUnavailable) {
        return error.message;
      }
      return ClassroomAccessWindow.webVpnFailureMessage(
        detail: failure?.message,
        serviceUnavailable: _webVpnServiceUnavailable,
      );
    }
    return ClassroomAccessWindow.directFailureMessage(
      detail: failure?.message,
      webVpnEnabled: ClassroomUrlResolver.usesWebVpn,
    );
  }
}

/// 录播平台课程列表的形态：左侧竖条取课程配色，右侧课程名 / 教室 / 教师。
class _CourseHitTile extends StatelessWidget {
  const _CourseHitTile({
    required this.hit,
    required this.onTap,
  });

  final ClassroomSearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final accent = Theme.of(context).colorScheme.primary;
    // 与录播平台首页/搜索的课程行完全一致：同款 ListTile 内边距与行高。
    return ListTile(
      key: ValueKey(
        'classroom-search-hit-${hit.building.id}-${hit.esHit.roomName}-'
        '${hit.esHit.courseName}-${hit.esHit.startSection}',
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: CourseColorLabel(
        code: hit.esHit.courseName,
        name: hit.esHit.courseName,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hit.esHit.courseName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.title(color: colors.textPrimary),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: hit.esHit.roomName,
                    // 教室名用主题色，但不加粗，与课程名拉开层次。
                    style: TextStyle(color: accent),
                  ),
                  if (hit.esHit.teacherName.isNotEmpty)
                    TextSpan(text: ' · ${hit.esHit.teacherName}'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.meta(color: colors.textSecondary),
            ),
          ],
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: colors.textMuted),
      onTap: onTap,
    );
  }
}
