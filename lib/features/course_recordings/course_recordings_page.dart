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
import 'recording_player_page.dart';
import 'recording_status_icon.dart';
import 'recording_term_menu.dart';

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
  List<VodTerm> _terms = const [];
  List<VodCourse> _courses = const [];
  int? _selectedTermId;
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
    _revision++;
    _repository.clear();
    setState(() {
      _checkingSession = false;
      _loading = false;
      _authenticated = false;
      _expired = ssoExpired;
      _courses = const [];
      _terms = const [];
      _presentedCourseIds.clear();
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
        _presentedCourseIds.clear();
        _selectedTermId = null;
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
      setState(() {
        if (_selectedTermId != selected) {
          _courses = const [];
          _presentedCourseIds.clear();
        }
        _terms = terms;
        _selectedTermId = selected;
      });
      final courses = selected == null
          ? <VodCourse>[]
          : await _repository.loadCatalog(
              termId: selected,
              forceRefresh: force,
              onProgress: (snapshot) {
                if (!mounted || revision != _revision) return;
                if (snapshot.isEmpty && _courses.isNotEmpty) return;
                setState(() => _courses = snapshot);
              },
            );
      if (!mounted || revision != _revision) return;
      setState(() {
        _courses = courses;
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
    if (_openingCourse) return;
    _openingCourse = true;
    try {
      await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) => RecordingPlayerPage(
          repository: _repository,
          course: course,
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
    setState(() {
      _selectedTermId = termId;
      _courses = const [];
      _presentedCourseIds.clear();
    });
    await _load(termId: termId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程录播'),
        actions: [
          if (_authenticated) ...[
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
            child: _checkingSession || _loading
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
      Expanded(
          child: _error != null && _courses.isEmpty
              ? _errorState()
              : RefreshIndicator.noSpinner(
                  onRefresh: () => _load(force: true),
                  child: _courses.isEmpty
                      ? LayoutBuilder(
                          builder: (context, constraints) => ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  SizedBox(
                                      height: constraints.maxHeight,
                                      child: _loading
                                          ? const SizedBox.expand()
                                          : EmptyState(
                                              icon:
                                                  Icons.video_library_outlined,
                                              title: '本学期暂无可观看课程',
                                              message: '可切换学期，或在课程回放生成后刷新。',
                                            )),
                                ],
                              ))
                      : ListView.separated(
                          key: ValueKey('vod-courses:$_selectedTermId'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: _courses.length,
                          findItemIndexCallback: (key) {
                            final index = _courses.indexWhere((course) =>
                                ValueKey(course.teachingClassId) == key);
                            return index < 0 ? null : index;
                          },
                          separatorBuilder: (_, __) => const Divider(
                            height: 1,
                            indent: 72,
                            endIndent: 16,
                          ),
                          itemBuilder: (context, index) {
                            final course = _courses[index];
                            return _CourseEntrance(
                              key: ValueKey(course.teachingClassId),
                              index: index,
                              animate: _presentedCourseIds
                                  .add(course.teachingClassId),
                              child: ListTile(
                                key: ValueKey(
                                    'vod-course:${course.teachingClassId}'),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                leading: Tooltip(
                                  message: course.isLive ? '正在直播' : '录播回放',
                                  child: RecordingStatusIcon(
                                      isLive: course.isLive),
                                ),
                                title: Text(course.name,
                                    style: ShuYoTextStyles.title(
                                        color: context.shuyoColors.textPrimary),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                      [
                                        course.teacherLabel.isEmpty
                                            ? '教师信息暂未提供'
                                            : course.teacherLabel,
                                        if (course.code.isNotEmpty) course.code,
                                      ].join(' · '),
                                      style: ShuYoTextStyles.meta(
                                          color: context
                                              .shuyoColors.textSecondary),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
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
