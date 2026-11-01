import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../data/models/vod_search_result.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'recording_course_title.dart';
import 'recording_player_page.dart';
import 'recording_status_icon.dart';
import 'recording_term_menu.dart';

class RecordingSearchPage extends StatefulWidget {
  const RecordingSearchPage({
    super.key,
    required this.repository,
    required this.terms,
    required this.selectedTermId,
    this.onSessionInvalidated,
    this.onLoginRequested,
    this.onSessionExpired,
  });

  final VodRepository repository;
  final List<VodTerm> terms;
  final int selectedTermId;
  final Future<void> Function(bool ssoExpired)? onSessionInvalidated;
  final Future<bool> Function()? onLoginRequested;
  final Future<bool> Function()? onSessionExpired;

  @override
  State<RecordingSearchPage> createState() => _RecordingSearchPageState();
}

class _RecordingSearchPageState extends State<RecordingSearchPage> {
  final _queryController = TextEditingController();
  final _queryFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _collapsedTermYears = <String>{};
  late int _selectedTermId = widget.selectedTermId;
  List<VodSearchResult> _results = const [];
  final _resultsByCourse = <(int, int), List<VodSearchResult>>{};
  final _courseLessons = <(int, int), List<VodLesson>>{};
  final _pendingLessons = <(int, int), List<VodLesson>>{};
  final _courseUpdates = ValueNotifier<int>(0);
  final _courseRows = <(int, int), Widget>{};
  List<VodCourse> _courses = const [];
  int _visibleCourseCount = 0;
  int _availableCourseCount = 0;
  bool _courseUpdateScheduled = false;
  final _animatedCourses = <(int, int)>{};
  String? _activeKeyword;
  Object? _error;
  bool _searching = false;
  bool _loadingCourses = false;
  bool _needsLogin = false;
  bool _loggingIn = false;
  bool _openingLesson = false;
  int _revision = 0;

  @override
  void dispose() {
    _revision++;
    _courseUpdates.dispose();
    _queryController.dispose();
    _queryFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cached rows still follow theme and text scale changes.
    _courseRows.clear();
  }

  void _resetCourses() {
    _courses = const [];
    _visibleCourseCount = 0;
    _availableCourseCount = 0;
    _courseLessons.clear();
    _pendingLessons.clear();
    _courseRows.clear();
    _animatedCourses.clear();
    _courseUpdateScheduled = false;
  }

  void _flushCourseUpdates(int revision) {
    if (!mounted || revision != _revision || _pendingLessons.isEmpty) return;
    _courseLessons.addAll(_pendingLessons);
    _pendingLessons.clear();
    _availableCourseCount =
        _courseLessons.values.where((lessons) => lessons.isNotEmpty).length;
    // Keep search ranking stable even when requests finish out of order.
    while (_visibleCourseCount < _courses.length) {
      final course = _courses[_visibleCourseCount];
      if (!_courseLessons
          .containsKey((course.termId, course.teachingClassId))) {
        break;
      }
      _visibleCourseCount++;
    }
    _courseUpdates.value++;
  }

