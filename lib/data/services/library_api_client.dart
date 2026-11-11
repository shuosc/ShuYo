import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../core/client_user_agent.dart';
import '../../core/library_constants.dart';
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
    final coverUrl = await fetchCoverUrl(
      isbn: book.isbn,
      title: book.title,
      recordId: book.recordId,
      session: session,
    );

    return book.copyWith(coverUrl: coverUrl);
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
        if (isbn != null && isbn.isNotEmpty) 'isbn': isbn,
        if (title != null && title.isNotEmpty) 'title': title,
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
}
