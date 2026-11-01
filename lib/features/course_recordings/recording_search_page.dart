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
  String? _activeKeyword;
  Object? _error;
  bool _searching = false;
  bool _needsLogin = false;
  bool _loggingIn = false;
  bool _openingLesson = false;
  int _revision = 0;

  @override
  void dispose() {
    _revision++;
    _queryController.dispose();
    _queryFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _clearSearch({bool clearField = true}) {
    _revision++;
    if (clearField) _queryController.clear();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _activeKeyword = null;
      _results = const [];
      _error = null;
      _searching = false;
    });
  }

  Future<void> _search() async {
    final keyword = _queryController.text.trim();
    if (_needsLogin || _loggingIn) return;
    if (keyword.isEmpty) {
      _clearSearch();
      return;
    }
    if (keyword.runes.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入至少 2 个字的课程或教师关键词')),
      );
      return;
    }
    _queryFocusNode.unfocus();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final revision = ++_revision;
    setState(() {
      _activeKeyword = keyword;
      _results = const [];
      _error = null;
      _searching = true;
    });
    try {
      final results = await widget.repository.searchLessons(
        termId: _selectedTermId,
        keyword: keyword,
      );
      if (!mounted || revision != _revision) return;
      final sorted = results.toList()..sort(_compareResults);
      setState(() => _results = sorted);
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
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _invalidateSession(bool ssoExpired) async {
    _revision++;
    setState(() {
      _needsLogin = true;
      _searching = false;
      _results = const [];
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

  Future<void> _openLesson(VodSearchResult result) async {
    if (_openingLesson || _needsLogin || !result.lesson.canPlay) return;
    _openingLesson = true;
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingPlayerPage(
          course: result.course,
          initialLesson: result.lesson,
          lessons: _results
              .where((candidate) =>
                  candidate.course.teachingClassId ==
                      result.course.teachingClassId &&
                  candidate.course.termId == result.course.termId &&
                  candidate.lesson.canPlay)
              .map((candidate) => candidate.lesson)
              .toList(),
          loadCourseCatalog: false,
          loadPreviewCatalog: true,
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
        _activeKeyword = null;
        _error = null;
        _searching = false;
        _needsLogin = true;
      });
    }
    final recovered = await widget.onSessionExpired?.call() ?? false;
    if (mounted) setState(() => _needsLogin = !recovered);
    return recovered;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
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
          child: _searching || _loggingIn
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
                  labelText: '课程 / 教师关键词',
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (selectedTerm != null) selectedTerm.name,
                    '实验性搜索',
                    if (_activeKeyword != null &&
                        !_searching &&
                        _error == null &&
                        !_needsLogin)
                      '${_results.length} 节课次',
                  ].join(' · '),
                  style: ShuYoTextStyles.meta(color: colors.textSecondary),
                ),
                const SizedBox(height: 4),
                Text('搜索最多返回 50 条，请细化关键词。',
                    style: ShuYoTextStyles.meta(color: colors.textMuted)),
              ],
            ),
          ),
        ),
        Expanded(child: _buildResults()),
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
    } else if (_results.isEmpty) {
      state = EmptyState(
        icon: _activeKeyword == null ? Icons.search : Icons.search_off,
        title: _activeKeyword == null ? '搜索课程或教师' : '没有找到录播',
        message:
            _activeKeyword == null ? '输入课程或教师关键词后点击搜索。' : '试试其他关键词，或切换学期后搜索。',
      );
    }
    final rows = <Widget>[];
    String? previousDate;
    for (final result in _results) {
      final date = _dateLabel(result.lesson.beginTime);
      if (date != previousDate) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Semantics(
            header: true,
            child: Text(date,
                style: ShuYoTextStyles.meta(
                    color: context.shuyoColors.textSecondary,
                    weight: FontWeight.w600)),
          ),
        ));
        previousDate = date;
      }
      rows.add(_SearchLessonTile(
        result: result,
        onTap: () => unawaited(_openLesson(result)),
      ));
      rows.add(const Divider(indent: 16, endIndent: 16));
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
          key: const ValueKey('vod-search-results'),
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            if (state != null)
              SliverFillRemaining(hasScrollBody: false, child: state)
            else ...[
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (_, index) => rows[index],
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ],
        ),
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

