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
import '../../shared/widgets/calendar_date_picker.dart';
import '../../shared/widgets/date_picker_dialog.dart';
import '../../shared/widgets/empty_state.dart';

part 'empty_classroom_filters.dart';

class EmptyClassroomPage extends StatefulWidget {
  const EmptyClassroomPage({
    super.key,
    required this.repository,
    this.initialDate,
    this.fixedDate = false,
    this.initialCampus = ClassroomCampus.defaultName,
    this.onWebVpnExpired,
    this.onWebVpnRecoveryRequired,
    this.onDisableWebVpn,
    this.webVpnServiceStatus,
  });

  final ClassroomRepository repository;
  final DateTime? initialDate;
  final bool fixedDate;
  final String initialCampus;
  final Future<void> Function()? onWebVpnExpired;
  final Future<WebVpnRecoveryOutcome> Function(bool interactive)?
      onWebVpnRecoveryRequired;

  /// Turns off global WebVPN and reports whether direct retry can proceed.
  final Future<bool> Function()? onDisableWebVpn;
  final WebVpnServiceStatus Function()? webVpnServiceStatus;

  @override
  State<EmptyClassroomPage> createState() => _EmptyClassroomPageState();
}

class _EmptyClassroomPageState extends State<EmptyClassroomPage> {
  late Future<void> _loadFuture;
  Future<_ClassroomQueryResult>? _resultFuture;
  ClassroomSearchOptions? _options;
  ClassroomBuilding? _selectedBuilding;
  Set<int> _selectedSections = const {};
  String? _selectedCampus;
  late DateTime _selectedDate = widget.initialDate ?? DateTime.now();
  bool _loadingOptions = false;
  bool _refreshingOptions = false;
  String _keyword = '';
  bool _initialSelectionApplied = false;
  ClassroomAccessMode? _retryingMode;
  Object? _retryingError;

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
    _applyOptions(options);
    _search();
  }

  void _applyOptions(ClassroomSearchOptions options) {
    final now = widget.fixedDate ? widget.initialDate : null;
    final repository = widget.repository;
    _options = options;
    _selectedCampus = _validCampus(options);
    _selectedBuilding = _validBuilding(options);
    if (!_initialSelectionApplied) {
      _selectedDate = widget.initialDate ?? repository.defaultDateFor(options);
      _initialSelectionApplied = true;
    }
    final validSections = repository
        .defaultRanges(options.sections)
        .expand((range) => range.sections)
        .toSet();
    _selectedSections = _selectedSections.intersection(validSections);
    if (_selectedSections.isEmpty) {
      _selectedSections =
          repository.defaultRangeFor(options, now: now).sections;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('空教室'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed:
                _loadingOptions || _retryingMode != null ? null : _refresh,
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
      final retryingError = _retryingError;
      if (retryingError != null) {
        return _failureState(retryingError, initialLoad: true);
      }
      return FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return _failureState(snapshot.error!, initialLoad: true);
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
        ExcludeFocus(
          excluding: _retryingMode != null,
          child: AbsorbPointer(
            absorbing: _retryingMode != null,
            child: _SearchControls(
              options: options,
              selectedCampus: _selectedCampus,
              selectedBuilding: _selectedBuilding,
              selectedSections: _selectedSections,
              selectedDate: _selectedDate,
              fixedDate: widget.fixedDate,
              onCampusChanged: _setCampus,
              onBuildingChanged: _setBuilding,
              onPickSections: _pickSections,
              onPickDate: _pickDate,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _ClassroomSearchField(
            onChanged: (value) => setState(() => _keyword = value),
          ),
        ),
        Expanded(child: _resultBody()),
      ],
    );
  }

  Widget _resultBody() {
    final retryingError = _retryingError;
    if (retryingError != null) return _failureState(retryingError);
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
              sections: _selectedSections,
              keyword: _keyword,
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 3));
        }
        if (snapshot.hasError) {
          return _failureState(snapshot.error!);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _loadOptions({
    bool force = false,
    ClassroomAccessMode? accessMode,
  }) async {
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
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
      final options = await _withWebVpnRecovery(
        () => widget.repository.loadOptions(
          forceRefresh: force,
          accessMode: mode,
        ),
        accessMode: mode,
      );
      if (!mounted) {
        return;
      }
      setState(() => _applyOptions(options));
      await _search(forceRefresh: force, accessMode: mode);
    } finally {
      _loadingOptions = false;
      if (mounted) {
        setState(() => _refreshingOptions = false);
      }
    }
  }

  Future<void> _refresh() async {
    if (_retryingMode != null || _loadingOptions) return;
    final future = _loadOptions(force: true);
    setState(() {
      _loadFuture = future;
    });
    // First-load failures are rendered by _loadFuture; keep toolbar retries
    // from also escaping as unhandled asynchronous errors.
    await future.then<void>((_) {}, onError: (_) {});
  }

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
        // A late failure must not undo a newer choice of network mode.
        if (!canRecover()) rethrow;
        if (_webVpnServiceUnavailable) {
          throw const ClassroomApiException(
            '暂时无法连接WebVPN，请稍后重试',
            accessMode: ClassroomAccessMode.webVpn,
          );
        }
        final recover = widget.onWebVpnRecoveryRequired;
        if (recover == null) {
          await widget.onWebVpnExpired?.call();
          rethrow;
        }
        final interactive =
            mounted && ModalRoute.of(context)?.isCurrent != false;
        final outcome = await recover(interactive);
        if (!canRecover()) rethrow;
        switch (outcome) {
          case WebVpnRecoveryOutcome.alreadyValid:
          case WebVpnRecoveryOutcome.recovered:
            // Reads can retry once. A second rejection reaches the error UI.
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

  bool get _webVpnServiceUnavailable =>
      widget.webVpnServiceStatus?.call().effectiveStateAt(DateTime.now()) ==
      WebVpnServiceState.unavailable;

  Widget _failureState(Object error, {bool initialLoad = false}) {
    final mode = error is ClassroomApiException
        ? error.accessMode ?? ClassroomUrlResolver.accessMode
        : ClassroomUrlResolver.accessMode;
    final needsAuthentication =
        error is ClassroomWebVpnAuthException && !_webVpnServiceUnavailable;
    final disableWebVpn = widget.onDisableWebVpn;
    final state = EmptyState(
      icon: initialLoad ? Icons.meeting_room_outlined : Icons.error_outline,
      title: initialLoad ? '空教室加载失败' : '查询失败',
      message: _friendlyError(error),
      action: _ClassroomFailureActions(
        accessMode: mode,
        needsAuthentication: needsAuthentication,
        retryingMode: _retryingMode,
        onRetry: () =>
            _retry(error, initialLoad: initialLoad, accessMode: mode),
        onTryDirect: disableWebVpn == null
            ? null
            : () => _retry(
                  error,
                  initialLoad: initialLoad,
                  disableWebVpn: disableWebVpn,
                ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: state,
        ),
      ),
    );
  }

  Future<void> _retry(
    Object error, {
    required bool initialLoad,
    ClassroomAccessMode? accessMode,
    Future<bool> Function()? disableWebVpn,
  }) async {
    if (_retryingMode != null || _loadingOptions) return;
    setState(() {
      _retryingError = error;
      _retryingMode = accessMode ?? ClassroomAccessMode.direct;
    });
    try {
      // With no access-mode override, the retry follows the saved preference.
      if (disableWebVpn != null) {
        final disabled = await disableWebVpn();
        if (!disabled || !mounted) return;
      }
      // Bypass query caches so the retry actually tries the selected route.
      if (initialLoad) {
        final future = _loadOptions(force: true, accessMode: accessMode);
        setState(() {
          _loadFuture = future;
        });
        await future;
      } else {
        await _search(forceRefresh: true, accessMode: accessMode);
      }
    } on ClassroomApiException {
      // _loadFuture and _resultFuture own the corresponding error UI.
    } finally {
      if (mounted) {
        setState(() {
          _retryingError = null;
          _retryingMode = null;
        });
      }
    }
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

  ClassroomBuilding? _validBuilding(ClassroomSearchOptions options) {
    final campus = _selectedCampus;
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

  Future<void> _pickSections() async {
    final options = _options;
    if (options == null) return;
    final selected = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => _SectionPickerSheet(
        ranges: widget.repository.defaultRanges(options.sections),
        sections: options.sections,
        selected: _selectedSections,
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _selectedSections = selected);
  }

  Future<void> _pickDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final firstDate = now.subtract(const Duration(days: 30));
    final lastDate = now.add(const Duration(days: 180));
    var selected =
        _selectedDate.isBefore(firstDate) || _selectedDate.isAfter(lastDate)
            ? now
            : _selectedDate;
    final date = await showDialog<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ShuYoDatePickerDialog(
          title: '选择日期',
          headerTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(now),
                child: const Text('今天'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context)
                    .pop(DateTime(now.year, now.month, now.day + 1)),
                child: const Text('明天'),
              ),
            ],
          ),
          child: ShuYoCalendarDatePicker(
            firstDate: firstDate,
            lastDate: lastDate,
            focusedDate: selected,
            selectedDate: selected,
            onDateChanged: (date) => setDialogState(() => selected = date),
          ),
          onConfirm: () => Navigator.of(context).pop(selected),
        ),
      ),
    );
    if (!mounted || date == null || DateUtils.isSameDay(date, _selectedDate)) {
      return;
    }
    setState(() => _selectedDate = date);
    _search();
  }

  Future<void> _search({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async {
    final buildings = _selectedBuilding == null
        ? _campusBuildings()
        : <ClassroomBuilding>[_selectedBuilding!];
    if (buildings.isEmpty) {
      return;
    }
    final future = _searchBuildings(
      buildings: buildings,
      date: _selectedDate,
      forceRefresh: forceRefresh,
      accessMode: accessMode ?? ClassroomUrlResolver.accessMode,
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
    required bool forceRefresh,
    required ClassroomAccessMode accessMode,
  }) async {
    final results = <ClassroomBuildingSchedule>[];
    for (final building in buildings) {
      final result = await _withWebVpnRecovery(
        () => widget.repository.loadSchedule(
          building: building,
          date: date,
          forceRefresh: forceRefresh,
          accessMode: accessMode,
        ),
        accessMode: accessMode,
      );
      results.add(result);
    }
    return _ClassroomQueryResult(
      date: date,
      results: results,
    );
  }

  String _friendlyError(Object error) {
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

class _ClassroomFailureActions extends StatelessWidget {
  const _ClassroomFailureActions({
    required this.accessMode,
    required this.needsAuthentication,
    required this.retryingMode,
    required this.onRetry,
    required this.onTryDirect,
  });

  final ClassroomAccessMode accessMode;
  final bool needsAuthentication;
  final ClassroomAccessMode? retryingMode;
  final VoidCallback onRetry;
  final VoidCallback? onTryDirect;

  Widget _icon(ClassroomAccessMode mode, IconData fallback) =>
      retryingMode == mode
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(fallback, size: 18);

  @override
  Widget build(BuildContext context) {
    final busy = retryingMode != null;
    final retryLabel = needsAuthentication
        ? '恢复WebVPN登录'
        : accessMode == ClassroomAccessMode.webVpn
            ? '重试WebVPN'
            : '重试';
    final retry = FilledButton.icon(
      onPressed: busy ? null : onRetry,
      icon: _icon(accessMode, Icons.refresh),
      label: Text(retryLabel),
    );
    if (accessMode == ClassroomAccessMode.direct ||
        needsAuthentication ||
        onTryDirect == null) {
      return retry;
    }
    final direct = OutlinedButton.icon(
      onPressed: busy ? null : onTryDirect,
      icon: _icon(ClassroomAccessMode.direct, Icons.swap_horiz),
      label: const Text('尝试直连'),
    );
    return LayoutBuilder(builder: (context, constraints) {
      double buttonWidth(String label) {
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = painter.width + 18 + 8 + 48;
        painter.dispose();
        return width;
      }

      final requiredWidth = buttonWidth('尝试直连') + buttonWidth('重试WebVPN') + 12;
      if (constraints.maxWidth < requiredWidth) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [direct, const SizedBox(height: 10), retry],
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [direct, const SizedBox(width: 12), retry],
      );
    });
  }
}

class _ClassroomQueryResult {
  const _ClassroomQueryResult({
    required this.date,
    required this.results,
  });

  final DateTime date;
  final List<ClassroomBuildingSchedule> results;

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

class _ClassroomSearchField extends StatefulWidget {
  const _ClassroomSearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

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

class _ClassroomResultList extends StatelessWidget {
  const _ClassroomResultList({
    required this.result,
    required this.sections,
    required this.keyword,
  });

  final _ClassroomQueryResult result;
  final Set<int> sections;
  final String keyword;

  @override
  Widget build(BuildContext context) {
    final normalizedKeyword = keyword.trim();
    final matches = result.courseMatches(normalizedKeyword);
    final colors = context.shuyoColors;
    final availability = [
      for (final schedule in result.results)
        ClassroomBuildingAvailability(schedule, sections),
    ];
    final availableCount =
        availability.fold(0, (sum, building) => sum + building.availableCount);
    final totalRooms =
        availability.fold(0, (sum, building) => sum + building.totalRooms);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
      children: [
        Text(
          '${result.scopeLabel} · ${_dateLabel(result.date)} · ${_sectionLabel(sections)}',
          style: ShuYoTextStyles.title(
            color: colors.textPrimary,
            size: 16.5,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        if (normalizedKeyword.isNotEmpty) ...[
          Text(
            '已按全天课程搜索，忽略当前节次',
            style: TextStyle(color: colors.textTertiary),
          ),
          const SizedBox(height: 18),
          _CourseMatches(matches: matches),
        ] else ...[
          Text(
            '可用 $availableCount / $totalRooms 间',
            style: TextStyle(color: colors.textTertiary),
          ),
          const SizedBox(height: 18),
          if (availableCount == 0)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: EmptyState(
                icon: Icons.event_busy_outlined,
                title: '没有空教室',
                message: '当前范围在所选节次没有可用教室。',
              ),
            )
          else
            for (final item in availability)
              _BuildingAvailableRooms(
                result: item,
                sections: sections,
                showBuildingName: result.results.length > 1,
              ),
        ],
      ],
    );
  }
}

class _BuildingAvailableRooms extends StatelessWidget {
  const _BuildingAvailableRooms({
    required this.result,
    required this.sections,
    required this.showBuildingName,
  });

  final ClassroomBuildingAvailability result;
  final Set<int> sections;
  final bool showBuildingName;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final availableFloors = result.floors
        .where((floor) => floor.availableRooms.isNotEmpty)
        .toList(growable: false);
    if (availableFloors.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showBuildingName) ...[
            Text(
              '${result.building.name} · ${result.availableCount}间',
              style: ShuYoTextStyles.title(
                color: colors.textPrimary,
                size: 15.5,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final floor in availableFloors)
            _FloorAvailableRooms(
              floor: floor,
              sections: sections,
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
    required this.sections,
  });

  final ClassroomFloorAvailability floor;
  final Set<int> sections;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${floor.floor.name} · ${floor.availableRooms.length}间',
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
              for (final room in floor.availableRooms)
                _RoomChip(
                  room: room,
                  sections: sections,
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
    required this.sections,
  });

  final ClassroomRoom room;
  final Set<int> sections;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(room.name),
      avatar: const Icon(Icons.meeting_room_outlined, size: 17),
      onPressed: () => _showRoomSheet(context),
    );
  }

  void _showRoomSheet(BuildContext context) {
    final selectedCourses = room.coursesFor(sections);
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
                      ? '${_sectionLabel(sections)}空闲'
                      : '${_sectionLabel(sections)}已有安排',
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
  if (DateUtils.isSameDay(date, now)) {
    return '今天 ${date.month}/${date.day}';
  }
  if (DateUtils.isSameDay(date, now.add(const Duration(days: 1)))) {
    return '明天 ${date.month}/${date.day}';
  }
  return '${date.month}/${date.day}';
}

ClassroomBuilding? _buildingById(
  List<ClassroomBuilding> buildings,
  int? id,
) {
  for (final building in buildings) {
    if (building.id == id) {
      return building;
    }
  }
  return null;
}
