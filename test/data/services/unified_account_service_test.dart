import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_auth_service.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/shu_sso_session_store.dart';
import 'package:shuyo/data/services/unified_account_service.dart';
import 'package:shuyo/data/services/wecom_auth_service.dart';

class _SessionStore extends ShuSsoSessionStore {
  _SessionStore(this.available);

  final bool available;
  int reads = 0;

  @override
  Future<List<({Cookie cookie, String domain, String path})>>
      sessionCookies() async {
    reads++;
    if (!available) return [];
    return [
      (
        cookie: Cookie('SHU_OAUTH2', 'session'),
        domain: 'newsso.shu.edu.cn',
        path: '/',
      ),
    ];
  }
}

class _BusinessSession extends AcademicAuthService {
  _BusinessSession(this.status)
      : super(cookieLoader: (_) async => [], cookieSetter: (_) async {});

  final WebVpnSessionStatus status;

  @override
  Future<WebVpnSessionStatus> validateWebVpnSession() async => status;
}

class _RejectedWebVpn extends WeComAuthService {
  @override
  Future<WeComRedeemResult> completeWebVpnLogin() async =>
      throw const WeComAuthException('webVpnFinishFailed', 'WebVPN 拒绝兑换');
}

class _RedeemWebVpn extends WeComAuthService {
  _RedeemWebVpn({this.fail = false, this.accountName});

  final bool fail;
  final String? accountName;
  int calls = 0;

  @override
  Future<WeComRedeemResult> completeWebVpnLogin() async {
    calls++;
    if (fail) throw const WeComAuthException('webVpnFinishFailed', '兑换失败');
    return WeComRedeemResult(
      callbackUri: Uri.parse('https://webvpn.shu.edu.cn/'),
      accountName: accountName,
      sessionCookies: [
        WeComStoredCookie(
          cookie: Cookie('webvpn-token', 'new'),
          domain: 'webvpn.shu.edu.cn',
          path: '/',
        ),
      ],
    );
  }
}

class _WebVpnInstaller extends AcademicNativeAuthService {
  _WebVpnInstaller() : super.forWebVpn();

  String? currentToken = 'old';
  String? pendingToken;
  final operations = <String>[];

  @override
  void adoptSessionCookies(
      Iterable<({Cookie cookie, String domain, String path})> cookies) {
    pendingToken = cookies.single.cookie.value;
    operations.add('adopt');
  }

  @override
  Future<void> resetPreviousSession() async {
    operations.add('reset');
    currentToken = null;
  }

