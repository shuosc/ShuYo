import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';

import '../core/client_app_info.dart';
import '../core/app_tab.dart';
import '../core/classroom_url_resolver.dart';
import '../core/otp_url_resolver.dart';
import '../data/demo/demo_data_bundle.dart';
import '../data/demo/demo_repositories.dart';
import '../data/demo/demo_session.dart';
import '../data/models/classroom.dart';
import '../data/repositories/academic_schedule_repository.dart';
import '../data/services/academic_account_store.dart';
import '../data/services/academic_profile_preferences.dart';
import '../data/services/academic_auth_service.dart';
import '../data/services/academic_schedule_display_settings_service.dart';
import '../data/services/app_data_migration_service.dart';
import '../data/services/client_settings_service.dart';
import '../data/services/student_identity_service.dart';
import '../data/services/unified_account_service.dart';
import '../data/services/webvpn_session_store.dart';
import 'app_shell.dart';
import '../features/onboarding/startup_onboarding.dart';
import '../shared/theme/shuyo_theme.dart';
import '../shared/theme/custom_background.dart';
import '../shared/widgets/shuyo_launch_surface.dart';

class ShuYoApp extends StatefulWidget {
  const ShuYoApp({
    super.key,
    this.initialThemeId,
    this.initialFollowSystemTheme = false,
    this.initialCustomBackground,
  });

  final String? initialThemeId;
  final bool initialFollowSystemTheme;
  final CustomBackground? initialCustomBackground;

  @override
  State<ShuYoApp> createState() => _ShuYoAppState();
}

