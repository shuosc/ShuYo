import 'dart:io';
import 'dart:ui' as ui;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/client_app_info.dart';
import '../../core/app_tab.dart';
import '../../core/client_update_policy.dart';
import '../../data/models/announcement_source.dart';
import '../../data/repositories/client_backend_repository.dart';
import '../../data/services/academic_schedule_notification_service.dart';
import '../../data/services/app_store_version_service.dart';
import '../../data/services/client_settings_service.dart';
import '../../data/services/student_identity_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/widgets/client_update_prompt.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/webvpn_toggle.dart';
import 'client_feedback_page.dart';
import 'privacy_data_page.dart';
import '../onboarding/startup_onboarding.dart';

class ClientSettingsPage extends StatelessWidget {
  const ClientSettingsPage({
    super.key,
    required this.settingsService,
    required this.scheduleNotificationService,
    required this.backendRepository,
    required this.selectedThemeId,
    required this.followSystemTheme,
    required this.onThemeChanged,
    required this.onFollowSystemThemeChanged,
    this.customBackground,
    this.onCustomBackgroundChanged,
    required this.selectedStartupTab,
    required this.onStartupTabChanged,
    required this.webVpnController,
    this.hasAcademicAccount = false,
    this.hasWebVpnSession = false,
    this.onAcademicLogout,
    this.studentIdentityService,
    this.isDemo = false,
    this.onExitDemo,
  });

