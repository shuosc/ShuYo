import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/library_book_item.dart';
import 'package:shuyo/data/models/library_daily_recommend.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/features/library/library_book_detail_page.dart';
import 'package:shuyo/features/library/library_page.dart';
import 'package:shuyo/features/library/library_rank_list_page.dart';

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
          jwt: 'a.b.c',
          jwtHeader: 'jwtOpacAuth',
        );
  }
}

class _MockLibraryApiClient extends LibraryApiClient {
  _MockLibraryApiClient({
    this.recommendResult,
    this.rankResult = const [],
  });

  LibraryDailyRecommend? recommendResult;
  List<LibraryBookItem> rankResult;
  int fetchCalls = 0;
  int rankCalls = 0;

  @override
  Future<LibraryDailyRecommend?> fetchDailyRecommend({
    LibraryAuthSession? session,
  }) async {
    fetchCalls++;
    return recommendResult;
  }

  @override
  Future<List<LibraryBookItem>> fetchRankList({
    required LibraryRankType type,
    int page = 1,
    int rows = 10,
    LibraryAuthSession? session,
    bool loadCovers = true,
    HotLoanSortType hotLoanSort = HotLoanSortType.loanCount,
    NewBookCampus newBookCampus = NewBookCampus.all,
  }) async {
    rankCalls++;
    return rankResult;
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
    // 不再展示原本“暂无借阅记录”的占位
    expect(find.text('暂无借阅记录'), findsNothing);
  });

  testWidgets('pull to refresh does not trigger app bar progress indicator',
      (tester) async {
    final authService = _MockLibraryAuthService();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(authService: authService),
      ),
    );
    await tester.pumpAndSettle();

    final pending = Completer<void>();
    authService.pendingSignal = pending;

    // 触发下拉刷新
    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 下拉刷新期间，AppBar 底部不应展示进度条
    expect(find.byKey(const ValueKey('library-auth-progress')), findsNothing);

    // 完成刷新
    pending.complete();
    await tester.pumpAndSettle();

    expect(authService.authorizeCalls, 2);
  });

  testWidgets(
      'displays daily recommend card and navigates to book detail on tap',
      (tester) async {
    final authService = _MockLibraryAuthService();
    const recommendBook = LibraryDailyRecommend(
      recordId: 1132202,
      title: '“傻瓜”计量经济学与Stata应用',
      author: '习明明编著',
      publisher: '经济科学出版社',
      publishYear: '2024',
      summary: '本书内容涵盖Stata的数据处理、图形绘制...',
    );
    final apiClient = _MockLibraryApiClient(recommendResult: recommendBook);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          authService: authService,
          apiClient: apiClient,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 检查“今日推荐”标题
    expect(find.text('今日推荐'), findsOneWidget);
    // 检查书目各行内容
    expect(find.text('“傻瓜”计量经济学与Stata应用'), findsOneWidget);
    expect(find.textContaining('习明明'), findsOneWidget);
    expect(find.textContaining('经济科学出版社'), findsOneWidget);
    expect(find.textContaining('(2024)'), findsOneWidget);
    expect(find.textContaining('本书内容涵盖Stata的数据处理'), findsOneWidget);

    // 点击今日推荐卡片
    await tester.tap(find.text('“傻瓜”计量经济学与Stata应用'));
    await tester.pumpAndSettle();

    // 验证跳转到了“图书详情”子页面
    expect(find.byType(LibraryBookDetailPage), findsOneWidget);
    expect(find.text('图书详情'), findsOneWidget);
  });

  testWidgets(
      'displays rank gallery with 4 titles and navigates to rank list page on tap view all',
      (tester) async {
    final authService = _MockLibraryAuthService();
    const hotBook = LibraryBookItem(
      recordId: 796762,
      title: '机器学习',
      author: '周志华著',
      publisher: '清华大学出版社',
      publishYear: '2016',
      badgeText: '借阅 5 次',
    );
    final apiClient = _MockLibraryApiClient(
      rankResult: const [hotBook],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          authService: authService,
          apiClient: apiClient,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 验证4个榜单标题
    expect(find.text('热门借阅'), findsOneWidget);
    expect(find.text('热门收藏'), findsOneWidget);
    expect(find.text('高分图书'), findsOneWidget);
    expect(find.text('新书速递'), findsOneWidget);
    expect(find.text('机器学习'), findsOneWidget);
    expect(find.text('周志华著'), findsOneWidget);

    // 点击底部“查看榜单”按钮进入榜单子页面
    await tester.tap(find.text('查看榜单'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryRankListPage), findsOneWidget);
    expect(find.text('图书榜单'), findsOneWidget);
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
    await tester.ensureVisible(find.text('重新授权'));
    await tester.tap(find.text('重新授权'));
    await tester.pumpAndSettle();

    expect(authService.authorizeCalls, 2);
    expect(find.text('未能获取借阅授权'), findsNothing);
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
