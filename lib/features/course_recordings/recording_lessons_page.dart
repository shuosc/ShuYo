import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'recording_player_page.dart';

class RecordingLessonsPage extends StatefulWidget {
  const RecordingLessonsPage({
    super.key,
    required this.repository,
    required this.course,
    this.onSessionExpired,
  });

  final VodRepository repository;
  final VodCourse course;
  final Future<bool> Function()? onSessionExpired;

  @override
  State<RecordingLessonsPage> createState() => _RecordingLessonsPageState();
}

enum _LessonFailure { session, permission, network, unavailable }

class _RecordingLessonsPageState extends State<RecordingLessonsPage> {
  List<VodLesson> _lessons = const [];
  bool _loading = true;
  bool _recovering = false;
  bool _opening = false;
  bool _newestFirst = true;
  int _loadRevision = 0;
  _LessonFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(RecordingLessonsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.course.teachingClassId != widget.course.teachingClassId ||
        oldWidget.course.termId != widget.course.termId) {
      _lessons = const [];
      _opening = false;
      _recovering = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _loadRevision++;
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final revision = ++_loadRevision;
    final course = widget.course;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final result = await widget.repository.loadLessons(
        course,
        forceRefresh: forceRefresh,
      );
      if (!mounted || revision != _loadRevision) return;
      // Guard the route as well as the repository against mixed class data.
      final unique = <int, VodLesson>{};
      for (final lesson in result) {
        if (lesson.isPlayable &&
            lesson.teachingClassId == course.teachingClassId) {
          unique[lesson.id] = lesson;
        }
      }
      final chronological = unique.values.toList(growable: false)
        ..sort((a, b) {
          final byTime = (a.beginTime?.millisecondsSinceEpoch ?? 0)
              .compareTo(b.beginTime?.millisecondsSinceEpoch ?? 0);
          return byTime == 0 ? a.id.compareTo(b.id) : byTime;
        });
      setState(() {
        _lessons = List.unmodifiable(chronological);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _loading = false;
        _failure = switch (error) {
          VodSessionExpiredException() => _LessonFailure.session,
          VodPermissionException() => _LessonFailure.permission,
          VodNetworkException() => _LessonFailure.network,
          _ => _LessonFailure.unavailable,
        };
        if (_failure == _LessonFailure.session ||
            _failure == _LessonFailure.permission) {
          _lessons = const [];
        }
      });
    }
  }

  Future<void> _refresh() async {
    if (_loading || _recovering || _failure == _LessonFailure.session) return;
    await _load(forceRefresh: true);
  }

  Future<void> _recoverSession() async {
    final recover = widget.onSessionExpired;
    if (recover == null || _recovering) return;
    final revision = ++_loadRevision;
    setState(() => _recovering = true);
    try {
      final restored = await recover();
      if (!mounted || revision != _loadRevision) return;
      if (!restored) {
        setState(() => _recovering = false);
        return;
      }
      widget.repository.clear();
      setState(() {
        _lessons = const [];
        _recovering = false;
      });
      await _load(forceRefresh: true);
    } on Object {
      if (!mounted || revision != _loadRevision) return;
      setState(() => _recovering = false);
    }
  }

  Future<void> _openLesson(VodLesson lesson) async {
    if (_loading || _recovering || _opening || _failure != null) return;
    final course = widget.course;
    final lessons = _lessons;
    final repository = widget.repository;
    final onSessionExpired = widget.onSessionExpired;
    setState(() => _opening = true);
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingPlayerPage(
          course: course,
          lessons: lessons,
          initialLesson: lesson,
          repository: repository,
          loadPlayback: (selected) => repository.preparePlayback(
            course: course,
            lesson: selected,
          ),
          onSessionExpired: onSessionExpired,
        ),
      ));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final ordered = _newestFirst ? _lessons.reversed.toList() : _lessons;
    final ordinals = {
      for (var i = 0; i < _lessons.length; i++) _lessons[i].id: i + 1,
    };
    final entries = <Object>[];
    String? previousDate;
    for (final lesson in ordered) {
      final date = _dateLabel(lesson.beginTime);
      if (date != previousDate) {
        entries.add(date);
        previousDate = date;
      }
      entries.add(lesson);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.course.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed:
                _loading || _recovering || _failure == _LessonFailure.session
                    ? null
                    : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _courseHeader()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Text('回放列表 · ${_lessons.length} 集',
                          style: ShuYoTextStyles.sectionTitle(
                              color: colors.textPrimary)),
                      PopupMenuButton<bool>(
                        tooltip: '排序',
                        enabled: !_loading && !_recovering,
                        initialValue: _newestFirst,
                        onSelected: (value) =>
                            setState(() => _newestFirst = value),
                        itemBuilder: (_) => [
                          CheckedPopupMenuItem(
                            value: true,
                            checked: _newestFirst,
                            child: const Text('最近在前'),
                          ),
                          CheckedPopupMenuItem(
                            value: false,
                            checked: !_newestFirst,
                            child: const Text('最早在前'),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            children: [
                              const Icon(Icons.sort, size: 18),
                              Text(_newestFirst ? '最近在前' : '最早在前'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_failure != null && _lessons.isNotEmpty)
                SliverToBoxAdapter(child: _failureBanner()),
              if (_lessons.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 3))
                      : _failure != null
                          ? _failureState()
                          : const EmptyState(
                              icon: Icons.video_library_outlined,
                              title: '暂无可观看回放',
                              message: '这门课还没有已生成且可观看的录播。稍后可下拉刷新。',
                            ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final item = entries[index];
                      if (item is String) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                          child: Text(item,
                              style: ShuYoTextStyles.label(
                                  color: colors.textSecondary)),
                        );
                      }
                      final lesson = item as VodLesson;
                      final canPlay = !_loading &&
                          !_recovering &&
                          !_opening &&
                          _failure == null;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        color: colors.surface,
                        elevation: 0,
                        child: ListTile(
                          key: ValueKey('recording-lesson-${lesson.id}'),
                          enabled: canPlay,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          leading: Icon(Icons.play_circle_outline,
                              color:
                                  canPlay ? colors.accent : colors.textMuted),
                          title: Text(
                              '第 ${ordinals[lesson.id]} 集 · ${_timeLabel(lesson)}'),
                          subtitle: Text([
                            if (lesson.weekNumber > 0)
                              '第 ${lesson.weekNumber} 周',
                            if (lesson.sectionLabel.isNotEmpty)
                              lesson.sectionLabel,
                            if (lesson.classroom.isNotEmpty) lesson.classroom,
                          ].join(' · ')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: canPlay
                              ? () => unawaited(_openLesson(lesson))
                              : null,
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _courseHeader() {
    final colors = context.shuyoColors;
    final course = widget.course;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(course.name,
              style: ShuYoTextStyles.headerTitle(color: colors.textPrimary)),
          const SizedBox(height: 8),
          Text(course.teacherLabel.isEmpty ? '教师信息暂无' : course.teacherLabel,
              style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary)),
          if (course.code.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('课程号 ${course.code}',
                style: ShuYoTextStyles.meta(color: colors.textSecondary)),
          ],
          const SizedBox(height: 10),
          Text('选择上课日期与集数观看回放',
              style: ShuYoTextStyles.meta(color: colors.textTertiary)),
        ],
      ),
    );
  }

  String get _failureTitle => switch (_failure) {
        _LessonFailure.session => '校园账户登录已失效',
        _LessonFailure.permission => '暂时无法观看这门课',
        _LessonFailure.network => '无法连接录播平台',
        _ => '回放列表加载失败',
      };

  String get _failureMessage => switch (_failure) {
        _LessonFailure.session => '请重新登录校园账户后查看课程回放。',
        _LessonFailure.permission => '当前账号没有这门课的观看权限，请返回课程列表刷新。',
        _LessonFailure.network => '请检查校园网、学校 VPN 或 WebVPN 连接，然后重试。',
        _ => '暂时未能取得回放列表，请稍后重试。',
      };

  Widget? _failureAction() {
    if (_failure == _LessonFailure.session) {
      if (widget.onSessionExpired == null) return null;
      return TextButton.icon(
        onPressed: _recovering ? null : _recoverSession,
        icon: const Icon(Icons.login),
        label: Text(_recovering ? '正在登录…' : '重新登录'),
      );
    }
    if (_failure == _LessonFailure.permission) return null;
    return TextButton.icon(
      onPressed: _loading ? null : _refresh,
      icon: const Icon(Icons.refresh),
      label: const Text('重试'),
    );
  }

  Widget _failureState() => EmptyState(
        icon: _failure == _LessonFailure.session
            ? Icons.lock_outline
            : _failure == _LessonFailure.permission
                ? Icons.no_accounts_outlined
                : Icons.cloud_off_outlined,
        title: _failureTitle,
        message: _failureMessage,
        action: _failureAction(),
      );

  Widget _failureBanner() {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_failureTitle,
              style: ShuYoTextStyles.bodyCompact(color: colors.danger)),
          Text(_failureMessage,
              style: ShuYoTextStyles.meta(color: colors.textSecondary)),
          if (_failureAction() case final action?) action,
        ],
      ),
    );
  }

  static String _dateLabel(DateTime? date) {
    if (date == null) return '日期待确认';
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${date.year}年${date.month}月${date.day}日 ${weekdays[date.weekday - 1]}';
  }

  static String _timeLabel(VodLesson lesson) {
    String time(DateTime date) =>
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final begin = lesson.beginTime;
    final end = lesson.endTime;
    if (begin == null) return '上课时间待确认';
    return end == null ? time(begin) : '${time(begin)}–${time(end)}';
  }
}
