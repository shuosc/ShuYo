import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/client_backend.dart';
import '../../data/services/client_settings_service.dart';
import '../auth/native_login_page.dart';

enum ForumAccountStatus {
  signedOut,
  connecting,
  loggedIn,
  connectionUnavailable,
  webVpnLoginRequired,
  waitingForAcademicLogin,
  reauthenticationRequired,
  directLoginUnavailable,
}

class StartupOnboardingController extends ChangeNotifier {
  bool _academicLoggedIn = false;
  ForumAccountStatus _forumStatus = ForumAccountStatus.signedOut;
  VoidCallback? _onForumReconnect;
  VoidCallback? _onDismissAccountManager;
  Future<bool> Function()? _onAcademicLogout;
  Future<bool> Function()? _onForumLogout;
  Future<bool> Function(bool enabled)? _onWebVpnChanged;
  bool _webVpnEnabled = false;
  WebVpnServiceStatus _webVpnServiceStatus =
      const WebVpnServiceStatus.unknown();
  int _openRequest = 0;
  bool _accountManagerOpen = false;
  bool _notificationScheduled = false;
  bool _disposed = false;

  bool get academicLoggedIn => _academicLoggedIn;
  ForumAccountStatus get forumStatus => _forumStatus;
  int get openRequest => _openRequest;
  bool get accountManagerOpen => _accountManagerOpen;
  bool get webVpnEnabled => _webVpnEnabled;
  WebVpnServiceStatus get webVpnServiceStatus => _webVpnServiceStatus;

  void openAccountManager({
    required bool academicLoggedIn,
    required ForumAccountStatus forumStatus,
    bool webVpnEnabled = false,
    WebVpnServiceStatus webVpnServiceStatus =
        const WebVpnServiceStatus.unknown(),
  }) {
    _academicLoggedIn = academicLoggedIn;
    _forumStatus = forumStatus;
    _webVpnEnabled = webVpnEnabled;
    _webVpnServiceStatus = webVpnServiceStatus;
    _openRequest++;
    _accountManagerOpen = true;
    _notifyListenersSafely();
  }

  void setAccountManagerDismissHandler(VoidCallback? handler) {
    _onDismissAccountManager = handler;
  }

  bool dismissAccountManager() {
    if (!_accountManagerOpen || _onDismissAccountManager == null) return false;
    _onDismissAccountManager!.call();
    return true;
  }

  void markAccountManagerClosed() => _accountManagerOpen = false;

  void setForumReconnectHandler(VoidCallback? handler) {
    _onForumReconnect = handler;
  }

  void updateAccountStatus({
    required bool academicLoggedIn,
    required ForumAccountStatus forumStatus,
    bool? webVpnEnabled,
    WebVpnServiceStatus? webVpnServiceStatus,
  }) {
    final nextEnabled = webVpnEnabled ?? _webVpnEnabled;
    final nextStatus = webVpnServiceStatus ?? _webVpnServiceStatus;
    if (_academicLoggedIn == academicLoggedIn &&
        _forumStatus == forumStatus &&
        _webVpnEnabled == nextEnabled &&
        identical(_webVpnServiceStatus, nextStatus)) {
      return;
    }
    _academicLoggedIn = academicLoggedIn;
    _forumStatus = forumStatus;
    _webVpnEnabled = nextEnabled;
    _webVpnServiceStatus = nextStatus;
    _notifyListenersSafely();
  }

  void reconnectForum() => _onForumReconnect?.call();

  void setWebVpnChangeHandler(
    Future<bool> Function(bool enabled)? handler,
  ) {
    _onWebVpnChanged = handler;
  }

  Future<bool> setWebVpnEnabled(bool enabled) async =>
      await _onWebVpnChanged?.call(enabled) ?? false;

  void setAccountLogoutHandlers({
    Future<bool> Function()? onAcademicLogout,
    Future<bool> Function()? onForumLogout,
  }) {
    _onAcademicLogout = onAcademicLogout;
    _onForumLogout = onForumLogout;
  }

  Future<bool> logoutAcademic() async =>
      await _onAcademicLogout?.call() ?? false;

  Future<bool> logoutForum() async => await _onForumLogout?.call() ?? false;

  bool get canLogoutAcademic => _onAcademicLogout != null;
  bool get canLogoutForum => _onForumLogout != null;

  void _notifyListenersSafely() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _onForumReconnect = null;
    _onAcademicLogout = null;
    _onForumLogout = null;
    _onWebVpnChanged = null;
    super.dispose();
  }
}

