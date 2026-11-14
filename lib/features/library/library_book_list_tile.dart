import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_author_text.dart';
import 'library_book_detail_page.dart';

/// 复刻榜单列表项的图书展示行，供榜单页与搜索页共同使用。
class LibraryBookListTile extends StatelessWidget {
  const LibraryBookListTile({
    super.key,
    required this.book,
    this.rankNumber,
    this.showTopBadge = false,
    this.coverWidth = 76.0,
    this.coverHeight = 106.0,
    this.hotLoanSort = HotLoanSortType.loanCount,
    this.apiClient,
    this.session,
    this.onTap,
  });

  final LibraryBookItem book;
  final int? rankNumber;
  final bool showTopBadge;
  final double coverWidth;
  final double coverHeight;
  final HotLoanSortType hotLoanSort;
  final LibraryApiClient? apiClient;
  final LibraryAuthSession? session;
  final VoidCallback? onTap;

  String? _buildBadgeText(LibraryBookItem book) {
    if (hotLoanSort == HotLoanSortType.loanRate && book.loanRate != null) {
      return '借阅比 ${(book.loanRate! * 100).toStringAsFixed(1)}%';
    }
    return book.badgeText;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return InkWell(
      onTap: onTap ??
          () {
            Navigator.of(context).push(
              shuyoRoute(
                builder: (context) => LibraryBookDetailPage(
                  recordId: book.recordId,
                  title: book.title,
                  author: book.author,
                  publisher: book.publisher,
                  publishYear: book.publishYear,
                  coverUrl: book.coverUrl,
                  apiClient: apiClient,
                  session: session,
                ),
              ),
            );
          },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCover(colors),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: coverHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title.isNotEmpty ? book.title : '未知书名',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    LibraryAuthorText(
                      parsed: book.parsedAuthors,
                      fallbackText:
                          book.author?.isNotEmpty == true ? book.author! : '',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    if (_buildPublishRow(colors) != null) ...[
                      _buildPublishRow(colors)!,
                      const SizedBox(height: 3),
                    ],
                    if (book.rating != null && book.rating! > 0) ...[
                      const SizedBox(height: 3),
                      _buildStarRating(colors, book.rating!),
                    ] else if (_buildBadgeText(book) != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        _buildBadgeText(book)!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.accent,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const Spacer(),
                    Row(
                      children: [
                        if (book.totalHolding != null) ...[
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${book.onShelfHolding ?? 0}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: colors.accent,
                                  ),
                                ),
                                TextSpan(
                                  text: '/${book.totalHolding}本',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
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
            ),
            const SizedBox(width: 4),
            Padding(
              padding: EdgeInsets.only(top: coverHeight * 0.38),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.textMuted,
              ),
            ),
          ],
        ),
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
            fontSize: 13,
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
        fontSize: 13,
        color: colors.textSecondary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildStarRating(ShuYoColors colors, double rating) {
    final filledCount = rating.round().clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              i < filledCount ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 15,
              color: i < filledCount
                  ? colors.accent
                  : colors.textMuted.withValues(alpha: 0.6),
            ),
          ),
        const SizedBox(width: 4),
        Text(
          '${rating.toStringAsFixed(rating.truncateToDouble() == rating ? 0 : 1)}分',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.accent,
          ),
        ),
      ],
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
          fontSize: 12,
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

  Widget _buildCover(ShuYoColors colors) {
    final coverUrl = book.coverUrl;
    final placeholder = Container(
      width: coverWidth,
      height: coverHeight,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: colors.textMuted,
          size: 26,
        ),
      ),
    );

    final coverWidget = (coverUrl == null || coverUrl.isEmpty)
        ? placeholder
        : ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              coverUrl,
              width: coverWidth,
              height: coverHeight,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => placeholder,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return placeholder;
              },
            ),
          );

    final rank = rankNumber;
    if (!showTopBadge || rank == null || rank > 3) {
      return coverWidget;
    }

    return Stack(
      children: [
        coverWidget,
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(
              'TOP $rank',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
