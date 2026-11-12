import '../../core/utils/library_book_citation.dart';

/// 馆藏所属校区（宝山、嘉定、延长，钱图并入宝山）
enum LibraryHoldingCampus {
  baoshan('宝山'),
  jiading('嘉定'),
  yanchang('延长');

  const LibraryHoldingCampus(this.label);
  final String label;
}

/// 馆藏书刊归类状态
enum HoldingStatusCategory {
  onShelf('在架'),
  borrowed('借出'),
  reshelving('上架中'),
  inTransit('流转中'),
  unavailable('暂不可借');

  const HoldingStatusCategory(this.label);
  final String label;
}

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
  bool get isOnShelf =>
      processType == '在架' ||
      processTypeCode == '411' ||
      statusCategory == HoldingStatusCategory.onShelf;

  /// 归类后的书刊状态枚举
  HoldingStatusCategory get statusCategory {
    final type = processType;
    final code = processTypeCode;

    if (type == '在架' || code == '411') {
      return HoldingStatusCategory.onShelf;
    }
    if (code == '412' ||
        code == '415' ||
        code == '416' ||
        code == '417' ||
        code == '517' ||
        type.contains('借出')) {
      return HoldingStatusCategory.borrowed;
    }
    if (code == '427' ||
        code == '320' ||
        code == '428' ||
        type.contains('上架') ||
        type.contains('归还')) {
      return HoldingStatusCategory.reshelving;
    }
    if (code == '413' ||
        code == '426' ||
        code == '414' ||
        code == '429' ||
        code == '430' ||
        code == '418' ||
        type.contains('预约') ||
        type.contains('委托') ||
        type.contains('物流') ||
        type.contains('运送') ||
        type.contains('调拨')) {
      return HoldingStatusCategory.inTransit;
    }
    if (code == '312' ||
        code == '423' ||
        code == '424' ||
        code == '318' ||
        code == '322' ||
        code == '313' ||
        code == '321' ||
        code == '323' ||
        code == '422' ||
        code == '316' ||
        code == '211' ||
        code == '111' ||
        type.contains('修') ||
        type.contains('装订') ||
        type.contains('清点') ||
        type.contains('丢') ||
        type.contains('报废') ||
        type.contains('下架') ||
        type.contains('编') ||
        type.contains('验收')) {
      return HoldingStatusCategory.unavailable;
    }
    return HoldingStatusCategory.borrowed;
  }

  /// 归类后的状态显示文本（精简友好）
  String get displayStatus {
    switch (statusCategory) {
      case HoldingStatusCategory.onShelf:
        return '在架';
      case HoldingStatusCategory.borrowed:
        return '借出';
      case HoldingStatusCategory.reshelving:
        return '上架中';
      case HoldingStatusCategory.inTransit:
        return '流转中';
      case HoldingStatusCategory.unavailable:
        return '暂不可借';
    }
  }

  /// 清洗后的藏书地点名称（移除校区前缀，并应用精简别名）
  String get cleanLocationName {
    final raw =
        (curLocationName?.isNotEmpty == true ? curLocationName! : locationName)
            .trim();
    return simplifyLocationName(raw);
  }

  /// 藏书地点名称精简化（去掉校区前缀及常见冗余字符）
  static String simplifyLocationName(String raw) {
    var name = raw
        .replaceAll(RegExp(r'^(宝山校区|嘉定校区|延长校区|钱图校区)\s*[-_—/]?\s*'), '')
        .trim();

    const locationNameMap = <String, String>{
      '宝山流通库': '总馆流通库',
      '宝山图书密集库1': '总馆密集书库1',
      '宝山图书密集库2': '总馆密集书库2',
      '宝山图书阅览室': '总馆阅览室',
      '宝山图书阅览室8楼': '总馆8楼阅览室',
      '宝山期刊阅览室': '总馆期刊阅览室',
      '宝山美术阅览室': '总馆美术阅览室',
      '宝山特藏阅览室': '总馆特藏阅览室',
      '宝山二楼图书专架': '总馆二楼专架',
      '宝山地下书库': '总馆地下书库',
      '宝山书店流通': '总馆书店流通',
      '宝山中法学院资料室': '中法学院资料室',
      '宝山会议': '总馆会议室',
      '宝山801阅览室': '总馆801阅览室',
      '宝山804阅览室': '总馆804阅览室',
      '宝山303': '总馆303室',
      '宝山图书馆服务台': '总馆服务台',
      '钱伟长图书馆流通': '钱图流通库',
      '钱伟长馆四楼': '钱图四楼',
      '钱伟长陈列展': '钱图陈列展',
      '钱伟长赠书阅览室': '钱图赠书阅览室',
      '钱伟长图书馆服务台': '钱图服务台',
      '钱伟长图书馆期刊': '钱图期刊室',
      '钱伟长刊阅览室': '钱图期刊阅览室',
      '钱图六楼名人捐赠': '钱图六楼名人捐赠',
      '钱图三楼书香谷': '钱图三楼书香谷',
      '钱图四楼外圈': '钱图四楼外圈',
      '钱图四楼内圈': '钱图四楼内圈',
      '钱图五楼特藏': '钱图五楼特藏',
      '钱图五楼外圈': '钱图五楼外圈',
      '钱图704室': '钱图704室',
      '钱图621室': '钱图621室',
      '南区伟长学院': '伟长学院资料室',
      '嘉定流通库': '嘉定流通库',
      '嘉定流通库1': '嘉定流通库1',
      '嘉定流通库2': '嘉定流通库2',
      '嘉定流通库3': '嘉定流通库3',
      '嘉定图书阅览室': '嘉定阅览室',
      '嘉定期刊阅览室': '嘉定期刊室',
      '嘉定微电子学科专架': '微电子学科专架',
      '嘉定图书馆服务台': '嘉定服务台',
      '延长流通库': '延长流通库',
      '延长图书阅览室': '延长阅览室',
      '延长期刊阅览室': '延长期刊室',
      '延长科图法书库': '科图法书库',
      '延长中图法书库': '中图法书库',
      '延长闭架书库四楼': '闭架书库四楼',
      '延长闭架书库五楼': '闭架书库五楼',
      '延长闭架书库六楼': '闭架书库六楼',
      '延长闭架书库100室': '闭架书库100室',
      '延长闭架书库101室': '闭架书库101室',
      '延长美术阅览室': '延长美术阅览室',
      '延长图书馆服务台': '延长服务台',
    };

    if (locationNameMap.containsKey(name)) {
      return locationNameMap[name]!;
    }
    return name;
  }

  /// 提取借出状态下的归还时间（例如 "委托借出-应还日期:2027-01-25" -> "2027-01-25"）
  String? get dueDate {
    final match = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(processType);
    return match?.group(0);
  }

  /// 所属校区（宝山、嘉定、延长，钱图并入宝山）
  LibraryHoldingCampus get campus {
    final text =
        '${curLocationName ?? ''} $locationName ${realLocationName ?? ''}';
    if (text.contains('嘉定')) {
      return LibraryHoldingCampus.jiading;
    }
    if (text.contains('延长')) {
      return LibraryHoldingCampus.yanchang;
    }
    // 默认或含宝山、钱图、钱伟长等均归入宝山
    return LibraryHoldingCampus.baoshan;
  }

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
            final clean =
                rawMarc.replaceAll(RegExp(r'^_{0,2}\|[a-z]\s*'), '').trim();
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
