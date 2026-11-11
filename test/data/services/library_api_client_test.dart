import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/core/library_constants.dart';
import 'package:shuyo/data/models/library_book_item.dart';
import 'package:shuyo/data/services/library_api_client.dart';
import 'package:shuyo/data/services/library_auth_service.dart';

void main() {
  http.Response utf8Response(String body, int statusCode) {
    return http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  group('LibraryApiClient', () {
    test('fetchDailyRecommend parses book and cover correctly', () async {
      final client = MockClient((request) async {
        if (request.url.path == LibraryConstants.dailyRecommendPath) {
          expect(request.headers['groupCode'], LibraryConstants.groupCode);
          expect(request.headers['jwtOpacAuth'], 'fake-jwt');
          return utf8Response(
            jsonEncode({
              'success': true,
              'message': '操作成功',
              'errCode': 200,
              'data': {
                'recordId': 1132202,
                'title': '“傻瓜”计量经济学与Stata应用',
                'author': '习明明编著',
                'publisher': '经济科学出版社',
                'publishYear': '2024',
                'isbn': '978-7-5218-5943-0',
                'callNo': 'F224.0-39/X19(2)',
                'adstract': '本书内容涵盖Stata的数据处理...',
              },
            }),
            200,
          );
        } else if (request.url.path == LibraryConstants.duxiuCoverPath) {
          expect(request.url.queryParameters['recordId'], '1132202');
          return utf8Response(
            jsonEncode({
              'success': true,
              'message': '操作成功',
              'errCode': 200,
              'data': 'https://cover01.chaoxing.com/cover/example.jpg',
            }),
            200,
          );
        }
        return utf8Response('Not Found', 404);
      });

      final apiClient = LibraryApiClient(httpClient: client);
      const session = LibraryAuthSession(
        studentId: '25120000',
        userName: '张三',
        jwt: 'fake-jwt',
        jwtHeader: 'jwtOpacAuth',
      );

      final book = await apiClient.fetchDailyRecommend(session: session);
      expect(book, isNotNull);
      expect(book!.recordId, 1132202);
      expect(book.title, '“傻瓜”计量经济学与Stata应用');
      expect(book.author, '习明明编著');
      expect(book.publisher, '经济科学出版社');
      expect(book.publishYear, '2024');
      expect(book.summary, '本书内容涵盖Stata的数据处理...');
      expect(book.coverUrl, 'https://cover01.chaoxing.com/cover/example.jpg');
    });

    test('fetchDailyRecommend handles cover failure gracefully', () async {
      final client = MockClient((request) async {
        if (request.url.path == LibraryConstants.dailyRecommendPath) {
          return utf8Response(
            jsonEncode({
              'success': true,
              'message': '操作成功',
              'errCode': 200,
              'data': {
                'recordId': 1001,
                'title': '测试图书',
              },
            }),
            200,
          );
        }
        return utf8Response('Internal Error', 500);
      });

      final apiClient = LibraryApiClient(httpClient: client);
      final book = await apiClient.fetchDailyRecommend();
      expect(book, isNotNull);
      expect(book!.recordId, 1001);
      expect(book.coverUrl, isNull);
    });

    test('fetchDailyRecommend throws on API error', () async {
      final client = MockClient((request) async {
        return utf8Response(
          jsonEncode({
            'success': false,
            'message': '服务异常',
            'errCode': 500,
          }),
          200,
        );
      });

      final apiClient = LibraryApiClient(httpClient: client);
      expect(
        () => apiClient.fetchDailyRecommend(),
        throwsA(isA<LibraryApiException>()),
      );
    });
    test('fetchRankList parses hot loan books correctly', () async {
      final client = MockClient((request) async {
        if (request.url.path == LibraryConstants.hotLoanPath) {
          expect(request.headers['groupCode'], LibraryConstants.groupCode);
          return utf8Response(
            jsonEncode({
              'success': true,
              'data': {
                'result': [
                  {
                    'recordId': 796762,
                    'title': '机器学习',
                    'author': '周志华著',
                    'publish': '清华大学出版社',
                    'pubDate': '2016',
                    'loanCount': 5,
                    'isbn': '978-7-302-42328-7',
                    'callNo': 'TP181/Z78J',
                  }
                ]
              }
            }),
            200,
          );
        } else if (request.url.path == LibraryConstants.duxiuCoverPath) {
          return utf8Response(
            jsonEncode({
              'success': true,
              'data': 'https://cover.test/ml.jpg',
            }),
            200,
          );
        }
        return utf8Response('Not Found', 404);
      });

      final apiClient = LibraryApiClient(httpClient: client);
      final list = await apiClient.fetchRankList(
        type: LibraryRankType.hotLoan,
        loadCovers: true,
      );

      expect(list.length, 1);
      expect(list.first.recordId, 796762);
      expect(list.first.title, '机器学习');
      expect(list.first.author, '周志华著');
      expect(list.first.badgeText, '借阅 5 次');
      expect(list.first.coverUrl, 'https://cover.test/ml.jpg');
    });
  });
}
