import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'recording_lessons_page.dart';

/// The ordinary account catalog. Search never expands the permission scope.
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
  final _searchController = TextEditingController();
  List<VodTerm> _terms = const [];
  List<VodCourse> _courses = const [];
  int? _selectedTermId;
  String? _teacher;
  Object? _error;
  bool _checkingSession = true;
  bool _authenticated = false;
  bool _expired = false;
  bool _loading = false;
  bool _loggingIn = false;
  bool _openingCourse = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _revision++;
    _searchController.dispose();
    if (widget.repository == null) _repository.dispose();
    if (widget.authService == null) _auth.dispose();
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
    await _auth.ensureSession(
        useWebVpn: widget.useWebVpn, forceRefresh: forceRefresh);
    return true;
  }

  Future<void> _campusAuthRequired({required bool ssoExpired}) async {
    if (!mounted) return;
    _repository.clear();
    setState(() {
      _checkingSession = false;
      _authenticated = false;
      _expired = ssoExpired;
      _courses = const [];
      _terms = const [];
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
      setState(() {
        _authenticated = true;
        _expired = false;
        _error = null;
        _terms = const [];
        _courses = const [];
        _selectedTermId = null;
        _teacher = null;
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

  Future<void> _load({bool force = false, int? termId}) async {
    if (!_authenticated) return;
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final terms = await _repository.loadTerms(forceRefresh: force);
      if (!mounted || revision != _revision) return;
      var selected = termId ?? _selectedTermId;
      if (!terms.any((term) => term.id == selected)) {
        selected = terms.isEmpty
            ? null
            : terms
                .firstWhere((term) => term.isCurrent, orElse: () => terms.first)
                .id;
      }
      final courses = selected == null
          ? <VodCourse>[]
          : await _repository.loadCourses(
              termId: selected, forceRefresh: force);
      if (!mounted || revision != _revision) return;
      setState(() {
        _terms = terms;
        _selectedTermId = selected;
        _courses = courses;
        if (_teacher != null &&
            !courses.any((course) => course.teacherNames.contains(_teacher))) {
          _teacher = null;
        }
      });
    } on VodSessionExpiredException catch (error) {
      if (!mounted || revision != _revision) return;
      await _campusAuthRequired(ssoExpired: error.ssoExpired);
    } on Object catch (error) {
      if (mounted && revision == _revision) setState(() => _error = error);
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openCourse(VodCourse course) async {
    if (_loading || _openingCourse) return;
    _openingCourse = true;
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingLessonsPage(
          repository: _repository,
          course: course,
          onSessionExpired: _recoverSession,
        ),
      ));
    } finally {
      _openingCourse = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程录播'),
        actions: [
          if (_authenticated) ...[
            IconButton(
              tooltip: '刷新课程',
              onPressed: _loading ? null : () => _load(force: true),
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_checkingSession) {
      return const Center(child: CircularProgressIndicator());
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
      return const Center(child: CircularProgressIndicator());
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
    final teachers = _courses
        .expand((course) => course.teacherNames)
        .toSet()
        .toList()
      ..sort();
    final filtered = _repository.filterCourses(_courses,
        keyword: _searchController.text, teacher: _teacher);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(children: [
          _filters(teachers),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('vod-course-search'),
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '搜索课程、教师或课程代码',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_searchController.clear),
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '当前账号 · ${filtered.length} 门课程',
                style: TextStyle(
                    fontSize: 12, color: context.shuyoColors.textMuted),
              )),
        ]),
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
          child: _error != null
              ? _errorState()
              : RefreshIndicator(
                  onRefresh: () => _load(force: true),
                  child: filtered.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) => ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  SizedBox(
                                      height: constraints.maxHeight,
                                      child: EmptyState(
                                        icon: _courses.isEmpty
                                            ? Icons.video_library_outlined
                                            : Icons.search_off,
                                        title: _courses.isEmpty
                                            ? '本学期暂无可观看课程'
                                            : '没有匹配的课程',
                                        message: _courses.isEmpty
                                            ? '可切换学期，或在课程回放生成后刷新。'
                                            : '试试其他关键词，或将教师筛选改为全部教师。',
                                      )),
                                ],
                              ))
                      : ListView.separated(
                          key: ValueKey('vod-courses:$_selectedTermId'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final course = filtered[index];
                            return Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                key: ValueKey(
                                    'vod-course:${course.teachingClassId}'),
                                enabled: !_loading,
                                leading: Icon(Icons.ondemand_video_outlined,
                                    color: context.shuyoColors.accent),
                                title: Text(course.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text([
                                    course.teacherLabel.isEmpty
                                        ? '教师信息暂未提供'
                                        : course.teacherLabel,
                                    if (course.code.isNotEmpty) course.code,
                                  ].join(' · ')),
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _openCourse(course),
                              ),
                            );
                          },
                        ),
                )),
    ]);
  }

  Widget _filters(List<String> teachers) {
    final term = InputDecorator(
      decoration: const InputDecoration(
          labelText: '学期', border: OutlineInputBorder(), isDense: true),
      child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
        key: const ValueKey('vod-term-filter'),
        value: _selectedTermId,
        isExpanded: true,
        isDense: true,
        items: [
          for (final term in _terms)
            DropdownMenuItem(
                value: term.id,
                child: Text(term.name, overflow: TextOverflow.ellipsis))
        ],
        onChanged: _loading
            ? null
            : (value) {
                if (value == null || value == _selectedTermId) return;
                setState(() {
                  _selectedTermId = value;
                  _teacher = null;
                  _courses = const [];
                });
                unawaited(_load(termId: value));
              },
      )),
    );
    final teacher = InputDecorator(
      decoration: const InputDecoration(
          labelText: '教师', border: OutlineInputBorder(), isDense: true),
      child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
        key: const ValueKey('vod-teacher-filter'),
        value: _teacher ?? '',
        isExpanded: true,
        isDense: true,
        items: [
          const DropdownMenuItem(value: '', child: Text('全部教师')),
          for (final name in teachers)
            DropdownMenuItem(
                value: name,
                child: Text(name, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: _loading
            ? null
            : (value) => setState(() {
                  _teacher = value == null || value.isEmpty ? null : value;
                }),
      )),
    );
    return LayoutBuilder(builder: (_, constraints) {
      if (constraints.maxWidth < 380) {
        return Column(children: [term, const SizedBox(height: 12), teacher]);
      }
      return Row(children: [
        Expanded(flex: 3, child: term),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: teacher)
      ]);
    });
  }

  Widget _errorState() {
    final error = _error;
    return EmptyState(
      icon: error is VodPermissionException
          ? Icons.lock_outline
          : Icons.cloud_off_outlined,
      title: error is VodPermissionException ? '暂时无法查看课程' : '课程加载失败',
      message: error is VodApiException
          ? error.message
          : error is VodAuthException
              ? error.message
              : '暂时无法连接录播平台，请稍后重试。',
      action: TextButton.icon(
        onPressed: _loading
            ? null
            : () => _authenticated ? _load(force: true) : _restore(),
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    );
  }
}
