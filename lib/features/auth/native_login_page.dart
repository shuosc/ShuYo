import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/academic_url_resolver.dart';
import '../../core/wecom_constants.dart';
import '../../data/services/academic_native_auth_service.dart';
import '../../data/services/academic_account_store.dart';
import '../../data/services/academic_auth_service.dart';
import '../../data/services/academic_progress_api_client.dart';
import '../../data/services/student_identity_service.dart';
import '../../data/services/there_booking_client.dart';
import '../../data/services/unified_account_service.dart';
import '../../data/services/verification_delivery_service.dart';
import '../../data/services/wecom_auth_service.dart';
import '../../data/demo/demo_session.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'wecom_scan_page.dart';

enum NativeLoginDestination { academic, webVpn, there, dataDeletion }

enum NativeLoginResult { authenticated, demo }

/// 该次登录是否已在扫码页内完成 WebVPN 握手。
///
/// 企微扫码登录 WebVPN 时，[WeComScanPage] 会在同一原生 Cookie 会话内自行走完
/// `auth/start → auth/finish → user/info`，此时 [WeComRedeemResult.callbackUri]
/// 是登录后的落地页，没有可兑换的 `code`。教务等其余目标只拿到授权码，仍须跟随
/// 回调兑换会话。
@visibleForTesting
bool weComEstablishedWebVpnSession({
  required NativeLoginDestination destination,
  required WeComRedeemResult? weComRedeem,
}) =>
    weComRedeem != null && destination == NativeLoginDestination.webVpn;

class NativeLoginPage extends StatefulWidget {
  const NativeLoginPage({
    super.key,
    this.destination = NativeLoginDestination.academic,
  }) : studentIdentityService = null;

  const NativeLoginPage.webVpn({
    super.key,
  })  : destination = NativeLoginDestination.webVpn,
        studentIdentityService = null;

  const NativeLoginPage.there({
    super.key,
  })  : destination = NativeLoginDestination.there,
        studentIdentityService = null;

  const NativeLoginPage.dataDeletion({
    super.key,
    required this.studentIdentityService,
  }) : destination = NativeLoginDestination.dataDeletion;

  final NativeLoginDestination destination;
  final StudentIdentityService? studentIdentityService;

  @override
  State<NativeLoginPage> createState() => _NativeLoginPageState();
}

class _NativeLoginPageState extends State<NativeLoginPage> {
  AcademicNativeAuthService? _authServiceInstance;
  AcademicNativeAuthService get _authService =>
      _authServiceInstance ??= switch (widget.destination) {
        NativeLoginDestination.webVpn => AcademicNativeAuthService.forWebVpn(),
        NativeLoginDestination.academic => AcademicNativeAuthService(),
        NativeLoginDestination.there => AcademicNativeAuthService.forThere(),
        NativeLoginDestination.dataDeletion => AcademicNativeAuthService(),
      };
  final _verificationDeliveryService = VerificationDeliveryService();
  final _weComAuthService = WeComAuthService();
  final _studentId = TextEditingController();
  final _studentIdFocusNode = FocusNode();
  final _password = TextEditingController();
  final _passwordFocusNode = FocusNode();
  final _code = TextEditingController();
  final _codeFocusNode = FocusNode();

  int _step = 0;
  bool _busy = false;
  bool _routeClosed = false;
  bool _passwordVisible = false;
  bool _studentIdError = false;
  bool _passwordError = false;
  bool _codeError = false;
  AcademicLoginChallenge? _challenge;
  AcademicVerificationMethod _method = AcademicVerificationMethod.wecom;
  Timer? _countdownTimer;
  int _countdown = 0;

  @override
  void initState() {
    super.initState();
    _passwordFocusNode.addListener(_onPasswordFocusChanged);
  }

