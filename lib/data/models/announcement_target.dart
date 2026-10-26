import 'announcement_source.dart';

enum AnnouncementArticleKind { vsb, vancouver, external }

/// The article's site and capabilities, independent from its list membership.
class AnnouncementTarget {
  const AnnouncementTarget._(this.url, this.owner, this.kind);

  factory AnnouncementTarget.resolve(String url, {String? sourceId}) {
    final normalized = url.trim();
    final uri = Uri.tryParse(normalized);
    final owner =
        AnnouncementSource.forUrl(normalized, preferredSourceId: sourceId);
    if (uri == null || !_isWebUri(uri)) {
      return AnnouncementTarget._(
          normalized, owner, AnnouncementArticleKind.external);
    }
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final kind = host == 'shvfs.cn' &&
            RegExp(r'^/site/newsDetail/\d+$', caseSensitive: false)
                .hasMatch(uri.path)
        ? AnnouncementArticleKind.vancouver
        : (host == 'shu.edu.cn' || host.endsWith('.shu.edu.cn')) &&
                RegExp(r'^/info/[^/]+/[^/]+\.(?:htm|html|hmtl)$',
                        caseSensitive: false)
                    .hasMatch(uri.path)
            ? AnnouncementArticleKind.vsb
            : AnnouncementArticleKind.external;
    return AnnouncementTarget._(normalized, owner, kind);
  }

  final String url;
  final AnnouncementSource? owner;
  final AnnouncementArticleKind kind;

  bool get canOpenInApp => kind != AnnouncementArticleKind.external;
  bool get canLoadMetadata => canOpenInApp;
  bool get showDepartment =>
      kind == AnnouncementArticleKind.vsb &&
      owner?.id == AnnouncementSource.officialId;
  bool get canPreview {
    final uri = Uri.tryParse(url);
    return uri != null &&
        _isWebUri(uri) &&
        !RegExp(r'\.(?:pdf|docx?|xlsx?|pptx?|zip|rar|7z|png|jpe?g|gif|webp|svg|bmp|ico|mp[34]|wav|avi|mov|css|js)$',
                caseSensitive: false)
            .hasMatch(uri.path);
  }

  static bool _isWebUri(Uri uri) =>
      uri.hasAuthority && (uri.scheme == 'http' || uri.scheme == 'https');
}

String announcementUrlKey(String url) =>
    Uri.tryParse(url.trim())?.removeFragment().toString() ?? url.trim();

String resolveAnnouncementUrl(String baseUrl, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  try {
    final uri = Uri.parse(baseUrl).resolve(trimmed);
    return uri.scheme == 'http' || uri.scheme == 'https' ? uri.toString() : '';
  } on FormatException {
    return '';
  }
}
