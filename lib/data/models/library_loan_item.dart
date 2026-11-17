import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 单条借阅记录的状态分级。
enum LibraryLoanStatus {
  /// 已逾期（今日已超过应还日期）。
  overdue,

  /// 即将到期（含今日应还，剩余 0~3 天）。
  dueSoon,

  /// 正常在借中。
  borrowed,

  /// 历史借阅：已归还。
  returned,
}

/// 图书馆个人借阅记录（兼容当前在借与历史借阅）。
class LibraryLoanItem {
  const LibraryLoanItem({
    this.recordId,
    this.loanId,
    this.itemId,
    required this.title,
    this.author,
    this.publisher,
    this.publishYear,
    this.isbn,
    this.loanDate,
    this.loanDateText,
    this.dueDate,
    this.dueDateText,
    this.returnDate,
    this.returnDateText,
    this.locationName,
    this.currentLocation,
    this.barcode,
    this.callNo,
    this.isRequested = false,
    this.renewTimes = 0,
    this.surplusRenewTimes = 0,
    this.isOnlineReturn = false,
    this.isHistory = false,
  });

  final int? recordId;
  final int? loanId;
  final int? itemId;
  final String title;
  final String? author;
  final String? publisher;
  final String? publishYear;
  final String? isbn;
  final DateTime? loanDate;
  final String? loanDateText;

  /// 唯一可信的应还日期来源（来自服务端 normReturnDate，绝不由 normalLoanPeriod 推算）。
  final DateTime? dueDate;
  final String? dueDateText;

  /// 历史记录中可能包含的实还日期（字段结构待实测账号进一步确认，按可空容错）。
  final DateTime? returnDate;
  final String? returnDateText;

  final String? locationName;
  final String? currentLocation;
  final String? barcode;
  final String? callNo;
  final bool isRequested;
  final int renewTimes;
  final int surplusRenewTimes;
  final bool isOnlineReturn;
  final bool isHistory;

  factory LibraryLoanItem.fromJson(
    Map<String, dynamic> json, {
    bool isHistory = false,
  }) {
    final loanDateParsed =
        _parseDateField(json['loanDate'] ?? json['lendDate']);
    final dueDateParsed = _parseDateField(json['normReturnDate']);
    final returnDateParsed = _parseDateField(
      json['returnDate'] ?? json['realReturnDate'] ?? json['actualReturnDate'],
    );
    final rawRequested = json['isRequested']?.toString().trim();
    final isRequested = rawRequested == '是' ||
        rawRequested == '1' ||
        rawRequested?.toLowerCase() == 'true' ||
        json['isRequested'] == true;
    final rawOnlineReturn = json['isOnlineReturn'];
    final isOnlineReturn = rawOnlineReturn == true ||
        rawOnlineReturn == 1 ||
        rawOnlineReturn?.toString().trim() == '1';

    final title = _cleanString(json['title']) ?? '未知书名';
    final barcode =
        _cleanString(json['barcode']) ?? _cleanString(json['propNo']);

    return LibraryLoanItem(
      recordId: _parseInt(json['recordId']),
      loanId: _parseInt(json['loanId']),
      itemId: _parseInt(json['itemId']),
      title: title,
      author: _cleanString(json['author']),
      publisher: _cleanString(json['publisher']),
      publishYear: _cleanString(json['publishYear']),
      isbn: _cleanString(json['isbn']),
      loanDate: loanDateParsed.date,
      loanDateText: loanDateParsed.text,
      dueDate: dueDateParsed.date,
      dueDateText: dueDateParsed.text,
      returnDate: returnDateParsed.date,
      returnDateText: returnDateParsed.text,
      locationName: _cleanString(json['locationName']),
      currentLocation: _cleanString(json['curLocationName']),
      barcode: barcode,
      callNo: _cleanString(json['callNo']),
      isRequested: isRequested,
      renewTimes: _parseInt(json['renewTimes']) ?? 0,
      surplusRenewTimes: _parseInt(json['surplusRenewTimes']) ?? 0,
      isOnlineReturn: isOnlineReturn,
      isHistory: isHistory,
    );
  }

