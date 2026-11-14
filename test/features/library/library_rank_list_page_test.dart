import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/library_book_item.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';
import 'package:shuyo/features/library/library_rank_list_page.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

class _MockRankApiClient extends LibraryApiClient {
  final calls = <({LibraryRankType type, Set<LibraryCampusFilter> campuses})>[];

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
    calls.add((type: type, campuses: newBookCampuses));
    return const [
      LibraryBookItem(
        recordId: 796762,
        title: '机器学习',
        author: '周志华著',
        publisher: '清华大学出版社',
        publishYear: '2016',
      ),
    ];
  }
}

void main() {
  testWidgets('newBook campus filter uses checkboxes without ALL',
      (tester) async {
    final apiClient = _MockRankApiClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: ShuYoThemes.all.first.themeData(),
        home: LibraryRankListPage(
          apiClient: apiClient,
          initialType: LibraryRankType.newBook,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(apiClient.calls.last.campuses, isEmpty);

    await tester.tap(find.byKey(const ValueKey('library-newbook-campus-filter')));
    await tester.pumpAndSettle();

    expect(find.text('ALL'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNWidgets(3));
    expect(find.text('宝山校区'), findsOneWidget);
    expect(find.text('延长校区'), findsOneWidget);
    expect(find.text('嘉定校区'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-campus-option:baoshan')));
    await tester.tap(find.byKey(const ValueKey('library-campus-option:yanchang')));
    // 点击遮罩关闭菜单后自动应用当前勾选
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(
      apiClient.calls.last.campuses,
      {LibraryCampusFilter.baoshan, LibraryCampusFilter.yanchang},
    );
  });
}
