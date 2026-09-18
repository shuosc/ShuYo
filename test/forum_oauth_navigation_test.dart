import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/forum_url_resolver.dart';
import 'package:shuyo/core/wecom_constants.dart';

void main() {
  setUp(() => ForumUrlResolver.configure(useWebVpn: true));
  tearDown(() => ForumUrlResolver.configure(useWebVpn: false));

  Uri authorize({String? host, String? client, String? callback}) => Uri.https(
        host ?? WeComConstants.forumWebVpnSsoHost,
        '/oauth/authorize',
        {
          'client_id': client ?? WeComOAuthTarget.forum.clientId,
          'response_type': 'code',
          'redirect_uri': callback ??
              '${ForumUrlResolver.webVpnBaseUrl}/auth/oauth2_basic/callback',
          'state': 'forum-state+/=',
          'scope': '',
        },
      );

  test('preserves forum state while restoring the registered OAuth callback',
      () {
    final input = authorize();
    final result = ForumUrlResolver.resolveOAuthNavigation(input)!;
    expect(result.host, 'newsso.shu.edu.cn');
    expect(result.queryParameters['redirect_uri'],
        WeComOAuthTarget.forum.redirectUri);
    expect(result.queryParameters['state'], input.queryParameters['state']);
    expect(result.queryParameters['client_id'],
        input.queryParameters['client_id']);
    expect(ForumUrlResolver.resolveOAuthNavigation(result), isNull);
  });

  test(
      'loads the direct callback through WebVPN without changing code or state',
      () {
    for (final resultParameter in [
      {'code': 'one-time-code'},
      {'error': 'access_denied'},
    ]) {
      final callback = Uri.parse(WeComOAuthTarget.forum.redirectUri).replace(
        queryParameters: {...resultParameter, 'state': 'forum-state+/='},
      );
      final result = ForumUrlResolver.resolveOAuthNavigation(callback)!;
      expect(result.host, ForumUrlResolver.webVpnHost);
      expect(result.queryParameters, callback.queryParameters);
      expect(ForumUrlResolver.resolveOAuthNavigation(result), isNull);
    }
  });

  test('does not rewrite another service or an untrusted authorization host',
      () {
    expect(
        ForumUrlResolver.resolveOAuthNavigation(
            authorize(client: 'another-client')),
        isNull);
    expect(
        ForumUrlResolver.resolveOAuthNavigation(authorize(host: 'example.com')),
        isNull);
    expect(
        ForumUrlResolver.resolveOAuthNavigation(
            authorize(callback: 'https://example.com/callback')),
        isNull);
    expect(
        ForumUrlResolver.resolveOAuthNavigation(
            Uri.parse('https://bbs.shu.edu.cn/latest')),
        isNull);
    expect(
        ForumUrlResolver.resolveOAuthNavigation(
            Uri.parse(WeComOAuthTarget.forum.redirectUri)),
        isNull);
  });

  test('keeps direct access unchanged', () {
    ForumUrlResolver.configure(useWebVpn: false);
    expect(ForumUrlResolver.resolveOAuthNavigation(authorize()), isNull);
  });
}
