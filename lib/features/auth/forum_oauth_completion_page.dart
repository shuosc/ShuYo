import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../core/certificate_policy.dart';
import '../../core/client_user_agent.dart';
import '../../core/forum_url_resolver.dart';
import '../../data/services/campus_reachability_service.dart';
import '../../data/services/discourse_api_client.dart';
import '../../data/services/forum_auth_service.dart';
import '../../data/services/http_timeout.dart';

enum ForumOAuthCompletionResult { loggedIn }

@visibleForTesting
bool isForumRegistrationUri(Uri uri) {
  if (uri.scheme != 'https' ||
      !ForumUrlResolver.isActiveForumHost(uri.host.toLowerCase())) {
    return false;
  }
  return uri.path == '/login';
}

@visibleForTesting
bool isForumRegistrationCompletionUri(Uri uri) {
  if (uri.scheme != 'https' ||
      !ForumUrlResolver.isActiveForumHost(uri.host.toLowerCase())) {
    return false;
  }
  final path = uri.path.toLowerCase();
  return path == '/' || path == '/latest' || path == '/latest/';
}

@visibleForTesting
bool isAuthenticatedForumCallbackCookie(String value) {
  var decoded = value;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      decoded = Uri.decodeComponent(decoded);
    } on FormatException {
      break;
    }
  }
  try {
    final data = jsonDecode(decoded);
    return data is Map && data['authenticated'] == true;
  } on Object {
    return false;
  }
}

bool _isForumRegistrationFlowUri(Uri uri) {
  if (uri.scheme != 'https' ||
      !ForumUrlResolver.isActiveForumHost(uri.host.toLowerCase())) {
    return false;
  }
  final path = uri.path.toLowerCase();
  return path == '/login' ||
      path == '/u/account-created' ||
      path.startsWith('/signup') ||
      path.startsWith('/register') ||
      path.contains('/complete-registration');
}

class ForumOAuthCompletionPage extends StatefulWidget {
  const ForumOAuthCompletionPage({
    super.key,
    required this.callbackUri,
  });

  final Uri callbackUri;

  @override
  State<ForumOAuthCompletionPage> createState() =>
      _ForumOAuthCompletionPageState();
}

class _ForumOAuthCompletionPageState extends State<ForumOAuthCompletionPage> {
  static const _sessionProbeChannel = 'ForumSessionProbe';

  late final WebViewController _controller;
  final _authService = ForumAuthService();
  Timer? _sessionPollTimer;
  Timer? _timeoutTimer;
  Timer? _certificateErrorTimer;
  bool _completed = false;
  bool _checkingSession = false;
  bool _forumReached = false;
  bool _callbackFinished = false;
  final Set<String> _replacedNavigationUrls = {};
  bool _registrationActive = false;
  bool _registrationCompletionReached = false;
  bool _webViewProbeInFlight = false;
  bool _finalizingWebViewSession = false;
  Timer? _webViewProbeTimeout;
  Uri? _currentUri;
  String? _error;
  int _certificateErrorGeneration = 0;
  int _webVpnLoginRedirectCount = 0;
  final String _status = '正在建立乐乎论坛会话';

