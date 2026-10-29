import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/academic_progress.dart';
import '../../data/models/academic_ranking.dart';
import '../../data/models/academic_schedule.dart';
import '../../data/models/academic_student_profile.dart';
import '../../data/repositories/academic_progress_repository.dart';
import '../../data/repositories/academic_ranking_repository.dart';
import '../../data/repositories/academic_schedule_repository.dart';
import '../../data/repositories/academic_student_profile_repository.dart';
import '../../data/services/academic_progress_display_settings_service.dart';
import '../../data/services/academic_auth_service.dart';
import '../../data/services/academic_schedule_api_client.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

class AcademicProgressPage extends StatefulWidget {
  const AcademicProgressPage({
    super.key,
    required this.repository,
    required this.onLoginRequired,
    this.rankingRepository,
    this.studentProfileRepository,
    this.scheduleRepository,
    this.active = true,
    this.autoRefreshEnabled = true,
    this.restoreSession,
  });

  final AcademicProgressRepository repository;
  final AcademicRankingRepository? rankingRepository;
  final AcademicStudentProfileRepository? studentProfileRepository;
  final AcademicScheduleRepository? scheduleRepository;
  final bool active;
  final bool autoRefreshEnabled;
  final Future<void> Function()? restoreSession;
  final Future<void> Function() onLoginRequired;

  @override
  State<AcademicProgressPage> createState() => _AcademicProgressPageState();
}

