import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/library_book_item.dart';

void main() {
  group('LibraryBookItem.parsePublisherAndYear', () {
    test('普通年份黏连在出版社后', () {
      final res1 = LibraryBookItem.parsePublisherAndYear('南京大学出版社2003', null);
      expect(res1.publisher, '南京大学出版社');
      expect(res1.year, '2003');

      final res2 = LibraryBookItem.parsePublisherAndYear('北京大学出版社2012', null);
      expect(res2.publisher, '北京大学出版社');
      expect(res2.year, '2012');

      final res3 =
          LibraryBookItem.parsePublisherAndYear('《城市轨道交通研究》杂志社1998-', null);
      expect(res3.publisher, '《城市轨道交通研究》杂志社');
      expect(res3.year, '1998-');
    });

    test('特殊纪年民国处理（民国XX年·XXXX）', () {
      final res1 =
          LibraryBookItem.parsePublisherAndYear('允晨文化公司民国80[1991]', null);
      expect(res1.publisher, '允晨文化公司');
      expect(res1.year, '民国80年·1991');

      final res2 =
          LibraryBookItem.parsePublisherAndYear('水牛图书出版公司民国73[1984]', null);
      expect(res2.publisher, '水牛图书出版公司');
      expect(res2.year, '民国73年·1984');

      final res3 =
          LibraryBookItem.parsePublisherAndYear('台湾商务印书馆,民国75[1986.12]', null);
      expect(res3.publisher, '台湾商务印书馆');
      expect(res3.year, '民国75年·1986');
    });

    test('单独仅民国XX年无西元括号的情况', () {
      final res = LibraryBookItem.parsePublisherAndYear('某某商务印书馆民国36年', null);
      expect(res.publisher, '某某商务印书馆');
      expect(res.year, '民国36年·1947');
    });

    test('正常已有独立年份字段的情况保持不变', () {
      final res = LibraryBookItem.parsePublisherAndYear('人民文学出版社', '2017');
      expect(res.publisher, '人民文学出版社');
      expect(res.year, '2017');
    });
  });
}
