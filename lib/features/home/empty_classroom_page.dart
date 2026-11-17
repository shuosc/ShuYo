import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/classroom_url_resolver.dart';
import '../../data/models/classroom.dart';
import '../../data/models/client_backend.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/classroom_api_client.dart';
import '../../data/services/unified_account_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../empty_classroom/classroom_filter_menu.dart';
import '../empty_classroom/classroom_search_page.dart';

class EmptyClassroomPage extends StatefulWidget {
  const EmptyClassroomPage({
    super.key,
    required this.repository,
    this.initialDate,
    this.initialCampus = ClassroomCampus.defaultName,
    this.onWebVpnExpired,
    this.onWebVpnRecoveryRequired,
    this.webVpnServiceStatus,
  });

  final ClassroomRepository repository;
  final DateTime? initialDate;
  final String initialCampus;
  final Future<void> Function()? onWebVpnExpired;
  final Future<WebVpnRecoveryOutcome> Function(bool interactive)?
      onWebVpnRecoveryRequired;
  final WebVpnServiceStatus Function()? webVpnServiceStatus;

  @override
  State<EmptyClassroomPage> createState() => _EmptyClassroomPageState();
}

class _EmptyClassroomPageState extends State<EmptyClassroomPage> {
  late Future<void> _loadFuture;
  Future<_ClassroomQueryResult>? _resultFuture;
  ClassroomSearchOptions? _options;
  ClassroomBuilding? _selectedBuilding;
  ClassroomSectionRange? _selectedRange;
  ClassroomWeather? _weather;
  String? _selectedCampus;
  late DateTime _selectedDate = widget.initialDate ?? DateTime.now();
  bool _loadingOptions = false;
  bool _refreshingOptions = false;
  int _activeQueries = 0;
  bool _pullRefreshing = false;
  bool _initialSelectionApplied = false;
  ClassroomAccessMode? _retryingMode;
  Object? _retryingError;

  /// AppBar 进度条只代表“非下拉刷新”的网络活动；下拉时由 [RefreshIndicator]
  /// 自带的转圈负责，两者不同时出现。
  bool get _toolbarBusy =>
      (_refreshingOptions || _activeQueries > 0) && !_pullRefreshing;

