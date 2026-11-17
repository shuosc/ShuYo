import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/library_loan_item.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/data/services/session_cookie_jar.dart';
import 'package:shuyo/features/library/library_book_cover.dart';
import 'package:shuyo/features/library/library_book_detail_page.dart';
import 'package:shuyo/features/library/library_loan_history_page.dart';
import 'package:shuyo/features/library/library_loan_list_tile.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

class _TestLibraryAuthService extends LibraryAuthService {
  _TestLibraryAuthService();

  @override
  Future<LibraryAuthSession> authorize({bool force = false}) async =>
      const LibraryAuthSession(
        studentId: '25120000',
        userName: '张三',
        jwt: 'header.payload.sig',
        jwtHeader: 'jwtOpacAuth',
      );
}

class _FakeLoanApiClient extends LibraryApiClient {
  _FakeLoanApiClient({
    required this.activePages,
    required this.historyPages,
    this.rules = const [],
    this.cardInfo,
  });

  List<LibraryLoanPageResult> activePages;
  List<LibraryLoanPageResult> historyPages;
  LibraryTodoCounts todoCounts = const LibraryTodoCounts();
  List<LibraryLoanRule> rules;
  LibraryReaderCardInfo? cardInfo;
  Object? renewError;

  Completer<void>? activeGate;
  Completer<void>? page2Gate;
  Object? page2Error;
  int loanListCalls = 0;
  int historyListCalls = 0;
  int renewCalls = 0;

  @override
  Future<LibraryLoanPageResult> fetchLoanList({
    int page = 1,
    int rows = 50,
    LibraryAuthSession? session,
  }) async {
    loanListCalls++;
    if (activeGate != null) {
      await activeGate!.future;
    }
    if (page - 1 < activePages.length) {
      return activePages[page - 1];
    }
    return LibraryLoanPageResult(
      items: const [],
      numFound: 0,
      page: page,
      rows: rows,
    );
  }

  @override
  Future<LibraryLoanPageResult> fetchLoanHistoryList({
    int page = 1,
    int rows = 20,
    LibraryAuthSession? session,
  }) async {
    historyListCalls++;
    if (page == 2 && page2Gate != null) {
      await page2Gate!.future;
    }
    if (page == 2 && page2Error != null) {
      throw page2Error!;
    }
    if (page - 1 < historyPages.length) {
      return historyPages[page - 1];
    }
    return LibraryLoanPageResult(
      items: const [],
      numFound: historyPages.isEmpty ? 0 : historyPages.first.numFound,
      page: page,
      rows: rows,
    );
  }

  @override
  Future<LibraryTodoCounts> fetchUserLimit({
    LibraryAuthSession? session,
  }) async =>
      todoCounts;

  @override
  Future<List<LibraryLoanRule>> fetchLoanRules({
    LibraryAuthSession? session,
  }) async =>
      rules;

