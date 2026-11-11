import 'package:flutter/foundation.dart';

import '../../core/utils/library_author_parser.dart';
import 'library_book_item.dart';

@immutable
class LibraryDailyRecommend {
  const LibraryDailyRecommend({
    required this.recordId,
    required this.title,
    this.author,
    this.publisher,
    this.publishYear,
    this.isbn,
    this.callNo,
    this.summary,
    this.coverUrl,
    this.totalHolding,
    this.onShelfHolding,
  });

  final int recordId;
  final String title;
  final String? author;
  final String? publisher;
  final String? publishYear;
  final String? isbn;
  final String? callNo;
  final String? summary;
  final String? coverUrl;
  final int? totalHolding;
  final int? onShelfHolding;

  /// 解析后的作者信息
  ParsedBookAuthors get parsedAuthors => LibraryAuthorParser.parse(author);

  /// 适合列表或卡片展示的格式化作者文本
  String get displayAuthor {
    if (author == null || author!.trim().isEmpty) return '暂无作者信息';
    final parsed = parsedAuthors;
    if (parsed.isEmpty) return author!.trim();
    return parsed.toDisplayString();
  }

  factory LibraryDailyRecommend.fromJson(
    Map<String, dynamic> json, {
    String? coverUrl,
    int? totalHolding,
    int? onShelfHolding,
  }) {
    final rawRecordId = json['recordId'];
    final recordId = rawRecordId is int
        ? rawRecordId
        : int.tryParse(rawRecordId?.toString() ?? '') ?? 0;

    final rawPub = (json['publisher'] as String?)?.trim();
    final rawYear = (json['publishYear'] as String?)?.trim();
    final pubInfo = LibraryBookItem.parsePublisherAndYear(rawPub, rawYear);

    return LibraryDailyRecommend(
      recordId: recordId,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: pubInfo.publisher,
      publishYear: pubInfo.year,
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNo'] as String?)?.trim(),
      summary: (json['adstract'] as String?)?.trim() ??
          (json['summary'] as String?)?.trim(),
      coverUrl: coverUrl,
      totalHolding: totalHolding,
      onShelfHolding: onShelfHolding,
    );
  }

  LibraryDailyRecommend copyWith({
    String? coverUrl,
    int? totalHolding,
    int? onShelfHolding,
  }) {
    return LibraryDailyRecommend(
      recordId: recordId,
      title: title,
      author: author,
      publisher: publisher,
      publishYear: publishYear,
      isbn: isbn,
      callNo: callNo,
      summary: summary,
      coverUrl: coverUrl ?? this.coverUrl,
      totalHolding: totalHolding ?? this.totalHolding,
      onShelfHolding: onShelfHolding ?? this.onShelfHolding,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryDailyRecommend &&
          runtimeType == other.runtimeType &&
          recordId == other.recordId &&
          title == other.title &&
          author == other.author &&
          publisher == other.publisher &&
          publishYear == other.publishYear &&
          isbn == other.isbn &&
          callNo == other.callNo &&
          summary == other.summary &&
          coverUrl == other.coverUrl;

  @override
  int get hashCode => Object.hash(
        recordId,
        title,
        author,
        publisher,
        publishYear,
        isbn,
        callNo,
        summary,
        coverUrl,
      );
}
