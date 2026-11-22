import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/wecom_constants.dart';
import 'package:shuyo/data/services/wecom_auth_service.dart';

void main() {
  group('WeComAuthService', () {
    test('scan timeout defaults to 90 seconds', () {
      expect(WeComAuthService.scanTimeout, const Duration(seconds: 90));
    });

    test('scan deadline expires even when a request is still pending',
        () async {
      final client = _PendingHttpClient();
      final service = WeComAuthService(httpClient: client);
      addTearDown(() {
        client.finishPendingRequest();
        service.dispose();
      });
      final statuses = <WeComScanStatus>[];

      final result = await service
          .waitForScan(
            'test-key',
            timeout: const Duration(milliseconds: 50),
            onStatusChanged: statuses.add,
          )
          .timeout(const Duration(seconds: 2));

      expect(client.requestStarted, isTrue);
      expect(result.status, WeComScanStatus.expired);
      expect(statuses, [WeComScanStatus.expired]);
    });

    test('OAuth redirect diagnostics never include authorization values', () {
      final callback = Uri.parse(
        'https://there.shu.edu.cn/login-oauth2?code=SECRET_CODE&state=SECRET_STATE',
      );
      final login = Uri.parse(
        'https://newsso.shu.edu.cn/oauth2/login/SECRET_CONTEXT',
      );
      final graduateCallback = Uri.parse(
        'https://yjs.shu.edu.cn/gsapp/sys/yjsrzfwapp/oauth_shu/callback/SECRET_FLOW.do?code=SECRET_CODE&state=SECRET_STATE',
      );
      final callbackLog = WeComAuthService.describeUrlForLog(callback);
      final loginLog = WeComAuthService.describeUrlForLog(login);
      expect(callbackLog, contains('login-oauth2'));
      expect(callbackLog, contains('queryKeys=[code, state]'));
      expect(callbackLog, isNot(contains('SECRET_CODE')));
      expect(callbackLog, isNot(contains('SECRET_STATE')));
      expect(loginLog, contains('/oauth2/login/{context}'));
      expect(loginLog, isNot(contains('SECRET_CONTEXT')));
      expect(WeComAuthService.describeUrlForLog(graduateCallback),
          isNot(contains('SECRET_')));
    });

    test('encodeOAuthParams produces base64url without padding', () {
      final encoded = WeComAuthService.encodeOAuthParams({
        'responseType': 'code',
        'clientId': 'abc',
      });
      // base64url (no + / = chars)
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
      expect(encoded, isNot(contains('=')));
      // Can be decoded back (normalize restores the stripped padding)
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      expect(decoded['responseType'], 'code');
      expect(decoded['clientId'], 'abc');
    });

    test('encodeOAuthParams handles Chinese text (ensureAscii=false)', () {
      final encoded = WeComAuthService.encodeOAuthParams({
        'clientName': '本科生教务系统',
      });
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      expect(decoded['clientName'], '本科生教务系统');
    });

    test('parseStatus maps QRCODE_SCAN_SUCC with auth_code to success',
        () async {
      // WeComScanResult 的静态构造器行为：
      expect(
        const WeComScanResult.succeeded('abc123').isSuccess,
        true,
      );
      expect(const WeComScanResult.succeeded('abc123').authCode, 'abc123');
    });

    test('the default QR context encodes the academic client', () {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(
          WeComAuthService.weComRedeemState,
        ))),
      );
      expect(decoded['clientId'], 'Km5t225E8KECKQ6ZDm5K2P6aS2459Cua');
      expect(decoded['scope'], 'jw');
      expect(WeComAuthService.weComRedeemState, isNot(contains('=')));
      expect(WeComAuthService.weComRedeemState, isNot(contains('+')));
      expect(WeComAuthService.weComRedeemState, isNot(contains('/')));
    });

    test('WeComSessionResult carries the SSO session cookies', () {
      final result = WeComSessionResult(
        sessionCookies: [Cookie('SHU_OAUTH2', 'session')],
        cookieSourceUri:
            Uri.parse('https://newsso.shu.edu.cn/oauth/wecom/qrcode'),
      );
      expect(result.sessionCookies.single.name, 'SHU_OAUTH2');
      expect(result.cookieSourceUri.host, 'newsso.shu.edu.cn');
    });

    test('WebVPN state uses standard padded base64', () {
      final state = WeComAuthService.webVpnState('YJrvSXWl');
      expect(state, endsWith('=='));
      expect(
        jsonDecode(utf8.decode(base64Decode(state))),
        {'externalId': 'YJrvSXWl'},
      );
    });

    test('unproxies only the trusted WebVPN newsso authorize host', () {
      final direct = WeComAuthService.directWebVpnAuthorizeUri(
        'https://https-newsso-shu-edu-cn-443.webvpn.shu.edu.cn/oauth/authorize?client_id=x',
      );
      expect(direct.host, 'newsso.shu.edu.cn');
      expect(direct.path, '/oauth/authorize');
      expect(direct.queryParameters['client_id'], 'x');
      expect(
        () => WeComAuthService.directWebVpnAuthorizeUri(
          'https://example.com/oauth/authorize',
        ),
        throwsA(isA<WeComAuthException>()),
      );
    });

    test('WebVPN device id is stable and uses 32 lowercase hex digits',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = WeComAuthService(random: Random(7));
      addTearDown(service.dispose);

      final first = await service.loadWebVpnDeviceId();
      final second = await service.loadWebVpnDeviceId();

      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(second, first);
    });
  });

  test('uses the supplied QR context and returns the SSO redirect untouched',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = WeComAuthService(
      httpClient:
          _LoopbackHttpClient(Uri.parse('http://127.0.0.1:${server.port}')),
    );
    addTearDown(() async {
      service.dispose();
      await server.close(force: true);
    });
    final visited = <Uri>[];
    server.listen((request) async {
      visited.add(request.uri);
      final response = request.response;
      if (request.uri.path.endsWith('/qrConnect')) {
        response.write('<img src="/qrImg?key=a1b2c3">');
      } else if (request.uri.path == '/oauth/wecom/qrcode') {
        response.statusCode = HttpStatus.found;
        response.cookies
            .add(Cookie('SHU_OAUTH2', 'fixture-session')..path = '/');
        response.headers.set(HttpHeaders.locationHeader,
            '/oauth/authorize?state=fixture-oauth-state');
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final session = await service.startQrSession(state: 'graduate-context');
    final result = await service.redeem('fixture-code', session.state);
    expect(session.state, 'graduate-context');
    expect(visited.map((uri) => uri.path), [
      '/wwopen/sso/qrConnect',
      '/oauth/wecom/qrcode',
    ]);
    expect(visited.map((uri) => uri.queryParameters['state']),
        ['graduate-context', 'graduate-context']);
    expect(
        result.redirectUri,
        Uri.https('newsso.shu.edu.cn', '/oauth/authorize', {
          'state': 'fixture-oauth-state',
        }));
    expect(result.sessionCookies.single.name, 'SHU_OAUTH2');
  });

  group('OAuth authorization state', () {
    const serverState = 'SERVER_STATE+/_=';
    late HttpServer server;
    late WeComAuthService service;
    Uri? requestedUri;
    var echoState = true;
    var duplicateState = false;
    String? responseState;

    setUp(() async {
      requestedUri = null;
      echoState = true;
      duplicateState = false;
      responseState = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requestedUri = request.uri;
        final state =
            echoState ? request.uri.queryParameters['state'] : responseState;
        final callback = Uri.parse(request.uri.queryParameters['redirect_uri']!)
            .replace(queryParameters: {
          'code': 'TEST_CODE',
          if (state != null) 'state': state,
        });
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          duplicateState
              ? '$callback&state=${Uri.encodeQueryComponent(state!)}'
              : callback.toString(),
        );
        await request.response.close();
      });
      service = WeComAuthService(
        httpClient:
            _LoopbackHttpClient(Uri.parse('http://127.0.0.1:${server.port}')),
      );
    });

    tearDown(() async {
      service.dispose();
      await server.close(force: true);
    });

    test('forwards and validates the exact booking bootstrap state', () async {
      final callback = await service.authorizeTarget(
        WeComOAuthTarget.there,
        state: serverState,
      );
      expect(requestedUri?.path, '/oauth/authorize');
      expect(requestedUri?.queryParameters['state'], serverState);
      expect(requestedUri?.queryParameters['client_id'],
          WeComOAuthTarget.there.clientId);
      expect(callback.queryParameters['state'], serverState);
    });

    for (final entry in <String, String?>{
      'missing': null,
      'mismatched': 'OTHER_STATE',
    }.entries) {
      test('rejects a ${entry.key} callback state', () async {
        echoState = false;
        responseState = entry.value;
        await expectLater(
          service.authorizeTarget(WeComOAuthTarget.there, state: serverState),
          throwsA(isA<WeComAuthException>().having(
            (error) => error.code,
            'code',
            'authorizationStateMismatch',
          )),
        );
      });
    }

    test('rejects duplicate callback state parameters', () async {
      duplicateState = true;
      await expectLater(
        service.authorizeTarget(WeComOAuthTarget.there, state: serverState),
        throwsA(isA<WeComAuthException>().having(
          (error) => error.code,
          'code',
          'authorizationStateMismatch',
        )),
      );
    });

    test('keeps the academic target local state generation', () async {
      final callback = await service.authorizeTarget(WeComOAuthTarget.academic);
      final state = requestedUri?.queryParameters['state'];
      expect(state, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(callback.queryParameters['state'], state);
    });
  });

  group('WeComOAuthTarget', () {
    test('academic target encodes the jwxt client', () {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(
          WeComAuthService.encodeOAuthParams(
              WeComOAuthTarget.academic.toParams()),
        ))),
      );
      expect(decoded['clientId'], 'Km5t225E8KECKQ6ZDm5K2P6aS2459Cua');
      expect(decoded['clientName'], '本科生教务系统');
      expect(decoded['scope'], 'jw');
      expect(decoded['redirectUri'], 'https://jwxt.shu.edu.cn/sso/shulogin');
      expect(decoded['responseType'], 'code');
      expect(decoded['state'], '');
    });

    test('WebVPN target uses its dedicated OAuth client', () {
      expect(WeComOAuthTarget.webVpn.kind, WeComOAuthTargetKind.webVpn);
      expect(
        WeComOAuthTarget.webVpn.clientId,
        'nn7sbb22j2tKE100T024tEp42777p755',
      );
      expect(
        WeComOAuthTarget.webVpn.redirectUri,
        'https://webvpn.shu.edu.cn/callback/oauth2',
      );
    });

    test('academic state is generated locally', () {
      expect(WeComOAuthTarget.academic.generateState, isTrue);
    });
  });
}

class _PendingHttpClient implements HttpClient {
  final _request = Completer<HttpClientRequest>();
  bool requestStarted = false;

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requestStarted = true;
    return _request.future;
  }

  void finishPendingRequest() {
    if (!_request.isCompleted) {
      _request.completeError(const HttpException('Request cancelled in test'));
    }
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Routes the real authorization request to a local HTTP server in tests.
class _LoopbackHttpClient implements HttpClient {
  _LoopbackHttpClient(this.baseUri);

  final Uri baseUri;
  final HttpClient _client = HttpClient();

  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _client.getUrl(baseUri.replace(path: url.path, query: url.query));

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
