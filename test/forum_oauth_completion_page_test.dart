import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/forum_url_resolver.dart';
import 'package:shuyo/features/auth/forum_oauth_completion_page.dart';
// The platform interface is intentionally used directly by this test harness.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebViewPlatform webViewPlatform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ForumUrlResolver.configure(useWebVpn: true);
    webViewPlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = webViewPlatform;
  });

  tearDown(() => ForumUrlResolver.configure(useWebVpn: false));

  testWidgets('completes only after a valid authenticated forum session',
      (tester) async {
    final callbackUri = _forumUri('/auth/oauth2_basic/callback');
    final result = await _pushCompletionPage(tester, callbackUri);

    webViewPlatform.navigationDelegate.onPageFinished!(
      callbackUri.toString(),
    );
    await tester.pump();
    webViewPlatform.controller.sendJavaScriptMessage(
      'ForumSessionProbe',
      jsonEncode({
        'status': 200,
        'currentUser': false,
        'url': _forumUri('/latest').toString(),
      }),
    );
    webViewPlatform.controller.sendJavaScriptMessage(
      'ForumSessionProbe',
      jsonEncode({
        'status': 200,
        'currentUser': true,
        'url': 'https://example.com/latest',
      }),
    );
    await tester.pump();

    expect(result.value, isNull);
    expect(find.byType(ForumOAuthCompletionPage), findsOneWidget);
    expect(webViewPlatform.controller.executedJavaScript, isNotEmpty);
    // Even a forged forum URL must not complete a different document.
    await webViewPlatform.controller.loadRequest(
      LoadRequestParams(uri: Uri.parse('https://newsso.shu.edu.cn/')),
    );
    webViewPlatform.controller.sendJavaScriptMessage(
      'ForumSessionProbe',
      jsonEncode({
        'status': 200,
        'currentUser': true,
        'url': _forumUri('/latest').toString(),
      }),
    );
    await tester.pump();
    expect(result.value, isNull);
    await webViewPlatform.controller
        .loadRequest(LoadRequestParams(uri: callbackUri));
    webViewPlatform.controller.sendJavaScriptMessage(
      'ForumSessionProbe',
      jsonEncode({
        'status': 200,
        'currentUser': true,
        'url': _forumUri('/latest').toString(),
      }),
    );
    await tester.pumpAndSettle();
    expect(result.value, ForumOAuthCompletionResult.loggedIn);
    expect(find.byType(ForumOAuthCompletionPage), findsNothing);
  });

  testWidgets('ignores an authenticated probe after the deadline fails',
      (tester) async {
    final callbackUri = _forumUri('/auth/oauth2_basic/callback');
    final result = await _pushCompletionPage(tester, callbackUri);

    webViewPlatform.navigationDelegate.onPageFinished!(
      callbackUri.toString(),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 45));
    await tester.pump();

    expect(find.text('建立乐乎论坛登录会话超时，请返回后重新登录'), findsOneWidget);

    webViewPlatform.controller.sendJavaScriptMessage(
      'ForumSessionProbe',
      jsonEncode({
        'status': 200,
        'currentUser': true,
        'url': _forumUri('/latest').toString(),
      }),
    );
    await tester.pump();

    expect(result.value, isNull);
    expect(find.text('建立乐乎论坛登录会话超时，请返回后重新登录'), findsOneWidget);
  });

  testWidgets('ignores subresource errors but fails on a callback HTTP 500',
      (tester) async {
    final callbackUri = _forumUri('/auth/oauth2_basic/callback');
    final result = await _pushCompletionPage(tester, callbackUri);

    webViewPlatform.navigationDelegate.onPageStarted!(callbackUri.toString());
    final sessionUri = _forumUri('/session/current.json');
    webViewPlatform.navigationDelegate.onHttpError!(
      HttpResponseError(
        request: WebResourceRequest(uri: sessionUri),
        response: WebResourceResponse(uri: sessionUri, statusCode: 404),
      ),
    );
    await tester.pump();
    expect(find.textContaining('HTTP 404'), findsNothing);
    webViewPlatform.navigationDelegate.onHttpError!(
      HttpResponseError(
        request: WebResourceRequest(uri: callbackUri),
        response: WebResourceResponse(uri: callbackUri, statusCode: 500),
      ),
    );
    await tester.pump();

    expect(find.text('论坛登录页面返回错误（HTTP 500），请稍后重试'), findsOneWidget);
    expect(result.value, isNull);
  });

  testWidgets('a finished replacement cannot hide a later URL-less error',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final callbackUri = _forumUri('/auth/oauth2_basic/callback');
      final result = await _pushCompletionPage(tester, callbackUri);
      webViewPlatform.navigationDelegate.onNavigationRequest!(
        NavigationRequest(
          url:
              'https://bbs.shu.edu.cn/auth/oauth2_basic/callback?code=c&state=s',
          isMainFrame: true,
        ),
      );
      await tester.pump();
      webViewPlatform
          .navigationDelegate.onPageFinished!(callbackUri.toString());
      webViewPlatform.navigationDelegate.onWebResourceError!(
        WebResourceError(
          errorCode: -999,
          description: 'Unexpected cancellation',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.textContaining('Unexpected cancellation'), findsOneWidget);
      expect(result.value, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final errorCode in <int>[102, -999]) {
    testWidgets(
      'ignores iOS $errorCode from an expected callback rewrite',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final initialUri = _forumUri('/auth/oauth2_basic/callback');
          final directCallbackUri = Uri.parse(
            'https://bbs.shu.edu.cn/auth/oauth2_basic/callback'
            '?code=authorization-code&state=forum-state',
          );
          final proxiedCallbackUri = _forumUri(
            '/auth/oauth2_basic/callback'
            '?code=authorization-code&state=forum-state',
          );
          final result = await _pushCompletionPage(tester, initialUri);

          final decision =
              webViewPlatform.navigationDelegate.onNavigationRequest!(
            NavigationRequest(
              url: directCallbackUri.toString(),
              isMainFrame: true,
            ),
          );
          expect(decision, NavigationDecision.prevent);
          await tester.pump();
          expect(
            webViewPlatform.controller.loadedRequests.last.uri,
            proxiedCallbackUri,
          );
          webViewPlatform.navigationDelegate.onWebResourceError!(
            WebResourceError(
              errorCode: errorCode,
              description: 'Frame load interrupted',
              isForMainFrame: true,
              url: directCallbackUri.toString(),
            ),
          );
          await tester.pump();

          expect(find.textContaining('Frame load interrupted'), findsNothing);
          webViewPlatform.navigationDelegate.onPageStarted!(
            proxiedCallbackUri.toString(),
          );
          webViewPlatform.navigationDelegate.onPageFinished!(
            proxiedCallbackUri.toString(),
          );
          await tester.pump();
          webViewPlatform.controller.sendJavaScriptMessage(
            'ForumSessionProbe',
            jsonEncode({
              'status': 200,
              'currentUser': true,
              'url': _forumUri('/latest').toString(),
            }),
          );
          await tester.pumpAndSettle();

          expect(result.value, ForumOAuthCompletionResult.loggedIn);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

Uri _forumUri(String path) => Uri.parse('${ForumUrlResolver.baseUrl}$path');

Future<_ResultHolder> _pushCompletionPage(
  WidgetTester tester,
  Uri callbackUri,
) async {
  final result = _ResultHolder();
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (value) {
          context = value;
          return const SizedBox();
        },
      ),
    ),
  );
  Navigator.of(context)
      .push<ForumOAuthCompletionResult>(
        MaterialPageRoute(
          builder: (_) => ForumOAuthCompletionPage(callbackUri: callbackUri),
        ),
      )
      .then((value) => result.value = value);
  await tester.pump();
  await tester.pump();
  return result;
}

class _ResultHolder {
  ForumOAuthCompletionResult? value;
}

class _FakeWebViewPlatform extends WebViewPlatform {
  late final _FakeWebViewController controller;
  late final _FakeNavigationDelegate navigationDelegate;
  late final _FakeCookieManager cookieManager;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    controller = _FakeWebViewController(params);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    navigationDelegate = _FakeNavigationDelegate(params);
    return navigationDelegate;
  }

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    cookieManager = _FakeCookieManager(params);
    return cookieManager;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakeWebViewWidget(params);
  }
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  final List<LoadRequestParams> loadedRequests = [];
  final List<String> executedJavaScript = [];
  final Map<String, JavaScriptChannelParams> javaScriptChannels = {};
  PlatformNavigationDelegate? navigationDelegate;
  String? _currentUrl;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    navigationDelegate = handler;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    javaScriptChannels[params.name] = params;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedRequests.add(params);
    _currentUrl = params.uri.toString();
  }

  @override
  Future<String?> currentUrl() async => _currentUrl;

  @override
  Future<void> runJavaScript(String javaScript) async {
    executedJavaScript.add(javaScript);
  }

  void sendJavaScriptMessage(String channel, String message) {
    javaScriptChannels[channel]!.onMessageReceived(
      JavaScriptMessage(message: message),
    );
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  ProgressCallback? onProgress;
  WebResourceErrorCallback? onWebResourceError;
  UrlChangeCallback? onUrlChange;
  HttpAuthRequestCallback? onHttpAuthRequest;
  HttpResponseErrorCallback? onHttpError;
  SslAuthErrorCallback? onSslAuthError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {
    onNavigationRequest = callback;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    onPageStarted = callback;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    onPageFinished = callback;
  }

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {
    onProgress = callback;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback callback,
  ) async {
    onWebResourceError = callback;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async {
    onUrlChange = callback;
  }

  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback callback) async {
    onHttpAuthRequest = callback;
  }

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {
    onHttpError = callback;
  }

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback callback) async {
    onSslAuthError = callback;
  }
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager(super.params) : super.implementation();

  final Map<String, List<WebViewCookie>> cookiesByHost = {};

  @override
  Future<List<WebViewCookie>> getCookies(Uri uri) async =>
      cookiesByHost[uri.host] ?? const [];

  @override
  Future<void> setCookie(WebViewCookie cookie) async {
    cookiesByHost.putIfAbsent(cookie.domain, () => []).add(cookie);
  }
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
