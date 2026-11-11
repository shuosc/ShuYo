import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/utils/library_author_parser.dart';

void main() {
  group('LibraryAuthorParser', () {
    test('纯中国大陆作者不显示国旗与前缀', () {
      final res = LibraryAuthorParser.parse('余华著');
      expect(res.authors.length, 1);
      expect(res.authors.first.name, '余华');
      expect(res.authors.first.flagEmoji, isNull);
      expect(res.authors.first.badgeText, isNull);
      expect(res.toDisplayString(), '余华 著');
    });

    test('中国古代朝代不显示国旗，只保留朝代名', () {
      final res = LibraryAuthorParser.parse('[清] 曹雪芹 著');
      expect(res.authors.length, 1);
      final author = res.authors.first;
      expect(author.name, '曹雪芹');
      expect(author.isAncient, isTrue);
      expect(author.flagEmoji, isNull);
      expect(author.badgeText, '[清]');
      expect(res.toDisplayString(), '[清] · 曹雪芹 著');
    });

    test('中国港澳台显示对应地区旗帜并补全地名', () {
      final tw = LibraryAuthorParser.parse('[中国台湾]林海音');
      expect(tw.authors.length, 1);
      final authorTw = tw.authors.first;
      expect(authorTw.name, '林海音');
      expect(authorTw.isRegion, isTrue);
      expect(authorTw.flagEmoji, '🇨🇳');
      expect(authorTw.countryName, '中国台湾');
      expect(authorTw.badgeText, '🇨🇳 中国台湾');
      expect(tw.toDisplayString(), '🇨🇳 中国台湾 · 林海音 著');

      final hk = LibraryAuthorParser.parse('[香港] 金庸 著');
      final authorHk = hk.authors.first;
      expect(authorHk.flagEmoji, '🇭🇰');
      expect(authorHk.badgeText, '🇭🇰 中国香港');
      expect(hk.toDisplayString(), '🇭🇰 中国香港 · 金庸 著');

      final mo = LibraryAuthorParser.parse('[澳门] 某某 著');
      final authorMo = mo.authors.first;
      expect(authorMo.flagEmoji, '🇲🇴');
      expect(authorMo.badgeText, '🇲🇴 中国澳门');
      expect(mo.toDisplayString(), '🇲🇴 中国澳门 · 某某 著');
    });

    test('外国作者显示国旗Emoji与国家全称', () {
      final jp = LibraryAuthorParser.parse('(日) 知念实希人著');
      expect(jp.authors.first.name, '知念实希人');
      expect(jp.authors.first.flagEmoji, '🇯🇵');
      expect(jp.authors.first.countryName, '日本');
      expect(jp.authors.first.badgeText, '🇯🇵 日本');
      expect(jp.toDisplayString(), '🇯🇵 日本 · 知念实希人 著');

      final us = LibraryAuthorParser.parse('(美) 约翰·斯坦贝克著');
      expect(us.authors.first.flagEmoji, '🇺🇸');
      expect(us.authors.first.countryName, '美国');
      expect(us.authors.first.badgeText, '🇺🇸 美国');
      expect(us.toDisplayString(), '🇺🇸 美国 · 约翰·斯坦贝克 著');
    });

    test('原著与改编、多责任人分离', () {
      final res = LibraryAuthorParser.parse('原著管致中, 夏恭恪, 孟桥; 主编孟桥, 夏恭恪');
      expect(res.originals.length, 3);
      expect(res.editors.length, 2);
      expect(res.originals.first.name, '管致中');
      expect(res.editors.first.name, '孟桥');
      expect(res.toDisplayString(), '管致中, 夏恭恪 等 原著');
    });

    test('复杂中译本包含作者与译者', () {
      final res = LibraryAuthorParser.parse(
        '(美) 拉斯·昂格尔, 卡洛琳·钱德勒著,张贝,袁萌; 张贝, 袁萌译',
      );
      expect(res.authors.length, 2);
      expect(res.translators.length, 2);
      expect(res.authors.first.name, '拉斯·昂格尔');
      expect(res.authors.first.badgeText, '🇺🇸 美国');
      expect(res.translators.first.name, '张贝');
      expect(res.translators.last.name, '袁萌');
      expect(
        res.toDisplayString(),
        '🇺🇸 美国 · 拉斯·昂格尔, 卡洛琳·钱德勒 著 / 张贝, 袁萌 译',
      );
    });

    test('带外文原名与特殊括号作者', () {
      final res = LibraryAuthorParser.parse('(英)波普(Popper,K.R.)著');
      expect(res.authors.length, 1);
      final author = res.authors.first;
      expect(author.name, '波普');
      expect(author.originalName, 'Popper,K.R.');
      expect(author.flagEmoji, '🇬🇧');
      expect(author.countryName, '英国');
      expect(author.badgeText, '🇬🇧 英国');
      expect(res.toDisplayString(), '🇬🇧 英国 · 波普 著');
    });

    test('处理西方学者姓名缩写及定语助词(如普朗特的,L.著)', () {
      final res = LibraryAuthorParser.parse('(德)普朗特的,L.著');
      expect(res.authors.length, 1);
      final author = res.authors.first;
      expect(author.name, '普朗特');
      expect(author.flagEmoji, '🇩🇪');
      expect(author.countryName, '德国');
      expect(author.badgeText, '🇩🇪 德国');
      expect(res.toDisplayString(), '🇩🇪 德国 · 普朗特 著');
    });

    test('空作者解析返回横杠 -', () {
      final res = LibraryAuthorParser.parse('');
      expect(res.toDisplayString(), '-');

      final nullRes = LibraryAuthorParser.parse(null);
      expect(nullRes.toDisplayString(), '-');
    });

    test('解析多责任者带“编者”前缀与纯英文姓名(如 339263 英汉双解财会词典)', () {
      final res = LibraryAuthorParser.parse(
        '编者 (英) P. H. Collin, Adrian Joliffe;译者张炜 ... [等]',
      );
      expect(res.editors.length, 2);
      expect(res.editors[0].name, 'P. H. Collin');
      expect(res.editors[0].countryName, '英国');
      expect(res.editors[0].flagEmoji, '🇬🇧');
      expect(res.editors[1].name, 'Adrian Joliffe');
      expect(res.translators.length, 1);
      expect(res.translators[0].name, '张炜');
      expect(res.hasEtAl, isTrue);
    });
  });
}
