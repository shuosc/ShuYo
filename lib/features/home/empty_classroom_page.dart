import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/classroom_url_resolver.dart';
import '../../data/models/classroom.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/classroom_api_client.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

class EmptyClassroomPage extends StatefulWidget {
  const EmptyClassroomPage({
    super.key,
    required this.repository,
    this.initialDate,
    this.initialCampus = ClassroomCampus.defaultName,
    this.onWebVpnExpired,
  });

  final ClassroomRepository repository;
  final DateTime? initialDate;
  final String initialCampus;
  final Future<void> Function()? onWebVpnExpired;

  @override
  State<EmptyClassroomPage> createState() => _EmptyClassroomPageState();
}

class _EmptyClassroomPageState extends State<EmptyClassroomPage> {
  late Future<void> _loadFuture;
  Future<_ClassroomQueryResult>? _resultFuture;
  ClassroomSearchOptions? _options;
  ClassroomBuilding? _selectedBuilding;
  ClassroomSectionRange? _selectedRange;
  String? _selectedCampus;
  late DateTime _selectedDate = widget.initialDate ?? DateTime.now();
  bool _loadingOptions = false;
  bool _refreshingOptions = false;
  String _keyword = '';
  bool _initialSelectionApplied = false;
  bool _showSearch = false;
  bool _highlightAvailable = false;

  @override
  void initState() {
    super.initState();
    final snapshot = widget.repository.optionsSnapshot;
    if (snapshot == null || snapshot.buildings.isEmpty) {
      _loadFuture = _loadOptions();
      return;
    }
    // Reopening the page can show the options kept in memory on the first
    // frame instead of the loading state; loading them again would only
    // return that same instance.
    _applyOptionsSnapshot(snapshot);
    _loadFuture = Future<void>.value();
  }