  void _scheduleCourseUpdate(int revision) {
    if (_courseUpdateScheduled) return;
    _courseUpdateScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      _courseUpdateScheduled = false;
      _flushCourseUpdates(revision);
    });
  }

  void _clearSearch({bool clearField = true}) {
    _revision++;
    if (clearField) _queryController.clear();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _activeKeyword = null;
      _results = const [];
      _resultsByCourse.clear();
      _resetCourses();
      _error = null;
      _searching = false;
      _loadingCourses = false;
    });
  }

  Future<void> _search({bool forceRefresh = false}) async {
    final keyword = _queryController.text.trim();
    if (_needsLogin || _loggingIn) return;
    if (keyword.isEmpty) {
      _clearSearch();
      return;
    }
    if (keyword.runes.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入至少 2 个字的课程、教师或课程号关键词')),
      );
      return;
    }
    _queryFocusNode.unfocus();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final revision = ++_revision;
    setState(() {
      _activeKeyword = keyword;
      _results = const [];
      _resultsByCourse.clear();
      _resetCourses();
      _error = null;
      _searching = true;
      _loadingCourses = false;
    });
    try {
      final results = await widget.repository.searchLessons(
        termId: _selectedTermId,
        keyword: keyword,
      );
      if (!mounted || revision != _revision) return;
      final matchingClasses = <(int, int)>{
        for (final result in results)
          if (_matches(result, keyword))
            (result.course.termId, result.course.teachingClassId),
      };
      setState(() {
        _results = results
            .where((result) => matchingClasses.contains(
                (result.course.termId, result.course.teachingClassId)))
            .toList(growable: false);
        _resultsByCourse.clear();
        for (final result in _results) {
          final course = result.course;
          _resultsByCourse.putIfAbsent(
              (course.termId, course.teachingClassId), () => []).add(result);
        }
        _courses = _resultsByCourse.values
            .map((results) => results
                .firstWhere((result) => _matches(result, keyword),
                    orElse: () => results.first)
                .course)
            .toList(growable: false);
        _searching = false;
        _loadingCourses = _resultsByCourse.isNotEmpty;
      });
      final courses = _courses;
      var nextCourse = 0;
      Future<void> loadNext() async {
        while (
            mounted && revision == _revision && nextCourse < courses.length) {
          final course = courses[nextCourse++];
          List<VodLesson> lessons;
          try {
            lessons = await widget.repository
                .loadPreviewLessons(course, forceRefresh: forceRefresh);
          } on VodSessionExpiredException {
            rethrow;
          } on VodCampusAuthRequiredException {
            rethrow;
          } on Object {
            lessons = const [];
          }
          if (!mounted || revision != _revision) return;
          final catalog = <int, VodLesson>{
            for (final lesson in lessons)
              if (lesson.id > 0 &&
                  !lesson.isLive &&
                  lesson.teachingClassId == course.teachingClassId)
                lesson.id: lesson,
          }.values.toList()
            ..sort((a, b) {
              final byTime = (b.beginTime?.millisecondsSinceEpoch ?? 0)
                  .compareTo(a.beginTime?.millisecondsSinceEpoch ?? 0);
              return byTime == 0 ? b.id.compareTo(a.id) : byTime;
            });
          _pendingLessons[(course.termId, course.teachingClassId)] =
              List.unmodifiable(catalog);
          _scheduleCourseUpdate(revision);
        }
      }

      // Only catalog metadata is parallelized. Video-link warming stays on its
      // independent low-frequency queue and starts after a course is opened.
      await Future.wait(
          [for (var i = 0; i < 3 && i < courses.length; i++) loadNext()],
          eagerError: true);
    } on VodSessionExpiredException catch (error) {
      if (!mounted || revision != _revision) return;
      await _invalidateSession(error.ssoExpired);
    } on VodCampusAuthRequiredException catch (error) {
      if (!mounted || revision != _revision) return;
      await _invalidateSession(error.ssoExpired);
    } on Object catch (error) {
      if (mounted && revision == _revision) setState(() => _error = error);
    } finally {
      if (mounted && revision == _revision) {
        _flushCourseUpdates(revision);
        setState(() {
          _searching = false;
          _loadingCourses = false;
        });
      }
    }
  }

  Future<void> _invalidateSession(bool ssoExpired) async {
    _revision++;
    setState(() {
      _needsLogin = true;
      _searching = false;
      _loadingCourses = false;
      _results = const [];
      _resultsByCourse.clear();
      _resetCourses();
      _error = null;
    });
    await widget.onSessionInvalidated?.call(ssoExpired);
  }

  Future<void> _login() async {
    final callback = widget.onLoginRequested;
    if (callback == null || _loggingIn) return;
    final revision = ++_revision;
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    var succeeded = false;
    try {
      succeeded = await callback();
      if (!mounted || revision != _revision) return;
      setState(() => _needsLogin = !succeeded);
    } on Object catch (error) {
      if (mounted && revision == _revision) setState(() => _error = error);
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _loggingIn = false);
      }
    }
    if (mounted && revision == _revision && succeeded) await _search();
  }

  Future<void> _chooseTerm() async {
    final termId = await showRecordingTermMenu(
      context,
      terms: widget.terms,
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
    if (!mounted || termId == null || termId == _selectedTermId) return;
    setState(() => _selectedTermId = termId);
    _clearSearch(clearField: false);
  }

  bool _matches(VodSearchResult result, String keyword) {
    final query = keyword.trim().toLowerCase();
    if (query.isEmpty) return false;
    final course = result.course;
    return [
      course.name,
      course.teachingClassName,
      course.code,
      result.courseNumber,
      ...course.teacherNames,
    ].any((value) => value.toLowerCase().contains(query));
  }

  Future<void> _refreshCourses() async {
    if (_needsLogin || _searching || _loadingCourses || _results.isEmpty) {
      return;
    }
    await _search(forceRefresh: true);
  }

  Future<void> _openCourse(VodCourse course) async {
    if (_openingLesson || _needsLogin) return;
    final lessons = _courseLessons[(course.termId, course.teachingClassId)];
    if (lessons == null || lessons.isEmpty) return;
    final initial = lessons.where((lesson) => lesson.canPlay).firstOrNull;
    _openingLesson = true;
    unawaited(widget.repository.warmCourseRecordings(course, lessons));
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingPlayerPage(
          course: course,
          term: widget.terms
              .where((term) => term.id == course.termId)
              .firstOrNull,
          initialLesson: initial,
          lessons: lessons,
          loadCourseCatalog: false,
          loadPreviewCatalog: true,
          skipInitialCatalogLoad: true,
          repository: widget.repository,
          onSessionExpired: _recoverPlaybackSession,
        ),
      ));
    } finally {
      _openingLesson = false;
    }
  }

  Future<bool> _recoverPlaybackSession() async {
    _revision++;
    if (mounted) {
      setState(() {
        _results = const [];
        _resultsByCourse.clear();
        _resetCourses();
        _activeKeyword = null;
        _error = null;
        _searching = false;
        _loadingCourses = false;
        _needsLogin = true;
      });
    }
    final recovered = await widget.onSessionExpired?.call() ?? false;
    if (mounted) setState(() => _needsLogin = !recovered);
    return recovered;
  }

  @override
  Widget build(BuildContext context) {
    final selectedTerm =
        widget.terms.where((term) => term.id == _selectedTermId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索录播'),
        actions: [
          IconButton(
            key: const ValueKey('vod-search-term-filter'),
            tooltip: '选择搜索学期',
            onPressed: widget.terms.isEmpty || _loggingIn ? null : _chooseTerm,
            icon: const Icon(Icons.format_list_bulleted),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _searching || _loadingCourses || _loggingIn
              ? const LinearProgressIndicator(
                  key: ValueKey('vod-search-progress'), minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('vod-search-query'),
                controller: _queryController,
                focusNode: _queryFocusNode,
                readOnly: _loggingIn,
                onTapOutside: (_) => _queryFocusNode.unfocus(),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_search()),
                onChanged: (value) {
                  if (value.isEmpty) {
                    _clearSearch(clearField: false);
                  } else {
                    setState(() {});
                  }
                },
                decoration: InputDecoration(
                  labelText: '课程 / 教师 / 课程号关键词',
                  suffixIcon: _queryController.text.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('vod-search-clear'),
                          tooltip: '清空关键词',
                          onPressed: _loggingIn ? null : _clearSearch,
                          icon: const Icon(Icons.clear),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              key: const ValueKey('vod-search-submit'),
              tooltip: '开始搜索',
              onPressed: _needsLogin ||
                      _loggingIn ||
                      _queryController.text.trim().isEmpty
                  ? null
                  : _search,
              icon: Icon(Icons.search,
                  color: Theme.of(context).colorScheme.primary),
            ),
          ]),
        ),
        ValueListenableBuilder<int>(
          valueListenable: _courseUpdates,
          builder: (context, _, __) => _buildSummary(selectedTerm),
        ),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: _courseUpdates,
            builder: (context, _, __) => _buildResults(),
          ),
        ),
      ]),
    );
  }

  Widget _buildSummary(VodTerm? term) {
    final colors = context.shuyoColors;
    final primary = Theme.of(context).colorScheme.primary;
    Widget number(String key, int value, Color color, double size) => Text(
          '$value',
          key: ValueKey(key),
          maxLines: 1,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
    return Padding(
      key: const ValueKey('vod-search-summary'),
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: Column(
            key: const ValueKey('vod-search-term-label'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (term != null) ...[
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    term.academicYear.isEmpty
                        ? term.name
                        : '${term.academicYear} 学年',
                    key: const ValueKey('vod-search-year-label'),
                    maxLines: 1,
                    style:
                        ShuYoTextStyles.bodyCompact(color: colors.textPrimary)
                            .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (term.academicYear.isNotEmpty)
                  Text(
                    term.seasonLabel,
                    key: const ValueKey('vod-search-season-label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.bodyCompact(color: primary)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('课程数',
                      style: TextStyle(color: colors.textMuted, fontSize: 12)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      number('vod-search-loaded-count', _availableCourseCount,
                          primary, 26),
                      Text('/',
                          style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                      number('vod-search-total-count', _resultsByCourse.length,
                          colors.textPrimary, 18),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildResults() {
    Widget? state;
    if (_needsLogin) {
      state = EmptyState(
        icon: Icons.login,
        title: '校园账户登录已失效',
        message: _error == null ? '重新登录后继续搜索录播。' : _errorMessage(),
        action: FilledButton.icon(
          onPressed:
              _loggingIn || widget.onLoginRequested == null ? null : _login,
          icon: const Icon(Icons.login),
          label: Text(_loggingIn ? '正在登录' : '重新登录'),
        ),
      );
    } else if (_error != null) {
      state = EmptyState(
        icon: _error is VodPermissionException
            ? Icons.lock_outline
            : Icons.cloud_off_outlined,
        title: '录播搜索失败',
        message: _errorMessage(),
        action: TextButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      );
    } else if (_searching) {
      state = const Center(child: Text('正在搜索录播…'));
    } else if (_loadingCourses && _visibleCourseCount == 0) {
      state = const Center(child: Text('正在加载课程…'));
    } else if (_results.isEmpty) {
      state = EmptyState(
        icon: _activeKeyword == null ? Icons.search : Icons.search_off,
        title: _activeKeyword == null ? '搜索课程、教师或课程号' : '没有找到录播',
        message: _activeKeyword == null
            ? '输入课程、教师或课程号关键词后点击搜索。'
            : '试试其他关键词，或切换学期后搜索。',
      );
    }
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
            context.shuyoColors.textMuted.withValues(alpha: 0.55)),
        thickness: const WidgetStatePropertyAll(2.5),
        radius: const Radius.circular(4),
      ),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        interactive: true,
        child: RefreshIndicator(
          onRefresh: _refreshCourses,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            key: const ValueKey('vod-search-results'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (state != null)
                SliverFillRemaining(hasScrollBody: false, child: state)
              else ...[
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList.builder(
                  itemCount: _visibleCourseCount == 0
                      ? 0
                      : _visibleCourseCount * 2 - 1,
                  itemBuilder: (context, index) {
                    if (index.isOdd) {
                      return const Divider(indent: 16, endIndent: 16);
                    }
                    final course = _courses[index ~/ 2];
                    final key = (course.termId, course.teachingClassId);
                    final row =
                        _courseRows.putIfAbsent(key, () => _courseTile(course));
                    return _SearchCourseEntrance(
                      key: ValueKey(
                          'vod-search-entrance:$_revision:${course.termId}:${course.teachingClassId}'),
                      animate: _animatedCourses.add(key),
                      child: row,
                    );
                  },
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _courseTile(VodCourse course) {
    final key = (course.termId, course.teachingClassId);
    final enabled = _courseLessons[key]?.isNotEmpty ?? false;
    final courseResults = _resultsByCourse[key]!;
    final result =
        courseResults.firstWhere((result) => identical(result.course, course));
    final query = (_activeKeyword ?? '').toLowerCase();
    final extraMatches = [
      if (course.teachingClassName.isNotEmpty &&
          course.teachingClassName != course.name &&
          course.teachingClassName.toLowerCase().contains(query))
        course.teachingClassName,
      if (result.courseNumber.isNotEmpty &&
          result.courseNumber != course.code &&
          result.courseNumber.toLowerCase().contains(query))
        result.courseNumber,
    ];
    return ListTile(
      key: ValueKey(
          'vod-search-course:${course.termId}:${course.teachingClassId}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      enabled: enabled,
      leading: Tooltip(
        message: course.isLive ? '正在直播' : '录播回放',
        child: RecordingStatusIcon(isLive: course.isLive, enabled: enabled),
      ),
      title: RecordingCourseTitle(
          course: course,
          enabled: enabled,
          maxNameLines: 2,
          missingTeacherLabel: '教师信息暂未提供',
          description: extraMatches.isEmpty
              ? null
              : Text(extraMatches.join(' · '),
                  style: ShuYoTextStyles.meta(
                      color: enabled
                          ? context.shuyoColors.textSecondary
                          : Theme.of(context).disabledColor))),
      trailing: enabled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_courseLessons[key]!.length}节',
                    key: ValueKey(
                        'vod-search-lesson-count:${course.termId}:${course.teachingClassId}'),
                    style: ShuYoTextStyles.meta(
                            color: Theme.of(context).colorScheme.primary)
                        .copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            )
          : Icon(Icons.block, color: Theme.of(context).disabledColor),
      onTap: enabled ? () => unawaited(_openCourse(course)) : null,
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

class _SearchCourseEntrance extends StatefulWidget {
  const _SearchCourseEntrance({
    super.key,
    required this.animate,
    required this.child,
  });

  final bool animate;
  final Widget child;

  @override
  State<_SearchCourseEntrance> createState() => _SearchCourseEntranceState();
}

class _SearchCourseEntranceState extends State<_SearchCourseEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.animate ? 0 : 1,
  );
  late final Animation<double> _opacity =
      _controller.drive(CurveTween(curve: Curves.easeOutCubic));
  late final Animation<Offset> _position =
      _opacity.drive(Tween(begin: const Offset(.12, 0), end: Offset.zero));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value < 1) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SlideTransition(
        position: _position,
        child: FadeTransition(opacity: _opacity, child: widget.child),
      );
}
