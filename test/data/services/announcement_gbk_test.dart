import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/announcement_gbk.dart';

void main() {
  test('decodes simplified Chinese department and author metadata', () {
    expect(
      decodeAnnouncementGbk(_hex('c9cfbaa3b5e7d3b0d1a7d4ba20d5c5c8fd')),
      '上海电影学院 张三',
    );
    expect(
      decodeAnnouncementGbk(_hex(
        'd7f7d5dfa3bad5d4c1e820c0b4d4b4a3bad6d0c5b7b9a4b3ccbcbccaf5d1a7d4ba'
        '20323032362d30392d31382031303a30303a3336',
      )),
      '作者：赵凌 来源：中欧工程技术学院 2026-09-18 10:00:36',
    );
  });

  test('decodes traditional Chinese instead of a sample-only dictionary', () {
    expect(
      decodeAnnouncementGbk(_hex(
          'd6d09a57b9a4b3ccbcbcd0678c57d4ba209cd8b8e7c841eb8ad3b08c57d4ba')),
      '中歐工程技術學院 溫哥華電影學院',
    );
  });

  test('keeps ASCII and the Windows-936 euro extension', () {
    expect(decodeAnnouncementGbk([]), isEmpty);
    expect(decodeAnnouncementGbk('A\u0000\t\r\n2026-10-26'.codeUnits),
        'A\u0000\t\r\n2026-10-26');
    expect(decodeAnnouncementGbk([0x41, 0x80, 0x42]), 'A€B');
    expect(decodeAnnouncementGbk([0x81, 0x40]), '丂');
  });

  test('rejects incomplete, invalid and unmapped byte sequences', () {
    for (final bytes in <List<int>>[
      [0x81],
      [0xff],
      [0x81, 0x7f],
      [0x81, 0x3f],
      [0x81, 0xff],
      [0xfe, 0xfe],
      [-1],
      [256],
      [0x41, 0x81],
    ]) {
      expect(() => decodeAnnouncementGbk(bytes), throwsFormatException,
          reason: '$bytes must not silently become replacement characters');
    }
  });

  test('reports GBK representability for export title verification', () {
    for (final rune in '上海电影学院中歐赵凌A?€\u0000'.runes) {
      expect(isAnnouncementGbkCharacter(rune), isTrue,
          reason: 'U+${rune.toRadixString(16)}');
    }
    for (final rune in [-1, 0x2212, 0x1f600, 0xd800, 0x110000]) {
      expect(isAnnouncementGbkCharacter(rune), isFalse,
          reason: 'U+${rune.toRadixString(16)}');
    }
  });
}

List<int> _hex(String hex) => [
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ];
