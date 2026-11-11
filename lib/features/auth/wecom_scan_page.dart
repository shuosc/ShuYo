import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/wecom_constants.dart';
import '../../data/services/wecom_auth_service.dart';

/// 企业微信扫码登录等待页。
///
/// 在本地根据确认链接生成二维码，并支持点击拉起企业微信确认页。在后台长轮询
/// 等待用户扫码确认，成功后返回换取到的 SSO 会话结果。
class WeComScanPage extends StatefulWidget {
  const WeComScanPage({
    super.key,
    required this.session,
    required this.authService,
    required this.target,
  });

  final WeComQrSession session;
  final WeComAuthService authService;

  /// 本次扫码要登录的目标系统，决定 SSO 下发授权码的归属。
  final WeComOAuthTarget target;

  @override
  State<WeComScanPage> createState() => _WeComScanPageState();
}

class _WeComScanPageState extends State<WeComScanPage> {
  WeComScanStatus _status = WeComScanStatus.waiting;
  bool _launchingLink = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_waitForScan());
  }

  @override
  void dispose() {
    // 页面被销毁时取消后台长轮询，避免在后台继续发起网络请求。
    _cancelled = true;
    super.dispose();
  }

  /// 后台长轮询，状态变化时刷新界面，成功后换取目标业务系统回调地址。
  Future<void> _waitForScan() async {
    final WeComScanResult result;
    try {
      result = await widget.authService.waitForScan(
        widget.session.key,
        isCancelled: () => _cancelled,
        onStatusChanged: (status) {
          if (mounted && status != _status) {
            setState(() => _status = status);
          }
        },
      );
    } on Object {
      if (mounted) _showError('无法连接企业微信服务，请稍后再试');
      return;
    }
    if (!mounted) return;
    if (!result.isSuccess) {
      _showError('二维码已过期或已取消，请重新尝试');
      return;
    }
    try {
      // 阶段一：auth_code → SSO 会话（state 固定为教务参数）。
      await widget.authService.redeem(
        result.authCode!,
        WeComAuthService.weComRedeemState,
      );
      if (mounted) {
        setState(() => _status = WeComScanStatus.succeeded);
      }
      // WebVPN 的 OAuth callback 只是 SPA 入口，还必须在同一原生
      // Cookie 会话中完成 auth/finish 并用 user/info 确认身份。
      if (widget.target.kind == WeComOAuthTargetKind.webVpn) {
        final webVpnResult = await widget.authService.completeWebVpnLogin();
        if (!mounted) return;
        Navigator.of(context).pop(webVpnResult);
        return;
      }
      final callbackUri =
          await widget.authService.authorizeTarget(widget.target);
      if (!mounted) return;
      final cookies = widget.authService.cookieJar;
      Navigator.of(context).pop(
        WeComRedeemResult(
          callbackUri: callbackUri,
          sessionCookies: cookies,
        ),
      );
    } on WeComAuthException catch (error) {
      if (mounted) {
        _showError(error.message);
      }
    } on Object {
      if (mounted) {
        _showError('企业微信授权失败，请重新尝试');
      }
    }
  }

  void _showError(String message) {
    _showSnackBar(message);
    Navigator.of(context).pop();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 调用系统打开 wxwork:// scheme（或复制链接）。
  Future<void> _openWeCom() async {
    if (_launchingLink) return;
    setState(() => _launchingLink = true);
    try {
      final ok = await launchUrl(
        Uri.parse(widget.session.wxWorkSchemeUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        await Clipboard.setData(
          ClipboardData(text: widget.session.confirmUrl),
        );
        _showSnackBar('无法打开企业微信，已复制链接，请手动打开');
      }
    } on Object {
      _showSnackBar('无法打开企业微信，请手动打开企业微信');
    } finally {
      if (mounted) setState(() => _launchingLink = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('企业微信登录'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                '使用企业微信扫一扫',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                '打开手机企业微信，点击右上角扫码，或点击下方按钮直接唤起企业微信。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 220,
                  height: 220,
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  // 校园网较差时上游二维码图片常常加载失败，改为本地生成。
                  child: QrImageView(
                    data: widget.session.confirmUrl,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    semanticsLabel: '企业微信登录二维码',
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _statusWidget(),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _launchingLink ? null : _openWeCom,
                icon: const Icon(Icons.open_in_new),
                label: const Text('打开企业微信登录'),
              ),
              const SizedBox(height: 8),
              Text(
                '扫码确认后请返回本应用',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusWidget() {
    final (text, icon) = switch (_status) {
      WeComScanStatus.waiting => (
          '等待扫码…',
          Icons.schedule,
        ),
      WeComScanStatus.confirmedPending => (
          '已扫码，请在手机企业微信确认',
          Icons.android,
        ),
      WeComScanStatus.succeeded => (
          '登录成功',
          Icons.check_circle,
        ),
      WeComScanStatus.expired => (
          '二维码已过期',
          Icons.error_outline,
        ),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
