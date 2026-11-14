import '../../core/utils/library_author_parser.dart';

class LibraryBookItem {
  const LibraryBookItem({
    required this.recordId,
    required this.title,
    this.author,
    this.publisher,
    this.publishYear,
    this.isbn,
    this.callNo,
    this.coverUrl,
    this.badgeText,
    this.summary,
    this.totalHolding,
    this.onShelfHolding,
    this.rating,
    this.loanCount,
    this.loanRate,
  });

  final int recordId;
  final String title;
  final String? author;
  final String? publisher;
  final String? publishYear;
  final String? isbn;
  final String? callNo;
  final String? coverUrl;
  final String? badgeText;
  final String? summary;
  final int? totalHolding;
  final int? onShelfHolding;
  final double? rating;
  final int? loanCount;
  final double? loanRate;

  /// 解析后的作者信息（包含国旗、国名、译者、改编者等）
  ParsedBookAuthors get parsedAuthors => LibraryAuthorParser.parse(author);

  /// 适合列表或卡片展示的格式化作者文本
  String get displayAuthor {
    if (author == null || author!.trim().isEmpty) return '暂无作者信息';
    final parsed = parsedAuthors;
    if (parsed.isEmpty) return author!.trim();
    return parsed.toDisplayString();
  }

  LibraryBookItem copyWith({
    String? coverUrl,
    int? totalHolding,
    int? onShelfHolding,
    double? rating,
    int? loanCount,
    double? loanRate,
  }) {
    return LibraryBookItem(
      recordId: recordId,
      title: title,
      author: author,
      publisher: publisher,
      publishYear: publishYear,
      isbn: isbn,
      callNo: callNo,
      coverUrl: coverUrl ?? this.coverUrl,
      badgeText: badgeText,
      summary: summary,
      totalHolding: totalHolding ?? this.totalHolding,
      onShelfHolding: onShelfHolding ?? this.onShelfHolding,
      rating: rating ?? this.rating,
      loanCount: loanCount ?? this.loanCount,
      loanRate: loanRate ?? this.loanRate,
    );
  }

  /// 分离出版社与年份，并对特殊纪年（如民国XX年）做规范化
  /// 输出示例：
  /// - "南京大学出版社2003" -> (publisher: "南京大学出版社", year: "2003")
  /// - "允晨文化公司民国80[1991]" -> (publisher: "允晨文化公司", year: "民国80年·1991")
  /// - "水牛图书出版公司民国73[1984]" -> (publisher: "水牛图书出版公司", year: "民国73年·1984")
  /// - "台湾商务印书馆,民国75[1986.12]" -> (publisher: "台湾商务印书馆", year: "民国75年·1986")
  static ({String? publisher, String? year}) parsePublisherAndYear(
    String? rawPublisher,
    String? rawYear,
  ) {
    var pub = (rawPublisher ?? '').trim();
    final year = (rawYear ?? '').trim();

    if (pub.isEmpty && year.isEmpty) {
      return (publisher: null, year: null);
    }

    // 1. 民国纪年处理：形如 "...民国80[1991]"、"...民国75[1986.12]"
    final minguoWithWestern = RegExp(
      r'^(.*?)[\s,，、]*民国\s*(\d{1,3})\s*(?:年)?\s*[\[\(（](\d{4})(?:\.\d+)?(?:年)?[\]\)）]$',
    );
    final mgMatch = minguoWithWestern.firstMatch(pub);
    if (mgMatch != null) {
      final cleanPub =
          mgMatch.group(1)!.replaceAll(RegExp(r'[,，、]+$'), '').trim();
      final mgYear = mgMatch.group(2)!;
      final adYear = mgMatch.group(3)!;
      return (
        publisher: cleanPub.isNotEmpty ? cleanPub : null,
        year: '民国$mgYear年·$adYear',
      );
    }

    // 单独写民国XX年无西元括号的
    final minguoSingle = RegExp(r'^(.*?)[\s,，、]*民国\s*(\d{1,3})\s*年?$');
    final singleMatch = minguoSingle.firstMatch(pub);
    if (singleMatch != null) {
      final cleanPub =
          singleMatch.group(1)!.replaceAll(RegExp(r'[,，、]+$'), '').trim();
      final mgYear = int.tryParse(singleMatch.group(2)!) ?? 0;
      final adYear = 1911 + mgYear;
      return (
        publisher: cleanPub.isNotEmpty ? cleanPub : null,
        year: '民国$mgYear年·$adYear',
      );
    }

    // 2. 粘在一起的西元年份：形如 "南京大学出版社2003"、"北京十月文艺出版社2021"
    final yearSuffix = RegExp(r'^(.*?)(\d{4}(?:-\d{2,4}|-)?)$');
    final suffixMatch = yearSuffix.firstMatch(pub);
    if (suffixMatch != null) {
      final cleanPub =
          suffixMatch.group(1)!.replaceAll(RegExp(r'[,，、]+$'), '').trim();
      final extractedYear = suffixMatch.group(2)!.trim();
      return (
        publisher: cleanPub.isNotEmpty ? cleanPub : null,
        year: year.isNotEmpty ? year : extractedYear,
      );
    }

    return (
      publisher: pub.isNotEmpty ? pub : null,
      year: year.isNotEmpty ? year : null,
    );
  }

