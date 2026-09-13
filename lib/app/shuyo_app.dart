import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';

import '../core/client_app_info.dart';
import '../core/classroom_url_resolver.dart';
import '../core/forum_url_resolver.dart';
import '../data/demo/demo_data_bundle.dart';
import '../data/demo/demo_forum_repository.dart';
import '../data/demo/demo_repositories.dart';
import '../data/demo/demo_session.dart';
import '../data/repositories/academic_schedule_repository.dart';
import '../data/repositories/forum_repository.dart';
import '../data/services/academic_account_store.dart';
import '../data/services/academic_auth_service.dart';
import '../data/services/academic_schedule_display_settings_service.dart';
import '../data/services/app_data_migration_service.dart';
import '../data/services/client_settings_service.dart';
import 'app_shell.dart';
import '../features/onboarding/startup_onboarding.dart';
import '../shared/theme/shuyo_theme.dart';
import '../shared/widgets/shuyo_launch_surface.dart';

class ShuYoApp extends StatefulWidget {
  const ShuYoApp({
    super.key,
    this.initialThemeId,
    this.initialFollowSystemTheme = false,
  });

  final String? initialThemeId;
  final bool initialFollowSystemTheme;

  @override
  State<ShuYoApp> createState() => _ShuYoAppState();
}

