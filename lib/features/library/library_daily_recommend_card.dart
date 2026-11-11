import 'package:flutter/material.dart';

import '../../data/models/library_daily_recommend.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
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
              fontWeight: FontWeight.bold,
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
                  child: SizedBox(
                    height: _coverHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title.isNotEmpty ? book.title : '未知书名',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        _buildAuthorRow(colors),
                        const SizedBox(height: 3),
                        _buildPublishRow(colors),
                        const SizedBox(height: 4),
                        Expanded(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              book.summary?.trim().isNotEmpty == true
                                  ? book.summary!.trim()
                                  : '暂无简介',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: colors.textMuted,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
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

  Widget _buildAuthorRow(ShuYoColors colors) {
    final author = book.author?.trim();
    return Row(
      children: [
        Icon(
          Icons.person_outline,
          size: 14,
          color: colors.textSecondary,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            author?.isNotEmpty == true ? author! : '暂无作者信息',
            style: TextStyle(
              fontSize: 12.5,
              color: colors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildPublishRow(ShuYoColors colors) {
    final publisher = book.publisher?.trim() ?? '';
    final year = book.publishYear?.trim() ?? '';

    return Row(
      children: [
        Icon(
          Icons.business_outlined,
          size: 14,
          color: colors.textSecondary,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: publisher.isNotEmpty
                  ? publisher
                  : (year.isNotEmpty ? '' : '暂无出版信息'),
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
          ),
        ),
      ],
    );
  }
}