  LibraryLoanItem copyWith({
    int? recordId,
    int? loanId,
    int? itemId,
    String? title,
    String? author,
    String? publisher,
    String? publishYear,
    String? isbn,
    DateTime? loanDate,
    String? loanDateText,
    DateTime? dueDate,
    String? dueDateText,
    DateTime? returnDate,
    String? returnDateText,
    String? locationName,
    String? currentLocation,
    String? barcode,
    String? callNo,
    bool? isRequested,
    int? renewTimes,
    int? surplusRenewTimes,
    bool? isOnlineReturn,
    bool? isHistory,
  }) {
    return LibraryLoanItem(
      recordId: recordId ?? this.recordId,
      loanId: loanId ?? this.loanId,
      itemId: itemId ?? this.itemId,
      title: title ?? this.title,
      author: author ?? this.author,
      publisher: publisher ?? this.publisher,
      publishYear: publishYear ?? this.publishYear,
      isbn: isbn ?? this.isbn,
      loanDate: loanDate ?? this.loanDate,
      loanDateText: loanDateText ?? this.loanDateText,
      dueDate: dueDate ?? this.dueDate,
      dueDateText: dueDateText ?? this.dueDateText,
      returnDate: returnDate ?? this.returnDate,
      returnDateText: returnDateText ?? this.returnDateText,
      locationName: locationName ?? this.locationName,
      currentLocation: currentLocation ?? this.currentLocation,
      barcode: barcode ?? this.barcode,
      callNo: callNo ?? this.callNo,
      isRequested: isRequested ?? this.isRequested,
      renewTimes: renewTimes ?? this.renewTimes,
      surplusRenewTimes: surplusRenewTimes ?? this.surplusRenewTimes,
      isOnlineReturn: isOnlineReturn ?? this.isOnlineReturn,
      isHistory: isHistory ?? this.isHistory,
    );
  }

  /// 距离应还日还剩多少个自然日（负数表示已逾期天数；历史记录或无应还日返回 null）。
  int? daysRemaining({DateTime? now}) {
    final due = dueDate;
    if (isHistory || due == null) return null;
    final today = (now ?? DateTime.now()).toLocal();
    final utcDue = DateTime.utc(due.year, due.month, due.day);
    final utcToday = DateTime.utc(today.year, today.month, today.day);
    return utcDue.difference(utcToday).inDays;
  }

  LibraryLoanStatus statusAt({DateTime? now}) {
    if (isHistory) return LibraryLoanStatus.returned;
    final days = daysRemaining(now: now);
    if (days != null && days < 0) return LibraryLoanStatus.overdue;
    if (days != null && days <= 3) return LibraryLoanStatus.dueSoon;
    return LibraryLoanStatus.borrowed;
  }

  String statusLabel({DateTime? now}) {
    final status = statusAt(now: now);
    final days = daysRemaining(now: now);
    return switch (status) {
      LibraryLoanStatus.returned => '已归还',
      LibraryLoanStatus.overdue => '已逾期 ${days == null ? '' : -days} 天'.trim(),
      LibraryLoanStatus.dueSoon => days == 0 ? '今日应还' : '剩 ${days ?? 0} 天',
      LibraryLoanStatus.borrowed => days == null ? '借阅中' : '剩 $days 天',
    };
  }

  /// 是否允许续借：严格仅由服务端 surplusRenewTimes、isRequested 与是否逾期决定。
  bool canRenewAt({DateTime? now}) {
    if (isHistory) return false;
    if (statusAt(now: now) == LibraryLoanStatus.overdue) return false;
    return surplusRenewTimes > 0 && !isRequested;
  }

  String? renewDisabledReason({DateTime? now}) {
    if (isHistory) return null;
    if (statusAt(now: now) == LibraryLoanStatus.overdue) {
      return '该书已逾期，无法线上续借，请尽快归还';
    }
    if (isRequested) {
      return '该书已被其他读者预约，无法续借';
    }
    if (surplusRenewTimes <= 0) {
      return renewTimes > 0
          ? '已达最大续借次数（已续借 $renewTimes 次）'
          : '该书暂不支持线上续借（剩余可续 0 次）';
    }
    return null;
  }

  /// 用于时间筛选与历史年月吸顶分组的日期锚点（优先借出日，降级实还日/应还日）。
  DateTime? get sortAnchorDate => loanDate ?? returnDate ?? dueDate;

  DateTime? get groupMonth {
    final anchor = sortAnchorDate;
    return anchor == null ? null : DateTime(anchor.year, anchor.month);
  }

  String? get displayLocation {
    final loc = locationName?.trim();
    if (loc != null && loc.isNotEmpty) return loc;
    final cur = currentLocation?.trim();
    if (cur != null && cur.isNotEmpty) return cur;
    return null;
  }

  String get stableKey =>
      '${isHistory ? 'h' : 'a'}:${loanId ?? ''}:${recordId ?? ''}:${barcode ?? ''}:${loanDateText ?? ''}:$title';

  static int? _parseInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  static String? _cleanString(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') return null;
    return text;
  }

