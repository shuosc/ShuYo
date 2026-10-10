import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/settings/student_identity_page.dart';

class _IdentityService extends StudentIdentityService {
  _IdentityService({this.failAfterSaving = false});

  final bool failAfterSaving;
  bool _saved = false;

  StudentIdentitySession get _session => StudentIdentitySession(
        token: 'a' * 43,
        studentId: '23123456',
        maskedStudentId: '23****56',
        expiresAt: DateTime.utc(2099),
      );

  @override
  Future<bool> hasConsent() async => true;

  @override
  Future<StudentIdentitySession?> checkCurrentSession() async =>
      _saved ? _session : null;

  @override
  Future<StudentIdentitySession> bindCurrentStudent(
      {bool force = false, bool manual = false}) async {
    _saved = true;
    if (failAfterSaving) throw StateError('cleanup failed after saving');
    return _session;
  }
}

void main() {
  testWidgets('successful verification refreshes without an error',
      (tester) async {
    final service = _IdentityService();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StudentIdentityPage(service: service),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('尝试认证'));
    await tester.pumpAndSettle();
    expect(find.text('已认证 · 23****56'), findsOneWidget);
    expect(find.text('身份已认证'), findsOneWidget);
    expect(find.text('当前暂时无法验证您的身份，请稍后再试'), findsNothing);
  });

  testWidgets('a confirmed session never shows a verification failure',
      (tester) async {
    final service = _IdentityService(failAfterSaving: true);
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
      home: StudentIdentityPage(service: service),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('尝试认证'));
    await tester.pumpAndSettle();
    expect(find.text('已认证 · 23****56'), findsOneWidget);
    expect(find.text('身份已认证'), findsOneWidget);
    expect(find.text('当前暂时无法验证您的身份，请稍后再试'), findsNothing);
  });
}
