import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/academic_progress.dart';
import '../../data/models/academic_ranking.dart';
import '../../data/repositories/academic_progress_repository.dart';
import '../../data/repositories/academic_ranking_repository.dart';
import '../../data/services/academic_progress_display_settings_service.dart';
import '../../data/services/academic_schedule_api_client.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

class AcademicProgressPage extends StatefulWidget {
  const AcademicProgressPage({
    super.key,
    required this.repository,
    required this.onLoginRequired,
    this.rankingRepository,
  });

  final AcademicProgressRepository repository;
  final AcademicRankingRepository? rankingRepository;
  final Future<void> Function() onLoginRequired;

  @override
  State<AcademicProgressPage> createState() => _AcademicProgressPageState();
}

class _AcademicProgressPageState extends State<AcademicProgressPage> {
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
  final Set<String> _expandedNodes = {};
  bool _loading = true;
  bool _refreshing = false;
  bool _showGpa = false;
  bool _showRanking = false;
  bool _showCollegeRanking = true;
  bool _rankingLoading = false;
  String? _rankingError;
  String? _loadError;
  final _displaySettingsService = AcademicProgressDisplaySettingsService();
  late final AcademicRankingRepository _rankingRepository =
      widget.rankingRepository ?? AcademicRankingRepository();

  @override
  void initState() {
    super.initState();
    unawaited(_loadCached());
    unawaited(_loadRankingAndDisplaySettings());
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

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      // Each request updates its own data as soon as it succeeds. Waiting here
      // only combines the final notice and handles an expired session once.
      final results = await Future.wait([
        _refreshProgress(),
        _refreshRanking(),
      ]);
      if (!mounted) return;
      if (results.contains(_AcademicRefreshResult.loginRequired)) {
        await widget.onLoginRequired();
        return; // Authentication never resumes this refresh automatically.
      }
      final progressUpdated = results[0] == _AcademicRefreshResult.success;
      final rankingUpdated = results[1] == _AcademicRefreshResult.success;
      _showSnack(progressUpdated
          ? rankingUpdated
              ? '学业信息已同步'
              : '学业信息已同步，排名获取失败'
          : rankingUpdated
              ? '排名已同步，学业信息获取失败'
              : '学业信息同步失败');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<_AcademicRefreshResult> _refreshProgress() async {
    try {
      await _fetchAndShow();
      return _AcademicRefreshResult.success;
    } on AcademicAuthException {
      return _AcademicRefreshResult.loginRequired;
    } on Object catch (error) {
      if (mounted && _progress == null) {
        setState(() => _loadError = '学业信息同步失败：$error');
      }
      return _AcademicRefreshResult.failed;
    }
  }

  Future<_AcademicRefreshResult> _refreshRanking() async {
    setState(() {
      _rankingLoading = true;
      _rankingError = null;
    });
    try {
      final ranking = await _rankingRepository.refreshRanking();
      if (mounted) setState(() => _ranking = ranking);
      return _AcademicRefreshResult.success;
    } on AcademicAuthException {
      if (mounted) setState(() => _rankingError = '登录已失效');
      return _AcademicRefreshResult.loginRequired;
    } on Object {
      if (mounted) setState(() => _rankingError = '获取失败');
      return _AcademicRefreshResult.failed;
    } finally {
      if (mounted) setState(() => _rankingLoading = false);
    }
  }

  Future<void> _fetchAndShow() async {
    final progress = await widget.repository.refreshProgress();
    if (!mounted) return;
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
    ScaffoldMessenger.of(context)
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
    final colors = context.shuyoColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学业总览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child:
                      _metric('已获学分', earned == null ? '—' : _number(earned)),
                ),
                Expanded(
                  child: _metric(
                      '要求学分', required == null ? '—' : _number(required)),
                ),
                if (_showGpa)
                  Expanded(
                    child: _metric(
                        '平均绩点', progress.gpa.isEmpty ? '—' : progress.gpa),
                  )
                else if (!_showRanking)
                  const Expanded(child: SizedBox.shrink()),
                if (_showRanking) Expanded(child: _rankingMetric()),
              ],
            ),
            if (earned != null && required != null && required > 0) ...[
              const SizedBox(height: 15),
              LinearProgressIndicator(
                value: (earned / required).clamp(0, 1),
                minHeight: 7,
                borderRadius: BorderRadius.circular(7),
              ),
            ],
            if (progress.plannedCourses != null) ...[
              const SizedBox(height: 12),
              Text(
                '计划 ${progress.plannedCourses} 门 · 已修 ${progress.passedCourses ?? '—'} 门'
                ' · 在修 ${progress.ongoingCourses ?? '—'} 门 · 未修 ${progress.notTakenCourses ?? '—'} 门',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '同步于 ${_dateText(progress.fetchedAt)} · 数据仅供学业修读参考',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
        ],
      );

  Widget _rankingMetric() {
    final colors = context.shuyoColors;
    final ranking = _ranking;
    final college = _showCollegeRanking;
    final rank = college ? ranking?.collegeRank : ranking?.majorRank;
    final count = college ? ranking?.collegeCount : ranking?.majorCount;
    final label = college ? '学院排名' : '专业排名';
    final value = rank == null
        ? '—'
        : count == null
            ? '$rank'
            : '$rank/$count';
    final headlineStyle = Theme.of(context).textTheme.headlineSmall;
    final valueHeight =
        (headlineStyle?.fontSize ?? 24) * (headlineStyle?.height ?? 1.3);
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
              : '${ranking.academicYear} ${ranking.term} · '
                  '同步于 ${_dateText(ranking.fetchedAt)}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                height: valueHeight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, style: headlineStyle),
                ),
              ),
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

  String _dateText(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
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