  static ({DateTime? date, String? text}) _parseDateField(Object? raw) {
    if (raw == null) return (date: null, text: null);
    if (raw is num) {
      final ms = raw > 100000000000 ? raw.toInt() : (raw * 1000).round();
      final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      final normalized = DateTime(dt.year, dt.month, dt.day);
      return (date: normalized, text: formatDate(normalized));
    }
    final text = raw.toString().trim();
    if (text.isEmpty || text == 'null') return (date: null, text: null);

    final sanitized = text.replaceAll('/', '-').replaceAll(RegExp(r'\s+'), 'T');
    var parsed = DateTime.tryParse(sanitized);
    if (parsed == null) {
      final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})')
          .firstMatch(text.replaceAll('/', '-'));
      if (match != null) {
        final y = int.parse(match.group(1)!);
        final m = int.parse(match.group(2)!);
        final d = int.parse(match.group(3)!);
        parsed = DateTime(y, m, d);
      }
    }
    if (parsed == null) {
      return (date: null, text: text);
    }
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    final dateOnly = DateTime(local.year, local.month, local.day);
    return (date: dateOnly, text: formatDate(dateOnly));
  }

  static String formatDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// 当前在借排序：逾期与最紧急应还日期优先，其次最近借出日期。
List<LibraryLoanItem> sortLibraryActiveLoans(
  Iterable<LibraryLoanItem> items, {
  DateTime? now,
}) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final aDue = a.$2.dueDate;
    final bDue = b.$2.dueDate;
    if (aDue != null && bDue != null) {
      final dueOrder = aDue.compareTo(bDue);
      if (dueOrder != 0) return dueOrder;
    } else if (aDue != bDue) {
      return aDue == null ? 1 : -1;
    }
    final aLoan = a.$2.loanDate;
    final bLoan = b.$2.loanDate;
    if (aLoan != null && bLoan != null) {
      final loanOrder = bLoan.compareTo(aLoan);
      if (loanOrder != 0) return loanOrder;
    } else if (aLoan != bLoan) {
      return aLoan == null ? 1 : -1;
    }
    return a.$1.compareTo(b.$1);
  });
  return List.unmodifiable(indexed.map((e) => e.$2));
}

/// 历史/记录列表排序：按借出/归还日期倒序（最新在前，便于年月吸顶分组不割裂）。
List<LibraryLoanItem> sortLibraryLoansNewestFirst(
  Iterable<LibraryLoanItem> items,
) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final aDate = a.$2.sortAnchorDate;
    final bDate = b.$2.sortAnchorDate;
    final order = aDate == null
        ? (bDate == null ? 0 : 1)
        : bDate == null
            ? -1
            : bDate.compareTo(aDate);
    if (order != 0) return order;
    if (a.$2.isHistory != b.$2.isHistory) {
      return a.$2.isHistory ? 1 : -1;
    }
    return a.$1.compareTo(b.$1);
  });
  return List.unmodifiable(indexed.map((e) => e.$2));
}

/// 分页借阅查询结果（刻意忽略 loanNum，避免误将其当作累计借阅量）。
class LibraryLoanPageResult {
  const LibraryLoanPageResult({
    required this.items,
    required this.numFound,
    required this.page,
    required this.rows,
  });

  final List<LibraryLoanItem> items;
  final int numFound;
  final int page;
  final int rows;
}

/// 待办提示计数（来源：GET /find/user/userLimit，非借阅额度）。
class LibraryTodoCounts {
  const LibraryTodoCounts({
    this.requestNum = 0,
    this.expiredNum = 0,
    this.behaviorNum = 0,
  });

  final int requestNum;
  final int expiredNum;
  final int behaviorNum;

  factory LibraryTodoCounts.fromJson(Map<String, dynamic> json) {
    int toInt(Object? raw) => raw is int
        ? raw
        : (raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0);
    return LibraryTodoCounts(
      requestNum: toInt(json['userRequestNum']),
      expiredNum: toInt(json['userLoanExpiredNum']),
      behaviorNum: toInt(json['userBehavierNotDealNum']),
    );
  }

  bool get hasAny => requestNum + expiredNum + behaviorNum > 0;
}

/// 读者借阅规则与可借额度（来源：POST /find/userInfo/UserLoanRules）。
class LibraryLoanRule {
  const LibraryLoanRule({
    this.ruleCode,
    required this.ruleName,
    this.ruleType,
    this.maxBorrowingNumber,
    this.maxRenewalTime,
    this.normalLoanPeriod,
    this.maxPenalty,
    this.applicableLocation,
  });

  final String? ruleCode;
  final String ruleName;
  final String? ruleType;
  final String? maxBorrowingNumber;
  final String? maxRenewalTime;
  final String? normalLoanPeriod;
  final String? maxPenalty;
  final String? applicableLocation;

