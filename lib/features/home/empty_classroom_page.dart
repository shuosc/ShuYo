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
part 'empty_classroom_results.dart';

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
  List<_BuildingLoad> _buildingLoads = const [];
  ClassroomSearchOptions? _options;
  ClassroomBuilding? _selectedBuilding;
  Set<int> _selectedSections = const {};
  String? _selectedCampus;
  late DateTime _selectedDate = widget.initialDate ?? DateTime.now();
  bool _loadingOptions = false;
  bool _refreshingOptions = false;
  _ClassroomView _view = _ClassroomView.available;
  _ArrangementScope _arrangementScope = _ArrangementScope.fullDay;
  bool _onlyArranged = false;
  final _courseSearch = TextEditingController();
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

  @override
  void dispose() {
    _courseSearch.dispose();
    super.dispose();
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
    _selectedBuilding = _validBuilding();
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
      return const Center(child: _ResultMessage('暂无教学楼'));
    }
    return SafeArea(
      top: false,
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: ExcludeFocus(
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
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: _ClassroomSegments(
                  segments: const [
                    ButtonSegment(
                        value: _ClassroomView.available, label: Text('找空教室')),
                    ButtonSegment(
                        value: _ClassroomView.arrangements,
                        label: Text('教室安排')),
                  ],
                  selected: _view,
                  onChanged: (value) {
                    if (value == _view) return;
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => _view = value);
                  },
                ),
              ),
            ),
            if (_view == _ClassroomView.arrangements)
              SliverToBoxAdapter(
                child: _ArrangementFilters(
                  controller: _courseSearch,
                  scope: _arrangementScope,
                  onlyArranged: _onlyArranged,
                  onSearch: (_) => setState(() {}),
                  onClear: () => setState(_courseSearch.clear),
                  onScope: (value) => setState(() => _arrangementScope = value),
                  onOnlyArranged: (value) =>
                      setState(() => _onlyArranged = value),
                ),
              ),
            _results(),
          ],
        ),
      ),
    );
  }

  Widget _results() {
    final errors = _buildingLoads.map((load) => load.error).nonNulls.toList();
    final allFailed =
        errors.isNotEmpty && errors.length == _buildingLoads.length;
    final error = _retryingError ??
        (allFailed
            ? errors.whereType<ClassroomWebVpnAuthException>().firstOrNull ??
                errors.first
            : null);
    if (error != null) {
      return SliverToBoxAdapter(child: _failureState(error));
    }
    if (_buildingLoads.length == 1 && _buildingLoads.single.pending) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
      );
    }
    return _ClassroomResults(
      loads: _buildingLoads,
      view: _view,
      sections: _selectedSections,
      scope: _arrangementScope,
      keyword: _courseSearch.text.trim().toLowerCase(),
      onlyArranged: _onlyArranged,
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
    bool Function()? isCurrent,
  }) async {
    final accessRevision = ClassroomUrlResolver.revision;
    bool canRecover() =>
        mounted &&
        (isCurrent?.call() ?? true) &&
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
    if (!initialLoad) return state;
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
      // The current load owns the corresponding error UI.
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

  ClassroomBuilding? _validBuilding() {
    if (_selectedBuilding == null && _buildingLoads.isNotEmpty) {
      return null;
    }
    final buildings = _campusBuildings();
    return _buildingById(buildings, _selectedBuilding?.id) ??
        _defaultBuilding(buildings);
  }

  ClassroomBuilding? _defaultBuilding(List<ClassroomBuilding> buildings) {
    for (final building in buildings) {
      if (building.campusName == ClassroomCampus.defaultName &&
          building.name == 'A楼') {
        return building;
      }
    }
    return buildings.firstOrNull;
  }

  void _setCampus(String? value) {
    if (_options == null || value == null || value == _selectedCampus) {
      return;
    }
    setState(() {
      _selectedCampus = value;
      if (_selectedBuilding != null) {
        _selectedBuilding = _defaultBuilding(_campusBuildings());
      }
    });
    _search();
  }

  void _setBuilding(ClassroomBuilding? value) {
    if (value?.id == _selectedBuilding?.id) return;
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
    final loads = buildings.map(_BuildingLoad.new).toList(growable: false);
    final date = _selectedDate;
    final mode = accessMode ?? ClassroomUrlResolver.accessMode;
    setState(() => _buildingLoads = loads);
    bool isCurrent() => mounted && identical(loads, _buildingLoads);

    for (final load in loads) {
      if (!isCurrent()) return;
      try {
        final schedule = await _withWebVpnRecovery(
          () => widget.repository.loadSchedule(
            building: load.building,
            date: date,
            forceRefresh: forceRefresh,
            accessMode: mode,
          ),
          accessMode: mode,
          isCurrent: isCurrent,
        );
        if (!isCurrent()) return;
        setState(() => load.schedule = schedule);
      } on ClassroomApiException catch (error) {
        if (!isCurrent()) return;
        if (error is ClassroomWebVpnAuthException) {
          // Authentication applies to the whole route, not one building.
          setState(() {
            for (final pending in loads.where((load) => load.pending)) {
              pending.error = error;
            }
          });
          return;
        }
        setState(() => load.error = error);
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