class _ShuYoAppState extends State<ShuYoApp> with WidgetsBindingObserver {
  final _settingsService = ClientSettingsService();
  final _dataMigrationService = AppDataMigrationService();
  final _onboardingController = StartupOnboardingController();
  late Future<_StartupData> _startupFuture;
  String _manualThemeId = ShuYoThemes.defaultId;
  bool _followSystemTheme = false;
  bool _demoMode = false;
  DemoDataBundle? _demoData;
  ForumRepository? _demoRepository;
  int _academicLoginSignal = 0;
  int _forumLoginSignal = 0;
  late final Future<bool> _initialScheduleWidgetLaunch;
  bool _initialWidgetLaunchConsumed = false;
  Brightness _systemBrightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    _manualThemeId = ShuYoThemes.byId(widget.initialThemeId).id;
    _followSystemTheme = widget.initialFollowSystemTheme;
    WidgetsBinding.instance.addObserver(this);
    _initialScheduleWidgetLaunch = _loadInitialScheduleWidgetLaunch();
    _startupFuture = _loadStartup();
    _loadTheme();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _onboardingController.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (brightness == _systemBrightness) {
      return;
    }
    _systemBrightness = brightness;
    if (_followSystemTheme) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = _effectiveTheme;
    return MaterialApp(
      title: 'ShuYo',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: theme.themeData(),
      home: FutureBuilder<_StartupData>(
        future: _startupFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _StartupError(error: snapshot.error.toString());
          }
          if (!snapshot.hasData) {
            return ShuYoLaunchSurface(theme: theme);
          }
          final data = snapshot.data!;
          final demo =
              _demoMode && _demoData != null && _demoRepository != null;
          final repository = demo ? _demoRepository! : data.repository;
          return StartupOnboarding(
            initiallyCompleted: demo || data.onboardingCompleted,
            initialAcademicLoggedIn: demo || data.hasAcademicSession,
            initialForumStatus: demo
                ? ForumAccountStatus.loggedIn
                : _forumAccountStatus(repository),
            onAcademicLoginCompleted: () {
              setState(() => _academicLoginSignal++);
            },
            onForumLoginCompleted: () {
              setState(() => _forumLoginSignal++);
            },
            onDemoLogin: _activateDemoMode,
            controller: _onboardingController,
            child: AppShell(
              repository: repository,
              key: ValueKey('app-shell-${demo ? 'demo' : 'normal'}'),
              reloadRepository: demo
                  ? () async => repository
                  : ForumRepositoryFactory.loadOnline,
              initialWebVpnEnabled: demo ? false : data.webVpnEnabled,
              selectedThemeId: theme.id,
              followSystemTheme: _followSystemTheme,
              onThemeChanged: _changeTheme,
              onFollowSystemThemeChanged: _changeFollowSystemTheme,
              academicLoginSignal: _academicLoginSignal,
              forumLoginSignal: _forumLoginSignal,
              initialHasAcademicSession: demo || data.hasAcademicSession,
              initialAcademicStudentId: demo
                  ? data.initialScheduleState?.schedule?.term.studentId
                  : data.academicStudentId,
              initialOpenSchedule: data.openScheduleFromWidget &&
                  (demo || data.onboardingCompleted),
              initialScheduleState: data.initialScheduleState,
              initialScheduleDisplayState: data.initialScheduleDisplayState,
              initialScheduleLoadError: data.initialScheduleLoadError,
              isDemo: demo,
              demoData: _demoData,
              onboardingController: _onboardingController,
              onExitDemo: demo ? _exitDemoMode : null,
            ),
          );
        },
      ),
    );
  }

  ShuYoThemeSpec get _effectiveTheme {
    final themeId = _followSystemTheme
        ? ShuYoThemes.systemThemeIdFor(_systemBrightness)
        : _manualThemeId;
    return ShuYoThemes.byId(themeId);
  }

  Future<_StartupData> _loadStartup() async {
    final openScheduleFromWidget = await _takeInitialScheduleWidgetLaunch();
    if (await DemoSession.isEnabled()) {
      return _loadDemoStartup(
        openScheduleFromWidget: openScheduleFromWidget,
      );
    }
    // This must run before any repository/auth service reads local state.  The
    // migration intentionally resets this major release to a fresh install.
    await _dataMigrationService.migrateIfNeeded();
    if (await DemoSession.isEnabled()) {
      return _loadDemoStartup(
        openScheduleFromWidget: openScheduleFromWidget,
      );
    }
    await ClientAppInfo.load();
    final networkSettings = await _settingsService.loadNetworkSettings();
    ForumUrlResolver.configure(
      useWebVpn: networkSettings.webVpnEnabled,
    );
    ClassroomUrlResolver.configure(
      useWebVpn: networkSettings.webVpnEnabled,
    );
    final repository = await ForumRepositoryFactory.loadLocal();
    final academicAccountStore = AcademicAccountStore();
    if (await academicAccountStore.hasLegacyExpiredAccount()) {
      await AcademicAuthService().clearAccount();
    }
    final academicStudentId = await academicAccountStore.loadStudentId();
    final onboardingCompleted =
        await _settingsService.loadStartupOnboardingCompleted();
    final initialScheduleLoad = openScheduleFromWidget && onboardingCompleted
        ? await _loadInitialScheduleState(AcademicScheduleRepository())
        : const _InitialScheduleLoad();
    return _StartupData(
      repository: repository,
      webVpnEnabled: networkSettings.webVpnEnabled,
      hasAcademicSession: academicStudentId != null,
      academicStudentId: academicStudentId,
      onboardingCompleted: onboardingCompleted,
      demoMode: false,
      openScheduleFromWidget: openScheduleFromWidget,
      initialScheduleState: initialScheduleLoad.state,
      initialScheduleDisplayState: initialScheduleLoad.displayState,
      initialScheduleLoadError: initialScheduleLoad.error,
    );
  }

  Future<_StartupData> _loadDemoStartup({
    bool openScheduleFromWidget = false,
  }) async {
    final demoData = await DemoDataBundle.load();
    final demoRepository = await DemoForumRepository.load();
    _demoMode = true;
    _demoData = demoData;
    _demoRepository = demoRepository;
    final initialScheduleLoad = openScheduleFromWidget
        ? await _loadInitialScheduleState(
            DemoAcademicScheduleRepository(demoData.schedule),
          )
        : const _InitialScheduleLoad();
    return _StartupData(
      repository: demoRepository,
      webVpnEnabled: false,
      hasAcademicSession: true,
      academicStudentId: initialScheduleLoad.state?.schedule?.term.studentId,
      onboardingCompleted: true,
      demoMode: true,
      openScheduleFromWidget: openScheduleFromWidget,
      initialScheduleState: initialScheduleLoad.state,
      initialScheduleDisplayState: initialScheduleLoad.displayState,
      initialScheduleLoadError: initialScheduleLoad.error,
    );
  }

  Future<_InitialScheduleLoad> _loadInitialScheduleState(
    AcademicScheduleRepository repository,
  ) async {
    try {
      final scheduleStateFuture = repository.loadCachedState();
      final displayStateFuture =
          AcademicScheduleDisplaySettingsService().loadState();
      return _InitialScheduleLoad(
        state: await scheduleStateFuture,
        displayState: await displayStateFuture,
      );
    } on Object catch (error) {
      return _InitialScheduleLoad(error: error.toString());
    }
  }

  Future<bool> _loadInitialScheduleWidgetLaunch() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      return uri?.scheme == 'shuyo' && uri?.host == 'schedule';
    } on Object {
      return false;
    }
  }

  Future<bool> _takeInitialScheduleWidgetLaunch() async {
    if (_initialWidgetLaunchConsumed) return false;
    _initialWidgetLaunchConsumed = true;
    return _initialScheduleWidgetLaunch;
  }

  Future<void> _activateDemoMode() async {
    final demoData = await DemoDataBundle.load();
    final demoRepository = await DemoForumRepository.load();
    if (!mounted) return;
    setState(() {
      _demoMode = true;
      _demoData = demoData;
      _demoRepository = demoRepository;
    });
  }

  Future<void> _exitDemoMode() async {
    await DemoSession.disable();
    await _settingsService.saveStartupOnboardingCompleted(false);
    if (!mounted) return;
    setState(() {
      _demoMode = false;
      _demoData = null;
      _demoRepository = null;
      // A demo-started app's original startup snapshot contains the demo
      // repository. Reload it after disabling demo so the normal chain gets a
      // real repository and fresh authentication state.
      _startupFuture = _loadStartup();
    });
  }

  Future<void> _loadTheme() async {
    // Theme preferences are part of the data reset.  Wait for startup (and
    // therefore the migration) before reading them, otherwise this parallel
    // task could briefly restore a legacy theme after an upgrade.
    try {
      await _startupFuture;
    } on Object {
      return;
    }
    final themeId = await _settingsService.loadThemeId();
    final followSystemTheme = await _settingsService.loadFollowSystemTheme();
    if (!mounted) {
      return;
    }
    setState(() {
      _manualThemeId = ShuYoThemes.byId(themeId).id;
      _followSystemTheme = followSystemTheme;
    });
  }

  Future<void> _changeTheme(String themeId) async {
    final theme = ShuYoThemes.byId(themeId);
    await _settingsService.saveThemeId(theme.id);
    await _settingsService.saveFollowSystemTheme(false);
    if (mounted) {
      setState(() {
        _manualThemeId = theme.id;
        _followSystemTheme = false;
      });
    }
  }

  Future<void> _changeFollowSystemTheme(bool enabled) async {
    if (enabled) {
      await _settingsService.saveFollowSystemTheme(true);
      if (mounted) {
        setState(() => _followSystemTheme = true);
      }
      return;
    }

    final currentThemeId = _effectiveTheme.id;
    await _settingsService.saveThemeId(currentThemeId);
    await _settingsService.saveFollowSystemTheme(false);
    if (mounted) {
      setState(() {
        _manualThemeId = currentThemeId;
        _followSystemTheme = false;
      });
    }
  }
}

