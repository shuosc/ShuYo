class AnnouncementApiException implements Exception {
  const AnnouncementApiException(this.message,
      {this.statusCode, this.retryAfter});

  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => statusCode == null ? message : '$message ($statusCode)';
}

/// The server confirms that this article no longer exists.
class AnnouncementUnavailableException extends AnnouncementApiException {
  const AnnouncementUnavailableException({super.statusCode}) : super('公告失效');
}
