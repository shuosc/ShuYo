/// 企业微信扫码登录相关的固定参数。
///
/// 数值来源于上海大学统一身份认证（newsso）前端 bundle 中的企微
/// `WwLogin` SDK 渲染参数。若学校侧变更，需要同步更新这里。
class WeComConstants {
  const WeComConstants._();

  /// 上海大学企业微信自建应用 appid。
  static const appId = 'wxa8dea949443de641';

  /// 上海大学企业微信自建应用 agentid。
  static const agentId = '1000059';

  /// 企微扫码确认回调地址（newsso 侧的 /oauth/wecom/qrcode）。
  static const redirectUri = 'https://newsso.shu.edu.cn/oauth/wecom/qrcode';

  /// 企微扫码会话页面（返回 HTML，内嵌 `qrImg?key=<key>`）。
  static const qrConnectBase =
      'https://open.work.weixin.qq.com/wwopen/sso/qrConnect';

  /// 扫码后企微客户端打开的确认页地址。
  static const confirmBase =
      'https://open.work.weixin.qq.com/wwopen/sso/confirm2';

  /// 扫码状态长轮询地址（JSONP）。
  static const longPollBase =
      'https://open.work.weixin.qq.com/wwopen/sso/l/qrConnect';

  /// 企微客户端协议：在企微内拉起内置浏览器打开指定 URL。
  ///
  /// 来源：企微官方 confirm2 页面内联脚本，原文为
  /// `launchWWByScheme("wxwork://sso/jump?url=" + encodeURIComponent(confirm2_url))`。
  static const schemeJumpBase = 'wxwork://sso/jump?url=';

  /// Open SHU's campus-card application in WeCom. The user then chooses
  /// account recharge inside the school application.
  static const campusCardAppScheme =
      'wxwork://jump?target=jump_to_third_app&businessid=5629500339709576';

  /// 承载企微扫码会话的域名，用于构造正确的 Referer/Origin。
  static const weComHost = 'open.work.weixin.qq.com';

  /// 统一身份认证（SSO）站点，`authorize` 与业务系统回调都在这里。
  static const ssoBase = 'https://newsso.shu.edu.cn';

  /// WebVPN OAuth 握手使用的固定端点。
  static const webVpnBase = 'https://webvpn.shu.edu.cn';
  static const webVpnCallback = '$webVpnBase/callback/oauth2';
  static const webVpnLanding = '$webVpnBase/site-nav/';
  static const webVpnNewssoProxyHost =
      'https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn';
  static const webVpnExternalIdFallback = 'YJrvSXWl';

  /// OAuth 授权端点路径。
  static const authorizePath = '/oauth/authorize';

  /// SSO 判定「未登录」时跳转的登录页路径片段。
  static const loginPathMarker = '/oauth2/login/';

  /// SSO 会话 Cookie 名。
  static const sessionCookieName = 'SHU_OAUTH2';
}

/// 现有两阶段扫码流程的静态授权目标。YJS 由门户动态提供授权地址。
class WeComOAuthTarget {
  const WeComOAuthTarget({
    required this.kind,
    required this.clientId,
    required this.clientName,
    required this.scope,
    required this.redirectUri,
    this.generateState = false,
  });

  /// 本科生教务系统（jwxt）：授权请求不带 state，需自行生成随机值防 CSRF。
  static const academic = WeComOAuthTarget(
    kind: WeComOAuthTargetKind.academic,
    clientId: 'Km5t225E8KECKQ6ZDm5K2P6aS2459Cua',
    clientName: '本科生教务系统',
    scope: 'jw',
    redirectUri: 'https://jwxt.shu.edu.cn/sso/shulogin',
    generateState: true,
  );

  /// WebVPN 需要在 OAuth 授权后调用 `auth/finish`，不能按通用
  /// callback 流程处理。
  static const webVpn = WeComOAuthTarget(
    kind: WeComOAuthTargetKind.webVpn,
    clientId: 'nn7sbb22j2tKE100T024tEp42777p755',
    clientName: 'WebVPN 访问控制系统',
    scope: '',
    redirectUri: WeComConstants.webVpnCallback,
  );

  static const there = WeComOAuthTarget(
    kind: WeComOAuthTargetKind.there,
    clientId: 'eDrd-M0i0WoSWRxk7ShDC1n-fbS7jRvi',
    clientName: '图书馆预约',
    scope: '1',
    redirectUri: 'https://there.shu.edu.cn/login-oauth2',
  );

  static const campusCard = WeComOAuthTarget(
    kind: WeComOAuthTargetKind.campusCard,
    clientId: 'WUHWfrntnWYHZfzQ5QvXUCVy',
    clientName: '校园卡查询',
    scope: '1',
    redirectUri: 'https://eportal.shu.edu.cn/login',
  );

  final WeComOAuthTargetKind kind;

  final String clientId;
  final String clientName;
  final String scope;
  final String redirectUri;

  /// 为 true 时由本地生成随机 state。
  final bool generateState;

  /// 供 [WeComAuthService.encodeOAuthParams] 编码为 `state` 的原始参数。
  Map<String, String> toParams() => {
        'responseType': 'code',
        'clientId': clientId,
        'clientName': clientName,
        'scope': scope,
        'redirectUri': redirectUri,
        'state': '',
      };
}

enum WeComOAuthTargetKind { academic, webVpn, there, campusCard }