  /// Restores the options and their matching selections and starts the query
  /// they describe right away.
  void _applyOptionsSnapshot(ClassroomSearchOptions options) {
    final now = DateTime.now();
    _options = options;
    _selectedCampus = _validCampus(options);
    _selectedBuilding = _validBuilding(options, campus: _selectedCampus);
    _selectedDate = widget.initialDate ??
        widget.repository.defaultDateFor(options, now: now);
    _selectedRange = widget.repository.defaultRangeFor(options, now: now);
    _initialSelectionApplied = true;
    _search();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('空教室'),
        actions: [
          IconButton(
            tooltip: _showSearch ? '关闭搜索' : '搜索课程、教师或教室',
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _keyword = '';
              }
            }),
            icon: Icon(_showSearch ? Icons.search_off : Icons.search),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshingOptions ? null : _refresh,
            icon: _refreshingOptions
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: _loadedBody(),
    );
  }

  /// Renders the query controls as soon as options exist, and waits on
  /// [_loadFuture] only when none were remembered.
  Widget _loadedBody() {
    final options = _options;
    if (options == null) {
      return FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 3),
            );
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.meeting_room_outlined,
              title: '空教室加载失败',
              message: _friendlyError(snapshot.error!),
              action: TextButton.icon(
                onPressed: () {
                  setState(() => _loadFuture = _loadOptions(force: true));
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }
          // Options arrive through setState; a finished load without them
          // cannot render the controls.
          return const SizedBox.shrink();
        },
      );
    }
    if (options.buildings.isEmpty) {
      return const EmptyState(
        icon: Icons.meeting_room_outlined,
        title: '暂无教学楼',
        message: '空教室系统没有返回可查询的教学楼。',
      );
    }
    return Column(
      children: [
        _SearchControls(
          options: options,
          selectedCampus: _selectedCampus,
          selectedBuilding: _selectedBuilding,
          selectedRange: _selectedRange,
          selectedDate: _selectedDate,
          showSearch: _showSearch,
          ranges: widget.repository.defaultRanges(options.sections),
          onCampusChanged: _setCampus,
          onBuildingChanged: _setBuilding,
          onRangeChanged: _setRange,
          onPreviousRange: () => _stepRange(-1),
          onNextRange: () => _stepRange(1),
          onDateChanged: _setDate,
          onKeywordChanged: (value) => setState(() => _keyword = value),
        ),
        Expanded(child: _resultBody()),
      ],
    );
  }

  Widget _resultBody() {
    final future = _resultFuture;
    if (future == null) {
      return const EmptyState(
        icon: Icons.search,
        title: '选择条件后查询',
        message: '请选择日期、教学楼和节次。',
      );
    }
    return FutureBuilder<_ClassroomQueryResult>(
      future: future,
      builder: (context, snapshot) {
        // FutureBuilder retains the previous result while a new query runs.
        // Keep it visible until the replacement is ready to avoid a flash.
        if (snapshot.hasData) {
          return RefreshIndicator(
            onRefresh: _search,
            child: _ClassroomResultList(
              result: snapshot.data!,
              keyword: _keyword,
              highlightAvailable: _highlightAvailable,
              onHighlightChanged: (value) =>
                  setState(() => _highlightAvailable = value),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 3));
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline,
            title: '查询失败',
            message: _friendlyError(snapshot.error!),
            action: TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _loadOptions({bool force = false}) async {
    if (_loadingOptions) {
      return;
    }
    _loadingOptions = true;
    // Only an explicit refresh needs the toolbar spinner: a first load is
    // covered by the body indicator, and a cached snapshot paints instantly.
    final showRefreshSpinner = force && _options != null;
    if (showRefreshSpinner) {
      setState(() => _refreshingOptions = true);
    }
    try {
      final options = await widget.repository.loadOptions(forceRefresh: force);
      if (!mounted) {
        return;
      }
      final campus = _validCampus(options);
      final ranges = widget.repository.defaultRanges(options.sections);
      setState(() {
        _options = options;
        _selectedCampus = campus;
        _selectedBuilding = _validBuilding(options, campus: campus);
        if (!_initialSelectionApplied) {
          final now = DateTime.now();
          if (widget.initialDate == null) {
            _selectedDate = widget.repository.defaultDateFor(options, now: now);
          }
          _selectedRange = widget.repository.defaultRangeFor(options, now: now);
          _initialSelectionApplied = true;
        } else if (_selectedRange == null ||
            !ranges.any(
              (range) =>
                  range.start == _selectedRange!.start &&
                  range.end == _selectedRange!.end,
            )) {
          _selectedRange = widget.repository.defaultRangeFor(options);
        }
      });
      _search(forceRefresh: force);
    } on ClassroomWebVpnAuthException {
      await widget.onWebVpnExpired?.call();
      rethrow;
    } finally {
      _loadingOptions = false;
      if (showRefreshSpinner && mounted) {
        setState(() => _refreshingOptions = false);
      }
    }
  }

  Future<void> _refresh() async {
    await _loadOptions(force: true);
  }

  String? _validCampus(ClassroomSearchOptions options) {
    final names = options.campusNames;
    if (names.contains(_selectedCampus)) {
      return _selectedCampus;
    }
    if (names.contains(widget.initialCampus)) {
      return widget.initialCampus;
    }
    if (names.contains(ClassroomCampus.defaultName)) {
      return ClassroomCampus.defaultName;
    }
    return names.isEmpty ? null : names.first;
  }

  ClassroomBuilding? _validBuilding(
    ClassroomSearchOptions options, {
    required String? campus,
  }) {
    final current = _selectedBuilding;
    if (current == null && _resultFuture != null) {
      return null;
    }
    final buildings = options.buildings
        .where((building) => campus == null || building.campusName == campus)
        .toList(growable: false);
    if (current != null &&
        buildings.any((building) => building.id == current.id)) {
      return current;
    }
    return buildings.isEmpty ? null : buildings.first;
  }

  void _setCampus(String? value) {
    final options = _options;
    if (options == null || value == null) {
      return;
    }
    final buildings = options.buildings
        .where((building) => building.campusName == value)
        .toList(growable: false);
    final keepAllBuildings = _selectedBuilding == null;
    setState(() {
      _selectedCampus = value;
      _selectedBuilding =
          keepAllBuildings || buildings.isEmpty ? null : buildings.first;
    });
    _search();
  }

  void _setBuilding(ClassroomBuilding? value) {
    setState(() => _selectedBuilding = value);
    _search();
  }

  void _setRange(ClassroomSectionRange range) {
    setState(() => _selectedRange = range);
    _search();
  }

  void _stepRange(int delta) {
    final options = _options;
    if (options == null) {
      return;
    }
    final ranges = widget.repository.defaultRanges(options.sections);
    final currentIndex = ranges.indexWhere(
      (range) =>
          range.start == _selectedRange?.start &&
          range.end == _selectedRange?.end,
    );
    if (currentIndex < 0) {
      return;
    }
    final nextIndex = currentIndex + delta;
    if (nextIndex < 0 || nextIndex >= ranges.length) {
      return;
    }
    _setRange(ranges[nextIndex]);
  }

  void _setDate(DateTime date) {
    setState(() => _selectedDate = date);
    _search();
  }

  Future<void> _search({bool forceRefresh = false}) async {
    final range = _selectedRange;
    if (range == null) {
      return;
    }
    final buildings = _selectedBuilding == null
        ? _campusBuildings()
        : <ClassroomBuilding>[_selectedBuilding!];
    if (buildings.isEmpty) {
      return;
    }
    final future = _searchBuildings(
      buildings: buildings,
      date: _selectedDate,
      range: range,
      forceRefresh: forceRefresh,
    );
    setState(() {
      _resultFuture = future;
    });
    await future.then<void>((_) {}, onError: (_) {});
  }

  List<ClassroomBuilding> _campusBuildings() {
    final options = _options;
    final campus = _selectedCampus;
    if (options == null) {
      return const <ClassroomBuilding>[];
    }
    return options.buildings
        .where((building) => campus == null || building.campusName == campus)
        .toList(growable: false);
  }

  Future<_ClassroomQueryResult> _searchBuildings({
    required List<ClassroomBuilding> buildings,
    required DateTime date,
    required ClassroomSectionRange range,
    required bool forceRefresh,
  }) async {
    final results = <ClassroomAvailabilityResult>[];
    try {
      for (final building in buildings) {
        final result = await widget.repository.search(
          ClassroomAvailabilityQuery(
            building: building,
            date: date,
            startSection: range.start,
            endSection: range.end,
          ),
          forceRefresh: forceRefresh,
        );
        results.add(result);
      }
    } on ClassroomWebVpnAuthException {
      await widget.onWebVpnExpired?.call();
      rethrow;
    }
    return _ClassroomQueryResult(
      date: date,
      startSection: range.start,
      endSection: range.end,
      results: results,
    );
  }

  String _friendlyError(Object error) {
    if (error is ClassroomWebVpnAuthException) {
      return error.message;
    }
    if (error is ClassroomApiException && ClassroomUrlResolver.usesWebVpn) {
      return error.message;
    }
    return ClassroomAccessWindow.directFailureMessage(
      detail: error is ClassroomApiException ? error.message : null,
    );
  }
}

class _ClassroomQueryResult {
  const _ClassroomQueryResult({
    required this.date,
    required this.startSection,
    required this.endSection,
    required this.results,
  });

  final DateTime date;
  final int startSection;
  final int endSection;
  final List<ClassroomAvailabilityResult> results;

  int get totalRooms =>
      results.fold(0, (sum, result) => sum + result.totalRooms);

  int get availableCount =>
      results.fold(0, (sum, result) => sum + result.availableCount);

  String get scopeLabel {
    if (results.length == 1) {
      return results.single.building.name;
    }
    return '全部教学楼';
  }

  List<_CourseLocationMatch> courseMatches(String keyword) {
    final normalized = keyword.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <_CourseLocationMatch>[];
    }
    final matches = <_CourseLocationMatch>[];
    for (final result in results) {
      for (final floor in result.floors) {
        for (final room in floor.rooms) {
          for (final course in room.courses) {
            final haystack =
                '${result.building.name} ${room.name} ${course.courseName} ${course.teacherName}'
                    .toLowerCase();
            if (haystack.contains(normalized)) {
              matches.add(
                _CourseLocationMatch(
                  building: result.building,
                  room: room,
                  course: course,
                ),
              );
            }
          }
        }
      }
    }
    matches.sort((a, b) {
      final section = a.course.startSection.compareTo(b.course.startSection);
      if (section != 0) {
        return section;
      }
      final building = a.building.name.compareTo(b.building.name);
      if (building != 0) {
        return building;
      }
      return a.room.name.compareTo(b.room.name);
    });
    return matches;
  }
}

class _CourseLocationMatch {
  const _CourseLocationMatch({
    required this.building,
    required this.room,
    required this.course,
  });

  final ClassroomBuilding building;
  final ClassroomRoom room;
  final ClassroomCourse course;
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.options,
    required this.selectedCampus,
    required this.selectedBuilding,
    required this.selectedRange,
    required this.selectedDate,
    required this.showSearch,
    required this.ranges,
    required this.onCampusChanged,
    required this.onBuildingChanged,
    required this.onRangeChanged,
    required this.onPreviousRange,
    required this.onNextRange,
    required this.onDateChanged,
    required this.onKeywordChanged,
  });

  final ClassroomSearchOptions options;
  final String? selectedCampus;
  final ClassroomBuilding? selectedBuilding;
  final ClassroomSectionRange? selectedRange;
  final DateTime selectedDate;
  final bool showSearch;
  final List<ClassroomSectionRange> ranges;
  final ValueChanged<String?> onCampusChanged;
  final ValueChanged<ClassroomBuilding?> onBuildingChanged;
  final ValueChanged<ClassroomSectionRange> onRangeChanged;
  final VoidCallback onPreviousRange;
  final VoidCallback onNextRange;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<String> onKeywordChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final campusBuildings = options.buildings
        .where(
          (building) =>
              selectedCampus == null || building.campusName == selectedCampus,
        )
        .toList(growable: false);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('campus-$selectedCampus'),
                      initialValue: selectedCampus,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '校区',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final campus in options.campusNames)
                          DropdownMenuItem(
                            value: campus,
                            child: Text(
                              campus,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: onCampusChanged,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: ValueKey(
                        'building-$selectedCampus-${selectedBuilding?.id ?? 0}',
                      ),
                      initialValue: selectedBuilding?.id ?? 0,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '教学楼',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 0,
                          child: Text('全部教学楼'),
                        ),
                        for (final building in campusBuildings)
                          DropdownMenuItem(
                            value: building.id,
                            child: Text(
                              building.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (id) => onBuildingChanged(
                        id == 0 ? null : _buildingById(campusBuildings, id),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _DateButton(
                    label: '今天',
                    selected: _isSameDay(selectedDate, DateTime.now()),
                    onTap: () => onDateChanged(DateTime.now()),
                  ),
                  const SizedBox(width: 8),
                  _DateButton(
                    label: '明天',
                    selected: _isSameDay(
                      selectedDate,
                      DateTime.now().add(const Duration(days: 1)),
                    ),
                    onTap: () => onDateChanged(
                      DateTime.now().add(const Duration(days: 1)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: selectedDate,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 30),
                          ),
                          lastDate: DateTime.now().add(
                            const Duration(days: 180),
                          ),
                        );
                        if (picked != null) {
                          onDateChanged(picked);
                        }
                      },
                      icon: const Icon(Icons.calendar_month_outlined, size: 18),
                      label: Text(_dateLabel(selectedDate)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _SectionRangeSelector(
              ranges: ranges,
              selectedRange: selectedRange,
              onChanged: onRangeChanged,
              onPrevious: onPreviousRange,
              onNext: onNextRange,
            ),
            if (showSearch) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ClassroomSearchField(
                  autofocus: true,
                  onChanged: onKeywordChanged,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ClassroomSearchField extends StatefulWidget {
  const _ClassroomSearchField({
    required this.onChanged,
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  State<_ClassroomSearchField> createState() => _ClassroomSearchFieldState();
}

class _ClassroomSearchFieldState extends State<_ClassroomSearchField> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: _focusNode.hasFocus ? colors.accent : colors.borderStrong,
            width: _focusNode.hasFocus ? 1.5 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _focusNode.requestFocus,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 12),
              child: Icon(Icons.search, size: 20, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              onTapOutside: (_) => _focusNode.unfocus(),
              decoration: const InputDecoration(
                hintText: '搜索课程、教师或教室',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
              ),
              textInputAction: TextInputAction.search,
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionRangeSelector extends StatelessWidget {
  const _SectionRangeSelector({
    required this.ranges,
    required this.selectedRange,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
  });

  final List<ClassroomSectionRange> ranges;
  final ClassroomSectionRange? selectedRange;
  final ValueChanged<ClassroomSectionRange> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = ranges.indexWhere(
      (range) =>
          range.start == selectedRange?.start &&
          range.end == selectedRange?.end,
    );
    final canGoPrevious = selectedIndex > 0;
    final canGoNext = selectedIndex >= 0 && selectedIndex < ranges.length - 1;
    final selector = Row(
      children: [
        IconButton(
          tooltip: '上一节',
          onPressed: canGoPrevious ? onPrevious : null,
          icon: const Icon(Icons.chevron_left),
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const compactWidth = 18.0;
              const gap = 6.0;
              final compactTotal = (ranges.length - 1) * (compactWidth + gap);
              final selectedWidth = (constraints.maxWidth - compactTotal)
                  .clamp(72.0, 104.0)
                  .toDouble();
              final sideWidth =
                  ((constraints.maxWidth - selectedWidth - compactTotal) / 2)
                      .clamp(0.0, double.infinity);
              return Stack(
                children: [
                  // Fill only the blank space beside the range buttons.
                  Positioned.fill(
                    child: Row(
                      children: [
                        SizedBox(
                          width: sideWidth,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTap: canGoPrevious ? onPrevious : null,
                          ),
                        ),
                        const Spacer(),
                        SizedBox(
                          width: sideWidth,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTap: canGoNext ? onNext : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var index = 0; index < ranges.length; index++) ...[
                        if (index > 0) const SizedBox(width: gap),
                        _AnimatedRangeButton(
                          range: ranges[index],
                          selected: index == selectedIndex,
                          selectedWidth: selectedWidth,
                          onTap: () => onChanged(ranges[index]),
                        ),
                      ],
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        IconButton(
          tooltip: '下一节',
          onPressed: canGoNext ? onNext : null,
          icon: const Icon(Icons.chevron_right),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
    return Stack(
      children: [
        Positioned.fill(
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: canGoPrevious ? onPrevious : null,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 16,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: canGoNext ? onNext : null,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: selector,
        ),
      ],
    );
  }
}

class _AnimatedRangeButton extends StatefulWidget {
  const _AnimatedRangeButton({
    required this.range,
    required this.selected,
    required this.selectedWidth,
    required this.onTap,
  });

  final ClassroomSectionRange range;
  final bool selected;
  final double selectedWidth;
  final VoidCallback onTap;

  @override
  State<_AnimatedRangeButton> createState() => _AnimatedRangeButtonState();
}

class _AnimatedRangeButtonState extends State<_AnimatedRangeButton> {
  static const _widthDuration = Duration(milliseconds: 500);
  static const _labelDelay = Duration(milliseconds: 50);
  Timer? _labelTimer;
  late bool _showLabel;

  @override
  void initState() {
    super.initState();
    _showLabel = widget.selected;
  }

  @override
  void didUpdateWidget(covariant _AnimatedRangeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) {
      return;
    }
    _labelTimer?.cancel();
    if (widget.selected) {
      setState(() => _showLabel = false);
      _labelTimer = Timer(_labelDelay, () {
        if (mounted && widget.selected) {
          setState(() => _showLabel = true);
        }
      });
    } else {
      setState(() => _showLabel = false);
    }
  }

  @override
  void dispose() {
    _labelTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return MergeSemantics(
      child: Semantics(
        label: widget.range.label,
        selected: widget.selected,
        inMutuallyExclusiveGroup: true,
        child: AnimatedContainer(
          duration: _widthDuration,
          curve: Curves.easeOutCubic,
          width: widget.selected ? widget.selectedWidth : 18,
          height: 44,
          decoration: BoxDecoration(
            color: widget.selected ? colors.accentSoft : colors.surfaceMuted,
            border: Border.all(
              color: widget.selected ? colors.accent : colors.borderStrong,
              width: widget.selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(10),
              child: Center(
                child: AnimatedOpacity(
                  opacity: _showLabel ? 1 : 0,
                  duration: _showLabel
                      ? const Duration(milliseconds: 300)
                      : Duration.zero,
                  child: Text(
                    widget.range.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.onAccentSoft,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return selected
        ? FilledButton(onPressed: onTap, child: Text(label))
        : OutlinedButton(onPressed: onTap, child: Text(label));
  }
}

class _ClassroomResultList extends StatelessWidget {
  const _ClassroomResultList({
    required this.result,
    required this.keyword,
    required this.highlightAvailable,
    required this.onHighlightChanged,
  });

  final _ClassroomQueryResult result;
  final String keyword;
  final bool highlightAvailable;
  final ValueChanged<bool> onHighlightChanged;

  @override
  Widget build(BuildContext context) {
    final normalizedKeyword = keyword.trim();
    final matches = result.courseMatches(normalizedKeyword);
    final colors = context.shuyoColors;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
      children: [
        Text(
          '${result.scopeLabel} · ${_dateLabel(result.date)} · '
          '${result.startSection}-${result.endSection}节',
          style: ShuYoTextStyles.title(
            color: colors.textPrimary,
            size: 16.5,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        if (normalizedKeyword.isNotEmpty) ...[
          Text('已按全天课程搜索，忽略当前节次', style: TextStyle(color: colors.textTertiary)),
          const SizedBox(height: 18),
          _CourseMatches(matches: matches),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '${result.availableCount} 间教室空闲 · 共 ${result.totalRooms} 间',
                  style: TextStyle(color: colors.textTertiary),
                ),
              ),
              const SizedBox(width: 16),
              FilterChip(
                label: const Text('高亮空闲'),
                selected: highlightAvailable,
                onSelected: onHighlightChanged,
                selectedColor: colors.accentSoft,
                checkmarkColor: colors.onAccentSoft,
                labelStyle: TextStyle(
                  color: highlightAvailable
                      ? colors.onAccentSoft
                      : colors.textSecondary,
                ),
                side: BorderSide(
                  color: highlightAvailable ? colors.accent : colors.border,
                ),
              ),
            ],
          ),
          if (highlightAvailable)
            Text(
              '主题色为空闲 · 灰色为已占用',
              style: TextStyle(color: colors.textTertiary, fontSize: 12),
            ),
          const SizedBox(height: 12),
          if (result.totalRooms == 0 ||
              (result.availableCount == 0 && !highlightAvailable))
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: EmptyState(
                icon: Icons.event_busy_outlined,
                title: result.totalRooms == 0 ? '暂无教室数据' : '没有空教室',
                message:
                    result.totalRooms == 0 ? '当前范围没有返回教室。' : '当前范围在所选节次没有可用教室。',
              ),
            )
          else
            for (final item in result.results)
              _BuildingAvailableRooms(
                result: item,
                showBuildingName: result.results.length > 1,
                highlightAvailable: highlightAvailable,
              ),
        ],
      ],
    );
  }
}

class _BuildingAvailableRooms extends StatelessWidget {
  const _BuildingAvailableRooms({
    required this.result,
    required this.showBuildingName,
    required this.highlightAvailable,
  });

  final ClassroomAvailabilityResult result;
  final bool showBuildingName;
  final bool highlightAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final visibleFloors = result.floors
        .where(
          (floor) => highlightAvailable
              ? floor.rooms.isNotEmpty
              : floor.availableRooms.isNotEmpty,
        )
        .toList(growable: false);
    if (visibleFloors.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBuildingName) ...[
            Text(
              '${result.building.name} · 空闲 ${result.availableCount}'
              '${highlightAvailable ? '/${result.totalRooms}' : ''} 间',
              style: ShuYoTextStyles.title(
                color: colors.textPrimary,
                size: 15.5,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final floor in visibleFloors)
            _FloorAvailableRooms(
              floor: floor,
              startSection: result.startSection,
              endSection: result.endSection,
              highlightAvailable: highlightAvailable,
            ),
        ],
      ),
    );
  }
}

class _CourseMatches extends StatelessWidget {
  const _CourseMatches({required this.matches});

  final List<_CourseLocationMatch> matches;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) {
      return Text(
        '未找到课程位置',
        style: TextStyle(color: context.shuyoColors.textTertiary),
      );
    }
    final colors = context.shuyoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '课程位置',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        for (final match in matches)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.location_on_outlined,
                  size: 18,
                  color: colors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${match.course.sectionText} · '
                    '${match.building.name} ${match.room.name} · '
                    '${match.course.courseName}'
                    '${match.course.teacherName.isEmpty ? '' : ' · ${match.course.teacherName}'}',
                    style: TextStyle(color: colors.textPrimary, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FloorAvailableRooms extends StatelessWidget {
  const _FloorAvailableRooms({
    required this.floor,
    required this.startSection,
    required this.endSection,
    required this.highlightAvailable,
  });

  final ClassroomFloorAvailability floor;
  final int startSection;
  final int endSection;
  final bool highlightAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${floor.floor.name} · 空闲 ${floor.availableRooms.length}'
            '${highlightAvailable ? '/${floor.totalRooms}' : ''} 间',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final room
                  in highlightAvailable ? floor.rooms : floor.availableRooms)
                _RoomChip(
                  room: room,
                  startSection: startSection,
                  endSection: endSection,
                  highlightAvailable: highlightAvailable,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({
    required this.room,
    required this.startSection,
    required this.endSection,
    required this.highlightAvailable,
  });

  final ClassroomRoom room;
  final int startSection;
  final int endSection;
  final bool highlightAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final isAvailable = room.isFreeFor(startSection, endSection);
    return ActionChip(
      label: Text(room.name),
      avatar: Icon(
        isAvailable ? Icons.meeting_room_outlined : Icons.event_busy_outlined,
        size: 17,
        color: highlightAvailable
            ? (isAvailable ? colors.onAccentSoft : colors.textMuted)
            : null,
      ),
      backgroundColor: highlightAvailable
          ? (isAvailable ? colors.accentSoft : colors.surfaceAlt)
          : null,
      side: highlightAvailable
          ? BorderSide(color: isAvailable ? colors.accent : colors.border)
          : null,
      labelStyle: highlightAvailable
          ? TextStyle(
              color: isAvailable ? colors.onAccentSoft : colors.textMuted,
              fontWeight: isAvailable ? FontWeight.w600 : FontWeight.normal,
            )
          : null,
      tooltip: '${room.name} · ${isAvailable ? '空闲' : '已占用'}',
      onPressed: () => _showRoomSheet(context),
    );
  }

  void _showRoomSheet(BuildContext context) {
    final selectedCourses = room.coursesFor(startSection, endSection);
    final courses = [...room.courses]
      ..sort((a, b) => a.startSection.compareTo(b.startSection));
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colors = context.shuyoColors;
        return SafeArea(
          top: false,
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              20 + MediaQuery.of(context).viewPadding.bottom,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.name,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (room.fullName.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    room.fullName,
                    style: TextStyle(color: colors.textTertiary),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  selectedCourses.isEmpty
                      ? '$startSection-$endSection节空闲'
                      : '$startSection-$endSection节已有安排',
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                if (courses.isEmpty)
                  Text(
                    '当天没有课程安排',
                    style: TextStyle(color: colors.textSecondary),
                  )
                else
                  for (final course in courses)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Text(
                        '${course.sectionText} · ${course.courseName}'
                        '${course.teacherName.isEmpty ? '' : ' · ${course.teacherName}'}',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14.5,
                          height: 1.46,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _dateLabel(DateTime date) {
  final now = DateTime.now();
  if (_isSameDay(date, now)) {
    return '今天 ${date.month}/${date.day}';
  }
  if (_isSameDay(date, now.add(const Duration(days: 1)))) {
    return '明天 ${date.month}/${date.day}';
  }
  return '${date.month}/${date.day}';
}

bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

ClassroomBuilding? _buildingById(List<ClassroomBuilding> buildings, int? id) {
  for (final building in buildings) {
    if (building.id == id) {
      return building;
    }
  }
  return null;
}
