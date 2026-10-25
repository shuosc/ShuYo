import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/features/home/announcement_search_matches.dart';

void main() {
  test('blank searches have no matching pattern', () {
    expect(announcementSearchPattern(' \n\t '), isNull);
  });

  test('matches independent words without duplicate alternatives', () {
    final pattern =
        announcementSearchPattern('大学 大学实验室 UNIVERSITY university')!;
    expect(
      pattern.allMatches('大学实验室和大学的 University').map((match) => match.group(0)),
      ['大学实验室', '大学', 'University'],
    );
    expect(pattern.pattern, 'UNIVERSITY|大学实验室|大学');
  });

  test('regular expression metacharacters remain literal', () {
    final pattern = announcementSearchPattern('C++ [甲] a.b')!;
    expect(
      pattern
          .allMatches('C++ 与 [甲] a.b aXb CCCC')
          .map((match) => match.group(0)),
      ['C++', '[甲]', 'a.b'],
    );
  });

  test('case insensitive matches preserve original offsets and spelling', () {
    const text = '😀前缀 AbC 内容 abc';
    final matches = announcementSearchPattern('abc')!.allMatches(text).toList();
    expect(matches.map((match) => match.group(0)), ['AbC', 'abc']);
    expect(matches.first.start, text.indexOf('AbC'));
    expect(text.substring(matches.first.start, matches.first.end), 'AbC');
    expect(matches.last.start, text.lastIndexOf('abc'));
  });
}
