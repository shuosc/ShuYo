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

/// 一条课程检索结果：课程、所在教室与教师。
class ClassroomSearchHit {
  const ClassroomSearchHit({
    required this.building,
    required this.room,
    required this.course,
  });

  final ClassroomBuilding building;
  final ClassroomRoom room;
  final ClassroomCourse course;

  String get _haystack => [
        course.courseName,
        course.teacherName,
        room.name,
        room.fullName,
        building.name,
      ].join(' ').toLowerCase();

  bool matches(List<String> terms) =>
      terms.every((term) => _haystack.contains(term));
}

/// 独立搜索页：通过文本框与搜索按钮检索课程。
///
/// 日期与教室筛选都在本页 AppBar 上，主页只负责进入这里。
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
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  late DateTime _date;
  late Set<int> _selectedIds;
  final _hits = <ClassroomSearchHit>[];
  int _revision = 0;
  int _completed = 0;
  int _total = 0;
  bool _loading = true;
  Object? _error;
  List<String> _terms = const [];
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
    unawaited(_load());
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  static List<String> _splitTerms(String keyword) => keyword
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> _load({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async {
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
    final buildings = selectedBuildingsOf(_options, _selectedIds);
    final revision = ++_revision;
    if (buildings.isEmpty) {
      setState(() {
        _hits.clear();
        _loading = false;
        _error = null;
        _completed = 0;
        _total = 0;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _completed = 0;
      _total = buildings.length;
      _hits.clear();
    });
    try {
      await _withWebVpnRecovery(
        () => _repository.loadBuildingDays(
          buildings: buildings,
          date: _date,
          forceRefresh: forceRefresh,
          accessMode: mode,
          onProgress: (completed, total) {
            if (!mounted || revision != _revision) return;
            setState(() {
              _completed = completed;
              _total = total;
            });
          },
          onLoaded: (schedule) {
            if (!mounted || revision != _revision) return;
            setState(() {
              _hits
                ..removeWhere((hit) => hit.building.id == schedule.building.id)
                ..addAll([
                  for (final room in schedule.rooms)
                    for (final course in room.courses)
                      ClassroomSearchHit(
                        building: schedule.building,
                        room: room,
                        course: course,
                      ),
                ]);
            });
          },
          isCancelled: () => !mounted || revision != _revision,
        ),
        accessMode: mode,
      );
      if (!mounted || revision != _revision) return;
      setState(() => _loading = false);
    } on Object catch (error) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
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

  void _submitSearch([String? raw]) {
    _focusNode.unfocus();
    _applyKeyword(raw ?? _controller.text);
  }

  void _applyKeyword(String value) {
    setState(() {
      _keyword = value.trim();
      _terms = _splitTerms(_keyword);
    });
  }

  void _clearKeyword({bool clearField = true}) {
    if (clearField) {
      _controller.clear();
    }
    _applyKeyword('');
  }

  Future<void> _pickDate() async {
    final picked = await showClassroomDateMenu(context, selectedDate: _date);
    if (picked == null || !mounted) return;
    if (DateUtils.isSameDay(picked, _date)) return;
    setState(() => _date = DateUtils.dateOnly(picked));
    await _load();
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
    await _load();
  }

  /// 命中结果按「楼 → 节次」分组，交给两级吸顶渲染。
  List<ClassroomSearchHit> get _matches {
    if (_terms.isEmpty) return const [];
    return [
      for (final hit in _hits)
        if (hit.matches(_terms)) hit,
    ]..sort((a, b) {
        final building = compareClassroomBuildings(a.building, b.building);
        if (building != 0) return building;
        final section = a.course.startSection.compareTo(b.course.startSection);
        if (section != 0) return section;
        return a.room.name.compareTo(b.room.name);
      });
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
          onPressed: () => unawaited(_load(forceRefresh: true)),
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
            '正在加载课表 $_completed/$_total',
            style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
          ),
        );
      }
      return const EmptyState(
        icon: Icons.search_off,
        title: '没有找到课程',
        message: '试试课程名、教师名或教室号，也可以在右上角换一批教学楼。',
      );
    }
    return _results(matches);
  }

  Widget _results(List<ClassroomSearchHit> matches) {
    // 分组顺序跟随结果本身，因此始终与楼宇展示顺序一致。
    final buildings = <int, List<ClassroomSearchHit>>{};
    for (final hit in matches) {
      buildings.putIfAbsent(hit.building.id, () => []).add(hit);
    }
    final ranges = _ranges;
    return Scrollbar(
      child: CustomScrollView(
        key: const ValueKey('classroom-search-results'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          for (final entry in buildings.values)
            ClassroomGroupedSliver(
              key:
                  ValueKey('classroom-search-group-${entry.first.building.id}'),
              title: '${entry.first.building.campusName}校区 '
                  '${entry.first.building.name}',
              groups: _rangeGroups(entry, ranges),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
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
            hit.course.startSection,
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
          room: hit.room,
          startSection: hit.course.startSection,
          endSection: hit.course.endSection,
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
        'classroom-search-hit-${hit.building.id}-${hit.room.id}-'
        '${hit.course.courseName}-${hit.course.startSection}',
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: CourseColorLabel(
        code: hit.course.courseName,
        name: hit.course.courseName,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hit.course.courseName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.title(color: colors.textPrimary),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: hit.room.name,
                    // 教室名用主题色，但不加粗，与课程名拉开层次。
                    style: TextStyle(color: accent),
                  ),
                  if (hit.course.teacherName.isNotEmpty)
                    TextSpan(text: ' · ${hit.course.teacherName}'),
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
