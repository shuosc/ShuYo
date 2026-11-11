import 'package:flutter/material.dart';

import '../../core/utils/library_author_parser.dart';

/// 渲染图书作者文本，支持针对国旗 Emoji 单独应用 Twemoji 字体，避免影响常规中英文字符渲染
class LibraryAuthorText extends StatelessWidget {
  const LibraryAuthorText({
    super.key,
    required this.parsed,
    required this.fallbackText,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final ParsedBookAuthors parsed;
  final String fallbackText;
  final TextStyle? style;
  final int maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    if (parsed.isEmpty) {
      final text = fallbackText.isNotEmpty ? fallbackText : '-';
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final spans = _buildSpans(context);
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  List<InlineSpan> _buildSpans(BuildContext context) {
    final spans = <InlineSpan>[];
    final parts = <List<InlineSpan>>[];

    // 1. 原著或主要作者
    if (parsed.originals.isNotEmpty) {
      parts.add([
        ..._buildAuthorListSpans(parsed.originals, maxCount: 2),
        if (parsed.originals.length > 2 || parsed.hasEtAl)
          const TextSpan(text: ' 等'),
        const TextSpan(text: ' 原著'),
      ]);
    } else if (parsed.authors.isNotEmpty) {
      parts.add([
        ..._buildAuthorListSpans(parsed.authors, maxCount: 2),
        if (parsed.authors.length > 2 || parsed.hasEtAl)
          const TextSpan(text: ' 等'),
        const TextSpan(text: ' 著'),
      ]);
    } else if (parsed.editors.isNotEmpty) {
      parts.add([
        ..._buildAuthorListSpans(parsed.editors, maxCount: 2),
        if (parsed.editors.length > 2 || parsed.hasEtAl)
          const TextSpan(text: ' 等'),
        const TextSpan(text: ' 编'),
      ]);
    }

    // 2. 改编
    if (parsed.adapters.isNotEmpty) {
      parts.add([
        ..._buildAuthorListSpans(parsed.adapters, maxCount: 2),
        const TextSpan(text: ' 改编'),
      ]);
    }

    // 3. 译者
    if (parsed.translators.isNotEmpty) {
      final shownTranslators =
          parsed.translators.take(2).map((t) => t.name).join(', ');
      final etAl = (parsed.translators.length > 2 ||
              (parsed.hasEtAl && parsed.authors.isEmpty))
          ? ' 等'
          : '';
      parts.add([
        TextSpan(text: '$shownTranslators$etAl 译'),
      ]);
    }

    // 4. 绘者
    if (parts.isEmpty && parsed.illustrators.isNotEmpty) {
      parts.add([
        ..._buildAuthorListSpans(parsed.illustrators, maxCount: 2),
        const TextSpan(text: ' 绘'),
      ]);
    }

    for (var i = 0; i < parts.length; i++) {
      if (i > 0) {
        spans.add(const TextSpan(text: ' / '));
      }
      spans.addAll(parts[i]);
    }

    return spans;
  }

  List<InlineSpan> _buildAuthorListSpans(
    List<LibraryAuthorEntity> list, {
    required int maxCount,
  }) {
    final spans = <InlineSpan>[];
    final items = list.take(maxCount).toList();
    if (items.isEmpty) return spans;

    final firstWithBadge = items.firstWhere(
      (a) => a.badgeText != null,
      orElse: () => items.first,
    );

    // 如果包含国旗 Emoji，将国旗单独设为 Twemoji 字体族
    // 格式: (<国旗>国家名)作者名，国旗挪入括号内紧邻国家名
    final flag = firstWithBadge.flagEmoji;
    if (flag != null && flag.isNotEmpty) {
      spans.add(const TextSpan(text: '('));
      spans.add(
        TextSpan(
          text: flag,
          style: const TextStyle(fontFamily: 'Twemoji'),
        ),
      );
      final name =
          firstWithBadge.countryName ?? firstWithBadge.countryCode ?? '';
      spans.add(TextSpan(text: '$name)'));
    } else if (firstWithBadge.isAncient) {
      spans.add(TextSpan(text: '${firstWithBadge.badgeText}'));
    }

    for (var i = 0; i < items.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: ', '));
      spans.add(TextSpan(text: items[i].name));
    }

    return spans;
  }
}
