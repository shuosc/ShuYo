import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/certificate_policy.dart';
import 'package:shuyo/core/forum_url_resolver.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    ForumUrlResolver.configure(useWebVpn: false);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('${platform.name} allows only the direct forum certificate exception',
        () {
      debugDefaultTargetPlatformOverride = platform;
      ForumUrlResolver.configure(useWebVpn: false);
      expect(CertificatePolicy.allowsHost('bbs.shu.edu.cn'), isTrue);
      for (final host in [
        'oauth.shu.edu.cn',
        'newsso.shu.edu.cn',
        'webvpn.shu.edu.cn',
        'bbs.shu.edu.cn.example.com',
      ]) {
        expect(CertificatePolicy.allowsHost(host), isFalse);
      }
      ForumUrlResolver.configure(useWebVpn: true);
      expect(CertificatePolicy.allowsHost('bbs.shu.edu.cn'), isFalse);
      expect(
          CertificatePolicy.allowsHost(ForumUrlResolver.webVpnHost), isFalse);
    });
  }
}