  /// 解析热门借阅项
  factory LibraryBookItem.fromHotLoan(Map<String, dynamic> json) {
    final rawLoanCount = json['loanCount'] ?? json['cnt'];
    final loanCount = (rawLoanCount as num?)?.toInt();
    final rawLoanRate = json['loanRate'];
    final loanRate = rawLoanRate is num
        ? rawLoanRate.toDouble()
        : double.tryParse(rawLoanRate?.toString() ?? '');
    final itemCount = (json['itemCount'] as num?)?.toInt();
    final canLoanCount = (json['canLoanCount'] as num?)?.toInt();
    final rawPub = (json['publish'] as String?)?.trim();
    final rawYear = (json['pubDate'] as String?)?.trim();
    final pubInfo = parsePublisherAndYear(rawPub, rawYear);

    return LibraryBookItem(
      recordId: (json['recordId'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNo'] as String?)?.trim(),
      badgeText: loanCount != null ? '借阅 $loanCount 次' : null,
      summary: (json['summary'] as String?)?.trim(),
      totalHolding: itemCount,
      onShelfHolding: canLoanCount,
      loanCount: loanCount,
      loanRate: loanRate,
    );
  }

  /// 解析热门收藏项
  factory LibraryBookItem.fromTopShare(Map<String, dynamic> json) {
    final count = json['count'];
    final rawPub = (json['publisher'] as String?)?.trim();
    final pubInfo = parsePublisherAndYear(rawPub, null);

    return LibraryBookItem(
      recordId: (json['recordId'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNo'] as String?)?.trim(),
      badgeText: count != null ? '收藏 $count 次' : null,
      summary: (json['adstract'] as String?)?.trim(),
    );
  }

  /// 解析热门评分/高分图书项
  factory LibraryBookItem.fromTopScore(Map<String, dynamic> json) {
    final rawScore = json['avgScore'];
    final score = rawScore is num
        ? rawScore.toDouble()
        : double.tryParse(rawScore?.toString() ?? '');
    final rawPub = (json['publisher'] as String?)?.trim();
    final pubInfo = parsePublisherAndYear(rawPub, null);

    return LibraryBookItem(
      recordId: (json['recordId'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNo'] as String?)?.trim(),
      badgeText: score != null
          ? '${score.toStringAsFixed(score.truncateToDouble() == score ? 0 : 1)}分'
          : null,
      rating: score,
      summary: (json['adstract'] as String?)?.trim(),
    );
  }

  /// 解析新书速递项
  factory LibraryBookItem.fromNewBook(Map<String, dynamic> json) {
    final inDate = json['inDate'] as String?;
    final total = (json['physicalCount'] as num?)?.toInt();
    final onShelf = (json['onShelfCountI'] as num?)?.toInt();
    final rawPub = (json['publisher'] as String?)?.trim();
    final rawYear = (json['publishYear'] as String?)?.trim();
    final pubInfo = parsePublisherAndYear(rawPub, rawYear);

    return LibraryBookItem(
      recordId: (json['recordId'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNoOne'] as String?)?.trim() ??
          (json['callNo'] is List && (json['callNo'] as List).isNotEmpty
              ? (json['callNo'] as List).first.toString()
              : null),
      badgeText: inDate != null && inDate.length >= 10
          ? inDate.substring(0, 10)
          : null,
      summary: (json['adstract'] as String?)?.trim(),
      totalHolding: total,
      onShelfHolding: onShelf,
    );
  }

  /// 解析统一检索结果项（限定图书）
  factory LibraryBookItem.fromUnifySearch(Map<String, dynamic> json) {
    final total = (json['physicalCount'] as num?)?.toInt() ??
        (json['groupPhysicalCount'] as num?)?.toInt();
    final onShelf = (json['onShelfCountI'] as num?)?.toInt() ??
        (json['onShelfNum'] as num?)?.toInt();
    final rawScore = json['avgScore'];
    final score = rawScore is num
        ? rawScore.toDouble()
        : double.tryParse(rawScore?.toString() ?? '');
    final rawPub = (json['publisher'] as String?)?.trim();
    final rawYear = (json['publishYear'] as String?)?.trim();
    final pubInfo = parsePublisherAndYear(rawPub, rawYear);
    final rawPic = (json['pic'] as String?)?.trim();

    return LibraryBookItem(
      recordId: (json['recordId'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNoOne'] as String?)?.trim() ??
          (json['callNo'] is List && (json['callNo'] as List).isNotEmpty
              ? (json['callNo'] as List).first.toString().trim()
              : null),
      coverUrl: rawPic != null && rawPic.isNotEmpty ? rawPic : null,
      summary: (json['adstract'] as String?)?.trim(),
      totalHolding: total,
      onShelfHolding: onShelf,
      rating: score != null && score > 0 ? score : null,
    );
  }
}

class LibraryBookSearchResult {
  const LibraryBookSearchResult({
    required this.numFound,
    required this.page,
    required this.rows,
    required this.books,
    this.rawResultCount,
  });

  final int numFound;
  final int page;
  final int rows;
  final List<LibraryBookItem> books;
  final int? rawResultCount;

  bool hasMore(int loadedCount) {
    final received = rawResultCount ?? books.length;
    if (received == 0 || received < rows) return false;
    return loadedCount < numFound && page * rows < numFound;
  }
}

enum LibraryRankType {
  hotLoan('热门借阅'),
  hotCollect('热门收藏'),
  highScore('高分图书'),
  newBook('新书速递');

  const LibraryRankType(this.label);
  final String label;
}

/// 热门借阅排序方式：按借阅次数 或 按借阅比
enum HotLoanSortType {
  loanCount('借阅次数'),
  loanRate('借阅比');

  const HotLoanSortType(this.label);
  final String label;
}

/// 新书速递校区筛选
enum NewBookCampus {
  all('ALL', []),
  baoshan('宝山校区', [1, 2]),
  yanchang('延长校区', [4]),
  jiading('嘉定校区', [3]);

  const NewBookCampus(this.label, this.campusIds);
  final String label;
  final List<int> campusIds;
}
