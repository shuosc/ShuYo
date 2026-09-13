import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/forum_url_resolver.dart';
import '../../core/wecom_constants.dart';
import '../../data/services/academic_native_auth_service.dart';
import '../../data/services/academic_account_store.dart';
import '../../data/services/academic_auth_service.dart';
import '../../data/services/campus_reachability_service.dart';
import '../../data/services/verification_delivery_service.dart';
import '../../data/services/wecom_auth_service.dart';
import '../../data/demo/demo_session.dart';
import 'forum_oauth_completion_page.dart';
import 'webvpn_oauth_completion_page.dart';
import 'wecom_scan_page.dart';

enum NativeLoginDestination { academic, forum, webVpn }

enum NativeLoginResult { authenticated, demo }

class NativeLoginPage extends StatefulWidget {
  const NativeLoginPage({
    super.key,
    this.destination = NativeLoginDestination.academic,
    this.reachabilityService,
  });

  const NativeLoginPage.forum({
    super.key,
    this.reachabilityService,
  }) : destination = NativeLoginDestination.forum;

  const NativeLoginPage.webVpn({
    super.key,
    this.reachabilityService,
  }) : destination = NativeLoginDestination.webVpn;

  final NativeLoginDestination destination;

  /// 校园网可达性探测器，仅用于测试注入。
  @visibleForTesting
  final CampusReachabilityService? reachabilityService;

  @override
  State<NativeLoginPage> createState() => _NativeLoginPageState();
}

class _NativeLoginPageState extends State<NativeLoginPage> {
  AcademicNativeAuthService? _authServiceInstance;
  AcademicNativeAuthService get _authService =>
      _authServiceInstance ??= switch (widget.destination) {
        NativeLoginDestination.forum => AcademicNativeAuthService.forForum(),
        NativeLoginDestination.webVpn => AcademicNativeAuthService.forWebVpn(),
        NativeLoginDestination.academic => AcademicNativeAuthService(),
      };
  final _verificationDeliveryService = VerificationDeliveryService();
  final _weComAuthService = WeComAuthService();
  late final CampusReachabilityService _reachabilityService =
      widget.reachabilityService ?? const CampusReachabilityService();
  final _studentId = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _credentialsKey = GlobalKey<FormState>();
  final _verificationKey = GlobalKey<FormState>();

