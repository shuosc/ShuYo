import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/library_book_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';

class LibrarySearchViewData {
  LibrarySearchViewData(LibrarySearchController controller)
      : revision = controller.revision,
        books = List.unmodifiable(controller.books),
        numFound = controller.numFound,
        activeKeyword = controller.activeKeyword,
        selectedCampuses = Set.unmodifiable(controller.selectedCampuses),
        publishTimeFilter = controller.publishTimeFilter,
        error = controller.error,
        loadMoreError = controller.loadMoreError,
        searching = controller.searching,
        loadingMore = controller.loadingMore,
        hasMore = controller.hasMore,
        hasResults = controller.books.isNotEmpty;

  final int revision;
  final List<LibraryBookItem> books;
  final int numFound;
  final String? activeKeyword;
  final Set<LibraryCampusFilter> selectedCampuses;
  final LibraryPublishTimeFilter publishTimeFilter;
  final Object? error;
  final Object? loadMoreError;
  final bool searching;
  final bool loadingMore;
  final bool hasMore;
  final bool hasResults;
}

/// 图书馆图书检索控制器：管理检索状态、revision 防竞态、串行无缝分页与去重终止条件。
class LibrarySearchController extends ChangeNotifier {
  LibrarySearchController(
    this.apiClient, {
    this.session,
    this.pageSize = 20,
    this.pageRequestDelay = const Duration(milliseconds: 200),
  });

  final LibraryApiClient apiClient;
  LibraryAuthSession? session;
  final int pageSize;
  final Duration pageRequestDelay;

  int revision = 0;
  bool _disposed = false;
  List<LibraryBookItem> books = const [];
  final Set<int> _seenRecordIds = {};
  int _currentPage = 0;
  int numFound = 0;
  String? activeKeyword;
  Set<LibraryCampusFilter> selectedCampuses = const {};
  LibraryPublishTimeFilter publishTimeFilter =
      const LibraryPublishTimeFilter.all();
  Object? error;
  Object? loadMoreError;
  bool searching = false;
  bool loadingMore = false;
  bool hasMore = false;
  DateTime? _lastRequestCompletedAt;

  bool _isCurrent(int value) => !_disposed && value == revision;

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void updateSession(LibraryAuthSession? nextSession) {
    session = nextSession;
  }

  void clear({bool keepFilters = true}) {
    revision++;
    books = const [];
    _seenRecordIds.clear();
    _currentPage = 0;
    numFound = 0;
    activeKeyword = null;
    if (!keepFilters) {
      selectedCampuses = const {};
      publishTimeFilter = const LibraryPublishTimeFilter.all();
    }
    error = null;
    loadMoreError = null;
    searching = false;
    loadingMore = false;
    hasMore = false;
    _publish();
  }

  Future<void> setCampuses(Set<LibraryCampusFilter> campuses) async {
    if (_disposed) return;
    if (campuses.length == selectedCampuses.length &&
        campuses.containsAll(selectedCampuses)) {
      return;
    }
    selectedCampuses = Set<LibraryCampusFilter>.unmodifiable(campuses);
    final keyword = activeKeyword;
    if (keyword != null && keyword.isNotEmpty) {
      await search(keyword);
    } else {
      _publish();
    }
  }

  Future<void> setPublishTimeFilter(LibraryPublishTimeFilter filter) async {
    if (_disposed || filter == publishTimeFilter) return;
    publishTimeFilter = filter;
    final keyword = activeKeyword;
    if (keyword != null && keyword.isNotEmpty) {
      await search(keyword);
    } else {
      _publish();
    }
  }

  Future<void> search(String keyword) async {
    if (_disposed) return;
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      clear();
      return;
    }

    clear();
    final current = revision;
    activeKeyword = trimmed;
    searching = true;
    _publish();

    final years = publishTimeFilter.resolveYears();
    final campusIds = LibraryCampusFilter.toSearchCampusIds(selectedCampuses);

    try {
      final result = await apiClient.searchBooks(
        keyword: trimmed,
        page: 1,
        rows: pageSize,
        campusIds: campusIds,
        publishBegin: years.begin,
        publishEnd: years.end,
        session: session,
      );
      if (!_isCurrent(current)) return;

      final uniqueBooks = <LibraryBookItem>[];
      for (final book in result.books) {
        if (_seenRecordIds.add(book.recordId)) {
          uniqueBooks.add(book);
        }
      }

      books = List.unmodifiable(uniqueBooks);
      _currentPage = result.page;
      numFound = result.numFound;
      hasMore = result.hasMore(books.length);
      _lastRequestCompletedAt = DateTime.now();
    } on Object catch (failure) {
      if (_isCurrent(current)) {
        error = failure;
      }
    } finally {
      if (_isCurrent(current)) {
        searching = false;
        _publish();
      }
    }
  }

  Future<void> loadMore({bool userRetry = false}) async {
    if (_disposed || searching || loadingMore || !hasMore) return;
    if (!userRetry && loadMoreError != null) return;
    final keyword = activeKeyword;
    if (keyword == null || keyword.isEmpty) return;

    final current = revision;
    final nextPage = _currentPage + 1;
    loadingMore = true;
    loadMoreError = null;
    _publish();

    try {
      final lastCompleted = _lastRequestCompletedAt;
      if (lastCompleted != null && pageRequestDelay > Duration.zero) {
        final elapsed = DateTime.now().difference(lastCompleted);
        final remaining = pageRequestDelay - elapsed;
        if (remaining > Duration.zero) {
          await Future<void>.delayed(remaining);
        }
      }
      if (!_isCurrent(current)) return;

      final years = publishTimeFilter.resolveYears();
      final campusIds = LibraryCampusFilter.toSearchCampusIds(selectedCampuses);

      final result = await apiClient.searchBooks(
        keyword: keyword,
        page: nextPage,
        rows: pageSize,
        campusIds: campusIds,
        publishBegin: years.begin,
        publishEnd: years.end,
        session: session,
      );
      if (!_isCurrent(current)) return;

      final appended = <LibraryBookItem>[];
      for (final book in result.books) {
        if (_seenRecordIds.add(book.recordId)) {
          appended.add(book);
        }
      }

      if (appended.isNotEmpty) {
        books = List.unmodifiable([...books, ...appended]);
      }
      _currentPage = result.page;
      if (result.numFound > 0) {
        numFound = result.numFound;
      }
      // 若本次新数据为空或已满足分页终止条件，立刻结束分页防止重复请求末尾页。
      hasMore = appended.isNotEmpty && result.hasMore(books.length);
      _lastRequestCompletedAt = DateTime.now();
    } on Object catch (failure) {
      if (_isCurrent(current)) {
        loadMoreError = failure;
      }
    } finally {
      if (_isCurrent(current)) {
        loadingMore = false;
        _publish();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    revision++;
    super.dispose();
  }
}
