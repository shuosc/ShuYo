import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/client_user_agent.dart';
import '../../core/library_constants.dart';
import '../models/library_book_item.dart';
import '../models/library_daily_recommend.dart';
import '../models/library_loan_item.dart';
import 'http_timeout.dart';
import 'library_auth_service.dart';

class LibraryApiException implements Exception {
  const LibraryApiException(
    this.message, {
    this.statusCode,
    this.isAuthRequired = false,
  });

  final String message;
  final int? statusCode;
  final bool isAuthRequired;

  @override
  String toString() => statusCode != null ? '$message ($statusCode)' : message;
}

class LibraryApiAuthRequiredException extends LibraryApiException {
  const LibraryApiAuthRequiredException(
    super.message, {
    super.statusCode,
  }) : super(isAuthRequired: true);
}

class LibraryApiClient {
  LibraryApiClient({http.Client? httpClient})
      : _httpClient = httpClient ?? IOClient(HttpClient()),
        _ownsClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }

  Map<String, String> _buildHeaders({LibraryAuthSession? session}) {
    final cookieHeader = session == null || session.cookies.isEmpty
        ? ''
        : [
            for (final c in session.cookies)
              if (c.name.isNotEmpty &&
                  (c.domain.isEmpty || c.domain == LibraryConstants.host))
                '${c.name}=${c.value}',
          ].join('; ');
    return {
      'Content-Type': 'application/json;charset=utf-8',
      'groupCode': LibraryConstants.groupCode,
      'x-lang': 'CHI',
      'content-language': 'zh_CN',
      'Referer': '${LibraryConstants.baseUrl}/',
      'Origin': LibraryConstants.baseUrl,
      'User-Agent': ClientUserAgent.mobileBrowser,
      'Accept': 'application/json, text/plain, */*',
      if (session != null && session.jwt.isNotEmpty)
        session.jwtHeader: session.jwt,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
  }

  /// 获取今日推荐图书（每日一本好书）
  Future<LibraryDailyRecommend?> fetchDailyRecommend({
    LibraryAuthSession? session,
  }) async {
    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.dailyRecommendPath}',
    );
    final response = await _httpClient
        .get(
          uri,
          headers: _buildHeaders(session: session),
        )
        .timeout(HttpTimeout.normal);

    if (response.statusCode != 200) {
      throw LibraryApiException(
        '获取今日推荐失败',
        statusCode: response.statusCode,
      );
    }

    final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    if (decoded['success'] != true) {
      throw LibraryApiException(
        decoded['message'] as String? ?? '获取今日推荐失败',
      );
    }

    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      return null;
    }

    final book = LibraryDailyRecommend.fromJson(data);
    final results = await Future.wait([
      fetchCoverUrl(
        isbn: book.isbn,
        title: book.title,
        recordId: book.recordId,
        session: session,
      ),
      fetchBookHoldings(
        recordId: book.recordId,
        session: session,
      ),
    ]);

    final coverUrl = results[0] as String?;
    final holdings = results[1] as ({int onShelf, int total})?;

    return book.copyWith(
      coverUrl: coverUrl,
      totalHolding: holdings?.total,
      onShelfHolding: holdings?.onShelf,
    );
  }

  /// 根据 ISBN、书名、记录 ID 获取读秀封面图片地址
  Future<String?> fetchCoverUrl({
    String? isbn,
    String? title,
    required int recordId,
    LibraryAuthSession? session,
  }) async {
    try {
      final queryParams = <String, String>{
        'isbn': isbn ?? '',
        'title': title ?? '',
        'recordId': recordId.toString(),
      };
      final uri = Uri.parse(
        '${LibraryConstants.baseUrl}${LibraryConstants.duxiuCoverPath}',
      ).replace(queryParameters: queryParams);

      final response = await _httpClient
          .get(
            uri,
            headers: _buildHeaders(session: session),
          )
          .timeout(HttpTimeout.normal);

      if (response.statusCode != 200) {
        return null;
      }

      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded['success'] == true) {
        final data = decoded['data'];
        if (data is String && data.trim().isNotEmpty) {
          return data.trim();
        }
      }
    } on Object {
      // 封面获取失败不阻断书本信息展示
      return null;
    }
    return null;
  }

  /// 获取指定类型的图书榜单
  Future<List<LibraryBookItem>> fetchRankList({
    required LibraryRankType type,
    int page = 1,
    int rows = 10,
    LibraryAuthSession? session,
    bool loadCovers = true,
    HotLoanSortType hotLoanSort = HotLoanSortType.loanCount,
    Set<LibraryCampusFilter> newBookCampuses = const {},
  }) async {
    final String path;
    switch (type) {
      case LibraryRankType.hotLoan:
        path = LibraryConstants.hotLoanPath;
        break;
      case LibraryRankType.hotCollect:
        path = LibraryConstants.topSharePath;
        break;
      case LibraryRankType.highScore:
        path = LibraryConstants.topScorePath;
        break;
      case LibraryRankType.newBook:
        path = LibraryConstants.newBookPath;
        break;
    }

    final Map<String, dynamic> requestBody = {
      'page': page,
      'rows': rows,
      'groupCode': LibraryConstants.groupCode,
    };

    if (type == LibraryRankType.hotLoan) {
      requestBody['statRange'] = 30;
      if (hotLoanSort == HotLoanSortType.loanRate) {
        requestBody['sortType'] = 2;
      }
    } else if (type == LibraryRankType.newBook) {
      requestBody['time'] = '1'; // 默认最近一周
      requestBody['docCode'] = '1';
      requestBody['campusId'] =
          LibraryCampusFilter.toCampusIds(newBookCampuses);
    }

    final uri = Uri.parse('${LibraryConstants.baseUrl}$path');
    final response = await _httpClient
        .post(
          uri,
          headers: _buildHeaders(session: session),
          body: jsonEncode(requestBody),
        )
        .timeout(HttpTimeout.normal);

    if (response.statusCode != 200) {
      throw LibraryApiException(
        '获取${type.label}失败',
        statusCode: response.statusCode,
      );
    }

    final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw LibraryApiException(
        decoded is Map<String, dynamic>
            ? (decoded['message'] as String? ?? '获取${type.label}失败')
            : '获取${type.label}失败',
      );
    }

    final data = decoded['data'];
    List<dynamic> rawList = const [];
    if (data is Map<String, dynamic>) {
      if (type == LibraryRankType.hotLoan) {
        rawList = (data['result'] as List?) ?? const [];
      } else if (type == LibraryRankType.hotCollect) {
        rawList = (data['courseListDtos'] as List?) ?? const [];
      } else if (type == LibraryRankType.highScore) {
        rawList = (data['topScoreList'] as List?) ?? const [];
      } else if (type == LibraryRankType.newBook) {
        rawList = (data['searchResult'] as List?) ?? const [];
      }
    } else if (data is List) {
      rawList = data;
    }

    final books = rawList
        .map((item) {
          if (item is! Map<String, dynamic>) {
            return null;
          }
          switch (type) {
            case LibraryRankType.hotLoan:
              return LibraryBookItem.fromHotLoan(item);
            case LibraryRankType.hotCollect:
              return LibraryBookItem.fromTopShare(item);
            case LibraryRankType.highScore:
              return LibraryBookItem.fromTopScore(item);
            case LibraryRankType.newBook:
              return LibraryBookItem.fromNewBook(item);
          }
        })
        .whereType<LibraryBookItem>()
        .toList();

    // 针对后端不支持服务端切片的分页进行客户端截取保护
    final List<LibraryBookItem> pagedBooks;
    if (type == LibraryRankType.hotLoan && books.length > rows) {
      final startIndex = (page - 1) * rows;
      if (startIndex >= books.length) {
        return const [];
      }
      pagedBooks = books.sublist(
        startIndex,
        (startIndex + rows).clamp(0, books.length),
      );
    } else {
      pagedBooks = books;
    }

    if (!loadCovers) {
      return pagedBooks;
    }

    final booksWithCover = await Future.wait(
      pagedBooks.map((b) async {
        var book = b;
        if (book.coverUrl == null || book.coverUrl!.isEmpty) {
          final coverUrl = await fetchCoverUrl(
            isbn: book.isbn,
            title: book.title,
            recordId: book.recordId,
            session: session,
          );
          book = book.copyWith(coverUrl: coverUrl);
        }

        // 若接口本身未返回馆藏数，则异步补充馆藏数
        if (book.totalHolding == null) {
          final holdings = await fetchBookHoldings(
            recordId: book.recordId,
            session: session,
          );
          if (holdings != null) {
            book = book.copyWith(
              totalHolding: holdings.total,
              onShelfHolding: holdings.onShelf,
            );
          }
        }

        return book;
      }),
    );

    return booksWithCover;
  }

  /// 统一检索图书（限定 docCode = ["1"]、resourceType = ["1"]，支持校区、出版年筛选与批量封面/馆藏补全）
  Future<LibraryBookSearchResult> searchBooks({
    required String keyword,
    int page = 1,
    int rows = 20,
    List<String> campusIds = const [],
    String? publishBegin,
    String? publishEnd,
    LibraryAuthSession? session,
    bool loadSupplementary = true,
  }) async {
    final trimmed = keyword.trim();
    final safeRows = rows.clamp(1, 50);
    if (trimmed.isEmpty) {
      return LibraryBookSearchResult(
        numFound: 0,
        page: page,
        rows: safeRows,
        books: const [],
        rawResultCount: 0,
      );
    }

    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.unifySearchPath}',
    );
    final normalizedBegin = publishBegin?.trim();
    final normalizedEnd = publishEnd?.trim();
    final requestBody = <String, dynamic>{
      'docCode': ['1'],
      'litCode': const [],
      'matchMode': '2',
      'resourceType': ['1'],
      'subject': const [],
      'discode1': const [],
      'publisher': const [],
      'libCode': const [],
      'locationId': const [],
      'eCollectionIds': const [],
      'neweCollectionIds': const [],
      'curLocationId': const [],
      'campusId': campusIds,
      'kindNo': const [],
      'collectionName': const [],
      'author': const [],
      'langCode': const [],
      'countryCode': const [],
      'publishBegin': normalizedBegin != null && normalizedBegin.isNotEmpty
          ? normalizedBegin
          : null,
      'publishEnd': normalizedEnd != null && normalizedEnd.isNotEmpty
          ? normalizedEnd
          : null,
      'coreInclude': const [],
      'ddType': const [],
      'verifyStatus': const [],
      'group': const [],
      'sortField': 'relevance',
      'sortClause': 'asc',
      'page': page,
      'rows': safeRows,
      'onlyOnShelf': null,
      'searchItems': null,
      'searchFieldContent': trimmed,
      'searchField': 'keyWord',
      'newCoreInclude': const [],
      'customSub': const [],
      'customSub0': const [],
      'indexSearch': 1,
    };

    final response = await _httpClient
        .post(
          uri,
          headers: _buildHeaders(session: session),
          body: jsonEncode(requestBody),
        )
        .timeout(HttpTimeout.normal);

    if (response.statusCode != 200) {
      throw LibraryApiException(
        '搜索图书失败',
        statusCode: response.statusCode,
      );
    }

    final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw LibraryApiException(
        decoded is Map<String, dynamic>
            ? (decoded['message'] as String? ?? '搜索图书失败')
            : '搜索图书失败',
      );
    }

    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      return LibraryBookSearchResult(
        numFound: 0,
        page: page,
        rows: safeRows,
        books: const [],
        rawResultCount: 0,
      );
    }

    final numFound = (data['numFound'] as num?)?.toInt() ?? 0;
    final rawList = (data['searchResult'] as List?) ?? const [];
    final rawItems = rawList.whereType<Map<String, dynamic>>().toList();

    final books = <LibraryBookItem>[];
    for (final item in rawItems) {
      final rawDocCode = item['docCode']?.toString().trim();
      if (rawDocCode != null && rawDocCode.isNotEmpty && rawDocCode != '1') {
        continue;
      }
      final book = LibraryBookItem.fromUnifySearch(item);
      if (book.recordId > 0) {
        books.add(book);
      }
    }

    if (!loadSupplementary || books.isEmpty) {
      return LibraryBookSearchResult(
        numFound: numFound,
        page: page,
        rows: safeRows,
        books: books,
        rawResultCount: rawItems.length,
      );
    }

    final supplemented = await _applyBatchBookSupplementary(
      books,
      session: session,
    );
    return LibraryBookSearchResult(
      numFound: numFound,
      page: page,
      rows: safeRows,
      books: supplemented,
      rawResultCount: rawItems.length,
    );
  }

  /// 批量获取图书封面和全馆馆藏数量（一页仅发一次请求）
  Future<
      Map<
          int,
          ({
            String? coverUrl,
            int? pCount,
            int? onShelfCount,
            double? avgScore
          })>> fetchBatchBookSupplementary(
    List<LibraryBookItem> books, {
    LibraryAuthSession? session,
  }) async {
    if (books.isEmpty) return const {};
    try {
      final uri = Uri.parse(
        '${LibraryConstants.baseUrl}${LibraryConstants.batchBookSupplementaryPath}',
      );
      final payload = {
        'items': [
          for (final book in books)
            {
              'title': book.title,
              'isbn': book.isbn ?? '',
              'recordId': book.recordId,
            },
        ],
      };

      final response = await _httpClient
          .post(
            uri,
            headers: _buildHeaders(session: session),
            body: jsonEncode(payload),
          )
          .timeout(HttpTimeout.normal);

      if (response.statusCode != 200) return const {};
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        return const {};
      }
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) return const {};

      final result = <int,
          ({
        String? coverUrl,
        int? pCount,
        int? onShelfCount,
        double? avgScore
      })>{};
      for (final entry in data.entries) {
        final id = int.tryParse(entry.key);
        if (id == null || entry.value is! Map<String, dynamic>) continue;
        final info = entry.value as Map<String, dynamic>;
        final rawCover = (info['duxiuImageUrl'] as String?)?.trim();
        final coverUrl =
            rawCover != null && rawCover.isNotEmpty ? rawCover : null;
        final pCount = (info['pCount'] as num?)?.toInt();
        final onShelfCount = (info['onShelfCount'] as num?)?.toInt();
        final rawScore = info['avgScore'];
        final score = rawScore is num
            ? rawScore.toDouble()
            : double.tryParse(rawScore?.toString() ?? '');
        result[id] = (
          coverUrl: coverUrl,
          pCount: pCount,
          onShelfCount: onShelfCount,
          avgScore: score != null && score > 0 ? score : null,
        );
      }
      return result;
    } on Object {
      return const {};
    }
  }

  Future<List<LibraryBookItem>> _applyBatchBookSupplementary(
    List<LibraryBookItem> books, {
    LibraryAuthSession? session,
  }) async {
    final map = await fetchBatchBookSupplementary(books, session: session);
    if (map.isEmpty) return books;
    return books.map((book) {
      final extra = map[book.recordId];
      if (extra == null) return book;
      return book.copyWith(
        coverUrl: (book.coverUrl == null || book.coverUrl!.isEmpty)
            ? extra.coverUrl
            : null,
        totalHolding: extra.pCount ?? book.totalHolding,
        onShelfHolding: extra.onShelfCount ?? book.onShelfHolding,
        rating: book.rating ?? extra.avgScore,
      );
    }).toList(growable: false);
  }

  /// 获取单本书籍的在架与总馆藏数
  Future<({int onShelf, int total})?> fetchBookHoldings({
    required int recordId,
    LibraryAuthSession? session,
  }) async {
    try {
      final uri = Uri.parse(
        '${LibraryConstants.baseUrl}${LibraryConstants.physicalGroupItemsPath}',
      );
      final response = await _httpClient
          .post(
            uri,
            headers: _buildHeaders(session: session),
            body: jsonEncode({
              'recordId': recordId,
              'groupCode': LibraryConstants.groupCode,
            }),
          )
          .timeout(HttpTimeout.normal);

      if (response.statusCode != 200) return null;
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        return null;
      }
      final data = decoded['data'];
      if (data is! List) return null;

      final total = data.length;
      final onShelf = data.where((item) {
        if (item is! Map<String, dynamic>) return false;
        final type = item['processType'];
        final code = item['processTypeCode'];
        return type == '在架' || code == '411';
      }).length;

      return (onShelf: onShelf, total: total);
    } on Object {
      return null;
    }
  }

  /// 获取图书全部单册馆藏原始列表
  Future<List<Map<String, dynamic>>> fetchRawBookHoldings({
    required int recordId,
    LibraryAuthSession? session,
  }) async {
    try {
      final uri = Uri.parse(
        '${LibraryConstants.baseUrl}${LibraryConstants.physicalGroupItemsPath}',
      );
      final response = await _httpClient
          .post(
            uri,
            headers: _buildHeaders(session: session),
            body: jsonEncode({
              'recordId': recordId,
              'groupCode': LibraryConstants.groupCode,
            }),
          )
          .timeout(HttpTimeout.normal);

      if (response.statusCode != 200) return const [];
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        return const [];
      }
      final data = decoded['data'];
      if (data is! List) return const [];
      return data.whereType<Map<String, dynamic>>().toList();
    } on Object {
      return const [];
    }
  }

  /// 获取图书完整书目详情（包含 baseMarcInfoDto、marcDetl、bean2List 等）
  Future<Map<String, dynamic>?> fetchBookDetail({
    required int recordId,
    LibraryAuthSession? session,
  }) async {
    try {
      final uri = Uri.parse(
        '${LibraryConstants.baseUrl}${LibraryConstants.searchResultDetailPath}?recordId=$recordId',
      );
      final response = await _httpClient
          .get(
            uri,
            headers: _buildHeaders(session: session),
          )
          .timeout(HttpTimeout.normal);

      if (response.statusCode != 200) return null;
      final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        return null;
      }
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) return null;
      return data;
    } on Object {
      return null;
    }
  }

  /// 获取当前在借图书列表（POST /find/loanInfo/loanList，不启用本地缓存）。
  Future<LibraryLoanPageResult> fetchLoanList({
    int page = 1,
    int rows = 50,
    LibraryAuthSession? session,
  }) async {
    return _fetchLoanCollection(
      path: LibraryConstants.loanListPath,
      page: page,
      rows: rows,
      isHistory: false,
      fallbackMessage: '获取当前借阅列表失败',
      session: session,
    );
  }

  /// 获取全部当前在借图书（按服务端 numFound 与去重兜底翻页拉全，不启用本地缓存）。
  Future<List<LibraryLoanItem>> fetchAllActiveLoans({
    LibraryAuthSession? session,
  }) async {
    final first = await fetchLoanList(page: 1, rows: 50, session: session);
    final result = <LibraryLoanItem>[];
    final seen = <String>{};
    for (final item in first.items) {
      if (seen.add(item.stableKey)) {
        result.add(item);
      }
    }
    var page = 2;
    while (result.length < first.numFound && first.items.isNotEmpty) {
      final next = await fetchLoanList(page: page, rows: 50, session: session);
      var added = 0;
      for (final item in next.items) {
        if (seen.add(item.stableKey)) {
          result.add(item);
          added++;
        }
      }
      if (next.items.isEmpty || added == 0) break;
      page++;
    }
    return result;
  }

  /// 获取历史借阅列表（POST /find/loanInfo/loanHistoryList，不启用本地缓存）。
  Future<LibraryLoanPageResult> fetchLoanHistoryList({
    int page = 1,
    int rows = 20,
    LibraryAuthSession? session,
  }) async {
    return _fetchLoanCollection(
      path: LibraryConstants.loanHistoryListPath,
      page: page,
      rows: rows,
      isHistory: true,
      fallbackMessage: '获取历史借阅记录失败',
      session: session,
    );
  }

  Future<LibraryLoanPageResult> _fetchLoanCollection({
    required String path,
    required int page,
    required int rows,
    required bool isHistory,
    required String fallbackMessage,
    LibraryAuthSession? session,
  }) async {
    final safePage = page < 1 ? 1 : page;
    final safeRows = rows.clamp(1, 50);
    final uri = Uri.parse('${LibraryConstants.baseUrl}$path');
    final response = await _httpClient
        .post(
          uri,
          headers: _buildHeaders(session: session),
          body: jsonEncode({
            'page': safePage,
            'rows': safeRows,
          }),
        )
        .timeout(HttpTimeout.normal);

    final payload = _decodePersonalPayload(
      response,
      fallbackMessage: fallbackMessage,
    );
    if (payload is! Map<String, dynamic>) {
      return LibraryLoanPageResult(
        items: const [],
        numFound: 0,
        page: safePage,
        rows: safeRows,
      );
    }

    final rawList = (payload['searchResult'] as List?) ??
        (payload['list'] as List?) ??
        (payload['result'] as List?) ??
        const [];
    final items = rawList
        .whereType<Map<String, dynamic>>()
        .map((item) => LibraryLoanItem.fromJson(item, isHistory: isHistory))
        .toList(growable: false);
    final numFound = (payload['numFound'] as num?)?.toInt() ?? items.length;
    return LibraryLoanPageResult(
      items: items,
      numFound: numFound,
      page: safePage,
      rows: safeRows,
    );
  }

  /// 获取待办提醒计数（预约请求、逾期在借、未处理违章），非借阅额度。
  Future<LibraryTodoCounts> fetchUserLimit({
    LibraryAuthSession? session,
  }) async {
    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.userLimitPath}',
    );
    final response = await _httpClient
        .get(
          uri,
          headers: _buildHeaders(session: session),
        )
        .timeout(HttpTimeout.normal);

    final payload = _decodePersonalPayload(
      response,
      fallbackMessage: '获取借阅提醒状态失败',
    );
    if (payload is Map<String, dynamic>) {
      return LibraryTodoCounts.fromJson(payload);
    }
    return const LibraryTodoCounts();
  }

  /// 获取读者借阅规则与可借上限（POST /find/userInfo/UserLoanRules）。
  Future<List<LibraryLoanRule>> fetchLoanRules({
    LibraryAuthSession? session,
  }) async {
    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.loanRulesPath}',
    );
    final response = await _httpClient
        .post(
          uri,
          headers: _buildHeaders(session: session),
          body: '{}',
        )
        .timeout(HttpTimeout.normal);

    final payload = _decodePersonalPayload(
      response,
      fallbackMessage: '获取借阅规则失败',
    );
    final List<dynamic> rawList;
    if (payload is List) {
      rawList = payload;
    } else if (payload is Map<String, dynamic>) {
      rawList = (payload['list'] as List?) ??
          (payload['rules'] as List?) ??
          (payload['data'] as List?) ??
          const [];
    } else {
      rawList = const [];
    }
    return rawList
        .whereType<Map<String, dynamic>>()
        .map(LibraryLoanRule.fromJson)
        .toList(growable: false);
  }

  /// 获取读者证基础信息（GET /find/userInfo/getUserInfo）。
  Future<LibraryReaderCardInfo?> fetchReaderCardInfo({
    LibraryAuthSession? session,
  }) async {
    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.checkFlagUserInfoPath}',
    );
    final response = await _httpClient
        .get(
          uri,
          headers: _buildHeaders(session: session),
        )
        .timeout(HttpTimeout.normal);

    final payload = _decodePersonalPayload(
      response,
      fallbackMessage: '获取读者证状态失败',
    );
    if (payload is Map<String, dynamic>) {
      return LibraryReaderCardInfo.fromJson(payload);
    }
    return null;
  }

  /// 续借当前在借图书（POST /find/lendbook/reNew，失败原样透出服务端报错原因）。
  Future<String?> renewLoan({
    required String barcode,
    int? loanId,
    LibraryAuthSession? session,
  }) async {
    final trimmedBarcode = barcode.trim();
    if (trimmedBarcode.isEmpty && loanId == null) {
      throw const LibraryApiException('缺少册条码，无法发起续借');
    }
    final uri = Uri.parse(
      '${LibraryConstants.baseUrl}${LibraryConstants.renewLoanPath}',
    );
    final body = <String, dynamic>{
      if (trimmedBarcode.isNotEmpty) 'barcode': trimmedBarcode,
      if (loanId != null) 'loanId': loanId,
    };
    final response = await _httpClient
        .post(
          uri,
          headers: _buildHeaders(session: session),
          body: jsonEncode(body),
        )
        .timeout(HttpTimeout.normal);

    final envelope = _decodeRawEnvelope(
      response,
      fallbackMessage: '续借失败',
    );
    if (envelope is Map<String, dynamic>) {
      final msg = (envelope['message'] as String?)?.trim();
      return msg != null && msg.isNotEmpty ? msg : null;
    }
    return null;
  }

  Object? _decodePersonalPayload(
    http.Response response, {
    required String fallbackMessage,
  }) {
    final raw = _decodeRawEnvelope(
      response,
      fallbackMessage: fallbackMessage,
    );
    if (raw is Map<String, dynamic> && raw.containsKey('success')) {
      final data = raw['data'];
      if (data != null) return data;
      if (raw.containsKey('searchResult') ||
          raw.containsKey('user') ||
          raw.containsKey('userRequestNum')) {
        return raw;
      }
      return null;
    }
    return raw;
  }

  Object? _decodeRawEnvelope(
    http.Response response, {
    required String fallbackMessage,
  }) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw LibraryApiAuthRequiredException(
        '图书馆登录状态已失效，请重新验证校园身份',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw LibraryApiException(
        fallbackMessage,
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw LibraryApiException(fallbackMessage);
    }

    if (decoded is Map<String, dynamic> && decoded.containsKey('success')) {
      if (decoded['success'] != true) {
        final rawCode = decoded['errCode'] ?? decoded['errorCode'];
        final codeInt =
            rawCode is num ? rawCode.toInt() : int.tryParse('$rawCode');
        final failReason = (decoded['failReason'] as String?)?.trim();
        final message = (decoded['message'] as String?)?.trim();
        final effectiveMessage = (failReason != null && failReason.isNotEmpty)
            ? failReason
            : (message != null && message.isNotEmpty
                ? message
                : fallbackMessage);

        final lower = effectiveMessage.toLowerCase();
        if (codeInt == 401 ||
            codeInt == 403 ||
            effectiveMessage.contains('未登录') ||
            effectiveMessage.contains('请先登录') ||
            effectiveMessage.contains('登录失效') ||
            lower.contains('token') && lower.contains('invalid')) {
          throw LibraryApiAuthRequiredException(
            effectiveMessage,
            statusCode: codeInt,
          );
        }
        throw LibraryApiException(effectiveMessage, statusCode: codeInt);
      }
    }
    return decoded;
  }
}