class StartupOnboarding extends StatefulWidget {
  const StartupOnboarding({
    super.key,
    required this.child,
    required this.initiallyCompleted,
    required this.initialAcademicLoggedIn,
    required this.initialForumStatus,
    required this.onAcademicLoginCompleted,
    required this.onForumLoginCompleted,
    this.onDemoLogin,
    this.onAcademicLogout,
    this.onForumLogout,
    required this.controller,
    this.settingsService,
    this.notificationPermissionRequester,
  });

  final Widget child;
  final bool initiallyCompleted;
  final bool initialAcademicLoggedIn;
  final ForumAccountStatus initialForumStatus;
  final VoidCallback onAcademicLoginCompleted;
  final VoidCallback onForumLoginCompleted;
  final Future<void> Function()? onDemoLogin;
  final Future<bool> Function()? onAcademicLogout;
  final Future<bool> Function()? onForumLogout;
  final StartupOnboardingController controller;
  final ClientSettingsService? settingsService;
  final Future<bool?> Function()? notificationPermissionRequester;

  @override
  State<StartupOnboarding> createState() => _StartupOnboardingState();
}

class _StartupOnboardingState extends State<StartupOnboarding>
    with SingleTickerProviderStateMixin {
  final _pageController = PageController();
  late final ClientSettingsService _settingsService =
      widget.settingsService ?? ClientSettingsService();
  late final AnimationController _panelAnimationController;
  late final Animation<Offset> _panelSlideAnimation;
  late final Animation<double> _barrierOpacityAnimation;
  int _page = 0;
  late bool _visible = !widget.initiallyCompleted;
  bool _accountManagerMode = false;
  bool _showForumCampusAccountHint = false;
  bool _showForumDirectUnavailableHint = false;
  bool _webVpnExpanded = false;
  bool _changingWebVpn = false;
  late bool _academicLoggedIn = widget.initialAcademicLoggedIn;
  late ForumAccountStatus _forumStatus = widget.initialForumStatus;
  late bool _webVpnEnabled = widget.controller.webVpnEnabled;
  late WebVpnServiceStatus _webVpnServiceStatus =
      widget.controller.webVpnServiceStatus;
  late int _handledOpenRequest;
  Timer? _panelNoticeTimer;
  String? _panelNotice;

  @override
  void initState() {
    super.initState();
    _handledOpenRequest = widget.controller.openRequest;
    _panelAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 240),
    );
    final curvedAnimation = CurvedAnimation(
      parent: _panelAnimationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _panelSlideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(curvedAnimation);
    _barrierOpacityAnimation = CurvedAnimation(
      parent: _panelAnimationController,
      curve: const Interval(0, .72, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    widget.controller.addListener(_handleControllerChange);
    widget.controller.setAccountManagerDismissHandler(_dismissFromSystemBack);
    if (_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _panelAnimationController.forward();
      });
    }
  }

  @override
  void didUpdateWidget(covariant StartupOnboarding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
      _handledOpenRequest = widget.controller.openRequest;
    }
    if (widget.initialAcademicLoggedIn != oldWidget.initialAcademicLoggedIn) {
      _academicLoggedIn = widget.initialAcademicLoggedIn;
      if (_academicLoggedIn) _showForumCampusAccountHint = false;
    }
    if (widget.initialForumStatus != oldWidget.initialForumStatus) {
      _forumStatus = widget.initialForumStatus;
    }
  }

  void _handleControllerChange() {
    if (!mounted) return;
    final shouldOpen = _handledOpenRequest != widget.controller.openRequest;
    if (!shouldOpen) {
      setState(() {
        _academicLoggedIn = widget.controller.academicLoggedIn;
        _forumStatus = widget.controller.forumStatus;
        _webVpnEnabled = widget.controller.webVpnEnabled;
        _webVpnServiceStatus = widget.controller.webVpnServiceStatus;
        if (_academicLoggedIn) _showForumCampusAccountHint = false;
        if (_forumStatus != ForumAccountStatus.directLoginUnavailable) {
          _showForumDirectUnavailableHint = false;
        }
      });
      return;
    }
    _handledOpenRequest = widget.controller.openRequest;
    setState(() {
      _visible = true;
      _accountManagerMode = true;
      _page = 2;
      _academicLoggedIn = widget.controller.academicLoggedIn;
      _forumStatus = widget.controller.forumStatus;
      _webVpnEnabled = widget.controller.webVpnEnabled;
      _webVpnServiceStatus = widget.controller.webVpnServiceStatus;
      _showForumCampusAccountHint = false;
      _showForumDirectUnavailableHint = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(2);
      }
      if (mounted) _panelAnimationController.forward(from: 0);
    });
  }

  Future<void> _continue() async {
    if (_page == 1) {
      final permissionGranted = await (widget.notificationPermissionRequester ??
          _requestNotifications)();
      if (!mounted) return;
      if (permissionGranted == false) {
        _showPanelNotice('通知权限未开启，可稍后在系统设置中开启');
      } else if (permissionGranted == null) {
        _showPanelNotice('通知权限请求失败，可稍后在系统设置中开启');
      }
    }
    if (!mounted) return;
    if (_page < 2) {
      await _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      if (mounted) setState(() => _page++);
      return;
    }
    if (_accountManagerMode) {
      await _complete();
      return;
    }
    if (_academicLoggedIn && _forumStatus == ForumAccountStatus.loggedIn) {
      await _complete();
    }
  }

  Future<bool?> _requestNotifications() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        final enabled = await android.areNotificationsEnabled();
        if (enabled == true) return true;
        return await android.requestNotificationsPermission();
      }

      final ios = plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return await ios.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
      return true;
    } on Object {
      return null;
    }
  }

  Future<void> _openAcademicLogin() async {
    final result = await Navigator.of(context).push<NativeLoginResult>(
      MaterialPageRoute(builder: (_) => const NativeLoginPage()),
    );
    if (result == NativeLoginResult.demo) {
      await _enterDemoMode();
      return;
    }
    if (result != NativeLoginResult.authenticated || !mounted) return;
    setState(() {
      _academicLoggedIn = true;
      _showForumCampusAccountHint = false;
    });
    widget.onAcademicLoginCompleted();
    if (!_accountManagerMode && mounted) {
      await _complete();
    }
  }

  Future<void> _logoutAcademic() async {
    final callback =
        widget.onAcademicLogout ?? widget.controller.logoutAcademic;
    final confirmed = await _confirmLogout(
      title: '退出上大校园账户？',
      message: '退出后课表需要重新登录教务系统，论坛账户不会受影响。',
    );
    if (!confirmed || !mounted) return;
    final loggedOut = await callback();
    if (loggedOut && mounted) {
      _showPanelNotice('已退出上大校园账户');
    }
  }

  Future<void> _openForumLogin() async {
    if (defaultTargetPlatform == TargetPlatform.iOS && !_webVpnEnabled) {
      _showPanelNotice('iOS暂时仅支持开启webvpn访问');
      return;
    }
    if (_showForumCampusAccountHint) {
      setState(() => _showForumCampusAccountHint = false);
    }
    final result = await Navigator.of(context).push<NativeLoginResult>(
      MaterialPageRoute(builder: (_) => const NativeLoginPage.forum()),
    );
    if (result == NativeLoginResult.demo) {
      await _enterDemoMode();
      return;
    }
    if (result != NativeLoginResult.authenticated || !mounted) return;
    setState(() => _forumStatus = ForumAccountStatus.connecting);
    widget.onForumLoginCompleted();
  }

  Future<void> _enterDemoMode() async {
    if (!mounted) return;
    setState(() {
      _academicLoggedIn = true;
      _forumStatus = ForumAccountStatus.loggedIn;
      _showForumCampusAccountHint = false;
    });
    await widget.onDemoLogin?.call();
    if (!mounted) return;
    await _complete();
  }

  Future<void> _logoutForum() async {
    final callback = widget.onForumLogout ?? widget.controller.logoutForum;
    final confirmed = await _confirmLogout(
      title: '退出乐乎论坛账户？',
      message: '退出后将清除论坛会话和本地账户数据，校园账户不会受影响。',
    );
    if (!confirmed || !mounted) return;
    final loggedOut = await callback();
    if (loggedOut && mounted) {
      _showPanelNotice('已退出乐乎论坛账户');
    }
  }

  Future<bool> _confirmLogout({
    required String title,
    required String message,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _reconnectForum() {
    if (_showForumCampusAccountHint) {
      setState(() => _showForumCampusAccountHint = false);
    }
    widget.controller.reconnectForum();
  }

  Future<void> _restoreForumAfterAcademicLogin() async {
    await _openAcademicLogin();
    if (!mounted || !_academicLoggedIn) return;
    setState(() => _forumStatus = ForumAccountStatus.connecting);
    widget.controller.reconnectForum();
  }

  void _showDirectForumUnavailableHint() {
    if (_showForumDirectUnavailableHint) return;
    setState(() => _showForumDirectUnavailableHint = true);
  }

  void _showPanelNotice(String message) {
    _panelNoticeTimer?.cancel();
    setState(() => _panelNotice = message);
    _panelNoticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _panelNotice == message) {
        setState(() => _panelNotice = null);
      }
    });
  }

  Future<void> _complete() async {
    if (!_accountManagerMode) {
      await _settingsService.saveStartupOnboardingCompleted(true);
    }
    await _hidePanel();
  }

  Future<void> _goBack() async {
    if (_page <= 0) return;
    await _pageController.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    if (mounted) setState(() => _page--);
  }

  Future<void> _closeAccountManager() async {
    if (_accountManagerMode) await _hidePanel();
  }

  void _handlePanelDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta == 0) return;
    final panelHeight = MediaQuery.sizeOf(context).height * .86;
    _panelAnimationController.value =
        (_panelAnimationController.value - delta / panelHeight).clamp(0, 1);
  }

  void _handlePanelDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 500 || _panelAnimationController.value < .8) {
      unawaited(_hidePanel());
      return;
    }
    unawaited(_panelAnimationController.forward());
  }

  Future<void> _hidePanel() async {
    if (!_visible) return;
    await _panelAnimationController.reverse();
    if (mounted) setState(() => _visible = false);
    if (_accountManagerMode) widget.controller.markAccountManagerClosed();
  }

  void _dismissFromSystemBack() {
    if (_visible) unawaited(_hidePanel());
  }

  @override
  void dispose() {
    widget.controller.setAccountManagerDismissHandler(null);
    widget.controller.removeListener(_handleControllerChange);
    _panelAnimationController.dispose();
    _pageController.dispose();
    _panelNoticeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // When opened from the home account row this panel is the foremost
      // surface. Consume the first back gesture/key to dismiss it instead of
      // allowing the shell underneath to process the back action.
      canPop: !_visible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _accountManagerMode && _visible) {
          unawaited(_hidePanel());
        }
      },
      child: Stack(
        children: [
          widget.child,
          if (_visible) ...[
            Positioned.fill(
              child: FadeTransition(
                opacity: _barrierOpacityAnimation,
                child: ModalBarrier(
                  color: Colors.black.withValues(alpha: .32),
                  dismissible: _accountManagerMode,
                  onDismiss: _accountManagerMode
                      ? () => unawaited(_hidePanel())
                      : null,
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: _panelSlideAnimation,
                child: _panel(context),
              ),
            ),
            _panelNoticeOverlay(context),
          ],
        ],
      ),
    );
  }

  Widget _panelNoticeOverlay(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(context).bottom + 96,
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _panelNotice == null
              ? const SizedBox.shrink()
              : Material(
                  key: ValueKey(_panelNotice),
                  color: colors.inverseSurface,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: colors.onInverseSurface,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _panelNotice!,
                            style: TextStyle(color: colors.onInverseSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showFooter = _accountManagerMode || _page < 2;
    return Material(
      key: const ValueKey('startup-onboarding-panel'),
      color: colors.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: MediaQuery.sizeOf(context).height * .86,
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('startup-onboarding-drag-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate:
                    _accountManagerMode ? _handlePanelDragUpdate : null,
                onVerticalDragEnd:
                    _accountManagerMode ? _handlePanelDragEnd : null,
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      if (_page > 0)
                        Positioned(
                          left: 8,
                          top: 4,
                          child: IconButton(
                            tooltip: '返回上一页',
                            onPressed: _goBack,
                            icon: const Icon(Icons.arrow_back),
                          ),
                        ),
                      if (_accountManagerMode)
                        Positioned(
                          right: 8,
                          top: 4,
                          child: IconButton(
                            tooltip: '关闭',
                            onPressed: _closeAccountManager,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  key: const ValueKey('startup-onboarding-pages'),
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _welcome(context),
                    _notifications(context),
                    _login(context),
                  ],
                ),
              ),
              SizedBox(
                key: const ValueKey('startup-onboarding-footer'),
                height: 78,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
                  child: showFooter
                      ? FilledButton(
                          onPressed: _continue,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            _accountManagerMode && _page == 2
                                ? '完成'
                                : _page == 2
                                    ? '开始使用'
                                    : '继续',
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcome(BuildContext context) => _content(
        context,
        '欢迎使用ShuYo',
        null,
        [
          _feature(Icons.calendar_month, '课表与空教室', '快速查看课程安排和可用教室'),
          _feature(Icons.forum_outlined, '乐乎论坛', '浏览校园动态，参与讨论'),
          _feature(Icons.notifications_none, '重要提醒', '不错过课程和校园公告'),
        ],
        pageFooter: _terms(context),
      );

  Widget _notifications(BuildContext context) => _content(
        context,
        '开启通知权限',
        null,
        [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              'ShuYo 会发送上课提醒，请在下一步中授予我们推送通知权限，'
              '你可以随时在系统设置中关闭通知',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 16,
                height: 1.5,
              ),
            ),
          ),
        ],
      );

  Widget _login(BuildContext context) => _pageLayout(
        context,
        header: _pageHeader(
          context,
          title: '账号管理',
          subtitle: _accountManagerMode
              ? '管理校园服务、乐乎论坛和WebVPN连接。'
              : '登录教务系统后，ShuYo将为你同步课表',
          subtitlePadding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        headerSpacing: 22,
        bottomChildren: [
          _accountTile(
            context,
            icon: Icons.school_outlined,
            title: '上大校园账户',
            description: '用于访问课程表等教务服务',
            statusLabel: _academicLoggedIn ? '已登录' : null,
            onTap: _academicLoggedIn
                ? (widget.onAcademicLogout == null &&
                        !widget.controller.canLogoutAcademic
                    ? null
                    : _logoutAcademic)
                : _openAcademicLogin,
          ),
          if (_accountManagerMode) ...[
            _forumAccountTile(context),
            _forumCampusAccountHint(context),
            _forumDirectUnavailableHint(context),
            _webVpnSection(context),
          ],
        ],
      );

  Widget _webVpnSection(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final presentation = _webVpnStatusPresentation(colors);
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom:
              BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
        ),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.only(left: 56, right: 4),
            title: const Text('使用WebVPN连接'),
            trailing: Icon(
              _webVpnExpanded ? Icons.expand_less : Icons.expand_more,
            ),
            onTap: () => setState(() => _webVpnExpanded = !_webVpnExpanded),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _webVpnExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          '若使用WebVPN代理，你需要完成上海大学统一认证，完成后可通过校外网络直接访问校内服务，但需注意该服务可能不稳定。',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_changingWebVpn)
                        const Padding(
                          padding: EdgeInsets.only(top: 12, right: 4),
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      Switch(
                        value: _webVpnEnabled,
                        onChanged: _changingWebVpn ? null : _changeWebVpn,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: presentation.$1,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: Text(presentation.$2)),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '最近检查：${_webVpnCheckedAtText()}',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  (Color, String) _webVpnStatusPresentation(ColorScheme colors) {
    return switch (_webVpnServiceStatus.effectiveStateAt(DateTime.now())) {
      WebVpnServiceState.available => (colors.primary, '当前WebVPN服务可用'),
      WebVpnServiceState.degraded => (Colors.orange, '当前WebVPN服务可能不稳定'),
      WebVpnServiceState.unavailable => (colors.error, '当前WebVPN服务不可用'),
      WebVpnServiceState.unknown => (colors.outline, '暂时无法获取WebVPN服务状态'),
    };
  }

  String _webVpnCheckedAtText() {
    final checkedAt = _webVpnServiceStatus.checkedAt?.toLocal();
    if (checkedAt == null) return '尚未取得检查结果';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${checkedAt.year}-${two(checkedAt.month)}-${two(checkedAt.day)} '
        '${two(checkedAt.hour)}:${two(checkedAt.minute)}';
  }

  Future<void> _changeWebVpn(bool enabled) async {
    if (_changingWebVpn) return;
    if (enabled &&
        !_webVpnEnabled &&
        _forumStatus == ForumAccountStatus.loggedIn) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('开启WebVPN连接'),
              content: const Text('开启后需要重新登录论坛账户'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('继续'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
    } else if (!enabled) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('关闭WebVPN连接'),
              content: const Text('关闭后需重新登录论坛账户'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
    }
    setState(() => _changingWebVpn = true);
    final changed = await widget.controller.setWebVpnEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _changingWebVpn = false;
      if (changed) _webVpnEnabled = enabled;
    });
  }

  Widget _forumCampusAccountHint(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: _showForumCampusAccountHint
          ? Padding(
              key: const ValueKey('forum-campus-account-hint'),
              padding: const EdgeInsets.fromLTRB(56, 0, 4, 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: colors.error),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '请先登录上大校园账户',
                      style: TextStyle(
                        color: colors.error,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(
              key: ValueKey('forum-campus-account-hint-hidden'),
            ),
    );
  }

  Widget _forumDirectUnavailableHint(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: _showForumDirectUnavailableHint
          ? Padding(
              key: const ValueKey('forum-direct-unavailable-hint'),
              padding: const EdgeInsets.fromLTRB(56, 0, 4, 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: colors.error),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'iOS暂时仅支持开启webvpn访问',
                      style: TextStyle(
                        color: colors.error,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(key: ValueKey('forum-direct-unavailable-hidden')),
    );
  }

  Widget _forumAccountTile(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, color, busy, onTap) = switch (_forumStatus) {
      ForumAccountStatus.signedOut => (
          null,
          null,
          false,
          _openForumLogin as VoidCallback
        ),
      ForumAccountStatus.connecting => (
          '正在连接',
          colors.onSurfaceVariant,
          true,
          null
        ),
      ForumAccountStatus.loggedIn => (
          '已登录',
          colors.primary,
          false,
          widget.onForumLogout == null && !widget.controller.canLogoutForum
              ? null
              : _logoutForum,
        ),
      ForumAccountStatus.connectionUnavailable => (
          '连接异常',
          colors.error,
          false,
          _reconnectForum,
        ),
      ForumAccountStatus.webVpnLoginRequired => (
          'WebVPN已失效',
          colors.error,
          false,
          _showWebVpnLoginRequired,
        ),
      ForumAccountStatus.waitingForAcademicLogin => (
          '等待校园账户登录',
          colors.error,
          false,
          _restoreForumAfterAcademicLogin as VoidCallback,
        ),
      ForumAccountStatus.reauthenticationRequired => (
          '登录已失效',
          colors.error,
          false,
          _openForumLogin as VoidCallback,
        ),
      ForumAccountStatus.directLoginUnavailable => (
          '暂不可登录',
          colors.error,
          false,
          _showDirectForumUnavailableHint,
        ),
    };
    return _accountTile(
      context,
      icon: Icons.forum_outlined,
      title: '乐乎账户',
      description: '用于访问上海大学校内论坛',
      statusLabel: label,
      statusColor: color,
      busy: busy,
      onTap: onTap,
    );
  }

  void _showWebVpnLoginRequired() {
    setState(() => _webVpnExpanded = true);
    _showPanelNotice('WebVPN已失效，需要重新登录');
  }

  Widget _accountTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    String? statusLabel,
    Color? statusColor,
    bool busy = false,
    required VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 4, 20),
          child: Row(
            children: [
              Icon(icon, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (statusLabel != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor ?? colors.primary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (busy) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ] else if (onTap != null) ...[
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(
      BuildContext context, String title, String? subtitle, List<Widget> items,
      {Widget? pageFooter}) {
    return _pageLayout(
      context,
      header: _pageHeader(context, title: title, subtitle: subtitle),
      bottomChildren: items,
      pageFooter: pageFooter,
    );
  }

  Widget _pageLayout(
    BuildContext context, {
    required Widget header,
    required List<Widget> bottomChildren,
    Widget? pageFooter,
    double headerSpacing = 32,
  }) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                SizedBox(height: headerSpacing),
                ...bottomChildren,
              ],
            ),
          ),
        ),
        if (pageFooter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: pageFooter,
          ),
      ],
    );
  }

  Widget _pageHeader(
    BuildContext context, {
    required String title,
    String? subtitle,
    EdgeInsets subtitlePadding = EdgeInsets.zero,
  }) {
    return Center(
      child: Column(
        children: [
          Image.asset(
            'assets/images/icon_clear_blue.png',
            width: 88,
            height: 88,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: subtitlePadding,
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _terms(BuildContext context) => Center(
        child: Text.rich(
          TextSpan(
            text: '继续即表示您已同意我们的',
            children: [
              _link(context, '使用条款', 'https://shuyo.work/doc/terms.html'),
              const TextSpan(text: '和'),
              _link(context, '隐私政策', 'https://shuyo.work/doc/privacy.html'),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      );

  InlineSpan _link(BuildContext context, String label, String url) =>
      WidgetSpan(
        child: GestureDetector(
          onTap: () => launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      );

  Widget _feature(
    IconData icon,
    String title,
    String description,
  ) =>
      Padding(
        padding: const EdgeInsets.only(left: 32, bottom: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 26),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 17,
                      ),
                    ),
                    Text(
                      description,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
