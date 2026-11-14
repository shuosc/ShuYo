import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/library_book_item.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/features/library/library_book_detail_page.dart';
import 'package:shuyo/features/library/library_book_list_tile.dart';
import 'package:shuyo/features/library/library_search_controller.dart';
import 'package:shuyo/features/library/library_search_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

LibraryBookItem _book(int id, {String? title, String? callNo}) =>
    LibraryBookItem(
      recordId: id,
      title: title ?? '图书 $id',
      author: '周志华著',
      publisher: '清华大学出版社',
      publishYear: '2016',
      callNo: callNo ?? 'TP181/Z$id',
      totalHolding: 6,
      onShelfHolding: 4,
    );

class _MockSearchApiClient extends LibraryApiClient {
  Future<LibraryBookSearchResult> Function(String keyword, int page, int rows)?
      searchHandler;
  final calls = <({String keyword, int page, int rows})>[];

  @override
  Future<LibraryBookSearchResult> searchBooks({
    required String keyword,
    int page = 1,
    int rows = 20,
    LibraryAuthSession? session,
    bool loadSupplementary = true,
  }) async {
    calls.add((keyword: keyword, page: page, rows: rows));
    if (searchHandler != null) {
      return searchHandler!(keyword, page, rows);
    }
    return LibraryBookSearchResult(
      numFound: 0,
      page: page,
      rows: rows,
      books: const [],
      rawResultCount: 0,
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  _MockSearchApiClient apiClient, {
  LibrarySearchController? controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ShuYoThemes.all.first.themeData(),
      home: LibrarySearchPage(
        apiClient: apiClient,
        controller: controller ??
            LibrarySearchController(
              apiClient,
              pageSize: 10,
              pageRequestDelay: Duration.zero,
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submit(
  WidgetTester tester,
  String keyword, {
  bool keyboard = false,
}) async {
  await tester.enterText(
      find.byKey(const ValueKey('library-search-query')), keyword);
  await tester.pump();
  if (keyboard) {
    await tester.testTextInput.receiveAction(TextInputAction.search);
  } else {
    await tester.tap(find.byKey(const ValueKey('library-search-submit')));
  }
  await tester.pump();
}

void main() {
  testWidgets('initial empty state and button enable/disable state',
      (tester) async {
    final apiClient = _MockSearchApiClient();
    await _mount(tester, apiClient);

    expect(find.text('搜索图书'), findsOneWidget);
    expect(find.text('搜索馆藏图书'), findsOneWidget);
    expect(find.text('仅检索图书'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
              find.byKey(const ValueKey('library-search-submit')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const ValueKey('library-search-clear')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('library-search-query')),
      '机器学习',
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('library-search-clear')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
              find.byKey(const ValueKey('library-search-submit')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('displays appbar linear progress while searching and slides rows',
      (tester) async {
    final pending = Completer<LibraryBookSearchResult>();
    final apiClient = _MockSearchApiClient()
      ..searchHandler = (_, __, ___) => pending.future;
    await _mount(tester, apiClient);

    await _submit(tester, '机器学习');

    expect(
        find.byKey(const ValueKey('library-search-progress')), findsOneWidget);
    expect(find.text('正在搜索图书…'), findsOneWidget);

    pending.complete(
      LibraryBookSearchResult(
        numFound: 1,
        page: 1,
        rows: 10,
        books: [_book(796762, title: '机器学习')],
        rawResultCount: 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    expect(find.byKey(const ValueKey('library-search-progress')), findsNothing);
    final tile = find.byKey(const ValueKey('library-search-book:796762'));
    expect(tile, findsOneWidget);

    final transition =
        find.ancestor(of: tile, matching: find.byType(SlideTransition)).first;
    expect(tester.widget<SlideTransition>(transition).position.value.dx,
        greaterThan(0));

    await tester.pumpAndSettle();
    expect(
        tester.widget<SlideTransition>(transition).position.value, Offset.zero);
    expect(find.text('已显示全部 1 本图书'), findsOneWidget);
  });

  testWidgets('seamlessly loads next page on scroll without duplicating items',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final apiClient = _MockSearchApiClient()
      ..searchHandler = (keyword, page, rows) async {
        if (page == 1) {
          return LibraryBookSearchResult(
            numFound: 15,
            page: 1,
            rows: rows,
            books: [for (var i = 1; i <= 10; i++) _book(i)],
            rawResultCount: 10,
          );
        }
        return LibraryBookSearchResult(
          numFound: 15,
          page: 2,
          rows: rows,
          books: [
            _book(10), // 模拟重叠数据，验证按 recordId 去重
            for (var i = 11; i <= 15; i++) _book(i),
          ],
          rawResultCount: 5,
        );
      };

    await _mount(tester, apiClient);
    await _submit(tester, '算法', keyboard: true);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-loaded-count')))
          .data,
      '10',
    );
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-total-count')))
          .data,
      '15',
    );

    final list = find.byKey(const ValueKey('library-search-results'));
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();

    expect(apiClient.calls.map((c) => c.page), [1, 2]);
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-loaded-count')))
          .data,
      '15',
    );
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('已显示全部 15 本图书'), findsOneWidget);

    // 滑到底后再尝试下拉不应触发第 3 页请求
    await tester.drag(list, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(apiClient.calls.map((c) => c.page), [1, 2]);
  });

  testWidgets('tapping book row opens LibraryBookDetailPage', (tester) async {
    final apiClient = _MockSearchApiClient()
      ..searchHandler = (_, page, rows) async => LibraryBookSearchResult(
            numFound: 1,
            page: page,
            rows: rows,
            books: [_book(796762, title: '机器学习')],
            rawResultCount: 1,
          );

    await _mount(tester, apiClient);
    await _submit(tester, '机器学习');
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBookListTile), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-search-book:796762')));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBookDetailPage), findsOneWidget);
    expect(find.text('图书详情'), findsOneWidget);
  });

  testWidgets('shows retry on initial error and on loadMore error',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    var failFirst = true;
    var failSecondPage = true;
    final apiClient = _MockSearchApiClient()
      ..searchHandler = (keyword, page, rows) async {
        if (page == 1 && failFirst) {
          throw const LibraryApiException('系统访问中断，请稍后再试！');
        }
        if (page == 1) {
          return LibraryBookSearchResult(
            numFound: 15,
            page: 1,
            rows: rows,
            books: [for (var i = 1; i <= 10; i++) _book(i)],
            rawResultCount: 10,
          );
        }
        if (page == 2 && failSecondPage) {
          throw const LibraryApiException('分页加载异常');
        }
        return LibraryBookSearchResult(
          numFound: 15,
          page: 2,
          rows: rows,
          books: [for (var i = 11; i <= 15; i++) _book(i)],
          rawResultCount: 5,
        );
      };

    await _mount(tester, apiClient);
    await _submit(tester, '测试');
    await tester.pumpAndSettle();

    expect(find.text('图书搜索失败'), findsOneWidget);
    expect(find.text('系统访问中断，请稍后再试！'), findsOneWidget);

    failFirst = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-loaded-count')))
          .data,
      '10',
    );

    final list = find.byKey(const ValueKey('library-search-results'));
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();

    final retryMore =
        find.byKey(const ValueKey('library-search-load-more-retry'));
    expect(retryMore, findsOneWidget);

    failSecondPage = false;
    await tester.tap(retryMore);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-loaded-count')))
          .data,
      '15',
    );
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('已显示全部 15 本图书'), findsOneWidget);
  });

  testWidgets('clear button resets results and keyword', (tester) async {
    final apiClient = _MockSearchApiClient()
      ..searchHandler = (_, page, rows) async => LibraryBookSearchResult(
            numFound: 1,
            page: page,
            rows: rows,
            books: [_book(796762, title: '机器学习')],
            rawResultCount: 1,
          );

    await _mount(tester, apiClient);
    await _submit(tester, '机器学习');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('library-search-clear')));
    await tester.pumpAndSettle();

    expect(find.text('搜索馆藏图书'), findsOneWidget);
    expect(find.byType(LibraryBookListTile), findsNothing);
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-loaded-count')))
          .data,
      '0',
    );
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('library-search-total-count')))
          .data,
      '0',
    );
  });
}