class _ShuYoAppState extends State<ShuYoApp> with WidgetsBindingObserver {
  final _settingsService = ClientSettingsService();
  final _studentIdentityService = StudentIdentityService();
  final _dataMigrationService = AppDataMigrationService();
  final _onboardingController = StartupOnboardingController();
  late Future<_StartupData> _startupFuture;
  String _manualThemeId = ShuYoThemes.defaultId;
  CustomBackground? _customBackground;
  bool _followSystemTheme = false;
  bool _demoMode = false;
  DemoDataBundle? _demoData;
  int _academicLoginSignal = 0;
  late final Future<bool> _initialScheduleWidgetLaunch;
  bool _initialWidgetLaunchConsumed = false;
  Brightness _systemBrightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    _customBackground = widget.initialCustomBackground;
    _manualThemeId = widget.initialThemeId == ShuYoThemes.customBackgroundId &&
            _customBackground != null
        ? ShuYoThemes.customBackgroundId
        : ShuYoThemes.byId(widget.initialThemeId).id;
    _followSystemTheme = widget.initialFollowSystemTheme;
    WidgetsBinding.instance.addObserver(this);
    _initialScheduleWidgetLaunch = _loadInitialScheduleWidgetLaunch();
    _startupFuture = _loadStartup();
    _loadTheme();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _studentIdentityService.dispose();
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
      builder: (context, child) {
        final background = theme.id == ShuYoThemes.customBackgroundId
            ? _customBackground
            : null;
        return CustomBackgroundFrame(
          settings: background,
          child: child ?? const SizedBox.shrink(),
        );
      },
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
          final demo = _demoMode && _demoData != null;
          return StartupOnboarding(
            initiallyCompleted: demo || data.onboardingCompleted,
            initialAcademicLoggedIn: demo || data.hasAcademicSession,
            initialAcademicSessionExpired: !demo && data.academicSessionExpired,
            onAcademicLoginCompleted: () {
              setState(() => _academicLoginSignal++);
            },
            onDemoLogin: _activateDemoMode,
            controller: _onboardingController,
            studentIdentityService: demo ? null : _studentIdentityService,
            child: AppShell(
              key: ValueKey('app-shell-${demo ? 'demo' : 'normal'}'),
              initialWebVpnEnabled: demo ? false : data.webVpnEnabled,
              initialWebVpnPendingRecovery:
                  demo ? false : data.webVpnPendingRecovery,
              initialWebVpnSessionReady: demo ? false : data.webVpnSessionReady,
              selectedThemeId: theme.id,
              followSystemTheme: _followSystemTheme,
              customBackground: _customBackground,
              onThemeChanged: _changeTheme,
              onFollowSystemThemeChanged: _changeFollowSystemTheme,
              onCustomBackgroundChanged: _changeCustomBackground,
              academicLoginSignal: _academicLoginSignal,
              initialHasAcademicSession: demo || data.hasAcademicSession,
              initialAcademicSessionExpired:
                  !demo && data.academicSessionExpired,
              initialAcademicStudentId: demo
                  ? data.initialScheduleState?.schedule?.term.studentId
                  : data.academicStudentId,
              initialNickname: demo ? null : data.nickname,
              initialPreferredCampus: data.preferredCampus,
              initialStartupTab: data.startupTab,
              initialOpenSchedule: data.openScheduleFromWidget &&
                  (demo || data.onboardingCompleted),
              initialScheduleState: data.initialScheduleState,
              initialScheduleDisplayState: data.initialScheduleDisplayState,
              initialScheduleLoadError: data.initialScheduleLoadError,
              isDemo: demo,
              demoData: _demoData,
              onboardingController: _onboardingController,
              studentIdentityService: demo ? null : _studentIdentityService,
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
    if (themeId == ShuYoThemes.customBackgroundId &&
        _customBackground != null) {
      return _customBackground!.theme;
    }
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
    final startupTab = await _settingsService.loadStartupTab();
    ClassroomUrlResolver.configure(
      useWebVpn: networkSettings.webVpnEnabled,
    );
    OtpUrlResolver.configure(useWebVpn: networkSettings.webVpnEnabled);
    final academicAccountStore = AcademicAccountStore();
    await academicAccountStore.rememberExistingAccounts();
    if (await academicAccountStore.hasLegacyExpiredAccount()) {
      await AcademicAuthService().clearAccount();
    }
    final academicStudentId = await academicAccountStore.loadStudentId();
    final profilePreferences = AcademicProfilePreferences();
    final nickname = academicStudentId == null
        ? null
        : await profilePreferences.loadNickname(academicStudentId);
    final preferredCampus = await profilePreferences.loadPreferredCampus();
    final onboardingCompleted =
        await _settingsService.loadStartupOnboardingCompleted();
    final initialScheduleLoad = openScheduleFromWidget && onboardingCompleted
        ? await _loadInitialScheduleState(AcademicScheduleRepository())
        : const _InitialScheduleLoad();
    return _StartupData(
      webVpnEnabled: networkSettings.webVpnEnabled,
      webVpnPendingRecovery:
          await UnifiedAccountService().isWebVpnPendingRecovery(),
      webVpnSessionReady: await _hasStoredWebVpnSession(),
      hasAcademicSession: academicStudentId != null,
      academicSessionExpired: await academicAccountStore.isSessionExpired(),
      academicStudentId: academicStudentId,
      nickname: nickname,
      preferredCampus: preferredCampus,
      startupTab: startupTab,
      onboardingCompleted: onboardingCompleted,
      demoMode: false,
      openScheduleFromWidget: openScheduleFromWidget,
      initialScheduleState: initialScheduleLoad.state,
      initialScheduleDisplayState: initialScheduleLoad.displayState,
      initialScheduleLoadError: initialScheduleLoad.error,
    );
  }

  Future<bool> _hasStoredWebVpnSession() async {
    try {
      return await WebVpnSessionStore().hasStoredSession();
    } on Object {
      return false;
    }
  }

  Future<_StartupData> _loadDemoStartup({
    bool openScheduleFromWidget = false,
  }) async {
    final demoData = await DemoDataBundle.load();
    _demoMode = true;
    _demoData = demoData;
    final initialScheduleLoad = openScheduleFromWidget
        ? await _loadInitialScheduleState(
            DemoAcademicScheduleRepository(demoData.schedule),
          )
        : const _InitialScheduleLoad();
    return _StartupData(
      webVpnEnabled: false,
      hasAcademicSession: true,
      academicStudentId: initialScheduleLoad.state?.schedule?.term.studentId,
      startupTab: await _settingsService.loadStartupTab(),
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
    if (!mounted) return;
    setState(() {
      _demoMode = true;
      _demoData = demoData;
    });
  }

  Future<void> _exitDemoMode() async {
    await DemoSession.disable();
    await _settingsService.saveStartupOnboardingCompleted(false);
    if (!mounted) return;
    setState(() {
      _demoMode = false;
      _demoData = null;
      // Reload the normal startup state after leaving the bundled demo.
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
    final customBackground = await _settingsService.loadCustomBackground();
    if (!mounted) {
      return;
    }
    setState(() {
      _customBackground = customBackground;
      _manualThemeId =
          themeId == ShuYoThemes.customBackgroundId && customBackground != null
              ? ShuYoThemes.customBackgroundId
              : ShuYoThemes.byId(themeId).id;
      _followSystemTheme = followSystemTheme;
    });
  }

  Future<void> _changeTheme(String themeId) async {
    final selectedId =
        themeId == ShuYoThemes.customBackgroundId && _customBackground != null
            ? themeId
            : ShuYoThemes.byId(themeId).id;
    await _settingsService.saveThemeId(selectedId);
    await _settingsService.saveFollowSystemTheme(false);
    if (mounted) {
      setState(() {
        _manualThemeId = selectedId;
        _followSystemTheme = false;
      });
    }
  }

  Future<void> _changeCustomBackground(CustomBackground settings) async {
    await _settingsService.saveThemeId(ShuYoThemes.customBackgroundId);
    await _settingsService.saveFollowSystemTheme(false);
    await _settingsService.saveCustomBackground(settings);
    if (mounted) {
      setState(() {
        _customBackground = settings;
        _manualThemeId = ShuYoThemes.customBackgroundId;
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

class _StartupData {
  const _StartupData({
    required this.webVpnEnabled,
    this.webVpnPendingRecovery = false,
    this.webVpnSessionReady = false,
    required this.hasAcademicSession,
    this.academicSessionExpired = false,
    required this.academicStudentId,
    this.nickname,
    this.preferredCampus = ClassroomCampus.defaultName,
    this.startupTab = AppTab.home,
    required this.onboardingCompleted,
    required this.demoMode,
    required this.openScheduleFromWidget,
    this.initialScheduleState,
    this.initialScheduleDisplayState,
    this.initialScheduleLoadError,
  });

  final bool webVpnEnabled;
  final bool webVpnPendingRecovery;
  final bool webVpnSessionReady;
  final bool hasAcademicSession;
  final bool academicSessionExpired;
  final String? academicStudentId;
  final String? nickname;
  final String preferredCampus;
  final AppTab startupTab;
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
