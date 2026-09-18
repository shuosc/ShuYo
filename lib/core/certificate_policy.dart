import 'package:flutter/foundation.dart';

import 'forum_constants.dart';
import 'forum_url_resolver.dart';

class CertificatePolicy {
  const CertificatePolicy._();

  // Compatibility workaround until the campus forum renews its certificate.
  // Do not broaden this to OAuth or arbitrary hosts.
  static const allowInvalidForumCertificate =
      bool.fromEnvironment('LEHU_ALLOW_INVALID_FORUM_CERT', defaultValue: true);

  static bool get supportsForumException =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool allowsHost(String host) {
    return supportsForumException &&
        allowInvalidForumCertificate &&
        !ForumUrlResolver.usesWebVpn &&
        host.toLowerCase() == ForumConstants.host;
  }

  static bool allowsUri(Uri? uri) {
    return uri != null && allowsHost(uri.host);
  }
}