  factory LibraryLoanRule.fromJson(Map<String, dynamic> json) {
    String? str(Object? raw) {
      final text = raw?.toString().trim();
      return text == null || text.isEmpty || text == 'null' ? null : text;
    }

    return LibraryLoanRule(
      ruleCode: str(json['ruleCode']),
      ruleName: str(json['ruleName']) ?? '借阅规则',
      ruleType: str(json['ruleType']),
      maxBorrowingNumber: str(json['maxBorrowingNumber']),
      maxRenewalTime: str(json['maxRenewalTime']),
      normalLoanPeriod: str(json['normalLoanPeriod']),
      maxPenalty: str(json['maxPenalty']),
      applicableLocation: str(json['applicableLocation']),
    );
  }
}

/// 读者证基础状态（来源：GET /find/userInfo/getUserInfo）。
class LibraryReaderCardInfo {
  const LibraryReaderCardInfo({
    this.name,
    this.unit,
    this.userGroupName,
    this.cardStatus,
    this.startDate,
    this.endDate,
  });

  final String? name;
  final String? unit;
  final String? userGroupName;
  final String? cardStatus;
  final String? startDate;
  final String? endDate;

  factory LibraryReaderCardInfo.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    final map = rawUser is Map<String, dynamic> ? rawUser : json;
    String? str(Object? raw) {
      final text = raw?.toString().trim();
      return text == null || text.isEmpty || text == 'null' ? null : text;
    }

    return LibraryReaderCardInfo(
      name: str(map['name']),
      unit: str(map['unit']),
      userGroupName: str(map['userGroupName']),
      cardStatus: str(map['cardStatus']),
      startDate: str(map['startDate']),
      endDate: str(map['endDate']),
    );
  }

  bool get isNormal =>
      cardStatus == null || cardStatus!.isEmpty || cardStatus == '1';

  String get statusLabel {
    if (cardStatus == '1') return '正常';
    if (cardStatus == null || cardStatus!.isEmpty) return '未知';
    return '异常（$cardStatus）';
  }
}

/// 借阅记录子页 AppBar 时间筛选预设。
enum LibraryLoanTimePreset {
  all('全部时间'),
  month('近一月'),
  halfYear('近半年'),
  year('近一年'),
  custom('自定义日期');

  const LibraryLoanTimePreset(this.label);

  final String label;
}

class LibraryLoanTimeFilter {
  const LibraryLoanTimeFilter._({
    required this.preset,
    this.customRange,
  });

  const LibraryLoanTimeFilter.all() : this._(preset: LibraryLoanTimePreset.all);

  const LibraryLoanTimeFilter.preset(LibraryLoanTimePreset preset)
      : this._(preset: preset);

  const LibraryLoanTimeFilter.custom(DateTimeRange range)
      : this._(preset: LibraryLoanTimePreset.custom, customRange: range);

  final LibraryLoanTimePreset preset;
  final DateTimeRange? customRange;

  bool get isActive => preset != LibraryLoanTimePreset.all;

  DateTimeRange? resolveRange({DateTime? now}) {
    final today = DateUtils.dateOnly((now ?? DateTime.now()).toLocal());
    switch (preset) {
      case LibraryLoanTimePreset.all:
        return null;
      case LibraryLoanTimePreset.month:
        return _monthsBackRange(today, 1);
      case LibraryLoanTimePreset.halfYear:
        return _monthsBackRange(today, 6);
      case LibraryLoanTimePreset.year:
        return _monthsBackRange(today, 12);
      case LibraryLoanTimePreset.custom:
        final range = customRange;
        if (range == null) return null;
        return DateTimeRange(
          start: DateUtils.dateOnly(range.start),
          end: DateUtils.dateOnly(range.end),
        );
    }
  }

  static DateTimeRange _monthsBackRange(DateTime today, int months) {
    final first = DateTime(today.year, today.month - months);
    final lastDay = DateUtils.getDaysInMonth(first.year, first.month);
    return DateTimeRange(
      start: DateTime(first.year, first.month, math.min(today.day, lastDay)),
      end: today,
    );
  }

  String displayLabel() {
    if (preset != LibraryLoanTimePreset.custom || customRange == null) {
      return preset.label;
    }
    String fmt(DateTime day) =>
        '${day.year}/${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}';
    return '${fmt(customRange!.start)}—${fmt(customRange!.end)}';
  }

  bool matches(LibraryLoanItem item, {DateTime? now}) {
    final range = resolveRange(now: now);
    if (range == null) return true;
    final anchor = item.sortAnchorDate;
    if (anchor == null) return false;
    final day = DateUtils.dateOnly(anchor);
    return !day.isBefore(range.start) && !day.isAfter(range.end);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryLoanTimeFilter &&
          other.preset == preset &&
          other.customRange == customRange;

  @override
  int get hashCode => Object.hash(preset, customRange);
}
