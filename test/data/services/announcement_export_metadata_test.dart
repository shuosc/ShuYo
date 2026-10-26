import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/announcement_export_metadata.dart';

// Captured export headings, including their GBK quoted-printable soft wraps.
const _shuHeading = '''
<div align=3D"center"><p><h1>=B9=D8=D3=DA=B7=A2=B2=BC=C7=F8=C8=CB=B4=F3=B4=
=FA=B1=ED=BB=BB=BD=EC=D1=A1=BE=D9=D1=A1=C3=F1=C3=FB=B5=A5=A3=A8=D2=BB=BA=C5=
=B9=AB=B8=E6=A3=A9=B5=C4=CD=A8=D6=AA</h1></p> =BA=AB=CF=FE=CF=BC  2026-10-2=
6 19:46:41  =B5=B3=CE=AF=D0=FB=B4=AB=B2=BF </div>''';

const _utseusHeading = '''
<div align=3D"center"><p><h1>=D6=D0=C5=B7=D1=A7=D4=BA2027=C4=EA=BD=D3=CA=D5=
=CD=C6=BC=F6=C3=E2=CA=D4=B9=A5=B6=C1=CB=B6=CA=BF=D1=A7=CE=BB=D1=D0=BE=BF=C9=
=FA=B8=B4=CA=D4=B9=A4=D7=F7=B0=EC=B7=A8</h1></p> =D5=D4=C1=E8  2026-09-18 1=
0:00:36 </div>''';

const _archiveHeading = '''
<div align=3D"center"><p><h1>=B9=D8=D3=DA=CE=D2=D0=A32026=BD=EC=A3=A8=BA=AC=
=CD=F9=BD=EC=A3=A9=B1=BE=BF=C6=B1=CF=D2=B5=C9=FA=CF=DF=C9=CF=B0=EC=C0=ED  =
=B5=B5=B0=B8=D7=AA=B5=DD=CA=D6=D0=F8=B5=C4=CD=A8=D6=AA</h1></p> 2026-05-11 =
09:40:46 </div>''';

List<int> _export(String heading, {String charset = 'GBK'}) => ascii.encode(
      'Message-ID: <generated-2030-12-31@example>\r\n'
      'Mime-Version: 1.0\r\n'
      'Content-Type: multipart/related;\r\n'
      '\tboundary="----test-export"\r\n\r\n'
      '------test-export\r\n'
      'Content-Type: text/html;charset=$charset\r\n'
      'Content-Transfer-Encoding: quoted-printable\r\n'
      'Content-Location: \r\n\r\n'
      '${heading.replaceAll('\n', '\r\n')}',
    );

