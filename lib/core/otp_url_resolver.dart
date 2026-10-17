/// Endpoints and transport for the school dynamic password token
/// (`https://otp.shu.edu.cn/`).
///
/// The transport is a process-wide switch, exactly like
/// `ClassroomUrlResolver`: the WebVPN setting decides it once and every client
/// reads the same value, so a page opened before the setting changed picks up
/// the new transport on its next request instead of needing a new client.
class OtpUrlResolver {
  const OtpUrlResolver._();

  /// Token site root; the logged-in root already renders the code.
  static const directHost = 'otp.shu.edu.cn';

  /// WebVPN gateway host that reverse-proxies [directHost].
  static const webVpnHost = 'https-otp-shu-edu-cn-443.webvpn.shu.edu.cn';

  /// OAuth client registered for the token system.
  static const clientId = '05Q1L8woQK5350aK1U5o5GKh411ar3h1';

  /// The doubled slash is the value registered with the server; do not tidy it.
  static const redirectUri = 'https://otp.shu.edu.cn//Callback.aspx';

  static const scope = 'read write';

  /// Landing page the callback falls through to.
  static const landingPath = '/Default.aspx';

  static bool _usesWebVpn = false;

  static bool get usesWebVpn => _usesWebVpn;

  static void configure({required bool useWebVpn}) {
    _usesWebVpn = useWebVpn;
  }

  /// Host that actually answers for the token site on this transport.
  static String get host => usesWebVpn ? webVpnHost : directHost;

  static Uri get baseUri => Uri.parse('https://$host/');

  static Uri get landingUri => Uri.parse('https://$host$landingPath');

  /// Maps a direct service URL onto the gateway host when WebVPN is on.
  ///
  /// The gateway keeps paths, but a doubled leading slash confuses it, so the
  /// registered `//Callback.aspx` is normalized while its meaning is preserved.
  static Uri mapServiceUri(Uri direct) {
    if (!usesWebVpn || direct.host != directHost) return direct;
    final path = direct.path.startsWith('//')
        ? direct.path.replaceFirst(RegExp(r'^/+'), '/')
        : direct.path;
    return direct.replace(host: webVpnHost, path: path);
  }
}
