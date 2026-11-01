import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'recording_catalog_controller.dart';
import 'recording_list_presentation.dart';
import 'recording_course_title.dart';
import 'recording_player_page.dart';
import 'recording_search_page.dart';
import 'recording_status_icon.dart';
import 'recording_term_menu.dart';
import 'recording_timetable_view.dart';

/// The ordinary account catalog.
class CourseRecordingsPage extends StatefulWidget {
  const CourseRecordingsPage({
    super.key,
    this.repository,
    this.authService,
    this.useWebVpn = false,
    this.onWebVpnSessionRequired,
    this.onCampusSessionExpired,
    this.sessionLoader,
    this.onLoginRequested,
  });

  final VodRepository? repository;
  final VodAuthService? authService;
  final bool useWebVpn;
  final Future<bool> Function()? onWebVpnSessionRequired;
  final Future<void> Function()? onCampusSessionExpired;
  final Future<bool> Function()? sessionLoader;
  final Future<bool> Function()? onLoginRequested;

  @override
  State<CourseRecordingsPage> createState() => _CourseRecordingsPageState();
}

class _CourseRecordingsPageState extends State<CourseRecordingsPage> {
  late final VodAuthService _auth = widget.authService ?? VodAuthService();
  late final VodRepository _repository = widget.repository ??
      VodRepository(
        clientFactory: () => VodApiClient(
          authService: _auth,
          useWebVpn: widget.useWebVpn,
        ),
      );
  final _collapsedTermYears = <String>{};
  final _presentedCourseIds = <int>{};
  late final _catalog = RecordingCatalogController(_repository,
      onSessionInvalidated: (expired) =>
          _campusAuthRequired(ssoExpired: expired));
  late RecordingCatalogViewData _view = RecordingCatalogViewData(_catalog);
  final _courseRows = <int, ({Object signature, Widget row})>{};
  bool _timetableCreated = false;
  Widget? _cachedTimetable;
  int? _presentedTermId;
  List<VodTerm> get _terms => _view.terms;
  List<VodCourse> get _courses => _view.courses;
  int? get _selectedTermId => _view.selectedTermId;
  Object? get _error => _view.error;
  set _error(Object? value) => _catalog.error = value;
  bool get _loading => _view.loading;
  Map<int, List<VodLesson>> get _courseLessons => _view.courseLessons;
  Set<int> get _pendingLessonCounts => _view.pendingLessonCounts;
  bool _checkingSession = true;
  bool _authenticated = false;
  bool _expired = false;
  bool _loggingIn = false;
  bool _openingCourse = false;
  bool _timetableMode = false;