ForumAccountStatus _forumAccountStatus(ForumRepository repository) {
  if (defaultTargetPlatform == TargetPlatform.iOS &&
      !ForumUrlResolver.usesWebVpn &&
      !repository.hasLocalAccount) {
    return ForumAccountStatus.directLoginUnavailable;
  }
  return switch (repository.connectionState) {
    ForumConnectionState.firstUse => ForumAccountStatus.signedOut,
    ForumConnectionState.cachedOffline =>
      ForumAccountStatus.connectionUnavailable,
    ForumConnectionState.reauthenticationRequired =>
      ForumAccountStatus.reauthenticationRequired,
    ForumConnectionState.online => ForumAccountStatus.loggedIn,
  };
}

class _StartupData {
  const _StartupData({
    required this.repository,
    required this.webVpnEnabled,
    required this.hasAcademicSession,
    required this.academicStudentId,
    required this.onboardingCompleted,
    required this.demoMode,
    required this.openScheduleFromWidget,
    this.initialScheduleState,
    this.initialScheduleDisplayState,
    this.initialScheduleLoadError,
  });

  final ForumRepository repository;
  final bool webVpnEnabled;
  final bool hasAcademicSession;
  final String? academicStudentId;
  final bool onboardingCompleted;
  final bool demoMode;
  final bool openScheduleFromWidget;
  final AcademicScheduleCacheState? initialScheduleState;
  final AcademicScheduleDisplayState? initialScheduleDisplayState;
  final String? initialScheduleLoadError;
}

class _InitialScheduleLoad {
  const _InitialScheduleLoad({
    this.state,
    this.displayState,
    this.error,
  });

  final AcademicScheduleCacheState? state;
  final AcademicScheduleDisplayState? displayState;
  final String? error;
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '启动失败',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: colors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
