import '../../core/utils/library_book_citation.dart';

/// 图书单册馆藏项
class LibraryBookHoldingItem {
  const LibraryBookHoldingItem({
    required this.itemId,
    required this.barcode,
    required this.callNo,
    required this.locationName,
    this.realLocationName,
    this.curLocationName,
    required this.processType,
    required this.processTypeCode,
    this.itemPolicyName,
    this.inDate,
    this.listPrice,
  });

  final int itemId;
  final String barcode;
  final String callNo;
  final String locationName;
  final String? realLocationName;
  final String? curLocationName;
  final String processType;
  final String processTypeCode;
  final String? itemPolicyName;
  final String? inDate;
  final double? listPrice;

  /// 是否在架可借
  bool get isOnShelf => processType == '在架' || processTypeCode == '411';

  factory LibraryBookHoldingItem.fromJson(Map<String, dynamic> json) {
    final rawPrice = json['listPrice'];
    final price = rawPrice is num
        ? rawPrice.toDouble()
        : double.tryParse(rawPrice?.toString() ?? '');

    return LibraryBookHoldingItem(
      itemId: (json['itemId'] as num?)?.toInt() ?? 0,
      barcode: (json['barcode'] as String?)?.trim() ?? '',
      callNo: (json['callNo'] as String?)?.trim() ?? '',
      locationName: (json['locationName'] as String?)?.trim() ?? '',
      realLocationName: (json['realLocationName'] as String?)?.trim(),
      curLocationName: (json['curLocationName'] as String?)?.trim(),
      processType: (json['processType'] as String?)?.trim() ?? '在架',
      processTypeCode: (json['processTypeCode'] as String?)?.trim() ?? '',
      itemPolicyName: (json['itemPolicyName'] as String?)?.trim(),
      inDate: (json['inDate'] as String?)?.trim(),
      listPrice: price,
    );
  }
}

/// 图书元数据项（如：出版发行项、ISBN及定价等）
class LibraryBookMetadataItem {
  const LibraryBookMetadataItem({
    required this.label,
    required this.value,
    this.isCopyable = true,
  });

  final String label;
  final String value;
  final bool isCopyable;
}

/// 完整图书详情数据模型
class LibraryBookDetailModel {
  const LibraryBookDetailModel({
    required this.recordId,
    required this.title,
    this.author,
    this.cleanAuthor,
    this.publisher,
    this.pubPlace,
    this.publishYear,
    this.isbn,
    this.callNo,
    this.summary,
    this.coverUrl,
    this.metadataList = const [],
    this.holdings = const [],
  });

  final int recordId;
  final String title;
  final String? author;
  final String? cleanAuthor;
  final String? publisher;
  final String? pubPlace;
  final String? publishYear;
  final String? isbn;
  final String? callNo;
  final String? summary;
  final String? coverUrl;
  final List<LibraryBookMetadataItem> metadataList;
  final List<LibraryBookHoldingItem> holdings;

  int get totalHoldings => holdings.length;
  int get onShelfHoldings => holdings.where((h) => h.isOnShelf).length;

  LibraryBookDetailModel copyWith({
    String? coverUrl,
    List<LibraryBookHoldingItem>? holdings,
  }) {
    return LibraryBookDetailModel(
      recordId: recordId,
      title: title,
      author: author,
      cleanAuthor: cleanAuthor,
      publisher: publisher,
      pubPlace: pubPlace,
      publishYear: publishYear,
      isbn: isbn,
      callNo: callNo,
      summary: summary,
      coverUrl: coverUrl ?? this.coverUrl,
      metadataList: metadataList,
      holdings: holdings ?? this.holdings,
    );
  }

  factory LibraryBookDetailModel.fromApiResponse({
    required int recordId,
    required Map<String, dynamic> detailData,
    List<dynamic>? holdingsData,
    String? fallbackTitle,
    String? fallbackAuthor,
    String? fallbackPublisher,
    String? fallbackPublishYear,
    String? coverUrl,
  }) {
    final baseMarc =
        detailData['baseMarcInfoDto'] as Map<String, dynamic>? ?? const {};
    final title = LibraryBookCitation.stripHtml(
      baseMarc['title'] as String? ?? fallbackTitle ?? '',
    );
    final cleanAuthor =
        LibraryBookCitation.stripHtml(baseMarc['cleanAuthor'] as String?);
    final rawAuthor =
        LibraryBookCitation.stripHtml(baseMarc['author'] as String?);
    final effectiveAuthor = cleanAuthor.isNotEmpty
        ? cleanAuthor
        : (rawAuthor.isNotEmpty ? rawAuthor : (fallbackAuthor ?? ''));

    final publisher = LibraryBookCitation.stripHtml(
      baseMarc['publisher'] as String? ?? fallbackPublisher ?? '',
    );
    final pubPlace =
        LibraryBookCitation.stripHtml(baseMarc['pubPlace'] as String?);
    final publishYear = LibraryBookCitation.stripHtml(
      baseMarc['publishYear'] as String? ?? fallbackPublishYear ?? '',
    );
    final isbn = LibraryBookCitation.stripHtml(
      baseMarc['isbn'] as String? ?? baseMarc['isbn13'] as String? ?? '',
    );

    // 从 marcDetl 中提取 330 提要文摘附注
    String? summary;
    final marcDetl = detailData['marcDetl'] as List?;
    if (marcDetl != null) {
      for (final m in marcDetl) {
        if (m is Map<String, dynamic>) {
          final field = m['field'] as String?;
          if (field == '330') {
            final rawMarc = m['fieldMarc'] as String? ?? '';
            // 形如 "__|a本书聚焦..." -> 剥离 __|a
            final clean = rawMarc.replaceAll(RegExp(r'^_{0,2}\|[a-z]\s*'), '').trim();
            if (clean.isNotEmpty) {
              summary = clean;
              break;
            }
          }
        }
      }
    }

    // 提取 bean2List 元数据列表
    final metadata = <LibraryBookMetadataItem>[];
    String? callNo;
    final bean2List = detailData['bean2List'] as List?;
    if (bean2List != null) {
      for (final b in bean2List) {
        if (b is Map<String, dynamic>) {
          final desc = (b['description'] as String?)?.trim() ?? '';
          final val =
              LibraryBookCitation.stripHtml(b['fieldVal'] as String? ?? '');
          if (desc.isNotEmpty && val.isNotEmpty) {
            metadata.add(
              LibraryBookMetadataItem(
                label: desc,
                value: val,
                isCopyable: true,
              ),
            );
            if (desc.contains('中图法分类号') && callNo == null) {
              callNo = val;
            }
          }
        }
      }
    }

    // 解析馆藏列表
    final holdings = <LibraryBookHoldingItem>[];
    if (holdingsData != null) {
      for (final item in holdingsData) {
        if (item is Map<String, dynamic>) {
          final holding = LibraryBookHoldingItem.fromJson(item);
          holdings.add(holding);
          if (callNo == null && holding.callNo.isNotEmpty) {
            callNo = holding.callNo;
          }
        }
      }
    }

    return LibraryBookDetailModel(
      recordId: recordId,
      title: title,
      author: effectiveAuthor,
      cleanAuthor: cleanAuthor,
      publisher: publisher,
      pubPlace: pubPlace,
      publishYear: publishYear,
      isbn: isbn,
      callNo: callNo,
      summary: summary,
      coverUrl: coverUrl,
      metadataList: metadata,
      holdings: holdings,
    );
  }
}