  @override
  void initState() {
    super.initState();
    unawaited(_loadWeather());
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

  Future<void> _loadWeather() async {
    final weather = await widget.repository.loadWeather();
    if (!mounted || weather == null) return;
    setState(() => _weather = weather);
  }

  /// Restores the options and their matching selections and starts the query
  /// they describe right away.
  void _applyOptionsSnapshot(ClassroomSearchOptions options) {
    final now = DateTime.now();
    _options = options;
    _selectedCampus = _validCampus(options);
    _selectedBuilding = _validBuilding(options);
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
            key: const ValueKey('classroom-search-entry'),
            tooltip: '搜索课程',
            onPressed:
                _options == null || _retryingMode != null ? null : _openSearch,
            icon: const Icon(Icons.search),
          ),
          const SizedBox(width: 2),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _toolbarBusy
              ? const LinearProgressIndicator(
                  key: ValueKey('classroom-toolbar-progress'),
                  minHeight: 3,
                )
              : const SizedBox(height: 3),
        ),
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
              selectedRange: _selectedRange,
              selectedDate: _selectedDate,
              weather: _weather,
              ranges: widget.repository.defaultRanges(options.sections),
              onPickBuilding: () => unawaited(_pickBuilding(options)),
              onRangeChanged: _setRange,
              onPreviousRange: () => _stepRange(-1),
              onNextRange: () => _stepRange(1),
              onDateChanged: _setDate,
            ),
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
            onRefresh: _refreshByPull,
            child: _ClassroomResultList(result: snapshot.data!),
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
      setState(() {
        _options = options;
        _selectedCampus = _validCampus(options);
        _selectedBuilding = _validBuilding(options);
        if (!_initialSelectionApplied) {
          final now = DateTime.now();
          if (widget.initialDate == null) {
            _selectedDate = widget.repository.defaultDateFor(options, now: now);
          }
          _selectedRange = widget.repository.defaultRangeFor(options, now: now);
          _initialSelectionApplied = true;
        } else {
          _selectedRange ??= widget.repository.defaultRangeFor(options);
        }
      });
      await _search(forceRefresh: force, accessMode: mode);
    } finally {
      _loadingOptions = false;
      if (mounted) {
        setState(() => _refreshingOptions = false);
      }
    }
  }

  /// 下拉刷新走列表自己的转圈，不重复点亮 AppBar 进度条。
  Future<void> _refreshByPull() async {
    if (_pullRefreshing) return;
    _pullRefreshing = true;
    try {
      await _search();
    } finally {
      _pullRefreshing = false;
    }
  }

  Future<void> _openSearch() async {
    final options = _options;
    if (options == null) return;
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (_) => ClassroomSearchPage(
          repository: widget.repository,
          options: options,
          initialDate: _selectedDate,
          initialCampus: _selectedCampus ?? widget.initialCampus,
          onWebVpnRecoveryRequired: widget.onWebVpnRecoveryRequired,
          webVpnServiceStatus: widget.webVpnServiceStatus,
        ),
      ),
    );
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
        onTryDirect: () => _retry(
          error,
          initialLoad: initialLoad,
          accessMode: ClassroomAccessMode.direct,
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
    required ClassroomAccessMode accessMode,
  }) async {
    if (_retryingMode != null || _loadingOptions) return;
    setState(() {
      _retryingError = error;
      _retryingMode = accessMode;
    });
    try {
      // Bypass query caches so choosing a transport really tries that route.
      // The override belongs to this operation, never the global resolver.
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
    if (current == null) {
      return null;
    }
    final buildings = options.buildings
        .where((building) => campus == null || building.campusName == campus)
        .toList(growable: false);
    if (buildings.any((building) => building.id == current.id)) {
      return current;
    }
    return null;
  }

  Future<void> _pickBuilding(ClassroomSearchOptions options) async {
    final picked = await showClassroomSingleBuildingMenu(
      context,
      buildings: options.buildings,
      selectedCampus: _selectedCampus,
      selectedBuilding: _selectedBuilding,
    );
    if (picked == null || !mounted) return;
    if (picked.campus == _selectedCampus &&
        picked.building?.id == _selectedBuilding?.id) {
      return;
    }
    setState(() {
      _selectedCampus = picked.campus;
      _selectedBuilding = picked.building;
    });
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

  Future<void> _search({
    bool forceRefresh = false,
    ClassroomAccessMode? accessMode,
  }) async {
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
      range: range,
      date: _selectedDate,
      forceRefresh: forceRefresh,
      accessMode: accessMode ?? ClassroomUrlResolver.accessMode,
    );
    setState(() {
      _resultFuture = future;
      _activeQueries++;
    });
    // The FutureBuilder owns the error UI; the bar only has to stop.
    try {
      await future.then<void>((_) {}, onError: (_) {});
    } finally {
      if (mounted) {
        setState(() => _activeQueries--);
      }
    }
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
    required ClassroomSectionRange range,
    required DateTime date,
    required bool forceRefresh,
    required ClassroomAccessMode accessMode,
  }) async {
    final results = <ClassroomAvailabilityResult>[];
    for (final building in buildings) {
      final result = await _withWebVpnRecovery(
        () => widget.repository.search(
          ClassroomAvailabilityQuery(
            building: building,
            date: date,
            startSection: range.start,
            endSection: range.end,
          ),
          forceRefresh: forceRefresh,
          accessMode: accessMode,
        ),
        accessMode: accessMode,
      );
      results.add(result);
    }
    return _ClassroomQueryResult(
      date: date,
      startSection: range.start,
      endSection: range.end,
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
  final VoidCallback onTryDirect;

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
    if (accessMode == ClassroomAccessMode.direct || needsAuthentication) {
      return FilledButton.icon(
        onPressed: busy ? null : onRetry,
        icon: _icon(accessMode, Icons.refresh),
        label: Text(needsAuthentication ? '恢复WebVPN登录' : '重试'),
      );
    }
    final direct = OutlinedButton.icon(
      onPressed: busy ? null : onTryDirect,
      icon: _icon(ClassroomAccessMode.direct, Icons.swap_horiz),
      label: const Text('尝试直连'),
    );
    final retry = FilledButton.icon(
      onPressed: busy ? null : onRetry,
      icon: _icon(ClassroomAccessMode.webVpn, Icons.refresh),
      label: const Text('重试WebVPN'),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(builder: (context, constraints) {
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

          final requiredWidth =
              buttonWidth('尝试直连') + buttonWidth('重试WebVPN') + 12;
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
        }),
        const SizedBox(height: 8),
        Text(
          '本次直连不改变全局WebVPN设置',
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.meta(
            color: context.shuyoColors.textSecondary,
          ),
        ),
      ],
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
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.options,
    required this.selectedCampus,
    required this.selectedBuilding,
    required this.selectedRange,
    required this.selectedDate,
    required this.weather,
    required this.ranges,
    required this.onPickBuilding,
    required this.onRangeChanged,
    required this.onPreviousRange,
    required this.onNextRange,
    required this.onDateChanged,
  });

  final ClassroomSearchOptions options;
  final String? selectedCampus;
  final ClassroomBuilding? selectedBuilding;
  final ClassroomSectionRange? selectedRange;
  final DateTime selectedDate;
  final ClassroomWeather? weather;
  final List<ClassroomSectionRange> ranges;
  final VoidCallback onPickBuilding;
  final ValueChanged<ClassroomSectionRange> onRangeChanged;
  final VoidCallback onPreviousRange;
  final VoidCallback onNextRange;
  final ValueChanged<DateTime> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final weatherInfo = weather?.weather.trim() ?? '';
    final campus = selectedCampus ?? '';
    final campusLabel = campus.isEmpty ? '' : '$campus校区';
    final buildingLabel = selectedBuilding?.name ?? 'ALL';
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxButtonWidth = constraints.maxWidth * 0.65;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, leftConstraints) => Row(
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: weatherInfo.isEmpty
                                      ? leftConstraints.maxWidth
                                      : leftConstraints.maxWidth * 0.6,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${selectedDate.month}月${selectedDate.day}日',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ShuYoTextStyles.title(
                                        color: colors.textPrimary,
                                        size: 15.5,
                                        weight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      _weekdayLabel(selectedDate),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ShuYoTextStyles.meta(
                                        color: colors.textTertiary,
                                        size: 12.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (weatherInfo.isNotEmpty) ...[
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _weatherIcon(weatherInfo),
                                        size: 16,
                                        color: colors.textSecondary,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          weatherInfo,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: ShuYoTextStyles.meta(
                                            color: colors.textSecondary,
                                            size: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxButtonWidth),
                        child: _BuildingPickerButton(
                          campusLabel: campusLabel,
                          buildingLabel: buildingLabel,
                          maxWidth: maxButtonWidth,
                          onPressed:
                              options.buildings.isEmpty ? null : onPickBuilding,
                        ),
                      ),
                    ],
                  );
                },
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
          ],
        ),
      ),
    );
  }
}