class _SearchLessonTile extends StatelessWidget {
  const _SearchLessonTile({required this.result, required this.onTap});

  final VodSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final lesson = result.lesson;
    final enabled = lesson.canPlay;
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = enabled ? colors.textSecondary : colors.textMuted;
    final title = RecordingCourseTitle(
      course: result.course,
      maxNameLines: 2,
      missingTeacherLabel: '教师信息暂未提供',
      description: Text.rich(
        TextSpan(children: [
          if (lesson.classroom.trim().isNotEmpty) ...[
            TextSpan(
                text: lesson.classroom.trim(),
                style: TextStyle(color: enabled ? primary : secondary)),
            const TextSpan(text: ' · '),
          ],
          TextSpan(
              text: [
            if (lesson.sectionLabel.trim().isNotEmpty)
              lesson.sectionLabel.trim(),
            if (_lessonTime(lesson).isNotEmpty) _lessonTime(lesson),
            if (!enabled) lesson.statusLabel,
          ].join(' · ')),
        ]),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: ShuYoTextStyles.meta(color: secondary),
      ),
    );
    return ListTile(
      key: ValueKey(
          'vod-search-result:${result.course.teachingClassId}:${lesson.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      enabled: enabled,
      leading: RecordingStatusIcon(
          isLive: lesson.isLive,
          enabled: enabled,
          disabledColor: colors.textMuted),
      title: enabled
          ? title
          : ColorFiltered(
              colorFilter: ColorFilter.mode(colors.textMuted, BlendMode.srcIn),
              child: title,
            ),
      trailing:
          enabled ? Icon(Icons.chevron_right, color: colors.textMuted) : null,
      onTap: enabled ? onTap : null,
    );
  }
}

DateTime? _schoolTime(DateTime? date) {
  if (date == null) return null;
  final time = date.isUtc ? date.add(const Duration(hours: 8)) : date;
  return DateTime.utc(time.year, time.month, time.day, time.hour, time.minute,
      time.second, time.millisecond, time.microsecond);
}

String _dateLabel(DateTime? date) {
  final time = _schoolTime(date);
  if (time == null) return '日期待定';
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${time.year}年${time.month}月${time.day}日 ${weekdays[time.weekday - 1]}';
}

String _lessonTime(VodLesson lesson) {
  String format(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  final begin = _schoolTime(lesson.beginTime);
  final end = _schoolTime(lesson.endTime);
  if (begin == null) return '';
  if (end == null ||
      !end.isAfter(begin) ||
      end.year != begin.year ||
      end.month != begin.month ||
      end.day != begin.day) {
    return format(begin);
  }
  return '${format(begin)}-${format(end)}';
}

int _compareResults(VodSearchResult first, VodSearchResult second) {
  final firstTime = _schoolTime(first.lesson.beginTime);
  final secondTime = _schoolTime(second.lesson.beginTime);
  if (firstTime == null && secondTime != null) return 1;
  if (secondTime == null && firstTime != null) return -1;
  if (firstTime != null && secondTime != null) {
    final firstDate =
        DateTime.utc(firstTime.year, firstTime.month, firstTime.day);
    final secondDate =
        DateTime.utc(secondTime.year, secondTime.month, secondTime.day);
    final byDate = secondDate.compareTo(firstDate);
    if (byDate != 0) return byDate;
  }
  final byTime = firstTime?.compareTo(secondTime!) ?? 0;
  if (byTime != 0) return byTime;
  final byCourse =
      first.course.teachingClassId.compareTo(second.course.teachingClassId);
  return byCourse == 0 ? second.lesson.id.compareTo(first.lesson.id) : byCourse;
}