class _AcademicProgressPageState extends State<AcademicProgressPage>
    with SingleTickerProviderStateMixin {
  static const _rootDotX = 10.0;
  static const _nestedDotX = 25.0;
  static const _courseBadgeWidth = 40.0;
  static const _courseInset = 2.0;
  static const _courseTopInset = 9.0;
  static const _courseTitleLineHeight = 24.0;
  // Extend the course ripple left without moving the dot or course text.
  static const _courseTapExtension = 8.0;

  AcademicProgress? _progress;
  AcademicRanking? _ranking;
  AcademicStudentProfile? _studentProfile;
  AcademicTerm? _scheduleTerm;
  final Set<String> _expandedNodes = {};
  bool _loading = true;
  bool _refreshing = false;
  late final AnimationController _creditAnimationController;
  double? _creditAnimationTarget;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _notice;
  bool _showGpa = false;
  bool _showRanking = false;
  bool _showCollegeRanking = true;
  bool _rankingLoading = false;
  String? _rankingError;
  String? _loadError;
  final _displaySettingsService = AcademicProgressDisplaySettingsService();
  late final AcademicRankingRepository _rankingRepository =
      widget.rankingRepository ?? AcademicRankingRepository();
  late final AcademicStudentProfileRepository _studentProfileRepository =
      widget.studentProfileRepository ?? AcademicStudentProfileRepository();
  late final AcademicScheduleRepository _scheduleRepository =
      widget.scheduleRepository ?? AcademicScheduleRepository();
  late final Future<void> _cacheReady;

  @override
  void initState() {
    super.initState();
    _creditAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _cacheReady = Future.wait([
      _loadCached(),
      _loadRankingAndDisplaySettings(),
      _loadStudentProfile(),
      _loadScheduleIdentity(),
    ]).then((_) {});
    if (widget.active && widget.autoRefreshEnabled) {
      unawaited(_refresh(automatic: true));
    }
  }

  @override
  void dispose() {
    _creditAnimationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AcademicProgressPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        widget.autoRefreshEnabled &&
        (!oldWidget.active || !oldWidget.autoRefreshEnabled)) {
      unawaited(_refresh(automatic: true));
    }
  }

  Future<void> _loadScheduleIdentity() async {
    try {
      final schedule = await _scheduleRepository.loadCachedSchedule();
      if (mounted && schedule != null) {
        setState(() => _scheduleTerm = schedule.term);
      }
    } on Object {
      // A damaged timetable cache must not prevent academic data from loading.
    }
  }

  Future<void> _loadStudentProfile() async {
    AcademicStudentProfile? profile;
    try {
      profile = await _studentProfileRepository.loadCachedProfile();
    } on Object {
      // A damaged cache can be replaced by a fresh response.
    }
    if (!mounted) return;
    if (profile != null) {
      setState(() => _studentProfile = profile);
    }
  }

  Future<_AcademicRefreshResult> _refreshStudentProfile({
    bool Function()? canApply,
  }) async {
    try {
      final profile = await _studentProfileRepository.refreshProfile();
      if (mounted && (canApply?.call() ?? true)) {
        setState(() => _studentProfile = profile);
      }
      return _AcademicRefreshResult.success;
    } on AcademicAuthException {
      return _AcademicRefreshResult.loginRequired;
    } on Object {
      // Keep the last available profile when the auxiliary request fails.
      return _AcademicRefreshResult.failed;
    }
  }

  Future<void> _loadRankingAndDisplaySettings() async {
    var showGpa = false;
    var showRanking = false;
    try {
      showGpa = await _displaySettingsService.loadShowGpa();
      showRanking = await _displaySettingsService.loadShowRanking();
    } on Object {
      // Display settings should not prevent cached academic data from loading.
    }
    AcademicRanking? ranking;
    try {
      ranking = await _rankingRepository.loadCachedRanking();
    } on Object {
      // A corrupt ranking cache should not prevent academic data from loading.
    }
    if (!mounted) return;
    setState(() {
      _showGpa = showGpa;
      _showRanking = showRanking;
      _ranking = ranking;
    });
  }

  Future<void> _loadCached() async {
    try {
      final progress = await widget.repository.loadCachedProgress();
      if (!mounted) return;
      setState(() {
        _progress = progress;
        if (progress != null && _expandedNodes.isEmpty) {
          final mainId = progress.mainNode?.id;
          if (mainId != null) _expandedNodes.add(mainId);
        }
        _loadError = null;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh({bool automatic = false}) async {
    if (_refreshing) return;
    _notice?.close();
    _notice = null;
    _creditAnimationController.stop();
    setState(() {
      _refreshing = true;
      _creditAnimationTarget = null;
    });
    try {
      await _cacheReady;
      if (!mounted) return;
      try {
        final restore = widget.restoreSession;
        if (restore != null) {
          await restore();
        } else if (!await AcademicAuthService().restoreAcademicCookies()) {
          throw const AcademicAuthException('请先登录上大校园账户');
        }
      } on AcademicAuthException {
        if (!mounted) return;
        if (widget.active) _showSnack('学业信息同步失败，请重新登录校园账户');
        if (!automatic) await widget.onLoginRequired();
        return;
      } on Object {
        if (mounted && widget.active) _showSnack('学业信息同步失败，请稍后重试');
        return;
      }
      if (!mounted) return;
      // A session failure must not wait for unrelated requests to finish.
      final loginRequired = Completer<void>();
      var sessionFailed = false;
      bool canApply() => !sessionFailed;
      Future<_AcademicRefreshResult> watch(
          Future<_AcademicRefreshResult> request) async {
        final result = await request;
        if (result == _AcademicRefreshResult.loginRequired && !sessionFailed) {
          sessionFailed = true;
          loginRequired.complete();
        }
        return result;
      }

      final requests = [
        watch(_refreshProgress(canApply)),
        watch(_refreshRanking(canApply)),
        watch(_refreshStudentProfile(canApply: canApply)),
      ];
      final results = await Future.any<List<_AcademicRefreshResult>?>([
        Future.wait(requests),
        loginRequired.future.then((_) => null),
      ]);
      if (!mounted) return;
      if (results == null || sessionFailed) {
        if (_rankingLoading) setState(() => _rankingLoading = false);
        if (widget.active) _showSnack('学业信息同步失败，请重新登录校园账户');
        if (!automatic) await widget.onLoginRequired();
        return; // Authentication never resumes this refresh automatically.
      }
      final progressUpdated = results[0] == _AcademicRefreshResult.success;
      final rankingUpdated = results[1] == _AcademicRefreshResult.success;
      final profileUpdated = results[2] == _AcademicRefreshResult.success;
      if (widget.active &&
          progressUpdated &&
          rankingUpdated &&
          profileUpdated) {
        final root = _progress?.mainNode;
        final earned = root?.earnedCredits;
        final required = root?.requiredCredits;
        if (earned != null && required != null && required > 0) {
          setState(
              () => _creditAnimationTarget = (earned / required).clamp(0, 1));
          _creditAnimationController.forward(from: 0);
        }
      }
      if (widget.active &&
          (!progressUpdated || !rankingUpdated || !profileUpdated)) {
        final failed = [
          if (!progressUpdated) '学业信息',
          if (!rankingUpdated) '排名',
          if (!profileUpdated) '学籍信息',
        ];
        _showSnack('${failed.join('、')}获取失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<_AcademicRefreshResult> _refreshProgress(
      bool Function() canApply) async {
    try {
      await _fetchAndShow(canApply);
      return _AcademicRefreshResult.success;
    } on AcademicAuthException {
      return _AcademicRefreshResult.loginRequired;
    } on Object catch (error) {
      if (mounted && canApply() && _progress == null) {
        setState(() => _loadError = '学业信息同步失败：$error');
      }
      return _AcademicRefreshResult.failed;
    }
  }

  Future<_AcademicRefreshResult> _refreshRanking(
      bool Function() canApply) async {
    setState(() {
      _rankingLoading = true;
      _rankingError = null;
    });
    try {
      final ranking = await _rankingRepository.refreshRanking();
      if (mounted && canApply()) setState(() => _ranking = ranking);
      return _AcademicRefreshResult.success;
    } on AcademicAuthException {
      if (mounted && canApply()) setState(() => _rankingError = '登录已失效');
      return _AcademicRefreshResult.loginRequired;
    } on Object {
      if (mounted && canApply()) setState(() => _rankingError = '获取失败');
      return _AcademicRefreshResult.failed;
    } finally {
      if (mounted && canApply()) setState(() => _rankingLoading = false);
    }
  }

  Future<void> _fetchAndShow(bool Function() canApply) async {
    final progress = await widget.repository.refreshProgress();
    if (!mounted || !canApply()) return;
    setState(() {
      _progress = progress;
      final existingIds = progress.nodes.map((node) => node.id).toSet();
      _expandedNodes.removeWhere((id) => !existingIds.contains(id));
      if (_expandedNodes.isEmpty) {
        final mainId = progress.mainNode?.id;
        if (mainId != null) _expandedNodes.add(mainId);
      }
      _loadError = null;
      _loading = false;
    });
  }

  void _showSnack(String message) {
    _notice?.close();
    _notice = ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openMoreMenu() async {
    final action = await showModalBottomSheet<_ProgressMenuAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
        return SafeArea(
          top: false,
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomPadding),
            decoration: BoxDecoration(
              color: context.shuyoColors.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context)
                        .pop(_ProgressMenuAction.displaySettings),
                    child: const ListTile(
                      leading: Icon(Icons.palette_outlined),
                      title: Text('显示设置'),
                    ),
                  ),
                  ListTile(
                    leading: _refreshing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : const Icon(Icons.refresh),
                    title: const Text('刷新学业信息'),
                    enabled: !_refreshing,
                    onTap: () => Navigator.of(context)
                        .pop(_ProgressMenuAction.refreshProgress),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case _ProgressMenuAction.displaySettings:
        await _openDisplaySettings();
      case _ProgressMenuAction.refreshProgress:
        await _refresh();
      case null:
        break;
    }
  }

  Future<void> _openDisplaySettings() async {
    final settings =
        await showModalBottomSheet<({bool showGpa, bool showRanking})>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _ProgressDisplaySettingsSheet(
        showGpa: _showGpa,
        showRanking: _showRanking,
      ),
    );
    if (!mounted || settings == null) return;
    try {
      await _displaySettingsService.saveShowGpa(settings.showGpa);
      await _displaySettingsService.saveShowRanking(settings.showRanking);
      if (!mounted) return;
      final rankingJustEnabled = settings.showRanking && !_showRanking;
      setState(() {
        _showGpa = settings.showGpa;
        _showRanking = settings.showRanking;
        if (rankingJustEnabled) _showCollegeRanking = true;
      });
    } on Object {
      if (mounted) _showSnack('显示设置保存失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('学业'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _refreshing
                ? const LinearProgressIndicator(
                    key: ValueKey('academic-refresh-indicator'),
                    minHeight: 2,
                  )
                : null,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '更多',
            onPressed: _openMoreMenu,
            icon: const Icon(Icons.more_horiz),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    final progress = _progress;
    if (progress == null) {
      return EmptyState(
        icon: Icons.school_outlined,
        title: _loadError == null ? '还没有学业信息' : '读取学业信息失败',
        message: _loadError ?? '登录校园账户后查看',
        action: FilledButton.icon(
          onPressed: _refreshing ? null : _refresh,
          icon: const Icon(Icons.refresh),
          label: Text(_refreshing ? '同步中...' : '同步学业信息'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _overview(progress),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Text('修读情况', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (progress.plannedCourses != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
            child: Text(
              '计划 ${progress.plannedCourses} 门 · 已修 ${progress.passedCourses ?? '—'} 门'
              ' · 在修 ${progress.ongoingCourses ?? '—'} 门 · 未修 ${progress.notTakenCourses ?? '—'} 门',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ..._treeRows(progress, '', 0),
      ],
    );
  }

  List<Widget> _treeRows(
          AcademicProgress progress, String parentId, int depth) =>
      [
        for (final node in progress.childrenOf(parentId))
          _treeNode(progress, node, depth),
      ];

  Widget _treeNode(
      AcademicProgress progress, AcademicProgressNode node, int depth,
      {bool isLastSibling = false}) {
    final colors = context.shuyoColors;
    final expanded = _expandedNodes.contains(node.id);
    final completed = node.passed == true;
    final credits = _creditsText(node);
    final dotX = depth > 0 ? _nestedDotX : _rootDotX;
    final dotSize = depth == 0 ? 13.0 : 10.0;
    final titleStyle = (depth == 0
            ? Theme.of(context).textTheme.bodyLarge
            : Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(
      fontWeight: depth == 0
          ? FontWeight.w600
          : depth == 1
              ? FontWeight.w500
              : FontWeight.w400,
      color: depth >= 2 ? colors.textSecondary : colors.textPrimary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          key: ValueKey('progress-node-${node.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            if (expanded) {
              _expandedNodes.remove(node.id);
            } else {
              _expandedNodes.add(node.id);
            }
          }),
          child: CustomPaint(
            painter: _TreeConnectorPainter(
              color: colors.borderStrong,
              horizontalEnd: depth > 0 ? dotX : null,
              verticalX: expanded ? dotX : null,
              verticalFromCenter: true,
              incomingRailX: depth > 0 ? 0 : null,
              incomingRailStopsAtJunction: isLastSibling,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: [
                  SizedBox(
                    width: dotX + 10,
                    height: 20,
                    child: Stack(
                      children: [
                        Positioned(
                          left: dotX - dotSize / 2,
                          top: 10 - dotSize / 2,
                          child: AnimatedContainer(
                            key: ValueKey('progress-node-dot-${node.id}'),
                            duration: const Duration(milliseconds: 220),
                            width: dotSize,
                            height: dotSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: completed
                                  ? colors.success
                                  : expanded
                                      ? colors.accent
                                      : colors.surface,
                              border: Border.all(
                                color: completed
                                    ? colors.success
                                    : expanded
                                        ? colors.accent
                                        : colors.borderStrong,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(node.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle),
                        if (credits != null) ...[
                          const SizedBox(height: 2),
                          Text(credits,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.textTertiary,
                                  )),
                        ],
                      ],
                    ),
                  ),
                  if (completed)
                    Icon(Icons.check_circle_rounded,
                        size: 15, color: colors.success),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.chevron_right,
                        size: 20, color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        CustomPaint(
          painter: _TreeConnectorPainter(
            color: colors.borderStrong,
            verticalX: depth > 0 && !isLastSibling ? 0 : null,
          ),
          child: _AnimatedProgressBranch(
            key: ValueKey('progress-branch-${node.id}'),
            expanded: expanded,
            child: expanded
                ? _branchChildren(progress, node, depth + 1, railOffset: dotX)
                : null,
          ),
        ),
      ],
    );
  }

  Widget _branchChildren(
      AcademicProgress progress, AcademicProgressNode node, int depth,
      {required double railOffset}) {
    final children = <Widget>[];
    if (node.id == 'zgzsxx') {
      if (progress.certificates.isEmpty) {
        children.add(_emptyRow('暂无资格证书信息', isLastSibling: true));
      } else {
        for (var i = 0; i < progress.certificates.length; i++) {
          children.add(_certificateRow(progress.certificates[i],
              isLastSibling: i == progress.certificates.length - 1));
        }
      }
    } else if (node.isLeaf) {
      if (node.courses.isEmpty) {
        children.add(_emptyRow('该分类暂无课程', isLastSibling: true));
      } else {
        for (var i = 0; i < node.courses.length; i++) {
          children.add(_courseRow(node.courses[i],
              isLastSibling: i == node.courses.length - 1));
        }
      }
    } else {
      final nodes = progress.childrenOf(node.id);
      for (var i = 0; i < nodes.length; i++) {
        children.add(_treeNode(progress, nodes[i], depth,
            isLastSibling: i == nodes.length - 1));
      }
    }
    return Container(
      margin: EdgeInsets.only(left: railOffset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _courseRow(AcademicProgressCourse course,
      {required bool isLastSibling}) {
    final colors = context.shuyoColors;
    final statusColor = _courseStatusColor(course, colors);
    return CustomPaint(
      painter: _TreeConnectorPainter(
        color: colors.borderStrong,
        horizontalEnd: _courseInset + _courseBadgeWidth / 2,
        horizontalY: _courseTopInset + _courseTitleLineHeight / 2,
        incomingRailX: 0,
        incomingRailStopsAtJunction: isLastSibling,
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                  width: _courseInset +
                      _courseBadgeWidth +
                      3 -
                      _courseTapExtension),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: ValueKey('progress-course-${course.id}'),
                    onTap: () => _showCourseDetails(course),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(6 + _courseTapExtension,
                          _courseTopInset + 2, 4, _courseTopInset + 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(course.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w400)),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    if (course.nature.isNotEmpty) course.nature,
                                    if (course.credits.isNotEmpty)
                                      '${course.credits} 学分',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: colors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              size: 17, color: colors.textMuted),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: _courseInset,
            top: _courseTopInset,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showCourseDetails(course),
              child: SizedBox(
                width: _courseBadgeWidth,
                child: Column(
                  children: [
                    SizedBox(
                      height: _courseTitleLineHeight,
                      child: Center(
                        child: Container(
                          key: ValueKey('progress-course-dot-${course.id}'),
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                              color: statusColor, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                    Text(_compactStatusLabel(course),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: statusColor, fontSize: 10)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _certificateRow(AcademicCertificate certificate,
      {required bool isLastSibling}) {
    final colors = context.shuyoColors;
    return CustomPaint(
      painter: _TreeConnectorPainter(
        color: colors.borderStrong,
        horizontalEnd: 22,
        horizontalY: 22,
        incomingRailX: 0,
        incomingRailStopsAtJunction: isLastSibling,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
        child: Row(
          children: [
            Icon(Icons.workspace_premium_outlined,
                size: 20, color: colors.accent),
            const SizedBox(width: 10),
            Expanded(child: Text(certificate.name)),
            if (certificate.acquisitionStatus.isNotEmpty)
              Text(certificate.acquisitionStatus,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _emptyRow(String message, {required bool isLastSibling}) {
    final colors = context.shuyoColors;
    return CustomPaint(
      painter: _TreeConnectorPainter(
        color: colors.borderStrong,
        horizontalEnd: 14,
        horizontalY: 22,
        incomingRailX: 0,
        incomingRailStopsAtJunction: isLastSibling,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 2, 14),
        child: Text(message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                )),
      ),
    );
  }

  Color _courseStatusColor(AcademicProgressCourse course, ShuYoColors colors) =>
      switch (course.status) {
        '4' || '21' => colors.success,
        '1' => colors.accent,
        '2' => colors.danger,
        '3' => colors.textMuted,
        _ => colors.warning,
      };

  String _compactStatusLabel(AcademicProgressCourse course) =>
      switch (course.status) {
        '5' || '6' || '7' || '8' || '9' => '认定',
        '1' || '2' || '3' || '4' || '21' => course.statusLabel,
        _ => '其他',
      };

  Widget _overview(AcademicProgress progress) {
    final root = progress.mainNode;
    final earned = root?.earnedCredits;
    final required = root?.requiredCredits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _studentBanner(progress),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: Text('学业总览', style: Theme.of(context).textTheme.titleMedium),
        ),
        Row(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                IntrinsicWidth(
                  key: const ValueKey('academic-credit-value-box'),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: earned == null ? '—' : _number(earned),
                            style: TextStyle(color: context.shuyoColors.accent),
                          ),
                          TextSpan(
                              text:
                                  '/${required == null ? '—' : _number(required)}'),
                        ]),
                        key: const ValueKey('academic-credit-value'),
                        maxLines: 1,
                        textWidthBasis: TextWidthBasis.longestLine,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text('学分', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            if (earned != null && required != null && required > 0) ...[
              const SizedBox(width: 10),
              Expanded(
                child: AnimatedBuilder(
                  animation: _creditAnimationController,
                  builder: (context, child) => LinearProgressIndicator(
                    key: const ValueKey('academic-credit-progress'),
                    value: _creditAnimationTarget == null
                        ? (earned / required).clamp(0, 1)
                        : _creditAnimationTarget! *
                            Curves.easeOutCubic
                                .transform(_creditAnimationController.value),
                    minHeight: 7,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (_showGpa || _showRanking) ...[
          const Divider(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showGpa)
                Expanded(
                  child: _metric('平均绩点', _gpaText(progress.gpa),
                      suffix: '/4.0',
                      valueBoxKey: const ValueKey('academic-gpa-value-box'),
                      valueKey: const ValueKey('academic-gpa-value')),
                ),
              if (_showRanking) Expanded(child: _rankingMetric()),
            ],
          ),
        ],
      ],
    );
  }

  Widget _studentBanner(AcademicProgress progress) {
    final profile = _studentProfile?.studentId == progress.studentId
        ? _studentProfile
        : null;
    final ranking = _ranking?.studentId == progress.studentId ? _ranking : null;
    final details = [
      if ((profile?.majorName ?? ranking?.majorName ?? '').trim().isNotEmpty)
        (profile?.majorName ?? ranking!.majorName).trim(),
      if ((profile?.collegeName ?? ranking?.collegeName ?? '')
          .trim()
          .isNotEmpty)
        (profile?.collegeName ?? ranking!.collegeName).trim(),
    ];
    final profileName = profile?.studentName.trim() ?? '';
    final scheduleName = progress.studentId.isNotEmpty &&
            _scheduleTerm?.studentId == progress.studentId
        ? _scheduleTerm!.studentName.trim()
        : '';
    final name = profileName.isNotEmpty ? profileName : scheduleName;
    final category = profile?.studentCategory ?? '';
    final colors = context.shuyoColors;
    final customBackground = CustomBackgroundScope.maybeOf(context) != null;
    final lightCard =
        !customBackground && colors.brightness == Brightness.light;
    final surface = customBackground
        ? colors.surface.withValues(alpha: 0.72)
        : lightCard
            ? const Color(0xFFFFFEFC)
            : colors.surface;
    return Card(
      key: const ValueKey('student-info-card'),
      margin: EdgeInsets.zero,
      color: surface,
      elevation: lightCard ? 0.5 : 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.school_outlined, size: 32, color: colors.textSecondary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (name.isNotEmpty || category.isNotEmpty) ...[
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (name.isNotEmpty)
                          Text(name,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  )),
                        if (category.isNotEmpty)
                          _StudentCategoryBadge(label: category),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(progress.studentId,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          )),
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(details.join(' · '),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colors.textSecondary,
                            )),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _gpaText(String value) {
    final number = double.tryParse(value);
    return number != null && number.isFinite ? number.toStringAsFixed(2) : '—';
  }

  Widget _metric(String label, String value,
      {String suffix = '',
      Key? valueKey,
      Key? valueBoxKey,
      Alignment alignment = Alignment.centerLeft,
      IconData? leadingIcon}) {
    final style = Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ) ??
        const TextStyle(
            fontSize: 24, fontFeatures: [FontFeature.tabularFigures()]);
    final labelStyle = Theme.of(context).textTheme.bodySmall;
    Size measure(String text, TextStyle? textStyle) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    // Fixed reference widths keep fitting independent of the displayed digits.
    final numberSize = measure('88888/88888', style);
    final labelWidth = [
      measure('平均绩点', labelStyle).width,
      measure('学院排名', labelStyle).width,
      measure('专业排名', labelStyle).width,
    ].reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: numberSize.height,
      child: Align(
        alignment: alignment,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leadingIcon != null) ...[
                Icon(leadingIcon,
                    size: 14, color: context.shuyoColors.textSecondary),
                const SizedBox(width: 4),
              ],
              SizedBox(
                width: labelWidth,
                child: Text(label, style: labelStyle, maxLines: 1),
              ),
              const SizedBox(width: 8),
              SizedBox(
                key: valueBoxKey,
                width: numberSize.width,
                height: numberSize.height,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: value),
                    if (suffix.isNotEmpty)
                      TextSpan(
                        text: suffix,
                        style:
                            TextStyle(color: context.shuyoColors.textSecondary),
                      ),
                  ]),
                  key: valueKey,
                  textAlign: TextAlign.left,
                  maxLines: 1,
                  style: style,
                ),
              ),
              // Match the ranking row's icon width so both use the same scale.
              if (leadingIcon == null) const SizedBox(width: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rankingMetric() {
    final colors = context.shuyoColors;
    final ranking = _ranking;
    final college = _showCollegeRanking;
    final rank = college ? ranking?.collegeRank : ranking?.majorRank;
    final count = college ? ranking?.collegeCount : ranking?.majorCount;
    final label = college ? '学院排名' : '专业排名';
    final value = rank == null ? '—' : '$rank';
    final suffix = rank != null && count != null ? '/$count' : '';
    final status = _rankingLoading && ranking == null
        ? '获取中'
        : _rankingError != null
            ? ranking == null
                ? '获取失败'
                : '旧数据'
            : rank == null
                ? '暂无排名'
                : '';
    return Semantics(
      button: true,
      label: '$label${rank == null ? '' : '第$rank名'}'
          '${count == null ? '' : '，共$count人'}',
      child: GestureDetector(
        key: const ValueKey('academic-ranking-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_rankingError != null && ranking == null) {
            unawaited(_refresh());
          } else {
            setState(() => _showCollegeRanking = !_showCollegeRanking);
          }
        },
        child: Tooltip(
          message: ranking == null
              ? _rankingError == null
                  ? '点击切换学院和专业排名'
                  : '点击重新同步学业信息'
              : '${ranking.academicYear} ${ranking.term} · 点击切换学院和专业排名',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              _metric(label, value,
                  suffix: suffix,
                  alignment: Alignment.centerRight,
                  leadingIcon: Icons.swap_horiz,
                  valueBoxKey: const ValueKey('academic-ranking-value-box'),
                  valueKey: const ValueKey('academic-ranking-value')),
              if (status.isNotEmpty)
                Text(status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _rankingError == null
                              ? colors.textSecondary
                              : colors.warning,
                        )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCourseDetails(AcademicProgressCourse course) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
        builder: (context) => SafeArea(
          top: false,
          bottom: false,
          child: Container(
            key: const ValueKey('progress-course-sheet'),
            width: double.infinity,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            decoration: BoxDecoration(
              color: context.shuyoColors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22,
                  10,
                  22,
                  28 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.shuyoColors.borderStrong,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(course.name,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color:
                                _courseStatusColor(course, context.shuyoColors),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(course.statusLabel,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: _courseStatusColor(
                                          course, context.shuyoColors),
                                    )),
                        if (course.credits.isNotEmpty) ...[
                          const SizedBox(width: 14),
                          Text('${course.credits} 学分',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ],
                    ),
                    const SizedBox(height: 18),
                    Divider(color: context.shuyoColors.border),
                    const SizedBox(height: 12),
                    _detail('课程号', course.code),
                    _detail('课程性质', course.nature),
                    _detail('课程类别', course.category),
                    _detail('学时', course.hours),
                    _detail('成绩', course.grade),
                    _detail('绩点', course.gradePoint),
                    _detail('成绩学年学期',
                        '${course.academicYear} ${course.term}'.trim()),
                    _detail(
                        '建议修读',
                        '${course.suggestedYear} ${course.suggestedTerm}'
                            .trim()),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _detail(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.shuyoColors.textSecondary,
                    )),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String? _creditsText(AcademicProgressNode node) {
    final required = node.requiredCredits;
    final earned = node.earnedCredits;
    if (required == null && earned == null) return null;
    return '已获 ${earned == null ? '—' : _number(earned)} / '
        '要求 ${required == null ? '—' : _number(required)} 学分';
  }

  String _number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

class _StudentCategoryBadge extends StatelessWidget {
  const _StudentCategoryBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = context.shuyoColors.accent;
    final textColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    final style = (Theme.of(context).textTheme.labelSmall ??
            const TextStyle(fontSize: 11))
        .copyWith(
            fontSize: 10,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: textColor);
    return DecoratedBox(
      key: const ValueKey('student-category-badge'),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(label, style: style),
      ),
    );
  }
}

enum _AcademicRefreshResult { success, failed, loginRequired }

enum _ProgressMenuAction { displaySettings, refreshProgress }

class _ProgressDisplaySettingsSheet extends StatefulWidget {
  const _ProgressDisplaySettingsSheet({
    required this.showGpa,
    required this.showRanking,
  });

  final bool showGpa;
  final bool showRanking;

  @override
  State<_ProgressDisplaySettingsSheet> createState() =>
      _ProgressDisplaySettingsSheetState();
}

class _ProgressDisplaySettingsSheetState
    extends State<_ProgressDisplaySettingsSheet> {
  late bool _showGpa;
  late bool _showRanking;

  @override
  void initState() {
    super.initState();
    _showGpa = widget.showGpa;
    _showRanking = widget.showRanking;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomPadding),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Text(
                  '显示设置',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Theme(
                data: Theme.of(context).copyWith(
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                ),
                child: SwitchListTile(
                  title: const Text('显示绩点'),
                  value: _showGpa,
                  overlayColor:
                      const WidgetStatePropertyAll<Color?>(Colors.transparent),
                  onChanged: (value) => setState(() => _showGpa = value),
                ),
              ),
              Theme(
                data: Theme.of(context).copyWith(
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                ),
                child: SwitchListTile(
                  title: const Text('显示排名'),
                  value: _showRanking,
                  overlayColor:
                      const WidgetStatePropertyAll<Color?>(Colors.transparent),
                  onChanged: (value) => setState(() => _showRanking = value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      (showGpa: _showGpa, showRanking: _showRanking),
                    ),
                    child: const Text('完成'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedProgressBranch extends StatefulWidget {
  const _AnimatedProgressBranch({
    super.key,
    required this.expanded,
    required this.child,
  });

  final bool expanded;
  final Widget? child;

  @override
  State<_AnimatedProgressBranch> createState() =>
      _AnimatedProgressBranchState();
}

class _AnimatedProgressBranchState extends State<_AnimatedProgressBranch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  Widget? _content;

  @override
  void initState() {
    super.initState();
    _content = widget.child;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.expanded ? 1 : 0,
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) {
          setState(() => _content = null);
        }
      });
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedProgressBranch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child != null) _content = widget.child;
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final content = _content;
        if (content == null || _controller.isDismissed) {
          return const SizedBox(width: double.infinity);
        }
        final value = _progress.value;
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: value,
            child: Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - value)),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TreeConnectorPainter extends CustomPainter {
  const _TreeConnectorPainter({
    required this.color,
    this.horizontalEnd,
    this.horizontalY,
    this.verticalX,
    this.verticalFromCenter = false,
    this.incomingRailX,
    this.incomingRailStopsAtJunction = false,
  });

  final Color color;
  final double? horizontalEnd;
  final double? horizontalY;
  final double? verticalX;
  final bool verticalFromCenter;
  final double? incomingRailX;
  final bool incomingRailStopsAtJunction;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    final end = horizontalEnd;
    if (end != null) {
      final y = horizontalY ?? size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(end, y), pen);
    }
    final incomingX = incomingRailX;
    if (incomingX != null) {
      final junctionY = horizontalY ?? size.height / 2;
      canvas.drawLine(
        Offset(incomingX, 0),
        Offset(
            incomingX, incomingRailStopsAtJunction ? junctionY : size.height),
        pen,
      );
    }
    final x = verticalX;
    if (x != null) {
      canvas.drawLine(
        Offset(x, verticalFromCenter ? size.height / 2 : 0),
        Offset(x, size.height),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TreeConnectorPainter oldDelegate) =>
      color != oldDelegate.color ||
      horizontalEnd != oldDelegate.horizontalEnd ||
      horizontalY != oldDelegate.horizontalY ||
      verticalX != oldDelegate.verticalX ||
      verticalFromCenter != oldDelegate.verticalFromCenter ||
      incomingRailX != oldDelegate.incomingRailX ||
      incomingRailStopsAtJunction != oldDelegate.incomingRailStopsAtJunction;
}
