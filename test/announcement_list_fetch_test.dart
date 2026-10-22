import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuyo/data/models/announcement_source.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

void main() {
  test('a multi-column list fetch returns each column and aligned page cursors',
      () async {
    final source = AnnouncementSource.byId('bkzsw');
    final requested = <String>[];
    final client = AnnouncementApiClient(
      httpClient: MockClient((request) async {
        final index = source.listUrls.indexOf(request.url.toString());
        requested.add(request.url.toString());
        expect(index, isNonNegative);
        final html = '<div class="list-rContent-down">'
            '<li id="line_u5_0"><a href="/info/123/$index.htm">'
            '公告 $index</a><i>2026-10-${(20 - index).toString().padLeft(2, '0')}</i></li>'
            '</div>'
            '<a class="Next" href="/next-$index.htm">下页</a>';
        return http.Response.bytes(utf8.encode(html), 200);
      }),
    );

    final page = await client.fetchPage(source: source);
    expect(requested, unorderedEquals(source.listUrls));
    expect(requested, hasLength(10));
    expect(page.items.map((item) => item.title), [
      for (var index = 0; index < 10; index++) '公告 $index',
    ]);
    expect(page.items.map((item) => item.column), source.columnNames);
    expect(page.nextPageUrls, [
      for (var index = 0; index < 10; index++)
        'https://bkzsw.shu.edu.cn/next-$index.htm',
    ]);
    client.close();
  });
}
