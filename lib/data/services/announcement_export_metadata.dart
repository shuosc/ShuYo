import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'announcement_gbk.dart';

/// Publication fields from the small header of a public VSB Word export.
///
/// These exports are MHTML documents. Only the first HTML part's heading is
/// inspected: dates in the article body and download-generation headers do not
/// describe when an article was published.
class AnnouncementExportMetadata {
  const AnnouncementExportMetadata({
    required this.title,
    required this.dateText,
    required this.publishedAt,
    this.author = '',
    this.department = '',
  });

  static const maximumPrefixBytes = 16 * 1024;

  final String title;
  final String dateText;
  final DateTime publishedAt;
  final String author;
  final String department;

  /// Whether the metadata heading has arrived, even when its date is invalid.
  /// Callers can cancel the export stream as soon as this returns true.
  static bool isComplete(List<int> prefix) => _readHeading(prefix) != null;

  static AnnouncementExportMetadata? tryParse(List<int> prefix) {
    final heading = _readHeading(prefix);
    if (heading == null) return null;
    final String decoded;
    try {
      decoded = switch (heading.charset) {
        'gbk' ||
        'gb2312' ||
        'gb_2312-80' =>
          decodeAnnouncementGbk(heading.bytes),
        'utf-8' || 'utf8' => utf8.decode(heading.bytes),
        'us-ascii' || 'ascii' => ascii.decode(heading.bytes),
        _ => throw const FormatException('Unsupported export charset'),
      };
    } on FormatException {
      return null;
    }
    final titleMatch = _titlePattern.firstMatch(decoded);
    if (titleMatch == null) return null;
    final title = _visibleText(titleMatch.group(1)!);
    if (title.isEmpty) return null;
    final fields = _visibleText(decoded.substring(titleMatch.end));
    final dateMatch = _timestampPattern.firstMatch(fields);
    if (dateMatch == null) return null;
    final components = [
      for (var index = 1; index <= 6; index++)
        int.parse(dateMatch.group(index)!),
    ];
    final date = DateTime(
      components[0],
      components[1],
      components[2],
      components[3],
      components[4],
      components[5],
    );
    // DateTime normalizes invalid dates and times, which must not turn a bad
    // export header into an apparently valid publication date.
    if (date.year != components[0] ||
        date.month != components[1] ||
        date.day != components[2] ||
        date.hour != components[3] ||
        date.minute != components[4] ||
        date.second != components[5]) {
      return null;
    }
    return AnnouncementExportMetadata(
      title: title,
      dateText: '${dateMatch.group(1)}-${dateMatch.group(2)}-'
          '${dateMatch.group(3)}',
      publishedAt: date,
      author: fields.substring(0, dateMatch.start).trim(),
      department: fields.substring(dateMatch.end).trim(),
    );
  }