  @override
  Future<void> publishSessionCookies() async {
    operations.add('publish');
    currentToken = pendingToken;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a valid business session needs no SSO authorization', () async {
    final sso = _SessionStore(false);
    var factories = 0;
    final account = UnifiedAccountService(
      ssoSessionStore: sso,
      academicAuthService: _BusinessSession(WebVpnSessionStatus.valid),
      weComAuthServiceFactory: () {
        factories++;
        return _RedeemWebVpn();
      },
    );
    expect(await account.recoverWebVpn(), WebVpnRecoveryOutcome.alreadyValid);
    expect(sso.reads, 0);
    expect(factories, 0);
    expect(await account.isWebVpnPendingRecovery(), isFalse);
  });

  test('forced recovery exchanges a valid portal session exactly once',
      () async {
    final sso = _SessionStore(true);
    final redeem = _RedeemWebVpn();
    final installer = _WebVpnInstaller();
    final account = UnifiedAccountService(
      ssoSessionStore: sso,
      academicAuthService: _BusinessSession(WebVpnSessionStatus.valid),
      weComAuthServiceFactory: () => redeem,
      webVpnInstallerFactory: () => installer,
    );
    expect(await account.recoverWebVpn(forceRefresh: true),
        WebVpnRecoveryOutcome.recovered);
    expect(sso.reads, 1);
    expect(redeem.calls, 1);
    expect(installer.operations, ['adopt', 'reset', 'publish']);
    expect(installer.currentToken, 'new');
    expect(await account.isWebVpnPendingRecovery(), isFalse);
  });

  test('failed forced exchange leaves the existing session unpublished',
      () async {
    final sso = _SessionStore(true);
    final redeem = _RedeemWebVpn(fail: true);
    final installer = _WebVpnInstaller();
    final account = UnifiedAccountService(
      ssoSessionStore: sso,
      academicAuthService: _BusinessSession(WebVpnSessionStatus.valid),
      weComAuthServiceFactory: () => redeem,
      webVpnInstallerFactory: () => installer,
    );
    addTearDown(installer.dispose);
    expect(await account.recoverWebVpn(forceRefresh: true),
        WebVpnRecoveryOutcome.businessFailure);
    expect(redeem.calls, 1);
    expect(installer.operations, isEmpty);
    expect(installer.currentToken, 'old');
    expect(await account.isWebVpnPendingRecovery(), isTrue);
  });

  test('forced exchange with another account preserves the existing session',
      () async {
    SharedPreferences.setMockInitialValues(
        {AcademicAccountStore.studentIdKey: 'student-one'});
    final redeem = _RedeemWebVpn(accountName: 'student-two');
    final installer = _WebVpnInstaller();
    final account = UnifiedAccountService(
      ssoSessionStore: _SessionStore(true),
      academicAuthService: _BusinessSession(WebVpnSessionStatus.valid),
      weComAuthServiceFactory: () => redeem,
      webVpnInstallerFactory: () => installer,
    );
    addTearDown(installer.dispose);
    expect(await account.recoverWebVpn(forceRefresh: true),
        WebVpnRecoveryOutcome.businessFailure);
    expect(redeem.calls, 1);
    expect(installer.operations, isEmpty);
    expect(installer.currentToken, 'old');
    expect(await AcademicAccountStore().loadStudentId(), 'student-one');
  });

  test('an uncertain business response keeps credentials for retry', () async {
    final sso = _SessionStore(true);
    final account = UnifiedAccountService(
      ssoSessionStore: sso,
      academicAuthService: _BusinessSession(WebVpnSessionStatus.unavailable),
    );
    expect(await account.recoverWebVpn(), WebVpnRecoveryOutcome.unavailable);
    expect(sso.reads, 0);
    expect(await account.isWebVpnPendingRecovery(), isTrue);
  });

  test('forced recovery does not replace a session when portal is unavailable',
      () async {
    final sso = _SessionStore(true);
    final account = UnifiedAccountService(
      ssoSessionStore: sso,
      academicAuthService: _BusinessSession(WebVpnSessionStatus.unavailable),
    );
    expect(await account.recoverWebVpn(forceRefresh: true),
        WebVpnRecoveryOutcome.unavailable);
    expect(sso.reads, 0);
  });

  test('a missing SSO session asks for authentication only after rejection',
      () async {
    final account = UnifiedAccountService(
      ssoSessionStore: _SessionStore(false),
      academicAuthService: _BusinessSession(WebVpnSessionStatus.loginRequired),
    );
    expect(await account.recoverWebVpn(),
        WebVpnRecoveryOutcome.needsAuthentication);
    expect(await account.isWebVpnPendingRecovery(), isTrue);
  });

  test('WebVPN redemption failure is not an expired SSO session', () async {
    final account = UnifiedAccountService(
      ssoSessionStore: _SessionStore(true),
      academicAuthService: _BusinessSession(WebVpnSessionStatus.loginRequired),
      weComAuthServiceFactory: _RejectedWebVpn.new,
    );
    expect(
        await account.recoverWebVpn(), WebVpnRecoveryOutcome.businessFailure);
    expect(account.lastWebVpnFailureMessage, 'WebVPN 拒绝兑换');
    expect(await account.isWebVpnPendingRecovery(), isTrue);
  });
}
