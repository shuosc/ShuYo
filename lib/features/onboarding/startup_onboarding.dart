import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/client_backend.dart';
import '../../data/models/classroom.dart';
import '../../data/services/client_settings_service.dart';
import '../../data/services/student_identity_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/widgets/webvpn_toggle.dart';
import '../auth/native_login_page.dart';
import '../settings/student_identity_page.dart';

class StartupOnboardingController extends ChangeNotifier {
  bool _academicLoggedIn = false;
  bool _academicSessionExpired = false;
  VoidCallback? _onDismissAccountManager;
  Future<bool> Function()? _onAcademicLogout;
  Future<bool> Function(bool enabled)? _onWebVpnChanged;
  Future<bool> Function(String? nickname)? _onNicknameChanged;
  Future<bool> Function(String campus)? _onCampusChanged;
  String? _academicStudentId;
  String? _nickname;
  String _preferredCampus = ClassroomCampus.defaultName;
  bool _webVpnEnabled = false;
  bool _webVpnPendingRecovery = false;
  bool _webVpnSessionReady = false;
  WebVpnServiceStatus _webVpnServiceStatus =
      const WebVpnServiceStatus.unknown();
  int _openRequest = 0;
  bool _accountManagerOpen = false;
  bool _notificationScheduled = false;
  bool _disposed = false;

  bool get academicLoggedIn => _academicLoggedIn;
  bool get academicSessionExpired => _academicSessionExpired;
  String? get academicStudentId => _academicStudentId;
  String? get nickname => _nickname;
  String? get displayName => _nickname ?? _academicStudentId;
  String get preferredCampus => _preferredCampus;
  int get openRequest => _openRequest;
  bool get accountManagerOpen => _accountManagerOpen;
  bool get webVpnEnabled => _webVpnEnabled;
  bool get webVpnPendingRecovery => _webVpnPendingRecovery;
  bool get webVpnSessionReady => _webVpnSessionReady;
  WebVpnServiceStatus get webVpnServiceStatus => _webVpnServiceStatus;

  void openAccountManager({
    required bool academicLoggedIn,
    bool academicSessionExpired = false,
    bool webVpnEnabled = false,
    bool webVpnPendingRecovery = false,
    bool webVpnSessionReady = false,
    WebVpnServiceStatus webVpnServiceStatus =
        const WebVpnServiceStatus.unknown(),
  }) {
    _academicLoggedIn = academicLoggedIn;
    _academicSessionExpired = !academicLoggedIn && academicSessionExpired;
    _webVpnEnabled = webVpnEnabled;
    _webVpnPendingRecovery = webVpnPendingRecovery;
    _webVpnSessionReady = webVpnSessionReady;
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

  void updateAccountStatus({
    required bool academicLoggedIn,
    bool academicSessionExpired = false,
    bool? webVpnEnabled,
    bool? webVpnPendingRecovery,
    bool? webVpnSessionReady,
    WebVpnServiceStatus? webVpnServiceStatus,
  }) {
    final nextEnabled = webVpnEnabled ?? _webVpnEnabled;
    final nextPendingRecovery = webVpnPendingRecovery ?? _webVpnPendingRecovery;
    final nextSessionReady = webVpnSessionReady ?? _webVpnSessionReady;
    final nextStatus = webVpnServiceStatus ?? _webVpnServiceStatus;
    if (_academicLoggedIn == academicLoggedIn &&
        _academicSessionExpired ==
            (!academicLoggedIn && academicSessionExpired) &&
        _webVpnEnabled == nextEnabled &&
        _webVpnPendingRecovery == nextPendingRecovery &&
        _webVpnSessionReady == nextSessionReady &&
        identical(_webVpnServiceStatus, nextStatus)) {
      return;
    }
    _academicLoggedIn = academicLoggedIn;
    _academicSessionExpired = !academicLoggedIn && academicSessionExpired;
    _webVpnEnabled = nextEnabled;
    _webVpnPendingRecovery = nextPendingRecovery;
    _webVpnSessionReady = nextSessionReady;
    _webVpnServiceStatus = nextStatus;
    _notifyListenersSafely();
  }

  void setWebVpnChangeHandler(
    Future<bool> Function(bool enabled)? handler,
  ) {
    _onWebVpnChanged = handler;
  }

  Future<bool> setWebVpnEnabled(bool enabled) async =>
      await _onWebVpnChanged?.call(enabled) ?? false;

  void updateProfile({
    required String? studentId,
    required String? nickname,
    required String preferredCampus,
  }) {
    if (_academicStudentId == studentId &&
        _nickname == nickname &&
        _preferredCampus == preferredCampus) {
      return;
    }
    _academicStudentId = studentId;
    _nickname = nickname;
    _preferredCampus = preferredCampus;
    _notifyListenersSafely();
  }

  void setProfileChangeHandlers({
    Future<bool> Function(String? nickname)? onNicknameChanged,
    Future<bool> Function(String campus)? onCampusChanged,
  }) {
    _onNicknameChanged = onNicknameChanged;
    _onCampusChanged = onCampusChanged;
  }

  Future<bool> saveNickname(String? nickname) async =>
      await _onNicknameChanged?.call(nickname) ?? false;

  Future<bool> savePreferredCampus(String campus) async =>
      await _onCampusChanged?.call(campus) ?? false;

  void setAccountLogoutHandlers({
    Future<bool> Function()? onAcademicLogout,
  }) {
    _onAcademicLogout = onAcademicLogout;
  }

  Future<bool> logoutAcademic() async =>
      await _onAcademicLogout?.call() ?? false;

  bool get canLogoutAcademic => _onAcademicLogout != null;

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
    _onAcademicLogout = null;
    _onWebVpnChanged = null;
    _onNicknameChanged = null;
    _onCampusChanged = null;
    super.dispose();
  }
}

