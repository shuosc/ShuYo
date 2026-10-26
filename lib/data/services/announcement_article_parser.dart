import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/announcement_target.dart';
import 'announcement_exception.dart';
import 'announcement_export_metadata.dart';

/// One original-page parse serves metadata, card excerpts and full articles.
class AnnouncementArticlePage {
  const AnnouncementArticlePage({
    this.url = '',
    required this.title,
    required this.summary,
    required this.metadata,
    required this.exportUrl,
    required this.blocks,
  });

  final String url;
  final String title;
  final String summary;
  final AnnouncementMetadata metadata;
  final Uri? exportUrl;
  final List<AnnouncementContentBlock> blocks;

  bool get hasContent => blocks.isNotEmpty;
}

abstract final class AnnouncementArticleParser {
  static AnnouncementArticlePage parse(
    String html, {
    required String url,
    String sourceId = AnnouncementSource.officialId,
    bool includeBody = true,
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? _parseDetailDocument(html);
    if (_isUnavailableAnnouncementPage(html, parsedDocument: document)) {
      throw const AnnouncementUnavailableException();
    }
    final target = AnnouncementTarget.resolve(url, sourceId: sourceId);
    final title = _articleTitle(document);
    final modern = _parseMetadata(
        document.querySelector('.nry .xx, .art-tit p'),
        document: document);
    var native =
        _parseVsbLegacyMetadata(document)?.withFallback(modern) ?? modern;
    if (target.kind == AnnouncementArticleKind.vancouver) {
      native = AnnouncementMetadata(
        dateText: _cleanText(
                document.querySelector('header.n-detail-title > p')?.text)
            .replaceFirst(RegExp(r'^时间\s*[:：]\s*'), ''),
      ).withFallback(native);
    }
    final publishedAt = _parseDate(native.dateText);
    final metadata = AnnouncementMetadata(
      title: title,
      dateText:
          publishedAt == null ? native.dateText : _formatDate(publishedAt),
      publishedAt: publishedAt,
      author: native.author,
      department: native.department,
    );
    final articleRoot = document.querySelector('.nry');
    final content = target.kind == AnnouncementArticleKind.vancouver
        ? document.querySelector('div.news-detail-infowrap')
        : articleRoot?.querySelector('.v_news_content') ??
            document.querySelector('.v_news_content') ??
            document.querySelector('#vsb_content') ??
            document.querySelector('div[id^="vsb_content_"]');
    final blocks = includeBody && content != null
        ? _parseContentBlocks(content, baseUrl: url)
        : <AnnouncementContentBlock>[];
    if (includeBody) _appendAttachments(document, blocks, url);
    return AnnouncementArticlePage(
      url: url,
      title: title,
      summary: includeBody
          ? _summaryFromBlocks(blocks, title)
          : _summarizeContent(content, document, title, url),
      metadata: metadata,
      exportUrl: AnnouncementExportMetadata.exportUrl(url, html,
          parsedDocument: document),
      blocks: blocks,
    );
  }

  /// Compatibility entry point for callers that already have list fallbacks.
  static AnnouncementDetail parseAnnouncementDetail(
    String html, {
    required String url,
    String sourceId = AnnouncementSource.officialId,
    String fallbackTitle = '',
    String fallbackDateText = '',
    DateTime? fallbackPublishedAt,
    dom.Document? parsedDocument,
  }) {
    final page = parse(html,
        url: url, sourceId: sourceId, parsedDocument: parsedDocument);
    final metadata = page.metadata;
    final dateText =
        metadata.dateText.isNotEmpty ? metadata.dateText : fallbackDateText;
    return AnnouncementDetail(
      title: page.title.isNotEmpty ? page.title : fallbackTitle,
      url: url,
      dateText: dateText,
      publishedAt:
          metadata.publishedAt ?? _parseDate(dateText) ?? fallbackPublishedAt,
      author: metadata.author,
      department: metadata.department,
      blocks: page.blocks,
    );
  }

  static String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static void _appendAttachments(dom.Document document,
      List<AnnouncementContentBlock> blocks, String url) {
    final linked = blocks
        .where((block) => block.isLink)
        .map((block) => block.value)
        .toSet();
    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      if (!href.contains('DownloadAttachUrl')) continue;
      final link = resolveAnnouncementUrl(url, href);
      if (link.isEmpty || !linked.add(link)) continue;
      final text = _cleanText(anchor.text);
      blocks.add(AnnouncementContentBlock.link(link,
          label: text.isEmpty ? '查看附件' : text));
    }
  }