  /// Resolves the export identity advertised by the actual article page.
  ///
  /// A VSB static URL's final number can differ from its database news ID.
  /// The page's `_jsq_`/download identity is authoritative; IDs and site owners
  /// are never inferred from a department registry or a different source site.
  static Uri? exportUrl(String articleUrl, String html,
      {dom.Document? parsedDocument}) {
    final article = Uri.tryParse(articleUrl);
    if (article == null || !_isCampusArticle(article)) return null;
    final pathIdentity =
        RegExp(r'/info/(\d+)/(\d+)\.html?$').firstMatch(article.path);
    if (pathIdentity == null) return null;
    final document = parsedDocument ?? html_parser.parse(html);
    final identities = <String, _ExportIdentity>{};
    for (final script in document.querySelectorAll('script')) {
      for (final match in _counterIdentity.allMatches(script.text)) {
        final identity = _ExportIdentity(
          match.group(1)!,
          match.group(4)!,
          match.group(3)!,
        );
        identities[identity.key] = identity;
      }
    }
    // Some templates expose only their public download control.
    if (identities.isEmpty) {
      for (final match in _downloadIdentity.allMatches(html)) {
        final identity = _ExportIdentity(
          match.group(1)!,
          match.group(2)!,
          match.group(3)!,
        );
        identities[identity.key] = identity;
      }
      for (final anchor in document.querySelectorAll('a[href]')) {
        final Uri target;
        try {
          target = article.resolve(anchor.attributes['href']!);
        } on FormatException {
          continue;
        }
        if ((target.scheme != 'http' && target.scheme != 'https') ||
            !target.hasAuthority ||
            target.origin != article.origin ||
            target.path != '/system/resource/news/newstoword.jsp') {
          continue;
        }
        final tree = target.queryParameters['treeid'];
        final owner = target.queryParameters['owner'];
        final news = target.queryParameters['wbnewsid'];
        if ([tree, owner, news].any(
          (value) => value == null || !_numericId.hasMatch(value),
        )) {
          continue;
        }
        final identity = _ExportIdentity(tree!, owner!, news!);
        identities[identity.key] = identity;
      }
    }
    if (identities.length != 1) return null;
    final identity = identities.values.single;
    if (identity.tree != pathIdentity.group(1)) return null;
    return article.replace(
      path: '/system/resource/news/newstoword.jsp',
      queryParameters: {
        'treeid': identity.tree,
        'owner': identity.owner,
        'wbnewsid': identity.news,
      },
      fragment: '',
    );
  }

  /// Compares a complete original-page title with the exported heading.
  ///
  /// GBK export irreversibly replaces unsupported characters with `?`; account
  /// for that conversion, without relaxing checks for ordinary characters.
  /// Truncated list titles should not be supplied as the expected title.
  static bool matchesTitle(String expected, String actual) {
    String normalize(String text) => _visibleText(text)
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('\u200b', '');
    final normalizedExpected = normalize(expected);
    final normalizedActual = normalize(actual);
    if (normalizedExpected.isEmpty || normalizedActual.isEmpty) return false;
    if (normalizedExpected == normalizedActual) return true;
    final exportedExpected = StringBuffer();
    for (final rune in normalizedExpected.runes) {
      final character = String.fromCharCode(rune);
      if (!isAnnouncementGbkCharacter(rune)) {
        exportedExpected.write('?');
      } else {
        exportedExpected.write(character);
      }
    }
    return exportedExpected.toString() == normalizedActual;
  }

