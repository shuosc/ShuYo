import 'academic_constants.dart';

class AcademicUrlResolver {
  const AcademicUrlResolver._();

  static const webVpnHost = 'https-jwxt-shu-edu-cn-443.webvpn.shu.edu.cn';
  static const webVpnBaseUrl = 'https://$webVpnHost';
  static const homePath = '/jwglxt/xtgl/index_initMenu.html';

  // The academic system is publicly reachable. WebVPN is deliberately kept
  // out of the academic route so classroom transport changes cannot
  // invalidate the timetable session.
  static bool get usesWebVpn => false;

  static String get baseUrl => AcademicConstants.baseUrl;

  static Uri get baseUri => Uri.parse(baseUrl);

  static Uri get entryUri => Uri.parse('$baseUrl/');

  static Uri get studentIdentityUri => uri('$homePath?jsdm=xs&echarts=1');

  static Uri get homeUri {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return Uri.parse(
      '$baseUrl$homePath?jsdm=xs&_t=$timestamp&echarts=1',
    );
  }

  static Uri get scheduleIndexUri => uri(AcademicConstants.scheduleIndexPath);

  static bool isTicketLoginUrl(String value) {
    final uri = Uri.tryParse(value);
    const expectedHost = AcademicConstants.host;
    return uri != null &&
        uri.host == expectedHost &&
        uri.path.endsWith('/jwglxt/ticketlogin');
  }

  /// True when [value] is a jwxt page that an authenticated session reaches.
  ///
  /// `/jwglxt/ticketlogin` and `/jwglxt/xtgl/login_slogin.html` belong to the
  /// login exchange and answer with HTTP 200 even without a session, so
  /// neither may be mistaken for a working one.
  static bool isAcademicSessionUrl(String value) {
    final uri = Uri.tryParse(value);
    const expectedHost = AcademicConstants.host;
    if (uri == null || uri.host != expectedHost) {
      return false;
    }
    final path = uri.path;
    return path.startsWith('/jwglxt/') &&
        !path.endsWith('/jwglxt/ticketlogin') &&
        !path.endsWith('/jwglxt/xtgl/login_slogin.html');
  }

  static Uri uri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized');
  }
}
