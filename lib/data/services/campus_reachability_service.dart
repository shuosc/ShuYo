import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/certificate_policy.dart';
import '../../core/forum_constants.dart';
import 'http_timeout.dart';

/// 校园站点直连可达性。
///
/// 只有 [reachable] 与 [unreachable] 是可信结论；证书异常等无法归因的情况
/// 一律返回 [unknown]，调用方不应据此阻止用户操作。
enum CampusReachabilityStatus { reachable, unreachable, unknown }

/// 单个站点探测方法，返回 true 表示直连可达。
typedef CampusReachabilityProbe = Future<bool> Function(Uri uri);

/// 校园网外访问乐乎论坛失败时的统一提示。
///
/// 论坛在校园网外完全不可达，且失败是静默的（连接挂起或立即拒绝），
/// 直接说明网络环境问题比让用户等待数十秒超时更有用。
const campusNetworkRequiredMessage = '当前网络无法访问乐乎论坛，请连接校园网后重试，'
    '或在「账号管理」中开启 WebVPN。';

class CampusReachabilityResult {
  const CampusReachabilityResult({required this.status});

  final CampusReachabilityStatus status;

  /// 明确判定为不可达时才为 true。
  bool get isUnreachable => status == CampusReachabilityStatus.unreachable;
}

/// 探测校园站点在**直连**（未开启 WebVPN）下的可达性。
///
/// 用于在真正发起登录前判断用户是否处于校园网环境，避免在非校园网下
/// 把账号密码、二步验证码依次交给学校认证服务之后，才在最后的业务系统
/// 回调上耗尽超时并给出模糊的「会话建立超时」。
///
/// 判定只看连接层结果：域名解析失败、连接被拒、建连超时都算不可达；
/// **HTTP 状态码不作为依据**——论坛在校园网外是即时连接失败，而教务入口
/// 在校外仍会返回 301/403，用状态码判断会把后者误判成不可达。
class CampusReachabilityService {
  const CampusReachabilityService({
    this.timeout = HttpTimeout.probe,
    @visibleForTesting CampusReachabilityProbe? probe,
  }) : _probe = probe;

  /// 单个站点的探测超时。
  final Duration timeout;

  final CampusReachabilityProbe? _probe;

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[SHU_REACHABILITY] $message');
  }

  /// 论坛直连入口。
  ///
  /// 论坛是本项目唯一在校园网外**完全不可达**的业务系统：校外访问会立即
  /// 连接失败，而教务系统、统一认证在校外仍可访问，因此只有论坛入口能
  /// 可靠地反映「是否处于校园网环境」。
  static final Uri directForumUri =
      Uri.parse('${ForumConstants.baseUrl}/auth/oauth2_basic');

  /// 探测论坛直连是否可达（WebVPN 模式下论坛走代理，不适用）。
  ///
  /// 失败时不重试：探测会阻断用户操作，而校外访问论坛的典型表现正是
  /// 立即失败，自动复测只会让用户多等一个超时周期；探测允许误报，
  /// 由调用方提供「仍然尝试」作为人工重试通道。
  Future<CampusReachabilityResult> checkDirectForum() async {
    final probe = _probe;
    if (probe != null) {
      return _classify(() async {
        final reachable = await probe(directForumUri).timeout(timeout);
        return CampusReachabilityResult(
          status: reachable
              ? CampusReachabilityStatus.reachable
              : CampusReachabilityStatus.unreachable,
        );
      });
    }
    final client = HttpClient()..connectionTimeout = timeout;
    if (defaultTargetPlatform == TargetPlatform.android) {
      client.badCertificateCallback = (certificate, host, port) {
        return CertificatePolicy.allowsHost(host);
      };
    }
    try {
      return await _classify(() async {
        // connectionTimeout 只覆盖建连阶段；这里再为整个探测设置上限，
        // 避免连接成功但响应头/响应体迟迟不结束时一直卡住登录入口。
        return await (() async {
          final request = await client.getUrl(directForumUri);
          request.followRedirects = false;
          final response = await request.close();
          await response.drain<void>();
          return const CampusReachabilityResult(
            status: CampusReachabilityStatus.reachable,
          );
        })()
            .timeout(timeout);
      });
    } finally {
      client.close(force: true);
    }
  }

  /// 把连接层异常统一映射为可达性结论。
  ///
  /// 只有解析失败、连接被拒、建连超时能证明网络不可达；其余（证书、
  /// 协议错误等）说明网络本身已连通，归为 [CampusReachabilityStatus.unknown]，
  /// 避免界面据此误导用户切换网络。
  Future<CampusReachabilityResult> _classify(
    Future<CampusReachabilityResult> Function() request,
  ) async {
    try {
      final result = await request();
      _debug('probe ${directForumUri.host} → ${result.status.name}');
      return result;
    } on TimeoutException catch (error) {
      _debug('probe timeout: $error');
      return const CampusReachabilityResult(
        status: CampusReachabilityStatus.unreachable,
      );
    } on SocketException catch (error) {
      // 域名解析失败或连接被拒绝，即校园网外访问论坛的典型表现。
      _debug('probe failed: $error');
      return const CampusReachabilityResult(
        status: CampusReachabilityStatus.unreachable,
      );
    } on HandshakeException catch (error) {
      // TLS 已开始握手说明网络本身连通，证书问题不属于可达性范畴。
      _debug('probe handshake: $error');
      return const CampusReachabilityResult(
        status: CampusReachabilityStatus.reachable,
      );
    } on Object catch (error) {
      _debug('probe unknown: $error');
      return const CampusReachabilityResult(
        status: CampusReachabilityStatus.unknown,
      );
    }
  }
}
