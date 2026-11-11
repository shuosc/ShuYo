/// 图书引用格式与导出工具类
class LibraryBookCitation {
  const LibraryBookCitation({
    required this.title,
    this.author,
    this.cleanAuthor,
    this.publisher,
    this.pubPlace,
    this.publishYear,
    this.docCode = 1,
  });

  final String title;
  final String? author;
  final String? cleanAuthor;
  final String? publisher;
  final String? pubPlace;
  final String? publishYear;
  final int docCode;

  /// 去除 HTML 标签与首尾空白字符
  static String stripHtml(String? text) {
    if (text == null) return '';
    return text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  String get effectiveAuthor {
    final ca = stripHtml(cleanAuthor);
    if (ca.isNotEmpty) return ca;
    final a = stripHtml(author);
    if (a.isNotEmpty) return a;
    return '佚名';
  }

  /// GB/T 7714 格式
  /// 规范: [1]责任者.题名[M].出版地:出版社,出版年.
  String get gb7714 {
    final auth = effectiveAuthor;
    final cleanTitle = stripHtml(title);
    final rawYear = stripHtml(publishYear);
    final year = rawYear.length >= 4
        ? rawYear.substring(0, 4)
        : (rawYear.isNotEmpty ? rawYear : '出版年不详');
    final place =
        stripHtml(pubPlace).isNotEmpty ? stripHtml(pubPlace) : '出版地不详';
    final pub =
        stripHtml(publisher).isNotEmpty ? stripHtml(publisher) : '出版社不详';

    if (docCode == 1) {
      return '[1]$auth.$cleanTitle[M].$place:$pub,$year.';
    } else if (docCode == 3) {
      return '[1]$auth.$cleanTitle[D].$pub,$year.';
    } else {
      final docTag = const {1: 'M', 2: 'J', 3: 'D', 4: 'C'}[docCode] ?? 'M';
      return '[1]$auth. $cleanTitle[$docTag]. $pub, $year.';
    }
  }

  /// MLA 格式
  /// 规范: 责任者. "题名". 出版社(出版年).
  String get mla {
    final authors = effectiveAuthor.split(',').map((s) => s.trim()).toList();
    final authStr = authors.join(', and ');
    final cleanTitle = stripHtml(title);
    final pub = stripHtml(publisher);
    final year = stripHtml(publishYear);
    return '$authStr. "$cleanTitle". $pub($year).';
  }

  /// APA 格式
  /// 规范: 责任者. (出版年). 题名. 出版社.
  String get apa {
    final authors = effectiveAuthor.split(',').map((s) => s.trim()).toList();
    final authStr = authors.join(', & ');
    final cleanTitle = stripHtml(title);
    final year = stripHtml(publishYear);
    final pub = stripHtml(publisher);
    return '$authStr. ($year). $cleanTitle. $pub.';
  }

  /// 导出 BibTex
  String exportBibTex() {
    final auth = effectiveAuthor;
    final cleanTitle = stripHtml(title);
    final year = stripHtml(publishYear);
    final pub = stripHtml(publisher);
    return '@book{$auth$year$cleanTitle,\n'
        '  title={$cleanTitle},\n'
        '  author={$auth},\n'
        '  publisher={$pub},\n'
        '  year={$year}\n'
        '}';
  }

  /// 导出 EndNote
  String exportEndNote() {
    final auths = effectiveAuthor.split(',');
    final cleanTitle = stripHtml(title);
    final authorLines = auths.map((a) => '\n%A ${a.trim()}').join();
    return '%0 Book\n'
        '%T $cleanTitle$authorLines\n'
        '%I ${stripHtml(publisher)}\n'
        '%D ${stripHtml(publishYear)}';
  }

  /// 导出 RefMan (RIS)
  String exportRefMan() {
    final auths = effectiveAuthor.split(',');
    final cleanTitle = stripHtml(title);
    final authorLines = auths.map((a) => '\nAU  - ${a.trim()}').join();
    return 'TY  - Book\n'
        'TI  - $cleanTitle$authorLines\n'
        'PB  - ${stripHtml(publisher)}\n'
        'PY  - ${stripHtml(publishYear)}\n'
        'ER  - ';
  }

  /// 导出 NoteExpress
  String exportNoteExpress() {
    final auths = effectiveAuthor.split(',');
    final cleanTitle = stripHtml(title);
    final authorLines = auths.map((a) => '\n{Author}: ${a.trim()}').join();
    return '{Reference Type}: Book\n'
        '{Title}: $cleanTitle$authorLines\n'
        '{Publisher}: ${stripHtml(publisher)}\n'
        '{Year}: ${stripHtml(publishYear)}';
  }

  /// 导出 NoteFirst
  String exportNoteFirst() {
    final auths = effectiveAuthor.split(',');
    final cleanTitle = stripHtml(title);
    final authorsXml = auths
        .map((a) =>
            '<Author><FullName><Info Lang="zh-CHS">${a.trim()}</Info></FullName></Author>')
        .join();
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Bibliographies NFVersion="NF5.0">\n'
        '<BibliographiesCount>1</BibliographiesCount>\n'
        '<Bibliography>\n'
        '<Type>Book</Type>\n'
        '<Language>zh-CHS</Language>\n'
        '<Title><PrimaryTitle><Info Lang="zh-CHS"><![CDATA[$cleanTitle]]></Info></PrimaryTitle></Title>\n'
        '<Authors>$authorsXml</Authors>\n'
        '<Press><![CDATA[${stripHtml(publisher)}]]></Press>\n'
        '<Year>${stripHtml(publishYear)}</Year>\n'
        '</Bibliography>\n'
        '</Bibliographies>';
  }
}
