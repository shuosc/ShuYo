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

    test('searchBooks restricts docCode to books and merges batch supplementary',
        () async {
      final requestedPaths = <String>[];
      final client = MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == LibraryConstants.unifySearchPath) {
          expect(request.headers['groupCode'], LibraryConstants.groupCode);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['docCode'], ['1']);
          expect(body['resourceType'], ['1']);
          expect(body['searchField'], 'keyWord');
          expect(body['searchFieldContent'], '机器学习');
          expect(body['sortField'], 'relevance');
          expect(body['page'], 1);
          expect(body['rows'], 20);
          return utf8Response(
            jsonEncode({
              'success': true,
              'data': {
                'numFound': 25,
                'searchResult': [
                  {
                    'recordId': 796762,
                    'title': '机器学习',
                    'author': '周志华著',
                    'publisher': '清华大学出版社',
                    'publishYear': '2016',
                    'isbn': '978-7-302-42328-7',
                    'callNoOne': 'TP181/Z78J',
                    'docCode': 1,
                    'physicalCount': 6,
                    'onShelfCountI': 4,
                  },
                  {
                    'recordId': 977968,
                    'title': '期刊噪音条目',
                    'docCode': 2,
                  },
                ],
              },
            }),
            200,
          );
        } else if (request.url.path ==
            LibraryConstants.batchBookSupplementaryPath) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final items = body['items'] as List<dynamic>;
          expect(items, hasLength(1));
          expect((items.first as Map<String, dynamic>)['recordId'], 796762);
          return utf8Response(
            jsonEncode({
              'success': true,
              'data': {
                '796762': {
                  'duxiuImageUrl': 'https://cover.test/ml-batch.jpg',
                  'pCount': 6,
                  'onShelfCount': 5,
                  'avgScore': 4.8,
                },
              },
            }),
            200,
          );
        }
        return utf8Response('Not Found', 404);
      });

      final apiClient = LibraryApiClient(httpClient: client);
      final result = await apiClient.searchBooks(
        keyword: ' 机器学习 ',
        page: 1,
        rows: 20,
      );

      expect(requestedPaths, [
        LibraryConstants.unifySearchPath,
        LibraryConstants.batchBookSupplementaryPath,
      ]);
      expect(result.numFound, 25);
      expect(result.books, hasLength(1));
      expect(result.books.first.recordId, 796762);
      expect(result.books.first.coverUrl, 'https://cover.test/ml-batch.jpg');
      expect(result.books.first.totalHolding, 6);
      expect(result.books.first.onShelfHolding, 5);
      expect(result.books.first.rating, 4.8);
      // rawResultCount == 2 < rows(20) 说明这是后端的尾页数据
      expect(result.hasMore(1), isFalse);
    });

    test('searchBooks throws LibraryApiException when server returns rate limit',
        () async {
      final client = MockClient((request) async {
        return utf8Response(
          jsonEncode({
            'success': false,
            'message': '系统访问中断，请稍后再试！',
          }),
          200,
        );
      });

      final apiClient = LibraryApiClient(httpClient: client);
      await expectLater(
        () => apiClient.searchBooks(keyword: '机器学习'),
        throwsA(
          isA<LibraryApiException>().having(
            (e) => e.message,
            'message',
            '系统访问中断，请稍后再试！',
          ),
        ),
      );
    });

    test('LibraryBookSearchResult stops pagination at numFound boundary', () {
      const page1 = LibraryBookSearchResult(
        numFound: 40,
        page: 1,
        rows: 20,
        books: [],
        rawResultCount: 20,
      );
      const page2 = LibraryBookSearchResult(
        numFound: 40,
        page: 2,
        rows: 20,
        books: [],
        rawResultCount: 20,
      );
      expect(page1.hasMore(20), isTrue);
      expect(page2.hasMore(40), isFalse);
    });
  });
}