  final ClientSettingsService settingsService;
  final AcademicScheduleNotificationService scheduleNotificationService;
  final ClientBackendRepository backendRepository;
  final String selectedThemeId;
  final bool followSystemTheme;
  final Future<void> Function(String themeId) onThemeChanged;
  final Future<void> Function(bool enabled) onFollowSystemThemeChanged;
  final CustomBackground? customBackground;
  final Future<void> Function(CustomBackground)? onCustomBackgroundChanged;
  final AppTab selectedStartupTab;
  final Future<void> Function(AppTab tab) onStartupTabChanged;
  final StartupOnboardingController webVpnController;
  final bool hasAcademicAccount;
  final bool hasWebVpnSession;
  final Future<bool> Function()? onAcademicLogout;
  final StudentIdentityService? studentIdentityService;
  final bool isDemo;
  final Future<void> Function()? onExitDemo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _SettingsRow(
            title: '主题切换',
            onTap: () => Navigator.of(context).push<void>(
              shuyoRoute(
                builder: (context) => _ThemeSettingsPage(
                  selectedThemeId: selectedThemeId,
                  followSystemTheme: followSystemTheme,
                  onThemeChanged: onThemeChanged,
                  onFollowSystemThemeChanged: onFollowSystemThemeChanged,
                  customBackground: customBackground,
                  onCustomBackgroundChanged: onCustomBackgroundChanged,
                ),
              ),
            ),
          ),
          if (!isDemo)
            _SettingsRow(
              title: '默认公告',
              onTap: () => Navigator.of(context).push<void>(
                shuyoRoute(
                  builder: (context) => _DefaultAnnouncementPage(
                    settingsService: settingsService,
                  ),
                ),
              ),
            ),
          _SettingsRow(
            title: '启动显示',
            onTap: () => Navigator.of(context).push<void>(
              shuyoRoute(
                builder: (context) => _StartupDisplayPage(
                  selectedTab: selectedStartupTab,
                  onChanged: onStartupTabChanged,
                ),
              ),
            ),
          ),
          _SettingsRow(
            title: 'WebVPN连接',
            onTap: () => Navigator.of(context).push<void>(
              shuyoRoute(
                builder: (context) => _WebVpnSettingsPage(
                  controller: webVpnController,
                  isDemo: isDemo,
                ),
              ),
            ),
          ),
          if (!isDemo && studentIdentityService != null)
            _SettingsRow(
              title: '隐私与数据',
              onTap: () => Navigator.of(context).push<void>(
                shuyoRoute(
                  builder: (_) => PrivacyDataPage(
                    identityService: studentIdentityService!,
                  ),
                ),
              ),
            ),
          _SettingsRow(
            title: '关于ShuYo',
            onTap: () => Navigator.of(context).push<void>(
              shuyoRoute(
                builder: (context) => _AboutClientPage(
                  backendRepository: backendRepository,
                  isDemo: isDemo,
                ),
              ),
            ),
          ),
          if (isDemo && onExitDemo != null)
            _SettingsRow(
              title: '退出演示',
              onTap: () => _exitDemo(context),
            ),
          if (!isDemo && (hasAcademicAccount || hasWebVpnSession))
            _AccountLogoutRow(
              hasAcademicAccount: hasAcademicAccount,
              hasWebVpnSession: hasWebVpnSession,
              onAcademicLogout: onAcademicLogout,
            ),
        ],
      ),
    );
  }

  Future<void> _exitDemo(BuildContext context) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('退出演示模式？'),
            content: const Text('退出后将返回正常登录流程，并清除本地演示数据。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('退出演示'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) {
      await onExitDemo?.call();
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

class _DefaultAnnouncementPage extends StatefulWidget {
  const _DefaultAnnouncementPage({required this.settingsService});

  final ClientSettingsService settingsService;

  @override
  State<_DefaultAnnouncementPage> createState() =>
      _DefaultAnnouncementPageState();
}

class _DefaultAnnouncementPageState extends State<_DefaultAnnouncementPage> {
  late final Future<AnnouncementSource> _initialSource =
      widget.settingsService.loadDefaultAnnouncementSource();
  AnnouncementSource? _selected;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('默认公告')),
      body: FutureBuilder<AnnouncementSource>(
        future: _initialSource,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('默认公告设置加载失败'));
          }
          final selected = _selected ?? snapshot.data!;
          return ListView(
            children: [
              for (final group in AnnouncementSourceGroup.values) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    group == AnnouncementSourceGroup.campus
                        ? '校级与公共服务'
                        : '学院与培养单位',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final source in AnnouncementSource.inGroup(group))
                  ListTile(
                    title: Text(source.name),
                    onTap: _saving ? null : () => _save(source),
                    trailing: Icon(
                      source == selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: source == selected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _save(AnnouncementSource source) async {
    if (_selected == source) return;
    setState(() => _saving = true);
    try {
      await widget.settingsService.saveDefaultAnnouncementSource(source);
      if (mounted) setState(() => _selected = source);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('默认公告保存失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _StartupDisplayPage extends StatefulWidget {
  const _StartupDisplayPage({
    required this.selectedTab,
    required this.onChanged,
  });

  final AppTab selectedTab;
  final Future<void> Function(AppTab tab) onChanged;

  @override
  State<_StartupDisplayPage> createState() => _StartupDisplayPageState();
}

class _StartupDisplayPageState extends State<_StartupDisplayPage> {
  late AppTab _selectedTab = widget.selectedTab;
  AppTab? _savingTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('启动显示')),
      body: ListView(
        children: [
          for (final tab in AppTab.values)
            ListTile(
              title: Text(tab.label),
              trailing: _savingTab == tab
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : tab == _selectedTab
                      ? const Icon(Icons.check)
                      : null,
              onTap: _savingTab == null && tab != _selectedTab
                  ? () => _selectTab(tab)
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _selectTab(AppTab tab) async {
    setState(() => _savingTab = tab);
    try {
      await widget.onChanged(tab);
      if (mounted) setState(() => _selectedTab = tab);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('启动显示保存失败，请重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingTab = null);
    }
  }
}

class _WebVpnSettingsPage extends StatefulWidget {
  const _WebVpnSettingsPage({
    required this.controller,
    required this.isDemo,
  });

  final StartupOnboardingController controller;
  final bool isDemo;

  @override
  State<_WebVpnSettingsPage> createState() => _WebVpnSettingsPageState();
}

class _WebVpnSettingsPageState extends State<_WebVpnSettingsPage> {
  bool _changing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebVPN连接')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final enabled = widget.controller.webVpnEnabled;
          final pendingRecovery = widget.controller.webVpnPendingRecovery;
          return ListView(
            children: [
              InkWell(
                onTap: widget.isDemo || _changing
                    ? null
                    : () => _changeWebVpn(!enabled),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('WebVPN'),
                              const SizedBox(height: 4),
                              Text(
                                widget.isDemo
                                    ? '演示模式下不可修改'
                                    : '启用后，可使用外部网络访问校内服务',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      WebVpnToggle(
                        value: enabled,
                        changing: _changing,
                        onChanged: widget.isDemo
                            ? null
                            : (value) => _changeWebVpn(value),
                      ),
                    ],
                  ),
                ),
              ),
              if (pendingRecovery && !widget.isDemo)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _changing ? null : () => _changeWebVpn(true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('恢复WebVPN登录'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _changeWebVpn(bool enabled) async {
    if (_changing) return;
    setState(() => _changing = true);
    await widget.controller.setWebVpnEnabled(enabled);
    if (mounted) setState(() => _changing = false);
  }
}

class _AccountLogoutRow extends StatefulWidget {
  const _AccountLogoutRow({
    required this.hasAcademicAccount,
    required this.hasWebVpnSession,
    required this.onAcademicLogout,
  });

  final bool hasAcademicAccount;
  final bool hasWebVpnSession;
  final Future<bool> Function()? onAcademicLogout;

  @override
  State<_AccountLogoutRow> createState() => _AccountLogoutRowState();
}

class _AccountLogoutRowState extends State<_AccountLogoutRow> {
  late bool _hasAcademicAccount;
  late bool _hasWebVpnSession;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _hasAcademicAccount = widget.hasAcademicAccount;
    _hasWebVpnSession = widget.hasWebVpnSession;
  }

  @override
  void didUpdateWidget(covariant _AccountLogoutRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasAcademicAccount != widget.hasAcademicAccount) {
      _hasAcademicAccount = widget.hasAcademicAccount;
    }
    if (oldWidget.hasWebVpnSession != widget.hasWebVpnSession) {
      _hasWebVpnSession = widget.hasWebVpnSession;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final enabled = !_loggingOut &&
        (_hasAcademicAccount || _hasWebVpnSession) &&
        widget.onAcademicLogout != null;
    return ListTile(
      title: Text('退出登录', style: TextStyle(color: colors.danger)),
      subtitle: _loggingOut ? const Text('正在退出...') : null,
      trailing: _loggingOut
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : const Icon(Icons.chevron_right),
      onTap: enabled ? _confirmAndLogout : null,
    );
  }

  Future<void> _confirmAndLogout() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认退出'),
            content: const Text('退出后将需要重新登录，仍可查看已保存的课表和学业信息'),
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
    if (!confirmed || !mounted) return;

    setState(() => _loggingOut = true);
    final loggedOut = await widget.onAcademicLogout?.call() ?? false;
    if (!mounted) return;
    setState(() {
      _loggingOut = false;
      if (loggedOut) {
        _hasAcademicAccount = false;
        _hasWebVpnSession = false;
      }
    });
    if (loggedOut) {
      _showSnack(context, '已退出上大校园账户');
    }
  }
}

class _AboutClientPage extends StatefulWidget {
  const _AboutClientPage({
    required this.backendRepository,
    required this.isDemo,
  });

  final ClientBackendRepository backendRepository;
  final bool isDemo;

  @override
  State<_AboutClientPage> createState() => _AboutClientPageState();
}

class _AboutClientPageState extends State<_AboutClientPage> {
  static const _sourceUrl = 'https://github.com/shuosc/ShuYo';
  static const _licenseUrl =
      'https://github.com/shuosc/ShuYo/blob/main/LICENSE';
  static const _contributorsUrl =
      'https://github.com/shuosc/ShuYo/graphs/contributors';
  static const _termsUrl = 'https://shuyo.work/doc/terms.html';
  static const _privacyUrl = 'https://shuyo.work/doc/privacy.html';

  bool _checkingUpdate = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('关于ShuYo')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.16),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/images/icon_light.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  ClientAppInfo.appName,
                  style: ShuYoTextStyles.title(
                    color: colors.textPrimary,
                    size: 22,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '版本 ${ClientAppInfo.version}（${ClientAppInfo.buildNumber}）',
                  style: ShuYoTextStyles.meta(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(),
          ),
          const _AboutGroupTitle('项目信息'),
          _AboutRow(
            icon: Icons.code,
            title: '源代码',
            subtitle: 'GitHub · shuosc/ShuYo',
            onTap: () => _openExternalUrl(_sourceUrl),
          ),
          _AboutRow(
            icon: Icons.balance_outlined,
            title: '开源许可',
            subtitle: 'GNU General Public License v3.0',
            onTap: () => _openExternalUrl(_licenseUrl),
          ),
          _AboutRow(
            icon: Icons.inventory_2_outlined,
            title: '第三方开源许可',
            onTap: _showThirdPartyLicenses,
          ),
          _AboutRow(
            icon: Icons.groups_outlined,
            title: '贡献者',
            subtitle: '查看 GitHub Contributors',
            onTap: () => _openExternalUrl(_contributorsUrl),
          ),
          const SizedBox(height: 18),
          const _AboutGroupTitle('隐私与声明'),
          _AboutRow(
            icon: Icons.security_outlined,
            title: '权限说明',
            onTap: () => Navigator.of(context).push<void>(
              shuyoRoute(builder: (context) => const _PermissionInfoPage()),
            ),
          ),
          _AboutRow(
            icon: Icons.description_outlined,
            title: '使用条款',
            onTap: () => _openExternalUrl(_termsUrl),
          ),
          _AboutRow(
            icon: Icons.privacy_tip_outlined,
            title: '隐私政策',
            onTap: () => _openExternalUrl(_privacyUrl),
          ),
          if (!widget.isDemo) ...[
            const SizedBox(height: 18),
            const _AboutGroupTitle('支持'),
            _AboutRow(
              icon: Icons.feedback_outlined,
              title: '问题与反馈',
              onTap: () => Navigator.of(context).push<void>(
                shuyoRoute(
                  builder: (context) => ClientFeedbackPage(
                    repository: widget.backendRepository,
                  ),
                ),
              ),
            ),
            _AboutRow(
              icon: Icons.system_update_outlined,
              title: '检查更新',
              trailing: _checkingUpdate
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : null,
              onTap: _checkingUpdate ? null : _checkForUpdate,
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(),
          ),
          Text(
            '本应用是由学生开发的非官方开源工具，与上海大学、上海大学信息办无关，不属于官方软件。\n\n本应用仅作信息聚合展示。如果在客户端使用过程中出现问题，或是你希望有些新的功能，请通过“问题与反馈”联系开发者。\n～(∠・ω< )⌒☆',
            style: ShuYoTextStyles.bodyCompact(
              color: colors.textMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) _showSnack(context, '无法打开链接');
    } on Object {
      if (mounted) _showSnack(context, '无法打开链接');
    }
  }

  void _showThirdPartyLicenses() {
    showLicensePage(
      context: context,
      applicationName: ClientAppInfo.appName,
      applicationVersion:
          '${ClientAppInfo.version}（${ClientAppInfo.buildNumber}）',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset(
          'assets/images/icon_light.png',
          width: 48,
          height: 48,
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      if (ClientUpdatePolicy.source == ClientUpdateSource.appStore) {
        await _checkAppStoreForUpdate();
        return;
      }
      final update = await widget.backendRepository.checkForUpdate(
        forceRefresh: true,
      );
      if (!mounted) return;
      if (update == null) {
        _showSnack(context, '已是最新版本');
        return;
      }
      final openDownload = await showClientUpdatePrompt(
        context,
        update: update,
      );
      if (!mounted || !openDownload || !update.hasDownloadUrl) return;
      await _openDownload(update.downloadUrl);
    } on AppStoreVersionUnavailableException catch (error) {
      if (mounted) _showSnack(context, error.message);
    } on Object catch (error) {
      if (mounted) _showSnack(context, '检查更新失败：$error');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _checkAppStoreForUpdate() async {
    final update = await AppStoreVersionService().checkForUpdate();
    if (!mounted) return;
    if (update == null) {
      _showSnack(context, '已是最新版本');
      return;
    }
    final openAppStore = await showAppStoreUpdatePrompt(
      context,
      update: update,
    );
    if (!mounted || !openAppStore) return;
    await _openDownload(update.productUrl);
  }

  Future<void> _openDownload(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      _showSnack(context, '下载链接无效');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) _showSnack(context, '无法打开下载链接');
  }
}

class _AboutGroupTitle extends StatelessWidget {
  const _AboutGroupTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Text(
        title,
        style: ShuYoTextStyles.sectionTitle(
          color: context.shuyoColors.textPrimary,
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _PermissionInfoPage extends StatelessWidget {
  const _PermissionInfoPage();

  @override
  Widget build(BuildContext context) {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    return Scaffold(
      appBar: AppBar(title: const Text('权限说明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            '为了实现对应功能，ShuYo 可能会在你使用功能时申请以下权限。具体项目会因系统版本而异。',
            style: ShuYoTextStyles.bodyCompact(
              color: context.shuyoColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          const _PermissionItem(
            icon: Icons.language,
            title: '网络访问',
            body: '用于访问校园服务、检查更新与提交反馈。',
          ),
          const _PermissionItem(
            icon: Icons.notifications_outlined,
            title: '通知',
            body: '用于发送上课提醒等你主动开启的通知。',
          ),
          _PermissionItem(
            icon: Icons.alarm_outlined,
            title: isIOS ? '闹钟' : '精确闹钟',
            body: isIOS ? '用于在支持 AlarmKit 的系统上为早课设置闹钟。' : '用于在设定时间准时触发课程提醒。',
          ),
          _PermissionItem(
            icon: Icons.photo_library_outlined,
            title: '照片与图片',
            body: isIOS
                ? '选图使用系统选择器，不需要读取整个相册；仅在保存图片时请求写入权限。'
                : '新版 Android 选图使用系统选择器；Android 9 及以下保存图片时可能需要存储权限。',
          ),
          if (!isIOS)
            const _PermissionItem(
              icon: Icons.restart_alt,
              title: '开机后恢复提醒',
              body: '用于设备重启后恢复已设置的课程提醒。',
            ),
          const SizedBox(height: 8),
          Text(
            '你可以在系统设置中随时查看或更改已授予的权限。拒绝某项权限只会影响对应功能。',
            style: ShuYoTextStyles.meta(
              color: context.shuyoColors.textMuted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionItem extends StatelessWidget {
  const _PermissionItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(body),
      ),
    );
  }
}

class _ThemeSettingsPage extends StatefulWidget {
  const _ThemeSettingsPage({
    required this.selectedThemeId,
    required this.followSystemTheme,
    required this.onThemeChanged,
    required this.onFollowSystemThemeChanged,
    this.customBackground,
    this.onCustomBackgroundChanged,
  });

  final String selectedThemeId;
  final bool followSystemTheme;
  final Future<void> Function(String themeId) onThemeChanged;
  final Future<void> Function(bool enabled) onFollowSystemThemeChanged;
  final CustomBackground? customBackground;
  final Future<void> Function(CustomBackground)? onCustomBackgroundChanged;

  @override
  State<_ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<_ThemeSettingsPage> {
  late String _selectedThemeId;
  late bool _followSystemTheme;
  String? _savingThemeId;
  bool _savingFollowSystemTheme = false;
  bool _savingCustom = false;
  CustomBackground? _customBackground;
  double? _opacityDraft;

  @override
  void initState() {
    super.initState();
    _selectedThemeId = widget.selectedThemeId;
    _followSystemTheme = widget.followSystemTheme;
    _customBackground = widget.customBackground;
  }

  @override
  void didUpdateWidget(covariant _ThemeSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedThemeId != oldWidget.selectedThemeId &&
        _savingThemeId == null) {
      _selectedThemeId = widget.selectedThemeId;
    }
    if (widget.followSystemTheme != oldWidget.followSystemTheme &&
        !_savingFollowSystemTheme) {
      _followSystemTheme = widget.followSystemTheme;
    }
    if (widget.customBackground != oldWidget.customBackground &&
        !_savingCustom) {
      _customBackground = widget.customBackground;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final page = Scaffold(
      appBar: AppBar(title: const Text('主题切换')),
      body: ListView.builder(
        itemCount: ShuYoThemes.all.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _SettingsSwitchRow(
              title: '跟随系统',
              value: _followSystemTheme,
              enabled: _savingThemeId == null &&
                  !_savingFollowSystemTheme &&
                  !_savingCustom,
              onChanged: _toggleFollowSystemTheme,
            );
          }
          if (index == ShuYoThemes.all.length + 1) {
            return _buildCustomBackgroundRow(context);
          }
          final theme = ShuYoThemes.all[index - 1];
          final selected = theme.id == _selectedThemeId;
          return ListTile(
            selected: selected,
            selectedColor: colors.textPrimary,
            title: Text(
              theme.name,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            trailing: _ThemeSwatches(
              theme: theme,
              selected: selected,
              saving: _savingThemeId == theme.id,
            ),
            onTap: _savingThemeId == null && !_savingCustom
                ? () => _selectTheme(theme)
                : null,
          );
        },
      ),
    );
    final preview = _opacityDraft != null &&
            !_followSystemTheme &&
            _selectedThemeId == ShuYoThemes.customBackgroundId &&
            _customBackground != null
        ? _customBackground!.copyWith(opacity: _opacityDraft!.round())
        : null;
    return CustomBackgroundLayer(settings: preview, child: page);
  }

  Widget _buildCustomBackgroundRow(BuildContext context) {
    final selected = !_followSystemTheme &&
        _selectedThemeId == ShuYoThemes.customBackgroundId;
    final settings = _customBackground;
    final colors = context.shuyoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          selected: selected,
          selectedColor: colors.textPrimary,
          title: Text('自定义主题',
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              )),
          trailing: settings == null
              ? Icon(Icons.palette_outlined, color: colors.textSecondary)
              : _ThemeSwatches(
                  theme: settings.theme,
                  selected: selected,
                  saving: _savingCustom,
                ),
          onTap: _savingCustom ||
                  _savingFollowSystemTheme ||
                  _savingThemeId != null
              ? null
              : _selectCustomBackground,
        ),
        if (selected && settings != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _savingCustom ? null : _replacePhoto,
                      icon: const Icon(Icons.photo_outlined, size: 18),
                      label: Text(settings.hasPhoto ? '更换照片' : '选择照片'),
                    ),
                    const Spacer(),
                    if (settings.hasPhoto)
                      TextButton(
                        onPressed: _savingCustom ? null : _clearPhoto,
                        child: const Text('清除'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('不透明度'),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    showValueIndicator: ShowValueIndicator.onDrag,
                    disabledActiveTrackColor: Colors.grey.shade600,
                    disabledInactiveTrackColor: Colors.grey.shade400,
                    disabledThumbColor: Colors.grey.shade600,
                  ),
                  child: Slider(
                    value: _opacityDraft ?? settings.opacity.toDouble(),
                    min: 0,
                    max: 100,
                    label: '${(_opacityDraft ?? settings.opacity).round()}%',
                    semanticFormatterCallback: (value) => '${value.round()}%',
                    onChanged: _savingCustom || !settings.hasPhoto
                        ? null
                        : (value) => setState(() => _opacityDraft = value),
                    onChangeEnd: _savingCustom || !settings.hasPhoto
                        ? null
                        : (value) {
                            setState(() => _opacityDraft = null);
                            _saveCustom(
                              settings.copyWith(opacity: value.round()),
                            );
                          },
                  ),
                ),
                const SizedBox(height: 16),
                const Text('颜色'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 10,
                  children: [
                    _editableColor('背景', settings.background,
                        (color) => settings.withBackgroundColor(color)),
                    _editableColor('文字', settings.text,
                        (color) => settings.copyWith(text: color)),
                    _editableColor('主题', settings.accent,
                        (color) => settings.copyWith(accent: color)),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _editableColor(
    String label,
    Color color,
    CustomBackground Function(Color) update,
  ) {
    return InkWell(
      onTap: _savingCustom
          ? null
          : () async {
              final next = await showDialog<Color>(
                context: context,
                builder: (_) => _ThemeColorDialog(label: label, initial: color),
              );
              if (next == null || !mounted) return;
              final settings = update(next);
              await _saveCustom(settings);
            },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: context.shuyoColors.borderStrong),
              ),
              child: const SizedBox.square(dimension: 32),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<void> _selectCustomBackground() async {
    if (_customBackground == null) {
      final callback = widget.onCustomBackgroundChanged;
      if (callback == null) return;
      final previousId = _selectedThemeId;
      final previousFollowSystem = _followSystemTheme;
      final settings = CustomBackground.withoutPhoto(context.shuyoColors);
      setState(() {
        _customBackground = settings;
        _selectedThemeId = ShuYoThemes.customBackgroundId;
        _followSystemTheme = false;
        _savingCustom = true;
      });
      try {
        await callback(settings);
      } on Object catch (error) {
        if (!mounted) return;
        _showSnack(context, '主题保存失败：$error');
        setState(() {
          _customBackground = null;
          _selectedThemeId = previousId;
          _followSystemTheme = previousFollowSystem;
        });
      } finally {
        if (mounted) setState(() => _savingCustom = false);
      }
      return;
    }
    if (!_followSystemTheme &&
        _selectedThemeId == ShuYoThemes.customBackgroundId) {
      return;
    }
    setState(() {
      _selectedThemeId = ShuYoThemes.customBackgroundId;
      _followSystemTheme = false;
      _savingCustom = true;
    });
    try {
      await widget.onThemeChanged(ShuYoThemes.customBackgroundId);
    } on Object catch (error) {
      if (!mounted) return;
      _showSnack(context, '主题保存失败：$error');
      setState(() {
        _selectedThemeId = widget.selectedThemeId;
        _followSystemTheme = widget.followSystemTheme;
      });
    } finally {
      if (mounted) {
        setState(() => _savingCustom = false);
      }
    }
  }

  Future<void> _replacePhoto() async {
    if (_savingCustom || widget.onCustomBackgroundChanged == null) return;
    setState(() => _savingCustom = true);
    File? newFile;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (picked == null || !mounted) return;
      final codec = await ui.instantiateImageCodec(await picked.readAsBytes());
      late Uint8List bytes;
      ui.FrameInfo? frame;
      try {
        frame = await codec.getNextFrame();
        final pngData =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (pngData == null) throw StateError('无法读取照片');
        bytes = pngData.buffer.asUint8List();
      } finally {
        frame?.image.dispose();
        codec.dispose();
      }
      if (!mounted) return;
      final cropped = await Navigator.of(context).push<Uint8List>(
        shuyoRoute(builder: (_) => _BackgroundCropPage(image: bytes)),
      );
      if (cropped == null || !mounted) return;
      final directory = await getApplicationSupportDirectory();
      newFile = File(
        '${directory.path}/custom_background_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await newFile.writeAsBytes(cropped, flush: true);
      final settings = await CustomBackground.fromImage(
        imagePath: newFile.path,
        provider: MemoryImage(cropped),
      );
      await widget.onCustomBackgroundChanged!(settings);
      final oldPath = _customBackground?.imagePath;
      if (!mounted) return;
      setState(() {
        _customBackground = settings;
        _selectedThemeId = ShuYoThemes.customBackgroundId;
        _followSystemTheme = false;
      });
      if (oldPath != null && oldPath.isNotEmpty && oldPath != newFile.path) {
        await _deleteStoredPhoto(oldPath);
      }
    } on Object catch (error) {
      if (newFile != null) {
        try {
          await newFile.delete();
        } on FileSystemException {
          // Keep the original error visible.
        }
      }
      if (mounted) _showSnack(context, '照片设置失败：$error');
    } finally {
      if (mounted) setState(() => _savingCustom = false);
    }
  }

  Future<void> _clearPhoto() async {
    final previous = _customBackground;
    final callback = widget.onCustomBackgroundChanged;
    if (_savingCustom ||
        previous == null ||
        !previous.hasPhoto ||
        callback == null) {
      return;
    }
    final cleared = previous.copyWith(imagePath: '', opacity: 0);
    setState(() {
      _customBackground = cleared;
      _savingCustom = true;
    });
    try {
      await callback(cleared);
      await _deleteStoredPhoto(previous.imagePath);
    } on Object catch (error) {
      if (!mounted) return;
      _showSnack(context, '照片清除失败：$error');
      setState(() => _customBackground = previous);
    } finally {
      if (mounted) setState(() => _savingCustom = false);
    }
  }

  Future<void> _deleteStoredPhoto(String path) async {
    final file = File(path);
    if (!file.uri.pathSegments.last.startsWith('custom_background_')) {
      return;
    }
    try {
      final directory = await getApplicationSupportDirectory();
      if (file.parent.path != directory.path) return;
      await file.delete();
    } on Object {
      // Theme changes are already saved; an orphaned cache file is harmless.
    }
  }

  Future<void> _saveCustom(CustomBackground settings) async {
    if (_savingCustom || widget.onCustomBackgroundChanged == null) return;
    final previous = _customBackground;
    setState(() {
      _customBackground = settings;
      _savingCustom = true;
    });
    try {
      await widget.onCustomBackgroundChanged!(settings);
    } on Object catch (error) {
      if (!mounted) return;
      _showSnack(context, '主题保存失败：$error');
      setState(() => _customBackground = previous);
    } finally {
      if (mounted) setState(() => _savingCustom = false);
    }
  }

  Future<void> _selectTheme(ShuYoThemeSpec theme) async {
    if ((!_followSystemTheme && _selectedThemeId == theme.id) ||
        _savingThemeId != null ||
        _savingFollowSystemTheme ||
        _savingCustom) {
      return;
    }
    setState(() {
      _selectedThemeId = theme.id;
      _followSystemTheme = false;
      _savingThemeId = theme.id;
    });
    try {
      await widget.onThemeChanged(theme.id);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack(context, '主题保存失败：$error');
      setState(() {
        _selectedThemeId = widget.selectedThemeId;
        _followSystemTheme = widget.followSystemTheme;
      });
    } finally {
      if (mounted) {
        setState(() => _savingThemeId = null);
      }
    }
  }

  Future<void> _toggleFollowSystemTheme(bool enabled) async {
    if (_savingFollowSystemTheme || _savingThemeId != null || _savingCustom) {
      return;
    }
    setState(() {
      _followSystemTheme = enabled;
      _savingFollowSystemTheme = true;
    });
    try {
      await widget.onFollowSystemThemeChanged(enabled);
      if (mounted && enabled) {
        final brightness = MediaQuery.platformBrightnessOf(context);
        setState(() {
          _selectedThemeId = ShuYoThemes.systemThemeIdFor(brightness);
        });
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack(context, '主题保存失败：$error');
      setState(() {
        _followSystemTheme = widget.followSystemTheme;
        _selectedThemeId = widget.selectedThemeId;
      });
    } finally {
      if (mounted) {
        setState(() => _savingFollowSystemTheme = false);
      }
    }
  }
}

class _ThemeSwatches extends StatelessWidget {
  const _ThemeSwatches({
    required this.theme,
    required this.selected,
    required this.saving,
  });

  final ShuYoThemeSpec theme;
  final bool selected;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      width: 126,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (saving)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          else if (selected)
            Icon(Icons.check, size: 20, color: colors.accent)
          else
            const SizedBox(width: 20),
          const SizedBox(width: 12),
          for (final color in theme.previewColors) ...[
            _ThemeSwatch(color: color),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: const SizedBox.square(dimension: 16),
    );
  }
}

class _BackgroundCropPage extends StatefulWidget {
  const _BackgroundCropPage({required this.image});

  final Uint8List image;

  @override
  State<_BackgroundCropPage> createState() => _BackgroundCropPageState();
}

class _BackgroundCropPageState extends State<_BackgroundCropPage> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('裁剪照片'),
        actions: [
          TextButton(
            onPressed: _cropping
                ? null
                : () {
                    setState(() => _cropping = true);
                    _controller.crop();
                  },
            child: const Text('完成'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Crop(
            image: widget.image,
            controller: _controller,
            aspectRatio: MediaQuery.sizeOf(context).aspectRatio,
            interactive: true,
            onCropped: (result) {
              if (!mounted) return;
              switch (result) {
                case CropSuccess(:final croppedImage):
                  Navigator.of(context).pop(croppedImage);
                case CropFailure(:final cause):
                  setState(() => _cropping = false);
                  _showSnack(context, '裁剪失败：$cause');
              }
            },
          ),
          if (_cropping) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

class _ThemeColorDialog extends StatefulWidget {
  const _ThemeColorDialog({required this.label, required this.initial});

  final String label;
  final Color initial;

  @override
  State<_ThemeColorDialog> createState() => _ThemeColorDialogState();
}

class _ThemeColorDialogState extends State<_ThemeColorDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexController = TextEditingController(text: _hex(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _hex(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  void _setColor(HSVColor color) {
    setState(() => _hsv = color);
    final hex = _hex(color.toColor());
    _hexController.value = TextEditingValue(
      text: hex,
      selection: TextSelection.collapsed(offset: hex.length),
    );
  }

  void _selectSquare(Offset point, double side) {
    final saturation = (point.dx / side).clamp(0.0, 1.0);
    final value = (1 - point.dy / side).clamp(0.0, 1.0);
    _setColor(_hsv.withSaturation(saturation).withValue(value));
  }

  void _selectHue(Offset point, double width) {
    final hue = (point.dx / width * 360).clamp(0.0, 360.0);
    _setColor(_hsv.withHue(hue));
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final side = (MediaQuery.sizeOf(context).width - 112).clamp(180.0, 300.0);
    return AlertDialog(
      title: Text(widget.label),
      content: SingleChildScrollView(
        child: SizedBox(
          width: side,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: '饱和度和明度',
                child: GestureDetector(
                  key: const Key('theme-color-square'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (details) =>
                      _selectSquare(details.localPosition, side),
                  onPanUpdate: (details) =>
                      _selectSquare(details.localPosition, side),
                  child: SizedBox.square(
                    dimension: side,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white,
                                      HSVColor.fromAHSV(1, _hsv.hue, 1, 1)
                                          .toColor(),
                                    ],
                                  ),
                                ),
                              ),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black,
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: _hsv.saturation * side - 9,
                          top: (1 - _hsv.value) * side - 9,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color,
                              border:
                                  Border.all(color: Colors.white, width: 2.5),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black54,
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                            child: const SizedBox.square(dimension: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Semantics(
                label: '色相',
                child: GestureDetector(
                  key: const Key('theme-hue-bar'),
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (details) =>
                      _selectHue(details.localPosition, side),
                  onPanUpdate: (details) =>
                      _selectHue(details.localPosition, side),
                  child: SizedBox(
                    width: side,
                    height: 28,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: const LinearGradient(colors: [
                              Colors.red,
                              Colors.yellow,
                              Colors.green,
                              Colors.cyan,
                              Colors.blue,
                              Colors.purple,
                              Colors.red,
                            ]),
                          ),
                          child: const SizedBox(
                              height: 16, width: double.infinity),
                        ),
                        Positioned(
                          left: _hsv.hue / 360 * side - 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1)
                                  .toColor(),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                            child: const SizedBox.square(dimension: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: context.shuyoColors.borderStrong),
                    ),
                    child: const SizedBox.square(dimension: 36),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('theme-hex-field'),
                      controller: _hexController,
                      maxLength: 6,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9a-fA-F]'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        prefixText: '#',
                        counterText: '',
                        isDense: true,
                      ),
                      onChanged: (value) {
                        if (value.length != 6) return;
                        final rgb = int.tryParse(value, radix: 16);
                        if (rgb != null) {
                          setState(() => _hsv =
                              HSVColor.fromColor(Color(0xFF000000 | rgb)));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _NotificationSettingsPage extends StatefulWidget {
  const _NotificationSettingsPage({
    required this.settingsService,
    required this.scheduleNotificationService,
  });

  final ClientSettingsService settingsService;
  final AcademicScheduleNotificationService scheduleNotificationService;

  @override
  State<_NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<_NotificationSettingsPage> {
  late Future<ClientNotificationSettings> _future;
  ClientNotificationSettings? _settings;
  bool _saving = false;

  bool _alarmsSupported = false;
  AcademicScheduleAlarmSettings? _alarmSettings;
  bool _savingAlarm = false;
  String? _alarmRingtoneName;
  bool _pickingAlarmRingtone = false;

  @override
  void initState() {
    super.initState();
    _future = _loadSettings();
    _loadAlarmState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: FutureBuilder<ClientNotificationSettings>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.notifications_off,
              title: '设置加载失败',
              message: snapshot.error.toString(),
              action: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _future = _loadSettings();
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }
          final settings = _settings ?? snapshot.data!;
          final alarmSettings = _alarmSettings;
          return ListView(
            children: [
              _SettingsSwitchRow(
                title: '课表提醒',
                value: settings.scheduleEnabled,
                enabled: true,
                onChanged: (value) => _save(
                  settings.copyWith(scheduleEnabled: value),
                ),
              ),
              if (_alarmsSupported && alarmSettings != null) ...[
                _SettingsSwitchRow(
                  title: '早课闹钟',
                  subtitle: '每天仅为上午最早的一节课设置闹钟',
                  value: alarmSettings.enabled,
                  enabled: !_savingAlarm,
                  onChanged: (value) => _saveAlarm(
                    alarmSettings.copyWith(enabled: value),
                    requestPermission: value,
                  ),
                ),
                if (alarmSettings.enabled)
                  ListTile(
                    title: const Text('提前时间'),
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: Text('${alarmSettings.leadMinutes} 分钟'),
                    ),
                    enabled: !_savingAlarm,
                    onTap: _savingAlarm
                        ? null
                        : () => _editAlarmLeadMinutes(alarmSettings),
                  ),
                if (alarmSettings.enabled &&
                    widget.scheduleNotificationService
                        .supportsAlarmRingtoneCustomization)
                  ListTile(
                    title: const Text('闹钟铃声'),
                    subtitle: Text(
                      _alarmRingtoneName ?? '默认',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _pickingAlarmRingtone
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Icon(Icons.chevron_right),
                    enabled: !_savingAlarm && !_pickingAlarmRingtone,
                    onTap: _pickAlarmRingtone,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<ClientNotificationSettings> _loadSettings() async {
    final settings = await widget.settingsService.loadNotificationSettings();
    _settings = settings;
    return settings;
  }

  Future<void> _loadAlarmState() async {
    final supported =
        await widget.scheduleNotificationService.supportsEarlyClassAlarms();
    final settings = supported
        ? await widget.scheduleNotificationService.loadAlarmSettings()
        : const AcademicScheduleAlarmSettings(
            enabled: false,
            leadMinutes: 20,
          );
    final ringtoneName = supported
        ? await widget.scheduleNotificationService.loadAlarmRingtoneName()
        : null;
    if (!mounted) return;
    setState(() {
      _alarmsSupported = supported;
      _alarmSettings = settings;
      _alarmRingtoneName = ringtoneName;
    });
  }

  Future<void> _save(ClientNotificationSettings settings) async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _settings = settings;
    });
    try {
      final saved =
          await widget.settingsService.saveNotificationSettings(settings);
      await widget.scheduleNotificationService.syncScheduleReminders(
        requestPermission: saved.scheduleEnabled,
      );
      if (!mounted) {
        return;
      }
      setState(() => _settings = saved);
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '设置保存失败：$error');
        setState(() {
          _future = _loadSettings();
        });
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _saveAlarm(
    AcademicScheduleAlarmSettings settings, {
    bool requestPermission = false,
  }) async {
    if (_savingAlarm) {
      return;
    }
    setState(() {
      _savingAlarm = true;
      _alarmSettings = settings;
    });
    try {
      final saved =
          await widget.scheduleNotificationService.saveAlarmSettingsAndSync(
        settings,
        requestPermission: requestPermission,
      );
      if (!mounted) {
        return;
      }
      setState(() => _alarmSettings = saved);
      if (settings.enabled && !saved.enabled) {
        _showSnack(context, '未获得闹钟权限，请在系统设置中允许 ShuYo 使用闹钟');
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '闹钟设置保存失败：$error');
        _loadAlarmState();
      }
    } finally {
      if (mounted) {
        setState(() => _savingAlarm = false);
      }
    }
  }

  Future<void> _editAlarmLeadMinutes(
    AcademicScheduleAlarmSettings settings,
  ) async {
    final formKey = GlobalKey<FormState>();
    var input = settings.leadMinutes.toString();
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('提前时间'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: input,
            onChanged: (value) => input = value,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '提前分钟数',
              helperText: '可设置 1–120 分钟',
            ),
            validator: (text) {
              final minutes = int.tryParse(text ?? '');
              if (minutes == null || minutes < 1 || minutes > 120) {
                return '请输入 1–120 之间的整数';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(int.parse(input));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value != null && mounted) {
      await _saveAlarm(settings.copyWith(leadMinutes: value));
    }
  }

  Future<void> _pickAlarmRingtone() async {
    if (_pickingAlarmRingtone || _savingAlarm) {
      return;
    }
    setState(() => _pickingAlarmRingtone = true);
    try {
      final name = await widget.scheduleNotificationService.pickAlarmRingtone();
      if (!mounted || name == null) {
        return;
      }
      setState(() => _alarmRingtoneName = name);
      _showSnack(context, '闹钟铃声已设置为$name');
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '选择闹钟铃声失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _pickingAlarmRingtone = false);
      }
    }
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    required this.onTap,
  });

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.title,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SwitchListTile(
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? colors.textPrimary : colors.textMuted,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(color: colors.textMuted),
            ),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
