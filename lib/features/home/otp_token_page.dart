import 'dart:async';

import 'package:flutter/material.dart';
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
  });

  final OtpTokenRepository repository;

  /// Invoked when the gateway rejects its token, so the shell can try to
  /// restore the WebVPN session the same way the classroom page does.
  final Future<void> Function()? onWebVpnExpired;

  @override
  State<OtpTokenPage> createState() => _OtpTokenPageState();
}

class _OtpTokenPageState extends State<OtpTokenPage>
    with WidgetsBindingObserver {
  OtpToken? _token;

  /// True while a read is in flight, which also keeps the ticker from stacking
  /// requests when one takes longer than the polling interval.
  bool _fetching = false;

  /// Set once a failed read has already asked the shell to restore WebVPN, so
  /// a run of failures does not repeat that request every second.
  bool _webVpnRecoveryRequested = false;

  /// Last failure already reported. Polling retries every second, so the same
  /// reason is shown once instead of one bar per attempt.
  String? _reportedError;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTicker();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
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
    if (_fetching) return;
    _fetching = true;
    try {
      final token = await widget.repository.fetchToken();
      if (!mounted) return;
      _webVpnRecoveryRequested = false;
      _reportedError = null;
      setState(() => _token = token);
    } on OtpTokenException catch (error) {
      _onFailure(error);
    } on Object {
      _onFailure(null);
    } finally {
      _fetching = false;
    }
  }

  /// Reports a failed read without disturbing what is on screen.
  ///
  /// The last code stays put with its bar standing still, and the next tick
  /// quietly tries again. The reason is still surfaced, but as one bar across
  /// the bottom rather than page content, and only when it changes: otherwise a
  /// persistent failure would push a new bar every second.
  void _onFailure(OtpTokenException? error) {
    if (!mounted) return;
    final message = _messageFor(error);
    if (message != _reportedError) {
      _reportedError = message;
      _showSnack(message);
    }
    if (error != null &&
        error.code == OtpTokenException.webVpnLoginRequired &&
        !_webVpnRecoveryRequested) {
      _webVpnRecoveryRequested = true;
      unawaited(widget.onWebVpnExpired?.call() ?? Future<void>.value());
    }
  }

  String _messageFor(OtpTokenException? error) {
    if (error == null) return '动态口令加载失败，请稍后重试。';
    return switch (error.code) {
      OtpTokenException.sessionNotReused => '校园登录状态已失效，请回到首页重新登录后再试。',
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
    if (_ticker != null) return;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('动态口令')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final token = _token;
    if (token == null) {
      // Nothing has been read yet; a spinner stays until the first read lands.
      return const Center(child: CircularProgressIndicator());
    }
    return _buildToken(token);
  }

  Widget _buildToken(OtpToken token) {
    final colors = context.shuyoColors;
    final remaining = token.remaining;
    final ratio =
        token.period <= 0 ? 0.0 : (remaining / token.period).clamp(0.0, 1.0);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            token.groupedCode,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 52,
              height: 1.1,
              fontWeight: FontWeight.w600,
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
        Text(
          '$remaining 秒后自动更新',
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary),
        ),
        const SizedBox(height: 36),
        FilledButton.icon(
          onPressed: () => unawaited(_copy()),
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制口令'),
        ),
        const SizedBox(height: 16),
        Text(
          '在需要动态口令的系统中输入这 6 位数字。口令每 ${token.period} 秒'
          '自动更新，请以页面显示的为准。',
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
        ),
      ],
    );
  }
}
