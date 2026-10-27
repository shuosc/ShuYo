/// The recording platform's deployed application and identity entry points.
class VodConstants {
  const VodConstants._();

  static const directHost = 'vod.cc.shu.edu.cn';
  static const mediaHost = 'vrmvod.cc.shu.edu.cn';
  static const casHost = 'vrm.cc.shu.edu.cn';
  static const casLoginPath = '/jy-cas-proxy/cas/login';
  static const casCallbackPath =
      '/jy-cas-proxy/proxy/callback/e32f2571e22e412daec4a52e7b1b4ce3';
  static const mediaPort = 40443;
  static const apiPath = '/jy-application-resourcemanage';
  static const uiPath = '/jy-application-resourcemanage-ui';
  static const jwtStorageKey =
      'jy-application-resourcemanage-ui_STORAGE_KEY_JWT_TOKEN';
  static const directSessionKey = 'vod.auth.session.direct.v1';
  static const webVpnSessionKey = 'vod.auth.session.webvpn.v1';
}