/// 顶栏校区与教学楼切换按钮：无边框、贴齐右侧边距，突出当前楼栋。
class _BuildingPickerButton extends StatelessWidget {
  const _BuildingPickerButton({
    required this.campusLabel,
    required this.buildingLabel,
    required this.maxWidth,
    required this.onPressed,
  });

  final String campusLabel;
  final String buildingLabel;
  final double maxWidth;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    final enabled = onPressed != null;
    final fixedWidth = campusLabel.isEmpty ? 52.0 : 60.0;
    final maxCampusWidth = math.max(0.0, maxWidth - fixedWidth) * 0.6;
    return TextButton(
      key: const ValueKey('classroom-building-picker'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.textPrimary,
        alignment: Alignment.centerRight,
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.location_city_outlined,
            size: 18,
            color: enabled ? colors.textSecondary : colors.textMuted,
          ),
          const SizedBox(width: 4),
          if (campusLabel.isNotEmpty) ...[
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxCampusWidth),
              child: Text(
                campusLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShuYoTextStyles.title(
                  color: enabled ? colors.textPrimary : colors.textMuted,
                  size: 16,
                  weight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              buildingLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShuYoTextStyles.title(
                color: enabled ? primary : colors.textMuted,
                size: 16,
                weight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.swap_horiz,
            size: 18,
            color: enabled ? colors.textSecondary : colors.textMuted,
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
  const _ClassroomResultList({required this.result});

  final _ClassroomQueryResult result;

  @override
  Widget build(BuildContext context) {
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
        Text(
          '可用 ${result.availableCount} / ${result.totalRooms} 间',
          style: TextStyle(color: colors.textTertiary),
        ),
        const SizedBox(height: 18),
        if (result.availableCount == 0)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: EmptyState(
              icon: Icons.event_busy_outlined,
              title: '没有空教室',
              message: '当前范围在所选节次没有可用教室。',
            ),
          )
        else
          for (final item in result.results)
            _BuildingAvailableRooms(
              result: item,
              showBuildingName: result.results.length > 1,
            ),
      ],
    );
  }
}

class _BuildingAvailableRooms extends StatelessWidget {
  const _BuildingAvailableRooms({
    required this.result,
    required this.showBuildingName,
  });

  final ClassroomAvailabilityResult result;
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
              startSection: result.startSection,
              endSection: result.endSection,
            ),
        ],
      ),
    );
  }
}

class _FloorAvailableRooms extends StatelessWidget {
  const _FloorAvailableRooms({
    required this.floor,
    required this.startSection,
    required this.endSection,
  });

  final ClassroomFloorAvailability floor;
  final int startSection;
  final int endSection;

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
                  startSection: startSection,
                  endSection: endSection,
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
  });

  final ClassroomRoom room;
  final int startSection;
  final int endSection;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(room.name),
      avatar: const Icon(Icons.meeting_room_outlined, size: 17),
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

String _weekdayLabel(DateTime date) {
  const names = <String>[
    '星期一',
    '星期二',
    '星期三',
    '星期四',
    '星期五',
    '星期六',
    '星期日',
  ];
  return names[date.weekday - 1];
}

IconData _weatherIcon(String weather) {
  if (weather.contains('雪')) return Icons.ac_unit_outlined;
  if (weather.contains('雷')) return Icons.thunderstorm_outlined;
  if (weather.contains('雨')) return Icons.grain_outlined;
  if (weather.contains('雾') || weather.contains('霾')) return Icons.blur_on;
  if (weather.contains('阴') || weather.contains('云')) {
    return Icons.cloud_outlined;
  }
  return Icons.wb_sunny_outlined;
}
