import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/client_user_agent.dart';
import '../../core/library_constants.dart';
import '../models/library_book_item.dart';
import '../models/library_daily_recommend.dart';
import 'http_timeout.dart';
import 'library_auth_service.dart';

class LibraryApiException implements Exception {
  const LibraryApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode != null ? '$message ($statusCode)' : message;
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
    NewBookCampus newBookCampus = NewBookCampus.all,
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
      requestBody['campusId'] = newBookCampus.campusIds;
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
}
