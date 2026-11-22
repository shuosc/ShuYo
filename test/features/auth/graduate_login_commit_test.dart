import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/graduate_session_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/data/services/wecom_auth_service.dart';
import 'package:shuyo/features/auth/native_login_page.dart';
import 'package:shuyo/features/auth/wecom_scan_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SessionCookieJar.shared.resetForTesting();
  });
  tearDown(() => SessionCookieJar.shared.resetForTesting());

  for (final succeeds in [false, true]) {
    testWidgets(
        'YJS sign-in ${succeeds ? 'commits' : 'leaves the active account'}',
        (tester) async {
      final accounts = AcademicAccountStore();
      await accounts.saveStudentId('undergrad-fixture');
      await SessionCookieJar.shared.setCookie(SessionCookie(
        name: 'JSESSIONID',
        value: 'jwxt-fixture',
        domain: AcademicUrlResolver.baseUri.host,
      ));
      final auth = _GraduateAuth(succeeds: succeeds);
      var changes = 0;
      NativeLoginResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<NativeLoginResult>(
                MaterialPageRoute(
                  builder: (_) => NativeLoginPage(
                    destination: NativeLoginDestination.graduate,
                    authServiceFactory: () => auth,
                    onCampusAccountChange: (accountChanged, commit) async {
                      expect(accountChanged, isTrue);
                      expect(await accounts.loadSystem(),
                          CampusSystem.undergraduate);
                      expect(
                          await accounts.loadStudentId(), 'undergrad-fixture');
                      expect(auth.completed, isTrue);
                      changes++;
                      await commit();
                    },
                  ),
                ),
              );
            },
            child: const Text('登录'),
          );
        }),
      ));
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, '25800001');
      await tester.enterText(fields.last, 'fixture-pass');
      await tester.tap(find.widgetWithText(FilledButton, '继续'));
      await tester.pumpAndSettle();

      expect(changes, succeeds ? 1 : 0);
      expect(result, succeeds ? NativeLoginResult.authenticated : isNull);
      expect(await accounts.loadSystem(),
          succeeds ? CampusSystem.graduate : CampusSystem.undergraduate);
      expect(await accounts.loadStudentId(),
          succeeds ? '25800001' : 'undergrad-fixture');
      expect(await GraduateSessionStore().loadCookies(),
          hasLength(succeeds ? 1 : 0));
      expect(
          await SessionCookieJar.shared
              .getCookies(domain: AcademicUrlResolver.homeUri),
          hasLength(succeeds ? 0 : 1));
      if (!succeeds) expect(find.text('研究生系统需要重新登录'), findsOneWidget);
    });
  }

  for (final outcome in ['accepted', 'mismatched account', 'cancelled']) {
    testWidgets('YJS QR login: $outcome', (tester) async {
      final accounts = AcademicAccountStore();
      await accounts.saveStudentId('current-account');
      final auth = _GraduateAuth(succeeds: true);
      final weCom = _GraduateWeComAuth();
      final accepted = outcome == 'accepted';
      final cancelled = outcome == 'cancelled';
      var changes = 0;
      NativeLoginResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<NativeLoginResult>(
                MaterialPageRoute(
                  builder: (_) => NativeLoginPage(
                    destination: NativeLoginDestination.graduate,
                    expectedCampusAccount: outcome == 'mismatched account'
                        ? 'current-account'
                        : null,
                    authServiceFactory: () => auth,
                    weComAuthServiceFactory: () => weCom,
                    onCampusAccountChange: (accountChanged, commit) async {
                      expect(accountChanged, isTrue);
                      expect(await accounts.loadStudentId(), 'current-account');
                      expect(
                          await GraduateSessionStore().loadCookies(), isEmpty);
                      changes++;
                      await commit();
                    },
                  ),
                ),
              );
            },
            child: const Text('登录'),
          );
        }),
      ));
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      // The persisted account must come from YJS, never the text field.
      await tester.enterText(
          find.byType(TextFormField).first, 'current-account');
      await tester.tap(find.text('使用企业微信登录'));
      await tester.pumpAndSettle();
      final scanPage = find.byType(WeComScanPage);
      expect(scanPage, findsOneWidget);
      expect(weCom.requestedState, auth.qrChallenge?.state);
      expect(weCom.requestedState, isNotNull);
      if (cancelled) {
        Navigator.of(tester.element(scanPage)).pop();
      }
      weCom.scan.complete(const WeComScanResult.succeeded('test-code'));
      await tester.pumpAndSettle();

      expect(weCom.redeemedState, cancelled ? null : weCom.requestedState);
      expect(auth.completed, !cancelled);
      expect(changes, accepted ? 1 : 0);
      expect(result, accepted ? NativeLoginResult.authenticated : null);
      expect(await accounts.loadSystem(),
          accepted ? CampusSystem.graduate : CampusSystem.undergraduate);
      expect(await accounts.loadStudentId(),
          accepted ? 'verified-account' : 'current-account');
      expect(await GraduateSessionStore().loadCookies(),
          hasLength(accepted ? 1 : 0));
      if (outcome == 'mismatched account') {
        expect(find.text('登录账号须与当前校园账户一致'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

class _GraduateAuth implements AcademicNativeAuthService {
  _GraduateAuth({required this.succeeds});

  final bool succeeds;
  bool completed = false;
  _GraduateQrChallenge? qrChallenge;

  @override
  Future<AcademicLoginResult> login({
    required String username,
    required String password,
  }) async =>
      AcademicLoginResult(callbackUri: GraduateSessionStore.entryUri);

  @override
  Future<void> completeLogin(Uri callbackUri, {bool publish = true}) async {
    expect(qrChallenge, isNull, reason: 'A QR callback must not be reused');
    expect(publish, isFalse);
    if (!succeeds) {
      throw const AcademicNativeAuthException(
          'graduateLoginRequired', '研究生系统需要重新登录');
    }
    completed = true;
  }

  @override
  Future<String> readCampusAccount() async {
    expect(completed, isTrue);
    return '25800001';
  }

  @override
  Future<GraduateWeComChallenge> prepareGraduateWeComLogin() async =>
      qrChallenge = _GraduateQrChallenge();

  @override
  Future<String> completeGraduateWeComLogin(
    GraduateWeComChallenge challenge, {
    required Uri? redirectUri,
    required List<Cookie> ssoCookies,
  }) async {
    expect(challenge, same(qrChallenge));
    expect(redirectUri, _GraduateWeComAuth.callback);
    expect(ssoCookies.single.name, 'SHU_OAUTH2');
    completed = true;
    return 'verified-account';
  }

  @override
  Future<void> publishSessionCookies() async {
    expect(completed, isTrue);
    await SessionCookieJar.shared.setCookie(const SessionCookie(
      name: 'GS_SESSIONID',
      value: 'yjs-fixture',
      domain: GraduateSessionStore.host,
      path: '/gsapp/',
    ));
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GraduateQrChallenge extends Fake implements GraduateWeComChallenge {
  @override
  String get state => 'graduate-wecom-context';
}

class _GraduateWeComAuth extends WeComAuthService {
  static final callback = Uri.https(GraduateSessionStore.host, '/callback');
  final scan = Completer<WeComScanResult>();
  String? requestedState;
  String? redeemedState;

  @override
  Future<WeComQrSession> startQrSession({String? state}) async {
    requestedState = state;
    return WeComQrSession(
      key: 'test-key',
      state: state!,
      confirmUrl: 'https://example.invalid/confirm',
      wxWorkSchemeUrl: 'wxwork://test',
    );
  }

  @override
  Future<WeComScanResult> waitForScan(
    String key, {
    Duration timeout = WeComAuthService.scanTimeout,
    void Function(WeComScanStatus status)? onStatusChanged,
    bool Function()? isCancelled,
  }) =>
      scan.future;

  @override
  Future<WeComSessionResult> redeem(String authCode, String state) async {
    expect(authCode, 'test-code');
    redeemedState = state;
    return WeComSessionResult(
      sessionCookies: [Cookie('SHU_OAUTH2', 'fixture-sso')],
      cookieSourceUri: Uri.https('newsso.shu.edu.cn', '/oauth/wecom/qrcode'),
      redirectUri: callback,
    );
  }
}
