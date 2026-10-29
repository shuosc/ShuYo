import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/vod_url_resolver.dart';

void main() {
  tearDown(() => VodUrlResolver.configure(useWebVpn: false));

  test('API transport follows the selected connection with explicit override',
      () {
    VodUrlResolver.configure(useWebVpn: true);
    final proxied = VodUrlResolver.apiUri('/v1/currentuser');
    expect(proxied.host, VodUrlResolver.webVpnHost);
    expect(proxied.path, '/jy-application-resourcemanage/v1/currentuser');
    expect(VodUrlResolver.apiUri('/v1/currentuser', useWebVpn: false).host,
        VodUrlResolver.directHost);
    expect(() => VodUrlResolver.apiUri('https://example.com'),
        throwsArgumentError);
  });

  test('OAuth adapter returns to its own platform login on the same transport',
      () {
    final authorize = VodUrlResolver.authorizeUri(useWebVpn: true);
    expect(authorize.host, VodUrlResolver.webVpnHost);
    expect(authorize.path, '/jy-application-resourcemanage/oauth2/authorize');
    expect(authorize.queryParameters['json'], '0');
    final callback = Uri.parse(authorize.queryParameters['returnUri']!);
    expect(callback.host, VodUrlResolver.webVpnHost);
    expect(callback.queryParameters['type'], 'cas');
    expect(callback.fragment, isEmpty);
    expect(callback.path, '/jy-application-resourcemanage-ui/');
    expect(authorize.fragment, isEmpty);
  });

  test('credential-bearing APIs require the exact HTTPS host, port and path',
      () {
    expect(
        VodUrlResolver.isBusinessUri(Uri.parse(
            'https://vod.cc.shu.edu.cn/jy-application-resourcemanage/v1/currentuser')),
        isTrue);
    for (final value in [
      'http://vod.cc.shu.edu.cn/jy-application-resourcemanage/v1/currentuser',
      'https://vod.cc.shu.edu.cn.evil.example/jy-application-resourcemanage/v1/currentuser',
      'https://vod.cc.shu.edu.cn:444/jy-application-resourcemanage/v1/currentuser',
      'https://vod.cc.shu.edu.cn/jy-application-resourcemanage-evil/token',
      'https://vod.cc.shu.edu.cn/media.mp4',
    ]) {
      expect(VodUrlResolver.isBusinessUri(Uri.parse(value)), isFalse,
          reason: value);
    }
  });

  test('gateway media rewriting preserves signed query and nonstandard port',
      () {
    const source =
        'https://vrmvod.cc.shu.edu.cn:40443/vod/a.mp4?auth_key=a%2Fb%2Bc&x=1&x=2';
    final mapped = VodUrlResolver.resolveMediaUrl(source, useWebVpn: true);
    expect(mapped.host, VodUrlResolver.mediaWebVpnHost);
    expect(mapped.port, 443);
    expect(mapped.query, 'auth_key=a%2Fb%2Bc&x=1&x=2');
    expect(
        VodUrlResolver.resolveMediaUrl(source, useWebVpn: false).port, 40443);
  });

  test('foreign media and unsafe login origins are refused', () {
    for (final url in [
      'https://example.com/recording.mp4',
      'http://vod.cc.shu.edu.cn/a.mp4',
      'https://name:password@vod.cc.shu.edu.cn/a.mp4',
    ]) {
      expect(() => VodUrlResolver.resolveMediaUrl(url), throwsFormatException);
    }
    expect(
        VodUrlResolver.isAllowedLoginUri(
            Uri.parse('https://newsso.shu.edu.cn/oauth2/login/test')),
        isTrue);
    expect(
        VodUrlResolver.isAllowedLoginUri(
            Uri.parse('https://newsso.shu.edu.cn.evil.example/login')),
        isFalse);
  });

  test('live RTC transport preserves stream path and signed query', () {
    const source =
        'https://rtc.cc.shu.edu.cn:32001/nmserv/server:32007/hls/live/channel/session/live.m3u8?account_token=a%2Fb%2Bc&x=1&x=2';
    final direct = VodUrlResolver.resolveMediaUrl(source, useWebVpn: false);
    final proxied = VodUrlResolver.resolveMediaUrl(source, useWebVpn: true);
    expect(direct.host, VodUrlResolver.liveHost);
    expect(direct.port, 32001);
    expect(proxied.host, VodUrlResolver.liveWebVpnHost);
    expect(proxied.port, 443);
    expect(proxied.path, direct.path);
    expect(proxied.query, direct.query);
    expect(VodUrlResolver.isProxiedMediaUri(proxied), isTrue);
    expect(VodUrlResolver.isProxiedMediaUri(direct), isFalse);
    expect(
        () => VodUrlResolver.resolveMediaUrl(proxied.toString(),
            useWebVpn: false),
        throwsFormatException);
    for (final source in [
      'https://rtc.cc.shu.edu.cn/live.m3u8',
      'https://rtc.cc.shu.edu.cn:32002/live.m3u8',
      'http://rtc.cc.shu.edu.cn:32001/live.m3u8',
      'https://rtc.cc.shu.edu.cn.evil.example:32001/live.m3u8',
      'https://user:pass@rtc.cc.shu.edu.cn:32001/live.m3u8',
      'https://https-rtc-cc-shu-edu-cn-32001.webvpn.shu.edu.cn:444/live.m3u8',
    ]) {
      expect(
          () => VodUrlResolver.resolveMediaUrl(source), throwsFormatException);
    }
  });
}
