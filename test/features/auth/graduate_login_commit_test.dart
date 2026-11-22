import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/core/campus_system.dart';
import 'package:shuyo/core/academic_url_resolver.dart';
import 'package:shuyo/data/services/academic_account_store.dart';
import 'package:shuyo/data/services/academic_native_auth_service.dart';
import 'package:shuyo/data/services/graduate_session_store.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/features/auth/native_login_page.dart';

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
}

class _GraduateAuth implements AcademicNativeAuthService {
  _GraduateAuth({required this.succeeds});

  final bool succeeds;
  bool completed = false;

  @override
  Future<AcademicLoginResult> login({
    required String username,
    required String password,
  }) async =>
      AcademicLoginResult(callbackUri: GraduateSessionStore.entryUri);

  @override
  Future<void> completeLogin(Uri callbackUri, {bool publish = true}) async {
    expect(publish, isFalse);
    if (!succeeds) {
      throw const AcademicNativeAuthException(
          'graduateLoginRequired', '研究生系统需要重新登录');
    }
    completed = true;
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
