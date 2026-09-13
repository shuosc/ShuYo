import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/classroom_url_resolver.dart';
import '../core/client_app_info.dart';
import '../core/client_update_policy.dart';
import '../core/forum_url_resolver.dart';
import '../data/demo/demo_data_bundle.dart';
import '../data/demo/demo_repositories.dart';
import '../data/models/forum_activity.dart';
import '../data/models/forum_notification.dart';
import '../data/models/client_backend.dart';
import '../data/models/topic.dart';
import '../data/repositories/client_backend_repository.dart';
import '../data/repositories/academic_schedule_repository.dart';
import '../data/repositories/announcement_repository.dart';
import '../data/repositories/classroom_repository.dart';
import '../data/repositories/course_rating_repository.dart';
import '../data/repositories/forum_repository.dart';
import '../data/services/academic_schedule_notification_service.dart';
import '../data/services/academic_schedule_display_settings_service.dart';
import '../data/services/academic_schedule_widget_service.dart';
import '../data/services/academic_schedule_api_client.dart';
import '../data/services/academic_auth_service.dart';
import '../data/services/academic_account_store.dart';
import '../data/services/client_settings_service.dart';
import '../data/services/discourse_api_client.dart';
import '../data/services/forum_image_headers.dart';
import '../data/services/forum_image_cache.dart';
import '../data/services/forum_account_snapshot.dart';
import '../data/services/forum_auth_service.dart';
import '../data/services/http_timeout.dart';
import '../features/auth/native_login_page.dart';
import '../features/forum/create_topic_page.dart';
import '../features/forum/forum_filter_bar.dart';
import '../features/forum/forum_search_page.dart';
import '../features/forum/forum_faq_page.dart';
import '../features/home/academic_schedule_page.dart';
import '../features/home/announcements_page.dart';
import '../features/home/course_rating_page.dart';
import '../features/home/empty_classroom_page.dart';
import '../features/home/home_dashboard_page.dart';
import '../features/home/topic_list_page.dart';
import '../features/messages/messages_page.dart';
import '../features/messages/notifications_page.dart';
import '../features/onboarding/startup_onboarding.dart';
import '../features/profile/profile_page.dart';
import '../features/profile/draft_box_page.dart';
import '../features/profile/forum_activity_page.dart';
import '../features/profile/profile_settings_page.dart';
import '../features/profile/user_profile_page.dart';
import '../features/settings/client_settings_page.dart';
import '../features/topic/topic_detail_page.dart';
import '../features/webview/forum_webvpn_preloader.dart';
import '../shared/navigation/shuyo_route.dart';
import '../shared/theme/shuyo_theme.dart';
import '../shared/widgets/client_update_prompt.dart';
import '../shared/widgets/info_confirm_dialog.dart';
import '../shared/widgets/app_header.dart';
import '../shared/widgets/empty_state.dart';
import '../shared/widgets/shuyo_launch_surface.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.repository,
    required this.reloadRepository,
    required this.initialWebVpnEnabled,
    required this.selectedThemeId,
    required this.followSystemTheme,
    required this.onThemeChanged,
    required this.onFollowSystemThemeChanged,
    required this.academicLoginSignal,
    required this.forumLoginSignal,
    required this.initialHasAcademicSession,
    required this.initialAcademicSessionExpired,
    required this.initialAcademicStudentId,
    required this.onboardingController,
    this.initialOpenSchedule = false,
    this.initialScheduleState,
    this.initialScheduleDisplayState,
    this.initialScheduleLoadError,
    this.isDemo = false,
    this.demoData,
    this.onExitDemo,
  });

  final ForumRepository repository;
  final Future<ForumRepository> Function() reloadRepository;
  final bool initialWebVpnEnabled;
  final String selectedThemeId;
  final bool followSystemTheme;
  final Future<void> Function(String themeId) onThemeChanged;
  final Future<void> Function(bool enabled) onFollowSystemThemeChanged;
  final int academicLoginSignal;
  final int forumLoginSignal;
  final bool initialHasAcademicSession;
  final bool initialAcademicSessionExpired;
  final String? initialAcademicStudentId;
  final bool initialOpenSchedule;
  final AcademicScheduleCacheState? initialScheduleState;
  final AcademicScheduleDisplayState? initialScheduleDisplayState;
  final String? initialScheduleLoadError;
  final StartupOnboardingController onboardingController;
  final bool isDemo;
  final DemoDataBundle? demoData;
  final Future<void> Function()? onExitDemo;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  static const _forumAccessModeReloadTimeout = HttpTimeout.normal;
  static const _forumBadgeRefreshInterval = Duration(seconds: 90);
  static const _feedLoadMoreThrottle = Duration(milliseconds: 900);
  static const _minimumForumRefreshDuration = Duration(milliseconds: 420);
  static const _exitBackPressInterval = Duration(seconds: 2);
  static const _webVpnStatusRefreshInterval = Duration(minutes: 5);
  static const _automaticForumRecoveryCooldown = Duration(seconds: 45);
  static const _directForumRecoveryTimeout = Duration(seconds: 10);
  static const _webVpnForumRecoveryTimeout = Duration(seconds: 15);
  static const _userForumRecoveryTimeout = Duration(seconds: 25);

  int _tabIndex = 0;
  TopicFeedQuery _feedQuery = const TopicFeedQuery();
  bool _reloadingSession = false;
  bool _checkingForumConnection = false;
  bool _isInitialForumConnectionCheck = false;
  bool _loadingMoreFeed = false;
  String? _loadMoreFeedError;
  DateTime? _lastLoadMoreFeedAttempt;
  final _feedSnapshots = <String, List<TopicListItem>>{};
  final _feedRequestTokens = <String, int>{};
  int _feedRequestSequence = 0;
  late ForumRepository _repo;
  late final AcademicScheduleRepository _scheduleRepository;
  late final AcademicScheduleNotificationService _scheduleNotificationService;
  late final AcademicScheduleWidgetService _scheduleWidgetService;
  late final ClientSettingsService _clientSettingsService;
  late final ClientBackendRepository _clientBackendRepository;
  late final AnnouncementRepository _announcementRepository;
  late final ClassroomRepository _classroomRepository;
  late final CourseRatingRepository _courseRatingRepository;
  late Future<List<TopicListItem>> _feedFuture;
  Future<ForumActivityCounts>? _activityCountsFuture;
  Timer? _scheduleSummaryTimer;
  Timer? _announcementSummaryTimer;
  Timer? _forumBadgeRefreshTimer;
  bool _loadingScheduleSummary = false;
  bool _syncingAcademicSchedule = false;
  bool _loadingAnnouncementSummary = false;
  bool _refreshingForumBadges = false;
  bool _checkingClientBackendPrompts = false;
  bool _refreshingWebVpnStatus = false;
  bool _webVpnReloginRequired = false;
  late bool _webVpnEnabled;
  late bool _hasAcademicSession;
  late bool _academicSessionExpired;
  String? _academicStudentId;
  int _seenNotificationBadgeCount = 0;
  int _seenMessageBadgeCount = 0;
  int _localNotificationBadgeCount = 0;
  int _messageRefreshSignal = 0;
  bool _showArchivedMessages = false;
  bool _messageSelectionActive = false;
  bool _messageRefreshing = false;
  Set<String> _seenNotificationKeys = const {};
  bool _notificationSeenKeysInitialized = false;
  DateTime? _lastAutomaticForumRecoveryFailure;
  DateTime? _lastWebVpnStatusFetchAttempt;
  DateTime? _lastExitBackAt;
  String _scheduleSummaryText = '正在读取课表...';
  String _announcementSummaryText = '正在读取通知公告...';
  WebVpnServiceStatus _webVpnServiceStatus =
      const WebVpnServiceStatus.unknown();
  final _forumTopicListController = TopicListPageController();
  final _messagesPageController = MessagesPageController();
  final _forumRefreshIndicatorKey = GlobalKey<RefreshIndicatorState>();
  Completer<ForumWebVpnPreparationResult>? _forumWebVpnPreloadCompleter;
  int _forumWebVpnPreloadToken = 0;
  int _forumRepositoryReloadToken = 0;
  int _forumRecoveryGeneration = 0;
  Future<ForumRecoveryResult>? _forumRecoveryFuture;
  bool _onboardingStatusSyncScheduled = false;
  StreamSubscription<Uri?>? _widgetClickSubscription;
  bool _openingScheduleFromWidget = false;
  final Set<Route<void>> _academicScheduleRoutes = {};
  late bool _hideShellForInitialWidgetLaunch = widget.initialOpenSchedule;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = widget.repository;
    _webVpnEnabled = widget.initialWebVpnEnabled;
    _hasAcademicSession = widget.initialHasAcademicSession;
    _academicSessionExpired = widget.initialAcademicSessionExpired;
    _academicStudentId = widget.initialAcademicStudentId;
    final demoData = widget.demoData;
    _scheduleRepository = widget.isDemo && demoData != null
        ? DemoAcademicScheduleRepository(demoData.schedule)
        : AcademicScheduleRepository();
    _scheduleNotificationService = AcademicScheduleNotificationService(
      repository: _scheduleRepository,
    );
    _scheduleWidgetService = AcademicScheduleWidgetService(
      repository: _scheduleRepository,
    );
    _clientSettingsService = ClientSettingsService();
    _clientBackendRepository = ClientBackendRepository();
    _announcementRepository = widget.isDemo && demoData != null
        ? DemoAnnouncementRepository(
            items: demoData.announcements,
            details: demoData.announcementDetails,
          )
        : AnnouncementRepository();
    _classroomRepository = widget.isDemo && demoData != null
        ? DemoClassroomRepository(
            options: demoData.classroomOptions,
            schedule: demoData.classroomSchedule,
          )
        : ClassroomRepository();
    _courseRatingRepository = widget.isDemo && demoData != null
        ? DemoCourseRatingRepository(demoData.courseRatings)
        : CourseRatingRepository();
    widget.onboardingController.setForumReconnectHandler(
      () => unawaited(_relogin()),
    );
    widget.onboardingController.setAccountLogoutHandlers(
      onAcademicLogout: _logoutAcademicAccount,
      onForumLogout: _logoutForumAccount,
    );
    widget.onboardingController.setWebVpnChangeHandler(
      _changeWebVpnFromAccountManager,
    );
    _syncOnboardingAccountStatus();
    _resetFeedFuture();
    if (Platform.isAndroid || Platform.isIOS) {
      _widgetClickSubscription =
          HomeWidget.widgetClicked.listen(_handleWidgetClick);
      if (widget.initialOpenSchedule) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_openScheduleFromWidget(initialLaunch: true));
        });
      }
    }
    unawaited(_initializeForumBadges());
    unawaited(_refreshScheduleSummaryQuietly());
    unawaited(_loadAnnouncementSummaryFromCache());
    if (!widget.isDemo) {
      unawaited(_loadNetworkSettings());
      _scheduleSummaryTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _refreshScheduleSummaryQuietly(),
      );
      _announcementSummaryTimer = Timer.periodic(
        AnnouncementRepository.defaultAutoRefreshInterval,
        (_) => _refreshAnnouncementSummaryQuietly(),
      );
      _startForumBadgeRefreshTimer(_forumBadgeRefreshInterval);
      unawaited(_scheduleNotificationService.syncScheduleReminders());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_repo.hasLocalAccount && !_repo.isOnline) {
          _isInitialForumConnectionCheck = true;
          unawaited(_restoreForumAfterFirstFrame());
        }
        unawaited(_refreshAnnouncementSummaryQuietly());
        unawaited(_checkClientBackendPrompts());
      });
    }
  }

  Future<void> _restoreForumAfterFirstFrame() async {
    final recovery = await _recoverForumAutomatically();
    if (!mounted || !recovery.isRestored) return;
    await _initializeForumBadges();
    unawaited(_recordForumDailyActivity());
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.academicLoginSignal != oldWidget.academicLoginSignal) {
      unawaited(_finishAcademicLogin());
    }
    if (widget.forumLoginSignal != oldWidget.forumLoginSignal) {
      unawaited(_reloadForumAfterLogin());
    }
  }

  Future<void> _finishAcademicLogin() async {
    if (widget.isDemo) {
      return;
    }
    if (mounted) {
      setState(() {
        _hasAcademicSession = true;
        _academicSessionExpired = false;
      });
    }
    await _loadAcademicStudentId();
    _syncOnboardingAccountStatus();
    await _persistAcademicLoginCookies();
    await _syncScheduleAfterAcademicLogin();
  }

  Future<void> _loadAcademicStudentId() async {
    final studentId = await AcademicAccountStore().loadStudentId();
    if (mounted && studentId != _academicStudentId) {
      setState(() => _academicStudentId = studentId);
    }
  }

  Future<void> _persistAcademicLoginCookies() async {
    try {
      _debugAcademicFlow('persist login cookies start');
      final authService = AcademicAuthService();
      // A successful login must clear the explicit-logout marker even when
      // Android's WebView has not exposed the newly-installed cookies yet.
      // Otherwise the marker can survive the login callback and force every
      // subsequent session validation to report `loginRequired`.
      await authService.markLoggedIn();
      await authService.cookieHeader();
      _debugAcademicFlow('persist login cookies complete');
    } on Object catch (error, stackTrace) {
      _debugAcademicFlow(
        'persist login cookies failed: $error',
        stackTrace: stackTrace,
      );
      // Cookie persistence is best effort and must not block the login flow.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hideShellForInitialWidgetLaunch) {
      return ShuYoLaunchSurface(
        theme: ShuYoThemes.byId(widget.selectedThemeId),
      );
    }
    ForumImageCache.configureCurrentAccount(
      _repo.hasLocalAccount ? _repo.profile.username : null,
    );
    ForumImageCache.setNetworkEnabled(!widget.isDemo && _repo.isOnline);
    final canOpenClientSettings = _tabIndex == 0 || _tabIndex == 3;
    final isForumTab = _tabIndex == 1 && _repo.isOnline;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        _handleRootPop(didPop);
      },
      child: Scaffold(
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  AppHeader(
                    title: _headerTitle,
                    showSettings: canOpenClientSettings,
                    showSearch: isForumTab,
                    showCreate: isForumTab,
                    showArchive: _tabIndex == 2 &&
                        _repo.hasLocalAccount &&
                        !_messageSelectionActive,
                    showRefresh: _tabIndex == 2 &&
                        _repo.hasLocalAccount &&
                        !_messageSelectionActive,
                    archiveView: _showArchivedMessages,
                    refreshing: _messageRefreshing,
                    notificationCount: _notificationBadgeCount,
                    onSearch: _openSearch,
                    onCreate: _openCreateTopic,
                    onArchive: _toggleMessageArchiveView,
                    onRefresh: _refreshMessagesFromHeader,
                    onSettings: _openClientSettings,
                    onNotification: _openNotifications,
                    onTitleDoubleTap: _tabIndex == 1
                        ? () => unawaited(_handleForumHeaderDoubleTap())
                        : null,
                  ),
                  Expanded(child: _bodyForTab()),
                ],
              ),
            ),
            if (_forumWebVpnPreloadCompleter != null)
              Positioned(
                left: 0,
                top: 0,
                child: ForumWebVpnPreloader(
                  key: ValueKey(_forumWebVpnPreloadToken),
                  onComplete: _completeForumWebVpnPreload,
                ),
              ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: (index) {
            final shouldRefreshMessages = index == 2 &&
                _repo.isOnline &&
                (index == _tabIndex || _messageBadgeCount > 0);
            setState(() {
              _tabIndex = index;
              if (shouldRefreshMessages) {
                _messageRefreshSignal++;
              }
            });
            if (index == 2) {
              unawaited(_markMessageBadgeSeen());
              unawaited(_refreshForumBadgesQuietly());
            }
            if (index == 0) {
              unawaited(_refreshScheduleSummaryQuietly());
              unawaited(_refreshAnnouncementSummaryQuietly());
            }
          },
          items: [
            const BottomNavigationBarItem(
                icon: Icon(Icons.dashboard), label: '首页'),
            const BottomNavigationBarItem(icon: Icon(Icons.forum), label: '论坛'),
            BottomNavigationBarItem(
              icon: _TabBadgeIcon(
                icon: Icons.chat_bubble_outline,
                count: _messageBadgeCount,
              ),
              label: '消息',
            ),
            const BottomNavigationBarItem(
                icon: Icon(Icons.account_circle), label: '我'),
          ],
        ),
      ),
    );
  }

  void _handleRootPop(bool didPop) {
    if (didPop) {
      return;
    }
    if (widget.onboardingController.dismissAccountManager()) {
      return;
    }
    final now = DateTime.now();
    final lastExitBackAt = _lastExitBackAt;
    if (lastExitBackAt != null &&
        now.difference(lastExitBackAt) <= _exitBackPressInterval) {
      SystemNavigator.pop();
      return;
    }
    _lastExitBackAt = now;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('再按一次退出程序'),
          duration: _exitBackPressInterval,
        ),
      );
  }

  @override
  void dispose() {
    unawaited(_widgetClickSubscription?.cancel());
    _scheduleSummaryTimer?.cancel();
    _announcementSummaryTimer?.cancel();
    _forumBadgeRefreshTimer?.cancel();
    widget.onboardingController.setForumReconnectHandler(null);
    widget.onboardingController.setAccountLogoutHandlers();
    widget.onboardingController.setWebVpnChangeHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleWidgetClick(Uri? uri) {
    if (uri?.scheme != 'shuyo' || uri?.host != 'schedule') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasCurrentAcademicScheduleRoute) {
        unawaited(_openScheduleFromWidget());
      }
    });
  }

  bool get _hasCurrentAcademicScheduleRoute =>
      _academicScheduleRoutes.any((route) => route.isCurrent);

  Future<void> _openScheduleFromWidget({bool initialLaunch = false}) async {
    if (_openingScheduleFromWidget) return;
    _openingScheduleFromWidget = true;
    try {
      final navigation = _openAcademicSystem(
        animatePush: false,
        initialState: initialLaunch ? widget.initialScheduleState : null,
        initialDisplayState:
            initialLaunch ? widget.initialScheduleDisplayState : null,
        initialLoadError:
            initialLaunch ? widget.initialScheduleLoadError : null,
      );
      if (initialLaunch) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _hideShellForInitialWidgetLaunch = false);
        });
      }
      await navigation;
    } finally {
      _openingScheduleFromWidget = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.isDemo) {
      _forumBadgeRefreshTimer?.cancel();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _startForumBadgeRefreshTimer(_forumBadgeRefreshInterval);
      unawaited(_recordForumDailyActivity());
      unawaited(_refreshAfterAppResumed());
      return;
    }
    _forumBadgeRefreshTimer?.cancel();
  }

  Future<void> _recordForumDailyActivity() async {
    if (widget.isDemo) return;
    if (!_repo.hasLocalAccount || !_repo.isOnline) return;
    await _clientBackendRepository.recordForumDailyActivity(
      userId: _repo.profile.id,
    );
  }

  void _startForumBadgeRefreshTimer(Duration interval) {
    _forumBadgeRefreshTimer?.cancel();
    _forumBadgeRefreshTimer = Timer.periodic(
      interval,
      (_) => unawaited(_refreshForumBadgesFromTimer()),
    );
  }

  Future<void> _refreshForumBadgesFromTimer() async {
    await _refreshForumBadgesQuietly();
    if (!mounted || _tabIndex != 2 || !_repo.isOnline) {
      return;
    }
    setState(() => _messageRefreshSignal++);
  }

  Future<void> _refreshAfterAppResumed() async {
    unawaited(_refreshScheduleSummaryQuietly());
    final lastStatusAttempt = _lastWebVpnStatusFetchAttempt;
    if (lastStatusAttempt == null ||
        DateTime.now().difference(lastStatusAttempt) >=
            _webVpnStatusRefreshInterval) {
      unawaited(_refreshWebVpnStatus());
    }
    ForumRecoveryResult? recovery;
    if (_repo.hasLocalAccount && !_repo.isOnline) {
      recovery = await _recoverForumAutomatically();
    }
    await _refreshForumBadgesQuietly(
      refreshSession: recovery?.isRestored != true,
    );
    if (!mounted || _tabIndex != 2 || !_repo.isOnline) {
      return;
    }
    setState(() => _messageRefreshSignal++);
  }

  String get _headerTitle {
    return switch (_tabIndex) {
      0 => '首页',
      1 => '论坛',
      2 => _showArchivedMessages ? '归档' : '消息',
      3 => '我',
      _ => 'ShuYo',
    };
  }

  void _toggleMessageArchiveView() {
    _setMessageArchiveView(!_showArchivedMessages);
  }

  void _setMessageArchiveView(bool showArchived) {
    if (!mounted || _showArchivedMessages == showArchived) {
      return;
    }
    setState(() => _showArchivedMessages = showArchived);
  }

  void _refreshMessagesFromHeader() {
    if (!mounted) {
      return;
    }
    unawaited(_messagesPageController.refresh());
  }

  void _setMessageSelectionActive(bool active) {
    if (!mounted || _messageSelectionActive == active) {
      return;
    }
    setState(() => _messageSelectionActive = active);
  }

  void _setMessageRefreshing(bool refreshing) {
    if (!mounted || _messageRefreshing == refreshing) {
      return;
    }
    setState(() => _messageRefreshing = refreshing);
  }

  int get _notificationBadgeCount {
    if (!_repo.isOnline) {
      return 0;
    }
    return _localNotificationBadgeCount;
  }

  int get _messageBadgeCount {
    if (!_repo.isOnline) {
      return 0;
    }
    final count = _repo.unreadPrivateMessageCount;
    return count <= _seenMessageBadgeCount ? 0 : count - _seenMessageBadgeCount;
  }

  String get _forumBadgeCacheUserKey => _repo.profile.username.toLowerCase();

  String _notificationBadgeSeenKey(String username) {
    return 'forum.badge.seen.notifications.$username';
  }

  String _notificationFeedSeenKeysKey(String username) {
    return 'forum.badge.seen.notification_activity_keys.v2.$username';
  }

  String _messageBadgeSeenKey(String username) {
    return 'forum.badge.seen.messages.$username';
  }

  Future<void> _initializeForumBadges() async {
    await _loadLocalForumBadges();
    await _refreshForumBadgesQuietly();
  }

  Future<void> _loadLocalForumBadges() async {
    if (!_repo.isOnline) {
      if (mounted) {
        setState(() {
          _seenNotificationBadgeCount = 0;
          _seenMessageBadgeCount = 0;
          _localNotificationBadgeCount = 0;
          _seenNotificationKeys = const {};
          _notificationSeenKeysInitialized = false;
        });
      }
      return;
    }
    final username = _forumBadgeCacheUserKey;
    final prefs = await SharedPreferences.getInstance();
    final notificationCount =
        prefs.getInt(_notificationBadgeSeenKey(username)) ?? 0;
    final messageCount = prefs.getInt(_messageBadgeSeenKey(username)) ?? 0;
    final notificationKeys =
        prefs.getStringList(_notificationFeedSeenKeysKey(username));
    final normalizedNotificationCount =
        notificationCount.clamp(0, _repo.unreadNotificationCount);
    final normalizedMessageCount =
        messageCount.clamp(0, _repo.unreadPrivateMessageCount);
    if (!mounted || username != _forumBadgeCacheUserKey) {
      return;
    }
    setState(() {
      _seenNotificationBadgeCount = normalizedNotificationCount;
      _seenMessageBadgeCount = normalizedMessageCount;
      _localNotificationBadgeCount = 0;
      _seenNotificationKeys = notificationKeys?.toSet() ?? const {};
      _notificationSeenKeysInitialized = notificationKeys != null;
    });
    if (normalizedNotificationCount != notificationCount) {
      unawaited(
        prefs.setInt(
          _notificationBadgeSeenKey(username),
          normalizedNotificationCount,
        ),
      );
    }
    if (normalizedMessageCount != messageCount) {
      unawaited(
        prefs.setInt(_messageBadgeSeenKey(username), normalizedMessageCount),
      );
    }
  }

  Future<void> _markNotificationBadgeSeen() async {
    if (!_repo.isOnline) {
      return;
    }
    final username = _forumBadgeCacheUserKey;
    final count = _repo.unreadNotificationCount;
    Set<String>? notificationKeys;
    try {
      notificationKeys = await _fetchCurrentNotificationKeys();
    } on Object {
      notificationKeys = null;
    }
    if (!mounted || !_repo.isOnline || username != _forumBadgeCacheUserKey) {
      return;
    }
    setState(() {
      _seenNotificationBadgeCount = count;
      _localNotificationBadgeCount = 0;
      if (notificationKeys != null) {
        _seenNotificationKeys = notificationKeys;
        _notificationSeenKeysInitialized = true;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_notificationBadgeSeenKey(username), count);
    if (notificationKeys != null) {
      await prefs.setStringList(
        _notificationFeedSeenKeysKey(username),
        _sortedNotificationKeys(notificationKeys),
      );
    }
  }

  Future<void> _markMessageBadgeSeen() async {
    if (!_repo.isOnline) {
      return;
    }
    final username = _forumBadgeCacheUserKey;
    final count = _repo.unreadPrivateMessageCount;
    setState(() => _seenMessageBadgeCount = count);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_messageBadgeSeenKey(username), count);
  }

  Future<void> _refreshForumBadgesQuietly({bool refreshSession = true}) async {
    if (_refreshingForumBadges || _reloadingSession || !_repo.isOnline) {
      return;
    }
    _refreshingForumBadges = true;
    final username = _forumBadgeCacheUserKey;
    try {
      if (refreshSession) {
        await _repo.refreshSession();
      }
      if (!mounted || !_repo.isOnline || username != _forumBadgeCacheUserKey) {
        return;
      }
      final notificationFeedBadge = await _loadNotificationFeedBadge();
      if (!mounted || !_repo.isOnline || username != _forumBadgeCacheUserKey) {
        return;
      }
      final normalizedNotificationCount =
          _seenNotificationBadgeCount.clamp(0, _repo.unreadNotificationCount);
      final normalizedMessageCount =
          _seenMessageBadgeCount.clamp(0, _repo.unreadPrivateMessageCount);
      final shouldPersist =
          normalizedNotificationCount != _seenNotificationBadgeCount ||
              normalizedMessageCount != _seenMessageBadgeCount;
      setState(() {
        _seenNotificationBadgeCount = normalizedNotificationCount;
        _seenMessageBadgeCount = normalizedMessageCount;
        if (notificationFeedBadge != null) {
          _localNotificationBadgeCount = notificationFeedBadge.count;
          if (notificationFeedBadge.baselineKeys != null) {
            _seenNotificationKeys = notificationFeedBadge.baselineKeys!;
            _notificationSeenKeysInitialized = true;
          }
        }
      });
      if (shouldPersist) {
        final prefs = await SharedPreferences.getInstance();
        await Future.wait([
          prefs.setInt(
            _notificationBadgeSeenKey(username),
            normalizedNotificationCount,
          ),
          prefs.setInt(_messageBadgeSeenKey(username), normalizedMessageCount),
        ]);
      }
      final baselineKeys = notificationFeedBadge?.baselineKeys;
      if (baselineKeys != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _notificationFeedSeenKeysKey(username),
          _sortedNotificationKeys(baselineKeys),
        );
      }
    } on ForumAuthException {
      _repo.markAuthenticationRequired();
      if (mounted) {
        setState(() {});
        _syncOnboardingAccountStatus();
      }
      // 会话已明确失效，但保留账户和所有缓存，等待首页重新认证。
    } on Object catch (error) {
      if (_isForumTransportError(error)) {
        _repo.markConnectionUnavailable();
        if (mounted) {
          setState(() {});
        }
      }
      // 刷新红点失败不打扰用户，下一轮会继续尝试。
    } finally {
      _refreshingForumBadges = false;
    }
  }

  Future<_NotificationFeedBadge?> _loadNotificationFeedBadge() async {
    final keys = await _fetchCurrentNotificationKeys();
    if (!_notificationSeenKeysInitialized) {
      return _NotificationFeedBadge(count: 0, baselineKeys: keys);
    }
    final count =
        keys.where((key) => !_seenNotificationKeys.contains(key)).length;
    return _NotificationFeedBadge(count: count);
  }

  Future<Set<String>> _fetchCurrentNotificationKeys() async {
    final notifications = await _repo.fetchNotifications(
      NotificationFeedFilter.all,
      forceRefresh: true,
    );
    return notifications.map(_notificationKey).toSet();
  }

  String _notificationKey(ForumNotification notification) {
    final createdAt = notification.createdAt?.millisecondsSinceEpoch ?? 0;
    return [
      notification.kind,
      notification.topicId ?? 0,
      notification.postNumber ?? 0,
      notification.id,
      createdAt,
    ].join(':');
  }

  List<String> _sortedNotificationKeys(Set<String> keys) {
    return keys.toList()..sort();
  }

  Widget _bodyForTab() {
    final Widget forumContent;
    final Widget messagesContent;
    if (_repo.hasLocalAccount) {
      forumContent = _forumBody();
      messagesContent = MessagesPage(
        controller: _messagesPageController,
        repository: _repo,
        onRecoverConnection: _recoverForumForUser,
        refreshSignal: _messageRefreshSignal,
        showArchived: _showArchivedMessages,
        onArchiveViewChanged: _setMessageArchiveView,
        onSelectionChanged: _setMessageSelectionActive,
        onRefreshStateChanged: _setMessageRefreshing,
      );
    } else if (_isForumWebVpnRecoveryPending) {
      forumContent = const _LoadingState();
      messagesContent = const _LoadingState();
    } else {
      forumContent = _loggedOutForumTab(
        const EmptyState(
          icon: Icons.forum,
          title: '暂未登录乐乎论坛',
          message: '登录后可浏览和参与论坛讨论',
        ),
      );
      messagesContent = _loggedOutForumTab(
        const EmptyState(
          icon: Icons.chat_bubble,
          title: '暂未登录乐乎论坛',
          message: '登录后可查看论坛消息',
        ),
      );
    }
    return IndexedStack(
      index: _tabIndex,
      children: [
        _homeBody(),
        forumContent,
        messagesContent,
        ProfilePage(
          profile: _repo.profile,
          summary: _repo.userSummary,
          isOnline: _repo.isOnline,
          hasLocalAccount: _repo.hasLocalAccount,
          hasCachedSummary: _repo.hasCachedUserSummary,
          isBusy: _reloadingSession,
          onEditProfile: _openProfileSettings,
          activityCountsFuture: _profileActivityCountsFuture,
          onOpenActivity: (kind) => unawaited(_openProfileActivity(kind)),
          onOpenDrafts: () => unawaited(_openDraftBox()),
        ),
      ],
    );
  }

  Widget _loggedOutForumTab(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (mounted && _tabIndex != 0) setState(() => _tabIndex = 0);
      },
      child: child,
    );
  }

  Future<ForumActivityCounts>? get _profileActivityCountsFuture {
    if (!_repo.isOnline && !_repo.hasCachedActivityCounts) {
      return null;
    }
    return _activityCountsFuture ??= _repo.fetchActivityCounts();
  }

  Widget _homeBody() {
    return HomeDashboardPage(
      profile: _repo.profile,
      isOnline: _repo.isOnline,
      hasLocalAccount: _repo.hasLocalAccount,
      forumRequiresReauthentication: _repo.connectionState ==
          ForumConnectionState.reauthenticationRequired,
      hasAcademicAccount: _hasAcademicSession,
      academicStudentId: _academicStudentId,
      isAcademicLoginCompleting: _syncingAcademicSchedule,
      isCheckingConnection: _checkingForumConnection,
      isInitialConnectionCheck: _isInitialForumConnectionCheck,
      isBusy: _reloadingSession,
      onLogin: _openAccountManager,
      onRelogin: _relogin,
      onOpenAcademicSystem: _syncingAcademicSchedule
          ? _showScheduleSyncingSnack
          : () => unawaited(_openAcademicSystem()),
      onOpenAnnouncements: () => unawaited(_openAnnouncements()),
      onOpenEmptyClassroom: () => unawaited(_openEmptyClassroom()),
      onOpenCourseRatings: () => unawaited(_openCourseRatings()),
      todayCourseContent:
          _syncingAcademicSchedule ? '课表获取中...' : _scheduleSummaryText,
      announcementContent: _announcementSummaryText,
      isDemo: widget.isDemo,
    );
  }

  void _openAccountManager() {
    if (widget.isDemo) {
      _showSnack('请在设置中退出演示模式');
      return;
    }
    widget.onboardingController.openAccountManager(
      academicLoggedIn: _hasAcademicSession,
      academicExpired: _academicSessionExpired,
      forumStatus: _forumAccountStatus,
      webVpnEnabled: _webVpnEnabled,
      webVpnServiceStatus: _webVpnServiceStatus,
    );
    unawaited(_refreshWebVpnStatus());
  }

  ForumAccountStatus get _forumAccountStatus {
    if (_webVpnReloginRequired && _repo.hasLocalAccount) {
      return ForumAccountStatus.webVpnLoginRequired;
    }
    if (!_repo.hasLocalAccount) {
      return defaultTargetPlatform == TargetPlatform.iOS &&
              !ForumUrlResolver.usesWebVpn
          ? ForumAccountStatus.directLoginUnavailable
          : ForumAccountStatus.signedOut;
    }
    if (_checkingForumConnection || _reloadingSession) {
      return ForumAccountStatus.connecting;
    }
    return switch (_repo.connectionState) {
      ForumConnectionState.firstUse => ForumAccountStatus.signedOut,
      ForumConnectionState.cachedOffline =>
        ForumAccountStatus.connectionUnavailable,
      ForumConnectionState.reauthenticationRequired =>
        ForumAccountStatus.reauthenticationRequired,
      ForumConnectionState.online => ForumAccountStatus.loggedIn,
    };
  }

  void _syncOnboardingAccountStatus() {
    if (_onboardingStatusSyncScheduled || !mounted) return;
    _onboardingStatusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onboardingStatusSyncScheduled = false;
      if (!mounted) return;
      widget.onboardingController.updateAccountStatus(
        academicLoggedIn: _hasAcademicSession,
        academicExpired: _academicSessionExpired,
        forumStatus: _forumAccountStatus,
        webVpnEnabled: _webVpnEnabled,
        webVpnServiceStatus: _webVpnServiceStatus,
      );
    });
  }

  Future<void> _loadNetworkSettings() async {
    try {
      final settings = await _clientSettingsService.loadNetworkSettings();
      final accessModeChanged =
          ForumUrlResolver.usesWebVpn != settings.webVpnEnabled;
      if (accessModeChanged) {
        _invalidateForumRepositoryReloads();
      }
      ForumUrlResolver.configure(
        useWebVpn: settings.webVpnEnabled,
      );
      ClassroomUrlResolver.configure(
        useWebVpn: settings.webVpnEnabled,
      );
      ForumImageHeaders.clearCache();
      if (!mounted) {
        return;
      }
      setState(() {
        _webVpnEnabled = settings.webVpnEnabled;
      });
      _syncOnboardingAccountStatus();
    } on Object {
      // 网络设置读取失败时保留当前访问模式，不阻断首页加载。
    }
  }

  Future<void> _setWebVpnEnabled(bool value) async {
    final settings = await _clientSettingsService.loadNetworkSettings();
    if (settings.webVpnEnabled != value) {
      await _clientSettingsService.saveNetworkSettings(
        settings.copyWith(webVpnEnabled: value),
      );
    }
    final accessModeChanged =
        ForumUrlResolver.usesWebVpn != value || _webVpnEnabled != value;
    if (accessModeChanged) {
      _invalidateForumRepositoryReloads();
    }
    ForumUrlResolver.configure(useWebVpn: value);
    ClassroomUrlResolver.configure(useWebVpn: value);
    ForumImageHeaders.clearCache();
    if (mounted) {
      setState(() {
        _webVpnEnabled = value;
        if (accessModeChanged && _reloadingSession) {
          _reloadingSession = false;
        }
      });
      _syncOnboardingAccountStatus();
    }
  }

  Future<bool> _changeWebVpnFromAccountManager(bool enabled) async {
    if (widget.isDemo || !mounted) return false;
    if (enabled) {
      final result = await Navigator.of(context).push<NativeLoginResult>(
        shuyoRoute(builder: (context) => const NativeLoginPage.webVpn()),
      );
      if (result != NativeLoginResult.authenticated || !mounted) return false;
      setState(() => _webVpnReloginRequired = false);
    }
    try {
      await _setWebVpnEnabled(enabled);
      if (!mounted) return false;
      if (!enabled) {
        // Direct and WebVPN forum sessions are intentionally isolated. A
        // deliberate switch back to direct access always starts a fresh forum
        // login, while the WebVPN session remains available for a later switch.
        await ForumAuthService().clearCookiesForMode(ForumAccessMode.direct);
        await const ForumAccountSnapshotStore().clear();
      }
      await _reloadForumRepositoryAfterAccessModeChange();
      if (!mounted) return false;
      if (enabled && _repo.hasLocalAccount && !_repo.isOnline) {
        final recovery = await _recoverForumConnection(
          forceValidation: true,
          userInitiated: true,
        );
        if (mounted && recovery.isRestored) {
          _showSnack('WebVPN已登录，论坛连接已恢复');
        }
      }
      return true;
    } on Object catch (error) {
      if (mounted) _showSnack('WebVPN设置失败：${_friendlyError(error)}');
      return false;
    }
  }

  Future<void> _refreshScheduleSummaryQuietly() async {
    if (_loadingScheduleSummary || _syncingAcademicSchedule) {
      return;
    }
    _loadingScheduleSummary = true;
    try {
      final summary = await _scheduleRepository.homeSummary();
      unawaited(_scheduleWidgetService.syncFromCache());
      if (!mounted || summary.text == _scheduleSummaryText) {
        return;
      }
      setState(() => _scheduleSummaryText = summary.text);
    } on Object {
      if (mounted && _scheduleSummaryText == '正在读取课表...') {
        setState(() => _scheduleSummaryText = '点击同步教务课表');
      }
    } finally {
      _loadingScheduleSummary = false;
    }
  }

  Future<bool> _syncScheduleAfterAcademicLogin() async {
    if (widget.isDemo) {
      return false;
    }
    _debugAcademicFlow('post-login sync start');
    if (_syncingAcademicSchedule) {
      return false;
    }
    _loadingScheduleSummary = true;
    _syncingAcademicSchedule = true;
    if (mounted) {
      setState(() => _scheduleSummaryText = '课表获取中...');
    }
    try {
      await _scheduleRepository.refreshSchedule();
      final summary = await _scheduleRepository.homeSummary();
      unawaited(_scheduleWidgetService.syncFromCache());
      if (!mounted) {
        return false;
      }
      setState(() => _scheduleSummaryText = summary.text);
      // Reminder permissions are opt-in and must not be requested as part of
      // the automatic post-login schedule sync.
      await _scheduleNotificationService.syncScheduleReminders();
      _debugAcademicFlow('post-login sync success');
      _showSnack('校园账户已登录，课表已同步');
      return true;
    } on AcademicAuthException catch (error, stackTrace) {
      _debugAcademicFlow(
        'post-login sync rejected authentication: $error',
        stackTrace: stackTrace,
      );
      if (mounted) {
        final summary = await _scheduleRepository.homeSummary();
        if (mounted) {
          setState(() => _scheduleSummaryText = summary.text);
        }
      }
      _showSnack('校园账户登录未完成，请重试');
      return false;
    } on Object catch (error, stackTrace) {
      _debugAcademicFlow(
        'post-login sync failed: $error',
        stackTrace: stackTrace,
      );
      if (mounted) {
        final summary = await _scheduleRepository.homeSummary();
        if (mounted) {
          setState(() => _scheduleSummaryText = summary.text);
        }
      }
      _showSnack('课表同步失败，请稍后重试');
      return false;
    } finally {
      _loadingScheduleSummary = false;
      if (mounted) {
        setState(() => _syncingAcademicSchedule = false);
      } else {
        _syncingAcademicSchedule = false;
      }
    }
  }

  Future<ForumWebVpnPreparationResult>
      _prepareForumWebVpnSessionInBackground() async {
    if (!ForumUrlResolver.usesWebVpn) {
      return ForumWebVpnPreparationResult.ready;
    }
    if (!mounted) {
      return ForumWebVpnPreparationResult.unavailable;
    }
    final existing = _forumWebVpnPreloadCompleter;
    if (existing != null) {
      return existing.future.timeout(
        HttpTimeout.normal,
        onTimeout: () => ForumWebVpnPreparationResult.unavailable,
      );
    }
    final completer = Completer<ForumWebVpnPreparationResult>();
    setState(() {
      _forumWebVpnPreloadCompleter = completer;
      _forumWebVpnPreloadToken++;
    });
    try {
      return await completer.future.timeout(
        HttpTimeout.normal,
        onTimeout: () => ForumWebVpnPreparationResult.unavailable,
      );
    } finally {
      if (mounted && identical(_forumWebVpnPreloadCompleter, completer)) {
        setState(() => _forumWebVpnPreloadCompleter = null);
      }
    }
  }

  void _completeForumWebVpnPreload(ForumWebVpnPreparationResult result) {
    final completer = _forumWebVpnPreloadCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  bool get _isForumWebVpnRecoveryPending {
    return !_repo.isOnline &&
        _webVpnEnabled &&
        ForumUrlResolver.mode == ForumAccessMode.webVpn &&
        (_forumRecoveryFuture != null || _forumWebVpnPreloadCompleter != null);
  }

  Future<void> _loadAnnouncementSummaryFromCache() async {
    try {
      final summary = await _announcementRepository.homeSummary();
      if (!mounted || summary.text == _announcementSummaryText) {
        return;
      }
      setState(() => _announcementSummaryText = summary.text);
    } on Object {
      if (mounted && _announcementSummaryText == '正在读取通知公告...') {
        setState(() => _announcementSummaryText = '点击查看通知公告');
      }
    }
  }

  Future<void> _refreshAnnouncementSummaryQuietly() async {
    if (_loadingAnnouncementSummary) {
      return;
    }
    _loadingAnnouncementSummary = true;
    try {
      final items = await _announcementRepository.fetchAnnouncements();
      final text = items.isEmpty ? '点击查看通知公告' : items.first.title;
      if (!mounted || text == _announcementSummaryText) {
        return;
      }
      setState(() => _announcementSummaryText = text);
    } on Object {
      if (mounted && _announcementSummaryText == '正在读取通知公告...') {
        setState(() => _announcementSummaryText = '点击查看通知公告');
      }
    } finally {
      _loadingAnnouncementSummary = false;
    }
  }

  Widget _forumBody() {
    return Column(
      children: [
        ForumFilterBar(
          categories: _repo.categories,
          isHot: _feedQuery.hot,
          selectedCategoryId: _feedQuery.categoryId,
          onToggleMode: () => _setFeedQuery(
            TopicFeedQuery(
              categoryId: _feedQuery.categoryId,
              hot: !_feedQuery.hot,
            ),
            forceRefresh: true,
          ),
          onSelectCategory: (id) => _setFeedQuery(
            TopicFeedQuery(categoryId: id, hot: _feedQuery.hot),
          ),
        ),
        Expanded(
          child: _topicList(
            future: _feedFuture,
            refresh: _refreshFeed,
            controller: _forumTopicListController,
            refreshIndicatorKey: _forumRefreshIndicatorKey,
            canLoadMore: _repo.canLoadMoreFeed(_feedQuery),
            isLoadingMore: _loadingMoreFeed,
            loadMoreError: _loadMoreFeedError,
            loadMore: _loadMoreFeed,
          ),
        ),
      ],
    );
  }

  Widget _topicList({
    required Future<List<TopicListItem>> future,
    required Future<void> Function() refresh,
    required TopicListPageController controller,
    required GlobalKey<RefreshIndicatorState> refreshIndicatorKey,
    required bool canLoadMore,
    required bool isLoadingMore,
    required String? loadMoreError,
    required Future<void> Function() loadMore,
  }) {
    final cachedTopics = _feedSnapshots[_feedQuery.key];
    return FutureBuilder<List<TopicListItem>>(
      future: future,
      initialData: cachedTopics,
      builder: (context, snapshot) {
        final topics = snapshot.data ?? cachedTopics;
        if (topics == null &&
            snapshot.connectionState != ConnectionState.done) {
          return const _LoadingState();
        }
        if (topics == null && snapshot.hasError) {
          return _ErrorState(
            title: '列表加载失败',
            message: _friendlyError(snapshot.error!),
            onRetry: () => refresh(),
          );
        }
        final visibleTopics = topics ?? const <TopicListItem>[];
        if (visibleTopics.isEmpty) {
          return RefreshIndicator(
            key: refreshIndicatorKey,
            onRefresh: refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 96),
                EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '暂无内容',
                  message: _repo.isCacheOnly ? '请尝试重新登录。' : '论坛暂时没有返回主题。',
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          key: refreshIndicatorKey,
          onRefresh: refresh,
          child: TopicListPage(
            controller: controller,
            topics: visibleTopics,
            users: _repo.users,
            previewForTopic: _repo.fetchTopicPreview,
            categoryById: _repo.categoryById,
            onOpenTopic: (topic) => unawaited(_openTopic(topic)),
            onOpenUser: (user) => _openUserProfile(user.username),
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            loadMoreError: loadMoreError,
            onLoadMore: loadMore,
          ),
        );
      },
    );
  }

  Future<void> _handleForumHeaderDoubleTap() async {
    if (_tabIndex != 1) {
      return;
    }
    await _forumTopicListController.scrollToTop();
    if (!mounted || _tabIndex != 1) {
      return;
    }
    final refreshIndicator = _forumRefreshIndicatorKey.currentState;
    if (refreshIndicator == null) {
      await _refreshFeed();
      return;
    }
    await refreshIndicator.show();
  }

  void _resetFeedFuture({bool forceRefresh = false}) {
    final query = _feedQuery;
    _feedFuture = _cacheFeedFuture(
      query.key,
      _repo.fetchTopicFeed(
        query,
        forceRefresh: forceRefresh,
      ),
    );
    if (!forceRefresh) {
      unawaited(_refreshFeedQuietlyAfterCache(query));
    }
    _loadingMoreFeed = false;
    _loadMoreFeedError = null;
  }

  Future<void> _refreshFeedQuietlyAfterCache(TopicFeedQuery query) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted || _feedSnapshots[query.key] == null) {
      return;
    }
    final recovery = _forumRecoveryFuture;
    if (!_repo.isOnline && recovery != null) {
      await recovery;
    }
    if (!_repo.isOnline) {
      return;
    }
    try {
      final topics = await _repo.fetchTopicFeed(query, forceRefresh: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _feedSnapshots[query.key] = topics;
        if (_feedQuery.key == query.key) {
          _feedFuture = Future.value(topics);
        }
      });
    } on Object {
      // 初始静默刷新失败时保留缓存，不打扰用户。
    }
  }

  Future<ForumRecoveryResult> _recoverForumConnection({
    bool forceValidation = false,
    bool userInitiated = false,
  }) {
    if (widget.isDemo) {
      return Future.value(
        ForumRecoveryResult(
            status: ForumRecoveryStatus.restored, repository: _repo),
      );
    }
    final pending = _forumRecoveryFuture;
    if (pending != null) {
      return pending;
    }
    final generation = _forumRecoveryGeneration;
    final operation = _performForumConnectionRecovery(
      forceValidation: forceValidation,
      generation: generation,
      allowWebViewPreparation: userInitiated,
    ).timeout(
      userInitiated
          ? _userForumRecoveryTimeout
          : ForumUrlResolver.usesWebVpn
              ? _webVpnForumRecoveryTimeout
              : _directForumRecoveryTimeout,
      onTimeout: () => _handleForumRecoveryTimeout(generation),
    );
    late final Future<ForumRecoveryResult> shared;
    shared = operation.whenComplete(() {
      if (identical(_forumRecoveryFuture, shared)) {
        _forumRecoveryFuture = null;
      }
    });
    _forumRecoveryFuture = shared;
    return shared;
  }

  Future<ForumRecoveryResult> _recoverForumAutomatically() async {
    final lastFailure = _lastAutomaticForumRecoveryFailure;
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) <
            _automaticForumRecoveryCooldown) {
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.unavailable,
        repository: _repo,
      );
    }
    final result = await _recoverForumConnection();
    _lastAutomaticForumRecoveryFailure =
        result.isRestored ? null : DateTime.now();
    return result;
  }

  Future<ForumRecoveryResult> _recoverForumForUser() {
    return _recoverForumConnection(userInitiated: true);
  }

  Future<ForumRecoveryResult> _handleForumRecoveryTimeout(
    int generation,
  ) async {
    if (generation == _forumRecoveryGeneration) {
      _forumRecoveryGeneration++;
      final completer = _forumWebVpnPreloadCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(ForumWebVpnPreparationResult.unavailable);
      }
      _forumWebVpnPreloadCompleter = null;
      _repo.markConnectionUnavailable();
      if (mounted) {
        setState(() {
          _reloadingSession = false;
          _checkingForumConnection = false;
          _isInitialForumConnectionCheck = false;
        });
        _syncOnboardingAccountStatus();
      }
    }
    return ForumRecoveryResult(
      status: ForumRecoveryStatus.unavailable,
      repository: _repo,
      error: const ForumConnectionUnavailableException('论坛连接超时，请稍后重试'),
    );
  }

  Future<ForumRecoveryResult> _performForumConnectionRecovery({
    required bool forceValidation,
    required int generation,
    required bool allowWebViewPreparation,
  }) async {
    if (!mounted) {
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.unavailable,
        repository: _repo,
      );
    }
    if (!_repo.hasLocalAccount) {
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.requiresReauthentication,
        repository: _repo,
      );
    }
    if (_repo.isOnline && !forceValidation) {
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.restored,
        repository: _repo,
      );
    }

    if (mounted) {
      setState(() {
        _reloadingSession = true;
        _checkingForumConnection = true;
      });
      _syncOnboardingAccountStatus();
    }

    try {
      if (ForumUrlResolver.usesWebVpn) {
        final portalStatus = await _validateWebVpnSessionForForum();
        _ensureForumRecoveryCurrent(generation);
        if (portalStatus == WebVpnSessionStatus.loginRequired) {
          _repo.markConnectionUnavailable();
          await _handleWebVpnExpired();
          return ForumRecoveryResult(
            status: ForumRecoveryStatus.webVpnLoginRequired,
            repository: _repo,
            error: const ForumAuthException('WebVPN已失效，需要重新登录'),
          );
        }
        if (portalStatus == WebVpnSessionStatus.unavailable) {
          _repo.markConnectionUnavailable();
          return ForumRecoveryResult(
            status: ForumRecoveryStatus.unavailable,
            repository: _repo,
            error: const ForumConnectionUnavailableException(
              '暂时无法验证 WebVPN 连接，请稍后重试',
            ),
          );
        }
      }

      final nextRepository = await _connectForumRepositoryWithFallback(
        generation,
        allowWebViewPreparation: allowWebViewPreparation,
      );
      _ensureForumRecoveryCurrent(generation);
      if (mounted) {
        setState(() {
          _repo = nextRepository;
          _activityCountsFuture = null;
          _clearFeedSnapshots();
          _resetFeedFuture(forceRefresh: true);
        });
        unawaited(_loadLocalForumBadges());
      }
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.restored,
        repository: nextRepository,
      );
    } on _ForumRecoveryCancelled {
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.unavailable,
        repository: _repo,
      );
    } on ForumAuthException catch (error) {
      _repo.markAuthenticationRequired();
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.requiresReauthentication,
        repository: _repo,
        error: error,
      );
    } on Object catch (error) {
      if (error is ForumConnectionUnavailableException ||
          _isForumTransportError(error)) {
        _repo.markConnectionUnavailable();
      }
      return ForumRecoveryResult(
        status: ForumRecoveryStatus.unavailable,
        repository: _repo,
        error: error,
      );
    } finally {
      final wasInitialConnectionCheck = _isInitialForumConnectionCheck;
      if (wasInitialConnectionCheck) {
        _isInitialForumConnectionCheck = false;
      }
      if (mounted && generation == _forumRecoveryGeneration) {
        setState(() {
          _reloadingSession = false;
          _checkingForumConnection = false;
        });
        _syncOnboardingAccountStatus();
      }
    }
  }

  Future<WebVpnSessionStatus> _validateWebVpnSessionForForum() async {
    final status = await AcademicAuthService().validateWebVpnSession();
    return status;
  }

  Future<void> _handleWebVpnExpired() async {
    if (!mounted) return;
    await _setWebVpnEnabled(false);
    if (!mounted) return;
    setState(() => _webVpnReloginRequired = true);
    _repo.markConnectionUnavailable();
    _syncOnboardingAccountStatus();
    _showSnack('WebVPN已失效，需要重新登录');
  }

  Future<ForumRepository> _connectForumRepositoryWithFallback(
    int generation, {
    required bool allowWebViewPreparation,
  }) async {
    try {
      final repository = await widget.reloadRepository();
      _ensureForumRecoveryCurrent(generation);
      return repository;
    } on ForumAuthException {
      rethrow;
    } on Object catch (firstError) {
      _ensureForumRecoveryCurrent(generation);
      if (!allowWebViewPreparation ||
          !ForumUrlResolver.usesWebVpn ||
          !_isForumTransportError(firstError)) {
        rethrow;
      }
      final prepared = await _prepareForumWebVpnSessionInBackground();
      _ensureForumRecoveryCurrent(generation);
      if (prepared == ForumWebVpnPreparationResult.loginRequired) {
        throw const ForumAuthException('论坛登录状态已失效');
      }
      if (prepared != ForumWebVpnPreparationResult.ready) rethrow;
      final repository = await widget.reloadRepository();
      _ensureForumRecoveryCurrent(generation);
      return repository;
    }
  }

  void _ensureForumRecoveryCurrent(int generation) {
    if (generation != _forumRecoveryGeneration) {
      throw const _ForumRecoveryCancelled();
    }
  }

  void _cancelForumRecovery() {
    _forumRecoveryGeneration++;
    final completer = _forumWebVpnPreloadCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(ForumWebVpnPreparationResult.unavailable);
    }
    _forumWebVpnPreloadCompleter = null;
    _forumRecoveryFuture = null;
    if (mounted) {
      setState(() {
        _reloadingSession = false;
        _checkingForumConnection = false;
        _isInitialForumConnectionCheck = false;
      });
    }
  }

  Future<List<TopicListItem>> _cacheFeedFuture(
    String queryKey,
    Future<List<TopicListItem>> future,
  ) {
    final token = ++_feedRequestSequence;
    _feedRequestTokens[queryKey] = token;
    return future.then((topics) {
      if (_feedRequestTokens[queryKey] == token) {
        _feedSnapshots[queryKey] = topics;
      }
      return topics;
    });
  }

  void _clearFeedSnapshots() {
    _feedSnapshots.clear();
    _feedRequestTokens.clear();
    _feedRequestSequence++;
  }

  void _setFeedQuery(TopicFeedQuery query, {bool forceRefresh = false}) {
    setState(() {
      _feedQuery = query;
      _resetFeedFuture(forceRefresh: forceRefresh);
    });
  }

  Future<void> _refreshFeed() async {
    final startedAt = DateTime.now();
    final queryKey = _feedQuery.key;
    try {
      if (!_repo.isOnline) {
        final recovery = await _recoverForumForUser();
        if (!mounted) {
          return;
        }
        if (!recovery.isRestored || !recovery.repository.isOnline) {
          _showSnack(_forumRecoveryMessage(recovery));
          return;
        }
      }
      final repository = _repo;
      final future = _cacheFeedFuture(
        queryKey,
        repository.fetchTopicFeed(_feedQuery, forceRefresh: true),
      );
      setState(() {
        _feedFuture = future;
        _loadMoreFeedError = null;
      });
      try {
        await future;
        if (mounted) {
          setState(() {});
        }
      } on Object catch (error) {
        if (error is ForumAuthException) {
          repository.markAuthenticationRequired();
        } else if (_isForumTransportError(error)) {
          repository.markConnectionUnavailable();
        }
        _syncOnboardingAccountStatus();
        if (!mounted) {
          return;
        }
        if (_feedSnapshots[queryKey] != null) {
          _showSnack(_refreshFailureMessage(error, prefix: '列表刷新失败'));
          setState(() {});
          return;
        }
        _showSnack(_refreshFailureMessage(error, prefix: '列表刷新失败'));
      }
    } finally {
      final remaining =
          _minimumForumRefreshDuration - DateTime.now().difference(startedAt);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
  }

  Future<void> _loadMoreFeed() async {
    final query = _feedQuery;
    if (_loadingMoreFeed || !_repo.canLoadMoreFeed(query)) {
      return;
    }
    final now = DateTime.now();
    final lastAttempt = _lastLoadMoreFeedAttempt;
    if (_loadMoreFeedError == null &&
        lastAttempt != null &&
        now.difference(lastAttempt) < _feedLoadMoreThrottle) {
      return;
    }
    _lastLoadMoreFeedAttempt = now;
    final queryKey = query.key;
    setState(() {
      _loadingMoreFeed = true;
      _loadMoreFeedError = null;
    });
    try {
      final topics = await _repo.loadMoreTopicFeed(query);
      if (!mounted || queryKey != _feedQuery.key) {
        return;
      }
      setState(() {
        _feedSnapshots[queryKey] = topics;
        _feedFuture = Future.value(topics);
      });
    } on Object catch (error) {
      if (!mounted || queryKey != _feedQuery.key) {
        return;
      }
      setState(() => _loadMoreFeedError = _loadMoreFeedErrorText(error));
    } finally {
      if (mounted) {
        setState(() => _loadingMoreFeed = false);
      }
    }
  }

  String _loadMoreFeedErrorText(Object error) {
    if (error is ForumAuthException) {
      return '加载失败，登录状态可能已变化';
    }
    return '加载失败，点击重试';
  }

  Future<void> _openTopic(TopicListItem topic) async {
    if (!_repo.hasLocalAccount) {
      _showSnack('当前没有可用的论坛账户，请通过首页登录。');
      return;
    }
    if (!mounted) {
      return;
    }
    final deleted = await Navigator.of(context).push<bool>(
      shuyoRoute(
        builder: (context) => TopicDetailPage(
          repository: _repo,
          topic: topic,
          onRecoverConnection: _recoverForumForUser,
          onLoginRequired: _login,
          onSessionExpired: _clearExpiredLogin,
          onOpenForumRoute: _openForumRoute,
          onBookmarkChanged: _refreshProfileActivityCounts,
        ),
      ),
    );
    if (deleted == true && mounted) {
      await _refreshFeed();
    }
  }

  void _openForumRoute(String url) {
    final path = Uri.tryParse(url)?.path;
    if (path == '/faq' || path == '/faq/') {
      Navigator.of(context).push<void>(
        shuyoRoute(builder: (_) => const ForumFaqPage()),
      );
      return;
    }
    final targetTab =
        path == '/my/preferences/account' || path == '/my/preferences/account/'
            ? 3
            : path == '/latest' || path == '/latest/'
                ? 1
                : null;
    if (targetTab == null || !mounted) {
      return;
    }
    // The link may have been clicked from one or more pushed topic pages.
    // Return to the shell before selecting the destination tab.
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _tabIndex = targetTab);
  }

  void _refreshProfileActivityCounts() {
    if (!mounted || !_repo.isOnline) {
      return;
    }
    setState(() {
      _activityCountsFuture = _repo.fetchActivityCounts(forceRefresh: true);
    });
  }

  Future<void> _openSearch() async {
    if (!_repo.isOnline) {
      _showSnack(
        _forumUnavailableMessage,
      );
      return;
    }
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => ForumSearchPage(
          repository: _repo,
          onRecoverConnection: _recoverForumForUser,
          onLoginRequired: _login,
          onBookmarkChanged: _refreshProfileActivityCounts,
          onSessionExpired: _clearExpiredLogin,
          onOpenForumRoute: _openForumRoute,
        ),
      ),
    );
  }

  Future<void> _openUserProfile(String username) async {
    if (!_repo.isOnline) {
      _showSnack(
        _forumUnavailableMessage,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => UserProfilePage(
          repository: _repo,
          username: username,
          onRecoverConnection: _recoverForumForUser,
        ),
      ),
    );
  }

  Future<void> _openProfileSettings() async {
    if (!_repo.isOnline) {
      _showSnack(_forumUnavailableMessage);
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      shuyoRoute(
        builder: (context) => ProfileSettingsPage(repository: _repo),
      ),
    );
    if (!mounted) {
      return;
    }
    if (changed == true) {
      try {
        await _repo.fetchCurrentUserProfile(forceRefresh: true);
      } on Object {
        // 设置页内已经完成提交；返回刷新失败时保持本地已更新的资料。
      }
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _openProfileActivity(ForumActivityKind kind) async {
    if (!_repo.isOnline) {
      _showSnack(_forumUnavailableMessage);
      return;
    }
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => ForumActivityPage(
          repository: _repo,
          kind: kind,
          onRecoverConnection: _recoverForumForUser,
          onLoginRequired: _login,
          onSessionExpired: _clearExpiredLogin,
          onBookmarkChanged: _refreshProfileActivityCounts,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    _refreshProfileActivityCounts();
  }

  Future<void> _openDraftBox() async {
    if (!_repo.hasLocalAccount) return;
    await Navigator.of(context).push<void>(
      shuyoRoute(builder: (context) => DraftBoxPage(repository: _repo)),
    );
  }

  Future<void> _openClientSettings() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => ClientSettingsPage(
          settingsService: _clientSettingsService,
          scheduleNotificationService: _scheduleNotificationService,
          backendRepository: _clientBackendRepository,
          selectedThemeId: widget.selectedThemeId,
          followSystemTheme: widget.followSystemTheme,
          onThemeChanged: widget.onThemeChanged,
          onFollowSystemThemeChanged: widget.onFollowSystemThemeChanged,
          isOnline: _repo.isOnline,
          loadForumCacheSize: _repo.forumCacheStorageSize,
          onClearForumCache: _clearForumCache,
          hasAcademicAccount: _hasAcademicSession,
          hasForumAccount: _repo.hasLocalAccount,
          onAcademicLogout: _logoutAcademicAccount,
          onForumLogout: _logoutForumAccount,
          isDemo: widget.isDemo,
          onExitDemo: widget.onExitDemo,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
  }

  Future<int> _clearForumCache() async {
    final released = await _repo.clearForumCache();
    if (!mounted) {
      return released;
    }
    setState(() {
      _clearFeedSnapshots();
      _resetFeedFuture();
      _activityCountsFuture = null;
    });
    return released;
  }

  Future<void> _openCreateTopic() async {
    if (!_repo.isOnline) {
      _showSnack(_forumUnavailableMessage);
      return;
    }
    final result = await Navigator.of(context).push<CreatedTopicResult>(
      shuyoRoute(
        builder: (context) => CreateTopicPage(
          repository: _repo,
          categories: _repo.categories,
          initialCategoryId: _feedQuery.categoryId,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    _showSnack('帖子已发布');
    await _refreshFeed();
    await _openTopic(
      TopicListItem(
        id: result.post.topicId,
        title: result.title,
        postsCount: 1,
        replyCount: 0,
        highestPostNumber: 1,
        views: 0,
        likeCount: 0,
        categoryId: result.categoryId,
        posters: const [],
        createdAt: result.post.createdAt,
        lastPostedAt: result.post.createdAt,
      ),
    );
  }

  Future<void> _openNotifications() async {
    if (!_repo.isOnline) {
      _showSnack(
        _forumUnavailableMessage,
      );
      return;
    }
    unawaited(_markNotificationBadgeSeen());
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => NotificationsPage(
          repository: _repo,
          onRecoverConnection: _recoverForumForUser,
          onLoginRequired: _login,
          onSessionExpired: _clearExpiredLogin,
          onBookmarkChanged: _refreshProfileActivityCounts,
        ),
      ),
    );
  }

  Future<void> _login() async {
    if (widget.isDemo) {
      return;
    }
    if (_reloadingSession) return;
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        !ForumUrlResolver.usesWebVpn) {
      _showSnack('iOS暂时仅支持开启webvpn访问');
      return;
    }
    if (ForumUrlResolver.usesWebVpn) {
      final status = await _validateWebVpnSessionForForum();
      if (!mounted) return;
      if (status == WebVpnSessionStatus.loginRequired) {
        await _handleWebVpnExpired();
        return;
      }
      if (status == WebVpnSessionStatus.unavailable) {
        _showSnack('暂时无法验证WebVPN连接，请稍后重试');
        return;
      }
    }
    final result = await Navigator.of(context).push<NativeLoginResult>(
      shuyoRoute(builder: (context) => const NativeLoginPage.forum()),
    );
    if (result == NativeLoginResult.authenticated && mounted) {
      await _reloadForumAfterLogin();
    }
  }

  Future<bool> _reloadForumAfterLogin() async {
    if (_reloadingSession) return false;
    setState(() => _reloadingSession = true);
    _syncOnboardingAccountStatus();
    try {
      final nextRepository = await widget.reloadRepository();
      if (!nextRepository.hasLocalAccount) {
        throw const ForumAuthException('论坛未返回有效的登录会话');
      }
      if (!mounted) return false;
      setState(() {
        _repo = nextRepository;
        _showArchivedMessages = false;
        _messageSelectionActive = false;
        _messageRefreshing = false;
        _reloadingSession = false;
        _activityCountsFuture = null;
        _clearFeedSnapshots();
        _resetFeedFuture(forceRefresh: true);
      });
      _syncOnboardingAccountStatus();
      unawaited(_initializeForumBadges());
      unawaited(_recordForumDailyActivity());
      _showSnack('乐乎论坛已登录');
      return true;
    } on Object catch (error) {
      if (!mounted) return false;
      if (error is ForumAuthException) {
        _repo.markAuthenticationRequired();
      } else if (_isForumTransportError(error)) {
        _repo.markConnectionUnavailable();
      }
      setState(() => _reloadingSession = false);
      _syncOnboardingAccountStatus();
      await _showErrorDialog(
        title: '论坛登录未完成',
        message: _friendlyError(error),
      );
      return false;
    }
  }

  Future<void> _relogin() async {
    if (widget.isDemo) {
      _showSnack('演示模式无需重新登录');
      return;
    }
    if (_reloadingSession) {
      return;
    }
    final recovery = await _recoverForumConnection(
      forceValidation: true,
      userInitiated: true,
    );
    if (!mounted) {
      return;
    }
    if (recovery.isRestored) {
      setState(() {
        _activityCountsFuture = null;
        _clearFeedSnapshots();
        _resetFeedFuture(forceRefresh: true);
      });
      unawaited(_initializeForumBadges());
      return;
    }
    if (recovery.status == ForumRecoveryStatus.webVpnLoginRequired) {
      return;
    }
    if (recovery.status == ForumRecoveryStatus.requiresReauthentication) {
      _showSnack('论坛登录状态已失效，请重新登录');
      await _login();
      return;
    }
    final relogin = await _confirmForumRelogin(
      _forumRecoveryMessage(recovery),
    );
    if (relogin && mounted) {
      await _login();
    }
  }

  Future<bool> _logoutForumAccount() async {
    _cancelForumRecovery();
    setState(() => _reloadingSession = true);
    _syncOnboardingAccountStatus();
    try {
      await _repo.clearLocalAccount();
      await _repo.clearLoginCookies();
      final nextRepository = await ForumRepositoryFactory.loadLocal();
      if (!mounted) {
        return false;
      }
      setState(() {
        _repo = nextRepository;
        _showArchivedMessages = false;
        _messageSelectionActive = false;
        _messageRefreshing = false;
        _reloadingSession = false;
        _activityCountsFuture = null;
        _clearFeedSnapshots();
        _resetFeedFuture();
      });
      _syncOnboardingAccountStatus();
      unawaited(_initializeForumBadges());
      return true;
    } on Object catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() => _reloadingSession = false);
      _syncOnboardingAccountStatus();
      await _showErrorDialog(
        title: '论坛账户退出失败',
        message: _friendlyError(error),
      );
      return false;
    }
  }

  Future<bool> _logoutAcademicAccount() async {
    _cancelForumRecovery();
    setState(() => _reloadingSession = true);
    try {
      final clearedNames = await AcademicAuthService().clearCookies();
      await AcademicAccountStore().clear();
      await ForumAuthService().removeCachedCookieNames(clearedNames);
      if (!mounted) return false;
      setState(() {
        _hasAcademicSession = false;
        _academicSessionExpired = false;
        _academicStudentId = null;
        _reloadingSession = false;
        if (ForumUrlResolver.usesWebVpn) {
          _repo.markConnectionUnavailable();
        }
      });
      _syncOnboardingAccountStatus();
      return true;
    } on Object catch (error) {
      if (!mounted) return false;
      setState(() => _reloadingSession = false);
      _syncOnboardingAccountStatus();
      await _showErrorDialog(
        title: '校园账户退出失败',
        message: _friendlyError(error),
      );
      return false;
    }
  }

  Future<bool> _confirmForumRelogin(String message) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('论坛连接失败'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('重新登录'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clearExpiredLogin() async {
    if (ForumUrlResolver.usesWebVpn) {
      final webVpnStatus = await _validateWebVpnSessionForForum();
      if (!mounted) return;
      if (webVpnStatus == WebVpnSessionStatus.loginRequired) {
        await _handleWebVpnExpired();
        return;
      }
    }
    try {
      await _repo.clearLoginCookies();
    } on Object {
      // Cookie 清理失败不应阻断 UI 回到可用状态。
    }
    final nextRepository = await ForumRepositoryFactory.loadLocal();
    nextRepository.markAuthenticationRequired();
    if (!mounted) {
      return;
    }
    setState(() {
      _repo = nextRepository;
      _showArchivedMessages = false;
      _messageSelectionActive = false;
      _messageRefreshing = false;
      _activityCountsFuture = null;
      _clearFeedSnapshots();
      _resetFeedFuture();
    });
    _syncOnboardingAccountStatus();
    unawaited(_initializeForumBadges());
  }

  Future<void> _openAcademicSystem({
    bool animatePush = true,
    AcademicScheduleCacheState? initialState,
    AcademicScheduleDisplayState? initialDisplayState,
    String? initialLoadError,
  }) async {
    final route = shuyoRoute<void>(
      animatePush: animatePush,
      builder: (context) => AcademicSchedulePage(
        repository: _scheduleRepository,
        notificationService: _scheduleNotificationService,
        widgetService: _scheduleWidgetService,
        onLoginRequired: _reauthenticateExpiredAcademicAccount,
        initialState: initialState,
        initialDisplayState: initialDisplayState,
        initialLoadError: initialLoadError,
      ),
    );
    _academicScheduleRoutes.add(route);
    try {
      await Navigator.of(context).push<void>(route);
    } finally {
      _academicScheduleRoutes.remove(route);
    }
    if (!mounted) {
      return;
    }
    await _refreshScheduleSummaryQuietly();
    unawaited(_scheduleNotificationService.syncScheduleReminders());
  }

  Future<void> _openAnnouncements() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => AnnouncementsPage(
          repository: _announcementRepository,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await _loadAnnouncementSummaryFromCache();
    unawaited(_refreshAnnouncementSummaryQuietly());
  }

  Future<void> _openEmptyClassroom() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => EmptyClassroomPage(
          repository: _classroomRepository,
          initialDate: widget.isDemo ? DateTime(2026, 9, 1) : null,
          onWebVpnExpired: widget.isDemo ? null : _handleWebVpnExpired,
        ),
      ),
    );
  }

  Future<void> _openCourseRatings() async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => CourseRatingPage(
          repository: _courseRatingRepository,
        ),
      ),
    );
  }

  Future<void> _checkClientBackendPrompts() async {
    if (widget.isDemo) {
      return;
    }
    if (_checkingClientBackendPrompts) {
      return;
    }
    _checkingClientBackendPrompts = true;
    _lastWebVpnStatusFetchAttempt = DateTime.now();
    try {
      final bootstrap =
          await _clientBackendRepository.fetchBootstrap(forceRefresh: true);
      if (!mounted) {
        return;
      }
      setState(() => _webVpnServiceStatus = bootstrap.webVpnStatus);
      _syncOnboardingAccountStatus();
      if (ClientUpdatePolicy.source == ClientUpdateSource.backend) {
        final version = bootstrap.version;
        if (version.isNewerThan(ClientAppInfo.buildNumber)) {
          final shouldPrompt =
              await _clientBackendRepository.shouldPromptUpdate(
            version.latestBuild,
          );
          if (mounted && shouldPrompt) {
            final openDownload = await showClientUpdatePrompt(
              context,
              update: version,
            );
            await _clientBackendRepository.markUpdatePrompted(
              version.latestBuild,
            );
            if (openDownload == true && version.hasDownloadUrl && mounted) {
              await _openUpdateDownload(version.downloadUrl);
            }
            return;
          }
        } else {
          await _clientBackendRepository.ensureUpdateBaselineInitialized(
            version.latestBuild,
          );
        }
      }

      if (!mounted) {
        return;
      }
      final announcement = bootstrap.latestAnnouncement;
      if (announcement == null) {
        await _clientBackendRepository.ensureAnnouncementBaselineInitialized();
        return;
      }
      final shouldPrompt = await _clientBackendRepository
          .shouldPromptAnnouncement(announcement.id);
      if (!mounted || !shouldPrompt) {
        return;
      }
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
      // 后端检查失败时不影响主流程。
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
      if (!mounted) return;
      setState(() => _webVpnServiceStatus = bootstrap.webVpnStatus);
      _syncOnboardingAccountStatus();
    } on Object {
      // A backend failure means the status is unknown, not that WebVPN is down.
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
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      _showSnack('无法打开下载链接');
    }
  }

  Future<void> _reloadForumRepositoryAfterAccessModeChange() async {
    if (_reloadingSession) {
      return;
    }
    final reloadToken = _nextForumRepositoryReloadToken();
    final accessMode = ForumUrlResolver.mode;
    setState(() => _reloadingSession = true);
    _syncOnboardingAccountStatus();
    try {
      final nextRepository = await _loadForumRepositoryForAccessModeChange();
      if (!_isCurrentForumRepositoryReload(reloadToken, accessMode)) {
        return;
      }
      setState(() {
        _repo = nextRepository;
        _showArchivedMessages = false;
        _messageSelectionActive = false;
        _messageRefreshing = false;
        _reloadingSession = false;
        _activityCountsFuture = null;
        _clearFeedSnapshots();
        _resetFeedFuture();
      });
      _syncOnboardingAccountStatus();
      unawaited(_initializeForumBadges());
      if (nextRepository.isOnline) {
        _showSnack('已切换论坛访问方式');
      }
      unawaited(_checkClientBackendPrompts());
    } on Object catch (error) {
      if (!_isCurrentForumRepositoryReload(reloadToken, accessMode)) {
        return;
      }
      setState(() => _reloadingSession = false);
      _syncOnboardingAccountStatus();
      await _showErrorDialog(
        title: '论坛重新加载失败',
        message: _friendlyError(error),
      );
    }
  }

  int _nextForumRepositoryReloadToken() {
    _forumRepositoryReloadToken++;
    return _forumRepositoryReloadToken;
  }

  void _invalidateForumRepositoryReloads() {
    _forumRepositoryReloadToken++;
  }

  bool _isCurrentForumRepositoryReload(
    int reloadToken,
    ForumAccessMode accessMode,
  ) {
    return mounted &&
        reloadToken == _forumRepositoryReloadToken &&
        ForumUrlResolver.mode == accessMode;
  }

  Future<ForumRepository> _loadForumRepositoryForAccessModeChange() {
    return ForumRepositoryFactory.loadLocal().timeout(
      _forumAccessModeReloadTimeout,
      onTimeout: () => FixtureForumRepository.load(),
    );
  }

  Future<void> _openAcademicLogin() async {
    if (widget.isDemo) {
      return;
    }
    if (_syncingAcademicSchedule) {
      _showScheduleSyncingSnack();
      return;
    }
    if (!mounted) return;
    _debugAcademicFlow('opening campus login');
    final result = await Navigator.of(context).push<NativeLoginResult>(
      shuyoRoute(builder: (context) => const NativeLoginPage()),
    );
    _debugAcademicFlow(
        'campus login returned result=${result?.name ?? 'cancelled'}');
    if (result != NativeLoginResult.authenticated || !mounted) return;
    setState(() {
      _hasAcademicSession = true;
      _academicSessionExpired = false;
    });
    await _loadAcademicStudentId();
    _syncOnboardingAccountStatus();
    await _persistAcademicLoginCookies();
    await _syncScheduleAfterAcademicLogin();
  }

  Future<void> _reauthenticateExpiredAcademicAccount() async {
    await AcademicAccountStore().markSessionExpired();
    if (!mounted) return;
    setState(() => _academicSessionExpired = true);
    _syncOnboardingAccountStatus();
    await _openAcademicLogin();
  }

  void _debugAcademicFlow(String message, {StackTrace? stackTrace}) {
    assert(() {
      debugPrint('[SHU_SCHEDULE_FLOW] $message');
      if (stackTrace != null) {
        debugPrintStack(
          label: '[SHU_SCHEDULE_FLOW] stack',
          stackTrace: stackTrace,
        );
      }
      return true;
    }());
  }

  void _showScheduleSyncingSnack() {
    _showSnack('正在获取课表，请稍后');
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String get _forumUnavailableMessage {
    if (_webVpnReloginRequired) {
      return 'WebVPN已失效，需要重新登录';
    }
    if (_repo.connectionState ==
        ForumConnectionState.reauthenticationRequired) {
      return '论坛登录状态已失效，请重新登录';
    }
    return _repo.hasLocalAccount ? '无法连接乐乎论坛，请稍后重试。' : '暂未登录乐乎论坛';
  }

  Future<void> _showErrorDialog({
    required String title,
    required String message,
  }) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  String _friendlyError(Object error) {
    if (error is ForumApiException) {
      return error.message;
    }
    return '操作失败，请稍后重试';
  }

  String _refreshFailureMessage(Object error, {required String prefix}) {
    if (error is ForumAuthException) {
      return '登录状态已失效，请尝试重新登录';
    }
    final message = _friendlyError(error);
    if (message == forumRefreshTooFastMessage) {
      return message;
    }
    return '$prefix：$message';
  }

  String _forumRecoveryMessage(ForumRecoveryResult result) {
    if (result.status == ForumRecoveryStatus.webVpnLoginRequired) {
      return 'WebVPN已失效，需要重新登录';
    }
    if (result.status == ForumRecoveryStatus.requiresReauthentication) {
      return '登录状态已失效，请尝试重新登录';
    }
    final error = result.error;
    if (error is ForumApiException &&
        error.message != forumRefreshTooFastMessage) {
      return error.message;
    }
    return '无法连接论坛，请尝试重新登录。';
  }
}

bool _isForumTransportError(Object error) {
  return error is ForumConnectionUnavailableException ||
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException;
}

class _ForumRecoveryCancelled implements Exception {
  const _ForumRecoveryCancelled();
}

class _NotificationFeedBadge {
  const _NotificationFeedBadge({
    required this.count,
    this.baselineKeys,
  });

  final int count;
  final Set<String>? baselineKeys;
}

class _TabBadgeIcon extends StatelessWidget {
  const _TabBadgeIcon({
    required this.icon,
    required this.count,
  });

  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    if (count <= 0) {
      return Icon(icon);
    }
    final label = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        Positioned(
          right: -10,
          top: -6,
          child: Container(
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.danger,
              borderRadius: const BorderRadius.all(Radius.circular(9)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: colors.onDanger,
                fontSize: 9.5,
                height: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(strokeWidth: 3),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: title,
      message: message,
      action: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    );
  }
}
