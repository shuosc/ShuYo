import 'dart:io';

import 'certificate_policy.dart';

class ShuYoHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    if (CertificatePolicy.supportsForumException) {
      client.badCertificateCallback = (certificate, host, port) {
        return CertificatePolicy.allowsHost(host);
      };
    }
    return client;
  }
}
