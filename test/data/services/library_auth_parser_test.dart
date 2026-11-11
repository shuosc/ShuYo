import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/library_auth_parser.dart';

// 取自真实的 tyrzfw.chaoxing.com/OAuth2/shu/init 响应（节选）。
const _initPage = r'''
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>跳转中...</title></head>
<body></body>
<script>
    /*let url = "https:\/\/newsso.shu.edu.cn\/oauth\/authorize?response_type=code\u0026redirect_uri=https:\/\/tyrzfw.chaoxing.com\/OAuth2\/shu\/index\u0026client_id=sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37";
    url = fullyDecodeURI(url);
    window.location = url;
    */

    window.location = "https:\/\/newsso.shu.edu.cn\/oauth\/authorize?response_type=code\u0026redirect_uri=https:\/\/tyrzfw.chaoxing.com\/OAuth2\/shu\/index\u0026client_id=sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37";
</script>
</html>
''';

// 取自真实的 /OAuth2/shu/index 响应（节选）。
const _callbackPage = r'''
<script>
    $(function () {
        var url = "\/OAuth2\/shu\/login";
        // var msg = null;
        var firstReferer = "https:\/\/findshu.libsp.cn\/find\/sso\/login\/shu\/0";
        var res = 0;
        jQuery.ajax({
            type: "get",
            url: url,
            async: false,
            data: {
                data: "",
                time: 1794298118289,
                enc: "B4FE9821886D77021390505D887FD0AC",
                displayName: null,
                userRole: 3
            },
            dataType: "json",
            success: function (data) {
                if (data.status) {
                    res = 2;
                }
            }
        });
        if (res == 2) {
            if (firstReferer) {
                // firstReferer = decodeURIComponent(firstReferer);
                window.location.href = firstReferer
            } else {
                window.location.href = 'https://i.chaoxing.com'
            }
        }
    });
</script>
''';

const _jwt =
    'eyJhbGciOiJIUzUxMiJ9.eyJzdWIiOiI0NDEyMjIiLCJleHAiOjE3OTQzODQ1MDB9.c2lnbmF0dXJl';

void main() {
  final base = Uri.parse('https://tyrzfw.chaoxing.com/OAuth2/shu/init');

  test('init page redirect ignores the commented-out copy', () {
    final target = LibraryAuthParser.parseJsRedirect(_initPage, base)!;
    expect(target.host, 'newsso.shu.edu.cn');
    expect(target.path, '/oauth/authorize');
    expect(target.queryParameters['response_type'], 'code');
    expect(target.queryParameters['client_id'],
        'sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37');
    expect(target.queryParameters['redirect_uri'],
        'https://tyrzfw.chaoxing.com/OAuth2/shu/index');
  });

  test('page without a redirect yields null', () {
    expect(LibraryAuthParser.parseJsRedirect('<html></html>', base), isNull);
  });

  test('callback page exposes the login parameters', () {
    final page = LibraryAuthParser.parseCallbackPage(_callbackPage)!;
    expect(page.loginPath, '/OAuth2/shu/login');
    expect(page.time, '1794298118289');
    expect(page.enc, 'B4FE9821886D77021390505D887FD0AC');
    expect(page.data, '');
    expect(page.displayName, '');
    expect(page.userRole, '3');
    expect(page.firstReferer, 'https://findshu.libsp.cn/find/sso/login/shu/0');
  });

  test('unrecognised callback page yields null', () {
    expect(LibraryAuthParser.parseCallbackPage('<html>网络错误</html>'), isNull);
  });

  test('extracts jwt from a hash redirect', () {
    final found = LibraryAuthParser.extractJwt(
        'https://findshu.libsp.cn/find/#/Home?jwt=$_jwt&jwtHeader=jwtOpacAuth')!;
    expect(found.jwt, _jwt);
    expect(found.header, 'jwtOpacAuth');
  });

  test('extracts jwt from the loginExternal route', () {
    final found = LibraryAuthParser.extractJwt(
        'https://findshu.libsp.cn/find/#/loginExternal/$_jwt/jwtOpacAuth')!;
    expect(found.jwt, _jwt);
    expect(found.header, 'jwtOpacAuth');
  });

  test('falls back to the default header name', () {
    final found = LibraryAuthParser.extractJwt('x?jwt=$_jwt')!;
    expect(found.header, 'jwtOpacAuth');
  });

  test('rejects values that are not JWT shaped', () {
    expect(
        LibraryAuthParser.extractJwt('?jwt=not-a-token&jwtHeader=a'), isNull);
    expect(LibraryAuthParser.extractJwt('nothing here'), isNull);
  });

  test('reads the expiry from the payload', () {
    expect(LibraryAuthParser.jwtExpiry(_jwt),
        DateTime.fromMillisecondsSinceEpoch(1794384500 * 1000));
    expect(LibraryAuthParser.jwtExpiry('garbage'), isNull);
  });

  test('extracts subject and payload from jwt', () {
    final payload = LibraryAuthParser.jwtPayload(_jwt)!;
    expect(payload['sub'], '441222');
    expect(payload['exp'], 1794384500);
    expect(LibraryAuthParser.jwtSubject(_jwt), '441222');
    expect(LibraryAuthParser.jwtSubject('garbage'), isNull);
  });
}