  @override
  Future<LibraryReaderCardInfo?> fetchReaderCardInfo({
    LibraryAuthSession? session,
  }) async =>
      cardInfo;

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
  group('LibraryLoanItem & LibraryApiClient', () {
    test(
        'parses real loanList payload, ignores loanNum 998, sends auth headers',
        () async {
      late Map<String, String> capturedHeaders;
      final client = LibraryApiClient(
        httpClient: MockClient((request) async {
          capturedHeaders = request.headers;
          expect(request.url.path, '/find/loanInfo/loanList');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'success': true,
                'data': {
                  'searchResult': [
                    {
                      'recordId': 2634730,
                      'loanId': 2542206,
                      'itemId': 3754962,
                      'title': '实时渲染',
                      'author': '(瑞典) 托马斯 著',
                      'isbn': '978-7-302-66127-6',
                      'loanDate': '2026-11-09',
                      'normReturnDate': '2027-02-07',
                      'locationName': '宝山校区-宝山流通库',
                      'curLocationName': '宝山流通库',
                      'barcode': 'Z01479576',
                      'callNo': 'TP391.41/A117.2',
                      'isRequested': '否',
                      'renewTimes': 2,
                      'surplusRenewTimes': 0,
                      'isOnlineReturn': 0,
                    }
                  ],
                  'loanNum': 998,
                  'numFound': 1,
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await client.fetchLoanList(
        session: const LibraryAuthSession(
          studentId: '25120000',
          userName: '张三',
          jwt: 'jwt-value',
          jwtHeader: 'jwtOpacAuth',
          cookies: [
            SessionCookie(
              name: 'SESSION',
              value: 'cookie-val',
              domain: 'findshu.libsp.cn',
              path: '/',
            ),
          ],
        ),
      );

      expect(capturedHeaders['groupCode'], '201578');
      expect(capturedHeaders['jwtOpacAuth'], 'jwt-value');
      expect(capturedHeaders['Cookie'], 'SESSION=cookie-val');
      expect(result.numFound, 1);
      expect(result.items, hasLength(1));

      final item = result.items.single;
      expect(item.title, '实时渲染');
      expect(item.dueDateText, '2027-02-07');
      // 严禁用 normalLoanPeriod (30天) 替代服务端 normReturnDate (实际90天)
      expect(item.daysRemaining(now: DateTime(2026, 11, 9)), 90);
      expect(item.canRenewAt(now: DateTime(2026, 11, 15)), isFalse);
      expect(item.renewDisabledReason(now: DateTime(2026, 11, 15)),
          contains('已达最大续借次数'));
    });

    test(
        'renewLoan throws server failReason and translates 401 to auth required',
        () async {
      var mode = 'failReason';
      final client = LibraryApiClient(
        httpClient: MockClient((request) async {
          if (mode == '401') {
            return http.Response('Unauthorized', 401);
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'success': false,
                'failReason': '该书已被其他读者预约',
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await expectLater(
        () => client.renewLoan(barcode: 'Z01479576', loanId: 2542206),
        throwsA(
          isA<LibraryApiException>().having(
            (e) => e.message,
            'message',
            contains('已被其他读者预约'),
          ),
        ),
      );

      mode = '401';
      await expectLater(
        () => client.fetchLoanHistoryList(),
        throwsA(isA<LibraryApiAuthRequiredException>()),
      );
    });
  });

  group('LibraryLoanHistoryPage', () {
    Widget wrapPage(Widget child) => MaterialApp(
          theme: ShuYoThemes.byId(ShuYoThemes.defaultId).themeData(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child,
        );

    final now = DateTime(2026, 11, 15);

    List<LibraryLoanItem> sampleActive() => [
          LibraryLoanItem(
            recordId: 1001,
            loanId: 501,
            title: '在借参考书',
            author: '陈某',
            callNo: 'TP301/1',
            locationName: '宝山校区-宝山流通库',
            barcode: 'B1001',
            loanDate: DateTime(2026, 11, 10),
            loanDateText: '2026-11-10',
            dueDate: DateTime(2026, 12, 10),
            dueDateText: '2026-12-10',
            renewTimes: 0,
            surplusRenewTimes: 2,
          ),
        ];

    List<LibraryLoanItem> sampleHistoryPage1() => [
          LibraryLoanItem(
            recordId: 1002,
            loanId: 401,
            title: '十一月已归还书籍',
            author: '李某',
            callNo: 'I247/2',
            locationName: '嘉定流通库',
            barcode: 'H1001',
            loanDate: DateTime(2026, 11, 1),
            loanDateText: '2026-11-01',
            returnDate: DateTime(2026, 11, 12),
            returnDateText: '2026-11-12',
            isHistory: true,
          ),
          LibraryLoanItem(
            recordId: 1003,
            loanId: 402,
            title: '三月已归还旧书',
            author: '王某',
            callNo: 'O17/3',
            locationName: '延长流通库',
            barcode: 'H1002',
            loanDate: DateTime(2026, 3, 5),
            loanDateText: '2026-03-05',
            isHistory: true,
          ),
        ];

    testWidgets(
        'fetches live from API, renders sticky month headers without covers, switches tabs and filters by time',
        (tester) async {
      final pendingGate = Completer<void>();
      final client = _FakeLoanApiClient(
        activePages: [
          LibraryLoanPageResult(
            items: sampleActive(),
            numFound: 1,
            page: 1,
            rows: 50,
          ),
        ],
        historyPages: [
          LibraryLoanPageResult(
            items: sampleHistoryPage1(),
            numFound: 2,
            page: 1,
            rows: 20,
          ),
        ],
        rules: const [
          LibraryLoanRule(
            ruleName: '读者借阅规则',
            maxBorrowingNumber: '999',
            maxRenewalTime: '2',
            normalLoanPeriod: '30天',
            maxPenalty: '10 RMB',
          ),
        ],
        cardInfo: const LibraryReaderCardInfo(
          name: '*张三',
          unit: '机自学院',
          userGroupName: '本科生',
          cardStatus: '1',
          startDate: '2025-09-01',
          endDate: '2029-09-01',
        ),
      )..activeGate = pendingGate;

      await tester.pumpWidget(
        wrapPage(
          LibraryLoanHistoryPage(
            apiClient: client,
            authService: _TestLibraryAuthService(),
            now: now,
          ),
        ),
      );
      await tester.pump();

      // 首次从 API 加载时，顶部出现 3px 进度条与加载态
      expect(
        find.byKey(const ValueKey('library-loan-history-progress')),
        findsOneWidget,
      );
      expect(find.text('正在加载借阅记录…'), findsOneWidget);

      pendingGate.complete();
      client.activeGate = null;
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-loan-history-progress')),
        findsNothing,
      );
      expect(find.byType(LibraryBookCover), findsNothing);
      expect(find.byType(LibraryLoanListTile), findsNWidgets(3));

      // 验证年月吸顶组头部
      expect(
        find.byKey(const ValueKey('library-loan-month-2026-11')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-loan-month-2026-03')),
        findsOneWidget,
      );
      expect(find.text('2026年11月'), findsOneWidget);
      expect(find.text('2026年3月'), findsOneWidget);

      // 切换 Tab：借阅中 / 已归还
      await tester.tap(find.byKey(const ValueKey('library-loan-tab-active')));
      await tester.pumpAndSettle();
      expect(find.text('在借参考书'), findsOneWidget);
      expect(find.text('十一月已归还书籍'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('library-loan-tab-returned')));
      await tester.pumpAndSettle();
      expect(find.text('在借参考书'), findsNothing);
      expect(find.text('十一月已归还书籍'), findsOneWidget);
      expect(find.text('三月已归还旧书'), findsOneWidget);

      // 打开 AppBar 时间筛选菜单并选择“近一月”（应过滤掉 3 月记录）
      await tester.tap(find.byKey(const ValueKey('library-loan-time-filter')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('library-loan-time-menu')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-loan-time-month')));
      await tester.pumpAndSettle();
      expect(find.text('十一月已归还书籍'), findsOneWidget);
      expect(find.text('三月已归还旧书'), findsNothing);

      // 下拉刷新直接再次走 API（无本地缓存）且不触发 AppBar 进度条
      final refreshGate = Completer<void>();
      client.activeGate = refreshGate;
      await tester.fling(
        find.byKey(const ValueKey('library-loan-history-scroll-view')),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('library-loan-history-progress')),
        findsNothing,
      );
      refreshGate.complete();
      client.activeGate = null;
      await tester.pumpAndSettle();
      expect(client.loanListCalls, 2);
      expect(client.historyListCalls, 2);

      // 打开借阅规则底表
      await tester.tap(find.byKey(const ValueKey('library-loan-rules')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-loan-rules-sheet')),
          findsOneWidget);
      expect(find.text('读者借阅规则'), findsOneWidget);
      expect(find.text('999 册'), findsOneWidget);
      expect(find.text('正常'), findsOneWidget);
    });

    testWidgets(
        'paginates history via numFound, shows retry on page2 error, opens detail sheet and navigates to book detail',
        (tester) async {
      final page1 = [
        for (var i = 0; i < 10; i++)
          LibraryLoanItem(
            recordId: 2000 + i,
            loanId: 800 + i,
            title: '历史测试图书 $i',
            author: '作者 $i',
            loanDate: DateTime(2026, 10, 20 - i),
            loanDateText: '2026-10-${(20 - i).toString().padLeft(2, '0')}',
            isHistory: true,
          ),
      ];
      final page2 = [
        LibraryLoanItem(
          recordId: 3001,
          loanId: 901,
          title: '第二页归还书籍',
          author: '作者B',
          loanDate: DateTime(2026, 8, 15),
          loanDateText: '2026-08-15',
          isHistory: true,
        ),
      ];

      final client = _FakeLoanApiClient(
        activePages: const [
          LibraryLoanPageResult(items: [], numFound: 0, page: 1, rows: 50),
        ],
        historyPages: [
          LibraryLoanPageResult(items: page1, numFound: 11, page: 1, rows: 20),
          LibraryLoanPageResult(items: page2, numFound: 11, page: 2, rows: 20),
        ],
      )..page2Error = const LibraryApiException('翻页超时');

      await tester.pumpWidget(
        wrapPage(
          LibraryLoanHistoryPage(
            apiClient: client,
            authService: _TestLibraryAuthService(),
            initialTabIndex: 2,
            now: now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 滚动到底部触发加载第 2 页失败
      await tester.drag(
        find.byKey(const ValueKey('library-loan-history-scroll-view')),
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-loan-history-load-more-retry')),
        findsOneWidget,
      );

      // 点击重试后加载第 2 页
      client.page2Error = null;
      await tester.ensureVisible(
        find.byKey(const ValueKey('library-loan-history-load-more-retry')),
      );
      await tester.tap(
        find.byKey(const ValueKey('library-loan-history-load-more-retry')),
      );
      await tester.pumpAndSettle();

      expect(find.text('第二页归还书籍'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('library-loan-history-scroll-view')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.text('已显示全部 11 条历史借阅'), findsOneWidget);

      // 点击条目弹出底部详情弹窗，验证可进入图书详情页
      await tester.ensureVisible(find.text('第二页归还书籍'));
      await tester.tap(find.text('第二页归还书籍'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('library-loan-detail-sheet')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-loan-detail-book')));
      await tester.pumpAndSettle();

      expect(find.byType(LibraryBookDetailPage), findsOneWidget);
    });
  });
}
