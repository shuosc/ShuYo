import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/features/library/library_page.dart';

class _MockLibraryAuthService extends LibraryAuthService {
  _MockLibraryAuthService({
    this.error,
  });

  LibraryAuthSession? sessionResult;
  Object? error;
  int authorizeCalls = 0;
  Completer<void>? pendingSignal;

  @override
  Future<LibraryAuthSession> authorize({bool force = false}) async {
    authorizeCalls++;
    if (pendingSignal != null) {
      await pendingSignal!.future;
    }
    if (error != null) {
      throw error!;
    }
    return sessionResult ??
        const LibraryAuthSession(
          studentId: '25120000',
          userName: '张三',
          unit: '机自学院',
          userGroupName: '本科生',
        );
  }
}

void main() {
  testWidgets(
      'displays app bar progress while authorizing and hides it when done',
      (tester) async {
    final pending = Completer<void>();
    final authService = _MockLibraryAuthService()..pendingSignal = pending;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(authService: authService),
      ),
    );
    await tester.pump();

    // 授权过程中，AppBar 底部应展示进度条
    expect(find.byKey(const ValueKey('library-auth-progress')), findsOneWidget);
    expect(authService.authorizeCalls, 1);

    // 完成授权
    pending.complete();
    await tester.pumpAndSettle();

    // 授权结束后，进度条消失
    expect(find.byKey(const ValueKey('library-auth-progress')), findsNothing);
    // 展示空页面与欢迎信息
    expect(find.text('暂无借阅记录'), findsOneWidget);
    expect(find.textContaining('欢迎你，张三'), findsOneWidget);
  });

  testWidgets('displays error state and retries on action tapped',
      (tester) async {
    final authService = _MockLibraryAuthService(
      error: const LibraryAuthException('网络连接失败，请检查网络'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(authService: authService),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未能获取借阅授权'), findsOneWidget);
    expect(find.text('网络连接失败，请检查网络'), findsOneWidget);
    expect(find.text('重新授权'), findsOneWidget);

    // 修复错误并点击重新授权
    authService.error = null;
    await tester.tap(find.text('重新授权'));
    await tester.pumpAndSettle();

    expect(authService.authorizeCalls, 2);
    expect(find.text('暂无借阅记录'), findsOneWidget);
  });

  testWidgets('invokes onCampusSessionExpired on sso expiry', (tester) async {
    var recoveryInvoked = false;
    final authService = _MockLibraryAuthService(
      error: const LibraryCampusAuthRequiredException(ssoExpired: true),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          authService: authService,
          onCampusSessionExpired: (interactive) async {
            recoveryInvoked = true;
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(recoveryInvoked, isTrue);
    expect(find.text('未能获取借阅授权'), findsOneWidget);
  });
}
