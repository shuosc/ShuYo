import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_book_detail_page.dart';

class LibraryRankGallery extends StatelessWidget {
  const LibraryRankGallery({
    super.key,
    required this.selectedType,
    required this.books,
    required this.isLoading,
    required this.onTypeChanged,
    required this.onViewAll,
  });

  final LibraryRankType selectedType;
  final List<LibraryBookItem> books;
  final bool isLoading;
  final ValueChanged<LibraryRankType> onTypeChanged;
  final VoidCallback onViewAll;

  static const double _coverWidth = 70.0;
  static const double _coverHeight = 98.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(colors),
        const SizedBox(height: 10),
        _buildContent(context, colors),
        _buildBottomAction(colors),
      ],
    );
  }

  Widget _buildHeader(ShuYoColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: LibraryRankType.values.map((type) {
          final isSelected = type == selectedType;
          return Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  if (isSelected) {
                    onViewAll();
                  } else {
                    onTypeChanged(type);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Center(
                    child: Text(
                      type.label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                        color:
                            isSelected ? colors.textPrimary : colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ShuYoColors colors) {
    if (isLoading && books.isEmpty) {
      return SizedBox(
        height: _coverHeight + 42,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (books.isEmpty) {
      return SizedBox(
        height: _coverHeight + 42,
        child: Center(
          child: Text(
            '暂无相关图书',
            style: TextStyle(
              fontSize: 12,
              color: colors.textMuted,
            ),
          ),
        ),
      );
    }

    // 主页最多展示 10 本，横向滑动时不附加更多按钮
    final displayBooks = books.take(10).toList();

    return SizedBox(
      height: _coverHeight + 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: displayBooks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final book = displayBooks[index];
          return _buildBookItem(context, colors, book);
        },
      ),
    );
  }

  Widget _buildBookItem(
    BuildContext context,
    ShuYoColors colors,
    LibraryBookItem book,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
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
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: SizedBox(
            width: _coverWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCover(context, colors, book),
                const SizedBox(height: 6),
                Text(
                  book.title.isNotEmpty ? book.title : '未知书名',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  book.author?.isNotEmpty == true ? book.author! : '暂无作者',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(
    BuildContext context,
    ShuYoColors colors,
    LibraryBookItem book,
  ) {
    final coverUrl = book.coverUrl;
    final placeholder = Container(
      width: _coverWidth,
      height: _coverHeight,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: colors.textMuted,
          size: 24,
        ),
      ),
    );

    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
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

  Widget _buildBottomAction(ShuYoColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: onViewAll,
          style: TextButton.styleFrom(
            foregroundColor: colors.textSecondary,
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('查看榜单'),
              SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
