import 'package:flutter/foundation.dart';

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

  factory LibraryDailyRecommend.fromJson(
    Map<String, dynamic> json, {
    String? coverUrl,
  }) {
    final rawRecordId = json['recordId'];
    final recordId = rawRecordId is int
        ? rawRecordId
        : int.tryParse(rawRecordId?.toString() ?? '') ?? 0;

    return LibraryDailyRecommend(
      recordId: recordId,
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim(),
      publisher: (json['publisher'] as String?)?.trim(),
      publishYear: (json['publishYear'] as String?)?.trim(),
      isbn: (json['isbn'] as String?)?.trim(),
      callNo: (json['callNo'] as String?)?.trim(),
      summary: (json['adstract'] as String?)?.trim() ??
          (json['summary'] as String?)?.trim(),
      coverUrl: coverUrl,
    );
  }

  LibraryDailyRecommend copyWith({
    String? coverUrl,
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
