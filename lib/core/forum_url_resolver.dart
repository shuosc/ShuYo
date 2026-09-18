import 'forum_constants.dart';
import 'wecom_constants.dart';

enum ForumAccessMode { direct, webVpn }

class ForumUrlResolver {
  const ForumUrlResolver._();

  static const webVpnPortalUrl = 'https://webvpn.shu.edu.cn';
  static const webVpnSiteNavUrl = 'https://webvpn.shu.edu.cn/site-nav/';
  static const webVpnSiteNavHomeUrl = 'https://webvpn.shu.edu.cn/site-nav/home';
  static const webVpnHost = 'https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn';
  static const webVpnBaseUrl = 'https://$webVpnHost';

  static ForumAccessMode _mode = ForumAccessMode.direct;

  static ForumAccessMode get mode => _mode;

  static bool get usesWebVpn => _mode == ForumAccessMode.webVpn;

  static String get baseUrl =>
      usesWebVpn ? webVpnBaseUrl : ForumConstants.baseUrl;

  static String get activeHost => usesWebVpn ? webVpnHost : ForumConstants.host;

  static Uri get baseUri => Uri.parse(baseUrl);

  static void configure({required bool useWebVpn}) {
    _mode = useWebVpn ? ForumAccessMode.webVpn : ForumAccessMode.direct;
  }

  static String resolve(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) {
      return resolve('https:$trimmed');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      return _resolveAbsoluteUri(uri).toString();
    }
    final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '$baseUrl$normalized';
  }

  static Uri uri(String pathOrUrl) {
    if (pathOrUrl.startsWith('http') || pathOrUrl.startsWith('//')) {
      return Uri.parse(resolve(pathOrUrl));
    }
    final normalized = pathOrUrl.startsWith('/') ? pathOrUrl : '/$pathOrUrl';
    return Uri.parse('$baseUrl$normalized');
  }

  static bool isActiveForumHost(String host) => host == activeHost;

  static bool isKnownForumHost(String host) =>
      host == ForumConstants.host || host == webVpnHost;

  /// Keep OAuth's registered redirect URI intact while fetching the actual
  /// callback through WebVPN. The gateway rewrites redirect_uri to its proxy,
  /// which breaks the forum's authorization-code exchange.
  static Uri? resolveOAuthNavigation(Uri uri) {
    if (!usesWebVpn || uri.scheme != 'https') return null;
    final target = WeComOAuthTarget.forum;
    final ssoHost = Uri.parse(WeComConstants.ssoBase).host;
    final ssoHosts = {
      ssoHost,
      WeComConstants.forumSsoHost,
      WeComConstants.forumWebVpnSsoHost,
      WeComConstants.webVpnNewssoProxyHost,
    };
    if (ssoHosts.contains(uri.host) &&
        uri.path == WeComConstants.authorizePath &&
        uri.queryParameters['client_id'] == target.clientId &&
        uri.queryParameters['response_type'] == 'code') {
      final callback = Uri.tryParse(uri.queryParameters['redirect_uri'] ?? '');
      if (callback == null ||
          callback.scheme != 'https' ||
          !isKnownForumHost(callback.host) ||
          callback.path != '/auth/oauth2_basic/callback') {
        return null;
      }
      final resolved = uri.replace(
        host: ssoHost,
        queryParameters: {
          ...uri.queryParameters,
          'redirect_uri': target.redirectUri,
        },
      );
      return resolved == uri ? null : resolved;
    }
    if (uri.host == ForumConstants.host &&
        uri.path == '/auth/oauth2_basic/callback' &&
        (uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('error')) &&
        uri.queryParameters.containsKey('state')) {
      return uri.replace(host: webVpnHost);
    }
    return null;
  }

  static Uri _resolveAbsoluteUri(Uri uri) {
    if (usesWebVpn && uri.host == ForumConstants.host) {
      return uri.replace(host: webVpnHost);
    }
    if (!usesWebVpn && uri.host == webVpnHost) {
      return uri.replace(host: ForumConstants.host);
    }
    return uri;
  }
}
