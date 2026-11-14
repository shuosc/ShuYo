import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'recording_search_controller.dart';
import 'recording_list_presentation.dart';
import 'recording_course_title.dart';
import 'recording_player_page.dart';
import 'recording_lesson_selection.dart';
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
    this.onWebVpnSessionExpired,
  });

  final VodRepository repository;
  final List<VodTerm> terms;
  final int selectedTermId;
  final Future<void> Function(bool ssoExpired)? onSessionInvalidated;
  final Future<bool> Function()? onLoginRequested;
  final Future<bool> Function()? onSessionExpired;
  final Future<bool> Function()? onWebVpnSessionExpired;

  @override
  State<RecordingSearchPage> createState() => _RecordingSearchPageState();
}

class _RecordingSearchPageState extends State<RecordingSearchPage> {
  final _queryController = TextEditingController();
  final _queryState = ValueNotifier((hasText: false, hasKeyword: false));
  final _queryFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _searchBusy = ValueNotifier(false);
  final _searchNeedsLogin = ValueNotifier(false);
  final _collapsedTermYears = <String>{};
  late final _searchController = RecordingSearchController(widget.repository,
      selectedTermId: widget.selectedTermId,
      onSessionInvalidated: widget.onSessionInvalidated);
  late RecordingSearchViewData _view =
      RecordingSearchViewData(_searchController);
  final _courseRows = <(int, int), (VodCourse, List<VodLesson>?, Widget)>{};
  final _animatedCourses = <(int, int)>{};
  ThemeData? _rowTheme;
  int _renderedRevision = -1;
  int get _selectedTermId => _view.selectedTermId;
  int get _visibleCourseCount => _view.visibleCourseCount;
  int get _availableCourseCount => _view.availableCourseCount;
  String? get _activeKeyword => _view.activeKeyword;
  Object? get _error => _view.error;
  bool get _searching => _view.searching;
  bool get _loadingCourses => _view.loadingCourses;
  bool get _needsLogin => _view.needsLogin;
  bool _loggingIn = false;
  bool _recoveringWebVpn = false;
  bool _openingLesson = false;
  int get _revision => _searchController.revision;

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_updateQueryState);
    _searchController.addListener(_updateSearchChrome);
    _updateSearchChrome();
  }

  void _updateQueryState() {
    final text = _queryController.text;
    _queryState.value =
        (hasText: text.isNotEmpty, hasKeyword: text.trim().isNotEmpty);
  }

  void _updateSearchChrome() {
    _searchBusy.value = _searchController.searching ||
        _searchController.loadingCourses ||
        _recoveringWebVpn;
    _searchNeedsLogin.value = _searchController.needsLogin;
  }

  @override
  void dispose() {
    _searchController.removeListener(_updateSearchChrome);
    _searchController.dispose();
    _searchBusy.dispose();
    _searchNeedsLogin.dispose();
    _queryController.removeListener(_updateQueryState);
    _queryState.dispose();
    _queryController.dispose();
    _queryFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cached tiles capture theme colors, but text and layout descendants
    // subscribe to their own media settings (including text scaling). An IME
    // inset change must not invalidate every cached row.
    final theme = Theme.of(context);
    if (_rowTheme != theme) {
      _rowTheme = theme;
      _courseRows.clear();
    }
  }

  void _clearSearch({bool clearField = true}) {
    if (clearField) _queryController.clear();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _searchController.clear();
  }

  Future<void> _search({bool forceRefresh = false}) async {
    final keyword = _queryController.text.trim();
    if (_searchController.needsLogin || _loggingIn) return;
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
    await _searchController.search(keyword, forceRefresh: forceRefresh);
  }

  /// The search button is the only manual refresh entry point: repeating a
  /// keyword re-reads the server instead of reusing cached lesson metadata.
  void _submitSearch() {
    unawaited(_search(forceRefresh: _searchController.activeKeyword != null));
  }

  Future<void> _login() async {
    final callback = widget.onLoginRequested;
    if (callback == null || _loggingIn) return;
    _searchController.clear(requireLogin: true);
    final revision = _revision;
    setState(() {
      _loggingIn = true;
      _searchController.error = null;
    });
    var succeeded = false;
    try {
      succeeded = await callback();
      if (!mounted || revision != _revision) return;
      _searchController.sessionRecovered(succeeded);
    } on Object catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _searchController.error = error);
      }
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
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _searchController.selectTerm(termId);
  }

  Future<void> _openCourse(VodCourse course, List<VodLesson> lessons,
      {required int revision}) async {
    if (_openingLesson ||
        revision != _searchController.revision ||
        _searchController.needsLogin ||
        course.termId != _searchController.selectedTermId) {
      return;
    }
    final key = (course.termId, course.teachingClassId);
    // A preview can finish after this row was built but before its next frame.
    // Resolve the selection at tap time instead of using the cached row data.
    lessons = _searchController.courseLessons[key] ?? lessons;
    course = _searchController.courses
            .where((item) => (item.termId, item.teachingClassId) == key)
            .firstOrNull ??
        course;
    if (lessons.isEmpty) return;
    final pendingPreview = _searchController.pendingLivePreview(key);
    final selectable = lessons.where(recordingLessonCanSelect);
    final initial =
        selectable.where((lesson) => lesson.isLiveAvailable).firstOrNull ??
            selectable
                .where((lesson) => !lesson.isLive && lesson.isPlayable)
                .firstOrNull ??
            selectable.firstOrNull;
    if (initial == null) return;
    _openingLesson = true;
    final recordings = lessons
        .where((lesson) => !lesson.isLive && !lesson.isGenerating)
        .toList(growable: false);
    if (recordings.isNotEmpty) {
      unawaited(widget.repository.warmCourseRecordings(course, recordings));
    }
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
          skipInitialCatalogLoad: pendingPreview == null,
          initialPreviewCatalog: pendingPreview,
          repository: widget.repository,
          onSessionExpired: _recoverPlaybackSession,
          onWebVpnSessionExpired: widget.onWebVpnSessionExpired,
        ),
      ));
    } finally {
      _openingLesson = false;
    }
  }

  Future<bool> _recoverPlaybackSession() async {
    _searchController.clear(requireLogin: true);
    final recovered = await widget.onSessionExpired?.call() ?? false;
    if (mounted) _searchController.sessionRecovered(recovered);
    return recovered;
  }

  Future<void> _recoverWebVpnSession() async {
    final recover = widget.onWebVpnSessionExpired;
    if (recover == null || _recoveringWebVpn) return;
    final revision = _revision;
    setState(() => _recoveringWebVpn = true);
    _updateSearchChrome();
    try {
      final recovered = await recover();
      if (!mounted || revision != _revision || !recovered) return;
      await _search();
    } on Object {
      // Keep the connection failure available for another explicit attempt.
    } finally {
      if (mounted) {
        setState(() => _recoveringWebVpn = false);
        _updateSearchChrome();
      }
    }
  }

  @override
  Widget build(BuildContext context) => _buildScaffold();

  Widget _buildScaffold() {
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
          child: ValueListenableBuilder<bool>(
            valueListenable: _searchBusy,
            builder: (context, busy, _) => busy || _loggingIn
                ? const LinearProgressIndicator(
                    key: ValueKey('vod-search-progress'), minHeight: 3)
                : const SizedBox(height: 3),
          ),
        ),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: ListenableBuilder(
            // Editing values also change for cursor, selection and IME
            // composition updates. Those do not change either button's state.
            listenable: Listenable.merge([_queryState, _searchNeedsLogin]),
            builder: (context, child) => Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('vod-search-query'),
                  controller: _queryController,
                  focusNode: _queryFocusNode,
                  readOnly: _loggingIn,
                  onTapOutside: (_) => _queryFocusNode.unfocus(),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submitSearch(),
                  onChanged: (value) {
                    if (value.isEmpty) {
                      _clearSearch(clearField: false);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: '课程 / 教师 / 课程号',
                    suffixIcon: !_queryState.value.hasText
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
                onPressed: _searchNeedsLogin.value ||
                        _loggingIn ||
                        !_queryState.value.hasKeyword
                    ? null
                    : _submitSearch,
                icon: Icon(Icons.search,
                    color: Theme.of(context).colorScheme.primary),
              ),
            ]),
          ),
        ),
        Expanded(
          child: RecordingListPresentation(
            changes: _searchController,
            shouldUpdateImmediately: () => _renderedRevision != _revision,
            builder: (context) {
              // One frozen revision drives both the summary and lazy rows.
              // Business completions never rebuild the AppBar or search input.
              _view = RecordingSearchViewData(_searchController);
              if (_renderedRevision != _revision) {
                _renderedRevision = _revision;
                _courseRows.clear();
                _animatedCourses.clear();
              }
              final selectedTerm = widget.terms
                  .where((term) => term.id == _selectedTermId)
                  .firstOrNull;
              return Column(children: [
                _buildSummary(selectedTerm),
                Expanded(child: _buildResults()),
              ]);
            },
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
                      number('vod-search-total-count', _view.totalCourseCount,
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
    final view = _view;
    final loadedCourses = view.courses;
    // A course is playable once its lessons contain a selectable episode.
    final courses = [
      for (final course in loadedCourses)
        if (view.courseLessons[(course.termId, course.teachingClassId)]
                ?.any(recordingLessonCanSelect) ??
            false)
          course,
    ];
    // A preview can insert a course before rows that are already on screen.
    // Let the sliver relocate their keyed elements instead of disposing their
    // entrance animations and rebuilding the rows at their new indexes.
    late final courseIndices = <Key, int>{
      for (var i = 0; i < courses.length; i++)
        ValueKey(
                (view.revision, courses[i].termId, courses[i].teachingClassId)):
            i * 2,
    };
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
      final webVpnSession = _error is VodWebVpnSessionExpiredException ||
          _error is VodWebVpnAuthRequiredException;
      state = EmptyState(
        icon: _error is VodPermissionException
            ? Icons.lock_outline
            : Icons.cloud_off_outlined,
        title: '录播搜索失败',
        message: _errorMessage(),
        action: TextButton.icon(
          onPressed: _recoveringWebVpn ||
                  webVpnSession && widget.onWebVpnSessionExpired == null
              ? null
              : webVpnSession
                  ? _recoverWebVpnSession
                  : _search,
          icon: Icon(webVpnSession ? Icons.vpn_key_outlined : Icons.refresh),
          label: Text(webVpnSession ? '恢复连接' : '重试'),
        ),
      );
    } else if (_searching) {
      state = const Center(child: Text('正在搜索录播…'));
    } else if (_loadingCourses && _visibleCourseCount == 0) {
      state = const Center(child: Text('正在加载课程…'));
    } else if (_visibleCourseCount > 0 && courses.isEmpty) {
      state = const EmptyState(
        icon: Icons.play_disabled_outlined,
        title: '没有可播放的课程',
        message: '搜索到的课程当前暂无可播放内容。',
      );
    } else if (!_view.hasResults) {
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
                findChildIndexCallback: (key) => courseIndices[key],
                itemCount: courses.isEmpty ? 0 : courses.length * 2 - 1,
                itemBuilder: (context, index) {
                  if (index.isOdd) {
                    return const Divider(indent: 16, endIndent: 16);
                  }
                  final course = courses[index ~/ 2];
                  final key = (course.termId, course.teachingClassId);
                  final lessons = view.courseLessons[key];
                  final cached = _courseRows[key];
                  final row = cached != null &&
                          identical(cached.$1, course) &&
                          identical(cached.$2, lessons)
                      ? cached.$3
                      : _courseTile(course, view);
                  _courseRows[key] = (course, lessons, row);
                  final firstAppearance = _animatedCourses.add(key);
                  final scrolling = _scrollController.hasClients &&
                      _scrollController.position.isScrollingNotifier.value;
                  return _SearchCourseEntrance(
                    key: ValueKey(
                        (view.revision, course.termId, course.teachingClassId)),
                    // The first page still enters normally. Creating a new
                    // opacity/translation animation for each row during a
                    // drag or fling adds compositing work to every frame.
                    animate: firstAppearance && !scrolling,
                    child: row,
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _courseTile(VodCourse course, RecordingSearchViewData view) {
    final key = (course.termId, course.teachingClassId);
    final lessons = view.courseLessons[key] ?? const <VodLesson>[];
    final enabled = lessons.any(recordingLessonCanSelect);
    final description = view.extraMatches[key] ?? '';
    // Rows are cached across incremental updates. Capture just the revision,
    // not the entire immutable snapshot and all of its course/lesson maps.
    final revision = view.revision;
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
          description: description.isEmpty
              ? null
              : Text(description,
                  style: ShuYoTextStyles.meta(
                      color: enabled
                          ? context.shuyoColors.textSecondary
                          : Theme.of(context).disabledColor))),
      trailing: enabled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${lessons.length}节',
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
      onTap: enabled
          ? () => unawaited(_openCourse(course, lessons, revision: revision))
          : null,
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
  late final AnimationController? _controller = widget.animate
      ? AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )
      : null;
  late final Animation<double> _opacity =
      _controller!.drive(CurveTween(curve: Curves.easeOutCubic));
  late final Animation<Offset> _position =
      _opacity.drive(Tween(begin: const Offset(.12, 0), end: Offset.zero));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = _controller;
    if (controller == null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = 1;
    } else if (!controller.isAnimating && controller.value < 1) {
      controller.forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : SlideTransition(
          position: _position,
          child: FadeTransition(opacity: _opacity, child: widget.child),
        );
}