  static const _reachabilityService = CampusReachabilityService();

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setUserAgent(ClientUserAgent.mobileBrowser)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _currentUri = Uri.tryParse(url);
            _handleNavigation(url, event: 'started');
          },
          onPageFinished: (url) {
            if (!_replacedNavigationUrls.contains(url)) {
              _replacedNavigationUrls.clear();
            }
            _currentUri = Uri.tryParse(url);
            _handleNavigation(url, event: 'finished');
            unawaited(_checkSession());
          },
          onNavigationRequest: (request) {
            if (request.isMainFrame) {
              _currentUri = Uri.tryParse(request.url);
            }
            if (kDebugMode) {
              final uri = Uri.tryParse(request.url);
              debugPrint(
                '[FORUM_AUTH_CALLBACK] navigation-request '
                '${uri == null ? request.url : _describeUri(uri)}',
              );
            }
            return _handleNavigationRequest(request);
          },
          // Both mobile platforms use the same host-scoped certificate policy.
          onSslAuthError: CertificatePolicy.supportsForumException
              ? _handleSslAuthError
              : null,
          onHttpError: _handleHttpError,
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            // Replacing the direct OAuth callback with its WebVPN URL cancels
            // the original WebKit navigation. These are cancellation signals,
            // not failures of the replacement page.
            if (_consumeReplacedNavigationError(error)) {
              return;
            }
            final failedUrl = error.url ?? _currentUri?.toString();
            final failedUri =
                failedUrl == null ? null : Uri.tryParse(failedUrl);
            if (CertificatePolicy.allowsUri(failedUri)) {
              _deferCertificateError(error.description);
              return;
            }
            unawaited(
              _failWithNetworkHint('论坛登录会话建立失败：${error.description}'),
            );
          },
        ),
      );
    unawaited(_start());
  }

  @override
  void dispose() {
    _sessionPollTimer?.cancel();
    _timeoutTimer?.cancel();
    _certificateErrorTimer?.cancel();
    _webViewProbeTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _registrationActive || _error != null,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_registrationActive ? '设置论坛昵称' : '乐乎论坛账户'),
          actions: [
            if (!_registrationActive && _error == null)
              IconButton(
                tooltip: '取消登录',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _webView()),
            if (!_registrationActive || _error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: _error == null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 24),
                            const Text(
                              '正在完成登录',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(_status, textAlign: TextAlign.center),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 44,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(height: 18),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(height: 1.5),
                            ),
                            const SizedBox(height: 24),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('返回'),
                            ),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _webView() {
    final webView = WebViewWidget(controller: _controller);
    if (_registrationActive) return webView;
    return IgnorePointer(
      child: Opacity(opacity: 0.01, child: webView),
    );
  }

  Future<void> _start() async {
    await _configureAndroidWebView();
    await _controller.addJavaScriptChannel(
      _sessionProbeChannel,
      onMessageReceived: _handleSessionProbeMessage,
    );
    if (!mounted) return;
    if (kDebugMode) {
      debugPrint(
        '[FORUM_AUTH_CALLBACK] load-start '
        '${_describeUri(widget.callbackUri)}',
      );
    }
    await _controller.loadRequest(widget.callbackUri);
    _sessionPollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => unawaited(_checkSession()),
    );
    _armCompletionTimeout();
  }

  Future<void> _configureAndroidWebView() async {
    final platform = _controller.platform;
    if (platform is! AndroidWebViewController) return;
    if (kDebugMode) {
      await AndroidWebViewController.enableDebugging(true);
    }
    final cookieManager = WebViewCookieManager().platform;
    if (cookieManager is AndroidWebViewCookieManager) {
      await cookieManager.setAcceptThirdPartyCookies(platform, true);
    }
  }

  void _handleNavigation(String value, {required String event}) {
    final uri = Uri.tryParse(value);
    if (uri == null || _completed) return;
    _clearCertificateError();
    if (kDebugMode) {
      debugPrint(
        '[FORUM_AUTH_CALLBACK] event=$event ${_describeUri(uri)} '
        'queryKeys=${uri.queryParameters.keys.toList()..sort()} '
        'message=${uri.queryParameters['message'] ?? '-'} '
        'strategy=${uri.queryParameters['strategy'] ?? '-'}',
      );
    }
    if (_isForumRegistrationFlowUri(uri)) {
      if (!_registrationActive && mounted) {
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        setState(() => _registrationActive = true);
      }
    }
    if (_registrationActive && isForumRegistrationCompletionUri(uri)) {
      if (!_registrationCompletionReached) {
        _registrationCompletionReached = true;
        _armCompletionTimeout();
      }
      if (kDebugMode) {
        debugPrint(
          '[FORUM_AUTH_CALLBACK] registration-complete-candidate '
          '${_describeUri(uri)}',
        );
      }
    }
    if (ForumUrlResolver.isKnownForumHost(uri.host.toLowerCase())) {
      _forumReached = true;
      if (event == 'finished' &&
          (uri.path == '/auth/oauth2_basic/callback' ||
              isForumRegistrationCompletionUri(uri))) {
        _callbackFinished = true;
      }
      if (uri.path.startsWith('/auth/failure') ||
          (uri.path == '/auth/oauth2_basic/callback' &&
              uri.queryParameters.containsKey('error'))) {
        _fail('乐乎论坛拒绝了本次登录，请返回后重试');
      }
    }
  }

  String _describeUri(Uri uri) {
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final replacement =
        uri == null ? null : ForumUrlResolver.resolveOAuthNavigation(uri);
    if (request.isMainFrame && replacement != null) {
      _replacedNavigationUrls.add(request.url);
      unawaited(_loadReplacementNavigation(replacement));
      return NavigationDecision.prevent;
    }
    if (uri != null &&
        request.isMainFrame &&
        _isRepeatedWebVpnLoginRedirect(uri)) {
      _webVpnLoginRedirectCount++;
      if (_webVpnLoginRedirectCount >= 2) {
        _fail('WebVPN登录凭证未能传递到论坛，请返回后重试');
        return NavigationDecision.prevent;
      }
    }
    if (uri != null && _isInternalWebViewScheme(uri.scheme)) {
      return NavigationDecision.navigate;
    }
    if (uri != null && uri.scheme == 'https' && _isAllowedHost(uri.host)) {
      return NavigationDecision.navigate;
    }
    if (request.isMainFrame) {
      _fail('认证页面尝试跳转到非上海大学地址');
    }
    return NavigationDecision.prevent;
  }

  Future<void> _loadReplacementNavigation(Uri uri) async {
    try {
      await _controller.loadRequest(uri);
    } on Object {
      _fail('无法加载论坛认证页面，请返回后重试');
    }
  }

  bool _consumeReplacedNavigationError(WebResourceError error) {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        (error.errorCode != -999 && error.errorCode != 102) ||
        _replacedNavigationUrls.isEmpty) {
      return false;
    }
    // WebKit sometimes omits the failing URL. Consume at most one expected
    // cancellation; an unrelated URL must still follow normal error handling.
    return _replacedNavigationUrls.remove(
      error.url ?? _replacedNavigationUrls.first,
    );
  }

  bool _isRepeatedWebVpnLoginRedirect(Uri uri) {
    if (!ForumUrlResolver.usesWebVpn || !_forumReached) return false;
    final portalHost = Uri.parse(ForumUrlResolver.webVpnPortalUrl).host;
    if (uri.host.toLowerCase() != portalHost) return false;
    return uri.queryParameters.containsKey('returnUrl') ||
        uri.path == '/' ||
        uri.path.startsWith('/auth/login');
  }

  void _handleHttpError(HttpResponseError error) {
    final status = error.response?.statusCode;
    if (kDebugMode) {
      debugPrint('[FORUM_AUTH_CALLBACK] http-error status=$status');
    }
    final current = _currentUri;
    final failed = error.request?.uri ?? error.response?.uri ?? current;
    if (status == null ||
        status < 400 ||
        current == null ||
        failed == null ||
        failed.host != current.host ||
        failed.path != current.path) {
      return;
    }
    if (!ForumUrlResolver.isKnownForumHost(current.host) ||
        current.path != '/auth/oauth2_basic/callback') {
      return;
    }
    _fail('论坛登录页面返回错误（HTTP $status），请稍后重试');
  }

  void _handleSslAuthError(SslAuthError error) {
    // Use the challenged host, never the page URL: a subresource may belong
    // to a different host from the currently displayed forum page.
    final uri = _sslErrorUri(error);
    if (kDebugMode) {
      debugPrint(
        '[FORUM_AUTH_CALLBACK] ssl-error '
        'host=${uri?.host ?? 'unknown'} description=${error.platform.description}',
      );
    }
    if (CertificatePolicy.allowsUri(uri)) {
      _clearCertificateError();
      if (kDebugMode) {
        debugPrint('[FORUM_AUTH_CALLBACK] allowing expired forum certificate '
            '${uri?.host}');
      }
      error.proceed();
      return;
    }
    error.cancel();
  }

  void _deferCertificateError(String description) {
    _certificateErrorTimer?.cancel();
    final generation = ++_certificateErrorGeneration;
    _certificateErrorTimer = Timer(const Duration(seconds: 3), () {
      if (_completed || !mounted || generation != _certificateErrorGeneration) {
        return;
      }
      _clearCertificateError();
      _fail('论坛登录会话建立失败：$description');
    });
  }

  void _clearCertificateError() {
    _certificateErrorTimer?.cancel();
    _certificateErrorTimer = null;
    _certificateErrorGeneration++;
  }

  Uri? _sslErrorUri(SslAuthError error) {
    final platform = error.platform;
    if (platform is AndroidSslAuthError) {
      return Uri.tryParse(platform.url);
    }
    if (platform is WebKitSslAuthError) {
      return Uri(scheme: 'https', host: platform.host, port: platform.port);
    }
    return null;
  }

  Future<void> _checkSession() async {
    if (_completed || _error != null || _checkingSession || !_forumReached) {
      return;
    }
    _checkingSession = true;
    try {
      // While the user is completing first-time forum registration, do not
      // issue native API requests. Those requests can rotate _forum_session
      // and write it back into the WebView while the registration page is
      // still using its own session. Ask the active WebView instead so the
      // browser and the registration form share exactly one cookie jar.
      if (_registrationActive) {
        if (!_registrationCompletionReached) return;
        await _checkWebViewSession();
        return;
      }
      if (ForumUrlResolver.usesWebVpn) {
        if (!_callbackFinished) return;
        await _checkWebViewSession();
        return;
      }
      await _authService.refreshFromWebView();
      final apiClient = DiscourseApiClient(authService: _authService);
      final session = await apiClient.getJson('/session/current.json');
      if (kDebugMode) {
        debugPrint(
          '[FORUM_AUTH_CALLBACK] session response '
          'currentUser=${session['current_user'] is Map}',
        );
      }
      if (session['current_user'] is Map) {
        await _authService.persistLastCookieHeader();
        _finish(ForumOAuthCompletionResult.loggedIn);
      }
    } on ForumAuthException {
      // The callback can finish setting cookies a moment after navigation.
    } on ForumApiException catch (error) {
      if (kDebugMode) debugPrint('[FORUM_AUTH_CALLBACK] session: $error');
    } on Object catch (error) {
      if (kDebugMode) debugPrint('[FORUM_AUTH_CALLBACK] session: $error');
    } finally {
      _checkingSession = false;
    }
  }

  Future<void> _checkWebViewSession() async {
    if (_webViewProbeInFlight) return;
    _webViewProbeInFlight = true;
    _webViewProbeTimeout?.cancel();
    _webViewProbeTimeout = Timer(const Duration(seconds: 5), () {
      _webViewProbeInFlight = false;
    });
    try {
      await _controller.runJavaScript('''
(async function() {
  if (window.location.origin !== ${jsonEncode(ForumUrlResolver.baseUrl)}) return;
  try {
    const response = await fetch('/session/current.json', {credentials: 'include'});
    const body = await response.text();
    let currentUser = false;
    try {
      const session = JSON.parse(body);
      currentUser = !!(session && typeof session.current_user === 'object' && session.current_user !== null);
    } catch (_) {}
    $_sessionProbeChannel.postMessage(JSON.stringify({
      status: response.status,
      currentUser: currentUser,
      url: window.location.origin + window.location.pathname
    }));
  } catch (error) {
    $_sessionProbeChannel.postMessage(JSON.stringify({
      status: 0,
      currentUser: false,
      url: window.location.origin + window.location.pathname
    }));
  }
})()
''');
    } on Object catch (error) {
      _webViewProbeInFlight = false;
      if (kDebugMode) {
        debugPrint('[FORUM_AUTH_CALLBACK] webview session probe: $error');
      }
    }
  }

  void _handleSessionProbeMessage(JavaScriptMessage message) {
    _webViewProbeInFlight = false;
    _webViewProbeTimeout?.cancel();
    _webViewProbeTimeout = null;
    if (_completed ||
        _error != null ||
        !mounted ||
        (ForumUrlResolver.usesWebVpn && !_callbackFinished) ||
        (!ForumUrlResolver.usesWebVpn &&
            (!_registrationActive || !_registrationCompletionReached))) {
      return;
    }
    Map<String, dynamic>? payload;
    try {
      final value = jsonDecode(message.message);
      if (value is Map) {
        payload = value.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint(
            '[FORUM_AUTH_CALLBACK] invalid webview session probe: $error');
      }
      return;
    }
    if (payload == null) return;
    final uri = Uri.tryParse(payload['url']?.toString() ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        uri.scheme != 'https' ||
        uri.origin != ForumUrlResolver.baseUri.origin) {
      return;
    }
    final status = payload['status'];
    final currentUser = payload['currentUser'] == true;
    if (kDebugMode) {
      debugPrint(
        '[FORUM_AUTH_CALLBACK] webview session '
        'status=$status currentUser=$currentUser '
        'url=${payload['url'] ?? '-'}',
      );
    }
    if (status != 200 || !currentUser || _finalizingWebViewSession) return;
    _finalizingWebViewSession = true;
    unawaited(_completeWebViewSession());
  }

  void _armCompletionTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(
      HttpTimeout.oauthCompletion,
      () => unawaited(
        _failWithNetworkHint('建立乐乎论坛登录会话超时，请返回后重新登录'),
      ),
    );
  }

  Future<void> _completeWebViewSession() async {
    try {
      // A JavaScript channel's payload is page-controlled. Also check the
      // actual top-level document before importing its browser session.
      final current = Uri.tryParse(await _controller.currentUrl() ?? '');
      if (!mounted ||
          _completed ||
          _error != null ||
          current == null ||
          !current.hasAuthority ||
          current.scheme != 'https' ||
          current.origin != ForumUrlResolver.baseUri.origin) {
        _finalizingWebViewSession = false;
        return;
      }
      await _authService.refreshFromWebView();
      await _authService.persistLastCookieHeader();
      _finish(ForumOAuthCompletionResult.loggedIn);
    } on Object catch (error) {
      _finalizingWebViewSession = false;
      if (kDebugMode) {
        debugPrint('[FORUM_AUTH_CALLBACK] finalize webview session: $error');
      }
    }
  }

  void _finish(ForumOAuthCompletionResult result) {
    if (_completed || _error != null || !mounted) return;
    _completed = true;
    _sessionPollTimer?.cancel();
    _timeoutTimer?.cancel();
    Navigator.of(context).pop(result);
  }

  /// 报错前先确认是否为校园网环境问题。
  ///
  /// 非校园网下论坛完全不可达：WebView 可能一直挂到超时（静默丢包），
  /// 也可能只给出「net::ERR_NAME_NOT_RESOLVED」之类的底层描述。
  /// 先探测一次论坛直连可达性，才能给出可操作的提示。
  Future<void> _failWithNetworkHint(String fallback) async {
    if (_completed || !mounted || _error != null) return;
    final unreachable = await _isForumDirectUnreachable();
    _fail(unreachable ? campusNetworkRequiredMessage : fallback);
  }

  Future<bool> _isForumDirectUnreachable() async {
    if (ForumUrlResolver.usesWebVpn) return false;
    final result = await _reachabilityService.checkDirectForum();
    return result.isUnreachable;
  }

  void _fail(String message) {
    if (_completed || !mounted || _error != null) return;
    _sessionPollTimer?.cancel();
    _timeoutTimer?.cancel();
    setState(() => _error = message);
  }

  bool _isAllowedHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'shu.edu.cn' || normalized.endsWith('.shu.edu.cn');
  }

  bool _isInternalWebViewScheme(String scheme) {
    return scheme == 'about' ||
        scheme == 'data' ||
        scheme == 'blob' ||
        scheme == 'javascript';
  }
}
