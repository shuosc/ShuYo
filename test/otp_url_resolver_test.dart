import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/otp_url_resolver.dart';

void main() {
  tearDown(() => OtpUrlResolver.configure(useWebVpn: false));

  test('direct transport uses the public token host', () {
    OtpUrlResolver.configure(useWebVpn: false);

    expect(OtpUrlResolver.host, OtpUrlResolver.directHost);
    expect(OtpUrlResolver.baseUri.toString(), 'https://otp.shu.edu.cn/');
    expect(
      OtpUrlResolver.landingUri.toString(),
      'https://otp.shu.edu.cn/Default.aspx',
    );
  });

  test('WebVPN transport uses the gateway host', () {
    OtpUrlResolver.configure(useWebVpn: true);

    expect(OtpUrlResolver.host, OtpUrlResolver.webVpnHost);
    expect(
      OtpUrlResolver.baseUri.toString(),
      'https://https-otp-shu-edu-cn-443.webvpn.shu.edu.cn/',
    );
  });

  test('service URLs follow the gateway and keep their query', () {
    OtpUrlResolver.configure(useWebVpn: true);

    final mapped = OtpUrlResolver.mapServiceUri(
      Uri.parse(
        'https://otp.shu.edu.cn//Callback.aspx?code=abc&state=def',
      ),
    );

    expect(mapped.host, OtpUrlResolver.webVpnHost);
    expect(mapped.path, '/Callback.aspx');
    expect(mapped.queryParameters, {'code': 'abc', 'state': 'def'});
  });

  test('service URLs are untouched on the direct transport', () {
    OtpUrlResolver.configure(useWebVpn: false);
    final direct = Uri.parse('https://otp.shu.edu.cn//Callback.aspx?code=a');

    expect(OtpUrlResolver.mapServiceUri(direct), direct);
  });

  test('a foreign host never gets rewritten', () {
    OtpUrlResolver.configure(useWebVpn: true);

    final foreign = Uri.parse('https://example.com/Callback.aspx');

    expect(OtpUrlResolver.mapServiceUri(foreign), foreign);
  });
}