  int _step = 0;
  bool _busy = false;
  bool _preflighting = false;
  bool _passwordVisible = false;
  AcademicLoginChallenge? _challenge;
  AcademicVerificationMethod _method = AcademicVerificationMethod.wecom;
  Timer? _countdownTimer;
  int _countdown = 0;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _authServiceInstance?.dispose();
    _weComAuthService.dispose();
    _studentId.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_busy) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (_step) {
            0 => switch (widget.destination) {
                NativeLoginDestination.forum => '乐乎论坛账户',
                NativeLoginDestination.webVpn => '登录WebVPN服务',
                NativeLoginDestination.academic => '上大校园账户',
              },
            _ => '验证身份',
          }),
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: switch (_step) {
              0 => _credentials(),
              _ => _verification(),
            },
          ),
        ),
      ),
    );
  }

  Widget _credentials() => Form(
        key: _credentialsKey,
        child: ListView(
          key: const ValueKey('credentials'),
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              switch (widget.destination) {
                NativeLoginDestination.forum => '登录论坛账户',
                NativeLoginDestination.webVpn => '登录WebVPN服务',
                NativeLoginDestination.academic => '登录校园账户',
              },
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '使用上海大学统一认证系统',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            TextFormField(
              controller: _studentId,
              enabled: !_busy,
              keyboardType: TextInputType.text,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                  labelText: '用户名/学号', prefixIcon: Icon(Icons.badge_outlined)),
              validator: (value) =>
                  value?.trim().isEmpty == true ? '请输入学号' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: !_passwordVisible,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _submitCredentials(),
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                  icon: Icon(_passwordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
              ),
              validator: (value) => value?.isEmpty == true ? '请输入密码' : null,
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: (_busy || _preflighting) ? null : _submitCredentials,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              child: _buttonContent('继续'),
            ),
            if (widget.destination != NativeLoginDestination.webVpn) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: (_busy || _preflighting) ? null : _startWeComLogin,
                icon: const Icon(Icons.qr_code_scanner_outlined),
                label: const Text('使用企业微信登录'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50)),
              ),
              const SizedBox(height: 8),
              Text(
                '使用企业微信扫码登录，可在手机企业微信中确认登录。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );

  Widget _verification() {
    final methods = _challenge?.methods ?? const {};
    return Form(
      key: _verificationKey,
      child: ListView(
        key: const ValueKey('verification'),
        padding: const EdgeInsets.all(24),
        children: [
          Text('二步验证',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_methodHint(methods)),
          const SizedBox(height: 24),
          SegmentedButton<AcademicVerificationMethod>(
            segments: [
              if (methods.containsKey(AcademicVerificationMethod.wecom))
                const ButtonSegment(
                    value: AcademicVerificationMethod.wecom,
                    label: Text('企业微信'),
                    icon: Icon(Icons.business_center_outlined)),
              if (methods.containsKey(AcademicVerificationMethod.sms))
                const ButtonSegment(
                    value: AcademicVerificationMethod.sms,
                    label: Text('手机号'),
                    icon: Icon(Icons.sms_outlined)),
            ],
            selected: {_method},
            onSelectionChanged: _busy
                ? null
                : (value) => _selectVerificationMethod(value.first),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy || _countdown > 0 ? null : _sendCode,
            icon: const Icon(Icons.send_outlined),
            label: Text(_countdown > 0 ? '${_countdown}s 后可重新发送' : '发送验证码'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _verifyCode(),
            decoration: const InputDecoration(
                labelText: '验证码', prefixIcon: Icon(Icons.password_outlined)),
            validator: (value) => value?.trim().length == 6 ? null : '请输入6位验证码',
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _verifyCode,
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _buttonContent('完成验证'),
          ),
        ],
      ),
    );
  }

  Widget _buttonContent(String label) {
    // 预检同样要给出反馈：探测最长会占住按钮数秒，
    // 静默禁用看起来像「点了没反应」。
    if (!_busy && !_preflighting) return Text(label);
    return const SizedBox.square(
        dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
  }

  Future<void> _submitCredentials() async {
    if (_busy ||
        _preflighting ||
        _credentialsKey.currentState?.validate() != true) {
      return;
    }
    // 演示模式完全离线，且网络预检会弹出对话框，必须在 busy 之前处理。
    if (DemoSession.matchesCredentials(_studentId.text, _password.text)) {
      await _submitDemoLogin();
      return;
    }
    if (!await _ensureDirectForumAccess()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _authService.login(
          username: _studentId.text.trim(), password: _password.text);
      _password.clear();
      if (!mounted) return;
      if (result.callbackUri != null) {
        await _completeLogin(result.callbackUri!);
        return;
      }
      final challenge = result.challenge;
      if (challenge == null) throw StateError('学校未返回登录结果');
      final methods = challenge.methods.keys;
      final preferred =
          await _verificationDeliveryService.preferredMethod(methods);
      final remaining =
          await _verificationDeliveryService.remainingCooldown(preferred);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _method = preferred;
        _step = 1;
      });
      _startCountdown(remaining);
    } on AcademicNativeAuthException catch (error) {
      _showError(error.message);
    } on Object {
      _showError('无法连接学校认证服务，请稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 进入本地演示模式并返回结果。
  ///
  /// 全程离线，必须早于网络预检，否则校外评审会被预检拦住。
  Future<void> _submitDemoLogin() async {
    setState(() => _busy = true);
    try {
      // The in-memory route must still work if persistence is unavailable
      // (for example, in a restricted review environment). The app state is
      // switched by the caller; persistence only keeps Demo active after a
      // restart.
      await DemoSession.enable();
    } on Object {
      // Continue into the local demo even when preferences cannot be written.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(NativeLoginResult.demo);
  }

  Future<void> _startWeComLogin() async {
    if (_busy || _preflighting) return;
    // 预检可能弹出对话框，放在 busy 之外以免按钮一直停留在加载动画。
    if (!await _ensureDirectForumAccess()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final session = await _weComAuthService.startQrSession();
      if (!mounted) return;
      setState(() => _busy = false);
      final redeemed = await Navigator.of(context).push<WeComRedeemResult>(
        MaterialPageRoute(
          builder: (_) => WeComScanPage(
            session: session,
            authService: _weComAuthService,
            target: _weComTarget,
          ),
        ),
      );
      if (redeemed == null || !mounted) return;
      await _completeLogin(
        redeemed.callbackUri,
        weComRedeem: redeemed,
      );
    } on WeComAuthException catch (error) {
      _showError(error.message);
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[SHU_WECOM] unexpected error type=${error.runtimeType} '
            'error=$error');
        debugPrintStack(label: '[SHU_WECOM] stack', stackTrace: stackTrace);
      }
      _showError('无法连接企业微信服务，请稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 企微扫码登录的目标系统参数，必须与用户正在登录的入口一致，
  /// 否则 SSO 会把授权码下发给错误的业务系统。
  WeComOAuthTarget get _weComTarget =>
      widget.destination == NativeLoginDestination.forum
          ? WeComOAuthTarget.forum
          : WeComOAuthTarget.academic;

  /// 仅当目标业务系统是乐乎论坛且当前为直连时才拦截。
  bool get _requiresDirectForumAccess =>
      widget.destination == NativeLoginDestination.forum &&
      !ForumUrlResolver.usesWebVpn;

  /// 在向学校认证服务提交凭据/发起授权之前，确认论坛直连可用。
  ///
  /// 非校园网下论坛完全不可达，而 SSO 会话与二步验证在校外仍能成功，
  /// 结果就是用户完整走完登录，最后卡在业务系统回调上直到超时。
  /// 这里提前拦住，避免无谓的凭据提交与等待。
  ///
  /// 返回 false 表示应当中止本次登录（已向用户说明原因）。
  Future<bool> _ensureDirectForumAccess() async {
    if (!_requiresDirectForumAccess) return true;
    // 探测有耗时窗口，按钮需要禁用并显示加载，避免连点弹出多个提示框。
    setState(() => _preflighting = true);
    final result = await _reachabilityService.checkDirectForum();
    if (!mounted) return false;
    // 必须在弹出对话框前复位：对话框本身是模态的，已足以阻止连点，
    // 若保持 true 按钮会一直停在加载动画上。
    setState(() => _preflighting = false);
    if (!result.isUnreachable) return true;
    return _showCampusNetworkRequired();
  }

  /// 告知用户当前不在校园网，并允许仍要继续尝试。
  ///
  /// 返回 true 表示用户选择继续（网络探测偶有误报，不应硬阻断登录）。
  Future<bool> _showCampusNetworkRequired() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法连接乐乎论坛'),
        // 与论坛会话页共用同一份文案，避免两处提示漂移。
        content: const Text(campusNetworkRequiredMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('仍然尝试'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _sendCode() async {
    if (_busy || _countdown > 0) return;
    setState(() => _busy = true);
    try {
      await _authService.sendCode(_method);
      await _verificationDeliveryService.markSent(_method);
      if (!mounted) return;
      _startCountdown(VerificationDeliveryService.cooldown);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('验证码已发送')));
    } on AcademicNativeAuthException catch (error) {
      _showError(error.message);
      if (error.code.toLowerCase() == 'senderror') {
        await _selectAlternateMethod();
      }
    } on Object {
      _showError('验证码发送失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_busy || _verificationKey.currentState?.validate() != true) return;
    setState(() => _busy = true);
    try {
      final callbackUri = await _authService.verifyCode(
          method: _method, code: _code.text.trim());
      if (!mounted) return;
      await _completeLogin(callbackUri);
    } on AcademicNativeAuthException catch (error) {
      _showError(error.message);
    } on Object {
      _showError('验证失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 完成登录：把会话 Cookie 装进 WebView，再加载 [callbackUri]。
  ///
  /// [weComRedeem] 非空时表示这次回调来自企业微信扫码，SSO 会话 Cookie
  /// 由 [WeComAuthService.redeem] 单独取得，必须先并入 [_authService]，
  /// 否则 [AcademicNativeAuthService.installCookiesInWebView] 无 cookie 可装，
  /// WebView 加载 callbackUri 会被 SSO 重定向回登录页并最终超时。
  Future<void> _completeLogin(
    Uri callbackUri, {
    WeComRedeemResult? weComRedeem,
  }) async {
    if (kDebugMode && widget.destination == NativeLoginDestination.forum) {
      debugPrint(
        '[FORUM_AUTH_CALLBACK] native redirect '
        '${callbackUri.host}${callbackUri.path} '
        'queryKeys=${callbackUri.queryParameters.keys.toList()..sort()} '
        'redirectUri=${_describeRedirectUri(callbackUri.queryParameters['redirect_uri'])} '
        'stateLength=${callbackUri.queryParameters['state']?.length ?? 0}',
      );
    }
    if (weComRedeem != null) {
      _authService.adoptSessionCookies(
        weComRedeem.sessionCookies.map(
          (entry) => (
            cookie: entry.cookie,
            domain: entry.domain,
            path: entry.path,
          ),
        ),
      );
    }
    await _authService.installCookiesInWebView();
    if (!mounted) return;
    if (widget.destination == NativeLoginDestination.forum) {
      final result =
          await Navigator.of(context).push<ForumOAuthCompletionResult>(
        MaterialPageRoute(
          builder: (_) => ForumOAuthCompletionPage(callbackUri: callbackUri),
        ),
      );
      if (!mounted) return;
      if (result == ForumOAuthCompletionResult.loggedIn) {
        Navigator.of(context).pop(NativeLoginResult.authenticated);
      }
      return;
    }
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebVpnOAuthCompletionPage(
          callbackUri: callbackUri,
          webVpnOnly: widget.destination == NativeLoginDestination.webVpn,
        ),
      ),
    );
    if (completed != true || !mounted) return;
    final auth = AcademicAuthService();
    if (widget.destination == NativeLoginDestination.academic) {
      await auth.markLoggedIn();
    }
    final status = widget.destination == NativeLoginDestination.webVpn
        ? await auth.validateWebVpnSession()
        : await auth.validateDirectAcademicSession();
    if (!mounted) return;
    if (status != WebVpnSessionStatus.valid) {
      if (widget.destination == NativeLoginDestination.academic) {
        // A callback that cannot produce a valid direct session must leave the
        // next attempt in the same clean state as an explicit campus logout.
        try {
          await auth.clearAccount();
        } on Object catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('[SHU_AUTH] failed-login cleanup failed: $error');
            debugPrintStack(
              label: '[SHU_AUTH] cleanup stack',
              stackTrace: stackTrace,
            );
          }
        }
        if (!mounted) return;
      }
      _showError(widget.destination == NativeLoginDestination.webVpn
          ? 'WebVPN登录未完成，请重试'
          : '教务系统登录未完成，请重试');
      return;
    }
    if (widget.destination == NativeLoginDestination.academic) {
      await AcademicAccountStore().saveStudentId(_studentId.text);
    }
    if (mounted) Navigator.of(context).pop(NativeLoginResult.authenticated);
  }

  String _describeRedirectUri(String? value) {
    if (value == null || value.isEmpty) return '-';
    final uri = Uri.tryParse(value);
    if (uri == null) return '<invalid>';
    return '${uri.host}${uri.path}';
  }

  String _methodHint(Map<AcademicVerificationMethod, String> methods) {
    final target = methods[_method];
    if (target == null || target.isEmpty) return '发送至学校统一认证中绑定的账号';
    return _method == AcademicVerificationMethod.wecom
        ? '发送至企业微信账号 $target'
        : '发送至手机号 $target';
  }

  Future<void> _selectVerificationMethod(
    AcademicVerificationMethod method,
  ) async {
    _countdownTimer?.cancel();
    final remaining =
        await _verificationDeliveryService.remainingCooldown(method);
    if (!mounted) return;
    setState(() => _method = method);
    _startCountdown(remaining);
  }

  Future<void> _selectAlternateMethod() async {
    final methods = _challenge?.methods.keys.toSet() ?? const {};
    if (methods.length < 2) return;
    final alternate = methods.firstWhere((method) => method != _method);
    await _selectVerificationMethod(alternate);
  }

  void _startCountdown(Duration remaining) {
    _countdownTimer?.cancel();
    final seconds = remaining.inSeconds;
    if (seconds <= 0) {
      if (mounted) setState(() => _countdown = 0);
      return;
    }
    setState(() => _countdown = seconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _countdown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _countdown = 0);
        return;
      }
      setState(() => _countdown--);
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
