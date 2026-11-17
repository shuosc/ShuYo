import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/library_book_item.dart';
import 'package:shuyo/data/models/library_daily_recommend.dart';
import 'package:shuyo/data/models/library_loan_item.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/features/library/library_book_cover.dart';
import 'package:shuyo/features/library/library_book_detail_page.dart';
import 'package:shuyo/features/library/library_loan_history_page.dart';
import 'package:shuyo/features/library/library_loan_list_tile.dart';
import 'package:shuyo/features/library/library_page.dart';
import 'package:shuyo/features/library/library_rank_list_page.dart';
import 'package:shuyo/features/library/library_search_page.dart';

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
    this.loanListResult = const LibraryLoanPageResult(
      items: [],
      numFound: 0,
      page: 1,
      rows: 50,
    ),
    this.todoCounts = const LibraryTodoCounts(),
  });

  LibraryDailyRecommend? recommendResult;
  List<LibraryBookItem> rankResult;
  LibraryLoanPageResult loanListResult;
  LibraryLoanPageResult historyResult = const LibraryLoanPageResult(
    items: [],
    numFound: 0,
    page: 1,
    rows: 20,
  );
  LibraryTodoCounts todoCounts;
  Object? renewError;
  int fetchCalls = 0;
  int rankCalls = 0;
  int loanCalls = 0;
  int renewCalls = 0;

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
    Set<LibraryCampusFilter> newBookCampuses = const {},
  }) async {
    rankCalls++;
    return rankResult;
  }

  @override
  Future<LibraryLoanPageResult> fetchLoanList({
    int page = 1,
    int rows = 50,
    LibraryAuthSession? session,
  }) async {
    loanCalls++;
    return loanListResult;
  }

  @override
  Future<LibraryLoanPageResult> fetchLoanHistoryList({
    int page = 1,
    int rows = 20,
    LibraryAuthSession? session,
  }) async {
    return historyResult;
  }

  @override
  Future<LibraryTodoCounts> fetchUserLimit({
    LibraryAuthSession? session,
  }) async {
    return todoCounts;
  }

  @override
  Future<String?> renewLoan({
    required String barcode,
    int? loanId,
    LibraryAuthSession? session,
  }) async {
    renewCalls++;
    if (renewError != null) throw renewError!;
    return '续借成功';
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
    expect(find.text('“傻瓜”计量经济学与Stata应用'), findsWidgets);
    expect(find.textContaining('习明明'), findsOneWidget);
    expect(find.textContaining('经济科学出版社'), findsWidgets);
    expect(find.textContaining('(2024)'), findsOneWidget);
    expect(find.textContaining('本书内容涵盖Stata的数据处理'), findsOneWidget);

    // 点击今日推荐卡片
    await tester.tap(find.text('“傻瓜”计量经济学与Stata应用').last);
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
    expect(find.text('机器学习'), findsWidgets);
    expect(find.text('周志华著'), findsOneWidget);

    // 点击底部“查看榜单”按钮进入榜单子页面
    await tester.ensureVisible(find.text('查看榜单'));
    await tester.pumpAndSettle();
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

  testWidgets('tapping appbar search button opens LibrarySearchPage',
      (tester) async {
    final authService = _MockLibraryAuthService();
    final apiClient = _MockLibraryApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          authService: authService,
          apiClient: apiClient,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final searchButton = find.byKey(const ValueKey('library-search'));
    expect(searchButton, findsOneWidget);

    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    expect(find.byType(LibrarySearchPage), findsOneWidget);
    expect(find.text('搜索图书'), findsOneWidget);
  });

  testWidgets(
      'displays current loans without cover, opens detail sheet and navigates to history',
      (tester) async {
    final now = DateTime(2026, 11, 15);
    final authService = _MockLibraryAuthService();
    final loans = [
      LibraryLoanItem(
        recordId: 201,
        loanId: 11,
        title: '正常在借图书',
        author: '作者甲',
        callNo: 'TP311/1',
        locationName: '宝山流通库',
        barcode: 'Z0001',
        loanDate: DateTime(2026, 11, 1),
        loanDateText: '2026-11-01',
        dueDate: DateTime(2026, 12, 10),
        dueDateText: '2026-12-10',
        renewTimes: 0,
        surplusRenewTimes: 2,
      ),
      LibraryLoanItem(
        recordId: 202,
        loanId: 12,
        title: '已逾期图书',
        author: '作者乙',
        callNo: 'TP312/2',
        locationName: '嘉定流通库',
        barcode: 'Z0002',
        loanDate: DateTime(2026, 9, 20),
        loanDateText: '2026-09-20',
        dueDate: DateTime(2026, 11, 12),
        dueDateText: '2026-11-12',
        renewTimes: 2,
        surplusRenewTimes: 0,
      ),
      LibraryLoanItem(
        recordId: 203,
        loanId: 13,
        title: '即将到期图书',
        author: '作者丙',
        callNo: 'TP313/3',
        locationName: '宝山流通库',
        barcode: 'Z0003',
        loanDate: DateTime(2026, 10, 20),
        loanDateText: '2026-10-20',
        dueDate: DateTime(2026, 11, 17),
        dueDateText: '2026-11-17',
        renewTimes: 0,
        surplusRenewTimes: 1,
      ),
      LibraryLoanItem(
        recordId: 204,
        loanId: 14,
        title: '第四本在借图书',
        author: '作者丁',
        callNo: 'TP314/4',
        locationName: '延长流通库',
        barcode: 'Z0004',
        loanDate: DateTime(2026, 11, 5),
        loanDateText: '2026-11-05',
        dueDate: DateTime(2027, 1, 5),
        dueDateText: '2027-01-05',
        renewTimes: 0,
        surplusRenewTimes: 1,
      ),
    ];
    final apiClient = _MockLibraryApiClient(
      loanListResult: LibraryLoanPageResult(
        items: loans,
        numFound: 4,
        page: 1,
        rows: 50,
      ),
      todoCounts: const LibraryTodoCounts(expiredNum: 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(
          authService: authService,
          apiClient: apiClient,
          now: now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的借阅'), findsOneWidget);
    expect(find.text('在借 4 本'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-home-overdue-banner')),
        findsOneWidget);

    // 只显示最多 3 本，且在借条目中不包含封面组件
    expect(find.byType(LibraryLoanListTile), findsNWidgets(3));
    expect(find.byType(LibraryBookCover), findsNothing);
    expect(find.text('已逾期 3 天'), findsOneWidget);
    expect(find.text('剩 2 天'), findsOneWidget);
    expect(find.text('剩 25 天'), findsOneWidget);
    expect(find.text('还有 1 本在借图书'), findsOneWidget);

    // 排序确认：最紧急（逾期）在最前，第四本应还最晚被折叠
    expect(find.text('第四本在借图书'), findsNothing);

    // 点击其中可续借图书，打开底部详情弹窗并完成二次确认续借
    await tester.tap(find.text('正常在借图书'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-loan-detail-sheet')),
        findsOneWidget);
    expect(find.text('TP311/1'), findsOneWidget);
    expect(find.text('Z0001'), findsOneWidget);

    final copyCallNoSize = tester.getSize(
      find.byKey(const ValueKey('library-loan-copy-索书号')),
    );
    expect(copyCallNoSize.width, greaterThanOrEqualTo(48));
    expect(copyCallNoSize.height, greaterThanOrEqualTo(48));

    final renewBtn = find.byKey(const ValueKey('library-loan-detail-renew'));
    await tester.ensureVisible(renewBtn);
    await tester.tap(renewBtn);
    await tester.pumpAndSettle();

    // 二次确认框
    expect(find.text('确认续借'), findsWidgets);
    await tester.tap(find.text('确认续借').last);
    await tester.pumpAndSettle();

    expect(apiClient.renewCalls, 1);
    expect(find.text('续借成功'), findsOneWidget);

    // 点击底表右上角关闭按钮后点击“查看历史借阅”
    await tester.tap(find.byKey(const ValueKey('library-loan-detail-close')));
    await tester.pumpAndSettle();

    final historyBtn = find.byKey(const ValueKey('library-loan-history'));
    await tester.ensureVisible(historyBtn);
    await tester.tap(historyBtn);
    await tester.pumpAndSettle();

    expect(find.byType(LibraryLoanHistoryPage), findsOneWidget);
    expect(find.text('借阅记录'), findsOneWidget);
  });
}