  static String _summaryFromBlocks(
      List<AnnouncementContentBlock> blocks, String title) {
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (!block.isText) continue;
      final value = block.value.trim();
      if (value.isEmpty || value == title) continue;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(value.length > 180 ? value.substring(0, 180) : value);
      if (buffer.length >= 180) break;
    }
    final text = _cleanText(buffer.toString());
    if (text.isNotEmpty) return _truncateSummary(text);
    if (blocks.any((block) => block.isLink && _isPdf(block.value))) {
      return '[PDF文件]';
    }
    if (blocks.any((block) => block.isImage)) return '[图片]';
    if (blocks.any((block) => block.isTable)) return '[表格]';
    return '';
  }

  static String _truncateSummary(String text) =>
      text.length > 110 ? '${text.substring(0, 110)}…' : text;

  static bool _isPdf(String url) =>
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.pdf') == true;

  /// Excerpts stop after enough visible text. They do not build table grids,
  /// inline-link runs or image blocks for the rest of a long article.
  static String _summarizeContent(
      dom.Element? root, dom.Document document, String title, String baseUrl) {
    final buffer = StringBuffer();
    var hasBlock = false;
    var hasTable = false;
    bool getEnoughText() => buffer.length >= 180;

    void appendText(String text, {bool listItem = false}) {
      if (text.isEmpty) return;
      hasBlock = true;
      final value = listItem ? '• $text' : text;
      if (value == title) return;
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(value.length > 180 ? value.substring(0, 180) : value);
    }

    void visit(dom.Element element) {
      if (getEnoughText()) return;
      final tag = element.localName;
      if (tag == 'script' || tag == 'style') return;
      if (tag == 'table') {
        if (element.classes.contains('shuArticle') ||
            _isSingleCellLayoutTable(element)) {
          for (final child in element.children) {
            visit(child);
            if (getEnoughText()) break;
          }
        } else {
          final tableHasRows = element.querySelectorAll('tr').any(
              (row) => row.parent == element || row.parent?.parent == element);
          hasTable = hasTable || tableHasRows;
          hasBlock = hasBlock || tableHasRows;
        }
        return;
      }
      if (tag == 'div' &&
          !element.children.any((child) => const {
                'div',
                'p',
                'table',
                'ul',
                'ol',
                'li',
                'h2',
                'h3'
              }.contains(child.localName))) {
        final separateBreaks = element.querySelector('br') != null &&
            element.nodes.every(_isPlainPreviewInline);
        appendText(_boundedPreviewText(element, baseUrl,
            separateBreaks: separateBreaks));
        return;
      }
      if (tag == 'p' || tag == 'li' || tag == 'h2' || tag == 'h3') {
        final anchors = element.querySelectorAll('a[href]');
        final onlyAttachments =
            anchors.isNotEmpty && anchors.every(_isAttachmentAnchor);
        if (onlyAttachments) {
          hasBlock = hasBlock ||
              anchors.any((anchor) => resolveAnnouncementUrl(
                      baseUrl, anchor.attributes['href'] ?? '')
                  .isNotEmpty);
        }
        appendText(
            _boundedPreviewText(element, baseUrl,
                omitAttachments: onlyAttachments),
            listItem: tag == 'li');
        return;
      }
      if (tag == 'a') {
        final href = element.attributes['href'] ?? '';
        hasBlock = hasBlock ||
            href.startsWith('mailto:') ||
            resolveAnnouncementUrl(baseUrl, href).isNotEmpty;
        return;
      }
      if (tag == 'img') {
        hasBlock = hasBlock || _previewImageUrl(element, baseUrl).isNotEmpty;
        return;
      }
      for (final child in element.children) {
        visit(child);
        if (getEnoughText()) break;
      }
    }

    if (root != null) {
      for (final child in root.children) {
        visit(child);
        if (getEnoughText()) break;
      }
      if (!hasBlock) {
        appendText(_boundedPreviewText(root, baseUrl, separateBreaks: true));
      }
    }
    final text = _cleanText(buffer.toString());
    if (text.isNotEmpty) return _truncateSummary(text);
    if (root != null) {
      for (final script in root.querySelectorAll('script')) {
        if (RegExp(r'''showVsbpdfIframe\(\s*["']([^"']+\.pdf)''',
                caseSensitive: false)
            .hasMatch(script.text)) {
          return '[PDF文件]';
        }
      }
      for (final anchor in root.querySelectorAll('a[href]')) {
        if (_isPdf(
            resolveAnnouncementUrl(baseUrl, anchor.attributes['href'] ?? ''))) {
          return '[PDF文件]';
        }
      }
    }
    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      if (href.contains('DownloadAttachUrl') &&
          _isPdf(resolveAnnouncementUrl(baseUrl, href))) {
        return '[PDF文件]';
      }
    }
    if (root
            ?.querySelectorAll('img')
            .any((image) => _previewImageUrl(image, baseUrl).isNotEmpty) ==
        true) {
      return '[图片]';
    }
    return hasTable ? '[表格]' : '';
  }

  static String _previewImageUrl(dom.Element image, String baseUrl) =>
      resolveAnnouncementUrl(
          baseUrl,
          image.attributes['orisrc'] ??
              image.attributes['data-src'] ??
              image.attributes['src'] ??
              image.attributes['vurl'] ??
              '');

  static bool _isPlainPreviewInline(dom.Node node) =>
      node is dom.Text ||
      node is dom.Element &&
          (node.localName == 'br' ||
              const {
                    'span',
                    'font',
                    'strong',
                    'b',
                    'em',
                    'i',
                    'u',
                    'sup',
                    'sub'
                  }.contains(node.localName) &&
                  node.nodes.every(_isPlainPreviewInline));

  static final _previewWhitespace = RegExp(r'\s');

  static String _boundedPreviewText(dom.Element element, String baseUrl,
      {bool omitAttachments = false, bool separateBreaks = false}) {
    final buffer = StringBuffer();
    var pendingSpace = false;
    void append(String value) {
      for (var index = 0;
          index < value.length && buffer.length < 180;
          index++) {
        final character = value[index];
        if (_previewWhitespace.hasMatch(character) || character == '\u00a0') {
          pendingSpace = buffer.isNotEmpty;
        } else {
          if (pendingSpace && buffer.length < 180) buffer.write(' ');
          pendingSpace = false;
          if (buffer.length < 180) buffer.write(character);
        }
      }
    }

    void walk(dom.Node node) {
      if (buffer.length >= 180) return;
      if (node is dom.Text) {
        append(node.text);
      } else if (node is dom.Element) {
        if (const {'script', 'style', 'img'}.contains(node.localName)) return;
        if (node.localName == 'a') {
          if (omitAttachments && _isAttachmentAnchor(node)) return;
          if (node.text.trim().isEmpty) {
            final href = node.attributes['href'] ?? '';
            append(href.startsWith('mailto:')
                ? href
                : resolveAnnouncementUrl(baseUrl, href));
            return;
          }
        }
        if (node.localName == 'br' && separateBreaks) append(' ');
        for (final child in node.nodes) {
          walk(child);
          if (buffer.length >= 180) break;
        }
      }
    }

    walk(element);
    return buffer.toString().trim();
  }

  static String _articleTitle(dom.Document document) {
    final declared = _cleanText(
      document.querySelector('meta[name="pageTitle"]')?.attributes['content'],
    );
    if (declared.isNotEmpty) return declared;
    for (final selector in const [
      '.nry h1',
      '.art-tit h3',
      'header.n-detail-title > h2',
      '.Head',
    ]) {
      final title = _cleanText(document.querySelector(selector)?.text);
      if (title.isNotEmpty) return title;
    }
    return '';
  }

  static dom.Document _parseDetailDocument(String html) {
    // Some VSB templates put the content div directly inside a layout table.
    // Supply its missing cell before HTML parsing can move a nested data table
    // and subsequent paragraphs outside the article body.
    final normalized = html.replaceAllMapped(
      RegExp(
        r'''(<table\b[^>]*\sclass\s*=\s*["'](?:[^"']*\s)?shuArticle(?:\s[^"']*)?["'][^>]*>)(\s*)(?=<div\b)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}<tbody><tr><td>${match[2]}',
    );
    return html_parser.parse(normalized);
  }

  static bool _isUnavailableAnnouncementPage(
    String html, {
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final title = _cleanText(document.querySelector('title')?.text);
    final message = _cleanText(document.body?.text);
    final missingArticle = RegExp(r'^没有找到文章\s*ID[。！!]?$');
    return title.contains('404错误提示') ||
        (message.contains('系统提示') && message.contains('您访问的页面未找到')) ||
        document
            .querySelectorAll('.content, .v_news_content, #vsb_content')
            .any(
                (element) => missingArticle.hasMatch(_cleanText(element.text)));
  }

  static List<AnnouncementContentBlock> _parseContentBlocks(
    dom.Element root, {
    required String baseUrl,
  }) {
    final blocks = <AnnouncementContentBlock>[];
    final linked = <String>{};
    final imaged = <String>{};

    void addImage(dom.Element image) {
      final src = image.attributes['orisrc'] ??
          image.attributes['data-src'] ??
          image.attributes['src'] ??
          image.attributes['vurl'] ??
          '';
      final imageUrl = resolveAnnouncementUrl(baseUrl, src);
      if (imageUrl.isEmpty || !imaged.add(imageUrl)) return;
      blocks.add(AnnouncementContentBlock.image(
        imageUrl,
        alt: _cleanText(image.attributes['alt'] ?? image.attributes['title']),
      ));
    }

    void addLink(dom.Element anchor) {
      final href = anchor.attributes['href'] ?? '';
      final link = href.startsWith('mailto:')
          ? href
          : resolveAnnouncementUrl(baseUrl, href);
      if (link.isEmpty || !linked.add(link)) return;
      blocks.add(AnnouncementContentBlock.link(
        link,
        label:
            _cleanText(anchor.text).isEmpty ? '查看附件' : _cleanText(anchor.text),
      ));
    }

    // VSB renders some PDFs through JavaScript. The page embeds image URLs for
    // each PDF page, which can be displayed with the same image widget as photos.
    for (final script in root.querySelectorAll('script')) {
      final code = script.text;
      final pdf = RegExp(r'''showVsbpdfIframe\(\s*["']([^"']+\.pdf)''',
              caseSensitive: false)
          .firstMatch(code);
      if (pdf == null) continue;
      for (final match in RegExp(r'''["']([^"']+\.(?:jpg|jpeg|png))["']''',
              caseSensitive: false)
          .allMatches(code)) {
        final imageUrl = resolveAnnouncementUrl(baseUrl, match.group(1) ?? '');
        if (imageUrl.isEmpty || !imaged.add(imageUrl)) continue;
        blocks.add(AnnouncementContentBlock.image(imageUrl));
      }
      final pdfUrl = resolveAnnouncementUrl(baseUrl, pdf.group(1) ?? '');
      if (pdfUrl.isNotEmpty && linked.add(pdfUrl)) {
        blocks.add(AnnouncementContentBlock.link(
          pdfUrl,
          label: '查看原始 PDF',
        ));
      }
    }

    void visit(dom.Element element) {
      final tag = element.localName;
      if (tag == 'style' || tag == 'script') return;
      if (tag == 'table' && element.classes.contains('shuArticle')) {
        for (final child in element.children) {
          visit(child);
        }
        return;
      }
      if (tag == 'table') {
        if (_isSingleCellLayoutTable(element)) {
          for (final child in element.children) {
            visit(child);
          }
          return;
        }
        final table = _parseTable(element);
        if (table.rows.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.structuredTable(
            rows: table.rows,
            cells: table.cells,
          ));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        for (final anchor in element.querySelectorAll('a[href]')) {
          addLink(anchor);
        }
        return;
      }
      if (tag == 'div' &&
          !element.children.any((child) => const {
                'div',
                'p',
                'table',
                'ul',
                'ol',
                'li',
                'h2',
                'h3'
              }.contains(child.localName))) {
        final separated = _parseBreakSeparatedText(element);
        if (separated != null) {
          blocks.addAll(separated);
          return;
        }
        final parts = _inlineParts(element, baseUrl);
        final text = parts.map((part) => part.text).join();
        if (text.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.text(text, parts: parts));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        return;
      }
      if (tag == 'img') {
        addImage(element);
        return;
      }
      if (tag == 'a') {
        addLink(element);
        return;
      }
      if (tag == 'p' || tag == 'li' || tag == 'h2' || tag == 'h3') {
        final anchors = element.querySelectorAll('a[href]');
        if (anchors.isNotEmpty && anchors.every(_isAttachmentAnchor)) {
          var surroundingText = element.text;
          for (final anchor in anchors) {
            surroundingText = surroundingText.replaceFirst(anchor.text, '');
          }
          final text = _cleanText(surroundingText);
          if (text.isNotEmpty) {
            blocks.add(
                AnnouncementContentBlock.text(tag == 'li' ? '• $text' : text));
          }
          for (final anchor in anchors) {
            addLink(anchor);
          }
          for (final image in element.querySelectorAll('img')) {
            addImage(image);
          }
          return;
        }
        final parts = _inlineParts(element, baseUrl);
        final text = parts.map((part) => part.text).join();
        if (text.isNotEmpty) {
          blocks.add(AnnouncementContentBlock.text(
            tag == 'li' ? '• $text' : text,
            parts: tag == 'li'
                ? [const AnnouncementInlinePart('• '), ...parts]
                : parts,
          ));
        }
        for (final image in element.querySelectorAll('img')) {
          addImage(image);
        }
        return;
      }
      for (final child in element.children) {
        visit(child);
      }
    }

    for (final child in root.children) {
      visit(child);
    }
    if (blocks.isEmpty) {
      final separated = _parseBreakSeparatedText(root);
      if (separated != null) {
        blocks.addAll(separated);
      } else {
        final text = _cleanText(_visibleText(root));
        if (text.isNotEmpty) blocks.add(AnnouncementContentBlock.text(text));
      }
    }
    return blocks;
  }

  static List<AnnouncementContentBlock>? _parseBreakSeparatedText(
      dom.Element element) {
    if (element.querySelector('br') == null) return null;
    const inlineTags = {
      'span',
      'font',
      'strong',
      'b',
      'em',
      'i',
      'u',
      'sup',
      'sub'
    };

    bool isPlainInline(dom.Node node) {
      if (node is dom.Text) return true;
      if (node is! dom.Element) return false;
      if (node.localName == 'br') return true;
      return inlineTags.contains(node.localName) &&
          node.nodes.every(isPlainInline);
    }

    if (!element.nodes.every(isPlainInline)) return null;

    final source = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        source.write(node.text
            .replaceAll('\u00a0', ' ')
            .replaceAll(RegExp(r'\s+'), ' '));
      } else if (node is dom.Element) {
        if (node.localName == 'br') {
          source.write('\n');
        } else {
          for (final child in node.nodes) {
            append(child);
          }
        }
      }
    }

    for (final node in element.nodes) {
      append(node);
    }
    final blocks = <AnnouncementContentBlock>[];
    for (final paragraph in source.toString().split(RegExp(r'\n{2,}'))) {
      final lines = paragraph
          .split('\n')
          .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((line) => line.isNotEmpty);
      final text = lines.join('\n');
      if (text.isNotEmpty) blocks.add(AnnouncementContentBlock.text(text));
    }
    return blocks.isEmpty ? null : blocks;
  }

  static bool _isAttachmentAnchor(dom.Element anchor) {
    final href = anchor.attributes['href'] ?? '';
    if (href.contains('DownloadAttachUrl')) return true;
    final path = Uri.tryParse(href)?.path.toLowerCase() ?? '';
    return RegExp(r'\.(?:pdf|docx?|xlsx?|pptx?|zip|rar|7z)$').hasMatch(path);
  }

  static List<AnnouncementInlinePart> _inlineParts(
      dom.Element element, String baseUrl) {
    final raw = <AnnouncementInlinePart>[];
    void appendRaw(AnnouncementInlinePart part) {
      if (raw.isNotEmpty && raw.last.url == part.url) {
        final previous = raw.removeLast();
        raw.add(
            AnnouncementInlinePart(previous.text + part.text, url: part.url));
      } else {
        raw.add(part);
      }
    }

    void walk(dom.Node node) {
      if (node is dom.Text) {
        appendRaw(AnnouncementInlinePart(node.text));
      } else if (node is dom.Element) {
        if (const {'script', 'style', 'img'}.contains(node.localName)) return;
        if (node.localName == 'a') {
          final href = node.attributes['href'] ?? '';
          final url = href.startsWith('mailto:')
              ? href
              : resolveAnnouncementUrl(baseUrl, href);
          appendRaw(AnnouncementInlinePart(
            node.text.trim().isEmpty ? url : node.text,
            url: url,
          ));
        } else {
          for (final child in node.nodes) {
            walk(child);
          }
        }
      }
    }

    for (final child in element.nodes) {
      walk(child);
    }
    final parts = <AnnouncementInlinePart>[];
    final autoLink = RegExp(
      r"(?:(?:https?://|www\.)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+|mailto:[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
      caseSensitive: false,
    );
    for (final part in raw) {
      final value =
          part.text.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ');
      if (part.url.isNotEmpty) {
        parts.add(AnnouncementInlinePart(value, url: part.url));
        continue;
      }
      var start = 0;
      for (final match in autoLink.allMatches(value)) {
        if (match.start > start) {
          parts
              .add(AnnouncementInlinePart(value.substring(start, match.start)));
        }
        final matched = match.group(0)!;
        final clean = _trimDetectedLink(matched);
        final lower = clean.toLowerCase();
        final url = lower.startsWith('mailto:')
            ? clean
            : lower.startsWith('www.')
                ? 'https://$clean'
                : lower.startsWith('http://') || lower.startsWith('https://')
                    ? clean
                    : 'mailto:$clean';
        parts.add(AnnouncementInlinePart(clean, url: url));
        if (clean.length < matched.length) {
          parts.add(AnnouncementInlinePart(matched.substring(clean.length)));
        }
        start = match.end;
      }
      if (start < value.length) {
        parts.add(AnnouncementInlinePart(value.substring(start)));
      }
    }
    if (parts.isEmpty) return parts;
    final first = parts.first;
    parts[0] = AnnouncementInlinePart(first.text.trimLeft(), url: first.url);
    final last = parts.last;
    parts[parts.length - 1] =
        AnnouncementInlinePart(last.text.trimRight(), url: last.url);
    return parts.where((part) => part.text.isNotEmpty).toList();
  }

  static String _trimDetectedLink(String candidate) {
    var end = candidate.length;
    while (end > 0) {
      final last = candidate[end - 1];
      if ('.!?;:,'.contains(last)) {
        end--;
        continue;
      }
      final opening = switch (last) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        _ => null,
      };
      if (opening == null) break;
      final prefix = candidate.substring(0, end);
      if (opening.allMatches(prefix).length >= last.allMatches(prefix).length) {
        break;
      }
      end--;
    }
    return candidate.substring(0, end);
  }

  static bool _isSingleCellLayoutTable(dom.Element table) {
    final rows = table.querySelectorAll('tr').where((row) {
      return row.parent == table || row.parent?.parent == table;
    }).toList();
    if (rows.length != 1) return false;

    final cells = rows.single.children.where((cell) {
      return cell.localName == 'td' || cell.localName == 'th';
    });
    if (cells.length != 1) return false;

    // Older Word-exported articles use a one-cell table as a layout wrapper
    // around paragraphs and sometimes a separate, real data table.
    const blockTags = {'div', 'p', 'table', 'ul', 'ol', 'li', 'h2', 'h3'};
    return cells.single.children
        .any((child) => blockTags.contains(child.localName));
  }

  static String _visibleText(dom.Node node) {
    if (node is dom.Text) return node.text;
    if (node is! dom.Element ||
        node.localName == 'script' ||
        node.localName == 'style') {
      return '';
    }
    final text = node.nodes.map(_visibleText).join();
    return _isTextBlock(node.localName) ? ' $text ' : text;
  }

  static bool _isTextBlock(String? tag) => const {
        'div',
        'p',
        'li',
        'ul',
        'ol',
        'table',
        'tr',
        'td',
        'th',
        'h1',
        'h2',
        'h3',
        'h4',
        'br',
      }.contains(tag);

  static _ParsedAnnouncementTable _parseTable(dom.Element table) {
    final occupied = <List<bool>>[];
    final cells = <AnnouncementTableCell>[];
    final rows = table.querySelectorAll('tr').where((row) {
      return row.parent == table || row.parent?.parent == table;
    });
    var rowIndex = 0;
    for (final row in rows) {
      while (occupied.length <= rowIndex) {
        occupied.add(<bool>[]);
      }
      var columnIndex = 0;
      final rowCells = row.children
          .where((cell) => cell.localName == 'td' || cell.localName == 'th');
      for (final cell in rowCells) {
        while (columnIndex < occupied[rowIndex].length &&
            occupied[rowIndex][columnIndex]) {
          columnIndex++;
        }
        final text = _cleanText(_visibleText(cell));
        final columnSpan = int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
        final rowSpan = int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1;
        final safeColumnSpan = columnSpan.clamp(1, 64).toInt();
        final safeRowSpan = rowSpan.clamp(1, 1000).toInt();
        cells.add(AnnouncementTableCell(
          row: rowIndex,
          column: columnIndex,
          text: text,
          rowSpan: safeRowSpan,
          columnSpan: safeColumnSpan,
          textAlignment: _tableTextAlignment(cell),
          verticalAlignment: _tableVerticalAlignment(cell),
        ));
        for (var rowOffset = 0; rowOffset < safeRowSpan; rowOffset++) {
          final targetRow = rowIndex + rowOffset;
          while (occupied.length <= targetRow) {
            occupied.add(<bool>[]);
          }
          for (var columnOffset = 0;
              columnOffset < safeColumnSpan;
              columnOffset++) {
            final targetColumn = columnIndex + columnOffset;
            while (occupied[targetRow].length <= targetColumn) {
              occupied[targetRow].add(false);
            }
            occupied[targetRow][targetColumn] = true;
          }
        }
        columnIndex += safeColumnSpan;
      }
      rowIndex++;
    }
    final columnCount = occupied.fold<int>(
      0,
      (count, row) => row.length > count ? row.length : count,
    );
    final textGrid = List.generate(
      occupied.length,
      (_) => List<String>.filled(columnCount, ''),
    );
    for (final cell in cells) {
      if (cell.row < textGrid.length && cell.column < columnCount) {
        textGrid[cell.row][cell.column] = cell.text;
      }
    }
    return _ParsedAnnouncementTable(
      rows: textGrid,
      cells: cells,
    );
  }

  static String _tableTextAlignment(dom.Element cell) {
    String? explicitAlignment(dom.Element element) {
      final attribute = _normalizedAlignment(element.attributes['align']);
      if (attribute != null) return attribute;
      if (element.localName == 'center') return 'center';
      return RegExp(r'(?:^|;)\s*text-align\s*:\s*(left|center|right|justify)\b',
              caseSensitive: false)
          .firstMatch(element.attributes['style'] ?? '')
          ?.group(1)
          ?.toLowerCase();
    }

    String? descendantAlignment;
    for (final descendant in cell.querySelectorAll('*')) {
      descendantAlignment =
          explicitAlignment(descendant) ?? descendantAlignment;
    }
    if (descendantAlignment != null) return descendantAlignment;
    for (dom.Element? current = cell;
        current != null;
        current = current.parent) {
      final alignment = explicitAlignment(current);
      if (alignment != null) return alignment;
      if (current.localName == 'table') break;
    }
    return 'left';
  }

  static String _tableVerticalAlignment(dom.Element cell) {
    String? explicitAlignment(dom.Element element) {
      final attribute = (element.attributes['valign'] ?? '').toLowerCase();
      if (const {'top', 'middle', 'bottom'}.contains(attribute)) {
        return attribute;
      }
      return RegExp(
        r'(?:^|;)\s*vertical-align\s*:\s*(top|middle|bottom)\b',
        caseSensitive: false,
      ).firstMatch(element.attributes['style'] ?? '')?.group(1)?.toLowerCase();
    }

    String? descendantAlignment;
    for (final descendant in cell.querySelectorAll('*')) {
      descendantAlignment =
          explicitAlignment(descendant) ?? descendantAlignment;
    }
    if (descendantAlignment != null) return descendantAlignment;
    for (dom.Element? current = cell;
        current != null;
        current = current.parent) {
      final alignment = explicitAlignment(current);
      if (alignment != null) return alignment;
      if (current.localName == 'table') break;
    }
    return 'middle';
  }

  static String? _normalizedAlignment(String? value) {
    final alignment = (value ?? '').toLowerCase();
    return const {'left', 'center', 'right', 'justify'}.contains(alignment)
        ? alignment
        : null;
  }

  static AnnouncementMetadata _parseMetadata(
    dom.Element? element, {
    required dom.Document document,
  }) {
    var dateText = '';
    var author = '';
    var department = '';
    for (final span in element?.querySelectorAll('span') ?? const []) {
      final text = _cleanText(span.text);
      if (text.startsWith('发布时间：')) {
        dateText = text.substring('发布时间：'.length).trim();
      } else if (text.startsWith('时间：')) {
        final value = text.substring('时间：'.length).trim();
        final date = _parseDate(value);
        dateText = date == null
            ? value
            : '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}';
      } else if (text.startsWith('部门：')) {
        department = text.substring('部门：'.length).trim();
      } else if (text.startsWith('部门:')) {
        department = text.substring('部门:'.length).trim();
      }
    }
    final labelElements = document
        .querySelectorAll(
          '.xx span, p span, span[id*="lblAuthor"]',
        )
        .where((element) => !_insideArticleBody(element));
    for (final span in labelElements) {
      final text = _cleanText(span.text);
      if (!_isAuthorLabel(text)) continue;
      author = _authorValue(text);
      if (author.isEmpty) {
        final next = _cleanText(span.nextElementSibling?.text);
        if (next.isNotEmpty) author = next;
      }
      if (author.isNotEmpty) break;
    }
    if (author.isEmpty) {
      for (final selector in const [
        'span[id*="lblUser"]',
        'span[id*="lblAuthor"]',
        'span[id*="articleAuthor"]',
        r'a[id$="_hypFirst"]',
        r'a[id$="_hypUser"]',
      ]) {
        for (final element in document.querySelectorAll(selector)) {
          if (_insideArticleBody(element) ||
              element.querySelector('script') != null) {
            continue;
          }
          final candidate = _cleanText(element.text);
          if (candidate.isEmpty) continue;
          author =
              _isAuthorLabel(candidate) ? _authorValue(candidate) : candidate;
          if (author.isNotEmpty) break;
        }
        if (author.isNotEmpty) break;
      }
    }
    return AnnouncementMetadata(
      dateText: dateText,
      author: author,
      department: department,
    );
  }

  static bool _insideArticleBody(dom.Element element) {
    for (dom.Element? parent = element;
        parent != null;
        parent = parent.parent) {
      if (parent.classes.contains('v_news_content') ||
          parent.classes.contains('news-detail-infowrap') ||
          parent.id.startsWith('vsb_content')) {
        return true;
      }
    }
    return false;
  }

  static bool _isAuthorLabel(String value) =>
      value.startsWith('投稿：') ||
      value.startsWith('投稿:') ||
      value.startsWith('作者：') ||
      value.startsWith('作者:') ||
      value.startsWith('供稿：') ||
      value.startsWith('供稿:') ||
      value.startsWith('发布人：') ||
      value.startsWith('发布人:') ||
      value.startsWith('发布者：') ||
      value.startsWith('发布者:');

  static AnnouncementMetadata? _parseVsbLegacyMetadata(dom.Document document) {
    for (final row in document.querySelectorAll('tr[valign="middle"]')) {
      var inArticleBody = false;
      for (var parent = row.parent; parent != null; parent = parent.parent) {
        if (parent.classes.contains('v_news_content') ||
            parent.id.startsWith('vsb_content')) {
          inArticleBody = true;
          break;
        }
      }
      if (inArticleBody) continue;
      final label = row.querySelector('span');
      if (!RegExp(r'^(?:创建|发布)时间').hasMatch(_cleanText(label?.text))) {
        continue;
      }
      final date = _parseDate(_cleanText(label?.nextElementSibling?.text));
      final author = row
          .querySelectorAll('font[face=""] > span')
          .where((span) =>
              !span.id.endsWith('lblTimes') &&
              span.querySelector('script') == null)
          .map((span) => _cleanText(span.text))
          .firstWhere((text) => text.isNotEmpty, orElse: () => '');
      return AnnouncementMetadata(
        dateText: date == null
            ? ''
            : '${date.year.toString().padLeft(4, '0')}-'
                '${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')}',
        author: author,
        department: '',
      );
    }
    return null;
  }

  static String _authorValue(String value) {
    final separator = value.indexOf(RegExp('[:：]'));
    return separator < 0 ? '' : value.substring(separator + 1).trim();
  }

  static DateTime? _parseDate(String value) {
    final match =
        RegExp(r'(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})').firstMatch(value);
    if (match == null) {
      return null;
    }
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) {
      return null;
    }
    return DateTime(year, month, day);
  }

  static String _cleanText(String? value) {
    return (value ?? '')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _ParsedAnnouncementTable {
  const _ParsedAnnouncementTable({required this.rows, required this.cells});

  final List<List<String>> rows;
  final List<AnnouncementTableCell> cells;
}