void main() {
  group('public Word export metadata', () {
    test('decodes official author and independently stored department', () {
      final metadata =
          AnnouncementExportMetadata.tryParse(_export(_shuHeading));

      expect(metadata, isNotNull);
      expect(metadata!.title, '关于发布区人大代表换届选举选民名单（一号公告）的通知');
      expect(metadata.dateText, '2026-10-26');
      expect(metadata.publishedAt, DateTime(2026, 10, 26, 19, 46, 41));
      expect(metadata.author, '韩晓霞');
      expect(metadata.department, '党委宣传部');
    });

    test('reads UTSEUS publication date instead of dates in the body', () {
      final metadata = AnnouncementExportMetadata.tryParse(_export(
        '$_utseusHeading<div><p>2026-09-16 00:00:00</p>'
        '<p>2026-09-20 17:00:00</p>',
      ));

      expect(metadata!.dateText, '2026-09-18');
      expect(metadata.publishedAt, DateTime(2026, 9, 18, 10, 0, 36));
      expect(metadata.author, '赵凌');
      expect(metadata.department, isEmpty);
    });

    test('a missing author remains empty rather than taking the date', () {
      final metadata = AnnouncementExportMetadata.tryParse(
        _export(_archiveHeading),
      );

      expect(metadata!.dateText, '2026-05-11');
      expect(metadata.author, isEmpty);
      expect(metadata.department, isEmpty);
    });

    test('every incomplete byte prefix stays incomplete across soft wraps', () {
      final bytes = _export(_shuHeading);
      for (var length = 0; length < bytes.length; length++) {
        final prefix = bytes.sublist(0, length);
        expect(AnnouncementExportMetadata.isComplete(prefix), isFalse,
            reason: 'Received only $length bytes');
        expect(AnnouncementExportMetadata.tryParse(prefix), isNull,
            reason: 'Received only $length bytes');
      }
      expect(AnnouncementExportMetadata.isComplete(bytes), isTrue);
      expect(AnnouncementExportMetadata.tryParse(bytes)!.author, '韩晓霞');
    });

    test('large binary/body tail does not need to arrive to parse metadata',
        () {
      final prefix = _export(_utseusHeading);
      final withBody = [
        ...prefix,
        ...ascii.encode('<div>${'x' * (1024 * 1024)}</div>'),
      ];

      expect(AnnouncementExportMetadata.isComplete(prefix), isTrue);
      expect(AnnouncementExportMetadata.tryParse(withBody)!.author, '赵凌');
      expect(AnnouncementExportMetadata.tryParse(prefix)!.dateText,
          AnnouncementExportMetadata.tryParse(withBody)!.dateText);
    });

    test('UTF-8, entities, and inline author markup are handled', () {
      const header = '<div align="center"><p><h1>A &amp; B&nbsp;通知</h1></p>'
          '<span>张三&nbsp;李四</span> 2026-02-28 09:10:11 '
          '<a>部门 &amp; 编辑室</a></div>';
      final encoded = utf8.encode(header).map((byte) {
        if (byte < 0x80 && byte != 0x3d) return String.fromCharCode(byte);
        return '=${byte.toRadixString(16).padLeft(2, '0')}';
      }).join();
      final metadata = AnnouncementExportMetadata.tryParse(
        _export(encoded, charset: '"UTF-8"'),
      );

      expect(metadata!.title, 'A & B 通知');
      expect(metadata.author, '张三 李四');
      expect(metadata.department, '部门 & 编辑室');
    });

    test('never promotes a body date when the heading has no date', () {
      final bytes = _export('<div><p><h1>Notice</h1></p></div>'
          '<div>2026-09-18 10:00:36</div>');

      expect(AnnouncementExportMetadata.isComplete(bytes), isTrue);
      expect(AnnouncementExportMetadata.tryParse(bytes), isNull);
    });

    test('invalid dates and times do not normalize into different dates', () {
      for (final invalid in [
        '2026-02-30 12:00:00',
        '2026-01-01 24:00:00',
        '2026-01-01 12:60:00',
        '2026-01-01 12:00:60',
      ]) {
        expect(
          AnnouncementExportMetadata.tryParse(
            _export('<div><p><h1>Notice</h1></p> $invalid</div>'),
          ),
          isNull,
          reason: invalid,
        );
      }
    });

    test('HTML errors, wrong MIME parts and unsupported charsets are rejected',
        () {
      expect(
        AnnouncementExportMetadata.tryParse(ascii.encode(
          '<div><h1>Forbidden</h1>2026-09-18 10:00:36</div>',
        )),
        isNull,
      );
      final bytes = _export(_utseusHeading);
      final text = ascii.decode(bytes);
      expect(
        AnnouncementExportMetadata.tryParse(ascii.encode(
          text.replaceFirst('text/html', 'image/jpeg'),
        )),
        isNull,
      );
      expect(
        AnnouncementExportMetadata.tryParse(
          _export(_utseusHeading, charset: 'unknown-charset'),
        ),
        isNull,
      );
      expect(
        AnnouncementExportMetadata.tryParse(ascii.encode(
          text.replaceFirst('boundary="----test-export"', 'boundary="missing"'),
        )),
        isNull,
      );
    });
  });

  group('actual article identity', () {
    test('uses linked article domain and owner from its public counter', () {
      final url = AnnouncementExportMetadata.exportUrl(
        'https://bkzsw.shu.edu.cn/info/1798/38490.htm',
        "<script>_jsq_(1798,'/content.jsp',38490,1364902694)</script>",
      );

      expect(url!.host, 'bkzsw.shu.edu.cn');
      expect(url.path, '/system/resource/news/newstoword.jsp');
      expect(url.queryParameters, {
        'treeid': '1798',
        'owner': '1364902694',
        'wbnewsid': '38490',
      });
    });

    test('static file ID may differ from the real content database ID', () {
      final url = AnnouncementExportMetadata.exportUrl(
        'https://adrichn.shu.edu.cn/info/1057/2054.htm',
        '<script>_jsq_(1057,"/noleftcontent.jsp",2034,1691313259)</script>',
      );

      expect(url!.queryParameters['wbnewsid'], '2034');
      expect(url.queryParameters['owner'], '1691313259');
    });

    test('explicit public download controls work without a counter', () {
      const article = 'https://utseus.shu.edu.cn/info/1010/6186.htm';
      for (final html in [
        '<a onclick="download_news(\'vsb_content\',1010,1430791623,6186)">'
            'Word</a>',
        '<a href="/system/resource/news/newstoword.jsp?treeid=1010'
            '&amp;owner=1430791623&amp;wbnewsid=6186">Word</a>',
      ]) {
        expect(
          AnnouncementExportMetadata.exportUrl(article, html)!.queryParameters,
          {'treeid': '1010', 'owner': '1430791623', 'wbnewsid': '6186'},
        );
      }
    });

    test('unadvertised owners and ambiguous identities are never guessed', () {
      const article = 'https://utseus.shu.edu.cn/info/1010/6186.htm';
      expect(AnnouncementExportMetadata.exportUrl(article, '<p>Notice</p>'),
          isNull);
      expect(
        AnnouncementExportMetadata.exportUrl(
          article,
          "<script>_jsq_(1010,'/content.jsp',6186,1430791623);"
          "_jsq_(1010,'/content.jsp',6187,1430791623)</script>",
        ),
        isNull,
      );
      expect(
        AnnouncementExportMetadata.exportUrl(
          article,
          "<script>_jsq_(9999,'/content.jsp',6186,1430791623)</script>",
        ),
        isNull,
      );
    });

    test('non-campus hosts and non-article URLs do not become exports', () {
      const html =
          "<script>_jsq_(1010,'/content.jsp',6186,1430791623)</script>";
      for (final article in [
        'https://shu.edu.cn.evil.example/info/1010/6186.htm',
        'https://www.shvfs.cn/site/newsDetail/1624',
        'https://utseus.shu.edu.cn:8080/info/1010/6186.htm',
        'https://user@utseus.shu.edu.cn/info/1010/6186.htm',
        'https://utseus.shu.edu.cn/tzgg.htm',
      ]) {
        expect(AnnouncementExportMetadata.exportUrl(article, html), isNull,
            reason: article);
      }
    });
  });

  test('title identity tolerates whitespace and GBK export loss only', () {
    expect(AnnouncementExportMetadata.matchesTitle('A&nbsp; B 通知', 'A B通知'),
        isTrue);
    expect(AnnouncementExportMetadata.matchesTitle('C−F键活化', 'C?F键活化'), isTrue);
    expect(AnnouncementExportMetadata.matchesTitle('甲学院通知', '乙学院通知'), isFalse);
    expect(AnnouncementExportMetadata.matchesTitle('甲学院通知', '?学院通知'), isFalse);
    expect(AnnouncementExportMetadata.matchesTitle('', ''), isFalse);
  });
}