  bool get _showLoadingProgress =>
      _checkingSession || _view.showLoadingProgress;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _catalog.dispose();
    if (widget.repository == null) {
      final repository = _repository;
      final auth = widget.authService == null ? _auth : null;
      unawaited(() async {
        try {
          await repository.waitForBackgroundWarming();
        } finally {
          repository.dispose();
          auth?.dispose();
        }
      }());
    } else if (widget.authService == null) {
      _auth.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    if (mounted) {
      setState(() {
        _checkingSession = true;
        _error = null;
      });
    }
    try {
      final valid = await _prepareSession();
      if (!mounted) return;
      setState(() {
        _authenticated = valid;
        _checkingSession = false;
      });
      if (valid) await _load();
    } on VodCampusAuthRequiredException catch (error) {
      await _campusAuthRequired(ssoExpired: error.ssoExpired);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _checkingSession = false;
        _error = error;
      });
    }
  }

  Future<bool> _prepareSession({bool forceRefresh = false}) async {
    final loader = widget.sessionLoader;
    if (loader != null) return loader();
    if (widget.useWebVpn &&
        widget.onWebVpnSessionRequired != null &&
        !await widget.onWebVpnSessionRequired!()) {
      throw const VodAuthException('WebVPN 连接未恢复，请检查连接后重试。');
    }
    try {
      await _auth.ensureSession(
          useWebVpn: widget.useWebVpn, forceRefresh: forceRefresh);
    } on Object catch (error) {
      final connectionFailure = error is VodAuthUnavailableException ||
          error is SocketException ||
          error is TimeoutException ||
          error is http.ClientException;
      if (!connectionFailure ||
          !await _auth.hasSession(useWebVpn: widget.useWebVpn) ||
          !await _repository.hasCachedRecordings()) {
        rethrow;
      }
    }
    return true;
  }

  Future<void> _campusAuthRequired({required bool ssoExpired}) async {
    if (!mounted) return;
    _catalog.clear();
    _repository.clear();
    setState(() {
      _checkingSession = false;
      _authenticated = false;
      _expired = ssoExpired;
      _presentedCourseIds.clear();
      _courseRows.clear();
      _error = null;
    });
    if (ssoExpired) await widget.onCampusSessionExpired?.call();
  }

  Future<bool> _login() async {
    if (_loggingIn) return false;
    setState(() => _loggingIn = true);
    try {
      final callback = widget.onLoginRequested;
      final succeeded = callback != null && await callback();
      if (!mounted || !succeeded) return false;
      if (!await _prepareSession(forceRefresh: true) || !mounted) return false;
      _repository.clear();
      _catalog.clear();
      setState(() {
        _authenticated = true;
        _expired = false;
        _error = null;
        _presentedCourseIds.clear();
      });
      await _load(force: true);
      return mounted && _authenticated;
    } on VodCampusAuthRequiredException catch (error) {
      await _campusAuthRequired(ssoExpired: error.ssoExpired);
      return false;
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<bool> _recoverSession() async {
    try {
      if (!await _prepareSession(forceRefresh: true) || !mounted) return false;
      _repository.clear();
      return true;
    } on VodCampusAuthRequiredException catch (error) {
      await _campusAuthRequired(ssoExpired: error.ssoExpired);
      if (!mounted) return false;
      return _login();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂时无法恢复课程录播，请稍后重试')),
        );
      }
      return false;
    }
  }

  Future<void> _load(
      {bool force = false, int? termId, bool fromPull = false}) async {
    if (!_authenticated) return;
    await _catalog.load(force: force, termId: termId, fromPull: fromPull);
  }

  Future<void> _openCourse(VodCourse course,
      {VodLesson? lesson, List<VodLesson>? preparedLessons}) async {
    if (_openingCourse || lesson != null && !lesson.canPlay) return;
    if (!_authenticated ||
        course.termId != _catalog.selectedTermId ||
        !_catalog.hasCompleteAvailability(course) ||
        !_catalog.hasPlayableCourse(course)) {
      return;
    }
    final lessons = preparedLessons ??
        _courseLessons[course.teachingClassId] ??
        const <VodLesson>[];
    final live = course.liveLesson;
    final initial = lesson ??
        (live != null && live.isLiveAvailable && live.canPlay ? live : null) ??
        lessons.where((item) => item.isLiveAvailable).firstOrNull ??
        lessons.where((item) => !item.isLive && item.isPlayable).firstOrNull ??
        lessons.where((item) => !item.isLive && item.canPlay).firstOrNull;
    _openingCourse = true;
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingPlayerPage(
          repository: _repository,
          course: course,
          term: _terms.where((term) => term.id == course.termId).firstOrNull,
          initialLesson: initial,
          lessons: lessons,
          skipInitialCatalogLoad: true,
          onSessionExpired: _recoverSession,
        ),
      ));
    } finally {
      _openingCourse = false;
    }
  }

  Future<void> _chooseTerm() async {
    final termId = await showRecordingTermMenu(
      context,
      terms: _terms,
      selectedTermId: _selectedTermId,
      collapsedYears: _collapsedTermYears,
      onExpansionChanged: (year, expanded) {
        if (expanded) {
          _collapsedTermYears.remove(year);
        } else {
          _collapsedTermYears.add(year);
        }
      },
    );
    if (!mounted ||
        !_authenticated ||
        termId == null ||
        termId == _selectedTermId) {
      return;
    }
    await _load(termId: termId);
  }

  Future<void> _openSearch() async {
    final termId = _selectedTermId;
    if (!_authenticated || termId == null) return;
    await Navigator.of(context).push<void>(shuyoRoute(
      builder: (_) => RecordingSearchPage(
        repository: _repository,
        terms: _terms,
        selectedTermId: termId,
        onSessionInvalidated: (ssoExpired) =>
            _campusAuthRequired(ssoExpired: ssoExpired),
        onLoginRequested: _login,
        onSessionExpired: _recoverSession,
      ),
    ));
  }

  Future<void> _showDataInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('课程录播信息说明'),
        content: const Text('学校录播平台接口可能随时更改，部分功能的可用性和完整性无法保证。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => RecordingListPresentation(
      changes: _catalog,
      builder: (context) {
        _view = RecordingCatalogViewData(_catalog);
        if (_presentedTermId != _selectedTermId) {
          _presentedTermId = _selectedTermId;
          _presentedCourseIds.clear();
          _courseRows.clear();
          _timetableCreated = _timetableMode;
          _cachedTimetable = null;
        }
        return _buildScaffold();
      });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _courseRows.clear();
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Flexible(
              child: Text('课程录播', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Transform.translate(
              offset: const Offset(-3, -0.5),
              child: Opacity(
                opacity: 0.65,
                child: IconButton(
                  tooltip: '课程录播信息说明',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: _showDataInfo,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_authenticated) ...[
            IconButton(
              key: const ValueKey('vod-search'),
              tooltip: '搜索录播',
              onPressed: _selectedTermId == null ? null : _openSearch,
              icon: const Icon(Icons.search),
            ),
            IconButton(
              key: const ValueKey('vod-term-filter'),
              tooltip: '选择学期',
              onPressed: _terms.isEmpty ? null : _chooseTerm,
              icon: const Icon(Icons.format_list_bulleted),
            ),
          ],
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _showLoadingProgress
                ? const LinearProgressIndicator(
                    key: ValueKey('vod-loading-progress'), minHeight: 2)
                : null,
          ),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_checkingSession) {
      return const SizedBox.expand();
    }
    if (!_authenticated) {
      if (_error != null) return _errorState();
      return EmptyState(
        icon: Icons.video_library_outlined,
        title: _expired ? '校园账户登录已失效' : '登录校园账户',
        message: '使用 ShuYo 的校园账户查看你有权限的课程回放。',
        action: FilledButton.icon(
          onPressed:
              _loggingIn || widget.onLoginRequested == null ? null : _login,
          icon: const Icon(Icons.login),
          label: Text(_loggingIn
              ? '正在登录'
              : _expired
                  ? '重新登录'
                  : '登录'),
        ),
      );
    }
    if (_terms.isEmpty && _loading) {
      return const SizedBox.expand();
    }
    if (_terms.isEmpty && _error != null) return _errorState();
    if (_terms.isEmpty) {
      return EmptyState(
        icon: Icons.event_note_outlined,
        title: '暂无可查询学期',
        message: '录播平台暂未提供学期信息。',
        action: TextButton.icon(
          onPressed: () => _load(force: true),
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    }
    final selectedTerm =
        _terms.where((term) => term.id == _selectedTermId).firstOrNull;
    final visibleCourses = _view.visibleCourses;
    final visibleIndexes = _view.visibleIndexes;
    final view = _view;
    final loadingCourses = _loading || _pendingLessonCounts.isNotEmpty;
    final unknownCourseCount = _courses.isEmpty && (_loading || _error != null);
    return Column(children: [
      if (_error != null && _courses.isNotEmpty)
        MaterialBanner(
          content: Text(_errorMessage()),
          actions: [
            TextButton(
              onPressed: _loading ? null : () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      if (selectedTerm != null)
        Padding(
          key: const ValueKey('vod-course-summary'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Expanded(
              flex: 2,
              child: Row(children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      if (selectedTerm.academicYear.isEmpty)
                        TextSpan(text: selectedTerm.name)
                      else ...[
                        TextSpan(text: '${selectedTerm.academicYear} 学年 '),
                        TextSpan(
                          text: selectedTerm.seasonLabel,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary),
                        ),
                      ],
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.bodyCompact(
                            color: context.shuyoColors.textPrimary)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text.rich(
                    key: const ValueKey('vod-course-count'),
                    TextSpan(children: [
                      TextSpan(
                          text: unknownCourseCount ? '—' : '${_courses.length}',
                          style: unknownCourseCount
                              ? null
                              : TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                      const TextSpan(text: '个课程'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.meta(
                            color: context.shuyoColors.textPrimary)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: _timetableMode ? '切换为课程列表' : '切换为时间表',
                  child: TextButton.icon(
                    key: const ValueKey('vod-view-toggle'),
                    onPressed: _terms.isEmpty
                        ? null
                        : () => setState(() {
                              _timetableMode = !_timetableMode;
                              _timetableCreated = true;
                            }),
                    icon: Icon(
                      _timetableMode
                          ? Icons.view_list_outlined
                          : Icons.calendar_view_week_outlined,
                      size: 20,
                    ),
                    label: Text(
                      _timetableMode ? '列表' : '时间表',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      Expanded(
          child: _error != null && _courses.isEmpty
              ? _errorState()
              : IndexedStack(index: _timetableMode ? 1 : 0, children: [
                  TickerMode(
                    enabled: !_timetableMode,
                    child: RefreshIndicator(
                      notificationPredicate: (notification) =>
                          !_showLoadingProgress &&
                          defaultScrollNotificationPredicate(notification),
                      onRefresh: () => _load(force: true, fromPull: true),
                      child: visibleCourses.isEmpty
                          ? LayoutBuilder(
                              builder: (context, constraints) => ListView(
                                    key: ValueKey(
                                        'vod-courses:$_selectedTermId'),
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    children: [
                                      SizedBox(
                                          height: constraints.maxHeight,
                                          child: loadingCourses ||
                                                  _courses.isNotEmpty
                                              ? const SizedBox.expand()
                                              : EmptyState(
                                                  icon: Icons
                                                      .video_library_outlined,
                                                  title: '本学期暂无可观看课程',
                                                  message: '可切换学期，或在课程回放生成后刷新。',
                                                )),
                                    ],
                                  ))
                          : ListView.separated(
                              key: ValueKey('vod-courses:$_selectedTermId'),
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.only(bottom: 24),
                              itemCount: visibleCourses.length,
                              findItemIndexCallback: (key) {
                                return key is ValueKey<int>
                                    ? visibleIndexes[key.value]
                                    : null;
                              },
                              separatorBuilder: (_, __) =>
                                  const Divider(indent: 16, endIndent: 16),
                              itemBuilder: (context, index) {
                                final course = visibleCourses[index];
                                return _CourseEntrance(
                                  key: ValueKey(course.teachingClassId),
                                  index: index,
                                  animate: _presentedCourseIds
                                      .add(course.teachingClassId),
                                  child: _courseTile(course, view),
                                );
                              },
                            ),
                    ),
                  ),
                  TickerMode(
                    enabled: _timetableMode,
                    child: _timetable(),
                  ),
                ])),
    ]);
  }

  Widget _timetable() {
    if (!_timetableCreated) return const SizedBox.shrink();
    if (!_timetableMode && _cachedTimetable != null) return _cachedTimetable!;
    final view = _view;
    return _cachedTimetable = RecordingTimetableView(
      key: ValueKey('vod-timetable:${view.selectedTermId}'),
      data: _catalog.timetable,
      loading: view.loading || view.pendingLessonCounts.isNotEmpty,
      refreshEnabled: !view.showLoadingProgress,
      failedCourseCount: view.courses
          .where((course) =>
              view.failedLessonCounts.contains(course.teachingClassId))
          .length,
      onRefresh: () => _load(force: true, fromPull: true),
      canSelectLesson: (entry) =>
          view.hasCompleteAvailability(entry.course) &&
          view.hasPlayableCourse(entry.course),
      onLessonSelected: (entry) => unawaited(_openCourse(entry.course,
          lesson: entry.lesson,
          preparedLessons: view.courseLessons[entry.course.teachingClassId])),
    );
  }

  Widget _courseTile(VodCourse course, RecordingCatalogViewData view) {
    final signature = (
      course,
      view.lessonCounts[course.teachingClassId],
      view.hasCompleteAvailability(course),
      view.failedLessonCounts.contains(course.teachingClassId),
    );
    final cached = _courseRows[course.teachingClassId];
    if (cached?.signature == signature) return cached!.row;
    final unavailable =
        view.hasCompleteAvailability(course) && !view.hasPlayableCourse(course);
    final lessons =
        view.courseLessons[course.teachingClassId] ?? const <VodLesson>[];
    final row = ListTile(
      key: ValueKey('vod-course:${course.teachingClassId}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Tooltip(
        message: course.isLive ? '正在直播' : '录播回放',
        child:
            RecordingStatusIcon(isLive: course.isLive, enabled: !unavailable),
      ),
      title: RecordingCourseTitle(
          course: course,
          maxNameLines: 2,
          missingTeacherLabel: '教师信息暂未提供',
          enabled: !unavailable),
      trailing: unavailable
          ? Icon(Icons.block, color: Theme.of(context).disabledColor)
          : _lessonCount(course, view),
      onTap: unavailable || !view.hasCompleteAvailability(course)
          ? null
          : () => _openCourse(course, preparedLessons: lessons),
    );
    _courseRows[course.teachingClassId] = (signature: signature, row: row);
    return row;
  }

  Widget _lessonCount(VodCourse course, RecordingCatalogViewData view) {
    final count = view.lessonCounts[course.teachingClassId];
    final playable = count?.playable;
    final failed = view.failedLessonCounts.contains(course.teachingClassId);
    final live = course.liveLesson;
    final total = count == null
        ? null
        : count.lessonIds.length +
            (live != null &&
                    live.id > 0 &&
                    live.isLiveAvailable &&
                    !count.lessonIds.contains(live.id)
                ? 1
                : 0);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: count != null
            ? '可观看回放 / 录播、回放生成中和直播课次'
            : failed
                ? '课次统计暂不可用，下拉刷新重试'
                : '正在统计课次',
        child: Text.rich(
          key: ValueKey('vod-course-lesson-count:${course.teachingClassId}'),
          TextSpan(children: [
            TextSpan(
              text: playable == null ? '—' : '$playable',
              style: playable == null
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            TextSpan(text: '/${total ?? '—'}节'),
          ]),
          style: ShuYoTextStyles.meta(color: context.shuyoColors.textSecondary)
              .copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(width: 8),
      if (view.hasCompleteAvailability(course)) const Icon(Icons.chevron_right),
    ]);
  }

  Widget _errorState() {
    final error = _error;
    return EmptyState(
      icon: error is VodPermissionException
          ? Icons.lock_outline
          : Icons.cloud_off_outlined,
      title: error is VodPermissionException ? '暂时无法查看课程' : '课程加载失败',
      message: _errorMessage(),
      action: TextButton.icon(
        onPressed: _loading
            ? null
            : () => _authenticated ? _load(force: true) : _restore(),
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    );
  }

  String _errorMessage() {
    final error = _error;
    return error is VodApiException
        ? error.message
        : error is VodAuthException
            ? error.message
            : '暂时无法连接录播平台，请稍后重试。';
  }
}

class _CourseEntrance extends StatefulWidget {
  const _CourseEntrance({
    super.key,
    required this.index,
    required this.animate,
    required this.child,
  });

  final int index;
  final bool animate;
  final Widget child;

  @override
  State<_CourseEntrance> createState() => _CourseEntranceState();
}

class _CourseEntranceState extends State<_CourseEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<Offset> _position = _entrance
      .drive(CurveTween(curve: Curves.easeOutCubic))
      .drive(Tween(begin: const Offset(0.12, 0), end: Offset.zero));
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _timer?.cancel();
      _entrance.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      if (widget.animate) {
        _timer = Timer(Duration(milliseconds: (widget.index % 6) * 55), () {
          if (mounted) _entrance.forward();
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
        position: _position,
        child: FadeTransition(opacity: _entrance, child: widget.child),
      );
}