class StartupOnboarding extends StatefulWidget {
  const StartupOnboarding({
    super.key,
    required this.child,
    required this.initiallyCompleted,
    required this.initialAcademicLoggedIn,
    this.initialAcademicSessionExpired = false,
    required this.onAcademicLoginCompleted,
    this.onDemoLogin,
    this.onAcademicLogout,
    required this.controller,
    this.settingsService,
    this.notificationPermissionRequester,
    this.studentIdentityService,
  });

  final Widget child;
  final bool initiallyCompleted;
  final bool initialAcademicLoggedIn;
  final bool initialAcademicSessionExpired;
  final VoidCallback onAcademicLoginCompleted;
  final Future<void> Function()? onDemoLogin;
  final Future<bool> Function()? onAcademicLogout;
  final StartupOnboardingController controller;
  final ClientSettingsService? settingsService;
  final Future<bool?> Function()? notificationPermissionRequester;
  final StudentIdentityService? studentIdentityService;

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
  bool _webVpnExpanded = false;
  bool _changingWebVpn = false;
  bool _choosingIdentity = false;
  late bool _academicLoggedIn = widget.initialAcademicLoggedIn;
  late bool _academicSessionExpired = widget.initialAcademicSessionExpired;
  late bool _webVpnEnabled = widget.controller.webVpnEnabled;
  late bool _webVpnPendingRecovery = widget.controller.webVpnPendingRecovery;
  late WebVpnServiceStatus _webVpnServiceStatus =
      widget.controller.webVpnServiceStatus;
  late int _handledOpenRequest;
  Timer? _panelNoticeTimer;
  String? _panelNotice;
  int get _loginPageIndex => widget.studentIdentityService == null ? 2 : 3;
  bool get _onIdentityPage =>
      widget.studentIdentityService != null && _page == 2;

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
    }
    if (widget.initialAcademicSessionExpired !=
        oldWidget.initialAcademicSessionExpired) {
      _academicSessionExpired = widget.initialAcademicSessionExpired;
    }
  }

  void _handleControllerChange() {
    if (!mounted) return;
    final shouldOpen = _handledOpenRequest != widget.controller.openRequest;
    if (!shouldOpen) {
      setState(() {
        _academicLoggedIn = widget.controller.academicLoggedIn;
        _academicSessionExpired = widget.controller.academicSessionExpired;
        _webVpnEnabled = widget.controller.webVpnEnabled;
        _webVpnPendingRecovery = widget.controller.webVpnPendingRecovery;
        _webVpnServiceStatus = widget.controller.webVpnServiceStatus;
      });
      return;
    }
    _handledOpenRequest = widget.controller.openRequest;
    setState(() {
      _visible = true;
      _accountManagerMode = true;
      _page = _loginPageIndex;
      _academicLoggedIn = widget.controller.academicLoggedIn;
      _academicSessionExpired = widget.controller.academicSessionExpired;
      _webVpnEnabled = widget.controller.webVpnEnabled;
      _webVpnPendingRecovery = widget.controller.webVpnPendingRecovery;
      _webVpnServiceStatus = widget.controller.webVpnServiceStatus;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_loginPageIndex);
      }
      if (mounted) _panelAnimationController.forward(from: 0);
      if (mounted) unawaited(_maybePresentOldUserIdentityChoice());
    });
  }

  Future<void> _maybePresentOldUserIdentityChoice() async {
    final service = widget.studentIdentityService;
    if (service == null) return;
    try {
      await service.refreshLocalStatus();
      final answered = await service.hasAnsweredConsent();
      if (!mounted ||
          !_accountManagerMode ||
          !_visible ||
          answered ||
          service.isVerified) {
        return;
      }
      await _showIdentityChoicePage();
    } on Object {
      // Account manager stays usable if local identity storage is unavailable.
    }
  }

  Future<void> _showIdentityChoicePage() async {
    if (!mounted || widget.studentIdentityService == null) return;
    await _pageController.animateToPage(2,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic);
    if (mounted) setState(() => _page = 2);
  }

  Future<void> _chooseIdentity(bool confirmed) async {
    final service = widget.studentIdentityService;
    if (service == null || _choosingIdentity) return;
    setState(() => _choosingIdentity = true);
    try {
      if (confirmed) {
        await service.grantConsent();
      } else {
        await service.declineConsent();
      }
      if (!mounted) return;
      await _pageController.animateToPage(_loginPageIndex,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic);
      if (!mounted) return;
      setState(() => _page = _loginPageIndex);
      if (confirmed && _accountManagerMode && _academicLoggedIn) {
        unawaited(service.ensureAfterCampusLogin());
      }
    } on Object {
      if (mounted) _showPanelNotice('暂时无法保存选择，请重试');
    } finally {
      if (mounted) setState(() => _choosingIdentity = false);
    }
  }

  void _openIdentityStatus() {
    final service = widget.studentIdentityService;
    if (service == null) return;
    Navigator.of(context).push<void>(
      shuyoRoute(builder: (_) => StudentIdentityPage(service: service)),
    );
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
    if (_page < _loginPageIndex) {
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
    if (_academicLoggedIn) {
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
      MaterialPageRoute(
        builder: (_) => const ShuYoRouteSurface(child: NativeLoginPage()),
      ),
    );
    if (result == NativeLoginResult.demo) {
      await _enterDemoMode();
      return;
    }
    if (result != NativeLoginResult.authenticated || !mounted) return;
    setState(() {
      _academicLoggedIn = true;
      _academicSessionExpired = false;
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
      title: '确认退出',
      message: '退出后将需要重新登录，仍可查看已保存的课表和学业信息',
    );
    if (!confirmed || !mounted) return;
    final loggedOut = await callback();
    if (loggedOut && mounted) {
      _showPanelNotice('已退出上大校园账户');
    }
  }

  Future<void> _enterDemoMode() async {
    if (!mounted) return;
    setState(() {
      _academicLoggedIn = true;
    });
    await widget.onDemoLogin?.call();
    if (!mounted) return;
    await _complete();
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
    final showFooter = _accountManagerMode || _page < _loginPageIndex;
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
                    if (widget.studentIdentityService != null)
                      _identityChoice(context),
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
                          onPressed: _onIdentityPage
                              ? (_choosingIdentity
                                  ? null
                                  : () => _chooseIdentity(true))
                              : _continue,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            _onIdentityPage
                                ? '确认'
                                : _accountManagerMode &&
                                        _page == _loginPageIndex
                                    ? '完成'
                                    : _page == _loginPageIndex
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
          _feature(Icons.map_outlined, '校园服务', '探索更多校园生活功能'),
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

  Widget _identityChoice(BuildContext context) => _content(
        context,
        '身份验证',
        null,
        [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              '为避免身份冒用，ShuYo将验证你的校园身份，认证后可使用分享课程表、课程评价等功能。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 16,
                height: 1.5,
              ),
            ),
          ),
        ],
        pageFooter: Center(
          child: TextButton(
            onPressed: _choosingIdentity ? null : () => _chooseIdentity(false),
            child: const Text('暂不'),
          ),
        ),
        pageFooterBottomPadding: 6,
      );

  Widget _login(BuildContext context) => _pageLayout(
        context,
        header: Column(
          children: [
            _pageHeader(
              context,
              title: '账号管理',
              subtitle: _accountManagerMode ? null : '登录教务系统后，ShuYo将为你同步课表',
              subtitlePadding: const EdgeInsets.symmetric(horizontal: 18),
            ),
            if (_accountManagerMode) ...[
              const SizedBox(height: 8),
              if (widget.studentIdentityService != null) ...[
                _identityStatusUnderTitle(context),
                const SizedBox(height: 6),
              ],
              _profileRow(context),
            ],
          ],
        ),
        headerSpacing: 22,
        bottomChildren: [
          _accountTile(
            context,
            icon: Icons.school_outlined,
            title: '上大校园账户',
            description: '用于访问课程表等校园服务',
            statusLabel: _academicLoggedIn
                ? '已登录'
                : _academicSessionExpired
                    ? '登录已失效'
                    : null,
            statusColor: _academicSessionExpired
                ? Theme.of(context).colorScheme.error
                : null,
            onTap: _academicLoggedIn
                ? (widget.onAcademicLogout == null &&
                        !widget.controller.canLogoutAcademic
                    ? null
                    : _logoutAcademic)
                : _openAcademicLogin,
          ),
          if (_accountManagerMode) ...[
            _webVpnSection(context),
          ],
        ],
      );

  Widget _identityStatusUnderTitle(BuildContext context) {
    final service = widget.studentIdentityService!;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final verified = service.isVerified;
        final colors = Theme.of(context).colorScheme;
        final color = verified
            ? colors.primary
            : Theme.of(context).brightness == Brightness.dark
                ? colors.onSurface
                : Colors.black;
        return Center(
          child: InkWell(
            key: const ValueKey('student-identity-status'),
            borderRadius: BorderRadius.circular(12),
            onTap: _openIdentityStatus,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(verified ? Icons.check_circle : Icons.cancel,
                      size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(
                    verified ? '已认证' : '未认证',
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _profileRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final studentId = widget.controller.academicStudentId;
    final canEditNickname = _academicLoggedIn && studentId != null;
    final name = canEditNickname
        ? widget.controller.displayName ?? studentId
        : '登录后设置昵称';
    final style = TextStyle(
      color: color,
      decoration: TextDecoration.underline,
      decorationColor: color,
    );
    final profileRow = Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: InkWell(
                key: const Key('nickname-edit'),
                onTap: canEditNickname ? _editNickname : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.edit_outlined, size: 16, color: color),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            PopupMenuButton<String>(
              key: const Key('campus-select'),
              tooltip: '选择校区',
              position: PopupMenuPosition.under,
              color: Colors.white,
              surfaceTintColor: Colors.transparent,
              itemBuilder: (context) => [
                for (final campus in ClassroomCampus.knownNames)
                  PopupMenuItem<String>(
                    value: campus,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            campus,
                            style: const TextStyle(color: Colors.black87),
                          ),
                        ),
                        if (campus == widget.controller.preferredCampus)
                          const Icon(Icons.check, color: Colors.black87),
                      ],
                    ),
                  ),
              ],
              onSelected: (campus) => unawaited(_saveCampus(campus)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('校区：${widget.controller.preferredCampus}', style: style),
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 18, color: color),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Theme(
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: profileRow,
    );
  }

  Future<void> _editNickname() async {
    final studentId = widget.controller.academicStudentId;
    if (!_academicLoggedIn || studentId == null) return;
    var input = widget.controller.nickname ?? '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑昵称'),
        content: TextFormField(
          initialValue: input,
          autofocus: true,
          maxLength: 20,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: studentId),
          onChanged: (value) => input = value,
          onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(input),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (!await widget.controller.saveNickname(value) && mounted) {
      _showPanelNotice('昵称保存失败，请稍后重试');
    }
  }

  Future<void> _saveCampus(String selected) async {
    if (selected == widget.controller.preferredCampus || !mounted) {
      return;
    }
    if (!await widget.controller.savePreferredCampus(selected) && mounted) {
      _showPanelNotice('校区保存失败，请稍后重试');
    }
  }

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
            title: Text(
                _webVpnPendingRecovery ? '使用WebVPN连接 · 登录待恢复' : '使用WebVPN连接'),
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
                          '启用后，可使用外部网络访问校内服务',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      WebVpnToggle(
                        value: _webVpnEnabled,
                        changing: _changingWebVpn,
                        onChanged: _changeWebVpn,
                      ),
                    ],
                  ),
                  if (_webVpnPendingRecovery)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed:
                            _changingWebVpn ? null : () => _changeWebVpn(true),
                        icon: const Icon(Icons.refresh),
                        label: const Text('恢复WebVPN登录'),
                      ),
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
    setState(() => _changingWebVpn = true);
    final changed = await widget.controller.setWebVpnEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _changingWebVpn = false;
      if (changed) _webVpnEnabled = enabled;
    });
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
      {Widget? pageFooter, double pageFooterBottomPadding = 12}) {
    return _pageLayout(
      context,
      header: _pageHeader(context, title: title, subtitle: subtitle),
      bottomChildren: items,
      pageFooter: pageFooter,
      pageFooterBottomPadding: pageFooterBottomPadding,
    );
  }

  Widget _pageLayout(
    BuildContext context, {
    required Widget header,
    required List<Widget> bottomChildren,
    Widget? pageFooter,
    double pageFooterBottomPadding = 12,
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
            padding: EdgeInsets.fromLTRB(24, 0, 24, pageFooterBottomPadding),
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
