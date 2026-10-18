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
    this.onWebVpnExpired,
  });

  final ClassroomRepository repository;
  final DateTime? initialDate;
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
  bool _refreshingOptions = false;
  String _keyword = '';
  bool _showSearch = false;
  bool _highlightAvailable = false;

  @override
  void initState() {
    super.initState();
    _loadFuture = _loadOptions();
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
      body: FutureBuilder<void>(
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
          final options = _options;
          if (options == null || options.buildings.isEmpty) {
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
                onDateChanged: _setDate,
                onKeywordChanged: (value) => setState(() => _keyword = value),
              ),
              Expanded(child: _resultBody()),
            ],
          );
        },
      ),
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
      },
    );
  }

  Future<void> _loadOptions({bool force = false}) async {
    if (_refreshingOptions) {
      return;
    }
    setState(() => _refreshingOptions = true);
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
        if (_selectedRange == null ||
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
      if (mounted) {
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
    if (names.contains('宝山')) {
      return '宝山';
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
      _selectedBuilding = keepAllBuildings || buildings.isEmpty
          ? null
          : buildings.first;
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          children: [
            Row(
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
                          child: Text(campus, overflow: TextOverflow.ellipsis),
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
                      const DropdownMenuItem(value: 0, child: Text('全部教学楼')),
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
            const SizedBox(height: 10),
            Row(
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
                        lastDate: DateTime.now().add(const Duration(days: 180)),
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
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              key: ValueKey('range-${selectedRange?.start}'),
              initialValue: selectedRange?.start,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '节次',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final range in ranges)
                  DropdownMenuItem(
                    value: range.start,
                    child: Text(
                      _rangeLabel(range),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (start) {
                for (final range in ranges) {
                  if (range.start == start) {
                    onRangeChanged(range);
                    break;
                  }
                }
              },
            ),
            if (showSearch) ...[
              const SizedBox(height: 10),
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索课程、教师或教室',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
                onChanged: onKeywordChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _rangeLabel(ClassroomSectionRange range) {
    String? startTime;
    String? endTime;
    for (final section in options.sections) {
      if (section.index == range.start) {
        startTime = section.startTime;
      }
      if (section.index == range.end) {
        endTime = section.endTime;
      }
    }
    if (startTime == null ||
        startTime.isEmpty ||
        endTime == null ||
        endTime.isEmpty) {
      return range.label;
    }
    return '${range.label} · $startTime–$endTime';
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
                message: result.totalRooms == 0
                    ? '当前范围没有返回教室。'
                    : '当前范围在所选节次没有可用教室。',
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
