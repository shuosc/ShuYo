import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../data/models/otp_token.dart';
import '../../data/repositories/otp_token_repository.dart';
import '../../data/services/otp_token_api_client.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

/// Shows the school dynamic password.
///
/// The code and its remaining seconds are read from the server once a second
/// for as long as the page is visible, never derived from the local clock, so
/// what the page shows is always the value the school is currently handing out.
/// A copy button puts the code on the clipboard, which is how it is normally
/// carried over to the system that asks for it.
class OtpTokenPage extends StatefulWidget {
  const OtpTokenPage({
    super.key,
    required this.repository,
    this.onWebVpnExpired,
    this.onCampusSessionExpired,
    this.onWebVpnRecoveryRequired,
  });

  final OtpTokenRepository repository;

  /// Invoked when the gateway rejects its token, so the shell can try to
  /// restore the WebVPN session the same way the classroom page does.
  final Future<void> Function()? onWebVpnExpired;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;
  final Future<bool> Function(bool interactive)? onWebVpnRecoveryRequired;

  @override
  State<OtpTokenPage> createState() => _OtpTokenPageState();
}

class _OtpTokenPageState extends State<OtpTokenPage>
    with WidgetsBindingObserver {
  OtpToken? _token;

  /// True while a read is in flight, which also keeps the ticker from stacking
  /// requests when one takes longer than the polling interval.
  bool _fetching = false;
  int _fetchRevision = 0;

  bool _authenticationBlocked = false;
  bool _recoveringAuthentication = false;
  bool _authenticationRecoveryAttempted = false;
  OtpTokenException? _authenticationError;

  /// Last failure already reported. Polling retries every second, so the same
  /// reason is shown once instead of one bar per attempt.
  String? _reportedError;
  Timer? _ticker;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.repository.addListener(_onSessionReset);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _startTicker();
    unawaited(_fetch());
  }

  @override
  void didUpdateWidget(covariant OtpTokenPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.repository == oldWidget.repository) return;
    oldWidget.repository.removeListener(_onSessionReset);
    widget.repository.addListener(_onSessionReset);
    _onSessionReset();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.repository.removeListener(_onSessionReset);
    _ticker?.cancel();
    super.dispose();
  }

  void _onSessionReset() {
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _clearToken());
      return;
    }
    _clearToken();
  }

  void _clearToken() {
    if (!mounted) return;
    _fetchRevision++;
    _fetching = false;
    setState(() => _token = null);
    _reportedError = null;
    _authenticationBlocked = !widget.repository.sessionActive;
    _authenticationError = null;
    if (_authenticationBlocked) {
      _ticker?.cancel();
      _ticker = null;
    } else if (!_recoveringAuthentication) {
      _authenticationRecoveryAttempted = false;
      _startTicker();
      unawaited(_fetch());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Returning to the page must not wait for the next tick: the code that
      // was on screen may have rotated while the app was in the background.
      _startTicker();
      unawaited(_fetch());
      return;
    }
    // A backgrounded page has nothing to show, so polling would only spend
    // battery and traffic to update a value the user cannot see.
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _fetch() async {
    if (_fetching || _authenticationBlocked || _recoveringAuthentication) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final revision = _fetchRevision;
    var retry = false;
    _fetching = true;
    try {
      final token = await widget.repository.fetchToken();
      if (!mounted || revision != _fetchRevision) return;
      _reportedError = null;
      _authenticationRecoveryAttempted = false;
      setState(() => _token = token);
    } on OtpTokenException catch (error) {
      if (revision == _fetchRevision) retry = await _onFailure(error);
    } on Object {
      if (revision == _fetchRevision) await _onFailure(null);
    } finally {
      if (revision == _fetchRevision) _fetching = false;
    }
    if (retry && mounted) unawaited(_fetch());
  }

  /// Transient failures retain the displayed code. Authentication failures
  /// clear it and pause polling until the account is restored.
  Future<bool> _onFailure(OtpTokenException? error) async {
    if (!mounted) return false;
    if (error != null &&
        (error.code == OtpTokenException.sessionNotReused ||
            error.code == OtpTokenException.webVpnLoginRequired)) {
      final allowRecovery = !_authenticationRecoveryAttempted;
      _authenticationRecoveryAttempted = true;
      return _recoverAuthentication(error, allowRecovery: allowRecovery);
    }
    final message = _messageFor(error);
    if (message != _reportedError) {
      _reportedError = message;
      _showSnack(message);
    }
    return false;
  }

  Future<bool> _recoverAuthentication(OtpTokenException error,
      {bool userInitiated = false, bool allowRecovery = true}) async {
    if (!mounted || _recoveringAuthentication) return false;
    _recoveringAuthentication = true;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _authenticationBlocked = true;
      _authenticationError = error;
      _token = null;
    });
    var recovered = false;
    final interactive = allowRecovery &&
        ModalRoute.of(context)?.isCurrent != false &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    try {
      if (error.code == OtpTokenException.sessionNotReused) {
        if (userInitiated || widget.repository.sessionActive) {
          recovered =
              await widget.onCampusSessionExpired?.call(interactive) ?? false;
        }
      } else if (allowRecovery && widget.onWebVpnRecoveryRequired != null) {
        recovered = await widget.onWebVpnRecoveryRequired!(interactive);
      } else if (allowRecovery) {
        await widget.onWebVpnExpired?.call();
      }
    } on Object {
      if (mounted && interactive) _showSnack('暂时无法恢复登录，请稍后重试。');
    } finally {
      _recoveringAuthentication = false;
      if (mounted) {
        setState(() {
          _authenticationBlocked = !recovered;
          _authenticationError = recovered ? null : error;
        });
        if (recovered) _startTicker();
      }
    }
    return recovered;
  }

  Future<void> _retryAuthentication() async {
    final error = _authenticationError;
    if (error == null) return;
    _authenticationRecoveryAttempted = true;
    if (await _recoverAuthentication(error, userInitiated: true) && mounted) {
      await _fetch();
    }
  }

  String _messageFor(OtpTokenException? error) {
    if (error == null) return '动态口令加载失败，请稍后重试。';
    return switch (error.code) {
      OtpTokenException.sessionNotReused => '登录已失效，请重新登录。',
      OtpTokenException.webVpnLoginRequired => 'WebVPN 连接已失效，请在账号管理里恢复后重试。',
      _ => error.message,
    };
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Polls once per second, with the first tick aligned to the wall clock.
  ///
  /// The server rotates on whole seconds, so starting the first read on a
  /// whole second keeps the gap between a rotation and the page reflecting it
  /// under a second. After that a fixed one-second beat is used, which avoids
  /// rescheduling work on every tick.
  void _startTicker() {
    if (_ticker != null ||
        _authenticationBlocked ||
        _recoveringAuthentication) {
      return;
    }
    final wait = Duration(milliseconds: 1000 - DateTime.now().millisecond);
    _ticker = Timer(wait, () {
      if (!mounted) return;
      unawaited(_fetch());
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_fetch()),
      );
    });
  }

  Future<void> _copy() async {
    final token = _token;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: token.code));
    if (!mounted) return;
    _showSnack('已复制动态口令');
  }

  /// True until the first code lands, which is the only state that shows the
  /// placeholder layout along with the app bar progress bar.
  bool get _awaitingFirstToken =>
      _token == null && !_authenticationBlocked && !_recoveringAuthentication;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('动态口令'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _awaitingFirstToken || _recoveringAuthentication
                ? const LinearProgressIndicator(
                    key: ValueKey('otp-loading-progress'),
                    minHeight: 2,
                  )
                : null,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_authenticationBlocked) {
      final error = _authenticationError;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error == null ? '登录已失效，请重新登录。' : _messageFor(error),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _recoveringAuthentication || error == null
                    ? null
                    : _retryAuthentication,
                child: Text(_recoveringAuthentication ? '正在恢复…' : '重试'),
              ),
            ],
          ),
        ),
      );
    }
    // The page is laid out before the first read lands, so nobody has to wait
    // on a blank screen: the code slot shows dashes and the copy button stays
    // greyed out until a real code arrives.
    return _buildToken(_token);
  }

  Widget _buildToken(OtpToken? token) {
    final colors = context.shuyoColors;
    final remaining = token?.remaining ?? 0;
    final period = token?.period ?? 0;
    final ratio = period <= 0 || token == null
        ? 0.0
        : (remaining / period).clamp(0.0, 1.0);
    final hasToken = token != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            token?.groupedCode ?? '--- ---',
            key: const ValueKey('otp-code'),
            style: TextStyle(
              color: hasToken ? colors.textPrimary : colors.textMuted,
              fontSize: 52,
              height: 1.1,
              fontWeight: FontWeight.w500,
              letterSpacing: 6,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 28),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: colors.border,
            valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
          ),
        ),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(
            children: [
              if (hasToken)
                TextSpan(
                  children: [
                    // The number keeps changing, so it carries the accent
                    // color while the wording stays quiet.
                    TextSpan(
                      text: '$remaining',
                      style: TextStyle(
                        color: colors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: ' 秒后自动更新',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ],
                )
              else
                TextSpan(
                  text: '正在获取动态口令…',
                  style: TextStyle(color: colors.textSecondary),
                ),
            ],
          ),
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary),
        ),
        const SizedBox(height: 36),
        FilledButton.icon(
          onPressed: hasToken ? () => unawaited(_copy()) : null,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制口令'),
        ),
        const SizedBox(height: 16),
        Text(
          '登录 OpenVPN、EasyConnect 等系统时需要输入这 6 位动态数字。',
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
        ),
      ],
    );
  }
}
