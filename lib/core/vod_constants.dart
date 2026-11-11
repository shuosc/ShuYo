/// The recording platform's deployed application and identity entry points.
class VodConstants {
  const VodConstants._();

  static const directHost = 'vod.cc.shu.edu.cn';
  static const mediaHost = 'vrmvod.cc.shu.edu.cn';
  static const casHost = 'vrm.cc.shu.edu.cn';
  static const casLoginPath = '/jy-cas-proxy/cas/login';
  static const casCallbackPathPrefix = '/jy-cas-proxy/proxy/callback/';
  static final _casCallbackPathPattern =
      RegExp(r'^/jy-cas-proxy/proxy/callback/[a-fA-F0-9]{32}$');

  static bool isCasCallbackPath(String path) =>
      _casCallbackPathPattern.hasMatch(path);
  static const mediaPort = 40443;
  static const apiPath = '/jy-application-resourcemanage';
  static const uiPath = '/jy-application-resourcemanage-ui';
  static const jwtStorageKey =
      'jy-application-resourcemanage-ui_STORAGE_KEY_JWT_TOKEN';
  static const directSessionKey = 'vod.auth.session.direct.v1';
  static const webVpnSessionKey = 'vod.auth.session.webvpn.v1';
}
