import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/classroom_url_resolver.dart';
import '../core/app_tab.dart';
import '../core/client_app_info.dart';
import '../core/client_update_policy.dart';
import '../data/demo/demo_data_bundle.dart';
import '../data/demo/demo_repositories.dart';
import '../data/models/client_backend.dart';
import '../data/models/classroom.dart';
import '../data/repositories/academic_schedule_repository.dart';
import '../data/repositories/academic_progress_repository.dart';
import '../data/repositories/academic_ranking_repository.dart';
import '../data/repositories/announcement_repository.dart';
import '../data/repositories/shuyo_content_repository.dart';
import '../data/repositories/classroom_repository.dart';
import '../data/repositories/client_backend_repository.dart';
import '../data/services/academic_account_store.dart';
import '../data/services/academic_native_auth_service.dart';
import '../data/services/academic_profile_preferences.dart';
import '../data/services/academic_auth_service.dart';
import '../data/services/academic_schedule_api_client.dart';
import '../data/services/academic_schedule_display_settings_service.dart';
import '../data/services/academic_schedule_notification_service.dart';
import '../data/services/academic_schedule_widget_service.dart';
import '../data/services/client_settings_service.dart';
import '../data/services/student_identity_service.dart';
import '../data/services/unified_account_service.dart';
import '../data/services/there_booking_client.dart';
import '../data/services/webvpn_session_store.dart';
import '../features/auth/native_login_page.dart';
import '../features/home/academic_schedule_page.dart';
import '../features/home/academic_progress_page.dart';
import '../features/home/announcements_page.dart';
import '../features/home/empty_classroom_page.dart';
import '../features/home/home_dashboard_page.dart';
import '../features/home/shuyo_content_page.dart';
import '../features/library_booking/library_booking_page.dart';
import '../features/onboarding/startup_onboarding.dart';
import '../features/settings/client_settings_page.dart';
import '../shared/navigation/shuyo_route.dart';
import '../shared/widgets/app_header.dart';
import '../shared/widgets/client_update_prompt.dart';
import '../shared/widgets/info_confirm_dialog.dart';
import '../shared/theme/custom_background.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.initialWebVpnEnabled,
    this.initialWebVpnPendingRecovery = false,
    this.initialWebVpnSessionReady = false,
    required this.selectedThemeId,
    required this.followSystemTheme,
    required this.onThemeChanged,
    required this.onFollowSystemThemeChanged,
    this.customBackground,
    this.onCustomBackgroundChanged,
    required this.academicLoginSignal,
    required this.initialHasAcademicSession,
    required this.initialAcademicStudentId,
    this.initialNickname,
    this.initialPreferredCampus = ClassroomCampus.defaultName,
    required this.onboardingController,
    this.initialAcademicSessionExpired = false,
    this.scheduleRepository,
    this.progressRepository,
    this.rankingRepository,
    this.academicAuthService,
    this.studentIdentityService,
    this.unifiedAccountService,
    this.initialOpenSchedule = false,
    this.initialStartupTab = AppTab.home,
    this.initialScheduleState,
    this.initialScheduleDisplayState,
    this.initialScheduleLoadError,
    this.isDemo = false,
    this.demoData,
    this.onExitDemo,
  });

  final bool initialWebVpnEnabled;
  final bool initialWebVpnPendingRecovery;
  final bool initialWebVpnSessionReady;
  final String selectedThemeId;
  final bool followSystemTheme;
  final Future<void> Function(String) onThemeChanged;
  final Future<void> Function(bool) onFollowSystemThemeChanged;
  final CustomBackground? customBackground;
  final Future<void> Function(CustomBackground)? onCustomBackgroundChanged;
  final int academicLoginSignal;
  final bool initialHasAcademicSession;
  final String? initialAcademicStudentId;
  final String? initialNickname;
  final String initialPreferredCampus;
  final StartupOnboardingController onboardingController;
  final bool initialAcademicSessionExpired;
  final AcademicScheduleRepository? scheduleRepository;
  final AcademicProgressRepository? progressRepository;
  final AcademicRankingRepository? rankingRepository;
  final AcademicAuthService? academicAuthService;
  final StudentIdentityService? studentIdentityService;
  final UnifiedAccountService? unifiedAccountService;
  final bool initialOpenSchedule;
  final AppTab initialStartupTab;
  final AcademicScheduleCacheState? initialScheduleState;
  final AcademicScheduleDisplayState? initialScheduleDisplayState;
  final String? initialScheduleLoadError;
  final bool isDemo;
  final DemoDataBundle? demoData;
  final Future<void> Function()? onExitDemo;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _exitBackPressInterval = Duration(seconds: 2);
  static const _webVpnStatusRefreshInterval = Duration(minutes: 5);

  AppTab _tab = AppTab.home;
  late AppTab _preferredStartupTab = widget.initialStartupTab;
  bool _scheduleTabInitialized = false;
  bool _progressTabInitialized = false;
  int _progressDataRevision = 0;
  int _scheduleDataRevision = 0;
  late bool _webVpnEnabled = widget.initialWebVpnEnabled;
  late bool _webVpnPendingRecovery = widget.initialWebVpnPendingRecovery;
  late bool _webVpnSessionReady = widget.initialWebVpnSessionReady;
  late bool _hasAcademicSession = widget.initialHasAcademicSession;
  late String? _academicStudentId = widget.initialAcademicStudentId;
  late String? _nickname = widget.initialNickname;
  late String _preferredCampus = widget.initialPreferredCampus;
  late bool _academicSessionExpired = widget.initialAcademicSessionExpired;
  bool _handlingInvalidAcademicSession = false;
  bool _completingAcademicLogin = false;
  bool _syncingAcademicSchedule = false;
  bool _syncingAcademicExtras = false;
  bool _loadingScheduleSummary = false;
  bool _loadingAnnouncementSummary = false;
  bool _checkingClientBackendPrompts = false;
  bool _refreshingWebVpnStatus = false;
  bool _openingLibraryBooking = false;
  ThereBookingClient? _directBookingClient;
  ThereBookingClient? _webVpnBookingClient;
  Future<WebVpnRecoveryOutcome>? _webVpnRecoveryTask;
  Future<void>? _thereRecoveryTask;
  String _scheduleSummaryText = '正在读取课表...';
  String _announcementSummaryText = '正在读取通知公告...';
  DateTime? _lastWebVpnStatusFetchAttempt;
  DateTime? _lastExitBackAt;
  WebVpnServiceStatus _webVpnServiceStatus =
      const WebVpnServiceStatus.unknown();
  Timer? _scheduleSummaryTimer;
  Timer? _announcementSummaryTimer;
  StreamSubscription<Uri?>? _widgetClickSubscription;

  late final AcademicScheduleRepository _scheduleRepository;
  late final AcademicProgressRepository _progressRepository;
  late final AcademicRankingRepository _rankingRepository;
  late final AcademicAuthService _academicAuthService =
      widget.academicAuthService ?? AcademicAuthService();
  late final AcademicScheduleNotificationService _scheduleNotificationService;
  late final AcademicScheduleWidgetService _scheduleWidgetService;
  late final AnnouncementRepository _announcementRepository;
  late ClassroomRepository _classroomRepository;
  final _clientSettingsService = ClientSettingsService();
  final _profilePreferences = AcademicProfilePreferences();
  late final UnifiedAccountService _unifiedAccountService =
      widget.unifiedAccountService ?? UnifiedAccountService();
  late final StudentIdentityService _studentIdentityService =
      widget.studentIdentityService ?? StudentIdentityService();
  late final ClientBackendRepository _clientBackendRepository =
      ClientBackendRepository(studentIdentityService: _studentIdentityService);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tab =
        widget.initialOpenSchedule ? AppTab.schedule : widget.initialStartupTab;
    _progressTabInitialized = _tab == AppTab.progress;
    _scheduleTabInitialized = _tab == AppTab.schedule;
    final demo = widget.demoData;
    _scheduleRepository = widget.scheduleRepository ??
        (widget.isDemo && demo != null
            ? DemoAcademicScheduleRepository(demo.schedule)
            : AcademicScheduleRepository());
    _progressRepository = widget.progressRepository ??
        (widget.isDemo
            ? DemoAcademicProgressRepository()
            : AcademicProgressRepository());
    _rankingRepository = widget.rankingRepository ??
        (widget.isDemo
            ? DemoAcademicRankingRepository()
            : AcademicRankingRepository());
    _scheduleNotificationService =
        AcademicScheduleNotificationService(repository: _scheduleRepository);
    _scheduleWidgetService =
        AcademicScheduleWidgetService(repository: _scheduleRepository);
    _announcementRepository = widget.isDemo && demo != null
        ? DemoAnnouncementRepository(
            items: demo.announcements,
            details: demo.announcementDetails,
          )
        : AnnouncementRepository();
    _classroomRepository = widget.isDemo && demo != null
        ? DemoClassroomRepository(
            options: demo.classroomOptions,
            schedule: demo.classroomSchedule,
          )
        : ClassroomRepository();
    widget.onboardingController.setAccountLogoutHandlers(
      onAcademicLogout: _logoutAcademicAccount,
    );
    widget.onboardingController
        .setWebVpnChangeHandler(_changeWebVpnFromAccountManager);
    widget.onboardingController.setProfileChangeHandlers(
      onNicknameChanged: _saveNickname,
      onCampusChanged: _savePreferredCampus,
    );
    _syncOnboardingAccountStatus();
    unawaited(_refreshScheduleSummaryQuietly());
    unawaited(_loadAnnouncementSummaryFromCache());
    if (Platform.isAndroid || Platform.isIOS) {
      _widgetClickSubscription = HomeWidget.widgetClicked.listen((uri) {
        if (uri?.scheme == 'shuyo' && uri?.host == 'schedule') {
          _openScheduleFromWidget();
        }
      });
    }
    if (!widget.isDemo) {
      _scheduleSummaryTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => unawaited(_refreshScheduleSummaryQuietly()),
      );
      _announcementSummaryTimer = Timer.periodic(
        AnnouncementRepository.defaultAutoRefreshInterval,
        (_) => unawaited(_refreshAnnouncementSummaryQuietly()),
      );
      unawaited(_scheduleNotificationService.syncScheduleReminders());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshAnnouncementSummaryQuietly());
        unawaited(_checkClientBackendPrompts());
        unawaited(_studentIdentityService.retryPendingRevocations());
        unawaited(_studentIdentityService.refreshLocalStatus());
        unawaited(_clientBackendRepository.reportPresence());
      });
    }
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStartupTab != oldWidget.initialStartupTab) {
      _preferredStartupTab = widget.initialStartupTab;
    }
    if (widget.academicLoginSignal != oldWidget.academicLoginSignal) {
      unawaited(_finishAcademicLogin());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.isDemo || state != AppLifecycleState.resumed) return;
    unawaited(_clientBackendRepository.reportPresence());
    unawaited(_refreshScheduleSummaryQuietly());
    unawaited(_refreshAnnouncementSummaryQuietly());
    unawaited(_scheduleNotificationService.syncScheduleReminders());
    final last = _lastWebVpnStatusFetchAttempt;
    if (last == null ||
        DateTime.now().difference(last) >= _webVpnStatusRefreshInterval) {
      unawaited(_refreshWebVpnStatus());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scheduleSummaryTimer?.cancel();
    _announcementSummaryTimer?.cancel();
    _widgetClickSubscription?.cancel();
    _directBookingClient?.dispose();
    _webVpnBookingClient?.dispose();
    if (widget.studentIdentityService == null) {
      _studentIdentityService.dispose();
    }
    widget.onboardingController.setWebVpnChangeHandler(null);
    widget.onboardingController.setProfileChangeHandlers();
    widget.onboardingController.setAccountLogoutHandlers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleRootPop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              if (_tab == AppTab.home)
                AppHeader(
                  title: AppTab.home.label,
                  showSettings: true,
                  onSettings: _openClientSettings,
                  onNotification: _openNotifications,
                ),
              Expanded(
                child: IndexedStack(
                  index: _tab.index,
                  children: [
                    _homeBody(),
                    _progressTabInitialized
                        ? AcademicProgressPage(
                            key: ValueKey(_progressDataRevision),
                            repository: _progressRepository,
                            rankingRepository: _rankingRepository,
                            onLoginRequired: _handleInvalidAcademicSession,
                          )
                        : const SizedBox.expand(),
                    _scheduleTabInitialized
                        ? AcademicSchedulePage(
                            key: ValueKey(_scheduleDataRevision),
                            repository: _scheduleRepository,
                            notificationService: _scheduleNotificationService,
                            widgetService: _scheduleWidgetService,
                            onLoginRequired: _handleInvalidAcademicSession,
                            studentIdentityService: _studentIdentityService,
                            initialState: widget.initialOpenSchedule &&
                                    _scheduleDataRevision == 0
                                ? widget.initialScheduleState
                                : null,
                            initialDisplayState: widget.initialOpenSchedule &&
                                    _scheduleDataRevision == 0
                                ? widget.initialScheduleDisplayState
                                : null,
                            initialLoadError: widget.initialOpenSchedule &&
                                    _scheduleDataRevision == 0
                                ? widget.initialScheduleLoadError
                                : null,
                          )
                        : const SizedBox.expand(),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tab.index,
          type: BottomNavigationBarType.fixed,
          onTap: (index) => _selectTab(AppTab.values[index]),
          items: [
            for (final tab in AppTab.values)
              BottomNavigationBarItem(
                  icon: Icon(_tabIcon(tab)), label: tab.label),
          ],
        ),
      ),
    );
  }

  void _handleRootPop() {
    if (widget.onboardingController.dismissAccountManager()) return;
    final now = DateTime.now();
    if (_lastExitBackAt != null &&
        now.difference(_lastExitBackAt!) <= _exitBackPressInterval) {
      SystemNavigator.pop();
      return;
    }
    _lastExitBackAt = now;
    _showSnack('再按一次退出 ShuYo');
  }

  IconData _tabIcon(AppTab tab) => switch (tab) {
        AppTab.home => Icons.dashboard,
        AppTab.progress => Icons.school_outlined,
        AppTab.schedule => Icons.calendar_month,
      };

  void _selectTab(AppTab tab) {
    setState(() {
      _tab = tab;
      if (tab == AppTab.progress) _progressTabInitialized = true;
      if (tab == AppTab.schedule) _scheduleTabInitialized = true;
    });
    if (tab == AppTab.home) {
      unawaited(_refreshScheduleSummaryQuietly());
      unawaited(_refreshAnnouncementSummaryQuietly());
    }
  }

  Widget _homeBody() => HomeDashboardPage(
        hasAcademicAccount: _hasAcademicSession,
        academicSessionExpired: _academicSessionExpired,
        academicDisplayName: _nickname ?? _academicStudentId,
        isAcademicLoginCompleting: _syncingAcademicSchedule,
        onLogin: _openAccountManager,
        onOpenAcademicSystem: _syncingAcademicSchedule
            ? () => _showSnack('正在获取课表，请稍后')
            : () => _selectTab(AppTab.schedule),
        onOpenAnnouncements: () => unawaited(_openAnnouncements()),
        onOpenEmptyClassroom: () => unawaited(_openEmptyClassroom()),
        onOpenLibraryBooking: () => unawaited(_openLibraryBooking()),
        todayCourseContent: _scheduleSummaryText,
        announcementContent: _announcementSummaryText,
        isDemo: widget.isDemo,
      );

  void _openNotifications() {
    Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (_) => ShuyoContentPage(
          repository: ShuyoContentRepository(),
          isDemo: widget.isDemo,
        ),
      ),
    );
  }

  void _openAccountManager() {
    if (widget.isDemo) {
      _showSnack('请在设置中退出演示模式');
      return;
    }
    widget.onboardingController.updateProfile(
      studentId: _academicStudentId,
      nickname: _nickname,
      preferredCampus: _preferredCampus,
    );
    widget.onboardingController.openAccountManager(
      academicLoggedIn: _hasAcademicSession,
      academicSessionExpired: _academicSessionExpired,
      webVpnEnabled: _webVpnEnabled,
      webVpnPendingRecovery: _webVpnPendingRecovery,
      webVpnSessionReady: _webVpnSessionReady,
      webVpnServiceStatus: _webVpnServiceStatus,
    );
    unawaited(_refreshWebVpnStatus());
  }

  void _syncOnboardingAccountStatus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onboardingController.updateProfile(
        studentId: _academicStudentId,
        nickname: _nickname,
        preferredCampus: _preferredCampus,
      );
      widget.onboardingController.updateAccountStatus(
        academicLoggedIn: _hasAcademicSession,
        academicSessionExpired: _academicSessionExpired,
        webVpnEnabled: _webVpnEnabled,
        webVpnPendingRecovery: _webVpnPendingRecovery,
        webVpnSessionReady: _webVpnSessionReady,
        webVpnServiceStatus: _webVpnServiceStatus,
      );
    });
  }

  Future<void> _finishAcademicLogin({
    bool connectWebVpn = true,
    bool allowInitialSync = true,
  }) async {
    if (widget.isDemo || _completingAcademicLogin) return;
    _completingAcademicLogin = true;
    try {
      // WebVPN obtains its own business session from the same SSO account.
      // It is independent of the first-use data sync below.
      if (connectWebVpn) {
        _directBookingClient?.resetSession();
        _webVpnBookingClient?.resetSession();
        unawaited(_recoverWebVpn());
        final task = _establishThereInBackground();
        _thereRecoveryTask = task;
        unawaited(task.whenComplete(() => _thereRecoveryTask = null));
      }
      await _loadAcademicStudentId();
      if (!mounted || _academicStudentId == null) return;
      final firstLogin = allowInitialSync &&
          await AcademicAccountStore().takeInitialSync(_academicStudentId!);
      if (!mounted) return;
      setState(() {
        _hasAcademicSession = true;
        _academicSessionExpired = false;
        // Reload account-scoped caches without making network requests.
        _progressDataRevision++;
        _scheduleDataRevision++;
      });
      _syncOnboardingAccountStatus();
      try {
        await _academicAuthService.markLoggedIn();
        await _academicAuthService.cookieHeader();
      } on Object {
        // A transient cookie delay can recover on a manual refresh.
      }
      await _refreshScheduleSummaryQuietly();
      try {
        await _scheduleNotificationService.syncScheduleReminders();
      } on Object {
        // Reminder availability must not block authentication or initial sync.
      }
      if (!mounted) return;
      if (!firstLogin) {
        unawaited(() async {
          await _studentIdentityService.ensureAfterCampusLogin();
          await _clientBackendRepository.reportPresence();
        }());
        _showSnack('登录已恢复，请再次点击刷新更新数据');
        return;
      }
      await _syncScheduleAfterAcademicLogin();
      if (!mounted || !_hasAcademicSession) return;
      unawaited(() async {
        await _syncAcademicExtrasAfterLogin();
        await _studentIdentityService.ensureAfterCampusLogin();
        await _clientBackendRepository.reportPresence();
      }());
    } finally {
      _completingAcademicLogin = false;
    }
  }

  Future<void> _syncAcademicExtrasAfterLogin() async {
    if (widget.isDemo || _syncingAcademicExtras) return;
    _syncingAcademicExtras = true;
    Future<bool> syncProgress() async {
      try {
        final progress = await _progressRepository.refreshProgress();
        if (progress.studentId.isNotEmpty && mounted && _hasAcademicSession) {
          await AcademicAccountStore().saveStudentId(progress.studentId);
          await _loadAcademicStudentId();
        }
        return true;
      } on Object {
        return false;
      }
    }

    Future<bool> syncRanking() async {
      try {
        await _rankingRepository.refreshRanking();
        return true;
      } on Object {
        return false;
      }
    }

    try {
      final results = await Future.wait([syncProgress(), syncRanking()]);
      if (!mounted || !_hasAcademicSession) return;
      setState(() => _progressDataRevision++);
      if (results.every((success) => success)) {
        _showSnack('学业情况已同步');
      } else if (results.any((success) => success)) {
        _showSnack('部分学业信息同步失败，可在学业页刷新');
      } else {
        _showSnack('学业情况同步失败，可在学业页刷新');
      }
    } finally {
      _syncingAcademicExtras = false;
    }
  }

  Future<void> _loadAcademicStudentId() async {
    final studentId = await AcademicAccountStore().loadStudentId();
    final nickname = studentId == null
        ? null
        : await _profilePreferences.loadNickname(studentId);
    if (!mounted) return;
    setState(() {
      _academicStudentId = studentId;
      _nickname = nickname;
    });
    _syncOnboardingAccountStatus();
  }

  Future<bool> _saveNickname(String? nickname) async {
    final studentId = _academicStudentId;
    if (widget.isDemo || !_hasAcademicSession || studentId == null) {
      return false;
    }
    try {
      await _profilePreferences.saveNickname(studentId, nickname);
      final saved = await _profilePreferences.loadNickname(studentId);
      if (!mounted || !_hasAcademicSession || _academicStudentId != studentId) {
        return false;
      }
      setState(() => _nickname = saved);
      _syncOnboardingAccountStatus();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _savePreferredCampus(String campus) async {
    if (widget.isDemo) return false;
    try {
      await _profilePreferences.savePreferredCampus(campus);
      if (!mounted) return false;
      setState(() => _preferredCampus = campus);
      _syncOnboardingAccountStatus();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _syncScheduleAfterAcademicLogin() async {
    if (widget.isDemo || _syncingAcademicSchedule) return false;
    setState(() {
      _syncingAcademicSchedule = true;
      _scheduleSummaryText = '课表获取中...';
    });
    try {
      await _scheduleRepository.refreshSchedule();
      final schedule = await _scheduleRepository.loadCachedSchedule();
      final studentId = schedule?.term.studentId ?? '';
      if (studentId.isNotEmpty) {
        await AcademicAccountStore().saveStudentId(studentId);
        await _loadAcademicStudentId();
      }
      final summary = await _scheduleRepository.homeSummary();
      unawaited(_scheduleWidgetService.syncFromCache());
      await _scheduleNotificationService.syncScheduleReminders();
      if (mounted) {
        setState(() {
          _scheduleSummaryText = summary.text;
          _scheduleDataRevision++;
        });
        _showSnack('校园账户已登录，课表已同步');
      }
      return true;
    } on AcademicAuthException {
      await _academicAuthService.clearAccount(sessionExpired: true);
      if (mounted) {
        setState(() {
          _hasAcademicSession = false;
          _academicSessionExpired = true;
          _academicStudentId = null;
          _nickname = null;
        });
        _syncOnboardingAccountStatus();
        _showSnack('校园账户登录未完成，请重试');
      }
      return false;
    } on Object {
      if (mounted) _showSnack('课表同步失败，请稍后重试');
      return false;
    } finally {
      if (mounted) setState(() => _syncingAcademicSchedule = false);
      unawaited(_refreshScheduleSummaryQuietly());
    }
  }

  Future<void> _refreshScheduleSummaryQuietly() async {
    if (_loadingScheduleSummary || _syncingAcademicSchedule) return;
    _loadingScheduleSummary = true;
    try {
      final summary = await _scheduleRepository.homeSummary();
      unawaited(_scheduleWidgetService.syncFromCache());
      if (mounted) setState(() => _scheduleSummaryText = summary.text);
    } on Object {
      if (mounted) setState(() => _scheduleSummaryText = '点击同步教务课表');
    } finally {
      _loadingScheduleSummary = false;
    }
  }

  Future<void> _loadAnnouncementSummaryFromCache() async {
    try {
      final summary = await _announcementRepository.homeSummary();
      if (mounted) setState(() => _announcementSummaryText = summary.text);
    } on Object {
      if (mounted) setState(() => _announcementSummaryText = '点击查看通知公告');
    }
  }

  Future<void> _refreshAnnouncementSummaryQuietly() async {
    if (_loadingAnnouncementSummary) return;
    _loadingAnnouncementSummary = true;
    try {
      await _announcementRepository.fetchAnnouncements();
      if (mounted) {
        final summary = await _announcementRepository.homeSummary();
        if (mounted) setState(() => _announcementSummaryText = summary.text);
      }
    } on Object {
      if (mounted && _announcementSummaryText == '正在读取通知公告...') {
        setState(() => _announcementSummaryText = '点击查看通知公告');
      }
    } finally {
      _loadingAnnouncementSummary = false;
    }
  }

  void _openScheduleFromWidget() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _selectTab(AppTab.schedule);
  }

  Future<void> _handleInvalidAcademicSession() async {
    if (_handlingInvalidAcademicSession) return;
    _handlingInvalidAcademicSession = true;
    try {
      final recovered = await _recoverAcademicWithSso();
      if (!mounted || recovered == true) return;
      setState(() {
        _hasAcademicSession = false;
        _academicSessionExpired = true;
      });
      _syncOnboardingAccountStatus();
      if (recovered == null) return;
      await _academicAuthService.clearAccount(sessionExpired: true);
      if (!mounted) return;
      _showSnack('统一认证需要重新登录');
      await _openAcademicLogin(trySso: false);
    } finally {
      _handlingInvalidAcademicSession = false;
    }
  }

  /// true: recovered; false: SSO explicitly needs authentication;
  /// null: transport or business result is uncertain, so retain credentials.
  Future<bool?> _recoverAcademicWithSso() async {
    Uri? callback;
    try {
      callback = await _unifiedAccountService.authorizeAcademic();
    } on Object {
      if (mounted) _showSnack('暂时无法恢复教务登录，请稍后重试');
      return null;
    }
    if (callback == null) return false;
    if (!mounted) return null;
    final completer = AcademicNativeAuthService();
    try {
      await completer.completeLogin(callback);
    } on Object {
      if (mounted) _showSnack('教务会话兑换失败，请稍后重试');
      return null;
    } finally {
      completer.dispose();
    }
    if (!mounted) return null;
    final WebVpnSessionStatus status;
    try {
      status = await _academicAuthService.validateDirectAcademicSession();
    } on Object {
      if (mounted) _showSnack('暂时无法验证教务登录，请稍后重试');
      return null;
    }
    if (status != WebVpnSessionStatus.valid) {
      if (mounted) {
        _showSnack(status == WebVpnSessionStatus.unavailable
            ? '暂时无法验证教务登录，请稍后重试'
            : '教务会话兑换失败，请稍后重试');
      }
      return null;
    }
    await _academicAuthService.markLoggedIn();
    if (!mounted) return null;
    await _finishAcademicLogin(
      connectWebVpn: false,
      allowInitialSync: false,
    );
    return true;
  }

  Future<void> _openAcademicLogin({bool trySso = true}) async {
    if (widget.isDemo) return;
    if (trySso && _academicSessionExpired) {
      final recovered = await _recoverAcademicWithSso();
      if (recovered == true || recovered == null || !mounted) return;
    }
    final result = await Navigator.of(context).push<NativeLoginResult>(
      shuyoRoute(builder: (_) => const NativeLoginPage()),
    );
    if (result == NativeLoginResult.authenticated && mounted) {
      await _finishAcademicLogin();
    }
  }

  Future<void> _openAnnouncements() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (_) => AnnouncementsPage(
          repository: _announcementRepository,
          isDemo: widget.isDemo,
        ),
      ),
    );
    if (mounted) {
      unawaited(_loadAnnouncementSummaryFromCache());
      unawaited(_refreshAnnouncementSummaryQuietly());
    }
  }

  Future<void> _openEmptyClassroom() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (_) => EmptyClassroomPage(
          repository: _classroomRepository,
          initialCampus: _preferredCampus,
          initialDate: widget.isDemo ? DateTime(2026, 9, 1) : null,
          onWebVpnExpired: widget.isDemo ? null : _handleWebVpnExpired,
        ),
      ),
    );
  }

  Future<void> _openLibraryBooking() async {
    if (_openingLibraryBooking) return;
    if (widget.isDemo) {
      _showSnack('演示模式暂不支持图书馆预约');
      return;
    }
    _openingLibraryBooking = true;
    try {
      final useWebVpn = _webVpnEnabled;
      final client = useWebVpn
          ? (_webVpnBookingClient ??= ThereBookingClient(useWebVpn: true))
          : (_directBookingClient ??= ThereBookingClient());
      await Navigator.of(context).push<void>(
        shuyoRoute(
          builder: (_) => LibraryBookingPage(
            accountService: _unifiedAccountService,
            client: client,
            useWebVpn: useWebVpn,
            onWebVpnSessionRequired: () =>
                _changeWebVpnFromAccountManager(true),
          ),
        ),
      );
    } finally {
      _openingLibraryBooking = false;
    }
  }

  Future<void> _establishThereInBackground() async {
    final client = ThereBookingClient();
    try {
      try {
        await client.selectVenue(BookingVenue.library);
        await client.profile();
      } on ThereBookingException catch (error) {
        if (error.kind != ThereFailureKind.loginRequired) rethrow;
        await client.prepareOAuth();
        final callback = await _unifiedAccountService.authorizeThere();
        if (callback == null) {
          await _unifiedAccountService.setTherePendingRecovery(true);
          return;
        }
        await client.completeOAuth(callback);
      }
      final profile = await client.profile();
      final expected = await AcademicAccountStore().loadStudentId();
      final mismatch = expected != null &&
          !ThereBookingClient.matchesAccount(profile, expected);
      if (mismatch) await client.clearSession();
      await _unifiedAccountService.setTherePendingRecovery(mismatch);
    } on Object {
      try {
        await _unifiedAccountService.setTherePendingRecovery(true);
      } on Object {
        // Keep campus login independent of this service.
      }
    } finally {
      client.dispose();
    }
  }

  Future<void> _openClientSettings() async {
    final hasWebVpnSession = !widget.isDemo &&
        (_webVpnEnabled || await WebVpnSessionStore().hasStoredSession());
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (_) => ClientSettingsPage(
          settingsService: _clientSettingsService,
          scheduleNotificationService: _scheduleNotificationService,
          backendRepository: _clientBackendRepository,
          selectedThemeId: widget.selectedThemeId,
          followSystemTheme: widget.followSystemTheme,
          onThemeChanged: widget.onThemeChanged,
          onFollowSystemThemeChanged: widget.onFollowSystemThemeChanged,
          customBackground: widget.customBackground,
          onCustomBackgroundChanged: widget.onCustomBackgroundChanged,
          selectedStartupTab: _preferredStartupTab,
          onStartupTabChanged: _changeStartupTab,
          webVpnController: widget.onboardingController,
          hasAcademicAccount: _hasAcademicSession,
          hasWebVpnSession: hasWebVpnSession,
          onAcademicLogout: _logoutAcademicAccount,
          studentIdentityService: _studentIdentityService,
          isDemo: widget.isDemo,
          onExitDemo: widget.onExitDemo,
        ),
      ),
    );
    if (mounted) {
      unawaited(_loadAnnouncementSummaryFromCache());
      unawaited(_refreshAnnouncementSummaryQuietly());
    }
  }

  Future<void> _changeStartupTab(AppTab tab) async {
    await _clientSettingsService.saveStartupTab(tab);
    if (mounted) setState(() => _preferredStartupTab = tab);
  }

  Future<bool> _logoutAcademicAccount() async {
    // Let an in-flight recovery finish before deleting credentials, so it
    // cannot install a fresh WebVPN token after the user signs out.
    try {
      await _webVpnRecoveryTask;
      await _thereRecoveryTask;
    } on Object {
      // Continue clearing every local credential.
    }
    var failed = false;
    try {
      await _studentIdentityService.signOut();
    } on Object {
      failed = true;
    }
    try {
      await _academicAuthService.clearAccount();
    } on Object {
      failed = true;
    }
    try {
      await WebVpnSessionStore().clearSession();
    } on Object {
      failed = true;
    }
    try {
      await _clearThereSession(useWebVpn: false);
    } on Object {
      failed = true;
    }
    try {
      await _clearProxiedThereSession();
    } on Object {
      failed = true;
    }
    try {
      await _unifiedAccountService.clearSsoSession();
    } on Object {
      failed = true;
    }
    try {
      await _unifiedAccountService.setWebVpnPendingRecovery(false);
      await _unifiedAccountService.setTherePendingRecovery(false);
    } on Object {
      failed = true;
    }
    try {
      await _setWebVpnEnabled(false);
    } on Object {
      failed = true;
    }
    if (mounted) {
      setState(() {
        _hasAcademicSession = false;
        _academicSessionExpired = false;
        _academicStudentId = null;
        _nickname = null;
        _webVpnPendingRecovery = false;
        _webVpnSessionReady = false;
      });
      _syncOnboardingAccountStatus();
      if (failed) _showSnack('部分登录状态清除失败，请重试退出');
    }
    return !failed;
  }

  Future<void> _clearProxiedThereSession() async {
    await _clearThereSession(useWebVpn: true);
  }

  Future<void> _clearThereSession({required bool useWebVpn}) async {
    final existing = useWebVpn ? _webVpnBookingClient : _directBookingClient;
    final client = existing ?? ThereBookingClient(useWebVpn: useWebVpn);
    try {
      await client.clearSession();
    } finally {
      if (existing == null) client.dispose();
    }
  }

  Future<void> _handleWebVpnExpired() async {
    if (!mounted) return;
    final outcome = await _recoverWebVpn();
    if (!mounted) return;
    switch (outcome) {
      case WebVpnRecoveryOutcome.alreadyValid:
      case WebVpnRecoveryOutcome.recovered:
        _showSnack('WebVPN连接已恢复，请重试刚才的操作');
      case WebVpnRecoveryOutcome.needsAuthentication:
        await _setWebVpnEnabled(false);
        _showSnack('统一认证已失效，请重新登录WebVPN');
      case WebVpnRecoveryOutcome.unavailable:
        _showSnack('暂时无法确认WebVPN连接，请稍后重试');
      case WebVpnRecoveryOutcome.businessFailure:
        await _setWebVpnEnabled(false);
        _showSnack(_unifiedAccountService.lastWebVpnFailureMessage ??
            'WebVPN会话恢复失败，请稍后重试');
    }
  }

  Future<void> _setWebVpnEnabled(bool enabled) async {
    final settings = await _clientSettingsService.loadNetworkSettings();
    if (settings.webVpnEnabled != enabled) {
      await _clientSettingsService.saveNetworkSettings(
        settings.copyWith(webVpnEnabled: enabled),
      );
    }
    final changed = ClassroomUrlResolver.usesWebVpn != enabled;
    ClassroomUrlResolver.configure(useWebVpn: enabled);
    if (changed) _classroomRepository = ClassroomRepository();
    if (mounted) {
      setState(() => _webVpnEnabled = enabled);
      _syncOnboardingAccountStatus();
    }
  }

  Future<bool> _changeWebVpnFromAccountManager(bool enabled) async {
    if (widget.isDemo || !mounted) return false;
    if (enabled) {
      final outcome = await _recoverWebVpn();
      if (!mounted) return false;
      if (outcome == WebVpnRecoveryOutcome.unavailable) {
        _showSnack('暂时无法验证WebVPN连接，请稍后重试');
        return false;
      }
      if (outcome == WebVpnRecoveryOutcome.businessFailure) {
        _showSnack(_unifiedAccountService.lastWebVpnFailureMessage ??
            'WebVPN会话恢复失败，请稍后重试');
        return false;
      }
      if (outcome == WebVpnRecoveryOutcome.needsAuthentication) {
        final result = await Navigator.of(context).push<NativeLoginResult>(
          shuyoRoute(builder: (_) => const NativeLoginPage.webVpn()),
        );
        if (result != NativeLoginResult.authenticated || !mounted) return false;
        await _unifiedAccountService.setWebVpnPendingRecovery(false);
        setState(() {
          _webVpnPendingRecovery = false;
          _webVpnSessionReady = true;
        });
        _syncOnboardingAccountStatus();
      }
    }
    try {
      await _setWebVpnEnabled(enabled);
      return true;
    } on Object {
      _showSnack('WebVPN设置失败，请稍后重试');
      return false;
    }
  }

  Future<WebVpnRecoveryOutcome> _recoverWebVpn() {
    final running = _webVpnRecoveryTask;
    if (running != null) return running;
    final task = _runWebVpnRecovery();
    _webVpnRecoveryTask = task;
    return task;
  }

  Future<WebVpnRecoveryOutcome> _runWebVpnRecovery() async {
    try {
      final outcome = await _unifiedAccountService.recoverWebVpn();
      if (mounted) {
        setState(() {
          _webVpnSessionReady = outcome == WebVpnRecoveryOutcome.alreadyValid ||
              outcome == WebVpnRecoveryOutcome.recovered;
          _webVpnPendingRecovery = !_webVpnSessionReady;
        });
        _syncOnboardingAccountStatus();
      }
      return outcome;
    } on Object {
      if (mounted) {
        setState(() {
          _webVpnPendingRecovery = true;
          _webVpnSessionReady = false;
        });
        _syncOnboardingAccountStatus();
      }
      return WebVpnRecoveryOutcome.unavailable;
    } finally {
      _webVpnRecoveryTask = null;
    }
  }

  Future<void> _checkClientBackendPrompts() async {
    if (widget.isDemo || _checkingClientBackendPrompts) return;
    _checkingClientBackendPrompts = true;
    _lastWebVpnStatusFetchAttempt = DateTime.now();
    try {
      final bootstrap =
          await _clientBackendRepository.fetchBootstrap(forceRefresh: true);
      if (!mounted) return;
      setState(() => _webVpnServiceStatus = bootstrap.webVpnStatus);
      _syncOnboardingAccountStatus();
      if (ClientUpdatePolicy.source == ClientUpdateSource.backend) {
        final version = bootstrap.version;
        if (version.isNewerThan(ClientAppInfo.buildNumber)) {
          final prompt = await _clientBackendRepository
              .shouldPromptUpdate(version.latestBuild);
          if (mounted && prompt) {
            final open = await showClientUpdatePrompt(context, update: version);
            await _clientBackendRepository
                .markUpdatePrompted(version.latestBuild);
            if (open == true && version.hasDownloadUrl && mounted) {
              await _openUpdateDownload(version.downloadUrl);
            }
            return;
          }
        } else {
          await _clientBackendRepository
              .ensureUpdateBaselineInitialized(version.latestBuild);
        }
      }
      final announcement = bootstrap.latestAnnouncement;
      if (announcement == null) {
        await _clientBackendRepository.ensureAnnouncementBaselineInitialized();
        return;
      }
      final prompt = await _clientBackendRepository
          .shouldPromptAnnouncement(announcement.id);
      if (!mounted || !prompt) return;
      final acknowledged = await showInfoConfirmDialog(
        context,
        title: announcement.title,
        message: announcement.content,
        confirmText: '知道了',
        secondaryText: '不再提示',
      );
      if (!acknowledged) {
        await _clientBackendRepository
            .markAnnouncementPrompted(announcement.id);
      }
    } on Object {
      // A backend outage must not block the app.
    } finally {
      _checkingClientBackendPrompts = false;
    }
  }

  Future<void> _refreshWebVpnStatus() async {
    if (widget.isDemo ||
        _refreshingWebVpnStatus ||
        _checkingClientBackendPrompts) {
      return;
    }
    _refreshingWebVpnStatus = true;
    _lastWebVpnStatusFetchAttempt = DateTime.now();
    try {
      final bootstrap =
          await _clientBackendRepository.fetchBootstrap(forceRefresh: true);
      if (mounted) {
        setState(() => _webVpnServiceStatus = bootstrap.webVpnStatus);
        _syncOnboardingAccountStatus();
      }
    } on Object {
      if (mounted && !_webVpnServiceStatus.isFreshAt(DateTime.now())) {
        setState(
          () => _webVpnServiceStatus = const WebVpnServiceStatus.unknown(),
        );
        _syncOnboardingAccountStatus();
      }
    } finally {
      _refreshingWebVpnStatus = false;
    }
  }

  Future<void> _openUpdateDownload(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      _showSnack('下载链接无效');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _showSnack('无法打开下载链接');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
