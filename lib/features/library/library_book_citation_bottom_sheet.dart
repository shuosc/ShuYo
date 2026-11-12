import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/library_book_citation.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 引用格式展示底部弹窗
class LibraryBookCitationBottomSheet extends StatelessWidget {
  const LibraryBookCitationBottomSheet({
    super.key,
    required this.citation,
  });

  final LibraryBookCitation citation;

  static Future<void> show(
    BuildContext context, {
    required LibraryBookCitation citation,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LibraryBookCitationBottomSheet(citation: citation),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.paddingOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '引用',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '复制并粘贴一种已设定好的引用格式',
            style: TextStyle(
              fontSize: 13,
              color: colors.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _CitationRow(
            colors: colors,
            name: 'GB/T 7714',
            content: citation.gb7714,
          ),
          const SizedBox(height: 8),
          _CitationRow(
            colors: colors,
            name: 'MLA',
            content: citation.mla,
          ),
          const SizedBox(height: 8),
          _CitationRow(
            colors: colors,
            name: 'APA',
            content: citation.apa,
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: colors.border.withValues(alpha: 0.6)),
          const SizedBox(height: 16),
          Text(
            '或利用其中一个链接导入到文献管理软件中',
            style: TextStyle(
              fontSize: 13,
              color: colors.textMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _buildExportTags(context, colors),
        ],
      ),
    );
  }

  Widget _buildExportTags(BuildContext context, ShuYoColors colors) {
    final links = [
      ('BibTex', citation.exportBibTex()),
      ('EndNote', citation.exportEndNote()),
      ('RefMan', citation.exportRefMan()),
      ('NoteExpress', citation.exportNoteExpress()),
      ('NoteFirst', citation.exportNoteFirst()),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in links)
          _ExportTagButton(
            colors: colors,
            name: item.$1,
            content: item.$2,
          ),
      ],
    );
  }
}

/// 引用条目（参照“播放器的播放链接”设计：标题独占一行，下方一整行展示引用内容 + 动效复制按钮，文字稍微放大）
class _CitationRow extends StatefulWidget {
  const _CitationRow({
    required this.colors,
    required this.name,
    required this.content,
  });

  final ShuYoColors colors;
  final String name;
  final String content;

  @override
  State<_CitationRow> createState() => _CitationRowState();
}

class _CitationRowState extends State<_CitationRow> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.content));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.name,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _handleCopy,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        widget.content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _AnimatedCopyButton(
                      colors: colors,
                      copied: _copied,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 导出管理软件格式标签按钮
class _ExportTagButton extends StatefulWidget {
  const _ExportTagButton({
    required this.colors,
    required this.name,
    required this.content,
  });

  final ShuYoColors colors;
  final String name;
  final String content;

  @override
  State<_ExportTagButton> createState() => _ExportTagButtonState();
}

class _ExportTagButtonState extends State<_ExportTagButton> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.content));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Material(
      color: colors.surfaceAlt,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: _handleCopy,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _copied
                  ? colors.textSecondary
                  : colors.border.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: child,
                ),
                child: _copied
                    ? Icon(
                        Icons.check_rounded,
                        key: const ValueKey('tag-checked'),
                        size: 13,
                        color: colors.textPrimary,
                      )
                    : Icon(
                        Icons.copy_rounded,
                        key: const ValueKey('tag-copy'),
                        size: 13,
                        color: colors.textMuted,
                      ),
              ),
              const SizedBox(width: 5),
              Text(
                widget.name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 复制图标：纯中性色（不用主题色），带 √ 动画，1 秒后平滑恢复
class _AnimatedCopyButton extends StatelessWidget {
  const _AnimatedCopyButton({
    required this.colors,
    required this.copied,
  });

  final ShuYoColors colors;
  final bool copied;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: copied
            ? Icon(
                Icons.check_rounded,
                key: const ValueKey('copied'),
                size: 16,
                color: colors.textPrimary,
              )
            : Icon(
                Icons.copy_rounded,
                key: const ValueKey('copy'),
                size: 16,
                color: colors.textMuted,
              ),
      ),
    );
  }
}
