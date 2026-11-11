import 'package:flutter/material.dart';

import '../../data/models/library_daily_recommend.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_author_text.dart';
import 'library_book_detail_page.dart';

class LibraryDailyRecommendCard extends StatelessWidget {
  const LibraryDailyRecommendCard({
    super.key,
    required this.book,
    this.onTap,
  });

  final LibraryDailyRecommend book;
  final VoidCallback? onTap;

  static const double _coverWidth = 78.0;
  static const double _coverHeight = 108.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '今日推荐',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        InkWell(
          onTap: onTap ??
              () {
                Navigator.of(context).push(
                  shuyoRoute(
                    builder: (context) => LibraryBookDetailPage(
                      recordId: book.recordId,
                      title: book.title,
                    ),
                  ),
                );
              },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(context, colors),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title.isNotEmpty ? book.title : '未知书名',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      _buildAuthorRow(colors),
                      if (_buildPublishRow(colors) != null) ...[
                        const SizedBox(height: 4),
                        _buildPublishRow(colors)!,
                      ],
                      const SizedBox(height: 5),
                      Text(
                        book.summary?.trim().isNotEmpty == true
                            ? book.summary!.trim()
                            : '暂无简介',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: colors.textMuted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (book.totalHolding != null) ...[
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${book.onShelfHolding ?? 0}',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: colors.accent,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '/${book.totalHolding}本',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          if (book.callNo != null && book.callNo!.isNotEmpty)
                            Expanded(
                              child: _buildCallNoRow(colors, book.callNo!),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCover(BuildContext context, ShuYoColors colors) {
    final coverUrl = book.coverUrl;
    final placeholder = Container(
      width: _coverWidth,
      height: _coverHeight,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: colors.textMuted,
          size: 28,
        ),
      ),
    );

    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        coverUrl,
        width: _coverWidth,
        height: _coverHeight,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => placeholder,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return placeholder;
        },
      ),
    );
  }

  Widget _buildCallNoRow(ShuYoColors colors, String callNo) {
    final slashIndex = callNo.indexOf('/');
    if (slashIndex > 0) {
      final classNo = callNo.substring(0, slashIndex);
      final remaining = callNo.substring(slashIndex); // 如 "/TP181"
      return Text.rich(
        TextSpan(
          text: '索书号 ',
          style: TextStyle(
            fontSize: 13.5,
            color: colors.textSecondary,
          ),
          children: [
            TextSpan(
              text: classNo,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            const TextSpan(text: ' '),
            TextSpan(
              text: remaining,
              style: TextStyle(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text(
      '索书号 $callNo',
      style: TextStyle(
        fontSize: 13.5,
        color: colors.textSecondary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildAuthorRow(ShuYoColors colors) {
    return LibraryAuthorText(
      parsed: book.parsedAuthors,
      fallbackText: book.author?.trim() ?? '',
      style: TextStyle(
        fontSize: 12.5,
        color: colors.textSecondary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget? _buildPublishRow(ShuYoColors colors) {
    final publisher = book.publisher?.trim() ?? '';
    final year = book.publishYear?.trim() ?? '';

    if (publisher.isEmpty && year.isEmpty) {
      return null;
    }

    return Text.rich(
      TextSpan(
        text: publisher,
        style: TextStyle(
          fontSize: 12.5,
          color: colors.textSecondary,
        ),
        children: [
          if (year.isNotEmpty) ...[
            if (publisher.isNotEmpty) const TextSpan(text: ' '),
            TextSpan(
              text: '($year)',
              style: TextStyle(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
