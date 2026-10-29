import 'vod_constants.dart';

/// Keeps the recording platform's transport separate from the academic login.
class VodUrlResolver {
  const VodUrlResolver._();

  static const directHost = VodConstants.directHost;
  static const webVpnHost = 'https-vod-cc-shu-edu-cn-443.webvpn.shu.edu.cn';
  static const mediaWebVpnHost =
      'https-vrmvod-cc-shu-edu-cn-40443.webvpn.shu.edu.cn';
  static const casWebVpnHost = 'https-vrm-cc-shu-edu-cn-443.webvpn.shu.edu.cn';
  static const liveHost = 'rtc.cc.shu.edu.cn';
  static const livePort = 32001;
  static const liveWebVpnHost =
      'https-rtc-cc-shu-edu-cn-32001.webvpn.shu.edu.cn';

  static bool _usesWebVpn = false;
  static bool get usesWebVpn => _usesWebVpn;

  static void configure({required bool useWebVpn}) {
    _usesWebVpn = useWebVpn;
  }

  static Uri baseUriFor({bool? useWebVpn}) => Uri(
        scheme: 'https',
        host: (useWebVpn ?? usesWebVpn) ? webVpnHost : directHost,
      );

  static Uri get baseUri => baseUriFor();

  static Uri apiUri(String path,
      {Map<String, String>? queryParameters, bool? useWebVpn}) {
    if (path.contains('://') || path.startsWith('//')) {
      throw ArgumentError.value(path, 'path', '需要录播平台内的接口路径');
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    return baseUriFor(useWebVpn: useWebVpn).replace(
      path: '${VodConstants.apiPath}$normalized',
      queryParameters: queryParameters,
    );
  }

  static Uri loginUri({bool? useWebVpn}) =>
      baseUriFor(useWebVpn: useWebVpn).replace(
        path: '${VodConstants.uiPath}/',
        fragment: '/login',
      );

  /// This is the platform's own OAuth adapter; newsso owns the following hops.
  static Uri authorizeUri({bool? useWebVpn}) {
    // The deployed frontend's HOME_PAGE_LOGIN is '/#/'. It sends the UI root
    // with type=cas, allowing the platform router to choose the login route.
    final returnUri = baseUriFor(useWebVpn: useWebVpn).replace(
      path: '${VodConstants.uiPath}/',
      queryParameters: {'type': 'cas'},
    );
    return apiUri('/oauth2/authorize', useWebVpn: useWebVpn, queryParameters: {
      'json': '0',
      'returnUri': returnUri.toString(),
    });
  }

  static bool isBusinessUri(Uri uri, {bool? useWebVpn}) {
    final base = baseUriFor(useWebVpn: useWebVpn);
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.host == base.host &&
        uri.port == base.port &&
        (uri.path == VodConstants.apiPath ||
            uri.path.startsWith('${VodConstants.apiPath}/'));
  }

  static bool isPlatformPage(Uri uri, {bool? useWebVpn}) {
    final base = baseUriFor(useWebVpn: useWebVpn);
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.host == base.host &&
        uri.port == base.port &&
        (uri.path == VodConstants.uiPath ||
            uri.path.startsWith('${VodConstants.uiPath}/'));
  }

  static bool isAllowedLoginUri(Uri uri) {
    if (uri.scheme != 'https' || uri.port != 443 || uri.userInfo.isNotEmpty) {
      return false;
    }
    return const {
      directHost,
      webVpnHost,
      VodConstants.casHost,
      casWebVpnHost,
      'newsso.shu.edu.cn',
      'oauth.shu.edu.cn',
      'webvpn.shu.edu.cn',
      'https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn',
      'https-oauth-shu-edu-cn-443.webvpn.shu.edu.cn',
    }.contains(uri.host);
  }

  /// Only known platform domains are mapped; paths and signed queries stay
  /// byte-for-byte in the URI rather than being decoded and reconstructed.
  static Uri mapServiceUri(Uri uri, {bool? useWebVpn}) {
    if (!(useWebVpn ?? usesWebVpn)) return uri;
    if (uri.scheme != 'https') return uri;
    if (uri.host == directHost && uri.port == 443) {
      return uri.replace(host: webVpnHost);
    }
    if (uri.host == VodConstants.casHost && uri.port == 443) {
      return uri.replace(host: casWebVpnHost);
    }
    if (uri.host == VodConstants.mediaHost &&
        uri.port == VodConstants.mediaPort) {
      return uri.replace(host: mediaWebVpnHost, port: 443);
    }
    if (uri.host == liveHost && uri.port == livePort) {
      return uri.replace(host: liveWebVpnHost, port: 443);
    }
    return uri;
  }

  static Uri resolveMediaUrl(String source, {bool? useWebVpn}) {
    final uri = Uri.tryParse(source);
    if (uri == null || !isKnownMediaUri(uri)) {
      throw const FormatException('录播媒体地址不属于已支持的平台域名');
    }
    final vpn = useWebVpn ?? usesWebVpn;
    if (!vpn &&
        (uri.host == webVpnHost ||
            uri.host == mediaWebVpnHost ||
            uri.host == liveWebVpnHost)) {
      throw const FormatException('录播媒体地址与当前连接方式不一致');
    }
    return mapServiceUri(uri, useWebVpn: vpn);
  }

  static bool isKnownMediaUri(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
    return (uri.host == directHost && uri.port == 443) ||
        (uri.host == VodConstants.mediaHost &&
            uri.port == VodConstants.mediaPort) ||
        (uri.host == liveHost && uri.port == livePort) ||
        (uri.host == webVpnHost && uri.port == 443) ||
        (uri.host == mediaWebVpnHost && uri.port == 443) ||
        (uri.host == liveWebVpnHost && uri.port == 443);
  }

  static bool isProxiedMediaUri(Uri uri) =>
      isKnownMediaUri(uri) &&
      (uri.host == webVpnHost ||
          uri.host == mediaWebVpnHost ||
          uri.host == liveWebVpnHost);
}
