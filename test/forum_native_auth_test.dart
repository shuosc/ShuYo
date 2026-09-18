import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/features/auth/forum_oauth_completion_page.dart';
import 'package:shuyo/features/auth/forum_registration_placeholder_page.dart';
import 'package:shuyo/data/services/forum_auth_service.dart';
import 'package:shuyo/core/forum_url_resolver.dart';

void main() {
  setUp(() => ForumUrlResolver.configure(useWebVpn: true));
  tearDown(() => ForumUrlResolver.configure(useWebVpn: false));
  test('cached forum cookies survive a partial WebView cookie restore', () {
    final merged = ForumAuthService.mergeCookieHeaders(
      'webvpn-token=old; _t=forum-session; _forum_session=discourse',
      'webvpn-token=new',
    );

    expect(merged, contains('webvpn-token=new'));
    expect(merged, contains('_t=forum-session'));
    expect(merged, contains('_forum_session=discourse'));
    expect(merged, isNot(contains('webvpn-token=old')));
  });

  group('forum OAuth callback', () {
    test('accepts direct and WebVPN callback hosts', () {
      expect(
        AcademicNativeAuthService.isForumOAuthCallback(
          Uri.parse(
            'https://bbs.shu.edu.cn/auth/oauth2_basic/callback?code=x&state=y',
          ),
        ),
        isTrue,
      );
      expect(
        AcademicNativeAuthService.isForumOAuthCallback(
          Uri.parse(
            'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/auth/oauth2_basic/callback?code=x&state=y',
          ),
        ),
        isTrue,
      );
    });

    test('rejects incomplete or external callbacks', () {
      expect(
        AcademicNativeAuthService.isForumOAuthCallback(
          Uri.parse(
            'https://bbs.shu.edu.cn/auth/oauth2_basic/callback?code=x',
          ),
        ),
        isFalse,
      );
      expect(
        AcademicNativeAuthService.isForumOAuthCallback(
          Uri.parse(
            'https://example.com/auth/oauth2_basic/callback?code=x&state=y',
          ),
        ),
        isFalse,
      );
    });
  });

  test('recognizes the exact registration route for both access modes', () {
    expect(
      isForumRegistrationUri(
        Uri.parse(
          'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/login',
        ),
      ),
      isTrue,
    );
    expect(
      isForumRegistrationUri(
        Uri.parse(
          'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/signup',
        ),
      ),
      isFalse,
    );
    ForumUrlResolver.configure(useWebVpn: false);
    expect(
      isForumRegistrationUri(
        Uri.parse('https://bbs.shu.edu.cn/login'),
      ),
      isTrue,
    );
  });

  test('recognizes registration completion forum routes', () {
    expect(
      isForumRegistrationCompletionUri(
        Uri.parse(
          'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/',
        ),
      ),
      isTrue,
    );
    expect(
      isForumRegistrationCompletionUri(
        Uri.parse(
          'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/latest?order=default',
        ),
      ),
      isTrue,
    );
    expect(
      isForumRegistrationCompletionUri(
        Uri.parse('https://bbs.shu.edu.cn/latest'),
      ),
      isFalse,
    );
    expect(
      isForumRegistrationCompletionUri(
        Uri.parse(
          'https://https-bbs-shu-edu-cn-443.webvpn.shu.edu.cn/categories',
        ),
      ),
      isFalse,
    );
    ForumUrlResolver.configure(useWebVpn: false);
    expect(
      isForumRegistrationCompletionUri(
        Uri.parse('https://bbs.shu.edu.cn/latest'),
      ),
      isTrue,
    );
  });

  testWidgets('registration placeholder does not submit an API request',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ForumRegistrationPlaceholderPage()),
    );

    expect(find.text('设置论坛昵称'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '完成注册'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ShuYoUser');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '完成注册'));
    await tester.pump();

    expect(find.text('论坛注册接口暂未接入'), findsOneWidget);
  });
}