  static bool _isCampusArticle(Uri uri) {
    final host = uri.host.toLowerCase();
    return (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.userInfo.isEmpty &&
        (host == 'shu.edu.cn' || host.endsWith('.shu.edu.cn')) &&
        (!uri.hasPort || uri.port == 80 || uri.port == 443);
  }

  static _ExportHeading? _readHeading(List<int> prefix) {
    final text = latin1.decode(
      prefix.length > maximumPrefixBytes
          ? prefix.sublist(0, maximumPrefixBytes)
          : prefix,
    );
    final envelope = _readHeaders(text, 0);
    if (envelope == null) return null;
    final envelopeType = envelope.fields['content-type'] ?? '';
    if (!envelopeType.toLowerCase().startsWith('multipart/related')) {
      return null;
    }
    final boundary = RegExp(
      r'''\bboundary\s*=\s*(?:"([^"]+)"|([^;\s]+))''',
      caseSensitive: false,
    ).firstMatch(envelopeType);
    final boundaryValue = boundary?.group(1) ?? boundary?.group(2);
    if (boundaryValue == null || boundaryValue.length > 200) return null;
    final boundaryMatch = RegExp(
      '^--${RegExp.escape(boundaryValue)}\\r?\$',
      multiLine: true,
    ).firstMatch(text.substring(envelope.end));
    if (boundaryMatch == null) return null;
    final partStart = envelope.end + boundaryMatch.end;
    final afterBoundary =
        text.startsWith('\r\n', partStart) ? partStart + 2 : partStart + 1;
    final part = _readHeaders(text, afterBoundary);
    if (part == null) return null;
    final contentType = part.fields['content-type'] ?? '';
    if (!contentType.toLowerCase().startsWith('text/html')) return null;
    final charsetMatch = RegExp(
      r'''\bcharset\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))''',
      caseSensitive: false,
    ).firstMatch(contentType);
    final charset = (charsetMatch?.group(1) ??
            charsetMatch?.group(2) ??
            charsetMatch?.group(3) ??
            'us-ascii')
        .toLowerCase();
    final encoding = part.fields['content-transfer-encoding']?.toLowerCase();
    final List<int> decoded;
    if (encoding == 'quoted-printable') {
      decoded = _decodeQuotedPrintable(text.substring(part.end));
    } else if (encoding == null ||
        encoding == '7bit' ||
        encoding == '8bit' ||
        encoding == 'binary') {
      decoded = text.substring(part.end).codeUnits;
    } else {
      return null;
    }
    // HTML tags are ASCII in all supported encodings. Inspect only this small
    // structural prefix before paying the cost of GBK/HTML decoding.
    final asciiHeading = latin1.decode(decoded);
    final opening = RegExp(
      r'^\s*<div\b[^>]*>\s*(?:<p\b[^>]*>\s*)?<h1\b',
      caseSensitive: false,
    ).firstMatch(asciiHeading);
    if (opening == null) return null;
    final title = _titlePattern.firstMatch(asciiHeading);
    if (title == null) return null;
    final end = RegExp(r'</div\s*>', caseSensitive: false)
        .firstMatch(asciiHeading.substring(title.end));
    if (end == null) return null;
    return _ExportHeading(
      decoded.sublist(0, title.end + end.end),
      charset,
    );
  }

  static _MimeHeaders? _readHeaders(String text, int start) {
    if (start >= text.length) return null;
    final end = RegExp(r'\r?\n\r?\n').firstMatch(text.substring(start));
    if (end == null) return null;
    final header = text
        .substring(start, start + end.start)
        .replaceAll(RegExp(r'\r?\n[ \t]+'), ' ');
    final fields = <String, String>{};
    for (final line in header.split(RegExp(r'\r?\n'))) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields[line.substring(0, colon).trim().toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    return _MimeHeaders(fields, start + end.end);
  }

  static List<int> _decodeQuotedPrintable(String text) {
    final input = text.replaceAll(RegExp(r'=\r?\n'), '');
    final bytes = <int>[];
    for (var index = 0; index < input.length; index++) {
      final byte = input.codeUnitAt(index);
      if (byte != 0x3d) {
        bytes.add(byte);
        continue;
      }
      if (index + 2 >= input.length) break;
      final value =
          int.tryParse(input.substring(index + 1, index + 3), radix: 16);
      if (value == null) {
        bytes.add(byte);
      } else {
        bytes.add(value);
        index += 2;
      }
    }
    return bytes;
  }

  static String _visibleText(String html) =>
      (html_parser.parseFragment(html).text ?? '')
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  static final _numericId = RegExp(r'^[0-9]+$');
  static final _titlePattern = RegExp(
    r'<h1\b[^>]*>(.*?)</h1\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final _timestampPattern = RegExp(
    r'(?<!\d)(\d{4})-(\d{2})-(\d{2})\s+'
    r'(\d{2}):(\d{2}):(\d{2})(?!\d)',
  );
  static final _counterIdentity = RegExp(
    r'''_jsq_\(\s*([0-9]+)\s*,\s*(['"])[^'"]+\.jsp\2\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*\)''',
  );
  static final _downloadIdentity = RegExp(
    r'''\bdownload_news\(\s*(?:'[^']*'|"[^"]*"|[0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*\)''',
  );
}

class _ExportIdentity {
  const _ExportIdentity(this.tree, this.owner, this.news);

  final String tree;
  final String owner;
  final String news;

  String get key => '$tree/$owner/$news';
}

class _ExportHeading {
  const _ExportHeading(this.bytes, this.charset);

  final List<int> bytes;
  final String charset;
}

class _MimeHeaders {
  const _MimeHeaders(this.fields, this.end);

  final Map<String, String> fields;
  final int end;
}