  void _onPasswordFocusChanged() => setState(() {});

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _authServiceInstance?.dispose();
    _weComAuthService.dispose();
    _studentId.dispose();
    _studentIdFocusNode.dispose();
    _password.dispose();
    _passwordFocusNode.removeListener(_onPasswordFocusChanged);
    _passwordFocusNode.dispose();
    _code.dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _routeClosed = true;
          TextInput.finishAutofillContext(shouldSave: false);
          return;
        }
        if (!_busy) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: AutofillGroup(
            onDisposeAction: AutofillContextAction.cancel,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: switch (_step) {
                0 => _credentials(),
                _ => _verification(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentials() {
    final colors = context.shuyoColors;
    final academic = widget.destination == NativeLoginDestination.academic;
    final dataDeletion =
        widget.destination == NativeLoginDestination.dataDeletion;
    final there = widget.destination == NativeLoginDestination.there;
    return Form(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const ValueKey('credentials'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 55, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        dataDeletion
                            ? '验证学校身份'
                            : academic
                                ? '上大校园账户'
                                : there
                                    ? '登录图书馆预约'
                                    : 'WebVPN服务',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          dataDeletion
                              ? '重新登录上海大学账户，以确认本人操作'
                              : academic
                                  ? '使用上海大学统一认证账户来访问各类校园服务'
                                  : there
                                      ? '使用上海大学统一认证账户来访问图书馆预约'
                                      : '使用上海大学统一认证账户来访问WebVPN服务',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                      const SizedBox(height: 32),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          border: Border.all(color: colors.border),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            _credentialRow(
                              label: '学/工号',
                              field: TextFormField(
                                controller: _studentId,
                                focusNode: _studentIdFocusNode,
                                enabled: !_busy,
                                keyboardType: TextInputType.text,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [AutofillHints.username],
                                textInputAction: TextInputAction.next,
                                onTapOutside: (_) =>
                                    FocusScope.of(context).unfocus(),
                                onChanged: (value) {
                                  if (_studentIdError &&
                                      value.trim().isNotEmpty) {
                                    setState(() => _studentIdError = false);
                                  }
                                },
                                decoration: _credentialDecoration(),
                              ),
                            ),
                            Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                                color: colors.border),
                            _credentialRow(
                              label: '密码',
                              rightPadding: 8,
                              field: TextFormField(
                                controller: _password,
                                focusNode: _passwordFocusNode,
                                enabled: !_busy,
                                obscureText: !_passwordVisible,
                                keyboardType: TextInputType.visiblePassword,
                                autocorrect: false,
                                enableSuggestions: false,
                                autofillHints: const [AutofillHints.password],
                                textInputAction: TextInputAction.done,
                                onTapOutside: (_) =>
                                    _passwordFocusNode.unfocus(),
                                onFieldSubmitted: (_) => _submitCredentials(),
                                onChanged: (value) {
                                  if (_passwordError && value.isNotEmpty) {
                                    setState(() => _passwordError = false);
                                  }
                                },
                                decoration: _credentialDecoration(
                                  suffixIcon: IgnorePointer(
                                    ignoring: !_passwordFocusNode.hasFocus,
                                    child: AnimatedOpacity(
                                      opacity:
                                          _passwordFocusNode.hasFocus ? 1 : 0,
                                      duration:
                                          const Duration(milliseconds: 180),
                                      child: IconButton(
                                        style: const ButtonStyle(
                                          splashFactory: NoSplash.splashFactory,
                                          overlayColor: WidgetStatePropertyAll(
                                            Colors.transparent,
                                          ),
                                        ),
                                        tooltip:
                                            _passwordVisible ? '隐藏密码' : '显示密码',
                                        onPressed: () => setState(() =>
                                            _passwordVisible =
                                                !_passwordVisible),
                                        icon: Icon(
                                          _passwordVisible
                                              ? Icons.visibility_off_outlined
                                              : Icons.visibility_outlined,
                                          color: colors.textTertiary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _validationSlot(
                        _studentIdError
                            ? '请输入学/工号'
                            : _passwordError
                                ? '请输入密码'
                                : null,
                        height: 28,
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _submitCredentials,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                        ),
                        child: _buttonContent('继续'),
                      ),
                      if (!dataDeletion) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _startWeComLogin,
                          icon: const Icon(Icons.qr_code_scanner_outlined),
                          label: const Text('使用企业微信登录'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(50),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '使用企业微信扫码或跳转至企业微信登录',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _credentialRow({
    required String label,
    required Widget field,
    double rightPadding = 16,
  }) {
    final colors = context.shuyoColors;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: rightPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SizedBox(
              width: 72,
              child: Text(label, style: TextStyle(color: colors.textSecondary)),
            ),
          ),
          Expanded(child: field),
        ],
      ),
    );
  }

  Widget _validationSlot(String? message, {required double height}) {
    final colors = context.shuyoColors;
    final textScaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: textScaler.scale(height),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.centerLeft,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        ),
        child: message == null
            ? const SizedBox(key: ValueKey('validation-empty'))
            : SizedBox(
                key: ValueKey(message),
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      liveRegion: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 14,
                            color: colors.danger,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            message,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  InputDecoration _credentialDecoration({Widget? suffixIcon}) {
    return InputDecoration(
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
    );
  }

  Widget _verification() {
    final methods = _challenge?.methods ?? const {};
    final colors = context.shuyoColors;
    return Form(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const ValueKey('verification'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 55, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '二步验证',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          '验证码将${_methodHint(methods)}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textSecondary),
                        ),
                      ),
                      if (methods.length > 1) ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<AcademicVerificationMethod>(
                            expandedInsets: EdgeInsets.zero,
                            showSelectedIcon: false,
                            segments: [
                              if (methods.containsKey(
                                  AcademicVerificationMethod.wecom))
                                const ButtonSegment(
                                  value: AcademicVerificationMethod.wecom,
                                  label: Text('企业微信'),
                                ),
                              if (methods
                                  .containsKey(AcademicVerificationMethod.sms))
                                const ButtonSegment(
                                  value: AcademicVerificationMethod.sms,
                                  label: Text('手机号'),
                                ),
                            ],
                            selected: {_method},
                            onSelectionChanged: _busy
                                ? null
                                : (value) =>
                                    _selectVerificationMethod(value.first),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          border: Border.all(color: colors.border),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16, right: 8),
                          child: TextFormField(
                            controller: _code,
                            focusNode: _codeFocusNode,
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            maxLength: 6,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _verifyCode(),
                            onChanged: (value) {
                              if (_codeError && value.trim().length == 6) {
                                setState(() => _codeError = false);
                              }
                            },
                            decoration: _credentialDecoration(
                              suffixIcon: TextButton(
                                onPressed:
                                    _busy || _countdown > 0 ? null : _sendCode,
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  splashFactory: NoSplash.splashFactory,
                                ),
                                child: Text(_countdown > 0
                                    ? '重发 ${_countdown}s'
                                    : '发送验证码'),
                              ),
                            ).copyWith(
                              hintText: '验证码',
                              counterText: '',
                            ),
                          ),
                        ),
                      ),
                      _validationSlot(
                        _codeError ? '请输入6位验证码' : null,
                        height: 24,
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _verifyCode,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                        ),
                        child: _buttonContent('完成验证'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buttonContent(String label) {
    // 登录请求期间显示进度，避免按钮看起来没有响应。
    if (!_busy) return Text(label);
    return const SizedBox.square(
        dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
  }

  Future<void> _submitCredentials() async {
    if (_busy) return;
    final studentIdError = _studentId.text.trim().isEmpty;
    final passwordError = _password.text.isEmpty;
    setState(() {
      _studentIdError = studentIdError;
      _passwordError = passwordError;
    });
    if (studentIdError || passwordError) {
      (studentIdError ? _studentIdFocusNode : _passwordFocusNode)
          .requestFocus();
      return;
    }
    // 演示模式完全离线，在发起网络请求之前处理。
    if (widget.destination == NativeLoginDestination.academic &&
        DemoSession.matchesCredentials(_studentId.text, _password.text)) {
      await _submitDemoLogin();
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      if (widget.destination != NativeLoginDestination.academic &&
          widget.destination != NativeLoginDestination.dataDeletion) {
        final currentStudentId = await AcademicAccountStore().loadStudentId();
        if (!mounted) return;
        if (currentStudentId != null &&
            currentStudentId.toLowerCase() !=
                _studentId.text.trim().toLowerCase()) {
          _showError('登录账号须与当前校园账户一致');
          return;
        }
      }
      final result = await _authService.login(
          username: _studentId.text.trim(), password: _password.text);
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
  /// 全程离线，在任何网络请求之前处理。
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
    _closeWith(NativeLoginResult.demo);
  }

  Future<void> _startWeComLogin() async {
    if (_busy) return;
    if (!mounted) return;
    TextInput.finishAutofillContext(shouldSave: false);
    _password.clear();
    setState(() => _busy = true);
    try {
      if (widget.destination == NativeLoginDestination.there) {
        final client = ThereBookingClient();
        try {
          await client.prepareOAuth();
        } finally {
          client.dispose();
        }
      }
      final session = await _weComAuthService.startQrSession();
      if (!mounted) return;
      setState(() => _busy = false);
      final redeemed = await Navigator.of(context).push<WeComRedeemResult>(
        MaterialPageRoute(
          builder: (_) => ShuYoRouteSurface(
            child: WeComScanPage(
              session: session,
              authService: _weComAuthService,
              target: _weComTarget,
            ),
          ),
        ),
      );
      if (redeemed == null || !mounted) return;
      await _completeLogin(
        redeemed.callbackUri,
        weComRedeem: redeemed,
      );
    } on AcademicNativeAuthException catch (error) {
      _showError(error.message);
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
  WeComOAuthTarget get _weComTarget => switch (widget.destination) {
        NativeLoginDestination.webVpn => WeComOAuthTarget.webVpn,
        NativeLoginDestination.academic => WeComOAuthTarget.academic,
        NativeLoginDestination.there => WeComOAuthTarget.there,
        NativeLoginDestination.dataDeletion => WeComOAuthTarget.academic,
      };

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
    if (_busy) return;
    final codeError = _code.text.trim().length != 6;
    setState(() => _codeError = codeError);
    if (codeError) {
      _codeFocusNode.requestFocus();
      return;
    }
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

  /// 完成登录：用 [callbackUri] 走完 OAuth 回调并建立业务会话。
  ///
  /// [weComRedeem] 非空时表示这次回调来自企业微信扫码，SSO 会话 Cookie
  /// 由 [WeComAuthService.redeem] 单独取得，必须先并入 [_authService]，
  /// 否则 [AcademicNativeAuthService.completeLogin] 无 cookie 可用，
  /// 加载 callbackUri 会被 SSO 重定向回登录页并最终超时。
  Future<void> _completeLogin(
    Uri callbackUri, {
    WeComRedeemResult? weComRedeem,
  }) async {
    if (widget.destination == NativeLoginDestination.dataDeletion) {
      try {
        await _authService.completeLogin(callbackUri, publish: false);
        final schoolUri = AcademicUrlResolver.uri(
            AcademicProgressApiClient.studentIdentityPath);
        final schoolCookie = _authService.cookieHeaderFor(schoolUri);
        if (schoolCookie.isEmpty) {
          _showError('学校登录未完成，请重试');
          return;
        }
        final grant = await widget.studentIdentityService!.beginDataDeletion(
          schoolCookie: schoolCookie,
          expectedStudentId: _studentId.text.trim(),
        );
        _closeWith(grant);
      } on AcademicNativeAuthException catch (error) {
        _showError(error.message);
      } on StudentIdentityException catch (error) {
        _showError(error.message);
      } on Object {
        _showError('身份验证失败，请稍后再试');
      }
      return;
    }
    if (widget.destination == NativeLoginDestination.webVpn &&
        weComRedeem?.accountName?.trim().isNotEmpty == true) {
      final currentStudentId = await AcademicAccountStore().loadStudentId();
      if (!mounted) return;
      if (currentStudentId != null &&
          currentStudentId.toLowerCase() !=
              weComRedeem!.accountName!.trim().toLowerCase()) {
        _showError('WebVPN账号与当前校园账户不一致');
        return;
      }
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
    await _authService.resetPreviousSession();
    if (!mounted) return;
    if (widget.destination == NativeLoginDestination.there) {
      // The booking client exchanges its own authorization code, so its flow
      // needs the adopted cookies in the shared jar rather than a completed
      // login.
      await _authService.publishSessionCookies();
      final client = ThereBookingClient();
      try {
        final target = callbackUri.host == client.baseUri.host &&
                callbackUri.path == '/login-oauth2' &&
                callbackUri.queryParameters['code']?.isNotEmpty == true
            ? callbackUri
            : await UnifiedAccountService().authorizeThere();
        if (target == null) {
          _showError('统一认证未能授权图书馆预约，请重新登录');
          return;
        }
        await client.completeOAuth(
          target,
          cookies: _authService.sessionCookies,
        );
        final profile = await client.profile();
        final expected = await AcademicAccountStore().loadStudentId();
        if (expected != null &&
            !ThereBookingClient.matchesAccount(profile, expected)) {
          await client.clearSession();
          _showError('图书馆预约账号与当前校园账户不一致');
          return;
        }
        _closeWith(NativeLoginResult.authenticated,
            savePassword: weComRedeem == null);
      } on ThereBookingException catch (error) {
        _showError(error.message);
      } on Object {
        _showError('图书馆预约登录失败，请稍后重试');
      } finally {
        client.dispose();
      }
      return;
    }
    if (weComEstablishedWebVpnSession(
      destination: widget.destination,
      weComRedeem: weComRedeem,
    )) {
      // 会话已由扫码流程建立，直接把已收集的 Cookie 发布给共享会话罐。
      await _authService.publishSessionCookies();
    } else {
      await _authService.completeLogin(callbackUri);
    }
    if (!mounted) return;
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
          await auth.clearAccount(
            sessionExpired: await AcademicAccountStore().isSessionExpired(),
          );
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
      final studentId = weComRedeem != null
          ? await AcademicProgressApiClient().fetchAuthenticatedStudentId()
          : _studentId.text;
      await AcademicAccountStore().saveStudentId(studentId);
    }
    _closeWith(NativeLoginResult.authenticated,
        savePassword: weComRedeem == null);
  }

  /// 结束自动填充上下文并带着 [result] 关闭登录页。
  ///
  /// 只有密码登录成功时才请求系统保存密码；必须先结束上下文再清空输入框，
  /// 否则系统读到的是空密码。
  void _closeWith(Object result, {bool savePassword = false}) {
    if (!mounted || _routeClosed) return;
    TextInput.finishAutofillContext(shouldSave: savePassword);
    _password.clear();
    _code.clear();
    Navigator.of(context).pop(result);
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
